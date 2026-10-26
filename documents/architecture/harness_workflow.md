# Harness Workflow

**Status**: Authoritative source
**Supersedes**: the self-invoking Production-lifecycle description of `test run`
**Referenced by**: [documents index](../README.md), [composition methodology](composition_methodology.md), [testing](../engineering/testing.md), [durable state](durable_state.md), [lifecycle state model](lifecycle_state_model.md)

> **Purpose**: Describe the implemented exact-plan test runner, including its command gate,
> assertion-only suite, owned generated artifacts, fresh same-run restart, and terminal close.

## TL;DR

The lifecycle root gives every Harness acquisition a sealed generative run identity and matching
mode, root, and unbound-lease evidence; its protected profile opener can enter exactly once per broker
generation, and `withFreshHarnessInvocation` rearms it only after a settled intermediate destroy. Each selected
variant owns its generated config, admits one exact Harness-scoped project plan, and drives that plan's
hidden fixed root-Up entry plus exact reverse action. The entry alone reaches the lower Chain. `TestSuite`
is assertion-only, and the lifecycle constructor is confined to a private Cabal component. A case may
declaratively span a settled destroy and fresh invocation generation without receiving lifecycle authority.

The [test-harness-and-run-ownership
phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md) owns this Harness command consumer
and assertion engine. It consumes the exact plan/Chain foundation supplied by the
[step-algebra-and-project-plan
phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md), whose own command adoption is the
Production path.

## Current Status

The fixed surface is:

```text
<project> test init
<project> test run <case-id>
<project> test run all
```

`test init` writes the executable-sibling `<project>.test.dhall` without requiring a production
`<project>.dhall`. An existing `<project>.test.dhall` is refused by name and left byte-identical unless
`test init --replace` is given; `--replace` authorizes replacing the test config only. `test run` reads that file, validates the compiled cases and the project-owned typed
variant projection into one opaque `TestMatrix`, and installs each selected variant's
executable-sibling `<project>.dhall` through `HostBootstrap.Harness.GeneratedConfig` — which holds all
four [ownership_invariant](ownership_invariant.md) clauses over that file — then drives the project's
exact Harness plan through common forward interpretation, assertions, and the matching reverse projection.
It unlinks the config only when its bound kernel identity **and** recorded payload still match. A found
config is refused before any mutation, an edited or replaced one is a structured conflict that is left
intact, and an abandoned run's config is reclaimed by the next run's sweep from the same durable record.

At the lifecycle boundary, `withHarnessRoot` mints an opaque nominal `RunId runId` only inside its
rank-2 continuation and returns the matching `HarnessMode runId` lease, Harness root authority, and
`UnboundRunLease (Harness projectId runId) brokerGeneration`. Only the diagnostic `runIdText` projection
is public. `harnessActiveMode` narrows the exact mode lease, and `withHarnessLifecycleProfile` requires
that active mode together with the matching root scope, `HarnessAuthority`, run witness, and unbound
lease. It compare-and-swaps that run's durable profile slot to consumed before entering the continuation;
within one broker generation, sequential replay or a concurrent same-slot contender receives no second
profile. The same-run restart (see [Teardown](#teardown)) rearms the slot, and does so only under a
strictly fresh broker generation after a settled intermediate destroy. Production uses its
structurally separate mode, scope, and profile opener, while both modes contend on one project record.

After a plan snapshot is persisted and read back, its Harness scope and both digest indices must match
the lease at the type boundary. Fresh-only `bindRunLease` rejects an already-bound record with
`LeaseConflict`. Existing Production recovery instead enters through
`ProjectPlan.Snapshot.withBoundPlanSnapshot`, which starts from the protected store and installed project,
mutates no protected record, and yields fully indexed recovery evidence only for a verified Open
invocation. Harness abandoned-run recovery keeps its weaker durable observation package-private behind
the sweep and scope-specific classifier. Neither route can claim a fresh binding. Harness command
dispatch consumes this admission foundation directly; it does not cross a root-level lifecycle subprocess
boundary.

Five gaps separate the tree from this page's target contract:

- **No root gate.** The command description calls `test` a root-only surface, and the target contract
  refuses a non-root context before any lifecycle read or mutation, but the parser applies no
  binary-context root gate to either subcommand. `test run` deliberately does not load a pre-existing
  project config, because it generates one, so root authority rests on the harness safety checks and the
  invocation location rather than on an unforgeable context capability. No test pins an off-root
  refusal. The [`test` and `context` commands
  phase](../../DEVELOPMENT_PLAN/phase-20-test-and-context-commands.md) owns this gap.
- **Coercible Harness authority.** `HarnessAuthority projectId runId` and
  `HarnessConfigAuthority projectId runId` in
  [Config.Authority.Internal](../../core/hostbootstrap-core/src/HostBootstrap/Config/Authority/Internal.hs)
  are newtypes over `Text` with phantom `projectId` and `runId` indices and no `type role` annotation, so
  `coerce` can re-index a witness to another project or run without the constructor. Constructor
  forgery and direct cross-run substitution are refused; role-based coercion is not. The [Dhall
  configuration and project model
  phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md), which owns that
  module, owns this gap.
- **Harness run closure can leave the mode held.** In `runOwned`
  ([Harness.Ownership](../../core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs)), a data-root
  acquisition (`takeDataRoot`) that refuses or throws skips `releaseRun`, so the run's fresh unbound lease
  and Harness mode stay held, and every Production opener is refused with `ModeHeldByAnother`, until the
  next `test run` sweeps them. When the body throws, the finalizer's cleanup verdict is discarded with the
  exception. `acquireOwnedRunConfig` does not recheck that an `OwnedHarnessRoot`'s lease is still open, so
  a root returned out of its bracket can install a generated config that no release or sweep reaches.
  `closeHarnessRun` closes the lease and releases the mode in two protected writes, and
  `recoverAbandonedHarnessRuns` enumerates only incomplete leases, so a crash between the two writes
  strands the Harness mode. The target closes the lease and mode on every refused or thrown path, reports
  the finalizer verdict with the exception, refuses a closed run's root, and has the sweep release a mode
  stranded behind a closed or absent lease. The [test-harness-and-run-ownership
  phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md) owns this gap.
- **Assertions can return engine classifications.** `CaseResult` exports all seven constructors and a
  `TestSuite` assertion has type `env -> Case -> IO CaseResult`; the engine passes the returned value
  through unchanged and maps only exceptions to `LifecycleFailed`. A project assertion can therefore
  return `Refused`, `Conflicted`, `Unsupported`, or `TeardownFailed`. The target narrows the assertion
  result to a pass/fail verdict that the engine maps into `CaseResult`. The [test-harness-and-run-ownership
  phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md) owns this gap.
- **Demo consumers read profile and root outside the plan.** The demo's cluster, provider, mount, and
  teardown consumers compute the cluster profile as `clusterProfileOf` of the working configuration and the
  durable root through `ensureProfileDataPath` over the process working directory, and the guest-alias,
  kind-node, and pod durable paths are fixed demo constants, rather than projecting each from the retained
  exact plan (see [Direct Harness plan boundary](#direct-harness-plan-boundary)). The [worked demo
  phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns this gap.

## What `<project>.test.dhall` means today

For the demo, the decoded type is `TestConfig` in
[HostBootstrapDemo.Config](../../demo/src/HostBootstrapDemo/Config.hs):

| Record | Field | Meaning |
|---|---|---|
| `TestConfig` | `testResources` | resource overrides, of the project's `Resources` type |
| `TestConfig` | `testVariants` | the list of declarative variant payloads |
| `TestVariantConfig` | `variantName` | the name validated into a stable `VariantId` |
| `TestVariantConfig` | `variantMessage` | the demo's per-variant message payload |

The executable `Case` registry is compiled into Haskell with opaque, validated `CaseId` values. The
command parser turns `<case-id>|all` into a typed selector; `all` is not stored in config. `TestCfg`
projects the decoded `tcfg` plus that executable registry into an opaque `TestMatrix`. The demo derives
its message variants from `testVariants`; every name is validated into a stable `VariantId`, and the
complete case-to-variant relation is checked before any mutation.

Accordingly, `<project>.test.dhall` contains resource overrides and declarative variant payloads. It is
not a general DSL containing case bodies, fixtures, secrets, or lifecycle actions; compiled Haskell owns
the assertion programs.

Haskell keeps the non-empty project-owned registry of opaque `CaseId` values and executable handlers.
Construction yields one opaque `TestMatrix` only after proving all of these invariants:

- the Haskell case registry and config variant registry are each non-empty and contain unique IDs (the
  one exception is `emptyTestMatrix`, the matrix of the `TestCfg ()` instance, which `mkTestMatrix`
  cannot produce, together with `emptySuite`, the zero-case suite that the `0/0 passed` rendering is
  pinned against; the bare binary itself ships `bareClusterLiveSuite`, one cluster-live Kind case whose
  matrix `mkTestMatrix` builds);
- every registered case has a `NonEmpty VariantId` row, so `all` cannot silently skip a handler;
- every referenced variant exists, every declared variant is referenced by at least one case, and each
  `(CaseId, VariantId)` pair occurs once;
- sharing a variant across cases and mapping one case to multiple variants are explicit valid relations,
  not duplicate or ambiguous rows.

CLI selection projects rows from that already total matrix; it does not weaken full-registry coverage or
turn unselected declarations into tolerated orphans. Empty rows, missing registered cases, unknown
references, orphan variants, duplicates, and ambiguous pairs fail before mutation. Selection,
generation, and reporting consume the same validated matrix, so a second unchecked string list cannot
disagree with executable handlers. A pure `VariantDraft payload` contains only its stable `VariantId`
and typed payload; project-config generation remains a separate `ProjectSpec` callback, and the draft
contains no run, plan, config, lease, or cleanup authority.

`VariantId` is stable reporting/config identity, not lifecycle ownership. After validating the pure
matrix/variant drafts, the lifecycle ownership bracket opens a fresh rank-2
`Harness projectId runId` and authoritative lease for each
distinct config variant, assembles only `cfg (Harness projectId runId)`, and runs every selected case mapped to
that variant against its one stack. The next variant cannot begin until the prior lease is closed; an
unresolved cleanup enters recovery/operator-resolution instead of reusing the same cluster/data root
under another config revision.

## Runner and ownership

The reusable engine aggregates `CaseResult`s into a `Report` and supports more than one generated config
variant. Reports use stable `VariantId`s, not assertion values masquerading as labels. A project's
five-field existential `TestSuite` supplies only the safety precondition, assertion-environment opener,
case matrix, per-case assertion, and post-reverse absence assertion. The command-owned `ConfigVariant`
instead supplies an opaque `HarnessLifecycle` closing over one exact plan's common forward and reverse
actions. Successful forward interpretation opens the assertion environment and runs the matrix under a
guaranteed final reverse. `AssertAcrossRestart` cases alone request an intermediate settled reverse, fresh
same-run broker generation, exact snapshot/plan rebind, second forward, and `AfterRestart` assertion. The
restart runs only if every selected restart-spanning case passed its `BeforeRestart` assertion; one
failing verdict suppresses the restart for every restart case in that variant. The `AfterRestart` verdict
replaces the case's `BeforeRestart` row, and a failed restart marks every restart case `BROKEN` with the
restart's cause. A non-refusal forward failure runs the current reverse. Only a refusal independently
verified to precede project-resource acquisition takes the no-reverse branch. A late refusal retains its
refused report classification but still reverses. The demo generates two message variants and runs the
compiled cases for each.

`HostBootstrap.Harness.Lifecycle.Internal` is exposed only by the private
`harness-lifecycle-internal` Cabal component. The main library constructs a real lifecycle at the command
boundary, and the core test suite constructs controlled fixtures through that same private component.
Downstream packages cannot import the constructor, and `TestSuite` cannot manufacture or replace a
top-level lifecycle path.

Non-passing outcomes are **distinct**, not one flattened failure string. `Fail` is the project's own
assertion verdict; `Refused`, `LifecycleFailed`, `Conflicted`, `Unsupported`, and `TeardownFailed` are
intended as the engine's classifications. The constructors are public and the assertion's result passes
through unchanged, so the tree does not yet prevent an assertion from returning one of them (see
[Current Status](#current-status)). The report card
prints a distinct label per outcome (`PASS`/`FAIL`/`REFUSED`/`CONFLICT`/`SKIPPED`/`BROKEN`/`LEAKED?`), and
`caseResultPassed`/`caseResultLabel`/`caseResultReason` are total, so a new outcome cannot be silently
counted as success. A failed teardown adds its own row rather than overwriting the case results: the
variant goes red with the cause named while "the assertions passed but the stack did not come down"
stays legible. A conforming project assertion returns only `Pass` or `Fail`.

The run's **durable data root** holds all four
[ownership_invariant](ownership_invariant.md) clauses. The run owns `.test_data/<runId>`; the shared
`.test_data` parent is unowned scaffolding, created if missing and never removed by a run.
`HostBootstrap.Harness.Ownership` acquires and releases `.test_data/<runId>` through
`HostBootstrap.Harness.DataRoot` inside the protected store's OS-released
exclusive entry (clause 1). Before the directory is created, a durable origin record names the exact
prior state — the identity of a directory that was already there, or explicit absence (clause 2). The
created directory's own `device:inode` is then bound to the receipt (clause 3), and teardown removes it
only after re-observing that exact identity (clause 4). A directory the run merely found is never in the
removal set; a directory that was *replaced* under the run is a structured conflict and is left intact
rather than deleted. A host that cannot report a stable identity yields `DataRootUnsupported`: no data-root
receipt is minted and nothing is created under `.test_data/<runId>`, and the variant reports `REFUSED`
rows. The data root is taken inside `withHarnessRoot`, so the run's Harness mode and unbound lease are
already held at that point and are not closed by this run; the abandoned-run sweep that opens the next
ownership bracket settles that incomplete unbound lease behind `verifyUnboundLeaseHasNoEffects` (see
[Current Status](#current-status)).

The same record drives recovery. Because the origin is published before the first mutation, an abandoned
run whose record says *absent* has its generated content removed rather than adopted — including the
crash window between publishing the origin and binding the identity, where no managed identity was ever
recorded. The sweep reclaims each abandoned run's data root **and its generated config** before closing
that run's lease.

Generated project config is on the invariant too, through the same identity seam. Its origin record adds
the intended payload digest, published before the file is created, so the crash window between the
record and the identity binding resolves without adopting bytes the record does not name. The "a
production config already exists" refusal lives *after* the abandoned-run sweep and is derived from
installed project identity inside the protected transaction that takes the mode. This single ordering lets
recovery settle an interrupted run's own generated config before deciding whether a foreign Production
config blocks the next run.

Both harness owners reach the store through the one record tape described in the
[ownership seam](ownership_seam.md): publishing the origin, binding it, forgetting it, and reading it
back are shared, and what each keeps is its own subject and its own removal-set rule. The data root's
rule is that the parent is scaffolding and a found directory is preserved; the generated config's is
that a found file is refused before any mutation rather than adopted.

The project-supplied Production-state probe follows the same ordering. For each variant, the ownership
bracket holds project liveness, settles every abandoned Harness resource, then evaluates the probe before it
allocates a fresh run lease, data root, generated config, or plan. A provider left by the abandoned run is
therefore released by recovery before the probe decides whether independently held Production state exists.
The probe is repeated inside each variant's bracket, so an operator-created obstacle between variants is
refused before the next acquisition. A probe refusal ends the whole `test run`: the command prints the
refusal and no report, so the rows of variants that already completed are not rendered.

The assertion engine receives no ownership receipts. Managed resource receipts stay inside the exact plan's
common interpreter, which consumes them in its reverse projection; the transitions that consume a
satisfying receipt are in [lifecycle_state_model](lifecycle_state_model.md).

`SafetyRefusal` has two routes, and they report differently:

| Route | When it fires | Reverse | Report |
|---|---|---|---|
| Ownership-bracket safety probe | after the abandoned-run sweep, before fresh run acquisition | none; no run state exists | the whole run ends with the refusal and no report |
| Forward-action refusal | inside the forward action, before rollback acquisition, and only after `verifyBoundRunHasNoProjectResourcesAcquired` succeeds | none; the rollback set is empty | that variant's rows are `REFUSED`; later variants continue |

Every other action-local provider or cluster refusal, conflict, or failure enters the exact reverse path,
and a late refusal keeps its `REFUSED` classification.

Execution shape is not selected by the harness. No detached selector or definition-only parallel execution
surface exists. The harness drives the exact run-scoped `ProjectPlan` the command admits and retains only its
live matrix loop, reporting, safety probes, and owned-artifact bracket.

## Direct Harness plan boundary

The harness owns a self-created `.test_data/<runId>` generation, and the generated demo config carries
`HarnessRun <runId>`, so cluster name, removable state, semantic exposure intent, durable setup, and nested
mounts select the run-scoped test identity rather than the Production name or `.data`; selected host ports
remain runtime results owned by that run. The demo's adopted lifecycle actions take their managed
cluster, provider, durable-share, and workload nodes from the exact retained plan's step execution (for
example `withExactPlanOwnedClusterConfig` and `withNodeResourceOfKind`), and source guards in
`CommandsSpec` pin those call shapes. The cluster profile, cluster name, and durable root those actions use
are not plan projections: they compute the profile as `clusterProfileOf` of the working configuration
and the durable root through `ensureProfileDataPath` over the process working directory (`runVmUp`,
`runCopySource`, and `withHostAcceleratorExposure` each do both), and the guest-alias, kind-node, and pod
durable paths are fixed demo constants. The run-scoped identity still holds because the generated config
carries `HarnessRun <runId>`; the [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns
projecting every such term from the retained plan (see [Current Status](#current-status)).

Authority scope matches that descriptive profile. The generated-config bracket finalizes and validates
`cfg (Harness projectId runId)`, admits
`ProjectPlan (Harness projectId runId) specDigest planId configId cfg`, persists and binds its exact
snapshot, and retains the matching lease, plan, lifecycle context, and reverse frame. Its forward action
calls the common `runExactProjectUp` wrapper, whose Cabal-private fixed root-Up `LifecycleEntry` alone derives
the journal/current cursor/authority before reaching the lower Chain; its reverse action derives the destroy
projection from that same retained plan and current frame. Neither action runs `project up` or
`project destroy` as a root-level subprocess, so it
cannot discard the Harness indices and re-enter Production.

The long gate creates real provider, Docker, and cluster state, so a disposable host is the supported
place to run it.

## Safety contract

`test run` acquires a sealed root-harness capability before lifecycle mutation. The contract, with how the
tree holds each item:

| # | Contract item | How the tree holds it |
|---|---|---|
| 1 | abandoned Harness resources are settled under project liveness before Production-state safety is judged | implemented: `recoverAbandonedHarnessRuns` runs before the safety probe in the ownership bracket |
| 2 | the generated config is owned by this run | implemented: `HostBootstrap.Harness.GeneratedConfig` |
| 3 | the resolved cluster profile is `Harness projectId runId` | implemented: the scope-indexed plan and `withHarnessLifecycleProfile` |
| 4 | the cluster identity is run-scoped | implemented: derived from the `HarnessRun <runId>` profile |
| 5 | the resolved durable root is `.test_data/<runId>` | implemented: `HostBootstrap.Harness.DataRoot` |
| 6 | neither `.data` nor the production cluster is opened, mounted, reconciled, or deleted | implemented by profile derivation only; no runtime tripwire checks it. The owed tripwire ([test-harness-and-run-ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)) observes changes: it fails a run whose variant changed the `.data` tree or started a production cluster, and read access stays excluded by profile derivation alone |
| 7 | every created resource returns an ownership receipt used by rollback and teardown | implemented inside the exact plan's common interpreter, which the demo adopts through the [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) |
| 8 | a pre-effect safety refusal owns no lifecycle resources, while any later failure rolls back every journaled preparation for which this run has an exact receipt | implemented: the two `SafetyRefusal` routes above and the guaranteed reverse |
| 9 | one project-wide mode compare-and-swap excludes every Production invocation for the full Harness run, and Harness mode is released only after the old run's lease and close effects settle | implemented: `withHarnessRoot` and the terminal close below |

The contract also requires the entry to refuse a non-root context; the parser does not yet enforce that
(see [Current Status](#current-status)).

The test config and profile are explicit in the typed inputs to plan construction, so a caller cannot
generate a test config and then silently obtain a Production plan.

The command boundary mints an opaque `HarnessAuthority projectId runId` and constructs
`ProjectPlan (Harness projectId runId) specDigest planId configId cfg` from the matching
profile/config/draft. Only an independently authorized Production root invocation can construct a
Production plan. The target has the demo's cluster, provider, mount, and teardown consumers take every term
from the exact retained plan projection; today they derive the cluster profile and durable root from the
working configuration and process working directory, as [Direct Harness plan
boundary](#direct-harness-plan-boundary) states, and the
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns that gap. See
[lifecycle state model](lifecycle_state_model.md#lifecycle-profile-authority).

### Direct root lifecycle and authenticated child descent

The Harness root lifecycle stays in one process. `test run` establishes the identity-bearing
`UnboundRunLease (Harness projectId runId) brokerGeneration`, opens the one-use lifecycle profile, builds
config only through the restricted `ConfigAssembly` effect, validates it with the scope-correct
`ProjectCodec`, persists and verifies the plan snapshot, and fresh-binds the lease to that exact digest.
The generated-config bracket then retains all of those values while Command builds the opaque lifecycle
from direct common-interpreter calls. No root Harness authority is serialized, inferred from config, or
reconstructed by a child process.

Self-reference remains only for plan-declared recursive child-frame transitions. The Handoff facade
implements the root-signed `AuthenticatedRootScope (Harness projectId runId)` primitive and verifies its
canonical wire with the independently installed project key before introducing a fresh run phantom. The
Harness lifecycle supplies that producer from the exact installed project identity and live
`HarnessAuthority projectId runId` retained by its ownership bracket. The unchanged four-field
Offer/Relay/Receiver transport carries and scope-first verifies the resulting capsule: root links mint it
and nested links copy only the exact canonical bytes. When a plan-declared child descent crosses a process
boundary, the Harness root signs it from the exact live generative evidence before received payload bytes can introduce that phantom,
then mints a one-time token bound
to the exact scope, plan revision, broker generation, edge, separate payload/config digests, verb, and phase. The capsule and
offer travel over a private duplex lift session, never through Dhall, `argv`, an environment variable, or a
durable config file. If assembly/codec/plan validation fails before binding, the bracket can close the
unbound lease only after protected proof that no token, permit, journal, or effect exists; a crash leaves an
explicit unbound incomplete lease rather than an invented plan digest.

Inside the authenticated-scope continuation, the child binary's internal receiver—not a shell config
writer—returns a fresh challenge. The root exact-matches the scope, catalog edge, binding fields, and nonce,
then signs the grant. Grant verification yields only transport-level
`VerifiedHandoff scope brokerGeneration`. Exact-byte verification through the scope-correct project-owned
`ProjectCodec` separately creates `VerifiedConfigWire` under a fresh child `configId` and matching
`ValidatedConfig`. `Config.Schema.withVerifiedConfigHandoff` checks the signed payload kind,
separate payload and config digests, the specification digest, closed verb, and lifecycle phase, and alone
yields fully indexed `VerifiedConfigHandoff` inside a rank-2 continuation.

Those values are not command authority. `ProjectPlan.Construct.withChildProjectPlan` consumes the
refinement with the same wire/config and non-empty drafts, verifies the stable revision plus signed
project/catalog/broker origin, and jointly yields the fresh local `ProjectPlan`, `PlanDigestBinding`, and
exact opaque `ChildPlanAuthority`. The Cabal-private child entry exact-matches those values and the nested
context against the root catalog, then admits only a storeless `FrameExecutor`. It receives root-signed
prepared responses one node at a time, independently compares their plan/frame/node/dependency/projected-key
coordinates, runs the selected local work, and returns bounded observations. The root retains every durable
journal, cursor, settlement, and receipt transition. No raw projection or public producer exists. The child
never reuses its parent's exact-byte identity or receives root/Harness-root/signing/store authority. The
[authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
owns the implemented generic authenticated root-scope primitive and scope-first receiver; this Harness phase
supplies the live generative producer evidence at the single command call site. Recursive process adoption is
owned by the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).

#### Sessions, recovery, and mode exclusion

The session, journal, fence, prepare, and terminal-acknowledgement protocol, and the terms it uses (broker
generation, fence epoch, project journal state, Closing epoch), are defined in
[sessions, fences, and terminal acknowledgement](lifecycle_state_model.md#sessions-fences-and-terminal-acknowledgement)
and implemented in [Lifecycle.Session](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs).
The rest of this subsection summarizes how the Harness path relies on that protocol and adds the
Harness-specific abandoned-run recovery and mode exclusion.

**Session admission.** One one-use command/handoff identity opens exactly one versioned operation session only after clean
activation or abandoned-session recovery yields current-broker admission. Clean activation first proves
every recorded older-broker session Closed, including zero-operation sessions. Session open and close each advance the shared Open
project-journal version and return its sole successor state/permit pair; opening also rechecks that the
revision is not migration-frozen. Abandoned activation instead consumes the exact old-permit fence
set and verifies the manifest pairing the independent complete session set with its operation set. Its
protected interpreter CAS-rebinds each existing stable session record once—including a zero-operation
Open session—and classifies unknown, the five pre-call continuable phases, already-observed retryable,
successful, and terminal operation records.

**Intent registration.** Initial intent registration and exact session membership are
one atomic session/project-journal version transition that consumes an exact `IntentOrigin` — either the
sole `NoHistory` origin or a `ReleasedReacquisition` one — so no orphan intent can be omitted from the
manifest and callers cannot choose the generation. An initial intent may have no fence record and cannot
prepare; recovery idempotently resumes the stable initial-fence protocol and threads its successor
session/state/permit before exposing current-fence authority. Only continuable phases receive
current-fence prepare authority, and only the closed retry
whitelist can receive fenced same-key authority. It withholds admission
until every operation is settled and every session is Closed, verifies the complete resource-record set,
and jointly yields fresh rehydrated resources while threading the sole successor state/permit pair.

**Prepare.** Before every remote reservation/mutation/delete, the storeless executor sends a bounded next-node request
naming its exact requester path, verb/phase/frame, session, ordinal, nonce, and predecessor response. One
protected compare-and-swap revalidates the project-wide Harness mode, bound lease, active plan revision,
Open-project state, catalog entry, command/session/fence, and operation record. It consumes the exact
plan-owned closed precondition set, reruns every target/dependency probe and version, and obtains conditional backend
versions; stale/replaced/not-ready evidence returns no grant. It records the operation-specific Unknown
journal state—including adoption transfer and adopted release—before producing the root-signed `Prepared`
response with the exact node and projected-key coordinates. Only after independently comparing those fields
may the executor's hidden allow-listed reifier adopt the same durable gate and invoke the local adapter. The
executor returns only a bounded observation; root settlement validates it and advances through
`OperationAdvance` with the sole successor project/session state. The consumed journal version cannot
authorize another prepare or close. Initial fence creation and crash-time fence rotation persist/resume the
same proposed epoch; an old or delayed response is rejected or deduplicated.

**Terminal acknowledgment.** Terminal acknowledgment proves
every registered outcome settled, records the root-owned receipt, and compare-and-swaps the exact session
version Closed, so it cannot race another prepare. Loss before the signed response refuses; loss after its
durable Unknown leaves explicit recovery work. A later teardown invocation receives a **fresh** per-edge
token and session.

**Abandoned-run recovery.** Before allocating a new test run, `recoverAbandonedHarnessRuns` enumerates incomplete unbound and bound
old leases at one protected-store version. Separate rank-2 fold callbacks receive each exact existential
`VerifiedIncompleteRunLease`; callers never manufacture the old run/digest phantom, and the sweep
rechecks terminal closure after every callback so a no-op handler cannot skip a record. An unbound
member closes only with
`VerifiedUnboundLeaseHasNoEffects`; a stray effect-shaped record refuses.
`withAbandonedHarnessRun` reopens each exact bound old harness scope with its bound snapshot/lease,
`BoundInvocationRecovery`, `ProjectDestroy`, and narrow recovery/close authority, but never a generic
journal, general harness, or `ProjectUp` authority. The recovery sum first distinguishes the normal
Open branch from the exact persisted Closing epoch; only the Open branch may then choose
normal/incomplete/completed plan-revision recovery and activate its matching journal. A normal revision
with an older Open operation session must use the recorded-session interpreter and its independent
session/operation manifest; missing/duplicate members, wrong membership, or unresolved recovery yields
neither current-broker admission nor a new session. Completed migration activation also rechecks prior
session settlement and yields the new revision's admission; the committed-new window cannot open a
session. The Closing branch
can resume only the close plan. Only after all are closed does a protected empty-set
compare-and-swap mint `ClosedAbandonedHarnessRuns`; `withHarnessRoot` consumes that versioned proof
atomically with fresh allocation. A new run ID or a concurrent sweep cannot bypass an abandoned run.
The bound no-resource proof checks both legacy effect markers and the exact plan's canonical resource
namespace. A canonical record, including a released tombstone (see
[ownership and idempotence](lifecycle_state_model.md#ownership-and-idempotence)), requires the settled-recovery path rather
than proving that no resource was acquired. The Harness short close repeats that check and verifies the
persisted lease epoch inside the protected entry that closes the lease. A bound run also requires its
complete session set to be Closed. An earlier proof cannot bypass a later session or ownership record;
refusal preserves the lease and mode so the abandoned-run sweep can still reach the work.

**Mode exclusion.** Production and Harness use disjoint authority/broker lease namespaces but contend on one
project-wide mode record. The precondition check has two halves. The project-supplied Production-cluster
liveness probe runs once, after the abandoned-run sweep and before `withHarnessRoot`; it is not rechecked
inside the mode acquisition, so a cluster started outside hostbootstrap between that probe and the mode
compare-and-swap is not observed. The sibling-config half, built by `harnessPreconditions` from the installed
project identity, is rechecked by `withHarnessRoot` inside the same protected entry that acquires Harness
mode. Exclusion of a hostbootstrap-managed Production invocation rests on the project-wide mode
compare-and-swap: Production cannot slip between precheck and ownership, and a Harness run cannot overlap a
stopped Production stack whose mode is still held. Production can release that mode only through a closed `ProductionClosureAuthorization`: exact
`ProjectDestroy` plus `DestroySettled` authorizes settled closure, while any exact Production verb can
close before its first effect only through `PreEffectProductionClosure`, whose sole evidence is
`verifyNoProjectResourcesAcquired`. The final compare-and-swap
rechecks the same mode/lease/snapshot/Open-state tuple and complete Closed-session set, then atomically
records `ClosedProject`, closes the invocation lease, and releases mode. Session opening advances and
compare-and-swaps that same project-journal version, so it and finalization have exactly one winner;
partial `up`/`down` work cannot be relabelled as destroy and no mode-cleared partial state exists.

If recovery crosses another child boundary after the old config was edited or removed, the root catalog and
bound snapshot are the sole producer of the canonical non-secret
`RecoveryChildPackage {child config bytes, adapter bytes}` for the exact reverse edge. Catalog-backed
`EdgeAdmission` authenticates its complete configuration and package digest, while `RecoveryAdmission`
independently authenticates the extracted adapter. Prepared/Bound reverse input and the Offer payload/digest
name the complete package, and the exact Offer travels over the keyless route to the already-installed root
signer; `Teardown.Internal` receives no root broker or signing capability. In the receiver path, the
child first verifies `AuthenticatedRootScope`, then the rooted binding, exact parent→child
`RecoveryProjectionBinding`, grant, `VerifiedRecoveryWire`, teardown-only fully indexed
`VerifiedRecoveryHandoff ... recoveryWireId verb`, and catalog frame coordinates before the storeless executor
accepts any teardown grant. The root-owned `TeardownForest` supplies the next `TeardownAuthorizationPoint`; no
forest cursor or store crosses the process boundary.

The recovered frame and matching ordinary-step resource evidence remains a root-held closed
owned-or-released sum arising only from the bound snapshot and complete rehydrated set. The owned branch can
produce a signed grant for the matching managed handle/receipt/resource/operation bindings. The released
branch yields only its verified tombstone, produces no backend-call grant, and requires a protected root-side
absence recheck plus a distinct new acquisition key before `ReleasedReacquisition`. Its sole root-side consumer
creates the exact reacquisition origin and atomically revalidates it with the new generation and session
membership. Provider reachability can therefore precede retained-child teardown without trusting raw
persisted receipts, recreating the old normal config, or granting `ProjectUp` authority.

The self-reference lift is used only by plan-declared child descent and streams the
context-adjusted full config record. The standalone authenticated root-scope and recovery-package primitives,
their Offer/Relay/Receiver adoption, and the bounded keyless rooted request/response route are implemented.
The generic Harness scope-capsule producer is adopted at the direct Harness root lifecycle's single command
call site. The storeless child executor verifies the complete binding, derives the exact Production or
`harness:<run-id>` profile from it, and executes callback-backed local release plus core-managed retained
cluster release. A callback-free non-core node remains foreign-retained. No child authority-store rehydration
is part of this path.

The full child protocol is specified in
[lifecycle state model](lifecycle_state_model.md#cross-process-authority-handoff).

## Teardown

The root command runs the verb's reverse projection of the one plan child-first. Each reachable child receives
one authenticated storeless reverse handoff, releases its exact retained cluster and declared local resources,
and settles before its owning parent provider is stopped or deleted. Provider deletion is therefore the final
owned parent action, not a substitute for child cleanup.

The Harness reverse action drives that projection from the exact retained plan/current-frame pair and
returns `DestroySettled`. It independently verifies all ordinary sessions Closed and uses
`destroySettledClosure` to construct exact Harness `ProjectClosureEvidence`. `authorizeHarnessClose`
requires that evidence, rejects its true-pre-effect branch, and only the settled-destroy branch may move
the project from Open to a fresh Closing epoch. A successful authorization is recorded as pending in the
private `OwnedHarnessCloseControl`; the exact settled evidence must then advance the control to settled.
The ownership finalizer receives no caller-supplied close action: after generated-config and data-root
cleanup it consumes the control exactly once and calls the trusted finalizer only from the retained
authorization. Binding-in-progress and Closing-pending states fail closed. A genuinely pre-effect bound
run instead takes the separate verified no-project-resources short-close path.

The plan's preserved `.test_data/<runId>` root supports the same-run durability check. After the intermediate
destroy settles and every session is Closed, `withFreshHarnessInvocation` advances the held Harness mode and
bound lease to a strictly fresh broker generation, rearms the lifecycle-profile slot and terminal fallback,
and re-admits the identical canonical plan snapshot under fresh local indices. Released stable resource
members admit only a canonical owned successor at a strictly greater ownership generation. The final destroy's
current-generation evidence alone authorizes terminal close. No raw lifecycle IO enters `TestSuite`.

Recursive reverse descends into each reachable child, tears it down, and only then stops or deletes the
parent. Independent failures are aggregated, and destructive actions consume ownership receipts. The complete
close/recovery algebra is described in
[lifecycle_state_model](lifecycle_state_model.md).

## Validation

The static authority suite proves distinct stable run identities across successive Harness
acquisitions, sequential refusal after each Production/Harness profile slot is consumed, and same-slot
two-thread races in which exactly one continuation runs. Public compile-fail fixtures pin constructor
sealing, nominal run/mode indices, cross-run and cross-scope refusal, exact snapshot/digest binding, and
the complete Production/Harness profile evidence sets; no fixture pins role-based coercion of
`HarnessAuthority`, whose indices are not nominal (see [Current Status](#current-status)). Harness/CLI tests also pin exact plan retention,
forward→assertion→reverse ordering, generated-config lifetime, settled-evidence-required close, and the
private lifecycle component's absence from the public library. A command-level fixture proves the protected
generation rotation and exact snapshot rebind, and a source guard rejects lifecycle-owned `project up` or
`project destroy` invocation from the demo assertion suite. The workflow validation surface is:

- `CLISpec` covers `test init`'s overwrite policy (a second `test init` refuses and leaves the file
  byte-identical; `--replace` is the only overwrite route), the missing-config refusal of `test run`, and
  the unknown-case refusal.
- A `<project>.test.dhall` schema test proves the documented resource field is exactly the decoded field;
  matrix tests prove typed selection has one source of truth.
- The demo gate records the config-derived profile/name/path and asserts `Harness projectId runId`, a
  run-scoped name, and `.test_data/<runId>`; the worked-demo gate additionally proves exact plan-owned
  projection.
- Interruption tests prove teardown removes only resources for which the run holds ownership receipts,
  with no production fault hook: they either kill a real process (`RecoveryInterruptionSpec`) or write
  the durable state an interrupted transaction leaves through
  [`HostBootstrap.Lifecycle.Session.Testing`](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session/Testing.hs)
  and re-enter the ordinary entry point.
- Handoff tests prove a valid token works once and reject replay/recorded transcripts, wrong
  project/verb/phase/frame/scope/config digest, stale generation, truncation, reuse during teardown, and
  token delivery through Dhall, `argv`, or environment variables. They also prove one invocation cannot
  open two sessions, stale authority/session/fence epochs cannot prepare, and a delayed permit after
  terminal acknowledgment has no effect. Broker loss before permit refuses; loss after permit leaves the
  durable unknown state.
- Hard-kill recovery reopens the exact abandoned run before a new run ID is allocated, resumes every
  prepared operation/preconditions attempt by reprobe, resumes every persisted retryable observation only through its fenced
  same-key branch, rebinds rather than duplicates every recorded Open logical session, and blocks later
  variants until the old lease closes and the protected sweep proof is atomically consumed. A
  zero-operation Open session remains a required member; missing/duplicate records, wrong
  session/operation membership, missing/replaced rehydration evidence, or unresolved recovery never
  produces current-broker admission. Kill points include intent/session registration before the first
  fence record, every durable initial-fence phase, and prepare-time dependency replacement; only a real
  current fence plus a jointly fresh prepared pair can reach an adapter. Stale `Ready`, wrong
  edge/precondition digest/version, and reused/wrong-resource generation origins produce no permit or
  new intent. Kill
  points cover Open→Closing, each terminal
  generated-config/data-root close state, lease close, and mode release; persisted Closing resumes
  without becoming Open. A true pre-effect refusal can close, unresolved partial ownership cannot, and
  neither Production nor another run can mint the close authority.
- Cross-profile races prove the sibling-config half of the Harness preconditions is rechecked in the same
  project-mode acquisition,
  Production cannot open during Harness, Harness cannot open while Production remains active or stopped,
  and the exact mode epoch is released last. Production closure fixtures prove settled release is
  destroy-only, true-pre-effect release is available to the exact invoking verb, and partial work
  inhabits neither authorization. A session-open/finalizer race has one winner, and kill/restart around
  the Production finalizer observes either the complete Open tuple or the atomic
  `ClosedProject`/closed-lease/released-mode tuple.
- The engine-owned same-run lifecycle generation drives the configured durable write→destroy→up→read
  assertion and the live matrix reports every row passing.

Not validated by any test:

- an off-root `test run` or `test init` being refused before any lifecycle read or mutation (the parser
  applies no root gate; see [Current Status](#current-status));
- a runtime tripwire that fails a run whose variant changed the `.data` tree or started a production
  cluster — contract item 6 rests on profile derivation alone, and the owed tripwire observes changes, not
  reads (see the [test-harness-and-run-ownership
  phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md));
- a project assertion being unable to return an engine classification;
- the next sweep recovering a Harness mode stranded by a crash between lease close and mode release (see
  [Current Status](#current-status)).

Phase status and live-run closure belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md), not this workflow page.

Abandoned-run nested recovery enters through the authenticated recovery-wire boundary. The root derives
each projection from snapshot-recovered parent/child frames and places the complete resource-set digest in the
canonical adapter wire. The receiver admits only an independently verified, one-use Down/Destroy teardown
handoff with the same project, store, broker generation, plan, edge, payload, and phase; child frames never
receive the signing key or ordinary config handoff.

If an abandoned bound run has resource records, the sweep rehydrates the complete snapshot-owned set and
executes frames child-first through the installed closed recovery executor. Released tombstones cause no
backend call. Each successful owned release is recorded before the parent proceeds; any refusal retains the
old lease, mode, snapshot, and records for retry. Reclamation and final close occur only after the complete
forest has settled as Destroy and the protected session enumeration proves every session Closed.

The Production command follows the same ownership discipline as the Harness path: its composite root owns the
mode and unbound lease, exact plan construction persists and verifies the canonical snapshot before binding,
and recursive execution retains the resulting root/lease/snapshot/binding tuple. Only a true pre-effect
refusal can take the short close; anything after binding remains available to the recovered Production route.

## Related

- [durable state](durable_state.md) — the preserved run root and destroy/up/readback proof.
- [lifecycle state model](lifecycle_state_model.md) — capability and ownership target.
- [testing](../engineering/testing.md) — fast unit-suite entry points and long demo-gate scope.
- [composition methodology](composition_methodology.md) — the project chain the harness drives.
