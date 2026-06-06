# Build & release

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [base_image.md](base_image.md), [harbor.md](harbor.md), [warm_store.md](warm_store.md)

> **Purpose**: Describe how the four base tags are built and published (host-native `docker build`,
> no buildx, cold publish) and how a downstream project can build the base locally.

`docker build` only — **no buildx, no emulation**. A build can only ever
produce the host-native arch. Multi-platform manifest lists are forbidden by
design (see [base_image.md](base_image.md)).

## Building & publishing

By default, one command builds and pushes both CPU and CUDA tags for one arch:

```sh
hostbootstrap base build-and-push --arch amd64
```

The CLI:

1. Detects the host substrate (or uses the explicit `--arch`).
2. Resolves every dynamic value (versions, URLs, the CUDA base image).
3. Invokes `docker build --build-arg … --pull --no-cache` against
   `docker/basecontainer.Dockerfile`.
4. `docker push`es
   `docker.io/tuee22/hostbootstrap:basecontainer-<flavor>-<arch>`.

Pass `--flavor cpu` or `--flavor cuda` to publish only one flavor:

```sh
hostbootstrap base build-and-push --flavor cpu --arch amd64
```

The publish path is **always cold** (`--no-cache --pull`): the registry copy
matches a clean rebuild from source, with no layer-cache carryover from a
stale local image.

For local validation without pushing:

```sh
hostbootstrap base build --flavor cpu --arch amd64
```

WRONG:

```sh
hostbootstrap base push --flavor cpu --arch amd64
```

Standalone push is not supported. Publishing always goes through the cold
`build-and-push` path so the registry copy matches the just-built local layers.

RIGHT:

```sh
hostbootstrap base build-and-push --arch amd64
```

The CLI never re-pushes the large base image when a downstream project pushes
its custom image (see [harbor.md](harbor.md)).

## `--build-base` for downstream projects

A downstream project's bootstrap invocation can pass
`--build-base --base-context /path/to/hostbootstrap` to build the base locally
from that checkout's `docker/basecontainer.Dockerfile`, tagging it with the
identical name. The downstream project container is then built without pulling
the base tag from Docker Hub. The default behaviour is to **pull** the base from
Docker Hub.

## Loss of provenance

Plain `docker build` does not emit the SBOM/attestation manifests buildx
produces. This is an accepted trade-off: a build is single-arch and host-native,
so the cross-arch manifest tooling that carries those attestations is not used.
