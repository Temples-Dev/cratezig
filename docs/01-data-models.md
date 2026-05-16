# Data Models

These are the core data structures your runtime needs. Field names are descriptive — use idiomatic names for your language.

---

## Container

A container has two kinds of data: **config** (what the user asked for) and **state** (what's actually happening at runtime).

```
Container {
    // Identity
    id:          string        // 64-char hex, generated at create time
    name:        string        // human-readable, e.g. "/myapp"
    created_at:  timestamp

    // What to run (user-provided at create time, never mutated)
    config: ContainerConfig

    // How to run it (resource limits, mounts, networking — also immutable after create)
    host_config: HostConfig

    // Current lifecycle state (mutable, in-memory + persisted)
    state: ContainerState

    // Image
    image_id:   string        // content-addressable digest of the image
    image_name: string        // "ubuntu:22.04" or similar

    // Filesystem
    rootfs_path: string       // absolute path to mounted overlay rootfs
    rw_layer_id: string       // identifier of the writable overlay layer

    // Networking (populated at Start time)
    network_settings: NetworkSettings

    // Logging
    log_path:   string        // path to log file (for json-file driver)
    log_driver: string        // "json-file", "syslog", etc.

    // Exec processes (docker exec)
    exec_commands: map<string, ExecProcess>
}
```

### ContainerConfig

What runs inside the container.

```
ContainerConfig {
    image:        string        // image name or digest
    cmd:          []string      // command to run, e.g. ["/bin/sh", "-c", "echo hello"]
    entrypoint:   []string      // overrides image ENTRYPOINT
    env:          []string      // ["KEY=value", ...]
    working_dir:  string        // working directory inside container
    user:         string        // "uid:gid" or username
    exposed_ports: map<string, struct{}>  // {"80/tcp": {}, "443/tcp": {}}
    volumes:      map<string, struct{}>   // {":/data": {}}  (anonymous volume declarations)
    labels:       map<string, string>
    stop_signal:  string        // default "SIGTERM"
    stop_timeout: int           // seconds before SIGKILL, default 10
    tty:          bool          // allocate a pseudo-TTY
    open_stdin:   bool          // keep stdin open
    attach_stdin: bool
    attach_stdout: bool
    attach_stderr: bool
    healthcheck:  HealthCheckConfig  // optional
    on_build:     []string       // for image builds only
    shell:        []string       // override default shell
}
```

### HostConfig

How the host exposes resources to the container.

```
HostConfig {
    // Resource limits
    memory:         int64    // bytes, 0 = unlimited
    memory_swap:    int64    // total memory+swap, -1 = unlimited
    cpu_shares:     int64    // relative weight
    cpu_period:     int64    // microseconds
    cpu_quota:      int64    // microseconds per cpu_period
    cpuset_cpus:    string   // "0-3" or "0,1"
    pids_limit:     int64    // 0 = unlimited

    // Port mapping
    port_bindings:  map<string, []PortBinding>
    // key: "80/tcp", value: [{host_ip: "0.0.0.0", host_port: "8080"}]
    publish_all_ports: bool  // auto-assign host ports for all exposed ports

    // Mounts
    binds:    []string       // ["/host/path:/container/path:ro", ...]
    mounts:   []MountPoint   // structured mount definitions
    volumes_from: []string   // copy mounts from another container

    // Networking
    network_mode:  string    // "bridge", "host", "none", "container:<id>"
    dns:           []string
    dns_options:   []string
    dns_search:    []string
    extra_hosts:   []string  // ["hostname:ip"]
    links:         []string  // legacy container links (deprecated)

    // Security
    privileged:    bool
    cap_add:       []string  // ["NET_ADMIN", "SYS_PTRACE"]
    cap_drop:      []string
    security_opt:  []string  // ["no-new-privileges", "seccomp=..."]
    read_only_rootfs: bool
    userns_mode:   string    // "host" to disable user namespace remapping

    // Runtime
    runtime:       string    // "runc", "kata-containers", etc.
    shm_size:      int64     // /dev/shm size in bytes
    sysctls:       map<string, string>  // {"net.ipv4.ip_forward": "1"}
    ulimits:       []Ulimit
    log_config:    LogConfig
    restart_policy: RestartPolicy

    // Init
    init:          bool      // run an init process (tini) as PID 1
    ipc_mode:      string    // "private", "host", "shareable", "container:<id>"
    pid_mode:      string    // "host"
    uts_mode:      string    // "host"
    isolation:     string    // Linux: "default", Windows: "process"/"hyperv"
    devices:       []DeviceMapping   // host devices to expose
    cgroup_parent: string    // place container in specific cgroup hierarchy
}
```

### ContainerState

Runtime state, updated as the container progresses through its lifecycle.

```
ContainerState {
    // Status string (one of the values below)
    status:     string
    // "created" | "running" | "paused" | "restarting" | "removing" | "exited" | "dead"

    running:    bool
    paused:     bool
    restarting: bool
    oom_killed: bool    // true if killed because it exceeded memory limit
    dead:       bool

    pid:        int     // host PID of the container's init process (0 if not running)
    exit_code:  int     // last exit code
    error:      string  // last error message from the runtime

    started_at:  timestamp
    finished_at: timestamp

    // Health check state (if configured)
    health: HealthState
}
```

### NetworkSettings

Populated when the container is started and attached to networks.

```
NetworkSettings {
    ip_address:    string   // deprecated, primary IPv4 address
    ip_prefix_len: int
    gateway:       string
    mac_address:   string
    ports:         map<string, []PortBinding>  // actual port mappings
    networks:      map<string, EndpointSettings>  // network name → endpoint details
}

EndpointSettings {
    network_id:    string
    endpoint_id:   string
    gateway:       string
    ip_address:    string
    ip_prefix_len: int
    ipv6_gateway:  string
    global_ipv6:   string
    mac_address:   string
    aliases:       []string  // DNS names for this container on this network
}
```

---

## Image

```
Image {
    id:           string        // content-addressable digest (sha256:...)
    repo_tags:    []string      // ["ubuntu:22.04", "ubuntu:latest"]
    repo_digests: []string      // ["ubuntu@sha256:abc123..."]
    created:      timestamp
    author:       string
    architecture: string        // "amd64", "arm64"
    os:           string        // "linux", "windows"
    size:         int64         // total uncompressed size in bytes
    virtual_size: int64         // size including shared layers
    parent:       string        // parent image digest (for legacy builder)

    config: ImageConfig         // same as ContainerConfig for default values
    rootfs: RootFS              // layer chain
    metadata: ImageMetadata
}

ImageConfig {
    // Same fields as ContainerConfig, but these are defaults
    // that are merged with user-provided ContainerConfig at container create time
    cmd, entrypoint, env, working_dir, user, exposed_ports, volumes, labels, ...
}

RootFS {
    type:   string       // "layers"
    layers: []string     // ordered list of layer digests, bottom to top
}
```

---

## Layer

A layer is a compressed tar archive of filesystem changes.

```
Layer {
    id:            string   // content-addressable digest of compressed tar
    diff_id:       string   // digest of uncompressed tar (used in image manifests)
    size:          int64    // compressed size
    uncompressed_size: int64
    parent_id:     string   // parent layer digest (empty for base layer)
    path:          string   // local path to extracted layer directory (for overlay2 lower dirs)
}
```

---

## Network

```
Network {
    id:          string
    name:        string
    driver:      string    // "bridge", "overlay", "host", "macvlan", "ipvlan", "none"
    created:     timestamp
    scope:       string    // "local", "swarm", "global"
    internal:    bool      // no external connectivity
    attachable:  bool      // standalone containers can attach
    ingress:     bool      // swarm load balancer network
    enable_ipv6: bool

    ipam: IPAMConfig

    options:     map<string, string>  // driver-specific
    labels:      map<string, string>

    // Runtime state
    containers:  map<string, NetworkContainerInfo>  // which containers are attached
}

IPAMConfig {
    driver:  string   // "default" (built-in) or custom IPAM driver
    options: map<string, string>
    configs: []IPAMPoolConfig
}

IPAMPoolConfig {
    subnet:      string   // CIDR, e.g. "172.17.0.0/16"
    ip_range:    string   // sub-range within subnet, e.g. "172.17.0.0/24"
    gateway:     string   // e.g. "172.17.0.1"
    aux_address: map<string, string>  // reserved addresses {"host": "172.17.0.100"}
}
```

---

## Volume

```
Volume {
    name:       string
    driver:     string    // "local" or plugin name
    mountpoint: string    // absolute path on host
    created:    timestamp
    labels:     map<string, string>
    options:    map<string, string>  // driver-specific options
    scope:      string    // "local" or "global"
    status:     map<string, interface{}>  // driver-reported status
}
```

---

## MountPoint

Used in both HostConfig.binds and in the container inspect response.

```
MountPoint {
    type:        string   // "bind", "volume", "tmpfs", "npipe"
    source:      string   // host path (for bind) or volume name (for volume)
    destination: string   // path inside container
    mode:        string   // "ro", "rw", "z", "Z", "shared", etc.
    rw:          bool
    propagation: string   // "private", "rprivate", "shared", "rshared", "slave", "rslave"
    name:        string   // volume name (for volume mounts)
    driver:      string   // volume driver (for volume mounts)
}
```

---

## Event

```
Event {
    type:     string    // "container", "image", "network", "volume", "daemon", "plugin", "node", "service", "secret", "config"
    action:   string    // "create", "start", "stop", "die", "destroy", "pull", "push", etc.
    actor: EventActor
    time:     int64     // Unix timestamp seconds
    time_nano: int64    // Unix timestamp nanoseconds
}

EventActor {
    id:         string              // container id, image id, network id, etc.
    attributes: map<string, string>  // extra context: image name, container name, exit code, etc.
}
```

---

## PortBinding

```
PortBinding {
    host_ip:   string   // IP to bind on host, e.g. "0.0.0.0" or "127.0.0.1"
    host_port: string   // host port number as string, e.g. "8080"
}
```

---

## LogConfig

```
LogConfig {
    type:   string              // "json-file", "syslog", "journald", "awslogs", etc.
    config: map<string, string> // driver-specific options
}
```

---

## RestartPolicy

```
RestartPolicy {
    name:               string  // "no", "always", "on-failure", "unless-stopped"
    maximum_retry_count: int
}
```

---

## ExecProcess

Represents a `docker exec` session.

```
ExecProcess {
    id:          string
    running:     bool
    exit_code:   int
    pid:         int
    open_stdin:  bool
    open_stdout: bool
    open_stderr: bool
    attach_stdin: bool
    tty:         bool
    process_config: ExecProcessConfig
    container_id: string
}

ExecProcessConfig {
    entrypoint: string
    arguments:  []string
    tty:        bool
    privileged: bool
    user:       string
}
```
