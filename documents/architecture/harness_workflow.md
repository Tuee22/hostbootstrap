# Harness Workflow

**Status**: Authoritative source
**Supersedes**: the self-invoking Production-lifecycle description of `test run`
**Referenced by**: [documents index](../README.md), [composition methodology](composition_methodology.md), [testing](../engineering/testing.md), [durable state](durable_state.md), [lifecycle state model](lifecycle_state_model.md)

> **Purpose**: Describe the implemented exact-plan test runner, including its command gate,
> assertion-only suite, owned generated artifacts, terminal close, and remaining same-run restart gap.

## TL;DR

The lifecycle root now gives every Harness acquisition a sealed generative run identity and matching
mode, root, and unbound-lease evidence; its protected profile opener can enter exactly once. Each selected
variant owns its generated config, admits one exact Harness-scoped project plan, and drives that plan's
hidden fixed root-Up entry plus exact reverse action. The entry alone reaches the lower Chain. `TestSuite`
is assertion-only, and the lifecycle constructor is confined to a private Cabal component. The parser still
does not enforce the documented root gate,
complete resource-indexed ownership remains downstream work, and the configured durable-readback case is
honestly red until the engine owns a fresh same-run lifecycle invocation for destroy→up.

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
`<project>.dhall`. `test run` reads that file, validates the compiled cases and the project-owned typed
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
sequential replay or a concurrent same-slot contender receives no second profile. Production uses its
structurally separate mode, scope, and profile opener, while both modes contend on one project record.

After a plan snapshot is persisted and read back, its Harness scope and both digest indices must match
the lease at the type boundary. Fresh-only `bindRunLease` rejects an already-bound record with
`LeaseConflict`. Existing Production recovery instead enters through
`ProjectPlan.Snapshot.withBoundPlanSnapshot`, which starts from the protected store and installed project,
mutates no protected record, and yields fully indexed recovery evidence only for a verified Open
invocation. Harness abandoned-run recovery keeps its weaker durable observation package-private behind
the sweep and scope-specific classifier. Neither route can claim a fresh binding. This implemented
admission foundation is now consumed directly by Harness command dispatch; it does not cross a root-level
lifecycle subprocess boundary.

The command description calls this a root-only surface, but the parser does not apply a binary-context
root gate to either subcommand. `test run` deliberately does not load a pre-existing project config,
because it generates one. Root authority therefore depends on harness safety checks and invocation
location rather than an unforgeable context capability. That mismatch is open.

## What `<project>.test.dhall` means today

For the demo, the decoded type is now:

```haskell
data TestVariantConfig = TestVariantConfig
  { variantName :: Text
  , variantMessage :: Text
  }
data TestConfig = TestConfig
  { testResources :: Resources
  , testVariants :: [TestVariantConfig]
  }
```

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

- the Haskell case registry and config variant registry are each non-empty and contain unique IDs;
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
guaranteed reverse; a non-refusal forward failure runs the same reverse. Only a refusal independently
verified to precede project-resource acquisition takes the no-reverse branch. A late refusal retains its
refused report classification but still reverses. The demo currently generates two message variants and
runs the compiled cases for each.

`HostBootstrap.Harness.Lifecycle.Internal` is exposed only by the private
`harness-lifecycle-internal` Cabal component. The main library constructs a real lifecycle at the command
boundary, and the core test suite constructs controlled fixtures through that same private component.
Downstream packages cannot import the constructor, and `TestSuite` cannot manufacture or replace a
top-level lifecycle path.

Non-passing outcomes are **distinct**, not one flattened failure string. `Fail` is the project's own
assertion verdict; `Refused`, `LifecycleFailed`, and `TeardownFailed` are the engine's classifications
and have no project-side constructor, so an assertion cannot label itself a refusal. The report card
prints a distinct label per outcome (`PASS`/`FAIL`/`REFUSED`/`CONFLICT`/`SKIPPED`/`BROKEN`/`LEAKED?`), and
`caseResultPassed`/`caseResultLabel`/`caseResultReason` are total, so a new outcome cannot be silently
counted as success. A failed teardown adds its own row rather than overwriting the case results: the
variant goes red with the cause named while "the assertions passed but the stack did not come down"
stays legible. `Conflicted` and `Unsupported` are engine-classified lifecycle outcomes; project assertions
still return only their own `Pass` or `Fail` verdict.

The run's **durable data root** holds all four
[ownership_invariant](ownership_invariant.md) clauses. `HostBootstrap.Harness.Ownership` acquires and
releases `.test_data` through `HostBootstrap.Harness.DataRoot` inside the protected store's OS-released
exclusive entry (clause 1). Before the directory is created, a durable origin record names the exact
prior state — the identity of a directory that was already there, or explicit absence (clause 2). The
created directory's own `device:inode` is then bound to the receipt (clause 3), and teardown removes it
only after re-observing that exact identity (clause 4). A directory the run merely found is never in the
removal set; a directory that was *replaced* under the run is a structured conflict and is left intact
rather than deleted. A host that cannot report a stable identity is `Unsupported` and the run takes no
ownership at all.

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

Most other lifecycle resources still return `IO ()`, and the runner does not receive opaque ownership
receipts for the VM, cluster, alias, or daemon. The transitions that consume a satisfying receipt are in
[lifecycle_state_model](lifecycle_state_model.md).

Some current safety checks are late. VM bring-up can run provider ensure, create the durable path, and
perform host preflight before its managed-VM refusal; the direct lane can run Docker ensure before its
cluster refusal. The harness treats `SafetyRefusal` as “skip teardown,” so those preparatory effects can
remain. The target classifies a true pre-effect refusal separately from post-acquisition conflict/failure
and rolls back every journaled owned preparation.

Execution shape is not selected by the harness. No detached selector or definition-only parallel execution
surface exists. The harness drives the exact run-scoped `ProjectPlan` the command admits and retains only its
live matrix loop, reporting, safety probes, and owned-artifact bracket.

## Direct Harness plan boundary

The harness owns a self-created `.test_data/<runId>` generation, and the generated demo config carries
`HarnessRun <runId>`. Demo lifecycle actions currently consume that config-derived profile independently,
so cluster name, removable state, host-port policy, durable setup, and nested mounts select the run-scoped
test identity rather than the Production name or `.data`. The
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) makes those consumers take one retained
plan-owned profile/root projection instead of rereading independent terms.

Authority scope now matches that descriptive profile. The generated-config bracket finalizes and validates
`cfg (Harness projectId runId)`, admits
`ProjectPlan (Harness projectId runId) specDigest planId configId cfg`, persists and binds its exact
snapshot, and retains the matching lease, plan, lifecycle context, and reverse frame. Its forward action
calls the common `runExactProjectUp` wrapper, whose Cabal-private fixed root-Up `LifecycleEntry` alone derives
the journal/current cursor/authority before reaching the lower Chain; its reverse action derives the destroy
projection from that same retained plan and current frame. Neither action runs `project up` or
`project destroy` as a root-level subprocess, so it
cannot discard the Harness indices and re-enter Production.

The long gate still creates real provider, Docker, and cluster state, so a disposable host remains the
supported place to run it until the remaining live acceptance phases close.

## Safety contract

`test run` acquires a sealed root-harness capability before lifecycle mutation. The complete target
contract is:

1. the generated config is owned by this run;
2. the resolved cluster profile is `Harness projectId runId`;
3. the cluster identity is run-scoped;
4. the resolved durable root is `.test_data`;
5. neither `.data` nor the production cluster is opened, mounted, reconciled, or deleted;
6. every created resource returns an ownership receipt used by rollback and teardown;
7. a pre-effect safety refusal owns no lifecycle resources, while any later failure rolls back every
   journaled preparation for which this run has an exact receipt;
8. one project-wide mode compare-and-swap excludes every Production invocation for the full Harness run,
   and Harness mode is released only after the old run's lease and close effects settle.

The command boundary implements generated-config and data-root ownership, the Harness mode exclusion, and
config-derived profile isolation. Most VM/cluster/alias/daemon mutations still lack the receipt coverage in
clauses 6–7, and the independent profile/root consumers in clauses 2–5 remain work in the
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

The test config/profile should be explicit in the typed inputs to plan construction. A caller should not
be able to generate a test config and then silently obtain a `Production` `ClusterPlan`.

The current command boundary mints an opaque `HarnessAuthority projectId runId` and constructs
`ProjectPlan (Harness projectId runId) specDigest planId configId cfg` from the matching
profile/config/draft. Only an independently authorized Production root invocation can construct a
Production plan. Cluster, provider, mount, and teardown consumers still receive config-derived profile,
path, and name terms independently; the worked-demo phase replaces those terms with the exact retained
plan projection. See
[lifecycle state model](lifecycle_state_model.md#lifecycle-profile-authority).

### Direct root lifecycle and authenticated child descent

The Harness root lifecycle stays in one process. `test run` establishes the identity-bearing
`UnboundRunLease (Harness projectId runId) brokerGeneration`, opens the one-use lifecycle profile, builds
config only through the restricted `ConfigAssembly` effect, validates it with the scope-correct
`ProjectCodec`, persists and verifies the plan snapshot, and fresh-binds the lease to that exact digest.
The generated-config bracket then retains all of those values while Command builds the opaque lifecycle
from direct common-interpreter calls. No root Harness authority is serialized, inferred from config, or
reconstructed by a child process.

Self-reference remains only for plan-declared recursive child-frame transitions. The Handoff facade now
implements the root-signed `AuthenticatedRootScope (Harness projectId runId)` primitive and verifies its
canonical wire with the independently installed project key before introducing a fresh run phantom. The
Harness lifecycle has not yet adopted that producer. The existing unchanged four-field Offer/Relay/Receiver
transport does carry and scope-first verify a capsule once its root producer supplies one: root links mint it
and nested links copy only the exact canonical bytes. In the target cross-process extension, the Harness root
signs it from the exact live generative evidence before received payload bytes can introduce that phantom,
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
owns the implemented generic authenticated root-scope primitive and the still-open scope-first receiver;
this Harness phase supplies the future live generative producer evidence. Recursive process adoption remains
with the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).

One one-use command/handoff identity opens exactly one versioned operation session only after clean
activation or abandoned-session recovery yields current-broker admission. Clean activation first proves
every recorded older-broker session Closed, including zero-operation sessions. Session open and close each advance the shared Open
project-journal version and return its sole successor state/permit pair; opening also rechecks that the
revision is not migration-frozen. Abandoned activation instead consumes the exact old-permit fence
set and verifies the manifest pairing the independent complete session set with its operation set. Its
protected interpreter CAS-rebinds each existing stable session record once—including a zero-operation
Open session—and classifies unknown, the five pre-call continuable phases, already-observed retryable,
successful, and terminal operation records. Initial intent registration and exact session membership are
one atomic session/project-journal version transition that consumes either the sole no-prior-generation
origin or an exact `FreshGeneration` reacquisition origin, so no orphan intent can be omitted from the
manifest and callers cannot choose the generation. An initial intent may have no fence record and cannot
prepare; recovery idempotently resumes the stable initial-fence protocol and threads its successor
session/state/permit before exposing current-fence authority. Only continuable phases receive
current-fence prepare authority, and only the closed retry
whitelist can receive fenced same-key authority. It withholds admission
until every operation is settled and every session is Closed, verifies the complete resource-record set,
and jointly yields fresh rehydrated resources while threading the sole successor state/permit pair.
Before every remote reservation/mutation/delete, the storeless executor sends a bounded next-node request
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
same proposed epoch; an old or delayed response is rejected or deduplicated. Terminal acknowledgment proves
every registered outcome settled, records the root-owned receipt, and compare-and-swaps the exact session
version Closed, so it cannot race another prepare. Loss before the signed response refuses; loss after its
durable Unknown leaves explicit recovery work. A later teardown invocation receives a **fresh** per-edge
token and session.
Before allocating a new test run, `recoverAbandonedHarnessRuns` enumerates incomplete unbound and bound
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
Production and Harness use disjoint authority/broker lease namespaces but contend on one project-wide
mode record. `verifyHarnessPreconditions` derives its total probe from the installed project identity;
`withHarnessRoot` rechecks it while acquiring Harness mode. Production therefore cannot slip between
precheck and ownership, and a Harness run cannot overlap a stopped Production stack whose mode is still
held. Production can release that mode only through a closed `ProductionClosureAuthorization`: exact
`ProjectDestroy` plus `DestroySettled` authorizes settled closure, while any exact Production verb can
close before its first effect only with `VerifiedNoProjectResourcesAcquired`. The final compare-and-swap
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
signer; `Teardown.Internal` receives no root broker or signing capability. In the target receiver path, the
child first verifies `AuthenticatedRootScope`, then the rooted binding, exact parent→child
`RecoveryProjectionBinding`, grant, `VerifiedRecoveryWire`, teardown-only fully indexed
`VerifiedRecoveryHandoff ... recoveryWireId verb`, and catalog frame coordinates before the storeless executor
accepts any teardown grant. The root-owned `TeardownForest` supplies the next `TeardownAuthorizationPoint`; no
forest cursor or store crosses the process boundary.

The recovered frame and matching ordinary-step resource evidence remains a root-held closed
owned-or-released sum arising only from the bound snapshot and complete rehydrated set. The owned branch can
produce a signed grant for the matching managed handle/receipt/resource/operation bindings. The released
branch yields only its verified tombstone, produces no backend-call grant, and requires a protected root-side
absence recheck plus a distinct new acquisition key before `FreshGeneration`. Its sole root-side consumer
creates the exact reacquisition origin and atomically revalidates it with the new generation and session
membership. Provider reachability can therefore precede retained-child teardown without trusting raw
persisted receipts, recreating the old normal config, or granting `ProjectUp` authority.

The current self-reference lift is used only by plan-declared child descent and streams the
context-adjusted full config record. The standalone authenticated root-scope and recovery-package primitives,
their Offer/Relay/Receiver adoption, and the bounded keyless rooted request/response route are implemented.
The generic Harness scope-capsule producer and the storeless executor remain incomplete. Complete
cross-process recursive scope therefore remains open even though the Harness root lifecycle itself is direct.
No child authority-store rehydration is part of the target.
The full child protocol is specified in
[lifecycle state model](lifecycle_state_model.md#cross-process-authority-handoff).

## Teardown

The current root command runs the verb's reverse projection of the one plan: current-frame cluster
cleanup plus the reverse each acquiring node declared.
It does not recursively dispatch `project down`/`project destroy` through the child frames before
unwinding. Deleting a provider VM can remove the nested compute incidentally, but that is not recursive
lifecycle interpretation and cannot establish that child cleanup ran.

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

The plan's preserved `.test_data/<runId>` root makes a same-run durability check conceptually possible,
but the current lifecycle cursor is terminal at `Teardown` and has no fresh invocation generation for a
second `up`. Consequently the configured `durable-readback` assertion performs no lifecycle command and
returns an honest `Fail`. Completion in the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) requires an engine-owned declarative two-phase
assertion: write, nonterminal settled destroy, allocate a fresh same-run lifecycle invocation, exact
forward interpretation, read, then a final settled destroy whose current-version evidence alone may
authorize terminal close. Adding raw lifecycle IO to `TestSuite` is not that protocol.

The recursive target still descends into each reachable child, tears it down, and only then stops or
deletes the parent. Independent failures are aggregated, and destructive actions consume ownership
receipts. The complete close/recovery algebra is described in
[lifecycle_state_model](lifecycle_state_model.md).

## Validation

The static authority suite already proves distinct stable run identities across successive Harness
acquisitions, sequential refusal after each Production/Harness profile slot is consumed, and same-slot
two-thread races in which exactly one continuation runs. Public compile-fail fixtures pin constructor
sealing, nominal run/mode indices, cross-run and cross-scope refusal, exact snapshot/digest binding, and
the complete Production/Harness profile evidence sets. Harness/CLI tests also pin exact plan retention,
forward→assertion→reverse ordering, generated-config lifetime, settled-evidence-required close, and the
private lifecycle component's absence from the public library. A source guard rejects lifecycle-owned
`project up`/`project destroy` invocation from the demo assertion suite. The remaining workflow gates are:

- A command-level test proves an off-root invocation is refused before reading or writing lifecycle
  state.
- A `<project>.test.dhall` schema test proves the documented resource field is exactly the decoded field;
  matrix tests prove typed selection has one source of truth.
- The demo gate records the config-derived profile/name/path and asserts `Harness projectId runId`, a
  run-scoped name, and `.test_data`; the worked-demo gate additionally proves exact plan-owned projection.
- An IO tripwire fails the run on any access below `.data` or to the production cluster identity.
- Fault injection proves teardown removes only resources for which the run holds ownership receipts.
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
- Cross-profile races prove Harness preconditions are rechecked in the same project-mode acquisition,
  Production cannot open during Harness, Harness cannot open while Production remains active or stopped,
  and the exact mode epoch is released last. Production closure fixtures prove settled release is
  destroy-only, true-pre-effect release is available to the exact invoking verb, and partial work
  inhabits neither authorization. A session-open/finalizer race has one winner, and kill/restart around
  the Production finalizer observes either the complete Open tuple or the atomic
  `ClosedProject`/closed-lease/released-mode tuple.
- The engine-owned same-run lifecycle generation drives the configured durable write→destroy→up→read
  assertion and the live matrix reports every row passing.

Phase status and live-run closure belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md), not this workflow page.

## Related

- [durable state](durable_state.md) — the preserved run root and remaining destroy/up/readback proof.
- [lifecycle state model](lifecycle_state_model.md) — capability and ownership target.
- [testing](../engineering/testing.md) — fast unit-suite entry points and long demo-gate scope.
- [composition methodology](composition_methodology.md) — the project chain the harness drives.
