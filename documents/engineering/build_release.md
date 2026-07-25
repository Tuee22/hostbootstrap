# Build and Release

**Status**: Authoritative source
**Supersedes**: the workflow that allowed derived projects to consume a same-named local base tag
**Referenced by**: [documents index](../README.md), [base image](base_image.md), [warm store](warm_store.md), [derived Dockerfile](derived_dockerfile.md)

> **Purpose**: Define the current base publish command and the target immutable consumption contract.

## TL;DR

- Maintainers build and publish single-architecture base tags with `hostbootstrap base
  build-and-push`.
- Derived builds must consume the published registry artifact, never a same-named local image.
- The target resolves the mutable discovery tag to a verified digest and runs the complete
  Python/Haskell preflight before any Docker or registry mutation.

## Current Status

The current command builds and pushes mutable tags and runs only the Python code-check before Docker.
Derived demo builds still accept a tag without forced pull/digest binding. The development plan owns the
full Haskell preflight, immutable consumer handoff, integrity checks, and publication evidence.

## Current maintainer command

From the repository Poetry environment:

```sh
poetry run hostbootstrap base build-and-push --arch amd64
```

Run that command on a native amd64 host/Docker engine; an arm64 publication must run as a separate
`--arch arm64` invocation on a native arm64 peer. The current CLI accepts a mismatched requested
architecture while still using plain `docker build`, so the operator must enforce the match until Phase
6 Sprint 6.7 adds the fail-closed preflight.

The command resolves dynamic build arguments, runs the Python `ruff`/`black`/`mypy` self-check, cold-builds
the selected CPU/CUDA tag(s) with plain single-architecture `docker build`, and pushes each tag. Two
flavors build concurrently unless `--sequential` or `--flavor` narrows the work. Buildx, emulation, and
multi-architecture manifest lists are outside this workflow.

## Missing Haskell preflight

The current preflight calls only `python -m hostbootstrap.check_code`. It does **not** run the Haskell
formatter/linter/build/test gate over `hostbootstrap-core` before Docker or registry mutation. The base
Dockerfile merely smoke-tests the installed formatter/linter against warm-store sample modules; that is
not a source-tree Haskell preflight.

The publish target must run, before any build or push:

```text
Python code check
Python tests
Haskell canonical code check/build
Haskell tests (including documentation validation)
```

Any failure stops before Docker build. Publishing must not infer success from an in-image sample smoke.

## Published base is the only derived input

`base build` may be used to inspect a base image itself, but a downstream/derived project must never build
against that local tag. A same-named local image hides registry drift and defeats reproducibility.

The old workflow “build the base locally, then let a derived build resolve the local tag” is prohibited.
After changing a base input, rebuild and publish the affected tag, then make consumers pull that
published copy.

## Immutable pull and digest target

The human-facing tag remains a discovery pointer, not a build identity. A derived build must:

1. authenticate if needed and explicitly pull the published tag;
2. resolve the repository digest returned by the registry;
3. use `repository@sha256:<digest>` as `BASE_IMAGE`;
4. record the digest and resolved tool-input manifest in build output/provenance;
5. reject a tag-only or local-only base.

Pseudocode:

```text
pull docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64
resolve -> docker.io/tuee22/hostbootstrap@sha256:...
docker build --build-arg BASE_IMAGE=docker.io/tuee22/hostbootstrap@sha256:...
```

The current demo builder passes a mutable tag and omits `--pull`, so this target is open.

## Publish atomicity and evidence

Current `build-and-push` pushes each mutable tag as soon as its build completes. There is no multi-tag
transaction, signed provenance record, or post-push digest handoff to consumers. The target publication
record includes:

- source revision supplied by the human release process;
- architecture/flavor;
- Dockerfile and warm-store input fingerprint;
- fully resolved base/tool manifest and checksums;
- pushed repository digest;
- preflight results.

No claim of immutability should be based on the mutable tag alone.

## Validation

- A test seeds a conflicting local tag and proves the derived builder still selects the registry digest.
- A tag republish changes the resolved digest and the consumer records the new value.
- A failed Haskell gate proves Docker build/push were not invoked.
- Download/base digest mismatch fails before executing or installing the artifact.

Release status and which tags require publication belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).
