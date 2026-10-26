# Phase 6 — Canonical quantities, readiness, and reconcile results

**Status**: Active
**Depends on**: Phase 5 (operator, root, and command authority)
**Substrates**: none (static)
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-12 ; x86_64 Ubuntu 24.04.4 LTS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate

> **Purpose**: Supply one canonical parser for every quantity, the provider-neutral capacity and cordon
> foundation, opaque generative readiness bound to a hidden probe, and the ownership- and phase-indexed
> result type every reconciliation returns.

## Phase Objective

Two kinds of value are pervasive above this phase: a quantity someone wrote down, and an observation
someone made. Both are places where a second representation causes silent disagreement — two parsers that
round differently, or a readiness flag a caller can set. This phase gives each exactly one canonical form,
gives capacity preflight and provider sizing one pure vocabulary, and gives reconciliation a result type
that distinguishes what we own from what we merely found.

## Sprints

### Sprint 6.1: Canonical quantities and the provider-neutral cordon foundation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/CordonSpec.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/resource_budgeting.md`

#### Objective

One parser, one exact unit model, and one pure capacity/sizing vocabulary for every provider consumer.

#### Deliverables

- Opaque `ResourceBudget` retains positive bounded CPU plus memory/storage in canonical units; callers cannot
  construct a zero, negative, or overflowed budget directly, and cannot reach one by record update either:
  `budgetCpu`, `budgetMemoryBytes`, and `budgetStorageBytes` are exported as plain accessor functions, not
  as record field labels, so `b { budgetCpu = 0 }` does not type-check outside `Cordon.Foundation`.
- `parseQuantity` is total: malformed, inexact, or unsupported input returns a descriptive refusal naming the
  input rather than a default or rounded value.
- `HostCapacity`, `CapacityReadPlan`, `verifyBudget`, and `verifyHostBudget` form the provider-neutral
  preflight foundation; capacity observation is separate from mutation authority.
- Lima, Colima, Incus, WSL2, and kind-node sizing renderers consume those same exact quantities, and a
  provider that cannot represent a hard ceiling exactly refuses it rather than rounding upward.
- `StorageCordonResult` states the supported wall mechanism or the typed unsupported decision (bare Linux,
  and a kind node container that `docker update` cannot cap); the pure result grants no authority to apply a
  provider wall. It is the one storage-wall vocabulary: the prepared storage-wall call in
  `HostBootstrap.Cluster.Budget` takes its mechanism and its unsupported reason from `storageCordonPolicy`
  rather than from a second enumeration.
- The module's Haddock states what the code does: the host reserve example is one the reserve actually
  refuses, bare Linux has no storage wall (`StorageCordonUnsupported`), and the WSL2 idle-timeout margin is
  stated against the recorded Windows gate duration (2 h 57 min), not a 25–50 minute run.

#### Validation

`CordonSpec` covers parsing/refusal, capacity and reserve overflow, provider exactness, the storage-wall
matrix, and fail-closed argument construction. A source guard permits the exposed
`HostBootstrap.Cluster.Cordon.Foundation` to import only `HostBootstrap.Effect.Run`,
`HostBootstrap.HostConfig`, `HostBootstrap.HostTool`, and `HostBootstrap.Substrate` from `HostBootstrap.*`.

Dated evidence: on 2026-08-09 (aarch64-osx, GHC 9.12.4), focused `CordonSpec` passed 54/54 and
`BudgetSpec` passed 19/19 under `-Werror`; the exact phase gate
`cabal test all --ghc-options=-Werror` from `core/` then passed 1463/1463.

The sprint closes when these cases also exist and pass under `cabal test all` from `core/`:

- a `CompileFailSpec` fixture `RecordUpdateBudget.hs` doing `relabel b = b { budgetCpu = 0 }` is rejected;
- `CordonSpec` cases for `mkResourceBudget` above each bound — CPU `fromIntegral (maxBound :: Int) + 1`,
  memory and storage `toInteger (maxBound :: Int64) + 1` — each answering
  `Left (DimensionAboveBound <dimension>)`, plus one through `budgetFromResources` with memory
  `"9000000Ti"` answering `DimensionAboveBound BudgetMemory`;
- a `BudgetSpec` case that every prepared storage-wall mechanism and every `Unsupported` storage refusal
  equals what `storageCordonPolicy` answers for that provider target;
- the `CordonSpec` idle-timeout case asserts the two rendered timeout lines and the absence of a `=-`
  value, with no line that restates `managedWslIdleTimeoutMillis`'s definition; the sibling WSL2 sizing case
  pins the exact `21600000` value.

#### Remaining Work

- Stop exporting the `ResourceBudget` field labels from `Cordon/Foundation.hs` (make the constructor
  positional and define `budgetCpu`, `budgetMemoryBytes`, `budgetStorageBytes` as functions) and keep the
  `Cordon` facade's re-exports; add `test/compile-fail/RecordUpdateBudget.hs` and register it in
  `CompileFailSpec` with the diagnostic GHC gives for a record update with no field in scope.
- Add the three above-bound `mkResourceBudget` cases and the `budgetFromResources "9000000Ti"` case to
  `CordonSpec`, each asserting the exact `DimensionAboveBound` dimension.
- Delete `StorageWallMechanism` and `StorageWallUnsupported` from `Cluster/Budget.hs`: add the kind node
  container to `StorageCordonTarget` with its own `StorageCordonUnsupportedReason`, have the prepared
  storage-wall call carry `StorageCordonMechanism`, and derive each provider's mechanism or `Unsupported`
  refusal from `storageCordonPolicy`; add the `BudgetSpec` equality case above.
- Correct three Haddocks in `Cordon/Foundation.hs`: `hostMemoryReserveBytes` (a 16 GiB host and a 10 GiB VM
  passes 10 + 4 ≤ 16; use an example the 4 GiB reserve refuses, such as a 13 GiB budget),
  `kindNodeCordonArgsForBudget` (drop "a quota'd hostPath on bare Linux"; bare Linux is
  `StorageCordonUnsupported`, and the walls are Colima, Lima, Incus, and the WSL2 VHDX), and
  `managedWslIdleTimeoutHours` / `wsl2SizingArgsForBudget` (cite the recorded 2 h 57 min Windows gate and
  the roughly 2x margin six hours gives).
- Rename the `CordonSpec` case "windows storage shortage fails before WSL2 VHDX pressure" to name what it
  checks, a pure `preflightBudget` storage refusal; it involves no Windows substrate and no WSL2 ordering.
- In the `CordonSpec` case "both managed idle timeouts are finite, so the host always recovers the balloon",
  drop the `managedWslIdleTimeoutMillis > 0` line and the line that recomputes it as
  `managedWslIdleTimeoutHours * 60 * 60 * 1000` (both restate the production definition and cannot fail
  where the rendered `21600000` assertion would not), keep the two-timeout count and the `=-` check, and
  rename the case to "both managed idle timeouts render a finite value", since recovery of the balloon is a
  runtime WSL2 property this case cannot observe.

Phase 7 owns the configuration-envelope facade and `fitsBudget`; Phase 12 owns the plan-indexed proof
families.

### Sprint 6.2: Opaque readiness and total probes [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`,
`core/hostbootstrap-core/test/ReadinessSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/RawReadiness.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Make readiness an observation, not a flag.

#### Deliverables

- A readiness value (`Ready scope planId id resource dependency`) is opaque, generative, and indexed by
  lifecycle scope, plan, resource instance, and the exact dependency a closed `BackendProbeKey` selected. A
  caller cannot construct one, and cannot re-index one or a `Probe` with `coerce`: both carry
  `type role ... nominal` annotations on every index.
- Every probe is **total**: `ProbeResult` is `ProbeReady`, `NotReady` with its cause, `Unavailable`
  (unsupported), `ProbeConflicted`, or `Failed` — never an exception and never a silent false — and
  `pollStep` decides each of the five.
- A readiness value carries the generation, phase version, and observation version the backend reported
  when it answered ready, taken from the probe's `ProbeReady` payload rather than stamped from numbers the
  caller passed at probe construction, so `planDependencyProbe` refuses a stale one rather than re-using it.
- The named poll policies are reviewed constants built without `error`, and the poll loop the binary runs,
  `pollUntilReadyWith`, is the loop the suite drives; no second test-only driver is exported.
- Readiness is not effect authority: holding one authorizes nothing.

#### Validation

`ReadinessSpec` covers each `pollStep` outcome, the named policy budgets, and indexed readiness retaining
the versions the probe reported.

The sprint closes when these cases also exist and pass under `cabal test all` from `core/`:

- `ReadinessSpec` registers a `planDependencyProbe` for a `ResourceHandle ... Managed` and runs it through
  `withDependencySnapshotEntry` and `withOperationPreconditions` (the only runner of a `DependencyProbe`),
  asserting: a reported generation different from `resourceHandleGeneration` refuses with
  `Conflict` whose expected side is `"generation=<n>"`; a reported observation version different from
  `resourceHandleObservationVersion` refuses with `Conflict` whose expected side is
  `"observation version=<n>"`; a probe that stays `NotReady` past its policy refuses with
  `Failure (FailureDetail ... ReprobeBeforeRetry)`; and a matching probe seals the preconditions.
- `ReadinessSpec` asserts each `withBackendProbe` zero guard separately: generation 0 →
  `ZeroProbeGeneration`, phase version 0 → `ZeroProbePhaseVersion`, observation version 0 →
  `ZeroProbeObservationVersion` (or, once the versions come from the payload, the equivalent refusal of a
  zero reported version).
- `ReadinessSpec` drives `pollUntilReadyWith` with a scripted probe popping results from an `IORef`, a
  `recover` action that counts its calls, and a zero-delay policy: it converges after two `NotReady`
  results with two recover calls, exhausts a three-attempt budget with exactly three probe calls and a
  `PollTimeout`, and stops at `Failed` without further probe calls.
- `ReadinessSpec` asserts each named policy equals the `mkPollPolicy` result for its attempts and delay.
- `ReadinessSpec` pins every named policy's delay as an absolute `microsValue`, not through `seconds`:
  `rolloutPoll`, `pushPoll`, and `reachPoll` 5000000, `vmBootPoll` and `dockerPoll` 2000000, `networkPoll`
  and `nodePoll` 3000000; and `microsValue <$> seconds 5` is `Right 5000000`.
- `ReadinessSpec` asserts each `PollPolicyError` constructor exactly rather than `isLeft`:
  `seconds (toInteger (maxBound :: Int))` gives `Left (DelayOverflow (toInteger (maxBound :: Int)))`;
  `seconds 0 >>= mkPollPolicy 1000001` gives `Left (AttemptsTooLarge 1000001)`;
  `seconds 9000000000000 >>= mkPollPolicy 3` gives `Left TotalDurationOverflow`; and
  `seconds 86401 >>= mkPollPolicy 2` gives `Left (TotalDurationTooLarge 86401000000)`.
- `CompileFailSpec` rejects: a `Ready` built with its constructor (fixture separate from `RawReadiness.hs`,
  asserting the diagnostic names `'Ready'`); a `Probe` built with its constructor (asserting the diagnostic
  names `'Probe'`); a `Probe` returned out of `withBackendProbe`'s continuation
  (skolem escape); `DockerDaemonProbe` applied to a `ClusterResource` planned resource; and `coerce` of a
  `Ready` and of a `Probe` across `planId`.

#### Remaining Work

- Make the probe a `withBackendProbe` wraps report the observed generation, phase version, and observation
  version as its `ProbeReady` payload, build `Ready` in `awaitPlanReadyWith` from that payload, refuse a zero
  reported version there, and drop the construction-time version arguments together with the unreachable
  `readyPhaseVersion ready == 0` branch of `readyPhaseVersionFor`; correct the `planDependencyProbe` Haddock
  and `documents/architecture/readiness.md` to match.
- Add `{-# LANGUAGE RoleAnnotations #-}` and `type role Probe nominal nominal nominal nominal nominal nominal
  representational` and `type role Ready nominal nominal nominal nominal nominal` to `Readiness.hs`, with the
  two `coerce` compile-fail fixtures.
- Add the `planDependencyProbe` generation, observation-version, poll-failure, and matching-probe cases and
  the three separate zero-version cases to `ReadinessSpec`.
- Delete `drivePure` from `Readiness.hs` and its export, and replace the three "pure driver" cases with the
  scripted `pollUntilReadyWith` cases above.
- Build the seven named policies (`rolloutPoll` … `nodePoll`) with the private `PollPolicy` constructor
  instead of `namedPolicy`'s `error` branch, and add the policy-equality case.
- Split the `Ready 0 0 0` line out of `test/compile-fail/RawReadiness.hs` into its own fixture (today
  `CompileFailSpec` pins only the `PollPolicy` diagnostic for that file, so exporting `Ready(..)` would still
  pass), and add a raw-`Probe` constructor fixture and the `Probe`-escape and wrong-key fixtures, each
  registered in `CompileFailSpec` with its own diagnostic.
- Replace `fiveSeconds = seconds 5` as the expected side of the policy cases with absolute `microsValue`
  assertions for all seven named policies, and replace the `isLeft` checks of the rejection case with the
  four exact `DelayOverflow`, `AttemptsTooLarge`, `TotalDurationOverflow`, and `TotalDurationTooLarge` cases
  listed above.

### Sprint 6.3: Ownership- and phase-indexed reconcile results [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Distinguish what we own from what we found, in the type.

#### Deliverables

- `ResourceHandle scope planId id resource ownership phase` indexes a handle by ownership (`Managed`,
  `Unmanaged`, `Unclassified`) and lifecycle phase.
- `ReconcileResult` has exactly two constructors: `ManagedResult` carries a managed handle, an
  `OwnershipReceipt`, and a `ChangeView`; `ForeignResult` carries only an `Unmanaged` handle and a
  `ForeignObservation`. A foreign handle **cannot type-check at teardown**, so a stranger's resource is
  structurally un-deletable rather than protected by a runtime check.
- `ManagedResult Unchanged` retains its handle and receipt, so an idempotent reconcile is still ownership.
  `withPriorCommitProof` admits exactly the matching ordinary `Committed` acquisition or the matching
  `AdoptionCommitted` transfer, so a resource adopted in an earlier run settles as `Unchanged`.
- Failure is structured: `Conflict`, `SafetyRefusal`, `Unsupported`, and `Failure` are distinct, each with
  its own detail record. `Failure` carries a typed `RecoveryDisposition` (`ReprobeBeforeRetry`,
  `RetrySameOperationKeyAfterFencing`, `OperatorResolutionRequired`, `DoNotRetry`); `Conflict` carries its
  expected and observed values and a remedy; `SafetyRefusal` and `Unsupported` are terminal and carry no
  retry disposition.
- Explicit adoption requires matching opaque authority and reports `Changed Adopted`; it is never implicit.
- Receipt rebinding re-types an ownership receipt only after `validateOwnershipReceipt` agrees on key and
  generation. The one rebinding opener is plan-bound, `withPlannedReboundManagedResourceEvidence`, so the
  rebound handle's resource kind comes from the `PlannedResource` rather than from the caller.

#### Validation

`ReconcileSpec` covers the `Created`, `Foreign`, `Adopted`, `Unchanged`, `Conflict`, `SafetyRefusal`, and
`Failure` branches and the `DoNotRetry` disposition. The type-level rejection of a foreign handle at
teardown is covered by the `CompileFailSpec` fixtures `ForeignProviderStop.hs`, `ForeignClusterCleanup.hs`,
and `ForeignGuestAliasRelease.hs`.

The sprint closes when these cases also exist and pass under `cabal test all` from `core/`:

- `ReconcileSpec` drives `completeReconcile` and `completeAdoption` with `BackendAbsent`,
  `BackendUnsupported`, and `BackendFailed` observations and asserts the exact answers:
  `Failure (FailureDetail "reconcile resource" "resource remained absent" ReprobeBeforeRetry)`,
  `Unsupported (UnsupportedDetail "reconcile resource" <reason>)`, the `BackendFailed` disposition passed
  through unchanged (one case each for `RetrySameOperationKeyAfterFencing` and
  `OperatorResolutionRequired`), and `Failure (FailureDetail "adopt resource" "resource became absent"
  OperatorResolutionRequired)`.
- `ReconcileSpec` asserts `withObservedPlannedResource` with generation 1 and observation version 0 answers
  `Failure (FailureDetail "observe resource" "observation version must be positive" DoNotRetry)`.
- `ReconcileSpec` asserts `withPriorCommitProof` on an `IntentRecorded` and on an `ObservedManaged` record
  answers `Failure (FailureDetail "rebind ownership" "journal record is not committed"
  OperatorResolutionRequired)`, and on a matching `AdoptionCommitted` record yields a proof that
  `completePreparedUnchanged` accepts as `Unchanged`.
- `ReconcileSpec` asserts `withAdoptionAuthority` refuses a `VerifiedForeignOrigin` whose key or generation
  differs from the planned resource with its specific `Conflict`.
- `ReconcileSpec` asserts `validateOwnershipReceipt` (and `withPlannedReboundManagedResourceEvidence` over it)
  answers `Conflict` with expected side `"generation=<n>"` for a receipt at generation + 1, `Conflict` with
  expected side `"resource key=<key>"` for a receipt of another key, and
  `Failure (FailureDetail "validate ownership receipt" "operation key is empty" DoNotRetry)` for an empty
  operation key.
- A source guard in `ReconcileSpec` asserts `HostBootstrap.Reconcile` exports no
  `withReboundManagedResourceEvidence`.
- The `ReconcileSpec` case "managed phase transition retains receipt generation" uses distinct generations:
  the resource is observed at generation 3, the backend answers `BackendCreated 9`, and
  `verifyPhaseTransition managed receipt transition 9` yields a ready handle whose
  `resourceHandleGeneration` is 9; a sibling case passes observed generation 3 to `verifyPhaseTransition`
  and answers `Conflict` with expected side `"9"` and observed side `"3"`.

#### Remaining Work

- Add the `BackendAbsent`, `BackendUnsupported`, and `BackendFailed` cases for `completeReconcile` and
  `completeAdoption`, the generation-1/version-0 observation case, and the `withAdoptionAuthority`
  mismatch case to `ReconcileSpec`.
- Make `withPriorCommitProof` in `Reconcile.hs` admit a verified `AdoptionCommitted` record whose resource,
  generation, and operation match (its own exact-operation check), keep refusing every other phase, and add
  the three `withPriorCommitProof` cases.
- Delete `withReboundManagedResourceEvidence` from `Reconcile.hs` and its export (it has no caller and lets
  the continuation pick any `resource` and `phase` index), and add the export source guard.
- Add the three `validateOwnershipReceipt` refusal cases, each driven through
  `withPlannedReboundManagedResourceEvidence` as well as directly.
- Rewrite `phaseSummary` in `ReconcileSpec` so the observed generation (3), the created generation (9), and
  the `verifyPhaseTransition` argument differ, assert the ready handle carries 9, and add the stale-argument
  `Conflict` case.

### Sprint 6.4: The budget path answers with a closed result [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/resource_budgeting.md`

#### Objective

This phase's contribution is that a reconcile answer is a closed sum rather than a sentence, and the
canonical-quantity constructors answer that way too: a caller that needs to know *which* dimension
failed reads it off the value rather than by matching on a string.

#### Deliverables

- `parseQuantity` and `mkResourceBudget` answer with `QuantityError`, a closed sum naming either the grammar that failed or the `BudgetDimension` and the bound it broke.
- `renderQuantityError` is the one place a refusal becomes operator-facing text, and it produces the sentences those refusals carried before the sum existed, so diagnostics do not regress.
- The plan-indexed cluster admission carries that value as `InvalidQuantity` rather than interpolating it into a string.
- The descriptive helpers that answer in text render at their own boundary, so the closed value reaches every caller that can use it and no caller that cannot.
- A case asserts the dimension of a refusal without matching on its rendered text, and a second pins that every constructor still renders the sentence it used to.

#### Objective boundary

The remaining free-text error channels elsewhere in the library — capacity reads, the fit check, and the
provider sizing renderers — are not in this sprint's scope. They are a different subject: a fit check
refuses about a *host*, not about a quantity.

#### Validation

The host static gate. `CordonSpec` covers the `QuantityError` refusals, that they can be identified without
string matching, and that their rendering is unchanged. Dated evidence: on 2026-09-12, x86_64 Ubuntu
24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal test all` from `core/` passed 2,518 tests.

#### Remaining Work

None. The exact `InvalidQuantity` cases at the plan-indexed admission belong to `BudgetSpec`, which the
step-algebra phase (phase 12) owns.

### Sprint 6.5: Host capacity is read through typed host effects and a Win32 binding [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Effect/Interpreter.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/CordonSpec.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/resource_budgeting.md`

#### Objective

`resolveHostCapacity` reads CPU, memory, and storage on every substrate without interpreter text: Windows
capacity comes from a Win32 binding, `df` and `sysctl` are described `HostCommand` values run by the one
interpreter, the procfs parsing is pure, and each dimension's source is its own type so a reader is a total
match.

#### Deliverables

- Windows logical processors, total physical memory, and system-drive free bytes come from Win32
  (`GetSystemInfo` or `GetLogicalProcessorInformationEx`, `GlobalMemoryStatusEx`, `GetDiskFreeSpaceExW`) in
  one capacity module built on every host, with `Win32` the only conditional dependency; off Windows it
  answers a typed refusal. `Cordon/Foundation.hs` carries no PowerShell expression and no
  `-NoProfile`/`-Command` token.
- `df -P -k <path>` and `sysctl -n <key>` are built with `hostCommand` and run through
  `interpretHostCommand`; `Cordon/Foundation.hs` does not call `runCaptured` directly.
- `CapacityReadPlan` is built from per-dimension source types (`CpuSource`, `MemorySource`,
  `StorageSource`), so a memory source in the CPU slot does not type-check and each reader is a total match
  with no wildcard branch.
- `/proc/cpuinfo` processor counting and `/proc/meminfo` `MemAvailable` parsing (kB to bytes) are pure
  functions over the file text; the IO wrapper only reads the file.

#### Validation

The sprint closes when these cases exist and pass under `cabal test all` from `core/`:

- `CordonSpec`: the pure cpuinfo counter over a two-processor fixture answers 2 and over a zero-processor
  fixture answers the refusal naming no processors; the meminfo parser over a fixture with
  `MemAvailable: 1024 kB` answers 1048576 bytes and over one without the key answers the refusal naming
  `MemAvailable`; `parsePositiveInteger` answers 16 for `"16\r\n"` after stripping, a non-positive refusal
  for `"0"`, and a non-integer refusal for `"abc"`; and the unresolved-tool refusal for `df` and for
  `sysctl`.
- The live capacity case runs on every gate host: it resolves the host's own substrate and tools and asserts
  positive cpu, memory, and storage from `resolveHostCapacity`; a host that cannot read capacity asserts the
  declared refusal instead of `pure ()`, and the family has a `CoverageManifest` row.
- A source guard asserts `Cordon/Foundation.hs` contains no `-Command` token, and the Foundation import guard
  admits exactly the modules this sprint adds to its import list.

#### Remaining Work

- Replace `readPowerShellPositiveInteger` and its three PowerShell expressions in `Cordon/Foundation.hs`
  with Win32 reads in a new Windows capacity module under `src/HostBootstrap/Cluster/Cordon/` (registered in
  `hostbootstrap-core.cabal`, `Win32` under `if os(windows)`), and add the no-`-Command` source guard and a
  `CordonSpec` `mingw32` case: with a `HostConfig` whose tool table resolves no `PowerShell`, the three Windows
  reads each return a positive `Right`.
- Route `readDfFreeBytes` and `readSysctlPositiveInteger` through `hostCommand` and `interpretHostCommand`,
  update the `CordonSpec` "foundation imports only modules below the canonical-quantities boundary" guard to
  the new import list, and add the unresolved-tool cases.
- Split `CapacityReadSource` into `CpuSource`, `MemorySource`, and `StorageSource`, make `CapacityReadPlan`
  use them, and drop the three wildcard reader branches of `readCores`, `readAvailableMemory`, and
  `readAvailableStorage`.
- Factor the procfs counting and `MemAvailable` parsing into pure functions with the fixture cases and the
  `parsePositiveInteger` cases.
- Replace the `else pure ()` branch of the live Apple-only capacity case "live apple-silicon sysctl read
  resolves positive capacity" with a case that runs on every host (or asserts the declared refusal) and
  register the family in `CoverageManifest`.

### Sprint 6.6: Only backend modules build a readiness probe [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ReadinessSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

The observation function behind a `Probe` is a backend's, never a consumer's. `withBackendProbe` (in
`HostBootstrap.Readiness`) is exported from an exposed module and accepts any caller-supplied action, so a
consumer holding a `PlannedResource` can mint a `Ready` from a constant `ProbeReady`. This sprint makes the rule
a visibility boundary: the injector sits behind a Cabal-private boundary that core's backend modules and the
test component reach and no consumer does. The dependency-probe wrapper `dependencyProbe` is the cluster
lifecycle phase's (Phase 16), which moves it into `lifecycle-dependency-internal` once every caller exists.

#### Deliverables

- `withBackendProbe` is absent from the export list of every exposed module of `hostbootstrap-core`; it lives
  behind a `visibility: private` sublibrary boundary (the pattern `ownership-internal` uses) that core backend
  modules and `hostbootstrap-core-test` depend on.
- A consumer cannot name the injector: a compile-fail fixture pins the rejection.

#### Validation

The sprint closes when these cases exist and pass under `cabal test all` from `core/` and from `demo/`:

- `CompileFailSpec` registers `CallerMintedBackendProbe.hs` (imports `HostBootstrap.Readiness` and calls
  `withBackendProbe` with `const (pure (ProbeReady ()))`), rejected with `Variable not in scope:
  withBackendProbe`;
- the existing `CallerForgedClusterProbe.hs` rejection still passes;
- `ReadinessSpec` builds against the private boundary unchanged in behaviour.

#### Remaining Work

- Move `withBackendProbe` out of the exposed `HostBootstrap.Readiness` export list into a `visibility: private`
  sublibrary registered in `hostbootstrap-core.cabal`, re-point `ReadinessSpec`'s import, and add the
  compile-fail fixture with its diagnostic.
- Correct the `documents/architecture/readiness.md` gap list and `BackendProbeKey` bullet so they state that
  `withBackendProbe` is private.

## Remaining Work

- Sprint 6.1: close `ResourceBudget` against record update, add the above-bound cases, make
  `StorageCordonResult` the one storage-wall vocabulary, correct three Foundation Haddocks, and rename two
  `CordonSpec` cases.
- Sprint 6.2: build `Ready` from the observed `ProbeReady` payload versions, add role annotations, add the
  staleness, zero-version, and exact poll-policy cases, delete `drivePure`, build the named policies without
  `error`, and add the `Ready`, raw-`Probe`, escape, wrong-key, and `coerce` compile-fail fixtures.
- Sprint 6.3: add the backend-branch, disposition, and distinct-generation phase-transition cases, admit an
  `AdoptionCommitted` commit proof, delete `withReboundManagedResourceEvidence`, and add the receipt refusal
  cases.
- Sprint 6.5: read host capacity through Win32 and `interpretHostCommand` with per-dimension source types
  and pure procfs parsers, and run the live capacity case on every gate host.
- Sprint 6.6: move `withBackendProbe` behind a Cabal-private boundary and pin its rejection with a compile-fail
  fixture.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/readiness.md` — opaque generative readiness and total probes.
- `documents/architecture/lifecycle_state_model.md` — the ownership/phase index and the result algebra.

**Engineering docs to create/update:**
- `documents/engineering/resource_budgeting.md` — opaque canonical-unit `ResourceBudget`, capacity
  verification, and exact sizing renderers.
- `documents/engineering/applied_cordon.md` — how the lower sizing and storage policies are applied, with
  plan-indexed proof consumption attributed to Phase 12.

**Cross-references to add:**
- `development_plan_standards.md` § O and § CC name this phase as the owner of the provider-neutral quantity,
  capacity, storage-policy, and readiness contracts.
