# HTTP API Contract

The daemon exposes a versioned REST API over a Unix socket (`/var/run/docker.sock`) and optionally TCP. All responses are JSON. The client sends `Content-Type: application/json` for request bodies.

---

## API Versioning

Every endpoint is prefixed with a version: `/v1.XX/`. The current minimum is `v1.24`.

The daemon negotiates: if the client requests a version the daemon doesn't support, it returns `400 Bad Request`. If the client requests an older version, the daemon responds in that older format.

```
GET /version
→ { "ApiVersion": "1.47", "MinAPIVersion": "1.24", ... }
```

---

## Transport

| Mode | Default path |
|------|-------------|
| Unix socket | `/var/run/docker.sock` |
| TCP | `tcp://0.0.0.0:2375` (insecure) |
| TLS TCP | `tcp://0.0.0.0:2376` (with cert/key) |

The daemon reads the socket permissions to determine if client auth is needed.

---

## Authentication

Registry credentials are sent per-request in the `X-Registry-Auth` header, base64-encoded JSON:

```json
{ "username": "user", "password": "pass", "serveraddress": "registry.example.com" }
```

For image operations against Docker Hub, this header is optional (public images work without it).

---

## Error Format

All errors return:

```json
{ "message": "human-readable error description" }
```

Common HTTP status codes:

| Code | Meaning |
|------|---------|
| 200 | Success |
| 201 | Created |
| 204 | No content (success with no body) |
| 304 | Not modified |
| 400 | Bad request (invalid parameters) |
| 404 | Not found |
| 409 | Conflict (container already running, name in use, etc.) |
| 500 | Server error |

---

## Container Endpoints

### Create a container

```
POST /v1.XX/containers/create?name={name}

Body: {
    "Image":      "ubuntu:22.04",
    "Cmd":        ["/bin/bash"],
    "Env":        ["KEY=value"],
    "WorkingDir": "/app",
    "ExposedPorts": { "80/tcp": {} },
    "HostConfig": {
        "Memory": 134217728,
        "PortBindings": { "80/tcp": [{"HostPort": "8080"}] },
        "Binds": ["/host:/container:ro"],
        "NetworkMode": "bridge",
        "RestartPolicy": { "Name": "unless-stopped" }
    },
    "NetworkingConfig": {
        "EndpointsConfig": {
            "my-network": { "Aliases": ["myapp"] }
        }
    }
}

Response 201: { "Id": "abc123...", "Warnings": [] }
Response 404: image not found
Response 409: name already in use
```

### Inspect a container

```
GET /v1.XX/containers/{id}/json

Response 200: full Container object (see data models)
```

### List containers

```
GET /v1.XX/containers/json?all=true&filters={"status":["running"]}

Query params:
  all=true        include stopped containers (default: only running)
  limit=N         max number to return
  size=true       include rootfs size (expensive)
  filters=<json>  e.g. {"status":["running"],"label":["env=prod"],"name":["myapp"]}

Response 200: array of container summaries
```

### Start a container

```
POST /v1.XX/containers/{id}/start

Response 204: started
Response 304: already running
Response 404: not found
```

### Stop a container

```
POST /v1.XX/containers/{id}/stop?t={seconds}

t: seconds to wait before SIGKILL (default: 10)

Response 204: stopped
Response 304: already stopped
```

### Restart a container

```
POST /v1.XX/containers/{id}/restart?t={seconds}

Response 204: restarted
```

### Kill a container (send a signal)

```
POST /v1.XX/containers/{id}/kill?signal={signal}

signal: SIGTERM, SIGKILL, SIGHUP, etc. (default: SIGKILL)

Response 204: signal sent
```

### Pause / Unpause a container

```
POST /v1.XX/containers/{id}/pause
POST /v1.XX/containers/{id}/unpause

Response 204: success
```

### Remove a container

```
DELETE /v1.XX/containers/{id}?v=true&force=true

v=true:     remove anonymous volumes created by this container
force=true: kill and remove even if running

Response 204: removed
Response 409: still running and force=false
```

### Get container logs

```
GET /v1.XX/containers/{id}/logs?stdout=true&stderr=true&follow=true&tail=100&timestamps=true&since=1700000000

stdout, stderr: which streams to include
follow=true:    stream new output (long-poll)
tail=N:         last N lines (default: all)
timestamps:     prefix each line with timestamp
since:          Unix timestamp to start from
until:          Unix timestamp to stop at

Response 200: multiplexed stream (see Multiplexed Streams section)
```

### Get container stats

```
GET /v1.XX/containers/{id}/stats?stream=true

stream=true: continuously stream stats (one JSON object per second)
stream=false: return one snapshot and close

Response 200: stream of stats JSON objects (one per line)
{
    "read": "2024-01-01T00:00:00Z",
    "cpu_stats": { "cpu_usage": {...}, "system_cpu_usage": 1234567 },
    "memory_stats": { "usage": 12345678, "limit": 134217728 },
    "networks": { "eth0": { "rx_bytes": 123, "tx_bytes": 456 } },
    "blkio_stats": {...},
    "pids_stats": { "current": 3 }
}
```

### Resize container TTY

```
POST /v1.XX/containers/{id}/resize?h={rows}&w={cols}

Response 200: OK
```

### Attach to container

```
POST /v1.XX/containers/{id}/attach?stdin=true&stdout=true&stderr=true&stream=true

Upgrades the HTTP connection to a raw stream (hijack).
If tty=true, it is a raw byte stream.
If tty=false, it is a multiplexed stream.
```

### Wait for container to stop

```
POST /v1.XX/containers/{id}/wait?condition={condition}

condition: "not-running" (default), "next-exit", "removed"

Response 200 (when condition is met): { "StatusCode": 0, "Error": null }
```

### Copy files from/to container

```
GET  /v1.XX/containers/{id}/archive?path={path}
     Response: tar stream

PUT  /v1.XX/containers/{id}/archive?path={dest_path}
     Body: tar stream
```

### Execute a command in a running container

```
POST /v1.XX/containers/{id}/exec
Body: {
    "Cmd":          ["/bin/sh", "-c", "ls /"],
    "AttachStdout": true,
    "AttachStderr": true,
    "AttachStdin":  false,
    "Tty":          false,
    "Privileged":   false,
    "User":         "",
    "WorkingDir":   ""
}
Response 201: { "Id": "<exec-id>" }

POST /v1.XX/exec/{exec-id}/start
Body: { "Detach": false, "Tty": false }
Response: stream (like attach)

GET /v1.XX/exec/{exec-id}/json
Response: exec process status
```

---

## Image Endpoints

### Pull an image

```
POST /v1.XX/images/create?fromImage=ubuntu&tag=22.04
Headers: X-Registry-Auth: <base64>

Response 200: stream of JSON progress objects
{"status":"Pulling from library/ubuntu","id":"22.04"}
{"status":"Pull complete","progressDetail":{},"id":"abc123"}
{"status":"Status: Downloaded newer image for ubuntu:22.04"}
```

### List images

```
GET /v1.XX/images/json?all=false&filters={"reference":["ubuntu:*"]}

Response 200: array of image summaries
```

### Inspect an image

```
GET /v1.XX/images/{name}/json

Response 200: full Image object
```

### Remove an image

```
DELETE /v1.XX/images/{name}?force=false&noprune=false

force=true:    remove even if containers are using it
noprune=false: also remove untagged parent images

Response 200: [{"Untagged": "ubuntu:22.04"}, {"Deleted": "sha256:abc123"}]
```

### Tag an image

```
POST /v1.XX/images/{name}/tag?repo=myrepo&tag=v1.0

Response 201: tagged
```

### Push an image

```
POST /v1.XX/images/{name}/push?tag=latest
Headers: X-Registry-Auth: <base64>

Response 200: stream of JSON progress objects
```

### Search Docker Hub

```
GET /v1.XX/images/search?term=ubuntu&limit=25

Response 200: array of search results
```

### Get image history

```
GET /v1.XX/images/{name}/history

Response 200: layer history
[{"Id":"abc123","Created":123456,"CreatedBy":"/bin/sh -c apt-get install vim","Size":12345678}]
```

### Build an image

```
POST /v1.XX/build?dockerfile=Dockerfile&t=myimage:latest&rm=true
Body: tar archive of build context

Response 200: stream of build output (JSON lines)
```

---

## Network Endpoints

### List networks

```
GET /v1.XX/networks?filters={"driver":["bridge"]}

Response 200: array of network objects
```

### Inspect a network

```
GET /v1.XX/networks/{id}

Response 200: full network object
```

### Create a network

```
POST /v1.XX/networks/create
Body: {
    "Name":     "my-network",
    "Driver":   "bridge",
    "Internal": false,
    "IPAM": {
        "Driver": "default",
        "Config": [{"Subnet": "172.18.0.0/16", "Gateway": "172.18.0.1"}]
    },
    "Options": {},
    "Labels": {}
}

Response 201: { "Id": "abc123", "Warning": "" }
```

### Remove a network

```
DELETE /v1.XX/networks/{id}

Response 204: removed
Response 409: network has active endpoints
```

### Connect container to network

```
POST /v1.XX/networks/{id}/connect
Body: {
    "Container": "<container-id>",
    "EndpointConfig": {
        "Aliases": ["myapp"],
        "IPAddress": "172.18.0.5"  // optional static IP
    }
}

Response 200: OK
```

### Disconnect container from network

```
POST /v1.XX/networks/{id}/disconnect
Body: { "Container": "<container-id>", "Force": false }

Response 200: OK
```

---

## Volume Endpoints

### List volumes

```
GET /v1.XX/volumes

Response 200: { "Volumes": [...], "Warnings": [] }
```

### Create a volume

```
POST /v1.XX/volumes/create
Body: {
    "Name":   "my-volume",
    "Driver": "local",
    "DriverOpts": {},
    "Labels": {}
}

Response 201: full volume object
```

### Inspect a volume

```
GET /v1.XX/volumes/{name}

Response 200: full volume object
```

### Remove a volume

```
DELETE /v1.XX/volumes/{name}?force=false

Response 204: removed
Response 409: volume in use by a container
```

---

## Event Endpoints

### Subscribe to events

```
GET /v1.XX/events?since=1700000000&until=1800000000&filters={"type":["container"]}

Long-polling stream. Each event is a JSON line.
Response 200: stream of Event JSON objects
```

---

## System Endpoints

```
GET /v1.XX/info        → daemon configuration and capabilities
GET /v1.XX/version     → version information
GET /v1.XX/_ping       → liveness check (returns "OK")
GET /v1.XX/df          → disk usage by images, containers, volumes
POST /v1.XX/system/prune → remove stopped containers, unused images, volumes
```

---

## Multiplexed Streams

When a container has no TTY (`tty: false`), log/attach streams use a multiplexing protocol so stdout and stderr can be mixed on one connection.

Each "frame" in the stream has an 8-byte header:

```
Byte 0:    stream type  (0=stdin, 1=stdout, 2=stderr)
Bytes 1-3: padding (0x00)
Bytes 4-7: big-endian uint32 — payload length
Bytes 8+:  payload
```

When `tty: true`, the stream is raw bytes (no framing) because TTY merges stdout+stderr.

---

## Progress Stream Format

Image pull, push, and build all stream progress as newline-delimited JSON:

```json
{"status": "Pulling from library/ubuntu"}
{"status": "Pulling fs layer", "progressDetail": {}, "id": "abc123"}
{"status": "Downloading", "progressDetail": {"current": 1024, "total": 4096}, "progress": "[======>    ]", "id": "abc123"}
{"status": "Pull complete", "progressDetail": {}, "id": "abc123"}
{"status": "Digest: sha256:deadbeef..."}
{"status": "Status: Downloaded newer image for ubuntu:22.04"}
```

Your server should flush after each line so clients see progress in real time.
