# Harness Workflow

**Status**: Authoritative source
**Supersedes**: the claim that `test run` is root-gated and the demo live path uses `.test_data`
**Referenced by**: [documents index](../README.md), [composition methodology](composition_methodology.md), [testing](../engineering/testing.md), [durable state](durable_state.md), [lifecycle state model](lifecycle_state_model.md)

> **Purpose**: Describe the implemented test runner honestly, including the command gate, the actual
> `<project>.test.dhall` shape, and the demo's production-profile defect.

## TL;DR

The runner supports `test init` and compiled case selection, but the parser does not enforce the
documented root gate and the demo currently builds its live cluster with the Production profile and
`.data`. The target gives each run sealed harness authority, one source of truth for cases, resource-
indexed ownership receipts, and verified isolation from all production identities.

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
real bring-up/assert/teardown seams and unlinks the config only when its bound kernel identity **and**
its recorded payload still match. A found config is refused before any mutation, an edited or replaced
one is a structured conflict that is left intact, and an abandoned run's config is reclaimed by the
next run's sweep from the same durable record.

The command description calls this a root-only surface, but the parser does not apply a binary-context
root gate to either subcommand. `test run` deliberately does not load a pre-existing project config,
because it generates one. Root authority therefore depends on harness safety checks and invocation
location rather than an unforgeable context capability. That mismatch is open.

## What `<project>.test.dhall` means today

For the demo, the decoded type is now:

```haskell
newtype TestConfig = TestConfig { testResources :: Resources }
```

The executable `Case` registry is compiled into Haskell with opaque, validated `CaseId` values. The
command parser turns `<case-id>|all` into a typed selector; `all` is not stored in config. `TestCfg`
projects the decoded `tcfg` plus that executable registry into an opaque `TestMatrix`. The demo still
declares its two message variants in Haskell until Phase 20 moves that concrete mapping into config, but
their stable `VariantId`s and complete case-to-variant relation are validated before any mutation.

Accordingly, `<project>.test.dhall` is currently only a resource override. It is not a general DSL
containing case bodies, fixtures, secrets, or arbitrary variants. Documentation and help should not
call it those things.

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
matrix/variant drafts, the target opens a fresh rank-2 `Harness projectId runId` and authoritative lease
for each
distinct config variant, assembles only `cfg (Harness projectId runId)`, and runs every selected case mapped to
that variant against its one stack. The next variant cannot begin until the prior lease is closed; an
unresolved cleanup enters recovery/operator-resolution instead of reusing the same cluster/data root
under another config revision.

## Runner and ownership

The reusable engine aggregates `CaseResult`s into a `Report` and supports more than one generated config
variant. Reports use stable `VariantId`s, not assertion values masquerading as labels. Successful
bring-up puts assertions under a guaranteed teardown, and a caught non-`SafetyRefusal` bring-up failure
runs the same teardown. A caught `SafetyRefusal` takes the direct no-teardown branch described below,
because a refusal proven to precede acquisition has an empty rollback set; a hard kill also bypasses the
handler. Durable recovery is target work. The demo currently generates two message variants and runs the
compiled cases for each.

Non-passing outcomes are **distinct**, not one flattened failure string. `Fail` is the project's own
assertion verdict; `Refused`, `LifecycleFailed`, and `TeardownFailed` are the engine's classifications
and have no project-side constructor, so an assertion cannot label itself a refusal. The report card
prints a distinct label per outcome (`PASS`/`FAIL`/`REFUSED`/`BROKEN`/`LEAKED?`), and
`caseResultPassed`/`caseResultLabel`/`caseResultReason` are total, so a new outcome cannot be silently
counted as success. A failed teardown adds its own row rather than overwriting the case results: the
variant goes red with the cause named while "the assertions passed but the stack did not come down"
stays legible. The `Conflict` and `Unsupported` rows the target also names have no producer until the
reconcilers are wired at their call sites, so they are not yet constructors.

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
record and the identity binding resolves without adopting bytes the record does not name. That ordering
is also why the "a production config already exists" refusal now lives *after* the abandoned-run sweep:
derived from installed project identity inside the protected transaction that takes the mode, it is the
sole copy. The two earlier pre-sweep copies made an interrupted run's own config refuse the next run
before recovery could resolve it, so the recovery machinery was unreachable in exactly the case it was
built for.

Most other lifecycle resources still return `IO ()`, and the runner does not receive opaque ownership
receipts for the VM, cluster, alias, or daemon. The transitions that consume a satisfying receipt are in
[lifecycle_state_model](lifecycle_state_model.md).

Some current safety checks are late. VM bring-up can run provider ensure, create the durable path, and
perform host preflight before its managed-VM refusal; the direct lane can run Docker ensure before its
cluster refusal. The harness treats `SafetyRefusal` as “skip teardown,” so those preparatory effects can
remain. The target classifies a true pre-effect refusal separately from post-acquisition conflict/failure
and rolls back every journaled owned preparation.

Execution shape is not selected by the harness. Sprint 10.10 removed the detached selector and all
definition/test-only one-shot, budget-slicing, prefix/profile helpers that had no lifecycle-plan
consumer. The harness drives the real `project up` plan and retains only its live matrix loop,
reporting, safety probes, and self-created-data bracket.

## Current production-state defect

The harness owns a self-created-only `.test_data` bracket, but the demo live bring-up does not currently
project that root or a harness-scoped cluster profile into its lifecycle plan:

- demo case setup invokes the real `project up`;
- demo cluster plan resolution hardcodes `Production`;
- durable setup creates `<project-root>/.data`;
- project-container and kind/nvkind mounts carry that production path.

Thus “tests always use `.test_data` and never touch `.data`” is false for the current demo. The
production-cluster precondition is valuable but does not make a Production-profile test deployment
test-scoped; it merely refuses one known collision before creating another production-named stack.

Until this is fixed, run the long demo gate only on a disposable host with no production demo state.

## Target safety contract

`test run` must acquire a sealed root-harness capability before any mutation and then prove:

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

The test config/profile should be explicit in the typed inputs to plan construction. A caller should not
be able to generate a test config and then silently obtain a `Production` `ClusterPlan`.

Concretely, the target harness mints an opaque `HarnessAuthority projectId runId`, constructs
`ProjectPlan (Harness projectId runId) specDigest planId configId cfg` from the matching
profile/config/draft, and obtains its
`ClusterPlan` only through that plan's `containerPlan` projection. Only an independently authorized
production root invocation can construct a Production plan. The harness plan derives
`.test_data/<runId>` and the run-scoped cluster identity together;
there are no independent profile, path, or name arguments that can disagree. See
[lifecycle state model](lifecycle_state_model.md#lifecycle-profile-authority).

### Self-invocation without serializing authority

Driving the real `project up` crosses a process boundary, so the target cannot simply pass the
non-serializable `HarnessAuthority projectId runId` as a Haskell value. Nor may it infer authority from the
generated config. Before launch, `test run` establishes an identity-bearing
`UnboundRunLease (Harness projectId runId) brokerGeneration` in its protected root authority broker,
builds config only through the read-only `ConfigAssembly` effect, validates it with the scope-correct
`ProjectCodec`, persists and verifies the plan snapshot, binds the lease to that exact digest, and only
then mints a one-time
token bound to the exact scope, plan revision, broker generation, edge, child config digest, verb, and
phase. The offer travels over a private duplex lift session, never through Dhall, `argv`, an environment
variable, or a durable config file. If assembly/codec/plan validation fails before binding, the bracket
can close the unbound lease only after protected proof that no token, permit, journal, or effect exists;
a crash leaves an explicit unbound incomplete lease rather than an invented plan digest.

The child binary's internal receiver—not a shell config writer—returns a fresh challenge. The root
broker verifies every binding, consumes the nonce, and signs the challenge. Grant plus byte verification
through the scope-correct project-owned `ProjectCodec` jointly creates the generic
`VerifiedConfigWire` under a fresh child `configId`, the exact
`VerifiedHandoff ... ConfigHandoff childConfigId verb phase`, and `ValidatedConfig`.
Those values are not command authority. `withChildProjectPlan` consumes them with the closed verb and
non-empty plan draft, verifies the stable revision, and jointly yields the fresh local `ProjectPlan`,
`PlanDigestBinding`, and exact `ChildPlanAuthority` inside a rank-2 continuation. Only
`authorizeChildProject` consumes that narrow authority. The child never reuses its parent's exact-byte
identity or receives root/harness-root/signing authority.

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
Before every child
reservation/mutation/delete, the child sends a prepare request naming its exact broker/authority epoch,
verb/phase/frame, session, operation key, journal version, and current authoritative fence. One protected
compare-and-swap revalidates the project-wide Harness mode, bound lease, active plan revision,
Open-project state, command/session/fence, and operation record. It consumes the exact plan-owned closed
precondition set, reruns every target/dependency probe and version, and obtains conditional backend
versions; stale/replaced/not-ready evidence returns no permit. It records the operation-specific unknown
journal state—including adoption transfer and adopted release—before jointly returning the only
`PreparedOperation`/`PreparedPreconditions` pair an adapter accepts and the fresh-versioned successor Open-session,
Open-project operation state, and revision-permit authority. The consumed journal version cannot
authorize another prepare or close; retained `Ready`/prerequisite values are not adapter inputs. Every
adapter terminal observation returns `OperationAdvance` on
success or typed failure; its eliminator yields the result only with the sole successor Open-project
state/revision-permit pair. Initial fence creation and crash-time fence rotation persist/resume the same
proposed epoch and return the sole successor session/state/permit pair; an old or delayed child permit is
rejected or deduplicated. Terminal acknowledgment first proves every registered
outcome settled and then compare-and-swaps the exact session version Closed, so it cannot race another
prepare. Loss before permit refuses; loss after permit leaves an explicit unknown state that recovery
reprobes. A later teardown invocation receives a **fresh** per-edge token and session.
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

If recovery crosses another child boundary after the old config was edited or removed, the bound
snapshot derives a signed non-secret recovery wire. The child accepts it only with the exact
parent→child `RecoveryProjectionBinding`, `VerifiedRecoveryWire`, teardown-only
`VerifiedHandoff ... RecoveryHandoff recoveryWireId verb TeardownPhase`, recovered frame, and the next
closed `TeardownAuthorizationPoint` produced only by the forest. Its private branches contain either the
ordinary settled-child/cursor pair or the destroy-only pre-descent step. The recovered frame and matching
ordinary-step resource evidence is a closed owned-or-released sum arising only from the bound snapshot
plus its complete rehydrated set and that exact point/step. The owned branch yields the matching managed
handle/receipt/resource/operation bindings; the released branch yields only its verified tombstone and
bindings, receives no backend-call authority, and needs a protected absence recheck plus a distinct new
acquisition key before `FreshGeneration`. That token grants only eligibility; its sole consumer creates
the exact reacquisition origin, which intent registration revalidates/consumes atomically with the new
generation and session membership. Provider reachability is therefore authorizable before retained
children without weakening their later stop/delete ordering or trusting raw persisted receipts. It does
not recreate the old normal config or gain `ProjectUp` authority.

The current self-reference lift streams only the context-adjusted full config record. It has no authenticated
authority-rehydration protocol, so the current runner's real-command reuse proves shared forward
orchestration, not sealed cross-process scope. The full protocol is specified in
[lifecycle state model](lifecycle_state_model.md#cross-process-authority-handoff).

## Teardown

The current root command runs the verb's reverse projection of the one plan: current-frame cluster
cleanup plus the reverse each acquiring node declared.
It does not recursively dispatch `project down`/`project destroy` through the child frames before
unwinding. Deleting a provider VM can remove the nested compute incidentally, but that is not recursive
lifecycle interpretation and cannot establish that child cleanup ran.

The target descends into the reachable child, tears it down, and only then stops or deletes the parent.
Independent failures are aggregated, and destructive actions consume ownership receipts. Ordinary
`project down` and `project destroy` preserve the plan's durable root, including during a destroy→up
assertion in one variant. After assertions, either a settled destroy or a verified true pre-effect
refusal can produce closure evidence. The sole `verifyDestroySettled` verifier checks the complete
plan-derived destroy forest, terminal release observations, protected journal, and lack of unresolved
nodes/live prepared operations; the sole `verifyNoProjectResourcesAcquired` verifier checks that no
resource operation/permit/fence/receipt/effect record exists and every registered session is Closed and
empty. Their closed conversions are the only producers of `ProjectClosureEvidence`; unresolved partial
ownership produces neither. The harness
combines that proof with the project-wide mode lease, bound run lease/snapshot, exact versioned Open
state, and `HarnessCloseRoot`, derived from the live root or exact abandoned-run recovery authority.
`authorizeHarnessClose` verifies all ordinary sessions Closed and atomically changes Open to a fresh
Closing epoch while creating the close journal; a concurrent prepare and close cannot both win. The same
plan's terminal close projection releases only that run's owned generated config and
`.test_data/<runId>` generations through close-specific durable unknown/reprobe/fence permits. Each
terminal close observation returns `HarnessCloseAdvance` on success or typed failure; its eliminator
yields the only successor close journal. After all close outcomes settle, one finalizer atomically
records `ClosedProject`, closes the bound lease, and releases Harness mode last. A kill after the close
CAS or any close effect reopens that exact Closing epoch; it cannot remint Open or permission to start
another ID. See
[lifecycle_state_model](lifecycle_state_model.md).

## Validation

- A command-level test proves an off-root invocation is refused before reading or writing lifecycle
  state.
- A `<project>.test.dhall` schema test proves the documented resource field is exactly the decoded field;
  matrix tests prove typed selection has one source of truth.
- The demo gate records the resolved profile/name/path and asserts `Harness projectId runId`, a run-scoped name, and
  `.test_data`.
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

Phase status and live-run closure belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md), not this workflow page.

## Related

- [durable state](durable_state.md) — why the current demo test path reaches `.data`.
- [lifecycle state model](lifecycle_state_model.md) — capability and ownership target.
- [testing](../engineering/testing.md) — fast unit-suite entry points and long demo-gate scope.
- [composition methodology](composition_methodology.md) — the project chain the harness drives.
