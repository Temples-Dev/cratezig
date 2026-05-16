# Container Runtime — Clean-Room Implementation Guide

This documentation describes **what** a Docker-compatible container runtime does and **how** its subsystems fit together. It is written for someone building their own implementation from scratch in any language.

Nothing here is copied from source code. All interfaces, flows, and data models are described behaviorally.

---

## Documents in This Series

| # | File | What it covers |
|---|------|---------------|
| 00 | `00-overview.md` | This file — architecture, vocabulary, build order |
| 01 | `01-data-models.md` | Core structs: Container, Image, Network, Volume |
| 02 | `02-api.md` | HTTP REST API contract |
| 03 | `03-daemon.md` | The Daemon — central coordinator |
| 04 | `04-image-service.md` | Image pulling, layers, storage |
| 05 | `05-container-lifecycle.md` | Create → Start → Stop → Remove flow |
| 06 | `06-networking.md` | Bridges, endpoints, IPAM, iptables |
| 07 | `07-storage.md` | Overlay filesystems, snapshots, volumes |
| 08 | `08-runtime.md` | OCI spec, runc/containerd interface |
| 09 | `09-events.md` | Event pub/sub system |
| 10 | `10-logging.md` | Log drivers and streaming |
| 11 | `11-build-order.md` | Suggested implementation order |

---

## Core Vocabulary

| Term | Meaning |
|------|---------|
| **Container** | An isolated process with its own filesystem, network, and PID namespace |
| **Image** | A read-only, layered filesystem snapshot + metadata |
| **Layer** | A diff of filesystem changes on top of a parent layer |
| **Snapshot** | A point-in-time copy-on-write view of a layer stack |
| **Registry** | Remote server storing images (e.g. Docker Hub) |
| **Daemon** | The long-running background process that manages everything |
| **OCI** | Open Container Initiative — standard specs for images and runtimes |
| **runc** | Low-level OCI runtime that creates the actual Linux namespaces |
| **containerd** | Mid-level runtime daemon managing lifecycle, snapshots, tasks |
| **Sandbox** | A network namespace shared by containers in a pod |
| **Endpoint** | A virtual NIC connecting a container to a network |
| **IPAM** | IP Address Management — assigns IPs to endpoints |
| **Volume** | A host-managed directory mounted into a container |

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Client (CLI, SDK, or any HTTP client)                       │
│  Issues requests like:                                        │
│    POST /containers/create                                    │
│    POST /containers/{id}/start                               │
│    GET  /containers/{id}/json                                │
└───────────────────────┬─────────────────────────────────────┘
                        │  HTTP over Unix socket or TCP
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  HTTP Server  (see 02-api.md)                                │
│  - Listens on unix:///var/run/docker.sock (default)          │
│  - Parses requests, validates API version                    │
│  - Routes to handler functions                               │
│  - Returns JSON responses                                    │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  Daemon  (see 03-daemon.md)                                  │
│  - Single central object                                     │
│  - Holds references to all subsystems                        │
│  - Implements all business logic                             │
│                                                              │
│  ┌───────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │ Container     │  │ Image        │  │ Network         │  │
│  │ Store         │  │ Service      │  │ Controller      │  │
│  └───────────────┘  └──────────────┘  └─────────────────┘  │
│  ┌───────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │ Volume        │  │ Event        │  │ Runtime         │  │
│  │ Service       │  │ Service      │  │ Client          │  │
│  └───────────────┘  └──────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                        │
          ┌─────────────┼──────────────┬───────────────┐
          ▼             ▼              ▼               ▼
  ┌──────────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐
  │ containerd   │ │ Network  │ │ Storage  │ │ OCI Registry │
  │ (runtime)    │ │ (kernel  │ │ (overlay │ │ (remote      │
  │              │ │  netlink │ │  2, zfs) │ │  image pull) │
  └──────────────┘ └──────────┘ └──────────┘ └──────────────┘
```

---

## Key Design Principles

### 1. Everything is an interface
Each subsystem exposes a narrow interface. The Daemon calls the interface, not the implementation. This makes drivers swappable: overlay2 or zfs storage, json-file or syslog logging, bridge or overlay networking.

### 2. Persistent metadata + runtime state
The daemon separates what it saves to disk (container config, image metadata) from what it tracks in memory (running process PIDs, live network endpoints). On restart, it reconstructs runtime state from persisted metadata.

### 3. REST API is the only external boundary
All external clients — CLI, SDK, CI systems — speak HTTP. The daemon speaks nothing external except to containerd (gRPC) and registries (HTTP/HTTPS). Internal subsystems call each other as library code.

### 4. Two-phase container operation
"Create" and "Start" are separate. Create allocates metadata and filesystem. Start allocates network, spawns the process, activates logging. This separation allows inspecting config before running.

### 5. Events as audit log
Every lifecycle event (container create, image pull, network delete) is published to an in-memory event bus. Clients can subscribe to a live stream or query history. Nothing is persisted to disk — on restart the buffer is empty.

---

## Suggested Implementation Languages

This guide uses pseudocode and language-neutral descriptions. Your implementation can be in:

- **Go** — most natural, since Moby itself is Go
- **Rust** — good for performance-critical components
- **Python** — easiest for learning, though not production-grade
- **C / C++** — if you want deep OS integration
- **TypeScript/Deno** — unusual but viable for a learning project

All subsystems have well-defined boundaries. You can implement them incrementally.

---

## Minimum Viable Implementation

To get a container running end-to-end, you need these in order:

1. HTTP server that accepts API calls
2. Image puller (download layers from a registry)
3. Overlay filesystem assembler (stack layers into a rootfs)
4. OCI spec generator (translate container config to runc format)
5. runc invocation (launch the process)
6. Container metadata store (track what's running)
7. Basic networking (at minimum, host networking works without extra code)

Everything else (volumes, events, log drivers, swarm) can be added incrementally.
