# Haskell Dependency Patches

**Status**: Supporting reference
**Supersedes**: prior README without metadata
**Referenced by**: [../../../documents/engineering/warm_store.md](../../../documents/engineering/warm_store.md)

> **Purpose**: State when a dependency patch belongs here and how one takes effect.

Nothing applies a file placed in this directory. A patch takes effect only as a vendored package
directory named in `core/warm-deps/cabal.project` `packages:`, which the base Dockerfile's existing
`COPY core/warm-deps/` carries into the build.

Add a vendored package here only when upstream Hackage bounds or releases cannot build with GHC 9.12.4.
On GHC 9.12.4 the shared dependency set resolves from Hackage without blanket `allow-newer`, so this
should be rare. Prefer a small checked-in vendored package over an external source override, and remove it
once upstream releases catch up.
