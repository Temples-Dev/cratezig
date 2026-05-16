# Runtime Interface

The runtime layer is the bridge between your daemon and the actual Linux kernel primitives (namespaces, cgroups, capabilities). You never call `clone()` or `unshare()` directly — instead you generate an OCI runtime spec and hand it to a compliant runtime (`runc`, `crun`, or `containerd`).

---

## The Stack

```
Your Daemon
    ↓  OCI Runtime Spec (JSON)
containerd  (optional mid-layer, manages task lifecycle + snapshots)
    ↓  OCI Runtime Bundle
runc / crun  (low-level runtime, talks to Linux kernel)
    ↓
Linux: namespaces, cgroups, seccomp, capabilities, mount
```

You have two integration options:

| Option | Complexity | What you manage |
|--------|-----------|-----------------|
| Direct runc | Low | Everything except the final fork |
| Via containerd | Medium | Higher-level task API, snapshots built in |

For learning, **direct runc** is simpler. For production, **containerd** is the right choice because it handles crash recovery, image storage, and task monitoring.

---

## OCI Runtime Spec

The spec is a JSON file (`config.json`) placed in a bundle directory alongside the rootfs. `runc` reads it and creates the container.

### Minimal spec structure

```json
{
    "ociVersion": "1.1.0",
    "process": {
        "terminal": false,
        "user": { "uid": 0, "gid": 0 },
        "args": ["/bin/sh"],
        "env": [
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM=xterm"
        ],
        "cwd": "/",
        "capabilities": {
            "bounding":  ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
            "effective": ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
            "permitted": ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
            "ambient":   []
        },
        "rlimits": [
            { "type": "RLIMIT_NOFILE", "hard": 1048576, "soft": 1048576 }
        ],
        "noNewPrivileges": true
    },
    "root": {
        "path": "rootfs",
        "readonly": false
    },
    "hostname": "mycontainer",
    "mounts": [
        { "destination": "/proc",  "type": "proc",  "source": "proc", "options": ["nosuid","noexec","nodev"] },
        { "destination": "/dev",   "type": "tmpfs", "source": "tmpfs", "options": ["nosuid","strictatime","mode=755","size=65536k"] },
        { "destination": "/dev/pts",  "type": "devpts", "source": "devpts", "options": ["nosuid","noexec","newinstance","ptmxmode=0666","mode=0620","gid=5"] },
        { "destination": "/dev/mqueue", "type": "mqueue", "source": "mqueue", "options": ["nosuid","noexec","nodev"] },
        { "destination": "/sys",   "type": "sysfs", "source": "sysfs",  "options": ["nosuid","noexec","nodev","ro"] },
        { "destination": "/sys/fs/cgroup", "type": "cgroup", "source": "cgroup", "options": ["nosuid","noexec","nodev","relatime","ro"] }
    ],
    "linux": {
        "namespaces": [
            { "type": "pid" },
            { "type": "network", "path": "/var/run/docker/netns/abc123" },
            { "type": "ipc" },
            { "type": "uts" },
            { "type": "mount" }
        ],
        "resources": {
            "memory": { "limit": 134217728, "reservation": 0, "swap": -1 },
            "cpu": { "shares": 1024, "quota": -1, "period": 100000 },
            "pids": { "limit": 1024 },
            "blockIO": { "weight": 500 }
        },
        "cgroupsPath": "/docker/abc123",
        "maskedPaths": [
            "/proc/acpi", "/proc/kcore", "/proc/keys", "/proc/latency_stats",
            "/proc/timer_list", "/proc/timer_stats", "/proc/sched_debug",
            "/proc/scsi", "/sys/firmware"
        ],
        "readonlyPaths": [
            "/proc/asound", "/proc/bus", "/proc/fs", "/proc/irq",
            "/proc/sys", "/proc/sysrq-trigger"
        ],
        "seccomp": { ... },
        "appArmorProfile": "docker-default"
    }
}
```

---

## Spec Generation: Translating ContainerConfig → OCI Spec

```
function generateOCISpec(container):

spec = new OCI spec

// Process
spec.process.args = merge_entrypoint_cmd(container.config.entrypoint, container.config.cmd)
spec.process.env  = merge_env(image_default_env, container.config.env)
spec.process.cwd  = container.config.working_dir OR "/"
spec.process.terminal = container.config.tty

// User
if container.config.user != "":
    uid, gid = resolve_user(container.config.user, container.rootfs_path + "/etc/passwd")
spec.process.user = { uid: uid, gid: gid }

// Capabilities
if container.host_config.privileged:
    spec.process.capabilities = ALL_CAPABILITIES
else:
    base_caps = DEFAULT_CAPS  // see table below
    spec.process.capabilities = base_caps + host_config.cap_add - host_config.cap_drop

// Root filesystem
spec.root.path     = container.rootfs_path
spec.root.readonly = container.host_config.read_only_rootfs

// Hostname
spec.hostname = short_id(container.id)  // first 12 chars

// Mounts (in addition to standard /proc, /dev, /sys):
for each bind_mount in container.host_config.binds:
    spec.mounts.append({
        destination: container_path,
        type: "bind",
        source: host_path,
        options: ["rbind", rw_or_ro, propagation_flags...]
    })

for each volume_mount in container.host_config.mounts:
    host_path = VolumeService.Mount(volume_name, container.id)
    spec.mounts.append({ destination: ..., type: "bind", source: host_path, ... })

// Namespaces
spec.linux.namespaces = [pid, ipc, uts, mount]
if network_mode == "bridge" or user-defined:
    spec.linux.namespaces.append({ type: "network", path: sandbox.netns_path })
elif network_mode == "host":
    // do NOT add network namespace → inherits host's
elif network_mode == "container:{id}":
    other = ContainerStore.Get(id)
    spec.linux.namespaces.append({ type: "network", path: other.sandbox.netns_path })

if host_config.ipc_mode == "host": omit ipc namespace
if host_config.pid_mode == "host": omit pid namespace

// Resources (cgroups)
spec.linux.resources.memory.limit       = host_config.memory
spec.linux.resources.memory.swap        = host_config.memory_swap
spec.linux.resources.cpu.shares         = host_config.cpu_shares
spec.linux.resources.cpu.quota          = host_config.cpu_quota
spec.linux.resources.cpu.period         = host_config.cpu_period
spec.linux.resources.pids.limit         = host_config.pids_limit

// Sysctl
spec.linux.sysctl = host_config.sysctls

// Seccomp (if not privileged)
if not privileged:
    spec.linux.seccomp = default_seccomp_profile()

// Apparmor
spec.linux.appArmorProfile = "docker-default"  // unless overridden

// Hooks
spec.hooks.prestart  = [network_setup_hook]    // sets up veth, if using prestart
spec.hooks.poststart = []
spec.hooks.poststop  = [network_teardown_hook]

return spec
```

### Default capabilities

```
DEFAULT_CAPS = [
    CAP_CHOWN, CAP_DAC_OVERRIDE, CAP_FSETID, CAP_FOWNER,
    CAP_MKNOD, CAP_NET_RAW, CAP_SETGID, CAP_SETUID,
    CAP_SETFCAP, CAP_SETPCAP, CAP_NET_BIND_SERVICE,
    CAP_SYS_CHROOT, CAP_KILL, CAP_AUDIT_WRITE
]
```

---

## Direct runc Integration

runc communicates via a bundle directory and a Unix socket for state queries.

### Creating and starting a container

```
bundle_dir = /run/runc/{container_id}/
mkdir bundle_dir
write bundle_dir/config.json  (the OCI spec)
symlink or bind-mount the rootfs to bundle_dir/rootfs

# Start the container (foreground, waits for it to finish)
runc run --bundle {bundle_dir} {container_id}

# OR, start detached:
runc create --bundle {bundle_dir} {container_id}
runc start {container_id}
# runc start returns immediately; container runs in background

# Get container state / PID
runc state {container_id}
→ { "id": "...", "pid": 12345, "status": "running", "bundle": "..." }

# Kill
runc kill {container_id} SIGTERM
runc kill {container_id} SIGKILL

# Delete (after container exits)
runc delete {container_id}
```

### Exec in running container

```
# Write exec process spec to a JSON file
write /tmp/process.json: {
    "args": ["/bin/sh"],
    "env": [...],
    "user": {"uid": 0, "gid": 0},
    "terminal": false
}

runc exec --process /tmp/process.json {container_id}
```

### Monitoring exit

After `runc start`, poll `runc state {container_id}` or use `runc events` to receive a stream of JSON events including the exit event. Alternatively, wait on the PID directly using `waitpid()`.

---

## containerd Integration

When using containerd as a mid-layer, you talk gRPC to the containerd daemon.

### Key concepts

```
Content Store   — immutable blobs (layer tarballs, image configs, manifests)
Snapshotter     — manages overlay layers (equivalent to graphdriver)
Image Store     — maps names to manifest digests
Container       — metadata record (spec, snapshots, labels)
Task            — a running process (created from a Container)
```

### Workflow

```
1. Pull image into content store
   containerd.Pull(ctx, "ubuntu:22.04", options)

2. Prepare snapshot (rootfs)
   snapshotter.Prepare(ctx, container_id, parent_snapshot_key)
   → returns mount info (overlay lowerdir/upperdir/workdir)

3. Create container record
   containerd.NewContainer(ctx, container_id, {
       spec:     oci_spec,
       snapshot: container_id,
       image:    "ubuntu:22.04",
   })

4. Create and start task
   task = container.NewTask(ctx, cio.NewCreator(cio.WithStdio))
   task.Start(ctx)
   → returns task with PID

5. Wait for exit
   exit_status_chan = task.Wait(ctx)
   exit_status = <-exit_status_chan

6. Cleanup
   task.Delete(ctx)
   container.Delete(ctx)
   snapshotter.Remove(ctx, container_id)
```

### Snapshot chain for a container

```
// Image layers (already exist after pull):
snapshotter.Prepare("sha256:layer1", "")
snapshotter.Commit("sha256:layer1", "sha256:layer1-snap")

snapshotter.Prepare("sha256:layer2", "sha256:layer1-snap")
snapshotter.Commit("sha256:layer2", "sha256:layer2-snap")

// Container writable layer (new for each container):
snapshotter.Prepare("{container-id}", "sha256:layer2-snap")
// (no Commit — this stays as an active, writable snapshot)

// Get mount info:
mounts = snapshotter.Mounts(ctx, "{container-id}")
// → [{type:"overlay", source:"overlay", options:["lowerdir=...", "upperdir=...", "workdir=..."]}]
```

---

## Seccomp Profile

Seccomp (Secure Computing mode) restricts which syscalls a container can make. The default Docker seccomp profile blocks ~44 syscalls out of ~300+.

Key blocked syscalls in the default profile:
- `reboot`, `kexec_load` — prevent host reboots
- `mount` (unless privileged) — prevent arbitrary mounts
- `clone` with `CLONE_NEWUSER` — prevent privilege escalation via user namespaces
- `ptrace` — block debugging other processes (unless `CAP_SYS_PTRACE` added)
- `acct`, `swapon`, `swapoff` — system administration
- Kernel module loading (`init_module`, `finit_module`)

The seccomp profile is a JSON file in the OCI spec format. For a simple implementation, you can start with the default Docker seccomp profile (publicly available) or omit seccomp entirely (less secure but simpler).

---

## cgroups

Cgroups enforce resource limits. Two versions exist:

### cgroups v1 (legacy)

Multiple hierarchies, each at a separate path:
```
/sys/fs/cgroup/memory/docker/{container-id}/
    memory.limit_in_bytes          → write limit here
    memory.usage_in_bytes          → read current usage

/sys/fs/cgroup/cpu,cpuacct/docker/{container-id}/
    cpu.shares                     → relative CPU weight
    cpu.cfs_quota_us               → quota (with period = 100000us, quota=50000 → 50% of 1 CPU)

/sys/fs/cgroup/pids/docker/{container-id}/
    pids.max                       → max processes

/sys/fs/cgroup/blkio/docker/{container-id}/
    blkio.weight                   → I/O weight
```

To create a cgroup: `mkdir /sys/fs/cgroup/memory/docker/{id}/`
To apply: write values to the pseudo-files
To add a process: write PID to `cgroup.procs`
To delete: `rmdir` the directory (after all processes leave)

### cgroups v2 (unified)

All controllers at a single path:
```
/sys/fs/cgroup/system.slice/docker-{container-id}.scope/
    memory.max                     → limit
    memory.current                 → current usage
    cpu.weight                     → relative CPU weight
    cpu.max                        → "quota period" e.g. "50000 100000"
    pids.max
```

Detection: if `/sys/fs/cgroup/cgroup.controllers` exists, you're on v2.

runc handles cgroup setup automatically from the spec's `resources` section — you just need to provide the values.

---

## User Namespace Remapping

When user namespace remapping is enabled (`--userns-remap`), UID 0 inside the container maps to an unprivileged UID on the host.

```
/etc/subuid: dockremap:100000:65536
/etc/subgid: dockremap:100000:65536
```

This means UID 0 in the container = UID 100000 on the host. A process cannot escape the container and gain host root privileges.

In the OCI spec:
```json
"linux": {
    "uidMappings": [
        { "containerID": 0, "hostID": 100000, "size": 65536 }
    ],
    "gidMappings": [
        { "containerID": 0, "hostID": 100000, "size": 65536 }
    ]
}
```

---

## Init Process (tini)

When `host_config.init = true`, the container's PID 1 is a tiny init process (`tini` or `docker-init`) that:
- Reaps zombie processes (orphaned child processes that exit)
- Forwards signals to the main process

Without an init, if PID 1 doesn't handle signals or reap zombies, containers can accumulate zombie processes.

Implementation: prepend `["/sbin/docker-init", "--"]` to the container's `args` in the OCI spec.
