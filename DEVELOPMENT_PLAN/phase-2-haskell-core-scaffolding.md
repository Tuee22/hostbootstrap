# Phase 2 — Haskell core scaffolding

**Status**: Done
**Depends on**: Phase 1 (Python pre-binary floor)
**Substrates**: none (static)
**Gate**: `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Establish the `hostbootstrap-core` package, its pinned compiler, and the generic CLI
> entrypoint every consuming project binary is built from.

## Phase Objective

Create the library that owns everything after the pre-binary floor: one Cabal package, one pinned GHC, one
warm-store-compatible optimisation level, and one entrypoint a project binary calls to inherit the fixed
command tree. Nothing here knows about hosts, providers, or lifecycles — it is the shell the rest is built
inside.

## Sprints

### Sprint 2.1: The Cabal package and compiler pin [Done]

**Status**: Done
**Implementation**: `core/cabal.project`, `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hie.yaml`
**Substrates**: none
**Docs to update**: `documents/engineering/cabal_layout.md`

#### Objective

One self-contained Haskell workspace with a pinned toolchain.

#### Deliverables

- `core/cabal.project` names the single package and pins `with-compiler: ghc-9.12.4`.
- `optimization: 2` matches the warm Cabal store baked into the base image, so derived builds reuse the
  pre-built dependency unfoldings.
- The package declares a library, an executable (`hostbootstrap`), and one test suite.
- `-Werror` is supplied by the gate rather than baked into the package, so a warm tree cannot hide a
  warning the clean gate would catch.
- The same `cabal.project` is used host-native and inside the derived container; there is no
  container-only project file and no base-owned freeze import.

#### Validation

`cabal build all` and `cabal test all --ghc-options=-Werror` from `core/`.

#### Remaining Work

None.

### Sprint 2.2: The generic CLI entrypoint [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/app/Main.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Give a project binary one function to call, and give the bare library binary its own.

#### Deliverables

- `runHostBootstrapCLI` is the entrypoint a consuming project binary calls; it supplies the fixed command
  tree and dispatches into the project's own extension streams.
- `runBareHostBootstrapCLI` is the separate entrypoint for `hostbootstrap-core`'s own executable, which
  carries no installed project config family.
- The two are distinct functions rather than one function with a mode flag, so a bare invocation cannot
  present itself as a project.
- Argument parsing is `optparse`-based and the command tree is closed at this layer.

#### Validation

`CLISpec` covers dispatch for each verb and the bare-versus-project entrypoint distinction.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — the library's surfaced command tree and the two
  entrypoints.

**Engineering docs to create/update:**
- `documents/engineering/cabal_layout.md` — the workspace layout, compiler pin, and optimisation level.

**Cross-references to add:**
- root `README.md` names the repository layout.
- `CLAUDE.md` and `AGENTS.md` name the `core/`-rooted build and test commands.
