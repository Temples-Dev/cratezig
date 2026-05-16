# Container Lifecycle

A container moves through these states:

```
                    ┌──────────┐
                    │  (none)  │
                    └────┬─────┘
                         │ ContainerCreate
                         ▼
                    ┌──────────┐
              ┌─────│ created  │─────┐
              │     └────┬─────┘     │
              │          │ Start     │ Remove
              │          ▼           │
              │     ┌──────────┐     │
    Remove    │  ┌──│ running  │──┐  │
              │  │  └────┬─────┘  │  │
              │  │ Pause │        │  │
              │  │       ▼        │ Kill/Stop
              │  │  ┌──────────┐  │  │
              │  │  │  paused  │  │  │
              │  │  └────┬─────┘  │  │
              │  │ Unpause│       │  │
              │  └────────┘       │  │
              │                   │  │
              │                   ▼  ▼
              │              ┌──────────┐
              └──────────────│  exited  │
                             └────┬─────┘
                                  │ Remove
                                  ▼
                             ┌──────────┐
                             │ (none)   │
                             └──────────┘
```

Additional transient states: `restarting` (between exited and running), `removing` (while being deleted), `dead` (removal failed).

---

## ContainerCreate

**Goal**: allocate persistent metadata and a writable filesystem layer. No process is started.

```
function ContainerCreate(config, host_config, network_config, name):

1. VALIDATE INPUT
   - Image exists: GetImage(config.image) or error
   - Name not already in use (if provided)
   - HostConfig values are sane (port bindings valid, resource limits non-negative, etc.)
   - Platform: image OS/arch matches daemon OS/arch

2. GENERATE ID
   - id = random 64-char hex string
   - name = name OR "/" + random_name()  (e.g. "/boring_einstein")

3. MERGE IMAGE CONFIG WITH USER CONFIG
   - Start with image's default config (Env, Cmd, Entrypoint, WorkingDir, etc.)
   - Override with user-provided ContainerConfig
   - Cmd: if user provided Entrypoint, use user's Entrypoint; else use image's Entrypoint
   - If Entrypoint is empty and Cmd is empty, error: no command specified

4. CREATE INIT LAYER
   - Write /etc/hostname    = container short ID
   - Write /etc/hosts       = "127.0.0.1 localhost\n::1 localhost\n"
   - Write /etc/resolv.conf = from daemon config DNS settings
   - Write /.dockerenv      = empty file
   - Create /dev/console    = device node (c 5 1)

5. CREATE WRITABLE LAYER
   - ImageService.CreateWritableLayer(id, image_id, init_layer_func)
   - This stacks: image_layers + init_layer + new_rw_layer
   - Result: {data_root}/overlay2/{id}/ exists but is NOT mounted yet

6. CREATE CONTAINER OBJECT
   container = Container {
       id:          id,
       name:        name,
       config:      merged_config,
       host_config: validated_host_config,
       image_id:    image.id,
       image_name:  config.image,
       state:       ContainerState{ status: "created" },
       created_at:  now(),
       rw_layer_id: id,
   }

7. PERSIST CONTAINER METADATA
   - Write {data_root}/containers/{id}/config.v2.json
   - Write {data_root}/containers/{id}/hostconfig.json

8. ADD TO CONTAINER STORE
   - containers.Add(id, container)

9. CONFIGURE INITIAL NETWORKING (metadata only, no kernel changes yet)
   - If network_config.endpoints_config is provided, store the endpoint configs
   - Actual network wiring happens at Start time

10. PUBLISH EVENT
    - EventService.publish(type="container", action="create", id=id, name=name, image=image_name)

11. RETURN
    - return { id: id, warnings: [] }
```

---

## ContainerStart

**Goal**: mount the filesystem, wire up networking, configure cgroups, spawn the process.

```
function ContainerStart(id, options):

1. GET CONTAINER
   container = ContainerStore.Get(id)
   if not found: error NotFound

2. VALIDATE STATE
   if container.state.running: error (already running)
   if container.state.status == "removing": error (being removed)

3. ACQUIRE CONTAINER LOCK
   (prevent concurrent start/stop/remove on same container)

4. MOUNT FILESYSTEM
   ImageService.MountRWLayer(container.rw_layer_id)
   - Mounts overlay at: {data_root}/overlay2/{id}/merged
   - Sets container.rootfs_path = that path

5. SETUP NETWORKING
   for each network in container.host_config.network_mode (or "bridge" default):
       endpoint = NetworkController.CreateEndpoint(network_name, container.id)
       container.network_settings.networks[network_name] = endpoint.settings
   
   - For "host" mode: no virtual network, container uses host's network stack
   - For "none" mode: loopback only, no external connectivity
   - For "bridge" / user-defined: creates veth pair, assigns IP (see 06-networking.md)

   Write container's /etc/hosts (add entries for linked containers, extra_hosts)
   Write container's /etc/resolv.conf (daemon DNS settings)
   Write container's /etc/hostname (container name)

6. SETUP VOLUMES AND MOUNTS
   for each mount in host_config.mounts + host_config.binds:
       if type == "volume":
           vol = VolumeService.GetOrCreate(mount.source)
           host_path = vol.mountpoint
       elif type == "bind":
           host_path = mount.source
       elif type == "tmpfs":
           create tmpfs at mount.destination in container rootfs
           continue

       verify host_path exists (or create for anonymous volumes)
       record mount so runtime can bind-mount it

7. BUILD OCI RUNTIME SPEC
   spec = generateOCISpec(container)
   - Root: { path: container.rootfs_path, readonly: host_config.read_only_rootfs }
   - Process: { cmd, env, cwd, user, capabilities, rlimits, terminal }
   - Namespaces: pid, mount, uts, ipc, network (optionally user)
   - Mounts: proc, sysfs, devtmpfs, bind mounts, volume mounts
   - Linux: cgroups (memory, cpu, pids, blkio), seccomp profile, apparmor
   - Hooks: prestart (network setup), poststart, poststop

8. START LOGGING
   logger = LogDriverFactory.Create(container.log_driver, container.log_opts)
   container.log_driver_instance = logger

9. SPAWN PROCESS VIA RUNTIME CLIENT
   task_id = RuntimeClient.CreateTask(container.id, spec, io_config)
   RuntimeClient.StartTask(task_id)
   
   io_config: pipes/FIFOs for stdin/stdout/stderr
   RuntimeClient returns PID of container's init process

10. UPDATE STATE
    container.state.running    = true
    container.state.pid        = <returned PID>
    container.state.started_at = now()
    container.state.status     = "running"
    Persist state to disk

11. START LOG COPIER
    goroutine/thread: read from stdout/stderr pipes → write to logger

12. START EXIT MONITOR
    goroutine/thread: wait for RuntimeClient exit notification
    When exit fires:
        container.state.running    = false
        container.state.exit_code  = <exit code>
        container.state.finished_at = now()
        container.state.status     = "exited"
        Persist state
        Unmount filesystem
        Release network endpoints
        EventService.publish(type="container", action="die", exit_code=N, ...)

13. RELEASE LOCK

14. PUBLISH EVENT
    EventService.publish(type="container", action="start", id=id, ...)
```

---

## ContainerStop

```
function ContainerStop(id, signal, timeout_seconds):

1. GET AND VALIDATE
   container = ContainerStore.Get(id)
   if not running: return (no-op)
   timeout = timeout_seconds ?? container.config.stop_timeout ?? 10

2. SEND GRACEFUL SIGNAL
   sig = signal ?? container.config.stop_signal ?? SIGTERM
   RuntimeClient.Kill(container.id, sig)
   EventService.publish(action="kill", signal=sig, ...)

3. WAIT FOR EXIT (with timeout)
   wait for container.state.running == false, up to timeout seconds

4. FORCE KILL IF NEEDED
   if still running after timeout:
       RuntimeClient.Kill(container.id, SIGKILL)
       wait again (shorter timeout, e.g. 2 seconds)

5. CLEANUP (done by the exit monitor goroutine from Start)
   - Unmount filesystem
   - Release IP addresses
   - Remove network endpoints

6. PUBLISH EVENT
   EventService.publish(type="container", action="stop", id=id, ...)
```

---

## ContainerRemove

```
function ContainerRemove(id, options):
   force:          kill running container before removing
   remove_volumes: also remove anonymous volumes created by this container

1. GET CONTAINER
   container = ContainerStore.Get(id)

2. CHECK STATE
   if container.state.status == "removing": error (already being removed)
   if container.state.running:
       if not options.force: error (cannot remove running container)
       else: ContainerStop(id, SIGKILL, 0)
   if container.state.status == "paused":
       if not options.force: error
       else: ContainerUnpause(id), ContainerStop(id, SIGKILL, 0)

3. MARK AS REMOVING
   container.state.status = "removing"
   Persist

4. RELEASE REMAINING RESOURCES
   if filesystem is mounted: unmount {rootfs_path}

5. REMOVE ANONYMOUS VOLUMES
   if options.remove_volumes:
       for each mount where mount.name was auto-generated:
           VolumeService.Remove(mount.name)

6. DELETE FILES ON DISK
   Delete {data_root}/containers/{id}/   (config, logs, etc.)
   Delete {data_root}/overlay2/{id}/     (writable layer + merged)

7. REMOVE FROM CONTAINER STORE
   ContainerStore.Delete(id)

8. PUBLISH EVENT
   EventService.publish(type="container", action="destroy", id=id, ...)
```

---

## ContainerPause / Unpause

Pause uses cgroup freezer or SIGSTOP to suspend all processes in the container without killing them.

```
function ContainerPause(id):
    RuntimeClient.Pause(container.id)
    container.state.paused = true
    container.state.status = "paused"
    EventService.publish(action="pause", ...)

function ContainerUnpause(id):
    RuntimeClient.Unpause(container.id)
    container.state.paused = false
    container.state.status = "running"
    EventService.publish(action="unpause", ...)
```

---

## Restart Policy

The exit monitor checks the restart policy after each container exit.

```
on container exit:
    policy = container.host_config.restart_policy

    if policy.name == "no":
        done

    if policy.name == "on-failure" and exit_code == 0:
        done

    if policy.name == "on-failure":
        restart_count++
        if policy.maximum_retry_count > 0 and restart_count > max:
            done

    // Wait with exponential backoff (100ms, 200ms, 400ms, ... max 1 minute)
    wait = min(100ms * 2^restart_count, 60s)
    sleep(wait)

    container.state.status = "restarting"
    ContainerStart(id)
```

---

## Exec

`docker exec` runs an additional process inside an already-running container's namespace.

```
function ExecCreate(container_id, exec_config):
    container = ContainerStore.Get(container_id)
    if not container.state.running: error

    exec_id = random_id()
    exec_process = ExecProcess {
        id:           exec_id,
        container_id: container_id,
        process_config: exec_config,
        running:      false,
    }
    container.exec_commands[exec_id] = exec_process
    return exec_id

function ExecStart(exec_id, options):
    ep = find_exec(exec_id)
    container = ContainerStore.Get(ep.container_id)

    if not container.state.running: error
    
    // Join the existing container namespace (by PID or by task ID)
    RuntimeClient.RunExecInContainer(container.id, ep.process_config, io_config)
    ep.pid     = <returned pid>
    ep.running = true

    // Wait for process to exit
    // Update ep.exit_code, ep.running = false
```

---

## Container Logs

Logs are captured from stdout/stderr of the container's process and stored by the log driver.

For the default `json-file` driver:
- Each log line is written as a JSON object: `{"log":"output\n","stream":"stdout","time":"2024-01-01T00:00:00Z"}`
- Stored at `{data_root}/containers/{id}/{id}-json.log`
- Rotated based on `max-size` and `max-file` log options

When a client calls `GET /containers/{id}/logs`:
1. Open the log file
2. If `follow=false`: read and send all matching lines, then close
3. If `follow=true`: read existing lines, then tail (inotify/kqueue) for new writes
4. Apply filters: `since`, `until`, `tail` (last N lines)
5. Frame output in multiplexed stream format (see API doc)

---

## Container Stats

Stats are collected by reading from cgroup pseudo-files and `/proc`:

| Metric | Source |
|--------|--------|
| Memory usage | `/sys/fs/cgroup/memory/docker/{id}/memory.usage_in_bytes` |
| Memory limit | `/sys/fs/cgroup/memory/docker/{id}/memory.limit_in_bytes` |
| CPU usage | `/sys/fs/cgroup/cpuacct/docker/{id}/cpuacct.usage` |
| System CPU | `/proc/stat` |
| Network I/O | `/sys/class/net/{interface}/statistics/rx_bytes` etc. |
| Block I/O | `/sys/fs/cgroup/blkio/docker/{id}/blkio.throttle.io_service_bytes` |
| PIDs | `/sys/fs/cgroup/pids/docker/{id}/pids.current` |

For cgroups v2 (`/sys/fs/cgroup/system.slice/docker-{id}.scope/`), file paths differ but concepts are the same.
