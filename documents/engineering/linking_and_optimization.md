# Linking and optimisation

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [warm_store.md](warm_store.md), [derived_project_standards.md](derived_project_standards.md), [../languages/haskell.md](../languages/haskell.md)

> **Purpose**: Explain the linking and optimisation defaults derived Haskell projects follow for the
> repository's workloads, and why those defaults do not decide opportunistic warm-store reuse.

This page is the supporting rationale for **how derived projects link and
optimise their Haskell code**. The linkage rule itself is rule 4 of
[derived_project_standards.md](derived_project_standards.md#the-rules), which
wins where the two differ. The defaults are tuned for the
performance-sensitive projects this base image targets (search, inference,
JIT compilation) rather than for distribution size.

## Recommended policy

* **Executables link statically.** Do not pass `--enable-executable-dynamic`.
  Default Cabal exe linkage is static against the project's library archives —
  keep it.
* **Local libraries build both vanilla and dyn ways.** Setting
  `shared: True` in the project's `cabal.project` is recommended, as the
  [compliant template](derived_project_standards.md#worked-compliant-dockerfile-and-cabalproject)
  does. As a top-level option it reaches only the project's local packages, so
  it does not change warm-store reuse (see
  ["Why build the dyn way"](#why-build-the-dyn-way)). It is not a requirement:
  the worked demo's project omits it.
* **Standardise on `-O2`.** Set `optimization: 2` in `cabal.project`. That
  setting compiles the project's own local packages at `-O2`, so the `.cabal`
  stanzas need no `-O2` in `ghc-options` (which would also override a
  developer's `-O0` for fast iteration); the repository's own packages carry
  none.
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

## Why build the dyn way

Template Haskell, `hint`-style runtime evaluation, and `ghci` all need
`.so`/`.dylib` versions of every loaded library. `shared: True` builds that
way for the project's own libraries alongside the vanilla way.

The warm store sets `shared: True` at the top level of
[`core/warm-deps/warm-store.config`](../../core/warm-deps/warm-store.config).
Top-level package options in a Cabal project reach only that project's local
packages, so that setting builds the dyn way of the warm store's own manifest
packages, not of the dependencies cached in the store, which build with Cabal's
per-package defaults. A project's own top-level `shared: True` likewise builds
the dyn way of its local packages and does not decide whether store
dependencies are reused (see [warm_store.md](warm_store.md)).

## Why `-O2`

GHC's `-O1` (the cabal default) is conservative on cross-module inlining. For
projects with:

* Polymorphic hot paths (search code that dispatches on backend interfaces),
* Monomorphic numeric kernels (BLAS-shaped Haskell loops),
* Heavy use of typeclass dictionaries that should be specialised at the call
  site,

`-O2` produces measurably faster code, often by ≥10% on the relevant
microbenchmarks. The choice is about the project's own code, not about cache
reuse. The top-level `optimization: 2` in
[`core/warm-deps/warm-store.config`](../../core/warm-deps/warm-store.config)
reaches only the warm store's own manifest packages; the dependencies cached in
the store build at Cabal's per-package default. A consumer's top-level
`optimization` likewise reaches only its local packages, so a project's
optimisation level does not decide whether store dependencies are reused (see
[warm_store.md](warm_store.md)).

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

## Project-specific tuning

A project whose modules are almost all hot numeric kernels (a search loop,
for example) can justify a blanket numeric-tuned flag set — `-O2` with
aggressive specialisation, exposed unfoldings, and `-fllvm` on the library and
executable — and is the measured case for blanket `-fllvm`. Such a project
records its flag set and the measurement behind it in its own repository;
this page does not track other projects' builds. Any project with polymorphic
exports on its inner loop adds `INLINABLE` to them, as described above.

## See also

* [warm_store.md](warm_store.md) — the cache-hit contract; a project's
  top-level flags here reach only its local packages, so they are not what
  store reuse depends on
* [languages/haskell.md](../languages/haskell.md) — GHC version, fourmolu /
  hlint pins
* [derived_project_standards.md](derived_project_standards.md) — the
  derived-project rule set
