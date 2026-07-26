# Build and Release

**Status**: Authoritative source
**Supersedes**: immutable-input and synthetic offline base validation
**Referenced by**: [documents index](../README.md), [base image](base_image.md),
[warm store](warm_store.md), [derived Dockerfile](derived_dockerfile.md)

> **Purpose**: Define the native rolling-base publish workflow and its real-consumer compatibility
> smoke.

## Workflow

Maintainers publish one native architecture at a time:

```sh
poetry run hostbootstrap base build-and-push --arch amd64
```

Run the arm64 form on a native arm64 host and Docker engine. The CLI rejects request/host/engine
architecture disagreement before source gates or Docker work. `--flavor` narrows to CPU or CUDA;
otherwise independent flavors may build concurrently unless `--sequential` is supplied.

For each selected flavor the workflow:

1. discovers current compatible upstream versions and URLs;
2. runs the complete Python/core/demo source preflight;
3. cold-builds the rolling tag with plain native `docker build`;
4. pushes the rolling tag;
5. pulls that published tag so a same-named local image cannot mask registry state;
6. resolves the pulled repository digest as an identifier for this workflow;
7. cold-builds the real `demo/docker/Dockerfile` with that pulled base as a compatibility smoke.

Buildx, emulation, and multi-architecture manifest lists are outside this workflow.

## Source preflight

Before any build or push:

```text
Python code check
Python tests and configured coverage threshold
core Cabal build/test with -Werror
demo Cabal build/test with -Werror
```

Any failure stops before registry mutation. The in-image Fourmolu/HLint sample check verifies the
rolling tools themselves and does not replace source preflight.

## Rolling selection and evidence

The published tag is the consumer discovery reference and intentionally moves. The source tree contains
no base-input lock. Rebuilding the same revision can select newer compatible parents, toolchains, and
packages.

A digest is still useful to identify the exact artifact just pulled and to bind the subsequent smoke
against a registry result rather than a stale local tag. That use does not make the digest a permanent
consumer pin and does not turn dynamic inputs into reproducibility evidence.

The compatibility smoke uses the real demo project and its ordinary `cabal.project`. It may download and
compile cache misses. It proves that the publication can build the consumer, not that the store is
complete or the build is offline.

## Local inspection versus publication

`hostbootstrap base build` may build a local image for inspection. Derived validation of the published
source of truth follows an operator-authorized `build-and-push`, explicit pull, and real-consumer smoke.
Do not silently substitute a same-named local base.

Publishing mutates Docker Hub and requires explicit user authorization. A requested documentation/code
change alone does not authorize it.

## Evidence and partial failure

Output records selected versions, architecture/flavor, pushed tag, pulled digest, source-gate results,
and compatibility-smoke result. These identify what happened in that run; no committed replay manifest
is produced.

Each flavor is pushed after its build succeeds. There is no multi-tag transaction. If one flavor fails,
report which rolling tags changed and which compatibility smokes completed; do not describe the whole
set as atomic.

## Validation

Unit seams cover:

- architecture mismatch before mutation;
- dynamic resolver output feeding build arguments;
- source-gate failure before Docker build/push;
- build → push → pull → digest identification → real-demo smoke ordering;
- the smoke's use of the real Dockerfile and ordinary online consumer project.

Live publication evidence belongs in the owning development-plan sprint.
