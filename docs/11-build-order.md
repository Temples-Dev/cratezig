# Implementation Build Order

A suggested sequence for building your own container runtime from scratch. Each phase produces something runnable.

---

## Phase 0 — Prerequisites

Before writing runtime code, understand these Linux concepts:

| Concept | What to learn |
|---------|---------------|
| Linux namespaces | `man clone`, `man unshare`, `man setns` — pid, net, mnt, uts, ipc, user |
| Cgroups v1/v2 | How to create cgroup dirs, write resource limits, add PIDs |
| Overlay filesystem | How `lowerdir/upperdir/workdir/merged` works, try `mount -t overlay` manually |
| `veth` pairs | `ip link add veth0 type veth peer name veth1`, `ip link set veth1 netns <pid>` |
| iptables | NAT, MASQUERADE, DNAT, FORWARD chain basics |
| OCI runtime spec | Read the spec at https://github.com/opencontainers/runtime-spec |
| OCI image spec | Read the spec at https://github.com/opencontainers/image-spec |
| OCI distribution spec | Registry HTTP API at https://github.com/opencontainers/distribution-spec |

---

## Phase 1 — Run a single container manually

Goal: understand the raw primitives before abstracting them.

```
Steps:
1. Pull ubuntu:22.04 manually using curl against the registry API
   - Authenticate, fetch manifest, fetch config, fetch each layer blob
   
2. Extract layers into a directory to form a rootfs
   - Stack them: base layer first, apply diffs on top

3. Write a minimal OCI config.json by hand

4. Install runc: apt install runc  (or build from source)

5. Run it:
   mkdir /tmp/bundle
   cp config.json /tmp/bundle/
   mkdir /tmp/bundle/rootfs
   # extract layers into rootfs
   runc run --bundle /tmp/bundle mytest
```

You now have a running container without any daemon.

---

## Phase 2 — Image Puller

Build a library that can:
- Parse image references (`ubuntu:22.04`, `registry.example.com/app:v1`)
- Authenticate against Docker Hub and private registries (Bearer token flow)
- Fetch the manifest index → select right platform → fetch manifest
- Fetch the image config
- Download layer blobs in parallel
- Verify digests
- Extract layers to disk, handling whiteouts
- Build a chain-id-indexed layer store

**Test**: `pull("ubuntu:22.04")` results in a directory with a working rootfs.

---

## Phase 3 — OCI Spec Generator

Build a function:
```
generateSpec(container_config, host_config, rootfs_path, netns_path) → OCI spec JSON
```

- Merge image defaults with user config
- Handle capabilities, user, env, working_dir
- Add standard mounts (proc, dev, sys, devpts, cgroup)
- Add bind mounts and volume mounts
- Set namespace entries (pid, ipc, uts, mount, network)
- Set cgroup resource limits

**Test**: generate a spec and run it with `runc run`.

---

## Phase 4 — Container Metadata Store

Build the persistent metadata layer:
- `Container` struct (see `01-data-models.md`)
- Read/write `config.v2.json` and `hostconfig.json` to disk
- In-memory store with Get/Add/Delete/List
- Load all containers from disk on startup

**Test**: create a container, kill the process, restart it, verify the container is still listed.

---

## Phase 5 — HTTP API Server

Build the HTTP server with these endpoints first (the minimum needed):

```
POST   /vX.XX/containers/create
POST   /vX.XX/containers/{id}/start
POST   /vX.XX/containers/{id}/stop
DELETE /vX.XX/containers/{id}
GET    /vX.XX/containers/{id}/json
GET    /vX.XX/containers/json
GET    /vX.XX/version
GET    /vX.XX/_ping
```

Wire each route to call your Daemon methods.

**Test**: use the official Docker CLI against your server:
```sh
DOCKER_HOST=unix:///tmp/myruntime.sock docker ps
DOCKER_HOST=unix:///tmp/myruntime.sock docker run ubuntu echo hello
```

---

## Phase 6 — Runtime Client (runc wrapper)

Build the glue between the Daemon and runc:

```
RuntimeClient {
    CreateTask(container_id, spec, io_config) → error
    StartTask(container_id) → (pid, error)
    Kill(container_id, signal) → error
    Wait(container_id) → <-chan ExitStatus
    Delete(container_id) → error
    Pause(container_id) → error
    Resume(container_id) → error
}
```

Implementation: shell out to `runc` binary (simplest), or use `runc` as a library (advanced).

**Test**: ContainerCreate + ContainerStart runs a process, ContainerStop kills it.

---

## Phase 7 — Exit Monitoring and Restart Policy

- Background goroutine per container watching for process exit
- On exit: update state, unmount overlay, publish event
- Restart policy: `no`, `always`, `on-failure`, `unless-stopped`
- Exponential backoff before restart

**Test**: `docker run --restart=always ubuntu sleep 1` — container restarts automatically.

---

## Phase 8 — Basic Networking (bridge + veth)

1. On daemon start: create `docker0` bridge, assign `172.17.0.1/16`
2. Enable IP forwarding: write `1` to `/proc/sys/net/ipv4/ip_forward`
3. Add iptables MASQUERADE rule for the subnet
4. On ContainerStart:
   - Allocate IP from pool
   - Create veth pair
   - Attach host end to bridge
   - Move container end into container's netns
   - Configure IP/route inside container netns
5. On ContainerStop: remove veth, release IP

**Test**: `docker run ubuntu ping 8.8.8.8` works.

---

## Phase 9 — Port Publishing

On ContainerStart, for each port binding in `host_config.port_bindings`:
- Add iptables DNAT rule: `host_port` → `container_ip:container_port`

On ContainerStop: remove those rules.

**Test**: `docker run -p 8080:80 nginx` → `curl http://localhost:8080` works.

---

## Phase 10 — Volumes

1. `local` volume driver: creates `{data_root}/volumes/{name}/_data/`
2. VolumeCreate, VolumeList, VolumeInspect, VolumeRemove API endpoints
3. On ContainerStart: resolve volume mounts to host paths, pass as bind mounts in OCI spec
4. Track reference counts (refuse removal if in use)

**Test**: `docker volume create mydata` → `docker run -v mydata:/data ubuntu touch /data/hello` → `docker run -v mydata:/data ubuntu ls /data` shows `hello`.

---

## Phase 11 — Event Service

1. In-memory ring buffer (256 events)
2. Pub/sub with filter support
3. Emit events from: ContainerCreate, ContainerStart, ContainerStop, ContainerRemove, image operations, network operations
4. `GET /events` streaming endpoint

**Test**: `docker events` streams live events while you start/stop containers.

---

## Phase 12 — Container Logs

1. On ContainerStart: open log file, start goroutine copying stdout/stderr to json-file driver
2. `GET /containers/{id}/logs` endpoint: read file, optionally tail
3. Multiplexed stream framing (8-byte header)

**Test**: `docker logs mycontainer` shows output.

---

## Phase 13 — Docker Exec

1. ExecCreate endpoint: create ExecProcess metadata, attach to container
2. ExecStart: use `runc exec` to run a process in the existing container's namespace
3. ExecInspect endpoint

**Test**: `docker exec -it mycontainer /bin/sh` works.

---

## Phase 14 — User-Defined Networks

1. Allow creating networks with custom subnets
2. Internal DNS resolver: container name → IP lookup
3. Network isolation: containers on different networks cannot communicate

---

## Phase 15 — Image Builder (optional)

Implement Dockerfile parsing and `docker build`:

Simplest approach: shell out to BuildKit (`buildkitd`), which handles the complex parts.

If implementing yourself:
1. Parse Dockerfile into a list of instructions
2. For each instruction, create a temporary container, run the command, commit the result as a new layer
3. Apply COPY/ADD by extracting files from build context into the layer
4. Save the final image with the accumulated layers

---

## Phase 16 — Remaining API Coverage

Fill in the less-critical endpoints:
- Container stats (`GET /containers/{id}/stats`)
- Container pause/unpause
- Container rename
- Copy files from/to containers
- Image save/load (tar format)
- System info/version (`GET /info`, `GET /version`)
- Disk usage (`GET /df`)
- Prune operations

---

## Testing Strategy

At each phase, test with the official Docker CLI:
```sh
export DOCKER_HOST=unix:///var/run/yourruntime.sock
docker version
docker pull ubuntu:22.04
docker run -d --name test ubuntu sleep 3600
docker ps
docker logs test
docker stop test
docker rm test
```

Compatibility with the real Docker CLI is the best integration test — if the CLI works, your API is correct.

---

## What to Skip for a Learning Project

| Feature | Reason to skip |
|---------|---------------|
| Swarm / cluster | Entire distributed systems problem |
| BuildKit integration | Complex, can use BuildKit as external binary instead |
| Plugin API | Complex HTTP proxying, skip until basics work |
| Windows containers | Requires Windows, completely different implementation |
| containerd integration | Use runc directly for simplicity |
| TLS / mTLS | Use Unix socket only during learning |
| Registry push | Pull is more important to start |
| Live restore | Reconnect to running containers after daemon restart — complex |
| User namespace remapping | Security feature, add after basics work |

---

## Reference Implementations to Study

| Project | Language | Notes |
|---------|----------|-------|
| `moby/moby` | Go | The original Docker daemon |
| `containerd/containerd` | Go | Runtime layer, study for task API |
| `opencontainers/runc` | Go | Low-level runtime, study for namespace/cgroup code |
| `lima-vm/lima` | Go | macOS container runtime, simpler than Moby |
| `containers/podman` | Go | Daemonless alternative, OCI-native |
| `genuinetools/contained.af` | Go | Minimal container runtime, ~200 lines |
| `lizrice/contained.af` (talk) | — | "Containers From Scratch" talk — best intro |

The "Containers From Scratch" talk by Liz Rice is the single best 30-minute intro to the namespace/cgroup primitives before you read any of this documentation.
