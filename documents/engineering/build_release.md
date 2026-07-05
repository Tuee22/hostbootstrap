# Build & release

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [base_image.md](base_image.md), [in_cluster_registry.md](in_cluster_registry.md), [warm_store.md](warm_store.md)

> **Purpose**: Describe how the four base tags are built and published (host-native `docker build`,
> no buildx, cold publish) and how a downstream project can build the base locally.

`docker build` only — **no buildx, no emulation**. A build can only ever
produce the host-native arch. Multi-platform manifest lists are forbidden by
design (see [base_image.md](base_image.md)).

## Building & publishing

`base` is a **maintainer command**: it is registered only in this repo's Poetry development install
(it needs the dev toolchain), so run it from the repo root via `poetry run` — the pipx-installed
consumer CLI does not expose it. See
[../languages/python.md](../languages/python.md#maintainer-commands-are-dev-only).

By default, one command builds and pushes both the CPU and CUDA tags for one
arch, **concurrently**:

```sh
poetry run hostbootstrap base build-and-push --arch amd64
```

The CLI:

1. Detects the host substrate (or uses the explicit `--arch`).
2. On Linux, measures host CPU/RAM and **refuses below a floor** — the supported build machine is
   16 GB RAM / 8 CPUs, so the floor is 8 CPUs / 14 GiB total / 8 GiB available — then sizes a
   per-build resource budget (see
   [base_image.md](base_image.md#host-sized-warm-store-build-budget)).
3. Resolves every dynamic value (versions, URLs, the CUDA base image) per flavor.
4. For each flavor, invokes `docker build --build-arg … --memory/--cpus … --pull --no-cache`
   against `docker/basecontainer.Dockerfile`, then `docker push`es
   `docker.io/tuee22/hostbootstrap:basecontainer-<flavor>-<arch>`.

The two flavors' builds are independent (different base image, distinct tag,
separate layer cache), so they run concurrently and each build's streamed output
is line-prefixed `[cpu]` / `[cuda]`. This is **host-level parallelism of two
plain single-arch `docker build`s** — not a buildx multi-platform manifest, which
remains forbidden. Concurrency roughly halves the wall-clock; the measured host
budget is **split** between the two concurrent builds (each gets half the
memory/CPU cap) so peak usage stays bounded, while `--sequential` gives each
build the whole host (higher per-build `-j`, lower disk pressure). Concurrency is
automatically moot with `--flavor`, which builds a single tag:

```sh
hostbootstrap base build-and-push --arch amd64 --sequential
```

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
docker push docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64
```

Standalone push is not supported by the hostbootstrap workflow. Publishing always goes through the cold
`build-and-push` path so the registry copy matches the just-built local layers.

RIGHT:

```sh
hostbootstrap base build-and-push --arch amd64
```

The CLI never re-pushes the large base image when a downstream project pushes
its custom image (see [in_cluster_registry.md](in_cluster_registry.md)).

## Building the base for downstream projects

A downstream project builds against the published
`docker.io/tuee22/hostbootstrap:basecontainer-<flavor>-<arch>` base. To validate
against a local checkout instead, `hostbootstrap base build` cold-rebuilds the
base from that checkout's `docker/basecontainer.Dockerfile` and leaves it tagged
with the identical name in the local Docker daemon. A downstream project image
build then resolves the local tag in place of pulling the published base.

The `run` command accepts a single `--project-root` option, which points at the
project root containing exactly one `.cabal` file. It builds the project binary
idempotently and execs it.

## Loss of provenance

Plain `docker build` does not emit the SBOM/attestation manifests buildx
produces. This is an accepted trade-off: a build is single-arch and host-native,
so the cross-arch manifest tooling that carries those attestations is not used.
