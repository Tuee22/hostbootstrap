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
- cache misses may update the package index, download dependencies, and compile them;
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

`warm-store.config` aligns commonly useful compilation ways: tests, benchmarks, shared libraries, and
optimization level 2. Matching these settings improves cache reuse, but no consumer is required to keep
them merely to satisfy the base.

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
Source quality and successful real-consumer build are the acceptance gates.

The host-native Python bootstrap uses its repository-local store under `.build/cabal-store/`; the base
cache exists only inside the Linux image. That difference does not require different project files.

## Adding or updating cached dependencies

1. Add the dependency alphabetically to the most descriptive manifest package.
2. Validate the single warm-store project and the normal consumer project.
3. With operator authorization, rebuild and publish the affected rolling native tags.
4. Pull the published tag and run the real demo compatibility smoke.

There is no freeze generation or commit step. A rebuild may select newer compatible transitive
dependencies than the prior publication.

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
COPY demo /workspace/demo
WORKDIR /workspace/demo
RUN cabal build all
```

The right form lets Cabal reuse matching inherited artifacts and recover gracefully when the cache
misses.

## Validation

Focused tests enforce one consumer project, absence of project swapping/base freeze imports, and absence
of forced offline solving. The normal Python and fast core/demo Haskell gates validate source and solver
compatibility. A registry publication/live compatibility smoke remains an explicit operator workflow,
not a synthetic offline proof.

## See also

- [Base image](base_image.md)
- [Build and release](build_release.md)
- [Cabal layout](cabal_layout.md)
- [Derived Dockerfile](derived_dockerfile.md)
