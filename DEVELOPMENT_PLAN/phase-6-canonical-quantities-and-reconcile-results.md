# Phase 6 — Canonical quantities, readiness, and reconcile results

**Status**: Done
**Depends on**: Phase 5 (operator, root, and command authority)
**Substrates**: none (static)
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-12 ; x86_64 Ubuntu 24.04.4 LTS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate
**Gate evidence**: 2026-10-27 ; native Windows 11 x86_64, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --test-options=--hide-successes` ; pass ; covers in-gate
**Gate evidence**: 2026-10-27 ; native-filesystem Ubuntu 24.04.4 x86_64 CPU container, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --test-options=--hide-successes` ; pass ; covers in-gate

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

### Sprint 6.1: Canonical quantities and the provider-neutral cordon foundation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/test/CordonSpec.hs`, `core/hostbootstrap-core/test/BudgetSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/RecordUpdateBudget.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/engineering/applied_cordon.md`

#### Objective

One parser, one exact unit model, and one pure capacity/sizing vocabulary for every provider consumer.

Phase 7 owns the configuration-envelope facade and `fitsBudget`; Phase 12 owns the plan-indexed proof
families.

#### Deliverables

- Opaque `ResourceBudget` retains positive bounded CPU plus memory/storage in canonical units; callers cannot
  construct a zero, negative, or overflowed budget directly, and cannot reach one by record update either:
  `budgetCpu`, `budgetMemoryBytes`, and `budgetStorageBytes` are exported as plain accessor functions, not
  as record field labels, so `b { budgetCpu = 0 }` does not type-check outside `Cordon.Foundation`.
  Its existing Eq behavior and record-style Show rendering, including precedence, are preserved.
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

On 2026-10-27, native Windows 11 x86_64 (GHC 9.12.4, Cabal 3.16.1.0) and native-filesystem
Ubuntu 24.04.4 x86_64 CPU container (same toolchain) passed focused `cabal test hostbootstrap-core-test`
runs from `core/`: `CordonSpec` 67 cases, `BudgetSpec` 29 cases, `RecordUpdateBudget.hs` 1 case,
sealed-surface checks 60 cases, and `DocValidatorSpec` 17 cases. Package `-Werror` remained enabled.

`CordonSpec` covers each above-bound dimension, overflow through resource text, record-shaped Show at
nested precedence, the canonical Docker unsupported decision, and finite rendered WSL2 idle timeouts.
`BudgetSpec` compares all four prepared mechanisms and the complete Docker/BareLinux refusals with the
canonical policy and rejects the removed duplicate enums across library sources. The negative fixture
imports both the budget type and its reader; the public-only GHC invocation rejects its record update
with `Not in scope: record field 'budgetCpu'`.

#### Remaining Work

None. Docker-specific numeric bounds and their admission propagation are owned by Sprints 6.8 and 6.9.

### Sprint 6.2: Opaque readiness and total probes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/ReadinessSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/RawReadiness.hs`,
`core/hostbootstrap-core/test/compile-fail/RawProbe.hs`,
`core/hostbootstrap-core/test/compile-fail/EscapeProbe.hs`,
`core/hostbootstrap-core/test/compile-fail/DockerProbeForCluster.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceReadyPlan.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceProbePlan.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Make readiness an observation, not a flag.

#### Deliverables

- A readiness value (`Ready scope planId id resource dependency`) is opaque, generative, and indexed by
  lifecycle scope, plan, resource instance, and the exact dependency a closed `BackendProbeKey` selected. A
  caller cannot construct one, and cannot re-index one or a `Probe` with `coerce`: `Ready` declares its
  nominal roles, and the public `Probe` synonym inherits the private kernel's six nominal identity roles.
- Every probe is **total**: `ProbeResult` is `ProbeReady`, `NotReady` with its cause, `Unavailable`
  (unsupported), `ProbeConflicted`, or `Failed`, and `pollStep` decides each of the five. Expected backend
  failures are values; backend adapters classify their IO failures. The poll loop preserves cancellation
  and programmer exceptions rather than concealing them as observations.
- A plain `BackendReady a` payload reports generation, phase version, observation version, and the backend
  value through `ProbeReady`; `ProbeVersionError` and `PollInvalidReady` retain typed zero-version refusals.
  The provider observation adapter exhaustively maps that polling refusal to its failure result.
- A readiness value carries the generation, phase version, and observation version the backend reported
  when it answered ready, taken from the probe's `ProbeReady` payload rather than stamped from numbers the
  caller passed at probe construction, so `planDependencyProbe` refuses a stale one rather than re-using it.
- The named poll policies are reviewed constants built without `error`, and the poll loop the binary runs,
  `pollUntilReadyWith`, is the loop the suite drives; no second test-only driver is exported.
- Readiness is not effect authority: holding one authorizes nothing.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`ReadinessSpec`, `ProviderSpec`, each of the five new negative fixtures, inventory checks, and
`DocValidatorSpec`. Windows selected 34 readiness, 27 provider, 5 individual fixture, 54 inventory, and
17 documentation cases. All components compiled with the package's `-Werror` policy.

`ReadinessSpec` drives the actual IO loop with counted probes/recovery, checks all seven policy values
and exact policy refusals, and changes a backend report after probe construction to establish observation
at await time. It independently checks each zero reported version. Its managed-dependency cases traverse
the real snapshot/precondition runner and check matching, stale generation, stale observation version,
and bounded not-ready failure with exact structured results. Its source-definition guard excludes the
test-only polling driver and partial named-policy builder.

Public-only GHC invocations and the registered negative fixtures reject raw probe
construction, a fresh probe identity re-indexed by a caller, a Docker key for a cluster, and both `Ready` and
`Probe` re-indexed across plans. The three independent `RawReadiness` diagnostic pins remain registered.

#### Remaining Work

None. Private backend-only injection is owned by Sprint 6.7, after the shared plan-resource kernel.

### Sprint 6.3: Ownership- and phase-indexed reconcile results [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
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
- A created resource retains the positive generation the backend actually created. Repair and adoption
  retain the exact observed generation; phase transitions validate the resulting managed receipt.
- Receipt rebinding re-types an ownership receipt only after `validateOwnershipReceipt` agrees on key and
  generation. The one rebinding opener is plan-bound, `withPlannedReboundManagedResourceEvidence`, so the
  rebound handle's resource kind comes from the `PlannedResource` rather than from the caller.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
filter `Reconcile` 111 cases (including `ReconcileSpec` and provider/cluster reconciliation),
`ReadinessSpec` 34, `BudgetSpec` 29, sealed-surface checks 60, and `DocValidatorSpec` 17. The package's
`-Werror` remained enabled. Reconciliation took 17.08 seconds on Windows and 12.07 seconds on Linux.

`ReconcileSpec` covers exact absent/unsupported/failure branches and recovery dispositions for acquisition
and adoption; zero observation version; noncommitted prior-proof refusals; matching adopted-commit replay
and wrong-operation refusal; foreign-origin generation/version mismatches; and created-generation zero.
Its phase transition observes generation 3, creates 9, accepts 9, and refuses stale 3. Repair and adoption
retain their exact-generation controls.

Receipt generation cases use genuine rendered, verified durable bundles, with a matching-generation
control before the mismatch. Key cases use genuine provider/share evidence through cross-identity public
rebinding. Empty operations are refused by durable rendering/parsing and verified-journal ingress; parser
mutation first proves the unmodified record verifies. The source-definition/export guard and sealed export
inventory exclude the unplanned opener while retaining planned rebinding. Independent source/test review
found no additional defect.

#### Remaining Work

None.

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

### Sprint 6.5: Host capacity is read through typed host effects and a Win32 binding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/internal/capacity/HostBootstrap/Cluster/Cordon/WindowsCapacity.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/CordonSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/Spec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/MemorySourceAsCpu.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportWindowsCapacity.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/hostbootstrap_core_library.md`

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

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
filter `CordonSpec` 85 cases (including the two declared-family manifest checks), `BudgetSpec` 29,
`MemorySourceAsCpu.hs` 1, `ImportWindowsCapacity.hs` 1, sealed checks 60, inventory checks 54, and
`DocValidatorSpec` 17. The Windows library build also passed without native-compiler pointer warnings;
package `-Werror` remained enabled.

`CordonSpec` checks exact cpuinfo/meminfo fixtures and integer refusals, whole-entry unresolved sysctl/df
refusals, the exact lower import set, and absence of PowerShell interpreter/direct-runner tokens. The df
case uses the test executable as an actual described sysctl process, retaining the production interpreter.
Each supported native host resolved positive CPU, memory, and storage. All three private Win32 readers and
the empty-tool-table Windows configuration ran positively on Windows; Linux asserted their exact declared
unsupported results. `CoverageManifest` declares native capacity 1 and Windows capacity 4, with successful
conditional callbacks. The final phase gate checks all family completion totals together.

The two public-only GHC fixtures reject a memory source in the CPU slot for the actual type mismatch and
reject the private Windows kernel import for its hidden capacity unit. The production change spans three
modules; no scalar IO API was exported for tests.

#### Remaining Work

None.

### Sprint 6.6: A shared private kernel owns planned resource identities [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/internal/plan-resource/HostBootstrap/Plan/Resource.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportPlanResource.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/readiness.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

The plan and backend readiness share one opaque planned-resource identity without a dependency cycle
between the main library and the private readiness injector.

#### Deliverables

- A private plan-resource unit owns the existing positional `PlannedResource` and resource-family tags.
  All identity indices retain nominal roles; the representation and public reader behavior are unchanged.
- `Lifecycle.Plan` consumes that exact representation and remains the owner of validated-graph projection.
  No public module exposes its constructor or a new minting route.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed the library build and focused `cabal test hostbootstrap-core-test`
runs from `core/`: `project-plan` 92 cases, `Reconcile` 111, `ImportPlanResource.hs` 1,
`CoercePlannedResourceRoles.hs` 1, `EscapePlannedResourceIndices.hs` 1, sealed checks 60,
inventory checks 54, and `DocValidatorSpec` 17. Package `-Werror` remained enabled.

The public-only compiler rejects the constructor-import fixture because the shared module belongs to the
hidden plan-resource unit. Existing nominal-role and generative-identity fixtures retain their named
rejections. Plan snapshot/projection and reconciliation cases retain their behavior. Independent review
confirmed one positional three-Text representation, five nominal indices, seven real resource tags, and
unchanged public facade exports, graph minting sites, and readers.

#### Remaining Work

None.

### Sprint 6.7: Only backend modules build a readiness probe [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`,
`core/hostbootstrap-core/internal/readiness/HostBootstrap/Readiness/Kernel.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ReadinessSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/RawProbe.hs`,
`core/hostbootstrap-core/test/compile-fail/EscapeProbe.hs`,
`core/hostbootstrap-core/test/compile-fail/DockerProbeForCluster.hs`,
`core/hostbootstrap-core/test/compile-fail/CallerMintedBackendProbe.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportReadinessKernel.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/readiness.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

The observation function behind a `Probe` belongs to its backend. Its injector and observer sit behind a
Cabal-private boundary that core backend modules and the test component reach and no consumer does.
The kernel shares the lower planned-resource identity and abstracts over configuration, so it depends on
neither the main library nor a duplicate host configuration. Public polling still consumes the existing
host-specialized probe. The dependency-probe wrapper `dependencyProbe` belongs to the cluster lifecycle
phase, which moves it into `lifecycle-dependency-internal` once every caller exists.

#### Deliverables

- The private kernel owns the generic-config `Probe`, backend observation/result payloads, and closed
  backend key relation. Its injector consumes the shared opaque `PlannedResource`; it depends only on the
  lower plan-resource unit, never on the main library.
- The public seven-parameter `Probe` is a `HostConfig`-specialized synonym for that private representation;
  its nominal indices inherit the kernel roles. Public polling and `Ready` integration remain in
  `Readiness`, so no second poll loop or configuration representation is introduced.
- `withBackendProbe` is absent from the export list of every exposed module of `hostbootstrap-core`; it lives
  behind a `visibility: private` sublibrary boundary (the pattern `ownership-internal` uses) that core backend
  modules and `hostbootstrap-core-test` depend on.
- A consumer cannot name the injector: a compile-fail fixture pins the rejection.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed the library build and focused `cabal test hostbootstrap-core-test`
runs from `core/`: `ReadinessSpec` 34 cases, `ProviderSpec` 27, eight individual public-boundary fixtures,
sealed checks 60, inventory checks 54, and `DocValidatorSpec` 17. Package `-Werror` remained enabled.
The complete core/demo host static runs are recorded at phase closure.

All 34 readiness case bodies are unchanged and now consume the actual private factory. Public-only GHC
rejects `CallerMintedBackendProbe.hs` for the unavailable injector and `ImportReadinessKernel.hs` for the
hidden readiness unit. `RawProbe.hs` rejects raw construction through the public synonym; the fresh-probe
identity and plan-role fixtures retain nominal coercion refusals. The Docker-key fixture rejects the
public closed relation independently of injection. `CallerForgedClusterProbe.hs` retains its existing
rejection. Each expectation was captured from the actual compiler after the extraction.

The sealed-export inventory now includes `Readiness` and excludes the injector. One generic probe
representation, shared resource identity, configuration alias, and production polling loop remain.

#### Remaining Work

None.

### Sprint 6.8: Docker limits refuse values outside the runtime representation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/CordonSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/engineering/applied_cordon.md`

#### Objective

A canonical budget can exceed Docker's representation even though its dimensions fit the generic bounds.
The Docker renderer refuses that budget before any ownership observation or container mutation.

#### Deliverables

- The one Docker limit renderer returns `Either String [String]`; its named-container wrapper and public
  facade propagate the same refusal without a second rendering.
- Whole CPU counts fit Docker's signed 64-bit NanoCPUs field, and doubling memory for `--memory-swap`
  fits its signed 64-bit field. Memory meets the Linux daemon's 6 MiB minimum and survives the CLI's
  binary64 byte parsing exactly; doubling an exactly represented value preserves that precision. Checks
  use unbounded arithmetic before conversion or rendering.
- `cordonOwnedCluster` propagates invalid limits as a structured ownership refusal before invoking its
  backend. Representable budgets retain their exact argv and existing ownership checks.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`CordonSpec` selection 95 cases, `ownership` selection 103, `BudgetSpec` 29, sealed checks 60, and
`DocValidatorSpec` 17. Package `-Werror` remained enabled. The ownership selection took 32.29 seconds
on Windows and 22.31 seconds on Linux.

Ten literal Docker renderer cases cover ordinary argv, CPU 9223372036 and its overflow, memory minimum
6291456 and the byte below it, maximum CLI-exact memory 4611686018427387392, the inexact raw half-Int64
bound and signed swap overflow, and 2^53+1 refusal versus 2^53+2 acceptance. Each checks the lower/public
limit renderers and all named wrappers against the same independently specified argv or refusal.

Four owned-cluster cases create genuine owned records, then use a concrete empty-tool configuration.
A valid-budget control reaches the first ownership query's exact unresolved-tool refusal; each invalid
budget instead produces the canonical `ClusterOwnershipBudget` before that query. Complete protected
record keys/versions/bytes, node state, and mutation history remain unchanged. Existing valid argv and
replacement/unclaimed-identity checks also pass. Production scope is three modules.

#### Remaining Work

None.

### Sprint 6.9: Docker budget admission uses the exact runtime renderer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/test/BudgetSpec.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Provider admission refuses every Docker budget that the canonical runtime renderer cannot express.

#### Deliverables

- Replace the unconditional Docker-node admission success with the canonical renderer's exactness check.
- Preserve byte-granular admission within Docker's range; its unsupported storage wall remains a separate
  typed policy result.

#### Validation

On 2026-10-27, the admission-only `BudgetSpec` control run against the unconditional Docker branch
failed exactly five of 39 cases (4.10 seconds): CPU overflow, sub-minimum memory, raw-half-Int64 precision,
swap overflow, and 2^53+1 precision were incorrectly admitted. Its helper stops in the real admission
continuation and returns exact effective values; no later workload or renderer can produce those results.
The five positive controls passed. Docker admission then delegated to the canonical renderer.

The complete host static gate passed natively on Windows 11 x86_64 with GHC 9.12.4/Cabal 3.16.1.0:

- `cabal test all --test-options=--hide-successes` from `core/`: 2972 main cases in 537.01 seconds, all
  declared suites passed;
- the same command from `demo/`: 164 demo cases in 5.84 seconds and 2972 core cases in 503.25 seconds,
  all declared suites passed;
- `poetry run python -m hostbootstrap.check_code`: Ruff, Black, and mypy passed;
- `poetry run python -m hostbootstrap.test_all`: 376 cases in 9.06 seconds, with 100% coverage of
  1585 statements and 460 branches.

The complete declared core gate also passed on the native-filesystem Ubuntu 24.04.4 x86_64 CPU container
with the same Haskell toolchain: 2979 main cases in 420.87 seconds and all declared suites passed.
The full runs include all 39 budget cases and all public compile-fail boundaries, with package `-Werror`.
Capacity completion checks observed native/Windows row counts (1,0)/(4,0) on Windows and (1,0)/(0,4) on
Linux; no unsupported branch disappeared. Demo consumer validation includes the private readiness boundary.

#### Remaining Work

None.


## Remaining Work

None.

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
- [system-components.md](system-components.md) records the three private kernel modules under this phase.
- `development_plan_standards.md` § O and § CC name this phase as the owner of the provider-neutral quantity,
  capacity, storage-policy, and readiness contracts.
