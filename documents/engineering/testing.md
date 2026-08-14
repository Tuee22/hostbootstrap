# Testing

**Status**: Authoritative source
**Supersedes**: the root-gated suite-selector and isolated-`.test_data` descriptions
**Referenced by**: [documents index](../README.md), [harness workflow](../architecture/harness_workflow.md), [cluster lifecycle](cluster_lifecycle.md), [demo runbook](../operations/demo_runbook.md)

> **Purpose**: Define the supported fast test entry points and describe the exact-plan demo lifecycle
> harness, including its command gate, assertion boundary, ownership, and remaining live-validation gaps.

## TL;DR

- Run Python tests from the repository root with
  `poetry run python -m hostbootstrap.test_all`; do not invoke `pytest` directly.
- Run Haskell suites from their Cabal project roots with `cabal test all`. The complete Haskell
  quality gate also includes formatter, linter, and warnings-as-errors build checks.
- The demo command is `test init` followed by `test run <case-id>|all`. Cases are compiled Haskell with
  validated `CaseId`s; the current `<project>.test.dhall` contains resource overrides and declarative
  variants, not case bodies or lifecycle actions.
- Help calls the test surface root-only, but the parser does not enforce a binary-context root gate.
- Each variant owns a generated config and one exact Harness-scoped `ProjectPlan`; the command drives its
  common forward/reverse interpreters directly. The five-field `TestSuite` contains assertions and no
  lifecycle callback.
- `durable-readback` is deliberately non-passing until the engine owns the fresh same-run lifecycle
  invocation needed for write → destroy → up → read.

## Current Status

The reusable engine runs a compiled, five-field `TestSuite` and aggregates `CaseResult`s into a report.
Those fields are the safety precondition, assertion-environment opener, case matrix, per-case assertion,
and post-reverse absence assertion. For each variant, `HostBootstrap.Command` retains one exact
Harness-scoped plan and supplies an opaque `HarnessLifecycle`; the engine invokes its forward action,
opens the assertion environment, runs the selected cases, invokes its reverse action, and finally runs the
absence assertion. A non-refusal bring-up failure still enters the same reverse path. Only a refusal that
the command independently verifies preceded project-resource acquisition becomes `SafetyRefusal` and
skips reverse; a late refusal is classified as refused but still tears down. The demo generates two
project-config variants with different messages and runs the selected compiled cases against each.

The [test-harness-and-run-ownership
phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md) owns both this assertion engine and
the Harness command consumer that supplies its opaque lifecycle. The shared exact-plan/Chain foundation
remains owned by the
[step-algebra-and-project-plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md).
Production and Harness enter the lower Chain only through the Cabal-private fixed root-Up `LifecycleEntry`;
the [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) owns
the root-coordinated extension across child frames.

The lifecycle constructor is not a consumer surface. `HostBootstrap.Harness.Lifecycle.Internal` lives in
the private `harness-lifecycle-internal` Cabal component. The main library uses it at the command boundary,
and `HarnessSpec` depends on the same private component for controlled ordering/failure fixtures;
downstream packages cannot construct a second lifecycle package.

The run's generated project config is owned rather than merely guarded: it is published create-if-absent
inside the protected store's exclusive entry, after a durable record naming the intended payload, and
bound to the created file's own kernel identity — the four
[ownership_invariant](../architecture/ownership_invariant.md) clauses, the same ones the run's
`.test_data` generation holds. Cleanup unlinks it only when both that identity and the payload still
match, so a non-cooperating writer is detected rather than clobbered, and an abandoned run's config is
reclaimed by the next run's sweep instead of blocking it. A precondition also refuses a known running
production cluster. These checks still do not provide complete transaction ownership: provider VMs,
aliases, clusters, ports, and daemons do not uniformly return opaque ownership receipts, teardown is not
recursive, and the demo's exact same-run destroy/up/readback assertion still lacks an engine-owned
lifecycle-invocation generation. The direct Harness plan boundary itself no longer opens Production
authority.

### Out-of-process races

Cross-process ownership exclusion is a property of a durable record contended by real competitors, so the
cases that prove that boundary run in **separate processes** rather than separate threads. Most probes
re-invoke the test executable with an
argument that `test/Spec.hs` dispatches before the suite runs. The command-reservation case instead forks
only after the parent holds the opaque root/plan values, allowing two processes to present the exact same
non-serializable reservation without adding a raw epoch reopener for the sake of a test. A probe's only
report is its own outcome — an exit code plus, where the distinction matters, the name it was refused by.
None of them exports a read-only observer of the holder's state, which is what
[ownership_invariant](../architecture/ownership_invariant.md) rules out.

| Probe | What it contends on | Reports |
|---|---|---|
| `--hostbootstrap-protected-entry-probe` | the store's exclusive entry (a real kernel lock) | acquired / contended |
| `--hostbootstrap-harness-acquire-probe` | a whole harness run reservation, held long enough to overlap every competitor | acquired / refused, with the reason |
| `--hostbootstrap-harness-abandon-probe` | a run plus its installed generated config, then blocks so the parent can hard-kill it | readiness only; only a real kill leaves the state the sweep resolves |
| `--hostbootstrap-mode-profile-probe` | the project-wide **mode** record, from the other lifecycle profile | acquired / refused, with the held mode's name |
| `--hostbootstrap-fence-delay-probe` | the plan's **fence** record: it takes the generation token, releases the store while the parent rotates, then presents the delayed token | accepted, with the fence it prepared under / refused as superseded, with the presented and live epochs |
| POSIX forked command-reservation contender | the canonical installed-project/store/plan/frame/epoch/verb/phase reservation retained from one root | exactly one reserved / exactly one already consumed |

The mode probe is the cross-*profile* half. The composite root brackets take the mode inside one exclusive
entry and then release the entry, so a holder's body runs with the entry free; what a competitor reaches is
the mode compare-and-swap, and it is refused there by name — `production` against a live Production
invocation, `harness:<runId>` against a live run.

The fence probe is the delayed-permit half. It runs in **two entries** with the store free between them,
which is what makes the generation boundary real: the parent rotates the fence in an ordinary protected
transaction while the competitor holds nothing, and the competitor then presents a token issued before that
rotation. Both outcomes the protocol distinguishes are covered — a delayed *prepare* is refused as
superseded, naming the presented and live epochs, while a delayed *initial-fence proposal* is deduplicated
to the observed epoch instead of opening a second generation.

Every refusal case has a control that runs the same probe with nothing to be refused by — an empty store
for the mode probe, an uncrossed boundary for the fence probe — and requires it to *succeed*, so a refusal
exit code cannot be satisfied vacuously.

### Authority-kernel evidence

`AuthoritySpec` exercises the lower authority boundary against real protected stores. It verifies the
executable-path identity match and `.exe` normalization, rejects invalid or non-ASCII stable names,
performs an actual create/remove write probe in the exact records directory for OS-principal evidence,
and checks that evidence and roots remain bound to one durable store. Broker counters advance
monotonically and malformed or exhausted encodings refuse rather than reuse a generation. Root scope,
verb, project, store, and epoch remain opaque and nominal.

Reservation cases cover replay, concurrent protected entries, the POSIX cross-process one-winner race,
and every stable key coordinate reachable through the current lifecycle adapter: project/store, plan
digest, frame key, broker epoch, verb, and phase. The record key is a SHA-256 digest of a canonical
length-prefixed encoding, while the stored full encoding detects a key collision rather than treating a
different invocation as consumed.

The compile-fail suite pins one contiguous GHC diagnostic for constructor forgery, rank-2 identity
escape, nominal-role coercion, cross-scope/plan/frame substitution, public raw-opener absence, and hidden
kernel import. A source-surface guard keeps the kernel free of configuration and reconciliation imports
and allow-lists its package-internal consumers. These checks prove only the lower vocabulary and atomic
primitive; proof-complete plan/lease/frame/cursor/context admission is owned by the later lifecycle
command gates.

### Lifecycle mode and profile evidence

`AuthoritySpec` separately exercises the protected lifecycle-mode boundary. Successive Harness root
acquisitions must expose distinct diagnostic run identities, while every typed value inside one
continuation retains that acquisition's nominal `runId`. Production and Harness acquisitions contend on
one project-wide mode record, and exact-mode narrowing preserves the originating broker epoch.

The profile-slot race is intentionally a two-thread same-process test: both workers retain the *same*
otherwise-valid root/mode/lease evidence and call the same Production or Harness opener concurrently.
Exactly one callback enters, while the other observes the protected slot as consumed. A sequential replay
test proves the same durable result without scheduling, and the callback runs only after the
compare-and-swap releases the protected-store lock.

The public compile-fail registry complements those runtime races. It pins opaque mode, lease, run, active
mode, snapshot, and profile constructors; nominal-role coercion refusal; cross-Production/Harness and
cross-run substitution; cross-digest lease binding; and wrong-root/wrong-broker profile evidence. Each
fixture matches the intended contiguous GHC diagnostic so an unrelated compile error cannot satisfy the
boundary. The dated full-suite and compile-fail totals live only in
[the lifecycle-modes-and-run-leases phase](../../DEVELOPMENT_PLAN/phase-9-lifecycle-modes-and-run-leases.md),
as required by the development-plan evidence rule.

Delivery status, exact test totals, dated hardware evidence, and phase closure belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Supported Fast Test Entries

From the repository root:

```text
poetry run python -m hostbootstrap.test_all
```

`hostbootstrap.test_all` sets the required sentinel and invokes `pytest tests` in-process. Pytest
selectors may be forwarded after the module name. Direct `pytest` invocation is intentionally rejected
by `tests/conftest.py`.

From `core/`:

```text
cabal test all
```

From `demo/`, for its Cabal test suite:

```text
cabal test all
```

This is the supported entry point. `hostbootstrap-demo-test` is built with `-threaded -rtsopts
"-with-rtsopts=-N"`, matching the executable because `WebServerSpec` starts Warp. The suite includes a
Cabal-stanza assertion so removing that runtime contract fails the same canonical command.

These static suites validate pure plans, argv builders, schema round trips, exact Harness lifecycle
ordering, private-constructor/public-surface separation, generated-config lifetime, closure-evidence gates,
and many failure branches. They cannot substitute for native provider, recursive teardown, or durable
readback gates.

## Demo Command Surface

```text
<project> test init
<project> test run <case-id>
<project> test run all
```

`test init` requires no production `<project>.dhall`; it writes the executable-sibling
`<project>.test.dhall`. `test run` reads that file, validates the project-owned typed matrix projection,
owns and writes each selected variant's generated `<project>.dhall`, admits one exact Harness plan, drives
the common forward interpreter, runs compiled assertions, and drives that plan's reverse projection.
Terminal close is not inferred from a successful callback: the command must produce settled-destroy
`ProjectClosureEvidence`, `authorizeHarnessClose` must accept it, and the private ownership state machine
must record the pending and settled handoff before the finalizer can consume the close authorization.

The selector names a compiled **case id**, not a dynamically defined suite. In the demo:

```haskell
data TestVariantConfig = TestVariantConfig { variantName :: Text, variantMessage :: Text }
data TestConfig = TestConfig { testResources :: Resources, testVariants :: [TestVariantConfig] }
```

`demoCases` is the executable source of truth for the **case** set. The **variant** set is a projection of
decoded configuration: `demoTestMatrix` reads `testVariants` and validates each declared name into a
`VariantId`, so adding, renaming, or removing a variant is an edit to the generated
`<project>.test.dhall` rather than to a Haskell module. Both registries are then validated into one total
relation: both non-empty and unique, every case has exactly one non-empty row, every reference exists, and
every variant is used. Construction also rejects duplicate rows/pairs and unknown/orphan references. A
declaration that is empty, duplicated, or not a valid identity is refused while the matrix is being built —
`EmptyVariantRegistry`, `DuplicateVariantIds`, and `InvalidVariantDeclaration` respectively — which is
before the run acquires anything. Selection, generation, and reporting consume that relation.

## Current Safety Defects

The following statements are false for the current implementation:

- “The parser root-gates `test init` and `test run`.” It does not apply the context root gate.
- “A harness run touches no host state at all.” Its config-derived `RunProfile` selects a distinct cluster
  name, removable state, host-port publication, and `.test_data/<run>` root, but consumers still receive
  those as independent terms rather than as one exact plan projection. The
  [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns that exact-plan adoption. The run
  still brings up real provider VMs, Docker state, and clusters on the host, which is why a disposable host
  remains the supported way to run the long gate.
- “A passing harness run proves resources are owned.” The run's `.test_data` root **is** owned under all
  four [ownership_invariant](../architecture/ownership_invariant.md) clauses — kernel-identity binding and
  identity-conditional release included — but most other lifecycle mutations still return `IO ()`, and
  neither the data root nor generated-file ownership establishes VM/cluster/alias/daemon ownership.
- “Teardown recursively visits every child.” The current command performs current-frame cluster cleanup
  plus the reverse effects the plan's own nodes declare.
- “The five configured cases currently pass.” `durable-readback` intentionally returns `Fail` because
  project assertion code is not allowed to run lifecycle commands and the engine does not yet provide a
  same-run destroy/up invocation transition.

The long demo suite mutates real provider, Docker, and cluster state. Run it only on a disposable machine
with no production demo state until the remaining ownership and recursive-lifecycle gates close.

## Remaining Transaction Work

The harness already obtains opaque `HarnessAuthority projectId runId`, active Harness mode, and the exact
unbound run lease. Only
[the lifecycle-modes-and-run-leases phase](../../DEVELOPMENT_PLAN/phase-9-lifecycle-modes-and-run-leases.md)'s
implemented protected profile opener can combine those matching values into
`LifecycleProfile (Harness projectId runId)`; the authority alone cannot construct it. Plan construction
derives a run-scoped cluster identity and `.test_data/<runId>` together, and Command retains that exact
plan through common forward/reverse interpretation. Remaining resource work requires every mutation to seal its
plan-internally traversed edge set and fresh resource-indexed probe observations into a plan-owned
precondition set; only the fresh prepared
operation/preconditions pair can enter the adapter, which returns an explicit reconcile result with an
owned receipt or foreign observation. Cleanup accepts only verified receipts
and walks child-to-parent while each child remains reachable.

The durable-readback program also needs an engine-owned two-phase assertion form and a protected fresh
lifecycle-invocation generation under the same run, config, durable root, and plan. The intermediate
destroy must be settled but nonterminal, the next exact `up` must use the fresh generation, and only the
final destroy's current-version evidence may authorize terminal Harness close. No lifecycle action enters
`TestSuite` to implement that choreography.

The full algebra, including the limits of non-linear Haskell values and cross-process receipt
rehydration, is canonical in
[lifecycle state model](../architecture/lifecycle_state_model.md).

## Required Live Gates

1. An off-root command is refused before any lifecycle read or mutation.
2. The documented `<project>.test.dhall` schema and selector have one source of truth.
3. Instrumented demo bring-up records the exact Harness plan/profile, run-scoped name, and
   `.test_data/<runId>` path, with an IO tripwire on `.data` and the production cluster.
4. Concurrent runs prove exclusive ownership; fault injection proves only matching owned resources are
   rolled back.
5. `down` and `destroy` visit all child frames before stopping or deleting the parent.
6. The engine allocates a fresh same-run lifecycle invocation, a workload writes durable bytes, the full
   stack is destroyed and recreated, and both host and pod read the same bytes before the final settled
   destroy closes the run.

## Related

- [harness workflow](../architecture/harness_workflow.md) — command/DSL/profile contract.
- [durable state](../architecture/durable_state.md) — `.data` carry and readback gap.
- [readiness](../architecture/readiness.md) — delivered opaque witness foundation and remaining live-effect integration.
- [demo runbook](../operations/demo_runbook.md) — operator-facing demo commands and cautions.
