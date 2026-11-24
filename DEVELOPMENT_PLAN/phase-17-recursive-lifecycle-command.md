# Phase 17 — The recursive lifecycle command

**Status**: Active
**Depends on**: Phase 13 (authenticated handoff and rooted lifecycle protocol), Phase 16 (cluster lifecycle,
budgets, and cordoning)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`, including the real local
process-boundary recursive-lifecycle tests
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-16 ; native x86_64 Windows 11 Home 10.0.26200, AMD Ryzen 7 5700G,
GHC 9.12.4, Cabal 3.16.1.0 ; `cabal build all` and
`cabal test all --test-show-details=direct --test-options=--hide-successes` from `core/` ; pass ; covers in-gate

> **Purpose**: Interpret one project plan recursively under a single root coordinator, execute each remote
> frame through a storeless child executor, and unwind the same plan child-first for reverse verbs and failed
> forward work.

## Phase Objective

One root process owns the only `ProtectedStore`, the global invocation lease and snapshot, the recursive plan
catalog, every frame journal, all compare-and-swap transitions, and terminal receipt confirmation. A child is a
long-lived, storeless `FrameExecutor` with only its frame-local `ResourceCarrier`. It verifies a root-signed
exact grant, executes the named local effect, and reports an observation; it cannot open the authority store or
settle lifecycle state.

The root recursively projects and admits every child configuration and plan before that child performs an
effect. It opens each frame session without a requester-supplied predecessor, then admits a four-field
`OpenFrame` whose inner value contains only a nonce; the sealed external relay envelope is its sole requester
ancestry, and attachment failure is an outer refusal. Its exact nine-field signed `Opened` response discloses
the root-admitted canonical path, selects the session, stage, and next ordinal, and establishes the first
predecessor-response digest. Exact eleven-field post-open responses echo the request path/session/nonce,
select successor stage/ordinal, and remain in their request's closed family; only later requests echo those
root-issued successor coordinates. The same root-owned coordinator drives `up`, `down`,
`destroy`, and failed-`up` unwind. A cooperating child interpreter verifies the installed root identity;
descriptive config, `argv`, a duplex channel, a store path, or a process exit status grants no authority.

Phase 13 owns the rooted request/response wire, payload/config digest separation, authenticated root scope,
scope-first receiver, keyless relay, neutral `RecoveryChildPackage` codec, and package-aware binding
verification. Its lower receiver authenticates a complete package but constructs no real one, and its keyless
relay carries a reverse Offer without being able to compose one. This phase owns the plan catalog, the sole
catalog-derived recovery-package producer, the transport that routes its exact Offer to the installed root
signer, complete-package `EdgeAdmission`, root-session, executor, process, command, and reverse-lifecycle
consumers. No lifecycle protocol exposes raw store operations, a shared authority mount, or a child signing
key.

The phase closes on the host-static core gate. Its tests spawn real local child processes and exercise the
authenticated duplex boundary without a provider, live cluster, or demo. Its closing evidence includes a
linux-cpu run over the final source that records the `RecursiveLifecycleSpec` count, because only the POSIX
row executes that group's recursive transitions; a native Windows run records most of its cases as declared
refusals. The
[worked-demo phase](phase-24-worked-demo.md) separately owns the live linux-cpu Production sequence and demo
Harness confirmation.

## Sprints

### Sprint 17.1: Independent root gate for the three verbs [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`, `core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Authorize every lifecycle verb independently of the configuration being interpreted.

#### Deliverables

- `project up|down|destroy` each enter through a `HostBootstrap.Lifecycle.Mode` root entry
  (`withProductionRoot` for Up, `withFreshExistingBoundReverseRootKernel` and
  `withExistingBoundReverseRootTransition` for Down/Destroy) that calls `verifyOsPrincipal` and then mints
  root invocation authority through `withVerifiedRootInvocationKernel` or
  `withExistingVerifiedRootInvocationKernel`. A failed operator verification refuses with
  `AuthorityOperatorRefused` before any mode, lease, journal, reverse-root intent, or effect write.
- The resulting root authority enters only the lifecycle gate indexed by the admitted `ProjectVerb`.
- Decoded configuration remains descriptive plan input and cannot authorize a command.
- No context-declared class, capability, frame name, or payload substitutes for operator/root authorization.
- `project init` remains the sole lifecycle verb that creates initial configuration without interpreting a
  plan.
- An omitted `--source-root` is resolved to the absolute current directory before the project assembler writes
  the sibling config, so the descriptive context and the canonical root admitted by lifecycle entry agree.

#### Validation

`AuthoritySpec` "OS-principal verification refuses an unavailable records directory" proves
`verifyOsPrincipal` itself refuses with `AuthorityOperatorRefused`; it calls the kernel directly and drives
no verb. `CLISpec` drives the three authorized verbs end to end. `ContextSpec` executes `project init` from a
separate source directory and asserts that the generated config records its absolute path.

The sibling context gate rejects a child VM frame before the later defensive "operator entry requires the
root frame" checks can execute: `HostOrchestratorCommand` is refused for that placement. The CLI cases
therefore assert the earlier context refusal and absence of store writes for each verb.

On 2026-11-09, WSL2 Ubuntu 24.04.5 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all` from `core/`: 5,290 core tests and the provider suite passed. `CLISpec`'s "operator
refusal precedes lifecycle work" and "child frame refuses operator entry" cover all three verbs; "parentless
VM orchestrator cannot enter project up or down" covers matching root admission. The `CLISpec` and
`ContextSpec` missing-sibling cases establish and check their own preconditions. The focused selection of
those cases and its `CoverageManifest` declaration also passed (10 cases).

#### Remaining Work

None.

### Sprint 17.2: Current-frame forward interpretation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`, `documents/architecture/run_models.md`

#### Objective

Drive one admitted frame's exact forward order and derive its declared descent boundary. The only descent is
the root coordinator's callback; no lifecycle descent runs `project <verb>` through `argv`.

#### Deliverables

- `runChainFromFrameWithDescentFailure`, the interpreter `Command/LifecycleEntry.hs` drives, selects only the
  non-empty segment owned by the current frame through the shared `runChainFromFrameWithDescentObserved`.
- Its descent is the caller-supplied root-coordinator callback; `HostBootstrap.Chain` exports no interpreter
  with a built-in `argv` descent.
- `DerivedTopology` identifies a declared child boundary without granting child admission.
- Each node action receives the exact plan-minted execution descriptor.
- The announcing node retains the exact child configuration associated with its descent declaration.
- A node failure stops its subtree and is returned as a structural result.
- `Command.hs` carries no unreachable failed-Up or reverse-projection routine that descends through `argv`.

#### Validation

On 2026-11-09, WSL2 Ubuntu 24.04.5 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all` from `core/` (5,289 core tests and the provider suite) and from `demo/` (169 demo
tests, 5,289 core tests, and the provider suite). `ChainSpec`'s "a two-frame descent runs between pre and
post handoff nodes" verifies ordering and the exact child context; its source guards reject the legacy
exports and argv route. `TeardownSpec`, `CLISpec`, `ProjectPlanSpec`, and demo `CommandsSpec` check the
live reverse owners. The four retargeted compile-fail fixtures retain their indexed mismatch assertions.

#### Remaining Work

None.

### Sprint 17.3: Teardown-forest frame-index propagation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/SourceGuard.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Keep every reverse-progress value indexed by the exact frame that opened its subtree.

#### Deliverables

- `TeardownForest scope planId frame verb` derives `frame` only from its matching `TeardownPlan`.
- Progress, authorization point, cursor, successor, and completion preserve the same nominal frame index.
- Destroy settlement retains its frame until unique-root refinement.
- A nested opening schedules only that frame and its descendants.
- Hidden constructors and nominal roles reject cross-frame reconstruction and coercion.

#### Validation

On 2026-11-09, WSL2 Ubuntu 24.04.5 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all` from `core/` (5,289 core tests and the provider suite). `TeardownSpec`'s "the complete
forest pipeline retains the projection frame" uses lexical tokens and parsed exports, tests comment and
string-literal controls, and scans every physical command module. `CoerceTeardownWorkRoles` and
`CoerceTeardownFrameRoles` independently pin the indexed coercion refusals. Their focused selection with
`TeardownSpec` and `DocValidatorSpec` also passed (66 cases).

#### Remaining Work

None.

### Sprint 17.4: Closed local/descent teardown work [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeTeardownForest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Make local reverse execution and recursive descent the exhaustive next-work branches.

#### Deliverables

- Hidden `TeardownWork` has one total eliminator over opaque `LocalWork` and indexed `DescentWork`.
- `LocalWork` alone exposes its local key, policy, action, and runner through fixed eliminators.
- `DescentWork` exposes only its exact parent/child binding and forest continuation.
- No general cursor projection can enter both branches.
- Success and typed failure advance only the exact forest that produced the work.

#### Validation

On 2026-11-09, WSL2 Ubuntu 24.04.5 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all` from `core/` (5,294 core tests and the provider suite). `CompileFailSpec` independently
pins `ForgeTeardownAuthorizationPoint`, `ForgeCompletedTeardownForest`, `ForgeSettledTeardownChildren`,
`ForgePreDescentStep`, and `ForgeTeardownProgressCompleted`; the existing `ForgeTeardownForest` retains its
verb, forest, and destroy-settlement checks. All six affected fixtures passed in isolation too.

#### Remaining Work

None.

### Sprint 17.5: One `ProjectVerb` universe [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`, `core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Carry the command gate's exact `ProjectVerb verb` through both forward and reverse interpretation.

#### Deliverables

- Reverse plans, forests, work, completion, and settlement retain the admitted `ProjectVerb` index.
- No second teardown-local verb universe or compatibility term exists.
- `ProjectUp` is total but receives a typed refusal before reverse work is exposed.
- Down and destroy remain structurally distinct and select only their declared reverse actions.
- Down projects `RetainResource` for `copy-source`, retaining the provider share and guest alias across
  stop/restart; Destroy projects `ReleaseResource` after the child subtree settles. Only provider
  stop/delete actions establish the forest's frame owner.
- Parser text and caller-selected tags cannot change the verb after root admission.

#### Validation

On 2026-11-09, WSL2 Ubuntu 24.04.5 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all` from `core/` (5,296 core tests and the provider suite). `TeardownSpec`'s "worked demo
destroy waits for its child before all parent cleanup" pins the first offer and exact drain order, and
"failed worked demo descent blocks every parent cleanup" proves the parent share, build, and provider
remain blocked. The latter failed against the previous scheduler, which offered `core:build-pb` after
child failure. The existing "a failed branch does not starve an independent sibling" remains green; the
focused teardown, real-process recursive lifecycle, and documentation selection passed 75 cases.

#### Remaining Work

None.

### Sprint 17.6: Frame-bound settlement and root destroy proof [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Separate settlement of one frame-bound subtree from proof that the whole project was destroyed.

#### Deliverables

- `SubtreeSettled` is produced only from the exact completed frame, verb, plan, and terminal observations.
- Parent continuation accepts only the child proof derived from its own `DescentWork`.
- `DestroySettled` requires root-frame destroy settlement and unique-root topology evidence.
- Nested completion remains useful to its parent but cannot authorize project closure.
- Down, unresolved work, and failed work yield no project-wide destroy proof.

#### Validation

On 2026-11-09, WSL2 Ubuntu 24.04.5 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all` from `core/` (5,296 core tests and the provider suite). `TeardownSpec`'s "the exact child
proof bulk-settles only its matching parent continuation" refuses a foreign digest and checks the exact
remaining parent operation. "exact terminal validation rejects missing, extra, duplicate, reordered, and
failed observations" includes a valid positive control, wrong verb/digest/frame refusals, and a forged root
subtree refusal. Both cases also passed in isolation.

#### Remaining Work

None.

### Sprint 17.8: Opaque root lifecycle entry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/ProjectPlan.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Package the exact root plan, frame, journal, cursor, and independent root authority into one entry.

#### Deliverables

- Opaque nominal `LifecycleEntry` is the sole value accepted by fixed root lifecycle interpreters.
- Its producer consumes matching root invocation authority, verb, bound plan/lease, and root lifecycle context.
- Production atomically revalidates the live lease, snapshot, journal source, cursor, and unique-root evidence.
- The entry retains its authority and state privately and exposes no store, plan, journal, cursor, or root proof.
- Production and typed Harness root routes enter through the same package-private root-entry constructor.

#### Validation

Dated 2026-08-10 evidence includes `CLISpec` 49/49, `ChainSpec` 38/38, eighteen affected compile-fail groups
18/18, the complete public boundary matrix 422/422, and `DocValidatorSpec` 2/2.

The sprint closes when the Haddocks below name the three entry constructors, `lifecycleEntryVerbName` is
gone with its export guards updated, the single-importer guard runs on `SourceGuard` tokens over both
main-library source roots, and the warning-clean `cabal test all` from `core/` passes.

Closing evidence, 2026-11-09, native x86_64 Windows 11 Pro 10.0.26300 (GHC 9.12.4, Cabal 3.16.1.0):
`cabal test all` from `core/` passed after the `ProjectPlanSpec` entry-sealing guard was updated from 9 to 8
constructor sites per name, because deleting `lifecycleEntryVerbName` removed one `RootDownLifecycleEntry` and
one `RootDestroyLifecycleEntry` pattern. The first run before that edit failed 1 of 5296 on exactly that guard.

#### Remaining Work

None.

### Sprint 17.9: Sealed handoff facade and root-signing admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Expose one handoff facade while keeping every fixed-domain signature inside a live-root-broker operation.

#### Deliverables

- `HostBootstrap.Handoff` is the sole exposed handoff facade and does not reexport protocol/channel internals.
  The library exposes exactly one other `HostBootstrap.Handoff.*` module, `HostBootstrap.Handoff.Transaction`
  (Sprint 13.41). It is the frame-child entry that `runCLI` routes to, and it grants nothing beyond
  `HostBootstrap.Lift` and `HostBootstrap.CLI`.
- Hidden `Handoff.Internal` owns the unconstructible root-signing admission `RecoverySigningKernel` and its
  sole producer; the capability name does not make it a generic byte signer.
- Only exact allowlisted hidden owners consume that admission while the root broker and typed input are live.
- Each signing kernel fixes its own canonical domain and typed material and refuses binding drift before use.
- No endpoint, raw channel, signing-key implementation, reusable signer, or recovery capability escapes.

#### Validation

Dated 2026-08-11 evidence includes `HandoffSpec` 47/47, recovery cases 35/35, eight boundary compile-fail
groups 8/8, `DocValidatorSpec` 2/2, and warning-clean library/test builds. A `HandoffSpec` guard pins the
exposed `HostBootstrap.Handoff*` modules to exactly `HostBootstrap.Handoff` and
`HostBootstrap.Handoff.Transaction`, and asserts that every other handoff module is hidden.

#### Remaining Work

None.

### Sprint 17.10: Durable verb-tagged reverse-root intent [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/durable_state.md`

#### Objective

Persist exact root reverse intent before any reverse effect can begin.

#### Deliverables

- The durable root intent is one protected row per installed project, keyed
  `reverse-root.<project>.production`. Its private `ReverseRootIntent projectId sourceBrokerGeneration verb`
  type is indexed by project, source broker generation, and reverse verb. The payload pins the run key, plan
  revision and digests, source broker epoch, acquisition and cursor records, root frame, and mode/lease
  predecessors.
- Canonical Pending, Committed, and Terminal rows retain the exact admitted verb and source coordinates.
  Committed adds the sole allocated target generation and the predicted mode/lease successor records.
- Compare-and-swap plus strict readback governs every transition and retry.
- Down and destroy intents cannot be relabelled or share an in-flight slot.
- The codec fixes its field-list, unsigned-integer, and reverse-verb guard result types explicitly across
  GADT branches, preserving the same canonical bytes on supported compilers.
- The substrate performs no teardown effect and exposes no store or raw intent row.

#### Validation

Dated 2026-08-11 focused mode/session tests, source guards, compile-fail checks, and the warning-clean core gate
passed.

On 2026-09-09, the native Windows GHC 9.12.4 core gate passes 2,492/2,492 in 675.12 seconds.
The library and both executables also build with `-Werror` against GHC 9.10.3 in published CPU/amd64
base digest `e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5`.
The reverse-root codec's explicit local types pass both compilers and the production formatter check.

The codec's value-level promises (canonical readback, trailing-byte refusal, field-count bound, Up refusal)
are checked only as fragments of the codec section; `decodeReverseRootIntent` is private, and the only
value-level reverse-root fixture (`CLISpec`, near lines 1954-1981) builds canonical bytes. The ordinary
admission gate that keeps a Pending or Committed intent exclusive, `refuseReverseRootIntentAt` inside
`withOrdinaryProjectAdmissionForName` (`Mode.hs`, near lines 9735-9771), is pinned only at its call sites:
no test produces `ModeReverseRootInProgress` or its malformed-intent `ModeMalformedRecord`. The sprint closes
when the cases in Remaining Work exist and pass in the warning-clean `cabal test all` from `core/`.

2026-11-09 (native Windows, GHC 9.12.4): the store-backed gate cases and the placement relabel landed, and the
reverse-root schema and codec moved out of `Mode.hs` into the pure module
`HostBootstrap.Lifecycle.ReverseRootIntent`, which the private sublibrary `reverse-root-intent-internal`
(`core/hostbootstrap-core/internal/reverse-root-intent`) exposes to `Mode.hs` and the test suite only.
`AuthoritySpec` "the reverse-root intent codec round-trips only its exact canonical bytes" asserts that canonical
Down and Destroy Pending, Committed, and Terminal values round-trip; that a Down row is refused as Destroy, a
Destroy row as Down, and every row as Up; and that a trailing byte, a truncated row, a field count of 33, a
mis-shaped well-framed row, and a future wire version each decode to `Nothing`. `AuthoritySpec` "a recognized
Pending Destroy intent refuses a profile and every ordinary root while its matching Terminal permits one" asserts
that `withProductionRoot` and `withHarnessRoot` return `ModeReverseRootInProgress` without running their body, and
that a trailing byte and an over-bound field count return `ModeMalformedRecord` naming the intent key. The
`ProjectPlanSpec` substrate guard reads the new module for the schema and codec sections, and the
`AuthoritySpec` kernel-importer set and the `ProjectPlanSpec` source-root and module-home lists name it. The
full `cabal test all` from `core/` passed. The edit added a package to `hostbootstrap-core.cabal`, a path in
Phase 16's `**Evidence covers**` set, so Phase 16 is `Active` and Sprint 16.68 owes its re-run.

`AuthoritySpec` "Harness short-close refuses while a reverse-root intent row exists, without changing the store"
reaches the lease-close funnel through the public `closeHarnessRun`: with an intent row present it returns
`Left (ModeMalformedRecord <intent key>)` and leaves the store image unchanged; the recognized Pending row's
`ModeReverseRootInProgress` text is asserted by the ordinary-root case above. The warning-clean `cabal test all`
from `core/` passed with every case above.

#### Remaining Work

None.

### Sprint 17.11: Exact reverse-root continuation and redo [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Snapshot.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`, `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/durable_state.md`

#### Objective

Resume or redo an admitted reverse verb only from its exact durable intent lineage.

#### Deliverables

- Pending resumes the same plan/run/broker/frame/verb without allocating a second intent.
- Committed admits only the exact replay path defined by its retained target and predicted successors.
- Terminal state returns a typed terminal observation and performs no effect.
- A terminal Down receipt admits one following Destroy after exact snapshot, closed-session, and current
  mode/lease verification. The same protected row advances from Down Terminal version 3 through Destroy
  Pending/Committed/Terminal versions 4/5/6 without discarding its predecessor before publication.
- In-flight cross-verb, cross-run, stale-version, malformed-row, and missing-source input refuses.
- Every branch rechecks state under the root-owned protected-store bracket before returning its fixed result.

#### Validation

Dated 2026-08-11 focused mode tests, sequential retry cases, source guards, and warning-clean library/test
builds passed.

On 2026-09-09, the native regression passes Up-to-Down-to-Destroy without another forward effect, with terminal
versions 3 and 6 and absent Production mode. Five stale-predecessor cases refuse before Destroy effects
and preserve the mode, lease, and reverse receipt. Exact terminal retries and fresh Up rearm pass, as does
resumption from the persisted Destroy Pending version 4 before broker allocation.

The published CPU/amd64 base's GHC 9.10.3 builds the library and both test components with `-Werror`.
Its compiled test executable, run directly in Ubuntu 24.04 on WSL2, passes the `RecursiveLifecycleSpec`
selection at 9/9 in 107.37 seconds: eight family cases and their coverage-manifest assertion. This includes
the real root/VM/container Up-to-Down-to-Destroy sequence, repeated reverse commands, and fresh Up rearm.
The complete native Windows GHC 9.12.4 host-static gate passes 2,499/2,499 in 499.45 seconds,
including the source boundaries, platform coverage manifest, and governed documentation. The provider-live
component reports its declared no-request Unsupported outcome and exits successfully. All four changed
production modules pass the formatter check; the Python code check and 235-case suite pass as well.

A terminal Destroy row is not a terminal outcome for a following `project down`:
`withExistingBoundReverseRootTransition`'s opposite-verb branch (`oppositeIntent`, `Mode.hs` near line 3901)
answers every decodable opposite row, whatever its phase, with `ModeReverseRootInProgress`. The resume/redo
source guard (`ProjectPlanSpec`, near line 4862) omits the terminal-Down epoch check, the
`ModeReverseRootInProgress` fallback, and every `terminalDestroy` guard, and its `committed` section opens at
the `finishCommitted` call inside `drive` rather than its definition, so the Committed ordering check is
satisfied by `commitAllocated`'s Pending guard. The sprint closes when the change and cases in Remaining Work
exist and pass in the warning-clean `cabal test all` from `core/`.

Closing evidence, 2026-11-09, native x86_64 Windows 11 Pro 10.0.26300 (GHC 9.12.4, Cabal 3.16.1.0): the
opposite-verb branch of `withExistingBoundReverseRootTransition` now answers a settled Destroy under
`project down` with `ModeReverseRootTerminal` and keeps `ModeReverseRootInProgress` for Pending and Committed
opposite rows; `CLISpec` "project down after a terminal destroy reports the terminal outcome without an effect"
and "a repeated destroy refuses a recreated Production mode after its terminal closure" pass; the
`ProjectPlanSpec` resume/redo guard pins the terminal-Down epoch check, the opposite-row fallback, and the
`terminalDestroy` version, lease-version, and closure checks, and its Committed section opens at the
`finishCommitted` definition with no `commitAllocated`. `cabal test all` from `core/` passed.

#### Remaining Work

None.

### Sprint 17.12: Fresh reverse-root source admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Create the sole absent-to-Pending reverse-root source after exact root admission.

#### Deliverables

- Only the exact live root authority, bound plan, lease, snapshot, frame, and verb can create Pending.
- The absent branch uses `ExpectAbsent` compare-and-swap and strict readback before yielding an admitted
  source. A lost compare-and-swap refuses with `ModeStoreFailure` and accepts no row.
- Admissions serialize under the root's exclusive protected entry (`runProtected`). A second admission reads
  the published Pending inside its own entry and resumes it through the Sprint 17.11 path; it never
  allocates a second intent.
- Any conflicting bytes, version, plan, run, broker, frame, or verb refuses without mutation.
- No caller-selected key, version, row bytes, or phase enters the source producer.

#### Validation

Dated 2026-08-11 focused mode tests, source guards, and warning-clean library/test builds passed. The fresh
producer's shape is checked by `ProjectPlanSpec` source guards. `CLISpec` "Destroy resumes the retained
Pending continuation after Down" covers the serialized existing-Pending branch behaviourally: it runs a
second admission over a published Pending and reads back a single `reverse-root.` row. No case races two
admissions in parallel. Convergence rests on the exclusive protected entry, not on a compare-and-swap loser
reading back the winner's row.

#### Remaining Work

None.

### Sprint 17.13: Reverse-root snapshot and liveness facade [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Snapshot.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Join fresh and resumed reverse-root intent to the exact live snapshot through one continuation facade.

#### Deliverables

- The facade admits only an exact bound lease and current immutable snapshot.
- It chooses fresh or same-verb resume from the durable source state rather than caller input.
- Rank-2 continuation scope prevents snapshot, lease, plan, or intent evidence from escaping.
- Liveness and snapshot drift refuse before a lifecycle entry is produced.
- The facade supplies no store, raw key, row bytes, or independently selectable branch.

#### Validation

Dated 2026-08-11 snapshot/liveness tests, source and compile-fail guards, and warning-clean library/test builds
passed.

On 2026-11-11, the warning-clean `cabal test all -j12` from `core/` passed all 5,337 cases on
the dedicated SSD-backed Linux/WSL2 gate host, including the peer-process liveness contention case.
The partial-application test forces the hidden token, the absent Production-mode regression is covered,
and the liveness failure and contention cases exercise the real store. `SnapshotLeaseConflict` remains
a possible refusal from the real lease-binding operation; this sprint claims no behavioural case that
reaches the intervening persistence-to-binding race. A test-only seam is not introduced (§ NN).

#### Remaining Work

None.

### Sprint 17.14: Sealed reverse-root lifecycle entry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/ProjectPlan.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Seal fresh and resumed root Down/Destroy admission into the same opaque lifecycle-entry family.

#### Deliverables

- Reverse entry production consumes exact root authority, verb, root plan/context, lease, snapshot, and intent.
- The entry retains its admitted source and all root-coordinator evidence behind nominal indices.
- Down and destroy have distinct typed branches and cannot enter the Up runner.
- Fresh and resumed routes converge on the same fixed reverse interpreter contract.
- Local phase and seed refusals fix their result effect to `IO` across the indexed lifecycle branches.
- No raw authority, intent, store, journal, cursor, or frame coordinate projects from the entry.

#### Validation

Dated 2026-08-11 authority/entry tests, compile-fail and source guards, and warning-clean library/test builds
passed.

The 2026-09-09 native Windows core gate passes 2,492/2,492 with GHC 9.12.4. The explicit `IO`
refusal types also pass the GHC 9.10.3 published-base build recorded in Sprint 17.10 and the formatter.

2026-11-09 (native Windows, GHC 9.12.4): three `CLISpec` cases passed in their selection:
`project down` with a retained Destroy Pending exits 1 with the in-progress text and an unchanged store,
`project destroy` on a never-brought-up project names the absent Production mode, and (Sprint 17.13)
`project down` does the same.

2026-11-09 finding: the reverse verb run after `seedBoundExecute` (a Bound lease, an Execute cursor, and no
completed Up) succeeds, because a failed-Up leftover is legitimately torn down by the reverse verb (Sprint 17.53).
The seed-phase refusals use a seed whose journal phase, not only its cursor, is Execute or Teardown.

2026-11-11: `CLISpec` now seeds a bound lease and source cursor at Prepare and verifies that `project down`
reports `reverse-root source phase`, runs no step effect, and leaves the protected-store image unchanged.
The `Prepare` selection passed all 27 cases on the dedicated Linux/WSL2 host.
Two further `CLISpec` cases rewrite the real acquisition seed to Execute or Teardown and confirm that the
source admission reports `reverse-root source acquisition seed`, runs no step effect and leaves the store
unchanged. The `non-Prepare` selection passed all three cases on Linux/WSL2. This earlier refusal does not
claim to exercise the target cursor's `SessionAcquisitionBindingMismatch` branch.
On 2026-11-12, after the protected store gained full-width record-version support, `CLISpec` also
seeded completed Up runs with maximum-version mode and lease records. Both Down refusals named the
exhausted record, performed no teardown and left the store unchanged; the `exhausted` selection passed
all three cases on Linux/WSL2.
The `ProjectPlanSpec` reverse-entry source guard now also pins the target cursor's `checkedVersion`
definition and the noninitial acquisition-record version refusal; its `phase-ordered` selection passed
on Linux/WSL2. These guards do not claim behavioural coverage of either refusal.
The `drifted` selection passed two `CLISpec` cases on Linux/WSL2 after changing the persisted source
mode or lease epoch. Both refused without effects or store mutation; mode drift was rejected by the
allocated-broker counter check. These cases do not claim to reach the target-entry epoch guards.
The target-cursor version case passed on Linux/WSL2: a teardown callback raises an IO exception,
leaving a pending Down and its real target cursor; after its record version is advanced without changing
its bytes, retry reports `reverse root target cursor version`, runs no additional teardown and leaves the
store unchanged.
The target root/mode/profile and rebuilt-plan epoch decisions are pure package-private authority
functions consumed by the sealed entry. `AuthoritySpec` applies them to matching values, each mismatch,
and competing mismatches; the `projections` selection passed seven cases on Linux/WSL2. This covers the
actual decision without forging the opaque target evidence or adding a test-only seam (§ NN).
The target acquisition-seed Execute and Teardown branches are exercised by interrupting a real Down,
rewriting its persisted target seed, and retrying. Both retries report the seed-phase refusal without
another teardown or store mutation; the `non-Prepare` selection passed five cases on Linux/WSL2.

On 2026-11-12, `cabal test all -j12` from `core/` passed all 5,349 core cases on the dedicated
SSD-backed Linux/WSL2 gate host, including these cases and the source and documentation guards.

#### Remaining Work

None.

### Sprint 17.15: Durable prepared reverse-descent substrate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/internal/reverse-descent/HostBootstrap/Teardown/Preparation.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/durable_state.md`

#### Objective

Persist the exact prepared parent-to-child reverse descent before a recovery message is signed.

#### Deliverables

- The prepared record binds the plan, parent/child frames, verb, work item, continuation, and observation set.
- Canonical bounded bytes are written with compare-and-swap and strict readback.
- Exact retry converges; malformed, stale, cross-work, or cross-frame bytes refuse.
- Hidden folds derive the plan-owned lift context and recovery projection without caller coordinates.
- The substrate creates no child session, process, handoff binding, or completion evidence.

#### Validation

Dated 2026-08-11 teardown and durable-state tests, compile-fail/source guards, and warning-clean builds passed.

Before this sprint's 2026-11-12 extraction, the preparation refusals were covered only by source text.
The shared comment-stripping fix to the fragment helpers belongs to Sprint 12.31.

On 2026-11-12 the pure preparation decision was extracted and the focused preparation/source-guard
selection passed 80 tests on the SSD-backed Linux WSL2 instance. A second selection passed 5 cases,
including a real store-A command authority refused by the pure preparation decision for store B while B
retained its complete protected-record image, including the seeded sentinel. The actual stored-row
classification was separated into a pure production decision: a conflicting row in a real protected store
refused and retained its exact version and bytes (7 selected cases passed), and all 49 `TeardownSpec` cases
passed. The protected-entry publication and reauthorization remain in the kernel. On the same date,
`cabal test all -j12 --test-show-details=direct --test-options=--hide-successes` from `core/` passed
all 5,354 tests in 991.92 seconds. The subsequent kernel fixture uses real root, plan, catalog, cursor, and command evidence: the conflicting
row case refuses without changing the protected image, and a command and cursor minted in store A refuse
against store B without changing B's full image. All 51 `TeardownSpec` cases and 29 descent/source-guard
cases passed. The full core gate with the fixture then passed all 5,356 tests in 1129.86 seconds on
2026-11-12, including the recursive process-boundary cases. The package metadata change expired phase 16 evidence; Sprint 16.69 revalidated it on 2026-11-12. The kernel fixture requires additional private test-component
imports, expiring that evidence again; Sprint 16.70 completed the composed rerun on 2026-11-12.

#### Remaining Work

None.

### Sprint 17.16: Root prepared reverse-descent producer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Produce prepared reverse descent only from the exact root-resident entry and its next `DescentWork`.

#### Deliverables

- The reverse interpreter derives descent from its retained teardown forest rather than caller frame input.
- Production joins the exact root entry, verb, plan, parent, child, work, and continuation.
- The prepared row is durable and read back before any handoff action can observe it.
- Local work cannot enter the descent producer and sibling/ancestor evidence refuses.
- The producer exposes only a fixed continuation over the sealed prepared descent.
- Its refusal helper retains the enclosing work and result indices through an explicit scoped type.

#### Validation

Dated 2026-08-11 lifecycle-entry and teardown tests, source/compile-fail guards, and warning-clean builds passed.

The 2026-09-09 native Windows core gate passes 2,492/2,492 with GHC 9.12.4, including the exact
producer signature guard. The scoped refusal result also passes the GHC 9.10.3 published-base build
recorded in Sprint 17.10 and the formatter.

The `ProjectPlanSpec` producer-ordering label (near line 6540) says the producer exhausts Up and
recovery-child refusals, but `withPreparedRootReverseDescentKernel` has only the `RootUp`, `RootDown`, and
`RootDestroy` branches, and its trailing single-word fragments (`root`, `verb`, `plan`, `work`, `use`) match
as substrings of longer identifiers. The sprint closes when the guard below is corrected and the
warning-clean `cabal test all` from `core/` passes.

Closing evidence, 2026-11-09 (native Windows, GHC 9.12.4): the `ProjectPlanSpec` producer-ordering guard is
relabelled "the producer refuses Up before the two exact root branches" and its single-word trailing fragments
are deleted, leaving the exact call-shape assertions; `cabal test all` from `core/` passed.

#### Remaining Work

None.

### Sprint 17.17: Durable recoverable-open map and token repair [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Map an exact prepared reverse descent to one recoverable handoff opening and keep its token durable across
retries.

#### Deliverables

- A binding-keyed durable row `recovery-open.<digest>` maps one prepared reverse descent to one canonical
  recovery opening. Its version-1 `hostbootstrap/recovery-open-record` bytes carry the identity, the
  rendered binding, and the token.
- `registerRecoverableAdmittedHandoffEdgeKernel` mints the token once with `freshHandoffToken` (32 random
  bytes) when the map row is absent. Every later retry reuses the token stored in the map. The token cannot
  be recomputed from the binding, so it survives only through that row.
- Repair rewrites only the planned-edge token record, from the retained binding. A token record already
  `granted:` is never reused: the map advances by compare-and-swap to a freshly minted token, whose
  planned-edge record is written first.
- Compare-and-swap, strict readback, and bounded canonical rows govern absent, retry, and repair paths.
- Binding, token, projection, verb, phase, frame, or version drift refuses without opening another edge.
- The map owns no process, child store, executor, lifecycle settlement, or terminal receipt.

#### Validation

Dated 2026-08-11 focused handoff recovery/open tests, source guards, compile-fail checks, and warning-clean
library/test builds passed.

Before the later recovery cases below, `registerRecoverableAdmittedHandoffEdgeKernel` was covered only by
partial application and source fragments, and write failures could be reported as conflicts. Admitting the
failed-Up `up` verb is Sprint 17.53's.

On 2026-11-12, the exact-map and token readback classifications moved into pure private decisions used by the
real protected-entry path. A real recovery broker supplied a version-1 map and granted token; protected CAS
advanced the actual map, and the decisions refused stale-version and changed-byte snapshots and identified
the granted token as consumed. A separate value table covers exact, missing, changed, and consumed states.
The `readback` selection passed 14 tests and the `recoverable` selection passed 6, including source guards.
The complete `cabal test all -j12 --test-show-details=direct --test-options=--hide-successes` gate from
`core/` passed all 5,358 tests in 1131.47 seconds on the SSD-backed Linux WSL2 instance, including the
recursive process-boundary cases. The protected entry excludes cooperating concurrent writers; the race
outcomes are covered by the pure decision over actual before/after store snapshots, without a production
race hook.

2026-11-09 (native Windows, GHC 9.12.4): `writeExact` and `publishMap` (`Handoff.hs`) now keep the compare-and-swap
failure: when readback shows neither the exact written record nor any other record, they return
`Left (HandoffStoreFailure writeFailure)`, and a conflict only when a different record is present. The
`HandoffSpec` token-repair guard pins `readExactInitial ... writeFailure`; the full `cabal test all` from `core/`
passed.

`HostBootstrap.Handoff.Internal` is already selected into the test suite by its private mixin, so no new Cabal seam is
needed: `recoverySigningKernel` is a real, importable value. `HandoffSpec` "a recoverable open registers once,
retries exactly, and refuses each malformed coordinate" registers a recovery edge through a real
`withRecoveryBroker`, asserts that the first registration writes exactly two records (the map and the planned
token), that an exact retry returns the same binding and token and writes nothing, and that an empty adapter, an
adapter digest mismatch, a non-teardown phase, a non-recovery payload kind, an empty coordinate, and the `up`
verb each refuse with their exact error. The full `cabal test all` from `core/` passed.

`HandoffSpec` "a recoverable open rotates its token once the edge is granted and refuses a corrupt map" grants the
registered edge and asserts that the next exact registration returns a fresh token and binding with the map at
version 2, that a retry after rotation is stable, that a well-framed map with another domain refuses with
"the recoverable-open map is malformed or conflicting" and writes nothing, and that a map record the store cannot
serve (a directory at its path) yields `HandoffStoreFailure`. The full `cabal test all` from `core/` passed.

`HandoffSpec` "a recoverable open refuses a token row that is neither planned nor granted, writing nothing" replaces the
planned token row of a registered recovery edge with foreign bytes and asserts that the next registration refuses
with "the recoverable token record conflicts" and leaves the store unchanged. The full `cabal test all` from `core/`
passed.

#### Remaining Work

None.

### Sprint 17.18: Bound reverse-descent attachment [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/internal/reverse-descent/HostBootstrap/Teardown/Preparation.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Attach the exact authenticated recovery binding to its prepared reverse descent.

#### Deliverables

- Bound attachment joins the prepared bytes, binding, recovery projection, exact adapter payload, and token.
- Every repeated plan, parent/child, verb, phase, broker, and digest coordinate must agree.
- Planned-token retransmission and token-free observation rehydration remain distinct closed paths.
- The complete Prepared bytes are bounded and validated before Bound publication.
- The attachment exposes no store, token signer, raw observations, process, or settlement constructor.

#### Validation

Dated 2026-08-11 focused relay/teardown tests, four affected compile-fail groups, source guards, and
warning-clean builds passed.

The original scope comparison passed an unrecognised stable scope through unchanged. The correction and
its pending behavioural validation are recorded below.

On 2026-11-12, the offer-scope comparison moved to a pure private decision used by the bound kernel. The
`scope` selection passed 78 tests, including exact Production and Harness spellings and an unrecognised scope
refusing with `the recovery offer scope differs`. A source guard pins the closed mode, the lease-derived
journal scope, the plan-scope comparison, and the only production callers of acquisition construction;
there is no reachable prepared journal with an unrecognised scope to forge for an effectful test. The descent
selection passed 29 tests, the strengthened journal guard passed, and the documentation validator passed 22
tests. The complete `cabal test all -j12 --test-show-details=direct --test-options=--hide-successes` from `core/`
passed all 5,360 tests in 1010.43 seconds, including the recursive process-boundary cases.

2026-11-09 (native Windows, GHC 9.12.4): `recoveryHandoffScope` (`Teardown/Internal.hs`) is now total. It maps
`production` and `harness:<run>` through `productionScopeTag` and `harnessScopeTagFor`, returns `Nothing` for any
other stable scope, and the offer check compares `Just (handoffScope binding)` against it, so an unrecognised
scope matches no offer. The `TeardownSpec` source guard pins that shape and the full `cabal test all` from
`core/` passed.

#### Remaining Work

None.

### Sprint 17.19: Canonical lifecycle completion wire [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Define the bounded canonical report, acknowledgement, and typed reverse-observation codecs.

#### Deliverables

- The handoff facade encodes exactly the six forward/reverse completed/refused/failed report branches.
- Every report and acknowledgement has a bounded canonical frame shape and exact binding commitment.
- Completed reports derive their origins from strict terminal state; nonterminal reports cannot become proof.
- Reverse observation rows preserve ordered unique keys and their closed outcome table; the hidden verifier
  derives the exact bound descent and plan-owned observation origin without exposing store authority.
- `Teardown` and its lower verifier map typed outcomes into the codec without introducing a dependency cycle
  or performing settlement.

#### Validation

Dated 2026-08-12 evidence includes focused Handoff and Teardown codec cases, compile-fail 452/452, the complete
suite 1913/1913, and `DocValidatorSpec` 2/2. The corrected three-module attribution is 385 significant lines:
the original 323-line public codec slice plus the 62-line hidden bound-observation verifier.

The `teardownObservationsFromWire` refusal for an unknown outcome (`Teardown.hs`, near line 1223) is
unreached by any test. The receive-side "over bound" cases (`HandoffSpec`, near lines 1777 and 1954) feed
all-zero bytes that the domain and frame checks refuse without the bound, and the terminal-origin negative
cases (near line 1845) accept any `Left` with no positive control. `validateLifecycleBranch` (`Handoff.hs`)
accepts forward-only `succeeded` rows in a reverse failed report, which no teardown decoder admits. The sprint
closes when the change and cases below exist and pass in the warning-clean `cabal test all` from `core/`.

2026-11-09 (native Windows, GHC 9.12.4): `TeardownSpec` "typed decoding refuses a well-framed row whose status is
not a teardown status" renders `[("one", "succeeded", "none")]` and asserts `Left (TeardownObservationWireRefused _)`;
the full `cabal test all` from `core/` passed.

`HandoffSpec` "observation and enclosing report bounds apply to the complete wire" now pads a well-formed observations
wire and a well-formed acknowledgement past `maxWireBytes` and asserts "lifecycle observations exceeds the wire
bound" and "lifecycle acknowledgement exceeds the wire bound", so deleting either `bounded` call fails it. "terminal
origins enforce exact fields, versions, and every reverse binding join" now asserts each of the ten forward and
thirteen reverse mutations against its exact `HandoffBindingMismatch` message. The full `cabal test all` from
`core/` passed with every case above.

#### Remaining Work

None.

### Sprint 17.20: Lower sealed completion ownership [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-completion/HostBootstrap/Handoff/Completion.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (completion module registration)
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Keep semantic completion evidence inside the lower authenticated handoff owner.

#### Deliverables

- Hidden `Handoff.Completion` owns nominal `LifecycleCompletion` and its sealed lower surface.
- Forward completion requires the terminal-origin/config-offer binding; reverse completion requires exact
  Bound verification and the same plan's subtree settlement.
- Canonical report bytes carry observations, not a child-local store, acquisition cursor, or command authority.
- Receiver consumes the authenticated terminal-report action and constructs no completion evidence.
- The root `LifecycleEntry` is reachable only by the command owner; nested execution uses rooted grants.

#### Validation

`HandoffSpec` exercises canonical report and acknowledgement codecs, exact bindings, and the rooted terminal
receipt. `ProjectPlanSpec` guards root-only lifecycle entry and storeless child execution, including negative
source fixtures. `CLISpec` checks the separator-neutral `LifecycleEntry` importer set. Compile-fail fixtures
refuse public construction and import of private completion authority.

Before the 2026-11-09 correction, reverse refusal and failure details were lost after acknowledgement,
and the receiver wrapped asynchronous `UserInterrupt` as synchronous. The earlier child-authority guards
checked retired identifiers rather than the live cursor users.

On 2026-11-12, the existing completion owner was moved into a private Cabal component so its actual kernels
can be tested. The package-description change expired phase 16 evidence; Sprint 16.71 revalidated the composed
gate on 2026-11-12. The actual forward and bound-reverse completion kernels now have wrong-direction,
refused, failed, and binding-mismatch cases; the `completion` selection passed 36 tests. A consolidated
retired-identifier table and child-executor cursor-user guard each passed, and the private-owner selection
passed 192 tests. The complete `cabal test all -j12 --test-show-details=direct --test-options=--hide-successes`
from `core/` passed all 5,358 tests in 1012.87 seconds on the SSD-backed Linux WSL2 instance, including the
recursive process-boundary cases. The documentation validator passed 22 tests.

2026-11-09 (native Windows, GHC 9.12.4): three production changes landed and the full `cabal test all` from `core/`
passed. `Handoff/Completion.hs`'s reverse kernel now acknowledges a refused or failed child and then returns
`Left ("lifecycle completion: the reverse child " <> status <> ": " <> detail)`, as the forward kernel does.
`Handoff/Relay.hs` classifies an acknowledged-then-refused terminal callback as `RelayLifecycleCallbackRefused
reason`, so the callback's text reaches the operator, and the `HandoffSpec` terminal-persistence guard pins it.
`Handoff/Receiver.hs` `runTerminalAction` rethrows with base `Control.Exception.throwIO`.

`HandoffSpec` "a terminal callback that throws UserInterrupt escapes the receiver unwrapped" runs a scripted receiver
whose terminal continuation throws `UserInterrupt` and asserts that the exception escaping is `UserInterrupt` itself.
An asynchronous exit is not announced as a child refusal (the receiver's `try` does not catch it), so the parent sees
silence, not a refusal. The full `cabal test all` from `core/` passed.

#### Remaining Work

None.

### Sprint 17.21: Root-resident parent acknowledgement substrate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Persist exact parent Reported, Acknowledged, and Adopted stages in the root-owned store.

#### Deliverables

- Parent rows derive their stable keys and canonical bytes from the exact binding, report, and acknowledgement.
- Root-broker admission, grant transcript equality, compare-and-swap, and strict readback guard every stage.
- Absent creation and concurrent retry converge only on the exact lawful root-resident successor.
- Fixed-unit branches expose no broker, store, durable row, disposition, or caller-selected result.
- This completed substrate makes no child-store, child-receipt, routed-message, or process-runtime claim.

#### Validation

Dated 2026-08-11 evidence includes the focused durable-acknowledgement cases 3/3, `HandoffSpec` 66/66,
protected-store cases 9/9, compile-fail 447/447, the complete suite 1901/1901, and `DocValidatorSpec` 2/2.

The parent-acknowledgement source guard retains exact tag/field tables, real child send/receive and
acknowledgement clauses, redaction, closed exports/datatypes, importer/caller/producer inventories, and
ordered assertions. Its only Protocol definition freeze is the wholly owned `requireAcknowledgement`
clause, encoded as 45 tokens / 483 ordered Aeson bytes with fixed saved-baseline digest
`116088b6fbcb48a1e31e920b6c8146362c6923fed4eec178e186f3ee28587b54`. The independent Handoff attribution
remains 343; the original `(343, 71, 414)` tuple and original budget remain dated 2026-08-11 evidence rather
than a current whole-Protocol line count or unchanged-complement subtraction. These source checks do not
replace the store-backed row-kernel obligations below.

No test runs the four row kernels (`publishLifecycleReportKernel`, `receiveLifecycleAcknowledgementKernel`,
`prepareLifecycleAcknowledgementKernel`, `adoptLifecycleAcknowledgementKernel`) on values: they appear only as
forced partial applications, source fragments, and a compile-fail export list. `HandoffSpec` "durable
lifecycle rows are exact, transcript-bound, convergent, and callback-safe" (near line 2309) reads source only,
and the convergence guards (near line 2612) pin guard order but not each guard's disposition (`Right False`
pending, `Right True` already adopted) or written-version check. The row writers (`publishChildRow`,
`prepareParentRow`, `adoptParentRow`, `writeLifecycleRow`) turn a compare-and-swap store failure into
`lifecycleRowConflict`. The sprint closes when the change and cases in Remaining Work exist and pass in the
warning-clean `cabal test all` from `core/`.

2026-11-09 (native Windows, GHC 9.12.4): the row writers (`prepareParentRow`, its `advance`, `publishChildRow`,
`adoptParentRow`, `writeLifecycleRow`) now return `Left (HandoffStoreFailure writeFailure)` when a rejected
compare-and-swap leaves no row or leaves the unchanged predecessor, and keep `lifecycleRowConflict` for a different
row actually present. The `HandoffSpec` durable-row guard's frozen line measurement is updated to 450; the full
`cabal test all` from `core/` passed.

`HandoffSpec` "child lifecycle rows publish, converge, receive, and refuse conflicts against a real store" drives
`publishLifecycleReportKernel` and `receiveLifecycleAcknowledgementKernel` with the already-selected
`HandoffInternal.recoverySigningKernel` against a real protected store: a fresh publish and an exact re-publish
converge, a different report under the same binding conflicts, receive and a repeated receive converge, a late
re-publish converges, a report naming another store refuses with "the lifecycle report names a different protected
store", and receiving a never-published report finds no row. The full `cabal test all` from `core/` passed.

`HandoffSpec` also drives the parent kernels against a real store, broker, and granted edge: "parent lifecycle rows
advance one to two to three and answer pending, fresh, and replay exactly" asserts the row at versions 2 then 3,
repeated pending answers, the fresh continuation once, and the replay continuation (writing nothing) for an exact
version-3 replay and a late prepare; "of two concurrent adopters exactly one is the fresh winner" runs two adopters
and asserts one fresh and one replay; and "parent lifecycle rows refuse an ungranted edge, an unprepared adoption,
and a foreign row" asserts the exact refusal text for an ungranted edge and an unrecognised challenge, the conflict
for adopting a never-prepared row, and a byte-identical store after a foreign row conflicts. The durable-row source
guard is retitled a placement check. The full `cabal test all` from `core/` passed.

`HandoffSpec` "a store that cannot write a lifecycle row reports a store failure, not a row conflict" places a
directory where the child row, then the parent row, belongs and asserts `HandoffStoreFailure` from
`publishLifecycleReportKernel` and `prepareLifecycleAcknowledgementKernel`. The full `cabal test all` from `core/`
passed with every case above.

#### Remaining Work

None.

### Sprint 17.22: Routed acknowledgement transport substrate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Provide the structural root-routed acknowledgement/adoption ordering without claiming an integrated runtime.

#### Deliverables

- Relay joins the exact authenticated edge, binding, report, acknowledgement, and root parent stage.
- The structural order is report preparation, direct acknowledgement attempt, then conditional root adoption.
- Fresh and replay branches suppress duplicate semantic-construction callbacks.
- Fixed-unit continuations expose no raw channel, store, durable stage, disposition, or completion constructor.
- The substrate owns no child persistence, process, receiver loop, descriptor, signal, timeout, or reap behavior.

#### Validation

Dated 2026-08-11 focused Relay lifecycle tests, `HandoffSpec`, source/compile-fail guards, and the warning-clean
core gate passed. The evidence is limited to structural routing and root-resident durable ordering.

Before the repairs below, the "exactly seven/five canonical frames" cases (`HandoffSpec`, near line 3102) pin guard text whose effect
lives in `requireLifecycleRelay`, `requireLifecycleDisposition`, and `exactLifecycleFrames`, which no test
runs; the one-shot terminal gate case (near line 3497) never pins the refusing then-branch or the
`fixedPersistFailure` consumer; the Relay line-budget "freeze" (near line 3296) compares constants and never
measures `Relay.hs`; and "BrokerLink carries only a fixed-unit raw acknowledgement continuation" (near line
3088) is a contains check. `runLifecycleTerminal` records the adopt-stage replay disposition before
`AcknowledgedTag` is sent, so a failed send on the pending branch is classified as success. The subsequent evidence records those repairs.
Sprint 17.36 adopts the Phase 13 rooted protocol into the relay service.


2026-11-09 (native Windows, GHC 9.12.4): `runLifecycleTerminal`'s pending branch now keeps its adopt-stage
disposition in a local (`adoptedStage`) and records it only after `sendAcknowledgement` succeeds, as the
already-Adopted branch does. The `HandoffSpec` terminal-persistence guard pins the new shape and its Handoff
attribution measurement is 355; the full `cabal test all` from `core/` passed. At that point the Haddock still owed a sentence on
how a replayed non-completed report is classified.

`renderLifecycleAcknowledgementResponse` and `withLifecycleAcknowledgementResponse` are now exported from the
hidden `HostBootstrap.Handoff.Relay`, which the test suite already selects, and the `HandoffSpec` Relay export
inventory names them. `HandoffSpec` "the relay's lifecycle response codec accepts only its exact canonical wire"
asserts that the canonical `fresh` and `replay` responses reach their own continuations, and that a wrong domain,
version, stage, disposition, or acknowledgement ("the lifecycle response differs from the exact request"), a
trailing byte or a sixth field ("the lifecycle envelope has trailing bytes"), and a truncated wire each refuse with
no continuation run. The full `cabal test all` from `core/` passed.

`runLifecycleTerminal`'s Haddock now states that a callback refusal after a successful acknowledgement is carried as
`RelayLifecycleCallbackRefused`, that a replayed report is acknowledgement-only with its disposition recorded after
the send, and that a replayed non-completed report is classified exactly like a replayed completed one. The
`HandoffSpec` Relay guards no longer carry tautological line-count constants: the terminal-relay figure is measured
from the live source (2728 significant lines), and the `BrokerLink` guard asserts its exact 14-field list. The full
`cabal test all` from `core/` passed.

2026-11-12, `hostbootstrap-linux-ssd`: The request renderer and parser now have cases against a genuine root
route; 50 codec-selected cases passed. A genuine duplex relay with a protected report exercises repeated and
late terminal persistence, and a closed output exercises a pending acknowledgement transmission failure;
37 persistence-selected and six pending-selected cases passed. The terminal callback intentionally receives
the fixed unavailable failure and the outer relay reports `RelayLifecycleCallbackAfterAcknowledgement` after
a failed send; the internal pending continuation returns `RelayLifecycleTransmissionFailure`. The full core
gate passed all 5,361 tests in 1,061.94 seconds before the final extraction.

The production pending continuation and its send operation now live in the existing private Relay module.
Seven pending-selected cases passed, including a real granted edge, protected report and failed pipe returning
`RelayLifecycleTransmissionFailure` without recording a disposition. The earlier full gate predates this change;
the measured Relay source-size guard is updated; 37 persistence-selected and 85 sealed-facade-selected cases
passed. The final warning-clean `cabal test all` from `core/` passed all 5,362 tests in 1,046.11 seconds.

#### Remaining Work

None.

### Sprint 17.23: Finalized forward-child projector foundation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Construct/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (build metadata only)
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Give every finalized project an acyclic project-owned child-plan projector.

#### Deliverables

- Real-project construction installs exactly one forward-child projector; missing or duplicate installation
  refuses.
- Hidden construction ownership retains the static builder and projector at the exact finalized scope.
- The fixed projector kernel validates canonical child configuration before its fixed callback.
- The pure projector exposes no canonical-root constructor, raw config bytes, runtime owner, or generic fold.
- This sprint adds no named type; the projector's one production caller is the shared immediate-target
  projection kernel (Sprint 17.25).

#### Validation

Dated 2026-08-11 evidence includes `CLISpec` 52/52, `ProjectPlanSpec` 67/67, `SchemaSpec` 21/21,
compile-fail 449/449, the complete suite 1909/1909, and `DocValidatorSpec` 2/2.

The source guard retains exact exports, hidden-owner/constructor boundaries, importer/user/type
inventories, projector ordering and CLI installation fragments. Its Construct freeze covers only the
five forwarding declarations `withFinalizedProjectSpec`, `withHarnessFinalizedProjectSpec`,
`withFinalizedProjectSpecParts`, `finalizedProjectCodec` and `finalizedProjectServices`: the saved-baseline
typed tokens and complete clauses encode to 2,458 ordered Aeson bytes with fixed digest
`c49bb152f01599b443a774dc506b11655665f209a31f3ab11b2b14f38c2326bd`. The actual private-owner
hash/count and one metadata registration remain independent controls.

Dated 2026-11-01 bookkeeping records Construct 631, private owner 226 and the shared CLI/later allowances
as source 216 plus metadata one, 217 total, below 400. These figures are dated attribution, not a live
whole-Construct hash, size pin or subtraction of another owner's edit. The remaining CLI count proxy
and separate forward-package size assertions are addressed by their own Remaining Work below.

`CLISpec` proves missing and duplicate installation refusals; source observations alone do not prove
that the retained projector runs or that the bare CLI selects its default refusal. The sprint closes
when those runtime cases and the remaining scoped source policies pass the warning-clean gate. This
owned-scope adoption changes no status or dated execution record.

2026-11-12, `hostbootstrap-linux-ssd`: The real one-layer catalog admission records invocation of the
installed projector before the first effect; 78 admitted-selected cases passed. The bare plan invokes the
same private default projector refusal as the CLI; 22 bare-selected cases passed. Comment-stripped tokens
pin both CLI installation paths and the frame-child classifier. The shared CLI size proxies and redundant
forward-package `< 400` comparison were removed, retaining the fixed 339-line measurement and independent
ownership checks. The private finalized-plan owner now measures 230 significant lines and its updated SHA-256
is `96ebc7735826269a748af76ded63cd403cef9e64c666d52607f7b922de43bf58`. Four forward-child, five
specification-index, 28 crossing, and 85 sealed-facade cases passed. Phase 16's composed gate passed the
full warning-clean core suite (5,362 tests, 1,031.22 seconds) and the live Kind case (1/1).

#### Remaining Work

None.

### Sprint 17.24: Exact projected child plan [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Handoff/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Context/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (build metadata only)
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Turn an independently projected child configuration into an exact canonical child plan whose lineage the
catalog can admit.

#### Deliverables

- `Lifecycle.Plan`'s projected-plan kernel (`withProjectedProjectPlanKernel`) turns the finalized projector's
  output into a canonical child configuration, child plan, digest, and `PlanDigestBinding`, and refuses a
  projected root that is not a canonical POSIX descriptor (`canonicalProjectedRootKernel`, reported as
  `PlanProjectedRootInvalid`).
- Exact parent/current/context lineage and the topology's immediate parent-to-child edge are proved by the
  shared immediate-target kernel (Sprint 17.25); the only forward package built on it is the catalog-admitted
  `CatalogForwardHandoff` (Sprint 17.29).
- No standalone single-edge forward package and no nested lifecycle-context eliminator stand in the library:
  `ProjectPlan/Handoff/Internal.hs` holds only the catalog package, and `Lifecycle/Context/Internal.hs`
  refines a context only to the root frame.
- Work is limited to the named production modules plus one Cabal row and adds no named type.

#### Validation

Dated 2026-08-12 evidence includes `ProjectPlanSpec` 68/68, `HandoffSpec` 68/68, compile-fail 451/451, the
complete suite 1912/1912, and `DocValidatorSpec` 2/2. Frozen hashes are
`5c23bb6d9eaed3baa18e7028893134684a34d559c545f34ba2def2237b180654` for `Lifecycle/Plan.hs` and
`eed529e4f5dbdbcade0364cf372136b30f43714810094d8e0ca38d4ed16a054a` for
`ProjectPlan/Handoff/Internal.hs`.

Before the changes below, `PlannedForwardHandoff`, `withPlannedForwardHandoffKernel`,
`withPlannedForwardProcessInputsKernel`, and `withValidatedNestedLifecycleContext` stood in the tree with
no caller and no behavioural test. `PlanProjectedRootInvalid` is produced by no test: every behavioural
projector returns an already canonical descriptor. The sprint closes when the deletion and the case in
Remaining Work land and pass in the warning-clean `cabal test all` from `core/`.

2026-11-12: The standalone forward package and nested-context eliminator and their obsolete compile-fail case
are removed. The projected-root table passed 23 selected cases and the context selection passed 140; the
remaining projection inventories were updated after a targeted run identified stale package references.
Architecture and legacy-tracking references are updated. The updated projection guards passed all 84
projection-selected cases. The full core gate result follows.

2026-11-12: `cabal test all -j12 --test-show-details=direct --test-option=--hide-successes` from
`core/` passed all 5,361 tests in 1,015.66 seconds on the dedicated SSD-backed Linux WSL instance.

#### Remaining Work

None.

### Sprint 17.25: Recursive rooted plan catalog [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/RootedPlan.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Projection/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Handoff/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Construct the root-owned recursive catalog before any remote frame can perform a lifecycle effect.

#### Deliverables

- Hidden all-nominal `RootedPlanCatalog scope rootPlanId brokerGeneration catalogId` is the sole named type
  this sprint introduces. Its base retains the root evidence and each extension retains one admitted descent,
  so the catalog is its own entry carrier and neither constructor is nameable outside the hidden module.
- Construction consumes the exact finalized specification, root invocation authority, root plan and current
  frame, and root-resident lifecycle context. It rechecks root residency, the supplied/retained/project frame
  evidence join, the admitted context endpoint, and the authority's installed project, durable store
  identity, and broker epoch against the root plan's before recursively projecting every declared child, so
  the catalog's durable record name and manifest, which key on the plan's epoch, never name an epoch other
  than the authority's.
- One VLC-free immediate-target kernel owns descriptor/context/configuration/target-plan validation for
  recursion, and the nested forward child's route derivation in `Command.Child` delegates to that same
  kernel. Its Direct host-container rebase compares the whole `ContainerLift`, placement included, apart from
  the one permitted rebased mount.
- Each rank-2 entry binds the existential exact target `ProjectPlan`, `PlanDigestBinding`, `CurrentFrame`, raw
  and stripped plan-owned route, canonical config bytes, both config/payload digests, parent/child edge, and
  the parent frame's plan-owned projected node keys needed by later packages and the local executor.
- Recursion terminates at a frame that declares no descent and is bounded by the root topology's own frame
  count, so a malformed topology refuses rather than descending without end.
- Catalog selection is available only through rank-2 folds on the catalog itself, and every exported fold has
  a production caller; no second entry/evidence type, raw row, child-supplied plan, or nested
  `ValidatedLifecycleContext` route is introduced. Edge selection by exact parent and child frame, with its
  missing, duplicate, and sibling refusals, is `withRootedPlanCatalogEdgeKernel`'s (Sprint 17.29).
- Work is limited to the three named production modules, targets at most 400 significant lines, and must split
  before exceeding that bound; it adopts no runtime call site.

#### Validation

The catalog and the shared kernel are hidden `other-modules`, so a test executable cannot name either one.
Their runtime callers are the root entry's construction call site (Sprint 17.28) and the reverse entries'
sealer (Sprint 17.30). Their direct coverage is exact source and compile-fail guards: export lists,
Cabal placement and hiddenness, the complete import set and dependency direction, the sole `data`
declaration, the four nominal roles, the producer's rank-2 signature, the ordered admission fragments, and
the absence of store, journal, cursor, process, and mutable-state identifiers. `ImportLifecycleRootedPlan`,
`ImportProjectPlanProjectionInternal`, `OpenRootedPlanCatalog`, and `OpenImmediateTargetProjection` pin the
hidden-module and no-public-export boundaries. Behavioural canonical ordering, digest/key binding, descent
refusal, and rank-2 selection are owned by Sprint 17.28, which installs the first root entry call site
through which a test can reach the catalog; positive multi-level admission is owned by Sprint 17.29, which
carries the projecting forward-child fixture that admission needs.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-12 at
`1950 tests passed`.

The sprint closes when `ProjectPlanSpec` pins `admitRoot`'s epoch refusal after the store-identity refusal and
before `descendRootedPlanCatalogKernel`, the owner's export list omits
`withRootedPlanCatalogEntryKernel`, and the catalog owner's significant-line guard asserts the 400-line split
boundary rather than 425, `directContainerRebase` compares placement, and the per-row projection and Direct
rebase cases in Remaining Work pass; then `cabal test all` from `core/` and `demo/`,
`poetry run python -m hostbootstrap.check_code`, and `poetry run python -m hostbootstrap.test_all` pass.

2026-11-12: The root catalog rejects a foreign broker epoch after store identity validation, and its unused
selector is removed. Direct rebasing checks the entire container constructor, including placement. The
real CLI catalog cases admit Incus, Lima, WSL2, and Direct container projections, verify the derived
placements, refuse three nested VM placements and a multi-layer edge, and cover one valid writable rebase
and 16 exact field/mount refusal rows before any catalog or effect. Catalog/projection, provider, nested,
and rebase selections passed. On the dedicated SSD-backed `hostbootstrap-linux-ssd` WSL2 instance, the
four-command host-static gate passed: `cabal test all` from `core/` (5,366 cases, 1,038.71 seconds),
`cabal test all` from `demo/` (169 demo and 5,366 core cases, the latter 1,001.66 seconds),
`poetry run python -m hostbootstrap.check_code`, and `poetry run python -m hostbootstrap.test_all`
(384 cases, 100% coverage). The instance uses an SSD-backed Linux virtual environment bind-mounted over
the host's Windows `.venv` and has `python-is-python3` installed.

#### Remaining Work

None.

### Sprint 17.26: Digest-proven codec and registry reindex [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Class/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Service/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Schema/Internal.hs`,
`core/hostbootstrap-core/test/SpecIndexSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Relabel the specification phantom of the two indexed carriers a finalized specification retains, and only
after their digests are proved equal.

#### Deliverables

- `ProjectCodec scope specDigest cfg` and `FinalizedServiceRegistry scope specDigest (cfg scope)` each keep a
  nominal specification index, so a value admitted under a durably recovered index and one finalized in this
  invocation are distinct types even when their digests are equal. Reindexing either one needs its hidden
  constructor, and both constructors currently sit inside exposed modules, so each carrier gets a hidden
  `.Internal` owner for its representation while its existing module keeps re-exporting the abstract type and
  every producer and eliminator it already exports.
- Each hidden owner gains one reindex kernel consuming the existing digest-equality token, which gains one
  accessor so every carrier reads its target digest from the token rather than from a second source. The
  kernel changes only the phantom: the retained label, schema, digest, decoders, renderers, and the finalized
  registry's identities, role codecs, and handlers are preserved unchanged.
- The finalized registry retains the exact digest its finalization stamped, so a project that registers no
  service is proved equal before relabelling rather than relabelled vacuously.
- Neither kernel is reachable from a public facade, and neither admits a caller-selected index or a token
  minted from unequal digests.
- Work adds no named type and adopts no call site. The split is additive: no existing export is removed and
  no consumer of either module changes.

#### Validation

`SpecIndexSpec` proves each hidden owner's exact export list, its `other-modules` placement, that its only
importer is the facade that re-exports it, its complete import set, its sole `data` declaration and nominal
roles, its exact reindex signature, the ordered equality-then-relabel fragments naming every preserved term,
the refusal branch, and that the token accessor is the only comparison source. It pins the token owner's own
mint/accessor shape and its four importers, proves no public module exports either kernel, the codec
representation, or a finalized definition, and pins both facade export lists unchanged.
`ImportConfigClassInternal.hs`, `ImportServiceInternal.hs`, `OpenProjectCodecReindex.hs`,
`OpenFinalizedServiceRegistryReindex.hs`, `CoerceProjectCodecSpec.hs`, and
`CoerceFinalizedServiceRegistrySpec.hs` pin the hidden-module, no-public-export, and nominal-index
boundaries.

Both kernels are hidden, so a test executable cannot name either one. Their runtime callers are Sprint
17.27's joined reindex, reached through the public recovered-inputs boundary, and the finalized registry's
activation path in `Service.hs`. Sprint 17.27 covers reindex on equal digests and preservation of every
retained term behaviourally. Refusal on unequal digests happens earlier, when the token is minted: the
recovered-inputs boundary mints the token from the codec's own digest and refuses an unequal finalized
specification there, as `"finalized specification"`. The codec kernel's comparison therefore cannot refuse
through that call site, and the registry kernel refuses (`"finalized specification carriers"`) only when the
registry's retained digest differs from the codec's, which no fixture constructs. The refusal branches of
both kernels have no behavioural case and are pinned by the `SpecIndexSpec` source guards above.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-12 at
`1960 tests passed`.

The `SpecIndexSpec` guards are weaker than the boundaries they name. Its importer corpus reads only `src`, not
the main library's second source root `internal/cluster-backend`; `exportedNames` drops `(`, `)`, and `..`,
so `ServiceId` and `ServiceId (..)` compare equal, and `modulesExporting` cannot see a `module M` re-export;
the token-authority case never reads `Config.Schema.Internal`'s own export list, so exporting
`RecoverySpecReindex (..)` passes; its fragment helpers match comment-bearing raw text; and the module header
says the behavioural join is deferred, though `ProjectPlanSpec` covers it. The sprint closes when the guards
in Remaining Work are corrected and pass in the warning-clean `cabal test all` from `core/`.

2026-11-12: The redundant one-sided enumeration was removed. The guards now scan all named implementation
roots, retain export punctuation, reject public module re-exports and exposed abstract constructors, check
the token export and importer occurrence counts, and compare comment-stripped Haskell tokens. These changes
passed five specification-index cases, including comment-only and constructor-export adversarial checks.
The existing public `HostBootstrap.Effect` and `HostBootstrap.Substrate.Provider` facades intentionally
re-export effect modules, so an unconditional ban would reject the current product surface. Instead the
guard allows only those exact reviewed re-exports, expands their actual export lists when checking protected
names, and rejects nested or unreviewed re-exports. The subsequent full core gate result follows.
The first full core attempt passed 5,364 of 5,366 cases in 1,015.55 seconds; two portability guards found
local path-separator handling in the new inventory. It now uses the shared cross-platform library source
reader and repository-relative path helper. Five specification-index, ten separator-selected, and one
comparable-path-selected cases passed; the subsequent full gate passed as recorded below.

2026-11-12: The final warning-clean `cabal test all` from `core/` passed all 5,366 tests in 1,022.61
seconds on the dedicated SSD-backed Linux WSL instance.

#### Remaining Work

None.

### Sprint 17.27: Recovered finalized-specification reindex [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Construct/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Make the exact finalized specification available at each root plan's own specification index, in both root
`project up` entries.

#### Deliverables

- A recovered plan carries the recovered specification index while the invocation's finalized specification
  carries the candidate index. One hidden reindex kernel joins the lower codec and registry reindexes under
  the same digest-equality token and preserves the retained plan builder and forward-child projector, which
  are specification-index-free already.
- The recovered-inputs boundary yields that reindexed specification alongside the recovered configuration and
  drafts, so the recovered and fresh root entries both hold a specification at the exact index their plan
  retains.
- `Command` threads that exact specification through both root `project up` entries without widening the
  command surface, duplicating the specification, or admitting a caller-selected index. The shared bound body
  proves the threaded specification's digest is the bound plan snapshot's before any lifecycle effect, so a
  recovered index that reached the entry without its own digest-proven relabelling refuses.
- Work is limited to the four named production modules, adds no named type, and adopts no catalog, session,
  journal, or process call site.

#### Validation

2026-11-12, dedicated Ubuntu WSL2 instance on x86_64 Windows, GHC 9.12.4 and Cabal 3.16.1.0:
`cabal test hostbootstrap-core-test --test-option=--pattern=recovered` passed 44 cases; the full
`cabal test all -j12 --test-show-details=direct --test-option=--hide-successes` from `core/` passed
5,368 core cases in 1001.52 seconds. The optional live provider suite correctly reported its confirmation
was not requested; phase 15 owns that live gate.

The recovered builder and candidate drafts yield the same successful canonical snapshot bytes. Empty
registries recover, while a non-empty recorded registry and empty candidate refuse as `finalized specification`.
A test-only representation mirror uses `unsafeCoerce` to pair a genuine independently finalized foreign
registry with the candidate codec, exercising the real recovered-inputs boundary and its exact
`finalized specification carriers` digest refusal. The production constructor remains hidden. The fixture
comments now describe the recorded registry accurately. Existing compiler and ownership guards run in the
full gate.

#### Remaining Work

None.

### Sprint 17.28: Root catalog persistence and readback [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/RootedPlan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Persist and re-open the exact recursive catalog under the global root invocation lease.

#### Deliverables

- `Command` threads the exact finalized specification into the one root-entry call site, which both the
  Production and Harness `project up` lanes share. The entry constructs the recursive catalog and writes one
  bounded canonical manifest keyed by the root plan's installed project, stable profile, and broker epoch.
- The catalog owner renders that manifest and strictly compares an observed one; it names no store, session,
  record, or compare-and-swap operation, so durable authority stays with the root entry alone. Every
  variable-width value is length-framed, every list carries an explicit count, and both an admitted-edge
  ceiling and a byte ceiling are refusals rather than truncations. A raw configuration payload is never
  present.
- Compare-and-swap and strict readback make exact retry convergent and conflicting catalog bytes a refusal.
  The decision comes from the readback rather than from who won the swap, so a compare-and-swap loser
  converges on the record already present.
- The journal has already revalidated the live global lease, protected snapshot, and plan digest when the
  catalog is admitted, so the manifest comparison joins that live evidence to the catalog's own digest,
  lineage, and complete entry ordering. It runs before the command reservation and before any lifecycle
  effect.
- The root Up entry retains the exact catalog, and later consumers reach its root evidence and admitted
  descent entries only through the owner's rank-2 folds — never a raw row, record, or store handle. The
  producer's continuation result narrows to the entry's own `Either String ()`, so the one call site no
  longer folds an optional result.
- Work is limited to the three named production modules, adds 175 significant lines, adds no named type, and
  adopts only the one root-entry construction/persistence call site.

#### Validation

2026-11-12, dedicated Ubuntu WSL2 instance on x86_64 Windows, GHC 9.12.4 and Cabal 3.16.1.0:
the catalog-focused core tests passed 10 cases, including the exact retry diagnostic and an actual
permission-denied catalog publication after operator authorization. The latter reports the protected-store
publication error, creates neither a catalog nor a reservation, and runs no lifecycle effect. A conditional
capability probe records a refusal on hosts that cannot make the fixture directory read-only.

The full `cabal test all -j12 --test-show-details=direct --test-option=--hide-successes` from `core/`
passed 5,369 core cases in 979.14 seconds. The optional live provider suite reported its confirmation was
not requested; phase 15 owns that live gate. Exact readback still decides a compare-and-swap version-mismatch
loser's outcome; all other publication errors retain their store diagnostics.

#### Remaining Work

None.

### Sprint 17.29: Catalog-admitted forward package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/RootedPlan.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Handoff/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Create the storeless forward package used only after an edge is admitted by the recursive catalog.

#### Deliverables

- New hidden all-nominal `CatalogForwardHandoff scope rootPlanId brokerGeneration catalogId parentFrame
  childPlanDigest childConfigId childFrame` is this sprint's sole named type.
- Planned child config, payload/config digests, child plan digest, topology edge, and projected keys must match.
- Its catalog-only producer retains the sealed route/input/payload fold and no lifecycle context, store,
  catalog row, process, or effect authority; it is the library's only forward package.
- Missing, duplicate, sibling, stale, or independently projected data refuses before session/process creation.
- Work is limited to the two named production modules, targets at most 400 significant lines, and adopts no
  process or command call site.

#### Validation

2026-11-12, x86_64 Windows 11 with GHC 9.12.4 and Cabal 3.16.1.0: the catalog-focused run passed
17 cases, including one behavioral case for each of the seven forward-package rechecks. Every case first
admits a real edge, then injects exactly one drift through the private fixture, asserts its exact refusal,
confirms the package callback was not entered again, and compares the protected-store image. The cases cover
child current frame, configuration endpoint, configuration digest, payload digest and bytes, child plan
binding, and a stripped route with zero layers. The multiple-layer route remains covered by the existing
source guard. `cabal test all -j8 --test-show-details=direct --test-option=--hide-successes` from `core/`
passed all 5,376 tests in 788.37 seconds.

The catalog representation is owned by a non-exposed module; only the private test fixture and the catalog
owner import its constructor. The forward-package owner resides in the private implementation sublibrary,
and the public facade still exposes neither its constructor nor the fixture. The source ownership and
compile-fail guards passed. The Cabal metadata change expired phase 16 evidence; sprint 16.73 refreshed it.
Linux WSL attempts were initially interrupted by host-wide low virtual memory. The later phase 16.74
core gate passed all 5,377 cases on linux-cpu, including the seven catalog rechecks and six recursive
process-boundary cases; phase 17 must still rerun its own gate when all its sprints close.

#### Remaining Work

None.

### Sprint 17.30: Catalog-produced recovery child package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Produce Phase 13's `RecoveryChildPackage` only from a catalog-admitted reverse descent and route its exact
Offer to the root signer already installed in the private relay.

#### Deliverables

- The sole application producer joins exact prepared/Bound descent evidence to the matching rank-2 catalog
  parent/child selection; `Teardown.Internal` consumes that selection, while `RootedPlan` imports neither
  `Teardown.Internal` nor `Lifecycle.Session`.
- Canonical child-config and adapter bytes come only from the selected catalog entry and plan-owned recovery
  projection. The producer invokes Phase 13's frozen neutral constructor, and catalog-backed `EdgeAdmission`
  exact-matches the complete package configuration and payload digest while `RecoveryAdmission` independently
  authenticates only the extracted adapter.
- Prepared/Bound reverse input, persisted binding, and `HandoffOffer` payload/digest all name the complete
  canonical `RecoveryChildPackage`, never the adapter alone. The complete-package and
  child-config digests are derived and rechecked separately against the exact edge and closed teardown verb.
- The exact constructed Offer is routed through Phase 13's private carrier to the already-installed root
  signer. `Teardown.Internal` receives neither `RootBroker` nor a signing key; the
  offering process retains only its existing keyless `BrokerLink` route and fixed continuation.
- Work is limited to the three named production modules, targets at most 400 significant lines, adds no named
  type, leaves `HostBootstrap.Handoff.Recovery` unchanged, and adopts exactly one recovery-package production
  call site without exposing a store, raw catalog row, config/adapter projection, or polymorphic result.

#### Validation

2026-11-12, x86_64 Windows 11 with GHC 9.12.4 and Cabal 3.16.1.0: 84 preparation cases passed,
including a real callback that reopens the protected store, observes one version-1 prepared row, and compares
its complete bytes with the post-callback image. The source guard passed with separate assertions for the
admission statements and the helper's write/readback statements; it makes no textual unlock claim.
`cabal test all -j8 --test-show-details=direct --test-option=--hide-successes` from `core/` passed all
5,377 tests in 718.14 seconds. The later phase 16.74 core gate also passed this case and the real linux-cpu process-boundary cases;
phase 17 must rerun its own gate when all its sprints close.

#### Remaining Work

None.

### Sprint 17.31: Installed recursive handoff runtime [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Runtime.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Install only the fixed trust, lifecycle policy, and keyless routing dependencies used by recursive handoffs.

#### Deliverables

- New hidden all-nominal `RecursiveHandoffRuntime scope brokerGeneration verb` is the sole named type
  introduced by this sprint.
- Construction derives the installed handoff signing/verification identity and fixed lifecycle-only route
  policy from the admitted root environment; it accepts no caller-selected key, tag, domain, or policy and is
  path-agnostic.
- The runtime distinguishes the root's fixed private signing arm from nested keyless exact-byte relay and
  structurally refuses Activation, Build, arbitrary protocol traffic, and semantic lifecycle decisions.
- It owns no root catalog or frame session, opens no journal, performs no durable mutation, and exposes no key,
  store, broker, channel, coordinator callback, generic signer, or caller-selected terminal result.
- Work is limited to the three named production modules, targets at most 400 significant lines, and must split
  before exceeding that bound; it adopts no command call site.

#### Validation

2026-11-12, dedicated SSD-backed Ubuntu WSL2, GHC 9.12.4 and Cabal 3.16.1.0: the private runtime
fixture built the root arm from a live broker and the nested arm from a signed, verified handoff. It checked
exact project, verb, advertised-key and current-frame refusals for the root arm; verb and frame refusals
for the nested arm; empty store identity, empty verification-key digest, zero generation, and both arm
narrowing refusals. Test-only representation mirrors inject the otherwise unrepresentable coordinate drift.
`cabal test all -j8 --test-show-details=direct --test-option=--hide-successes` from `core/` passed all
5,378 tests in 943.01 seconds, including all six real recursive lifecycle cases. The runtime stays private;
phase 16.74 refreshed the evidence expired by the test mixin.

#### Remaining Work

None.

### Sprint 17.32: Rooted frame session [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/durable_state.md`

#### Objective

Open one root-owned journal/session for an exact catalog frame.

#### Deliverables

- New hidden all-nominal `RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb`
  is this sprint's sole named type.
- `Lifecycle.Rooted` alone joins catalog folds to lower session operations; root opening derives
  journal keys and root-selects the catalog's canonical requester path, a non-empty opaque session token,
  initial stage, and next nonzero ordinal while `Lifecycle.Session` imports no catalog type. The root lineage
  that keys the session row and the token is the stable snapshot digest of the catalog's own root plan, read
  through `withRootedPlanCatalogRootKernel`, never a caller-supplied digest.
- A newly root-opened session has no predecessor-response digest. Processing `OpenFrame` triggers its private
  attachment/admission or exact replay, but the request bytes cannot construct or select the session, path,
  stage, ordinal, journal key, or catalog row. A failure before attachment returns Phase 13's existing outer
  `Refused`; rooted `Refused` is post-open only.
- Attachment resolves the sealed external envelope against authenticated scope, runtime, catalog, and the
  session-retained path before mutation. Its replay identity includes exact root lineage, catalog, envelope
  path, and nonce. Only the exact nine-field root-signed `Opened` discloses the canonical path/coordinates;
  strict readback records the lowercase SHA-256 digest of those complete signed bytes as the first predecessor
  before later closed next-node, descent, settlement, completion, and refusal folds become available.
- Work is limited to the three named production modules, targets at most 400 significant lines, and must
  split before exceeding that bound; it adopts no command call site, and `Command.LifecycleEntry` changes only
  where its session openings drop the root-plan-digest argument.

#### Validation

2026-11-12, dedicated Linux WSL2 instance with the host worktree bound in: the real two-level catalog
fixture passed canonical and direct opening of the same nested frame, checking catalog-derived lineage and
separate rows. The rooted focused run passed its behavioral cases; its first source-signature assertion was
corrected and the individual corrected assertion passed. `poetry run python -m hostbootstrap.check_code`
passed, and `poetry run python -m hostbootstrap.test_all` passed 384 tests with 100% coverage. Full
`cabal test all` in both `core/` and `demo/` each ran 5,385 cases and failed the same three source
inventories: a PATH-binding false positive on a test label, the sealed Session export inventory, and the
rooted handoff test-importer inventory. The fixture label and inventories have been corrected; the full
Cabal gates must be rerun before closing the sprint. After correction, 85 focused sealed-boundary tests and
five PATH checks passed. The `demo/` Cabal rerun passed all 5,385 core cases and all 169 demo cases;
the `core/` Cabal rerun passed all 5,385 cases (1,036.58 seconds). The demo core suite took 1,037.39
seconds. Both Cabal runs also passed the provider-live suite's declared unsupported path. All four host
static gate commands passed.

The sprint closes when `ProjectPlanSpec` pins `withRootOpenedFrameSessionKernel` and
`withRootOpenedDirectFrameSessionKernel` with no root-plan-digest `Text` parameter and pins the
`withRootedPlanCatalogRootKernel`-to-`stablePlanSnapshotDigest` derivation inside the opening, the module's
token Haddock names the requester path, and `RecursiveLifecycleSpec`'s public `up`, `down`, and `destroy`
cases still open, attach, and progress every remote frame session across real process boundaries. Then the
four host static gate commands pass: `cabal test all` from `core/` and `demo/`,
`poetry run python -m hostbootstrap.check_code`, and `poetry run python -m hostbootstrap.test_all`. It also
requires the behavioural cases named in Remaining Work: direct and canonical session openings, a direct
opening of an unadmitted or root frame, a faulty-signer opening, the two advance refusals, the attach
refusals driven with test-key-signed responses, and the `SessionSpec` row-kernel and key-distinctness cases.

Opening, the no-predecessor initial row, root-selected path and opaque coordinates, the four-part replay
identity, signed `Opened` digest recording and readback, and ordinal/predecessor progression are covered by
the source guards below and by those public real-process cases. The opening has no lease input and performs no
stale-catalog check; cross-root-plan, generation, catalog, session, and frame separation is the seven nominal
indices', enforced at the type level by the compile-fail guards, and no behavioural case drives a refusal.

`Lifecycle.Rooted` is the sole owner of the seven-role `RootedFrameSession`. Both constructors retain a
private `OpenedFrameFields` value containing the root-selected coordinates and exact published row; Attached
also retains the admitted nonce, the first predecessor digest, and its own successor row. Neither retains a store, catalog, runtime, request, or response, so an elimination yields
coordinates and coordinates authorize nothing.

Opening admits before it writes. The runtime must be the root arm — a keyless nested arm cannot open a session
at all, which is what keeps journal ownership at the topology root — and must be path-agnostic. The requester
path is the catalog's own descent chain to the frame, root-nearest-to-leaf, built from the existing entries
and root folds: a frame no admitted edge names, a frame two edges name, and a chain that walks more levels
than the catalog holds all refuse. The session token is an opaque digest of root lineage, catalog identity,
frame, verb, and path — stable, so a reopening converges rather than forking. The stage is fixed and the next
ordinal is the first nonzero one. The record key is a function of root lineage, catalog identity, and frame
alone. The published row frames all of that and no predecessor, because nothing has been answered yet, and
the opening refuses unless the strict readback is byte-identical to what it rendered.

Attachment resolves everything before mutation: the root arm again, the sealed external envelope against the
path the session itself retains, and the request against the closed request family — only `OpenFrame`
attaches, and every post-open form refuses through one fixed continuation. The attached row frames root
lineage, catalog identity, envelope path, and nonce together, so that quadruple *is* the replay identity and
the same nonce under a different lineage, catalog, or path is a different attachment rather than a replay.
The predecessor is the lowercase SHA-256 digest of the complete signed `Opened` bytes as supplied; this module
neither produces nor signs a response, and names no response builder or signer, so Sprint 17.36 keeps sole
ownership of response production and fixed-signer invocation at the live root endpoint. Every failure here is
pre-attachment and leaves the transport's existing outer `Refused` to carry it — no rooted `Refused` is
constructible in this module.

`Lifecycle.Session` gains only the durable half: key derivation and the two record operations, taking plain
coordinates and interpreting no framing of its own. The opening operation returns the version and the exact
bytes the store actually holds rather than a claim that they are the ones presented, so only the caller's
codec decides whether a row is its own. `Lifecycle.Session` still imports no catalog type, and
`Lifecycle.RootedPlan` is untouched — the canonical path is derived through its existing public folds, which
keeps that owner byte-identical at its frozen digest.

`ProjectPlanSpec` pins the export set, the Cabal-private placement, the seven nominal roles, the sole named
type, the existential frame and session indices, the admission-before-write ordering on both operations, the
canonical path derivation and its three refusals, the no-predecessor opened row, the fixed stage and nonzero
ordinal, the `OpenFrame`-only attachment, the four-part replay identity, the absence of any response builder,
signer, broker, or raw store operation, and both neighbours' unchanged boundaries. `CompileFailSpec` pins the
hidden-module boundary.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-13 at
`1972 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`.

#### Remaining Work

None.

### Sprint 17.32a: Failed-Up recovery admission and nested direct opening [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Allow only the already-authorized failed-Up unwind to carry its exact recovery package to a nested frame,
while retaining the ordinary recovery path's Down/Destroy-only refusal.

#### Deliverables

- Join failed-Up recovery admission to its exact prepared descent and narrow unwind authority before any
  signing or publication, preserving the generic Up refusal and existing root/edge identity checks.
- Drive the existing real-process failed-Up fixture through a direct nested-frame opening. Completion of
  cleanup and its reached-work proof are split to sprint 17.32b because they require the separate teardown
  projection owner beyond this sprint's three production modules.

#### Validation

2026-11-12: the strengthened real-process failed-Up assertion failed before direct opening. The actual
recovery opener returned `HandoffRecoveryVerbInvalid "up"`; no scoped Up recovery admission was then
installed. After sprint 17.32 closed, the restored `RecursiveLifecycleSpec` regression failed with two
crossings rather than the four expected for forward descent and failed-Up unwind; it remains in the suite.
The initial Up-specific root link and recovery kernels compile with `cabal build all`; the ordinary
Down/Destroy-only kernels remain in place. The focused real-process regression was rerun against that implementation. The subsequent real-process run reached all four expected crossings but failed before any
reverse-attempt record was created; no successful unwind is claimed. These failed attempts are not passing evidence.
The nested reverse child then refused because the reached operations were in reverse order relative to its
admitted plan. That independent teardown-projection defect is assigned to sprint 17.32b. This sprint closes
only after the narrow route, generic Up refusal, and nested opening pass the host static gate. The narrowed
real-process regression now passes all four crossing checks. The handoff suite passed 226 cases including
ordinary Up refusal and a refused Up-specific edge that leaves the real store unchanged; the sealed-boundary
selection passed 85 cases. The project-plan selection passed 117 of 118 cases; the one exact Relay
ownership count was updated for the new link. Both Python gate commands passed, including 384 tests and
100% coverage. The first full core Cabal run passed 5,384 cases and failed the documentation validator because two
new phase references lacked links. Those references were corrected; a full core rerun is required. The demo
Cabal run passed 5,385 core cases (1,001.60 seconds) and 169 demo cases after reading the corrected
links. The documentation validator selection passed all 22 cases; the complete core rerun passed all 5,385 cases (990.19 seconds). All four host static gate commands
passed.

#### Remaining Work

None.

### Sprint 17.32b: Failed-Up reached-order projection [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/reverse-executor/HostBootstrap/Teardown/Executor/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Project reached work into each admitted child plan in its own canonical forward order before reverse cleanup.

#### Deliverables

- Preserve the exact authorized reached set while ordering its child projection according to the admitted plan.
- Extend the real failed-Up fixture to prove its composed VM/container route reaches the nested rooted
  preparation. The subsequent durable-row conflict and full cleanup proof belong to sprint 17.32c.

#### Validation

2026-11-12: the authenticated nested reverse child refused the reached set: its admitted plan was
`project:vm, project:container`, while the observed projection was `project:container, project:vm`.
The child executor now validates the adapter operation set and reorders it to its local admitted forward
plan before retaining the exact adapter-byte check. The real-process retry still failed before producing a
cleanup record. The next refusal came from passing a VM binary path to a composed route ending in a
container; the failed-Up selector now derives that path from the terminal lift layer, matching reverse
entry behavior. The sprint closes when the narrowed real-process crossing assertion and the host static gate pass. The next attempt reached the nested rooted node but refused because its
durable Unknown row belonged to the earlier forward preparation; that separate session-row collision is
assigned to sprint 17.32c. The focused real-process regression passed after asserting at least six forward
and direct reverse crossings and a successful subsequent destroy. The handoff selection passed 226 cases
and the documentation validator passed 22. Both Python gate commands passed, with 384 tests and 100%
coverage. The core Cabal gate passed 5,385 cases (1,012.06 seconds); the demo gate passed 5,385
core cases (998.18 seconds) and 169 demo cases. All four host static gate commands passed.

#### Remaining Work

None.

### Sprint 17.32c: Failed-Up preparation row isolation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`, `documents/architecture/lifecycle_state_model.md`

#### Objective

Keep failed-Up reverse preparations distinct from the forward session's durable Unknown rows.

#### Deliverables

- Bind durable preparation and settlement identity to the admitted session so a nested direct reverse
  opening cannot conflict with its different forward session, while preserving exact replay and isolation.
  Equal-path direct and canonical sessions need distinct tokens and are assigned to sprint 17.32d.
- Prove the complete real-process failed-Up cleanup is child-first and does not widen beyond reached work.

#### Validation

2026-11-12: after the direct route and child order corrections, the nested rooted node refused
`the durable unknown row is not this preparation`; cleanup produced no reverse-attempt record.
This is failing evidence. Both Unknown and settlement key kernels now include the root-selected session
token, and the real-process child-first cleanup assertion has been restored. The focused rerun is compiling;
The next run performed child-first cleanup twice because the command retried root unwind even after an
authenticated failed-frame unwind succeeded. The command now preserves the original failure without a
second unwind on success, retaining root fallback when failed-frame admission or cleanup fails. The sprint
closes only after the exactly-once cleanup assertion and host static gate pass. The real-process fixture now
passes with exactly four authenticated crossings, one `container`, `vm`, `root` cleanup sequence, the original
Up failure, and a successful later destroy. Rooted, session, project-plan, and documentation selections
passed 53, 301, 118, and 22 cases respectively. Both Python host-gate commands passed, with 384 tests and
100% coverage. The standalone core Cabal gate passed all 5,385 cases (1,015.53 seconds); the demo
core gate passed 5,385 cases (1,017.56 seconds), and its 169 demo cases passed. All four host static gate
commands passed.

#### Remaining Work

None.

### Sprint 17.32d: Equal-path opening token isolation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`, `documents/architecture/lifecycle_state_model.md`

#### Objective

Give direct and canonical openings distinct session tokens even when they use the same one-edge path.

#### Deliverables

- Derive the session token from the opening mode as well as the retained catalog and path coordinates,
  preserving deterministic exact replay within each mode.
- Prove real one-edge direct and canonical sessions use distinct tokens and preparation rows, and refresh
  the rooted owner source pins.

#### Validation

2026-11-12: source inspection found that the two key families can share a token for a first-level frame:
`sessionTokenFor` hashes the same lineage, catalog, frame, verb, and path in both modes. The session-token
coordinate added to preparation keys therefore does not yet isolate that case. The sprint closes after
behavioral isolation checks and the host static gate pass. The versioned token now includes the mode; the
rooted selection passed 53 cases including distinct equal-path tokens, real preparation rows, and exact
opening replay with no store mutation. Documentation validation passed 22 cases. Both Python gate commands
passed, including 384 tests and 100% coverage. The standalone core gate passed 5,385 cases (1,042.70
seconds); the demo gate passed 5,385 core cases (1,018.44 seconds) and 169 demo cases. All four host static
gate commands passed.

#### Remaining Work

None.

### Sprint 17.33: Prepared node grant [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Prepare the exact root-owned node evidence from which the live root endpoint signs a grant before a frame
executor can run an effect.

#### Deliverables

- New hidden all-nominal `PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node
  verb` is this sprint's sole named type.
- The producer first compare-and-swap publishes and reads back every exact durable Unknown row for the node's
  own operation and ordered projected operations before it can sign a grant.
- The exact `NextNode -> Prepared` response body has Phase 13's four nested fields: node, dependencies,
  operation gate, and projected gates. Each gate package frames the frame plan's digest, catalog identity,
  frame, session, supersession generation, attempt, journal version, and the operation key of the row it was
  prepared for. The supersession generation is the runtime's own broker generation, read from the
  `RecursiveHandoffRuntime` fold rather than supplied by the caller, so a grant cannot carry a generation other
  than the one its runtime and session are indexed by.
- A grant exposes only fixed evidence folds for the node and its durable gate packages, never request,
  response, store, or journal state; only the live root endpoint may turn that evidence into a paired
  `NextNode -> Prepared` response, while `Descend | Refused` has no constructor on this path.
- Work is limited to the three named production modules, targets at most 400 significant lines, and must split
  before exceeding that bound; it adopts no transport call site, and its existing callers in
  `Command.LifecycleEntry` change only by dropping the generation argument.

#### Validation

2026-11-12: after the private codec mixin expired phase 16 evidence, sprint 16.76 restored its complete
core and live Kind gate and covered-path digest. The node producer now takes its generation from the live
runtime, and version-two gate packages encode and validate the operation key. The codec selection passed
round-trip and exact malformed-input cases; the recursive lifecycle selection passed nine cases; the
project-plan selection passed 119 cases, including the new source pins; documentation validation passed 22.
The handoff selection passed all 226 cases. Both Python host-gate commands passed, including 384 tests
and 100% coverage. The standalone core Cabal gate passed all 5,386 cases (1,030.60 seconds); the demo
Cabal gate passed all 5,386 core cases (1,022.76 seconds) and 169 demo cases. All four host static
gate commands passed.

The sprint closes when `ProjectPlanSpec` pins `withPreparedRootedNodeGrantKernel` with no `Word64` parameter
and its `GateSupersessionGeneration` fed from the runtime fold's generation binding, pins the version-2 gate
package framing with its operation-key frame on both the render and read sides, and pins the
`PreparedNodeGrant` Haddock free of any signed-response claim; the gate-package codec cases in Remaining Work
pass; `RecursiveLifecycleSpec`'s public `up` case still prepares every node across real process boundaries;
and the four host static gate commands pass.

Unknown-before-grant ordering, retry convergence through the exact-bytes readback, and the duplicate,
self-reference, and empty-key refusals are covered by the source guards below, with eight nominal roles and
the unchanged hidden mint allowlist. The module is hidden, so no store-backed case drives a retried or
concurrent preparation or a per-coordinate drift; the fresh preparation path runs in the public `up` case.

`Lifecycle.Prepared.Internal` owns the eight-role `PreparedNodeGrant`, beside the `PreparedGate` it already
held. A grant retains the authorized node, that node's ordered dependencies, and the two gate packages from
which the live endpoint produces the canonical signed response; it names no request, response, store, session, record key, or
compare-and-swap operation, so its fixed-unit evidence fold discloses what a frame may do and nothing about
how the root recorded it. The gate package length-frames each coordinate under an explicit domain and
version, and the projected list carries an explicit count. The supersession generation identifies the broker generation that invalidates a prior routed grant. It is
not an operation fence; Sprint 17.37b owns supplying the missing fence coordinate to routed consumers.

`Lifecycle.Rooted.Node` is the producer, and the ordering is the deliverable. Only an attached session prepares —
an opened-but-unattached one has answered no `OpenFrame`, so there is no exchange a grant could belong to —
and the path-agnostic root arm is required again. The node's own operation is published first, then each
projected operation in the catalog's order; every row is compare-and-swap published and strictly read back,
and a row that returns anything but the exact bytes rendered for it stops the whole preparation, so a
partially prepared node yields no grant rather than a grant covering less than it claims. Duplicate,
self-referential, and empty projected keys refuse before the first write.

The mint allowlist is unchanged: `mintPreparedGate` keeps its exact three owners, because the grant carries
canonical gate *packages* rather than `PreparedGate` values and mints none. `Lifecycle.Rooted.Node` names no
response builder and no signer. Durable preparation therefore completes before its evidence reaches the live
endpoint, which then renders and signs the paired `Prepared`; a `NextNode -> Descend | Refused` answer has no
constructor on this path at all.

`Lifecycle.Session` gains only the rooted unknown row's key derivation and its publish-and-strict-readback
transition, which is the same absent-then-readback shape the frame session opens with and interprets no
framing of its own.

`ProjectPlanSpec` pins the export set, the Cabal-private placement, the eight nominal roles, the retained
response-free shape, both package framings, the fixed-unit evidence fold, the unattached refusal, the
admission-before-publication ordering, the node-before-dependencies order, the duplicate refusal, the exact
three-owner mint allowlist, and the absence of any response builder, signer, or raw store operation.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-13 at
`1973 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`.

#### Remaining Work

None.

### Sprint 17.34: Root settlement and replay [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Settle an executor observation exactly once and replay only its exact rooted result.

#### Deliverables

- Root settlement checks the request's echoed requester path, session token, ordinal, and predecessor against
  the session, requires a non-empty node, nonce, and observation, and keys the row by the session's own lineage,
  catalog identity, and frame plus the node and ordinal.
- Only `SettleNode` and `DescendResult` settle, and only a signed `Settled` settles them: the response must
  answer the exact request (its request digest is the request's digest), echo the same path, session, and
  nonce, select a strictly greater successor ordinal, and carry as its body the digest of the request's own
  observation. A signed `Refused` settles nothing.
- An exact retry of the durable settlement converges on the row already present; a different observation at
  the same coordinates refuses without effect. The signed response is not stored, so a request retried after
  the session has advanced refuses on its stale ordinal rather than receiving the earlier response.
- The coordinator's fixed signer produces the signed `Settled`, the kernel publishes and strictly reads back
  the observation row, and only then does the coordinator advance its in-memory session through
  `withAdvancedRootedFrameSessionKernel` and release the bytes; this sprint creates no child gate or local
  execution authority.
- Work is limited to the three named production modules, targets at most 400 significant lines, introduces no
  named type, and adopts no unrelated production call site; `Command.LifecycleEntry` changes only at its
  `Settled` signing sites.

#### Validation

The sprint closes when `ProjectPlanSpec` pins, inside `withSettledRootedNodeKernel`'s admission and before
`publishExactRow`, the response-answers-this-request check and the `Settled`-body-names-this-observation check,
and pins the `Refused` arm as a refusal; `RecursiveLifecycleSpec`'s public `up`, `down`, `destroy`, and
failed-reverse cases still settle every node across real process boundaries; the behavioural settlement
refusal cases named in Remaining Work pass; and the four host static gate commands pass.

The node owner is exposed only to the test component through the existing private implementation unit.
`TeardownSpec` drives genuine root-signed responses against the protected store, checks coordinate and family
refusals, zero generation, request and observation binding, exact retry, and conflicting observation.
On 2026-11-12 on the dedicated SSD-backed Linux WSL2 instance, the settlement selection passed 63 tests
and the indexed project-plan selection passed 119. The complete host static gate passed: `cabal test all`
from `core/` passed 5,387 tests (878.15 seconds), and from `demo/` passed 5,387 core tests (892.28 seconds)
and 169 demo tests. `poetry run python -m hostbootstrap.check_code` passed; `poetry run python -m
hostbootstrap.test_all` passed 384 tests with 100% coverage. The recursive root/VM/container cases ran in
both Cabal legs. The first complete core attempt passed 5,386 of 5,387: a test label matched the PATH-binding
source guard; renaming the label fixed it and the complete rerun passed.

This sprint opens by splitting the rooted owner, which § G requires before its 400-line bound is crossed
rather than after. `Lifecycle.Rooted` keeps the durable row a session *is* — the type, opening, attachment,
and coordinate fold — and the new `Lifecycle.Rooted.Node` holds what happens inside one: the prepared node
grant and now settlement. The split is a real boundary rather than bookkeeping, because the node owner
reaches a session only through its fixed-unit coordinate fold. It never sees the session's record key,
version, or row bytes, so it cannot advance or rewrite the session itself; it derives its own keys from the
coordinates it is shown, and every row it writes is its own. Source guards pin that: the node owner names
neither session constructor, neither session key kernel, nor the attachment transition.

Settlement checks every echoed coordinate against the session before a byte is written — requester path,
session token, ordinal, nonce, and the predecessor digest the session recorded when it attached — and an
unattached session, a keyless nested arm, or a session with no recorded predecessor each refuse first. Only
`SettleNode` and `DescendResult` settle; every other request form leaves through one fixed continuation, and
the supplied signed response must be a `Settled` that answers this exact request and names this observation,
echo the same path, session, and nonce, and select a strictly greater successor ordinal. The observation row
is published and strictly read back before the response digest is taken, so a response can never be
recorded for an observation that was not durably settled.

Settling twice is one settlement rather than two. The row is keyed by root lineage, catalog identity, frame,
node, *and* ordinal, and its bytes carry the observation, so an exact retry converges on the record already
present while a different observation under the same coordinates comes back as different bytes and refuses
without effect. One node settled at two session ordinals addresses two rows and neither can overwrite the
other. No named type is introduced, no child gate is minted — the node owner names neither `PreparedGate` nor
its mint — and no response is produced or signed here.

`ProjectPlanSpec` pins the split boundary in both directions, the node owner's two-name export set, the
echoed-coordinate ordering, the two closed-family refusals, the publish-before-digest ordering, the
ordinal-keyed row, the absence of any gate mint, and both owners' line budgets.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-13 at
`1973 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. After the split `Lifecycle.Rooted` stands at
286 significant lines and `Lifecycle.Rooted.Node` at 231.

#### Remaining Work

None.

### Sprint 17.35: Root terminal receipt confirmation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Confirm terminal receipt in the root-owned store after exact executor completion.

#### Deliverables

- Receipt state derives from the exact root session, binding, terminal report, acknowledgement, and completion.
- `CloseFrame` yields only signed `FrameComplete | Refused`; the root first publishes and reads back the exact
  canonical lifecycle report carried by `FrameComplete`, then derives the complete signed-response digest.
- `ReceiptConfirm` must name that exact digest and the session predecessor. A successful `ReceiptRecorded`
  body repeats the exact `FrameComplete` digest. Sprint 17.35a owns completing the reverse path's durable
  Published-to-Received transition before the session advances.
- Exact retry is convergent and never requires the child to persist or reopen receipt state; no other request
  family can publish, confirm, or receive a terminal report.
- Work is limited to two production modules, targets at most 400 significant lines, adds no named type, and
  supplies the split durable continuations a request-at-a-time rooted service composes; the publish-then-
  advance order is pinned at the two `Command.LifecycleEntry` compositions that use them.

#### Validation

The fresh `CloseFrame`/`ReceiptConfirm` exchange runs behaviourally in `RecursiveLifecycleSpec`'s public `up`,
`down`, and `destroy` cases across real process boundaries. Convergent retry of the two durable steps has no
behavioural case yet; Sprint 17.21 owes the store-backed row cases. The rooted join itself — report, acknowledgement, binding,
and session drift, and the absence of child store and receipt operations — is covered by the source guards
below; no case drives a lost response, a compare-and-swap race, or a root restart at this join. The
warning-clean core gate runs them.

The Published-to-Received transition this sprint needs already exists as `publishLifecycleReportKernel` and
`receiveLifecycleAcknowledgementKernel`, whose exact-row replay is convergent by construction; Sprint 17.21
owes their fresh, replayed, conflicting, and absent-row cases. Both consume the hidden `RecoverySigningKernel`,
whose importer allowlist is exactly four modules and does not include any rooted owner. The durable
continuations therefore live in `Handoff.Relay`, which already holds that capability, leaving the rooted
owner to hold only the session/binding validation and the two digest derivations — which is why widening that
allowlist is not part of this sprint.

This sprint opens by splitting the terminal exchanges into their own owner, which § G requires before the
frame-session owner's 400-line bound is crossed rather than after. `Lifecycle.Rooted` keeps the durable row a
session *is*, `Lifecycle.Rooted.Node` keeps what happens inside one while work remains, and the new
`Lifecycle.Rooted.Receipt` keeps how one ends. The boundary is the same one the node owner already stands on
— the receipt owner reaches a session only through its fixed-unit coordinate fold — and it goes one step
further: the receipt owner names no `ProtectedStore` at all. Both durable steps arrive as continuations from
the module that already holds the capability, so what it owns is the join and the two digests rather than the
writes.

The two exchanges are closed in both directions. Only a `CloseFrame` reaches a terminal report and only a
`ReceiptConfirm` confirms one; every other request form leaves through one fixed continuation, so no other
family can publish, confirm, or receive a terminal report. Each answer must belong to its own paired family,
and a signed `Refused` is read as an outcome rather than minted. The close checks requester path, session
token, ordinal, nonce, and the predecessor the session recorded when it attached, then requires the report the
signed `FrameComplete` carries to eliminate canonically and name the session's own verb — a report bound to
another edge's verb is not this frame's terminal report. The report is published and strictly read back before
the complete signed-response digest exists, so a receipt can never name a report the root has not durably
held.

The confirmation names that report the only way it can: the digest of the complete signed `FrameComplete`
bytes is its predecessor. Only an exact match runs the Published-to-Received compare-and-swap, and the
recorded receipt repeats the same digest in its own body, which is what lets a child that persists nothing
still say which terminal report was received. Nothing in either exchange retains state of its own, and both
durable steps are already convergent, so an exact retry re-derives the same digest over a row that is already
where it belongs. The acknowledgement is the canonical one rendered from the published report rather than
anything a requester supplied. `Handoff.Relay` also provides package-private publish and completion-persist
continuations so the coordinator can retain the derived `FrameComplete` digest between the separate close
and receipt requests; they retain no session and accept no caller-selected signing capability.

`ProjectPlanSpec` pins the receipt owner's two-name export set, its Cabal-private placement, the absence of
any store, session, signer, response-builder, or session-constructor name, both closed request and response
families, the predecessor-naming check, the publish-before-digest and admit-before-advance orderings, the
recorded-repeats-completion check, the continuation order at the two live compositions, and all three rooted owners' line budgets. `HandoffSpec` keeps `Handoff.Protocol` and the `Handoff` facade byte-frozen at their existing
digests across the change. `CompileFailSpec` pins the new owner's hidden-module boundary.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-13 at
`1975 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. `Lifecycle.Rooted.Receipt` stands at 202
significant lines, `Lifecycle.Rooted` is unchanged at 286, `Lifecycle.Rooted.Node` at 231, and the
`Handoff.Relay` call site adds 35.

On 2026-11-12 in the dedicated SSD-backed Ubuntu WSL2 instance, the focused receipt selection passed
40 cases, including a genuine signed stale completion that reaches neither receive nor the success
continuation. `cabal test all -j8 --test-show-details=direct --test-option=--hide-successes` from `core/`
passed all 5,388 tests in 889.53 seconds, including the public recursive lifecycle cases. The first focused
runs exposed two stale Relay source inventories, which were corrected. Inspection found that the reverse
`complete` callback only retained subtree settlement, so Sprint 17.35a owns adding the missing durable
acknowledgement at that composition; the current forward path already renders and persists the canonical
acknowledgement before advancing.

#### Remaining Work

None.

### Sprint 17.35a: Persist the reverse terminal acknowledgement [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Complete the reverse rooted receipt by persisting the exact canonical report acknowledgement before the
session advances or the signed `ReceiptRecorded` is released. This is the remaining call-site change split
from Sprint 17.35 after inspection found its existing reverse callback only retained subtree settlement.

#### Deliverables

- Derive the acknowledgement from the retained terminal report and persist it before invoking the completion
  continuation, advancing the rooted session, or releasing the signed receipt. Refuse without advancing on
  a persistence failure.
- Pin the reverse composition and its ordering, and exercise the real public recursive reverse lifecycle.

#### Validation

On 2026-11-13 in the dedicated SSD-backed Ubuntu WSL2 instance, the focused receipt selection passed
40 cases and `RecursiveLifecycleSpec` passed nine real-process cases. The full host static gate passed:
`cabal test all` from `core/` passed 5,388 tests (842.54 seconds); from `demo/` it passed 5,388 core
tests (883.31 seconds) and 169 demo tests. `poetry run python -m hostbootstrap.check_code` passed,
and `poetry run python -m hostbootstrap.test_all` passed all 384 cases with 100% coverage.

#### Remaining Work

None.

### Sprint 17.36: Rooted relay service [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Runtime.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Join the installed runtime to an already root-opened session and attach its first `OpenFrame` through the
keyless relay. This sprint is the first point at which the structurally validating Phase 13 root endpoint
becomes available instead of returning the existing outer `Refused`.

#### Deliverables

- The first runtime/coordinator adoption replaces Phase 13's unavailable outer-refusing root endpoint and
  accepts only Phase 13's exact four-field `OpenFrame`; its inner value has no path, while the relay
  reconstructs the sealed external requester ancestry in root-nearest-to-leaf
  order. The root first enforces the same one-to-256 non-empty UTF-8 component grammar and 4,096-byte encoded
  component bound as the post-open request codec, then resolves that path plus nonce against scope, runtime,
  catalog, and the already-opened session before any mutation.
- The runtime joins that request to an already root-opened `RootedFrameSession`; `OpenFrame` never creates a
  session and supplies no session, stage, ordinal, predecessor, verb, or result body. Attachment failure returns
  the existing outer `Refused`; it cannot manufacture a post-open rooted refusal.
- Only the root's fixed signer produces the exact nine-field `Opened`, bound through the fixed Phase 13
  transcript to the complete request and disclosing the admitted canonical path plus root-selected session,
  stage, and next ordinal. The coordinator records and reads back the digest of those complete signed bytes
  before the response is released as the session's first predecessor.
- Exact replay under the same root lineage, catalog, envelope path, and nonce returns a byte-identical
  `Opened`: the attachment converges on the row already present, whose recorded predecessor is the digest of
  those bytes, and the fixed signer is deterministic. Nonce or request bytes alone are never a replay identity. Any ancestry, request, catalog, scope,
  runtime, session-liveness, or attachment conflict refuses. The intermediate route remains keyless and
  exposes no store RPC, signer, session constructor, semantic callback, or caller-chosen result.
- Work is limited to the three named production modules, targets at most 400 significant lines, adds no named
  type, and adopts only the runtime/root-session `OpenFrame` attachment call site; it does not edit or
  reinterpret the neutral Phase 13 codec or frozen Protocol framing.

#### Validation

`Handoff.Runtime` gains one root-arm fold, so the arm that may reach a signer is selected by which fold a
caller can enter rather than by a boolean beside the identity it returns. `Lifecycle.Rooted` gains the join:
it binds that arm, reads its own session's coordinates, enforces the sealed envelope's grammar before
comparing it to the path the session retains, admits exactly an `OpenFrame`, and renders the nine-field
unsigned `Opened` from root-selected coordinates alone — the request contributes only the digest that names
it. Signing is a continuation, so the owner still names no signer, and the existing attachment records the
complete signed response's digest and reads it back before the caller may release those bytes.
`Handoff.Relay` holds the one call site, because the hidden recovery signing admission is already inside its
importer allowlist, and `rootBrokerLink` now runs that live endpoint where it previously refused every rooted
request.

All three owners are Cabal-private with no runtime caller, so their coverage is exact source and compile-fail
guards, as it is for every rooted owner below. `ProjectPlanSpec` pins the runtime's five-name export set and
its root-arm/nested-arm branches, the session owner's five-name export set, the opening's
arm-then-session-then-admit-then-sign order, the record-and-read-back-before-release order, the
grammar-before-identity order, both the 256-component and 4,096-byte bounds as the post-open codec's own, the
already-attached refusal, the single fixed post-open refusal, the response's digest-names-the-request shape,
the call site's key-digest check against the live broker's own route, the fixed signer as the sole response
producer, the live endpoint replacing the refusal, the endpoint's link-field shape, the absence of channel and
transport names from the session owner, all four call-site counts, and both line budgets. `HandoffSpec` keeps
`Handoff.Protocol`, the `Handoff` facade, `Handoff.Rooted`, `Handoff.Recovery`, `Handoff.Internal`,
`Handoff.Receiver`, and `Handoff.Receiver.Internal` byte-frozen at their existing digests across the change,
and re-pins `Handoff.Relay`'s digest, its export set, and the two-owner rooted increment.

Behavioural coverage of a live `OpenFrame`/`Opened` exchange needs a caller that holds a root broker, a
catalog, an opened session, and a channel at once. Sprint 17.42's root coordinator holds all four, and
`RecursiveLifecycleSpec`'s public `up`, `down`, and `destroy` cases run the fresh exchange across real process
boundaries. No case drives a replayed `OpenFrame`, ancestry or request drift, an attachment conflict, a
truncated frame, or EOF; those are covered by the source guards above alone. The live coordinator answers a
retransmitted `OpenFrame` from its already-attached session, which refuses; Sprint 17.42 owes the change that
routes an exact replay through the attachment's convergent path.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-14 at
`1976 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. `Lifecycle.Rooted` stands at 355 significant
lines, `Handoff.Runtime` at 159, and `Handoff.Relay` grows from 2,167 to 2,203 — 131 significant lines across
the three owners.

On 2026-11-13 in the dedicated SSD-backed Ubuntu WSL2 instance, `ProjectPlanSpec` compares the complete
value tokens from both definitions for path cardinality and component byte length. Four negative controls
change either side to a longer numeric token and verify mismatch. The focused rooted selection passed
55 tests; the first attempt identified the codec's missing reviewed source-home entry, which was added.
`cabal test all -j8 --test-show-details=direct --test-option=--hide-successes` from `core/` passed all
5,388 tests in 885.54 seconds. Sprint 17.42 owns the separate live coordinator exact-replay behavior.

#### Remaining Work

None.

### Sprint 17.37: Storeless frame executor [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (build metadata only)
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Interpret root-signed node grants inside one long-lived child frame without local durable authority.

#### Deliverables

- New hidden all-nominal `FrameExecutor scope rootPlanId brokerGeneration catalogId frame sessionId verb` is
  this sprint's sole named type.
- Construction requires the exact independently verified `Opened` response paired to the preceding
  `OpenFrame`; it retains verified root scope, exact projected frame plan, frame-local `ResourceCarrier`, and
  only the response's admitted canonical path, root-selected session/stage, next ordinal, and complete-response
  predecessor digest.
- Each later request echoes those opaque coordinates byte-exact, uses the required nonzero ordinal, fresh
  32-byte nonce, and exact predecessor, and accepts only its Phase 13 response family. It advances from the
  verified response's root-selected successor stage/ordinal and complete signed-response digest; the executor
  cannot fabricate pre-open state or treat an opaque body as typed before local Phase 17 validation.
- Execution reads the verified `Prepared` response's four nested node/dependencies/operation-gate/
  projected-gates packages out of that response rather than beside it, exact-compares them with its local
  `ExecutionNode` and exact durable coordinates — each gate package's framed operation key must equal the
  local operation it is paired with, and every package must name the one catalog identity the executor's first
  verified `Prepared` established — and only then becomes the sole additional allowlisted caller
  of `mintPreparedGate` for the already published root Unknown, invokes the local effect, and returns one
  closed typed observation.
- Work is limited to the named production modules, targets at most 400 significant lines, and must split
  before exceeding that bound; it adopts no process call site and retains no `ProtectedStore`, journal, lease,
  snapshot, catalog row, signing key, session opener, or settlement capability.

#### Validation

The executor's whole shape is the claim that a place in a conversation is not a capability, so the guards are
about what it cannot reach as much as what it does. Every entry point turns signed bytes into a response
through one helper that consumes the installed key and the exact request those bytes claim to answer, so no
branch reads a coordinate off unverified bytes. Opening admits only a verified `Opened` and takes its path,
session, stage, and next ordinal from that response, with the first predecessor the digest of the complete
signed bytes — the same digest the root recorded before releasing them. Advancing admits every post-open
family but `Opened`, requires the echoed path and session to be the executor's own, and requires a strictly
greater ordinal, so a root reissuing one position twice refuses. Execution admits only `Prepared`, reads the
four packages out of it, and refuses a `Descend` or a signed `Refused` on the same fixed branch — which is
what keeps "the root answered" apart from "the root authorized this effect".

`Prepared.Internal` gains the canonical ordered-key framing both sides compare against and a strict canonical
gate-package decode, because a storeless frame has no journal to read an attempt or journal version off; the
only place those exist for it is inside the package the root signed. The decode re-renders and compares, and
the gate list checks its declared count, so a package that parses into the same shape but is not the one the
root rendered refuses.

Both owners are Cabal-private with no runtime caller, so their coverage is exact source and compile-fail
guards. `ProjectPlanSpec` pins the executor's five-name export set, its Cabal-private placement, the seven
nominal roles, the five existentially minted indices, the frame-ownership and distinct-key checks, the
verify-then-take order in all three entry points, the three closed refusal branches, the five-family request
builder and the absence of any opening-request builder, the compare-before-mint and mint-before-effect
orders, every gate-package coordinate check, the nonempty-observation requirement, the absence of store,
signer, catalog, session, and process names, the empty importer set, and both line budgets. `CompileFailSpec`
adds `ImportLifecycleFrameExecutor.hs` for the hidden-module boundary and `OpenFrameExecutorGate.hs` for the
mint and gate-codec allowlist. `HandoffSpec` re-pins the Cabal digest across the one added module row.

Behavioural coverage needs a caller holding a verified root scope, a reconstructed frame plan, and a channel
at once. Sprint 17.41's forward child receiver adoption holds them, and `RecursiveLifecycleSpec`'s public
`up`, `down`, and `destroy` cases run one grant per frame through a real child executor. No case runs two
grants through one executor, a reordered or foreign-catalog projected package, or a redelivered grant after a
crash.

The sprint closes when `ProjectPlanSpec` pins `gateFor`'s operation-key comparison, the executor's
catalog-identity comparison before `mintPreparedGate`, the routed gate's own supersession field, and both
opening kernels separately; `RecursiveLifecycleSpec` carries a case whose child
frame runs two grants through one executor; the replayed-`Prepared` case and the behavioural executor refusal
cases named in Remaining Work pass; and the four host static gate commands pass.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-14 at
`1979 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. `Lifecycle.FrameExecutor` stands at 296
significant lines and `Lifecycle.Prepared.Internal` at 207, so the two owners together are well inside the
sprint's 400-line bound.

On 2026-08-21, the five-family selector correction passed its focused source/shape case and the complete
warning-clean core gate on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. `DescendResult` now carries its
nonempty observation through the same executor-owned path and exact retained coordinates as `SettleNode`.

On 2026-11-13, the private package decoder was extended to return its already-validated operation key.
The executor now compares the package operation and catalog before minting, retains the catalog when a
verified `Prepared` advances, and checks the current request coordinates and successor ordinal before
execution. The first indexed selection passed 117/119; two source inventories required updates for the
new decoder and call sites. The routed generation now has a separate field and the real recursive fixture exercises two VM nodes.
The executor moved into the private implementation unit for behavioural tests; that package metadata
change expired Phase 16 evidence, which Sprint 16.79 must refresh first. Routed gates currently have no
local fence epoch (the legacy fence accessor returns zero), so fence-dependent consumers refuse rather
than misread a broker generation as a fence. Supplying and testing a real fence remains outstanding, as do
the remaining behavioral and source-guard checks, and the complete static gate. Sprint 17.37a owns the
closed request selector.

The relocated executor now has a test-only private import. A broker-signed fixture exercises a foreign
opening frame, foreign requester coordinates, wrong plan/frame/session/operation, zero generation,
reordered projections, catalog drift within and across grants, wrong response family, and a replayed
`Prepared`; it also checks the carrier-bound opening's first predecessor. The focused executor selection
passed five tests, and the real recursive selection passed nine tests with two VM-frame grants. On 2026-11-13 the full host static gate passed on the dedicated SSD-backed Ubuntu WSL2 instance:
`cabal test all` passed 5,389 core tests in 821.95 seconds; from `demo/` the core suite passed 5,389
tests in 815.23 seconds and the demo suite passed. `poetry run python -m hostbootstrap.check_code`
passed and `poetry run python -m hostbootstrap.test_all` passed 384 tests with 100% coverage.

#### Remaining Work

None.

### Sprint 17.37a: Close the frame request selector [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Make the five post-open request families a closed selector with their required bodies. This is split from
Sprint 17.37 because the selector introduces a new type and changes its child-command callers.

#### Deliverables

- Replace the textual family and optional body with a closed five-case sum and update the child callers.
- Pin the closed selection and retain all public recursive lifecycle behavior.

#### Validation

On 2026-11-13 on the dedicated SSD-backed Ubuntu WSL2 instance, the focused executor selection passed
five tests, the indexed project-plan selection passed 119, and the real recursive lifecycle selection passed
nine. The first indexed run found one obsolete textual child-call guard; it was updated and the rerun passed.
The full host static gate passed: `cabal test all` from `core/` passed 5,389 tests in 827.96 seconds; from
`demo/` it passed 5,389 core tests in 825.13 seconds and 169 demo tests. `poetry run python -m
hostbootstrap.check_code` passed, and `poetry run python -m hostbootstrap.test_all` passed 384 tests
with 100% coverage.

#### Remaining Work

None.

### Sprint 17.37b: Frame the routed fence separately [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Add a canonical package format that can carry an operation fence and broker generation as distinct roles.
This codec-only sprint is split from the routed-fence work; it does not claim a live fence or change consumers.

#### Deliverables

- Encode and strictly decode a versioned package with both nonzero coordinates, retaining the current format
  for its existing callers until the root producer and executor are migrated.
- Exercise canonical round trips and refuse missing, malformed, zero, and noncanonical fence coordinates.

#### Validation

On 2026-11-13 on the dedicated SSD-backed Ubuntu WSL2 instance, the `prepared` selection passed
75 tests. It includes a version-3 round trip with distinct generation and fence, missing and malformed
fence, zero fence and generation, and trailing bytes, plus the source inventory. The existing version-2
producer remains unchanged; the phase gate will run the complete host static gate.

#### Remaining Work

None.

### Sprint 17.37c: Admit a frame journal and observed fence [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Admit the catalog-selected child plan to a root-owned operation session and observed fence without confusing
the operation fence with the broker generation.

#### Deliverables

- Open the catalog-selected plan's session and observed fence under the current root authority.
- Exercise a fresh transition, stale fence, foreign catalog and store, interruption, and replay against the store.

#### Validation

2026-11-13 (WSL2 linux-cpu): the focused store-backed frame-journal test passed (1 case), establishing the
observed fence, checking the selected plan journal, closing the child session, and refusing replay without a store
change. A subsequent two-case run passed stale-fence refusal and interruption retention but exposed an
identically named catalog from a foreign store being admitted. After adding the root-authority comparison, both
cases passed: foreign catalog and store refusal leave both stores unchanged; a rotated fence cannot prepare,
and interrupted work remains open and blocks replay. The prepared-node source-boundary case also passed after
the authority check. The two focused cases then passed with the fresh session registering an operation, recording
its unknown outcome, acknowledging `Committed`, and closing with the successor permit. This exercises the local
journal; the routed producer and its lifecycle tests are scheduled in the following sprints. All 72 `TeardownSpec`
cases passed against the journal bridge; the phase gate re-runs the host static gate.

#### Remaining Work

None.

### Sprint 17.37c2: Report exact projected-operation outcomes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Return the projected-operation and carried-resource evidence needed to settle a routed node's real journal.

#### Deliverables

- Encode and validate which projected gates were taken, which remain unused, and any carried-resource settlement
  evidence. Bind the report to the node and its declared projections, and reject malformed or foreign evidence.
- Preserve failure semantics without claiming that an unobserved effect succeeded, and refuse incomplete reports.
- Exercise real child reports, invalid projections, and failed work. The next sprint tests interruption against
  the root-held journal.

#### Validation

2026-11-13 (WSL2 linux-cpu): the node-observation round-trip and malformed-data case passed; all 9 selected
`RecursiveLifecycleSpec` cases passed, including real two-boundary Up, Down, Destroy, and failure recovery. A
subsequent run of 59 rooted handoff, catalog, session, and teardown cases passed, including truncated and trailing
reports and foreign nodes, frames, and reordered projections. The phase gate re-runs the host static gate.

#### Remaining Work

None.

### Sprint 17.37c3: Retain and validate journal gates [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Retain each root-owned plan session and prepare and validate its gates against the actual observed fence and
permit before connecting it to the routed exchange.

#### Deliverables

- Retain a plan-indexed session, fence, successor permit, and pending gates across root requests.
- Publish and reread exact unknown records before returning gates, and recheck a prepared operation before
  settlement. Exercise fresh, stale, foreign, and interrupted cases against the protected store.

#### Validation

2026-11-13 (WSL2 linux-cpu): the focused frame-journal cases passed with the retained handle. They exercised
unknown-first preparation, duplicate refusal, permit succession, explicit session close, stale-fence and
stale-operation refusal, and exception propagation with the interrupted durable session left open. The phase gate
re-runs the host static gate.

#### Remaining Work

None.

### Sprint 17.37c3a: Persist frame resource settlements privately [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/ResourceRecord.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Persist resource settlements only inside the private resource owner after preflighting every report and gate.

#### Deliverables

- Check each resource's canonical plan, frame, key, and predecessor before any report member is written.
- Keep the raw resource writer Cabal-private, and acknowledge each operation only after its resource write.
- Exercise successful persistence and refusal of stale gates and malformed later records without store changes.

#### Validation

2026-11-13 (WSL2 linux-cpu): 61 rooted cases passed, including successful resource persistence, stale-gate refusal,
and rejection of a malformed later resource without changing the store. All 9 `ResourceRecordSpec` cases, 13
consumed-gate cases, and 85 sealed-boundary cases passed; the private-writer source guard and public export
inventory passed. All 22 documentation validator cases passed. The phase gate re-runs the host static gate.

#### Remaining Work

None.

### Sprint 17.37c4: Connect the forward exchange to its journal [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Connect the admitted root-held journal and exact child observations to the forward frame exchange.

#### Deliverables

- Retain the frame journal across opening, preparation, signed settlement, and closure; leave interrupted work
  for recovery and never issue a grant before the unknown records are durable.
- Exercise fresh, stale, foreign, and interrupted forward exchanges against the protected store.

#### Validation

2026-11-13 (WSL2 linux-cpu): all 10 selected `RecursiveLifecycleSpec` checks passed with the forward journal
connected. The Up case inspected durable VM and container operation records in the root store; a real child
exception after preparation left its operation in `EffectOutcomeUnknown`. The phase gate re-runs the host static
gate. A subsequent mounted run passed 61 rooted cases, 45 grant cases, and 40 export cases, including stale-fence
and foreign-plan refusals without store changes.

#### Remaining Work

None.

### Sprint 17.37c4a: Harden forward admission and completion replay [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Keep the live fence check and preparation under one protected lock, and make completion retries safe.

#### Deliverables

- Recheck the observed operation fence inside the same protected entry that registers and prepares operations,
  refusing a concurrent supersession before any intent is written.
- Serialize an exact journal-close retry without another store change, and leave interrupted work open for
  recovery. Full terminal-response replay remains in Sprint 17.42.

#### Validation

2026-11-13 (WSL2 linux-cpu): 62 rooted checks passed, including a queued preparation refused after a concurrent
fence rotation without a store change and an exact repeated journal close without another write. The terminal
ordering selection passed 40 cases, all 10 recursive checks passed including the interrupted child, and all 22
documentation validator cases passed. Full terminal-response replay remains in Sprint 17.42. The phase gate
re-runs the host static gate.

#### Remaining Work

None.

### Sprint 17.37c5: Connect the reverse exchange to its journal [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Connect reverse frame preparation and teardown observations to the retained root-owned journal.

#### Deliverables

- Prepare reverse work under its actual session and fence, then settle its exact teardown result before replying.
- Exercise successful, failed, stale, and interrupted reverse work across the rooted exchange.

#### Validation

2026-11-13, dedicated Ubuntu WSL2 on C: SSD: `TeardownSpec` cases "reverse journal records each distinct
teardown outcome" and "frame journal refuses a superseded fence and retains interrupted work" passed.
`RecursiveLifecycleSpec` cases "public down unwinds the same two real process boundaries child-first",
"public destroy unwinds the same two real process boundaries child-first", "failed up preserves its failure and
admits exact reverse recovery", "a failed reverse operation is settled once and terminates the child", and
"an interrupted reverse child leaves its operation unknown" passed. The selected terminal-order cases and
`DocValidatorSpec` also passed. A broad exploratory `grant` selection
exposed an existing test-output capture collision; the affected Docker setup test passed in isolation.
The phase gate remains outstanding.

#### Remaining Work

None.

### Sprint 17.37c5a: Remove obsolete unknown-row addressing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Remove the unused pre-journal node-unknown address constructor after both directions adopt real journals.

#### Deliverables

- Delete the constructor and its test-only callers without weakening session-address isolation checks.
- Rename the remaining settlement-row publisher to describe the row it now publishes.
- Validate the session, rooted-opening, and sealed-export boundaries.

#### Validation

2026-11-13, dedicated Ubuntu WSL2 on C: SSD: `SessionSpec` "rooted durable coordinates remain bounded
and distinct at maximum input size", `TeardownSpec` "direct openings require a non-root admitted frame and
use a distinct row", `AuthoritySpec` "every exposed sealed importer and local sealed surface has one exact
export pin", `ProjectPlanSpec` "the prepared node grant follows exact durable unknown rows and mints nothing
else", and `DocValidatorSpec` passed. The phase gate
remains outstanding.

#### Remaining Work

None.

### Sprint 17.37d: Adopt and validate routed fences [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/FrameExecutor.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Carry the real root-issued operation fence separately from the broker generation through the signed grant
and into the routed gate, restoring fence-dependent work without inventing a fence.

#### Deliverables

- Adopt the fence-bearing package only after its producer derives the actual live fence.
- Exercise a routed fence-dependent consumer and reject stale or foreign fence evidence before its effect.

#### Validation

2026-11-13, dedicated Ubuntu WSL2 on C: SSD: `ProjectPlanSpec` "prepared gate codecs round-trip and
reject malformed fields" and "the storeless frame executor holds coordinates, never authority" passed.
`TeardownSpec` "frame executor binds signed grants to current coordinates and exact packages" passed with
the real provider-budget reservation and zero or mismatched fence and generation refusals. `TeardownSpec`
"frame journal refuses a superseded fence and retains interrupted work" and `RecursiveLifecycleSpec`
"public up crosses two real authenticated process boundaries" passed.
The phase gate remains outstanding.

#### Remaining Work

None.

### Sprint 17.37e: Bind managed reverse work to its routed gate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child/Reverse.hs`,
`core/hostbootstrap-core/internal/reverse-executor/HostBootstrap/Teardown/Executor/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Carry the adopted routed gate into the core-managed reverse action instead of discarding it.

#### Deliverables

- Pass the exact prepared operation and observed fence to managed reverse work.
- Exercise a real routed managed consumer and refuse mismatched or missing gate evidence before its callback.
- Reject superseded fences during root preparation; backend enforcement is owned by Sprint 17.37e1.

#### Validation

2026-11-13, dedicated Ubuntu WSL2 on C: SSD: `RecursiveLifecycleSpec` "a routed managed reverse action
records its foreign outcome" and "an interrupted reverse child leaves its operation unknown" passed.
`HandoffSpec` "the reverse lifecycle child is storeless and exact" and `TeardownSpec` "frame journal refuses
a superseded fence and retains interrupted work" passed. The managed-chart case crosses real child processes
and records foreign retention.
This does not establish that the separate retained cluster backend enforces the fence; Sprint 17.37e1 owns
that boundary. The phase gate remains outstanding.

#### Remaining Work

None.

### Sprint 17.37e1: Fence the retained cluster cleanup backend [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child/Reverse.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Make retained cluster cleanup reject a routed fence older than one already observed in its ownership store.

#### Deliverables

- Record and compare the routed generation and operation fence under the cluster ownership lock before destructive work.
- Exercise valid and locally superseded fence cases against the backend fixture; expire and re-run earlier evidence
  whenever a covered backend file changes.

#### Validation

2026-11-13, dedicated Ubuntu WSL2 on C: SSD: `ClusterBackendSpec` "routed cleanup refuses a fence older
than the cluster has observed" and "routed cleanup refuses a corrupt recorded fence before deletion" passed.
The backend suite passed its 107 cases before the corruption case was added; the final full core gate passed
all 5,401 cases in 837.90 seconds. Phase 16's live `hostbootstrap test run cluster-live` passed 1/1 and its
covered-path evidence was refreshed. Root supersession before a newer fence reaches the target remains
Sprint 17.37e1a.

#### Remaining Work

None.

### Sprint 17.37e1a: Coordinate root supersession with cluster cleanup [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Prevent an older routed cleanup from acting after root supersession even if the newer fence has not yet reached
its separate cluster store.

#### Deliverables

- Coordinate root fence supersession with the in-flight remote cleanup boundary.
- Exercise a delayed older cleanup racing a newer root fence before any successor reaches the cluster store.

#### Validation

On 2026-11-13 the targeted `supersession` selection passed both cases, including a competing
independent store handle and a separate process blocked until release, followed by stale-lease refusal.
The `cleanup` selection passed 67 cases, including the real child-process backend refusal. The phase gate
remains outstanding.

#### Remaining Work

None.

### Sprint 17.37e1b: Bind fenced cleanup to the admitted cluster target [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child/Reverse.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`, `core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Bind the fenced backend call to the exact cluster target selected by its admitted plan.

#### Deliverables

- Require the backend to join its fenced operation with the admitted plan and cluster target.
- Refuse a valid gate presented with another plan or cluster before the backend changes either.

#### Validation

On 2026-11-13 the cluster backend selection passed 108 cases, including a valid gate presented with a
different plan and an incomplete gate, both refused before target-state creation. The storeless and teardown
source-boundary selections passed four cases. Phase 16's complete gate passed 5,407 core cases and the
live cluster check 1/1; its covered-path digest was refreshed.

#### Remaining Work

None.

### Sprint 17.37e2: Confirm fenced cluster cleanup live [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`,
`core/hostbootstrap-core/test/Spec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Confirm the fenced retained cleanup against a realized linux-cpu cluster.

#### Deliverables

- Exercise the routed retained-cluster cleanup against a realized cluster and record its observed result.
- Run the phase's live cluster gate and record its observed result.

#### Validation

On 2026-11-13 the rebuilt bare binary's `hostbootstrap test run cluster-live` passed 1/1 on the dedicated
Ubuntu WSL2 instance, including readiness, wrong-generation refusal, and post-deletion absence. This
exercises the ordinary retained cleanup, not the routed fenced cleanup; the latter remains outstanding.
On 2026-11-13 the opt-in test executable command `--hostbootstrap-routed-live-probe`, with
`HOSTBOOTSTRAP_RECURSIVE_REAL_DOCKER=1`, provisioned an owned Kind cluster and released it through
the recursive child process route. It confirmed the routed fence record, retirement of the cluster origin,
and cluster absence. No Kind clusters or Docker containers remained; Docker, its socket, and containerd
were stopped. The core `cleanup` selection also passed 67 cases with the normal fixture behavior.

#### Remaining Work

None.

### Sprint 17.37f0: Frame reverse resource settlements [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Frame a reverse observation with the exact resource predecessors and successors it reports.

#### Deliverables

- Encode and decode bounded canonical reverse observation and resource transition bytes.
- Reject duplicate resources, wrong frame or operation coordinates, malformed fields, and trailing data.

#### Validation

On 2026-11-13 the observation selection passed 49 cases, including round-trip, foreign coordinates,
reordered and duplicate resources, truncation, trailing data, and empty predecessor refusals. The rooted
boundary selection passed 66 cases after updating the pinned private export inventory. The phase gate
remains outstanding.

#### Remaining Work

None.

### Sprint 17.37f1: Verify and persist reverse release evidence [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/ResourceRecord.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Admit an exact recovered release transition and persist it under the live reverse journal gate.

#### Deliverables

- Refuse a transition that changes any retained coordinate or is not the exact owned-to-released successor.
- Preflight the predecessor and live gate before writing the release, then acknowledge the operation.
- Preserve records on stale, foreign, malformed, or non-release observations.

#### Validation

On 2026-11-13 the settlement selection passed 64 cases, including exact release, substitutions of each
retained coordinate, malformed and stale predecessors, a superseded gate, and a foreign outcome. The
rooted boundary selection passed 67 cases after refreshing the pinned source digest. The phase gate remains
outstanding.

#### Remaining Work

None.

### Sprint 17.37f2: Frame the prepared reverse predecessor [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Provide a canonical prepared-gate envelope for an exact optional resource predecessor.

#### Deliverables

- Frame a canonical fenced gate with either its exact predecessor bytes or explicit absence.
- Refuse malformed, ambiguous, oversized, and unfenced packages before they can reach a child.

#### Validation

On 2026-11-13 the prepared selection passed 75 cases, including present and absent round-trips and
malformed, oversized, unfenced, and trailing-byte refusals. The rooted boundary selection passed 67
cases. The phase gate remains outstanding.

#### Remaining Work

None.

### Sprint 17.37f3: Hold an exact reverse predecessor [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Read the exact resource predecessor under the journal gate and recheck it while acquiring the cleanup lease.

#### Deliverables

- Select only the attached frame and prepared operation's canonical resource record.
- Refuse a changed or malformed predecessor before releasing a prepared response to the child.

#### Validation

On 2026-11-13 the predecessor selection passed eight cases, including absent and present records,
changed and malformed predecessors, and an interrupted lease callback. The rooted boundary selection
passed 68 cases. The phase gate remains outstanding.

#### Remaining Work

None.

### Sprint 17.37f4: Authenticate the reverse predecessor [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Carry the exact predecessor in the root-signed reverse preparation and recheck it under the cleanup lease.

#### Deliverables

- Prepare the gate, read the predecessor, sign its envelope, and recheck it before releasing the response.
- Admit the envelope only on the reverse executor route; forward gates retain their existing representation.

#### Validation

On 2026-11-13 the rooted selection passed 68 cases, the executor selection passed five (including a
signed reverse envelope and refusal of an unwrapped reverse gate), the cleanup selection passed 68,
and the recursive forward `crosses` selection passed three. The earlier predecessor selection covers a
changed record at lease acquisition. A broader `public` selection exceeded its 90-second limit and is
not counted. The phase gate remains outstanding.

#### Remaining Work

None.

### Sprint 17.37f5: Derive the recovered release bytes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/ResourceRecord.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Derive the one canonical released successor from an exact owned predecessor for the reverse child.

#### Deliverables

- Return only the exact recovered owned-to-released successor for the admitted plan, frame, and resource.
- Use the same derivation for root verification, so the two sides cannot disagree about the transition.

#### Validation

On 2026-11-13 the settlement selection passed 64 cases, including malformed and substituted
predecessors; the resource-record selection passed nine and the rooted boundary selection passed 68.
The phase gate remains outstanding.

#### Remaining Work

None.

### Sprint 17.37f6a: Deliver the signed predecessor [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Deliver the signed predecessor to the admitted reverse node.

#### Deliverables

- Pass the verified predecessor to the matching node, with no predecessor on forward execution.

#### Validation

2026-11-13: the linux-cpu executor selection passed all five cases, including signed predecessor delivery
and refusal of an unwrapped reverse gate. The full phase gate remains outstanding.

#### Remaining Work

None.

### Sprint 17.37f6: Carry reverse resource transitions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child/Reverse.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Carry an authenticated predecessor through reverse execution and return its exact release transition.

#### Deliverables

- Expose the signed predecessor only to the matching prepared node and return a canonical observation.
- Refuse a resource-bearing settlement before acknowledgement until its durable join is installed.
- Preserve ordinary reverse observations and forward execution.

#### Validation

2026-11-13: linux-cpu checks passed the storeless source-boundary selection (3), executor selection (5),
cleanup selection (68), rooted selection (68), recursive crossing selection (3), and plan validator (22).
The routed selection passed all 10 cases on 2026-11-13, including a child release followed by root refusal
with its resource and unknown operation retained, and a foreign observation that retains its resource.

#### Remaining Work

None.

### Sprint 17.37f7: Admit settlement before publishing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Permit a validated journal transition to run after exact settlement admission and before its rooted row is published.

#### Deliverables

- Refuse a conflicting retained row before invoking the journal transition.
- Refuse a failed journal transition without publishing a settlement row.
- Preserve existing forward and descent settlement behavior.

#### Validation

2026-11-13: linux-cpu settlement selection passed 65 cases, including refusal of a journal continuation
without publishing and refusal of a conflicting retained row before the continuation. Prepared-boundary
selection passed 76, rooted selection 68, recursive crossings 3, and plan validator 22. The phase gate
remains outstanding.

#### Remaining Work

None.

### Sprint 17.37f8: Checkpoint admitted release before acknowledgement [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Retain the exact admitted resource settlement before acknowledging its journal outcome.

#### Deliverables

- Validate the live gate, exact predecessor, transition, and settlement row under the same protected entry.
- Publish and read back the admitted row before recording the released outcome.
- Refuse stale evidence or a conflicting row before changing resource or operation state.

#### Validation

2026-11-13: the linux-cpu rooted selection passed 68 cases, including checkpoint publication and refusal of
conflicting or stale evidence; the prepared selection passed 76, including the source ordering check. The
routed selection passed 10 cases and the plan validator passed 22. A process interruption at the
acknowledgement boundary remains untested. Later investigation found that an outer refusal ends the relay and
the child does not retry a settlement request, so the unreachable in-process retry and its unused checkpoint
selector were removed. On 2026-11-13 the resulting rooted selection passed 68 cases, including a protocol
assertion that a refused child cannot send another rooted request; the prepared selection passed 76 and the
routed selection passed 10. A further rooted selection passed 68 cases, including interrupted response
delivery after acknowledgement with the exact checkpoint and released resource retained. Real process-death
recovery is owned by Sprints 18.16 and 18.19.

#### Remaining Work

None.

### Sprint 17.37f: Settle managed reverse resource evidence [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Carry and durably settle managed resource changes from a reverse child before acknowledging teardown.

#### Deliverables

- Bind the returned resource settlement to the operation and its prepared journal gate.
- Prove release, foreign retention, stale evidence, and interrupted teardown preserve the correct record.

#### Validation

2026-11-13: the linux-cpu settlement selection passed 65 cases, including an exact journal retry after
the released resource bytes were already persisted and refusal of a conflicting retry without further writes.
The routed selection passed 10 cases on 2026-11-13 after connecting the journal, including successful
recursive release and foreign retention. After that connection the settlement selection passed 64,
prepared selection 76, rooted selection 68, recursive crossings 3, and plan validator 22. After removal
of the unreachable retry, the settlement selection passed 64, routed selection 10, and plan validator 22;
the interrupted-response case retained the released record and exact checkpoint. Real process-death recovery
belongs to phase 18; this phase's gate remains outstanding.

#### Remaining Work

None.

### Sprint 17.37g: Fence-only routed package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/OpenFrameExecutorGate.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Remove the obsolete unfenced package codec after the routed executor adopts the fence-bearing format.

#### Deliverables

- Remove the callerless version-two producer and reader and their obsolete tests.
- Keep canonical framing and malformed-field coverage for the fence-bearing package.

#### Validation

On 2026-11-13, x86_64 Linux on the dedicated WSL2 host passed 76 `prepared` cases,
including the fence-bearing codec and source-boundary cases, 10 `routed` cases including
the recursive process fixture, the `OpenFrameExecutorGate` compile-fail case, and 22
`DocValidator` cases. The phase gate remains outstanding.

#### Remaining Work

None.

### Sprint 17.37h: Failed-Up reverse gate direction [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Keep reverse work distinct from the invocation verb so cleanup after a failed Up consumes the signed reverse
gate envelope and reports a failed cleanup descent's actual detail.

#### Deliverables

- The child opens a reverse executor only from its authenticated recovery path; the executor retains that
  direction across successor responses and uses it when decoding operation gates.
- Failed-Up cleanup reports a failed descent's operation and detail. Forward gates remain forward-only.
- Signed-gate tests exercise reverse work under both Down and Up, and the real failed-Up fixture reaches its
  reverse callbacks without a duplicate retry.

#### Validation

On 2026-11-13, the executor selection passed five cases, including the signed-gate direction checks; the
`admits` selection passed 70 cases, including the real failed-Up recursive fixture. The Python suite passed
384 cases and the Python code checks passed on Windows.
The full `cabal test all` from `core/` then passed all 5,413 core tests on x86_64 Linux; its provider-live
component asserted the declared unsupported result because the opt-in live Incus lane was not requested.
The full `cabal test all -j1` from `demo/` passed its 169 demo cases and 5,413 core cases; its optional
provider-live component likewise asserted its declared unsupported result. Both Haskell gates ran on the
dedicated x86_64 Linux WSL2 distribution.

#### Remaining Work

None.

### Sprint 17.38: Protocol-safe lifecycle process route [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Runtime.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Derive a sanitized route that can carry the rooted protocol over child standard I/O.

#### Deliverables

- New hidden all-nominal `LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb`
  is the route's sole indexed type; the module's other declarations (`ChannelInteractivity`,
  `AdmittedLaunch`, `AdmittedEdge`, `AdmittedLayers`, `ValidatedArgument`, `ValidatedPath`) are unindexed,
  unexported derivation intermediates. It points in one direction only — at the child a frame is about to
  launch —
  and holds no coordinate of that frame's own session, because a middle frame is a nested frame of the root and
  the parent of a deeper child at the same time, and one value carrying both edges would let a frame open a
  session for the child it is spawning instead of for itself.
- Derivation accepts only the catalog forward/recovery packages and their plan-owned lift route: the forward
  producer reads route and binding input out of the `CatalogForwardHandoff`, the reverse producer reads
  package, route, binding input, and verb out of one prepared `ReverseDescent`, and the nested forward producer
  takes the route and binding input its only caller obtains together from `withImmediateTargetKernel`.
- Docker uses interactive standard input and `/`; Incus, Lima, and WSL use fixed noninteractive
  working-directory forms, including noninteractive sudo where applicable. A route is one plan-owned layer, or
  a root-relative composition of VM layers ending in one terminal VM or container layer, and every layer passes
  the same closed grammar. That grammar rejects detach/TTY/attach/stdin/entrypoint/workdir/signal overrides,
  separators, user payloads, and descriptor inheritance. The root producers strip the terminal container's
  `ConfigDelivery` from the catalog route, because the child configuration travels inside the signed package;
  a route that reaches the grammar still carrying one is refused.
- Beside the route this sprint adds the one startup step that has no owner yet: a frame's own opening. It is
  not a fold on the route. It admits the nested arm of the frame's own installed runtime, builds the exact
  four-field `OpenFrame` from a fresh nonce alone, carries it through the frame's own carrier, and verifies the
  signed answer against the independently installed key and those exact request bytes, admitting only an
  `Opened`. What it yields is that exact request and that exact signed response and no decoded coordinate, so
  the storeless frame executor built from the pair still verifies both for itself.
- Everything after the opening belongs to `Lifecycle.FrameExecutor`, which already owns the root-selected path,
  session, stage, ordinal, and predecessor and the closed post-open request families. This sprint introduces no
  second owner of those coordinates and builds no post-open request.
- Work is limited to the three named production modules, targets at most 400 significant lines, and must
  split before exceeding that bound; it adopts no spawn call site, and `Handoff.Process` changes only at the
  reverse route derivation it already calls.

#### Validation

The route's whole claim is that a lift context says where a child runs and says nothing about whether its
standard input and output are free, so the guards are about what the rendered vector cannot contain as much
as what it does. Forward derivation reads its edge out of the package's own binding input rather than an
argument, and Remaining Work owes the same for the reverse producer: the parent and child frames are that
input's, a frame reaching itself refuses, and the phase must be the one that edge belongs to, so a forward descent cannot be relaunched through the reverse producer. Each provider
then renders one written-out shape — Docker interactive at `/`, Incus, Lima, and WSL noninteractive at `/`
with noninteractive sudo where the guest's default user is not root — and the child's command is the fixed,
coordinate-free lifecycle-child entry marker. The authenticated Offer carries the invocation verb, so no
descriptive command argument competes with that signed fact. `ConfigDelivery` is the case
that matters most: it would put a `cat` on the descriptor the root's request and response bytes travel on.
The root producers therefore strip it from the catalog route before the grammar runs — the configuration
already travels in the signed package — and the grammar refuses any route that still carries one, so no
rendered vector contains a delivery. Container extra arguments, a container that outlives its
exchange, a non-absolute or delimiter-bearing path, and any derived name reading as an option, a separator,
or a descriptor request are refused on the same closed grammar, which is what leaves the detach, TTY, attach,
standard-input, entrypoint, working-directory, and signal overrides unrepresentable rather than filtered.

The opening is guarded as the separate thing it is. It hangs off no route, because a route describes the
edge below a frame and an opening belongs to the edge above it. Admission is not this owner's to assert
either: it is read off the nested arm of the frame's own installed runtime, and `Handoff.Runtime` gains the
mirror of its root-arm narrowing for exactly that, admitting the keyless arm alone and disclosing the
authenticated frame itself rather than a `Maybe`, so a root arm speaks for no frame here instead of being
handed over with a `Nothing` beside it. The request is the four-field `OpenFrame` built from a fresh nonce
and nothing else, and only a verified `Opened` is admitted; what leaves is the exact request and the exact
signed response rather than any decoded coordinate. No post-open request builder exists in this owner at all,
because the storeless frame executor already owns every coordinate an opening produces.

Both owners are Cabal-private. The route's direct behavioral control links its actual hidden interface into a
temporary test executable; source and compile-fail guards hold the boundary. Its runtime callers are
`Command.Child`'s nested forward launch and `Handoff.Process`'s reverse launch.
`ProjectPlanSpec` pins the route's export set, its Cabal-private placement, the seven nominal roles, the
module's `data` declarations, the minted edge indices, the derive-from-package ordering in the producers, the
binding-input edge and phase checks, the rendered subcommand, the three container refusals, all four provider
argv shapes, the composed-layer validation and the refusal of any other shape, the option check, the opening's
nested-arm
admission and verify-then-yield order, its single refusal branch, the absence of every post-open request
builder, the single verified-response helper, both new runtime-fold fragments, the absence of store, signer,
catalog, executor, and process names, and both line budgets. `CompileFailSpec` adds
`ImportHandoffProcessRoute.hs` for the hidden-module boundary and `RenderLifecycleProcessRouteArgv.hs` for the
lift facade's absence of any sanitized renderer. `HandoffSpec` re-pins the Cabal digest and the rooted
request/response/recovery attribution lists across the one added module row.

Behavioural coverage needs a real child process on the far end of the rendered vector and a real carrier under
the opening. `RecursiveLifecycleSpec`'s public `up`, `down`, and `destroy` cases launch a VM-layer and a
container-layer child through derived routes and run the opening across those real process boundaries; the
fixture's container lift carries a `ConfigDelivery`, so those cases also show the root producers stripping it.
The private route control also exercises grammar refusals and exact provider argument vectors.

The sprint closes when `ProjectPlanSpec` pins the reverse producer's single `ReverseDescent` elimination and
the absence of any callerless route producer, the module doc comments describe one-layer and composed routes
and no opened route, the forward-kernel layer refusal and the behavioural route refusal and per-provider argv
cases named in Remaining Work pass, the duplicated-argv guard runs on lexer tokens, `rejectedOverrides` is
gone, `RecursiveLifecycleSpec`'s reverse cases still pass, and the four host static gate commands pass.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-14 at
`1985 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. `Handoff.Process.Route` stands at 255
significant lines and `Handoff.Runtime` at 185, so both owners are well inside the sprint's 400-line bound.

On 2026-08-21, the corrected fixed-marker route passed its focused source/shape case and the complete
warning-clean core gate on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0: all 2,300 tests passed in
136.87 seconds. The route now launches only `--hostbootstrap-lifecycle-child`; the authenticated Offer is
the sole source of the verb and edge coordinates.

On 2026-11-13, the private route control passed its provider-vector and refusal cases on x86_64 Linux;
the protocol-safe source guard, 13 lineage-selected cases, 10 routed cases, 22 documentation checks, and
`ImportHandoffProcessRoute` compile-fail case passed. The full core gate passed 5,413 tests, the full demo
gate passed 169 demo and 5,413 core tests, and the Windows Python suite passed 384 tests alongside the Python
code checks. Both optional provider-live components asserted their declared unsupported results.

The expanded private control also passed exact malformed path, mount, provider, frame, and container refusals,
and exercised opening with an authenticated nested runtime: root-arm refusal, invalid nonce, carrier refusal,
invalid response, signer refusal of the wrong response family, and a signed `Opened`. Invalid composed lift
shapes and empty recovery package components are excluded by their owning constructors and codecs before a
route can receive them. A composed-route catalog drift was refused before a forward package or protected-store
mutation; all 20 catalog-selected cases, 15 recursive-lifecycle-selected cases, and 22 documentation cases
passed. After this test expansion, the complete core gate passed 5,414 tests in 878.21 seconds and the
complete demo gate passed 169 demo tests and 5,414 core tests in 880.76 seconds on 2026-11-13 in the
dedicated x86_64 Linux WSL2 distribution. The provider-live component reported its unsupported, not-requested
result; these runs do not claim a live Incus exercise. The Python code checks and 384-test Python suite also
passed on Windows after the expansion.

The dedicated WSL distribution has `strace` installed for diagnostics and uses C:-backed native build
caches. Its `hostbootstrap-build-caches.service` restores both bind mounts at startup; restarting the
distribution confirmed the service active and both mounts on ext4.

#### Remaining Work

None.

### Sprint 17.39: Protocol-safe child standard-I/O isolation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Give the dedicated child receiver private protocol descriptors before any lifecycle callback can touch standard
input or output.

#### Deliverables

- `Handoff.Protocol.withPrivateProtocolStdio` is the one owner of the isolation, shared by the receiver and
  `Handoff.Transaction`. It duplicates the original standard input/output handles for the private binary
  protocol channel before the receiver invokes any configuration, plan, executor, or lifecycle continuation.
- Global standard input is redirected to the null device and global standard output to standard error for the
  entire callback, so ordinary reads and diagnostics cannot steal or corrupt protocol bytes.
- One bracket flushes, redirects, restores, and closes every duplicate on success, refusal, exception, or
  cancellation; protocol standard output remains binary and diagnostics remain field-free.
- The linux-cpu implementation has one source-guarded `GHC.IO.Handle` duplication policy and no ambient
  stdin/stdout channel, alternate descriptor, exported raw-channel entry, or exported testing seam.
- Work is limited to the two named production modules, targets at most 400 significant lines, adds no named
  type, and adopts only the existing dedicated-receiver channel call site.

#### Validation

The isolation is a claim about which handle names what, and in what order, so the guards are about order as
much as about shape. Both duplications precede either redirection, because a handle duplicated after the
global one has already moved names the wrong descriptor; the protocol pair and the restore pair are taken
separately, because the protocol handles are closed at the end and the globals still have to be restored from
something. The outer bracket owns the duplicates and the inner bracket owns only the redirection, so
restoration always runs before anything it would restore from is closed, and the two restores are attempted
independently so that one failing does not strand the other. Standard input goes to the host's own null
device — selected by `os`, never probed — so an ordinary read sees EOF rather than a protocol frame, and
standard output goes to standard error so an ordinary write becomes a diagnostic rather than a byte inside a
length-framed message.

The surface is the other half of the claim. `withIsolatedReceivedHandoffEdge` takes the installed identity,
the installed key, and the four closed continuations and nothing else: its type mentions neither
`HandoffChannel` nor `Handle`, so there is no argument through which a caller supplies a descriptor. The
bracket is `withPrivateProtocolStdio` in `Handoff.Protocol`, whose helpers stay private, and it holds the
receiver's only channel construction. `withReceivedHandoffEdge` is private to `Handoff.Receiver`, with the
isolated wrapper as its sole caller. `Handoff.Protocol` no longer exposes an ambient channel.

`HandoffSpec` pins the export list, the Cabal-private placement, the channel-free and handle-free entry
signature, the two-bracket structure, the acquisition order, both redirections, the independent restores, the
closing of all five duplicates, the host-selected null device, the absence of a named type, the absence of
every ambient-descriptor and process identifier, the private helper set, the seam absence, and the work's
line budget. The rooted-carrier sprint's frozen receiver baseline joins its two already-frozen peers as a
constant, so that sprint's own nine-line delta stays exactly what it was rather than growing with every later
sprint that touches the receiver, and the frozen receiver-source digest is re-pinned across this change.

Behavioural coverage over real pipes needs a process on the far end of those descriptors. The owner is
Cabal-private and adds no testing seam. `RecursiveLifecycleSpec`'s public `up`, `down`, and `destroy` cases
run binary framing through the isolated receiver across real process boundaries, including a callback that
reads standard input and writes standard output. A subprocess probe exercises restoration after normal return,
an exception, and cancellation, and checks the private channel handles after each exit.

The sprint closes when the recursive fixture's child-frame step writes to standard output and reads standard
input to EOF inside the callback and the public `up` case still passes; `HandoffSpec` pins the isolation owner
in `Handoff.Protocol`, the receiver's export list without `withReceivedHandoffEdge`, and the protocol owner's
export list without `stdioHandoffChannel`; and the four host static gate commands pass.

On 2026-11-13 the child-frame fixture was extended to write a diagnostic through standard output and force a
standard-input read to EOF. All 15 recursive-lifecycle-selected cases passed in the dedicated Linux WSL2
distribution, including public `up`, `down`, `destroy`, and failed-up cleanup. The scripted protocol
tests now exercise the isolated receiver through subprocesses. The unused ambient `stdioHandoffChannel` has been deleted and its absence added to
the protocol source guard, which passed on the same host. The subprocess isolation probe also passed its
exception and thread-cancellation cases, checking both streams after restoration and confirming that the
original exception escapes; four stdio-selected cases passed.
`HandoffFormerChannelProducers.hs` also passed its compile-fail check for the named facade omissions.
On 2026-11-14 the subprocess probe additionally verified that both private channel handles are closed after
normal return, exception, and cancellation; all four stdio-selected cases passed. The recursive fixture now
records that its child callback reached the EOF check, and all 15 recursive-lifecycle-selected cases passed.
The stdio cases were repeated with a forced `hGetContents` read to EOF before exception and cancellation;
both original streams still restored successfully.
The hidden-module compile-fail fixture now targets the isolated entry, and all three
`ImportHandoffReceiver`-selected boundary checks passed on 2026-11-14.
A new subprocess fixture drove a real authenticated offer through the isolated receiver and a callback that
uses ordinary standard I/O; the focused case passed. The advertised-key mismatch case has also been moved to
that fixture, followed by the other-project and wrong-scope signed-capsule cases. All four real-process cases
passed alongside the remaining receiver-selected cases on 2026-11-14 (20 selected cases total).
The malformed Offer and Grant, wrong-request refusal, and callback-decline cases have also been moved to the
subprocess fixture; the parent checks EOF after the child exits and the child checks the exact receiver result.
All 20 receiver-selected cases passed after that migration on 2026-11-14.
The callback IOException and interrupt cases have been moved as well; the complete 20-case receiver selection
passed again on 2026-11-14, including exact exception and post-exit EOF checks.
The successful report, invalid acknowledgement, consumed report refusal, and post-acknowledgement callback
cases have been moved to the subprocess fixture with the exact report bytes passed to the child; validation
passed in the 20-case receiver selection on 2026-11-14. The first build rejected an unused helper left by the
migration; removing it allowed the warning-clean run to pass.
The consumed-relay and signed-rooted-refusal cases now run inside the isolated subprocess as well, retaining
their nested channel and repeated-operation assertions; all 20 receiver-selected cases passed on 2026-11-14.
The exact-limit and over-limit config-carrier cases now use the isolated subprocess, including a full-byte
payload assertion inside the child. All 20 receiver-selected cases passed on 2026-11-14.
The recovery-carrier success, wrong-phase, cross-proof, and hostile-verb cases have been moved to the isolated
subprocess with their real signed grants; all 20 carrier-selected cases passed on 2026-11-14.
The self-sent relay refusal and oversized requester-path cases have been moved to the isolated subprocess;
all four requester-selected cases passed on 2026-11-14. The obsolete raw scripted-receiver helper was removed.
The requester-mutation duplex fixture now launches the isolated receiver in a separate process and takes its
root-state snapshot at the actual request before mutation; all four requester-selected cases passed on
2026-11-14, including all seven path variants and the wrong-parent refusal.
The nested trailing-offer dialogue has been converted to separate middle and leaf receiver processes, with
the leaf's result checking whether its callback ran. All six duplex-selected cases passed on 2026-11-14;
an initial compile caught and corrected a missing parenthesis in the leaf-refusal expectation.
The severed-route dialogue has also been converted to middle and leaf receiver processes, retaining the
pre-cut root snapshot and leaf non-admission check; all six duplex-selected cases passed on 2026-11-14.
The settled-grant replay case has been converted to receiver subprocesses, and the raw receiver export and
its last test helper have been removed. All six duplex-selected cases, 229 HandoffSpec cases, and the updated
isolated-entry private compilation control passed on 2026-11-14.
The full core run then found one fixture-inventory failure: the public compile-fail fixture still imported
the now-deleted `stdioHandoffChannel`. The fixture and its expected diagnostics were corrected; all 54
inventory-selected checks and the named compile-fail case passed on 2026-11-14. The parallel demo run was
stopped after the shared failure was identified, so it supplies no completed gate result. On the corrected
tree, the full core gate passed 5,416 tests in 902.15 seconds and the demo gate passed 169 demo tests plus
5,416 core tests in 905.31 seconds on x86_64 Linux under the dedicated SSD-backed WSL2 distribution. The
provider-live components reported unsupported because the live lane was not requested; these runs do not
claim live Incus coverage. Windows Python code checks and the 384-test Python suite passed with 100% coverage.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-14 at
`1983 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. The isolation stands at 87 significant lines
inside an owner that now stands at 680, so the sprint's work is well inside its 400-line bound.

#### Remaining Work

None.

### Sprint 17.40: POSIX lifecycle process owner [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (build metadata only)
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Own the child process, duplex descriptors, fixed control deadlines, cancellation, and reap in one bracket.

#### Deliverables

- The owner spawns only an exact `LifecycleProcessRoute` into a new process group with isolated descriptors.
- One bracket owns stdin/stdout/stderr closure, relay lifetime, the fixed runtime completion operation, and child
  wait. No caller supplies a callback, deadline, grace value, process shape, or channel; the shared
  `Effect.ChildGroup` constant bounds the TERM grace, and the relay's bound the scope/admission and
  control-frame waits — the relay's fixed control-frame deadline on the challenge is the only bound on a child
  that never sends its first frame — while
  admitted backend effects retain their own closed policies instead of one blanket lifecycle wall-clock
  deadline. The relay owns those waits, so it is one of this sprint's production modules; the fixed completion
  operation is adopted from `Handoff.Completion` unchanged.
- Cancellation, fixed-control timeout, protocol failure, or catchable exception sends group TERM, waits the
  fixed grace, sends group KILL if needed, and unconditionally reaps before bracket release.
- EOF, exit zero, diagnostic text, or channel closure cannot substitute for rooted completion and root receipt.
- Work is limited to the named production modules, targets at most 400 significant lines, adds no named type,
  and adopts no command call site.

#### Validation

A child is a resource with three ways of outliving the thing that wanted it — it can keep running after the
exchange fails, leave descendants behind after it exits, and hold descriptors open after nobody is reading
them — so the guards are about the release path as much as the launch. What is spawned is the sanitized route
and nothing else: the host tool is resolved to an absolute path through the installed configuration, so a bare
command name cannot be executed even if one reached the argument vector. One process shape exists at all: private pipes for standard input and output, inherited standard error, its own group, and closed
descriptors. The release path runs on normal return, refusal, protocol failure, exception, and asynchronous
cancellation alike — group TERM, fixed grace, group KILL if the group is still present, an unconditional wait,
and only then the pipes — and it signals the group rather than the process, which is what makes a shell or
provider the child launched go away with it.

The deadline shape is the part worth stating carefully, because getting it wrong is invisible until something
slow is legitimate. The owner bounds the termination grace through `Effect.ChildGroup`. Everything else that
can be bounded belongs to the relay, which is why the relay is a production module of this sprint: it receives
the challenge and the acceptance of the offered digest under a fixed 120-second control-frame deadline whose
expiry is its own closed refusal — which is also what bounds a child that never sends its first frame — and
deliberately leaves the wait that follows admission unbounded. That wait is the
admitted backend effect, and the effect keeps its own closed policy; one wall-clock deadline across it would
turn every slow provisioning step into a protocol failure. A child that is working is not a child that has
stopped talking.

Nor does exiting mean succeeding. EOF on the pipe, a zero exit status, reassuring text on standard error, and
a closed channel are all things a child that never completed its edge can produce, so the only thing reported
as success is the rooted completion the relay obtained and the root recorded — reached through the fixed
completion kernel for the edge's direction rather than a caller-selected one.

`HandoffSpec` pins the owner's export set, its unconditional Cabal-private placement, the absence of a named
type, both fixed completion compositions, the admitted-route-and-absolute-path launch order, the single
process shape, the full termination-and-reap order, the
group signal, the release-path bracket, the absence of every store, broker, catalog, and executor identifier,
the relay's bounded control frame beside its unbounded serving wait, the route's admitted-only launch fold,
and both line budgets. `CompileFailSpec` adds `ImportHandoffProcess.hs` for the hidden-module boundary. The
rooted-transport sprint's frozen relay figure joins its already-frozen peers as a constant, so that sprint's
own increment stays what it was rather than growing with every later sprint that touches the relay, and the
relay source and Cabal digests are re-pinned.

Behavioural coverage over real local processes comes through the public command path.
`RecursiveLifecycleSpec`'s public `up`, `down`, `destroy`, failed-up, and failed-reverse cases run success,
refusal, cancellation, natural exit, and reap through this owner across real process boundaries. The scoped
group cases exercise TERM-resistant leaders and descendants, KILL escalation, and descendant cleanup.

The sprint closes when `HandoffSpec` pins `exchange` without a `timeout` around `handoffChannel` and the
owner's Haddock without a launch bound or an opened route, and `launchMicros` is gone from
`Effect.ChildGroup`; `EffectSpec` carries the TERM-to-KILL escalation case
below; the grandchild-reaped case passes; the release path rethrows asynchronous exceptions and escalates on
group existence rather than the leader's exit; and the four host static gate commands pass.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-14 at
`1985 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. `Handoff.Process` stands at 157 significant
lines and `Handoff.Process.Route` at 398; the relay increment is 13 lines, so every owner is inside the
sprint's 400-line bound.

`Handoff.Process` and `Handoff.Process.Route` are built as private modules on every gate host. The
compile-fail fixtures therefore require the same hidden-module diagnostic everywhere. Platform-specific
signal and termination primitives live behind the shared process owner; they do not remove the module or
its command entry from Windows. Native gate evidence belongs to this phase and the
[host-portability acceptance phase](phase-29-host-portability-acceptance.md).

On 2026-11-14, channel construction was changed to run directly, the unused `launchMicros` constant was
removed, and both exception handlers were changed to rethrow asynchronous exceptions. The source guard now
checks that the removed constant is absent across library sources. All 51 process-selected cases passed on
x86_64 Linux under WSL2, including the source guard and recursive lifecycle cases. Direct confirmation that
asynchronous exceptions escape after cleanup remains owed.
An additional POSIX group case explicitly sends TERM, observes a 200-ms timeout while the leader and
descendant remain alive, sends KILL, and checks group and process exit. Both escalation-selected cases passed
on x86_64 Linux under WSL2 on 2026-11-14.
The process owner now gives a successfully completed child a bounded chance to exit before teardown, while
failure and cancellation enter teardown immediately. Teardown skips signalling an already absent group and
still escalates a surviving group independently of its leader. All 51 process-selected cases passed on
2026-11-14, including the updated source guard and public recursive lifecycle cases.
The outer group finalizer was then aligned to avoid signalling an already empty group on both platform rows;
45 group-selected and 52 process-selected cases passed on x86_64 Linux under WSL2 on 2026-11-14. A
host-portable native group-stop case exercises the Windows job and POSIX group rows; its Linux case passed,
while native Windows confirmation belongs to host-portability acceptance.
A further POSIX case makes the leader exit on TERM while its descendant ignores TERM, then checks group-aware
KILL escalation and descendant removal. All 46 group-selected cases passed on x86_64 Linux under WSL2 on
2026-11-14, including the coverage inventory for all four scoped POSIX cases.
The process-owner declaration guard has been widened to include type synonyms and families, classes, and
pattern synonyms while excluding role annotations and imports; its synthetic self-check passed in the 52-case
process selection on 2026-11-14.
A real recursive lifecycle cancellation probe now interrupts the root thread after its VM child enters a
controlled wait, checks the propagated `ThreadKilled`, and observes that child's PID disappear. Both
cancellation-selected cases passed on x86_64 Linux under WSL2 on 2026-11-14.
A natural-exit fixture now delays each completed child briefly after its protocol returns and records its
post-protocol work; the real two-boundary lifecycle case passed on x86_64 Linux under WSL2 on 2026-11-14.
The complete recursive selection passed 17 cases and `DocValidatorSpec` passed 22 after the architecture
documents were aligned. On 2026-11-14 the full core gate passed 5,421 tests in 913.62 seconds and the demo
gate passed its demo suite and 5,421 core tests in 881.76 seconds on x86_64 Linux under the dedicated WSL2
distribution. The provider-live components asserted their not-requested unsupported result; these runs do
not claim live Incus coverage. Windows Python code checks and all 384 Python tests passed with 100% coverage.

#### Remaining Work

None.

### Sprint 17.41: Forward child receiver adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Adopt authenticated forward child packages into a long-lived storeless frame executor, over the
frame-child entry the handoff phase supplies.

#### Deliverables

- The fixed coordinate-free lifecycle-child entry the
  [authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md) supplies delegates a
  lifecycle conversation to `Command.Child`, which derives exact child config and frame plan from the
  authenticated scope-first, catalog-bound forward package and isolated receiver channel. This sprint adds
  the conversation, not the entry: the marker it arrives through already carries no coordinates, path,
  authority, or user-selected action, and this sprint gives it none.
- It verifies authenticated root scope and opens one `FrameExecutor` for repeated rooted requests.
- Each Prepared response drives only its exact local node effect and returns one typed observation.
- Descend and terminal branches return closed protocol results without local settlement or receipt persistence.
- Work is limited to the three named production modules, targets at most 400 significant lines, adds no named
  type, and adopts only the one forward child receiver call site.

#### Validation

Source and ownership guards cover exact marker dispatch, scope/config/plan admission order, the closed request
loop, Prepared-only execution, explicit descent refusal, terminal receipt order, storeless imports, and the
line budget. The warning-clean core gate covers the existing real Receiver framing and process primitives,
and `RecursiveLifecycleSpec`'s real-process matrix (Sprint 17.54) composes them with the root coordinator.

On 2026-08-21, the focused forward-child ownership guard passed on x86_64 Linux with GHC 9.12.4 and
Cabal 3.16.1.0. The complete `cabal test all --ghc-options=-Werror` gate then passed all 2,301 tests. The
new private owner stands at 351 significant lines; together with its four-line CLI adoption it remains below
the sprint's 400-line limit.

On 2026-09-05, `cabal test all --ghc-options=-Werror` passed all 2,482 tests on native arm64
macOS 26.6.2 with GHC 9.12.4 and Cabal 3.16.1.0 in 382.92 seconds. The gate includes the complete
real-process forward/reverse matrix, root-only durable admission, storeless child observations and
terminal receipts. Absence guards cover child durable authority, and the compile-fail admission fixture
exercises the active reverse-root kernel.

On 2026-09-05 the complete native Windows gate passed 2,477/2,477 in 318.23 seconds,
and the Linux gate passed 2,482/2,482 in 139.04 seconds, with GHC 9.12.4 and Cabal 3.16.1.0.
The macOS gate and rationale-linked absence guards also pass.

The forward child's local step call now converts synchronous exceptions to failed observations while preserving
asynchronous cancellation; nested descent delegates to its own child and has no `runStep` call. The Child-owner
budget now counts named interpreter sections, excluding module metadata, imports, and the worked-demo activation
relay. The warning-clean `cabal test all` from `core/` validates these changes.

On 2026-11-14, WSL2 x86_64 with GHC 9.12.4 passed the focused `throwing` cases, including ordinary
exceptions and `SafetyRefusal` across the real container child, and the focused `storeless` source guards.
The test checks exit status and diagnostic, the settled operation, and the acknowledged failed terminal
report containing the container observation. The complete `cabal test all -j4 --test-show-details=direct
--test-option=--hide-successes` gate passed 5,421 core tests in 868.60 seconds, including all 14 Linux
recursive lifecycle cases; the optional native Incus provider lane reported not requested.

#### Remaining Work

None.

### Sprint 17.42: Root coordinator and Chain adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/RootedPlan.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`, `documents/architecture/harness_workflow.md`

#### Objective

Drive root and nested forward frames through one root-owned recursive coordinator.

#### Deliverables

- The root command supplies its already indexed handoff scope and installed signing identity to the sealed
  lifecycle entry; neither is reconstructed from descriptive project text inside the interpreter.
- Root entry opens and strictly rereads the persisted catalog, then opens every catalog-selected remote frame
  session root-first before `Chain` interpretation. The root frame itself remains on its already-open
  acquisition journal and Execute cursor rather than inventing a loopback wire session.
- Local-root nodes and remote-frame nodes use the same prepare/settle journal contract.
- Declared descent selects the exact catalog edge and process owner; undeclared descent refuses.
- A nested storeless frame derives its immediate sanitized process route only inside the exact target-plan
  projection, launches that child with its keyless broker link, and returns the descendant observation to the
  root; it never receives a catalog or root session authority.
- Settled node and descendant observations advance only the matching root session. Canonical terminal reports,
  completion evidence, and the child-first terminal continuation are produced by the semantic-completion owner
  (Sprint 17.43a). A `NextNode` that arrives after every node and the descent have settled is answered with a
  signed `Refused` saying no node remains and the frame must close.
- The frame's `OpenFrame` service answers an exact replay — the same envelope path, nonce, and request bytes —
  with the byte-identical `Opened` by attaching through the retained pre-attach session, whose attachment
  converges; a differing replay still refuses.
- After journal closure, an exact terminal completion retry must converge on the retained response and must not
  close or settle the journal twice; an interrupted publication must remain recoverable.
- The root lifecycle link exposes the forward edge, rooted exchange, fixed completion, and activation-signing
  capabilities; the activation signer is the installed activation key behind `withActivationBroker`, adopted
  at this call site by Sprint 24.33. Recovery signing is absent rather than populated with placeholder authority.
- Work is limited to the eight named production modules, targets at most 400 significant lines per coherent
  implementation split, adds no named type, and adopts at most the one root-Up interpreter call site. `Command`
  performs only the authority-preserving scope/key handoff; recursive coordination remains below the sealed entry.

#### Validation

Cover root-only execution plus the nonterminal root→VM and root→VM→container coordinator paths: catalog-first
session opening, multi-node prepare/settle, nested descent, retry, refusal, and child failure with root journal
readback. Guard sole store ownership and run the warning-clean core gate. Terminal success and receipt are not
part of this sprint's gate because this sprint deliberately possesses neither their canonical report nor their
completion evidence.

On 2026-08-21, the focused handoff, indexed-plan, Production-route, and coordinator ownership gate passed
all 183 selected tests on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. The complete
`cabal test all --ghc-options=-Werror` gate then passed all 2,301 tests. Its CLI integration fixture proved
that a descended Production entry persists and reads back its exact catalog before the first root effect;
the remaining source and behavioral guards jointly cover root-only lazy key loading, root-first session
opening, exact path/edge dispatch, multi-node durable prepare/settle, nested immediate-target process routing,
retry/refusal preservation, sole-store ownership, and the closed terminal refusal boundary.

The sprint closes when `ProjectPlanSpec` pins the forward coordinator's `open` branch routing a second
`OpenFrame` through the retained pre-attach session and pins the reworded post-completion `NextNode` refusal,
the forward settle/descend-result refusal cases, the forward-link narrowing case, the rejected-admission and
requester-provenance cases, and the activation-signing route cases named in Remaining Work pass,
`RecursiveLifecycleSpec`'s public `up`, `down`, and `destroy` cases still pass, and the four host static gate
commands pass.

On 2026-11-14, the focused `exhausted` cases passed on WSL2 x86_64 with GHC 9.12.4, including
`ProjectPlanSpec`'s signed refusal for an exhausted forward frame and its guard for replay through the
retained pre-attachment session without replacing the advanced session. The plan validator passed all 22
cases after splitting live grant admission into two bounded sprints. Later results are recorded below.

On 2026-11-14, the focused `forward root relay` pipe-pair case passed on WSL2 x86_64 with GHC 9.12.4.
It drives actual recovery-kind ordinary opening, recoverable opening, and recovery-signing requests through
the forward root relay, asserting their exact refusals, admission count, and unchanged protected-store
image. The ordinary request is refused by the service before `linkOpenRaw`.
The focused `reverse descent attachment is ordered` source guard passed and pins the forward link's own
payload-kind check before its admission and registration calls, as well as the check's exact accepted kind.
The revised link Haddock was checked against those fields and the supplied callback routing.
The focused `RecursiveLifecycleSpec` selection passed 17 tests after the forward descent-result admission
change; its existing real-process cases cover successful nested descent and failed-Up unwind. The additional
foreign-domain and unsolicited-descent refusal cases are recorded below.
The focused `rejected admitted edge` case passed: the actual admission callback rejects once without a
store change, a fresh-token grant returns `HandoffEdgeUnregistered`, and an accepted control grants.
The focused `rooted opening replay` case passed: the retained lower opening returns byte-identical signed
responses for the exact retry, rejects a different nonce or envelope path, and leaves its protected image
unchanged. The focused `coordinator replays` real-process case passed: the fixture duplicates the exact
opening after a Prepared response, compares the signed reply byte-for-byte, and completes `project up`
through the advanced session. It also sends a changed nonce and a changed path, asserts each exact refusal,
and compares all protected records and versions before and after each request.
The same focused case passed with a foreign node, a descent-domain body presented as a node observation,
an unsolicited descent result, and a node-domain body after a real descent was issued; each is refused
before any protected record or version changes.
The complete focused recursive lifecycle selection then passed 18 tests with the new proxy fixture.
The focused `requester path limits` process-backed relay case passed with a post-open inner path whose
leaf suffix matches the envelope but whose full path differs: the root refused it before its endpoint or
protected store changed. The same case also passed for an empty path, an invalid suffix, and a path outside
the admitted child. The focused `another requested parent` case passed with the exact refusal and unchanged
registration.
The focused `single-frame step refuses` `ChainSpec` case passed and checks that an execution with no
installed activation service returns `runtime activation signing service is absent`.
The focused `installed root signer` real-process case passed for the admitted child placement and foreign
frame, plan, service, and effects. The admitted signature verifies with the independently installed public
key; each foreign request reports its exact activation refusal at the root command.
The complete focused recursive lifecycle selection passed all 19 selected tests with the replay and
activation fixtures in place.
An initial complete core gate on 2026-11-14 ran 5,427 tests and failed two `HandoffSpec` source guards:
the exact Relay line-count assertion still expected 2,767 after the two-line forward-link change, and the
rooted-module test importer list omitted `RecursiveLifecycleSpec`. Both assertions were updated and the
complete gate was rerun below. The concurrent demo gate was started against the same failing assertions and
is diagnostic only.
After correcting those assertions on 2026-11-14, the host static gate passed: `cabal test all -j4
--test-show-details=direct --test-option=--hide-successes` from `core/` passed 5,427 tests in 922.02 seconds;
the same command from `demo/` passed 5,427 core tests in 932.22 seconds and 169 demo tests; both runs used
SSD-backed WSL2 x86_64 with GHC 9.12.4. On Windows, `poetry run python -m hostbootstrap.check_code` passed,
and `poetry run python -m hostbootstrap.test_all` passed 384 tests at 100% reported coverage. The optional
native provider-live lane was not requested.

An interactive GHCi check on 2026-11-14 loaded the production relay source and invoked its private
`linkOpenRaw` field with a `RecoveryAdapterWire` input under a production root using a test-installed
project identity. It returned the exact payload-kind refusal, called the admission callback zero times,
and preserved all protected record bytes and versions. A `NarrowedProjectConfig` control succeeded,
called admission once, and changed the store. This was a one-off behavioral check; the persistent suite
contains the pipe-level cases and source guard above, but no direct-field behavioral regression case.

#### Remaining Work

None.

### Sprint 17.42a: Revalidate the live acquisition at grant preparation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Revalidate the root acquisition binding in the same protected entry that prepares a rooted grant.

#### Deliverables

- Carry the root's retained acquisition validation into forward journal preparation and check the actual
  Harness or Production mode and epoch, bound lease and version, and retained snapshot before publishing
  any Unknown operation. Keep the existing broker-allocation and operation-fence checks in that entry.
- Preserve the authority boundary: the child supplies neither the live validator nor descriptive data that
  can substitute for it, and validation and preparation do not use separate protected entries.

#### Validation

Exercise per-grant stale mode, rotated broker, missing, versioned and frozen lease, and changed snapshot.
Assert exact refusals, zero effect callbacks, and complete protected-store before-images. Run the host static gate.

On 2026-11-14, the plan validator passed all 22 cases after the sprint status update. The forward journal
route now retains the root authority and cursor and validates them inside the preparation entry. An initial
build found a polymorphic validator type error; after adding its signature, `cabal build all -j4` from
`core/` passed on the SSD-backed WSL2 x86_64 instance with GHC 9.12.4. The behavioral cases and full gate
remain outstanding.

The existing real-process `RecursiveLifecycleSpec` selection then passed all 19 tests on that instance
after the forward journal change. The focused `forward` selection passed all 39 tests, including a new
rooted journal case that first issues a valid grant and then checks another grant against a changed mode,
rotated broker, missing lease, same-byte lease version drift, frozen lease, or changed snapshot. Every
refusal is compared with its exact diagnostic, invokes no grant callback, and preserves the complete
protected-store image; the unchanged control produces a grant and writes its operation. The full gate
remains outstanding.

On 2026-11-14 the Windows Python legs of the host static gate passed: `poetry run python -m
hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` (384 tests, 100% reported
coverage). Initial WSL2 `core/` and `demo/` Cabal legs were interrupted after discovering that the
rooted-module source-hash guard still pinned the pre-change source. The guard was updated; both legs
were restarted against the corrected test source. A focused `rooted` selection passed all 71 tests,
including the revised source-integrity guard, before those full runs.
The restarted `cabal test all -j4 --test-show-details=direct --test-option=--hide-successes` from `core/`
passed all 5,428 core tests in 1,194.78 seconds; the optional native provider-live lane was not requested.
The same command from `demo/` passed all 5,428 core tests in 1,154.35 seconds and all 169 demo tests;
the optional native provider-live lane was not requested there either. These complete the sprint's host
static gate on the changed source.

#### Remaining Work

None.

### Sprint 17.42b: Retain root resource observations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Retain and recheck root-observed resource records as groundwork for plan-owned grant admission.

#### Deliverables

- Project the admitted node's closed-family and declared-provider dependency coordinates and capture
  verified root resource records with their store identity and physical version.
- Return observations from successful settlement, provide replacement by exact record identity, and select
  exact requested records without accepting missing or duplicate requirements.
- Provide an entry-scoped journal preparation check that refuses changed physical versions before writing
  Unknown. The following sprints own coordinator retention, complete projections, live probes and grant adoption.

#### Validation

Exercise the plan projection, observation capture and selection, and same-byte physical-version drift;
assert exact refusals and protected-store before-images. Run the host static gate.

On 2026-11-14, the plan validator passed all 22 cases after this sprint became Active. The forward
coordinator currently projects operation keys, ordered dependency keys, and projection keys before calling
the journal-backed grant kernel. The existing reconciliation dependency traversal owns fresh probes and
managed handles; its use at the rooted grant boundary and the associated conditional-version checks still
need to be established and tested.
The standard distinguishes root-authoritative probes, which precede the root's Unknown publication, from
local probes, which the executor runs after the grant. The current `Step` retains its action and declarations
but no root-authoritative target probe, and the existing `withPreparedOperation` traversal runs local
dependency probes only after a prepared gate exists. Resource settlement records retain canonical identity
and versions, but are not themselves proof that a backend is ready. Adopting the existing local traversal
as a pre-grant root probe, or treating a child report as one, would not establish the required boundary.
After recording that distinction, the `DocValidatorSpec` selection passed all 22 tests on WSL2.
The retained `PlannedStep` currently carries its executable `Step` and ordered step-dependency prefix;
`plannedOperationFromGraph` later derives the resource-bearing subset and takes its call digest from the
operation caller. Thus the root's current `forwardFrameNodes` tuple does not contain the operation descriptor,
call digest, probe identities, or expected conditional versions required by § EE. In particular, treating all
step dependencies as managed resources would reject legitimate non-resource-bearing nodes. The representation
and its production owners must supply those facts before the root can check them; a new unchecked callback or
an assumed empty set would leave the requirement unimplemented.
For example, provider provisioning computes its call digest in the backend adapter before constructing the
local operation descriptor. The existing rooted node owner is already at approximately 396 significant lines;
new root-prerequisite machinery must be split under § G instead of enlarging that owner past its boundary.
An initial private plan projection selected the closed resource-family members of an admitted node's
dependency prefix. On 2026-11-14, the focused `prerequisites` selection passed its one test on SSD-backed
WSL2 x86_64 with GHC 9.12.4. That version retained the step's frame, which can differ from a provider's
resource frame when its declaration targets the immediate child. The projection is being corrected to
resolve frames from the full admitted plan and include provider declarations with nonstandard operation
keys. On 2026-11-14, the revised closed-family `prerequisites` case passed, as did all 17 tests in the
`declarations` selection, including project-specific and immediate-child provider placement. The broader
`provider` selection passed all 351 tests in 107.09 seconds. Synthetic resources require their own
projections. Grant preparation does not yet use this projection, and it does
not provide probes, observed versions, call digests, or effect authority.
The focused `prerequisites` case was rerun after adding an independently admitted foreign-plan node;
it passed and asserted the exact plan-digest refusal. It was rerun with two admitted plans whose target
and dependency prefix are identical but whose synthetic guest-alias declarations differ; the foreign node
was refused on the plan digest there as well.
The existing rooted predecessor reader verifies the resource bundle but returns only its bytes, after a
gate has already been prepared. It neither retains the protected record's physical version nor establishes
the pre-grant conditional-version check; same-byte replacement would be invisible to that interface. The
new admission must retain and compare the actual version inside the entry that publishes Unknown.
The broader `indexed` selection passed all 121 tests on the current projection, including its existing
source-boundary checks; it does not establish the outstanding probe or physical-version checks.
Forward settlement checks and writes each reported resource bundle under the journal's protected entry,
but the journal retains pending prepared gates rather than the versions of settled resource records. The
coordinator's `observationsRef` retains node result summaries, not physical record versions. Any version
evidence for a later grant must therefore be retained from a root-owned observation or rehydration and
bound to the admitted plan and resource; a fresh read immediately before preparation alone cannot detect
replacement of a previously observed record.
The existing `RehydratedResourceSet` also derives its member version from the canonical resource bundle;
its verified input is keyed bytes and does not include the protected record's physical version. It therefore
cannot by itself supply the physical compare condition either. A new retained observation must bind both
versions rather than treating the bundle's logical version as the store's CAS version.
An internal root observation now captures a verified resource bundle together with its store identity and
physical record version, and an entry-scoped check compares both version and bytes. Its same-byte replacement
test passed in the eight-case `physical` selection on WSL2; the `rooted` selection passed all 72 cases,
including its updated source-boundary guard. The coordinator does not yet retain or consume these observations, and live backend
probes and atomic grant integration remain outstanding.
The `physical` selection was rerun after adding absent-record and foreign-store refusal assertions; all
eight cases passed. The `rooted` selection also passed all 72 cases after the accompanying source update.
The forward settlement path returns observations captured in its protected entry. An initial coordinator
adoption retained them; on 2026-11-14, the `journal` selection passed 104 tests, including the settlement
capture case; the `rooted` selection passed 72 tests; and the real-process `RecursiveLifecycleSpec`
selection passed 19 tests. Grant preparation does not yet select or recheck those observations; the current
collection also needs exact resource selection and replacement semantics. Live probes and conditional-version
integration remain open.
The initial coordinator adoption serialized settlement and retention across frames and replaced an earlier observation
only for the same store and record key. This avoids allowing a delayed settlement callback to overwrite a
later captured version. On 2026-11-14 the `physical` selection passed 8 cases, including replacement;
the `rooted` selection passed 72 cases; and the real-process `RecursiveLifecycleSpec` selection passed 19
cases. Coordinator retention is adopted in Sprint 17.42c; later sprints own grant-time selection and live
probes.
An internal selector now selects exact store and plan/frame/resource coordinates, with explicit refusals for
missing or duplicate members. On 2026-11-14 its `physical` selection passed all 8 tests and the `rooted`
selection passed all 72 tests. Grant-time adoption remains outstanding.
The `physical` selection was rerun with identical coordinates in different protected stores and with two
same-store resources requested in reverse order; all eight tests passed, including checks that each selected
observation belongs to the requested store and occupies the requested order.
An internal journal prepare variant now rechecks supplied root observations inside the protected entry
before registration and Unknown publication. On 2026-11-14, the `journal` selection passed all 104 tests,
including a same-byte physical-version drift case that asserts the exact refusal and unchanged store image;
the `rooted` selection passed all 72 tests. The `journal` selection was rerun with a positive control:
a freshly observed version prepared one gate, which the subsequent grant reused; all 104 tests passed.
The production grant path does not yet supply the selected observations or run its live probes.
An attempted forward call-site adoption derived all resource-family coordinates from the retained child plan,
selected root observations, and rechecked them before grant construction. On 2026-11-14 that call site
compiled and the `rooted` selection passed 72 cases. The real-process
`RecursiveLifecycleSpec` selection failed one of 19 cases: `a routed cluster cleanup releases its root lease
after backend refusal` expected `up` to succeed, but a later node was refused because the earlier fixture
cluster step returned `StepChanged` without publishing a resource observation. This is an unresolved
behavioral regression, not a passing gate. The fixture's cluster step is a generic `StepChanged` action;
its operation key alone does not establish that it produced a managed resource or that a root-owned record
is a required precondition. The overbroad call-site adoption was removed. A correct implementation must
distinguish root-authoritative resource requirements from executor-local probes and establish genuine
evidence for those the root must check; do not silently skip a missing required observation. The failed run
also reported an open child session during failed-Up cleanup, which must be rechecked after correcting the
admission path. The remaining observation and journal building blocks are not yet adopted at grant time.
After removing that attempted adoption, `RecursiveLifecycleSpec` passed all 19 cases on WSL2 in 113.21
seconds. This confirms restoration of the prior process behavior only; it does not close the root admission
or failed-Up cleanup obligations for a future corrected adoption.
After splitting the coordinator adoption into Sprint 17.42c, the plan validator passed all 22 cases.
On 2026-11-14, Windows `poetry run python -m hostbootstrap.check_code` passed and
`poetry run python -m hostbootstrap.test_all` passed 384 tests at 100% reported coverage. The first WSL2
`core/` and `demo/` legs were interrupted while moving coordinator adoption into the following sprint;
both must be rerun on the final foundation source.
After moving coordinator adoption, both Windows Python commands were rerun successfully (384 tests at
100% reported coverage); `DocValidatorSpec` passed all 22 cases, and the WSL2 `core/` and `demo/` legs
have been restarted.
The WSL2 `core/` gate passed all 5,430 tests in 1,128.87 seconds on the final foundation source.
The `demo/` gate passed its demo suite and all 5,430 core tests in 1,122.79 seconds. The optional
direct-Colima live lane was not requested.

#### Remaining Work

None.

### Sprint 17.42c: Retain root settlement observations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Production modules**: `HostBootstrap.Command.LifecycleEntry`, `HostBootstrap.Lifecycle.Rooted` (2; cap 3)
**Sprint budget**: one coordinator adoption and no new named type; at most 120 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Retain successful resource settlements at the root coordinator for later plan-owned grant admission.

#### Deliverables

- Retain successful settlement observations at the root coordinator, serialized across frames, and replace
  earlier observations only for the same protected store and record key.
- Failed or invalid settlements do not enter the retained successful-observation set.

#### Validation

Exercise successful and failed settlements, exact store/key replacement and concurrent retention. Run the
host static gate, including the real-process recursive lifecycle cases.

On 2026-11-15 the coordinator began retaining successful settlement observations in one shared lock across
frames, replacing observations only for the same protected store and record key. The warning-clean WSL2
build and all 31 `RecursiveLifecycleSpec` cases passed in 33.45 seconds. Grant-time selection,
root-owned live probes, conditional versions and their refusal cases remain outstanding.
The combined rooted, journal and documentation selection also passed all 194 cases in 86.81 seconds.
The serialized settle-and-retain operation now lives in the private rooted journal owner. A protected-store
fixture checks invalid settlement leaves the retained set alone, successful settlement retains both old and
new resources, and a failed node contributes no retained observation. After updating the rooted source
boundary digest, the rooted selection passed 78 cases; the combined journal, recursive lifecycle and
documentation selection passed all 157 cases in 91.49 seconds. Grant-time use and the root probe contract
remain due.
The journal selection passed all 104 cases in 28.27 seconds after adding concurrent settlements that
retain both exact resources under the shared lock.
After splitting prerequisite projection, root probes and grant adoption into their own sprints, the rooted,
recursive lifecycle and documentation selection passed all 131 cases in 94.53 seconds on WSL2.
On 2026-11-15, the full host static gate passed: `cabal test all -j4 --ghc-options=-Werror
--test-option=--hide-successes` from `core/` (5,515 tests, 935.25 seconds) and from `demo/`
(5,515 core tests, 926.44 seconds, plus the demo suite); `poetry run python -m
hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` passed on Windows.

#### Remaining Work

None.

### Sprint 17.42d: Project complete root prerequisite coordinates [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`, `core/hostbootstrap-core/test/TeardownSpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Plan`, `HostBootstrap.Lifecycle.Execution.Internal`,
`HostBootstrap.Reconcile` (3; cap 3)
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Derive the exact target and ordered prerequisite coordinates from the retained admitted plan.

#### Deliverables

- Project target and dependency identities, including synthetic resources and root-local or pre-existing
  resources, without treating non-resource step dependencies as managed resources.
- Refuse foreign-plan nodes, duplicate or missing declarations, and coordinates the plan cannot justify.

#### Validation

Exercise closed-family, synthetic, root-local, pre-existing and foreign-plan cases with exact refusals.

On 2026-11-15, the WSL2 warning-clean build and the focused `root guest alias coordinates` case
passed. It checks the exact admitted alias and durable-share edge, wrong target, missing projection and
foreign-plan refusal. The first test filter matched zero cases and was corrected before this run.
The subsequent warning-clean rebuild and three focused cases passed on WSL2. They cover ordinary
resource prefixes, a provider in the immediate child frame, non-resource refusal, the chart workload's
single cluster edge, and the synthetic alias's single share edge. The plan projection itself is independent
of whether a named resource pre-exists; no probe or grant-time enforcement is claimed by this run.
The complete `indexed project-plan foundation` selection passed all 115 cases in 78.14 seconds;
`DocValidatorSpec` passed its 22 cases in the accompanying 23-case selection. A subsequent focused
WSL2 run passed both root-resource-coordinate cases, including exact refusal of a missing chart
declaration, duplicate provider declarations and a foreign-plan node. After the resource-prefix
projection was made to reject a dependency declared as two resource kinds, the warning-clean WSL2
rebuild and all three root-coordinate cases passed, including the ambiguous-dependency refusal.

The execution package now carries the plan-derived resource dependencies and provider kind, and both
executor descriptor paths derive their edges from that projection. On 2026-11-15 a warning-clean build
and the focused WSL2 selection passed all 25 cases, including the project-declared provider descriptor
comparison and documentation validation. No grant-time enforcement is claimed. The reconciliation change expired the cluster phase's covered evidence; Sprint 16.85 reran its complete
gate and refreshed that evidence on 2026-11-16.

Executor-local resource lookup now uses the admitted resource kind and actual resource frame. On 2026-11-16
the focused warning-clean WSL2 selection passed all 26 cases, including a project-declared provider in its
child frame, wrong-kind refusal, the existing node-resource boundary and documentation validation.
On 2026-11-16, four focused WSL2 cases passed, including `TeardownSpec`'s admitted root coordinates for
an already-recorded protected resource and its wrong-frame refusal; this establishes record identity, not
readiness. Windows `poetry run python -m hostbootstrap.check_code` and `poetry run python -m
hostbootstrap.test_all` passed (384 tests, 100% reported coverage). The complete WSL2 core gate
passed all 5,520 tests in 985.99 seconds on 2026-11-16. The WSL2 demo gate passed its 169 demo
tests and all 5,520 core tests in 981.56 seconds on the same date.

#### Remaining Work

None.

### Sprint 17.42e: Bind root probe identities to the admitted plan [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/TeardownSpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Plan` (1; cap 3)
**Sprint budget**: one opaque `RootProbeIdentity` type; at most 100 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Bind descriptive probe identities to the exact admitted plan resource coordinates.

#### Deliverables

- Derive target and dependency identities from the admitted plan, including synthetic resources and
  root-local or pre-existing resources, without accepting child-supplied coordinates or a callback.
- Keep identities distinct from backend observations, readiness evidence and grant authority.

#### Validation

`ProjectPlanSpec` checks exact provider, share, alias and chart identities and foreign-plan refusal;
`TeardownSpec` checks an already-recorded root resource identity. Run the host static gate, including
the recursive lifecycle cases.

On 2026-11-16 the first focused WSL2 build caught a shadowed-name warning, which was corrected. The
warning-clean rebuild and 26 focused cases then passed, including the admitted provider, share, alias and
chart probe identities and a foreign-plan refusal, plus the coordinate and documentation selections. The
opaque identity contains only the admitted plan digest, resource frame, key and closed family; it is not a
backend observation, readiness proof or grant authority. On 2026-11-16 the Windows Python code checks
and full Python suite passed (384 tests, 100% reported coverage). The WSL2 core and demo gates are
run against the final identity source and the existing-resource identity case. The focused
`TeardownSpec` case passed on WSL2, selecting an already-recorded root resource under the matching
plan-bound probe identity and refusing a different frame. The complete WSL2 core gate passed all
5,521 tests in 974.04 seconds on 2026-11-16. The WSL2 demo gate passed its 169 demo tests and
all 5,521 core tests in 968.98 seconds on the same date.

#### Remaining Work

None.

### Sprint 17.42e1: Select root prerequisites from the admitted plan [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Select the admitted node's closed-family target and ordered protected-record prerequisites.

#### Deliverables

- Retain the closed resource family in the root probe identity and derive the ordered prerequisite set
  from the admitted plan, including synthetic targets and pre-existing resources.
- Select and recheck exact owned protected records and their physical versions without treating them as
  backend readiness or accepting them as grant authority.
- Reconstruct chart workload inputs only from the exact admitted chart identity and declaration.

#### Validation

Exercise exact probe identity, complete prerequisite selection, missing or duplicate records, stale
physical versions, and foreign-plan and wrong-family refusals in `ProjectPlanSpec` and `TeardownSpec`.
Run the host static gate.

On 2026-11-16 a private rooted selector began resolving protected observations from plan-derived probe
identities rather than raw coordinate lists. The WSL2 warning-clean build and 24 focused cases passed,
including exact existing-resource selection, duplicate and foreign-plan refusal, the rooted private-source
boundary and documentation validation. Selection establishes record identity only; no backend readiness
or conditional version is claimed. The journal now selects those identities and rechecks their protected
record versions inside preparation. On 2026-11-16, 25 focused WSL2 cases passed, including missing-record
and same-byte physical replacement refusals with protected-store before-images, successful preparation,
the rooted private-source boundary and documentation validation. The prerequisite-only preparation path
now also checks exact owned status under the same protected entry as its physical-version recheck. The
subsequent warning-clean WSL2 selection passed all 25 cases on 2026-11-16, including released, missing,
foreign and physically replaced records, successful preparation, unchanged store before-images and the
private-source boundary. These checks do not establish a complete prerequisite set or perform a backend
probe. The admitted snapshot binds a closed step implementation identity and revision, not its opaque
callback; the existing resource bundle likewise records resource identity, phase and adapter revision but
not the native backend realization. A root probe therefore needs a plan-bound backend descriptor and an
independent backend observation before it can establish readiness or a conditional native version. On
2026-11-16 the warning-clean WSL2 selection passed all 24 cases, including `ProjectPlanSpec` checks that
distinct opaque callbacks can share the same probe identity and the documentation validator.
The root probe identity now retains a closed resource-family value covering the six ordinary families,
the guest alias, and the chart workload, so a future root dispatcher can match all cases without accepting
an arbitrary family string. This family selection is descriptive and does not yet perform a backend probe.
The dedicated WSL instance had restarted and lost its bind mount; the first subsequent selection ran
against an older local directory and is discarded. The host repository and SSD build caches were rebound
before the selection below. On 2026-11-16 the dedicated distribution received an enabled systemd
oneshot service that binds the C: working tree and both SSD-backed Cabal build directories at startup.
After terminating and restarting only `hostbootstrap-linux-ssd`, the service was active and `findmnt`
confirmed all three mounts; the unrelated `shipnorth` distribution stayed running.
The Windows distribution registration names `C:\CodexScratch\hostbootstrap-linux-ssd` as its disk
location. After the restart, the documentation-validation selection passed all 22 cases on the
automatically mounted working tree.
On 2026-11-16, the mounted working-tree build and 44 identity-selected cases passed with GHC 9.12.4
and warnings treated as errors, including all eight plan-derived resource-family cases. The subsequent
documentation-validation selection passed 22 cases.
The root can now reconstruct a chart workload's declared inputs and cluster identity from its exact
plan-bound probe identity. This projection is not a live chart probe; root-controlled backend observation
and its conditional-version comparison remain outstanding. On 2026-11-16 the mounted WSL2
warning-clean `inputs` selection passed all 11 cases, including the exact chart declaration, a foreign
plan, and a non-chart resource family.
The existing chart call is served by the executor's registered cluster dependency after preparation;
it is not a root probe. The chart declaration identifies its cluster and workload, but the cluster
backend's rendered configuration is supplied separately to `withPlanOwnedClusterConfig`. A root chart
probe therefore also needs independently retained cluster realization and a native observation/version;
the chart declaration alone cannot establish either.
The private record selector now derives the entire ordered prerequisite identity set from the admitted
node before selecting observations; callers no longer need to supply that set to this selector. It is
not yet adopted by grant preparation and does not perform a native probe. On 2026-11-16 the warning-clean
WSL2 `prerequisites` selection passed both cases, including reordered observations and missing or duplicate
records; the rooted private-boundary selection also passed its one case.
On 2026-11-16 the full host static gate subsequently passed: the mounted WSL2 `core/` and `demo/`
legs each passed 5,527 core cases, the demo leg passed 169 demo cases, and Windows Python `check_code`
and `test_all` passed, with 384 Python tests. The separate phase 15 provider correction was included.

#### Remaining Work

None. Backend descriptors, independent observations, conditional versions, and grant adoption remain in
the following sprints.

### Sprint 17.42e1a: Bind provider probe descriptions to the admitted plan [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/internal/lifecycle-representation/HostBootstrap/Lifecycle/Snapshot/Core.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/LifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Retain a closed, serializable provider probe description in the admitted plan and its canonical snapshot.

#### Deliverables

- Bind the exact provider realization inputs to the declaring plan node without retaining an executable
  callback or accepting a child-supplied probe, and preserve their canonical snapshot and recovery grammar.
- Reject ambiguous or malformed declarations and prove that changing a native target changes the plan identity.

#### Validation

On 2026-11-16, the host static gate passed: `cabal test all -j4 --test-show-details=direct
--test-option=--hide-successes` from each of `core/` and `demo/` on the dedicated linux-cpu WSL2 instance
passed 5,531 core cases each, including 26 real recursive lifecycle cases; the demo leg also passed 169
demo cases. On Windows, `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` passed (384 tests). `ProjectPlanSpec` exercises declaration
admission, all four descriptions in the snapshot grammar, changed-target identity, malformed and duplicate
declarations, foreign-plan refusal, and the version-8 refusal. The documentation validator passed 22 cases.

#### Remaining Work

None.

### Sprint 17.42e1b: Establish independent root provider observations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Establish a genuine root-owned provider probe and conditional-version evidence from the admitted description.

#### Deliverables

- Reconstruct the provider target from the exact admitted plan description and perform an independent,
  read-only native observation, including synthetic and pre-existing providers.
- Retain its native conditional version without child-supplied authority or an unchecked caller-selected
  callback, keeping it distinct from executor-local probes. Refuse missing or ambiguous descriptions.

#### Validation

`TeardownSpec` "admitted root coordinates select an already recorded resource without proving readiness"
checks generation extraction and foreign, stale, and released row refusals. `ProjectPlanSpec` exercises
"rooted Direct provider observation detects refusal and native replacement", "rooted Incus provider
observation refuses stopped and replaced instances without mutation", "rooted Lima provider observation
refuses stopped and replaced guests without mutation", "rooted WSL2 provider observation refuses an unowned
guest without mutation", and "rooted synthetic provider observes its own declared Direct target". These
cover the exact plan, native readiness and identity, physical record version, and mutation-free refusals.
The WSL2 case is a refusal on linux-cpu; native WSL2 confirmation belongs to its acceptance gate.

On 2026-11-16 the host static gate passed: `cabal test all -j4 --test-show-details=direct
--test-option=--hide-successes` from each of `core/` and `demo/` on the dedicated SSD-backed linux-cpu
WSL2 instance passed 5,536 core cases each, including 26 recursive lifecycle cases; `demo/` also passed 169
demo cases. On Windows, `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` passed (384 tests). Phase 15's covered provider evidence was
refreshed under Sprint 15.53 after the backend change.

#### Remaining Work

None.

### Sprint 17.42e1b1: Bind the bare provider plan to its backend description [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Have the bare provider-producing plan declare the same target inputs from which its actual backend is built.

#### Deliverables

- Bind the bare live-gate Direct provider node to the description used for its backend construction.
- Revalidate any earlier deferred phase whose evidence covers an edited source before advancing.

#### Validation

Exercise exact target binding and changed target refusal, run the host static gate, and rerun every expired
earlier phase's declared gate.

On 2026-11-16 `ProjectPlanSpec`'s bare selection passed all 22 cases, including the exact Direct root and
changed-image declarations. The Python static checks and all 384 Python tests passed on Windows, and the
demo's 169 tests passed on the dedicated linux-cpu WSL2 instance. The full host static gate passed: core 5,536 cases (1,314.48 seconds), demo 169 cases plus
5,536 core cases (1,300.82 seconds), Python checks and 384 Python tests. Phase 16's complete
declared gate also passed, including the installed bare live cluster leg (1/1).

#### Remaining Work

None.

### Sprint 17.42e1b1a: Bind the demo VM provider plan to its backend description [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Have the demo VM provider node declare the same target inputs from which its backend is built.

#### Deliverables

- Bind Incus, Lima, and WSL2 provider descriptions to their corresponding backend construction without
  independently drifting copies of the inputs.

#### Validation

Exercise exact target binding and changed target refusal in `CommandsSpec`, then run the host static gate.

On 2026-11-16 the call-site audit found that `demoChainFor` receives the canonical root, while the
VM-stack helpers and independently reconstructed child plans do not retain the original host root.
The implementation must preserve child-local plan reconstruction as well as bind the root plan's
provider description to the exact backend inputs; a runtime current-directory lookup alone is not
evidence of the admitted root. Implementation and validation remain open.
The immediate-target projection validates frame labels, ancestry and lift routes; it admits the
child-local plan independently. The root-only provider declaration can therefore stay on the root
plan, while nested reconstructions retain their local plans. Tests must cover that projection as well
as the three root provider descriptions.
The root plan now constructs a description and the VM action compares it with its runtime inputs
before provisioning; backend construction consumes the retained description. The demo executable built
successfully. The first demo test run passed 169 of 170 cases; its source guard expected the prior
VM action signature. After updating the guard, all 170 demo tests passed, including the three provider
descriptions, changed-root and missing-description refusals, and the existing child projection cases.
The Python checks and all 384 tests passed. Both full Cabal gate legs passed: 5,536 core
cases in 1,277.14 seconds from `core/`, and 170 demo cases plus 5,536 core cases in 1,270.71
seconds from `demo/` on dedicated SSD-backed WSL2.

#### Remaining Work

None.

### Sprint 17.42e1b1b: Bind the demo Direct provider plan to its backend description [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Have the demo Direct provider node declare the same target inputs from which its backend is built.

#### Deliverables

- Bind the Direct provider description to the backend construction without independently drifting inputs.

#### Validation

Exercise exact target binding and changed target refusal in `CommandsSpec`, then run the host static gate.

On 2026-11-16 the root Direct plan was changed to declare its canonical root and configured base
image, and the reservation passes that description to backend construction after checking the host
image. Child-local plans omit the host-only description. All 171 demo tests passed, including exact
root and image binding and refusal of a changed or missing image declaration. Python checks and all
384 Python tests passed. The complete host static gate passed on 2026-11-16: the core leg ran
5,536 tests in 1,255.50 seconds; the demo leg ran 171 demo tests and 5,536 core tests in
1,255.88 seconds on dedicated SSD-backed WSL2.

#### Remaining Work

None.

### Sprint 17.42e1b2: Declare the durable-share probe target [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/internal/lifecycle-representation/HostBootstrap/Lifecycle/Snapshot/Core.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/LifecycleSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Bind the exact host and guest share paths to the admitted canonical plan without granting probe authority.

#### Deliverables

- A closed share probe description is validated, encoded in canonical plan bytes and projected only from
  its exact plan-derived share identity. Snapshot admission refuses incompatible bytes before effects.

#### Validation

Exercise canonical round trips and malformed, foreign and changed target refusals in `ProjectPlanSpec`,
then run the host static gate.

On 2026-11-16 the audit found that the root retains only the share family and operation identity; the
plan has no share target description. The Incus native share device binding also includes the provider
and share generations, operation key and prepared-call digest. `providerShareCallDigest` derives the
latter from backend fingerprints and both share paths. The root probe must reconstruct those exact inputs
and reject a changed realization, not accept a child assertion. The plan validator passed all 22 cases.
The plan representation now carries validated host and guest share paths in snapshot format 10; format 9
is refused. The core library builds and the focused share selection passed all 144 tests on 2026-11-16.
The first snapshot selection passed 120 of 126 cases: one new corruption fixture assumed a unique
share list, and five existing fixtures still expected the prior step field count. Those test fixtures
were corrected; the snapshot rerun passed all 126. The plan validator passed 22 cases and the effect
boundary selection passed 53. The broader indexed plan selection passed 138 of 139; its golden byte
fixture still encoded format 9 and was updated for the new field and format; the corrected golden
selection passed all six cases. Python checks and all 384 Python tests passed. The complete core gate
passed all 5,538 cases in 1,289.81 seconds on dedicated SSD-backed WSL2. The demo Cabal leg also
passed, including all 5,538 core cases in 1,278.91 seconds.

#### Remaining Work

None.

### Sprint 17.42e1b2a: Select the share's protected prerequisites [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Select the exact share generation and its provider from the admitted plan and still-current protected rows.

#### Deliverables

- Recover an owned share generation only from its exact current protected record and refuse other families.
- Select the sole provider dependency for the admitted share, refusing foreign identities or ambiguous providers.

#### Validation

`ProjectPlanSpec` exercises share generation, foreign-plan refusal, and admitted provider projection;
`TeardownSpec` rejects a provider record as a share. Run the host static gate.

On 2026-11-16, the `share`, `coordinates`, `nominal`, and `DocValidatorSpec` selections passed 145, 18,
12, and 22 cases respectively. The host static gate passed: on dedicated SSD-backed WSL2, `cabal test all`
passed 5,538 core cases in 1,283.38 seconds from `core/`, and from `demo/` passed 171 demo cases plus
5,538 core cases in 1,271.70 seconds; on Windows both Python checks passed, including all 384 tests.
Earlier full runs each failed one private export-inventory case; the inventory and source hash were corrected
before the focused and full reruns. Linux Poetry recreated the shared Windows `.venv` during an initial
attempt; Windows `poetry install` restored it from the lock before the successful Python checks.

#### Remaining Work

None.

### Sprint 17.42e1b2a1: Observe the durable share independently [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/GuestVm.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Report.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/ProviderReportSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Observe and recheck the exact plan-owned share and native conditional identity without a prepared mutation,
for the Direct, Incus, and Lima realizations.

#### Deliverables

- Reuse the canonical share call digest when reconstructing the exact provider and share binding.
- One opaque root share observation refuses absent, stale, foreign or unready native objects and detects replacement.
- Incus and guest-VM observation reenter existing provider stores and directory leases without creating them.
- Lima proves host/guest correspondence from its native mount configuration: exactly one writable mount at the
  guest target whose location is the declared host source, observed on both sides of the guest sample.
- A guest share is observed only while its owned guest is observed running; WSL2, whose registration carries no
  non-launching running state, refuses before any guest command (Sprint 17.42e1b2a2 owns its observation).

#### Validation

- `ProjectPlanSpec`: the Direct share observation cases (missing protected records, root replacement).
- `ProviderBackendSpec` "recorded guest VM transaction": the `existing-only` guest cases and the
  `existing-only share observation` cases — a running guest's configured writable mount observed with no
  mutation; a stopped guest refused without starting; missing admission refused without creating state; and a
  configured mount for another host source, a read-only mount, no mount at the target, a repeated target, and
  an inadmissible mount each refused before any guest sample. The Lima cases run on non-Windows gate hosts;
  on Windows the same cases assert the WSL2-only identity row's refusal.
- `ProviderBackendSpec`: the rooted Incus cases (missing store, retained share, guest mount replacement and
  device removal without observer mutation).
- `ProviderReportSpec` "native Lima mounts": location, default mount point and write policy; absent mounts;
  a malformed entry; inadmissible paths that refuse correspondence but keep the instance observable.
- `SealedExportInventory`: the public provider exports.

- `demo/test/CommandsSpec.hs`: an Apple Silicon plan built over a Windows temporary root names a non-POSIX Lima
  guest path, which plan admission refuses as an invalid VM provider probe. The three cases that build that
  plan accept exactly that refusal on a Windows gate host and assert the plan's contents on POSIX hosts.

2026-11-18, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the focused selection (`native Lima mounts`,
`native Lima instance reports`, `recorded guest VM transaction`, sealed exports) passed 162 cases; `cabal test all`
from `core/` passed 5,567 core tests in 1,018.02 seconds; `check_code` passed and `test_all` passed 384 tests.
`cabal test all` from `demo/` failed 3 of 171 demo cases on the Apple-plan refusal above; after the fixture
correction the complete `demo/` leg passed all 171 demo and 5,567 core tests (exit 0, 970 seconds).
On the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4) the selection `native Lima mounts`, `recorded
guest VM transaction`, sealed exports, and `share` passed all 271 cases in 1,484.09 seconds, including the
Lima `existing-only share observation` cases.

#### Remaining Work

None. Sprint 15.58 re-runs the phase 15 gate that this sprint's provider change expired, and Sprint
17.42e1b2a2 owns the WSL2 share observation.

### Sprint 17.42e1b2a2: Observe a WSL2 share without launching its distribution [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/GuestVm.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Report.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderReportSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`, `documents/architecture/lifecycle_state_model.md`

#### Objective

Give the owned WSL2 guest a running-state observation that cannot start its distribution, and prove its share
correspondence from the guest's DrvFs mount.

#### Deliverables

- A WSL2 running-state observation from the running-distribution listing, which never launches a distribution:
  `listRunningWslCommand` and `classifyWslRunningReport`, which narrows the NUL-padded UTF-16LE capture and
  passes the common provider-report boundary.
- Every existing-only guest command (`runningGuestExec`) observes the owned guest running immediately before it
  runs: Lima from its instance listing, WSL2 from the running listing.
- DrvFs correspondence: `classifyDrvFsCorrespondence` requires the guest target on the 9p DrvFs mount of exactly
  the host source's drive at `/mnt/<drive>`, with the target the source's projection there.
- Rooted share observation admits WSL2 through the same existing-only entry as Lima.

#### Validation

- `ProviderReportSpec` "native WSL running listings": UTF-16LE and UTF-8 listings naming the distribution, an
  unlisted distribution and an empty listing, a nonzero exit, an unrun and a noisy listing, NULs outside the
  UTF-16LE shape, and a control character in a listed name.
- `ProviderBackendSpec` "WSL DrvFs share correspondence": the corresponding drive mount, a lower-case drive with a
  bare drive path, and refusals for another drive, a non-DrvFs 9p mount, a native filesystem, another mount
  point, a non-projection target, a driveless source, a failed or noisy `findmnt`, and several rows.
- `ProviderBackendSpec` "recorded guest VM transaction": the `existing-only` guest and share cases, which now run
  through `runningGuestExec`.
- `SealedExportInventory`: the provider exports.

The transaction itself has no fake-process WSL2 fixture, because registration is a registry read; native
confirmation belongs to the Windows and WSL2 acceptance phase.

2026-11-19, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the focused selection (`native WSL running
listings`, `WSL DrvFs share correspondence`, `native Lima`, `recorded guest VM transaction`, sealed exports)
passed 211 cases. The complete host static gate passed on the same host: `cabal test all` from `core/` passed
5,586 core tests in 810.52 seconds; `cabal test all` from `demo/` passed 171 demo and 5,586 core tests;
`check_code` passed and `test_all` passed 384 tests. On the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC
9.12.4) the same selection plus `share` passed all 354 cases in 1,467.72 seconds, including the Lima
`existing-only` guest and share cases through `runningGuestExec`.

#### Remaining Work

None. Sprint 15.59 re-runs the phase 15 gate this provider change expired; native WSL2 confirmation belongs to
the Windows and WSL2 acceptance phase.

### Sprint 17.42e1b2b: Bind the demo share declaration [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Bind the demo's share plan declaration to the exact share used by its backend.

#### Deliverables

- One shared declaration supplies the canonical host and guest paths to the root plan and share consumer:
  `demoPlannedShare` derives the share, `demoShareProbeDescription` declares it on the copy-source node, and
  `admitDemoShareDescription` recomputes it in `runCopySource` from the canonical root and refuses any other
  declaration.

#### Validation

- `demo/test/CommandsSpec.hs` "the copy-source share declaration binds the backend's exact share": for each VM
  substrate the copy-source node declares exactly the planned host durable root and guest target, which the
  executor admits; another project root, a changed guest target, and a missing declaration are refused.
- Incus and Lima keep the host path as the guest path, so a Linux CPU or Apple Silicon plan built over a Windows
  temporary root names a non-POSIX guest path and plan admission refuses its share probe. `admitPlanOnHost`
  accepts exactly that refusal on a Windows gate host, and the cases that build those plans assert their
  contents on POSIX gate hosts.

2026-11-19, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the complete host static gate passed —
`cabal test all` from `core/` passed 5,586 core tests in 838.78 seconds; `cabal test all` from `demo/` passed 172
demo and 5,586 core tests; `check_code` passed and `test_all` passed 384 tests. On the dedicated Linux VM
(Ubuntu 24.04.5 x86_64, GHC 9.12.4) the demo suite passed all 172 cases, including the Incus and Lima plan
assertions.

#### Remaining Work

None.

### Sprint 17.42e1b2c: Integrate root share observation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Use the root-owned share observation for the exact planned share, including synthetic and retained shares.

#### Deliverables

- Root-side selection observes and rechecks the exact owned share without child-supplied authority:
  `observePlannedRootShare` derives the share identity from the admitted plan's own copy-source node and reads
  the exact provider and share records from the protected store at the call.
- The forward root coordinator runs that observation before every child-frame grant and refuses the grant
  when the share is missing, foreign, released or unready; a plan without a share probe is unaffected.

#### Validation

- `ProjectPlanSpec` "planned root share observation selects its own records and refuses missing, foreign, stale
  and unready shares": a plan without a share observes none; a foreign record and a missing share record are
  refused; the pre-existing share is observed and rechecks; a changed share record makes the retained
  observation stale; a moved share root is unready; and a synthetic project-declared provider's share is
  observed.
- The existing rooted Incus and Direct share cases cover native replacement through `recheckRootedShare`.

2026-11-19, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the `planned root share`, `rooted` and sealed
export selection passed 156 cases. The first complete `core/` run failed one source guard, "an exhausted
forward frame is told to close", whose marker named the forward service's old parameter list; after updating
the marker the complete host static gate passed: `cabal test all` from `core/` passed 5,587 core tests in
816.29 seconds; `cabal test all` from `demo/` passed 172 demo and 5,587 core tests; `check_code` passed and
`test_all` passed 384 tests. On the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4) the
`RecursiveLifecycle`, `planned root share`, `rooted` and `share` selection passed all 279 cases in 883.24
seconds, including the real-process recursive lifecycle cases.

#### Remaining Work

None. Sprint 15.60 re-runs the phase 15 gate this provider change expired; Sprint 17.42f adopts the remaining
prerequisite rechecks at grant preparation.

### Sprint 17.42e1b3a: Observe a bound symbolic link without repairing it [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Give the shipped ownership program a read-only act that reports the symbolic link its frame already bound.

#### Deliverables

- `ShipObserveSymbolicLink` enters only an existing authority store, reads the bound record for the exact link
  target, and reports `ShippedSymbolicLinkRetained` only when the live link is the bound identity.
- It records, stages, publishes, cleans up and removes nothing; an absent store, a missing or unbound record, a
  replaced link and a removed link refuse. The act has its own wire tag and round-trips through the codec.

#### Validation

- `OwnershipShippedSpec` "existing-only symbolic-link observation reports the bound link and repairs nothing":
  an absent authority refuses without being created; a taken link reports its bound identity with the record
  unchanged; a replaced and a removed link refuse, and the removed link is not republished.
- `OwnershipShippedSpec` link-target and codec cases cover tag 6, unchecked target wire fields, wrong-frame
  payloads, and the act's exact round-trip.

2026-11-19, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the `OwnershipShippedSpec` and sealed export
selection passed 173 cases, and the complete host static gate passed: `core/` passed 5,588 core tests in 997.24
seconds; `demo/` passed 172 demo and 5,588 core tests; `check_code` passed and `test_all` passed 384 tests. On
the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4), where the symbolic-link cases run, the
`OwnershipShippedSpec`, sealed export and `alias` selection passed all 262 cases in 1,230.24 seconds.

#### Remaining Work

None.

### Sprint 17.42e1b3b: Declare the guest-alias probe target [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Carry the exact guest-alias path and link target in the admitted plan, as the share probe carries its paths.

#### Deliverables

- `AliasProbeDescription` is declared on the copy-source node beside its share; plan admission requires POSIX
  absolute paths, a link target equal to the share's guest path, and at most one declaration.
- The canonical step record carries the `alias-probes` list, and `withRootAliasProbeDescriptionKernel`
  recovers the declaration only from the exact alias probe identity of the one step projecting it.
- The demo declares the alias from the same values its alias backend uses, and `runCopySource` refuses any
  other declaration through `admitDemoAliasDescription`.

#### Validation

- `ProjectPlanSpec` "alias probe descriptions bind the exact admitted alias": the alias path changes the plan
  digest; the persisted snapshot re-admits with its members and recovery frames; the exact alias identity
  recovers its description while a share identity and a foreign alias identity do not; and an alias without
  its share, an alias linking elsewhere, a relative alias path, and a duplicate alias are refused.
- `ProjectPlanSpec` "fixed admitted input has golden canonical bytes under its exact root" and the
  `LifecycleSpec` canonical-mutation cases pin the 17-field step record.
- `demo/test/CommandsSpec.hs` "the copy-source alias declaration binds the backend's exact alias": each VM
  substrate declares the stable alias path linked to its share's guest path; another root, a changed alias
  path, and a missing declaration are refused.

2026-11-19, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the `alias probe descriptions`, `probe`,
`snapshot`, `canonical`, `golden` and sealed export selection passed 508 cases, and the complete host static
gate passed: `core/` passed 5,589 core tests in 822.44 seconds; `demo/` passed 173 demo and 5,589 core tests;
`check_code` passed and `test_all` passed 384 tests. On the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC
9.12.4) the demo suite passed all 173 cases, including the Incus and Lima plan assertions.

#### Remaining Work

None.

### Sprint 17.42e1b3c: Observe durable aliases at the root [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Independently observe each exact plan-owned guest alias and its native conditional version at the root.

#### Deliverables

- `rootedAliasTarget` (the plan side, which imports no effectful lift) takes the alias path and link target,
  the alias's share, the share's provider and the guest frame from the admitted plan
  (`withRootAliasProbeDescriptionKernel`, `rootAliasShareProbeIdentityKernel`) and selects the exact alias and
  share records into an opaque target.
- `observeRootedAlias` requires those records to be current on both sides of the guest call and ships the
  read-only `ShipObserveSymbolicLink` act to the target's guest frame.
- `recheckRootedAlias` reobserves and refuses a changed native identity; a Direct provider has no guest alias
  frame and refuses as unsupported. Neither grants anything.

#### Validation

- `ProjectPlanSpec` "rooted guest alias observation reports the bound link and refuses missing, replaced and
  removed aliases" (POSIX gate hosts, through the prepared-alias fixture's local frame child): an alias never
  taken is refused; a taken alias is observed and rechecks; a missing alias record is refused; a replaced and
  a removed link fail the recheck, and the removed link is not republished. On a host without symbolic-link
  ownership the shipped observation itself refuses.
- `ProjectPlanSpec` "rooted guest alias observation refuses a Direct provider without a guest frame".

2026-11-19/20, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the first complete `core/` run failed
"exactly the audited production modules import the plan kernel", because the plan-reading observer imported
the effectful `HostBootstrap.Lift`; the observer was split into the plan-side `rootedAliasTarget` and the
effect-side `observeRootedAlias`. The focused selection then passed 90 cases and the complete host static gate
passed: `core/` passed 5,591 core tests in 797.83 seconds; `demo/` passed 173 demo and 5,591 core tests;
`check_code` passed and `test_all` passed 384 tests. On the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC
9.12.4) the first run of the alias row failed because its fixture marked the fake Incus instance `Running`
rather than the Incus fake's `RUNNING`; after that fixture correction the `rooted guest alias`, `alias probe`,
`alias`, sealed export and import-audit selection passed all 179 cases in 1,228.20 seconds.

#### Remaining Work

None. Sprint 15.61 re-runs the phase 15 gate this provider change expired, and Sprint 17.42e1b3d integrates
the observation.

### Sprint 17.42e1b3d: Integrate root alias observation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Observe the root plan's own declared guest alias before each child-frame grant, as the share is observed.

#### Deliverables

- `plannedRootAliasProbeIdentitiesKernel` lists the alias probe identities the admitted plan declares.
- The forward root coordinator's resource gate observes the share and then each declared alias through
  `observeRootedAlias`, with the alias and share records read at the call, and refuses the grant when an alias
  is missing, foreign, replaced or unready; a plan without an alias probe is unaffected.

#### Validation

- `ProjectPlanSpec` "alias probe descriptions bind the exact admitted alias": the declared alias identity is the
  plan's one planned alias probe, and a plan without an alias probe lists none.
- `ProjectPlanSpec` "rooted guest alias observation reports the bound link and refuses missing, replaced and
  removed aliases" covers the observation the gate runs; "an exhausted forward frame is told to close" bounds
  the forward service by its gate parameter; the real-process recursive lifecycle cases run the gate.

2026-11-20, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the `alias probe descriptions`, `exhausted
forward frame`, `audited production modules` and `rooted guest alias` selection passed 5 cases, and the
complete host static gate passed: `core/` passed 5,591 core tests in 776.21 seconds; `demo/` passed 173 demo and
5,591 core tests; `check_code` passed and `test_all` passed 384 tests. On the dedicated Linux VM (Ubuntu 24.04.5
x86_64, GHC 9.12.4) the `RecursiveLifecycle`, `rooted`, `alias` and `exhausted forward frame` selection passed
all 211 cases in 666.59 seconds, including the real-process recursive lifecycle cases.

#### Remaining Work

None.

### Sprint 17.42e1b4: Observe Docker at the root [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Independently observe the exact plan-owned Docker dependency and its native conditional version at the root.

#### Deliverables

- `observeRootedDocker` accepts only a Docker probe identity of the admitted plan in the root's own frame,
  requires its exact record to be current and unreleased on both sides of the daemon query, and takes the
  daemon identity from one bounded `docker info --format {{.ID}}` line; `recheckRootedDocker` refuses a changed
  daemon identity as a conflict.
- A Docker resource in a child frame lives behind that frame's boundary and is refused as unsupported rather
  than observed from the root. No production plan declares `core:ensure-docker`; grant-time adoption belongs to
  Sprint 17.42f.

#### Validation

`ProjectPlanSpec` "rooted Docker observation reads its own frame's daemon and refuses stale, foreign, unready and
child-frame daemons": a missing and a foreign record are refused; the current daemon is observed and rechecks; a
replaced daemon fails the recheck; an unanswering daemon and a multi-line identity are refused; and a Docker
resource in a child frame is refused as unsupported.

2026-11-20, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the `rooted Docker`, sealed export and
import-audit selection passed 88 cases, and the complete host static gate passed: `core/` passed 5,592 core tests
in 816.17 seconds; `demo/` passed 173 demo and 5,592 core tests; `check_code` passed and `test_all` passed 384
tests. On the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4) the `rooted Docker`, `rooted`, sealed
export and import-audit selection passed all 159 cases in 1,351.14 seconds.

#### Remaining Work

None. Sprint 15.62 re-runs the phase 15 gate this provider change expired.

### Sprint 17.42e1b5a: Observe one cluster object in its own frame [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`, `core/hostbootstrap-core/test/ClusterShippedSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Give the frame that holds a cluster a closed, read-only request that reports one workload object's identity, so
the root can observe in-cluster resources across the frame boundary.

#### Deliverables

- A closed request names the cluster's absolute POSIX state directory, its exact name, and one object's
  namespace, closed kind (Deployment or StatefulSet) and name; no kubeconfig path, executable or selector crosses
  the frame. The far side derives the kubeconfig from the cluster's own state directory.
- `observeClusterObject` reads the object's UID and resource version through the cluster's kubeconfig and
  applies nothing; an absent kubeconfig, an absent object, a failed or noisy query and a malformed identity
  refuse. The shared frame-child dispatcher recognizes the request beside the cluster exposure request.

#### Validation

`ClusterShippedSpec` "cluster object observation": the canonical request round-trips; invalid namespaces, names,
paths, kinds and trailing fields are refused; foreign prefixes fall through both cluster interpreters; only a
two-field bounded identity is a response; and the object query refuses an absent kubeconfig, an absent object
and a malformed identity and reports the exact identity through the fake kubectl (POSIX gate hosts).

2026-11-20, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the `ClusterShippedSpec` and sealed export
selection passed 100 cases, and the complete host static gate passed: `core/` passed 5,598 core tests in 820.77
seconds; `demo/` passed 173 demo and 5,598 core tests; `check_code` passed and `test_all` passed 384 tests. On
the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4) the `ClusterShippedSpec`, `Cluster` and sealed export
selection passed all 269 cases in 1,210.11 seconds, including the fake-kubectl identity case.

#### Remaining Work

None. Sprint 16.88 re-runs the phase 16 gate this cluster change expired.

### Sprint 17.42e1b5b: Declare plan-owned object-store targets [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Carry the exact cluster state, namespace, kind and name of the object-store workload in the admitted plan.

#### Deliverables

- `ClusterObjectProbeDescription` is declared only on the object-store or registry node; plan admission requires
  an absolute POSIX state directory, DNS-label cluster, namespace and name, a closed kind, and one declaration.
  The canonical step record carries the `cluster-object-probes` list, and
  `withRootClusterObjectProbeDescriptionKernel` recovers it only from the exact object-store or registry identity.
- The demo declares its `object-store` Deployment in the default namespace of the container cluster, at that
  cluster's runtime state directory joined as a guest POSIX path, from the same frame-invariant inputs as its
  container cluster plan; `deployObjectStoreAction` refuses a cluster other than the declared one. Sprint
  17.42e1b5c moved the declared path to the one the provider guest sees.

#### Validation

- `ProjectPlanSpec` "cluster object probe descriptions bind the exact admitted object store": the object name
  changes the digest; the persisted snapshot re-admits; the exact identity recovers its description and a foreign
  one does not; a cluster object on another node, invalid paths, names and kinds, and a duplicate are refused.
- `ProjectPlanSpec` "fixed admitted input has golden canonical bytes under its exact root" and the
  `LifecycleSpec` canonical-mutation cases pin the 18-field step record.
- `demo/test/CommandsSpec.hs` "the object-store node declares the container cluster's exact object-store
  Deployment" for the Direct GPU, WSL2 and Incus chains. Its first run found the state directory joined with the
  Windows host's separator; the declaration now joins the guest path POSIX-style.

2026-11-20, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the core probe, snapshot, canonical, golden and
sealed export selection passed 510 cases, and the demo suite passed 174. The first complete `core/` run failed one
of 5,599 tests whose name the run's output filter did not retain; the `demo/` leg on the same tree passed all
5,599 core tests, and a repeated complete `core/` run passed all 5,599 in 778.38 seconds. The `demo/` leg passed
174 demo and 5,599 core tests; `check_code` passed and `test_all` passed 384 tests. On the dedicated Linux VM
(Ubuntu 24.04.5 x86_64, GHC 9.12.4) the demo suite passed all 174 cases, including the Incus and Lima plans.

#### Remaining Work

None.

### Sprint 17.42e1b5c: Observe object stores at the root [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Independently observe the exact plan-owned object store and its native conditional version at the root.

#### Deliverables

- `observeRootedClusterObjectKernel` recovers the object only from the admitted plan through the exact object-store
  or registry identity, requires its record current and unreleased on both sides of the native query, and hands
  that query only the declared description. `recheckRootedClusterObjectKernel` reobserves and refuses a changed
  record, UID or resource version.
- Before every child grant the root also observes each object store the granted node depends on, through a closed
  route derived from the root plan's own admitted share provider: shipped to the provider guest that holds the
  cluster, or read in the root's own frame. No child data selects the object, route or result. An undeclared store
  behind a guest frame is refused; the Direct chain's store is in the root's own frame, declares no object and
  is left to the node's own readiness probe.
- The demo's VM chains declare the object at the cluster state directory the provider guest sees,
  `/var/tmp/hostbootstrap-demo-data/cluster/kind/state`, the path its cluster exposure observation already reads;
  the Direct chain declares none. Sprint 17.42e1b5b's container-side path was not the frame the root reads.

#### Validation

- `ProjectPlanSpec` "rooted object-store observation reads the declared object and refuses missing, foreign, stale
  and unready identities": a missing record refuses without a native query; the exact identity hands the query
  only its declared description and reports the native identity; a foreign plan's identity and a Docker identity
  refuse; the recheck passes unchanged and refuses a changed resource version and a replaced UID; an absent object
  refuses; a record replaced during the native query refuses, and the stale observation fails its recheck.
- `ProjectPlanSpec` "an exhausted forward frame is told to close" pins that each child grant first runs
  `nodeResourceGate` over the node's dependencies.
- `demo/test/CommandsSpec.hs` "the object-store node declares the container cluster's exact object-store
  Deployment": the WSL2 and Incus chains declare the guest-side state directory and the container cluster's
  name, and the Direct GPU chain declares none.

2026-11-20, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the two focused cases passed, the guard, import
audit and document validator selection passed 171 cases, and the demo suite passed 174. The first complete
`core/` and `demo/` legs each failed only "the rooted frame session is root-selected, hidden, nominal, and
request-inert", which pins `Rooted.hs`'s exports, its `data` count and its bytes; the four new exports, a fifth
`data` declaration for the opaque observation and the new byte digest were pinned. The repeated `core/` leg then
passed all 5,600 tests in 772.58 seconds and the `demo/` leg passed 174 demo and 5,600 core tests; `check_code`
passed and `test_all` passed 384 tests. On the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4) the demo
suite passed all 174 cases from 18:53:40 to 19:31:18 UTC. No live demo run has yet exercised the per-grant
observation; the long demo gate owes it.

#### Remaining Work

None.

### Sprint 17.42e1b6: Observe registries at the root [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Independently observe the exact plan-owned registry and its native conditional version at the root.

#### Deliverables

- The root grant gate observes each object store and registry the granted node depends on through Sprint
  17.42e1b5c's kernel and closed route, which already admit only an object-store or registry identity; no child
  data selects the object, route or result, and an undeclared registry behind a guest frame is refused.
- The demo's VM chains declare the `registry` Deployment in the default namespace of the container's Kind cluster
  at the guest-side state directory, through the same `demoClusterObjectDescription` as the object store, and
  `deployRegistryAction` refuses a cluster other than the declared one; the Direct chain declares none.

#### Validation

- `ProjectPlanSpec` "rooted object-store and registry observation reads the declared object and refuses missing,
  foreign, stale and unready identities" now also observes a registry: a missing record refuses, the exact
  identity hands the query only the registry's description, the object store's identity refuses in the registry's
  plan, and the recheck refuses a changed resource version.
- `demo/test/CommandsSpec.hs` "the registry node declares the container cluster's exact registry Deployment":
  the WSL2 and Incus chains declare it and the Direct GPU chain does not.

2026-11-20, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the rooted, guard and document validator
selection passed 25 cases and the demo suite passed 175. The complete `core/` leg passed all 5,600 tests in
778.45 seconds and the `demo/` leg 175 demo and 5,600 core tests; `check_code` passed and `test_all` passed 384
tests. On the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4) the demo suite passed all 175 cases from
19:52:47 to 20:33:25 UTC.

#### Remaining Work

None.

### Sprint 17.42e1b7: Observe clusters at the root [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Shipped.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/ClusterShippedSpec.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Independently observe the exact plan-owned cluster and its native conditional version at the root.

#### Deliverables

- The cluster's native identity is its `kube-system` namespace: the UID its own API server assigned at creation
  and that namespace's resource version. The shipped object observation's closed kind set gains
  `ClusterNamespace`; nothing is applied, and the far side still derives the kubeconfig from the cluster's own
  state directory.
- Plan admission accepts a cluster object on the `core:deploy-kind` node only as a namespace named in its own
  namespace field, and a workload node's only as a Deployment or StatefulSet.
  `withRootClusterObjectProbeDescriptionKernel` and `observeRootedClusterObjectKernel` accept the exact cluster
  identity, and the root grant gate observes the cluster as well as each workload a granted node depends on.
- The demo's VM chains declare the Kind cluster's `kube-system` namespace at the guest-side state directory; the
  Direct chain declares none. The namespace kind edits phase 16's covered cluster code, and Sprint 16.89 owes
  its re-run.

#### Validation

- `ProjectPlanSpec` "rooted cluster, object-store and registry observation reads the declared object and refuses
  missing, foreign, stale and unready identities" now also observes a cluster: a missing record refuses, the
  exact identity hands the query only the namespace description, the recheck passes unchanged and refuses a
  replaced cluster UID, and an absent kubeconfig refuses; a Deployment or a foreign namespace on the cluster node
  and a namespace on a workload node are refused at admission.
- `ClusterShippedSpec` "a cluster's namespace identity request round-trips exactly", and the object query case
  now refuses an absent namespace and reads a present one with the fake kubectl.
- `demo/test/CommandsSpec.hs` "the cluster node declares its Kind cluster's kube-system namespace identity".

2026-11-20, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the rooted, cluster object and guard selection
passed and the demo suite passed 176. The complete `core/` leg passed all 5,601 tests in 776.39 seconds and the
`demo/` leg 176 demo and 5,601 core tests; `check_code` passed and `test_all` passed 384 tests. On the dedicated
Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4) Sprint 16.89's core leg passed all 5,601 tests, including the fake
kubectl namespace query native Windows skips, the installed bare `cluster-live` passed, and the demo suite passed
all 176 cases from 2026-11-21 00:12:31 to 00:50:29 UTC.

#### Remaining Work

None.

### Sprint 17.42e1b8: Observe chart workloads at the root [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Independently observe the exact plan-owned chart workload and its native conditional version at the root.

#### Deliverables

- Plan admission accepts a cluster object on the `core:deploy-chart` node only when the node carries exactly one
  admitted chart declaration and the object is a Deployment or StatefulSet in that chart's namespace whose
  `kind:name` the chart lists among its admitted effects.
- `withRootClusterObjectProbeDescriptionKernel` recovers the object from a chart-workload identity only after
  `withRootChartProbeResourceKernel` binds it to the admitted chart, its plan and frame;
  `observeRootedClusterObjectKernel` accepts that identity, and the root grant gate observes the chart workload a
  granted node depends on, with its UID and resource version as the native conditional version.
- The demo's VM chains declare the chart's `hostbootstrap-demo-web` Deployment in `default`, which its chart lists
  as `deployment:hostbootstrap-demo-web`; the Direct chain declares none. No covered cluster code changed.

#### Validation

- `ProjectPlanSpec` "rooted chart-workload observation reads the chart's own declared workload and refuses unbound
  ones": the identity is a chart-workload identity; a missing record refuses; the exact identity hands the query
  only the declared workload; the recheck passes unchanged and refuses a changed resource version; the plan's
  undeclared cluster identity recovers nothing; and a workload in another namespace, outside the chart's effects
  or of another kind, and an object on a chart node without an admitted chart, are refused at admission.
- `demo/test/CommandsSpec.hs` "the chart node declares its own web Deployment".

2026-11-21, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the rooted, cluster object and document validator
selection passed apart from the pinned `Rooted.hs` digest, which was then re-pinned, and the demo suite passed 177.
The complete `core/` leg passed all 5,602 tests in 781.26 seconds and the `demo/` leg 177 demo and 5,602 core
tests; `check_code` passed and `test_all` passed 384 tests. On the dedicated Linux VM (Ubuntu 24.04.5 x86_64,
GHC 9.12.4) the demo suite passed all 177 cases from 00:58:38 to 01:36:31 UTC.

#### Remaining Work

None.

### Sprint 17.42f: Recheck prerequisites before rooted grants [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Admit each rooted grant only against the target and dependencies selected by its retained plan.

#### Deliverables

- `rootedNodePrerequisites` derives a granted node's prerequisites from the admitted plan alone: each direct
  dependency that is a plan resource, and the node itself when it is one. A chart step without a chart
  declaration is not a plan resource. Each identity uses the root's retained observation from an earlier
  settlement, or else the current record. A resource with no record at all carries no root evidence and is left
  to its node's own readiness probe; a recorded one must be the current, unreleased row, checked in its own
  protected entry.
- `withJournalPreparedRootedNodeGrantKernel` takes the prerequisite identities and rows and prepares through
  `prepareRootedOperationJournalForPrerequisitesKernel`, so they recheck in the protected entry that publishes
  the node's Unknown records; reverse and fixture callers pass none.
- A root refusal at a grant (resource observation or prerequisite selection) publishes no Unknown row, closes the
  frame's operation session, and answers with the root's signed `refused` stage, so the frame fails in protocol
  order and failed-Up cleanup opens its own session. Before this, the refusal left the forward session open and
  cleanup was refused with "an older session ... is still open".

#### Validation

- `TeardownSpec` (the rooted journal fixture): through the node grant itself, a stale prerequisite refuses with
  "physical version changed" and a missing one with "required resource was not observed", each with zero grant
  callbacks and an unchanged protected-store image; the current row grants once. The existing preparation cases
  keep the missing, stale and released refusals.
- `RecursiveLifecycleSpec` "a released prerequisite refuses the next grant and failed-Up cleanup refuses the
  foreign release": across real root, VM and container processes, a fixture node publishes a released record for
  the settled cluster as an outside writer; the chart's grant is refused at the root as a released prerequisite
  and its effect never runs; failed-Up cleanup runs without meeting an open session, refuses to release the
  foreign-released cluster before reversing anything, and leaves that record as written. Its first runs exposed
  the open-session defect fixed above.
- `ProjectPlanSpec` pins the grant handler's order (gate, prerequisite selection, prepared grant) and the
  preparation call; `CoverageManifest` declares the suite's 30 cases, 27 exercised on the POSIX row.

2026-11-21, dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4): the focused `RecursiveLifecycleSpec`
selection passed all 32 cases from 05:00:05 to 05:41:49 UTC. Native Windows 11 Pro 10.0.26300, where the
process-transport cases skip: the recursive, teardown and guard selection passed 134 cases. The first complete
`core/` leg failed two tests: "exactly the audited production modules import the plan kernel", because
`Rooted/Node.hs` now imports the plan kernel for the opaque `RootProbeIdentity` in its grant signature and was
added to the audited set (it imports nothing effectful), and `ContextSpec` "project init resolves one
existing-output policy and refuses the pair", whose temporary-file rename Windows denied once and which passed on
its rerun and in the same leg run from `demo/`. The repeated `core/` leg then passed all 5,603 tests in 830.13
seconds and the `demo/` leg 177 demo and 5,603 core tests; `check_code` passed and `test_all` passed 384 tests.
On the dedicated Linux VM the demo suite passed all 177 cases from 05:42:45 to 06:20:01 UTC.

#### Remaining Work

None.

### Sprint 17.43a: Semantic report and completion integration [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-completion/HostBootstrap/Handoff/TerminalReport.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-completion/HostBootstrap/Handoff/Completion.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Produce canonical semantic completion only after the root coordinator settles the terminal frame state.

#### Deliverables

- New lower `Handoff.TerminalReport` accepts only canonical terminal-origin bytes plus exact typed settlement
  input and imports no `Command`, `LifecycleEntry`, `Chain`, process, or store owner.
  Root-coordinator settlement is the sole report origin; a child returns authenticated observations.
- `LifecycleEntry` is the sole origin producer/caller and invokes `TerminalReport` only after exact rooted
  frame-session completion. `TerminalReport` admits the two forward reports (completed and failed), each
  only for an attached, advanced Up session. Reverse reports do not pass through it. `LifecycleEntry`
  renders a reverse descent's completed report directly through the `Handoff` renderer, and only from a
  verified `SubtreeSettled` proof and the prepared descent's terminal origin. It renders the root-local
  failed-Up unwind's reverse-completed or reverse-failed report from the root's own broker binding, where
  no child session exists.
- Completion joins forward state to its authenticated binding and reverse state to exact subtree settlement,
  recovery binding, and observations; refused/failed reports enter receipt flow but yield no proof.
- The fixed runtime completion operation runs inside the validated receipt transition, after durable root
  settlement and before `ReceiptRecorded` is released; no caller supplies a terminal callback or report bytes.
- Work is limited to the five named production modules, targets at most 400 significant lines per coherent
  owner, adds no named
  type, and adopts at most one semantic-completion call site.

#### Validation

Cover all six reports, exact binding/origin joins, proof-before-report ordering, refused/failed non-proof, and
fixed completion-operation failure/retry; guard sole completion producers and run the warning-clean core gate.

On 2026-08-21, the focused terminal-owner, completion-ownership, compile-fail, and documentation gates passed
on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. The complete
`cabal test all --ghc-options=-Werror` gate then passed all 2,302 tests. The gate covers all six canonical
report branches, exact binding/origin joins, completion-after-acknowledgement construction, refused/failed
non-proof paths, durable publish/receive retry and conflict behavior, the hidden terminal-report module, and
the coordinator's settlement → report → `FrameComplete` → validated receipt → completion →
`ReceiptRecorded` ordering.

The two forward kernels of `Handoff.TerminalReport` gate on `ordinal <= 1 || not (isJust predecessor)` and
discard the stage. An attached session always carries a predecessor, so any single root-issued advance (a node
prepare, a descend, a refusal) admits a completed report, while an attached frame with no work stays at
ordinal 1 and can never report completion. No test references either kernel or any of their six refusal
texts. The sprint closes when the change and cases in Remaining Work exist and pass in the warning-clean
`cabal test all` from `core/`.

On 2026-11-14, the forward close path was traced before changing the report gate. A `settled` response
records one node or descent, so that stage alone does not prove that every planned node and descent has
finished. The coordinator separately checks the retained node index and descent state at close. An empty
frame stays at its initial session stage and ordinal, so allowing that stage unconditionally would also
admit a nonempty frame before its first node. The empty-work case therefore needs root-owned proof of the
exact admitted frame's completed work, rather than an exception based on ordinal or child-supplied data.
The current journal-close kernel checks that no prepared gates remain, but it does not prove that every
plan-owned operation was ever prepared. Closing an empty journal alone is therefore not that proof.
The forward report kernel now checks the root-issued stage: a settled stage is required, except that an
attached `open` session can complete when its unique catalog entry has neither nodes nor a descent. The
coordinator continues to check its node index and descent state before invoking that kernel; a failed report
requires `settled`. On 2026-11-14, `cabal build all -j4` passed on the dedicated WSL2 Linux host. The
real-process recursive lifecycle selection passed all 19 cases in 113.09 seconds. The sprint's direct
admission cases remain to be added.
The private component seam and a real-session test now exercise unopened, unstarted, intermediate, and
settled report paths with valid report fixtures. Its first build found two discarded `Either` results under
`-Werror`; the test now checks both results and the focused run has been restarted. Empty-work and non-Up
cases remain to be covered.
The first focused execution refused its fixture's settled response because it was paired with a next-node
request. The fixture now pairs it with a settle-node request.
On 2026-11-15 the corrected `root-issued` selection passed both cases, including the new real-session
checks and the existing session-stage case.
The direct refusal case additionally asserts zero report callbacks and an unchanged protected-store image
for unstarted and intermediate sessions; the updated `root-issued` selection passed both cases on
2026-11-15. A separate test-only fault fixture opens a Down session and coerces its index only at the
forward-report boundary to exercise the defensive verb refusal.
On 2026-11-15 the `non-Up` selection passed its one case, including both exact refusal messages and
the unchanged protected-store image.
An attempted empty-child variant of the genuine catalog fixture did not construct a plan: `mkStepPlan`
refused `DescentFromInnermostFrame "host-orchestrator-0"` when the child's only step was removed. The
invalid fixture was removed. Determine whether the plan can admit an empty child through another valid
projection, and otherwise reconcile that invariant with the empty-work requirement before closing this sprint.
The first empty-child filter selected zero tests and was not treated as evidence; a broader `empty` filter
selected 151 cases and exposed the construction refusal above. `StepPlan` is nonempty and its innermost
frame cannot declare a descent, so this case cannot be manufactured by deleting that frame's last step.
The projection trace further shows that `withImmediateTargetKernel` admits the child's current frame through
the projected plan's topology, `topologyFromAdmittedPlan` takes that topology from `chainFrames`, and
`chainFrames` derives its frames from normal steps retained by `forwardKernel`. A regression case now
checks the explicit `DescentFromInnermostFrame` refusal; on 2026-11-15 the `empty` selection passed all
151 tests including that case. The sprint still owes
a resolution of the requested empty-work behavior rather than assuming that refusal proves it.
A further genuine-catalog test checks that every admitted child agrees with its retained current frame and
has a forward node. This fixture-level check does not by itself prove
empty-frame completion or replace the architectural resolution.
On 2026-11-15 the `admitted` selection passed all 82 cases, including the genuine-catalog check.
The coordinator initializes each opened frame's node index at zero and its descent flag to false; a
restart does not make an admitted frame empty by initializing those counters. The plan validator passed
all 22 cases after the status and evidence updates.
On 2026-11-15 the sprint was split to keep the genuine empty-frame admission and root-issued settlement
obligation explicit in Sprint 17.43b. The plan validator passed all 22 cases after the split.
On 2026-11-15 the complete WSL2 `cabal test all -j4 --test-show-details=direct
--test-option=--hide-successes` gate passed all 5,434 core tests in 1,087.97 seconds. The optional native
provider-live lane was not requested. Genuine empty-frame admission and root-issued settlement remain
scheduled in Sprint 17.43b.

#### Remaining Work

None.

### Sprint 17.43b: Admit and settle an empty-work frame [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/internal/handoff-completion/HostBootstrap/Handoff/TerminalReport.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Reconcile plan admission and rooted session settlement so a genuinely admitted child with no nodes and no
descent can produce its completion report.

#### Deliverables

- Split into Sprint 17.43b1 and Sprint 17.43b2 under § G.

#### Validation

On 2026-11-21 the conflict was resolved in favour of changing the plan contract. Frames are derived only from
the `StepFrame` each step names, and a descent carries a lift context but no target frame. A frame with no steps
is therefore unrepresentable, and `mkStepPlan` refuses `DescentFromInnermostFrame` for the innermost
step-bearing frame. The empty child must be a declared plan element whose identity the admitted plan's digest
binds; it cannot be manufactured from a catalog, an ordinal or an empty journal. Sprint 17.43b1 owns that
representation and admission. Sprint 17.43b2 owns the empty frame's authenticated session, its root-issued
settlement and completion report, and the real-process case. The split touches more than three source modules.

#### Remaining Work

None.

### Sprint 17.43b1: Declare and admit an empty terminal frame [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`

#### Objective

Make an empty terminal child frame a declared, digest-bound plan element.

#### Deliverables

- `declaresEmptyChildFrame` names one terminal child frame on a descending step of the innermost step-bearing
  frame; admission then accepts that frame's descent and refuses the declaration anywhere else, twice, without a
  descent, or under an existing frame's identity. The derived topology places the declared frame after the
  innermost step-bearing frame, with no node and no descent.
- The canonical step record carries the declaration, so a different or absent empty child changes the plan
  digest, and the persisted snapshot re-admits it.

#### Validation

- `ProjectPlanSpec` "a declared empty terminal child is a digest-bound frame with no node and no descent": the
  host frame's descending step declares `empty`; the derived topology is `host` then `empty`, `host` descends
  into `empty`, `empty` has no descent and `host` as its parent, and every forward node stays in `host`; another
  empty child's identity changes the plan digest and the persisted snapshot re-admits. A declaration without a
  descent, on an outer frame, twice, under the reused `host` identity or an empty one is refused, and an
  innermost descent without a declaration still refuses `DescentFromInnermostFrame`.
- The golden canonical bytes and `LifecycleSpec` canonical-mutation cases pin the 19-field step record with its
  `empty-child-frames` list, and the sealed export inventory names the new declaration.

2026-11-21, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the empty-frame, golden, canonical, snapshot,
sealed export, `StepSpec` and document validator selection passed 440 cases. The complete `core/` leg passed all
5,604 tests in 855.56 seconds and the `demo/` leg 177 demo and 5,604 core tests; `check_code` passed and
`test_all` passed 384 tests. On the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4) the demo suite passed
all 177 cases from 07:05:56 to 07:44:00 UTC.

#### Remaining Work

None.

### Sprint 17.43b2: Settle an empty terminal frame [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-completion/HostBootstrap/Handoff/TerminalReport.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`, `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

A genuinely admitted empty terminal frame opens its authenticated session and produces its completion report
from root-issued settlement.

#### Deliverables

- `rootedEmptyFrameProofKernel` proves from the root's own catalog that the exact selected frame's one entry
  places no forward node in it and gives it no descent, and refuses a nonempty frame or one that is not exactly
  one entry. The root issues an Up opening of such a frame at the `settled` stage, written into its durable
  opened row; every other opening starts at `open`. The closed request and response pairing matrix is unchanged.
- The forward report kernel requires the `settled` stage; the former exception that completed an `open` session
  of an empty catalog entry is removed, and `TerminalReport` no longer imports the plan kernel.
- A forward frame executor may open with no node, because only the root's catalog proof settles it; a reverse
  opening still requires one. The child closes an empty frame at once.
- A first attempt answered `NextNode` with `settled` and widened the pairing matrix; the `HandoffSpec` guards that
  pin that closed matrix refused it, and it was reverted in favour of the root-chosen opening stage. The change
  touches four production modules, one more than § G's three, because the executor's empty-opening refusal sits
  in its own owner.

#### Validation

- `RecursiveLifecycleSpec` "an admitted empty container frame settles from the root and completes": across real
  root, VM and container processes, the `vm` step descends into a declared empty container frame; `up` succeeds,
  the container frame runs its own authenticated child through the Docker crossing and executes no node, every
  frame publishes a completed forward report, no container operation commits, and `destroy` succeeds.
- `TeardownSpec` "forward terminal reports require the root-issued settled stage": the unstarted nonempty frame
  still refuses both reports with zero callbacks and an unchanged protected-store image, and the proof kernel
  refuses that frame as having admitted work and an absent frame as not one catalog entry.
- `ProjectPlanSpec` pins that only an Up opening of a frame the catalog proves empty is issued `settled`, the
  opened row's stage, `Rooted.hs`'s exports and bytes, and the plan-kernel import audit without `TerminalReport`;
  `CoverageManifest` declares the recursive suite's 31 cases, 28 exercised on the POSIX row.

2026-11-21, dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4): the focused recursive, root-issued and
teardown selection passed all 134 cases from 10:26:26 to 11:09:35 UTC; its earlier runs exposed the executor's
empty-opening refusal and a test helper that did not name completed forward reports. Native Windows 11 Pro
10.0.26300, where the process-transport cases skip: the affected selection passed 401 cases. The complete `core/`
leg passed all 5,605 tests in 792.02 seconds and the `demo/` leg 177 demo and 5,605 core tests; `check_code`
passed and `test_all` passed 384 tests. On the dedicated Linux VM the demo suite passed all 177 cases from
11:10:05 to 11:47:32 UTC.

#### Remaining Work

None.

### Sprint 17.44a: Recover abandoned rooted operation sessions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/RecoveryInterruptionSpec.hs`, `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Recover the exact abandoned rooted operation journal under a fresh fence before opening a replacement session.

#### Deliverables

- Fence and interpret the exact abandoned session and operation manifest under the current root authority,
  preserving committed observations and refusing unknown effects before admitting a replacement session.
- Prove process death after the container's Adopted report and a subsequent destroy without a second effect.

#### Validation

On 2026-11-15, the `RecoveryInterruptionSpec` case "reverse restart after Adopted replays without a second
effect" reached the sentinel after verifying the container's Adopted parent row and one container effect,
then killed the root. Restart refused because an older operation session remained open. The case and full
`cabal test all --ghc-options=-Werror` gate remain due after recovery is implemented.
An initial generation-only recovery composition compiled, but the restart still refused the open session;
the interrupted and post-restart images show the same generation-2 session. Reverse entry can reify the
committed broker generation, so generation alone cannot prove that a same-generation session belongs to a
dead invocation. That speculative composition was removed. Recovery needs a retained liveness or invocation
witness; it must not treat same-generation sessions as abandoned merely to pass the restart case.
The Production reverse-entry callback now attempts catalog-scoped recovery while the existing project
run-liveness lock is held and before it opens any new frame sessions. It uses the existing complete
manifest, fence, interpreter, and admission kernels. On 2026-11-15 the process-death case confirmed the
abandoned session was closed, then failed because the restarted rooted journal tried to reopen that same
durable session identifier. The closed row must remain evidence; replacement sessions need a distinct
identity tied to the recovered fence. The first fence-bound run failed during `up` because the prepared
gate still compared the journal identity to the unfenced token; that comparison now derives the journal
identity from the token and fence. On 2026-11-15 the `RecoveryInterruptionSpec` process-death case passed
on WSL2: the root was killed after the container parent row became Adopted, restarted destroy exited zero,
and the container effect appeared exactly once. The full gate and negative recovery cases remain due.
The expanded process-death case passed again on WSL2 on 2026-11-15: a competing destroy while the first
root held liveness refused without changing the protected image before the original root was killed.
The documentation-validator selection passed all 22 cases. The first `indexed` selection found one
source-shape guard expecting the old direct callback; after correction, all 121 selected cases passed on
WSL2 on 2026-11-15. On that date the `unknown` selection passed all 33 cases on WSL2, including
`RecoveryInterruptionSpec`'s "reverse restart refuses an unknown child effect without repeating it": the
restart refused `EffectOutcomeUnknown` and the container effect remained recorded exactly once.
On 2026-11-15 the Windows host Python `check_code` passed and `test_all` passed all 384 tests. The full
WSL2 core gate with `--ghc-options=-Werror` and the separate `demo/` Cabal leg are running; their results
remain due. The core run reported the recovery-interruption coverage inventory still listed five cases;
the inventory is corrected to seven cases, three conditional on the POSIX guest row. That running core
gate is therefore not a pass and must be rerun after the inventory change.
That core run finished with two failures out of 5,437 cases, both caused by the old total/conditional
recovery-interruption inventory; no other case failed. The corrected full core gate is being rerun.
The `demo/` Cabal leg passed on WSL2 on 2026-11-15, including the demo suite and all 5,437 core tests
(1,161.38 seconds for the core suite). The corrected standalone core gate passed all 5,437 tests in
1,133.30 seconds. The committed-work recovery test now also compares the exact stored operation image
before and after interpretation. The `committed` selection passed all 13 cases, including that strengthened
case, on WSL2 on 2026-11-15; the final warning-clean `cabal test all` from `core/` passed all 5,437
tests in 1,124.32 seconds on that host, including the strengthened test and process-death cases.
The 22 documentation-validator cases and the 121-case `indexed` selection passed on WSL2 after removal;
the latter executable was built before removal, so it establishes the current source guards but not a
rebuild of the reverted implementation.

#### Remaining Work

None.

### Sprint 17.44b: Reverse Adopted replay proof rehydration [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-completion/HostBootstrap/Handoff/Completion.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Rehydrate reverse semantic proof from exact root-resident Adopted state after restart or response loss.

#### Deliverables

- Rehydration joins Adopted binding/report/acknowledgement to Bound descent and root frame journal state.
- Canonical reverse observations are decoded and verified against the exact plan-owned teardown work.
- Live and rehydrated branches verify reverse observations through the one Bound observation verifier,
  `withVerifiedBoundReverseDescentObservationsKernel`. The live branch reaches it through
  `withBoundReverseLifecycleCompletionKernel`; the restart branch is `withRehydratedSettledReverseDescentKernel`
  (`Teardown/Internal.hs`), which the root reverse driver's `launch` calls before opening a session.
- Drift or incomplete parent/session state refuses without reopening a token, child process, or local effect.
- Work is limited to the three named production modules plus their focused source/behavior guard, targets at
  most 400 significant lines per coherent owner, introduces no
  named type, and adopts no unrelated production call site.

#### Validation

The sprint closes when the `RecoveryInterruptionSpec` restart case and the rehydration, parent-row, and
observation verifier cases named in Remaining Work exist and pass, the dead rehydrated-completion path is
deleted, the source guards name
`withRehydratedSettledReverseDescentKernel` as the one restart path, and
`cabal test all --ghc-options=-Werror` passes from `core/`.

On 2026-08-21, the focused handoff, project-plan ownership, and documentation gate passed all 184 tests on
x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. The complete
`cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate then passed all 2,302 tests.
The gate covers the existing live Reported/Acknowledged/Adopted transition and reverse-report corruption,
binding, observation, and replay cases. Restart recovery is covered by source/ownership guards only: they
pin that `withRehydratedSettledReverseDescentKernel` rehydrates the exact child Bound row, read-only reads the
parent Adopted row, and replays its report through `withVerifiedBoundReverseDescentObservationsKernel`. No
behavioural case restarts a root after Adopted.

On 2026-11-15, tracing the retained Bound binding found that the current parent scan deliberately
matches the same lifecycle edge across binding changes, and `rebindAdopted` can then replace the Bound
binding with the adopted one. A single lookup keyed by the input binding would miss that alternate
binding; the scan change must preserve replay and duplicate detection while isolating unrelated corrupt
rows. The kernel Haddock now describes the existing scan and cross-binding behavior rather than claiming a
single-key lookup. The scan now skips a malformed or later-version row when its decoded binding names another
edge. The `parent` selection passed all 76 cases and `HandoffSpec` all 230 cases on WSL2 on 2026-11-15,
including an unrelated malformed row at versions one through four; rows whose binding cannot be decoded
remain an open isolation problem.
Separately, `rebindAdopted` now checks the retained
lifecycle cursor inside the protected entry before reading or replacing the Bound row. That change compiles;
behavioral validation of the stale-cursor case is pending.
The `rehydrat` selection passed all three selected cases on WSL2 on 2026-11-15; these do not yet exercise
the stale-rebind case. The source guard now slices the Bound, Adopted, and Settled kernels by their signatures
and checks each kernel's cursor, read, and compare-and-swap counts separately.
On 2026-11-15 the updated `HandoffSpec` selection passed all 230 tests, including the separate source guards.
The existing real-store parent lifecycle case now checks absent, pending version-two, and adopted version-three
report rehydration and verifies unchanged store images; the report kernel was also added to the capability
partial-application forcing case.
The initial narrow filter selected zero cases and is not evidence. On 2026-11-15, direct `parent` and
`partial` selections passed all 76 and 15 tests respectively, including the new store-backed and forcing
checks.
The same real-store case now also queries an adopted report using a distinct token binding for the same
edge, to pin the current cross-binding replay behavior before changing the scan. On 2026-11-15 the updated
`parent` selection passed all 76 cases, including that control.
The uncalled rehydrated-completion producer, its unused completion fold, and their exclusive Adopted
rehydration helpers have been removed. The source guard now distinguishes the remaining Bound and Settled
rehydration kernels. The affected handoff suite first found five inventories still counting the removed path;
those inventories were corrected and the suite is rerunning. Bound rehydration now distinguishes an exact
Prepared row from refusal using `Maybe`, so an absent or unreadable row cannot resume recovery; this change
compiled and the updated `HandoffSpec` selection passed all 230 tests on WSL2 on 2026-11-15. The direct
behavioural cases, project-plan and compile-fail boundary checks, and complete sprint gate remain due.
The first `indexed` project-plan selection found two remaining counts of the removed Prepared constructor
use; those counts were corrected and need a rerun. The `compile-fail` selection passed all 884 tests on
WSL2 on 2026-11-15; an earlier filter matched zero cases and supplies no evidence. The `rehydration`
selection passed both cases on WSL2 on 2026-11-15, including real-store exact Prepared replay and malformed
or missing Bound refusal with unchanged store images. The next `indexed` run found two further duplicate
inventory expectations; after correction, all 121 selected cases passed on WSL2 on 2026-11-15.
The updated `rehydration` and `parent` selections passed 2 and 76 cases on WSL2 on 2026-11-15, respectively;
these include foreign version-one Prepared, foreign-store binding, and version-four adopted-row refusals
with unchanged store images.
The extended `parent` selection passed all 76 cases on WSL2 on 2026-11-15, including version-one
parent-row miss and wrong-key version-three refusal with no rehydration writes.
The updated `parent` selection passed all 76 cases on WSL2 on 2026-11-15, including two independently
adopted rows for one edge refusing rehydration without writing. The `verifier` selection passed all 12
cases, including direct real-store Bound checks for missing, extra, and failed child observations.
The `parent` selection passed all 76 cases again on WSL2 on 2026-11-15 after adding malformed matching
version-three refusal with an unchanged store image.
The `rehydration` selection passed both cases on WSL2 on 2026-11-15 after advancing a real lifecycle cursor;
the retained cursor is refused with the exact stale-cursor reason and no further writes. This checks the
initial rehydration entry, not the separate rebind race.
The expanded `verifier` selection passed all 12 cases on WSL2 on 2026-11-15, including exact foreign-binding
and foreign-verb refusals with unchanged store images.
The expanded `rehydration` selection passed both cases on WSL2 on 2026-11-15, including exact malformed,
conflicting Prepared bytes, and trailing-byte Bound-record refusals with unchanged store images.
The expanded `verifier` selection passed all 13 cases on WSL2 on 2026-11-15, including a two-operation
child fixture that confirms reordered observations are refused by the real Bound verifier.
On 2026-11-15 the `rehydration` selection passed both cases, including an unreadable protected-record
envelope that remains a refusal without rewriting its bytes. The `verifier` selection passed all 13 cases
again, including a real Bound-but-not-Adopted row returning `False` with an unchanged store image.
The reordered-observation fixture now uses the recursive VM/container plan and also removes the nested
container observation. Its first run refused during child-context projection before reaching the verifier;
after switching to the recursive plan's child projector, the `verifier` selection passed all 13 cases on
WSL2 on 2026-11-15, including reordered and incomplete nested observations.
A real-store fixture now prepares and adopts a completed reverse report, then rehydrates it through the
production Bound verifier without a store write. The `verifier` selection passed all 13 cases on WSL2 on
2026-11-15, including single-level and nested adopted replay. This in-process evidence does not replace the
required process-death restart case.
The first process-death probe watched for an adoption response at the VM crossing and timed out: the root
adopts locally before sending the container's `Acknowledged` message. The test-only proxy now holds that
message at the container crossing, checks the container parent row is Adopted, and publishes the sentinel.
A second attempt watched `docker` directly and also timed out: the fixture invokes the container through a
composed `incus ... docker` route. The selector now matches that route; the case awaits another run.
On 2026-11-15 the corrected probe reached the sentinel with the container's Adopted parent row and exactly
one container effect, then terminated the root. The restarted `project destroy` failed: opening a rooted
operation session refused because an older session remained open. The case therefore remains failing; it
exposes an abandoned-session recovery obligation before adopted replay can complete. No second-effect
claim is made from this failed run.
The `DocValidatorSpec` selection passed all 22 cases on WSL2 on 2026-11-15 after these plan updates.

On 2026-11-21 the remaining work was completed:

- `rehydrateAdoptedLifecycleReportKernel` now attributes a row whose binding cannot be decoded by its key alone:
  under the exact key of this edge's own binding it refuses as a conflict, and under any other key it cannot be
  this edge's current row and is skipped. Decoded rows still match across token rotations and duplicates still
  refuse. A store-backed `HandoffSpec` case writes opaque bytes under an unrelated edge's key at versions one
  through three and rehydration still returns this edge's exact report with an unchanged store image; the
  existing opaque bytes under this edge's own key still refuse. The residual limit is recorded: opaque bytes left
  under an earlier token binding of the same edge are indistinguishable from another edge's and are skipped, so
  rehydration misses them and the live exchange resumes under its exact-key adoption checks.
- The Bound row classification is typed: the former local `rehydrateRecord` is
  `classifyRehydratedBoundRecordKernel`, returning `Nothing` for the exact version-one Prepared bytes, the binding
  for a canonical version-two-or-later Bound row, and a refusal for a read failure, an absent row or any other
  row. No comparison with refusal text remains.
- `rebindAdopted` is `rebindAdoptedReverseDescentKernel`. A real-store `TeardownSpec` case calls it with a rotated
  adopted binding after the lifecycle cursor advances; it refuses with "the lifecycle cursor is stale" from its
  own check inside the protected entry and leaves the store image unchanged.
- `Teardown.Internal`, already private to the test suite through the `TestTeardownInternal` mixin and excluded
  from production by its compile-fail case, now exports `classifyRehydratedBoundRecordKernel`,
  `rebindAdoptedReverseDescentKernel`, `classifyPrepared`, `parseBoundRecord` and `verifyChildObservations`, so no
  Cabal edit was needed. Direct cases classify a canonical Bound row, an absent row and a read failure, parse
  canonical, conflicting and trailing Bound bytes, and check that preparation accepts a canonical Bound row of the
  same preparation.
- The `RecoveryInterruptionSpec` case "reverse restart after Adopted replays without a second effect" passes: the
  abandoned-session recovery of Sprint 17.44a now lets the restarted root replay the Adopted report, and
  `reverse-attempts` names `container` once.

On 2026-11-21 the dedicated Linux VM (Ubuntu 24.04.5 x86_64, GHC 9.12.4) passed the focused recovery-interruption,
teardown, rehydration, parent and verifier selection, all 194 cases, from 12:05:27 to 12:51:38 UTC, including all
three process-death recovery cases. Native Windows 11 Pro 10.0.26300 passed the teardown, rehydration, handoff,
guard and document validator selection, 370 cases; two `HandoffSpec` measured line counts rose by four for the
isolation change and were updated. The first complete `core/` and `demo/` legs each failed only "the
reverse-descent substrate is hidden, nominal, and durably ordered", which pins `Teardown.Internal`'s exports; the
five new exports were pinned. The repeated `core/` leg passed all 5,605 tests in 817.23 seconds and the `demo/`
leg 177 demo and 5,605 core tests; `check_code` passed and `test_all` passed 384 tests. On the dedicated Linux VM
the demo suite passed all 177 cases from 12:52:35 to 13:30:20 UTC.

#### Remaining Work

None.

### Sprint 17.45: Reverse child executor adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/reverse-executor/HostBootstrap/Teardown/Executor/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Adopt an authenticated recovery child package into the same storeless frame executor.

#### Deliverables

- A local reverse effect that throws settles as `TeardownFailed` with the exception's text, exactly as the
  root's `guardedReverse` does, so the root's reverse node is settled rather than stranded. Once the effect
  has run, its observation always renders, so the successor forest and the observation are never dropped.
- Real child-process cases exercise refused outcomes and their durable successor observations.

#### Validation

Cover Down/Destroy local and nested work, package/digest drift, response replay, child failure, exact
observation order, and the storeless import DAG through real receiver framing; run the warning-clean core gate.

On 2026-08-21, the combined handoff, indexed-plan, compile-fail, and documentation gate passed all 680
selected tests on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. The complete
`cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate then passed all 2,304 tests.
The gate composes the existing real Receiver framing and Down/Destroy teardown behavior with a new ownership
guard proving recovery-package decode, canonical config re-admission, exact local-plan/adapter projection,
installed-key response verification, Prepared-before-effect order, canonical descendant-observation replay,
and the signed `FrameComplete` → `ReceiptRecorded` terminal sequence. A compile-fail fixture proves the
reverse executor remains Cabal-private; its import guard excludes Command, Chain, protected-store,
lifecycle-context/session, and process owners.

The sprint closes when the thrown-reverse and normalized-observation cases named below pass, together with
the host static gate. Adapter, classifier, and storeless-boundary obligations move to the following sprints.
On 2026-11-15, the executor began converting synchronous callback exceptions to failed outcomes. The
process fixture now terminates the child for its crash case rather than using a catchable exception; a new
throwing-callback case and the updated coverage inventory await their first run. Outcome normalization and
the full sprint gate remain due.
The first `throwing` selection on WSL2 on 2026-11-15 failed the new case: the first destroy recorded the
callback failure and its terminal operation row, but the second destroy refused `the durable settlement row
conflicts`. The settlement key is based on the frame token and ordinal, which can recur on retry. The failed
settlement must remain immutable evidence while the new attempt receives a distinct, authority-bound identity;
the retry is not yet proven. The split plan passed all 22 documentation-validator cases.
The `interrupted` selection passed all 17 cases on WSL2 on 2026-11-15, including the abrupt child exit and
the retained unknown-effect recovery behavior.
The observation normalizer now preflights the actual rooted wrapper before the effect, and fits oversized
details through that same wrapper rather than assuming the outer 8 MiB limit applies to its 6 MiB body.
The changed production modules compiled on WSL2 on 2026-11-15. The first empty-refusal fixture incorrectly
expected exit 1; the lifecycle returns success for a settled refusal. The fixture now checks the stored
normalized detail and terminal operation row; the `usable` selection passed all four cases on WSL2 on
2026-11-15, including that fixture. The throwing case still fails on the
settlement collision recorded above.
The `oversized` selection passed all 15 cases on WSL2 on 2026-11-15, including a real child callback
returning 3,200,000 multibyte characters; the root decoded its clipped observation and recorded the
operation terminally after exactly one effect. A strengthened assertion then found that a later signed
refusal had its own smaller text bound and failed with `oversized refusal detail`; the relay now fits the
refusal through that encoder too. The strengthened `oversized` selection passed all 15 cases on WSL2 on
2026-11-15, including the terminal operation and absence of an oversized-transport refusal.
On 2026-11-15, the updated `HandoffSpec` and `indexed` selections passed 230 and 121 cases on WSL2,
respectively; the Windows Python code check and test suite passed. The full core and demo Cabal legs of
the host static gate are running on the dedicated WSL2 instance.
Those Cabal runs were stopped before completion when the throwing fixture was corrected to use the
specified `LifecycleFailure` rather than a generic I/O exception; neither stopped run is gate evidence.
The corrected `throwing` selection passed all four cases on WSL2 on 2026-11-15, including the retry and
unchanged predecessor records. On 2026-11-15 the final host static gate passed: the WSL2 `core/` leg
passed 5,441 tests in 1,164.12 seconds; the WSL2 `demo/` leg passed 5,441 core tests in 1,154.10 seconds
and 169 demo tests; the Windows Python code check and test suite passed.

#### Remaining Work

None.

### Sprint 17.45a: Canonical reverse adapter [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/reverse-descent/HostBootstrap/Teardown/Preparation.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/internal/reverse-executor/HostBootstrap/Teardown/Executor/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`, `core/hostbootstrap-core/test/compile-fail/OpenReverseDescentSubstrate.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Use one canonical adapter renderer and one storeless verifier for reverse child admission.

#### Deliverables

- `renderReverseAdapterKernel` in the private `reverse-descent-internal` library's
  `HostBootstrap.Teardown.Preparation` is the one adapter renderer; it takes the reverse verb's name and frames
  each field with the shared eight-byte big-endian length prefix, byte for byte as before. The root producer in
  `Teardown.Internal` and the child verifier in `Teardown.Executor.Internal` both call it; the root's
  `renderReverseAdapter` and the executor's `renderAdapter` are deleted, and the executor still does not import
  `Teardown.Internal`. The main library gains `reverse-descent-internal` as a dependency, which edits phase 16's
  covered Cabal file; Sprint 16.90 owes its re-run.
- The callerless `withVerifiedReverseAdapterKernel` is deleted with its export, its compile-fail fixture import
  and diagnostic, and its `ProjectPlanSpec` fragments.

#### Validation

- `ProjectPlanSpec` "exactly one private module renders the canonical reverse adapter": only `Preparation.hs`
  frames the adapter domain as text, it fixes the three terminal outcomes, the root producer and the child
  verifier render through it, and the executor does not import `Teardown.Internal`. The failed-Up decoder that
  compares the domain is not a renderer and is not counted.
- `ProjectPlanSpec` "the reverse-descent substrate is hidden, nominal, and durably ordered" pins the root
  producer's shared-renderer call and the reduced export list; the compile-fail selection keeps
  `HostBootstrap.Teardown` closed.

2026-11-21, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the adapter, reverse-descent, compile-fail,
teardown, audit and sealed export selection passed 1,006 cases.

The complete `core/` leg passed all 5,610 tests in 797.50 seconds and the `demo/` leg 177 demo and 5,610 core
tests, after the first complete run found the test that pins every library source root missing the new
`internal/reverse-executor` root; `ContextSpec` "project init resolves one existing-output policy and refuses the
pair" also failed once in that run's `demo/` leg on a Windows-denied temporary-file rename, its second such
occurrence after Sprint 17.42f, and passed on rerun; it is an open Windows intermittent outside these sprints.
`check_code` passed and `test_all` passed 384 tests. On the dedicated Linux VM Sprint 16.90's core leg passed all
5,610 tests including the real-process recursive lifecycle and recovery cases, the installed bare `cluster-live`
passed, and the demo suite passed all 177 cases from 19:08:10 to 19:31:17 UTC.

#### Remaining Work

None.

### Sprint 17.45b: Reverse receiver and executor refusals [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/internal/reverse-executor/HostBootstrap/Teardown/Executor/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `core/hostbootstrap-core/test/TeardownSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Reject invalid receiver config and mismatched authenticated reverse execution responses.

#### Deliverables

- `runScopedRecovery` decodes the child config with `TextEncoding.decodeUtf8'` and refuses "reverse child: the
  child config is not UTF-8" before invoking the codec, rather than letting a lenient decode replace bytes.
- `Teardown.Executor.Internal` moves into the new private `reverse-executor-internal` library, which the main
  library depends on and the test suite reaches as `TestTeardownExecutor`; it is no longer a main-library hidden
  module, and importing it outside the package names that hidden library. It also exports the pure
  `failedUpExpectedOperations` decoder.
- The storeless-executor guard replaces its six-name import deny-list with an exact allow-list of the executor's
  seventeen imports and bans `ProtectedStore`, `ProtectedSession`, `compareAndSwapProtectedRecord` and
  `withProtectedEntry` as identifiers.

#### Validation

- `TeardownSpec` "the storeless reverse executor refuses non-canonical failed-Up adapters exactly": a differing
  header, a differing suffix, a non-UTF-8 operation and a count that is not eight bytes each refuse exactly, and a
  canonical one-operation adapter decodes.
- `TeardownSpec` "the storeless reverse executor admits only the canonical adapter of one exact topology child":
  the container frame admits its canonical Down adapter and refuses a Destroy adapter, an extra operation and a
  duplicated operation as not canonical; a duplicated failed-Up operation and the root frame, which is no
  topology child, refuse exactly.
- `TeardownSpec` "the storeless reverse executor refuses mismatched Prepared and Descend responses without running
  work": a gate for another operation, a gate without durable authority, a Prepared response for another
  operation, root-owned pre-descent work and a descent result for another child frame refuse exactly, and no
  reverse work runs. The sprint named `HandoffSpec` for these cases; they sit beside the existing teardown
  fixtures in `TeardownSpec`.
- `HandoffSpec` "the reverse lifecycle child is storeless and exact" pins the allow-list, the identifier bans, the
  strict UTF-8 decode and its exact refusal, and the executor's single registration in its private library.

2026-11-21, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the refusal, storeless, compile-fail and
document validator selections passed.

The complete `core/` leg passed all 5,610 tests in 797.50 seconds and the `demo/` leg 177 demo and 5,610 core
tests, after the first complete run found the test that pins every library source root missing the new
`internal/reverse-executor` root; `ContextSpec` "project init resolves one existing-output policy and refuses the
pair" also failed once in that run's `demo/` leg on a Windows-denied temporary-file rename, its second such
occurrence after Sprint 17.42f, and passed on rerun; it is an open Windows intermittent outside these sprints.
`check_code` passed and `test_all` passed 384 tests. On the dedicated Linux VM Sprint 16.90's core leg passed all
5,610 tests including the real-process recursive lifecycle and recovery cases, the installed bare `cluster-live`
passed, and the demo suite passed all 177 cases from 19:08:10 to 19:31:17 UTC.

#### Remaining Work

None.

### Sprint 17.45c: Reverse profile classification [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child/Reverse.hs`,
`core/hostbootstrap-core/internal/reverse-executor/HostBootstrap/Command/Child/Reverse/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `core/hostbootstrap-core/test/TeardownSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Exercise recovery profile and core-managed reverse policy classification by value.

#### Deliverables

- The new private `HostBootstrap.Command.Child.Reverse.Internal`, in `reverse-executor-internal` and test-visible as
  `TestReversePolicy`, holds `recoveryProfileNameKernel` over the authenticated scope and
  `coreManagedReverseKernel` over the reverse policy, the teardown action and the two release actions.
  `Command/Child/Reverse.hs` keeps its fence checks and delegates to both.
- The `HandoffSpec` fragments that read those values out of source now pin the delegation; the remaining
  string-absence checks are labelled as name bans.

#### Validation

`TeardownSpec` "the recovery profile and core-managed reverse policy classify by value": `Production` names
`production`, `Harness r` names `harness:r`, an empty run name and an unknown scope refuse exactly; a
non-core-managed policy answers `TeardownForeignRetained` and a core-managed action other than `DeleteCluster`
answers its contained-release outcome, neither invoking a release; a failed exposure release answers
`TeardownFailed` without the cluster release; and a clean deletion releases the exposure and then the cluster.

2026-11-21, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the classification, `HandoffSpec`, compile-fail
and storeless selection passed 250 cases.

The complete `core/` leg passed all 5,610 tests in 797.50 seconds and the `demo/` leg 177 demo and 5,610 core
tests, after the first complete run found the test that pins every library source root missing the new
`internal/reverse-executor` root; `ContextSpec` "project init resolves one existing-output policy and refuses the
pair" also failed once in that run's `demo/` leg on a Windows-denied temporary-file rename, its second such
occurrence after Sprint 17.42f, and passed on rerun; it is an open Windows intermittent outside these sprints.
`check_code` passed and `test_all` passed 384 tests. On the dedicated Linux VM Sprint 16.90's core leg passed all
5,610 tests including the real-process recursive lifecycle and recovery cases, the installed bare `cluster-live`
passed, and the demo suite passed all 177 cases from 19:08:10 to 19:31:17 UTC.

#### Remaining Work

None.

### Sprint 17.45d: Distinct retry settlement identity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Identify a rooted node settlement by its exact authenticated frame attachment as well as its node coordinates.

#### Deliverables

- A later retry can settle independently while the predecessor settlement remains immutable evidence.
- Exact replay within an attachment converges; a different observation under those coordinates refuses.
- Existing durable rows receive an explicit safe interpretation rather than being silently ignored.

#### Validation

The real throwing-callback case succeeds on its second destroy and retains the first settlement; the rooted
settlement replay, conflicting observation, interrupted publication, and host static gates pass.
On 2026-11-15, the settlement coordinator began deriving the new address from the retained attachment nonce.
It checks the old address first, replays matching legacy bytes, and refuses conflicting legacy bytes. The
process test now also checks that the first attempt's settlement records survive the retry unchanged. These
changes are compiling; behavioral validation is still due.
The first focused run refused during `up`: the scoped token used a dot that protected record names reject.
After correcting the separator, the `throwing` selection passed all four cases on WSL2 on 2026-11-15;
the real retry exited successfully and retained every first-attempt settlement row unchanged. Exact replay,
legacy-row behavior, source guards, and the full gate remain due. A conflicting pre-existing unscoped row
still refuses; no automatic attribution or migration of such a row is claimed.
The `settlement` selection passed all 65 cases on WSL2 on 2026-11-15, including absent, exact, and
conflicting legacy-address cases with unchanged protected images, and interrupted checkpoint coverage.
The node owner's publication helper was moved to the session owner to retain its source-size boundary;
the retry selection passed all four cases again. The first `indexed` rerun found stale whole-module hash,
source marker, and moved-publisher guard expectations; these are corrected and the selection is rerunning.
After correcting the remaining publisher call-site inventory, all 121 `indexed` cases and all 17
`interrupted` cases passed on WSL2 on 2026-11-15. The final host static gate passed on 2026-11-15:
the `core/` leg passed 5,441 tests in 1,164.12 seconds, the `demo/` leg passed 5,441 core tests in
1,154.10 seconds and 169 demo tests, and the Windows Python code check and test suite passed. Conflicting
unscoped legacy rows remain refused pending the recovery work in Sprint 18.26.

#### Remaining Work

None.

### Sprint 17.46: Exact cluster cleanup adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Adopt Phase 16's one cluster cleanup, `releaseRetainedCluster`, at every root lifecycle site that releases a
core-managed cluster, each behind the exact durable preparation of that operation.

#### Deliverables

- Every root core-managed `DeleteCluster` reaches Phase 16's `releaseRetainedCluster`: the root Down/Destroy
  local runner and the failed-Up local runner through `releaseRetainedClusterLifecycle` in `Command.hs`.
- A root-local cleanup runs only after the root reverse driver has durably prepared that operation: it
  publishes the operation's `PreparedGate` through `Lifecycle.Session.withPreparedGate` and hands it to the
  local runner, which refuses unless `preparedGatePlan` is the entry plan's snapshot digest and
  `preparedGateOperation` is the work's key.
- Down and destroy select their exact retained/released policies by the closed verb without caller flags.
- A failed Up releases a cluster its reached prefix acquired, under its `FailedUpUnwindAuthority` (Sprint
  17.52) and the same gate check; outside that authority, Up runs no cluster cleanup.
- Failure yields a typed observation and enters the shared reverse continuation without bypassing child work.
- Work is limited to the three named production modules, targets at most 400 significant lines, and adds no
  named type.

#### Validation

Cover exact policy/verb/plan binding and root-local retry through real journal and store operations. CLI cases
exercise absent or malformed ownership without substituting tool executables; source guards hold the prepared
gate at the cluster release sites. Run the focused command tests and the warning-clean core gate. The
worked-demo phase owns live cluster confirmation with actual provider tools.

On 2026-08-21, the focused cluster reconcile/backend, reverse-entry ownership, indexed-plan, and
documentation gate passed all 123 selected tests on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. The
complete `cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate then passed all 2,305
tests. Existing typed cleanup behavior covers exact removal, retry/already-absence, replacement preservation,
partial failure, and origin retention. Production Down/Destroy sends a core-managed `DeleteCluster` through
`runSealedLocal` to `runCluster` in `Command.hs` (near lines 1749-1770), and the failed-Up runner `runFailedLocal`
(near lines 1666-1680) does the same; both call `releaseRetainedClusterLifecycle` with no durable gate, because
the root reverse driver calls `runLocal plan local` without preparing the operation. The gate-checking
`runPreparedRootClusterCleanupKernel`/`runExactClusterCleanupKernel` pair has no caller; Sprint 17.46a deletes
it with its `HandoffSpec` guard, so the gate check lives at the call sites above. No test drives a
core-managed node through `project down` or `project destroy`.

On 2026-11-15, inspection confirmed that the root reverse driver's `runLocal` callback receives no prepared
gate. Its root plan's own journal also needs abandoned-session handling: a later invocation may not repeat
an effect with unknown outcome, and a replacement session must not reuse a closed predecessor's identity.
The existing child-frame journal recovery does not cover this root plan.
The existing live prepare entry accepts only `ExecutePhase`. A teardown-specific entry now shares its live
binding and cursor checks without widening the forward entry's type. The `prepare` selection passed all 137
cases on WSL2 on 2026-11-15, including the updated type and shared-validation source guard; the root callback
and behavioral teardown-admission cases remain due.
The unused cluster-kernel deletion is split into Sprint 17.46a so this sprint stays within three production
owners and does not expire phase 16's evidence before its own work is ready.
The Production reverse-entry recovery now includes the root plan digest as well as the cataloged child plans;
the change compiled. The root driver now attempts to open a fresh per-operation session, register intent,
prepare a gate under the teardown entry, run the local callback, and acknowledge and close the session. The
Production and Harness root cluster runners check that gate's plan and operation before release. These
changes compiled warning-clean on WSL2 on 2026-11-15 after making the local cleanup helper polymorphic over
the reverse verb. The real recursive lifecycle selection passed all 22 cases on WSL2 on 2026-11-15 after
the root journal change. This covers existing root callbacks and process recovery, not the new root-local
cluster or interrupted-root-effect cases. Failed-Up adoption and those behavioral tests remain due.
The root-local journal sequence is now shared by reverse work and failed-Up unwind; failed-Up cleanup also
checks the gate's plan and operation before cluster release. The refactor compiled warning-clean on WSL2 on
2026-11-15. The recursive selection then failed one case: a failed child descent left the live root Chain
session open, so the failed-Up journal refused a second session. Sprint 17.46c owns closing that known
session after a failed descent, before unwind. After that change the recursive lifecycle selection passed
all 23 cases on WSL2 on 2026-11-15, including the original failed-Up failure and child-first unwind. The
focused root-cluster cases and full gate remain due.
A real-process root interruption case now kills the root during its local reverse callback and requires the
next destroy to refuse the unknown effect without a second callback. Its first run on WSL2 on 2026-11-15
confirmed the unknown operation record. The retry refused `session: ... is still open` during reverse-root
admission, before the later recovery wrapper can interpret the row. The fixture now accepts that conservative
refusal while still requiring no second effect and an unchanged unknown phase. The `interrupted` selection
passed all 18 cases on WSL2 on 2026-11-15, including that check. Sprint 17.46b reconciles the earlier
completeness check with recovery so settled abandoned sessions can resume.
The `HandoffSpec` guard now checks the failed-Up plan and operation comparisons and the reverse runner's
shared gate check before cluster release. The `checks` selection passed all 37 cases on WSL2 on 2026-11-15,
including this guard. `DocValidatorSpec` initially found a bare sprint-number reference in the lifecycle
document; after replacing it with the owning phase link, all 22 cases passed on WSL2 on 2026-11-15.
A CLI fixture now creates cluster ownership in the real protected store through the ownership kernel and
uses modeled cluster tools. The first Up/Down release case initially failed to compile because its action
needed an explicit rank-polymorphic signature; after adding it, the `once` selection passed all 48 cases on
WSL2 on 2026-11-15, including the Up/Down case and its repeated-Down no-duplicate assertion. An initial
pattern selected zero tests and provides no validation evidence. The `managed` selection then passed the
failed-Up release case but failed the absent-chart assertion: the operation identity is encoded in the
record key rather than its payload. The assertion now checks that encoded key and the `ObservedForeign`
phase. The next focused run passed that assertion but found the corrupt-chart case exited successfully:
the fixture had not declared a chart workload, so neither case reached chart-record verification. The
fixture was corrected to declare that workload before rerunning the chart cases.
With the declared workload, the `managed` selection passed all 67 cases on WSL2 on 2026-11-15, including
Up/Down with no duplicate deletion, Destroy with absent chart ownership, Destroy with corrupt chart
ownership, and failed-Up release. The complete gate remains due.
The first complete core run was stopped before completion to correct the cluster-lifecycle and core-library
documentation for the prepared root gate and chart ownership behavior; that stopped run is not gate evidence.
The next full core gate failed 5 of 5,448 tests on WSL2 on 2026-11-15 (1,171.16 seconds). Reverse retry
admission compared the current closed-session count with the source snapshot's earlier count after the new
root-local journal added a closed session, preventing the tests from reaching their target-record checks.
The demo leg was stopped after its own 169 tests passed because its same core suite still contained this
failure; neither run closes the gate. The complete CLI selection was rerun to enumerate its failures.
The `CLISpec` selection then failed four of 125 cases: retained Pending Destroy continuation, target cursor
version refusal, and both non-Prepare target-seed refusals. All four encountered the closed-session count
mismatch first. The fifth failure from the full run was outside this selection and remains to be isolated.
The later core gate failed two of 5,461 cases: the cluster CLI fixture substituted executables on `PATH`,
contrary to the portability guard and § NN, and the authority reifier guard still named the earlier
convergence call. The modeled-cluster cases above do not count as gate evidence and have been replaced by
real-store refusal cases; live cleanup confirmation is scheduled in the worked-demo phase. The demo leg
was stopped after its own 169 tests passed, so neither complete Haskell leg is gate evidence.

On 2026-11-15, WSL2 Ubuntu 24.04.5 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed cabal test all from core/ (5,461 tests, 1,216.10 seconds) and demo/ (169 demo tests and 5,461 core tests, 1,206.36 seconds for its core suite). The Windows Python check_code and test_all legs passed; the latter ran 384 tests at 100% coverage. The provider-live suite reported its declared unsupported result in WSL.

#### Remaining Work

None.

### Sprint 17.46a: One root cleanup path [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Keep one root cluster cleanup path, protected by the adopted durable gate.

#### Deliverables

- `runExactClusterCleanupKernel` is deleted with its export and its now-unused imports from `Cluster/Reconcile.hs`,
  and its one uncalled caller `runPreparedRootClusterCleanupKernel` with its export and import from
  `Command/LifecycleEntry.hs`. The `HandoffSpec` case "cluster cleanup is bound to the sealed root reverse entry",
  which guarded their text, is deleted, and the sealed export inventory drops the producer.
- Sprint 16.11's absence guard, `ClusterBackendSpec` "only retained cluster cleanup through the adopted durable gate
  remains", now bans both names where it formerly required the producer.

#### Validation

The absence guard passes, the reverse-root sealing guard counts each root entry constructor eight times rather
than nine, and the failed-Up entry section now ends at the next declaration. 2026-11-21, native Windows 11 Pro
10.0.26300 x86_64, GHC 9.12.4: the cluster backend, `HandoffSpec`, sealed export and project-plan foundation
selection passed apart from the expected phase 16 evidence expiry. The change edits phase 16's covered cluster
source; Sprint 16.91 revalidated the composed cluster gate on 2026-11-23.
The complete `core/` leg passed all 5,609 tests in 793.75 seconds and the `demo/` leg 177 demo and 5,609 core
tests; `check_code` passed and `test_all` passed 384 tests.

#### Remaining Work

None.

### Sprint 17.46b: Recover root sessions before reverse admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Recover the exact abandoned root journal under held run liveness before reverse-root admission requires
closed sessions.

#### Deliverables

- Interpret and fence the complete root manifest before its closed-session proof is required.
- Resume from settled evidence and refuse unknown effects without repeating them.
- Preserve the existing authority, cursor, and liveness boundaries during recovery.
- Distinguish sessions added by the admitted reverse continuation from the source snapshot's closed-session
  proof without accepting an unrelated, missing, or open session as source evidence.

#### Validation

Real-process cases interrupt a root after a settled outcome and at an unknown effect, proving respectively
successful continuation and refusal without a second effect; include live-owner contention and store-image
checks, then run the host static gate.

On 2026-11-15, the full core gate found that a root-local reverse session can close after the source
snapshot captures its closed-session count. A retry then sees two closed sessions instead of one and
refuses before validating the target cursor or acquisition seed. The exact source and continuation
session sets must be distinguished; weakening the count comparison alone would not prove their ownership.
The source generation is retained in the reverse intent and each operation session stores its broker
generation. A safe partition must still prove that later-generation sessions belong to this exact reverse
continuation, account for terminal Down promoted to Destroy, and reject missing or unrelated sessions;
the generation or a session-name prefix alone is not that proof. `DocValidatorSpec` passed all 22 cases
and `HandoffSpec` all 231 cases on WSL2 after the failed gate, so the fifth failure remains unidentified.
A CLI regression case now changes the closed source session's recorded generation and requires a
generation-specific refusal, no teardown effect, and an unchanged store image. Its first compilation
rejected a partial list operation under `-Werror`; after that was fixed, the fixture failed its setup check
because it counted the transaction stamp as payload. With the corrected field offset, the `broker` selection
failed one of 56 cases on WSL2 on 2026-11-15: Down returned success after the source session generation was
changed to a future generation. This confirms the current count-only proof does not check session provenance.
The fresh reverse admission now enumerates the paired session manifest and refuses a missing, malformed,
zero, or future session generation before recovery. This is only the source-admission check; it does not
yet authorize later reverse sessions or recover an abandoned root continuation. After the change, the
`broker` selection passed all 56 cases on WSL2 on 2026-11-15, including the future-generation refusal and
its unchanged-store assertion. The `sealed` selection also passed all 86 cases and the `LifecycleSpec`
selection all 195 cases on that host and date, including the recursive lifecycle cases.
The continuation path needs durable provenance for each session created after source admission: that
evidence must bind the exact plan, source and target generations, session, operation, and admitted reverse
intent, and must remain valid across a terminal Down promoted to Destroy. The complete session/operation
manifest still decides membership. A missing or mismatched provenance record must refuse; an interrupted
publication must never authorize a callback or hide an open session. Recovery must interpret unknown
outcomes conservatively while holding project liveness, before any replacement session opens.
The Production root-local path now attempts to record the exact committed reverse-intent coordinates and
plan-indexed local operation under its live teardown authority before opening the session. A record left
without its session grants no effect authority. This writer is not yet consumed by admission and has not
yet been validated; its first build found two erroneous `Text` conversions, which were corrected before the
focused rerun. A second build found that the initial readback helper was out of scope; the writer now reads
back exact bytes and version itself, and the Down case asserts its chart and cluster receipts. The `once`
selection passed all 49 cases on WSL2 on 2026-11-15, including those assertions. Continuation verification,
interrupted publication, and recovery remain due.
Reverse admission now attempts to compare the retained source-session count separately and verify each
later session against its exact receipt and admitted target generation. The Down-to-Destroy transition
retains the source count. A CLI case mutates a receipt and requires refusal before a second effect; the
`receipt` selection passed all 41 cases on WSL2 on 2026-11-15, including that case. The formerly failing
CLI continuation cases then passed in the complete 127-case `CLISpec` selection on WSL2 on 2026-11-15.
Recovery of open root sessions remains due.
The count still does not bind the identities of the original source sessions: replacing one source-era
session with another could preserve the count. The source manifest needs an exact durable commitment and
an unchanged-store refusal case before the admission proof is complete. That commitment must cover each
source session identity, generation, version, membership, and the exact version and payload of each paired
operation. It must be published and read back before Pending, admit an exact replay after interruption,
and be compared under the protected entry on every resumed admission. The recovery interpreter must also
avoid rewriting a committed closed source operation while handling a later open reverse session; otherwise
the continuation itself would invalidate that commitment.
A read-only preflight now rejects unknown operation phases before the recovery fence, and fresh reverse
admission attempts the complete fence/manifest/interpreter/admission sequence before recording its source
commitment. Terminal rearm is preflighted before that sequence. The `unrecognised` selection passed all
four cases on WSL2 on 2026-11-15, including refusal without a store change; the fresh-admission sequence
still requires its broader lifecycle validation. The `reverse-root` selection failed one of 16 cases because
its source-section marker omitted the new rearm argument; after correcting the marker, all 16 cases passed.
The complete `CLISpec` selection passed all 128 cases on WSL2 on 2026-11-15 with the fresh-admission
sequence. An earlier concurrent run was invalidated when Cabal relinked its running executable and is not
validation evidence. The `recovery` selection also passed all 211 cases with the preflight in place.
Receipt verification now also attempts to recognize a session with no registered operation when the
exact version-one receipt retains a canonical operation identity; this covers interruption between session
opening and intent registration. The receipt cases and interrupted-session recovery are still due.
The existing `receipt` selection passed all 41 cases on WSL2 on 2026-11-15; a behavioral case for the
zero-operation interruption remains due. `DocValidatorSpec` passed all 22 cases after the plan update.
Before any recovery mutation, resumed admission must also validate the target mode and lease suffix and
the operator, in addition to the source commitment and continuation receipts.
An attempted admission change compiled but failed an existing `reverse-root` source guard (one of 16 cases)
and was withdrawn after review found that the driver could repeat a settled effect. That attempt left the
open-session refusal in place while outcome rehydration was implemented.
The restored `reverse-root` selection then found a separate stale source guard for the earlier receipt change;
after updating it to check the canonical operation name and exact encoded bytes, all 16 cases passed on WSL2.
Inspection of the root driver exposed another requirement: it currently opens a fresh journal session
for every local item without reusing a prior `Released` observation. Admission recovery alone could
therefore repeat a successfully settled effect. The driver must rehydrate the exact operation's proven
outcome before this recovery path can be considered safe; the process case must assert one callback.
The session layer now attempts a read-only lookup of an operation phase through the complete paired
manifest, returning no match for an operation outside that session. The result grants no authority; the
consumer must authenticate the continuation receipt and exact live lifecycle binding. A store-backed case
checks unknown, absent, and released observations. The `manifest` selection passed all 90 cases on WSL2 on
2026-11-15, including that case. The `sealed` selection passed all 86 cases with the updated export inventory;
the driver integration remains due.
The Production root driver now attempts to reuse `Released` only after rechecking the live teardown entry,
committed intent, source commitment, complete continuation receipts, and current broker generation. A
two-operation CLI retry case requires the earlier release to run once while a failed operation retries.
The `once` selection passed all 50 cases and the complete `CLISpec` selection all 129 cases on WSL2 on
2026-11-15, including that case. Open-session recovery and the real-process interruption proof remain due.
The first `sealed` selection failed one of 86 cases because its decoder-use count did not include the new
authenticated reader; after updating the expected counts, all 86 cases passed on WSL2 on 2026-11-15.
The real-process `RecursiveLifecycleSpec` selection also passed all 23 existing cases with the updated driver.
Before open-session recovery is enabled, also account for retained foreign observations and other terminal
outcomes: `Released` is the only outcome the new reader currently rehydrates.
The session layer now attempts a separate version-one root outcome record, written and read back only
while the exact prepared gate is live. Reading requires the paired manifest operation and its matching
acknowledged phase; the detail row alone cannot prove settlement. The new test covers a foreign detail
containing tabs and a newline, the pre-acknowledgement window, and a version-changing rewrite. That focused
case passed on WSL2 on 2026-11-15 before production integration.
Root settlement now attempts to write the result kind and exact detail before acknowledging the operation.
The authenticated reader attempts to reuse released, foreign, and refused results, while failed results
remain retryable; conflicting terminal results and legacy foreign or failure/refusal records without detail refuse.
A two-operation CLI retry case checks that a foreign callback is not repeated. Full validation and legacy
attribution remain due. The first test build found a missing fixture import
for `TeardownForeignRetained`; after adding it, the `once` selection passed all 51 cases on WSL2 on
2026-11-15, including both released and foreign retry cases.
Additional CLI cases now attempt to prove that a terminal refusal is not repeated and that rewriting an
outcome record refuses without another callback or store change. The `root outcome` selection passed all
four cases on WSL2 on 2026-11-15, including both checks and the exact-detail session case.
The complete `CLISpec` selection passed all 132 cases, the `sealed` selection all 86 cases, and
`DocValidatorSpec` all 22 cases on WSL2 on 2026-11-15 after outcome integration and the migration-plan update.
Committed reverse admission now attempts to accept only target-generation open sessions after verifying
source and receipt evidence. It requires the completed target suffix and operator, checks known outcomes
before fencing, then rechecks provenance and closure after settlement. On WSL2 on 2026-11-15, a
store-backed CLI case simulating an interrupted open settled session passed, and a four-case selection
including a rewritten outcome with an open session passed its unchanged-store refusal. These simulated
states do not substitute for the required real-process interruption case.
The existing real-process unknown-effect case now also requires the explicit unknown-phase refusal and an
unchanged protected-store image. On WSL2 on 2026-11-15 the `interrupted` selection passed all 18 cases,
including that check, and the updated `reverse-root` selection passed all 16 cases.
The complete `CLISpec` selection passed all 133 cases and `DocValidatorSpec` all 22 cases on WSL2 on
2026-11-15. The released-operation retry fixture has since been strengthened to simulate its own open
session; the amended case passed and confirmed the release callback ran once.
A Linux real-process fixture now attempts to interrupt the root at the actual session-close publication
boundary using a temporary test-only shared object, after the operation acknowledgement. It asserts an
open session, the durable `Released` phase, successful retry, and one root callback. The focused case
passed on WSL2 on 2026-11-15 with GCC and glibc. `RecoveryInterruptionSpec` separately exercises a live
reverse owner excluding a contender with an unchanged protected-store image.
The first host-static attempt found that the Linux fixture launched a bare compiler name; resolving the
compiler path made all 384 Windows Python tests pass. The preliminary core run then found the added case
was absent from `CoverageManifest`; the core and demo runs were stopped and do not constitute gate
evidence. The fixture now remains visible on every host with a declared Linux/POSIX row and an explicit
unavailable-platform branch. Its family and parent counts have been updated; the focused fixture and its
manifest declaration both passed on WSL2 on 2026-11-15. The gate remains due.
After replacing the modeled cluster commands with real-store refusal cases, the complete `CLISpec`
selection passed all 133 cases, the portability selection all 27, the allocated-generation authority
guard its case, and `DocValidatorSpec` all 22 cases on WSL2 on 2026-11-15.
A source-manifest digest now includes each closed source session and paired operation's identity, version,
and payload hash. A store-backed test rewrites each record with identical bytes and requires the digest to
change. Fresh reverse admission now attempts to publish and read back a source commitment before Pending;
resumption recomputes and verifies it before accepting later session receipts. A CLI case also rewrites the
source session after the first Down and requires refusal without a second effect. The complete `CLISpec`
selection passed all 128 cases on WSL2 on 2026-11-15, including that refusal and the earlier continuation
cases. The `reverse-root` selection also passed all 16 cases. The `commitment` selection passed all 11 cases on WSL2
on 2026-11-15, including the session and operation version checks. Terminal rearm is preflighted before writing the source commitment, so an invalid
retained intent does not cause that new write; its exact deletion still follows a successful commitment.
The first commitment build rejected a shadowed local name under `-Werror`; the name was corrected and the
focused run restarted. An existing intent without this commitment refuses until its source can be attributed;
the recovery and migration phase owns that legacy attribution. The updated plan passed all 22
`DocValidatorSpec` cases on WSL2 on 2026-11-15.
The first admission build exposed misplaced manifest-selector imports; they were corrected before rerunning.
The source guard now requires source-count and exact-receipt verification instead of the former total-count
comparison. The subsequent build was stopped before completion to include this guard; it is not evidence.
The next build was likewise stopped before completion to restrict preceding-Down admission to Destroy and
require its new broker generation to follow that predecessor; the focused cases still require a complete run.
The subsequent `reverse-root` selection failed three source guards: two counted or ordered the old code,
and one used a comment as a source-section boundary. The guards now name the additional intent checks,
generation check, and a real declaration boundary; the `reverse-root` rerun passed all 16 cases on WSL2
on 2026-11-15.
The verified manifest now retains each session's decoded broker generation, so source and continuation
classification can consume the same complete paired observation rather than rereading session records;
the `manifest` selection passed all 89 cases and the `broker` selection all 56 cases on WSL2 on
2026-11-15 after this change. The sealed-interface selection passed all 86 cases on the same host and date.
Inspection then found that the older abandoned-session sweep overwrote the broker generation with
`recovered`; it now retains the original marker, and an interrupted-open recovery case checks that the
manifest and source-generation verifier still see it. The `recovery` selection passed all 211 cases on
WSL2 on 2026-11-15, including that case. Existing
records with a nonnumeric marker still refuse because their original generation cannot be inferred. The
updated plan passed all 22 `DocValidatorSpec` cases on WSL2 on 2026-11-15.

On 2026-11-15, WSL2 Ubuntu 24.04.5 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed cabal test all from core/ (5,461 tests, 1,216.10 seconds) and demo/ (169 demo tests and 5,461 core tests, 1,206.36 seconds for its core suite). The Windows Python check_code and test_all legs passed; the latter ran 384 tests at 100% coverage. The provider-live suite reported its declared unsupported result in WSL.

#### Remaining Work

None.

### Sprint 17.46c: Close the live Chain session after failed descent [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Close a live root Chain session after a child descent fails, before failed-Up unwind opens its journal.

#### Deliverables

- The owner uses its current permit and the normal unsettled-operation check to close the exact session.
- A close refusal is reported and never treated as permission to begin cleanup.
- The original descent failure and reached work remain available to the unwind.

#### Validation

The real failed-Up recursive case unwinds child-first and retains its original failure; a close refusal case
proves no session is guessed closed. Run the Chain and host static gates.

On 2026-11-15, the recursive lifecycle selection passed all 23 cases on WSL2 after closing the live session
on the failed-descent branch, including the failed-Up child-first case. The close-refusal case and full gates
remain due. A real-store case now corrupts the live session during the descent and checks that the original
failure and close refusal are both returned without certifying the session closed. The `corrupt` selection
passed all ten cases on WSL2 on 2026-11-15, including that case. The complete Chain selection then passed all
59 cases on WSL2 on 2026-11-15 with `-Werror`; the host static gate remains due.
On 2026-11-15, its Windows Python `check_code` and `test_all` legs passed (384 tests, 100% coverage).
The WSL2 core gate failed five cases and the demo gate was stopped after its own 169 cases passed; both
complete Haskell legs must be rerun after the reverse-admission defect is fixed.

On 2026-11-15, WSL2 Ubuntu 24.04.5 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed cabal test all from core/ (5,461 tests, 1,216.10 seconds) and demo/ (169 demo tests and 5,461 core tests, 1,206.36 seconds for its core suite). The Windows Python check_code and test_all legs passed; the latter ran 384 tests at 100% coverage. The provider-live suite reported its declared unsupported result in WSL.

#### Remaining Work

None.

### Sprint 17.47: Reverse terminalization and rearm [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/durable_state.md`

#### Objective

Terminalize successful reverse intent and define lawful same-project rearm.

#### Deliverables

- Root terminalization requires exact completed forest/subtree evidence and all frame sessions closed.
- Down records retained terminal state; destroy additionally requires the unique-root `DestroySettled` proof.
- Compare-and-swap plus strict readback makes exact terminal retry convergent.
- Rearm derives only from the admitted terminal row and a fresh root invocation lease/snapshot.
- Work is limited to the three named production modules, targets at most 400 significant lines, adds no named
  type, and adopts at most one reverse-terminalization call site.

#### Validation

Cover Down/Destroy terminalization, nested/unresolved refusal, exact retry, stale lease, and lawful rearm; run
mode/teardown/entry tests, source guards, and the warning-clean core gate.

On 2026-08-21, the focused teardown settlement and root-entry ownership gates passed all 35 selected tests on
x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0; the complete
`cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate then passed all 2,306 tests.
`SubtreeSettled` now has one verb-polymorphic unique-root validator, so both Down and Destroy refuse nested or
incomplete forests before durable mutation; Destroy additionally promotes through the existing
`DestroySettled` producer. The sealed root-entry call site is the only caller of the Mode terminalizer. Mode
checks the exact plan, verb, all-session proof, live mode, bound lease version, and broker generation before a
single Committed-to-Terminal compare-and-swap and strict version-three readback; exact retry is mutation-free.
The retained terminal row permits ordinary admission but can be consumed for rearm only after the next
successful-Up source lease, protected snapshot, journal, cursor, and closed sessions are revalidated with a
strictly newer broker generation. No named type or second terminalization call site was added.

On 2026-11-15, the unused `TeardownIncomplete` error and released-operation projection were removed, and
root and nested Down settlement cases were added.
The terminalizer compares the settled opening frame with the retained root frame, and the
unreachable Destroy arms, redundant release branch, and fresh-admission rearm were removed. Source guards
were updated for those changes. On WSL2 on 2026-11-15, all 95 `TeardownSpec` cases, the terminalization
source guard, and all 22 `DocValidatorSpec` cases passed. The first `reverse-root` selection failed one of
16 cases because its constructor count was stale; after correction all 16 passed. The direct closed-session
digest, missing Destroy closure, and Up refusal cases passed on WSL2 on 2026-11-15; each verifies the protected
record image is unchanged. The cross-plan settled-subtree refusal and both real pre-effect closure refusal
cases also passed on WSL2 on 2026-11-15. The child-frame case passed against a committed intent, bringing
the focused selection to seven passing cases. All seven passed again on WSL2 on 2026-11-15 after the cases
were strengthened to include a committed intent and assert the complete protected-record image is unchanged.
The warning-clean `cabal test all --ghc-options=-Werror --test-option=--hide-successes` run passed all 5,470
core tests in 884.13 seconds on WSL2 with GHC 9.12.4 and Cabal 3.16.1.0. Its provider-live component reported
unsupported on WSL2; the native Linux/KVM/Incus live lane was not run.

#### Remaining Work

None.

### Sprint 17.48: Prepared reverse process route [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Bind one prepared reverse descent to its exact sanitized child-process route.

#### Deliverables

- Canonical package decoding remains inside the private teardown owner and exposes no raw package bytes.
- Witness-only route selection preserves the prepared descent's nominal scope and broker generation.
- Process ownership derives and launches the route in one lexical continuation with no caller argv/tool seam.
- Work is limited to the three named production modules, targets at most 400 significant lines, adds no named
  type, and adopts exactly one prepared reverse-process composition seam.

#### Validation

Cover canonical package recovery and nominal route retention; run the warning-clean core gate. This sprint
composes the route and the process owner without adding behaviour to either. Sprint 17.38 owns the route
sanitizer's behavioural refusal cases, and Sprint 17.40 owns the process-group platform row and its cleanup
cases.

On 2026-08-21, the prepared reverse process ownership guard passed its selected case, `HandoffSpec` passed all
107 cases, the indexed-plan gate passed all 79 cases, and `DocValidatorSpec` passed both cases on x86_64 Linux
with GHC 9.12.4 and Cabal 3.16.1.0. The complete
`cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate then passed all 2,307 tests. The
route accepts only empty proxy witnesses for scope and broker
selection, reuses the existing closed recovery derivation, and is launched only by the bracketed process owner
from the opaque prepared descent. No named type, raw package projection, caller-selected argv/tool,
protected-store access, or process constructor was added.

#### Remaining Work

None.

### Sprint 17.49: Rooted reverse service foundation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Build the root-owned service and canonical terminal join used by one authenticated reverse process.

#### Deliverables

- The service enters only through the sealed reverse root lifecycle entry and persisted rooted catalog.
- One retained prepared descent owns its exact Offer, rooted frame session, incremental teardown forest, and
  canonical child terminal origin.
- Rooted next, settle, descend-result, close, and receipt requests advance only the retained reverse work.
- Once one local reverse operation has durably settled as failed, fresh unrelated siblings may still drain,
  but selecting that failed operation again returns its retained refusal before another Prepared grant or
  effect. The child therefore exits through the existing failed-unwind path instead of creating an unbounded
  sequence of same-operation settlement records.
- The child terminal join accepts only the exact canonical completed report and returns only its verified
  subtree settlement to the retained parent continuation.
- Work is limited to the three named production modules, targets at most 400 significant lines, adds no named
  type, and adopts no command call site.

#### Validation

Cover rooted reverse request order, exact Offer retention, report verification, retry/refusal, and terminal
state; run the warning-clean core gate.

Validated on 2026-08-21 on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. The focused handoff suite passed
all 36 cases and the indexed-plan suite passed all 85 cases. The complete
`cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate passed all 2,307 tests. Source
ownership guards cover exact Offer retention, the prepared forest/origin eliminators, root-owned pre-descent,
local and descent settlement, canonical close, and receipt-bound subtree delivery. The reverse-only link
closes config/activation capabilities; the service retains no raw store key, signing key, package bytes, or
caller-selected plan coordinate, and the rooted transport freeze now covers only its owned sections rather
than the whole shared Relay module.

Revalidated on 2026-08-26 on Apple Silicon with GHC 9.12.4 and Cabal 3.16.1.0 after live worked-demo
acceptance exposed an unbounded retry of one durably failed reverse operation. The rooted service now checks
the retained forest failure before issuing another Prepared grant. The real-process `RecursiveLifecycleSpec`
gate passed 7/7, including prompt child termination and exactly one cleanup effect for the failed operation;
the source-order guard passed in `ProjectPlanSpec`, and `TeardownSpec` passed 37/37. No `TeardownSpec` case
yet fails one node beside an unattempted independent sibling; Sprint 12.6 owes that case. The complete
warning-clean core gate passed 2,463/2,463 in 366.69 seconds. `DocValidatorSpec` then passed 2/2.

On 2026-11-15, the `rootReverseBrokerLink` Haddock was corrected to distinguish its closed endpoints,
broker checks, and supplied admission and service callbacks. A test of the reverse link's config-open refusal
over a pipe and direct activation-signing
refusal passed on WSL2 with GHC 9.12.4 and Cabal 3.16.1.0; it also proves admission is not called and the
protected store is unchanged.
The local-settlement decision has been moved into the existing Cabal-private `Teardown.Internal` module.
On 2026-11-15, two focused cases passed on WSL2 covering mismatched nodes, zero or two observations,
pre-descent, and descent; a `source` selection also passed 194 cases, including the updated codec-ownership
guard.
The decision boundary has since been expanded to the decoded rooted request, retained prepared node, pending
descent, offer, and terminal state, and wired into the service; its combined behavioral cases and compilation
passed four focused cases on WSL2 on 2026-11-15. The first combined test build stopped on two name-shadowing
warnings; their bindings were renamed before the passing run. Real recursive-service and source-guard
validation were then run on WSL2: all 25 `RecursiveLifecycleSpec` cases passed in 26.72 seconds and the
post-integration `source` selection passed 194 cases in 63.32 seconds.
The direct refusals have been split into individually named cases. Their first build stopped on one
name-shadowing warning; after the binding was renamed all 12 focused cases passed on WSL2 on 2026-11-15.
A real child-process proxy case now injects config and activation requests over the reverse handoff pipes;
its first focused run reached the config refusal but the parent terminated the proxy before its response
marker. The test now checks the parent's exact refusal and the durable handoff-token keys before and after
injection. Both config-open and activation-signing requests passed that real-pipe case on WSL2 on
2026-11-15, each returning the expected edge-not-planned refusal without adding a handoff-token record.
The broader `HandoffSpec` run then passed 238 of 244 cases; six rooted-codec ownership inventories still
omitted the new `Teardown.Internal` importer; those inventories were updated.
The rerun passed 243 of 244; the remaining request-ownership inventory also needed the request type and
eliminator attributed to that module. After those entries were updated, the focused `single-owner` selection
passed both cases on WSL2 on 2026-11-15.
The warning-clean `cabal test all --ghc-options=-Werror` gate on WSL2 passed 5,483 of 5,484 cases in
878.05 seconds. The remaining `ProjectPlanSpec` export inventory omitted the new private decision function;
the inventory was updated and the `reverse-descent` selection passed both cases on WSL2. The complete
warning-clean rerun passed all 5,484 core tests in 897.48 seconds on 2026-11-15 in the dedicated WSL2
instance with GHC 9.12.4 and Cabal 3.16.1.0. The optional native Linux provider-live lane reported unsupported
in WSL2.

#### Remaining Work

None.

### Sprint 17.50: Root-authorized nested reverse descent [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Authorize every nested descent from the root command without equating its root frame with the descent parent.

#### Deliverables

- `ReverseDescent` retains the root lifecycle context/cursor/authority under an existential root-frame index
  distinct from its public descent-parent index; both remain nominal and neither can be coerced.
- Preparation accepts any `DescentWork` in the retained root plan, then exact-selects its parent/child edge from
  the recursive catalog before producing a package or durable row.
- Root command reauthorization and cursor validation still precede every nested Prepared/Bound transition.
- Immediate and deeper descent use the same producer; no child command authority, raw frame text, or second
  root plan is manufactured.
- Work is limited to the two named production modules, targets at most 400 significant lines, adds no named
  type, and adopts no command call site.

#### Validation

Cover immediate and deeper parent frames, cross-plan/frame/catalog refusal, retry/rehydration, constructor
hiding, and nominal root/parent separation; run the warning-clean core gate.

Validated on 2026-08-21 on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. The focused indexed-plan suite
passed all 85 cases, and the complete
`cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate passed all 2,307 tests. The
constructor and producer signatures mechanically distinguish existential `rootFrame` from public
`parentFrame`; guards reject the former equality checks, retain nominal roles and constructor hiding, and
prove that only the catalog-selected parent/child edge can reach preparation. No catalog row, child command
authority, raw frame selector, named type, or public export was added.

On 2026-11-15, the obsolete-equality guard was changed to compare Haskell token sequences and to check each
sequence against an indented synthetic line. Both selected `reverse-descent` cases passed on WSL2; the
warning-clean `cabal test all --ghc-options=-Werror --test-option=--hide-successes` gate passed all 5,484
core tests in 894.55 seconds with GHC 9.12.4 and Cabal 3.16.1.0. The provider-live component reported its
unsupported result on WSL2.

#### Remaining Work

None.

### Sprint 17.51: Shared authenticated reverse driver [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Drive Down and Destroy through one root-coordinated child-first interpreter.

#### Deliverables

- The driver enters only through the sealed reverse root lifecycle entry and persisted rooted catalog.
- Local and remote reverse work use the same frame session, prepare/settle, process, and receipt machinery.
- Children complete before their parent continuation advances; siblings retain exact plan order.
- Root intent terminalizes only after every frame and cluster cleanup settles successfully.
- Work is limited to the three named production modules, targets at most 400 significant lines, adds no named
  type, and adopts at most the one shared reverse-command call site.

#### Validation

Cover root-only and multi-level Down/Destroy, ordering, retry/restart, refusal/failure, process cleanup, and
terminal state; run the warning-clean core gate.

On 2026-08-21, the focused project-plan, handoff, and Production reverse-command selection passed all 120
selected tests on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. The complete
`cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate then passed all 2,307 tests.
The single Production Down/Destroy call site now obtains only a sealed target entry and its lease-retaining
terminal continuation. Every descent prepares the exact catalog edge, opens its rooted session, installs the
restricted reverse admissions and service, launches the derived process route, and returns only the
receipt-retained and durably adopted `SubtreeSettled` proof. Root terminalization separately verifies every
session closed for the retained plan digest before consuming that proof; mismatched admissions, absent
settlement, process failure, or terminal refusal cannot advance the parent forest.

#### Remaining Work

None.

### Sprint 17.52: Failed-Up cleanup authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/failed-up/HostBootstrap/Authority/FailedUp/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Authorize cleanup of only the effects made reachable by one exact failed Up without forging Destroy authority.

#### Deliverables

- New hidden all-nominal `FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId` is this sprint's
  sole named type and cannot be used as `RootInvocationAuthority ... VerbDestroy`.
- Two producers exist, and each consumes exact `VerbUp` root authority, the catalog, a canonical failed-forward
  report with its expected binding, and the immutable set of operations reached before failure. Unresolved
  settlement outside that set refuses. `withFailedUpUnwindAuthorityKernel` covers a failed child frame and
  also consumes that frame's failed rooted session. `withRootFailedUpUnwindAuthorityKernel` covers a
  root-local failure. It has no session: it takes the root frame name from the sealed entry, refuses a name
  that is not the catalog root's frame, and records the fixed coordinates path `[frame]`, token `root` and
  ordinal 0. Its anchor is the failed-forward report the
  root publishes first.
- The report check counts only operation rows. `descent/<child>` rows are settlement of a descent and are
  not operations, so the coordinator's frozen prefix and the report agree on what an operation is.
- Fixed folds authorize only child-first cleanup of those reached operations under the same invocation and
  cannot create a general reverse Pending intent, close Production mode, or target another plan/catalog.
  The entry wrappers that consume the authority compare its catalog identity with the entry's own catalog.
- One failed Up mints its authority once. Recovery after it goes through the reverse entry, never through
  a second failed-Up admission, so the module has no retry producer.
- Work is limited to the three named production modules, targets at most 400 significant lines, and adopts no
  command call site.

#### Validation

Cover root/VM/container failure authority, partial settlement, every cross-coordinate refusal, constructor
hiding, nominal roles, and inability to substitute Destroy authority; run the warning-clean gate. The sprint
closes when the behavioural refusal cases, the failed-session kernel cases, and the corrected budget and
placement guards named in Remaining Work exist and pass and `cabal test all --ghc-options=-Werror` passes
from `core/`.

On 2026-08-21, the focused indexed-plan authority and representation suite passed all 86 tests on x86_64
Linux with GHC 9.12.4 and Cabal 3.16.1.0. The complete
`cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate then passed all 2,308 tests.
The `ProjectPlanSpec` case "failed-Up unwind authority is hidden, nominal, exact, and narrower than Destroy"
is a source, export and import guard. It pins the refusal texts and the absence of Mode/store mutation and
Destroy authority. No test calls a producer: the module is in `other-modules`, and no test produces any
`failed-Up unwind authority:` refusal. `RecursiveLifecycleSpec` runs only the success path of a failed `up`
followed by `destroy`, and only on the POSIX row.

On 2026-11-15, the unused retry producer and equality helper were removed. Failed-forward report validation
now excludes `descent/` rows from operation membership, distinguishes non-failed reports, and refuses an empty
binding. The root-local producer now checks the supplied frame against the catalog root. These changes await
their behavioral cases; the `failed-Up` selection passed three existing cases on WSL2. The remaining entry,
session, and budget work is still due.
Both entry wrappers now compare the failure authority's retained catalog identity to the entry's catalog;
the existing three-case `failed-Up` source selection passed again on WSL2 after the change. Direct refusal
coverage remains due. The descent reauthorization action now reconstructs and re-reads the exact Execute
reservation, requiring its original bytes and version; this change and its source guards await validation.
The first build found an unqualified frame accessor; after correction all three selected `failed-Up` cases
passed on WSL2 on 2026-11-15. The direct authority and session refusal cases remain due.
The authority module has been moved into the private `failed-up-internal` component so tests can exercise its
producers. The package change expired cluster-phase evidence; Sprint 16.83's complete core and live-cluster
gate has since passed and its digest was refreshed. Nine direct root-authority cases for duplicate and foreign
coordinates, non-failed reports, empty binding, and descent-row handling passed on WSL2 on 2026-11-15.
The existing rooted-session fixtures now exercise unopened, non-Up, nonterminal, and terminal Up sessions;
all 95 `TeardownSpec` cases passed on WSL2 on 2026-11-15.
An attempted foreign-catalog case reached the root-plan refusal instead: both independently built fixtures
have the same catalog record identity, while their root plans differ. A revised fixture first allocates a broker
generation so its subsequently admitted catalog has a different profile epoch; all six `advancement` cases,
including the resulting distinct-catalog refusal, passed on WSL2 on 2026-11-15.
The focused `advancement` selection passed again with a positive terminal-child authority case and direct
foreign-binding and same-catalog-identity/foreign-root-plan refusals. The same selection then passed with
both VM and nested container sessions. Direct foreign-broker-generation checks passed for the root and child
producers. Foreign-project checks using the private installed-identity fixture then passed for both producers
in the same focused selection.
Compiler fixtures have been added for the private authority's four nominal roles, its hidden constructor,
and the public consumer's inability to import its private component; all three passed on WSL2. A fourth fixture
checks that failed-Up authority cannot be supplied as Destroy root authority; all four fixtures passed on
WSL2 with the actual private and public components exposed to the fixture compiler as appropriate. The fixture
inventory selection also passed all 51 cases. The focused four-case compiler selection passed again after the
Destroy fixture's expected diagnostic was tightened to name the root authority type.
The revised failed-Up source budget and private-component placement guard passed the three-case `failed-Up`
selection on WSL2; the separate `rooted opening` selection also passed all three cases. A real-process fixture
attempts to replace the root Execute reservation before a child reports failure. Its first run failed because
all four cleanup callbacks ran despite the expected refusal. A marker and fuller diagnostics confirmed that
the injected write did not occur: the fixture used handoff framing for a text-framed reservation identity.
With the reservation encoding corrected, the test passed on WSL2: the replacement marker was present,
the command reported the exact stale-reservation refusal, cleanup did not reach the container, and the foreign
row was preserved. The extended real-process case passed on WSL2 for all three variants: foreign bytes,
the same bytes rewritten at a newer version, and a deleted reservation. Each produced the exact stale
reservation refusal, left the injected state intact, and did not start container cleanup.
The focused rerun also passed with both rewritten rows explicitly checked for retained physical record version 2.
A temporary Main-unit control is being added for the two entry wrappers. It builds separately admitted catalogs
with different broker generations and aims to verify refusal before any continuation or store mutation; its
first compile found an ambiguous error type in the test control. The annotation has been added and the
next runs reached the wrappers but the positive control could not construct a cleanup forest: first its steps
preserved on reverse, and then its unresolved set was empty. With removable steps marked unresolved, the
control passed on WSL2: both wrappers refused the distinct-catalog authority, the descent continuation was
not called, and the protected store was unchanged. Its source has since been embedded in the test module so
it is included in source distributions; the embedded control also passed its focused rerun on WSL2.
The first full core gate on 2026-11-15 was stopped after `CoverageManifest` reported the recursive-lifecycle
family had grown from 24 to 25 cases. The new reservation-drift test exercises the POSIX row, so its manifest
has been updated from 24/21 to 25/22; the corrected manifest and complete gate still need their reruns.
Running the entire `CoverageManifest` group alone then failed its aggregate branch-completion check because
the other conditional test families were filtered out; that filtered run cannot validate the aggregate.
An attempted count-only selection was rejected by Tasty's pattern parser before any tests ran; the complete
gate remains the validation for the corrected count and aggregate.
The complete warning-clean core gate was restarted on 2026-11-15 after the manifest correction. On the
dedicated WSL2 linux-cpu instance, `cabal test all --ghc-options=-Werror --test-option=--hide-successes`
passed all 5,499 core tests in 975.34 seconds. The provider-live component passed its declared unsupported
result because native Linux/KVM/Incus was not requested on this WSL host.

#### Remaining Work

None.

### Sprint 17.53: Failed-Up unwind adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/internal/handoff-completion/HostBootstrap/Handoff/TerminalReport.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/internal/reverse-executor/HostBootstrap/Teardown/Executor/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Route failed forward work through the shared child-first machinery under its narrow cleanup authority.

#### Deliverables

- A typed Up failure freezes exact reached and unresolved frame state before requesting cleanup authority.
  The failed row of the root's failed-forward report names the operation that failed, not the last element
  of the merged list.
- The one failed-Up command call site runs only work admitted by `FailedUpUnwindAuthority` through the shared
  child-first process/executor path; it never opens a Destroy root or reverse Pending intent. A failed-Up
  descent renders the same route as a reverse descent, and the reverse rule supplies the target binary. The
  child admits its failed-Up adapter as the canonical outstanding (deepest-first) rendering of a reached set
  that is an ordered subset of the admitted plan, so an adapter with two or more operations is admitted.
- A skipped or failed unwind is never silent. A signing-key load failure, a broker failure, or an unwind
  that leaves unsettled work is appended to the returned Up failure on both the catalog-free and the
  catalog branch.
- Retry resumes exact rooted cleanup state and never reruns settled work or widens the reachable operation set.
- Original forward-failure and unwind reports remain separately authenticated canonical terminal records;
  neither raw text nor one report may stand in for the other.
- Eagerly opened child sessions that never receive an Offer are cancelled only by exact version-and-bytes
  comparison. A failed terminal `frame-complete` is persisted and acknowledged before narrow unwind admission,
  and reverse entry is the only path that advances a retained failed Execute cursor to Teardown.
- Reverse-root admission first classifies and closes abandoned operation sessions, then proves the exact plan
  has no open session before publishing Pending. A same-verb replay of the consumed failed Up still refuses.
- Work is limited to the named production modules, targets at most 400 significant lines, adds no named
  type, and adopts only the one failed-Up unwind call site.

#### Validation

Cover root/VM/container failure, partial settlement, retry/restart, cleanup failure, scope/catalog drift, and
exact dual terminal reporting; run the warning-clean core gate. The sprint closes when the changes and cases
named in Remaining Work exist and pass, together with the real-process failed-Up cases Sprint 17.54 owes, and
`cabal test all --ghc-options=-Werror` passes from `core/`.

The Chain has a no-new-type failure-returning interpreter that records the exact ordered operation prefix
only after each durable Prepared gate is published; the forward coordinator preserves the tuple across its
fixed `Either Text` broker continuation and the existing public interpreter still erases it to descriptive
failure. `failedUpTeardownPlanKernel` retains `VerbUp`, refuses duplicate, foreign, or reordered operation sets,
and admits the reached evidence as an ordered subset of the plan's own and projected keys. It selects
destroy-strength cleanup actions only for removable own nodes, excluding preservation-only nodes and projected
relations, so it cannot promote to Destroy settlement. The child stops after the first durably settled failed
observation, requests early frame closure, authenticates and receipts a canonical `forward/failed` terminal
report, then returns the original failure separately; malformed or trailing observation frames are refused
before settlement. Failed reports retain the canonical ordered settled-observation rows, and the coordinator
freezes those child rows with the root Chain prefix before joining the receipt-recorded session, exact
report, exact Offer binding, catalog, and root authority. The hidden authority verifies that every report
operation belongs to that frozen prefix. The live failure call site drives the joined forest through the
durable shared Prepared/Bound rooted recovery service; the authenticated recovery receiver admits the narrow
Up/teardown adapter while the command cursor remains at Execute. Root-local failure publishes its own
canonical failed-forward record before deriving the same narrow authority, successful cleanup publishes a
distinct canonical reverse-completed record, and cleanup failure publishes a reverse-failed record without
replacing the retained original forward error. Canonical failed-forward observations are covered by the
lifecycle codec suite; the source/representation gates cover the authority, no-Destroy call path, Up/teardown
adapter, and shared process/executor adoption. The complete host-static core suite passed all 2,309 tests on
x86_64 Linux with GHC 9.12.4, and the library/executable build passed with `-Werror`.

On 2026-08-23, `RecursiveLifecycleSpec` passed 6/6 through real root/VM/container processes, including a
failed Up followed immediately by exact reverse recovery. That case asserts only exit codes (`up` 1, then
`destroy` 0); it reads neither `reverse-attempts` nor the stored reports, and on a host without the POSIX
row it asserts a different refusal instead. The complete warning-clean core gate passed 2,442/2,442 in
179.14 seconds; the focused `TeardownSpec` group passed 36/36, including reached preservation and
projected-relation evidence.

On 2026-11-15, the failed-Up adapter already restores the decoded operation set to admitted forward order
before projection while retaining the byte-exact canonical adapter comparison. The real-process failed-Up
case already checks that both VM operations unwind once; it now also captures stderr and rejects the
ordered-subset failure. The strengthened real-process case passed on WSL2.
The root-failure report now selects the final operation from the root's own reached list rather than the
merged child list. A real-process fixture appends a failing root operation after a successful descent and
checks the durable report's root and child statuses; the change and case await focused validation.
Its first run failed because an ordinary root step runs before descent, so the report had no child rows.
Using an explicit post-handoff step, the focused real-process case passed on WSL2: the persisted failed-forward
report marks the root operation failed and all three child operations succeeded.
The coordinator now distinguishes a frame with no failed report from an admitted failed unwind, stops on the
latter, and retains the original reached/unresolved sets when reporting its error. A real-process failure plus
cleanup-failure case asserts both errors on stderr. The focused `failed up` selection passed all four cases on
WSL2, including the ordinary failed-Up and reservation-drift controls.
The catalog-free coordinator now retains signing, broker, and unwind errors; the catalog branch preserves the
original failure on cancellation or root unwind failure and cancels unused sessions when link creation fails.
Two single-frame CLI cases and a link-failure source guard have been added; these changes await validation.
The first focused run passed the cleanup-error case but the success case expected a declared reverse on the
failing, reached step not to run. That expectation contradicted the retained reached-prefix semantics; the
fixture now gives only the acquiring step a reverse, as specified. Both single-frame CLI cases passed on WSL2:
the acquired step reversed once with `ReleaseResource`, Destroy recovered, and the cleanup-failure case
reported both the forward and unwind failures. The success case now records its reverse call in the fixture
directory, as specified, rather than an in-memory counter; both cases passed again in that final form.
The focused `failed-Up` selection then passed all seven cases, including the new guard that forward-link
failure cancels unused rooted sessions.
The forward, failed-Up, and reverse coordinators now share the same container/VM target-binary rule, and
the root Up entry Haddock describes the actual success and failure cursor transitions. The `failed up`
selection passed all four cases after the change, including the real
container route and failed-Up cleanup failure.
The failed-Up projection test now checks the exact duplicate and foreign refusal details, accepts a skipped
earlier operation, and rejects reordered operations. Its focused run passed on WSL2.
The dedicated failed-Up recovery registration and signing paths already admit Up only for teardown; the
verified recovery join now admits the same verb and still checks teardown and exact projection evidence.
The Up join and store-backed admitted/invalid-phase registration cases passed within the 273-case `recover`
selection on WSL2, alongside the existing ordinary-Up refusal and recursive recovery cases.
A Chain interpreter case now checks the reached and unresolved lists, including the failed node's projected
key and exclusion of a later node; its focused validation passed on WSL2.
The Chain already rethrows the original callback exception after settlement. The CLI safety-refusal case now
pairs an acquired step followed by either an ordinary failure or a `SafetyRefusal`, checking forward and
reverse calls and the safety marker; its focused validation passed on WSL2.
Harness failed-Up now treats a core-managed reverse as acquired work deferred to its reverse owner, and the
Haddocks have been moved to their actual functions. A Harness case invokes the real CLI with a synthetic
cluster step followed by failure and checks the persisted unwind row. The focused Harness case passed on WSL2;
its expected later reverse refusal refers to the deliberately absent synthetic cluster ownership record, and
the fixture's temporary authority store was removed with its temporary directory.
The single-frame cleanup-failure case now also checks the failing step's identity, and source guards pin the
catalog and catalog-free error propagation and retained state. The `failed-Up` selection passed all eight
cases, and the two single-frame CLI cases passed with the failing-step assertion. The source guard has since
been extended to name broker and unwind failures separately; all eight cases in its final focused selection
passed on WSL2. The 17.54 failed-Up fixture now gives its failing container step no declared reverse while
its previously reached reversible steps still unwind; the process case passed with distinct canonical
forward-failed and reverse-completed reports read from the protected store. The related four-case `failed up`
selection passed again after that fixture change.
The first complete sprint gate was stopped after review found that the composition document still described
separate route selectors. The composition and lifecycle documents now describe the shared selector, root-failure
attribution, Up teardown join, and Harness deferral; the complete gate must run against this aligned tree.
The documentation validator passed all 22 focused cases after those corrections.
The next complete core run failed one of 5,505 cases after 921.88 seconds: the Handoff codec ownership
inventory did not include the coordinator's new `eliminateLifecycleReport` use. The inventory has been
updated to name that actual caller, and its focused rerun passed on WSL2; the complete gate was then rerun.
On 2026-11-15, the corrected `cabal test all --ghc-options=-Werror --test-option=--hide-successes` run passed
all 5,505 core tests in 933.16 seconds on the dedicated WSL2 linux-cpu instance. The provider-live component
passed its declared unsupported result because native Linux/KVM/Incus was not requested on this host.

#### Remaining Work

None.

### Sprint 17.54: Process cancellation and unresolved-operation snapshots [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`,
`core/hostbootstrap-core/test/Spec.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`,
`documents/engineering/composition_patterns.md`

#### Objective

Prove local process cleanup and retain exact unresolved-operation coordinates for safe recovery.

#### Deliverables

- One local root/VM/container fixture exercises forward, Down, Destroy, and failed-Up unwind.
- Tests use real child processes, duplex pipes, installed root identity, the root store, and public command gate.
- Each fixture installs the compiled binary, fresh identities, sibling config, and project tree under one
  temporary anchor. Native compiled clients forward the private protocol pipes to that binary.
- Every case remains present on every host. The POSIX row runs the recursive transitions; where that row
  is unavailable, the case asserts its declared refusal and the real receiver's rejection of the different
  native canonical root. The coverage manifest declares the group's cases and its POSIX row cases
  (`familyCases` and `familyRowCases`, 29 and 26 in the tree) without counting a refusal as guest
  execution.
- The `incus` and `docker` names on the fixture's `PATH` are copies of the test executable that relay the
  private protocol pipes and record their argv. The group is a process-transport fixture, and its name and
  manifest `familyPath` say so; it is not evidence of a provider crossing (§ NN).
- Each reverse case asserts the cross-process effect order, not only the exit code: the fixture's
  `reverse-attempts` file shows child-first order, and a repeated verb adds no row.
- Real-process cases prove a child crash mid-exchange, an operator interrupt of the root, and partial failure.
  In each, the root exits non-zero and no fixture child process outlives the command. A following reverse
  verb converges when the effect is settled; an interrupted unknown effect requires verified recovery.
  Scope, catalog, session, frame, node, key, nonce, ordinal and digest mismatch refusals are
  proven at the kernels that own them (Sprints 17.32 to 17.42 and 17.49), not through this fixture.
- The private child converts POSIX termination into owner interruption to unwind nested process groups.
  Reverse admission preflights the recursive catalog before frame recovery. A read-only unresolved-operation
  snapshot retains exact protected coordinates without granting recovery or mutation authority.

#### Validation

Run `cabal test all --ghc-options=-Werror` from `core/`. The named recursive-lifecycle group must execute real
local process fixtures on linux-cpu; record dated counts and source/compile-fail evidence after the gate passes.
The sprint closes when the cases named in Remaining Work exist and pass on the POSIX row. The focused
`SessionSpec` "unresolved manifest observations retain exact protected operation coordinates" checks the exact
coordinates and unchanged refusal without store mutation. On 2026-11-15 the focused case passed on WSL2 in 0.11 seconds after warning-clean compilation.

On 2026-08-21, the five-case `RecursiveLifecycleSpec` group passed on x86_64 Linux through the public command
gate and real root/VM/container child processes, covering forward Up, child-first Down and Destroy, failed-Up
propagation and reached cleanup, and the proof-matrix guard. The complete warning-clean core suite passed at
2,314 tests, while the Python code check and all 231 Python tests also passed.

On 2026-08-23, the six-case group passed with the failed-Up immediate reverse-recovery case included; the
complete warning-clean core suite passed 2,442/2,442 in 179.14 seconds.

On 2026-09-05, `cabal test all --ghc-options=-Werror` passed all 2,483 tests in 142.11 seconds
on native x86_64 Linux (GHC 9.12.4, Cabal 3.16.1.0). The seven recursive cases use compiled
clients and a temporary installed identity; the shared case manifest accounts for five POSIX guest-frame
cases on every host. The recursive/manifest selection passed 23/23 on native macOS arm64 in 26.87 seconds
and native Windows x86_64 in 11.45 seconds; Windows asserts the declared row refusal and the real receiver
digest refusal. The shebang guard exercises both an extension-bearing script and an extensionless script
in its negative fixture. The ownership replacement fixture retains the original object and independently
checks that the replacement has a different kernel identity; ownership/documentation checks passed 28/28
on macOS. Python checks and all 231 tests passed on both native Linux and Windows.

On 2026-11-15, the focused failed-Up process case passed on WSL2. Its failed container step had no declared
reverse; the reached VM and root reverses each ran once in child-first order, and the protected store held
distinct canonical forward-failed and reverse-completed reports. The rest of this sprint's evidence is due.
The public Destroy and repeated Down/Destroy cases now inspect the exact reverse-attempt sequence and check
that repeated commands append no work. Both `public down` cases passed on WSL2, including the repeated
Down/Destroy sequence; the standalone public Destroy case also passed. The recursive group run on the next
assertions passed 28 of 29 cases; an over-broad assertion change made the empty-refusal case fail. Its
original check has been restored and a rerun is owed. The new root-interruption fixture reached the container
but failed: after SIGINT the root exited while its nested container child remained alive beyond five seconds.
The leaked test processes were stopped. The child-crash fixture then passed its focused run: the container
child exited with status 9 after a settlement response, the root failed within the bound, the recorded child
was gone, and a subsequent Destroy succeeded. The lifecycle child entry now converts POSIX SIGTERM into an
asynchronous exception in its owner so its scoped nested groups can unwind. The focused interruption rerun
confirmed the container child was reaped and no failed-Up reverse ran, but its following Destroy refused the
container operation at `EffectOutcomeUnknown`. The interim case checks refusal and no reverse callback; the
required successful Destroy still owes a safe way to resolve the unknown outcome and a passing run. Its first
group build exposed a shadowed fixture environment binding under `-Werror`; the binding was removed. The next
recursive group run passed 30 of 31 cases: the interruption case confirmed refusal, but its whole-store
equality check found mutation; the refusal advanced several root and earlier-frame recovery records before
detecting the unknown container operation. The reverse-entry recovery now preflights every catalog plan before
fencing any frame. The focused rerun still failed whole-store equality: two child-frame fences no longer
advanced, but root admission had already changed its own fence, session, cursor, lease and related records
before the recursive preflight. Earlier admission must be examined; successful Destroy remains due. The 30
passing cases included the exact reverse-failure attempt, both forward frame markers, both exact proxy
argument vectors, and response rejection under a different nonce. On 2026-11-15 the complete recursive
selection then passed all 31 cases on WSL2 in 35.46 seconds, including the interim unknown-effect refusal and
the process cleanup assertion; that refusal does not satisfy the successful Destroy requirement. The focused
`DocValidatorSpec` selection also passed all 22 cases on WSL2 in 27.52 seconds. The `reverse-root` selection
passed all 17 cases in 14.46 seconds on the same host. The interim interruption test now also checks each
recorded child-frame fence for unchanged bytes and version; its first focused rerun failed to find the
sessions because it matched encoded record-key spellings in session payloads. After correcting the match, the
focused case passed on WSL2 in 0.84 seconds, proving the recorded child-frame fence versions and bytes remain
unchanged on refusal. The focused child-process owner test passed on WSL2 in 1.57 seconds. A verified recovery
path must bind a fresh outcome to the exact plan, operation, session and protected record version, and fence
delayed effects before treating a proven absence as `EffectAbsent`; absent, foreign, stale or inconclusive
evidence must continue to refuse. The current step descriptor supplies no such observer. On 2026-11-15 `cabal test all --ghc-options=-Werror --test-option=--hide-successes` on WSL2 passed all 5,507 core tests in 963.80 seconds; provider-live reported its declared not-requested result. This is interim regression evidence from before the snapshot change. On 2026-11-15 the updated plan passed all 22 `DocValidatorSpec` cases in 27.80 seconds on WSL2; the current sprint gate is due.

On 2026-11-15, `cabal test all --ghc-options=-Werror --test-option=--hide-successes` passed all
5,508 core tests in 946.45 seconds on the dedicated C: WSL2 Linux substrate. The 31-case recursive selection
includes 26 POSIX-row cases executing their process transitions; the manifest accounts for the remaining
cases separately. The provider-live component reported its declared not-requested result. The exact
unresolved-operation snapshot and its unchanged refusal passed, as did the combined recursive,
unknown-phase and sealed-export selection (62 cases). Successful Destroy after an unknown effect remains
scheduled in this phase's bounded recovery work.

#### Objective boundary

Consuming root `DestroySettled` as `ProjectClosureEvidence SettledDestroyClose` also requires the bound run
lease and the all-sessions-closed proof, and recovery beyond the retained live plan belongs to the
[recovery phase](phase-18-recovery-and-migration.md). This sprint's gate is the host-static real-process
one and nothing beyond it.

#### Remaining Work

None.

### Sprint 17.54a: Bind a recovery observer to a step [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/StepSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`

#### Objective

Give a retained step an exact-frame, read-only recovery observer without treating a raw callback result as
settlement authority.

#### Deliverables

- A `RecoveryObserver` carries a non-empty identity, a positive revision, a `DelayedEffectGuarantee` and a check
  that receives only the step's operation key and frame, never an execution, gate, store or reverse authority, so
  it cannot perform an effect or mint settlement. `observesRecoveryWith` attaches at most one per step.
- `observeStepRecovery` runs it for the step's own operation and frame and returns a `BoundRecoveryObservation`
  naming that operation, frame, identity and revision, or `Nothing` for a step without an observer, which stays
  unresolved. An absence from an observer that declares `DelayedEffectPossible`, as ordinary process exit would,
  and any exception the check raises, are `RecoveryInconclusive`.
- `admitRecoveryObservation` yields the result only against the admitted step that declares the same observer:
  another operation or frame is foreign, another identity or revision is stale, and a step without an observer
  admits nothing.
- The observer's identity and revision are part of the canonical step record, so the admitted plan binds them;
  the step record now carries 20 fields with its `recovery-observers` list.

#### Validation

- `StepSpec` "recovery observers": an observer sees exactly its own operation and frame and binds its result to
  them; a step without an observer stays unresolved and admits nothing; an observation from another operation, from
  another frame, from a newer revision and from another observer each refuse exactly; absence is usable only when
  the mechanism rules out a delayed effect, and a raising observer is inconclusive; an unnamed observer and a zero
  revision are refused.
- `ProjectPlanSpec` "a recovery observer's identity and revision are bound by the admitted plan": the revision and
  the declaration itself change the plan digest, and the persisted snapshot re-admits. The golden canonical bytes,
  the `LifecycleSpec` canonical-mutation cases and the sealed export inventory are updated.

2026-11-21, native Windows 11 Pro 10.0.26300 x86_64, GHC 9.12.4: the observer, `StepSpec`, golden, canonical,
snapshot, sealed export and document validator selection passed 447 cases. The complete `core/` leg passed all
5,615 tests in 821.77 seconds and the `demo/` leg 177 demo and 5,615 core tests; `check_code` passed and
`test_all` passed 384 tests.

#### Remaining Work

None.

### Sprint 17.54b: Transport the recovery observation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Obtain the admitted observer's result in the operation's own child frame before reverse admission.

#### Deliverables

- Split into Sprint 17.54b1 and Sprint 17.54b2 under § G.

#### Validation

On 2026-11-21 the transport was designed without a new request family. A seventh rooted request would change the
closed request and response matrix, its eliminator's fifteen call sites across eight production modules, and the
guards that freeze both. The authenticated exchange already carries typed bodies: the root's `prepared` answer
carries a gate package, and a `SettleNode` body carries a domain-prefixed observation, as the forward descent result
does. The root therefore asks through a recovery-observe envelope around the exact gate package, and the child
answers with a canonical recovery-observation record in its settle body; the request's own path, session, stage,
ordinal, nonce and predecessor bind the catalog, frame, session and request identity, and the record binds the
operation, record version, attempt, observer identity and revision, and the result. Sprint 17.54b1 owns that wire;
Sprint 17.54b2 owns the child and root call sites and the process-boundary cases.

#### Remaining Work

None.

### Sprint 17.54b1: Recovery observation wire [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Give the recovery exchange one canonical ask and one canonical answer inside the existing rooted request families.

#### Deliverables

- A recovery-observe envelope around one exact prepared gate package, and a canonical recovery-observation record
  naming the operation, record version, attempt, observer identity and revision, and a closed result; both decode
  strictly, are bounded, and refuse trailing, foreign-domain, malformed and noncanonical bytes.
- Admission of a record against an expected operation, record version, attempt, identity and revision refuses any
  mismatch; nothing here settles an operation.

#### Validation

- `renderRecoveryObserveEnvelopeKernel` wraps only a valid fenced gate package and
  `readRecoveryObserveEnvelopeKernel` recovers it, refusing trailing, truncated, foreign-domain, unfenced and
  extra-field bytes.
- `renderRootedRecoveryObservationKernel` and `readRootedRecoveryObservationKernel` round-trip every closed result
  (absent, present, foreign, inconclusive) with byte-exact framing, and refuse trailing bytes, a foreign domain, a
  missing field, a zero record version, a noncanonical attempt width, detail on an absence, an empty presence
  identity, an unknown result and a non-UTF-8 observer; a zero revision cannot be rendered.
- `admitRootedRecoveryObservationKernel` returns the result only for the exact operation, record version, attempt,
  observer and revision, and refuses each mismatch with its exact reason.

The cases sit in the existing `ProjectPlanSpec` "prepared gate codecs round-trip and reject malformed fields", beside
the reverse gate envelope cases whose fenced and unfenced fixtures they reuse, rather than in `HandoffSpec`; the
`HandoffSpec` export pin names the seven new exports. 2026-11-21, native Windows 11 Pro 10.0.26300 x86_64, GHC
9.12.4: the gate codec and `HandoffSpec` selection passed 244 cases. The first complete `core/` and `demo/` legs
each failed only "the storeless frame executor holds coordinates, never authority", which counts the uses of
`readFencedPreparedGatePackageKernel`; the observe envelope validates its wrapped gate as the reverse envelope
does, and the pinned count for `Handoff.Rooted` rose from two to three. The repeated `core/` leg passed all 5,615
tests in 797.65 seconds and the `demo/` leg 177 demo and 5,615 core tests; `check_code` passed and `test_all` passed
384 tests.

#### Remaining Work

None.

### Sprint 17.54b2: Exchange the recovery observation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Obtain the admitted observer's result in the operation's own child frame before reverse admission.

#### Deliverables

- Split into Sprints 17.54b2a, 17.54b2b and 17.54b2c under § G.

#### Validation

On 2026-11-21 the call sites were traced before implementation. A restarted Destroy reaches an interrupted
operation through `withRecoveredReverseEntrySessions` (`LifecycleEntry`), whose `preflightPlans` runs
`verifyNoUnknownSessionOperations` over the whole recursive catalog before fencing any frame and refuses on the first
unknown phase; `Lifecycle/Mode.hs` runs the same preflight at three further recovery entries. The existing reverse
launch reaches a child only through a prepared reverse descent inside a fenced, recovered session, so it cannot be
used to observe before that preflight. The observation therefore needs its own observation-only launch, run before
the preflight, in which the child executes only its retained observer; the preflight then admits an unresolved
operation only through a recorded, admitted observation, which Sprint 17.54c settles. The work spans the root entry,
the recovery preflights in `Mode.hs`, the child, and the frame executor, beyond § G's three-module budget.

#### Remaining Work

None.

### Sprint 17.54b2a: Ship the recovery observation to the operation's frame [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Let the root obtain one unresolved operation's observation from that operation's own frame without a rooted session,
a fence, or any effect, so it can happen before the recovery preflight.

#### Deliverables

- A closed shipped recovery-observation act, like the shipped cluster-object observation, carries the plan digest,
  frame, operation, record version, attempt, observer identity and revision, and the frame's canonical child config.
  The project binary's frame interpreter re-admits the plan from its own finalized spec and that config, requires the
  digest, frame and step to match and the step's observer to have the expected identity and revision, runs only that
  observer, and answers with the canonical recovery-observation record. It never runs the step's action or reverse
  effect and opens no protected store.
- A lost response or a failed observer leaves the operation unresolved.

#### Validation

Exercise the act's decode and refusals, and across a real frame child a matching observation and foreign or stale
coordinates, asserting no effect runs. Run the host static gate.

Progress on 2026-11-21:

- `RecoveryObservationRequest` (`Handoff.Rooted`) is the shipped act: profile, profile epoch, installed project,
  store identity, plan digest, frame, operation, record version, attempt, observer identity and revision, and the
  frame's canonical child config, under its own domain. It renders and decodes strictly and canonically, refuses
  trailing, truncated and foreign-domain bytes, an empty config and zero coordinates, and
  `isRecoveryObservationRequestKernel` lets every other act fall through.
- `interpretShippedRecoveryObservation` (`Command.Child`) decodes the act, requires the config to be strict UTF-8 and
  canonical for the installed codec, re-admits the plan through `withChildProjectPlanKernel` under the act's
  coordinates (so another digest refuses), and requires the local frame, the single admitted operation in that frame,
  and the step's observer identity and revision to match before running only that observer; it answers with the
  canonical recovery-observation record. `CLI.hs` registers it ahead of the closed core acts as
  `interpretProjectFrameTransaction`.
- The act's codec cases sit in `ProjectPlanSpec` "prepared gate codecs round-trip and reject malformed fields"; the
  `HandoffSpec` export and frame-child dispatch pins and the `Command.Child` export pin name the new surface. The
  affected selection passed 406 cases on native Windows.

- `CLISpec` "the shipped recovery observation runs only the exact admitted step's observer" builds a real finalized
  fixture project whose host step declares an observer, re-admits its exact plan, and drives the act through
  `HostBootstrap.CLI.interpretProjectFrameTransaction`, the interpreter the project binary runs, now exported beside
  `interpretFrameTransaction`. The exact act runs the observer once, for that operation and frame, and returns the
  canonical record; a foreign frame, operation and plan digest, another observer and a stale revision each refuse with
  their exact reason; the step's effect never runs; and an ownership act still falls through to the core
  interpreters. The interpreter stays in `Command.Child`, because the plan-construction functions it uses live in the
  main library; `CLISpec` therefore joins the registered `Handoff.Rooted` test importers, and the sealed export
  inventory names the new `CLI` export.

The first complete `core/` and `demo/` legs each failed the sealed export pin for `HostBootstrap.CLI` and the
registered `Handoff.Rooted` test importers, both naming the new surface above; once pinned, the repeated `core/` leg
passed all 5,616 tests in 824.83 seconds and the `demo/` leg 177 demo and 5,616 core tests; `check_code` passed and
`test_all` passed 384 tests.

#### Remaining Work

None.

On 2026-11-21 the earlier plan, an observation-only grant inside a rooted frame session, was replaced: opening a
rooted session for the child first fences the abandoned session, which the recovery preflight withholds while an
operation's effect is unknown. A shipped frame transaction needs neither.

### Sprint 17.54b2b: Admit observations before the recovery preflight [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Before `withRecoveredReverseEntrySessions` preflights the catalog, observe each unresolved operation whose admitted
step declares an observer, and record only an admitted observation for Sprint 17.54c to settle.

#### Deliverables

- The root selects unresolved operations from its own store and plan, launches the observation-only exchange for each
  that has an observer, and admits the record against the exact operation, record version, attempt, observer
  identity and revision; an operation without an observer keeps the existing refusal.

#### Validation

Exercise selection, admission and refusal against real-store unresolved operations, and run the host static gate.

Progress on 2026-11-21:

- `withRecoveredReverseEntrySessions` now receives the root's `HostConfig` and `SelfRef` (threaded through
  `withRootProjectReverseLifecycleEntry` from `runProductionTeardown`) and, before `preflightPlans`, reads each plan's
  unresolved rows in its own protected entry (`findUnresolvedSessionOperations`, under the allocated broker epoch).
  For a row whose admitted step declares an observer in that plan's frame (`plannedRecoveryObserverKernel`) and whose
  record names a version and attempt (`unresolvedOperationAttempt`), the root asks the observer: in the root's own
  frame by running it in-process, and in a descended frame by shipping `RecoveryObservationRequest` with
  `withFrameChildTransaction` along its composed route from the root frame under the catalog's canonical child config.
  `rootedPlanCatalogChildRoutesKernel` (`Lifecycle/RootedPlan.hs`) composes that route root-first from the stripped
  edges of the frame's whole ancestry, refusing edges that do not chain from the root frame, so a frame below the
  root's immediate child is reached through every frame above it and never along its single parent edge. Every answer
  is admitted through `admitRootedRecoveryObservationKernel` against the exact operation, version, attempt, observer
  identity and revision; a lost, raised, malformed or foreign answer is dropped and the row stays unresolved.
- Only an admitted answer is kept, keyed by plan digest and operation. The preflight still refuses every unknown
  phase, settlement being Sprint 17.54c's, and `describeUnresolvedRefusal` names the admitted answer in that
  operation's own refusal; another plan's or operation's answer leaves a refusal bare.
- `SessionSpec` "a recovery observation names the unresolved row's attempt and only annotates its own refusal"
  drives a real-store `EffectOutcomeUnknown` row: its attempt, its bare refusal, and the annotation only for its own
  plan and operation, with the store unchanged. `ProjectPlanSpec` "a recovery observer's identity and revision are
  bound by the admitted plan" now also checks `plannedRecoveryObserverKernel`'s frame, identity and revision, and none
  for an unobserved step or unknown operation. The reverse-entry and sealed-export pins name the new arguments and
  exports.

`lifecycle_state_model.md` describes the observation before the preflight. On 2026-11-22, over the tree that composes
each descended frame's route from the root, the native Windows `core/` leg passed all 5,621 tests in 854.51 seconds,
the `demo/` leg passed 177 demo and 5,621 core tests, `check_code` passed, and `test_all` passed 384 tests. The
linux-cpu `core/` leg passed all 5,621 tests in 6,740.19 seconds (05:02:16Z to 07:35:53Z). The process-boundary exercise of the shipped observation inside a real restarted
Destroy moves to Sprint 17.54c, whose settlement makes it observable end to end.

#### Remaining Work

None.

### Sprint 17.54b2c: Observation-aware recovery preflights [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Make the three `Mode.hs` recovery preflights agree with the root entry: an unresolved operation passes only through
its settled observation, and every other unknown phase still refuses.

#### Deliverables

- One shared preflight, used by the root entry and the three `Mode.hs` entries, refuses any unknown phase without a
  settled observation.

#### Validation

Exercise each entry's refusal and admission and run the host static gate.

Progress on 2026-11-21: tracing the four recovery entries showed they already share one preflight. The root reverse
entry's `preflightPlans` and the three `Mode.hs` entries (`settleAndAdmit` behind migration activation and
`withAbandonedHarnessRun`, `verifyRootOutcomeRecovery`, and `readRootReverseOutcomeKernel`'s reverse-receipt read)
each call `verifyNoUnknownSessionOperations`, and none classifies a recorded phase itself. A settled observation is a
recorded phase (Sprint 17.54c records it), which moves the row out of `UnknownDisposition`; the same preflight then
admits it, and every other unknown phase still refuses. No new preflight was needed, so the sprint pins and exercises
the shared one:

- `ProjectPlanSpec` "every recovery entry shares the one unknown-phase preflight" pins the one call per entry, that only
  the root's observation step reads unresolved rows, that no entry calls `classifyRecordedPhase`, and the root's order:
  observe, then the refusing preflight, then the per-plan recovery.
- `SessionSpec` "the shared recovery preflight admits an interrupted row only once its own outcome is recorded" drives
  a real-store `EffectOutcomeUnknown` row: the preflight refuses it, and after its own `EffectAbsent` outcome is
  recorded and the store reopened, the same preflight admits and no unresolved row remains.

The behavioural exercise of each `Mode.hs` entry over a settled observation belongs to Sprint 17.54c's restarted
Destroy, the first path that produces one.

On native Windows the `core/` leg passed all 5,619 tests in 810.11 seconds and the `demo/` leg 177 demo and 5,619
core tests; `check_code` passed and `test_all` passed 384 tests.

#### Remaining Work

None.
### Sprint 17.54c: Settle observed recovery and complete Destroy [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`, `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Settle only an exact, freshly observed and fenced interrupted operation, then finish the requested Destroy.

#### Deliverables

- Under the protected entry, recheck the exact unresolved record version and bytes, admitted operation,
  session, current broker and fence before recording a supported observation. Stale, foreign, incomplete,
  unrecognised and inconclusive evidence refuses without settling the operation.
- After a proven absence and the required fence, the existing recorded-session interpreter can close the
  interrupted session and resume child-first Destroy. Managed presence follows its own exact ownership proof.
- The root SIGINT fixture blocks the container step, proves all children reaped and no failed-Up unwind,
  then proves a subsequent `destroy` exits 0 after the fixture's verified absence observation.

#### Validation

Add `SessionSpec` cases for exact settlement, stale record and fence, wrong operation, foreign and unknown
observations, and crash/replay. Run the recursive SIGINT case and `cabal test all --ghc-options=-Werror`
from `core/` on linux-cpu, recording the recursive group count and POSIX-row execution.

Progress on 2026-11-21:

- `recordRecoveryObservation` (`Session.hs`) records an admitted absence over the exact snapshot only. The
  manifest must still list the operation in an open session, the record must keep the snapshot's version and
  bytes, the attempt must be the observed one, and the live fence must be the row's own. Its successor is the
  family's fenced-retryable absence (`EffectAbsent`, `ReservationAbsent`, `AdoptionObservedAbsent`) at the same
  session, fence and attempt. Managed presence, a foreign effect, an inconclusive answer, and repair,
  managed-phase and teardown rows (whose absences are terminal or mean release) refuse without writing. The
  no-delayed-effect requirement holds: `observeStepRecovery` already turns an absence from an observer that
  allows a delayed effect into an inconclusive answer.
- The root reverse entry settles each admitted answer in a fresh protected entry under the current broker,
  before the shared preflight. A settled row is no longer unknown, so the preflight admits it and
  `recoverPlan`'s recorded-session interpreter abandons it under its new fence; an unsettled answer is named in
  that operation's refusal.
- The recursive fixture's container step declares `fixture-container-observer`. It answers absent only when the
  fixture sets `HOSTBOOTSTRAP_RECURSIVE_OBSERVE_ABSENT=1`, and is otherwise inconclusive. The fixture's fake
  `incus`/`docker` client now forwards a shipped frame transaction to the fixture project's own frame child
  (`runLifecycleFrameChild`), exactly as a project binary dispatches it.
- `SessionSpec` "a recorded recovery absence settles only the exact row, once, and recovery then abandons it"
  covers four refusals without a write: another attempt, managed presence, a foreign effect and an inconclusive
  answer. It then covers the exact settlement, the cleared preflight, a crash/replay of the same snapshot
  refusing as stale with the store unchanged, and the interpreter's `OperationAbandonedRetryable "op-1"
  "EffectAbsent"`. "a recovery absence observed under a superseded fence is not recorded" covers the fence. A
  wrong operation cannot be forged as a snapshot, because `UnresolvedOperation` has no exported constructor; it
  is refused at admission by `admitRootedRecoveryObservationKernel`, whose cases are in `ProjectPlanSpec`.
- `RecursiveLifecycleSpec` "an interrupted root aborts and reaps its children" now finishes the story. After the
  SIGINT, the reaped children, the absent failed-Up unwind, and the unverified `destroy` refusing with its store
  unchanged, a second `destroy` run with the verified absence exits 0, and no operation remains outcome-unknown.
  On the Linux VM a focused run of the recursive group and the settlement cases passed 35 tests. The built test
  binary run visibly showed the case executing its three root processes in 1.15 seconds, rather than taking the
  conditional path.

On 2026-11-22 the complete `core/` leg ran on the linux-cpu VM (the live Windows checkout over sshfs, VM-local build
directory) from 05:02:16Z to 07:35:53Z and passed all 5,621 tests in 6,740.19 seconds. `-Werror` is carried by the
package's `common warnings` stanza. There the POSIX row holds, so the recursive process-transport family
(`CoverageManifest`: 31 cases, 28 on the POSIX row) and its `root-settlement-interruption` group executed rather than
asserting their refusal. A focused linux-cpu run of that family and the settlement cases (35 tests) passed before it.
The SIGINT case also asserts the fixture's recorded crossings: the container's shipped observation crossed `incus`
with `docker` nested inside it, and no frame child was reached along a bare `docker` edge. On native Windows the
`core/` leg passed 5,621 tests in 854.51 seconds, and the `demo/` leg 177 demo and 5,621 core tests. `check_code`
passed, and `test_all` passed 384 tests.

#### Remaining Work

None.

### Sprint 17.55: Protected fresh Harness invocation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Snapshot.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Mode`, `HostBootstrap.ProjectPlan.Snapshot`,
`HostBootstrap.Command` (3; cap 3)
**Sprint budget**: one fresh-invocation contract and one command call-site adoption; at most 400 production
Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Move one live Harness run from an intermediate settled destroy to a strictly fresh invocation generation while
retaining its run identity, generated config, durable root, and immutable canonical plan snapshot.

#### Deliverables

- `withFreshHarnessInvocationFrom` requires the exact live Harness root, held bound lease, and settled-destroy
  closure evidence bound to that source generation, and verifies the operator and the root before it
  allocates a fresh broker epoch or writes anything.
- The transition advances mode and bound lease to that epoch, rearms the one-use lifecycle profile, and yields
  only a fresh root/mode/bound/profile/close-root tuple under a rank-2 generation; its destroy-only twin
  `withFreshHarnessDestroyInvocation` rearms the profile slot for the profile it hands out.
- `withRestartedBoundPlanSnapshot` compares exact project/store/spec/plan/config/canonical bytes and the bound
  lease's epoch, location, and profile mode, and binds a freshly re-admitted local plan identity without
  mutating the persisted snapshot.
- The command performs intermediate exact reverse without terminal close, rotates, rebuilds the exact plan and
  lifecycle context, rebinds the snapshot, runs the second forward, and retains the fresh final reverse.
- A command-level fixture proves two variants each execute forward/reverse twice, observe both assertion phases,
  and terminally close with no generated config left behind.

#### Validation

Run warning-clean build, focused `CLISpec` restart case, `HarnessSpec`, and the complete core gate.

On 2026-08-24 the warning-clean build, protected command-level same-run fixture, focused 45-case Harness
gate, and complete 2,454/2,454 core host-static gate passed.

The sprint closes when the focused Harness, closure, and snapshot cases pass, followed by the warning-clean
core gate and all four host-static commands.

On 2026-11-15 the callerless rotation wrapper was removed. Settled closure evidence now retains its source
broker epoch and bound-lease version; fresh Up checks those coordinates before writes. Both rotation paths
precheck the operator and existing root, distinguish another mode from an epoch mismatch, and rearm the
profile slot. The restarted snapshot now checks its bound lease and plan origins. The restart fixture records
run, plan and broker epoch at each assertion, and the authority fixture checks pre-effect refusal without
store mutation. On 2026-11-15 the updated `CLISpec` restart case passed on dedicated WSL2 in 0.83 seconds: both variants retained their run and plan across restart and advanced their broker epochs. A 50-case combined pre-effect refusal, sealed-export and documentation selection passed 49 cases; the documentation validator found two stale mentions of the removed wrapper. The architecture document now names the surviving entry; the same 50-case selection passed in 30.97 seconds. A POSIX-row test now makes the records directory read-only before a Destroy restart and requires operator refusal with an unchanged protected store; the combined focused selection passed all 52 cases in 31.11 seconds on WSL2. A further case now constructs a settled-Destroy proof from an admitted Harness plan and real teardown forest, rotates the lease, then presents that proof to the next generation. The first focused build found a root scope created outside the generative Harness continuation and a session error-type mismatch; those errors and a discarded nested action were corrected. The genuine stale-generation case then passed on WSL2 in 0.09 seconds, with the protected store unchanged. The same genuine Harness fixture now also presents the old plan after rotation: the plan-epoch backstop refused it with `ModeEvidenceMismatch`, and the protected store stayed unchanged. The extended case passed in 0.11 seconds. It now also admits a genuinely different plan and a root from another protected store; both were refused with their exact `ModeEvidenceMismatch` subjects, and the extended case passed again in 0.11 seconds on WSL2. Further controls presented a genuine old root and a genuine old lease across the generation boundary, using casts only to exercise the runtime backstops; both refused `root epoch` without protected-store changes. The extended case passed in 0.12 seconds. Both fresh-Up and fresh-Destroy rotation were then presented with a different held mode; each returned the exact `ModeHeldByAnother` and left the seeded records unchanged. The extended case passed again in 0.12 seconds. It also seeded the same Harness mode at a different epoch; both rotation paths returned the exact `ModeEpochMismatch` without changing the seeded state, and the case passed again in 0.12 seconds. The two-case selection then passed in 0.20 seconds on WSL2, including actual read-only-records operator refusal on both Up and Destroy and foreign-profile and foreign-lease refusals. The same controls now also verify the successful Destroy rotation writes a profile slot bound to its new epoch and lease version; the two-case selection passed again in 0.22 seconds. The added project and store drift controls first failed to compile because their root-store projection was not imported; the import was added. The two-case selection passed in 0.22 seconds on WSL2, covering root and lease project/store, root and lease epoch, and plan project/store/profile/epoch drift with exact refusal subjects.

On 2026-11-15 the combined Harness, restart, authority, sealed-export and documentation selection passed
all 104 cases in 37.36 seconds on WSL2, including terminal-close refusal of stale settled evidence. The
Windows host Python code checks passed, and all 384 Python tests passed with 100% reported coverage.

On 2026-11-15 the dedicated linux-cpu WSL2 instance passed `cabal test all --ghc-options=-Werror
--test-option=--hide-successes` from `core/` and `cabal test all` from `demo/`. The latter's core suite
passed all 5,511 cases in 943.84 seconds. The provider-live component reported its declared no-request result.

#### Remaining Work

None.


### Sprint 17.56: Stable released-resource successor [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/ResourceRecord.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`, `core/hostbootstrap-core/test/ChainSpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.ResourceRecord`, `HostBootstrap.Chain` (2; cap 3)
**Sprint budget**: no new public named type and one exact stable-member transition; at most 120 production
Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/durable_state.md`

#### Objective

Admit reacquisition after intermediate destroy without weakening stable resource members into arbitrary
replacement.

#### Deliverables

- A predecessor and successor are both parsed as canonical resource records.
- Plan, frame, and resource coordinate must be identical; predecessor must be Released and successor Owned.
- The successor ownership generation must be strictly greater than the released generation.
- `Chain` performs the replacement with exact record-version compare-and-swap; owned predecessors, malformed
  bytes, changed coordinates, and non-advancing generations remain conflicts before journal commit.

#### Validation

`ChainSpec` proves the accepted released-to-owned successor and refusal of a non-advancing generation alongside
the existing arbitrary-conflict gate; run the complete core gate.

#### Remaining Work

None. On 2026-08-24 the warning-clean build, focused `ChainSpec` 48/48 gate, and complete 2,454/2,454 core
host-static gate passed.

### Sprint 17.57: Generation-correct Harness close fallback [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/harness-close/HostBootstrap/Harness/Ownership/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`, `core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`
**Production modules**: `HostBootstrap.Harness.Ownership.Internal`,
`HostBootstrap.Harness.Ownership`, `HostBootstrap.Lifecycle.Mode` (3; cap 3)
**Sprint budget**: no new named type and one close-fallback rearm adoption; at most 240 production Haskell
lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Keep the Harness ownership finalizer bound to the current generation after a same-run restart, and
revalidate the exact short-close state inside the protected entry that releases its lease.

#### Deliverables

- The private close control existentially retains a matching close-root/mode/bound tuple rather than erasing
  the generation join or retaining only the source-generation bound lease.
- Initial binding arms the source tuple; a fresh invocation may rearm only the existing bound fallback with its
  new tuple.
- Pre-effect finalization verifies no project resource was acquired under that exact current bound lease and
  closes with the matching current root and mode. Settled terminal authorization remains generation-erased only
  after the protected kernel has validated the current tuple.
- A retained no-effect proof cannot close a run after resource effects or an open session appear. The
  short close rechecks the exact lease, current effect records, and complete session set before mutation;
  refusal retains lease and mode for recovery.
- Binding, pending, settled, and consumed states keep their existing fail-closed monotonicity.

#### Validation

The command-level same-run fixture exercises the rearmed fallback and final settled close; source guards retain
the control behind the private component. `AuthoritySpec` exercises a retained proof against a subsequently
opened session and a subsequently recorded effect, and verifies the refused close preserves ownership.

The 2026-09-16 Windows live attempt reports an open operation session after an image-import failure while
its run lease is closed. Both regressions fail against that implementation because the short close returns
success. With the protected recheck, both pass on native Windows in 0.09 seconds and the broader
`AuthoritySpec` run passes. Fourmolu accepts both changed modules and HLint reports no hints for the
changed production module. The complete native Windows host static gate passes on the host the header
names: core build plus 2,543/2,543 tests in 413.56 seconds; demo build, focused 151/151 tests in
5.52 seconds, and the complete demo workspace at 151/151 plus 2,543/2,543 core cases in 439.78 seconds;
the Python code check and 251/251 Python tests in 6.42 seconds. The combined core build/test command
takes 463.50 seconds; the demo build/focused/full sequence takes 634.09 seconds. Both workspaces
report the provider-live component's declared no-request result. The same source also passes the
complete independent x86_64 Linux gate recorded in Sprint 29.5: 2,548/2,548 core cases in each workspace,
151/151 demo cases, the Python code check, and 251/251 Python tests.

On 2026-11-15 a private close-control component made the state machine reachable to the test suite while
keeping it hidden from downstream packages. A real Harness fixture minted pre-effect and recovered-settled
evidence and terminal authorization. The focused case passed on WSL2, exercising all six control states,
each transition's success or exact refusal, pre-effect settlement refusal, dispatch callbacks and the
settled-recovery short-close refusal with the protected store unchanged.
After adding repeat-consumption checks, the focused case passed again; the combined Harness, documentation,
and recovered-forest selection passed all 75 cases in 38.44 seconds on the dedicated WSL2 instance.
The warning-clean `cabal test all -j4 --ghc-options=-Werror --test-option=--hide-successes` from `core/`
passed all 5,512 cases in 972.45 seconds on that instance; the optional provider-live component reported
its declared no-request result.

#### Remaining Work

None.

### Sprint 17.58: The process route names its interactivity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production modules**: `HostBootstrap.Handoff.Process.Route`, `HostBootstrap.Handoff.Process` (2; cap 3)
**Sprint budget**: one two-case type, three named results, two admitted-text wrappers consumed by the
renderer, and no new behaviour; at most 120 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/run_models.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

The route's closed argument grammar distinguishes an interactive provider invocation from a
noninteractive one, and the distinction travels as an unnamed boolean inside anonymous tuples through
four construction sites. The doctrine spells the distinction out in prose precisely because it matters;
in the code it is the second element of a triple. Alongside it, the path and argument validators return
the same unmarked text they were given, so "this argument passed the grammar" is a property of calling
order rather than of the value.

#### Deliverables

- Interactivity is a two-case type, named at every site that carries it. It records whether the rendered
  shape is the container shape whose argv carries `-i`. Every provider, VM or container, carries the
  protocol on the child's standard input, and the spawn site pipes it for all of them.
- The anonymous tuples threading it become named results.
- A validated path and a validated argument are distinct from unvalidated text, so the closed grammar is a property of the value.
- The argument-vector fixtures continue to pin the exact rendered vector per provider.

#### Validation

The host static gate. The route's argv rendering is pinned by an existing fixture; an unchanged
rendering is the evidence that naming the distinction changed nothing about it.

On 2026-09-12 the route carries `ChannelInteractivity` (`InteractiveChannel` / `NoninteractiveChannel`) at
all four construction sites and the one borrow site. The named results are `AdmittedEdge`,
`AdmittedLaunch`, and `AdmittedLayers`, and the closed grammar yields `ValidatedArgument` and
`ValidatedPath`. The route's source guard pins those declarations, reads the rendered vector fragments,
and holds the one remaining `Bool` to `require`'s own predicate argument. The warning-clean `-Werror` build
and the complete 2,533/2,533 core host-static gate passed.

On 2026-11-15 the route was changed to reconstruct each VM, binary path, image and mount from admitted
values before the shared Lift fold. The process owner now borrows only the tool and argv and pipes stdin
for every provider. The route-focused WSL2 selection passed 65 tests in 40.17 seconds, and passed again in
38.33 seconds after adding a positive argv case for read-only and writable mounts. The Windows Python code
checks and full test command passed, with 100% reported coverage. On the same date the dedicated WSL2
instance passed `cabal test all -j4 --ghc-options=-Werror --test-option=--hide-successes` from both `core/`
and `demo/`; the latter's core suite passed all 5,512 cases in 932.44 seconds. The provider-live component
reported its declared no-request result.

#### Remaining Work

None.

### Sprint 17.59: The descent resolves a provider its own chain just installed [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/HostConfig.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Production modules**: `HostBootstrap.HostConfig`, `HostBootstrap.Handoff.Process` (2; cap 3)
**Sprint budget**: one resolver, one call-site change, and no new type; at most 20 production Haskell
lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/run_models.md`

#### Objective

The worked demo's live gate found this on the one host shape nothing had run it on: a **pristine**
Linux host with no provider installed. `HostConfig` measures every host tool once, at the start of an
invocation, which is what makes every later call read a typed absolute path instead of consulting
`$PATH` (§ K). The chain's own `ensure` step then installs the provider partway through that same
invocation. Each reconciler re-measures locally, so the steps that create and probe the guest work; the
authenticated descent does not, because it resolves the route's host tool through the pure lookup
against the configuration measured before the install.

The observed failure is exact: `project up` built the guest, built the project image inside it, minted
the copy-source witness, and then refused with `authenticated descent refused: lifecycle child process:
the route's host tool resolves to no absolute path` — for the provider that had just created the guest
it was about to descend into. No previously recorded run could reach it. The Windows lane crosses
through WSL, which is present on the host before the run; the Linux GPU lane takes the Direct chain and
descends into a container; and a Linux host that already has Incus installed resolves it at startup.

#### Deliverables

- `HostConfig` gains one resolver that reads the typed configuration first and re-measures the host only
  when the configuration has no entry, so a tool that was present keeps its recorded path.
- Neither branch can produce a bare command name: the re-measure goes through the same discovery that
  answers with an absolute `AbsExe` or with nothing, so § K holds either way.
- The authenticated descent resolves its route's host tool through it.
- One case asserts that the configured path wins, for `Docker`. A second asserts, for every tool in the
  closed set and on whatever gate host runs it, that a tool the configuration lacks resolves to exactly
  what discovery answers, absolute or absent.

#### Validation

The host static gate. Beyond it, the run that found this is the run that confirms it: the
[worked demo](phase-24-worked-demo.md) exercises the descent live on a pristine `linux-cpu` host, and its
2026-09-14 gate records `project up` descending into a guest its own `ensure` step had just made the
provider available for — where the same sequence had refused with
`the route's host tool resolves to no absolute path`.

#### Remaining Work

None. `HostToolSpec` asserts that the configured `Docker` path wins, and that a tool the configuration
predates resolves to exactly what discovery answers, absolute or absent, for every tool in the closed set.

### Sprint 17.60: The reachability step actually reaches [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Teardown`,
`HostBootstrap.Command.LifecycleEntry` (3; cap 3)
**Sprint budget**: one action constructor, one node state, one projection, one named pre-descent handler and
two refusals; at most 120 production Haskell lines and no new type.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

The reverse projection already had the right shape for this: a provider node under `destroy` starts in
`PreDescentPending`, because after a `down` that provider is stopped and its retained children are
unreachable until it is started again. What the root reverse driver did with that step was
`const (pure TeardownReleased)` — it ticked the reachability step without reaching anything, then
descended into a stopped frame.

The worked demo's live gate found it immediately after the descent repair of the previous sprint:
`project up` and `project down` both passed, and `project destroy` refused with
`Error: Instance is not running` and named every in-guest node as unsettled. The step, the state, the
projection and the test that asserts the ordering all existed; only the effect was missing.

#### Deliverables

- A reachability action distinct from stop and delete, produced only by the driver and never by the
  reverse projection's own action table, so no step can declare it.
- The pre-descent step exposes the node's own declared reverse, so the component that knows how to stop
  and delete this provider is the one asked to open it — not a second declaration that could disagree.
- The root reverse entry runs it, and records its failure like any other node's. The failed-Up unwind
  runs the same handler; neither driver answers released for a step that declares a reverse.
- A failed reachability step stays a pre-descent failure. It is offered again only as a pre-descent step,
  and `SettledChildren` is built only when every child node is `Settled`, so a provider's stop or delete is
  never authorized over children that were never reached. A foreign-retained or refused reachability answer
  blocks the subtree the same way, and `nextTeardownWork` never yields `ProgressCompleted` while
  `teardownForestOutstanding` is non-empty, so `CompletedTeardownForest` is proof that every node settled.
- A frame serving its children's reverse, which holds no project callback, refuses loudly instead of
  answering released.

#### Validation

The host static gate. `TeardownSpec` exercises the provider's declared callback through the driver, checks
that a failed, foreign, or refused reachability step blocks descent and retries as pre-descent work, and
checks the nested refusal and exact outstanding rows. The effect itself is observable live, and the
[worked demo](phase-24-worked-demo.md) is where it is observed: its 2026-09-14 gate records
`project destroy` reporting `starting hostbootstrap-demo-vm so its retained children can be reached`,
settling every retained child through the frame it reopened, and exiting 0 — where the same sequence had
refused with `Error: Instance is not running`.

On 2026-11-15 the root and failed-Up drivers adopted a shared pre-descent handler, and failed or refused
reachability was retained as pre-descent retry work. New driver and refusal cases were added. The first
focused WSL2 `TeardownSpec` run passed 98 of 99 cases; the remaining assertion named the wrong descent
row. That assertion and preservation of pre-descent state across a failed child descent were corrected;
the focused `TeardownSpec` rerun passed all 99 cases in 24.56 seconds. The related handoff, plan,
authority, recursive lifecycle and documentation selection passed all 659 cases in 176.60 seconds.
After adding successful-retry observation checks, `TeardownSpec` passed all 99 cases again in 24.49
seconds. The Windows Python code checks and full test command passed with 100% reported coverage.
On the same date, `cabal test all -j4 --ghc-options=-Werror --test-option=--hide-successes` passed from
both `core/` and `demo/` on dedicated WSL2; their core suites passed all 5,515 cases in 929.66 and
919.98 seconds respectively. The optional provider-live component reported its declared no-request result.

#### Remaining Work

None.

### Sprint 17.61: Canonical resource records refuse the short close [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`, `core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Make the no-resource proof observe the canonical resource records ordinary execution writes. The
preserved Windows run owns provider and share records without a legacy `effect.*` marker, while the
recovery fixture currently adds that marker to make the no-resource proof refuse.

#### Deliverables

- Demonstrate resource recovery with the existing canonical fixture and no additional effect marker.
- Refuse the bound short-close proof and its final recheck while any record remains in the exact plan's
  canonical resource namespace; settled recovery consumes that resource set through its existing path.
- Preserve backend-refusal retry and released-tombstone behavior in the recovery tests.
- Add no type; budget 80 production lines in one module.

#### Validation

On 2026-09-16, removing the extra effect marker from the canonical resource fixture makes its existing
acquired-resource test fail: the expected backend call is absent even though the successor is admitted.
After the correction, all 46 `HarnessSpec` tests pass on native Windows in 6.66 seconds, including
backend-refusal retry and released-tombstone recovery. The retained-proof close test also covers a later
canonical resource record. Fourmolu 0.19.0.1 checks the changed files; HLint reports no hints on retry
after one isolated Linux process segfault. The complete native Windows phase gate passes: `cabal build
all` followed by `cabal test all --test-show-details=direct --test-options=--hide-successes` from
`core/` exits 0, with 2,547/2,547 core cases in 511.60 seconds and the provider-live component's
declared no-request result. The complete command takes 529.45 seconds. The repository Python code
check and 251/251 Python tests also pass (7.92 seconds).

#### Remaining Work

None. The worked-demo phase owns live confirmation against the preserved run.

### Sprint 17.62: Typed rooted catalog entry coordinates [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/RootedPlan.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Handoff/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Give every coordinate role that crosses the recursive catalog's sealed folds its own newtype (§ HH), so a
transposed parent/child frame, raw/stripped route, or configuration/payload digest is a type error rather than
a value the edge recheck may miss.

#### Deliverables

- `RootedPlanCatalogDescent` and every rank-2 fold (`withRootedPlanCatalogEntriesKernel`,
  `withRootedPlanCatalogEntriesContinuationKernel`, `withRootedPlanCatalogEdgeKernel`) carry
  `ParentFrameId`/`ChildFrameId`, `RawLiftRoute`/`StrippedLiftRoute`, and `ConfigDigest`/`PayloadDigest`
  newtypes instead of bare `Text` and `LiftContext` by position.
- `withRootedPlanCatalogEdgeKernel` takes typed parent and child selectors.
- The newtypes are shared by the catalog producer, the manifest renderer, and the `CatalogForwardHandoff`
  consumer; no consumer unwraps a role except at its renderer.
- Runtime behaviour and the durable manifest bytes are unchanged.

#### Validation

A new compile-fail fixture that swaps the configuration and payload digests (or the parent and child frames)
in a catalog fold continuation fails with one contiguous type-mismatch diagnostic. `ProjectPlanSpec` re-pins
the fold signatures, and the catalog owner stays under its 400-line split boundary. `CLISpec`'s catalog
manifest cases and `RecursiveLifecycleSpec`'s public up/down/destroy cases pass unchanged, and the four host
static gate commands pass.

Progress on 2026-11-22:

- The six role newtypes `ParentFrameId`, `ChildFrameId`, `RawLiftRoute`, `StrippedLiftRoute`, `ConfigDigest` and
  `PayloadDigest` sit beside the catalog GADT in `Lifecycle/RootedPlan/Internal.hs` and are re-exported by
  `Lifecycle/RootedPlan.hs`. The catalog producer wraps each role once as it extends the catalog.
  `RootedPlanCatalogDescent`, `withRootedPlanCatalogEntriesKernel`,
  `withRootedPlanCatalogEntriesContinuationKernel` and `withRootedPlanCatalogEdgeKernel` (which now takes typed
  parent and child selectors) carry them in place of bare `Text` and `LiftContext`.
- Every consumer binds a role by its constructor pattern in its fold continuation:
  `ProjectPlan/Handoff/Internal.hs`'s `CatalogForwardHandoff` seal, `Command/LifecycleEntry.hs`, `Teardown/Internal.hs`,
  `Lifecycle/Rooted.hs`, `Lifecycle/Rooted/Node.hs`, the catalog's own `rootedPlanCatalogChildRoutesKernel`, and
  the fault-injection fixture `Lifecycle/RootedPlan/Testing.hs`. A transposed binding is a type error; only the
  manifest renderer turns roles back into text, so the durable manifest bytes are unchanged.
- `CompileFailSpec` gains a "private rooted catalog unit" group whose compiler exposes only
  `HostBootstrap.Lifecycle.RootedPlan` from the private implementation unit. In it,
  `SwapRootedPlanCatalogCoordinates.hs` returns the payload digest where a configuration digest belongs and fails
  with the single diagnostic "Couldn't match expected type 'ConfigDigest' with actual type 'PayloadDigest'".
- `ProjectPlanSpec` re-pins the descent constructor, the edge fold's signature and rechecks, the manifest entry,
  the `CatalogForwardHandoff` selection and seal, the reverse catalog package, the catalog's export list, its
  representation module's six named newtypes, the four changed module digests, and the handoff owner's line
  count (197). The catalog owner stays under its 400-line boundary.
- The first full native `core/` leg failed one unrelated case: HarnessSpec "real case and underscore project
  identities keep exact origin records and recovery" waited a fixed 600 × 20 ms for a probe to announce
  readiness, and the probe started more slowly under the full suite's load. The case passed three times alone.
  Its wait now ends on the probe's own readiness or exit, with only a two-minute backstop.

The repeated native Windows `core/` leg passed all 5,622 tests in 867.40 seconds, and the `demo/` leg passed 177 demo
and 5,622 core tests; `check_code` passed and `test_all` passed 384 tests. On the linux-cpu VM (09:12:52Z to
09:59:17Z), where the POSIX row holds, a focused run of `RecursiveLifecycleSpec`'s process-transport family (its public
up/down/destroy cases), `CLISpec` (its catalog manifest cases) and the recovery-interruption family passed all 177
tests unchanged.

#### Remaining Work

None.

### Sprint 17.63: `project up --dry-run` renders without Production authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

`project up --dry-run` prints the admitted chain plan and leaves the protected store unchanged. It takes no
Production mode, writes no lease, re-arms no closed invocation, and consumes no lifecycle-profile slot, so a
preview never blocks `test run`, `project down`, or `project destroy`.

#### Deliverables

- The dry-run branch of `runUp` (`Command.hs`, near lines 1263 and 1297-1300) renders `renderChain plan` from
  a plan admitted without `withProductionRoot` and `withProductionLifecycleProfile`: a pure projection of the
  validated config through `projectPlanDrafts` and plan construction.
- No dry-run path reaches `withFreshProductionPlan`. The recovered-plan branch renders from the recovered plan
  and writes nothing.
- A dry run after `project destroy` leaves the closed invocation disposition, the terminal Destroy receipt,
  and the closed journal byte-identical, because no `rearmClosed=True` root opens (`Mode.hs`, near lines
  9478-9490).

#### Validation

`CLISpec` cases: (1) On a freshly initialised store, `project up --dry-run` exits 0 and prints the chain. The
protected-store record listing is byte-identical before and after. A following `test run` is not refused with
`ModeHeldByAnother production`, and `project destroy` does not die with
`ModeLeaseNotBindable "production" "unbound"`. (2) After `project up` then `project destroy`,
`project up --dry-run` leaves the store byte-identical, so the terminal Destroy receipt survives. The sprint
closes when both pass in `cabal test all --ghc-options=-Werror` from `core/` and the four host static gate
commands pass.

Progress on 2026-11-22:

- `runUp`'s dry-run arm now runs before `openAuthorityStore`. It projects the validated config through
  `projectPlanDrafts`, builds the forward projection with `withProjectPlanPreview` (the `ProjectPlan` facade over
  `withPreviewPlannedStepsKernel` in `Lifecycle/Plan.hs`), renders it with `renderChainPreview` (`Chain.hs`), and
  exits. No dry-run path therefore reaches `withRecoveredProductionPlan`,
  `withFreshProductionPlan`, `withProductionRoot` or `withProductionLifecycleProfile`, and the effectful
  branches no longer carry a dry-run arm. The trace showed the recovered branch is not read-only either, since it
  recovers and holds the bound Production mode, so it is bypassed too and the preview renders from the current
  config.
- `withPreviewPlannedStepsKernel` runs the profile-free half of plan admission (`admitStepPlanAtRootKernel`, now
  shared with `admitProjectPlanAtRootKernel` rather than copied). That half checks the drafts' root, specification
  and configuration bindings, runs `mkStepPlan`, and checks the chart workload, service activation and provider
  probe root declarations. The kernel projects the admitted steps through the same `plannedStepsOfKernel` that
  `forwardKernel` uses, under a fresh rank-2 plan identity. It mints no `ProjectPlan`, and no `StepExecution`
  exists for that identity, so `runPlannedStep` cannot run a preview step.
- A first version rendered raw `Step` values from `Chain.hs` and imported the plan kernel into `Command.hs`. The
  gate's `ChainSpec` raw-step guard and the audited plan-kernel importer list refused both, and the preview now
  reaches `Command.hs` only through the `HostBootstrap.ProjectPlan` facade.
- `renderChainPreview` renders any forward projection, and `renderChain` is that renderer applied to an admitted
  plan's own projection, so the preview matches an admitted plan's rendering line for line. The sealed export
  inventory names `renderChainPreview` and `withProjectPlanPreview`. `Mode.hs` needed no change: with no
  root opened, no `rearmClosed=True` transition can run.
- `CLISpec` "project up --dry-run renders the exact plan and leaves the protected store byte-identical" replaces
  the case that pinned the old unbound lease. On a fresh store the subprocess dry run prints the chain, runs no
  effect, and leaves the protected-store image byte-identical. A following `project destroy` names neither
  `ModeLeaseNotBindable` nor `ModeHeldByAnother`, and a real `project up` then succeeds.
  "project up --dry-run after destroy leaves the closed invocation and terminal receipt byte-identical" runs
  `project up` and `project destroy` in process, then the dry run, which exits successfully with the chain and
  leaves every record, the two closed invocations included, byte-identical. The `test run` interaction is
  covered by the byte-identical store, since a preview leaves no mode for a Harness run to contend with;
  neither case drives a Harness run itself.
- `lifecycle_state_model.md` states the preview's authority, and `composition_methodology.md`,
  `hostbootstrap_core_library.md`, `authoring_project_binaries.md` and `demo_runbook.md` no longer list the
  dry run as an open gap.

On native Windows the `core/` leg (whose `common warnings` stanza carries `-Werror`) passed all 5,623 tests in
1,017.57 seconds, including both dry-run cases, and the `demo/` leg passed 177 demo and 5,623 core tests; `check_code`
passed and `test_all` passed 384 tests. The dry-run cases need no POSIX row, so this leg is their execution.

#### Remaining Work

None.

### Sprint 17.64: The root project gate names the evidence it refuses [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority/ProjectPlan.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`, `core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

`authorizeRootProject` is the root-project command-reservation gate every root entry passes (Up, Down, and
Destroy, `Command/LifecycleEntry.hs` near lines 500, 588, and 875). It cross-checks about twenty-five retained
terms before reserving, and reports every mismatch, including a frame outside the admitted topology and a
nested lifecycle context, as `AuthorityMalformedBinding`, the constructor that denotes a corrupt durable
`authority.binding` record. No test calls it on drifted values, and the `AuthoritySpec` root-gate case is a
substring check that stops at each comparison's expected operand. This sprint gives retained-evidence
refusals their own constructor and proves each one by value.

#### Deliverables

- `AuthorityError` gains `AuthorityEvidenceMismatch Text`, rendered by `authorityErrorMessage` as "the retained
  root evidence does not match: <subject>". `authorizeRootProject` produces it for every retained-evidence
  refusal (verb, specification/configuration/plan digests, canonical bytes, project, store, broker epoch,
  journal scope and run lease, lease/journal agreement, topology membership, cursor and context frame,
  placement) and for a refused root lifecycle context.
- `AuthorityMalformedBinding` is produced only for the durable binding record it names.
- An `AuthoritySpec` drift table proves each refusal by value and proves that no `invocation.` record is
  written.
- No named type is added beyond the one constructor; the reservation bridge is unchanged.

#### Validation

`AuthoritySpec` drift cases in the style of `SessionSpec`'s coerced-evidence cases (near lines 544-609): each
feeds `authorizeRootProject` one coerced foreign term (verified snapshot, bound snapshot, binding, lease, plan,
journal, cursor, context) or a non-cluster placement, and asserts `AuthorityEvidenceMismatch "<subject> does
not match"` (or its exact subject) and no `invocation.` record. A nested-frame lifecycle context asserts the
root-frame-required subject. The four host static gate commands pass.

Progress on 2026-11-22:

- `AuthorityError` (`Authority/Kernel.hs`) gains `AuthorityEvidenceMismatch Text`, rendered "the retained root
  evidence does not match: <subject>". `authorizeRootProject` produces it for every retained-evidence refusal,
  through its `malformed` helper, and for a refused root lifecycle context. It no longer produces
  `AuthorityMalformedBinding`. The reservation bridge is unchanged, so a stale cursor version or live
  lease-version drift found while reserving still reports the durable record it read.
- `AuthoritySpec`'s real root-gate fixture (`rootGateCheckCase`) proves each refusal by value with the store
  image unchanged and no `invocation.` record. The nested lifecycle context asserts the root-frame-required
  subject, the cursor frame from a genuine second plan asserts "cursor frame does not match", a Destroy verb
  presented against the Up root and cursor asserts "root project verb does not match", and a genuine second
  plan over the same config, differing in one step label, asserts "verified plan digest does not match". The
  remaining terms (bound snapshot, binding, lease, journal, placement) are not yet driven by value: each needs a
  second persisted acquisition, which this fixture's single unbound lease cannot provide. They are pinned as
  whole source lines instead.
- "the generic root gate consumes one exact root lifecycle context for every closed verb" now pins whole
  comparison lines, observed operands included (the three verb checks, the verified plan digest, the cursor and
  context frames), plus the `requireText` definition, the `malformed` helper's new constructor and the context
  refusal. It also asserts that the gate's source no longer names `AuthorityMalformedBinding`. The affected
  `AuthoritySpec` selection passed 366 tests on native Windows.
- `ownership_invariant.md` separates the two failures under the durable-origin clause.

On native Windows the `core/` leg passed all 5,625 tests in 1,100.88 seconds and the `demo/` leg passed 177 demo and
5,625 core tests; `check_code` passed and `test_all` passed 384 tests. The by-value drift cases for the persisted
evidence terms split into Sprint 17.64a under § G, because they need a second persisted acquisition.

#### Remaining Work

None.

### Sprint 17.64a: Drive the persisted-evidence root-gate drift terms by value [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Prove by value each retained-evidence refusal of `authorizeRootProject` whose foreign term must come from a
second persisted acquisition, which Sprint 17.64's single-acquisition fixture cannot mint.

#### Deliverables

- A rank-2 evidence fixture beside `rootGateCheckCase` runs one complete root-gate acquisition in an isolated
  root, so two can run side by side.
- One case per term feeds the first acquisition's evidence with exactly one term coerced from the second: the
  verified snapshot, bound snapshot, digest binding, bound run lease and acquisition journal. One more case
  supplies a validated context whose placement refuses cluster lifecycle commands. Each asserts its exact
  `AuthorityEvidenceMismatch` subject, the store image unchanged, and no `invocation.` record.

#### Validation

Run the new `AuthoritySpec` cases and the four host static gate commands.

Progress on 2026-11-22:

- `withRootGateEvidence` (`AuthoritySpec`) runs one genuine Production acquisition in its own temporary root:
  the root authority, persisted verified and bound snapshots, digest binding, bound run lease, plan, acquisition
  journal, Execute cursor and root lifecycle context, passed to a rank-2 continuation.
- `rootGateForeignEvidenceCase` nests two such acquisitions in two roots and feeds the first one's evidence to
  `authorizeRootProject` with exactly one term coerced from the second. Each asserts its exact subject, the
  store image unchanged, and no `invocation.` record:
  - verified snapshot: "verified configuration digest does not match";
  - bound snapshot: "bound canonical plan bytes do not match";
  - digest binding: "plan digest binding does not match";
  - bound run lease: "bound lease plan digest does not match";
  - acquisition journal: "acquisition journal snapshot digest does not match".
- The placement refusal is not driven by value. A root lifecycle context is the host orchestrator, whose
  placement admits cluster lifecycle commands, so a genuine root context cannot reach it. It stays pinned by
  `requireCondition`'s whole source line in "the generic root gate consumes one exact root lifecycle context for
  every closed verb".
- The seven retained-evidence drift cases, these five plus Sprint 17.64's verb and plan drift, passed on native
  Windows.

On native Windows the `core/` leg passed all 5,630 tests in 838.11 seconds and the `demo/` leg passed 177 demo and
5,630 core tests; `check_code` passed and `test_all` passed 384 tests.

#### Remaining Work

None.

### Sprint 17.65: The forward-child projector takes typed frame roles [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Construct/Internal.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Projection/Internal.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/engineering/authoring_project_binaries.md`

#### Objective

The project-owned forward-child projector (`psForwardChildPlan`, `pbForwardChildPlan`, `addForwardChildPlan`,
`refuseForwardChildPlan`, and `withFinalizedProjectSpec`'s parameter) has type
`cfg scope -> Text -> Text -> LiftContext -> Either String (FilePath, cfg scope, StepPlan)`: the parent and
child frame ids cross the sealed `ProjectSpec` boundary as two positional bare `Text` values. A project author
who swaps them type-checks and finalizes, and the mistake surfaces only at `project up` as a refusal or a wrong
edge. Each coordinate role gets its own type (§ HH).

#### Deliverables

- The projector takes the parent and child frame ids as the `ParentFrameId` and `ChildFrameId` role newtypes
  Sprint 17.62 introduces, re-exported from `HostBootstrap.CLI` with their unwrapping accessors.
- The hidden kernel (`ProjectPlan/Construct/Internal.hs`) and its caller (`ProjectPlan/Projection/Internal.hs`)
  wrap each role once at the topology edge; no consumer re-wraps a bare `Text`.
- The worked demo's `demoForwardChildPlan` binds the typed roles.
- Runtime behaviour, durable bytes, and the projected plans are unchanged; no other named type is added.

#### Validation

The compile-fail fixture installs a projector that uses the child id where the parent id belongs and fails
with one type-mismatch diagnostic naming `ParentFrameId`. The complete core and demo suites include
`CLISpec`'s projector cases and `RecursiveLifecycleSpec`'s public cases.

2026-11-23: `SwapForwardChildProjectorFrames.hs` is registered in the public compile-fail inventory. GHC
9.12.4 on the dedicated Linux VM rejected it with one diagnostic: expected `ParentFrameId`, actual
`ChildFrameId`. The projector signature, source ownership and sealed export guards were updated for the
typed roles; the affected focused guards passed during Sprint 16.91. On native Windows, `check_code` passed
Ruff, Black and mypy, and `test_all` passed 384 tests at 100% coverage. The first core command could not find
`cabal` on `PATH`; it was restarted with the installed `C:\ghcup\bin` toolchain on the process path. The
complete core and demo legs remain due. The first native core run then failed when Windows reported that its
paging file could not commit more memory; a concurrently started demo build failed package registration with
a missing package-database file. Neither is passing evidence. The now-idle dedicated Linux VM was shut down;
the Cabal legs were retried one at a time with one build and test worker. `cabal test all -j1 --test-option=-j1`
from `core/` passed all 5,631 core tests in 831.58 seconds; its optional provider-live suite reported the
declared unsupported result. The serial `demo/` leg then failed to compile `CommandsSpec`: its typed projector
fixtures lacked imports for the new frame constructors. After adding those imports, `cabal test all -j1
--test-option=-j1` from `demo/` passed its core suite and all 177 demo tests. Together with the passing Python
legs, this completes all four host static gate commands.

#### Remaining Work

None.

### Sprint 17.66: The rooted post-open response family is a closed sum [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

`withRootedPostOpenResponseKernel` (`Handoff/Relay.hs`, near line 862) says its family selector is
"deliberately closed", but `family :: Text` accepts any string; closure is a runtime fallback in `build`'s
wildcard arm and in `postOpenNonce`'s `require` lists, and `LifecycleEntry` passes a variable family. An
unpaired or misspelt family compiles and fails only at signing time. The family becomes a closed sum (§ HH).

#### Deliverables

- `PostOpenFamily = Descend | Settled | FrameComplete | ReceiptRecorded | Refused`, with a total renderer to
  the wire label, is the selector's type.
- `build` and `postOpenNonce` pattern-match on it, so the wildcard arm and its runtime refusal are gone and the
  request-kind pairing derives from the constructor.
- Every `LifecycleEntry` call site passes a constructor; the wire bytes are unchanged.

#### Validation

The rooted response cases and `RecursiveLifecycleSpec`'s public cases pass; the existing six-builder test
checks canonical wire bytes and request pairing. A `ProjectPlanSpec` guard pins the sum, total renderer,
exhaustive pairing and the absence of a wildcard builder arm.

2026-11-23: The closed selector, total wire-label renderer, request-family pairing and `LifecycleEntry`
constructor call sites are implemented. The existing response source guard was updated and a project-plan
guard added. Focused post-open, exact relay export, wire-byte and pairing checks passed. Native Windows Python
`check_code` and `test_all` passed, the latter with 384 cases and 100% coverage. The full core run failed two
of 5,632 cases in 830.36 seconds because two exact relay declaration inventories did not yet name or count
`PostOpenFamily`; those inventories have been updated. A focused rerun then found the related relay source-size
pin stale (2,815 significant lines); it was updated, and an already-started full run was stopped because it
would have failed that known assertion. Both updated inventory cases passed individually, and the next
`cabal test all -j1 --test-option=-j1 --test-option=--hide-successes` from `core/` passed all 5,632 tests
in 811.22 seconds. The Windows recursive process-boundary row was unsupported, so its real Linux cases still
need focused validation. The serial `demo/` gate passed its demo suite and all 5,632 shared core tests in
813.95 seconds. The dedicated Linux VM was restarted with the live checkout and guest-local build storage;
source identity, fresh bidirectional writes and relative symlink resolution were rechecked, and the real
recursive lifecycle selection passed all 33 cases in 83.67 seconds on 2026-11-23, exercising the real
root/VM/container process transport. All four host static gate commands passed as described above.

#### Remaining Work

None.

### Sprint 17.67: The resource-record set hashes and frames through Digest [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/ResourceRecord.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`

#### Objective

`HostBootstrap.Digest` exports the lowercase-hex `sha256Hex` and the 8-byte big-endian length prefix
`frameWire`. The resource-record set spells its hash through `Show (Digest SHA256)`, which renders the same
lowercase hex, and frames its members with a local copy of the same prefix; importing the exports makes that
agreement a single definition rather than a coincidence of two.

#### Deliverables

- `Lifecycle.ResourceRecord` imports `sha256Hex` and `frameWire` from `HostBootstrap.Digest` and defines no
  SHA-256 or framing helper of its own.
- Every record-set digest, member digest and framed member keeps the bytes `ResourceRecordSpec` pins.

#### Validation

`ResourceRecordSpec` passed unchanged inside the declared `cabal test all --ghc-options=-Werror` from `core/`,
and the host static gate (§ JJ) passed.

2026-11-23: The existing implementation already imports `frameWire` and `sha256Hex` from
`HostBootstrap.Digest` and has no local copies. The unchanged `ResourceRecordSpec` selection passed all nine
cases on native Windows. `check_code` passed Ruff, Black and mypy, and `test_all` passed 384 tests at 100%
coverage. `cabal test all --ghc-options=-Werror -j1 --test-option=-j1 --test-option=--hide-successes` from
`core/` passed all 5,632 tests in 822.55 seconds. The serial `demo/` leg passed the same 5,632 core tests in
822.03 seconds and all 177 demo tests in 9.36 seconds. The optional Incus lane reported unsupported on Windows.

#### Remaining Work

None.

### Sprint 17.68: The core test fixture's init assembler refuses through `failConfigAssembly` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/Fixture.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`, `core/hostbootstrap-core/test/ChainSpec.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`, `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/generic_project_model.md`

#### Objective

An assembly refusal (`failConfigAssembly`) ends `project init` with a non-zero exit before anything is
published, and the core suite reaches that branch through its own fixture assembler. The test `Fixture`'s
`projectInit` is wrapped in `pureConfigAssembly` by `ChainSpec`, `CLISpec`, `ContextSpec`, and this phase's
`RecursiveLifecycleSpec`, so the change lands here, where every caller exists.

#### Deliverables

- The test `Fixture`'s `projectInit` returns `ConfigAssembly scope (ProjectConfig scope)` and maps an
  `addRole` refusal to `failConfigAssembly (Context.contextErrorMessage err)` rather than calling `error`; its
  four callers use it without `pureConfigAssembly`.
- The `Fixture` module header calls it a minimal `ProjectCfg` instance for the generic machinery and points to
  the demo consumer for the demo config's refined schema coverage; it does not claim equivalence with the
  demo's `ProjectConfig`.

#### Validation

The sprint closes when this case exists and passes under `cabal test all` from `core/`:

- `ContextSpec`: `project init --role daemon --also-role one-shot --output <dir>/<project>.dhall` returns
  `Left (ExitFailure 1)`, its captured stderr contains
  `Context.contextErrorMessage (ContextRoleAdditionRefused Daemon OneShotJob)`, and no file exists at the
  output path afterwards.

2026-11-23: The fixture now returns restricted assembly, its four callers use that value directly, and the
requested refusal/no-publication case passed in a five-case focused selection. Native Windows `cabal test all
-j1 --test-option=-j1 --test-option=--hide-successes` from `core/` passed all 5,633 tests in 824.53 seconds.
The optional Incus provider-live suite reported its declared unsupported result.

#### Remaining Work

None.

### Sprint 17.69: Project-spec finalization reads its scope tag from the scope index [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/ProjectPlan/Construct/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/authoring_project_binaries.md`

#### Objective

The `ScopeKind` a `FinalizedProjectSpec scope specDigest cfg` reports comes from its `scope` index through
Phase 7's `KnownScopeKind scope` class and its `scopeKindOf` method (Sprint 7.12), never from a caller argument.
`withFinalizedProjectSpec` (Phase 12's `ProjectPlan/Construct.hs`) delegates to `withFinalizedProjectSpecKernel`
in this phase's hidden `ProjectPlan/Construct/Internal.hs`, and both take a caller-chosen `ScopeKind` that
nothing ties to `scope`, so a Harness tag can be finalized over a Production codec. Harness re-finalization,
`withHarnessFinalizedProjectSpecKernel` in the same hidden module, passes the literal `HarnessScope` to the
kernel; the public `withHarnessFinalizedProjectSpec` is a bare alias of it and carries no tag. The signature
change spans both modules, so it lands here, where every file it touches exists. The kernel keeps passing a
tag to `withFinalizedServiceRegistry`, which still takes a `ScopeKind` term here; Phase 22's Sprint 22.9 drops
that parameter and the kernel's argument with it.

#### Deliverables

- `withFinalizedProjectSpec` and `withFinalizedProjectSpecKernel` take no `ScopeKind` parameter and carry a
  `KnownScopeKind scope` constraint; the kernel passes `scopeKindOf (Proxy @scope)` to
  `withFinalizedServiceRegistry`.
- `withHarnessFinalizedProjectSpecKernel` calls `withFinalizedProjectSpecKernel` without the `HarnessScope`
  literal; the `Harness projectId runId` instance supplies the tag.
- `HostBootstrap.CLI` (both `withFinalizedProjectSpec` calls) and the test callers pass no scope tag:
  `CLISpec` in `project up fails fast without a sibling context`, `ProjectPlanSpec` in `Production and exact
  Harness runs jointly finalize one static project definition` and the helpers
  `withRecoveredProjectPlanCandidateFixtureUsing` and `withSnapshotPlanUsing`, and `SessionSpec` in the helpers
  `withAcquisitionPlanFixtureForConfig` and `attemptRecoveredAcquisitionFor`.
- Runtime behaviour and the finalized specification digests are unchanged.

#### Validation

The sprint closes when these pass under `cabal test all` from `core/`:

- `CompileFailSpec` registers `rejectsWith "FinalizeProjectSpecWithScopeKind.hs" ["Couldn't match expected
  type: ProjectCodec", "with actual type: ScopeKind"]`; the fixture applies `withFinalizedProjectSpec` to
  `HarnessScope` ahead of a Production codec, the remaining arguments, and a continuation. The two fragments
  are confirmed against the pinned GHC's rendering when the fixture is written, and stay a type mismatch of a
  `ScopeKind` against the `ProjectCodec` parameter.
- `ProjectPlanSpec`: `Production and exact Harness runs jointly finalize one static project definition` passes
  with its call site rewritten, and `forward-child projection ownership is hidden, fixed-unit, acyclic, and
  frozen` passes with its `Harness refinalization reuses the exact static projector` source guard rewritten to
  the fragments `baseCodec staticServices staticPlanBuilder staticProjector use =` and
  `withFinalizedProjectSpecKernel baseCodec staticServices staticPlanBuilder staticProjector use`.
- `CLISpec`: `project up fails fast without a sibling context`, and every `ProjectPlanSpec` and `SessionSpec`
  case built on the four helpers named under Deliverables, pass with their call sites rewritten.

2026-11-23: The kernel and public finalizer now derive the tag from `KnownScopeKind`; the Production and
Harness callers, including newer `TeardownSpec` calls and its generated fixture, no longer pass a tag. The
production build passed. The new compile-fail fixture applies the former signature and GHC reports the
expected mismatch between the Production `ProjectCodec` type and `ScopeKind` (plus cascading argument errors);
its inventory entry pins that complete diagnostic as one phrase because the matcher assigns separate
expected phrases to separate compiler errors. The registered negative fixture, the Production/Harness
finalization case and the updated frozen projector guard each passed focused runs on native Windows. The
complete core gate passed on native Windows: `cabal test all -j1 --test-option=-j1 --test-option=--hide-successes`
ran 5,634 core tests in 806.75 seconds; the optional Incus provider-live lane reported Unsupported.

#### Remaining Work

None.

### Sprint 17.70: Child-plan admission checks the running frame [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Phase 13's `withChildProjectPlan` admits a child plan whose signed child frame is the frame the admitting
binary runs. The comparison sits at this phase's admission call site in `Command/Child.hs`, so any other
caller of `withChildProjectPlan` admits a plan signed for another frame. The admission itself takes the running
frame and refuses a mismatch before it mints `ChildPlanAuthority`; the signature change spans Phase 12's
`ProjectPlan/Construct.hs` and this phase's `Command/Child.hs`, so it lands here, where every file it touches
exists.

#### Deliverables

- `withChildProjectPlan` takes the running frame's name and refuses with `AuthorityMalformedBinding` naming both
  frames when `handoffChildFrame` differs, before minting `ChildPlanAuthority`.
- `Command/Child.hs` passes `Context.currentFrame` and carries no frame comparison of its own at the admission
  call site.

#### Validation

The sprint closes when a `ProjectPlanSpec` case, built from the existing successful admission fixture with only
the running frame changed, asserts the exact `AuthorityMalformedBinding` text naming both frames, and the
existing child-admission cases pass, under `cabal test all` from `core/`.

2026-11-23: Admission now compares the running frame with the signed child frame before authority is minted;
the forward child route passes its validated context frame, and callers and the negative fixture are updated.
The first focused build exposed a test-only ambiguous string type, followed by an unqualified type name; both
were corrected. The three focused admission cases, updated compile-fail fixture and forward-child ownership
guard passed. The native Windows `cabal test all -j1 --test-option=-j1 --test-option=--hide-successes` gate
passed all 5,635 core tests in 814.37 seconds; the optional Incus provider-live lane reported Unsupported.

#### Remaining Work

None.

### Sprint 17.71: Represent the prepared effect coordinates [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Introduce distinct unknown-phase and call-digest coordinates and a transitional internal representation before
threading the committed values through the journal, signed wire and preparation check in the following sprints.
The legacy unbound path remains in place only until that adoption is complete.

#### Deliverables

- The private gate representation can retain both nominal coordinates and exposes their observation internally.
- Existing gates retain their current behavior during the transition.

#### Validation

The gate coordinate and ownership cases pass, followed by `cabal test all` from `core/`.

2026-11-23: The rooted version-3 package contains neither coordinate, and its producer obtains gates from a
separate rooted journal module. The original sprint therefore spans more than ? G's three production modules;
the journal, wire and enforcement adoption are split into the following bounded sprints. Typed transitional
storage and its focused case are implemented and passed, as did the private ownership guard. The first
documentation-validator run rejected a range-form Remaining Work reference; listing the active sprint explicitly
fixed it, and all 22 documentation cases passed. Native Windows `cabal test all -j1 --test-option=-j1
--test-option=--hide-successes` passed 5,635 core tests in 816.39 seconds; the optional Incus provider-live
lane reported Unsupported.

#### Remaining Work

None.

### Sprint 17.71a: Bind effect coordinates to the durable journal [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Record the unknown phase and call digest together and bind the gate from the re-read committed record. Retain
the existing route until its callers migrate in the following sprints.

#### Deliverables

- The journal's effect-aware prepare records and re-reads both coordinates before binding the gate.
- Invalid or unrepresentable call digests refuse before the journal write.

#### Validation

Session and journal cases check the committed coordinates and refusals under `cabal test all` from `core/`.

2026-11-23: An effect-aware journal route writes the phase and call digest together, rejects invalid digests,
and binds the gate only from the re-read committed payload. The first focused build found a test import of a
hidden module; it was corrected to the existing test-only alias. The focused rerun passed both new cases, including empty and tab-containing digests; all 311 `SessionSpec`
cases, the prepared-node ownership guard and all 22 documentation-validator cases passed. Rooted adoption
belongs to the next sprint. The first full core gate ran 5,637 cases in 828.64 seconds and failed only the
public Session export pin, which omitted the newly exported function. The corrected pin passed its focused
check; the rerun of native Windows `cabal test all -j1 --test-option=-j1 --test-option=--hide-successes` passed
all 5,637 core tests in 830.04 seconds. The optional Incus provider-live lane reported Unsupported.

#### Remaining Work

None.

### Sprint 17.71b: Encode effect coordinates in a gate package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Add a canonical effect-bearing gate package that retains the existing fenced gate coordinates and also
carries distinct unknown-phase and call-digest fields. Preserve the existing package while its producers and
consumers migrate in the following sprints.

#### Deliverables

- The private package codec round-trips both effect coordinates with the complete fenced gate.
- Malformed, empty, truncated, noncanonical or trailing fields refuse.

#### Validation

Effect-bearing gate round trips and malformed-field cases pass with the existing codec and ownership guards,
under `cabal test all` from `core/`.

2026-11-23: The current rooted producer receives operation keys but no effect digest; the codec is split from
its producer adoption so no fabricated coordinate is recorded. The journal and wire consumers still need the
actual plan-derived effect before the end-to-end guarantee exists. A version-4 codec now carries the existing
fenced fields and both effect coordinates. The codec round-trip and malformed-field case, both affected
ownership guards and all 22 documentation-validator cases passed. Native Windows `cabal test all -j1
--test-option=-j1 --test-option=--hide-successes` passed all 5,637 core tests in 817.93 seconds; the optional
Incus provider-live lane reported Unsupported.

#### Remaining Work

None.

### Sprint 17.71c: Prepare rooted effect coordinates [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Provide an effect-aware rooted journal route that records each supplied phase and digest before returning its
gate, and refuses to reuse a pending gate for different effect coordinates. Its caller remains responsible for
obtaining the coordinates from an authenticated plan or separately validated request.

#### Deliverables

- Rooted preparation records exact effect coordinates and reuses only an exact pending effect gate.
- The existing rooted route remains available while its producer migrates.

#### Validation

Rooted journal cases cover effect-aware preparation and reuse under `cabal test all` from `core/`.

2026-11-23: Rooted preparation now accepts explicit effect coordinates and refuses mismatched pending gates.
Integration exposed a legacy settlement check that accepted only four-field records; it is being updated to
match both effect coordinates against the durable five-field record. The first build required an explicit
polymorphic signature for the rooted preparation helper; that correction compiled successfully. The rooted
prepare/reuse/settlement and different-digest refusal cases passed, as did all 311 session cases. The rooted
ownership guard first required its intentional export and source-digest updates and then passed; all 22
documentation-validator cases passed. Native Windows `cabal test all -j1 --test-option=-j1
--test-option=--hide-successes` passed all 5,638 core tests in 822.70 seconds; the optional Incus
provider-live lane reported Unsupported.

#### Remaining Work

None.

### Sprint 17.71d: Package rooted effect gates [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Provide a private rooted grant path that rechecks prerequisites, records supplied effect coordinates, and
packages the committed gate as version 4. The existing production route remains until the coordinator has an
authenticated source of effect coordinates.

#### Deliverables

- Effect-aware rooted admission rechecks the same prerequisite observations as the existing route.
- The root packages each committed gate's exact recorded phase and digest with its fenced coordinates.

#### Validation

Rooted effect-grant and prerequisite-refusal cases pass under `cabal test all` from `core/`.

2026-11-23: The coordinator currently receives operation keys only; provider and cluster call digests are
computed inside step actions after a gate has already been requested. Deriving a digest from the key would be
incorrect, so obtaining an authenticated, exact effect description remains a separate sprint. A private
forward grant route now rechecks prerequisites and packages the gate?s committed effect coordinates; its
focused validation initially found the grant owner above its 400-line bound. Shared journal validation and
packaging were moved to the existing rooted journal owner; after updating its private exports and frozen digest,
the ownership guards pass. All 105 teardown cases, including the effect package, wrong-operation and missing-
prerequisite refusals, the executor guard and all 22 documentation-validator cases passed. The existing
version-3 response route remains in use. Native Windows `cabal test all -j1 --test-option=-j1
--test-option=--hide-successes` passed all 5,638 core tests in 831.30 seconds; the optional Incus provider-live
lane reported Unsupported.

#### Remaining Work

None.

### Sprint 17.71e: Encode ordered effect proposals [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Define a bounded canonical proposal for the ordered operation keys, unknown phases and call digests an
executing frame intends to prepare. A proposal is descriptive data: by itself it grants no authority.

#### Deliverables

- The private codec preserves all three distinct coordinates and rejects empty, duplicate, malformed,
  oversized, truncated and trailing fields.

#### Validation

Round-trip and malformed proposal cases and existing ownership guards pass under `cabal test all` from `core/`.

2026-11-23: Provider digests include backend realization information computed in the executing frame, and the
existing next-node request has no effect body. The originally proposed coordinator change exceeds one bounded
sprint. The representation, local preflight, request and coordinator adoption are split below; no digest will
be inferred from an operation key or treated as authority merely because it was proposed. A bounded codec
and malformed-input cases passed focused validation, including invalid UTF-8, version, count, duplicate keys,
empty fields, separators, oversized fields, truncation and trailing bytes. The private ownership guard and all
22 documentation-validator cases passed. Native Windows `cabal test all -j1 --test-option=-j1
--test-option=--hide-successes` passed all 5,638 core tests in 827.58 seconds; the optional Incus provider-live
lane reported Unsupported.

#### Remaining Work

None.

### Sprint 17.71f: Declare a pure step effect preflight [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/test/StepSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Allow a step to declare a pure effect preflight that describes its operation keys, unknown phases and call
digests without executing its effectful `StepAction`. An absent declaration remains explicit during adoption.
The plan-bound invocation, runtime evidence and production-step adoption are separate following work.

#### Deliverables

- A step may retain a pure preflight independently of its action, and an undeclared preflight is observable.
- Reading or evaluating a preflight never invokes the step action.

#### Validation

Step cases prove an absent declaration, exact proposed coordinates and that preflight does not execute the action,
under `cabal test all` from `core/`.

2026-11-23: Steps now retain one optional pure `HostConfig`-based effect preflight separately from the action;
the public export pin and focused cases are updated. The declaration does not yet carry backend realization
evidence, bind to a plan, or feed the routed lifecycle. Both new preflight cases, all 57 `StepSpec` cases, the
public export pin and all 22 documentation-validator cases passed. Native Windows `cabal test all -j1
--test-option=-j1 --test-option=--hide-successes` passed all 5,640 core tests in 839.49 seconds; the optional
Incus provider-live lane reported Unsupported.

#### Remaining Work

None.

### Sprint 17.71g: Bind effect preflight to the admitted plan [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

A preflight runs only for its exact admitted planned node. Its ordered proposed operation keys must match the
node and its declared projections. Missing, malformed or foreign proposals refuse without running the step
action. The result is descriptive; the authenticated route and later effect check establish authority.

#### Deliverables

- The private plan kernel produces an opaque plan-indexed preflight result only from the exact planned step.
- Canonical snapshot bytes stay unchanged; the proposal is descriptive and cannot authorize an effect.

#### Validation

Plan cases cover missing and mismatched proposals, canonical successful preflight, action non-execution and
snapshot compatibility under `cabal test all` from `core/`.

2026-11-23: A private, nominally plan-indexed result now checks proposed operation keys against the exact
admitted node and its projections. An initial snapshot-field approach was removed after identifying that the
version-10 recovery readers require a fixed field count; proposals are descriptive and the later signed route
and effect check, not a snapshot change, must establish authority. The first focused build also exposed a
reserved test variable name; it was corrected. The preflight refusal, success, action non-execution and snapshot
compatibility cases pass, as do all 148 project-plan cases and all 22 documentation-validator cases. Native
Windows `cabal test all -j1 --test-option=-j1 --test-option=--hide-successes` passed all 5,641 core tests
in 839.67 seconds; the optional Incus provider-live lane reported Unsupported.

#### Remaining Work

None.

### Sprint 17.71h: Project provider binding without an effect [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Expose the existing provider-backend admission as a pure, generative binding projection for preflight. The
projection and the eventual strong-backend discovery share the same executable check and fingerprints; it
must run no provider command and grant no prepared operation.

#### Deliverables

- Preflight can obtain the exact provider binding only after the existing retained-client check succeeds.
- Strong-backend discovery reuses that same admission rather than duplicating its decisions.

#### Validation

Provider cases compare the projected binding with the eventual backend and reject substituted clients without
commands, under `cabal test all` from `core/`.

2026-11-23: Provider realization is selected in the executing frame. The admission check itself is pure, but
provider provision and readiness currently share one gate even though they describe different effects. This
sprint exposes only the read-only binding; successive effect prepares and step adoption remain outstanding.
The four focused provider realization cases passed, including matching digests and substituted-client refusals;
all 266 provider backend cases and the public export pin passed. The phase-15 evidence set also covers this
provider directory, so this change expired its deferred evidence; Sprint 15.63 is active and must close before
this sprint proceeds. The full core gate for this sprint remains outstanding.

#### Remaining Work

- Implement and validate pure provider-binding admission.

### Sprint 17.71i: Supply runtime evidence to effect preflight [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Extend the preflight's input with read-only evidence required for exact runtime backend realization, and adopt
it at shipped and project step constructors. The same digest must be used by the eventual adapter. A live
provider action currently uses one gate for both provision and readiness, whose phase and digest differ; it must
obtain successive journaled effect gates rather than reuse one. Split further if adoption exceeds ? G.

#### Deliverables

- A plan-bound preflight obtains the exact effect proposal from actual runtime evidence before each effect.
- Shipped and project steps adopt the preflight or refuse the effect-aware route when evidence is unavailable.

#### Validation

Plan and step cases prove exact runtime coordinates and refusal of missing evidence under `cabal test all` from
`core/`.

#### Remaining Work

- Implement and validate runtime evidence, successive prepares and step adoption.

### Sprint 17.71j: Route and validate effect proposals [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Carry the frame's effect proposal to the root in its authenticated, session-bound exchange. The root checks
its ordered operation keys against the admitted node, journals the supplied effects and signs the exact gate
packages; a proposal alone is never authority. Split the protocol and caller adoption if it exceeds ? G.

#### Deliverables

- The next-node route carries and validates a canonical effect proposal before any Unknown write.
- The coordinator uses the effect-aware rooted grant to sign the committed packages.

#### Validation

Rooted request and grant cases prove malformed, reordered or foreign proposals are refused before a journal
write and matching proposals are recorded, under `cabal test all` from `core/`.

#### Remaining Work

- Implement and validate the authenticated proposal route and coordinator adoption.

### Sprint 17.71k: Reify effect coordinates in the frame executor [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

The executor copies the journaled effect coordinates from the authenticated gate package into the locally
minted gate, refusing malformed or mismatched package fields.

#### Deliverables

- The routed gate mint receives both coordinates exclusively from verified signed bytes.

#### Validation

The routed executor and malformed gate cases pass under `cabal test all` from `core/`.

#### Remaining Work

- Adopt the signed effect fields at the routed executor mint and validate the route.

### Sprint 17.71l: Refuse gates for a different effect [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`, `core/hostbootstrap-core/test/PrepareFixture.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

A gate authorizes exactly the effect whose unknown phase the journal recorded: the same resource, the same
transition, and the same call digest. A gate published for an acquisition cannot prepare a destroy of the same
resource, so after a crash the journal's unknown phase always names the effect that may have run. The gate and
its prepare belong to the prepared-operations phase (Phase 11), but `mintPreparedGate` has a routed caller in
this phase's `Lifecycle/FrameExecutor.hs`, so changing its coordinates lands here, where every file it touches
exists.

#### Deliverables

- `PreparedGate` carries the recorded unknown phase and the call digest beside its plan, operation, session,
  fence, attempt, and journal version; `mintPreparedGate` takes them as `GateUnknownPhase` and `GateCallDigest`
  coordinates.
- `withPreparedGate` takes the call digest beside the unknown phase, writes both into the durable operation
  record, and mints the gate from the re-read record; `gateFor` in `Lifecycle/FrameExecutor.hs` copies both
  from the authenticated response.
- An `OperationDescriptor` carries the unknown phase its transition journals (`ReservationOutcomeUnknown` for
  an acquisition, `AdoptionOutcomeUnknown` for an adoption, `PhaseEffectOutcomeUnknown` with its from and to
  phases for a phase transition), derived by the plan rather than supplied by the caller.
- `withPreparedOperation` refuses with a `Conflict` a gate whose unknown phase or call digest differs from the
  descriptor's, before any other dependency work.
- The `FrameExecutor` change is the one routed mint call site; if the four production modules exceed § G's
  400-line bound, the routed adoption splits into a following sprint.

#### Validation

The sprint closes when these exist and pass under `cabal test all` from `core/`: a `ReconcileSpec` case "a gate
recorded for an acquisition cannot prepare a destroy of the same resource" that records
`ReservationOutcomeUnknown` for a provider resource and asserts `withPreparedPhaseTransition` over `planDestroy`
of that resource returns the `Conflict` with no package; a `ReconcileSpec` case "a gate recorded under another
call digest cannot prepare" asserting the same refusal for a matching transition and a different call digest;
and the existing `SessionSpec` and `ReconcileSpec` prepare cases passing with `test/PrepareFixture.hs`'s
`gateFor` and `gateForValues` taking the unknown phase and call digest.

#### Remaining Work

- `withPreparedOperation` matches the gate on plan digest and operation key only, and
  `plannedOperationFromGraph` sets the operation key to `plannedResourceKey`, while `PreparedGate` records
  neither the unknown phase `withPreparedGate` wrote nor a call digest. A gate published for a
  `ReservationOutcomeUnknown` write on resource R therefore prepares a destroy of R whose
  `PhaseEffectOutcomeUnknown` was never journaled. Add the two gate coordinates, thread them through
  `withPreparedGate`, the `FrameExecutor` mint, and `PrepareFixture`, add the descriptor's journaled unknown
  phase, add the refusal to `withPreparedOperation`, and add the two `ReconcileSpec` cases named in Validation.

### Sprint 17.72: No exposed module produces a prepared gate [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `core/hostbootstrap-core/test/PrepareFixture.hs`,
`core/hostbootstrap-core/provider-live/ProviderLiveAliasFixture.hs`,
`core/hostbootstrap-core/test/compile-fail/OpenFrameExecutorGate.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

The prepared-operations phase (Phase 11) makes `PreparedGate` opaque and its local producer `withPreparedGate`.
The exposed `HostBootstrap.Lifecycle.Prepared` still exports `recordDurableUnknown`, a second producer whose
callers are the providers phase's `provider-live/ProviderLiveAliasFixture.hs` and whose compile-fail boundary is
this phase's `test/compile-fail/OpenFrameExecutorGate.hs`. Moving it out of the exposed surface lands here, where
every file it touches exists, and the producer Haddocks name the routed mint site this phase introduces.

#### Deliverables

- No exposed module exports a function that returns a `PreparedGate`. `recordDurableUnknown` lives in a
  `visibility: private` sublibrary that also holds `Prepared.Internal` (the `lifecycle-dependency-internal`
  pattern in `hostbootstrap-core.cabal`), and the export list of `HostBootstrap.Lifecycle.Prepared` drops it.
- `test/PrepareFixture.hs` and `provider-live/ProviderLiveAliasFixture.hs` import it from that sublibrary.
- The module header and function Haddock in `Lifecycle/Prepared.hs` and the `withPreparedOperation` Haddock in
  `Reconcile.hs` name both production mint sites, `withPreparedGate` in `Session.hs` and `gateFor` in
  `FrameExecutor.hs`, and what each verifies.

#### Validation

The sprint closes when these exist and pass under `cabal test all` from `core/`: the `CompileFailSpec`
diagnostic `Module 'HostBootstrap.Lifecycle.Prepared' does not export 'recordDurableUnknown'` from the import
added to `test/compile-fail/OpenFrameExecutorGate.hs`, and a `ProjectPlanSpec` `sites "recordDurableUnknown"`
allowlist, beside the `mintPreparedGate` one, naming no module under `src/`.

#### Remaining Work

- `recordDurableUnknown` is exported from the exposed `HostBootstrap.Lifecycle.Prepared`, and the
  `ProtectedSession` it takes is reachable through the re-exported `HostBootstrap.Protected`. It runs one
  compare-and-swap on a caller-chosen `RecordKey` with no permit, open-session, registration, or fence check,
  and copies caller-chosen plan, operation, session, fence, and attempt onto the gate, so a downstream project
  can mint a gate that `withPreparedOperation` accepts without the operation's journal row ever reaching an
  unknown phase. No module under `src/` calls it. Move `Prepared.Internal` out of the public library's
  `other-modules` into a `visibility: private` sublibrary, move `recordDurableUnknown` into it, drop it from
  the export list of `HostBootstrap.Lifecycle.Prepared`, and import it from the sublibrary in
  `test/PrepareFixture.hs` and `provider-live/ProviderLiveAliasFixture.hs`.
- Add the `recordDurableUnknown` import to `test/compile-fail/OpenFrameExecutorGate.hs` with the expected
  diagnostic in `CompileFailSpec`, and the `sites "recordDurableUnknown"` allowlist in `ProjectPlanSpec`.
- Add `gateFor` in `FrameExecutor.hs` as the routed mint site to the producer Haddocks in `Lifecycle/Prepared.hs`
  and `Reconcile.hs`.

### Sprint 17.73: Rooted request kernels take the nominal lifecycle coordinates [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

The authenticated handoff phase (Phase 13, Sprints 13.43 through 13.49) gives the rooted input roles private
checked scalars and retypes the kernels whose callers it owns. The five post-open request builders and
`rootedOpenedResponseUnsignedKernel` are called only from this phase's modules, so retyping them, and adopting
the newtypes at those callers, lands here (§ HH).

#### Deliverables

- `rootedOpenFrameRequestKernel` retains its nonce-only shape. The five post-open builders
  `rootedNextNodeRequestKernel`, `rootedSettleNodeRequestKernel`, `rootedDescendResultRequestKernel`,
  `rootedCloseFrameRequestKernel` and `rootedReceiptConfirmRequestKernel` take `LifecycleSession`, `LifecycleStage`, `LifecycleOrdinal`, and `PredecessorDigest` instead of
  `Text`/`Word64`.
- `rootedOpenedResponseUnsignedKernel` takes `RequestDigest`, `LifecycleSession`, `LifecycleStage` and
  `LifecycleOrdinal`, retaining its existing nonzero ordinal rule.
- `Handoff.Process.Route`, `Lifecycle.FrameExecutor`, `Lifecycle.Rooted` with its `Node` and `Receipt`
  submodules, and `Command.Child` construct the newtypes at their own boundaries.
- The canonical bytes are byte-identical to the current wire; the change is type-level only. Callers beyond
  the three production modules or 400 lines § G allows this sprint are adopted by a following sprint.

- Adopt the broader request/response descriptive fold-return coordinates at their actual Receipt, Node
  and Command.Child consumers here; that caller closure was not claimed by the earlier two-owner input
  adoptions. Recut this work into bounded call-site sprints before implementation; add no raw compatibility
  shim to hide an over-cap atomic migration.

#### Validation

The sprint closes when the existing `HandoffSpec` golden-byte and round-trip cases and `RecursiveLifecycleSpec`'s
public `up`, `down`, and `destroy` cases pass unchanged under `cabal test all` from `core/`, which proves wire
stability, and the four host static gate commands pass.

#### Remaining Work

- Audit and split the actual kernel/fold-return caller closures into at most three production owners per
  sprint before implementation, preserving all named coordinate and consumer obligations.
- Retype the five post-open request kernels and `rootedOpenedResponseUnsignedKernel` in `Handoff/Rooted.hs` to the
  Sprints 13.43 through 13.49 checked scalars; keep nonce-only OpenFrame unchanged.
- Adopt the newtypes at `Handoff/Process/Route.hs`, `Lifecycle/FrameExecutor.hs`, `Lifecycle/Rooted.hs`,
  `Lifecycle/Rooted/Node.hs`, `Lifecycle/Rooted/Receipt.hs`, and `Command/Child.hs`, splitting into a following
  sprint if the adoption exceeds the § G module cap.

## Remaining Work

- Sprint 17.71h: project the exact provider binding without an effect.
- Sprint 17.71i: supply runtime evidence, successive prepares and step adoption.
- Sprint 17.71j: route and validate the proposal before rooted preparation.
- Sprint 17.71k: reify the signed effect coordinates in the frame executor.
- Sprint 17.71l: refuse gates whose journaled transition or call digest differs from the descriptor.
- Sprint 17.72: move `recordDurableUnknown` into a private sublibrary, with its compile-fail diagnostic and
  `ProjectPlanSpec` allowlist, and name the routed `gateFor` mint site in the producer Haddocks.
- Sprint 17.73: retype the rooted request kernels and the `Opened` builder to the nominal lifecycle
  coordinates and adopt them at this phase's callers.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/ownership_invariant.md` — the surface this phase changes in it.
- `documents/architecture/harness_workflow.md` — the surface this phase changes in it.
- `documents/architecture/generic_project_model.md` — the surface this phase changes in it.

- `documents/architecture/composition_methodology.md` — root-coordinated recursive interpretation,
  catalog-bound descent, storeless executors, and child-first unwind.
- `documents/architecture/hostbootstrap_core_library.md` — root lifecycle entries, rooted sessions, executor,
  and surfaced verbs.
- `documents/architecture/binary_context_config.md` — Phase 13 rooted scope/messages and the process channel.
- `documents/architecture/lifecycle_state_model.md` — root-owned catalogs, per-frame journals, settlement, and
  terminal receipt.
- `documents/architecture/unrepresentable_state.md` — catalog/session/grant/executor/process seals.
- `documents/architecture/durable_state.md` — the sole root store and all compare-and-swap state.

**Engineering docs to create/update:**

- `documents/engineering/composition_patterns.md` — the rooted coordinator/storeless executor pattern.
- `documents/engineering/cluster_lifecycle.md` — exact cluster cleanup call-site adoption.

**Cross-references to add:**

- `development_plan_standards.md` names this phase as owner of the proof-complete host-static lifecycle command
  and Phase 24 as owner of its live worked-demo confirmation.
