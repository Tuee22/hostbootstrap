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

### Sprint 17.1: Independent root gate for the three verbs [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
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

The "operator entry requires the root frame" refusals in `runUp`, `runDown`, and `runDestroy` have no
test.

The sprint closes when a command-level operator-refusal case and a root-frame refusal case exist for each of
`project up`, `project down`, and `project destroy`, the sibling-context case asserts its own precondition, and
all pass in the warning-clean `cabal test all` from `core/` on linux-cpu.

#### Remaining Work

- Add a `CLISpec` test group "operator refusal precedes lifecycle work", one case per verb. Each case runs in
  `withIsolatedProjectConfig`, as "Destroy resumes the retained Pending continuation after Down" does, with
  counting fixture steps. The Down and Destroy cases first run `project up` successfully. Each case then makes
  the store's `records` directory reject `verifyProtectedStoreWritable`'s temp-file probe by removing its
  write permission (`setPermissions`), runs the verb through `runHostBootstrapCLI`, and restores the
  permission. Assert that the command exits non-zero with the `authorityErrorMessage` text for
  `AuthorityOperatorRefused` ("operator authorization refused: …"), that `readProtectedStoreImage` is
  byte-identical before and after the refused verb (no mode, lease, journal, reverse-root intent, or
  broker-generation write), and that no fixture-step counter moved. Where a read-only directory still accepts
  the probe (native Windows, or uid 0), the case records a declared refusal in `CoverageManifest` instead of
  passing vacuously.
- Correct the `openAuthorityStore` comment in `Command.hs` (near line 2090). It cites the nonexistent
  `Authority.withVerifiedRootInvocation`; it should name the Mode root entry and
  `withVerifiedRootInvocationKernel` as the check that refuses a store whose recorded project differs.
- Add `CLISpec` cases for the root-frame refusals in `runUp`, `runDown`, and `runDestroy` (`Command.hs`, near
  lines 1255, 1373, and 1384). Each case writes a VM-orchestrator sibling config with a non-empty parent
  chain (`Fixture.deriveProjectConfigForKind VMOrchestrator`), runs the verb, and asserts exit 1 with
  "project <verb>: operator entry requires the root frame" and no new protected-store record.
- Rewrite the comment above `runUp` in `Command.hs` (near line 1241). It says `project up` runs in every
  orchestration frame (host, VM, container), but `runUp` dies whenever `Context.parentChain` is non-empty and
  child frames enter through `--hostbootstrap-lifecycle-child`; describe the root-only operator entry. Gate
  `runUp` on `Context.HostOrchestratorCommand`, as `runDown` and `runDestroy` do, so the forward and reverse
  verbs admit the same root, and add a `CLISpec` case where a parentless vm-orchestrator config is refused by
  `project up` as it is by `project down`.
- `CLISpec` "project up fails fast without a sibling context" (near line 1725) runs against the
  executable-sibling `<exe>.dhall` path every CLI case shares, so a config left by a killed earlier run makes
  it exit 1 for another reason. Remove any stale file at that path first, assert
  `doesFileExist cfgPath >>= (@?= False)` before running `project up --dry-run`, and assert that stderr names
  the missing sibling configuration, not only `ExitFailure 1`.

### Sprint 17.2: Current-frame forward interpretation [Active]

**Status**: Active
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

`ChainSpec` covers frame order, typed descent selection, plan-minted descriptors, and failure containment.

The sprint closes when the deletions below have landed and the two-frame pre/child/post order case passes. The four rewritten compile-fail fixtures must fail to
compile under `CompileFailSpec`, the new `ChainSpec` source guards and the retargeted `TeardownSpec`,
`CLISpec`, and `CommandsSpec` guards must pass, and the warning-clean
`cabal test all` from `core/` must pass on linux-cpu.

#### Remaining Work

- Delete `runChainFromFrame` and its `legacyDescent`, which launches `<self> project up` through
  `liftSubcommandWithStdin … handoffArgv`, from `Chain.hs`. In the same change delete
  `runChainFromFrameWithDescent`, whose only caller is `runChainFromFrame`, and
  `handoffDispatch`/`handoffArgv`, which only render that `argv`. Drop them from the export list and drop
  the `ChainSpec` "handoffDispatch (recursive `project up` handoff)" group. Rewrite the `renderChain` Haddock
  in `Chain.hs`, which names `runChainFromFrame` as the interpreter that selects the current-frame segment, to
  name `runChainFromFrameWithDescentFailure`, which selects it through `runChainFromFrameWithDescentObserved`.
- Delete the dead `_failChain`, `_ignoreChainExc`, `_reverseProjection`, and `_announce` bindings from
  `Command.hs`, together with the helpers only `_reverseProjection` uses: `descendCurrent`,
  `descentReverse`, `descendOnce`, `runDescent` (an `argv` `project <verb>` descent), and `coreManaged`,
  which holds an unreachable `releaseRetainedClusterLifecycle` call. `_failChain`'s comment claims a failed
  `project up` runs a best-effort `project destroy` projection, which is false.
- Retarget the compile-fail fixtures `CrossAuthorityChain.hs`, `CrossCursorChain.hs`,
  `CrossRunHarnessProjectPlanChain.hs`, and `ProductionProjectPlanAsHarnessChain.hs` at
  `runChainFromFrameWithDescentFailure`, keeping their mismatched authority, cursor, and run indices. Replace
  the `runChainFromFrame` signature pin in `ChainSpec`'s `sourceShapeCases` with the exact
  `runChainFromFrameWithDescentFailure` signature.
- Add `ChainSpec` source guards asserting that the `HostBootstrap.Chain` export list names neither
  `runChainFromFrame` nor `handoffDispatch`, and that neither `Chain.hs` nor `Command.hs` contains
  `liftSubcommandWithStdin`.
- Retarget the source guards that only the dead `_failChain`/`_reverseProjection` code satisfies, so the
  deletion does not break them. The `TeardownSpec` guards on `Teardown.DescentWork`, `driveTeardownForest`,
  `withDescentWorkSubtree`, "nextFrameAfter (topology plan) parent", "plan-bound teardown descent mismatch",
  "Authority.projectVerbName verb", `clusterEffectFor`, and
  "profileFromPlanName (ProjectPlan.projectPlanProfileName plan)", the `CLISpec` guard near line 1680, and the
  `CommandsSpec` guards near lines 313-319 point at the live owners instead: `runSealedLocal`,
  `runExactHarnessDestroyProjection.runLocal`, `LifecycleEntry.runRootProjectReverseLifecycleEntry`, and
  `Command/Child/Reverse.hs`. A guard with no live owner is deleted.
- No executed test distinguishes the pre/post-handoff partition `interpret` takes through
  `plannedStepRunsAfterHandoff`: the `ChainSpec` post-handoff case checks only `renderChain`, and the only
  execution with a post-handoff node is single-frame. Add a `ChainSpec` case that runs a two-frame plan
  through `runChainFromFrameWithDescentFailure` with a descent callback: a pre-handoff root node, the declared
  child-frame descent, and a post-handoff root node each append their name to one shared log. Assert the log
  is exactly `["pre", "child", "post"]`, so a constant or inverted partition fails the case.

### Sprint 17.3: Teardown-forest frame-index propagation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
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

Dated 2026-08-10 evidence includes `TeardownSpec` 27/27, the eight affected compile-fail groups 8/8,
`DocValidatorSpec` 2/2, and warning-clean library/test builds.

`TeardownSpec`'s `sourceShapeTests` match raw `Text.isInfixOf` over three source files, so a commented-out
or string-literal occurrence satisfies them. The sprint closes when they run through `SourceGuard`, cover
every module under `HostBootstrap/Command/`, and pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- Rewrite `TeardownSpec`'s `sourceShapeTests` through `SourceGuard` (comment-stripped tokens and parsed
  export lists) instead of `Text.isInfixOf`, extend the Command-side guards to every module under
  `HostBootstrap/Command/`, and drop the text guards whose role or coercibility claim `CompileFailSpec`
  already proves.

### Sprint 17.4: Closed local/descent teardown work [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
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

Dated 2026-08-10 evidence includes `TeardownSpec` 25/25, sixteen affected compile-fail groups 16/16,
`DocValidatorSpec` 2/2, and warning-clean library/test builds.

`ForgeTeardownForest.hs` forges `TeardownAuthorizationPoint`, `CompletedTeardownForest`, `SettledChildren`,
`PreDescentStep`, and `ProgressCompleted`, but `CompileFailSpec` pins only three phrases for the whole file,
and the `CompletedTeardownForest` forgery also fails on its `String` literals. GHC stops at the first errors,
so the unpinned forgeries are not proven to be refused for the stated reason. The sprint closes when each
forgery has its own fixture with a pinned diagnostic and `CompileFailSpec` passes in the warning-clean
`cabal test all` from `core/`.

#### Remaining Work

- Split `ForgeTeardownForest.hs` into one compile-fail fixture per forged value (`TeardownAuthorizationPoint`,
  `CompletedTeardownForest`, `SettledChildren`, `PreDescentStep`, `ProgressCompleted`), each with
  `OverloadedStrings` so a literal cannot be the failing term, and register each in `CompileFailSpec` with
  its exact "Illegal term-level use of the type constructor '…'" or "Data constructor not in scope: …"
  phrase.

### Sprint 17.5: One `ProjectVerb` universe [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Step.hs`, `core/hostbootstrap-core/test/TeardownSpec.hs`
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

`TeardownSpec` proves the exact share action under each verb, unchanged child-first ordering, and the
separate provider stop/delete actions. Run the complete warning-clean core gate.

On 2026-09-09, native Ubuntu 24.04.4 WSL x86_64 passes the complete core gate at 2,505/2,505
in 291.83 seconds with GHC 9.12.4 and Cabal 3.16.1.0 under `--ghc-options=-Werror`.
The same source passes native Windows 11 Home 10.0.26200 at 2,500/2,500 in 504.50 seconds.
The post-status Linux documentation gate passes 5/5 in 1.72 seconds.

`Teardown.nest`'s `attachDeeper` (`Teardown.hs`, near lines 433-444) hangs the deeper subtree only under the
level's first reverse node; the frame's other nodes are `SelfPending` siblings and run while a failed child
subtree is unsettled, so Destroy can offer `ReleaseResource` for `copy-source` before its child subtree
settles. No case over `workedDemoReversePlan` pins the first offer or the drain order. The sprint closes when
the cases in Remaining Work exist and pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- Make every reverse node of a frame wait on that frame's child subtree in `Teardown.nest`, not only the
  level's first node, keeping `retainFrameOwner`. Add a `TeardownSpec` case where a failed descent leaves the
  frame's other nodes (`OfferedLocal "core:copy-source" ReleaseResource`) unoffered.
- Over `workedDemoReversePlan` under `ProjectDestroy`, assert
  `firstWork destroyForest == Just (OfferedPreDescent "core:deploy-vm" "host-orchestrator-0")` and the exact
  `drainOrder`, with `OfferedLocal "core:copy-source" ReleaseResource` after the descent edges.
- Add a case that fails the copy-source descent and asserts that neither `OfferedLocal "core:build-pb"` nor
  `OfferedLocal "core:deploy-vm"` is offered afterwards, so removing `retainFrameOwner` fails it.

### Sprint 17.6: Frame-bound settlement and root destroy proof [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
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

Dated 2026-08-10 evidence includes `TeardownSpec` 31/31, the affected compile-fail matrix 39/39,
`ReconcileSpec` 30/30, `LifecycleSpec` 100/100, and `DocValidatorSpec` 2/2.

The forged-completion test varies one coordinate, the bulk-settle case never presents a mismatched proof, and
the terminal-validation case has no positive control. The sprint closes when the cases in Remaining Work
exist and pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- Extend `TeardownSpec`'s forged-completion test with a wrong verb, a wrong plan digest, and a wrong frame,
  asserting `TeardownProjectVerbMismatch`, `TeardownPlanDigestMismatch`, and `TeardownOpeningFrameMismatch`
  from `verifySubtreeSettled`, and feed a forged `SubtreeSettled` to `settleDescentWork` and
  `verifyDestroySettled`, asserting each refuses.
- In "the exact child proof bulk-settles only its matching parent continuation", forge a mismatched
  `SubtreeSettled` (wrong digest or reordered keys), assert `settleDescentWork` returns that `Left`, and assert
  `teardownForestOutstanding joined == ["core:deploy-vm"]`.
- In "exact terminal validation rejects ...", add the positive control
  `verifySubtreeSettled projection (forgeCompleted ProjectDestroy digest frame exact) == Right …`.

### Sprint 17.7: Root-resident validated lifecycle-context join [Active]

**Status**: Active
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

The membership refinement is asserted only as source text: `ContextSpec` (near lines 1459 and 1467) pins the
two refusal lines, no test hands a nested-frame context to a root-only borrower, and no test renders any row
of `lifecycleContextErrorMessage`, the exported renderer every production consumer uses. The sprint closes
when the cases in Remaining Work exist and pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- Add a `ContextSpec` case that admits the nested context of "admits the exact nested context without a
  caller-selected child frame" (near line 1143) and passes it to `withValidatedRootLifecycleContext`,
  asserting `Left (LifecycleContextRootFrameRequired "<the nested frame>")`, beside the root-context control
  that returns `Right`. The nested eliminator `withValidatedNestedLifecycleContext` and
  `LifecycleContextNestedFrameRequired` go with the planned-forward package (Sprint 17.24).
- Add a `ContextSpec` golden table over every `LifecycleContextError` constructor that asserts the exact
  `lifecycleContextErrorMessage` text of each.
- Drive `mintValidatedLifecycleContext`'s `LifecycleContextFrameEvidenceMismatch`,
  `LifecycleContextFrameOutsidePlan`, and `LifecycleContextPlanRootCount` refusals through
  `withValidatedLifecycleContext` (drifted frame evidence, a frame outside the plan, a plan with two roots),
  asserting each constructor. A refusal that `withValidatedLifecycleContext` cannot produce is deleted with
  its renderer row, and the case asserts its absence instead.

### Sprint 17.8: Opaque root lifecycle entry [Active]

**Status**: Active
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

The sprint closes when the Haddocks below name the three entry constructors, `lifecycleEntryVerbName` is
gone with its export guards updated, the single-importer guard runs on `SourceGuard` tokens over both
main-library source roots, and the warning-clean `cabal test all` from `core/` passes.

#### Remaining Work

- Rewrite the `Command/LifecycleEntry.hs` module header ("sole root constructor") and the `LifecycleEntry`
  type Haddock ("consumed by the fixed project up interpreter") to name the three constructors
  `RootUpLifecycleEntry`, `RootDownLifecycleEntry`, and `RootDestroyLifecycleEntry`: Up retains an Execute
  cursor and catalog; Down and Destroy retain a Teardown cursor, a teardown `CommandAuthority`, and the stored
  reauthorize action.
- Delete the callerless `lifecycleEntryVerbName` (`LifecycleEntry.hs`, export line 18, definition near
  395-400) and its re-export from `Command.hs` (lines 28 and 73), and update the `ChainSpec` export-list guard
  (near line 414) and the `ProjectPlanSpec` name list (near line 6588).
- Rewrite the `CLISpec` single-importer guard for `HostBootstrap.Command.LifecycleEntry` (near line 1634) on
  `SourceGuard`. Enumerate the files of every main-library `hs-source-dirs` entry (`src` and
  `internal/cluster-backend`) through `SourceGuard.listHaskellSources`, deleting the private, unsorted
  `CLISpec.lifecycleHaskellSources` walker, find importers through the token-level import parser so
  `import qualified HostBootstrap.Command.LifecycleEntry as E` counts, and match the required route fragments
  against comment-stripped tokens. Replace the cabal occurrence count with an explicit check that the module
  is in the main library's `other-modules` and in no `exposed-modules` field (`fieldModules`).

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

- `HostBootstrap.Handoff` is the sole exposed handoff facade and does not reexport protocol/channel internals.
  The library exposes exactly one other `HostBootstrap.Handoff.*` module, `HostBootstrap.Handoff.Transaction`
  (Sprint 13.18). It is the frame-child entry that `runCLI` routes to, and it grants nothing beyond
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

### Sprint 17.10: Durable verb-tagged reverse-root intent [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`
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

#### Remaining Work

- Expose `encodeReverseRootIntent` and `decodeReverseRootIntent` to the test suite through a private Cabal
  sublibrary module (the `lifecycle-transaction-internal` pattern), keeping them out of every public facade.
  Add pure cases: canonical Down and Destroy Pending, Committed, and Terminal values round-trip to `Just`;
  a canonical encoding plus one trailing byte, a field count one above the codec's bound, a canonical Down row
  decoded as `ProjectUp`, and a parseable but non-canonical re-framing each decode to `Nothing`.
- Add store-backed cases for the ordinary admission gate. After `project up` and `project down`, rewrite the
  `reverse-root.<project>.production` row to Pending Destroy bytes (`pendingDestroyAfterDown`, `CLISpec`
  near line 1954). Assert that `withProductionRoot`, `withHarnessRoot`, and the lease close
  (`closeLeaseForKey`) each return `Left ModeReverseRootInProgress` without running their continuation, and
  that `readProtectedStoreImage` is unchanged. A malformed intent row yields `ModeMalformedRecord` naming the
  intent key; an absent intent row is the control and admits.
- Change the `ProjectPlanSpec` guard "ordinary lifecycle funnels refuse reverse intent" (near line 6775) so it
  pins the refusing bodies `refuseReverseRootIntentAt` and `withOrdinaryProjectAdmissionForName` as well as
  the call sites, and label it a placement check; the behavioural cases above carry the refusal claim.

### Sprint 17.11: Exact reverse-root continuation and redo [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
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

#### Remaining Work

- In `withExistingBoundReverseRootTransition`'s opposite-verb branch, decode the opposite row's phase. A
  Destroy Terminal row (version 3 or 6) under `project down` returns `ModeReverseRootTerminal`; only Pending
  or Committed opposite rows return `ModeReverseRootInProgress`. Add a `CLISpec` case: `project up`,
  `project destroy`, then `project down` reports the same terminal outcome an exact repeated `destroy`
  reports, runs no effect, and leaves `readProtectedStoreImage` unchanged.
- Cover the remaining resume/redo branches: the terminal-Down epoch check (`target > source`, "terminal Down
  epoch"), the `_ -> pure (Left ModeReverseRootInProgress)` fallback, and `terminalDestroy`'s version 3-or-6
  check, its `leaseVersion` `maxBound` check, and its closed-journal, closed-lease, and absent-mode
  requirement. Add a `CLISpec` case that, after `project destroy`, rewrites the lease (or recreates the mode)
  record and asserts a repeated `destroy` refuses with the "terminal Production closure" mismatch and leaves
  the store otherwise unchanged; pin the epoch check and the fallback in the `ProjectPlanSpec` ordered list.
- Anchor `ProjectPlanSpec`'s `committedSource` section (near line 4689) on the `finishCommitted` definition
  rather than its call inside `drive`, and assert the section does not contain `commitAllocated`, so the
  "Committed validates before target reification" order reads `finishCommitted`'s own `target <= source`
  guard.

### Sprint 17.12: Fresh reverse-root source admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`
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

### Sprint 17.13: Reverse-root snapshot and liveness facade [Active]

**Status**: Active
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

No test produces `SnapshotLivenessContended`, `SnapshotLivenessFailure`, or `SnapshotLeaseConflict`; the
kernel's only behavioural cases pass `error` thunks to prove the admission token is forced, and those three
fully apply the kernel, so moving the `case` inside the lambda still passes them. When the selector fails with
`ModeWrongMode "production" "absent"` and no reverse-root intent exists, the resume branch reports
`ModeReverseRootInProgress` for a project that was never brought up. The sprint closes when the change and
cases in Remaining Work exist and pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- In `withReauthorizedBoundPlanSnapshotKernel` (`ProjectPlan/Snapshot.hs`), resume on
  `ModeWrongMode "production" "absent"` only when a reverse-root intent row exists; with none, return the
  original `SnapshotVerificationError (ModeWrongMode "production" "absent")`. Add a `CLISpec` case: on a freshly
  initialised store `project down` exits 1 naming the absent Production mode, not
  `ModeReverseRootInProgress`.
- Add `LifecycleSpec` cases that hold `withRunLiveness` for the installed project name from a second thread
  (or a probe process, as `AuthoritySpec` does) and call `withReauthorizedBoundPlanSnapshotKernel` for
  `ProjectDown`, asserting `Left SnapshotLivenessContended` and no `reverse-root.` row; make the liveness
  store unwritable to assert `SnapshotLivenessFailure`; and move the bound lease between
  `withPersistedPlanSnapshot`'s persist and bind steps to assert `SnapshotLeaseConflict`.
- Relabel `ProjectPlanSpec`'s "only the selector's outer InProgress failure resumes" (near line 5374) to
  "InProgress or absent-mode selector failures resume", and pin
  `fromMode (Left ModeReverseRootTerminal) = Left SnapshotReverseRootTerminal`.
- In `LifecycleSpec`'s three "forces ... on partial application" cases (near lines 871, 888, and 916),
  evaluate the partial application itself, for example
  `try (evaluate (withResumedExistingBoundReverseRootKernel (error "bottom ...")))`, and assert the admission
  message; keep the fully applied variants as the argument-order check.

### Sprint 17.14: Sealed reverse-root lifecycle entry [Active]

**Status**: Active
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

`withRootProjectReverseLifecycleEntry`'s admission refusals, the in-progress and version-exhaustion refusals,
and the target cursor's version checks have no behavioural test. The sprint closes when
the `CLISpec` cases in Remaining Work exist and pass in the warning-clean `cabal test all` from `core/`. The
single-frame failed-up-then-destroy bridge case belongs to Sprint 17.53.

#### Remaining Work

- Add `CLISpec` cases, built with `seedBoundExecute`-style helpers, for each admission refusal of
  `withRootProjectReverseLifecycleEntry`: a source cursor still at Prepare (`LifecycleEntry.hs`, near line
  790), an acquisition seed at Execute or Teardown (near 805-806), root, mode, or profile epochs that differ
  (near 966-971), a target plan with another broker epoch (near 846-847), and `project down`/`project destroy`
  with no bound Up snapshot. Each asserts exit 1 with the refusal text and an unchanged protected-store image.
- Back the reverse-root refusals that `ProjectPlanSpec` names only as source text (near line 5389) with
  value-level `CLISpec` cases in the same style: a Destroy Pending left in place, then `project down`, refuses
  with `ModeReverseRootInProgress`'s text; an acquisition seed at Execute and at Teardown each refuse with
  `SessionAcquisitionBindingMismatch` ("seed phase"); a mode or lease record rewritten to version `maxBound`
  refuses with the version-exhaustion text. Each asserts an unchanged protected-store image.
- The reverse-root target cursor's exact versions (`Lifecycle/Session.hs`, near lines 1225-1255) are pinned
  only as call shapes. Pin `checkedVersion`'s definition (`requireCursorBindingWord "reverse root target cursor
  version" expected (lifecycleCursorRecordVersion cursor)`) and the
  `| otherwise -> refuseAcquisition "record version" "1"` branch in `ProjectPlanSpec`, and add a `CLISpec`
  case that rewrites the cursor record to a version its phase does not admit and asserts `project down`
  refuses with "reverse root target cursor version" and an unchanged store image.

### Sprint 17.15: Durable prepared reverse-descent substrate [Active]

**Status**: Active
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

The preparation refusals of `withPreparedReverseDescentKernel` (`Teardown/Internal.hs`, its `validate`, near
lines 443-490) are checked only as comment-inclusive source text: parent equal to child, an empty or
duplicated child observation order, the adapter and prepared-record bounds, the stored-collision conflict,
and "the command belongs to a different store" (`commandAuthorityMatchesStore`). No test produces any of them.
The sprint closes when the cases in Remaining Work exist and pass in the warning-clean `cabal test all` from
`core/`. The shared comment-stripping fix to the fragment helpers is Sprint 12.31's.

#### Remaining Work

- Move `withPreparedReverseDescentKernel`'s pure `validate` decision into a private Cabal sublibrary module
  (the `lifecycle-transaction-internal` pattern), keeping every store effect in the kernel, and add
  `TeardownSpec` cases asserting the exact refusal text for: parent equal to child, an empty child observation
  order, a duplicate in it, an adapter over its bound, a prepared record over its bound, and a command
  authority minted in another store ("the command belongs to a different store").
- Add store-backed cases: a conflicting prepared row already present refuses with the collision conflict and
  leaves the row byte-identical; a command authority from store A presented with store B refuses before any
  write, and store B's `readProtectedStoreImage` is unchanged.

### Sprint 17.16: Root prepared reverse-descent producer [Active]

**Status**: Active
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

#### Remaining Work

- Drop "recovery-child" from the producer-ordering label and delete its single-word trailing fragments,
  relying on the exact call-shape assertion near line 6508.

### Sprint 17.17: Durable recoverable-open map and token repair [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`
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

`registerRecoverableAdmittedHandoffEdgeKernel` (`Handoff.hs`, near lines 3339-3569) runs in tests only as a
forced partial application and as fragments of "recoverable edge registration is token-gated, durable, and
Relay-owned". No case runs first registration, retry, token rotation after a grant, a corrupt map, a foreign
token row, or any `recoveryOpenIdentity` refusal, and the readback guards inside `readExact`, `rotate`'s
post-CAS version check, `publishMap`'s CAS-version check, and `readToken`'s version-one guard match no
fragment. `writeExact` and `publishMap` discard a compare-and-swap `ProtectedError` and report a token or map
conflict, so an I/O fault reads as tampering. The sprint closes when the change and cases in Remaining Work
exist and pass in the warning-clean `cabal test all` from `core/`. Admitting the failed-Up `up` verb is Sprint
17.53's.

#### Remaining Work

- Keep the compare-and-swap failure in `writeExact` and `publishMap`: bind the `ProtectedError`; when the
  readback does not show the exact written record and no other record is present, return
  `Left (HandoffStoreFailure writeFailure)`, as `consumeRegisteredEdge` does; return the token or map conflict
  only when a different record is present.
- Make the kernel reachable from the suite with a real `RecoverySigningKernel` through a private Cabal
  sublibrary seam, and add store-backed `HandoffSpec` cases: first registration writes the version-1 map and
  planned-edge token rows; an exact retry returns the same binding and token and writes nothing; a retry after
  the token row is `granted:` rotates to a fresh token and advances the map by exactly one version; a map at
  the wrong version, a map advanced by a concurrent writer, a token row at version 2, a foreign token row, and
  a corrupt map record each refuse with their exact `HandoffBindingMismatch` text or `HandoffTokenConsumed`;
  and each `recoveryOpenIdentity` refusal (verb, phase, empty adapter, digest mismatch) yields its exact
  error.
- Add a case whose store rejects the write (a read-only records directory; a declared refusal in
  `CoverageManifest` where the host still accepts the write) and assert `HandoffStoreFailure`.

### Sprint 17.18: Bound reverse-descent attachment [Active]

**Status**: Active
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

`recoveryHandoffScope` (`Teardown/Internal.hs`, near line 663) passes an unrecognised stable scope through
unchanged, so the scope comparison is not total. The sprint closes when it refuses that case, a test pins
the refusal, and the warning-clean `cabal test all` from `core/` passes.

#### Remaining Work

- Make `recoveryHandoffScope` total: map `production` and `harness:<run>` through the `Handoff`
  `productionScopeTag`/`harnessScopeTagFor` helpers and refuse any other stable scope with "the recovery
  offer scope differs". Add a `HandoffSpec` or `TeardownSpec` case with an unrecognised stable scope that
  asserts the refusal.

### Sprint 17.19: Canonical lifecycle completion wire [Active]

**Status**: Active
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

The `teardownObservationsFromWire` refusal for an unknown outcome (`Teardown.hs`, near line 1223) is
unreached by any test. The receive-side "over bound" cases (`HandoffSpec`, near lines 1777 and 1954) feed
all-zero bytes that the domain and frame checks refuse without the bound, and the terminal-origin negative
cases (near line 1845) accept any `Left` with no positive control. `validateLifecycleBranch` (`Handoff.hs`)
accepts forward-only `succeeded` rows in a reverse failed report, which no teardown decoder admits. The sprint
closes when the change and cases below exist and pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- Add a `TeardownSpec` decode case that renders `[("one", "succeeded", "none")]` with
  `renderLifecycleObservations` and asserts `teardownObservationsFromWire` returns
  `Left (TeardownObservationWireRefused _)`.
- Rewrite the two receive-side over-bound cases to pad an otherwise well-formed observations wire and
  acknowledgement wire (a valid domain and version prefix followed by filler) past `maxWireBytes`, and assert
  the bound refusal's exact text, so deleting `bounded "lifecycle observations" raw` or
  `bounded "lifecycle acknowledgement" observed` fails them.
- In `validateLifecycleBranch`, restrict `("reverse", "failed")` rows to the teardown statuses released,
  foreign-retained, refused, and failed; add a case where a reverse failed report carrying a `succeeded` row
  is refused.
- In the terminal-origin negative cases, first assert that the unmutated forward (seed 64) and reverse
  (seed 65, with `observations`) completed reports are `Right`, then match each mutation's exact
  `HandoffBindingMismatch` message, for example "the reverse terminal origin differs from its binding" for the
  join cases.

### Sprint 17.20: Lower sealed completion ownership [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Completion.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
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

The reverse completion kernel's `refused` and `failed` branches return `Right ()` after acknowledging, so
`withReverseLifecycleChildProcess` reports a refusing child as a completed edge and the child's detail is
replaced by the root's generic "without verified subtree settlement" message; the relay maps a forward
child's post-acknowledgement refusal to `RelayLifecycleCallbackAfterAcknowledgement`, which drops its detail.
`Receiver.runTerminalAction` rethrows a caught exception with safe-exceptions `throwIO`, which wraps an
asynchronous `UserInterrupt` as synchronous. No test produces the live completion refusals. The "children
cannot ..." guards (`ProjectPlanSpec`, near lines 7104-7173) and `HandoffSpec` "child report rendering cannot
recover root-store cursor authority" (near line 7086) only check that retired identifiers stay absent. The
sprint closes when the changes and cases in Remaining Work exist and pass in the warning-clean
`cabal test all` from `core/`.

#### Remaining Work

- In `Handoff/Completion.hs`, the reverse kernel's `refused` and `failed` branches return
  `Left ("lifecycle completion: the reverse child " <> status <> ": " <> detail)` after a successful
  acknowledgement, mirroring the forward kernel; the root's settlement check keeps its role, and its refusal
  carries the child's detail.
- In `Handoff/Relay.hs`, carry the callback's text when the acknowledgement succeeded and the terminal callback
  then refused (a `RelayLifecycleCallbackRefused Text` variant), so a forward child's refusal or failure
  detail reaches the operator.
- In `Handoff/Receiver.hs` `runTerminalAction`, rethrow with base `Control.Exception.throwIO` (or catch only
  synchronous exceptions with `tryAny`). Add a case whose terminal continuation throws `UserInterrupt` and
  assert that the exception escaping `receiveScopedHandoffEdge` is `UserInterrupt`, not a
  `SyncExceptionWrapper`.
- Expose the live completion kernels through a private Cabal sublibrary seam and add cases for "a forward
  offer refuses a reverse report", "the forward child refused/failed", "a reverse descent refuses a forward
  report", and "the report binding differs from the exact offer", each asserting the exact text.
- Rename the five `ProjectPlanSpec` "children cannot ..." cases and the `HandoffSpec` child-report case to what
  they check ("the retired `<name>` identifier is not reintroduced in src/") and merge them with the
  `HandoffSpec` list near line 7092 into one table-driven guard. Back the capability claim with a
  `SourceGuard` users check: `validateCurrentLifecycleCursor` and the cursor-advancing kernels have no user in
  `Command/Child.hs`, `Command/Child/*.hs`, `Lifecycle/FrameExecutor.hs`, or
  `Teardown/Executor/Internal.hs`.

### Sprint 17.21: Root-resident parent acknowledgement substrate [Active]

**Status**: Active
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

No test runs the four row kernels (`publishLifecycleReportKernel`, `receiveLifecycleAcknowledgementKernel`,
`prepareLifecycleAcknowledgementKernel`, `adoptLifecycleAcknowledgementKernel`) on values: they appear only as
forced partial applications, source fragments, and a compile-fail export list. `HandoffSpec` "durable
lifecycle rows are exact, transcript-bound, convergent, and callback-safe" (near line 2309) reads source only,
and the convergence guards (near line 2612) pin guard order but not each guard's disposition (`Right False`
pending, `Right True` already adopted) or written-version check. The row writers (`publishChildRow`,
`prepareParentRow`, `adoptParentRow`, `writeLifecycleRow`) turn a compare-and-swap store failure into
`lifecycleRowConflict`. The sprint closes when the change and cases in Remaining Work exist and pass in the
warning-clean `cabal test all` from `core/`.

#### Remaining Work

- In each row writer, when the compare-and-swap returns `Left failure` and the re-read does not show the
  expected row, return `Left (HandoffStoreFailure failure)`; keep `lifecycleRowConflict` for a different row
  actually present.
- Make the four row kernels reachable from the suite with a real `RecoverySigningKernel` through a private
  Cabal sublibrary seam, and add store-backed `HandoffSpec` cases: a fresh publish and an exact re-publish
  converge; a different report under the same binding conflicts; a report naming another store refuses with
  its exact text; receive after publish writes the version-2 Received row; prepare and adopt move the parent
  row from version 1 to 2 to 3, a version-2 row answers pending (`Right False`) and an exact version-3 replay
  takes the replay continuation (`Right True`); of two concurrent adopters exactly one is the fresh winner; a
  missing token row and a token row not at version 2 refuse; a foreign row conflicts; and `Right Nothing` at
  receive and at adopt is asserted; a store that rejects the write yields `HandoffStoreFailure`.
- Rename "durable lifecycle rows are exact, transcript-bound, convergent, and callback-safe" to a placement
  name, and either extend the convergence fragment lists with each guard's result
  (`exactLifecycleRow 2 acknowledged record -> pure (Right False)`,
  `exactLifecycleRow 3 adopted record -> pure (Right True)`, `recordVersionWord version == 1 -> Right ()`) or
  drop them in favour of the behavioural cases.

### Sprint 17.22: Routed acknowledgement transport substrate [Active]

**Status**: Active
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

The "exactly seven/five canonical frames" cases (`HandoffSpec`, near line 3102) pin guard text whose effect
lives in `requireLifecycleRelay`, `requireLifecycleDisposition`, and `exactLifecycleFrames`, which no test
runs; the one-shot terminal gate case (near line 3497) never pins the refusing then-branch or the
`fixedPersistFailure` consumer; the Relay line-budget "freeze" (near line 3296) compares constants and never
measures `Relay.hs`; and "BrokerLink carries only a fixed-unit raw acknowledgement continuation" (near line
3088) is a contains check. `runLifecycleTerminal` records the adopt-stage replay disposition before
`AcknowledgedTag` is sent, so a failed send on the pending branch is classified as success. The sprint closes
when the change and cases in Remaining Work exist and pass in the warning-clean `cabal test all` from `core/`.
Sprint 17.36 adopts the Phase 13 rooted protocol into the relay service.

#### Remaining Work

- In `runLifecycleTerminal` (`Handoff/Relay.hs`), keep the pending branch's adopt-stage disposition in a local
  and record it only after `sendAcknowledgement` succeeds, as the already-Adopted branch does, and state in the
  Haddock how a replayed non-completed report is classified.
- Make the pure lifecycle relay codec and the terminal gate reachable from the suite through a private Cabal
  sublibrary seam. Render canonical request and response wires with `renderLifecycleAcknowledgementRequest`
  and `renderLifecycleAcknowledgementResponse`, mutate the domain, version, stage, a trailing byte, the field
  count, the disposition, and the acknowledgement one at a time, and assert each exact
  `RelayHandoffFailure (HandoffBindingMismatch …)`. Drive the gate with a callback that calls `persist` twice
  and once after returning, asserting the second and late calls receive `fixedPersistFailure`; and assert that
  a transmit failure on the pending branch returns the transmission failure.
- Replace the Relay line-budget constants with `significantHaskellLineCount relaySource @?= <measured>` and
  derive the attribution from it, as the Protocol case does, or delete the constant-only asserts.
- Assert the exact `BrokerLink` field-name list instead of the one contained signature.

### Sprint 17.23: Finalized forward-child projector foundation [Active]

**Status**: Active
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
- This sprint adds no named type; the projector's one production caller is the shared immediate-target
  projection kernel (Sprint 17.25).

#### Validation

Dated 2026-08-11 evidence includes `CLISpec` 52/52, `ProjectPlanSpec` 67/67, `SchemaSpec` 21/21,
compile-fail 449/449, the complete suite 1909/1909, and `DocValidatorSpec` 2/2.

Retention of the installed projector rests on `ProjectPlanSpec` fragments over raw `CLI.hs` text (near lines
1867-1873), which a comment can satisfy, and `CLI.hs` carries no digest pin; `CLISpec` covers only the
missing and duplicate installation refusals. The `< 400` and `>= 424` size checks (near lines 1933-1939 and
2225-2228) are implied by the exact pins before them. The sprint closes when the cases in Remaining Work exist
and pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- Add a `CLISpec` case that finalizes a real-project spec whose installed projector (`addForwardChildPlan`)
  records its invocation, admits a one-layer descent through the projecting fixture of Sprint 17.29, and
  asserts the installed projector ran; and a `bareStepPlan` case asserting `refuseForwardChildPlan`'s refusal.
  Match the `(psStepPlan spec) (psForwardChildPlan spec)` and
  `(bareStepPlan progName) refuseForwardChildPlan` fragments against comment-stripped `SourceGuard` tokens.
- Drop the `< 400` and `>= 424` assertions that follow the exact `(216, 217)` and `(631, 226)` pins, and the
  `< 400` after the exact forward-package size pin, or keep the size budgets and drop the exact counts; name the remaining CLI count a
  pin rather than a sprint attribution.

### Sprint 17.24: Exact projected child plan [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Handoff/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Context/Internal.hs`,
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

`PlannedForwardHandoff`, `withPlannedForwardHandoffKernel`, `withPlannedForwardProcessInputsKernel`, and
`withValidatedNestedLifecycleContext` (whose only production caller is that package) stand in the tree with
no caller and no behavioural test. `PlanProjectedRootInvalid` is produced by no test: every behavioural
projector returns an already canonical descriptor. The sprint closes when the deletion and the case in
Remaining Work land and pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- Delete `PlannedForwardHandoff`, `withPlannedForwardHandoffKernel`, `withPlannedForwardProcessInputsKernel`,
  `runPlannedForward`, the root-to-nested fallback, and the "parent frame evidence differs" refusal from
  `ProjectPlan/Handoff/Internal.hs` and its export list, and rewrite its module header ("inert single-edge
  foundation") to describe the catalog package alone. Delete `withValidatedNestedLifecycleContext` and
  `LifecycleContextNestedFrameRequired` (with its `lifecycleContextErrorMessage` row) from
  `Lifecycle/Context/Internal.hs`. Delete `test/compile-fail/OpenPlannedForwardHandoff.hs` and its
  `CompileFailSpec` entry, and the `ProjectPlanSpec` fragments that name the deleted terms. In `ContextSpec`'s
  "private source separates root and nested refinement without a public projection" case, delete the two
  `require` assertions "nested-only evidence branch" and "nested refusal of root evidence", whose fragments
  exist only inside `withValidatedNestedLifecycleContext`; the case's
  `forbid "nested eliminator" "withValidatedNestedLifecycleContext" facade` stays as an absence guard. Retitle
  that case, now "private source separates root and nested refinement without a public projection", to name
  only what it still asserts: the private source refines root evidence without a public projection, and no
  nested eliminator exists. Add a `SourceGuard` absence guard for the four names.
- Add a table-driven `CLISpec` case through the projection route: a projecting fixture returns each bad
  descriptor (`"rel"`, `"/a/../b"`, `"/a/./b"`, `"/a/"`, `"/a//b"`, `"\\a"`) and `project up` refuses with
  "projected plan refused: PlanProjectedRootInvalid …" before any catalog record; `"/"` and `"/a/b"` are
  admitted.

### Sprint 17.25: Recursive rooted plan catalog [Active]

**Status**: Active
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

#### Remaining Work

- Add the broker-epoch check to `admitRoot` in `Lifecycle/RootedPlan.hs`: after the store-identity guard,
  refuse with `"root invocation authority names another broker epoch"` when
  `brokerEpochWord (rootAuthorityEpoch authority) /= projectPlanProfileEpochKernel rootPlan`, and list the epoch
  in the `withRootedPlanCatalogKernel` Haddock. Pin the refusal string and its position in the admission
  order in `ProjectPlanSpec` and re-pin the module digest.
- Delete the callerless `withRootedPlanCatalogEntryKernel` (a deepest-match selector that never refuses a
  duplicate) and its export from `Lifecycle/RootedPlan.hs`; drop it from the import list of
  `test/compile-fail/OpenRootedPlanCatalog.hs`, from the `ProjectPlanSpec` export and name lists, and from the
  `CompileFailSpec` expected diagnostics. Then re-pin the owner's significant-line count (about 397) and tighten
  the `ProjectPlanSpec` split-boundary assertion from 425 back to 400.
- The catalog owner's `< 425` boundary (`ProjectPlanSpec`, near line 2731) and the projection owner's (near
  lines 2483-2485) follow exact `@?=` counts that imply them, inside files that are SHA-256 pinned. Keep the
  split-boundary assertions and drop the exact counts, so the policy check is the one that fires.
- `directContainerRebase` (`ProjectPlan/Projection/Internal.hs`, near line 264) compares `ContainerLift`
  field by field and never reads `clPlacement`, so a `ProviderGuestContainer` target passes under a
  `DirectHostContainer` parent. Destructure `ContainerLift` positionally (so a new field is a compile error)
  or normalise the one rebased mount and require `parent == targetContainer`, and refuse
  "direct container placement differs".
- Add `CLISpec` cases over the projecting fixture: parameterise "an admitted one-layer descent is cataloged"
  over `inVM`, `inLimaVM`, `inWsl2VM`, and a host-level `inContainer` (the Direct Linux GPU lane), asserting
  the catalog edge and the derived child context's provider for each; illegal (placement, lift) cases
  asserting "the selected lift is illegal for the parent placement"; and a multi-layer lift asserting
  "the immediate topology edge is not one layer".
- For the Direct lane, a case admitting exactly one rebased writable mount, and one refusal case per
  `directContainerRebase` check: placement, image, argument, remove-policy, and delivery drift; a changed
  mount count; a missing or moved Docker socket; two writable mounts changed; a changed target; rebasing
  `/var/run/docker.sock`; an empty source; a source that differs from its target; and a non-canonical path
  (`..`, a trailing separator). Each asserts its exact refusal text.

### Sprint 17.26: Digest-proven codec and registry reindex [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Class/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema/Internal.hs`,
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

#### Remaining Work

- Build `SpecIndexSpec`'s importer corpus from `librarySourceDirectories` (`src` and
  `internal/cluster-backend`), mapping module names relative to each root, and use it for every exact-importer
  guard (near lines 90-93, 175-178, and 247-254).
- Compare raw export token lists, keeping `(`, `)`, and `..`, against the frozen expectations, and make
  `modulesExporting` fail any public module whose export list carries a `module` re-export or `(..)` on an
  abstract-by-contract type.
- In "the digest-equality token is the only relabelling authority", assert that `Config.Schema.Internal`'s
  raw export list names `RecoverySpecReindex` without `(..)`, and apply `assertSoleTokenAuthority`-style
  constructor counts to every importer of the token module except the minting site.
- Run `assertContains` and `assertFragmentsInOrder` over the comment-stripped `SourceGuard.haskellTokens`
  stream.
- Rewrite the module header to cite `ProjectPlanSpec`'s recovered-inputs cases as the behavioural evidence for
  equal-digest reindex, unequal-digest refusal, and term preservation, and to state that this module holds
  placement and shape guards only.
- Delete the one-sided case "one reader enumerates the main library, and the package declares every module"
  from `SpecIndexSpec`: the two-directional module enumeration over every component stanza is
  `PortabilitySpec`'s, from the [Haskell core scaffolding phase](phase-2-haskell-core-scaffolding.md)'s
  source-introspection sprint, so `SpecIndexSpec` keeps only its specification-index guards.

### Sprint 17.27: Recovered finalized-specification reindex [Active]

**Status**: Active
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
- Work is limited to the four named production modules, adds no named type, and adopts no catalog, session,
  journal, or process call site.

#### Validation

`ProjectPlanSpec` covers the joined reindex behaviourally through the public recovered-inputs boundary: the
yielded specification carries the recovered profile's index, its codec label, schema, digest, rendered
configuration, service variant names, and role-wire schema families equal the candidate's, and its retained
builder yields a draft stream of the same length at the recovered index. An empty-registry fixture shows that
recovery of a project that registers no service succeeds with no variants; both sides use the empty registry,
so the registry kernel's digest refusal is not reached. The existing refusal cases still refuse on an unequal finalized specification (at token
minting, as `"finalized specification"`, before either lower kernel runs), unequal validated configuration
bytes, and every downstream evidence drift, and none of them touches the protected store. The internal
owner's export list, its `staticProjector` threading, and both edited modules' digests
are re-pinned, and `CrossConfigSpecRecoveredProjectPlan.hs` and
`HarnessCandidateAsRecoveredProjectPlanInputs.hs` keep the candidate index and scope closed.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-12 at
`1962 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. The join adds 46 significant lines across the
two shared owners.

The sprint closes when the cases in Remaining Work exist and pass in the warning-clean `cabal test all` from
`core/`.

#### Remaining Work

- In the retained-builder case (`ProjectPlanSpec`, near lines 1217-1219), compare the recovered drafts'
  canonical snapshot bytes (or step identities) with the candidate specification's `projectPlanDrafts` output,
  not only `NonEmpty.length`.
- Rename the empty-registry case (near line 1223) to "an empty-registry recovery succeeds with no variants",
  and add a negative case pairing a non-empty recorded registry with an empty candidate (or the reverse) that
  asserts the `finalized specification` refusal subject. Model a registry whose retained digest differs from
  the codec's with `unsafeCoerce`, as the neighbouring drift cases do, and assert
  `"finalized specification carriers"` from the registry kernel (`Service/Internal.hs`,
  `expected /= retained`).
- Reword the doc comments on `withSnapshotPlanUsing` and `withRecoveredProjectPlanCandidateFixtureUsing`
  (near lines 7504 and 7773): the default fixtures record with `fixtureServiceRegistry`, and the `Using`
  variant lets a test choose the recorded registry.

### Sprint 17.28: Root catalog persistence and readback [Active]

**Status**: Active
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
payload frame, alongside the existing nominal/hidden/fold-only guards and the module digest. The 64-edge and
65,536-byte ceilings and the topology-depth refusal have no behavioural case, because no fixture plan reaches
either ceiling or a malformed topology; those refusals are pinned by these source guards alone.
`CLISpec` and `ChainSpec` pin the threaded specification at the one call site and the entry's
catalog-before-reservation route. `OpenRootedPlanCatalog.hs` and `OpenLifecycleEntryProducer.hs` keep the
manifest kernels and the durable settlement out of every public facade.

Positive multi-level projection needs a fixture whose forward-child projector actually projects a child; the
core suite's projector refuses by construction, so that fixture and its multi-level admission coverage are
Sprint 17.29's, which is the first sprint whose deliverable consumes an admitted descent entry.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-12 at
`1966 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`.

`settleManifest` (`Command/LifecycleEntry.hs`, near line 656) binds the `compareAndSwapProtectedRecord`
result to `_written`, so a publish that fails with an OS error is reported as "the recursive catalog
manifest did not persist" instead of the store failure. The sprint closes when the store failure is
reported, the cases below pass, and the warning-clean `cabal test all` from `core/` passes.

#### Remaining Work

- In `settleManifest`, treat `Left ProtectedVersionMismatch` from `compareAndSwapProtectedRecord` as the
  expected loser and fall through to readback; return any other `Left` as a store failure carrying its
  `protectedErrorMessage` text. Add a case with a store whose publish fails and assert the refusal names the
  OS error.
- "retry converges on the persisted catalog" (`CLISpec`, near line 1171) passes identically when the retry
  diverges: a diverging manifest refuses at `verifyManifest` with the same exit code, effect count, and
  untouched record. Assert the retry's refusal reason: stderr names the consumed reservation and does not name
  the durable recursive catalog manifest.

### Sprint 17.29: Catalog-admitted forward package [Active]

**Status**: Active
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
  catalog row, process, or effect authority; it is the library's only forward package.
- Missing, duplicate, sibling, stale, or independently projected data refuses before session/process creation.
- Work is limited to the two named production modules, targets at most 400 significant lines, and adopts no
  process or command call site.

#### Validation

Multi-level exact admission is covered behaviourally. The coordinate, digest, and key mismatch refusals are
covered by source guards, with eight nominal roles, fixed-result encapsulation, zero process calls, and zero
store exposure, and the warning-clean core gate runs them. This sprint also carries the projecting forward-child fixture the core suite still lacks — a one-layer VM
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
forcing, the one-layer route predicate, and each module's digest and significant line count. The behavioural
case exercises only the admitted success path: no fixture feeds a missing, duplicate, sibling, foreign-frame,
undeclared-descent, or projected-key-mismatched edge into the fold, because the suite's admitted chains cannot
produce one, so those refusals are pinned by the refusal-ordering source guard alone.
`OpenCatalogForwardHandoff.hs` keeps the package, its constructor, its producer, and its fold out of the
public `ProjectPlan` facade, and `OpenRootedPlanCatalog.hs` keeps both new catalog folds out of the public
lifecycle facade.

At this sprint's close the two owners held 391 and 304 significant lines; the sprint adds 60 and 159
significant lines respectively, 219 against a 400-line target. `ProjectPlanSpec` pins the catalog owner at 421
significant lines against a 425-line boundary; Sprint 17.25's Remaining Work returns it under the 400-line
split boundary.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-13 at
`1968 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`.

`withCatalogForwardHandoffKernel`'s seven rechecks are pinned only by source order and their success path runs
only in `RecursiveLifecycleSpec` on the POSIX row. The sprint closes when the cases in Remaining Work exist and
pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- Expose a private Cabal sublibrary seam that can build an inconsistent catalog edge, and add one case per
  `withCatalogForwardHandoffKernel` recheck: the admitted child frame is not the target plan's current frame;
  the child frame is not the configuration endpoint; the config digest drifts; the config and payload digests
  differ; the canonical payload no longer hashes to its digest; the binding digest is not the rendered child
  plan's digest; a route that is not exactly one lift layer. Each asserts its exact refusal text.

### Sprint 17.30: Catalog-produced recovery child package [Active]

**Status**: Active
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
- Work is limited to the three named production modules, targets at most 400 significant lines, adds no named
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

The preparation-order guard "derives, validates, reauthorizes, persists, rereads, unlocks, then calls back"
(`ProjectPlanSpec`, near line 6195) checks the textual order of fragments, some of them where-bound
definitions, and has no fragment for the reread or unlock step. The sprint closes when the change in Remaining
Work lands and the warning-clean `cabal test all` from `core/` passes.

#### Remaining Work

- Limit that label to the do-block statements the fragments actually sequence and add the readback fragment.
  Prove the persist, reread, then callback order behaviourally with a store-backed preparation case on Sprint
  17.15's seam: the callback observes the prepared row already present at its exact version.

### Sprint 17.31: Installed recursive handoff runtime [Active]

**Status**: Active
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

Installed identity and policy derivation, keyless relay selection, and the key-digest, scope, generation, and
route-frame refusals are covered by hidden-module, role, constructor, path-agnostic/no-session/no-store, and
surface source guards, run by the warning-clean core gate. The runtime retains no lease or liveness evidence,
so it has no liveness drift to refuse. The root arm's success path runs behaviourally inside the root
coordinator of `RecursiveLifecycleSpec`'s public `up`, `down`, and `destroy` cases; no behavioural case drives
a drift refusal.

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

The arms decide which frame may reach the root signer and which may open a child, and no test constructs a
runtime or produces a "recursive handoff runtime:" refusal. The sprint closes when the cases in Remaining
Work exist and pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- Expose `Handoff.Runtime` to the suite through a private Cabal sublibrary seam and build both arms: the root
  arm from a live test broker and route, the nested arm from a verified edge. Assert each producer refusal of
  `rootRecursiveHandoffRuntimeKernel` (project, verb, advertised key digest, a route carrying a current frame),
  of `nestedRecursiveHandoffRuntimeKernel` (verb, a relayed route naming another frame), and of
  `requireIdentity` (an empty coordinate, a zero generation), and each narrowing eliminator's refusal ("a
  keyless nested arm has no root recursive handoff runtime", "a root arm speaks for no authenticated nested
  frame").

### Sprint 17.32: Rooted frame session [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
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

The sprint closes when `ProjectPlanSpec` pins `withRootOpenedFrameSessionKernel` and
`withRootOpenedDirectFrameSessionKernel` with no root-plan-digest `Text` parameter and pins the
`withRootedPlanCatalogRootKernel`-to-`stablePlanSnapshotDigest` derivation inside the opening, the module's
token Haddock names the requester path, and `RecursiveLifecycleSpec`'s public `up`, `down`, and `destroy`
cases still open, attach, and progress every remote frame session across real process boundaries. Then the
four host static gate commands pass: `cabal test all` from `core/` and `demo/`,
`poetry run python -m hostbootstrap.check_code`, and `poetry run python -m hostbootstrap.test_all`. It also
requires the behavioural cases named in Remaining Work: a nested-frame failed-Up direct opening, a direct
opening of an unadmitted or root frame, a faulty-signer opening, the two advance refusals, the attach
refusals driven with test-key-signed responses, and the `SessionSpec` row-kernel and key-distinctness cases.

Opening, the no-predecessor initial row, root-selected path and opaque coordinates, the four-part replay
identity, signed `Opened` digest recording and readback, and ordinal/predecessor progression are covered by
the source guards below and by those public real-process cases. The opening has no lease input and performs no
stale-catalog check; cross-root-plan, generation, catalog, session, and frame separation is the seven nominal
indices', enforced at the type level by the compile-fail guards, and no behavioural case drives a refusal.

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

- Derive the root lineage inside `withRootOpenedFrameSessionPathKernel` in `Lifecycle/Rooted.hs` from the
  catalog: `withRootedPlanCatalogRootKernel catalog (\_ _ plan _ _ -> stablePlanSnapshotDigest (renderSnapshot
  plan))`. Drop the root-plan-digest `Text` parameter from `withRootOpenedFrameSessionKernel` and
  `withRootOpenedDirectFrameSessionKernel`, and remove the `rootDigest` argument at their call sites in
  `Command/LifecycleEntry.hs` (the forward coordinator's session opening and the reverse direct opening). Today
  the digest is checked only for non-emptiness, so a digest that is not the catalog's opens a session under a
  foreign journal key. Re-pin both signatures, the derivation fragment, the module's import set, and its digest
  in `ProjectPlanSpec`.
- Correct the `withRootOpenedFrameSessionKernel` Haddock in `Lifecycle/Rooted.hs`: the session token digests
  root lineage, catalog identity, frame, verb, and the canonical requester path, not lineage, catalog, frame,
  and verb alone.
- Direct and canonical openings of one frame share the record key (root lineage, catalog identity, frame)
  (`Rooted.hs`, near line 251; `Session.hs`, near lines 2599-2607) but render different bytes (path `[G]`
  against `[P,G]`), so a failed-Up unwind's direct opening of a nested frame refuses with "the durable rooted
  frame session row is not this opening". Make the opening mode part of the record key, or derive the
  failed-Up direct opening from the forward session's row, and add a `RecursiveLifecycleSpec` failed-Up case
  whose unwind opens a nested frame directly.
- In direct mode `canonicalRequesterPath` (`Rooted.hs`, near line 267) returns `[requestedFrame]` without
  consulting the catalog. Require exactly one admitted edge naming the frame as child and refuse the root
  frame, with a case for each refusal.
- `AttachedRootedFrameSession` accepts any `RootedFrameSession`, so a nested attachment is representable and
  refused only at run time. Factor the opened fields into a private record that the attached constructor
  takes, and remove the three runtime refusals for the nested case.
- `withAdvancedRootedFrameSessionKernel` requires only `successor > ordinal` (`Rooted.hs`, near line 697).
  Require `successor == ordinal + 1` and refuse advancing a session whose stage is refused or
  receipt-recorded; add a refusal case for each.
- `withRootedFrameOpeningKernel` records the digest of whatever bytes its `sign` continuation returns. Decode
  `signedOpened` with `rootedLifecycleResponseFromWireKernel`, require the `Opened` variant and a digest, path,
  session, stage, and ordinal equal to the unsigned rendering before attaching, and add a case whose faulty
  `sign` continuation returns other bytes and is refused.
- Expose `Lifecycle.Rooted` to tests through a private sublibrary and add behavioural refusal cases for the
  attach refusals (`Rooted.hs`, near lines 416-417 and 476): wrong path, session, ordinal, frame, and family,
  each driven with a test-key-signed response, beside the existing `ProjectPlanSpec` source guards.
- `openRootedFrameSessionRecordKernel` and `attachRootedFrameSessionRecordKernel` (`Lifecycle/Session.hs`,
  near lines 2627-2688) answer a compare-and-swap failure with `Left _ -> reread` and turn a failed readback
  into `SessionRecordCorrupt`. Keep the store failure: map a readback `Left` to `SessionStoreFailure`, and when
  the compare-and-swap returned `Left` and the readback does not show the expected row, return
  `SessionStoreFailure` carrying the compare-and-swap's `ProtectedError`.
- Add `SessionSpec` cases on a temporary store for the three row kernels: open, attach, then
  `cancelOpenedRootedFrameSessionRecordKernel` refuses with "only the exact unattached rooted frame session can
  be cancelled" and the attached row is retained; attach with bytes other than the opened row refuses with
  "the rooted frame session row conflicts"; open over a different existing row writes nothing and returns that
  row's version and bytes; cancel of an absent row refuses; and a store that rejects the write yields
  `SessionStoreFailure`.
- Extend "rooted durable coordinates remain bounded and distinct at maximum input size" (`SessionSpec`, near
  line 2085) with pairs that change each coordinate of each key kernel in turn (lineage, catalog, frame, node,
  operation), a re-split pair (`("ab", "c", …)` against `("a", "bc", …)`), and identical inputs across the
  frame-session, unknown, and settlement key families; assert distinct record keys for every pair.

### Sprint 17.33: Prepared node grant [Active]

**Status**: Active
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

- Drop the `Word64` generation parameter from `withPreparedRootedNodeGrantKernel` in
  `Lifecycle/Rooted/Node.hs` and frame `GateSupersessionGeneration` from the generation bound by its own
  `withRecursiveHandoffRuntimeKernel` elimination (today discarded as `_generation`); remove the argument at both
  call sites in `Command/LifecycleEntry.hs` (the forward coordinator's `NextNode` branch and the reverse local
  preparation). Re-pin the signature and the generation fragment in `ProjectPlanSpec`.
- Frame the operation key in the gate package: add a `GateOperationKey` frame to
  `renderPreparedGatePackageKernel` and `readPreparedGatePackageKernel` in `Lifecycle/Prepared/Internal.hs`,
  raise the package version from 1 to 2, and pass each row's `operation` from `publishOrdered`. Pin the framing
  and the decode's strict re-render in `ProjectPlanSpec`. Sprint 17.37 owes the executor-side comparison.
- Correct the `PreparedNodeGrant` Haddock in `Lifecycle/Prepared/Internal.hs`: a grant retains the node, its
  ordered dependencies, and the two gate packages, and carries no signed response.
- `readPreparedGatePackageKernel` and `readPreparedGatePackagesKernel` have only source-string pins. With
  `Lifecycle.Prepared.Internal` in the private sublibrary Phase 11 provides, add value cases: a render/read
  round trip of one package and of a package list, then refusals for a wrong domain, a version other than the
  current one, a trailing byte, a 7-byte word, empty text, invalid UTF-8, a list declaring two packages and
  carrying one, 257 packages, and a 4,097-byte frame, each asserting its exact refusal.

### Sprint 17.34: Root settlement and replay [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
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

Exact settlement, convergent retry, conflicting observation, echoed-coordinate mismatch, and the absence of any
child-gate mint are covered by the source guards below. The module is hidden, so no store-backed case drives a
conflicting observation or a replayed nonce; fresh settlement runs in the public cases.

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

- Bind the signed response to the exact request and observation in `withSettledRootedNodeKernel`'s `admit`
  (`Lifecycle/Rooted/Node.hs`): stop discarding the response's request digest and body, require
  `responseDigest == childConfigDigest request`, and require the `Settled` body to equal
  `TextEncoding.encodeUtf8 (childConfigDigest body)`, the observation digest the forward coordinator signs.
  The reverse coordinator's `settle` and `descend-result` branches in `Command/LifecycleEntry.hs` sign the raw
  observation as the `Settled` body; change both to sign the same observation digest (the child reads only the
  response family, not the body). Today a `Settled` signed for one request passes beside another request with
  the same path, session, ordinal, nonce, and predecessor, and the row is published for an observation the root
  never signed. Pin both checks before `publishExactRow` and the three signing sites in `ProjectPlanSpec`.
- Make the `Refused` arm of the response elimination in `withSettledRootedNodeKernel` refuse with
  `"a signed Refused response does not settle a rooted node"` instead of publishing a settlement row and running
  the caller's success continuation; pin the refusal in `ProjectPlanSpec`.
- Expose `Lifecycle.Rooted.Node` to tests through a private sublibrary and add behavioural cases for
  `withSettledRootedNodeKernel`'s refusals (`Rooted/Node.hs`, near lines 235-273), each driven with a
  test-key-signed response: wrong path, session, ordinal, frame, zero generation, wrong family, a response for
  another request, a `Settled` body naming another observation, and a signed `Refused`.

### Sprint 17.35: Root terminal receipt confirmation [Active]

**Status**: Active
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
recorded-repeats-completion check, the continuation order (pinned today on the callerless Relay helper;
Remaining Work moves it to the two live compositions), and all three rooted owners' line budgets. `HandoffSpec` keeps `Handoff.Protocol` and the `Handoff` facade byte-frozen at their existing
digests across the change. `CompileFailSpec` pins the new owner's hidden-module boundary.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-13 at
`1975 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. `Lifecycle.Rooted.Receipt` stands at 202
significant lines, `Lifecycle.Rooted` is unchanged at 286, `Lifecycle.Rooted.Node` at 231, and the
`Handoff.Relay` call site adds 35.

`withRootedReceiptConfirmationKernel` binds the session predecessor as `_predecessor` (`Rooted/Receipt.hs`,
near line 146) and checks the confirmation against a caller-supplied completion digest instead, so a stale
completion digest is not refused by the session. The sprint closes when the check below and its refusal case
pass, the callerless combined helper is gone with its guard moved to the live compositions, and the
warning-clean `cabal test all` from `core/` passes.

#### Remaining Work

- In `withRootedReceiptConfirmationKernel`, require the session predecessor to equal `Just completion`, or
  derive the completion digest from the predecessor and drop the `Text` completion parameter; add a case
  where a stale completion digest is refused.
- `withRootedTerminalReceiptKernel` (`Handoff/Relay.hs`, near line 965) has no caller; `Command.LifecycleEntry`
  composes `withRootedTerminalReportKernel` and `withRootedReceiptConfirmationKernel` itself on the forward
  path (through `persistRootedLifecycleCompletionKernel`) and the reverse path (through `complete settled`).
  Delete the helper and its export, and move the `ProjectPlanSpec` "sole call site" assertion to those two
  compositions, pinning publish-before-advance and the canonical acknowledgement at each.

### Sprint 17.36: Rooted relay service [Active]

**Status**: Active
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

The envelope bounds are not the codec's own: `Lifecycle/Rooted.hs` defines `maxRootedRequesterComponents =
256` and `maxRootedRequesterComponentBytes = 4096` (near line 807) beside `Handoff/Rooted.hs`'s
`rootedLifecyclePathLimit` and `rootedLifecycleTextLimit`, and `ProjectPlanSpec` (near line 3167) pins the
local literals, so the two can diverge with every test green. The sprint closes when the change in Remaining
Work lands and the warning-clean `cabal test all` from `core/` passes. Sprint 17.42 owns the live
coordinator's exact-replay answer to a retransmitted `OpenFrame`.

#### Remaining Work

- Tie the two pairs in one guard without editing the frozen Phase 13 codec: the `ProjectPlanSpec` case reads
  both `Lifecycle/Rooted.hs` and `Handoff/Rooted.hs`, extracts the right-hand side of
  `maxRootedRequesterComponents`/`rootedLifecyclePathLimit` and of
  `maxRootedRequesterComponentBytes`/`rootedLifecycleTextLimit` as whole tokens, and asserts each pair equal,
  so a change to either side fails it and `= 2560` no longer matches `= 256`.

### Sprint 17.37: Storeless frame executor [Active]

**Status**: Active
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
selector and the absence of any opening-request builder, the compare-before-mint and mint-before-effect
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

#### Remaining Work

- Bind each gate package to its operation in `Lifecycle/FrameExecutor.hs`: `gateFor` reads the operation key
  that Sprint 17.33 frames into the package and refuses with `"a gate package names another operation"`
  unless it equals the local key it is paired with. Today the projected packages carry no operation key and are
  paired with `executionNodeProjectedKeys` by list position only, so a reordered list mints projection A's gate
  with projection B's attempt and journal version.
- Stop discarding the package catalog identity (`_catalog` in `gateFor`). Require every package in one
  `Prepared` to name the operation gate's catalog identity, retain that identity in the `FrameExecutor` from
  its first verified `Prepared`, and refuse a later package naming another with
  `"a gate package names another catalog"`. Pin both refusals before `mintPreparedGate` in `ProjectPlanSpec`.
- Add a second, non-descending step on the `vm-orchestrator-1` frame to `fixtureSteps` in
  `test/RecursiveLifecycleSpec.hs`, wrapped in the same `reversible` recorder, and a case that runs public `up`
  then `down` and asserts `reverse-attempts` names the new step exactly once, which proves two grants were
  prepared, executed, and settled through one child executor.
- `withExecutedFrameNodeKernel` (`FrameExecutor.hs`, near lines 433-446) accepts a signed `Prepared` pair
  without checking that the response's successor ordinal exceeds the executor's ordinal or that the request
  echoes the executor's stage, ordinal, and predecessor. Add those checks, mirroring
  `withAdvancedFrameExecutorKernel` (near line 358), and a case where a replayed earlier `Prepared` pair is
  refused.
- `withFrameExecutorRequestKernel` takes `family :: Text` matched against literals. Replace it with a closed
  sum (`NextNode | CloseFrame | ReceiptConfirm | SettleNode ByteString | DescendResult ByteString`) so a
  family/body mismatch is unrepresentable, and update the Haddock that calls the selector closed. The catch-all
  arm, the bodies-on-bodiless-families refusal (near lines 307-308), and the `ProjectPlanSpec` "the five
  families are closed" message check (near line 3348) go with it.
- The opening guards (`ProjectPlanSpec`, near line 3318) match their signature and predecessor fragments in
  `withOpenedFrameExecutorKernel` only, so `withOpenedFrameExecutorForPlanKernel`, the variant
  `Command/Child.hs` uses, is unguarded. Pin each kernel from its own `requiredSourceSection` slice (its
  rank-2 signature and its `(childConfigDigest signedOpened)` predecessor), and in the behavioural opening
  case assert that the first request built by the `ForPlan` variant carries `childConfigDigest` of the signed
  `Opened` bytes as its predecessor.
- `gateFor` wraps the package's supersession generation as `GateFence`, the role
  `GateSupersessionGeneration`'s Haddock (`Prepared/Internal.hs`, near line 80) says it must not stand in for.
  Give `PreparedGate` a routed minting function that takes `GateSupersessionGeneration` and records it in its
  own field, so no routed gate carries a broker generation as a fence epoch, and pin the call in
  `ProjectPlanSpec`.
- Correct the `FrameExecutor` Haddock: the carrier is `ResourceCarrier scope rootPlanId` with no frame index,
  and `withOpenedFrameExecutorForPlanKernel` inherits `planId` from the caller's carrier, so only four indices
  are fresh there.
- Expose `Lifecycle.FrameExecutor` to tests through a private sublibrary and add behavioural refusal cases
  for its opening, advance, and execution refusals (`FrameExecutor.hs`, near lines 220-245, 336-375, and
  433-487), each driven with a test-key-signed response: wrong path, session, ordinal, gate plan, and frame,
  zero generation, and wrong family.

### Sprint 17.38: Protocol-safe lifecycle process route [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Runtime.hs`,
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

Both owners are Cabal-private, so their direct coverage is exact source and compile-fail guards; their runtime
callers are `Command.Child`'s nested forward launch and `Handoff.Process`'s reverse launch.
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
The grammar refusals are covered by the source guards above alone.

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

#### Remaining Work

- Bind the reverse route to its package in `Handoff/Process/Route.hs`:
  `withRecoveryLifecycleProcessRouteForKernel` takes the prepared `ReverseDescent` instead of separate `RecoveryChildPackage`, `LiftContext`,
  `HandoffBindingInput`, and verb arguments, and reads all four through one
  `withReverseDescentProcessInputsKernel` elimination; `withPreparedReverseLifecycleChildProcess` in
  `Handoff/Process.hs` passes the descent through. Today the kernel checks only that the package's
  configuration and adapter are non-empty, so a package-internal caller can pair a valid package with an
  unrelated route or binding input. Pin the single elimination in `ProjectPlanSpec`.
- Delete the callerless `withRecoveryLifecycleProcessRouteKernel` and its export from
  `Handoff/Process/Route.hs`, drop it from `test/compile-fail/ImportHandoffProcessRoute.hs`, and update the
  `ProjectPlanSpec` export list.
- Correct the `Handoff/Process/Route.hs` doc comments: the `LifecycleProcessRoute` Haddock (near line 96)
  states the type's seven indices, its one constructor, and the fresh parent/child skolems, and claims no eighth
  index, session index, opened-route constructor, or per-edge index enforcement; the `sanitizedLaunch` Haddock
  describes a one-layer route or a composed route of VM layers ending in one terminal layer instead of "one
  layer deep by construction". Re-pin the module digest.
- `sanitizedLaunch` admits any composed route of two or more layers (`Route.hs`, near lines 381-383) for the
  forward and nested-forward kernels too. Pass an explicit composed-allowed flag (or use separate sanitizers) so
  `withForwardLifecycleProcessRouteKernel` and `withNestedForwardLifecycleProcessRouteKernel` refuse more than
  one layer, fix the refusal texts, and add a case where a two-layer route is refused by the forward kernel and
  admitted by the recovery kernel.
- Expose the route owner to tests through a private sublibrary and add behavioural cases that feed crafted
  `LiftContext` and `HandoffBindingInput` values to the route kernels: one per "lifecycle process route:"
  refusal (`Route.hs`, near lines 325-509 and 563-591), and one asserting the exact rendered argv per provider
  (Docker, Incus, Lima, WSL). The refusal cases include `sanitizedPath`'s three refusals (`Route.hs`, near
  lines 476-478) for `"rel/path"`, `"/a/../b"`, and `"/a:b"`, each asserting its exact text; until they land,
  the ordered fragment list near `ProjectPlanSpec` line 3766 names those three `require` lines.
- The duplicated-argv guard (`ProjectPlanSpec`, near line 3752) tests `notElem … words routeSource`, so the
  bracket-adjacent `(["exec", …` idiom every `Lift` site uses is invisible to it. Use
  `SourceGuard.countHaskellIdentifier "\"exec\"" routeSource @?= 0` and the same for `"shell"`, with a
  self-check that the lexer counts the literal inside a synthetic `(["exec", vm]` line.
- Delete `rejectedOverrides` and its `notElem` check from `sanitizedArgument` (`Route.hs`, near lines 493 and
  497-506): every entry begins with `-`, which the preceding leading-`-` check already refuses. Delete the
  `ProjectPlanSpec` assertion that pins the list; the leading-`-` check stays pinned.

### Sprint 17.39: Protocol-safe child standard-I/O isolation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`
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
receiver's only channel construction. `Handoff.Receiver` also exports `withReceivedHandoffEdge`, which takes a
raw `HandoffChannel` and whose only caller is the isolated wrapper, and `Handoff.Protocol` exports the
callerless ambient `stdioHandoffChannel`; Remaining Work removes both.

`HandoffSpec` pins the export list, the Cabal-private placement, the channel-free and handle-free entry
signature, the two-bracket structure, the acquisition order, both redirections, the independent restores, the
closing of all five duplicates, the host-selected null device, the absence of a named type, the absence of
every ambient-descriptor and process identifier, the private helper set, the seam absence, and the work's
line budget. The rooted-carrier sprint's frozen receiver baseline joins its two already-frozen peers as a
constant, so that sprint's own nine-line delta stays exactly what it was rather than growing with every later
sprint that touches the receiver, and the frozen receiver-source digest is re-pinned across this change.

Behavioural coverage over real pipes needs a process on the far end of those descriptors. The owner is
Cabal-private and adds no testing seam. `RecursiveLifecycleSpec`'s public `up`, `down`, and `destroy` cases
run binary framing through the isolated receiver across real process boundaries, but no fixture callback
reads standard input or writes standard output, so redirection has no behavioural case. No case drives
restoration, descriptor closure, an exception, or cancellation.

The sprint closes when the recursive fixture's child-frame step writes to standard output and reads standard
input to EOF inside the callback and the public `up` case still passes; `HandoffSpec` pins the isolation owner
in `Handoff.Protocol`, the receiver's export list without `withReceivedHandoffEdge`, and the protocol owner's
export list without `stdioHandoffChannel`; and the four host static gate commands pass.

`cabal test all --ghc-options=-Werror` from `core/` passed warning-clean on macOS/aarch64 on 2026-08-14 at
`1983 tests passed`, alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at `231 passed`. The isolation stands at 87 significant lines
inside an owner that now stands at 680, so the sprint's work is well inside its 400-line bound.

#### Remaining Work

- Make the recursive fixture prove redirection: in `test/RecursiveLifecycleSpec.hs`, give the
  `vm-project-container-2` step's action a body that writes a line to `stdout` and reads `stdin` to EOF
  (`hGetContents` forced) before returning its observation. Without isolation those bytes corrupt or consume
  the protocol and the public `up` case fails; with it the read sees EOF from the null device and the write
  lands on standard error.
- Delete the callerless ambient `stdioHandoffChannel` and its export from `Handoff/Protocol.hs`, and keep
  `test/compile-fail/HandoffFormerChannelProducers.hs` failing for its named reason.
- Drop `withReceivedHandoffEdge` from the `Handoff/Receiver.hs` export list so the raw-channel exchange is
  reachable only through `withIsolatedReceivedHandoffEdge`; retarget the hidden-module import in
  `test/compile-fail/ImportHandoffReceiver.hs` at `withIsolatedReceivedHandoffEdge`, and re-pin the receiver's
  export list in `HandoffSpec`.

### Sprint 17.40: POSIX lifecycle process owner [Active]

**Status**: Active
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
refusal, and reap through this owner across real process boundaries. No case drives a crash, a partial
write, a control-frame timeout, cancellation, a TERM-ignoring group, KILL escalation, or descendant cleanup.

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

#### Remaining Work

- Remove the deadline that times nothing in `Handoff/Process.hs`: `exchange` wraps only `handoffChannel`, which
  sets binary mode and buffering on two local handles and returns at once, in `timeout launchMicros`. Call
  `handoffChannel` directly, drop the `launchMicros` import, drop the "launch is bounded" sentence from the
  `exchange` Haddock, and drop "an already opened route refuses" from the `withLifecycleChild` Haddock (the
  route has no opened form). Replace the `HandoffSpec` fragments that pin the timed `handoffChannel` call and
  "the launch bound is the owner's only deadline" with a pin of the untimed call.
- Delete `launchMicros` and its export from `Effect.ChildGroup`
  (`core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/ChildGroup.hs`): Phase 13 Sprint 13.18 removes
  the `Handoff/Transaction.hs` use, and the bullet above removes the last one, so the constant has no importer.
  A `HandoffSpec` source guard asserts that no module under `src/` or `internal/` names `launchMicros`.
- Add an `EffectSpec` case for the escalation `terminateChildGroup` composes: on a POSIX host, launch
  `sh -c 'trap "" TERM; sleep 60 & echo $!; wait'` with `create_group = True`, read the descendant's pid,
  call `askChildGroupToStop`, assert `awaitChildExit` with a 200 ms budget returns `Nothing` (TERM is
  ignored), call `killChildGroup`, assert `awaitChildExit` then returns `Just` and that `kill -0` on the descendant
  pid fails. On Windows the case asserts that `askChildGroupToStop` alone ends the child.
- Correct the `Handoff/Process.hs` module header's platform-row paragraph (the one beginning "Every
  obligation above is a POSIX primitive"): it claims a total refusal on non-POSIX hosts and a covering case,
  neither of which exists. State the row it holds: the module is compiled on every gate host; on POSIX the
  bracket launches the child into its own process group and signals that group; on Windows the
  `HostBootstrap.Effect.ChildGroup` row is `terminateProcess` of the single launched child, which ends that
  child and not processes it launched.
- `exchange` and `withLifecycleChild` catch `SomeException`, so an asynchronous exception (Ctrl-C) becomes a
  `Left`. Rethrow `SomeAsyncException` after the release path runs. Sprint 17.54's interrupt case depends on
  this.
- The bracket signals the group as soon as `serve` returns. Await the child's own exit for a bounded interval
  first, and signal the group only if it has not exited.
- Escalation keys on the leader's exit, so SIGTERM-ignoring descendants of an exited leader are never killed.
  Record the child's pgid at spawn and, after the grace, test group existence with
  `signalProcessGroup nullSignal pgid` before sending SIGKILL. Add a behavioural `HandoffSpec` or `EffectSpec`
  case where the leader exits on TERM while a TERM-ignoring grandchild survives; after the release path the
  grandchild is gone.
- `HandoffSpec` "the process owner introduces no named type" (near line 7531) counts only `data` and `newtype`
  tokens. Also count top-level `type` synonyms, `type family`, `class`, and `pattern` declarations in
  `Handoff/Process.hs`, excluding `type role` lines and imports.

### Sprint 17.41: Forward child receiver adoption [Active]

**Status**: Active
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

The forward child's `runLocal` and `runNested` (`Command/Child.hs`, near lines 710-730) call `runStep` with no
`tryAny`, so a step that throws never settles its root-prepared node or closes the frame. The Child-owner line
budget adds an identifier count to a line count and subtracts unexplained constants. The sprint closes when the
change, the case, and the budget guard below pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- Wrap `runStep` in `runLocal` and `runNested` in `tryAny`, map an exception to a failed observation
  (`StepRefused` for a `SafetyRefusal`), settle the node through `settle-node`, and close the frame with the
  failed set. Add a `RecursiveLifecycleSpec` case whose container step throws: `project up` exits 1 with the
  exception text, and the container frame closes with that node in its failed set instead of hanging.
- State the Child-owner line budget ("two coherent sprint splits", `ProjectPlanSpec` near line 3576) as a plain
  sum of `significantHaskellLineCount` over named `requiredSourceSection` slices of `Command/Child.hs`, with a
  comment explaining each exempted slice, compared with 800. Drop the unexplained 8 and 5 and the cross-file
  `CLI.hs` identifier count.

### Sprint 17.42: Root coordinator and Chain adoption [Active]

**Status**: Active
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
  completion evidence, and the child-first terminal continuation are produced by the semantic-completion owner
  (Sprint 17.43). A `NextNode` that arrives after every node and the descent have settled is answered with a
  signed `Refused` saying no node remains and the frame must close.
- The frame's `OpenFrame` service answers an exact replay — the same envelope path, nonce, and request bytes —
  with the byte-identical `Opened` by attaching through the retained pre-attach session, whose attachment
  converges; a differing replay still refuses.
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

#### Remaining Work

- Answer an exact `OpenFrame` replay in `serveForwardFrame` (`Command/LifecycleEntry.hs`): keep the pre-attach
  `RootedFrameSession` in its own `IORef` beside `sessionRef`, and route an `open` request that arrives after
  attachment through `withRootedOpenedResponseKernel` with that retained value, so
  `attachRootedFrameSessionRecordKernel` converges on the attached row and the deterministic fixed signer
  returns the byte-identical `Opened`; a replay with another nonce or path still refuses. Today the `open`
  branch overwrites `sessionRef` with the attached session, so a retransmitted `OpenFrame` reaches the "already
  attached" refusal. Pin the retained value and the replay route in `ProjectPlanSpec`.
- Reword the post-completion `NextNode` refusal in `serveForwardFrame` from "terminal report integration is not
  yet admitted" to "no node remains; the frame must close", and pin the new text in `ProjectPlanSpec`.
- `serveForwardFrame`'s `settle` and `descend-result` arms (`Command/LifecycleEntry.hs`, near lines
  2050-2060) pass the body through `forwardObservationFailure` without checking that the observation's
  operation key is the granted node or that its domain matches the request kind, and accept a
  `descend-result` when no `Descend` was issued. Parse each kind's observation, refuse a foreign operation
  key, a mismatched domain, and an unsolicited `descend-result`, as the reverse `advanceLocal` does, and add a
  case for each refusal.
- `rootForwardBrokerLink.linkOpenRaw` (`Handoff/Relay.hs`, near line 512) passes its input straight to
  `registerAdmittedHandoffEdge`, unlike `rootBrokerLink` and `relayedBrokerLinkKernel`. Apply
  `requireConfigOpen input` there first.
- Add a relay harness case that runs `rootForwardBrokerLink` over a pipe-pair `HandoffChannel` and asserts
  that a recoverable open and a recovery signing request each yield `RelayRecoveryNotPlanned`, and that a
  `RecoveryAdapterWire` input to `linkOpenRaw` is refused before any edge is registered. Sprint 17.49 owes the
  reverse link's case.
- Rewrite the `rootForwardBrokerLink` Haddock (`Handoff/Relay.hs`, today "It carries exactly the capabilities a
  forward lifecycle child can exercise. Activation signing is supplied by the root coordinator for the child's
  exact canonical manifest; recovery signing remains a closed refusal.") to state what the link enforces once
  `linkOpenRaw` applies `requireConfigOpen`, and what it delegates: ordinary opening refuses a binding input
  whose payload kind is not narrowed-project-config and registers only an edge the supplied `EdgeAdmission`
  admits; a grant first runs the supplied offer-retention callback; activation signing calls the supplied
  signer and adds no check of its own, so which manifests are signed is that signer's decision; rooted
  lifecycle requests reach the supplied endpoint only after the requester-path check; rooted-binding
  authentication and lifecycle acknowledgements are the root broker's own operations; recoverable opening and
  recovery signing are closed `RelayRecoveryNotPlanned` refusals, and the provider reprobe endpoint is a closed
  `RelayEdgeNotPlanned` refusal. Sprint 17.49 owes the reverse link's Haddock.
- `registerAdmittedHandoffEdge` (`Handoff.hs`, near line 3302) is named in tests only inside a fragment list.
  Add a facade-level `HandoffSpec` case whose admission predicate rejects the edge: the call returns
  `Right (Left _)` carrying the rejection, and a following `grantHandoff` for an offer built from that input
  with a fresh token (as "an edge the root never opened is refused" builds one) yields
  `Left HandoffEdgeUnregistered`, so a plan-rejected edge registers nothing.
- The requester-provenance checks in `Handoff/Relay.hs` (`requireRootedRequesterPath`,
  `requireServedProvenance`, `requireServedRequester`, near lines 2176-2217) are pinned only as source
  fragments. In the same relay harness, submit a post-open rooted request whose inner path differs from the
  complete envelope at the root, a relayed request whose envelope is not the leaf suffix of its inner path, a
  path that does not begin at the admitted child, an empty path, and an edge open whose requested parent is
  not the path origin; assert each exact `HandoffBindingMismatch` text and that nothing is registered.
- The installed activation signers (`launchChild` and `signActivation` in `Command/LifecycleEntry.hs`, near
  lines 1668-1680 and 1747-1754; `openFrame` in `Command/Child.hs`, near lines 577-584) are reached by no
  test, and no test calls `stepExecutionSignActivationManifest`. Add a `RecursiveLifecycleSpec` fixture step on
  a child frame whose plan declares a service activation placement: the step signs its admitted manifest and
  the case asserts a grant whose signature verifies against the installed activation key; fixture flags make
  the step sign a manifest naming another frame, another plan digest, and another service/effect set, and
  each case asserts the exact `ActivationManifestInvalid` text. Add a `ChainSpec` case whose single-frame
  step calls it with no installed service and asserts "runtime activation signing service is absent".

### Sprint 17.43: Semantic report and completion integration [Active]

**Status**: Active
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

#### Remaining Work

- Gate `withForwardRootedTerminalReportKernel` and `withFailedForwardRootedTerminalReportKernel` on the stage
  the root issued — an explicit set of settled stages, as `withFailedRootedFrameSessionKernel` does — and drop
  the vacuous `isJust predecessor` test. Define how an attached frame with no nodes and no descent reaches a
  settled stage, so it reports completion.
- Expose `Handoff.TerminalReport` and a `RootedFrameSession` test constructor through a private Cabal
  sublibrary seam and add cases for both kernels: an unopened session, a non-Up session, a session at a
  non-settled stage, and the empty-work frame each give their exact result, and a settled session renders the
  report.

### Sprint 17.44: Reverse Adopted replay proof rehydration [Active]

**Status**: Active
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

#### Remaining Work

- Delete `withRehydratedAcknowledgedReverseLifecycleCompletionKernel` from `Handoff/Completion.hs` and its
  export; nothing in `src/` calls it. Drop it from the `HandoffSpec` name list (near line 3661) and from the
  `CompileFailSpec` diagnostic list (near line 1769) and its `compile-fail/HandoffLifecycleProducers.hs`
  import. Delete with it the terms only that dead path reaches: `withLifecycleCompletionKernel`
  (`Handoff/Completion.hs`, no caller), `withRehydratedAdoptedReverseDescentKernel` (`Teardown/Internal.hs`),
  and `rehydrateAdoptedLifecycleAcknowledgementKernel` (`Handoff.hs`), with their exports, the
  `compile-fail/HandoffLifecycleFold.hs` import and `CompileFailSpec` entry, and their `HandoffSpec` and
  `ProjectPlanSpec` fragments.
- `rehydrateAdoptedLifecycleReportKernel` (`Handoff.hs`, near lines 795-861) lists every
  `lifecycle-parent.` row and reads each, so one malformed or out-of-range row anywhere in the store fails
  every reverse rehydration, while its Haddock says the binding picks the sole key. Derive the parent-row key
  from the input binding and read that row alone (or skip rows whose decoded binding names another edge), and
  make the Haddock state what the code does. Add store-backed cases: absent, version 1, and version 2 rows
  answer `Right Nothing`; an exact version-3 row answers `Right (Just …)`; a version-4 row, a row whose key
  differs from its binding, a binding naming another store, two matching rows, and malformed bytes each
  refuse; and a malformed row for an unrelated edge does not fail this edge's rehydration. Add the kernel to
  the partial-application forcing case.
- Split `HandoffSpec`'s "observation-only Bound rehydration" section (near lines 6698-6703), which spans the
  Bound, Adopted, and Settled kernels (`Teardown/Internal.hs`, near lines 742-953), into one section per
  kernel delimited by the next top-level signature rather than Haddock prose, and assert each kernel's own
  compare-and-swap and cursor counts: none in Bound and Adopted rehydration, the one rebind in Settled.
- Add a `RecoveryInterruptionSpec` case "reverse restart after Adopted replays without a second effect". Add
  a probe flag beside `--hostbootstrap-destroy-interruption-probe` that writes its sentinel once the
  container child's reverse report is Adopted, before the parent forest advances. Terminate the probe at
  that sentinel, run a fresh `project destroy`, and assert exit 0. Then assert that `reverse-attempts` names
  `container` exactly once, so the restarted root replays the Adopted report and runs no second effect.
- Rehydration classifies the Bound row by type, not by refusal text (`Teardown/Internal.hs`).
  `withRehydratedBoundReverseDescentKernel`'s `rehydrateRecord` returns three cases. A version-1 row equal
  to `preparedBytes` (`exactRecord 1`) is Prepared. A version-2-or-later row that `parseBoundRecord` admits
  is Bound. A `readProtectedRecord` `Left`, a `Right Nothing`, and any other row stay refusals.
  `withRehydratedSettledReverseDescentKernel` returns `False` only for the typed Prepared case and for Bound
  not yet Adopted. Delete its `detail == "the exact bound record is absent"` comparison.
- `rebindAdopted` calls `validateCurrentLifecycleCursor session cursor` inside its `withProtectedEntry`
  before `compareAndSwapProtectedRecord`, as `bindRecord` does, and refuses "the lifecycle cursor is
  stale" without writing.
- Expose `verifyChildObservations`, `parseBoundRecord`, `classifyPrepared` and the rehydration classifier
  to the test suite through a private Cabal sublibrary (the `lifecycle-transaction-internal` pattern).
  Add `HandoffSpec` cases asserting the exact refusal for: reordered, extra, missing and failed child
  observation rows; a nested descent whose rows do not match its subtree; a malformed, non-canonical or
  conflicting Bound record; a version-1 row whose bytes differ from `preparedBytes`, which is refused and
  not resumed; and a store read failure, which stays a refusal.

### Sprint 17.45: Reverse child executor adoption [Active]

**Status**: Active
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
- A local reverse effect that throws settles as `TeardownFailed` with the exception's text, exactly as the
  root's `guardedReverse` does, so the root's reverse node is settled rather than stranded. Once the effect
  has run, its observation always renders, so the successor forest and the observation are never dropped.
- `withStorelessReverseExecutorKernel` is the one reverse-adapter verifier, and the adapter bytes have one
  renderer, shared by the root package producer and the child verifier.
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

No test feeds the executor a mutated adapter or a mismatched Prepared or Descend response: only
`RecursiveLifecycleSpec` reaches the module, with canonical inputs, on the POSIX row. The sprint closes when
the thrown-reverse `RecursiveLifecycleSpec` case, the executor refusal cases, the profile and classification
value cases, and the storeless identifier bans named in Remaining Work exist and pass and
`cabal test all --ghc-options=-Werror` passes from `core/`.

#### Remaining Work

- In `runStorelessReversePreparedKernel` (`Teardown/Executor/Internal.hs`, the `runLocal` branch), wrap both
  the declared-callback call (`run host (localWorkAction local)`) and the `runCoreManaged local` call in
  `tryAny`. Map an exception to `TeardownFailed (displayException e)` before rendering the observation, so
  a throwing reverse callback or cluster release reaches `settle-node` instead of escaping `driveReverse`.
- Add a `RecursiveLifecycleSpec` case "a throwing child reverse settles as failed and closes the frame". Add
  a fixture flag that makes the `container` step's `reversedBy` callback append to `reverse-attempts` and then
  `throwIO (LifecycleFailure "fixture reverse exception")`. Run `up` (exit 0) and `destroy` (exit 1). Assert
  that stderr carries the exception text in the unsettled-work detail and `reverse-attempts` names
  `container` exactly once. Then clear the flag and assert that a second `destroy` exits 0.
- In the same `runLocal` branch, normalize the outcome before `renderTeardownObservations`. A
  foreign-retained, refused or failed detail that is empty or exactly `none` becomes a fixed placeholder
  (for example `"no detail given"`). A detail that would push the row past the handoff wire bound is
  truncated under it. Rendering after the effect then cannot return `Left`. Add an executor case where a
  declared reverse returns `TeardownRefused ""`: the successor forest settles the node and the rendered
  observation carries the placeholder.
- Delete the callerless `withVerifiedReverseAdapterKernel` from `Teardown/Internal.hs` and its export,
  the `compile-fail/OpenReverseDescentSubstrate.hs` import and `CompileFailSpec` diagnostic, and its
  `ProjectPlanSpec` fragments. Keep one adapter renderer: move `renderReverseAdapter` into a private module
  that both `Teardown/Internal.hs` and `Teardown/Executor/Internal.hs` import, and delete the executor's
  `renderAdapter`. The executor still does not import `Teardown.Internal`. Add a source guard that exactly one
  module defines the adapter renderer.
- In `runScopedRecovery` (`Command/Child.hs`), decode the child config with `TextEncoding.decodeUtf8'` and
  return `Left "reverse child: the child config is not UTF-8"` before calling the codec.
- Expose `Teardown/Executor/Internal.hs` to the test suite through a private Cabal sublibrary. Add
  `HandoffSpec` cases asserting the exact refusal text for: a failed-Up adapter with a differing header, a
  differing suffix, a non-UTF-8 operation and a count that is not 8 bytes; a Down adapter with the wrong
  verb, an extra operation and a duplicate operation; a frame that is not exactly one topology child; a
  Prepared response naming another operation; a Prepared response over root-owned pre-descent work; and a
  descent result naming another child frame.
- `recoveryProfileName` and `runCoreManagedReverse`'s policy classification (`Command/Child/Reverse.hs`) are
  guarded by one literal fragment and string-absence checks (`HandoffSpec`, near lines 8884-8908). Move them
  into a test-visible internal module and assert their values: Production, `harness:r`, an empty run name, and
  an unknown scope; a non-`CoreManagedReverse` policy answers `TeardownForeignRetained` without invoking the
  host; a failed exposure release answers `TeardownFailed` without calling `releaseRetainedCluster`. Rename
  the remaining string-absence checks as name bans.
- "the reverse lifecycle child is storeless and exact" (`HandoffSpec`, near line 8919) refuses six exact
  import names only. Add `countHaskellIdentifier` bans for `ProtectedStore`, `ProtectedSession`,
  `compareAndSwapProtectedRecord`, and `withProtectedEntry` over `Teardown/Executor/Internal.hs`, and replace
  the import deny-list with an allow-list of the executor's permitted imports.

### Sprint 17.46: Exact cluster cleanup adoption [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Adopt Phase 16's one cluster cleanup, `releaseRetainedCluster`, at every root lifecycle site that releases a
core-managed cluster, each behind the exact durable preparation of that operation.

#### Deliverables

- Every root core-managed `DeleteCluster` reaches Phase 16's `releaseRetainedCluster` and nothing else: the
  root Down/Destroy local runner and the failed-Up local runner through `releaseRetainedClusterLifecycle` in
  `Command.hs`. No separate cleanup kernel stands beside it: `runExactClusterCleanupKernel`
  (`Cluster/Reconcile.hs`) and its one caller `runPreparedRootClusterCleanupKernel`
  (`Command/LifecycleEntry.hs`) are absent.
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

Cover exact policy/verb/plan binding, order relative to frame work, retry, partial failure, and no duplicate
cleanup; run focused reconcile/command tests and the warning-clean core gate. The sprint closes when the
`CLISpec` cases and source guards named in Remaining Work exist and pass and
`cabal test all --ghc-options=-Werror` passes from `core/`.

On 2026-08-21, the focused cluster reconcile/backend, reverse-entry ownership, indexed-plan, and
documentation gate passed all 123 selected tests on x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0. The
complete `cabal test all --test-options='--hide-successes' --ghc-options=-Werror` gate then passed all 2,305
tests. Existing typed cleanup behavior covers exact removal, retry/already-absence, replacement preservation,
partial failure, and origin retention. Production Down/Destroy sends a core-managed `DeleteCluster` through
`runSealedLocal` to `runCluster` in `Command.hs` (near lines 1749-1770), and the failed-Up runner `runFailedLocal`
(near lines 1666-1680) does the same; both call `releaseRetainedClusterLifecycle` with no durable gate, because
the root reverse driver calls `runLocal plan local` without preparing the operation. The gate-checking
`runPreparedRootClusterCleanupKernel`/`runExactClusterCleanupKernel` pair has no caller; this sprint deletes it
with its `HandoffSpec` guard, so the gate check lives at the call sites above. No test drives a
core-managed node through `project down` or `project destroy`.

#### Remaining Work

- Make the root reverse driver prepare root-local work. Before running a root-local reverse operation,
  `runRootProjectReverseLifecycleEntry` (`Command/LifecycleEntry.hs`, the local branch of its
  `driveTeardownForest` call) publishes the operation's durable `PreparedGate` through
  `Lifecycle.Session.withPreparedGate`, as `Chain.hs` does for forward nodes, and passes the gate to `runLocal`.
- In `runSealedLocal`'s `runCluster` (`Command.hs`) and in `runFailedLocal`, refuse with
  `TeardownFailed "cluster cleanup: the durable gate names another plan"` or
  `"… names another operation"` unless the gate's plan is the entry plan's snapshot digest and its operation is
  the work's key, before calling `releaseRetainedClusterLifecycle`; `runFailedLocal` runs only for an
  operation in its failed-Up authority's reached set.
- Delete `runExactClusterCleanupKernel` (and its export) from `Cluster/Reconcile.hs`, its one caller
  `runPreparedRootClusterCleanupKernel` (and its export and import) from `Command/LifecycleEntry.hs`, which
  nothing calls, and the `HandoffSpec` case "cluster cleanup is bound to the sealed root reverse entry" that
  guards their text. Extend Sprint 16.11's absence source guard over `Cluster/Reconcile.hs` to name
  `runExactClusterCleanupKernel`, and assert `Command/LifecycleEntry.hs` defines no
  `runPreparedRootClusterCleanupKernel`.
- Add a `HandoffSpec` source guard, in place of the deleted case, that `runCluster` and `runFailedLocal` check
  the gate before `releaseRetainedClusterLifecycle`.
- Add `CLISpec` cases with a single-frame `deploy-kind` + `deploy-chart` plan backed by
  `FakeCluster.withFakeClusterClient`. `project up` then `project down` performs exactly one cluster release.
  `project destroy` with the chart's ownership record absent records a foreign-retained row for the chart and
  still releases the cluster once. With a corrupt chart ownership record, `project destroy` exits 1 and names
  a failed row for the chart. A failed `project up` whose failing step follows `deploy-kind` releases the
  cluster once through the failed-Up unwind.

### Sprint 17.47: Reverse terminalization and rearm [Active]

**Status**: Active
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

The Down half of the nested refusal has no test. `TeardownSpec` reaches `TeardownRootFrameMismatch` only
through `verifyDestroySettled`. Nothing calls `validateRootSubtreeSettled`, the check that guards Down
terminalization, outside `terminalizeRootReverseLifecycleEntryKernel`. The Mode terminalizer's own refusals
are pinned only by fragment order (`HandoffSpec`, near line 9033) and no test calls it. The sprint closes when
the changes and cases named in Remaining Work exist and pass and `cabal test all --ghc-options=-Werror`
passes from `core/`.

#### Remaining Work

- Add `TeardownSpec` cases for `validateRootSubtreeSettled`, mirroring "nested destroy settlement cannot
  promote to project-wide closure". Settle a `vm-orchestrator-1` Down subtree with `inVM demoShapedPlan` and
  assert `Left (TeardownRootFrameMismatch "vm-orchestrator-1" ["host-orchestrator-0"])`. Settle the root
  frame's Down subtree and assert `Right ()`.
- Delete the `TeardownIncomplete` constructor of `TeardownError` and its `teardownErrorMessage` arm
  (`Teardown.hs`); nothing constructs it. Delete `subtreeSettledReleasedOperationKeys` and its export; it has
  no caller in `src/` or `test/`.
- `terminalizeExistingBoundReverseRootKernel`, exported from the exposed `Lifecycle.Mode`, compares only the
  settled verb and plan digest, so a child frame's `SubtreeSettled` for the same plan terminalizes the root
  intent; only its caller `validateRootSubtreeSettled` adds the root-frame check. Once the intent is decoded
  (`validateLive`), require `subtreeSettledOpeningFrame settled` to equal the intent's recorded root frame
  (common field 16) and refuse with a "settled frame" `ModeEvidenceMismatch`.
- Delete the unreachable Destroy arms of the terminalize case (`ReverseRootDestroyCommitted`,
  `ReverseRootDestroyTerminal`) and `releaseIfDestroy`'s `Just authorization` branch: `validateEvidence`
  requires a closure for Destroy and every closure goes to `releaseProductionMode`. Rewrite the Haddock: Down
  retries accept only their version-3 result, and `releaseProductionMode` finalizes Destroy at version 3 or 6.
- Delete `rearmTerminal` from fresh reverse-root admission (`admitFresh`, `Mode.hs`, near lines 3432 and
  3461-3498) and call `publishAbsent` directly: `admitFresh` runs only when the intent row is absent inside the
  same exclusive session, and its version-3-only check disagrees with the live rearm policy
  `clearTerminalReverseRoot`, which stays the one rearm path. Drop the `ProjectPlanSpec` pins of its
  `compareAndDeleteProtectedRecord`.
- Add `LifecycleSpec` cases with the existing fixture and `withProductionRoot` machinery for
  `terminalizeExistingBoundReverseRootKernel`'s refusals: a settled plan digest and a closed-session digest
  that differ from the bound lease's, `ProjectUp`, a Down with a closure, a Destroy without one, a Destroy with
  a pre-effect closure, and a child-frame `SubtreeSettled`. Each asserts its exact `ModeError` and an unchanged
  intent record.

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

### Sprint 17.49: Rooted reverse service foundation [Active]

**Status**: Active
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
state; run the warning-clean core gate. The sprint closes when each refusal case named in Remaining Work
exists and passes and `cabal test all --ghc-options=-Werror` passes from `core/`. Until then the service's
request refusals are covered only by source guards. `RecursiveLifecycleSpec` drives honest children only.

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

#### Remaining Work

- Make the request checks of `withPreparedRootReverseFrameServiceKernel` (`Command/LifecycleEntry.hs`)
  testable. Move the pure decisions into one function in a private Cabal sublibrary module, following the
  `lifecycle-transaction-internal` pattern. That function takes the retained forest, prepared node, pending
  descent, retained Offer and terminal state, plus one decoded rooted request, and returns the next state or
  the refusal. These decisions are `advanceLocal`'s `teardownObservationsFromWire` settle-body check and
  the descend-result, close, offer and receipt guards. The service keeps every store and broker effect.
- Add `HandoffSpec` cases over that function, one per refusal, each asserting the exact refusal text: a
  settle naming a node other than the prepared one, a settle of root-owned pre-descent work, a settle of
  descent work, and a settle body with zero or two rows. Add the same for a descend-result with no pending
  descent or naming another child, a receipt before `FrameComplete`, a close before its Offer is retained,
  a second Offer that differs from the retained one, and a re-offer of a durably failed node.
- Add a relay harness case that runs `rootReverseBrokerLink` over a pipe-pair `HandoffChannel` and asserts
  that a config open and an activation signing request each yield `RelayEdgeNotPlanned` and register nothing.
- Rewrite the `rootReverseBrokerLink` Haddock (`Handoff/Relay.hs`, today "Root link restricted to prepared
  reverse edges. Config opening and activation signing are closed refusals. Recoverable opening, recovery
  signing, rooted responses, and lifecycle acknowledgements remain the exact root-broker operations the
  prepared reverse exchange requires.") to state what the link enforces and what it delegates: config opening
  and activation signing are closed `RelayEdgeNotPlanned` refusals, as is the provider reprobe endpoint;
  recoverable opening goes through `registerRecoverableAdmittedHandoffEdgeKernel`, which refuses any input but
  a recovery-adapter-wire teardown binding under a `down` or `destroy` broker whose adapter digest matches, and
  registers only an edge the supplied `EdgeAdmission` admits, so the restriction to the prepared reverse edge
  belongs to that admission, not to the link; recovery signing authenticates the request against the live
  broker and signs only what the supplied `RecoveryAdmission` admits; a grant first runs the supplied
  offer-retention callback; rooted lifecycle requests reach the supplied endpoint only after the requester-path
  check; and rooted-binding authentication and lifecycle acknowledgements are the root broker's own operations.

### Sprint 17.50: Root-authorized nested reverse descent [Active]

**Status**: Active
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

The guard that bans the former root/parent equality checks (`ProjectPlanSpec`, near line 6741) compares
unindented fragments with whole raw lines (`fragment \`notElem\` lines internalSource`), and every `require`
in `Teardown/Internal.hs` is indented, so it can never fail. The sprint closes when the guard below is
corrected and the warning-clean `cabal test all` from `core/` passes.

#### Remaining Work

- Ban the obsolete equality checks as token sequences (`SourceGuard.countHaskellTokenSequence … @?= 0` over
  `Teardown/Internal.hs`), and add a self-check that the matcher finds a banned fragment inside an indented
  synthetic line.

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

### Sprint 17.52: Failed-Up cleanup authority [Active]

**Status**: Active
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

#### Remaining Work

- Delete `withRetriedFailedUpUnwindAuthorityKernel` and its helper `sameAuthority` from
  `Authority/FailedUp/Internal.hs` and its export list; nothing calls them. Drop the name and the
  `sameAuthority retained candidate` fragment from the `ProjectPlanSpec` guard (near lines 3003-3031).
- In `failedReport`, drop the rows whose key starts with `descent/` before `verifyFailureReport` compares the
  reported operations with `reached`. The forward root records those rows in a frame's observations when a
  `descend-result` settles (`serveForwardFrame`), and the coordinator drops them from `frozenReached`. A
  failed VM frame whose container descent failed must therefore admit its own cleanup and not refuse with
  "the failed report reaches an operation outside the frozen prefix".
- Make `HostBootstrap.Authority.FailedUp.Internal` reachable from the test suite through a private Cabal
  sublibrary (the `lifecycle-transaction-internal` pattern), keeping it out of every public facade. Add
  `AuthoritySpec` cases that call `withRootFailedUpUnwindAuthorityKernel` and assert each exact
  `failed-Up unwind authority: ...` text. The inputs are a duplicate reached operation, an unresolved
  operation not in reached, a duplicate unresolved operation, a report bound to another binding, a report
  reaching an operation outside reached, and a non-failed report. Add one more case for a report carrying a
  `descent/<child>` failed row, which is admitted. Add one `withFailedUpUnwindAuthorityKernel` case whose
  session names another catalog.
- `withRootFailedUpUnwindAuthorityKernel` compares its `frame` argument with the `currentFrameId` of the
  catalog root's `CurrentFrame` (the fourth argument of the `withRootedPlanCatalogRootKernel` continuation)
  and refuses "the failed root frame is not the catalog root". Correct the module header: the root-local
  producer joins its frame to the catalog root and records the fixed path, token and ordinal; it joins no
  session. Add an `AuthoritySpec` case passing `"not-a-frame"` that asserts this refusal.
- `verifyFailureReport` tells a report that is not a failed forward report apart from one bound to
  another binding. Replace the `emptyReport` sentinel with a `Maybe` result, refuse a `Nothing` with
  "the report is not a failed forward report" before the binding comparison, and refuse an empty
  `expectedBinding`. The `AuthoritySpec` non-failed-report case asserts the new text.
- Bind the failure authority to its entry in `Command/LifecycleEntry.hs`.
  `withPreparedFailedUpReverseDescentKernel` and `withFailedUpTeardownForestForEntryKernel` compare the
  authority's catalog identity with `rootedPlanCatalogRecordIdentityKernel` of the entry's retained catalog
  and refuse "the failure authority names another catalog", in place of `failedAuthority \`seq\``. The
  reauthorize action passed to `withPreparedReverseDescentKernel` re-reads the Execute reservation and does not
  return `pure (Right authority)`. Pin both with the `ProjectPlanSpec` source guard.
- `withFailedRootedFrameSessionKernel` (`Lifecycle/Rooted.hs`) is pure and no test applies it; its coordinate
  checks and its `OpenedRootedFrameSession{} -> refused "the failed session was never attached"` arm are
  pinned only as bare expressions matched anywhere in the source. Add pure cases built from the existing session
  fixtures: an opened (unattached) session, a non-Up session, and a non-terminal stage each refuse with their
  exact text, and an attached Up session at a terminal stage admits. Until those exist, each coordinate
  fragment carries its full `require "<message>" (<predicate>)` text.
- The failed-Up "three sprint-owned additions" budget (`ProjectPlanSpec`, near line 3053) adds
  `countHaskellIdentifier` occurrence counts to a line count. Sum `significantHaskellLineCount` over a
  `requiredSourceSection` slice of each added function; do the same for "the rooted-opening runtime stays inside
  its sprint line budget" (near lines 3227-3229), measuring the opening code in `Lifecycle/Rooted.hs` and
  `Handoff/Relay.hs` as well as `Handoff/Runtime.hs`.
- "Hidden module is built but not exposed" for `Authority.FailedUp.Internal` (near line 3047) matches a
  three-module run of `other-modules` text. Assert the module's placement exactly with `fieldModules`: in the
  private test-reachable sublibrary named above, and in no public `exposed-modules` field.

### Sprint 17.53: Failed-Up unwind adoption [Active]

**Status**: Active
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

#### Remaining Work

- Child adapter order (`Teardown/Executor/Internal.hs`, `withStorelessReverseExecutorKernel`, `ProjectUp` arm):
  put the operations `failedUpExpectedOperations` decodes into admitted forward order before
  `failedUpTeardownPlanKernel`. Keep the byte-exact `observed /= canonical` comparison, which pins the
  deepest-first wire order. Using Sprint 17.37's second reversible `vm-orchestrator-1` step, extend the
  failed-up `RecursiveLifecycleSpec` case so that the VM frame's failed-Up adapter carries two operations.
  Assert that `up` exits 1 with no "is not an ordered subset of the admitted plan" text on stderr, and that
  `reverse-attempts` names both VM steps once each.
- Failure attribution (`runRootFailedUpUnwind`, `Command/LifecycleEntry.hs`): mark as `failed` the last
  element of the root's own `reached` list, which is the root operation that failed. Mark every other row
  `succeeded`, whatever its position after `frozenReached` appends child operations. Add a fixture flag
  that appends a failing root step after the descending root step. Assert that the published
  failed-forward report read back from the fixture store names that root step as `failed` and the child
  operations as `succeeded`.
- Child unwind failure (`admitFirstFailedFrame` and its caller): `admitFailedUnwind` tells "this frame has no
  failed report" apart from "the unwind began and failed". Continue to the next frame only on the first,
  stop on the second, and append its detail to the returned Up failure. Delete the
  `Left _ -> finishRootUnwind` arm that drops it. With the fixture's `failContainer` and `failCleanup` flags
  both set, assert that `up` exits 1 and that stderr carries both the container failure and the unwind's
  "left unsettled work" detail.
- Catalog-free branch (`runRootForwardCoordinator`, `null catalogEntries`): a `loadSigningKey` failure and a
  `Left` from `withRootBroker`/`runRootFailedUpUnwind` are appended to the returned failure detail, not
  dropped through `Left _ -> pure ()` and `_ <-`.
- Failed-Up route (`launchFailed`): use the reverse coordinator's `targetBinary` rule, which is empty when the
  innermost layer is `ViaContainer`, through one helper shared with the reverse coordinator. Remove dependence on the
  forward coordinator's singleton-only target rule from the failed-Up path.
- Correct the `runRootProjectUpLifecycleEntry` Haddock. Only Chain success moves the cursor to Teardown. A
  controlled failure and an unexpected exception both stay at Execute, and the reverse entry's
  Execute-to-Teardown bridge recovers them.
- Add a host-portable `CLISpec` case "a failed single-frame up unwinds its reached prefix". Step A is
  `reversedBy` and records each call to a file; step B returns `StepConflict`. Assert that `project up` exits
  1 and that A's reverse ran exactly once, with the action `failedUpTeardownPlanKernel` projects for it, and
  B's never ran. Then assert that `project destroy` exits 0 through the Execute-to-Teardown bridge. Add a
  second case where A's reverse returns `TeardownFailed`, and assert that
  stderr names both the Up failure and the unwind failure.
- Catalog branch (`runRootForwardCoordinator`, after `runChainFromFrameWithDescentFailure` fails): a
  `cancelUnusedFrameSessions` failure or a `runRootFailedUpUnwind` `Left` is appended to the Chain's
  `detail` (`detail <> "; cleanup: " <> failure`). The retained `(detail, reached, unresolved)` tuple is
  returned with the combined text, never replaced by `(failure, [], [])`. The same CLISpec unwind-failure
  case asserts that stderr still names the failing step.
- When `rootForwardBrokerLink` returns `Left`, call `cancelUnusedFrameSessions services` before returning, and
  append a cancellation failure to the link failure. Better, one bracket around the opened sessions cancels the
  unattached ones on every early exit. Add a `ProjectPlanSpec` source guard that the link-failure arm cancels.
- Harness failed-Up (`Command.hs`): move the Haddock that sits above `runFailedDeclared` to
  `runExactProjectUp`, and give `runFailedDeclared` its own Haddock. A node with no declared reverse and a
  `CoreManagedReverse` policy is reported as `TeardownForeignRetained "deferred to the Harness reverse owner"`
  and sets the rollback-acquired flag, as `runHarnessFailed` does for declared reverses. Only a node that
  acquired nothing reports "the node acquired nothing this frame must release". Add a `HarnessSpec` case: a
  root `deploy-kind` node followed by a failing step, asserting the unwind report's row for `deploy-kind`.
- `TeardownSpec` "failed-Up cleanup retains Up while projecting only the exact reached prefix": match the
  refusal detail ("the failed-Up reached set contains a duplicate" for the duplicate case, and the
  "is not an ordered subset of the admitted plan" text for the foreign case). Add a case whose reached set
  skips an earlier admitted operation (an ordered subset that is not a prefix) and assert that it is
  admitted. Add a reordered case, `["core:build-pb", "core:deploy-vm"]`, refused with the
  ordered-subset text. Rename the case "... only an exact ordered subset".
- Recovery-edge verb admission (`Handoff.hs`): `recoveryOpenIdentity` (near lines 3371-3383),
  `validateRecoverySigningEnvelopeActive` (near line 3098), and `withVerifiedRecoveryHandoff` (near line 4088)
  admit only `down` or `destroy`, so the failed-Up unwind, whose broker verb is `up`, gets
  `HandoffRecoveryVerbInvalid "up"` on every reverse child edge it opens. Admit `up` with phase `teardown` in
  all three, consistently with `validatedLifecycleBinding`; `up` with any other phase still refuses. Add a
  store-backed `HandoffSpec` registration case under an Up broker (on Sprint 17.17's seam) that admits the
  teardown phase and refuses the execute phase, and assert in the failed-up `RecursiveLifecycleSpec` case
  (Sprint 17.54) that the child's reached reversible steps appear in `reverse-attempts`.
- The reached and unresolved lists `runChainFromFrameWithDescentFailure` returns, the only input deciding
  what a failed Up releases, are never inspected by a test. Add a `ChainSpec` case with two `reversedBy` nodes
  where the second fails, and assert the returned lists name exactly the reached prefix, including the failing
  node's own and projected keys, in order, and nothing beyond it.
- `Chain.hs` rethrows a step exception as a fresh `userError` after settling, so
  `runRootProjectUpLifecycleEntry`'s `fromException` `SafetyRefusal` branch never matches a step's refusal and
  the safety marker is lost. Rethrow the original exception after settlement. Rewrite `CLISpec` "project up
  safety refusal skips automatic project teardown" (near line 1032) with a forward-call counter and a paired
  control: an acquiring step with a declared reverse followed by an ordinary step failure runs that reverse
  once, while the same step followed by a `SafetyRefusal` runs none and stderr carries the
  `HOSTBOOTSTRAP_SAFETY_REFUSAL` marker.

### Sprint 17.54: Proof-complete host-static real-process gate [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`,
`core/hostbootstrap-core/test/Spec.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`,
`documents/engineering/composition_patterns.md`

#### Objective

Close the recursive command with static proofs and real local process-boundary behavior.

#### Deliverables

- One local root/VM/container fixture exercises forward, Down, Destroy, and failed-Up unwind.
- Tests use real child processes, duplex pipes, installed root identity, the root store, and public command gate.
- Each fixture installs the compiled binary, fresh identities, sibling config, and project tree under one
  temporary anchor. Native compiled clients forward the private protocol pipes to that binary.
- Every case remains present on every host. The POSIX row runs the recursive transitions; where that row
  is unavailable, the case asserts its declared refusal and the real receiver's rejection of the different
  native canonical root. The coverage manifest declares the group's cases and its POSIX row cases
  (`familyCases` and `familyRowCases`, eight and six in the tree) without counting a refusal as guest
  execution.
- The `incus` and `docker` names on the fixture's `PATH` are copies of the test executable that relay the
  private protocol pipes and ignore their argv. The group is a process-transport fixture, and its name and
  manifest `familyPath` say so; it is not evidence of a provider crossing (§ NN).
- Each reverse case asserts the cross-process effect order, not only the exit code: the fixture's
  `reverse-attempts` file shows child-first order, and a repeated verb adds no row.
- Real-process cases prove a child crash mid-exchange, an operator interrupt of the root, and partial failure.
  In each, the root exits non-zero, no fixture child process outlives the command, and a following reverse
  verb converges. Scope, catalog, session, frame, node, key, nonce, ordinal and digest mismatch refusals are
  proven at the kernels that own them (Sprints 17.32 to 17.42 and 17.49), not through this fixture.
- This sprint changes no production module and adds no production type or call-site adoption. The process
  fixture remains one bounded module; script detection and case accounting extend the existing shared guards.

#### Validation

Run `cabal test all --ghc-options=-Werror` from `core/`. The named recursive-lifecycle group must execute real
local process fixtures on linux-cpu; record dated counts and source/compile-fail evidence after the gate passes.
The sprint closes when the cases named in Remaining Work exist and pass on the POSIX row. Until then the group
asserts exit codes for the reverse and failed-Up cases. It has no crash, interrupt or reap case; the destroy
interruption probe serves `RecoveryInterruptionSpec` only. Process-group ownership is a source guard in
`EffectSpec`. None of the group's eight cases drives a control-frame timeout, KILL escalation, truncation,
EOF, cancellation, descendant cleanup, or `OpenFrame` replay; those cases are owed by the sprints that own the
behaviour (17.37, 17.39, 17.40, and 17.42), not by this fixture.

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

#### Objective boundary

Consuming root `DestroySettled` as `ProjectClosureEvidence SettledDestroyClose` also requires the bound run
lease and the all-sessions-closed proof, and recovery beyond the retained live plan belongs to the
[recovery phase](phase-18-recovery-and-migration.md). This sprint's gate is the host-static real-process
one and nothing beyond it.

#### Remaining Work

- In the two "public down/destroy unwinds ... child-first" cases, read `reverse-attempts` after the verb
  and assert the child-first rows: `container`, then the `vm-orchestrator-1` steps in reverse plan order
  (with Sprint 17.37's second step), then `root`. In "public down then destroy preserves the recursive source",
  read it after every verb. Assert the child-first rows once for the first `down` and once for the first
  `destroy`, and assert that the repeated `down` and the repeated `destroy` append no row.
- In "failed up preserves its failure and admits exact reverse recovery", read `reverse-attempts` after the
  failed `up`. Assert that each reversible step the failed Up reached appears exactly once, in child-first
  order, and that the failed `container` step does not appear. From the fixture store, read the root's
  failed-forward report and its reverse-completed report, and assert that they are two distinct canonical
  records.
- Add a case "a child that dies mid-exchange fails the root and leaves no process". A fixture flag makes
  the container child write its pid to `child-pid` and `exitWith (ExitFailure 9)` after its first
  `settle-node` is acknowledged. Assert that `up` exits 1 within the test's bound and that the recorded pid
  no longer runs, then that `destroy` exits 0.
- Add a POSIX-row case "an interrupted root aborts and reaps its children". Start `project up` as a
  subprocess with a fixture flag that makes the container step block on a sentinel file. Once the container
  child's pid file exists, send the root `SIGINT`. Assert that the root exits non-zero without running the
  failed-Up unwind (no new `reverse-attempts` row), that the child pid no longer runs, and that a following
  `destroy` exits 0. This depends on Sprint 17.40's change that lets asynchronous exceptions propagate.
- In "a failed reverse operation is settled once and terminates the child", assert the exact file contents,
  `attempts @?= ["container"]`, so no parent reverse runs after the child's failure.
- In "public up crosses two real authenticated process boundaries", assert a per-frame marker that only the
  `vm-orchestrator-1` and `container` child processes write (each frame's forward step appends its frame name
  to a `forward-frames` file), and assert the file lists both child frames.
- Rename the group from "RecursiveLifecycleSpec (real root/VM/container lifecycle)" to
  "RecursiveLifecycleSpec (root/VM/container process-transport fixture)" in the spec and in the
  `CoverageManifest` `familyPath`. Make `runLifecycleFixtureClient` append its argv to a `crossings` file, and
  assert in the up case that one `incus` crossing names the fixture VM instance and one `docker` crossing
  carries `-i` and the child frame's `HOSTBOOTSTRAP_CURRENT_FRAME`.
- "the local provider reprobe kernel returns only nonce-bound observation data": decode the response under
  a second nonce and assert `Left`, or move the case beside `HandoffSpec`'s reprobe cases and out of this
  group's manifest count.
- Run `cabal test all --ghc-options=-Werror` from `core/` on linux-cpu over the final phase source and record
  in Validation the `RecursiveLifecycleSpec` count with every POSIX-row case executing its recursive
  transitions. The only phase gate evidence is native Windows, where `posixOwnershipSupported` is `False` and
  six of the eight family cases record declared refusals instead.

### Sprint 17.55: Protected fresh Harness invocation [Active]

**Status**: Active
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

The generation advance allocates the epoch and compare-and-swaps mode and lease (`Mode.hs`, near lines
7849-7883) before `verifyOsPrincipal` and the root checks, and `runProtected` is not transactional, so a
refusal leaves the store half advanced. Its settled-destroy evidence carries only a `ProductionCloseKind`, so
evidence minted for one generation advances another. `withFreshHarnessInvocation` is exported with no caller
and no test. The restart `CLISpec` case (near line 672) observes call counts and phases but not run identity;
`withRestartedBoundPlanSnapshot`'s refusals and the pre-effect refusal of `withFreshHarnessInvocationFrom` are
produced by no test. The sprint closes when the changes and cases in Remaining Work exist and pass in the
warning-clean `cabal test all` from `core/` and the four host static gate commands pass.

#### Remaining Work

- Delete the callerless `withFreshHarnessInvocation` (`Mode.hs`, near lines 7956-7993) and its export.
- In `withFreshHarnessInvocationFrom` and `withFreshHarnessDestroyInvocation`, run `verifyOsPrincipal`, the
  `withExistingVerifiedRoot` checks, and every other refusable check before `withFreshEpoch` and the mode,
  lease, and profile-slot writes, as `withProductionRoot` and `withHarnessRoot` do. Add a case where operator
  verification refuses and the mode and lease records are byte-identical afterwards.
- Bind settled-destroy evidence to its generation: `ProjectClosureEvidence` carries the source broker epoch
  and bound lease version that `destroySettledClosure` read, and `withFreshHarnessInvocationFrom` refuses
  evidence whose coordinates differ from the source bound lease. Add a case that reuses one generation's
  evidence at the next generation and is refused; and a case that presents pre-effect evidence and is refused
  with `ModeClosureMismatch`, store unchanged.
- In both `readExactSourceMode` helpers, a mode held by another mode or run returns
  `ModeHeldByAnother (modeWireName observedMode) (modeWireName wantedMode)`; only a matching mode at another
  epoch returns `ModeEpochMismatch`.
- `withFreshHarnessDestroyInvocation` hands its continuation a `LifecycleProfile` built without touching the
  profile slot, while its Haddock says it hands out no planning profile. Rearm the slot through
  `initializeProfileSlot` as the up variant does, and rewrite the Haddock to say the destroy generation
  receives the exact retained plan's profile.
- `withRestartedBoundPlanSnapshot` (`ProjectPlan/Snapshot.hs`): add the fresh path's backstops (bound lease
  epoch against the root epoch, the bound lease location's project and store against the root, the plan
  profile name against the lease mode). Add `LifecycleSpec` cases that persist a Harness snapshot, rotate the
  lease, and call it with a plan admitted from different drafts, with a root from another store, and with each
  backstop drifted, asserting the exact `ModeEvidenceMismatch` subject.
- Haddocks in `Mode.hs`: list the generation-rotation `deliver` helpers (near lines 7918 and 8151) as
  `HarnessCloseRoot` producers or route them through `currentHarnessCloseRoot`; delete the stale first
  Haddock block above `retainBoundLeaseGeneration` (near line 9091).
- In the `CLISpec` restart case, record the run name, the plan digest (`observeBoundHarnessPlan`,
  `stepExecutionPlanDigest`), and the broker epoch before and after the restart, and assert the same run, the
  same digest, and an advanced epoch.

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

### Sprint 17.57: Generation-correct Harness close fallback [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`, `core/hostbootstrap-core/test/AuthoritySpec.hs`
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

The close control's fail-closed refusals have only source-text guards: no test produces the Binding,
Pending, or Consumed refusal of `consumeOwnedHarnessClose`, `settleOwnedHarnessClose`'s refusal of
`PreEffectRefusalClose` evidence, or an out-of-order transition (`Harness/Ownership/Internal.hs`, near lines
158-265); `HarnessSpec` checks only that the function names appear in order in `Command.hs`. No test drives
`closeHarnessRun`'s refusal of settled-destroy evidence (`Mode.hs`, near lines 8498-8500). The sprint closes
when the cases in Remaining Work exist and pass in the warning-clean `cabal test all` from `core/`.

#### Remaining Work

- Make `Harness.Ownership.Internal` reachable from the test suite (its private sublibrary, or through
  `withOwnedHarnessRoot`) and drive each `OwnedHarnessCloseControl` state (Unbound, Binding, BoundFallback,
  Pending, Settled, Consumed) through `consumeOwnedHarnessClose` and every transition function. Assert the
  exact `Left` text for Binding ("did not yield its exact bound close fallback"), Pending ("recovery is
  required"), Consumed ("already consumed"), `PreEffectRefusalClose` evidence presented to
  `settleOwnedHarnessClose`, and each out-of-order transition, and that neither `closeUnbound` nor `closeBound`
  runs on a refused state.
- Add a `HarnessSpec` (or `AuthoritySpec`) case that mints `SettledDestroyClose` evidence for a Harness run
  through the recovered-forest path and asserts `closeHarnessRun` returns
  `Left (ModeClosureMismatch "pre-effect refusal" "settled destroy")` with the store unchanged.

### Sprint 17.58: The process route names its interactivity [Active]

**Status**: Active
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

The validated values do not reach the renderer. `sanitizedLaunch`, `validateComposedLayers` and
`admittedContainer` bind the target-binary, instance, distribution, image and mount results with `_ <-`
(`Route.hs`, near lines 370-436), and `folded` hands `Lift.foldLeaf` the original `LiftContext` strings.
Only the child frame renders from a `ValidatedArgument`. The sprint closes when the change in Remaining
Work lands, the argv fixtures render unchanged, and the host static gate passes.

#### Remaining Work

- Make the lifecycle argv render from the validated values. Either build the `LiftContext` handed to
  `Lift.foldLeaf` from the `ValidatedPath`/`ValidatedArgument` results, or add a lifecycle-specific
  render that takes them. No `_ <- sanitizedPath`, `_ <- sanitizedArgument` or discarded
  `traverse sanitizedMount` result remains in `Route.hs`. Extend the route's `ProjectPlanSpec` source guard to
  assert that absence. The existing per-provider argv fixtures must render byte-identical vectors.
- Correct the `ChannelInteractivity` and `withLifecycleProcessRouteLaunchKernel` Haddocks in `Route.hs`. They
  say the VM providers run noninteractively "because nothing on the far side of them reads that descriptor"
  and that the borrow reports whether the shape keeps standard input attached. The VM child reads its Offer
  from the same piped standard input, and `Process.hs` pipes it for every provider while ignoring the value
  (`_interactivity`). The value only tells the container shape, whose `-i` `admittedContainer` renders,
  apart from the VM shapes. Either the spawn site consumes the value, or the borrow continuation drops it
  and the type stays inside `Route.hs`; the Haddock states which.

### Sprint 17.59: The descent resolves a provider its own chain just installed [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostConfig.hs`,
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

### Sprint 17.60: The reachability step actually reaches [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Teardown`,
`HostBootstrap.Command.LifecycleEntry` (3; cap 3)
**Sprint budget**: one action constructor, one node state, one projection, one named pre-descent handler and
two refusals; at most 120 production Haskell lines and no new type.
**Substrates**: linux-cpu

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

The host static gate. `TeardownSpec` asserts that the step carries the declared callback and that a node
declaring no reverse has no reachability effect to run. The case named "the pre-descent step runs the
provider's own declared reverse, with ReachFrame" calls the callback itself with `ReachFrame` and reads the
same value back. It runs no driver, so replacing the driver's handler with `const (pure TeardownReleased)`
passes it. No test reaches `nestedPreDescentRefusal`. A foreign or refused reachability answer settles the
provider over pending children, and `nextTeardownWork` then yields a completion that only
`verifySubtreeSettled` rejects; the existing case pins that behaviour. The sprint closes when the
driver-level, nested-refusal, blocked-subtree and tightened driver cases named in Remaining Work exist and
pass. The effect itself is observable only live, and the
[worked demo](phase-24-worked-demo.md) is where it is observed: its 2026-09-14 gate records
`project destroy` reporting `starting hostbootstrap-demo-vm so its retained children can be reached`,
settling every retained child through the frame it reopened, and exiting 0 — where the same sequence had
refused with `Error: Instance is not running`.

#### Remaining Work

- Name the pre-descent handler. Move the lambda that `runRootProjectReverseLifecycleEntry` passes to
  `driveTeardownForest` (`Command/LifecycleEntry.hs`, near line 1371) into one function in `Teardown.hs`,
  `runPreDescentReachability :: HostConfig -> PreDescentStep scope planId frame verb -> IO TeardownOutcome`.
  `Nothing` answers `TeardownReleased`; `Just declared` runs `declared cfg ReachFrame`. Move
  `nestedPreDescentRefusal` beside it. The root reverse driver and `runFailedUpUnwind`, which today passes
  `const (pure TeardownReleased)`, both call it and append a `TeardownFailed` detail to their failure list.
- Rename the existing `TeardownSpec` case to "preDescentStepRun returns the provider's declared reverse".
  Add a case that drives `driveTeardownForest` over `reachablePlan recorder` under `ProjectDestroy` with
  `runPreDescentReachability` as the pre-descent handler and a descent handler that appends to the same log.
  Assert that `ReachFrame` is logged before the first descent. Add a second case where the recorder returns
  `TeardownFailed "provider unreachable"`. Assert that the descent handler is never called and that
  `driveTeardownForest` returns `Left` naming `core:deploy-vm`.
- Add a `TeardownSpec` case asserting that `nestedPreDescentRefusal` answers `TeardownFailed` and that its
  text names the step's key.
- Keep a failed reachability step distinct in `Teardown.hs`. Add a `PreDescentFailed` node state that the
  `RetryWork` pass offers again only as a pre-descent step, and make `withTeardownAuthorization` build
  `SettledChildren` only when every child of the node is `Settled`. Change the case "failed provider
  reachability retains its children without offering guest descent" (`TeardownSpec`, near line 703). After
  the failure it expects the pre-descent step for `core:deploy-vm` again, not
  `OfferedLocal "core:deploy-vm" DeleteFrame`.
- In `advanceAuthorizationPoint`'s pre-descent arm (`Teardown.hs`), a `TeardownForeignRetained` or
  `TeardownRefused` outcome moves the provider to `PreDescentFailed` and keeps its observation, instead of
  `terminalNode`. `driveTeardownForest` adds the key to its failed set for any non-`TeardownReleased`
  pre-descent outcome, and returns `Left` naming the unreached children and the provider.
  `nextTeardownWork` takes the completed branch only when `teardownForestOutstanding` is empty. Rewrite the
  `TeardownSpec` case "a pre-descent foreign result cannot hide unobserved child nodes": after the foreign
  answer `nextTeardownWork` offers the pre-descent step again, not a completion, and a driver run over the
  same forest returns `Left ["core:deploy-chart", "core:deploy-kind", "core:build-pb", "core:deploy-vm"]`.
- Tighten "a failed node stops the run and names every node left outstanding" (`TeardownSpec`): assert
  `outstanding @?= ["core:deploy-chart", "core:deploy-kind", "core:build-pb", "core:deploy-vm"]` exactly,
  record the reported rows instead of `\_ _ -> pure ()`, and assert the descent key's row is
  `TeardownFailed "boom"`.
- In "the ordinary branch carries the settled-child proof", assert
  `teardownForestOutstanding ready @?= ["core:deploy-vm"]` before taking the proof, so the proof is shown to
  follow settlement and not structure.
- In `TeardownSpec.hs` (near line 1299), move the orphaned "The demo's own shape: an ensure step that
  preserves on reverse…" Haddock block from above `reachablePlan` to directly above `demoShapedPlan`, which it
  describes.

### Sprint 17.61: Canonical resource records refuse the short close [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
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

### Sprint 17.62: Typed rooted catalog entry coordinates [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/RootedPlan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Handoff/Internal.hs`,
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

#### Remaining Work

- Introduce the six role newtypes in `Lifecycle/RootedPlan.hs` and thread them through the descent
  constructor, the three folds, and the manifest renderer.
- Update the fold consumers in `ProjectPlan/Handoff/Internal.hs`, `Command/LifecycleEntry.hs`, and
  `Teardown/Internal.hs` to bind the typed roles.
- Add `test/compile-fail/SwapRootedPlanCatalogCoordinates.hs`, register it in `CompileFailSpec`, and re-pin
  the `ProjectPlanSpec` signature guards.

### Sprint 17.63: `project up --dry-run` renders without Production authority [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
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

#### Remaining Work

- Replace the dry-run arm of the fresh branch in `runUp` with a read-only render path that opens no
  `withProductionRoot`, and add the two `CLISpec` cases above.

### Sprint 17.64: The root project gate names the evidence it refuses [Planned]

**Status**: Planned
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

#### Remaining Work

- Add `AuthorityEvidenceMismatch` to `AuthorityError` in `Authority/Kernel.hs` with its `authorityErrorMessage`
  row, and route `authorizeRootProject`'s `malformed` helper and its lifecycle-context refusal through it.
- Add the `AuthoritySpec` drift table above, one case per retained term.
- Replace "the generic root gate consumes one exact root lifecycle context for every closed verb" (near line
  347) with the drift table, or keep it as a placement check that pins whole comparison lines, observed
  operands included, and the `requireText` definition as `SourceGuard` token sequences.

### Sprint 17.65: The forward-child projector takes typed frame roles [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Projection/Internal.hs`,
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

A new compile-fail fixture installs a projector that uses the child id where the parent id belongs and fails
with one type-mismatch diagnostic naming `ParentFrameId`. `CLISpec`'s projector cases and
`RecursiveLifecycleSpec`'s public cases pass unchanged, `demo/` builds and its tests pass, and the four host
static gate commands pass.

#### Remaining Work

- Change the projector type in `CLI.hs` and thread the typed roles through `ProjectPlan/Construct/Internal.hs`
  and `ProjectPlan/Projection/Internal.hs`.
- Update `demoForwardChildPlan` in `demo/src/HostBootstrapDemo/Commands.hs` and any `demo/test` fixture that
  installs a projector.
- Add `test/compile-fail/SwapForwardChildProjectorFrames.hs`, register it in `CompileFailSpec`, and re-pin
  the `ProjectPlanSpec` projector signature guards.

### Sprint 17.66: The rooted post-open response family is a closed sum [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
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

The existing rooted response cases and `RecursiveLifecycleSpec`'s public cases pass with byte-identical wire
output; a `ProjectPlanSpec` guard pins the sum, the total renderer, and the absence of the wildcard arm; the
four host static gate commands pass.

#### Remaining Work

- Introduce `PostOpenFamily` and its renderer in `Handoff/Relay.hs`, replace `family :: Text` in
  `withRootedPostOpenResponseKernel`, `build`, and `postOpenNonce`, and update the `LifecycleEntry` call sites
  (including the variable-family `respond session family body after` near line 2235).
- Add the `ProjectPlanSpec` guard above and delete the wildcard-arm refusal text from any existing guard.

### Sprint 17.67: The resource-record set hashes and frames through Digest [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`
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

`ResourceRecordSpec` passes unchanged inside `cabal test all --ghc-options=-Werror` from `core/`, and the host
static gate (§ JJ) passes.

#### Remaining Work

- Delete `sha256Hex`, `frameWire` and its `word64BigEndian` helper from
  `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`, and import `sha256Hex` and
  `frameWire` from `HostBootstrap.Digest`.

### Sprint 17.68: The core test fixture's init assembler refuses through `failConfigAssembly` [Planned]

**Status**: Planned
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

#### Remaining Work

- Make `Fixture.projectInit` return `ConfigAssembly scope (ProjectConfig scope)` with `failConfigAssembly`
  on an `addRole` refusal, update its four callers (`ChainSpec`, `CLISpec`, `ContextSpec`,
  `RecursiveLifecycleSpec`) that wrap it in `pureConfigAssembly`, and add the `ContextSpec` init-refusal
  case under Validation.
- Rewrite the `Fixture.hs` module header as Deliverables states.

### Sprint 17.69: Project-spec finalization reads its scope tag from the scope index [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct/Internal.hs`,
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

#### Remaining Work

- Drop the `ScopeKind` parameter from `withFinalizedProjectSpec` in
  `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct.hs` and from `withFinalizedProjectSpecKernel`
  in `ProjectPlan/Construct/Internal.hs`, add the `KnownScopeKind scope` constraint to both, and have the kernel
  pass `scopeKindOf (Proxy @scope)` as the `ScopeKind` argument of `withFinalizedServiceRegistry`.
- Remove the `HarnessScope` literal from the `withFinalizedProjectSpecKernel` call in
  `withHarnessFinalizedProjectSpecKernel` (`ProjectPlan/Construct/Internal.hs`).
- Drop the scope-tag argument at the `HostBootstrap.CLI` call sites and at the `CLISpec`, `ProjectPlanSpec`, and
  `SessionSpec` call sites listed under Deliverables.
- Rewrite the `ProjectPlanSpec` source guard `Harness refinalization reuses the exact static projector` (in
  `forward-child projection ownership is hidden, fixed-unit, acyclic, and frozen`) to the two fragments under
  Validation, without `scopeKind` and without `HarnessScope`.
- Add `core/hostbootstrap-core/test/compile-fail/FinalizeProjectSpecWithScopeKind.hs` and register it in
  `CompileFailSpec` with the `rejectsWith` expectation under Validation.

### Sprint 17.70: Child-plan admission checks the running frame [Planned]

**Status**: Planned
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

#### Remaining Work

- Add the running-frame parameter and the refusal to `withChildProjectPlan` in
  `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct.hs`, pass `Context.currentFrame` from
  `Command/Child.hs` and drop its call-site comparison, update the `ProjectPlanSpec` and compile-fail callers,
  and add the `ProjectPlanSpec` case named in Validation.

### Sprint 17.71: The prepared gate binds the journaled transition and call digest [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/test/PrepareFixture.hs`
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
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared.hs`,
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
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted/Receipt.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

The authenticated handoff phase (Phase 13, Sprint 13.19) gives the rooted kernel coordinates private nominal
types and retypes the kernels whose callers that phase owns. The six rooted lifecycle request kernels and
`rootedOpenedResponseUnsignedKernel` are called only from this phase's modules, so retyping them, and adopting
the newtypes at those callers, lands here (§ HH).

#### Deliverables

- `rootedOpenFrameRequestKernel`, `rootedNextNodeRequestKernel`, `rootedSettleNodeRequestKernel`,
  `rootedDescendResultRequestKernel`, `rootedCloseFrameRequestKernel`, and `rootedReceiptConfirmRequestKernel`
  take `LifecycleSession`, `LifecycleStage`, `LifecycleOrdinal`, and `PredecessorDigest` instead of
  `Text`/`Word64`.
- `rootedOpenedResponseUnsignedKernel` takes `RequestDigest`, `LifecycleSession`, and `LifecycleStage`.
- `Handoff.Process.Route`, `Lifecycle.FrameExecutor`, `Lifecycle.Rooted` with its `Node` and `Receipt`
  submodules, and `Command.Child` construct the newtypes at their own boundaries.
- The canonical bytes are byte-identical to the current wire; the change is type-level only. Callers beyond
  the three production modules or 400 lines § G allows this sprint are adopted by a following sprint.

#### Validation

The sprint closes when the existing `HandoffSpec` golden-byte and round-trip cases and `RecursiveLifecycleSpec`'s
public `up`, `down`, and `destroy` cases pass unchanged under `cabal test all` from `core/`, which proves wire
stability, and the four host static gate commands pass.

#### Remaining Work

- Retype the six request kernels and `rootedOpenedResponseUnsignedKernel` in `Handoff/Rooted.hs` to the
  Sprint 13.19 newtypes.
- Adopt the newtypes at `Handoff/Process/Route.hs`, `Lifecycle/FrameExecutor.hs`, `Lifecycle/Rooted.hs`,
  `Lifecycle/Rooted/Node.hs`, `Lifecycle/Rooted/Receipt.hs`, and `Command/Child.hs`, splitting into a following
  sprint if the adoption exceeds the § G module cap.

## Remaining Work

- Sprint 17.1: add command-level operator-refusal and root-frame-refusal cases per verb, gate `project up` on
  the host orchestrator, fix the stale `withVerifiedRootInvocation` and `runUp` comments, and make the
  sibling-context case assert its precondition.
- Sprint 17.2: delete the argv-descent `runChainFromFrame`/`handoffDispatch` and the dead
  `_failChain`/`_reverseProjection` teardown in `Command.hs`, retarget the guards they satisfy, and add the
  two-frame pre/child/post order case.
- Sprint 17.3: rewrite `TeardownSpec`'s source-shape guards through `SourceGuard`.
- Sprint 17.4: split `ForgeTeardownForest.hs` into one pinned compile-fail fixture per forged value.
- Sprint 17.5: make every frame node wait on its child subtree and pin the worked-demo first offer and drain
  order.
- Sprint 17.6: add the wrong-verb/digest/frame, mismatched-proof, and positive-control settlement cases.
- Sprint 17.7: add the root-refinement refusal case, the `lifecycleContextErrorMessage` golden table, and the
  mint-refusal cases.
- Sprint 17.8: correct the `LifecycleEntry` Haddocks, delete the callerless `lifecycleEntryVerbName`, and move
  the single-importer guard onto `SourceGuard` tokens over both source roots, deleting `CLISpec`'s private
  walker.
- Sprint 17.10: add reverse-root codec value cases and store-backed ordinary-admission refusal cases.
- Sprint 17.11: report Down after a terminal Destroy as terminal, cover the remaining resume/redo branches,
  and anchor the Committed section on its definition.
- Sprint 17.13: keep the absent-mode failure when no intent exists, and add the liveness, lease-conflict, and
  partial-application forcing cases.
- Sprint 17.14: add `CLISpec` cases for each reverse-root admission, in-progress, version-exhaustion, and
  target-cursor-version refusal.
- Sprint 17.15: add behavioural cases for the prepared reverse-descent refusals, including the foreign-store
  command authority.
- Sprint 17.16: correct the producer-ordering label and its substring fragments.
- Sprint 17.17: keep compare-and-swap store failures in the recoverable-open map and add its store-backed
  registration, retry, rotation, and refusal cases.
- Sprint 17.18: make `recoveryHandoffScope` total with a refusal and a case.
- Sprint 17.19: add the unknown-outcome decode case and well-formed over-bound cases, restrict reverse-failed
  rows, and positive-control the origin cases.
- Sprint 17.20: report refused/failed reverse children as failures, keep the child's detail through the relay,
  preserve asynchronous exceptions in the receiver, test the live completion refusals, and rename the
  tombstone guards.
- Sprint 17.21: keep row-writer store failures and add store-backed lifecycle row state-machine cases.
- Sprint 17.22: record the replay disposition only after the acknowledgement is sent, and add the relay codec,
  one-shot gate, line-budget, and `BrokerLink` field cases.
- Sprint 17.23: prove projector retention behaviourally and drop the implied size checks.
- Sprint 17.24: delete the planned-forward package and the nested lifecycle-context eliminator, and add the
  projected-root refusal table.
- Sprint 17.25: refuse a foreign broker epoch in `admitRoot`, delete the callerless
  `withRootedPlanCatalogEntryKernel`, compare the Direct container placement, and add the per-row projection
  and Direct rebase cases.
- Sprint 17.26: widen and tighten the `SpecIndexSpec` importer, export, and token-authority guards, correct
  its header, and delete its one-sided module-enumeration case.
- Sprint 17.27: compare recovered drafts by bytes, add the registry-mismatch refusal, and reword the fixture
  comments.
- Sprint 17.28: report a failed catalog manifest publish as the store failure, with a case, and assert the
  retry's refusal reason.
- Sprint 17.29: add one case per catalog forward-package recheck.
- Sprint 17.30: correct the preparation-order guard and prove the order against a store.
- Sprint 17.31: add behavioural cases for the runtime arms' refusals.
- Sprint 17.32: derive the session root lineage from the catalog, key direct openings apart, verify the signed
  `Opened`, tighten advancing, keep row-kernel store failures, and add behavioural row, key, and refusal cases.
- Sprint 17.33: frame the runtime generation and the operation key into gate packages, fix the grant Haddock,
  and add the gate-package codec cases.
- Sprint 17.34: bind `Settled` to its request and observation, refuse a signed `Refused`, and add behavioural
  settlement refusal cases.
- Sprint 17.35: bind receipt confirmation to the session predecessor, with a stale-digest case, and delete the
  callerless combined receipt helper.
- Sprint 17.36: tie the envelope bounds to the codec's own constants in one guard.
- Sprint 17.37: compare gate-package operation and catalog identities, give routed gates their own
  supersession field, check replayed `Prepared` pairs, close the request selector, pin both opening kernels,
  and add the two-grant and behavioural refusal cases.
- Sprint 17.38: bind the reverse route to its `ReverseDescent`, refuse composed forward routes, correct the
  route Haddocks, delete `rejectedOverrides` and the callerless `withRecoveryLifecycleProcessRouteKernel`, fix
  the argv guard, and add behavioural route refusal and argv cases.
- Sprint 17.39: prove redirection in the fixture and delete `stdioHandoffChannel` and the raw-channel
  receiver export.
- Sprint 17.40: drop the no-op launch timeout and delete the then-unimported `launchMicros`, rethrow
  asynchronous exceptions, await the child's exit before signalling its group, escalate on group existence,
  correct the module header, widen the no-named-type guard, and add the escalation and grandchild-reaped
  cases.
- Sprint 17.41: settle and close a frame whose forward step throws, with a case, and state the Child-owner
  budget as a line count.
- Sprint 17.42: answer an exact `OpenFrame` replay, reword the post-completion refusal, refuse foreign forward
  observations, narrow and test the forward root link and make its Haddock state what it enforces, and add the
  edge-admission rejection, requester provenance, and installed activation-signer cases.
- Sprint 17.43: gate forward terminal reports on the settled stage and add their session-guard cases.
- Sprint 17.44: delete the dead rehydrated-completion path, scope parent-row rehydration to its edge, classify
  rehydration typed, split the rehydration guard, and add the restart and verifier refusal cases.
- Sprint 17.45: settle a throwing reverse callback as failed, delete the callerless
  `withVerifiedReverseAdapterKernel`, keep one adapter renderer, decode UTF-8, and add
  executor, profile-classification, and storeless-identifier cases.
- Sprint 17.46: prepare root-local cleanup durably, check the gate at every root cluster release site, delete
  the uncalled `runPreparedRootClusterCleanupKernel`/`runExactClusterCleanupKernel` pair and its `HandoffSpec`
  guard, and add the `FakeCluster` down, destroy, and failed-Up cases.
- Sprint 17.47: bind terminalization to the root frame, delete the unreachable Destroy arms, the fresh-admission
  rearm, `TeardownIncomplete`, and `subtreeSettledReleasedOperationKeys`, and add the terminalizer and nested
  Down refusal cases.
- Sprint 17.49: move the reverse-service request decisions into a private module, add a case per refusal,
  test the reverse root link's narrowing, and make its Haddock state what it enforces.
- Sprint 17.50: make the obsolete-equality ban a token-sequence guard that can fail.
- Sprint 17.52: delete the callerless failed-Up retry producer, bind frame, report kind, and catalog, add the
  behavioural authority and failed-session refusal cases, and correct the budget and placement guards.
- Sprint 17.53: admit the `up` teardown recovery edge, fix adapter order, failure attribution, swallowed unwind
  failures, session cancellation, and safety-refusal classification in the failed-Up unwind, and add the
  reached-prefix and `CLISpec` cases.
- Sprint 17.54: add the reverse-attempts, crash, interrupt, and crossing assertions and record a linux-cpu
  `RecursiveLifecycleSpec` run over the final source.
- Sprint 17.55: verify before advancing the generation, bind settled-destroy evidence to its generation, delete
  `withFreshHarnessInvocation`, add the restart backstops, correct the Harness Haddocks, and add the
  run-identity and refusal cases.
- Sprint 17.57: add behavioural cases for the close-control state machine and `closeHarnessRun`'s
  settled-destroy refusal.
- Sprint 17.58: render the lifecycle argv from the validated values and correct the interactivity Haddocks.
- Sprint 17.60: name the shared pre-descent handler, keep a failed reachability step blocking, and add the
  driver-level cases.
- Sprint 17.62: give the rooted catalog fold coordinates their own role newtypes.
- Sprint 17.63: render `project up --dry-run` without Production mode or a lease.
- Sprint 17.64: report the root gate's retained-evidence refusals as `AuthorityEvidenceMismatch` and prove
  each by value.
- Sprint 17.65: give the forward-child projector typed parent and child frame roles.
- Sprint 17.66: make the rooted post-open response family a closed sum.
- Sprint 17.67: `Lifecycle.ResourceRecord` takes `sha256Hex` and `frameWire` from `HostBootstrap.Digest`.
- Sprint 17.68: the test fixture's `projectInit` refuses through `failConfigAssembly`, with a `ContextSpec`
  init-refusal case and an accurate `Fixture` module header.
- Sprint 17.69: `withFinalizedProjectSpec` and its kernel read the scope tag from `KnownScopeKind`, with a
  compile-fail fixture.
- Sprint 17.70: `withChildProjectPlan` refuses a signed child frame other than the running frame, with a
  `ProjectPlanSpec` refusal case.
- Sprint 17.71: record the unknown phase and call digest on the `PreparedGate`, through `withPreparedGate` and
  the `FrameExecutor` mint, and refuse a gate whose journaled transition or call digest differs from the
  descriptor's.
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
