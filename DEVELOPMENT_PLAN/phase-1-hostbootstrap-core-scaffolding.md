# Phase 1: hostbootstrap-core Scaffolding

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-0-documentation-and-governance.md](phase-0-documentation-and-governance.md), [phase-2-host-tools-and-config.md](phase-2-host-tools-and-config.md)

> **Purpose**: Stand up the `hostbootstrap-core` Cabal package, the bare executable, the
> optparse/dhall dependency surface, and the generic `runHostBootstrapCLI` entrypoint so later phases
> have a buildable place to land host-management logic.

## Phase Status

**Status**: Done

The `hostbootstrap-core` Cabal package exists, pinned to the base-image GHC toolchain, with the
`HostBootstrap.*` module surface, the bare `hostbootstrap` executable, and the generic
`runHostBootstrapCLI` project entrypoint over a buildable command tree. `cabal build all` and `cabal
test` pass, and `hostbootstrap --help` exits 0. Later phases own the host-management logic exposed
through this package boundary.

## Phase Objective

Create `hostbootstrap-core` as a Cabal package: a `library` stanza for the `HostBootstrap.*` module
surface and a bare `hostbootstrap` executable. Pin GHC to the base-image toolchain, take
`optparse-applicative` and `dhall` as dependencies, and expose the project entrypoint
`runHostBootstrapCLI progName projectSpec` over a buildable command tree plus
`runBareHostBootstrapCLI` for the bare core executable. Phase 1 owns the structural package shell; later
phases own the concrete host-management behavior.

## Sprints

### Sprint 1.1: Cabal package + GHC pin [Done]

**Status**: Done
**Implementation**: `core/cabal.project`, `core/hostbootstrap-core/hostbootstrap-core.cabal`
**Docs to update**: `documents/engineering/cabal_layout.md`, `system-components.md`

#### Objective

Create the `hostbootstrap-core` Cabal package with a `library` stanza and a bare executable
stanza, pinned to the base-image GHC toolchain.

#### Deliverables

- `hostbootstrap-core.cabal` with one `library` stanza (`HostBootstrap.*` exposed modules) and one
  `executable hostbootstrap` stanza.
- `core/cabal.project` pinning the GHC version that matches the base image, plus any required
  `allow-newer` carve-out.
- `optparse-applicative` and `dhall` declared as library dependencies.
- `cabal build all` succeeds with the package and module boundary in place.

#### Validation

`cabal build all` exits 0 against the warm Cabal store (GHC 9.12.4, `-O2`); `optparse-applicative`
and `dhall` resolve from the store without recompilation.

#### Remaining Work

None.

### Sprint 1.2: Module skeleton + runHostBootstrapCLI [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/app/Main.hs`,
`core/hostbootstrap-core/src/HostBootstrap/`
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `system-components.md`

#### Objective

Create the empty `HostBootstrap.*` module skeleton and the generic optparse entrypoint so Phase 2
onward has named modules to fill in and the command-tree extension contract has a concrete signature.

#### Deliverables

- `HostBootstrap.CLI` exporting the composable optparse entrypoint (`runHostBootstrapCLI`) and the bare
  executable entrypoint (`runBareHostBootstrapCLI`), wired to a buildable core command tree.
- `HostBootstrap.*` module declarations for the surfaces named in
  [system-components.md](system-components.md) (host tools, prereqs, substrate, ensure, config,
  cluster).
- The bare `hostbootstrap` executable calls `runBareHostBootstrapCLI "hostbootstrap"` and prints
  `--help`.

#### Command Surface

- `hostbootstrap --help` lists the (initially empty) core command groups.
- A project binary calls `runHostBootstrapCLI "<project>" projectSpec` to extend the tree through named
  `ProjectCommand` values, a non-empty `TestSuite`, a `check-code` action, and any project
  `ConfigArtifact`s (see [development_plan_standards.md § P](development_plan_standards.md)).

#### Validation

- `cabal build all` succeeds; the library compiles every declared `HostBootstrap.*` module.
- `hostbootstrap --help` exits 0 and prints the core command tree.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` - the `HostBootstrap.*` module surface and
  the `runHostBootstrapCLI` command-tree extension contract.

**Engineering docs to create/update:**
- `documents/engineering/cabal_layout.md` - records the GHC pin, the `optparse-applicative` / `dhall`
  dependencies, and the library/executable stanza layout.

**Cross-references to add:**
- `system-components.md` marks the Phase 1 module rows present.
