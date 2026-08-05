# Phase 5 — Operator, root, and command authority

**Status**: Done
**Depends on**: Phase 4 (protected store)
**Substrates**: none (static)
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, including the compile-fail fixtures

> **Purpose**: Replace self-asserted permission with unforgeable, generation-indexed authority values that
> only a verified operator invocation can mint.

## Phase Objective

A command must not authorize itself. Before this phase the only thing a verb could consult was the decoded
configuration it was handed — which is the caller's own claim. This phase introduces the chain that
converts an operating-system fact into a typed capability: the OS permits this process to act as the
project's operator, therefore a root invocation authority exists for this exact verb under this exact
broker generation, therefore a command authority exists for this exact frame and phase, exactly once.

Every value here has a private constructor and a generative type index, so it cannot be forged, retained
across a generation boundary, or presented at a frame it was not minted for.

## Sprints

### Sprint 5.1: Verbs, phases, and installed project identity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Make the verb and the project identity types rather than strings.

#### Deliverables

- `ProjectVerb` is a GADT over `VerbUp`, `VerbDown`, `VerbDestroy`, so a value minted for one verb cannot
  be presented for another.
- `LifecyclePhase` distinguishes `PreparePhase`, `ExecutePhase`, and `TeardownPhase` at the type level.
- `InstalledProject projectId` carries a validated project name; `withInstalledProject` opens a generative
  index for a binary with no installed config family, and `installedProjectFor` fixes the index to the
  project's own config family.
- The declared project name must equal the invoked executable identity, so one binary cannot present itself
  as another project.

#### Validation

`AuthoritySpec` covers verb parsing, the name validation, and both project openers.

#### Remaining Work

None.

### Sprint 5.2: Operator authorization and broker generations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Turn an OS fact into a typed capability, and index every capability by generation.

#### Deliverables

- `verifyOperatorAuthorization` reads the operating system's own answer and yields an
  `OperatorAuthorization` bound to the store it was issued against; presenting it to another store refuses.
- `BrokerEpoch brokerGeneration` is generative and monotonic; `withFreshBrokerEpoch` allocates the next one
  durably, and `withRecordedBrokerEpoch` reopens the type identity of a generation a record already names.
- A fresh generation is what fences a dead invocation's permits out. Reusing one would make a delayed
  permit indistinguishable from a live one — see [rationale.md](rationale.md).

#### Validation

`AuthoritySpec` covers the OS check, the cross-store refusal, monotonic allocation, and the recorded-epoch
reopening.

#### Remaining Work

None.

### Sprint 5.3: Root invocation and command authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Authority/Internal.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

One root authority per verified invocation, one command authority per frame, consumed once.

#### Deliverables

- `withVerifiedRootInvocation` consumes the operator authorization, the generation, and the exact verb, and
  yields `RootInvocationAuthority scope brokerGeneration verb` inside a continuation. It also binds the
  store to this project on first use.
- `authorizeProjectCommand` yields `CommandAuthority` for one verb at one frame of one plan in one phase,
  under one generation, exactly once. The frame index is generative, so an authority obtained for one frame
  cannot be presented at another even when the frame names match.
- `InvocationId` is recorded durably *before* it is handed out, so a one-use identity cannot be replayed.
- `HarnessAuthority projectId runId` is minted only inside the harness opener and is the only planning
  capability a project test component receives; there is no function from it to a production capability.
- Compile-fail fixtures prove each opaque constructor is unreachable from outside its module.

#### Validation

`AuthoritySpec` covers the mint, the one-use consumption, and each refusal. `CompileFailSpec` runs the
fixtures and asserts GHC rejects them by content rather than by line wrapping.

#### Remaining Work

None.

### Sprint 5.4: The closure root half [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Separate "this verb may close the project" from "the project is provably closeable".

#### Deliverables

- `ProductionCloseKind` distinguishes `SettledDestroyClose` from `PreEffectRefusalClose`.
- `destroyCloseRoot` accepts only an exact `VerbDestroy` root; `preEffectCloseRoot` accepts any production
  verb.
- Both yield `ProductionCloseRoot`, which is the root half only. The proof half is a separate value from the
  lifecycle-modes phase, and neither closes a project alone.
- A close root records the project name, because the `projectId` index belongs to the config family and two
  projects sharing a family share it — see [rationale.md](rationale.md).

#### Validation

`AuthoritySpec` covers both producers and the refusal when the root and the proof disagree.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/binary_context_config.md` — descriptive context versus opaque authority, and the
  operator → root → command chain.
- `documents/architecture/lifecycle_state_model.md` — where the closure root half sits.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the compile-fail fixture mechanism.

**Cross-references to add:**
- `development_plan_standards.md` § X names this phase as the owner of command gating.
