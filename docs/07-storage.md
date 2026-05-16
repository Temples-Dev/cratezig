# Storage

The storage subsystem manages two distinct things:

1. **Layer storage** — the stacked read-only image layers and the container's writable top layer (overlay filesystem)
2. **Volumes** — host-managed directories mounted into containers, independent of the container lifecycle

---

## Layer Storage Overview

Each image is a stack of read-only layers. When a container starts, a new writable layer is added on top. This is called **copy-on-write** (CoW): reads come from the highest layer that has the file; writes go to the top writable layer only.

```
Container writable layer (upperdir)     ← changes go here
──────────────────────────────────────
Image layer N (lowerdir, top)
Image layer N-1 (lowerdir)
...
Image layer 1 (lowerdir, bottom)        ← base OS files
```

---

## Storage Driver Interface

Your storage driver must implement:

```
interface StorageDriver {
    // Check if this driver works on the current system
    Status() → []DriverStatus
    Supported() → bool

    // Layer operations
    CreateReadOnly(id, parent_id, opts) → error
    Create(id, parent_id, opts) → error     // creates writable layer
    Remove(id) → error

    // Mount/unmount
    Get(id, mount_label) → (path, error)    // mount the layer, return rootfs path
    Put(id) → error                          // unmount the layer

    // Diff operations (for image push/export)
    Diff(id, parent_id) → io.ReadCloser          // tar stream of changes
    DiffSize(id, parent_id) → (int64, error)
    ApplyDiff(id, parent_id, diff io.Reader) → (int64, error)  // extract tar into layer

    // Introspection
    Exists(id) → bool
    Status() → [][]string
}
```

---

## Overlay2 Driver

`overlay2` is the default and recommended storage driver on modern Linux kernels (4.0+). It uses the kernel's `overlay` filesystem.

### Directory layout

```
{data_root}/overlay2/
├── {layer-cache-id}/           ← one directory per layer
│   ├── diff/                   ← actual filesystem contents
│   ├── link                    ← short name (symlink target)
│   ├── lower                   ← colon-separated lower layer short names
│   └── merged/                 ← (only exists while mounted)
│
├── {container-id}/             ← container's writable layer
│   ├── diff/                   ← container writes land here
│   ├── link
│   ├── lower                   ← all image layer short names
│   ├── work/                   ← overlay workdir (kernel requirement)
│   └── merged/                 ← container's rootfs (mounted here)
│
└── l/                          ← symlink directory (short names → full paths)
    ├── ABCDEFGHIJ → ../layer-cache-id-1/diff
    ├── KLMNOPQRST → ../layer-cache-id-2/diff
    └── ...
```

The `l/` directory exists because the kernel has a limit on the length of the `lowerdir=` mount option. Short symlink names avoid hitting this limit.

### Mounting a container layer

```
mount -t overlay overlay \
  -o lowerdir=/overlay2/l/ABCD:/overlay2/l/EFGH:/overlay2/l/IJKL,\
     upperdir=/overlay2/{container-id}/diff,\
     workdir=/overlay2/{container-id}/work \
  /overlay2/{container-id}/merged
```

Order of lowerdirs: **top layer first**, bottom layer last.

### Creating a new image layer

```
function CreateReadOnly(id, parent_id):
1. mkdir -p {data_root}/overlay2/{id}/diff
2. Generate short name: shortname = random_base32(26)
3. Write {data_root}/overlay2/{id}/link = shortname
4. Create symlink: {data_root}/overlay2/l/{shortname} → ../{id}/diff
5. If parent_id is not empty:
   parent_lower = read {data_root}/overlay2/{parent_id}/lower (if exists)
   parent_link  = read {data_root}/overlay2/{parent_id}/link
   Write {data_root}/overlay2/{id}/lower = parent_link + ":" + parent_lower
   (prepend parent's link, making it the next-highest layer)
```

### Applying a diff (extracting a pulled layer)

```
function ApplyDiff(id, parent_id, tar_stream):
1. Ensure layer directory exists: {data_root}/overlay2/{id}/diff/
2. Extract tar_stream into {data_root}/overlay2/{id}/diff/
   Handle whiteout files:
     - .wh.{filename}        → record that {filename} should be deleted
     - .wh..wh..opq          → opaque whiteout (directory replaces parent entirely)
3. For deleted files: create overlay whiteout: mknod -m 0 {file} c 0 0
4. Return bytes written
```

### Whiteout files

When a layer deletes a file that existed in a lower layer, it cannot actually remove the lower file (it's read-only). Instead it creates a "whiteout" marker:

- **Regular whiteout**: a character device with major/minor 0,0 named `.wh.{filename}`
- **Opaque whiteout**: a file named `.wh..wh..opq` in a directory means the entire directory contents from lower layers are hidden

The overlay filesystem handles these natively — no special code needed at read time. But during tar import/export you must translate between the tar whiteout format (`.wh.` prefix) and the overlay format (char device 0,0).

---

## Volumes

Volumes are directories managed by the daemon (or a plugin) that exist independently of containers. They persist when a container is removed.

### Volume Driver Interface

```
interface VolumeDriver {
    Name() → string
    Create(name, opts) → (Volume, error)
    Remove(volume) → error
    List() → ([]Volume, error)
    Get(name) → (Volume, error)
    Path(volume) → string        // host path to mount into container
    Mount(volume, id) → (string, error)  // called at container start
    Unmount(volume, id) → error          // called at container stop
    Capabilities() → Capability
}
```

### Local Volume Driver

The built-in `local` driver stores volumes under `{data_root}/volumes/`:

```
{data_root}/volumes/
├── {volume-name}/
│   ├── _data/          ← actual volume contents, bind-mounted into container
│   └── opts.json       ← driver options (for nfs/tmpfs mounts)
└── metadata.db         ← volume metadata index
```

Operations:
- **Create**: `mkdir -p {data_root}/volumes/{name}/_data`
- **Remove**: `rm -rf {data_root}/volumes/{name}/`
- **Mount**: return `{data_root}/volumes/{name}/_data` as the host path
- **Unmount**: no-op for local driver (it's just a directory)

The local driver also supports special mount options for network filesystems:

```json
{
  "type": "nfs",
  "o": "addr=192.168.1.1,rw",
  "device": ":/path/on/nfs/server"
}
```

When these options are present, the local driver issues an actual `mount` syscall instead of just returning a directory path.

### Volume Lifecycle

```
VolumeCreate(name, driver, options):
1. If name empty: generate random name
2. If driver empty: use "local"
3. Check name not already in use
4. driver.Create(name, options)
5. Persist to metadata.db
6. Return Volume object

VolumeRemove(name, force):
1. Check no containers currently using this volume
   (track reference count per volume)
2. driver.Remove(volume)
3. Delete from metadata.db

VolumeMount(volume, container_id):
1. Increment reference count
2. host_path = driver.Mount(volume, container_id)
3. Return host_path for use in container's bind mount list

VolumeUnmount(volume, container_id):
1. driver.Unmount(volume, container_id)
2. Decrement reference count
```

### Anonymous vs Named Volumes

- **Named**: `docker run -v mydata:/app/data` — volume persists, user can manage it
- **Anonymous**: `docker run -v /app/data` — volume gets a random UUID name; removed with container if `--rm` or `-v` flag used on `docker rm`

Track which volumes were created anonymously so `ContainerRemove` with `remove_volumes=true` knows what to clean up.

---

## Bind Mounts

Bind mounts (`-v /host/path:/container/path`) are not managed by the volume system. They are passed directly to the OCI runtime spec as bind mounts.

```
OCI spec mount entry:
{
    "destination": "/container/path",
    "type":        "bind",
    "source":      "/host/path",
    "options":     ["rbind", "rw"]   // or "ro" for read-only
}
```

Propagation modes:
- `private` / `rprivate`: default — mounts inside container don't propagate to host
- `shared` / `rshared`: mounts propagate both ways
- `slave` / `rslave`: host mounts propagate into container but not vice versa

SELinux labels:
- `:z` — relabel content for sharing between containers
- `:Z` — relabel content as private (one container only)

---

## tmpfs Mounts

tmpfs mounts create an in-memory filesystem inside the container — useful for secrets or scratch space that must not touch disk.

```
OCI spec mount entry:
{
    "destination": "/run",
    "type":        "tmpfs",
    "source":      "tmpfs",
    "options":     ["nosuid", "noexec", "nodev", "size=65536k"]
}
```

---

## Disk Usage Accounting

The `GET /df` endpoint reports disk usage broken down by:

- **Images**: sum of unique layer sizes (layers shared between images counted once)
- **Containers**: size of each container's writable layer (via `du -sh {container-id}/diff`)
- **Volumes**: size of each volume's `_data` directory
- **Build cache**: BuildKit cache (if build service is running)

Computing image disk usage correctly requires tracking which layers are shared:

```
unique_layers = set()
total_size = 0
for each image:
    for each layer in image.rootfs.layers:
        if layer not in unique_layers:
            unique_layers.add(layer)
            total_size += layer.size
```

---

## Data Root Layout (Complete)

```
{data_root}/                         default: /var/lib/docker
├── containers/
│   └── {container-id}/
│       ├── config.v2.json           container + image config
│       ├── hostconfig.json          host config
│       ├── {container-id}-json.log  json-file log output
│       ├── checkpoints/             CRIU checkpoint data
│       └── secrets/                 swarm secrets (tmpfs)
│
├── image/
│   └── overlay2/
│       ├── imagedb/
│       │   ├── content/sha256/      image config blobs
│       │   └── metadata/sha256/     image metadata (created, parent)
│       ├── layerdb/
│       │   └── sha256/
│       │       └── {chain-id}/
│       │           ├── cache-id     → overlay2 directory name
│       │           ├── diff         uncompressed tar digest
│       │           ├── parent       parent chain-id
│       │           ├── size         uncompressed layer size
│       │           └── tar-split.json.gz  for re-streaming the original tar
│       └── repositories.json        name:tag → imageID mappings
│
├── overlay2/                        layer storage (see above)
│
├── volumes/
│   ├── {volume-name}/
│   │   └── _data/
│   └── metadata.db
│
├── network/
│   ├── files/
│   │   └── {network-id}.json        network config
│   └── ingress-sbox/                swarm ingress sandbox
│
├── plugins/
│   └── {plugin-id}/
│       ├── config.json
│       └── rootfs/
│
├── swarm/                           swarm state
├── trust/                           content trust keys
├── buildkit/                        BuildKit cache
└── docker.pid                       daemon PID
```
