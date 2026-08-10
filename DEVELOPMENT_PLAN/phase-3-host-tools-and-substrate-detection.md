# Phase 3 — Host tools and substrate detection

**Status**: Done
**Depends on**: Phase 2 (Haskell core scaffolding)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Close both axes of host invocation — *which* executable a call names, and the *shape* the
> call takes — and classify the substrate the binary is running on.

## Phase Objective

Every later phase invokes host tools. Two independent things can go wrong: the call can resolve to the
wrong executable, and it can be launched with a stdio and session disposition that makes its failure
invisible. Both boundaries are closed here, together, because resolving a path absolutely says nothing
about the shape of the call — and a child that outlives its launcher is where the two come apart most
sharply.

## Sprints

### Sprint 3.1: The closed `HostTool` boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostConfig.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

No invocation resolves through `$PATH`.

#### Deliverables

- `HostTool` is a closed enumeration of every external tool core may invoke, including the host-provider
  tools (`incus`, `lima`, `colima`, `wsl`), the provider ownership prerequisites (`python3`, `flock`,
  `lockf`), and the accelerator toolchains.
- Each tool resolves to an `AbsExe` — an absolute path — recorded in typed `HostConfig`.
- `buildHostConfig` performs resolution once; no library or project code calls a bare command name.
- A tool that cannot be resolved is a typed refusal naming the tool, not a runtime `ENOENT`.
- In-VM tools are reached through one resolved host-provider command; the VM's own `$PATH` is the VM's
  concern, because the VM is a separate machine.

#### Validation

`HostToolSpec` covers resolution, the refusal, and the absence of bare-name invocation.

#### Remaining Work

None.

### Sprint 3.2: Substrate classification [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate.hs`,
`core/hostbootstrap-core/test/SubstrateSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Classify the host into one closed set of substrates.

#### Deliverables

- `detect` yields exactly one of `apple-silicon`, `linux-cpu`, `linux-gpu`, `windows-cpu`, `windows-gpu`.
- The GPU distinction on Linux is drawn from concrete host evidence (`/proc/driver/nvidia/version` and
  `/dev/nvidiactl`), so a host without NVIDIA markers classifies as `linux-cpu` and cannot be presented as
  a GPU lane.
- Classification is a total function: there is no unknown substrate that later code must guess about.

#### Validation

`SubstrateSpec` covers each branch and the evidence each one reads.

#### Remaining Work

None.

### Sprint 3.3: Host prerequisites after the binary exists [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostPrereqs.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

State the post-binary host floor separately from the pre-binary one.

#### Deliverables

- `HostPrereqs` names what the binary requires of its host, per substrate.
- The set is derived from the classified substrate rather than asserted uniformly.
- A missing prerequisite is a typed refusal that names it.

#### Validation

Covered by `SubstrateSpec` and `HostToolSpec` over each substrate branch.

#### Remaining Work

None.

### Sprint 3.4: The invocation-shape boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Detached.hs`,
`core/hostbootstrap-core/test/DetachedSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Close the second axis: the stdio disposition, descriptor inheritance, session, environment, and working
directory of every launched child.

#### Deliverables

- `HostBootstrap.Detached` is the single sealed boundary for launching a child, including one that outlives
  its launcher.
- A detached child's stdio disposition is declared explicitly, so a failure cause is written somewhere a
  reader can find it rather than to a descriptor that is already closed.
- Descriptor inheritance, session leadership, environment, and working directory are all part of the
  declared shape; none is inherited by accident.
- The type makes an unspecified disposition unrepresentable, so a call site cannot omit one.

#### Validation

`DetachedSpec` covers each disposition and asserts a detached child's cause survives its launcher.

#### Remaining Work

None.

### Sprint 3.5: The canonical project root [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectRoot.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/test/ProjectRootSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/CrossScopeProjectRoot.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Derive one canonical root for a project's durable state.

#### Deliverables

- `CanonicalProjectRoot` is an opaque, validated absolute root; a caller cannot supply an arbitrary path as
  "the project root".
- Root admission retains the surrounding config/lifecycle `scope` and mints only a fresh `rootId`; the sibling
  config admission therefore yields `CanonicalProjectRoot configScope rootId`, never an independently scoped
  root that a later plan must reconcile by convention.
- Every durable projection — state, build outputs, protected store — is derived from it, so two call sites
  cannot disagree about where a project's state lives.
- The root is host-durable and is never inside a provider frame.

#### Validation

`ProjectRootSpec` covers derivation, validation, and the durable projections. `CrossScopeProjectRoot.hs`
proves a root admitted with one config scope cannot be consumed as another.

Dated evidence for the phase gate: `cabal test all --ghc-options=-Werror` from `core/` passed 1047/1047
on 2026-08-08 (aarch64-osx, GHC 9.12.4).

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — the closed `HostTool`/`AbsExe` boundary and the separate
  invocation-shape boundary.
- `documents/architecture/build_and_run_model.md` — the closed substrate set and the evidence each branch reads.
- `documents/architecture/durable_state.md` — the canonical project root and its durable projections.

**Engineering docs to create/update:**
- `documents/engineering/prerequisites.md` — the host floor per substrate.
- `documents/engineering/testing.md` — what the static suites do and do not cover for host invocation.

**Cross-references to add:**
- `development_plan_standards.md` § K and § HH name this phase as the owner of the two axes.
