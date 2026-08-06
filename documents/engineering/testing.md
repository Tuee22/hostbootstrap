# Testing

**Status**: Authoritative source
**Supersedes**: the root-gated suite-selector and isolated-`.test_data` descriptions
**Referenced by**: [documents index](../README.md), [harness workflow](../architecture/harness_workflow.md), [cluster lifecycle](cluster_lifecycle.md), [demo runbook](../operations/demo_runbook.md)

> **Purpose**: Define the supported fast test entry points and describe the demo lifecycle harness
> honestly, including its command-gate, test-config, profile, ownership, and live-validation gaps.

## TL;DR

- Run Python tests from the repository root with
  `poetry run python -m hostbootstrap.test_all`; do not invoke `pytest` directly.
- Run Haskell suites from their Cabal project roots with `cabal test all`. The complete Haskell
  quality gate also includes formatter, linter, and warnings-as-errors build checks.
- The demo command is `test init` followed by `test run <case-id>|all`. Cases are compiled Haskell with
  validated `CaseId`s; the current `<project>.test.dhall` contains resource overrides, not case bodies.
- Help calls the test surface root-only, but the parser does not enforce a binary-context root gate.
- The demo live planner currently selects `Production` and `.data`. Do not describe the current long
  demo gate as isolated from production state.

## Current Status

The reusable engine runs a compiled `TestSuite` and aggregates `CaseResult`s into a report. After
successful bring-up, assertions run under `finally`; a caught non-`SafetyRefusal` bring-up failure also
runs teardown under `finally`. A caught `SafetyRefusal` returns a failed variant directly and skips
teardown, even though preparatory effects may already have occurred. A hard kill also does not run the
handler; durable incomplete-run recovery and receipt-driven cleanup are target work. The demo generates
two project-config variants with different messages and runs the selected compiled cases against each.

The run's generated project config is owned rather than merely guarded: it is published create-if-absent
inside the protected store's exclusive entry, after a durable record naming the intended payload, and
bound to the created file's own kernel identity — the four
[ownership_invariant](../architecture/ownership_invariant.md) clauses, the same ones the run's
`.test_data` generation holds. Cleanup unlinks it only when both that identity and the payload still
match, so a non-cooperating writer is detected rather than clobbered, and an abandoned run's config is
reclaimed by the next run's sweep instead of blocking it. A precondition also refuses a known running
production cluster. These checks still do not provide complete transaction ownership: provider VMs,
aliases, clusters, ports, and daemons do not uniformly return opaque ownership receipts, teardown is not
recursive, and the demo itself resolves the live cluster with the Production profile.

### Out-of-process races

Exclusion is a property of a durable record contended by real competitors, so the cases that prove it run
in **separate processes** rather than separate threads. The test executable re-invokes itself with a probe
argument that `test/Spec.hs` dispatches before the suite runs, and a probe's only report is its own
outcome — an exit code plus, where the distinction matters, the name it was refused by. None of them
exports a read-only observer of the holder's state, which is what
[ownership_invariant](../architecture/ownership_invariant.md) rules out.

| Probe | What it contends on | Reports |
|---|---|---|
| `--hostbootstrap-protected-entry-probe` | the store's exclusive entry (a real kernel lock) | acquired / contended |
| `--hostbootstrap-harness-acquire-probe` | a whole harness run reservation, held long enough to overlap every competitor | acquired / refused, with the reason |
| `--hostbootstrap-harness-abandon-probe` | a run plus its installed generated config, then blocks so the parent can hard-kill it | readiness only; only a real kill leaves the state the sweep resolves |
| `--hostbootstrap-mode-profile-probe` | the project-wide **mode** record, from the other lifecycle profile | acquired / refused, with the held mode's name |
| `--hostbootstrap-fence-delay-probe` | the plan's **fence** record: it takes the generation token, releases the store while the parent rotates, then presents the delayed token | accepted, with the fence it prepared under / refused as superseded, with the presented and live epochs |

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

These static suites validate pure plans, argv builders, schema round trips, harness mechanics, and many
failure branches. They cannot substitute for native provider, recursive teardown, production-isolation,
or durable readback gates.

## Demo Command Surface

```text
<project> test init
<project> test run <case-id>
<project> test run all
```

`test init` requires no production `<project>.dhall`; it writes the executable-sibling
`<project>.test.dhall`. `test run` reads that file, validates the project-owned typed matrix projection,
drives the real `project up`, runs compiled case assertions, and invokes `project destroy`.

The selector names a compiled **case id**, not a dynamically defined suite. In the demo:

```haskell
newtype TestConfig = TestConfig { testResources :: Resources }
```

`demoCases` is the executable source of truth. Its opaque `CaseId`s and the demo's stable `VariantId`
drafts are validated into one total relation: both registries are non-empty and unique, every case has
exactly one non-empty row, every reference exists, and every variant is used. Construction also rejects
duplicate rows/pairs and unknown/orphan references. Selection, generation, and reporting consume that
relation. The remaining Phase 20 work is to move the demo's concrete hard-coded two-message mapping into
typed test config; the generic core no longer carries an unchecked suite-name or string-label list.

## Current Safety Defects

The following statements are false for the current implementation:

- “The parser root-gates `test init` and `test run`.” It does not apply the context root gate.
- “The demo always uses `TestCase`/`.test_data/<caseId>`.” Its `containerPlan` call selects `Production`, so its real
  provider, cluster, and mounts use `.data` and the production cluster identity.
- “A passing harness run proves resources are owned.” The run's `.test_data` root **is** owned under all
  four [ownership_invariant](../architecture/ownership_invariant.md) clauses — kernel-identity binding and
  identity-conditional release included — but most other lifecycle mutations still return `IO ()`, and
  neither the data root nor generated-file ownership establishes VM/cluster/alias/daemon ownership.
- “Teardown recursively visits every child.” The current command performs current-frame cluster cleanup
  plus the reverse effects the plan's own nodes declare.

Until profile isolation is implemented and live-gated, run the long demo suite only on a disposable
machine with no production demo state.

## Target Transaction

The target harness obtains opaque `HarnessAuthority projectId runId`, active Harness mode, and the exact
unbound run lease. Only Phase 10's protected profile opener can combine those matching values into
`LifecycleProfile (Harness projectId runId)`; the authority alone cannot construct it. Plan construction
derives a run-scoped cluster identity and `.test_data/<runId>` together. Every mutation first seals its
plan-internally traversed edge set and fresh resource-indexed probe observations into a plan-owned
precondition set; only the fresh prepared
operation/preconditions pair can enter the adapter, which returns an explicit reconcile result with an
owned receipt or foreign observation. Cleanup accepts only verified receipts
and walks child-to-parent while each child remains reachable.

The full algebra, including the limits of non-linear Haskell values and cross-process receipt
rehydration, is canonical in
[lifecycle state model](../architecture/lifecycle_state_model.md).

## Required Live Gates

1. An off-root command is refused before any lifecycle read or mutation.
2. The documented `<project>.test.dhall` schema and selector have one source of truth.
3. Instrumented demo bring-up records a Harness profile, run-scoped name, and `.test_data` path, with an
   IO tripwire on `.data` and the production cluster.
4. Concurrent runs prove exclusive ownership; fault injection proves only matching owned resources are
   rolled back.
5. `down` and `destroy` visit all child frames before stopping or deleting the parent.
6. A workload writes durable bytes, the full stack is destroyed and recreated, and both host and pod
   read the same bytes.

## Related

- [harness workflow](../architecture/harness_workflow.md) — command/DSL/profile contract.
- [durable state](../architecture/durable_state.md) — `.data` carry and readback gap.
- [readiness](../architecture/readiness.md) — delivered opaque witness foundation and remaining live-effect integration.
- [demo runbook](../operations/demo_runbook.md) — operator-facing demo commands and cautions.
