# Logging

The logging subsystem captures stdout and stderr from running containers and routes them to a pluggable log driver.

---

## Log Driver Interface

Every log driver implements:

```
interface LogDriver {
    // Called for each log line produced by the container
    Log(message: LogMessage) → error

    // Driver name (e.g. "json-file", "syslog")
    Name() → string

    // Release resources (close files, flush buffers)
    Close() → error
}

interface LogReader {
    // Only drivers that support reading back logs implement this
    ReadLogs(config: ReadConfig) → LogReadCloser
}

LogMessage {
    line:       []byte     // the log line content (without trailing newline)
    source:     string     // "stdout" or "stderr"
    timestamp:  time.Time
    attrs:      map<string, string>  // extra metadata
    partial:    bool       // true if this is a partial line (buffered)
}

ReadConfig {
    since:      time.Time
    until:      time.Time
    tail:       int        // -1 = all, N = last N lines
    follow:     bool
}
```

---

## Built-in Drivers

### json-file (default)

Writes each log message as a JSON line to a file on disk.

```
Format (one JSON object per line):
{"log":"hello world\n","stream":"stdout","time":"2024-01-01T00:00:00.123456789Z"}
{"log":"error: something failed\n","stream":"stderr","time":"2024-01-01T00:00:01.000000000Z"}
```

File location: `{data_root}/containers/{id}/{id}-json.log`

Options:
- `max-size`: rotate when file reaches this size (e.g. `"10m"`)
- `max-file`: keep this many rotated files (e.g. `"3"`)
- `compress`: gzip rotated files
- `labels`, `env`, `env-regex`: include container labels/env vars in each log line

Implementation:

```
struct JsonFileDriver {
    file:       File
    mu:         Mutex
    max_size:   int64
    max_file:   int
    current_size: int64
}

function Log(message):
    mu.Lock()
    entry = {
        log:    string(message.line) + "\n",
        stream: message.source,
        time:   message.timestamp.format(RFC3339Nano)
    }
    bytes = json.encode(entry) + "\n"
    file.Write(bytes)
    current_size += len(bytes)
    if max_size > 0 and current_size >= max_size:
        rotate()
    mu.Unlock()

function rotate():
    file.Close()
    rename("{id}-json.log.2" → "{id}-json.log.3")
    rename("{id}-json.log.1" → "{id}-json.log.2")
    rename("{id}-json.log"   → "{id}-json.log.1")
    file = open("{id}-json.log", create+write)
    current_size = 0
```

Reading logs back:

```
function ReadLogs(config):
    // If tail=N: scan backwards from end of file to find the Nth newline
    // Read forward from that position
    // If follow=true: after reaching EOF, use inotify/kqueue to watch for new writes
    return LogReadCloser{ ... }
```

### syslog

Sends log messages to the system syslog daemon via UDP/TCP or Unix socket.

```
Options:
- syslog-address:  "udp://localhost:514", "tcp://host:514", "unix:///dev/log"
- syslog-facility: "daemon", "local0"–"local7", etc.
- syslog-tag:      prefix for messages (default: container name)
- syslog-format:   "rfc3164" or "rfc5424"

Implementation: connect to syslog address, format message per RFC, send.
Does NOT support ReadLogs (cannot read back from syslog).
```

### journald

Sends to the systemd journal.

```
Uses: sd_journal_send() or /run/systemd/journal/socket
Includes container ID and name as journal fields.
Does NOT support ReadLogs unless journald is accessible.
```

### other drivers

- `awslogs` — sends to AWS CloudWatch Logs
- `gcplogs` — sends to Google Cloud Logging
- `splunk` — sends to Splunk HTTP Event Collector
- `fluentd` — sends to Fluentd over TCP/Unix
- `gelf` — sends to Graylog Extended Log Format

All external drivers: no ReadLogs support (logs live in the external service).

---

## Log Pipeline

When a container starts, a goroutine copies from the container's stdout/stderr pipes to the log driver.

```
function startLogCopier(container, stdout_pipe, stderr_pipe, driver):
    
    // Start two goroutines, one per stream
    go copyStream(stdout_pipe, "stdout", driver)
    go copyStream(stderr_pipe, "stderr", driver)

function copyStream(pipe, source, driver):
    scanner = LineScanner(pipe)
    while scanner.Scan():
        line = scanner.Bytes()
        timestamp = now()
        
        driver.Log(LogMessage{
            line:      line,
            source:    source,
            timestamp: timestamp,
        })
    
    // EOF: container's process closed its end of the pipe
    driver.Close()
```

For TTY containers, stdout and stderr are merged into a single stream — use one goroutine instead of two.

---

## Serving Logs to Clients

`GET /containers/{id}/logs` is served like this:

```
function handleLogs(container_id, opts):
    container = ContainerStore.Get(container_id)
    driver    = container.log_driver_instance
    
    if not driver implements LogReader:
        error "this log driver does not support reading"
    
    config = ReadConfig{
        since:  opts.since,
        until:  opts.until,
        tail:   opts.tail,
        follow: opts.follow,
    }
    reader = driver.ReadLogs(config)
    
    // Write in multiplexed stream format (see 02-api.md)
    while message = reader.ReadMessage():
        stream_type = 1 if message.source == "stdout" else 2
        if opts.timestamps:
            line = message.timestamp.format() + " " + message.line
        else:
            line = message.line
        
        // 8-byte header + payload
        write_multiplexed_frame(response, stream_type, line)
        flush(response)
        
        if not opts.follow and reader.EOF():
            break
```

---

## Log Driver Selection

Precedence (highest to lowest):

1. Per-container `LogConfig` in `HostConfig` at create time
2. Daemon default `log-driver` and `log-opts` from config
3. Built-in default: `json-file`

---

## Partial Lines

Long lines (> 16KB by default) are split into partial frames. The last frame has `partial=false`. Log drivers that reassemble lines should buffer partial frames and only emit when `partial=false`.

---

## Container-Scoped Log Files

The log file path is:
```
{data_root}/containers/{container_id}/{container_id}-json.log
```

When a container is removed, its log file is also deleted (unless the user saved it externally).

The size of all log files counts toward the container's disk usage in `GET /df`.
