# Phase 5 — Installed identity, operator verification, and authority kernels

**Status**: Done
**Depends on**: Phase 4 (protected store)
**Substrates**: none (static)
**Gate**: `cabal test all` from `core/`, including the compile-fail fixtures,
host-native on the gate host that runs it
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-12 ; x86_64 Ubuntu 24.04.4 LTS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate

> **Purpose**: Turn independently verified executable, operating-system, store, and generation facts into
> opaque authority inputs, while leaving lifecycle-specific command admission to the phases that possess
> the complete plan, lease, frame, cursor, and context package.

## Phase Objective

An invocation cannot establish authority by choosing a phantom type, replaying a recorded integer, or
presenting descriptive configuration. This phase supplies the lower authority vocabulary and the sealed
compare-and-swap kernels later lifecycle gates consume. The safe facade verifies installed identity and
the current OS principal, exposes opaque inspection, and parses the closed verb vocabulary; only the
allow-listed package implementation can allocate a fresh epoch, select a root scope, or reserve a command
invocation. Recorded recovery evidence remains in the protected transition that read it and never remints
an epoch from an integer.

## Sprints

### Sprint 5.1: Closed verb and phase vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Make lifecycle verbs and phases closed type-indexed vocabularies.

#### Deliverables

- `ProjectVerb` is a GADT over `VerbUp`, `VerbDown`, and `VerbDestroy`; a value for one verb cannot inhabit
  another.
- `LifecyclePhase` distinguishes `PreparePhase`, `ExecutePhase`, and `TeardownPhase` at the type level.
- Parsing yields one existential member of the closed verb set or a typed refusal; there is no text-backed
  extension constructor.

#### Validation

`AuthoritySpec` covers every accepted verb, unknown-verb refusal, and exact rendering.

#### Remaining Work

None.

### Sprint 5.2: Generative installed project identity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Bind project identity before any plan, run, or authority identity exists.

#### Deliverables

- `InstalledProjectIdentity projectId` has a hidden constructor and exists only inside a rank-2 continuation.
- `withInstalledProjectIdentity` validates an ASCII stable project name against the normalized leaf of
  `getExecutablePath`, including the Windows `.exe` spelling, before minting `projectId`.
- The safe facade cannot fix project identity to a caller-chosen phantom or reconstruct it from its rendered
  name; Phase 7 threads this opener through the configuration and CLI surfaces.
- Stable record keys derive their project component only from `InstalledProjectIdentity`.

#### Validation

`AuthoritySpec` covers matching/mismatching executable identities, Windows suffix normalization, and invalid
ASCII stable names. Pinned compile-fail fixtures cover constructor forgery, rank-2 escape, and nominal-index
coercion; Phase 7 covers propagation across distinct runtime invocations.

#### Remaining Work

None.

### Sprint 5.3: Verified OS principal [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Represent the OS decision separately from lifecycle authority.

#### Deliverables

- `verifyOsPrincipal` asks the operating system to create and remove a probe in the exact protected records
  directory and yields opaque `VerifiedOsPrincipal` only on success.
- The evidence retains the protected-store identity and is refused by a kernel operating on another store.
- `VerifiedOsPrincipal` grants no verb, scope, plan, epoch, or command authority by itself.

#### Validation

`AuthoritySpec` covers OS refusal, matching-store evidence, and root/reservation refusal across stores.

#### Remaining Work

None.

### Sprint 5.4: Broker epochs [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Make a broker generation evidence of a protected transition, not an integer claim.

#### Deliverables

- `BrokerEpoch brokerGeneration` is opaque and generative.
- The package-private fresh opener advances the installed project's protected monotonic counter before yielding
  the new epoch and retains its exact project and store origin.
- Root admission rechecks that origin. No recorded-value opener exists: higher recovery transitions retain or
  verify the generation evidence from their protected record without reconstructing `BrokerEpoch`.
- The exposed module offers no `Word64 -> BrokerEpoch` route, and nominal roles prevent coercing one generation
  index into another.

#### Validation

`AuthoritySpec` covers monotonic allocation, malformed/exhausted counter refusal, and project/store separation.
Pinned compile-fail and import guards cover constructor opacity, nominal coercion, and raw-opener absence.

#### Remaining Work

None.

### Sprint 5.5: Scoped root invocation authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Verify one exact root invocation without letting a public caller select its lifecycle scope.

#### Deliverables

- `RootInvocationAuthority scope brokerGeneration verb` is opaque and retains the installed project, durable
  protected-store identity, project/store-bound broker epoch, and exact closed verb.
- Its package-private producer consumes the exact installed identity, verified OS principal, epoch, verb, and a
  scope selected by the composite lifecycle transaction.
- The verifier binds an unclaimed authority store to the installed identity with compare-and-swap and refuses a
  store already bound to another project.
- The exposed module offers no standalone root opener and no scope-selection witness.

#### Validation

`AuthoritySpec` reaches the kernel through the composite Production/Harness brackets and covers project/store,
verb, epoch-origin, and scope binding. Pinned compile-fail fixtures cover constructor, scope-substitution,
nominal-role, and public-opener absence.

#### Remaining Work

None.

### Sprint 5.6: Root-scope narrowing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Expose the root's established scope without exposing a scope constructor.

#### Deliverables

- `RootScopeAuthority scope` is opaque.
- `rootScopeAuthority` projects it only from `RootInvocationAuthority scope brokerGeneration verb`.
- No function converts one `RootScopeAuthority` to another scope or constructs one from configuration/context.

#### Validation

`AuthoritySpec` covers exact projection; compile-fail fixtures cover construction and cross-scope substitution.

#### Remaining Work

None.

### Sprint 5.7: Command authority vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeCommandAuthority.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Define the opaque result shared by proof-complete lifecycle command gates.

#### Deliverables

- `CommandAuthority scope planId frame authorityEpoch verb phase` carries the exact scope, plan, frame,
  authority epoch, verb, and phase indices.
- Its constructor is package-private; the safe authority facade exposes inspection but no producer. The later
  proof-complete plan, child, and teardown gates own production. Sprint 12.25 first surfaced the local root
  producer as `authorizeProjectUp`; Sprint 17.8 supersedes that shape with root-refined generic
  `authorizeRootProject` and a Cabal-private root-Up `LifecycleEntry` consumer without changing this Phase 5
  constructor/kernel ownership.
- `commandAuthorityEpoch` returns the indexed epoch value rather than erasing it to an unrelated word.
- The safe authority facade exports no generic lifecycle command-authority producer; the reservation producer
  remains package-private and proof-complete gates own its use.

#### Validation

Pinned construction/coercion fixtures cover scope, plan, frame, and epoch indices, and an exported-surface
guard pins the safe facade's absence of a generic producer.

#### Remaining Work

None.

### Sprint 5.8: One-use command reservation kernel [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Give later complete authorization gates one atomic reservation primitive.

#### Deliverables

- Package-private `CommandReservation` contains the stable installed-project, protected-store, plan-digest,
  frame-key, epoch, verb, and phase identity already verified by its caller.
- `reserveCommandInvocationKernel` compare-and-swaps the exact absent reservation to consumed before yielding
  `CommandAuthority`.
- The record key is SHA-256 over one canonical length-prefixed encoding; the complete encoding is retained in
  the record so a digest collision refuses rather than consuming another invocation.
- Concurrent identical reservations have exactly one winner; changing any stable member names a distinct
  reservation.
- The kernel performs no plan, lease, frame, cursor, or context validation and is not an authorization gate.

#### Validation

`AuthoritySpec` covers thread and POSIX cross-process one-winner races plus every stable key member. Import
guards restrict the kernel to its allow-listed package implementation and keep configuration/reconciliation
dependencies above it. The allow-list is a set of repo-relative module paths, compared separator-neutrally
so it names the same modules on every supported outer host realization (§ JJ).

Dated evidence for the phase gate: `cabal test all --ghc-options=-Werror` from `core/` passed 1088/1088
on 2026-08-08 (aarch64-osx, GHC 9.12.4). The gate includes all 69 public compile-fail boundaries.

The allow-list now builds its names with `SourceGuard.repoRelativePath`, the separator-neutral helper the
[Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md) owns, so the eleven importers and
the single child-reservation caller are named identically on every gate host. On 2026-08-17 the same gate
passed host-native on Windows 11 Home 10.0.26200 x86_64 (GHC 9.12.4, Cabal 3.16.1.0) at 1,877/1,877,
which is the first run to exercise this allow-list from a native-separator gate host. Confirming it on
the remaining families belongs to the
[host-portability acceptance phase](phase-28-host-portability-acceptance.md) (§ JJ).

#### Remaining Work

None.

### Sprint 5.9: The identity decision reads the role it parsed [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Writing the root config at the binary's own sibling path is what provisions the installed handoff and
build identities, and that decision is about the **role**, not about the spelling the role arrived in.
`--role` accepts aliases and normalises case and separators, so the decision is taken on the parsed
value the same function already produced.

#### Deliverables

- The initializer's default-role parameter is the parsed role kind, not its rendered text.
- The provisioning guard compares parsed role kinds.
- The parser default and help text render that value rather than carrying a second literal.
- Cases cover the canonical spelling, an accepted alias, and a case- and separator-normalised spelling, each asserting that identity is provisioned, and one non-default role asserting that it is not.
- The cases restore whatever the executable's siblings held, so no case's expectation depends on the order it ran in.

#### Validation

The host static gate; the command suite is where the cases land. Dated evidence: on 2026-09-12,
x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal test all` from `core/` passed
with the four `project init` cases green, including `--role host` and `--role "  HOST_Orchestrator  "`
each provisioning the five root identity files.

#### Remaining Work

None. The fixture diagnostics, the testing seam, and the coordinate pilot are Sprints 5.10 to 5.12.

### Sprint 5.10: Every registered fixture pins the diagnostic it expects [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeSessionPermit.hs`,
`core/hostbootstrap-core/test/compile-fail/ObservedReadyGuestAlias.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

§ HH requires a compile-fail fixture to fail *for its named reason*, because a fixture that merely
fails to compile is satisfied by a typo. Every registered fixture therefore states the phrase it
expects, and the registration takes no other shape — including the two the architecture page cites as
the proof for its readiness and capability boundaries.

#### Deliverables

- Every registered fixture carries one contiguous expected phrase, read from the diagnostic it actually produces.
- The capability and readiness fixtures the boundary table cites — `ForgePreparedGate.hs` and `RawReadiness.hs` — are among them.
- Expectations split across separately-matched fragments are re-joined into one phrase, because fragments can be satisfied independently by an unrelated error on the same line.
- The registration combinator that accepted no expectation is gone, so an unpinned fixture is not expressible rather than merely absent.
- Four fixtures whose diagnostic named an arity or kind error rather than the boundary they are registered under are repaired to ask their own question, not re-pinned to what they happened to say.

#### Validation

The host static gate. The compile-fail suite is the subject and the long pole. Dated evidence: on
2026-09-12, x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, the public boundary suite
passed 522 cases in 83.11 seconds with every case stating its expected phrase.

#### Remaining Work

None beyond the phase's own.

### Sprint 5.11: The session testing seam leaves the public surface [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/compile-fail/ForgeTransactionPermitFromDescriptor.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

The direct-provider testing seam is private precisely so downstream code cannot use it to mint a value
in the sealed column, and the session seam is private for the same reason. Its types mint no authority;
the bytes it renders are the coordinator's own, and a consumer that could write them could put the
store into a state no run produced.

#### Deliverables

- `HostBootstrap.Lifecycle.Session.Testing` and the transaction vocabulary it re-exports live in a private sublibrary, the pattern the package already uses five times.
- A compile-fail fixture pins that a downstream consumer cannot import it, naming the sublibrary that holds it.
- The suite that legitimately uses it depends on the private sublibrary directly.

#### Validation

The host static gate, plus the fixture. Dated evidence: on 2026-09-12, x86_64 Ubuntu 24.04.4 LTS with
GHC 9.12.4 and Cabal 3.16.1.0, `cabal build all` and `cabal test all` from `core/` passed, with the
fixture reporting the seam as a member of the hidden `lifecycle-transaction-internal` sublibrary.

#### Remaining Work

None beyond the phase's own.

### Sprint 5.12: Coordinate types at the prepared-gate boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/FrameExecutor.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

§ HH states that a coordinate carried across a sealed boundary is a type. The prepared gate is the
smallest complete instance and the one the architecture page leads with: its producer takes three text
coordinates then three numeric ones, and the canonical renderer beside it has the same shape, so a
transposition would be invisible from mint to wire. This sprint is the pilot — one boundary, done
fully, so the cost of the remaining ones is judged from something real rather than estimated.

#### Deliverables

- Each coordinate role at this boundary is a newtype: the plan digest, the operation key, the session, the fence, the attempt, and the journal version.
- The rooted renderer's three further roles — the catalog identity, the frame, and the supersession generation — are newtypes too, so the generation that stands where a fence stands cannot be written in its place.
- The producer and the canonical renderer both take them, so the two cannot disagree about order.
- The fields, the accessors, and the framing are unchanged: no runtime representation changes and no durable byte changes. This is an argument-order proof, not a format change.

#### Objective boundary

What it cost: nine newtypes and one exported constructor each, four call sites wrapped, one round-trip
check inside the module wrapped, and two source guards re-stated against the new call shape. No
consumer of a gate changed, because the accessors still answer in the underlying types. That is the
price for one boundary of six-plus-three coordinates; the remaining sealed producers are not in this
sprint's scope.

#### Validation

The host static gate. The existing cases pin the canonical bytes, and they pass unchanged — which is
the evidence that the newtypes are a compile-time property only. Dated evidence: on 2026-09-12,
x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal test all` from `core/` passed
2,517 tests.

#### Remaining Work

None beyond the phase's own.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/binary_context_config.md` — installed identity, OS evidence, root scope, and the
  reservation kernel beneath proof-complete command gates.
- `documents/architecture/lifecycle_state_model.md` — the composite lifecycle transaction that alone scopes a
  root and the later consumers of `CommandAuthority`.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — compile-fail/export/import guards and the cross-process reservation race.

**Cross-references to add:**
- `development_plan_standards.md` § X and § EE name this phase as the owner of the lower authority vocabulary;
  Phases 9, 12, 13, 17, and 18 own its proof-complete lifecycle consumers.
