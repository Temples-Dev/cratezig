# Image Service

The image service handles everything related to images: pulling from registries, storing layers on disk, managing references (tags and digests), and creating writable layers for containers.

---

## Overview

An image is a read-only, layered filesystem snapshot plus metadata. The layers are stacked bottom-to-top to produce the root filesystem a container sees.

```
Image = [ base_layer, layer_2, layer_3, ..., top_layer ]
         ↑ lowest (e.g. OS)              ↑ highest (e.g. app)
```

Each layer is a compressed tar archive of filesystem changes (added files, modified files, deleted files — "whiteouts").

---

## Image Service Interface

```
interface ImageService {
    // Lookup
    GetImage(ctx, name_or_digest, options) → Image
    ListImages(ctx, filters) → []ImageSummary
    ImageHistory(ctx, name) → []HistoryItem

    // Mutations
    PullImage(ctx, ref, registry_config, progress_output)
    PushImage(ctx, ref, registry_config, progress_output)
    TagImage(ctx, source, target) → error
    RemoveImage(ctx, name, options) → []ImageDeleteResponse

    // For container lifecycle
    CreateWritableLayer(container_id, image_id, init_func) → RWLayer
    GetLayerPath(container_id) → string   // path to mounted root

    // For build
    ImportImage(ctx, ref, config, layer_reader) → Image
    SaveImages(ctx, names) → io.Reader   // tar export
    LoadImages(ctx, reader) → progress
}
```

---

## OCI Image Format

Images are stored in the OCI Image Layout format. Understanding this is essential for implementing pull and storage.

### Manifest

A manifest describes what layers make up an image for a specific platform.

```json
{
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {
        "mediaType": "application/vnd.oci.image.config.v1+json",
        "digest": "sha256:abc123...",
        "size": 7023
    },
    "layers": [
        {
            "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
            "digest": "sha256:def456...",
            "size": 32654591
        },
        {
            "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
            "digest": "sha256:789abc...",
            "size": 5123456
        }
    ]
}
```

### Image Config

The image config contains runtime defaults and layer diff IDs.

```json
{
    "architecture": "amd64",
    "os": "linux",
    "config": {
        "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
        "Cmd": ["/bin/bash"],
        "WorkingDir": "/",
        "ExposedPorts": {}
    },
    "rootfs": {
        "type": "layers",
        "diff_ids": [
            "sha256:layer1_uncompressed_digest...",
            "sha256:layer2_uncompressed_digest..."
        ]
    },
    "history": [
        { "created": "2024-01-01T00:00:00Z", "created_by": "/bin/sh -c #(nop)  CMD [\"/bin/bash\"]" },
        ...
    ]
}
```

### Index (multi-platform manifest)

When you pull `ubuntu:22.04`, the registry first returns an index pointing to platform-specific manifests:

```json
{
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.index.v1+json",
    "manifests": [
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": "sha256:amd64manifest...",
            "size": 529,
            "platform": { "architecture": "amd64", "os": "linux" }
        },
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": "sha256:arm64manifest...",
            "size": 529,
            "platform": { "architecture": "arm64", "os": "linux" }
        }
    ]
}
```

Your pull code should select the manifest matching the daemon's platform.

---

## Registry Protocol (OCI Distribution Spec)

Pulling an image involves these HTTP calls against the registry.

### Step 1: Authenticate

```
GET https://registry.hub.docker.com/v2/
→ 401 Unauthorized
   WWW-Authenticate: Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/ubuntu:pull"

GET https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/ubuntu:pull
→ { "token": "eyJ...", "expires_in": 300 }
```

For private registries or non-DockerHub, the auth challenge URL will differ.

### Step 2: Fetch the manifest

```
GET https://registry.hub.docker.com/v2/library/ubuntu/manifests/22.04
Headers:
    Authorization: Bearer eyJ...
    Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json

Response headers include:
    Docker-Content-Digest: sha256:...
    Content-Type: application/vnd.oci.image.index.v1+json
```

If you receive an index, pick the right platform manifest and fetch that too.

### Step 3: Fetch the image config blob

```
GET https://registry.hub.docker.com/v2/library/ubuntu/blobs/sha256:abc123...
Headers: Authorization: Bearer eyJ...

Response: raw JSON of the image config
```

### Step 4: Fetch each layer blob

```
GET https://registry.hub.docker.com/v2/library/ubuntu/blobs/sha256:def456...
Headers: Authorization: Bearer eyJ...

Response: compressed tar stream

Verify: sha256(response_body) == "def456..."
```

Download all layers, potentially in parallel (typically 3-5 concurrent downloads).

### Step 5: Extract and verify

For each layer:
1. Decompress the gzip stream
2. Extract the tar archive into a directory
3. Compute sha256 of the uncompressed tar → this must match `diff_ids[i]` in the image config

---

## Layer Storage (overlay2)

After extracting layers, they are stored for use as lower directories in overlay mounts.

### Directory layout

```
{data_root}/
├── image/overlay2/
│   ├── imagedb/
│   │   ├── content/sha256/    → image config blobs (keyed by image ID)
│   │   └── metadata/sha256/   → image metadata (parent, last-updated, etc.)
│   ├── layerdb/
│   │   └── sha256/
│   │       └── {chain-id}/    → per-layer metadata
│   │           ├── cache-id   → points to overlay2 directory
│   │           ├── diff       → diff_id (uncompressed tar digest)
│   │           ├── parent     → parent chain-id
│   │           └── size       → uncompressed size
│   └── repositories.json      → tag → image-id mappings
│
└── overlay2/
    └── {cache-id}/            → extracted layer content
        ├── diff/              → actual filesystem files
        ├── link               → short symlink name (for lower dir list)
        ├── lower              → colon-separated lower dir links
        └── work/              → overlay workdir (for RW layers)
```

### Chain ID

The chain ID is how the runtime identifies a layer stack unambiguously. It chains the diff IDs together:

```
chain_id_0 = sha256(diff_id_0)
chain_id_1 = sha256("sha256:" + chain_id_0 + " " + diff_id_1)
chain_id_n = sha256("sha256:" + chain_id_{n-1} + " " + diff_id_n)
```

This ensures two images with the same layers (in the same order) share the same on-disk storage.

---

## Creating a Writable Layer for a Container

When a container is created from an image, a writable overlay layer is added on top of the image's read-only layers.

```
overlay mount:
  lowerdir = /overlay2/{layer_n}/diff:/overlay2/{layer_{n-1}}/diff:...:/overlay2/{layer_0}/diff
  upperdir = /overlay2/{container_id}/diff    ← writable container layer
  workdir  = /overlay2/{container_id}/work
  merged   = /overlay2/{container_id}/merged  ← this is the container's rootfs
```

To create:
1. Create directory `{data_root}/overlay2/{container_id}/`
2. Create `diff/`, `work/`, `merged/` subdirs
3. Write the `lower` file with the colon-separated lower directories (image layers)
4. At container start time, execute:
   ```
   mount -t overlay overlay \
     -o lowerdir={lower},upperdir={container_id}/diff,workdir={container_id}/work \
     {container_id}/merged
   ```

### init layer

Between the image layers and the container's upper layer, an extra "init layer" is inserted. This layer contains files that should be reset on each container start:
- `/etc/hostname`
- `/etc/hosts`
- `/etc/resolv.conf`
- `/dev/console` (device node)
- `/.dockerenv` (empty file signaling we're inside Docker)

The init layer is created at container create time and populated with these files based on the container's networking config.

---

## Reference Store

The reference store maps human-readable names (tags and digests) to image IDs.

```
repositories.json structure:
{
    "Repositories": {
        "ubuntu": {
            "ubuntu:22.04": "sha256:full-image-id...",
            "ubuntu:latest": "sha256:full-image-id...",
            "ubuntu@sha256:digest...": "sha256:full-image-id..."
        }
    }
}
```

Operations:
- `Tag(ref, image_id)` — add a tag
- `Untag(ref)` — remove a tag
- `Get(ref)` → image_id
- `References(image_id)` → []ref — all tags pointing to this image
- `Delete(image_id)` → error if any container references it

---

## Image Removal

Removing an image is a cascading operation:

1. Check no running containers reference this image (error if so)
2. Remove all tags pointing to this image
3. Check if any other tags still point to this image digest — if yes, done (just untagged, not deleted)
4. Find all layers used only by this image (not shared with any remaining image)
5. Delete those layer directories
6. Delete the image config from imagedb
7. Return list of untagged refs + deleted layer digests

---

## Image Push

Push is the reverse of pull:

1. Check the target registry — do the layers already exist? (`HEAD /v2/{repo}/blobs/{digest}`)
2. Upload missing layers: `POST /v2/{repo}/blobs/uploads/` → get upload URL → `PUT` with content
3. Upload image config
4. Upload manifest: `PUT /v2/{repo}/manifests/{tag}`

---

## Tagging Format

Image references follow the format:
```
[registry/][namespace/]repository[:tag][@digest]
```

Examples:
- `ubuntu` → `docker.io/library/ubuntu:latest`
- `ubuntu:22.04` → `docker.io/library/ubuntu:22.04`
- `myregistry.example.com/myapp:v1.0`
- `ubuntu@sha256:abc123...`

When no registry is specified, default to `docker.io`. When no tag is specified, default to `latest`.
