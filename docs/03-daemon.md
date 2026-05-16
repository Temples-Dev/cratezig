# The Daemon

The Daemon is the central object of the runtime. It starts once, owns all subsystems, and implements every operation the HTTP API exposes.

---

## Daemon Structure

```
Daemon {
    id:              string          // random ID for this daemon instance

    // Subsystem references (injected at startup)
    containers:      ContainerStore
    image_service:   ImageService
    network_controller: NetworkController
    volume_service:  VolumeService
    event_service:   EventService
    runtime_client:  RuntimeClient   // containerd or equivalent
    plugin_store:    PluginStore
    registry_service: RegistryService
    build_service:   BuildService

    // Config (immutable after startup, but reloadable via SIGHUP)
    config:          DaemonConfig

    // Internal state
    start_time:      timestamp
    hostname:        string
    kernel_version:  string
}
```

---

## Daemon Configuration

Loaded from `/etc/docker/daemon.json` and CLI flags at startup. Most fields are not reloadable — they require a daemon restart.

```
DaemonConfig {
    // Storage
    data_root:         string    // "/var/lib/docker"
    storage_driver:    string    // "overlay2", "zfs", "vfs"
    storage_opts:      []string  // driver-specific options

    // Networking
    default_bridge_network:  bool    // create docker0 bridge at startup
    bridge_ip:               string  // IP for the docker0 bridge
    bip:                     string  // alias for bridge_ip
    ip_forward:              bool    // enable kernel IP forwarding
    ip_tables:               bool    // manage iptables rules
    userland_proxy:          bool    // use docker-proxy for port mapping
    dns:                     []string
    dns_search:              []string
    dns_opts:                []string

    // Security
    selinux_enabled:         bool
    userns_remap:            string  // "default" or "uid:gid"
    no_new_privileges:       bool

    // Logging
    log_driver:   string
    log_opts:     map<string, string>

    // Registry
    insecure_registries:  []string   // allow HTTP for these registries
    registry_mirrors:     []string   // mirror URLs for Docker Hub
    allow_nondistributable_artifacts: []string  // push restricted content

    // Runtime
    default_runtime:  string    // "runc"
    runtimes:         map<string, Runtime>  // named alternate runtimes
    init_binary:      string    // path to docker-init or tini

    // Labels and metadata
    labels:    []string   // "key=value" pairs attached to this daemon
    raw_logs:  bool

    // Shutdown
    shutdown_timeout: int   // seconds
}
```

### Reloadable config (SIGHUP)

These fields update without restart:
- `log_driver`, `log_opts`
- `labels`
- `registry_mirrors`, `insecure_registries`
- `allow_nondistributable_artifacts`
- `live_restore_enabled` (only takes effect on next crash)
- `max_concurrent_downloads`, `max_concurrent_uploads`

---

## Daemon Startup Sequence

The startup order matters — each step depends on the previous.

```
1. Parse config
   Load daemon.json + merge CLI flags
   Validate: data_root exists, storage_driver supported

2. System checks
   Verify kernel version meets minimums
   Check required kernel features (namespaces, cgroups, overlay)
   Check for conflicting daemons (PID file check)

3. Setup data directories
   Create {data_root}/containers/
   Create {data_root}/image/
   Create {data_root}/volumes/
   Create {data_root}/network/

4. Initialize storage driver
   Load graphdriver (overlay2 or containerd snapshotter)
   Verify it can create/delete layers

5. Initialize image service
   Connect to containerd (or start embedded one)
   Verify content store is accessible

6. Initialize volume service
   Load local volume driver
   Discover plugin drivers

7. Initialize network controller
   Create default networks: bridge (docker0), host, none
   Restore previously created user-defined networks from disk
   Apply iptables rules

8. Load existing containers
   Read {data_root}/containers/*/config.v2.json
   Reconstruct Container objects in memory
   For running containers (from previous crash), optionally reconnect (live restore)
   For stopped containers, mark as exited

9. Start event service
   Initialize in-memory ring buffer (256 events)

10. Start plugin service
    Discover and load daemon plugins

11. Start HTTP server
    Bind to unix socket and/or TCP
    Register all route handlers
    Start accepting connections

12. Write PID file
    Write daemon PID to {data_root}/docker.pid

13. Publish daemon start event
    EventService.publish(type="daemon", action="start")
```

---

## Daemon Shutdown Sequence

Triggered by SIGTERM or SIGINT.

```
1. Stop accepting new API requests
2. Wait for in-flight requests to complete (or timeout)
3. Stop running containers (if live_restore=false)
   For each running container: ContainerStop(timeout=shutdown_timeout)
4. Flush event buffer
5. Cleanup network resources (iptables rules)
6. Remove PID file
7. Exit
```

If `live_restore=true`, containers keep running after daemon exits and are reconnected on next start.

---

## Core Daemon Operations

Each HTTP route calls one of these methods on the Daemon.

### Container operations

```
ContainerCreate(ctx, config, host_config, network_config, name) → (id, warnings)
ContainerStart(ctx, id, stdin_fd, detach_keys) → error
ContainerStop(ctx, id, signal, timeout) → error
ContainerRestart(ctx, id, timeout) → error
ContainerKill(ctx, id, signal) → error
ContainerPause(ctx, id) → error
ContainerUnpause(ctx, id) → error
ContainerRemove(ctx, id, options) → error
ContainerInspect(ctx, id, size) → Container
ContainerList(ctx, options) → []ContainerSummary
ContainerLogs(ctx, id, options) → io.ReadCloser
ContainerStats(ctx, id, stream) → io.ReadCloser
ContainerAttach(ctx, id, options) → (hijacked_conn, error)
ContainerWait(ctx, id, condition) → (<-chan WaitResult, <-chan error)
ContainerExecCreate(ctx, id, config) → (exec_id, error)
ContainerExecStart(ctx, exec_id, options) → error
ContainerExecInspect(ctx, exec_id) → ExecProcess
ContainerCopyFrom(ctx, id, path) → (io.ReadCloser, error)
ContainerCopyTo(ctx, id, path, content) → error
```

### Image operations

```
ImagePull(ctx, ref, options) → io.ReadCloser  (progress stream)
ImagePush(ctx, ref, options) → io.ReadCloser  (progress stream)
ImageList(ctx, options) → []ImageSummary
ImageInspect(ctx, name) → Image
ImageRemove(ctx, name, options) → []ImageDeleteResponse
ImageTag(ctx, source, target) → error
ImageBuild(ctx, build_context, options) → (io.ReadCloser, error)
ImageSearch(ctx, term, options) → []SearchResult
ImageHistory(ctx, name) → []HistoryItem
```

### Network operations

```
NetworkCreate(ctx, name, options) → (id, warning, error)
NetworkInspect(ctx, id, options) → Network
NetworkList(ctx, options) → []Network
NetworkRemove(ctx, id) → error
NetworkConnect(ctx, network_id, container_id, endpoint_config) → error
NetworkDisconnect(ctx, network_id, container_id, force) → error
```

### Volume operations

```
VolumeCreate(ctx, options) → Volume
VolumeInspect(ctx, name) → Volume
VolumeList(ctx, filters) → ([]Volume, []string)
VolumeRemove(ctx, name, force) → error
```

### System operations

```
Info(ctx) → SystemInfo
Version(ctx) → VersionInfo
Events(ctx, options) → <-chan Event
DiskUsage(ctx) → DiskUsage
Prune(ctx, options) → PruneReport
```

---

## Container Store Interface

The ContainerStore manages Container objects in memory, with optional persistence to disk.

```
interface ContainerStore {
    Add(id, container)
    Get(id) → Container?       // by full id or unique prefix
    GetByName(name) → Container?
    Delete(id)
    List() → []Container
    Size() → int
    ApplyAll(fn: Container → void)  // iterate all
    First(filter: Container → bool) → Container?  // find by predicate
}
```

**Disk persistence**: each container's config lives at `{data_root}/containers/{id}/config.v2.json`. The store loads all these at startup and writes on every mutation.

---

## Error Handling Philosophy

- Return errors up the call stack; do not silently swallow them.
- Use typed errors where possible so HTTP handlers can pick the right status code:
  - `NotFoundError` → 404
  - `ConflictError` → 409
  - `ValidationError` → 400
  - all others → 500
- Log errors with context (operation name, container id, etc.).

---

## Concurrency

The daemon handles many concurrent API calls. The main concerns:

- **Container state mutations**: acquiring a per-container lock when changing state (start/stop/remove)
- **Container store reads**: safe for concurrent reads, lock writes
- **Config reads**: use atomic pointer or reader/writer lock; config reloads are rare
- **Event publishing**: event service is its own goroutine/thread with a channel queue

Avoid holding global locks during slow operations (network setup, process spawning). Acquire the per-container lock, do fast state transitions, release, then do slow work.
