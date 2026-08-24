# Phase 17 — The recursive lifecycle command

**Status**: Done
**Current sprint**: None — phase complete
**Depends on**: Phase 13 (authenticated handoff and rooted lifecycle protocol), Phase 16 (cluster lifecycle,
budgets, and cordoning)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, including the real local
process-boundary recursive-lifecycle tests

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
authenticated duplex boundary without a provider, live cluster, or demo. The
[worked-demo phase](phase-24-worked-demo.md) separately owns the live linux-cpu Production sequence and demo
Harness confirmation.

## Sprints

### Sprint 17.1: Independent root gate for the three verbs [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Authorize every lifecycle verb independently of the configuration being interpreted.

#### Deliverables

- `project up|down|destroy` each enter through `verifyOperatorAuthorization` and
  `withVerifiedRootInvocation`.
- The resulting root authority enters only the lifecycle gate indexed by the admitted `ProjectVerb`.
- Decoded configuration remains descriptive plan input and cannot authorize a command.
- No context-declared class, capability, frame name, or payload substitutes for operator/root authorization.
- `project init` remains the sole lifecycle verb that creates initial configuration without interpreting a
  plan.
- An omitted `--source-root` is resolved to the absolute current directory before the project assembler writes
  the sibling config, so the descriptive context and the canonical root admitted by lifecycle entry agree.

#### Validation

Dated linux-cpu evidence covers all three authorized verbs and refusal before lifecycle work when operator
verification fails. `ContextSpec` also executes `project init` from a separate source directory and asserts that
the generated config records its absolute path; the warning-clean core gate passed.

#### Remaining Work

None.

### Sprint 17.2: Current-frame forward interpretation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Drive one admitted frame's exact forward order and derive its declared descent boundary.

#### Deliverables

- `runChainFromFrame` selects only the non-empty segment owned by the current frame.
- `DerivedTopology` identifies a declared child boundary without granting child admission.
- Each node action receives the exact plan-minted execution descriptor.
- The announcing node retains the exact child configuration associated with its descent declaration.
- A node failure stops its subtree and is returned as a structural result.

#### Validation

`ChainSpec` covers frame order, typed descent selection, plan-minted descriptors, and failure containment; the
warning-clean core gate passed on linux-cpu.

#### Remaining Work

None.

### Sprint 17.3: Teardown-forest frame-index propagation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`
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

Dated 2026-08-10 evidence includes `TeardownSpec` 27/27, the eight affected compile-fail groups 8/8,
`DocValidatorSpec` 2/2, and warning-clean library/test builds.

#### Remaining Work

None.

### Sprint 17.4: Closed local/descent teardown work [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
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

Dated 2026-08-10 evidence includes `TeardownSpec` 25/25, sixteen affected compile-fail groups 16/16,
`DocValidatorSpec` 2/2, and warning-clean library/test builds.

#### Remaining Work

None.

### Sprint 17.5: One `ProjectVerb` universe [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Carry the command gate's exact `ProjectVerb verb` through both forward and reverse interpretation.

#### Deliverables

- Reverse plans, forests, work, completion, and settlement retain the admitted `ProjectVerb` index.
- No second teardown-local verb universe or compatibility term exists.
- `ProjectUp` is total but receives a typed refusal before reverse work is exposed.
- Down and destroy remain structurally distinct and select only their declared reverse actions.
- Parser text and caller-selected tags cannot change the verb after root admission.

#### Validation

Dated 2026-08-10 evidence includes `TeardownSpec` 28/28, twenty-seven affected compile-fail groups 27/27,
`DocValidatorSpec` 2/2, and warning-clean library/test builds.

#### Remaining Work

None.

### Sprint 17.6: Frame-bound settlement and root destroy proof [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`
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

Dated 2026-08-10 evidence includes `TeardownSpec` 31/31, the affected compile-fail matrix 39/39,
`ReconcileSpec` 30/30, `LifecycleSpec` 100/100, and `DocValidatorSpec` 2/2.

#### Remaining Work

None.

### Sprint 17.7: Root-resident validated lifecycle-context join [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Context/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Join descriptive binary context to an exact root-coordinator plan/frame package before lifecycle entry.

#### Deliverables

- `ValidatedLifecycleContext` retains the exact root-owned `ProtectedStore`, current frame, project frame, and
  decoded context under nominal indices.
- Root/nested classification describes plan frames coordinated inside the root process; the value is never a
  child-process input or a claim that a child can open the store.
- The join rechecks root, store origin, identities, topology, placement, and live witnesses without reading
  command authority from config.
- A mismatch refuses before any journal, rooted session, catalog, or effect action.
- Package-private eliminators may borrow the store and frame evidence only while constructing root-resident
  coordinator state.

#### Validation

Dated 2026-08-10 evidence includes `ContextSpec` 78/78, seven lifecycle-context compile-fail groups 7/7,
`DocValidatorSpec` 2/2, and a warning-clean complete test build.

#### Remaining Work

None. This evidence remains resident in the root coordinator.

### Sprint 17.8: Opaque root lifecycle entry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
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

#### Remaining Work

None.

### Sprint 17.9: Sealed handoff facade and root-signing admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Expose one handoff facade while keeping every fixed-domain signature inside a live-root-broker operation.

#### Deliverables

- `HostBootstrap.Handoff` is the sole exposed handoff surface and does not reexport protocol/channel internals.
- Hidden `Handoff.Internal` owns the unconstructible root-signing admission `RecoverySigningKernel` and its
  sole producer; the capability name does not make it a generic byte signer.
- Only exact allowlisted hidden owners consume that admission while the root broker and typed input are live.
- Each signing kernel fixes its own canonical domain and typed material and refuses binding drift before use.
- No endpoint, raw channel, signing-key implementation, reusable signer, or recovery capability escapes.

#### Validation

Dated 2026-08-11 evidence includes `HandoffSpec` 47/47, recovery cases 35/35, eight boundary compile-fail
groups 8/8, `DocValidatorSpec` 2/2, and warning-clean library/test builds.

#### Remaining Work

None.

### Sprint 17.10: Durable verb-tagged reverse-root intent [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/durable_state.md`

#### Objective

Persist exact root reverse intent before any reverse effect can begin.

#### Deliverables

- The durable root intent row is indexed by plan, root frame, run, broker generation, and reverse verb.
- Canonical Pending, Running, and terminal rows retain the exact admitted verb and source coordinates.
- Compare-and-swap plus strict readback governs every transition and retry.
- Down and destroy intents cannot be relabelled or share an in-flight slot.
- The substrate performs no teardown effect and exposes no store or raw intent row.

#### Validation

Dated 2026-08-11 focused mode/session tests, source guards, compile-fail checks, and the warning-clean core gate
passed.

#### Remaining Work

None.

### Sprint 17.11: Exact same-verb reverse-root resume and redo [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/durable_state.md`

#### Objective

Resume or redo an admitted reverse verb only from its exact durable intent lineage.

#### Deliverables

- Pending resumes the same plan/run/broker/frame/verb without allocating a second intent.
- Running admits only the exact replay path defined by its durable transition state.
- Terminal state returns a typed terminal observation and performs no effect.
- Cross-verb, cross-run, stale-version, malformed-row, and missing-source input refuses.
- Every branch rechecks state under the root-owned protected-store bracket before returning its fixed result.

#### Validation

Dated 2026-08-11 focused mode tests, retry/concurrency cases, source guards, and warning-clean library/test
builds passed.

#### Remaining Work

None.

### Sprint 17.12: Fresh reverse-root source admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Create the sole absent-to-Pending reverse-root source after exact root admission.

#### Deliverables

- Only the exact live root authority, bound plan, lease, snapshot, frame, and verb can create Pending.
- The absent branch uses compare-and-swap and strict readback before yielding an admitted source.
- A concurrent loser converges only on the exact canonical Pending successor.
- Any conflicting bytes, version, plan, run, broker, frame, or verb refuses without mutation.
- No caller-selected key, version, row bytes, or phase enters the source producer.

#### Validation

Dated 2026-08-11 focused mode tests, absent/concurrent cases, source guards, and warning-clean library/test
builds passed.

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

#### Remaining Work

None.

### Sprint 17.14: Sealed reverse-root lifecycle entry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/ProjectPlan.hs`
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
- No raw authority, intent, store, journal, cursor, or frame coordinate projects from the entry.

#### Validation

Dated 2026-08-11 authority/entry tests, compile-fail and source guards, and warning-clean library/test builds
passed.

#### Remaining Work

None.

### Sprint 17.15: Durable prepared reverse-descent substrate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`
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

#### Validation

Dated 2026-08-11 lifecycle-entry and teardown tests, source/compile-fail guards, and warning-clean builds passed.

#### Remaining Work

None.

### Sprint 17.17: Durable recoverable-open map and token repair [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Map an exact prepared reverse descent to one recoverable handoff opening and repair its token deterministically.

#### Deliverables

- A binding-keyed durable row maps one prepared reverse descent to one canonical recovery opening.
- Token creation and repair derive only from the retained binding and canonical signed material.
- Compare-and-swap, strict readback, and bounded canonical rows govern absent, retry, and repair paths.
- Binding, token, projection, verb, phase, frame, or version drift refuses without opening another edge.
- The map owns no process, child store, executor, lifecycle settlement, or terminal receipt.

#### Validation

Dated 2026-08-11 focused handoff recovery/open tests, source guards, compile-fail checks, and warning-clean
library/test builds passed.

#### Remaining Work

None.

### Sprint 17.18: Bound reverse-descent attachment [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`
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

#### Remaining Work

None.

### Sprint 17.19: Canonical lifecycle completion wire [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`
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

#### Remaining Work

None.

### Sprint 17.20: Lower sealed completion ownership split [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Completion.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (build metadata only)
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Separate lower semantic completion evidence from upper lifecycle reporting without adding process ownership.

#### Deliverables

- Hidden `Handoff.Completion` owns nominal `LifecycleCompletion` and its exact five-symbol lower surface.
- Hidden `Handoff.Lifecycle` owns exactly the two upper completed-forward/completed-reverse reporters.
- Forward completion requires the terminal-origin/config-offer binding; reverse completion requires exact Bound
  verification and `SubtreeSettled`.
- Receiver accepts one strict owner-supplied terminal-report action and constructs no completion evidence.
- Receiver retains only the strict owner-supplied terminal-report action; the complete reviewed attribution is
  337 significant lines and adds no process caller.

#### Validation

Dated 2026-08-12 evidence includes `HandoffSpec` 68/68, `ProjectPlanSpec` 68/68, compile-fail 452/452, the
complete suite 1913/1913 in 388.65 seconds, and `DocValidatorSpec` 2/2. Frozen SHA-256 values are
`2f85e79d42290b22b1ed69522dcdfd1b5e84bf1d3f94b12a150765e0bf444070` for
`HostBootstrap.Handoff.Completion`,
`203bbc49082d7e094bfed17d0630897b11523875092e5d1c0f60ca8326e85a32` for
`HostBootstrap.Handoff.Lifecycle`, and
`e800aae27a5db74a7e94dfa828bf80013ac25ddbf7f2c98131a15153ed029449` for the Cabal file. Attribution is
148 + 120 + 67 source lines plus two Cabal rows = 337; the lower 62-line bound-observation verifier belongs
to the preceding canonical-wire sprint.

`CLISpec` pins the two importers this split leaves the Cabal-private `LifecycleEntry` — `Command.hs` and
`Handoff/Lifecycle.hs` — as a separator-neutral repo-relative allow-list, so the same two modules are
named on every supported outer host realization (§ JJ). It builds those names with
`SourceGuard.repoRelativePath`, the helper the
[Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md) owns; the module ownership the
sprint states is unchanged. On 2026-08-17 the gate passed host-native on Windows 11 Home 10.0.26200
x86_64 (GHC 9.12.4, Cabal 3.16.1.0) at 1,877/1,877, which is the first run to exercise this allow-list
from a native-separator gate host. Cross-family confirmation is the
[host-portability acceptance phase](phase-28-host-portability-acceptance.md)'s (§ JJ).

#### Remaining Work

None.

### Sprint 17.21: Root-resident parent acknowledgement substrate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`
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

#### Remaining Work

None. Root terminal receipt confirmation is completed in Sprint 17.35.

### Sprint 17.22: Routed acknowledgement transport substrate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`
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

#### Remaining Work

None. Sprint 17.36 adopts the Phase 13 rooted protocol into the relay service.

### Sprint 17.23: Finalized forward-child projector foundation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct/Internal.hs`,
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
- This sprint adds no named type and has zero production projector callers outside the planned package builder.

#### Validation

Dated 2026-08-11 evidence includes `CLISpec` 52/52, `ProjectPlanSpec` 67/67, `SchemaSpec` 21/21,
compile-fail 449/449, the complete suite 1909/1909, and `DocValidatorSpec` 2/2.

#### Remaining Work

None.

### Sprint 17.24: Exact planned forward handoff [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Handoff/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (build metadata only)
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Seal exact parent lineage and an independently projected canonical child plan into one forward package.

#### Deliverables

- Hidden `PlannedForwardHandoff` is the sole new type and retains its eight nominal indices privately.
- Its producer proves exact parent/current/context lineage and the topology's immediate parent-to-child edge.
- The finalized projector yields canonical child config, child plan, digest, and `PlanDigestBinding`.
- The package retains the canonical protocol payload, stripped process route, invocation input, and binding
  input, but no live binding, executable, or effect capability.
- This sprint changes two production modules plus one Cabal row, has zero runtime callers, and has exactly 397
  attributable significant lines.

#### Validation

Dated 2026-08-12 evidence includes `ProjectPlanSpec` 68/68, `HandoffSpec` 68/68, compile-fail 451/451, the
complete suite 1912/1912, and `DocValidatorSpec` 2/2. Frozen hashes are
`5c23bb6d9eaed3baa18e7028893134684a34d559c545f34ba2def2237b180654` for `Lifecycle/Plan.hs` and
`eed529e4f5dbdbcade0364cf372136b30f43714810094d8e0ca38d4ed16a054a` for
`ProjectPlan/Handoff/Internal.hs`.

#### Remaining Work

None.

### Sprint 17.25: Recursive rooted plan catalog [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/RootedPlan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Projection/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Handoff/Internal.hs`
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
  evidence join, the admitted context endpoint, and the authority's installed project and durable store
  identity before recursively projecting every declared child.
- One VLC-free immediate-target kernel owns descriptor/context/configuration/target-plan validation for
  recursion, and the immediate `PlannedForwardHandoff` producer delegates to that same kernel.
- Each rank-2 entry binds the existential exact target `ProjectPlan`, `PlanDigestBinding`, `CurrentFrame`, raw
  and stripped plan-owned route, canonical config bytes, both config/payload digests, parent/child edge, and
  the parent frame's plan-owned projected node keys needed by later packages and the local executor.
- Recursion terminates at a frame that declares no descent and is bounded by the root topology's own frame
  count, so a malformed topology refuses rather than descending without end.
- Catalog selection is available only through rank-2 folds on the catalog itself; no second entry/evidence type,
  raw row, child-supplied plan, or nested `ValidatedLifecycleContext` route is introduced.
- Work is limited to the three named production modules, targets at most 400 significant lines, and must split
  before exceeding that bound; it adopts no runtime call site.

#### Validation

The catalog and the shared kernel are hidden `other-modules` with no runtime caller, so a test executable
cannot name either one. Their coverage is therefore exact source and compile-fail guards: export lists,
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

#### Remaining Work

None.

### Sprint 17.26: Digest-proven codec and registry reindex [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Class/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema/Internal.hs`
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

Because both kernels are hidden with no runtime caller, a test executable cannot name either one, so their
behavioural coverage — reindex on equal digests, refusal on unequal digests, and preservation of every
retained term — is owned by Sprint 17.27, which joins them under one recovered specification reachable
through the public recovered-inputs boundary.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-12 at
`1960 tests passed`.

#### Remaining Work

None.

### Sprint 17.27: Recovered finalized-specification reindex [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct/Internal.hs`,
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
- Work is limited to the three named production modules, adds no named type, and adopts no catalog, session,
  journal, or process call site.

#### Validation

`ProjectPlanSpec` covers the joined reindex behaviourally through the public recovered-inputs boundary: the
yielded specification carries the recovered profile's index, its codec label, schema, digest, rendered
configuration, service variant names, and role-wire schema families equal the candidate's, and its retained
builder still regenerates the same draft stream at the recovered index. A matched-registry fixture covers a
project that registers no service, so the finalized registry's own retained digest is proved rather than
relabelled vacuously. The existing refusal cases still refuse on an unequal finalized specification, unequal
validated configuration bytes, and every downstream evidence drift, and none of them touches the protected
store. The internal owner's export list, its `staticProjector` threading, and both edited modules' digests
are re-pinned, and `CrossConfigSpecRecoveredProjectPlan.hs` and
`HarnessCandidateAsRecoveredProjectPlanInputs.hs` keep the candidate index and scope closed.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-12 at
`1962 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. The join adds 46 significant lines across the
two shared owners.

#### Remaining Work

None.

### Sprint 17.28: Root catalog persistence and readback [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/RootedPlan.hs`,
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

`CLISpec` drives the real `project up` command and covers absent creation before the first effect — one
version-1 `catalog.<project>.production.<epoch>` record whose framed tag, installed project, stable profile,
specification digest, root plan digest, and root frame match the same run's bound lease, and whose trailing
count admits no descent edge for a single-frame root plan. An exact retry re-enters at Execute, converges on
the record already present, and leaves it byte-identical at version 1. A conflicting durable manifest refuses
before the reservation: no invocation record is minted, no step effect runs, and the foreign bytes are
untouched. A plan that declares a descent is recursively projected through the shared immediate-target kernel
and its projection refusal likewise precedes the catalog record, the reservation, and every effect.

`ProjectPlanSpec` pins the owner's export list, its single importer, its exact import set, the durable record
name, the framed manifest layout, the strict byte-equality readback, both ceilings, and the absence of a raw
payload frame, alongside the existing nominal/hidden/fold-only guards and the module digest.
`CLISpec` and `ChainSpec` pin the threaded specification at the one call site and the entry's
catalog-before-reservation route. `OpenRootedPlanCatalog.hs` and `OpenLifecycleEntryProducer.hs` keep the
manifest kernels and the durable settlement out of every public facade.

Positive multi-level projection needs a fixture whose forward-child projector actually projects a child; the
core suite's projector refuses by construction, so that fixture and its multi-level admission coverage are
Sprint 17.29's, which is the first sprint whose deliverable consumes an admitted descent entry.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-12 at
`1966 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`.

#### Remaining Work

None.

### Sprint 17.29: Catalog-admitted forward package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/RootedPlan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Handoff/Internal.hs`
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
  catalog row, process, or effect authority; the implemented immediate `PlannedForwardHandoff` remains the
  inert single-edge foundation owned by its introducing sprint.
- Missing, duplicate, sibling, stale, or independently projected data refuses before session/process creation.
- Work is limited to the two named production modules, targets at most 400 significant lines, and adopts no
  process or command call site.

#### Validation

Cover multi-level exact admission and every coordinate/digest/key mismatch; guard eight nominal roles,
fixed-result encapsulation, zero process calls, and zero store exposure, then run the warning-clean core gate.
This sprint also carries the projecting forward-child fixture the core suite still lacks — a one-layer VM
descent whose child configuration, context, and rebuilt child plan are admitted rather than refused — so
multi-level catalog admission through the root entry is covered behaviourally alongside the package.

The catalog gained one rank-2 edge fold. `withRootedPlanCatalogEdgeKernel` selects by exact parent and child
frame — no admitted entry naming the requested child is missing, more than one is a duplicate, and one
reached from another parent is a sibling of the requested edge — and then rechecks the selected entry
against the parent level's own retained plan and current frame, which the private
`withRootedPlanCatalogFrameKernel` borrows without exposing an entry. A retained parent frame that is not
that level's current frame, a descent the parent plan does not declare with exactly the retained raw route,
and projected node keys that are not the parent plan's own are each a refusal, so coordinates, routes, or
keys projected independently of this catalog cannot reach the continuation. The fold discloses the parent
level only as its own `CurrentFrame`; the parent plan is what the rechecks are made against, never what the
continuation receives.

`CatalogForwardHandoff` is produced only through that fold. It rechecks the admitted child against the
evidence the entry itself retains — the child frame is the target plan's own current frame and its validated
configuration's endpoint, the retained child plan digest is both the digest that plan still renders and the
digest its binding carries, the retained configuration and payload digests equal one another and the digest
the canonical payload still hashes to, and both routes remain exactly one lift layer — and only then rebuilds
the binding input from admitted evidence and seals. All thirteen retained fields are forced before either
callback. It retains no lifecycle context, parent plan, or specification index, and its one eliminator
exposes only the stripped route, binding input, and canonical payload under a fixed unit result.

`CLISpec` carries the behavioural half. `Fixture.projectingForwardChildPlan` is the suite's first projector
that really projects: it derives the child configuration from the parent's own retained context exactly as
the kernel's expected-context derivation does, roots it at a canonical POSIX descriptor, and rebuilds the
same declared chain, so the projected plan's frame labels, parent edges, and descent lifts are the parent's.
Driving the real `project up` against a two-frame plan whose host frame descends one layer into a VM, the
run's durable manifest — observed from inside the first effect — frames exactly one admitted descent edge
with its `host-orchestrator-0`/`vm-orchestrator-1` coordinates at version 1 under the same run's bound lease.
The step halts the run at that first effect rather than descending, because executing a real remote frame is
later-sprint work and the core gate must not depend on a live provider.

`ProjectPlanSpec` pins the two owners' export lists, importers, exact import sets, the eight nominal roles,
the hidden constructor's retained fields, both producer signatures, the complete refusal ordering of the edge
fold and the package rechecks, the rebuilt binding input, the fixed-result eliminator, the thirteen-field
forcing, the one-layer route predicate, and each module's digest and significant line count.
`OpenCatalogForwardHandoff.hs` keeps the package, its constructor, its producer, and its fold out of the
public `ProjectPlan` facade, and `OpenRootedPlanCatalog.hs` keeps both new catalog folds out of the public
lifecycle facade.

The two owners hold 391 and 304 significant lines, both under the hard 400-line split boundary; the sprint
adds 60 and 159 significant lines respectively, 219 against a 400-line target.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-13 at
`1968 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`.

#### Remaining Work

None.

### Sprint 17.30: Catalog-produced recovery child package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`
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
- Work is limited to the two named production modules, targets at most 400 significant lines, adds no named
  type, leaves `HostBootstrap.Handoff.Recovery` unchanged, and adopts exactly one recovery-package production
  call site without exposing a store, raw catalog row, config/adapter projection, or polymorphic result.

#### Validation

Cover exact production, config/adapter/package-digest/edge drift, exact Offer routing, retransmission, and
rehydrated recovery; guard that adapter-only input cannot be persisted or transmitted, all bytes are derived,
`Teardown.Internal` holds no `RootBroker`, and no child store route exists, then run the
warning-clean core gate.

`withPreparedReverseDescentKernel` takes the recursive catalog the reverse
root entry was admitted under and selects its edge through Sprint 17.29's rank-2 fold, narrowed so only the
canonical child-configuration bytes and their digest reach this module — no plan, digest binding, current
frame, route, or projected key does. The adapter is still the plan's own reverse projection, and the two are
joined only by Phase 13's frozen `recoveryChildPackageKernel`. Every downstream term then names the complete
canonical package rather than the adapter: the prepared record frames the package digest, the child-config
digest, and the package bytes; the binding input's child-config digest is the package digest; the bind path
opens and validates the offer against the package; and preparation refuses an empty or mismatched catalog
configuration, a package that is not the exact rendering of that configuration and adapter, an over-bound
package, and a conflation of the package and child-configuration digests.

`Command.LifecycleEntry` supplies that catalog. Both root reverse entries now retain a
`RootedPlanCatalog scope planId brokerGeneration catalogId`, admitted by one new top-level sealer from the
recovered finalized specification, root invocation authority, recovered plan, the plan's own retained current
frame, and the root-resident lifecycle context — the same recursion the forward entry admits. It writes no
durable manifest, because Sprint 17.28's Up entry alone owns that record, and Up remains a structural refusal
because only Down and Destroy have a reverse. The reverse producer's continuation narrows to the entry's own
`Either String ()`, matching what Sprint 17.28 did for the forward producer.

`Handoff.Relay` supplies the transport. `offerReverseDescentKernel` is the durable Bound transition wrapped
in the same four-field Offer exchange the ordinary edge uses: it wraps
`withBoundReverseDescentKernel`, whose `open` continuation bounds the embedded payload and calls the new
private `openRecoverableEdgeThroughLink`, which admits only the recovery-adapter-wire kind, requires the
input's parent frame to be this authenticated frame, and hands the complete package — the sole payload the
kernel ever sees — to the link's recoverable open field. `mkHandoffOffer` then proves payload, token, and
opened binding agree, and the durable transition revalidates that offer against the retained package before
its Bound compare-and-swap. Only then does `serve` route the exact constructed Offer through
`offerAuthentication` to the already-installed root signer, transmit the four fields, and enter the existing
challenge loop with the Bound descent bound into the terminal. A refused durable transition becomes one
`RelayRecoveryNotPlanned` refusal on the channel, so a waiting child is told rather than left blocked.

The kernel takes no payload argument, so an adapter-only input is unrepresentable rather than rejected, and
it names no `RootBroker`, `ProtectedStore`, or package constructor. Retransmission is the same exchange: the
root's durable recoverable-open map answers a repeated attempt with the binding and token it already minted,
`mkHandoffOffer` rebuilds the identical offer, and the Bound compare-and-swap converges on the row already
present.

`ProjectPlanSpec` pins the catalog-narrowing fold, the frozen-constructor join, the package-first preparation
ordering, the rebuilt binding input, the revalidation of the catalog configuration/digest/package, the
rerendered expected package, the durable record framing, both widened reverse constructors, the delegation to
the one sealer, the catalog's third importer, and the Relay call site the live Bound transition now has.
`HandoffSpec` pins the package-valued bind path, the widened `HostBootstrap.Handoff.Recovery` and
`recoveryChildPackageKernel` attributions, the kind-separated openers, the ordered
bind/open/authenticate/transmit route, and the absence of any broker, store, or package constructor in it.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-13 at
`1968 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`.

#### Remaining Work

None.

### Sprint 17.31: Installed recursive handoff runtime [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Runtime.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
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

Cover installed identity/policy success, keyless relay selection, and key, broker, scope, route-policy, and
liveness drift; add hidden-module, role, constructor, path-agnostic/no-session/no-store, and surface guards,
then run the warning-clean core gate.

`Handoff.Runtime` is the sole owner of the all-nominal `RecursiveHandoffRuntime scope brokerGeneration verb`.
Its two arms retain the same derived coordinates — installed project, scope tag, protected-store identity,
broker generation, and installed verification-key digest — plus the closed verb, and only the nested arm also
retains the authenticated frame its keyless relay speaks for. Nothing else is retained: the module names no
store, session, catalog, journal, compare-and-swap, channel, broker link, requester path, protocol tag,
activation manifest, build key, or signing key, and it imports no effect or transport owner. The
lifecycle-only route policy is therefore absence rather than a filter — a runtime cannot express a route to
Activation, Build, or arbitrary protocol traffic because no such term is in scope to express it with.

The root arm is derived from the admitted root environment alone: the invocation authority supplies project,
store identity, generation, and verb, the scope evidence supplies the descriptive tag, and the live broker's
own public half supplies the installed verification identity, which is then cross-checked against the route's
advertised digest. It also requires the route to carry no authenticated current frame, so the path-agnostic
root arm and the frame-bearing nested arm are mutually unreachable. The nested arm is derived from an already
authenticated parent edge and requires the relayed route to name exactly that edge's child frame. Shared
admission refuses an empty coordinate or a zero generation on both arms.

`Handoff.Relay` owns the keyless selection: `withNestedRecursiveHandoffRuntimeKernel` derives runtime and
route from the same received edge and hands the runtime out only beside `relayedBrokerLinkKernel`'s keyless
link, so a nested frame that holds the runtime necessarily holds a route that cannot sign.
`Command.LifecycleEntry` owns the root selection: its fold installs the root arm from a sealed root Up, Down,
or Destroy entry and refuses both child entries. Neither is reached from a command interpreter.

The one eliminator is a fixed-unit fold that discloses whether this frame signs locally, the identity
coordinates, and the nested arm's frame; it exposes no key, store, broker, channel, or route value and admits
no caller-selected result. Coverage is exact source, ownership, and hidden-module guards plus a compile-fail
boundary, because the module has no public surface a behavioural test could reach.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-13 at
`1970 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`.

#### Remaining Work

None.

### Sprint 17.32: Rooted frame session [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`
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
  initial stage, and next nonzero ordinal while `Lifecycle.Session` imports no catalog type.
- A newly root-opened session has no predecessor-response digest. Processing `OpenFrame` triggers its private
  attachment/admission or exact replay, but the request bytes cannot construct or select the session, path,
  stage, ordinal, journal key, or catalog row. A failure before attachment returns Phase 13's existing outer
  `Refused`; rooted `Refused` is post-open only.
- Attachment resolves the sealed external envelope against authenticated scope, runtime, catalog, and the
  session-retained path before mutation. Its replay identity includes exact root lineage, catalog, envelope
  path, and nonce. Only the exact nine-field root-signed `Opened` discloses the canonical path/coordinates;
  strict readback records the lowercase SHA-256 digest of those complete signed bytes as the first predecessor
  before later closed next-node, descent, settlement, completion, and refusal folds become available.
- Work is limited to the two named production modules, targets at most 400 significant lines, and must split
  before exceeding that bound; it adopts no command call site.

#### Validation

Cover root/nested opening, the no-predecessor initial row, root-selected path/opaque coordinates, exact
lineage/catalog/path/nonce replay identity, signed `Opened` digest recording/readback, later
ordinal/predecessor progression, stale catalog/lease, and cross-root-plan/generation/catalog/session/frame
refusal; add seven-role/hidden compile-fail guards and run the warning-clean core gate.

`Lifecycle.Rooted` is the sole owner of the seven-role `RootedFrameSession`, whose two constructors nest the
way the durable states do: Opened retains the root-selected coordinates and the exact row they were published
as, and Attached nests that exact opening with the admitted nonce, the first predecessor digest, and its own
successor row. Neither retains a store, catalog, runtime, request, or response, so an elimination yields
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
keeps that owner byte-identical at its frozen digest and inside its hard 400-line split boundary.

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

### Sprint 17.33: Prepared node grant [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared/Internal.hs`
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
  operation gate, and projected gates. The gate packages carry each exact plan/session/fence/attempt/
  journal-version/operation coordinate selected by the catalog and durable preparation.
- A grant exposes only fixed evidence folds for the node and its durable gate packages, never request,
  response, store, or journal state; only the live root endpoint may turn that evidence into a paired
  `NextNode -> Prepared` response, while `Descend | Refused` has no constructor on this path.
- Work is limited to the three named production modules, targets at most 400 significant lines, and must split
  before exceeding that bound; it adopts no transport call site.

#### Validation

Cover exact Unknown-before-grant ordering, retry, concurrent preparation, all coordinate drift, and signature
binding; guard eight nominal roles and the unchanged hidden mint allowlist, then run the warning-clean core gate.

`Lifecycle.Prepared.Internal` owns the eight-role `PreparedNodeGrant`, beside the `PreparedGate` it already
held. A grant retains the authorized node, that node's ordered dependencies, and the two gate packages from
which the live endpoint produces the canonical signed response; it names no request, response, store, session, record key, or
compare-and-swap operation, so its fixed-unit evidence fold discloses what a frame may do and nothing about
how the root recorded it. The gate package length-frames each coordinate under an explicit domain and
version, and the projected list carries an explicit count. The supersession generation stands where an
ordinary operation gate carries its fence epoch, because for rooted work the broker generation is what
invalidates a prior permit.

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
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Settle an executor observation exactly once and replay only its exact rooted result.

#### Deliverables

- Root settlement validates session, catalog, frame, node, projected gate, nonce, ordinal, and predecessor.
- `SettleNode` and `DescendResult` yield only the exact paired signed `Settled | Refused` family. Exact replay
  returns the durable response; conflict, stale order, or cross-session input refuses without effect.
- Root compare-and-swap records the typed observation and advances only the matching frame session.
- The exact eleven-field response carries the echoed request path/session/nonce plus root-selected successor
  stage/ordinal, and is signed and read back only after that compare-and-swap; this sprint creates no child
  gate or local execution authority.
- Work is limited to the two named production modules, targets at most 400 significant lines, introduces no
  named type, and adopts no unrelated production call site.

#### Validation

Cover exact settlement/replay, conflicting observation, reordered/replayed nonce, key/node mismatch, response
signing/readback failure, and absence of any child-gate mint; run the warning-clean core gate.

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
the supplied signed response must belong to the paired `Settled | Refused` family, echo the same path,
session, and nonce, and select a strictly greater successor ordinal. The observation row is published and
strictly read back before the response digest is taken, so a response can never be recorded for an
observation that was not durably settled.

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
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted/Receipt.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Confirm terminal receipt in the root-owned store after exact executor completion.

#### Deliverables

- Receipt state derives from the exact root session, binding, terminal report, acknowledgement, and completion.
- `CloseFrame` yields only signed `FrameComplete | Refused`; the root first publishes and reads back the exact
  canonical lifecycle report carried by `FrameComplete`, then derives the complete signed-response digest.
- `ReceiptConfirm` must name that exact digest. The root compare-and-swaps Published to Received and returns
  only signed `ReceiptRecorded | Refused`; a successful `ReceiptRecorded` body repeats the exact
  `FrameComplete` digest.
- Exact retry is convergent and never requires the child to persist or reopen receipt state; no other request
  family can publish, confirm, or receive a terminal report.
- Work is limited to two production modules, targets at most 400 significant lines, adds no named type, and
  supplies one combined terminal-receipt helper plus the split durable continuations required by a
  request-at-a-time rooted service.

#### Validation

Cover fresh/replay receipt, lost response, CAS races, report/ack/binding/session drift, and root restart; guard
the absence of child store/receipt operations and run the warning-clean core gate.

The Published-to-Received transition this sprint needs already exists as `publishLifecycleReportKernel` and
`receiveLifecycleAcknowledgementKernel`, whose exact-row replay is already convergent, and whose fresh,
replayed, conflicting, and absent-row behaviour the durable lifecycle-acknowledgement substrate already
covers. Both consume the hidden `RecoverySigningKernel`, whose importer allowlist is exactly four modules and
does not include any rooted owner. The one terminal-receipt call site therefore belongs in `Handoff.Relay`,
which already holds that capability, leaving the rooted owner to hold only the session/binding validation and
the two digest derivations — which is why widening that allowlist is not part of this sprint.

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
recorded-repeats-completion check, the sole call site's continuation order, and all three rooted owners' line
budgets. `HandoffSpec` keeps `Handoff.Protocol` and the `Handoff` facade byte-frozen at their existing
digests across the change. `CompileFailSpec` pins the new owner's hidden-module boundary.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-13 at
`1975 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. `Lifecycle.Rooted.Receipt` stands at 202
significant lines, `Lifecycle.Rooted` is unchanged at 286, `Lifecycle.Rooted.Node` at 231, and the
`Handoff.Relay` call site adds 35.

#### Remaining Work

None.

### Sprint 17.36: Rooted relay service [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Runtime.hs`
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
- Exact replay under the same root lineage, catalog, envelope path, and nonce returns the stored byte-identical
  `Opened`; nonce or request bytes alone are never a replay identity. Any ancestry, request, catalog, scope,
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
catalog, an opened session, and a channel at once. Sprint 17.42's root coordinator is the first sprint whose
deliverable holds all four, and Sprint 17.54's real-process gate is where the exchange runs across an actual
process boundary; both are where the fresh/replay, drift, conflict, truncation, and EOF cases belong.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-14 at
`1976 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. `Lifecycle.Rooted` stands at 355 significant
lines, `Handoff.Runtime` at 159, and `Handoff.Relay` grows from 2,167 to 2,203 — 131 significant lines across
the three owners.

#### Remaining Work

None.

### Sprint 17.37: Storeless frame executor [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
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
  `ExecutionNode` and exact durable coordinates, and only then becomes the sole additional allowlisted caller
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
selector and the absence of any opening-request builder, the compare-before-mint and mint-before-effect
orders, every gate-package coordinate check, the nonempty-observation requirement, the absence of store,
signer, catalog, session, and process names, the empty importer set, and both line budgets. `CompileFailSpec`
adds `ImportLifecycleFrameExecutor.hs` for the hidden-module boundary and `OpenFrameExecutorGate.hs` for the
mint and gate-codec allowlist. `HandoffSpec` re-pins the Cabal digest across the one added module row.

Behavioural coverage needs a caller holding a verified root scope, a reconstructed frame plan, and a channel
at once. Sprint 17.41's forward child receiver adoption is the first sprint whose deliverable holds them, and
Sprint 17.54's real-process gate is where multiple grants in one executor, exact local effects, and crash-safe
redelivery run across an actual process boundary.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-14 at
`1979 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. `Lifecycle.FrameExecutor` stands at 296
significant lines and `Lifecycle.Prepared.Internal` at 207, so the two owners together are well inside the
sprint's 400-line bound.

On 2026-08-21, the five-family selector correction passed its focused source/shape case and the complete
warning-clean core gate on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. `DescendResult` now carries its
nonempty observation through the same executor-owned path and exact retained coordinates as `SettleNode`.

#### Remaining Work

None.

### Sprint 17.38: Protocol-safe lifecycle process route [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Runtime.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Derive a sanitized route that can carry the rooted protocol over child standard I/O.

#### Deliverables

- New hidden all-nominal `LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb`
  is this sprint's sole named type. It points in one direction only — at the child a frame is about to launch —
  and holds no coordinate of that frame's own session, because a middle frame is a nested frame of the root and
  the parent of a deeper child at the same time, and one value carrying both edges would let a frame open a
  session for the child it is spawning instead of for itself.
- Derivation accepts only the catalog forward/recovery packages and their plan-owned lift route.
- Docker uses interactive standard input and `/`; Incus, Lima, and WSL use fixed noninteractive
  working-directory forms, including noninteractive sudo where applicable. A closed grammar rejects
  detach/TTY/attach/stdin/entrypoint/workdir/signal overrides, separators, user payloads, descriptor
  inheritance, and ConfigDelivery.
- Beside the route this sprint adds the one startup step that has no owner yet: a frame's own opening. It is
  not a fold on the route. It admits the nested arm of the frame's own installed runtime, builds the exact
  four-field `OpenFrame` from a fresh nonce alone, carries it through the frame's own carrier, and verifies the
  signed answer against the independently installed key and those exact request bytes, admitting only an
  `Opened`. What it yields is that exact request and that exact signed response and no decoded coordinate, so
  the storeless frame executor built from the pair still verifies both for itself.
- Everything after the opening belongs to `Lifecycle.FrameExecutor`, which already owns the root-selected path,
  session, stage, ordinal, and predecessor and the closed post-open request families. This sprint introduces no
  second owner of those coordinates and builds no post-open request.
- Work is limited to the two named production modules, targets at most 400 significant lines, and must split
  before exceeding that bound; it adopts no spawn call site.

#### Validation

The route's whole claim is that a lift context says where a child runs and says nothing about whether its
standard input and output are free, so the guards are about what the rendered vector cannot contain as much
as what it does. Derivation reads its edge out of the package's own binding input rather than an argument:
the parent and child frames are that input's, a frame reaching itself refuses, and the phase must be the one
that edge belongs to, so a forward descent cannot be relaunched through the reverse producer. Each provider
then renders one written-out shape — Docker interactive at `/`, Incus, Lima, and WSL noninteractive at `/`
with noninteractive sudo where the guest's default user is not root — and the child's command is the fixed,
coordinate-free lifecycle-child entry marker. The authenticated Offer carries the invocation verb, so no
descriptive command argument competes with that signed fact. `ConfigDelivery` is the case
that matters most: it would put a `cat` on the descriptor the root's request and response bytes travel on,
so a route carrying one cannot be derived at all. Container extra arguments, a container that outlives its
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

Both owners have no runtime caller, so their coverage is exact source and compile-fail guards.
`ProjectPlanSpec` pins the route's five-name export set, its Cabal-private placement, the seven nominal roles,
the sole `data` declaration, the minted edge indices, the derive-from-package ordering in both producers, the
binding-input edge and phase checks, the rendered subcommand, the three container refusals, all four provider
argv shapes, the one-layer refusal, the named override list and the option check, the opening's nested-arm
admission and verify-then-yield order, its single refusal branch, the absence of every post-open request
builder, the single verified-response helper, both new runtime-fold fragments, the absence of store, signer,
catalog, executor, and process names, and both line budgets. `CompileFailSpec` adds
`ImportHandoffProcessRoute.hs` for the hidden-module boundary and `RenderLifecycleProcessRouteArgv.hs` for the
lift facade's absence of any sanitized renderer. `HandoffSpec` re-pins the Cabal digest and the rooted
request/response/recovery attribution lists across the one added module row.

Behavioural coverage needs a real child process on the far end of the rendered vector and a real carrier under
the opening. Sprint 17.40's POSIX lifecycle process owner is the first sprint whose deliverable spawns one,
Sprint 17.41's forward child receiver adoption is the first that holds a carrier, and Sprint 17.54's
real-process gate is where the rendered shapes, the opening, descriptor isolation, and crash-safe redelivery
run across an actual process boundary.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-14 at
`1985 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. `Handoff.Process.Route` stands at 255
significant lines and `Handoff.Runtime` at 185, so both owners are well inside the sprint's 400-line bound.

On 2026-08-21, the corrected fixed-marker route passed its focused source/shape case and the complete
warning-clean core gate on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0: all 2,300 tests passed in
136.87 seconds. The route now launches only `--hostbootstrap-lifecycle-child`; the authenticated Offer is
the sole source of the verb and edge coordinates.

#### Remaining Work

None.

### Sprint 17.39: Protocol-safe child standard-I/O isolation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Give the dedicated child receiver private protocol descriptors before any lifecycle callback can touch standard
input or output.

#### Deliverables

- Receiver duplicates the original standard input/output handles for its private binary protocol channel before
  invoking any configuration, plan, executor, or lifecycle continuation.
- Global standard input is redirected to the null device and global standard output to standard error for the
  entire callback, so ordinary reads and diagnostics cannot steal or corrupt protocol bytes.
- One bracket flushes, redirects, restores, and closes every duplicate on success, refusal, exception, or
  cancellation; protocol standard output remains binary and diagnostics remain field-free.
- The linux-cpu implementation has one source-guarded `GHC.IO.Handle` duplication policy and no ambient
  stdin/stdout heuristic, alternate descriptor, raw channel argument, or exported testing seam.
- Work is limited to the one named production module, targets at most 400 significant lines, adds no named
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
bracket and its helpers stay private, the module's export list is exactly six names, and the bracket holds
the receiver's only channel construction, so no ambient terminal or environment heuristic, alternate
descriptor, raw channel argument, or exported testing seam exists.

`HandoffSpec` pins the export list, the Cabal-private placement, the channel-free and handle-free entry
signature, the two-bracket structure, the acquisition order, both redirections, the independent restores, the
closing of all five duplicates, the host-selected null device, the absence of a named type, the absence of
every ambient-descriptor and process identifier, the private helper set, the seam absence, and the work's
line budget. The rooted-carrier sprint's frozen receiver baseline joins its two already-frozen peers as a
constant, so that sprint's own nine-line delta stays exactly what it was rather than growing with every later
sprint that touches the receiver, and the frozen receiver-source digest is re-pinned across this change.

Behavioural coverage over real pipes needs a process on the far end of those descriptors. The owner is
Cabal-private, has no runtime caller, and this sprint adds no testing seam, so the core suite cannot drive
it here. Sprint 17.40's POSIX lifecycle process owner is the first sprint whose deliverable spawns a child
through the sanitized route, and Sprint 17.54's real-process gate is where binary framing, callback stdin
EOF, stdout-to-stderr redirection, restoration, descriptor closure, exceptions, and cancellation run across
an actual process boundary.

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
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (build metadata only)
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Own the child process, duplex descriptors, fixed control deadlines, cancellation, and reap in one bracket.

#### Deliverables

- The owner spawns only an exact `LifecycleProcessRoute` into a new process group with isolated descriptors.
- One bracket owns stdin/stdout/stderr closure, relay lifetime, the fixed runtime completion operation, and child
  wait. No caller supplies a callback, deadline, grace value, process shape, or channel; the owner's constants
  bound launch and TERM grace and the relay's bound the scope/admission and control-frame waits, while
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
command name cannot be executed even if one reached the argument vector, and an opened route refuses before a
process exists, because it already has a child on the far end of its descriptors. One process shape exists at
all: private pipes for standard input and output, inherited standard error, its own group, and closed
descriptors. The release path runs on normal return, refusal, protocol failure, exception, and asynchronous
cancellation alike — group TERM, fixed grace, group KILL if the group is still present, an unconditional wait,
and only then the pipes — and it signals the group rather than the process, which is what makes a shell or
provider the child launched go away with it.

The deadline shape is the part worth stating carefully, because getting it wrong is invisible until something
slow is legitimate. The owner bounds the launch, since a child that never reaches its first frame is
indistinguishable from one that never started, and bounds the termination grace. Everything else that can be
bounded belongs to the relay, which is why the relay is a production module of this sprint: it now receives
the challenge and the acceptance of the offered digest under a fixed control-frame deadline whose expiry is
its own closed refusal, and deliberately leaves the wait that follows admission unbounded. That wait is the
admitted backend effect, and the effect keeps its own closed policy; one wall-clock deadline across it would
turn every slow provisioning step into a protocol failure. A child that is working is not a child that has
stopped talking.

Nor does exiting mean succeeding. EOF on the pipe, a zero exit status, reassuring text on standard error, and
a closed channel are all things a child that never completed its edge can produce, so the only thing reported
as success is the rooted completion the relay obtained and the root recorded — reached through the fixed
completion kernel for the edge's direction rather than a caller-selected one.

`HandoffSpec` pins the owner's two-name export set, its Cabal-private POSIX-conditional placement, the absence
of a named type, both fixed completion compositions, the admitted-route-and-absolute-path launch order, the
single process shape, the launch bound as the owner's only deadline, the full termination-and-reap order, the
group signal, the release-path bracket, the absence of every store, broker, catalog, and executor identifier,
the relay's bounded control frame beside its unbounded serving wait, the route's admitted-only launch fold,
and both line budgets. `CompileFailSpec` adds `ImportHandoffProcess.hs` for the hidden-module boundary. The
rooted-transport sprint's frozen relay figure joins its already-frozen peers as a constant, so that sprint's
own increment stays what it was rather than growing with every later sprint that touches the relay, and the
relay source and Cabal digests are re-pinned.

Behavioural coverage over real local processes needs a command path that reaches this owner. It has no command
call site by deliverable, so the cases the objective names — success, refusal, crash, partial write, timeout,
long-running admitted work, cancellation, TERM grace, KILL escalation, descendant cleanup, descriptor closure,
and reap — run in Sprint 17.54's real-process gate, which drives the whole recursion through the public
command gate once Sprints 17.41–17.51 have adopted it.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-14 at
`1985 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. `Handoff.Process` stands at 157 significant
lines and `Handoff.Process.Route` at 398; the relay increment is 13 lines, so every owner is inside the
sprint's 400-line bound.

The owner's placement is what makes its fixture platform-conditional. `Handoff.Process` is a
POSIX-conditional module, so on a Windows outer host it is unreachable because the package does not build
it rather than because it is hidden, and `ImportHandoffProcess.hs` expects the diagnostic its host
actually produces (§ JJ): `Could not load module … it is a hidden module` on POSIX, and
`Could not find module …` on Windows. The guard asserts unreachability from a public importer on both,
and the sibling `ImportHandoffProcessRoute.hs` stays unconditional because `Handoff.Process.Route` is
built and hidden everywhere. On 2026-08-17 the gate passed host-native on Windows 11 Home 10.0.26200
x86_64 (GHC 9.12.4, Cabal 3.16.1.0) at 1,877/1,877, including both fixtures. Cross-family confirmation is
the [host-portability acceptance phase](phase-28-host-portability-acceptance.md)'s (§ JJ).

#### Remaining Work

None.

### Sprint 17.41: Forward child receiver adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/FrameExecutor.hs`,
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
line budget. The warning-clean core gate covers the existing real Receiver framing and process primitives;
the phase-level real-process matrix composes them with the root coordinator once that adjacent sprint exists.

On 2026-08-21, the focused forward-child ownership guard passed on x86_64 Linux with GHC 9.12.4 and
Cabal 3.16.1.0. The complete `cabal test all --ghc-options=-Werror` gate then passed all 2,301 tests. The
new private owner stands at 351 significant lines; together with its four-line CLI adoption it remains below
the sprint's 400-line limit.

#### Remaining Work

None.

### Sprint 17.42: Root coordinator and Chain adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/RootedPlan.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

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
  completion evidence, and the child-first terminal continuation are produced by the semantic-completion owner,
  so this coordinator refuses `CloseFrame` and `ReceiptConfirm` until that evidence exists.
- The root lifecycle link exposes only the forward edge, rooted exchange, and fixed completion capabilities;
  activation and recovery signing are absent rather than populated with placeholder authority.
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

#### Remaining Work

None.

### Sprint 17.43: Semantic report and completion integration [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/TerminalReport.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Completion.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted/Receipt.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Produce canonical semantic completion only after the root coordinator settles the terminal frame state.

#### Deliverables

- New lower `Handoff.TerminalReport` accepts only canonical terminal-origin bytes plus exact typed settlement
  input and imports no `Command`, `LifecycleEntry`, `Chain`, process, or store owner; the implemented upper
  `Handoff.Lifecycle` package remains unchanged and is never imported by Process or Chain.
- `LifecycleEntry` is the sole origin producer/caller and invokes `TerminalReport` only after exact rooted
  frame-session completion.
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

#### Remaining Work

None.

### Sprint 17.44: Reverse Adopted replay proof rehydration [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Completion.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Rehydrate reverse semantic proof from exact root-resident Adopted state after restart or response loss.

#### Deliverables

- Rehydration joins Adopted binding/report/acknowledgement to Bound descent and root frame journal state.
- Canonical reverse observations are decoded and verified against the exact plan-owned teardown work.
- The same lower `LifecycleCompletion` producer is used for live and rehydrated branches.
- Drift or incomplete parent/session state refuses without reopening a token, child process, or local effect.
- Work is limited to the three named production modules plus their focused source/behavior guard, targets at
  most 400 significant lines per coherent owner, introduces no
  named type, and adopts no unrelated production call site.

#### Validation

Cover restart before/after acknowledgement, response loss, exact Adopted replay, corrupt observations, and
binding/session drift; guard the one proof producer and run the warning-clean core gate.

On 2026-08-21, the focused handoff, project-plan ownership, and documentation gate passed all 184 tests on
x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. The complete
`cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate then passed all 2,302 tests.
The gate covers the existing live Reported/Acknowledged/Adopted transition and reverse-report corruption,
binding, observation, and replay cases, while the new source/ownership guards prove that restart recovery
first rehydrates the exact child Bound row, then read-only verifies the exact parent Adopted row, and feeds
the retained canonical acknowledgement through the same lower `LifecycleCompletion` producer as the live
branch. No token, process, effect, or compare-and-swap operation is reachable on that replay path.

#### Remaining Work

None.

### Sprint 17.45: Reverse child executor adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Executor/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Adopt an authenticated recovery child package into the same storeless frame executor.

#### Deliverables

- Receiver exposes canonical config and adapter bytes only after the distinct complete-package and child-config
  digest claims, exact package decoded from the authenticated payload, and catalog edge all agree.
- A lower storeless reverse verifier derives exact local work from the projected plan and root-signed rooted
  responses; it imports neither `Teardown.Internal`, `ProtectedStore`, lifecycle context, nor root cursor state.
- Descendant reverse work returns a closed descent result for root-coordinator continuation.
- Child completion returns observations only; root owns settlement, proof, and receipt confirmation.
- Work is limited to the three named production modules, targets at most 400 significant lines, adds no named
  type, and adopts at most the one reverse child receiver call site.

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

#### Remaining Work

None.

### Sprint 17.46: Exact cluster cleanup adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Adopt Phase 16 cluster cleanup at the exact root lifecycle call site.

#### Deliverables

- Root lifecycle entry derives the cluster cleanup package from its admitted plan and verb.
- Cleanup is admitted at the declared plan position through its exact durable `PreparedGate`; Sprint 17.51's
  shared reverse driver supplies that gate and consumes the returned typed observation in the ordinary settle
  continuation.
- Down and destroy select their exact retained/released policies without caller flags.
- Failure yields a typed observation and enters the shared reverse continuation without bypassing child work.
- Work is limited to the two named production modules, targets at most 400 significant lines per coherent
  addition, adds no named type, and pre-adopts exactly the sealed root-entry cluster-cleanup seam that Sprint
  17.49's one shared reverse-command call site drives.

#### Validation

Cover exact policy/verb/plan binding, order relative to frame work, retry, partial failure, and no duplicate
cleanup; run focused reconcile/command tests and the warning-clean core gate.

On 2026-08-21, the focused cluster reconcile/backend, reverse-entry ownership, indexed-plan, and
documentation gate passed all 123 selected tests on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. The
complete `cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate then passed all 2,305
tests. Existing typed cleanup behavior covers exact removal, retry/already-absence, replacement preservation,
partial failure, and origin retention. The new ownership guard proves the root seam checks the exact plan
digest, prepared operation, and plan-derived `DeleteCluster` action in order; only then does the closed verb
select Down or Destroy. Exceptions become the ordinary typed failed teardown observation, and no Boolean,
raw store operation, new type, or second cleanup call site was added.

#### Remaining Work

None.

### Sprint 17.47: Reverse terminalization and rearm [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`
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

#### Remaining Work

None.

### Sprint 17.48: Prepared reverse process route [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`,
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

Cover canonical package recovery, nominal route retention, route sanitization, platform refusal, and process
cleanup; run the warning-clean core gate.

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
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`
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

#### Remaining Work

None.

### Sprint 17.50: Root-authorized nested reverse descent [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`,
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

#### Remaining Work

None.

### Sprint 17.51: Shared authenticated reverse driver [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`
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
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority/FailedUp/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Authorize cleanup of only the effects made reachable by one exact failed Up without forging Destroy authority.

#### Deliverables

- New hidden all-nominal `FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId` is this sprint's
  sole named type and cannot be used as `RootInvocationAuthority ... VerbDestroy`.
- Its producer consumes exact `VerbUp` root authority, catalog identity, failed rooted session state, and the
  immutable set of operations reached before failure; unresolved settlement outside that set refuses.
- Fixed folds authorize only child-first cleanup of those reached operations under the same invocation and
  cannot create a general reverse Pending intent, close Production mode, or target another plan/catalog.
- Exact retry reopens the same failed-Up cleanup coordinates; altered failure, reachability, generation, or
  catalog state refuses without a process or effect.
- Work is limited to the three named production modules, targets at most 400 significant lines, and adopts no
  command call site.

#### Validation

Cover root/VM/container failure authority, partial settlement, exact retry, every cross-coordinate refusal,
constructor hiding, nominal roles, and inability to substitute Destroy authority; run the warning-clean gate.

On 2026-08-21, the focused indexed-plan authority and representation suite passed all 86 tests on x86_64
Linux with GHC 9.12.4 and Cabal 3.16.1.0. The complete
`cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate then passed all 2,308 tests.
The hidden four-index authority is produced only from a sealed root Up entry, its existential catalog, and an
attached root-issued `refused` session. Project, broker generation, catalog identity, and root plan digest are
rejoined; reached and unresolved operation sequences are duplicate-free and subset-related; exact retry
compares every retained failure/reachability coordinate. Its only work fold yields the frozen unresolved
sequence, while source and export guards prove it imports no Mode/store mutation, names no Destroy authority,
has nominal roles, and remains absent from every public facade.

#### Remaining Work

None.

### Sprint 17.53: Failed-Up unwind adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/TerminalReport.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Executor/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Route failed forward work through the shared child-first machinery under its narrow cleanup authority.

#### Deliverables

- A typed Up failure freezes exact reached and unresolved frame state before requesting cleanup authority.
- The one failed-Up command call site runs only work admitted by `FailedUpUnwindAuthority` through the shared
  child-first process/executor path; it never opens a Destroy root or reverse Pending intent.
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
exact dual terminal reporting; run the warning-clean core gate.

The Chain has a no-new-type failure-returning interpreter that records the exact ordered operation prefix
only after each durable Prepared gate is published; the forward coordinator preserves the tuple across its
fixed `Either Text` broker continuation and the existing public interpreter still erases it to descriptive
failure. `failedUpTeardownPlanKernel` retains `VerbUp`, refuses duplicate, foreign, or reordered operation sets,
and admits the reached evidence as an ordered subset of the plan's own and projected keys. It selects
destroy-strength cleanup actions only for removable own nodes, excluding preservation-only nodes and projected
relations, so it cannot promote to Destroy settlement. The child now stops after the first durably settled failed observation, requests early frame
closure, authenticates and receipts a canonical `forward/failed` terminal report, then returns the original
failure separately; malformed or trailing observation frames are refused before settlement. Failed reports
now retain the canonical ordered settled-observation rows, and the coordinator freezes those child rows with
the root Chain prefix before joining the receipt-recorded session, exact report, exact Offer binding, catalog,
and root authority. The hidden authority verifies that every report operation belongs to that frozen prefix.
The live failure call site now drives the joined forest through the durable shared Prepared/Bound rooted
recovery service; the authenticated recovery receiver admits the narrow Up/teardown adapter while the command
cursor remains at Execute, and the child reconstructs only the ordered operation projection carried by that
adapter. Root-local failure now publishes its own canonical failed-forward record before deriving the same
narrow authority, successful cleanup publishes a distinct canonical reverse-completed record, and cleanup
failure publishes a reverse-failed record without replacing the retained original forward error. Canonical
failed-forward observations are covered by the lifecycle codec suite; the source/representation gates cover
the authority, no-Destroy call path, Up/teardown adapter, and shared process/executor adoption. The complete
host-static core suite passed all 2,309 tests on x86_64 Linux with GHC 9.12.4, and the library/executable build
passed with `-Werror`. Sprint 17.54 owns the already-declared real-process root/VM/container, crash-redelivery,
retry, cleanup-failure, and exact dual-report proof matrix.

On 2026-08-23, `RecursiveLifecycleSpec` passed 6/6 through real root/VM/container processes, including a
failed Up followed immediately by exact reverse recovery. The complete warning-clean core gate passed
2,442/2,442 in 179.14 seconds; the focused `TeardownSpec` group passed 36/36, including reached
preservation and projected-relation evidence.

#### Remaining Work

None.

### Sprint 17.54: Proof-complete host-static real-process gate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/fixtures/recursive-lifecycle/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`,
`documents/engineering/composition_patterns.md`

#### Objective

Close the recursive command with static proofs and real local process-boundary behavior.

#### Deliverables

- One local root/VM/container fixture exercises forward, Down, Destroy, and failed-Up unwind.
- Tests use real child processes, duplex pipes, installed root identity, the root store, and public command gate.
- Adversarial cases cover every scope/catalog/session/frame/node/key/nonce/ordinal/digest and protocol mismatch.
- Crash, timeout, cancellation, partial failure, descriptor isolation, process-group cleanup, and reap are proven.
- This sprint changes no production module, adds no production type or call-site adoption, and keeps test work
  within three named test areas and the 400-line-per-coherent-split rule.

#### Validation

Run `cabal test all --ghc-options=-Werror` from `core/`. The named recursive-lifecycle group must execute real
local process fixtures on linux-cpu; record dated counts and source/compile-fail evidence after the gate passes.

On 2026-08-21, the five-case `RecursiveLifecycleSpec` group passed on x86_64 Linux through the public command
gate and real root/VM/container child processes, covering forward Up, child-first Down and Destroy, failed-Up
propagation and reached cleanup, and the proof-matrix guard. The complete warning-clean core suite passed at
2,314 tests, while the Python code check and all 231 Python tests also passed.

On 2026-08-23, the six-case group passed with the failed-Up immediate reverse-recovery case included; the
complete warning-clean core suite passed 2,442/2,442 in 179.14 seconds.

#### Objective boundary

Consuming root `DestroySettled` as `ProjectClosureEvidence SettledDestroyClose` also requires the bound run
lease and the all-sessions-closed proof, and recovery beyond the retained live plan belongs to the
[recovery phase](phase-18-recovery-and-migration.md). This sprint's gate is the host-static real-process
one and nothing beyond it.

#### Remaining Work

None. On 2026-08-24 the narrow handoff and reverse-plan source guards pass with their final recursive handoff,
reverse-descent, and fresh-generation shapes; the complete warning-clean core gate passes 2,454/2,454 in
148.82 seconds.

### Sprint 17.55: Protected fresh Harness invocation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Snapshot.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
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

- `withFreshHarnessInvocation` requires the exact live Harness root, held bound lease, and settled-destroy
  closure, then atomically validates the source mode/lease before allocating a fresh broker epoch.
- The transition advances mode and bound lease to that epoch, rearms the one-use lifecycle profile, verifies the
  operator, and yields only a fresh root/mode/bound/profile/close-root tuple under a rank-2 generation.
- `withRestartedBoundPlanSnapshot` compares exact project/store/spec/plan/config/canonical bytes and binds a
  freshly re-admitted local plan identity without mutating the persisted snapshot.
- The command performs intermediate exact reverse without terminal close, rotates, rebuilds the exact plan and
  lifecycle context, rebinds the snapshot, runs the second forward, and retains the fresh final reverse.
- A command-level fixture proves two variants each execute forward/reverse twice, observe both assertion phases,
  and terminally close with no generated config left behind.

#### Validation

Run warning-clean build, focused `CLISpec` restart case, `HarnessSpec`, and the complete core gate.

#### Remaining Work

None. On 2026-08-24 the warning-clean build, protected command-level same-run fixture, focused 45-case Harness
gate, and complete 2,454/2,454 core host-static gate passed.

### Sprint 17.56: Stable released-resource successor [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`,
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
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`
**Production modules**: `HostBootstrap.Harness.Ownership.Internal`,
`HostBootstrap.Harness.Ownership` (2; cap 3)
**Sprint budget**: no new named type and one close-fallback rearm adoption; at most 160 production Haskell
lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Keep the Harness ownership finalizer bound to the current generation after a same-run restart.

#### Deliverables

- The private close control existentially retains a matching close-root/mode/bound tuple rather than erasing
  the generation join or retaining only the source-generation bound lease.
- Initial binding arms the source tuple; a fresh invocation may rearm only the existing bound fallback with its
  new tuple.
- Pre-effect finalization verifies no project resource was acquired under that exact current bound lease and
  closes with the matching current root and mode. Settled terminal authorization remains generation-erased only
  after the protected kernel has validated the current tuple.
- Binding, pending, settled, and consumed states keep their existing fail-closed monotonicity.

#### Validation

The command-level same-run fixture exercises the rearmed fallback and final settled close; source guards retain
the control behind the private component. Run `HarnessSpec` and the complete core gate.

#### Remaining Work

None. On 2026-08-24 the warning-clean build, command-level restart fixture, focused 45-case Harness gate, and
complete 2,454/2,454 core host-static gate passed.

## Remaining Work

None. The root entry admits, persists, and strictly re-reads the
recursive catalog under the live global lease; Sprint 17.29 has added the one rank-2 edge fold that selects an
admitted descent by exact parent and child frame, the storeless `CatalogForwardHandoff` that edge authorizes,
and the projecting forward-child fixture that gives multi-level admission its behavioural coverage through the
real `project up` entry. Sprint 17.30 has closed both halves of the reverse edge: both root reverse entries
retain their admitted catalog, durable reverse-descent preparation names the complete catalog-derived
`RecoveryChildPackage` everywhere it named the adapter, and the private relay opens that package recoverably,
routes its exact Offer to the installed root signer, and enters the existing challenge loop. Sprint 17.31
has installed the recursive handoff runtime, so every frame can now say which arm it holds without holding a
capability, and Sprint 17.32 has opened the root-owned frame session that admits an `OpenFrame` and records
its first predecessor, and Sprint 17.33 has added the prepared node grant that follows every exact durable
unknown row, and Sprint 17.34 has split the rooted owner and added settlement. Sprint 17.35 has split the
terminal exchanges into their own storeless owner and closed the receipt: a `CloseFrame` publishes and reads
back the exact canonical report before its complete-response digest exists, and only a `ReceiptConfirm` naming
that digest advances Published to Received. Sprint 17.36 then adds the Phase 13 rooted relay, and Sprint 17.37 the
storeless frame executor that answer builds. Sprint 17.38 derives the sanitized process route that can carry
the exchange over a child's standard input and output at all, Sprint 17.39 gives the dedicated receiver
private protocol descriptors before any callback can touch those streams, and Sprint 17.40 holds one real
child, its group, and its descriptors for exactly one edge — bounding the launch, the termination grace, and
the frames a peer owes immediately, and leaving the admitted effect's own wait alone. Sprint 17.41 installs
the forward receiver, Sprint 17.42 installs the root coordinator and Chain descent adoption, Sprint 17.43
integrates semantic completion, and Sprint 17.44 rehydrates exact reverse proof after restart or response
loss. Sprint 17.45 adds reverse receiver adoption, Sprint 17.46 binds exact cluster cleanup, and Sprint 17.47
terminalizes and rearms the durable reverse root, and Sprint 17.48 binds prepared descent to its process route.
The failed-Up cleanup authority participates in the shared unwind, and the proof-complete host-static
real-process gate is closed. Live worked-demo confirmation remains Phase 24 work.

Two of this phase's own guards are stated for one outer host and hold on every supported one (§ JJ):
Sprint 17.20's `LifecycleEntry` importer allow-list takes the separator-neutral repo-relative path
helper, and Sprint 17.40's `ImportHandoffProcess.hs` fixture takes the platform-conditional expectation
its POSIX-conditional owner requires. Both follow the harness foundation the
[Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md) owns. Sprint 17.54's gate drives
real local child processes through that POSIX-conditional owner, so it runs on a POSIX outer host or a
realized Linux substrate; the sprints between close on the host static gate.

## Documentation Requirements

**Architecture docs to create/update:**

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
