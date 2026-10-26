# Warm store

**Status**: Authoritative source
**Supersedes**: the layered `core.freeze` / `daemon.freeze` consumer contract
**Referenced by**: [base_image.md](base_image.md),
[derived_project_standards.md](derived_project_standards.md),
[linking_and_optimization.md](linking_and_optimization.md),
[../languages/haskell.md](../languages/haskell.md)

> **Purpose**: Define the base image's best-effort Cabal cache, the one-project consumer rule, and the
> dependency-addition workflow.

## Contract

The base image contains a pre-built Cabal store at `/opt/cache/cabal/`. It is a performance cache only:

- consumers do not import base-owned freezes or project fragments;
- the store does not prescribe package versions;
- matching artifacts may be reused;
- cache misses solve, download dependencies, and compile them against the package index the base's
  `cabal update` fetched; `cabal build` does not refresh that index, so a consumer needing a newer release
  runs `cabal update` (or sets its own `index-state`) in its own Dockerfile;
- offline builds and complete cache hits are not acceptance requirements.

Every consumer uses one ordinary host-compatible `cabal.project` both host-native and in its derived
container. A Dockerfile copies the project source and runs Cabal; it does not replace `cabal.project`
with a container-only variant.

## Population inputs

[`core/warm-deps/cabal.project`](../../core/warm-deps/cabal.project) is the only warm-store Cabal project.
It builds two organizational manifest packages into one store:

- `core/basecontainer-core-deps.cabal` covers the `hostbootstrap-core` closure and shared web-build
  dependencies such as `purescript-bridge`, `warp`, `wai`, and `network`;
- `daemon/basecontainer-daemon-deps.cabal` covers additional daemon-family dependencies such as Redis,
  PostgreSQL, protobuf, and secure WebSocket clients.

These groups make the manifest maintainable. They are not consumer layers and do not produce separate
solver fragments. The build-only executables exist solely to make Cabal compile the listed dependency
sets.

`warm-store.config` sets `tests`, `benchmarks`, `shared`, and `optimization: 2` at the top level of the
warm-store project. Top-level package options in a Cabal project apply only to that project's local
packages, which here are the two manifest packages; they do not reach the dependencies cached in the
store, which build with Cabal's per-package defaults. A consumer's own top-level settings, such as the
`optimization: 2` in `core/cabal.project` and `demo/cabal.project`, likewise reach only its local packages,
so its dependencies are planned with the same defaults the store holds. A consumer therefore neither needs
nor gains cache reuse by copying these settings.

## Consumer project

The demo's single project illustrates the supported form:

```cabal
packages:
  hostbootstrap-demo.cabal
  ../core/hostbootstrap-core/hostbootstrap-core.cabal

optimization: 2
```

The same file is valid on the host and in `/workspace/demo` because both package paths exist in those
layouts. It contains no `/opt/basecontainer` path, no base freeze import, and no rolling-base version
pin. A consumer remains free to add its own ordinary Cabal constraints for product reasons; those
constraints belong to the consumer, not the warm-store API.

## Cache behavior

Cabal store keys include compiler, package version, flags, optimization, and build way. Reuse occurs only
when the consumer's selected plan matches an inherited artifact. A different current solver result,
consumer flag, or compiler is a normal miss, not an error in the base-image contract.

`cabal build --dry-run` may be used to observe likely reuse. Its output is diagnostic only. A third-party
package marked for build is allowed, and an online derived build must be able to resolve and compile it.
Source quality and a real consumer's resolvable build plan are the publication gates.

The host-native Python bootstrap uses its repository-local store under `.build/cabal-store/`; the base
cache exists only inside the Linux image. That difference does not require different project files.

## Adding or updating cached dependencies

1. Add the dependency alphabetically to the most descriptive manifest package.
2. Validate the single warm-store project and the normal consumer project.
3. Rebuild and publish the affected rolling native tags; agents do this as required.
4. Pull the published tag and run the dedicated real-consumer compatibility smoke. That smoke resolves a
   consumer package it writes itself, not this manifest: resolving the manifest would re-resolve the
   description whose resolution produced the store, which proves nothing about a project that builds
   `FROM` the publication.

There is no freeze generation or commit step. A rebuild may select newer compatible transitive
dependencies than the prior publication.

A publication runs the compatibility consumer twice: against the newly built immutable local image ID
before publication, and against the pulled digest afterward. Each run passes when
`cabal build --dry-run all` resolves a complete build plan; the plan may list builds or downloads, because
the consumer is a package the store has never built (see [base image](base_image.md#republishing)).
The dated publication and that digest belong to the
[base-image-publication-and-opportunistic-warm-store phase](../../DEVELOPMENT_PLAN/phase-23-base-image-and-warm-store.md).

## Wrong and right

Wrong:

```cabal
import: /opt/basecontainer/haskell-deps/some-freeze
```

Wrong:

```dockerfile
RUN cp docker/special-container-project cabal.project
RUN cabal build --offline all
```

Right:

```dockerfile
COPY core/hostbootstrap-core /workspace/core/hostbootstrap-core
COPY demo /workspace/demo
WORKDIR /workspace/demo
RUN cabal build all
```

The right form lets Cabal reuse matching inherited artifacts and recover gracefully when the cache
misses.

## Validation

Focused tests enforce one consumer project, absence of project swapping/base freeze imports, and absence
of forced offline solving. The normal Python and fast core/demo Haskell gates validate source and solver
compatibility. A registry publication/live compatibility smoke remains a deliberate live workflow that
agents run as required, not a synthetic offline proof.

## See also

- [Base image](base_image.md)
- [Build and release](build_release.md)
- [Cabal layout](cabal_layout.md)
- [Derived Dockerfile](derived_dockerfile.md)
