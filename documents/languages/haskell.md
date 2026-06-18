# Haskell

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/warm_store.md](../engineering/warm_store.md), [../engineering/code_check_doctrine.md](../engineering/code_check_doctrine.md), [../engineering/linking_and_optimization.md](../engineering/linking_and_optimization.md)

> **Purpose**: Document the Haskell toolchain the base image ships and how derived projects build
> against it.

This page documents what the base image ships for Haskell.

The base image ships a **single GHC** — 9.12.4 — with Cabal 3.16.1.0 and a
warm Cabal store. The plan retires the previous dual-GHC arrangement
(formatter-only GHC plus project GHC) because `fourmolu`/`hlint`'s
`ghc-lib-parser` targets 9.12, so one compiler now serves both formatting and
project builds.

## Warm store

[`core/warm-deps/`](../../core/warm-deps/) declares the shared
dependency set. The base image builds it with
`--enable-tests --enable-benchmarks --enable-shared` at `-O2`, pinned via the layered
`core.freeze` / `daemon.freeze`, so
downstream projects following the warm-store cache-hit contract skip the
entire third-party build closure. See
[engineering/warm_store.md](../engineering/warm_store.md) for the contract and
the dep-addition workflow.

## fourmolu / hlint

Both are prebuilt into the base image at
`/opt/hostbootstrap/haskell-style/bin/`:

* `fourmolu-0.19.0.1`
* `hlint-3.10`

`/usr/local/bin/fourmolu` and `/usr/local/bin/hlint` are symlinks to that
pinned directory. They are **container-only**: never installed, built, or run
on the host.

The base image smoke-tests both binaries during its own build (see
[engineering/code_check_doctrine.md](../engineering/code_check_doctrine.md));
derived projects invoke them via their own `<project> check-code` command as a
`RUN` step in the project Dockerfile.

## Editor support (HLS)

The repository is a multi-workspace Cabal layout with no project file at the root, so each Cabal
workspace carries its own `hie.yaml` cradle. This lets the Haskell Language Server provide hover,
go-to-definition, and diagnostics for every `.hs` file even when the repository root is opened as the
editor workspace. See the cradle table in
[engineering/cabal_layout.md](../engineering/cabal_layout.md#editor-and-hls-cradles).

## Project standardisation

All downstream projects standardise on GHC 9.12 as part of adopting
hostbootstrap. See
[engineering/derived_project_standards.md](../engineering/derived_project_standards.md)
for the full rule set every derived project follows, including the canonical
`cabal.project` template and the linking/optimisation policy in
[engineering/linking_and_optimization.md](../engineering/linking_and_optimization.md).
