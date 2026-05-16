# Events

The event system is a pub/sub bus inside the daemon. Every lifecycle change — container started, image pulled, network created — is published as an event. Clients can subscribe to a live stream or query recent history.

---

## Event Structure

```
Event {
    type:      string    // "container" | "image" | "network" | "volume" | "daemon" | "plugin"
    action:    string    // see tables below
    actor:     EventActor
    time:      int64     // Unix seconds
    time_nano: int64     // Unix nanoseconds
    scope:     string    // "local" (always, unless Swarm)
}

EventActor {
    id:         string              // entity ID (container ID, image digest, network ID, etc.)
    attributes: map<string, string> // extra context
}
```

---

## Event Types and Actions

### Container events

| Action | When | Actor attributes |
|--------|------|-----------------|
| `create` | ContainerCreate succeeds | `image`, `name` |
| `start` | Container process starts | `image`, `name` |
| `restart` | Container restarted by restart policy | `image`, `name` |
| `stop` | Container stopped gracefully | `image`, `name` |
| `kill` | Signal sent to container | `image`, `name`, `signal` |
| `die` | Container process exits | `image`, `name`, `exitCode` |
| `pause` | Container paused | `image`, `name` |
| `unpause` | Container unpaused | `image`, `name` |
| `attach` | Client attached to container I/O | `image`, `name` |
| `detach` | Client detached | `image`, `name` |
| `copy` | Files copied from/to container | `image`, `name` |
| `rename` | Container renamed | `image`, `name`, `oldName` |
| `resize` | TTY resized | `image`, `name` |
| `update` | Container resource limits updated | `image`, `name` |
| `destroy` | Container fully removed | `image`, `name` |
| `oom` | Container killed by OOM killer | `image`, `name` |
| `health_status` | Health check result | `image`, `name`, `health_status` |
| `exec_create` | Exec instance created | `image`, `name`, `execID` |
| `exec_start` | Exec instance started | `image`, `name`, `execID` |
| `exec_die` | Exec instance exited | `image`, `name`, `execID`, `exitCode` |

### Image events

| Action | When |
|--------|------|
| `pull` | Image successfully pulled |
| `push` | Image successfully pushed |
| `tag` | Image tagged |
| `untag` | Tag removed |
| `delete` | Image deleted |
| `import` | Image imported from tar |
| `load` | Image loaded from tar |
| `save` | Image saved to tar |
| `build` | Image built |

### Network events

| Action | When | Actor attributes |
|--------|------|-----------------|
| `create` | Network created | `name`, `type` |
| `connect` | Container connected | `name`, `type`, `container` |
| `disconnect` | Container disconnected | `name`, `type`, `container` |
| `destroy` | Network removed | `name`, `type` |

### Volume events

| Action | When |
|--------|------|
| `create` | Volume created |
| `mount` | Volume mounted into container |
| `unmount` | Volume unmounted |
| `destroy` | Volume removed |

### Daemon events

| Action | When |
|--------|------|
| `reload` | Config reloaded (SIGHUP) |

---

## Event Service Implementation

### In-memory ring buffer

The event service keeps the last N events (default: 256) in a ring buffer. New subscribers immediately receive all buffered events, then live events.

```
EventService {
    buffer:     RingBuffer<Event>(capacity=256)
    subscribers: []Subscriber
    mu:          Mutex
}

struct Subscriber {
    channel:   chan<Event>
    filter:    EventFilter
    cancel:    func()
}

struct EventFilter {
    types:   []string   // empty = all types
    actions: []string   // empty = all actions
    since:   timestamp  // only events after this time
    until:   timestamp  // only events before this time (0 = no limit)
    labels:  map<string, string>  // filter by actor attributes
}
```

### Publish

```
function Publish(event):
    mu.Lock()
    buffer.Push(event)
    for each subscriber in subscribers:
        if Filter.Matches(event, subscriber.filter):
            subscriber.channel <- event  // non-blocking: drop if channel full
    mu.Unlock()
```

### Subscribe

```
function Subscribe(filter) → ([]Event, <-chan Event, cancel_func):
    mu.Lock()
    
    // Return buffered events that match the filter
    history = []
    for each event in buffer.Snapshot():
        if event.time >= filter.since and Filter.Matches(event, filter):
            history.append(event)
    
    // Create live channel
    ch = make(chan Event, 64)
    sub = Subscriber{ channel: ch, filter: filter }
    subscribers.append(sub)
    
    cancel = func():
        mu.Lock()
        subscribers.remove(sub)
        close(ch)
        mu.Unlock()
    
    mu.Unlock()
    return history, ch, cancel
```

---

## HTTP Streaming (`GET /events`)

The events endpoint keeps the HTTP connection open and streams new events as they arrive.

```
function handleGetEvents(request, response):
    filter = parse_filter_from_query(request)
    
    history, live_chan, cancel = EventService.Subscribe(filter)
    defer cancel()
    
    response.headers["Content-Type"] = "application/json"
    response.WriteHeader(200)
    
    // Send historical events first
    for each event in history:
        write_json_line(response, event)
        flush(response)
    
    // Stream live events
    for {
        select {
            case event = <-live_chan:
                if filter.until > 0 and event.time > filter.until:
                    return
                write_json_line(response, event)
                flush(response)
            
            case <-request.context.Done():
                return  // client disconnected
        }
    }
```

---

## OOM Monitoring

The OOM (Out Of Memory) event requires a background goroutine watching the cgroup:

```
function monitorOOM(container):
    // cgroups v1: watch memory.oom_control eventfd
    // cgroups v2: watch memory.events file for "oom" counter changes
    
    on OOM detected:
        container.state.oom_killed = true
        EventService.Publish(Event{
            type:   "container",
            action: "oom",
            actor:  { id: container.id, attributes: {name: container.name} }
        })
```

---

## Health Check Events

When a container has a HEALTHCHECK defined, a goroutine runs the health check command periodically.

```
HealthCheckConfig {
    test:     []string  // ["CMD", "/healthcheck.sh"] or ["CMD-SHELL", "curl -f http://localhost/"]
    interval: duration  // default 30s
    timeout:  duration  // default 30s
    retries:  int       // default 3
    start_period: duration  // default 0 (grace period before failures count)
}
```

```
function runHealthChecks(container):
    consecutive_failures = 0
    
    loop every interval:
        result = runHealthCheckCommand(container, config.test, config.timeout)
        
        if result.exit_code == 0:
            consecutive_failures = 0
            container.state.health.status = "healthy"
        else:
            consecutive_failures++
            if consecutive_failures >= config.retries:
                container.state.health.status = "unhealthy"
            else:
                container.state.health.status = "starting"  (if in start_period)
        
        container.state.health.log.append(result)
        
        EventService.Publish(Event{
            type:   "container",
            action: "health_status",
            actor:  { attributes: { health_status: container.state.health.status } }
        })
```
