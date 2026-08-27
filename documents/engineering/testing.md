# Testing

**Status**: Authoritative source
**Supersedes**: the root-gated suite-selector and isolated-`.test_data` descriptions
**Referenced by**: [documents index](../README.md), [harness workflow](../architecture/harness_workflow.md), [cluster lifecycle](cluster_lifecycle.md), [demo runbook](../operations/demo_runbook.md), [code-check doctrine](code_check_doctrine.md), [build and run model](../architecture/build_and_run_model.md), [durable Windows runs](durable_windows_runs.md), [Haskell toolchain](../languages/haskell.md)

> **Purpose**: Define the supported fast test entry points, name the gate kinds and what each proves, and
> describe the exact-plan demo lifecycle harness, including its command gate, assertion boundary,
> ownership, and remaining live-validation gaps.

## TL;DR

- Run Python tests from the repository root with
  `poetry run python -m hostbootstrap.test_all`; do not invoke `pytest` directly.
- Run Haskell suites from their Cabal project roots with `cabal test all`. The complete Haskell
  quality gate also includes formatter, linter, and warnings-as-errors build checks.
- Those fast suites are the **host static gate**. Because the project binary is built host-native on
  every substrate, they run as ordinary processes of the outer host and pass host-native on macOS,
  Linux, and Windows alike. Running them natively on Windows is an outer host realization, not a
  substrate.
- A **`linux-cpu` substrate gate** is a different thing: its process and POSIX/container effects execute
  inside the realized Linux substrate. Neither gate substitutes for the other.
- The demo command is `test init` followed by `test run <case-id>|all`. Cases are compiled Haskell with
  validated `CaseId`s; the current `<project>.test.dhall` contains resource overrides and declarative
  variants, not case bodies or lifecycle actions.
- The test surface is admitted only at the rooted Harness entry.
- Each variant owns a generated config and one exact Harness-scoped `ProjectPlan`; the command drives its
  common forward/reverse interpreters directly. The five-field `TestSuite` contains assertions and no
  lifecycle callback.
- `durable-readback` declares `AssertAcrossRestart`; the engine owns the fresh same-run lifecycle invocation,
  exact plan rebind, and write → settled destroy → forward → read choreography.

## Gate Kinds

Four gates exist, and confusing them is how coverage silently disappears. Each proves a different class
of thing, and none substitutes for another.

| Gate | Command | Where it runs | What it proves | What it cannot prove |
|---|---|---|---|---|
| Host static gate | `cabal test all --ghc-options=-Werror` from `core/`; `poetry run python -m hostbootstrap.check_code`; `poetry run python -m hostbootstrap.test_all` | an ordinary process of the outer host — macOS, Linux, or Windows | type boundaries, compile-fail diagnostics, codecs, source-shape guards, plan projections, argv builders, the documentation validator | anything about a provider, a container, a cluster, or a real POSIX process boundary |
| `linux-cpu` substrate gate | the phase's own declared command | inside the realized Linux substrate — native Linux, a Lima/Colima VM, or WSL2 | that the gated process and its POSIX/container effects actually ran on the baseline substrate | that the same sources build and self-test on another outer host |
| Container `check-code` | `<project> check-code` in the derived image | inside the built container | the formatter (`fourmolu`) and linter (`hlint`), which are installed in the base image only | behaviour; it is a build-time guardrail |
| Live demo gate | `hostbootstrap run -- test init` then `test run all` | a disposable host with real Docker, provider, and cluster state | end-to-end lifecycle over real infrastructure | anything on a host it did not run on |

The independent cluster-phase live gate is the bare binary's `hostbootstrap test run cluster-live` case.
It is a `linux-cpu` substrate gate rather than the demo gate: one Harness-owned Kind plan creates the
run-scoped cluster; the assertion performs read-only Kubernetes observation and concurrently asks Docker to
assign loopback ports to two isolated same-listener containers without supplying host numbers; the allocation
bracket requires distinct inspected ports and proves both exact containers absent. The ordinary exact reverse
then proves labelled-node absence plus survival of the run's durable sentinel.

The host static gate is not the complete quality gate: `fourmolu` and `hlint` live only in the container
`check-code`. See [code-check doctrine](code_check_doctrine.md).

A host static gate run is evidence for the one outer host that ran it. Dated results therefore name that
host, and a pass on macOS is not a claim about Windows. Delivery status, exact totals, and dated evidence
live in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

### Harness portability

The host static gate must pass host-native on every supported outer host, so the harness itself is
host-portable. Five rules hold, and each is a property of how a guard is *written* — a host-portable
guard proves the same thing everywhere, which is exactly why it may not be written in terms of one host.

- **A guard over source bytes reads bytes.** A frozen source digest is computed from the file's own
  bytes rather than by decoding to text and re-encoding, so it is a property of the file and not of the
  process locale or the platform's newline translation. The suite driver additionally fixes the locale
  encoding to UTF-8 before the runner starts, so a spec that reads a source file or captured command
  output decodes the same text on every gate host and a governed golden containing non-ASCII text
  compares equal everywhere.
- **A repo-relative module path is separator-neutral.** An import allow-list, importer set, or
  module-ownership list compares canonical forward-slash paths, so a native path separator cannot make a
  satisfied allow-list fail.
- **A host tool-path fixture is absolute on the host that runs it; a guest path stays POSIX.** A host
  tool is resolved and invoked by the outer host and is admitted by the same total absolute-path
  constructor production uses. A guest path names a file on a different machine reached through one
  host-provider command, so it is unaffected. Fixtures respect the same split the invocation boundary
  does.
- **A conditional expectation follows the subject, not the package.** A platform row exists on every gate
  host, so what varies is what it *answers* there: the kernel result where the row can hold its
  obligations, the total refusal where it cannot. A case reads that from the row's own declaration —
  `posixGlobalWallSupported`, `windowsGlobalWallSupported` — rather than from a build symbol the suite
  repeats, so the expectation cannot drift from the subject it is about. A compile-fail fixture expects
  one diagnostic, because the module it names is built everywhere.
- **No case is skipped, and no module is excluded from the build.** A case whose subject is unavailable on
  this gate host asserts the refusal its row declares; it does not disappear. A conditional that changes
  an *expectation* keeps the evidence, while one that removes the case removes it — and a green total that
  quietly shrank on one family is the most complete form of spoofing available, because the number reads
  the same. Platform rows are therefore compiled everywhere and stubbed to a total refusal where they
  cannot apply, so the package description carries no `os()`- or `arch()`-conditional module or
  `buildable` field; only the platform library a row binds to is conditional.

Cases that genuinely need POSIX — the real kernel lock namespace, process-group signal and reap probes,
symlink-root probes, and the fork-based cross-process races — carry explicit platform conditions. On a
gate host that cannot run one, the case asserts the declared refusal and is counted, so the manifest and
the total both stay honest.

`CoverageManifest` is where that declaration lives. Each row names a family, the number of cases it has
on *every* gate host, how many of those drive a platform row, and why the row is conditional; the driver
assembles the manifest from the same list it hands the runner, so what the manifest counts is what runs.
The report is the case name itself, which is why reading a gate's output tells you which families
exercised a real kernel and which recorded a refusal:

```text
CoverageManifest
  WslGlobalWallHostSpec / crash resume: 3 cases, 3 asserting the row's declared refusal
    on this gate host (the POSIX row needs fcntl record locks and device:inode identity): OK
  WslGlobalWallWindowsSpec: 4 cases, 3 exercising the row against this gate host's kernel: OK
```

A family that lost a case on one host fails its declared count there rather than reporting a smaller
total. A family whose subject is available everywhere is not declared, because a manifest listing every
family would be a second copy of the suite. Conditional families name platform rows and the shipped guest
alias symbolic-link row. On a POSIX gate the alias family exercises create, interruption recovery, exact
retry, replacement-safe release, and record cleanup against the real kernel; on a gate without POSIX
symbolic-link ownership the same fixed case family asserts the row's declared refusal. The publication cases
exercise Linux's no-replace hard link and Darwin's `renamex_np(RENAME_EXCL)` move through the same durable
pre-publication identity binding. No external
interpreter, `flock`, or `stat` executable is part of that test or production route.

The ownership row's release-on-death case takes the suite's own re-invocation route: the suite spawns
itself with a probe argument, the probe takes the row's exclusive open and drops the raw descriptor rather
than closing it, and the parent observes the contention, kills the probe, and re-opens. A raw descriptor
carries no finalizer, so nothing in the probe can release that lock and the successful re-open is evidence
about the kernel rather than about a cleanup path.

The protected-store liveness case separately launches an executed child that remains alive after its parent
leaves the liveness extent. The parent immediately reacquires the same kernel lock before terminating the
child. That observation proves the lock descriptor is close-on-exec; a subprocess fixture that exited first
would not distinguish non-inheritance from ordinary process cleanup.

### What counts as evidence

A gate is worth exactly what its evidence is worth. The rule above governs whether a guard proves the same
thing on every host; this one governs whether it proves anything at all.

**A fake exists because a decision is trapped inside an effect.** A suite reaches for a stand-in binary
when the logic deciding what to do with that binary's output lives inside a subprocess, and for an
injected executor when the classification that follows a command lives beside the command. Lift the
decision into a total function over a closed sum and there is nothing left to stand in for.

Four things count as evidence:

- **applying a pure total function to values** — not spoofable, because the function under test *is* the
  function;
- **exercising a platform row against the real kernel**, in a temporary directory the case created. The
  ownership invariant's "the OS releases the lock on process death" is proved by a real process dying;
- **a compile-fail fixture that fails for its named reason**, expecting one contiguous diagnostic phrase
  rather than a token list an unrelated error could also satisfy;
- **a row reporting `Unsupported` on a gate host where it genuinely cannot hold a clause** — the row is
  real; only the host differs.

Four things do not:

- an executable a spec wrote and placed on `PATH` so production would resolve it;
- an injected seam standing in for a subject the gate claims to cover — and a seam whose only production
  instance lives in an opt-in component *is* that, whatever it is called;
- a case a conditional removed;
- a branch in production code that exists for a test — a crash point, a fault token, an execution
  override. It is a spoofable path shipped to operators, and it makes the gate agree with a shape
  production never takes.

The `Unsupported` decision needs no injected row, because "a backend that cannot hold a clause mints no
receipt" is itself a total function from a declared capability value to a refusal. Applying it to every
capability combination is stronger than injecting one stand-in that returns the answer it was written to
return.

Where a capability cannot be exercised on any available gate host, the honest disposition is to test the
pure classification with values and record the live confirmation as **owed to the acceptance phase that
declares that hardware**. Coverage that is owed and named is a smaller claim than coverage that is
simulated, and it is a true one. The normative statement is
[development_plan_standards.md § NN](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## Current Status

The reusable engine runs a compiled, five-field `TestSuite` and aggregates `CaseResult`s into a report.
Those fields are the safety precondition, assertion-environment opener, case matrix, per-case assertion,
and post-reverse absence assertion. For each variant, `HostBootstrap.Command` retains one exact
Harness-scoped plan and supplies an opaque `HarnessLifecycle`. The ownership bracket first recovers abandoned
Harness state under project liveness, then evaluates the safety precondition before allocating that variant's
fresh lease, data root, config, or plan. The engine invokes its forward action,
opens the assertion environment, runs the selected cases, and for `AssertAcrossRestart` cases invokes an
intermediate reverse, a protected fresh same-run forward, and an `AfterRestart` assertion before its one final
reverse and absence assertion. Both assertion phases retain one report row. A non-refusal bring-up failure still enters the same reverse path. Only a refusal that
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

Phase 19's realized-linux acceptance is deliberately narrower than the live demo gate: on 2026-08-22 a
disposable Ubuntu 24.04 amd64 Incus VM ran the deterministic recovery-interruption group (5/5) and the
complete warnings-as-errors core gate (2366/2366 in 151.83 seconds). Those runs exercise the Harness
ownership, process, interruption, exact-plan, and report-engine rows available by Phase 19. The
provider/cluster/workload lifecycle, exact recursive demo
reverse adopter, and live same-run durable recreate remain the worked-demo phase's own acceptance; making
the earlier harness phase wait for them would invert the development-plan order.

The Phase 20 command-surface acceptance ran the phase-owned concrete parser fixture in that same realized
Linux VM: `CLISpec` passed 57/57 and the `ContextSpec`/`LiftContextSpec` selection passed 84/84, both with
warnings as errors. These are live filesystem/process invocations of the real generic command machinery,
not a provider demo substitute; the long provider/cluster sequence remains the worked-demo acceptance.

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
production cluster. The direct Harness plan boundary never opens Production authority; its same-run transition
rotates only the held Harness mode and exact bound lease after settled destroy.

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

### The interruption matrix

A process death inside a lifecycle transaction is not an event the suite reproduces; it is a **value** the
store is left holding. The redo coordinator publishes an `Applying` descriptor, materializes that
descriptor's targets in order, then publishes `Idle`, so the only durable states a death is distinguishable
in are "the descriptor is published and no target is materialized", "the first *n* targets are
materialized", and "every target is materialized and the commit has not happened".

`SessionSpec` writes those states directly and re-enters the ordinary entry point. The descriptor it writes
is the transition's own: the fixture snapshots the store's directory, runs the real transition once, reads
the records it stamped — their keys, their roles, their exact payloads, and its transaction id — restores
the directory from the snapshot, and rebuilds the descriptor against those same pre-transition versions. The
snapshot restore is what makes the expectations faithful, because a store rebuilt through the API would
carry later record versions than the coordinator saw. One case pins that faithfulness directly: the
reproduced state carries the exact bytes the completed transition wrote, under the same transaction id.

The coordinator therefore carries no crash point, and no shipped module installs one. That is not a smaller
claim than an injected exception would support — it is a larger one, because the recovery driver under test
needs no cooperation from the code under test, and there is no branch in production that only a gate takes.
`HostBootstrap.Lifecycle.Session.Testing` exposes the vocabulary that state is written in and mints no
authority: a compile-fail fixture proves a descriptor cannot become a transaction permit.

The separate top-level `recovery-interruption` group proves the process boundary around that state model. Its
producer subprocesses reach five real durable boundaries, publish a managed ready sentinel, and then block
until the parent hard-kills them. A separately exec'd successor reopens the same protected store. The matrix is:

| Boundary | Successor proof |
|---|---|
| owned-resource settlement | the recovered backend is called child-first exactly once, its release is recorded, and a second successor performs no duplicate effect |
| migration freeze | the incomplete pre-activation revision closes and admits the successor |
| migration commit | the completed revision retains its exact missing-candidate refusal rather than being guessed closed |
| root Destroy settlement | the public recursive lifecycle has released its terminal lease/mode, a fresh Up rearms the retained terminal intent under a newer broker, and a later Destroy succeeds |
| persisted `Closing` | the successor observes the exact closing epoch and cannot mint a new open permit |

These probes are test-executable entry modes only. Production lifecycle modules still contain no crash point,
fault token, or test-only branch. Sentinels, results, and backend-call traces live only under the fixture's
managed temporary directory and use no `.log` files.

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
readback gates. They are the host static gate described above, so they are expected to pass host-native on
macOS, Linux, and Windows.

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

## Current Safety Boundaries

- `test init` and `test run` are admitted only at the rooted Harness entry.
- A Harness run deliberately creates real provider VMs, Docker state, and clusters. Its exact plan derives the
  run-scoped cluster name, removable state, semantic exposure intents, and `.test_data/<run-id>` root together;
  runtime-selected ports remain opaque results rather than profile fields. The long gate therefore runs only
  on a disposable host with no production demo state.
- Provider, share, alias, exposure, cluster, workload, activation, generated-config, and durable-root mutations
  are released only through their exact plan projection and ownership evidence. Recursive reverse settles each
  child frame before stopping or deleting its parent provider.
- Project assertion code receives only `BeforeRestart` or `AfterRestart`. The engine owns settled Destroy,
  protected generation rotation, exact snapshot/plan rebind, fresh recursive Up, and terminal close.

The harness obtains opaque `HarnessAuthority projectId runId`, active Harness mode, and the exact unbound run
lease. The protected profile opener combines only matching values into
`LifecycleProfile (Harness projectId runId)`; authority alone cannot construct it. Plan construction derives a
run-scoped cluster identity and `.test_data/<run-id>` together, and Command retains that exact plan through
common forward/reverse interpretation. Every adapter consumes a freshly prepared operation/preconditions pair
and returns an explicit reconcile result with owned evidence or a foreign observation. Cleanup accepts only
verified records and walks child-to-parent while each child remains reachable.

The durable-readback program uses the engine-owned two-phase assertion form and a protected fresh
lifecycle-invocation generation under the same run, config, durable root, and plan. No lifecycle action enters
`TestSuite` to implement that choreography.

The full algebra, including the limits of non-linear Haskell values and cross-process receipt
rehydration, is canonical in
[lifecycle state model](../architecture/lifecycle_state_model.md).

## Live Gate Contract

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

- [build and run model](../architecture/build_and_run_model.md) — the host-native build the gate kinds follow from.
- [code-check doctrine](code_check_doctrine.md) — the container-only formatter and linter leg.
- [durable Windows runs](durable_windows_runs.md) — why only the long gate needs a durable launcher on Windows.
- [Haskell toolchain](../languages/haskell.md) — the host-portability idioms a suite uses.
- [harness workflow](../architecture/harness_workflow.md) — command/DSL/profile contract.
- [durable state](../architecture/durable_state.md) — `.data` carry and readback gap.
- [readiness](../architecture/readiness.md) — delivered opaque witness foundation and remaining live-effect integration.
- [demo runbook](../operations/demo_runbook.md) — operator-facing demo commands and cautions.
