# Linking and optimisation

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [warm_store.md](warm_store.md), [derived_project_standards.md](derived_project_standards.md), [../languages/haskell.md](../languages/haskell.md)

> **Purpose**: Give the authoritative recommendation for how derived Haskell projects link and
> optimise so they match the warm store and get cache hits.

This page is the authoritative recommendation for **how derived projects link
and optimise their Haskell code**. The defaults are tuned for the
performance-sensitive projects this base image targets (search, inference,
JIT compilation) rather than for distribution size.

## Recommended policy

* **Executables link statically.** Do not pass `--enable-executable-dynamic`.
  Default Cabal exe linkage is static against the project's library archives —
  keep it.
* **Libraries ship both vanilla and dyn ways in the Cabal store.** Set
  `shared: True` in the project's `cabal.project`; the warm store already does
  this, and matching the warm store gives cache hits.
* **Standardise on `-O2`.** Set `optimization: 2` in `cabal.project`. Apply
  `-O2` in the library and executable stanzas' `ghc-options` so the project's
  own modules also benefit.
* **Use `INLINABLE` / `SPECIALISE` on hot polymorphic exports.** This is the
  biggest perf lever in Haskell — and it is independent of linkage. See
  ["Inlining is the bigger lever"](#inlining-is-the-bigger-lever) below.

## Why static for executables

Static linkage gives:

* No PLT/GOT indirection on cross-package calls.
* Faster startup — no `dlopen` cascade.
* Aggressive dead-code elimination at link time.

The cost is binary size, which does not matter for projects that run inside
the container they were built in. For tight cross-package hot loops the
runtime gap from static → dynamic is in the few-percent range; for normal
business logic it is in the noise.

## Why ship the dyn way in the store

Template Haskell, `hint`-style runtime evaluation, and `ghci` all need
`.so`/`.dylib` versions of every loaded library. Pre-building the dyn way in
the warm store removes a class of surprise rebuilds when a project pulls in
TH-heavy libraries (`brick`, `aeson` with `deriving`, `proto-lens`,
`postgresql-simple`).

The warm store is built with `--enable-shared`, so the `dyn` way exists for
every cached package. A project enabling `shared: True` in its `cabal.project`
matches the warm store's store keys and gets cache hits; a project leaving it
off rebuilds the dyn way of any TH-using package.

## Why `-O2`

GHC's `-O1` (the cabal default) is conservative on cross-module inlining. For
projects with:

* Polymorphic hot paths (search code that dispatches on backend interfaces),
* Monomorphic numeric kernels (BLAS-shaped Haskell loops),
* Heavy use of typeclass dictionaries that should be specialised at the call
  site,

`-O2` produces measurably faster code, often by ≥10% on the relevant
microbenchmarks. The warm store builds at `-O2`, so a project also building
at `-O2` is the cache-friendly path. A project at `-O1` rebuilds every
package against `-O1` and pays for it.

## Inlining is the bigger lever

GHC's cross-module inliner uses unfoldings written to `.hi` interface files by
the upstream module. To expose unfoldings to downstream code, the upstream
must annotate them:

```haskell
{-# INLINABLE searchOne #-}
searchOne :: (Backend b, MonadIO m) => Config -> b -> m Result
searchOne cfg b = ...

{-# SPECIALISE searchOne :: Config -> CppBackend -> IO Result #-}
{-# SPECIALISE searchOne :: Config -> RustBackend -> IO Result #-}
```

`INLINABLE` exposes the function's full unfolding; `SPECIALISE` pre-computes
a monomorphic copy at known instantiations. Downstream code calling
`searchOne cfg myCppBackend` gets the specialised path with no dictionary
indirection and full call-site inlining.

This is **independent of linking**. A statically-linked `-O2` executable
without `INLINABLE` on hot polymorphic exports leaves more performance on
the table than the entire static-vs-dynamic difference. Audit hot modules
for the pattern; add it where measured.

## What NOT to do

* **Don't pass `--enable-executable-static`.** It requires a musl-based
  system or a fully-static system C library; the base image is glibc.
  The flag silently produces a partially-static binary that breaks DNS,
  PAM, locale, and NSS in production-shaped containers.
* **Don't enable `--enable-split-sections` for the warm store.** Interacts
  poorly with Template Haskell loading at runtime; symbol-not-found
  surprises. The warm store does not use it; do not opt in downstream.
* **Add `-fllvm` only after measuring it helps.** The LLVM backend compiles
  2–3× slower than the NCG and produces faster code only on numeric
  workloads. For projects where most modules are numeric kernels (search,
  numerical linear algebra, JIT codegen) blanket `-fllvm` on the library and
  executable is fine; for mixed projects apply per-module via
  `{-# OPTIONS_GHC -fllvm #-}`. Never enable it without a measurement to
  point at.
* **`-fexpose-all-unfoldings` is a real choice, not a default.** It bloats
  every `.hi` file and inflates downstream compile times. Worth it for
  libraries whose hot paths cross many module boundaries; otherwise prefer
  targeted `INLINABLE`.

## Project-specific notes

* **MCTS:** the four foreign backends (`cpp-legacy`, `cpp-imperative`,
  `cpp-functional`, `rust`) apply PGO + LLVM BOLT in their own build
  pipelines. The Haskell library and executable already use the full
  numeric-tuned set (`-O2 -funbox-strict-fields -fspecialise-aggressively
  -fexpose-all-unfoldings -flate-dmd-anal -fmax-simplifier-iterations=20
  -fworker-wrapper -fstatic-argument-transformation -fllvm`) — a deliberate
  choice because almost every module is a hot kernel for the search loop.
  This is the measured-and-justified case for blanket `-fllvm`. New Haskell
  modules under `MCTS.*` should add `INLINABLE` to any polymorphic exports
  that participate in the inner search loop.
* **jitML:** the migration to GHC 9.12 also relaxes `base >=4.22` to
  `base >=4.18`; once on 9.12 the project should adopt the canonical
  `cabal.project` template from
  [warm_store.md](warm_store.md#recommended-project-cabalproject) and audit
  hot numeric modules for `-fllvm` opportunities.

## See also

* [warm_store.md](warm_store.md) — the cache-hit contract; flags here must
  match it
* [languages/haskell.md](../languages/haskell.md) — GHC version, fourmolu /
  hlint pins
* [derived_project_standards.md](derived_project_standards.md) — the
  derived-project rule set
