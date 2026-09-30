# Cratezig: Production Readiness Review & Plan

Reviewed 2026-09-30 against `main` @ 2d6f862 plus uncommitted changes. Zig 0.16.0.

## Progress

**Phase 0 + critical bugs: done** (branch `prod/phase0-critical-fixes`). Summary:
- Memory: containers and images own an arena and deep-copy everything they're given (`container/clone.zig`).
  `Daemon` is heap-allocated. Events store fixed-size copies instead of borrowed pointers.
- Locking: fixed the network/image RwLock self-deadlocks. Start holds the container lock for the
  whole transition. stop/kill/rm suppress the restart policy, and restarts back off exponentially.
- Exit codes: the daemon is a child subreaper and the monitor `waitpid`s the container's init,
  so exit codes and `128+signal` are real. Before, `wait` always returned 0.
- `runc create` no longer hangs. Previously the container inherited stdout pipes that never
  closed. Its output now goes to `containers/<id>/output.log`, which `docker logs` serves (framed).
- Persistence: every file write went through a buffered writer with **no flush** (state files
  were empty). All persistence now goes through `util/fsutil.zig` (std.json + fsync + atomic
  rename). Container state and HostConfig round-trip. Networks, IPAM and the default bridge
  persist.
- Isolation: `/var/lib/cratezig` and `/run/cratezig` (`exec-root`), runc `--root`, cgroup
  `/cratezig/<id>`. `daemon --config <file>` reads dockerd-style keys (`data-root`).
- OCI spec: built with std.json, and user names resolve through the rootfs `/etc/passwd`.
  cap add/drop/ALL work, and privileged mode gets all caps. Docker's default masked and
  read-only paths are set. Seccomp follows Docker's model (the old allowlist broke nearly every
  program). AppArmor `docker-default` is no longer required.
- HTTP: headers are read in full (431 if too large), header names are case-insensitive, query
  strings are percent-decoded, chunked and length-delimited bodies are read properly,
  `{"message"}` errors are escaped, a failed accept no longer kills the daemon, and `all=1` /
  `force=1` are parsed like Go's ParseBool.
- Compat: create accepts Docker's real body (nulls, `Mounts` objects, `RestartPolicy`,
  `PidsLimit`). `docker ps` gets the summary shape. `version` has the right shape. RFC 3339
  dates are used for networks and volumes, and all timestamps use the wall clock.
- Fakes removed: pull, push and build return 501. 14 dead modules were deleted. Every file is
  under 500 lines, enforced by `zig build lint` (part of `zig build test`) and in CI.

Verified against the stock Docker CLI 29.x: `version`, `ps -a`, `images`, `create`, `rm -f`,
`network ls/create`, clean 501 on `pull`/`build`, and state intact across daemon restarts.
Not verified: a real container run. That needs root plus image layers (Phase 2).

**Phase 1: done** (branch `prod/phase1`).
- Containers are refcounted. `get`/`list` return retained handles, background threads hold
  their own reference, and `rm` frees memory once the last holder releases it.
- HTTP: keep-alive, bodyless HEAD, streamed responses (close-delimited, headers flushed early),
  a 101 hijack path for attach/exec, API version checks (1.24–1.43, 400 outside that range),
  method-aware routing, and a cap of 1024 concurrent connections (503 beyond it).
  Fixed a `/volumes/{name}` → `/{name}` path-mangling bug.
- `wait` blocks on a condition variable and supports `not-running`, `next-exit` and `removed`,
  which `docker run` needs. `/events` streams with `type`/`event`/`container` filters and
  `since`/`until`.
- `inspect` returns Docker's shape (`Path`/`Args`, RFC 3339 times, `/name`). Container JSON is
  produced under the container lock.
- `tests/smoke.sh`: 40 checks against the real binary, run as non-root with curl and the stock
  docker CLI. It runs in CI.

**Known gaps:** there is no idle timeout on keep-alive connections. An `/events` stream only
notices a client disconnect at its next event. `logs -f` waits for the Phase 3 shim. `rm` of a
never-started container logs a harmless umount error. `-it`/TTY stays off until attach lands.

## 1. Where it stood (original review)

- About 7.8k LOC across 70 files. Every file is already under 500 lines. The largest are
  `image/service.zig` (483), `server/handlers/container.zig` (448) and `container/container.zig` (426).
- `zig build` and `zig build test` pass, but the 23 tests mostly check string formatting.
  Nothing tests a real container lifecycle.
- The API routing skeleton, the container store, JSON persistence and the OCI spec generator
  are real. **Most of what makes Docker useful is stubbed or faked:**

| Area | State |
|---|---|
| `docker pull` | **Fake.** Generates a random `sha256:` ID with size 1000. No registry client, no layers downloaded (`image/service.zig:387`). |
| Image layers / rootfs | **Broken.** `lower` gets the image ID written into it, which expands to `{root}/overlay2/sha256:…` and doesn't exist. No container can get a real rootfs. |
| `docker build` | **Fake.** `RUN`, `COPY` and `ADD` don't run. Layer IDs are random, and the stream prints "Using cache" for every step. |
| Networking | **No-op.** `bridge.setupBridge/connectContainer` are empty. veth and iptables code only formats strings. The netns path `/var/run/docker/netns/{id}` is never created, so `runc create` fails for bridge mode. |
| Logs | **Never written.** Nothing captures container stdout/stderr. `logs.zig` reads a file that nobody creates. |
| attach / `docker run -it` | **Missing.** No `/containers/{id}/attach`, no connection hijack, no TTY resize. |
| exec | Spawns `runc exec` with piped stdio that nobody reads (it can block). No inspect route, no stream back to the client. |
| events, df, history, push, info | Stubs or hard-coded JSON. |
| Dead modules | `storage/snapshot`, `storage/exporter`, `storage/overlay`, `storage/volume`, `image/push`, `container/health`, `vpm/manager+policy`, `network/veth`, `network/port_mapper`, `runtime/spec_generator` + `runc.prepareBundle` (uses a removed std API), `handlers/container.handleLogs`, `handlers/images.handlePruneImages` (neither compiles; they're only skipped by lazy analysis). |

## 2. Critical bugs (fix first)

**Memory safety**
1. **Container allocated in the per-request arena.** `daemon/create.zig:47`: `allocator` is the
   request arena from `server.zig`, so the `Container`, its name and its config are freed when the
   HTTP request ends. The store then holds dangling pointers. The same applies to `merged_config`
   slices (they point into the parsed request JSON) and to `labels` / `port_bindings`.
2. **`rootfs_paths` points at a stack buffer.** `daemon/start.zig:23-24`.
3. **Event `actor_id = &id`** points at a stack array in `create.zig:74`. Every published event also
   leaks a `StringHashMap`.
4. **`Daemon.init` returns by value**, but `builder.image_service = &d.images` points at the local
   (`daemon.zig:51,59`). The builder ends up with a dangling pointer. `Daemon` needs a stable
   address (heap-allocate it, or init in place).
5. `std.Thread.spawn` per connection and per monitor, detached, with no limit and no shutdown path.

**Deadlocks / races**
6. `NetworkController.createEndpoint/releaseEndpoint/deleteNetwork` take the write lock and then
   call `self.get()`, which takes the shared lock. That's a self-deadlock (`controller.zig:108,134,275`).
7. `ImageService.tagImage` takes the shared lock, calls `getImage` (shared again), then upgrades.
   That's re-entrant and racy (`service.zig:271`).
8. `containerStart` reads state, unlocks, then locks again, so two concurrent starts can both
   pass the check. The restart policy calls `containerStart` from the monitor thread, and nothing
   stops that path when the user runs `docker stop`, so `always` restarts forever.
9. `ContainerStore.get` returns a raw `*Container`. `remove` can delete it while another handler
   still uses it. There's no refcount or lifetime rule.

**Safety / isolation**
10. **The default `data_root` is `/var/lib/docker`** (`config.zig:14`) and the netns path is under
    `/var/run/docker`. Running next to real dockerd will corrupt its state. Use
    `/var/lib/cratezig` and `/run/cratezig`.
11. The build scratch dir is seeded from `@intFromPtr(req)` (`builder_handler.zig:32`). The path is
    predictable in world-writable `/tmp`, which allows symlink attacks. The untrusted tar is
    extracted as root with no path checks.
12. JSON is written by hand with unescaped `{s}` in `saveImageToDisk`, `saveNetworkToDisk`,
    seccomp and mounts. That allows JSON injection and corrupt state files. Use `std.json.Stringify`
    everywhere.
13. Privileged mode only adds `CAP_SYS_ADMIN`. It needs all caps, no seccomp, no masked paths,
    and host devices.

**HTTP layer**
14. Headers are read with a single 8 KB `readVec` (`server.zig:61-65`). Headers split across TCP
    reads, or bigger than 8 KB, are lost.
15. Header lookup is case-sensitive, with only two spellings checked. There's no keep-alive, no
    streaming responses (logs `-f`, events, pull progress, build), and no hijack (attach, exec).
16. Every error response gets `Connection: close` and a hand-built JSON message, which is unescaped.

## 3. Target: what "drop-in" must mean (MVP scope)

Pass these with the stock `docker` CLI and `docker compose`, with `DOCKER_HOST=unix:///run/cratezig.sock`:

```
docker version / info / ps -a / images
docker pull alpine nginx:alpine               # Docker Hub + ghcr.io, multi-arch index
docker run --rm alpine echo hi                # attach + exit code
docker run --rm -it alpine sh                 # TTY + hijack + resize
docker run -d --name web -p 8080:80 nginx     # bridge net + NAT
docker logs -f web ; docker exec -it web sh
docker stop/start/restart/kill/rm -f web
docker volume create/ls/rm ; -v vol:/data ; -v $PWD:/src
docker network create n1 ; run --network n1   # + container-name DNS
docker rmi ; docker system prune
docker compose up -d / down                   # basic web+db stack
```

Build is **not** in the MVP. Until the builder is real, `POST /build` should return a clear
`501`/error, not fake success. Faking success is worse than failing.

## 4. Phased plan

Each phase ends green on `zig build test` plus the integration suite (Phase 1 adds it).

### Phase 0: Hygiene and stop the bleeding (small)
- Move `data_root` to `/var/lib/cratezig` and runtime state to `/run/cratezig` (bundles, netns, sockets).
- Delete or quarantine dead modules (the list in §1). Delete fake paths: fake pull and fake build
  return `NotImplemented`.
- Repo cleanup: remove the `\252\252…` junk dir. Add `dist/`, `.zig-cache/` and `zig-out/` to
  `.gitignore`. Strip the boilerplate comments from `build.zig`.
- Add a `zig build lint` step (or `scripts/check-loc.sh`) that fails if any `src/**/*.zig` is over
  500 lines. Run it in CI.
- CI: GitHub Actions running `zig build test` plus the LOC check.

### Phase 1: Core correctness (memory, locking, HTTP)
- **Ownership model:** each `Container` owns an `ArenaAllocator` (backed by the daemon GPA) that
  holds all its strings and config. Deep-copy from the request at create time, and free
  everything in one `deinit` on remove. Do the same for `Image` and `Network`.
- **Lifetime:** `ContainerStore.get` returns a refcounted handle (`acquire/release`), or handlers
  run under the store lock for short reads. Use a per-container state machine with transitions
  (`created→running→exited→removing`) validated in one place.
- Heap-allocate `Daemon` (`*Daemon`) so interior pointers are stable.
- Fix the RwLock self-deadlocks: add internal `getLocked()` helpers that assume the lock is held.
- **HTTP:** move to `std.http.Server` (supports keep-alive, chunked encoding and header parsing)
  over the unix socket. Add:
  - streaming response writer (chunked) for logs/events/pull/build
  - connection **hijack** (`Upgrade: tcp`, 101) for attach and exec
  - `/v1.xx/` prefix handling, `Api-Version` header, `HEAD /_ping`, version negotiation (min 1.24, max 1.45)
  - one `Response.fromError` table producing `{"message": ...}` via `std.json`
- A bounded worker pool, or `std.Io` async, instead of unbounded detached threads.
- **Integration test harness:** `tests/integration/*.sh` (or a Zig test runner) that starts the
  daemon in a temp root and drives the real `docker` CLI. It runs as root in CI (GitHub runners
  allow this).

### Phase 2: Real images
- Registry v2 client on `std.http.Client` (TLS in std): token auth (Docker Hub
  `auth.docker.io`), `~/.docker/config.json` credentials, manifest list / OCI index with
  platform selection, schema2 and OCI manifests, blob download with sha256 verification,
  resumable, parallel layers.
- Content store: `blobs/sha256/<digest>`. Layer unpack with `std.compress.flate` (gzip) and
  zstd plus `std.tar`, handling OCI whiteouts (`.wh.` becomes an overlay char-device/opaque xattr),
  hardlinks, symlinks, xattrs, uid/gid, and path-traversal protection.
- Layer DB keyed by **chainID**. Image ID = sha256 of the config blob, like Docker.
- Parse the image config (`Env`, `Cmd`, `Entrypoint`, `WorkingDir`, `User`, `ExposedPorts`,
  `Volumes`, `Labels`, `StopSignal`, `Healthcheck`).
- Correct `lowerdir` chain for container RW layers. Use short `l/` links so the mount options fit
  in a page.
- Streaming pull progress JSON (the CLI renders it). `docker save/load`, `tag`, `rmi` with
  refcounting against containers, `image prune`, `history`.

### Phase 3: Runtime and lifecycle
- **Per-container shim** (a small separate `cratezig-shim` binary, like conmon or
  containerd-shim): owns the container's stdio, writes json-file logs, keeps the exit code, and
  survives daemon restarts. The daemon talks to it over a unix socket. This is what makes
  `logs`, `attach`, restart-safe containers and `wait` correct.
- `runc create` with `--console-socket` for TTY, or with pipes. Use `runc start` / `kill` /
  `delete` with `--root /run/cratezig/runc`.
- Merge image and user config properly (env, user name→uid via the rootfs `/etc/passwd`, workdir).
  Generate `/etc/hosts`, `/etc/resolv.conf`, `/etc/hostname` and bind them in.
- cgroup v2 resources: memory, swap, cpu quota/period/shares→weight, pids, shm size.
- Replace `wait` polling with exit notification from the shim. Support
  `wait?condition=not-running|next-exit|removed`.
- Restart policies with exponential backoff, `unless-stopped` semantics, and a manual stop that
  suppresses restart.
- **Live restore:** on daemon start, reconcile the stored state with the shim and runc state.
  Mark dead containers exited.
- exec: create, start (hijacked stream), inspect, resize. Exit codes come from the shim.
- Graceful daemon shutdown on SIGTERM/SIGINT (close the listener, drain, persist).

### Phase 4: Networking
- Netlink (raw `AF_NETLINK` via `std.os.linux`) or `ip` as a first cut: create `cz0` bridge,
  veth pair, move the peer into the netns, set IP/route, bring it up. Create the netns bind mount
  under `/run/cratezig/netns`.
- Persist IPAM allocations so restarts don't hand out duplicate IPs.
- NAT with nftables (preferred) or iptables: MASQUERADE for egress and DNAT for `-p`, plus
  hairpin and a localhost proxy (or `route_localnet`) for `localhost:8080`.
- `host` and `none` modes, user-defined bridge networks, connect/disconnect.
- Embedded DNS for container names on user networks (needed for compose).

### Phase 5: Volumes and mounts
- Named volumes (local driver), anonymous volumes from the image `Volumes`, copy-up of image
  content on first mount.
- `HostConfig.Mounts` is an array of objects (`Type/Source/Target/ReadOnly/TmpfsOptions`), not
  strings. Fix the type. Support `tmpfs`, `--read-only`, and `:ro,z,Z` bind options.
- Volume refcounts: block `rm` while in use, `-v` on container rm, `volume prune`.

### Phase 6: API shape parity
Docker CLI and compose parse responses strictly. Match the Engine API exactly:
- `GET /containers/json`: `Id, Names[], Image, ImageID, Command, Created (unix s), State, Status ("Up 3 minutes"), Ports[], Labels, NetworkSettings, Mounts`, plus the `filters` query (compose relies on label filters).
- `GET /containers/{id}/json`: `State.Status` string, RFC3339 `StartedAt/FinishedAt`, `Config`, `HostConfig`, `NetworkSettings.Networks[*].IPAddress`, `Mounts`.
- Drop the duplicate snake_case JSON fields in the create handler. The API is PascalCase only.
  This roughly halves `handlers/container.zig`.
- `info`/`version` from real data (kernel via `uname`, counts, cgroup version, runtimes).
- `/events` streaming with filters and since/until. `/system/df`, prunes with filters.

### Phase 7: Builder (post-MVP)
Pick one:
- **(a) Real classic builder:** each `RUN` runs in a temp container via runc. `COPY/ADD` read from
  the extracted context with `.dockerignore`. The layer is a tar of the overlay upperdir. Cache key
  = parent chainID + instruction + content hash of the sources. Also needs multi-stage `--from`,
  `ARG`, `ENV` expansion and `SHELL`.
- **(b) Delegate** to a BuildKit daemon (`buildkitd` with the runc worker) and import the result.
  Much less code and full Dockerfile compatibility.

Recommendation: (b) first so compose `build:` works. (a) later if a native fast path is a goal.

### Phase 8: Production operations
- systemd `cratezig.service` plus `cratezig.socket` (socket activation), a `docker` group-style
  socket permission (0660 root:cratezig, **not** 0666), `/etc/cratezig/daemon.json`.
- Structured logging with levels. `--debug`. Optional Prometheus `/metrics`.
- Rootless mode (user namespaces, slirp4netns/pasta), later.
- Packaging: `.deb`/`.rpm` from CI, and a runc version check at startup.
- Fuzz the HTTP parser, tar extractor and JSON loaders (`zig build fuzz`).
- Benchmarks against dockerd: daemon RSS, `docker run --rm alpine true` latency, pull time,
  and 100 containers in parallel. Publish numbers only from real runs.

## 5. Code structure rules (≤500 lines/file)

- Keep one concern per file. Planned splits as code grows:
  - `server/handlers/container.zig` → `container_create.zig` (request decode), `container_lifecycle.zig`, `container_io.zig` (logs/attach/exec)
  - `image/service.zig` → `image/store.zig`, `image/registry.zig`, `image/unpack.zig`, `image/reference.zig` (name/tag/digest parsing)
  - `container/container.zig` → `container/types.zig`, `container/persist.zig`
  - `network/` → `netlink.zig`, `nat.zig`, `ipam.zig`, `dns.zig`
- Never write JSON by hand. Use `std.json.Stringify` with `jsonStringify` methods on types.
- Every allocation has a named owner (daemon GPA, object arena, or request arena). Never store
  request-arena memory in long-lived state.
- Enforce the rule with a build step that fails CI over 500 lines.

## 6. Suggested order and rough size

| Phase | Unblocks | Rough effort |
|---|---|---|
| 0 Hygiene | safe to run next to Docker | 1–2 days |
| 1 Core + HTTP | everything below; integration tests | 1–2 weeks |
| 2 Images | real rootfs; `pull`, `images`, `rmi` | 2 weeks |
| 3 Runtime + shim | `run`, `logs`, `exec`, `-it`, restart | 2–3 weeks |
| 4 Networking | `-p`, compose networking | 1–2 weeks |
| 5 Volumes | compose stateful services | 1 week |
| 6 API parity | CLI/compose output correctness | ongoing, ~1 week |
| 7 Builder | `docker build`, compose `build:` | 1 week (delegate) / 4+ weeks (native) |
| 8 Ops | installable, supportable | 1 week |
