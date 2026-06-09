# Warm store

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [base_image.md](base_image.md), [derived_project_standards.md](derived_project_standards.md), [linking_and_optimization.md](linking_and_optimization.md), [../languages/haskell.md](../languages/haskell.md)

> **Purpose**: Define the warm Cabal store contents — including `hostbootstrap-core`'s dependency
> closure — the cache-hit contract derived projects rely on, and the dep-addition workflow.

The base image ships a **pre-built Cabal store** at `/opt/cache/cabal/`. Every
package listed in
[`haskell/haskell-deps/basecontainer-haskell-deps.cabal`](../../haskell/haskell-deps/basecontainer-haskell-deps.cabal)
is compiled at base-image build time, in the configurations downstream projects
actually use, then frozen via
`haskell/haskell-deps/cabal.project.freeze`
so the registry copy of each base tag pins the exact versions baked in.

The frozen closure **includes `hostbootstrap-core`'s own transitive dependencies** (notably
`optparse-applicative` and the Dhall and process libraries the core uses), so a project binary that
extends `hostbootstrap-core` via `runHostBootstrapCLI` hits the warm store for the core's
dependencies, not only its own. The `hostbootstrap-core` dependency set is part of
`cabal.project.freeze` and is treated like any other warm-store dependency for cache-hit purposes.

This page is the contract between the warm store and derived projects: follow
it and `cabal build` skips the dependency closure; deviate and Cabal silently
rebuilds packages that look pre-built but have a different store key.

## What the warm store ships

For every package in
[`basecontainer-haskell-deps.cabal`](../../haskell/haskell-deps/basecontainer-haskell-deps.cabal):

* Compiled under **GHC 9.12.4** with Cabal 3.16.1.0.
* Built with `--enable-tests --enable-benchmarks --enable-shared`, so the
  vanilla, profiling, **and** dynamic (`dyn`) ways are all in the store.
* Compiled at **`-O2`** (`optimization: 2` in
  [`haskell/haskell-deps/cabal.project`](../../haskell/haskell-deps/cabal.project)).
* Pinned to the versions in
  `haskell/haskell-deps/cabal.project.freeze`.

`fourmolu 0.19.0.1` and `hlint 3.10` are also baked in
(see [base_image.md](base_image.md) and [code_check_doctrine.md](code_check_doctrine.md)).

## The cache-hit contract

A derived project's `cabal build` reuses the warm store **iff** all of the
following hold:

1. **Same compiler.** `with-compiler: ghc-9.12.4` in the project's
   `cabal.project`. A different GHC produces a different store key for every
   package.
2. **Flag subset.** The project's enabled-flag set is a subset of
   `tests + benchmarks + shared`. Enabling something the warm store didn't enable
   (an exotic Cabal flag, a custom `cpp-options`, …) silently triggers a rebuild
   for that package and everything that depends on it.
3. **Same optimisation level.** Project uses `optimization: 2`. Asking for `-O1`
   or `-O0` does not "downgrade" — Cabal treats it as a different configuration
   and rebuilds.
4. **Same resolved versions.** The project's dependency resolver picks the same
   versions as those pinned in `cabal.project.freeze`. Tight upper bounds in a
   project's `*.cabal` that disagree with the freeze cause cabal to rebuild the
   conflicting package against the project's preferred version.

If any condition is violated for a given package, **only that package and its
transitive consumers in the project's build** are rebuilt — the warm store is
not corrupted, it just stops being used for that subtree.

## Recommended project `cabal.project`

The minimal compliant template for a derived project:

```cabal
packages: .

with-compiler: ghc-9.12.4

import: /opt/basecontainer/haskell-deps/cabal.project.freeze

tests: True
benchmarks: True
shared: True

optimization: 2
```

The `import:` line is the cache-hit guarantee — see
[Required: import the freeze file](#required-import-the-freeze-file) below.
The rest matches the warm-store flag set verbatim. Adding `allow-newer:` or
source-repository-package stanzas is fine as long as the resolver still
lands on versions compatible with the imported freeze; if it cannot, Cabal
fails with a clear error.

## Required: import the freeze file

The warm store and the derived project **must use the same
`cabal.project.freeze`** or the resolver will pick different versions of
transitive dependencies (microlens, statistics, vty-unix, …) and Cabal will
rebuild every package whose store key differs.

Derived projects MUST NOT commit a `cabal.project.freeze` of their own.
Instead, the project's `cabal.project` **imports** the freeze that ships in
the base image:

```cabal
import: /opt/basecontainer/haskell-deps/cabal.project.freeze
```

That one line is the whole sync mechanism. No copy step, no
"remember to refresh when the base updates," no two-repo drift.

Why this works:

* The base image bakes
  `haskell/haskell-deps/cabal.project.freeze`
  into `/opt/basecontainer/haskell-deps/cabal.project.freeze` (via the
  `COPY haskell/haskell-deps/` step in the base Dockerfile). Every
  `basecontainer-<flavor>-<arch>` tag carries one specific freeze, frozen at
  the moment the base was built.
* The binary is built **host-native** on every substrate, where the freeze is read
  through the project's `import:` line resolved against the host toolchain. When the
  binary later builds the project container `FROM` the base image, the same freeze at
  `/opt/basecontainer/haskell-deps/cabal.project.freeze` is present in the image at the
  point Cabal reads `cabal.project` and the absolute path resolves. How the host-native
  build reaches the same warm store is detailed in [base_image.md](base_image.md); either
  way the project commits no freeze of its own. See [base_image.md](base_image.md) for the
  host-native build model.
* When `hostbootstrap base build-and-push` ships a new base tag with a
  refreshed warm store, the derived project's next container build
  automatically picks up the new freeze. Nothing in the derived project
  needs to change.
* If a derived project's own `*.cabal` constrains a package to a version
  incompatible with the freeze, Cabal errors out clearly with "could not
  satisfy" — the right behaviour. The project then either bumps its own
  bound, or the warm-store manifest is updated and a new base tag cut. The
  conflict is loud, not silent.

> **WRONG**
>
> Project `cabal.project`:
>
> ```cabal
> packages: .
> with-compiler: ghc-9.12.4
> tests: True
> benchmarks: True
> shared: True
> optimization: 2
> ```
>
> Project repo also contains a committed `cabal.project.freeze`, copied once
> from the base image and now drifting.
>
> The freeze in the project lags behind the base image's. Cabal resolves
> against the project's stale freeze, store keys diverge from the warm
> store, every third-party package rebuilds.
>
> **RIGHT**
>
> Project `cabal.project`:
>
> ```cabal
> packages: .
> with-compiler: ghc-9.12.4
> import: /opt/basecontainer/haskell-deps/cabal.project.freeze
> tests: True
> benchmarks: True
> shared: True
> optimization: 2
> ```
>
> No `cabal.project.freeze` in the project repo. The import resolves at
> build time to whatever freeze the current base image ships. Cache hits
> are automatic.

## How to add a dep to the warm store

Adding a new dep is a one-PR loop:

1. **Edit the manifest.** Add the package alphabetically to `build-depends:` in
   [`haskell/haskell-deps/basecontainer-haskell-deps.cabal`](../../haskell/haskell-deps/basecontainer-haskell-deps.cabal).
2. **Regenerate the freeze.** Inside a fresh base container (or after a local
   rebuild), run `cabal freeze` against the warm-store project and commit the
   updated `cabal.project.freeze`.
3. **Rebuild and push every base tag.** Use the canonical publish workflow in
   [build_release.md](build_release.md):

   ```sh
   hostbootstrap base build-and-push --arch amd64
   hostbootstrap base build-and-push --arch arm64
   ```

The freeze file is the **SSoT for "what versions ship with each base tag"**.
Treat it as a public API.

## How to verify your project hits the cache

Inside a project container (after `hostbootstrap build`), run:

```sh
cabal build --dry-run --enable-tests --enable-benchmarks all
```

The build plan should show **only the project's own** library, executable,
test-suite, and benchmark targets in "Compiling …" status. If any third-party
package appears in the plan with `(requires build)`, the warm store missed it.

Most common causes, in order of likelihood:

1. The project's `cabal.project` does not match the canonical template (a flag
   missing, `optimization` not set to `2`).
2. The project's `*.cabal` has an upper bound that conflicts with the freeze.
3. The package is genuinely not in the warm store — open a PR adding it to
   [`basecontainer-haskell-deps.cabal`](../../haskell/haskell-deps/basecontainer-haskell-deps.cabal).

## WRONG vs RIGHT

> **WRONG**
>
> Project `cabal.project`:
>
> ```cabal
> packages: .
> with-compiler: ghc-9.12.4
> ```
>
> Project `docker/Dockerfile`:
>
> ```dockerfile
> RUN cabal build --enable-tests --enable-benchmarks all
> ```
>
> The Dockerfile enables tests/benchmarks but the `cabal.project` does not, so
> Cabal store keys for the deps include `tests=True` while the warm store does
> not. Every test-using package rebuilds.
>
> **RIGHT**
>
> Project `cabal.project`:
>
> ```cabal
> packages: .
> with-compiler: ghc-9.12.4
> tests: True
> benchmarks: True
> shared: True
> optimization: 2
> ```
>
> Project `docker/Dockerfile`:
>
> ```dockerfile
> RUN cabal build all
> ```
>
> Flags live in one place; the Dockerfile invocation does not need to repeat
> them; warm-store cache keys match. `cabal build --dry-run` shows only the
> project's own targets.

## See also

* [base_image.md](base_image.md) — what else ships in the base
* [languages/haskell.md](../languages/haskell.md) — Haskell-specific overview
* [code_check_doctrine.md](code_check_doctrine.md) — build-time code-check
* [linking_and_optimization.md](linking_and_optimization.md) — why `-O2` and
  `shared`
* [derived_project_standards.md](derived_project_standards.md) — the
  derived-project rule set
