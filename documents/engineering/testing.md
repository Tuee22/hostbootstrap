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
| Host static gate | `cabal test all --ghc-options=-Werror` from `core/`; `poetry run python -m hostbootstrap.check_code`; `poetry run python -m hostbootstrap.test_all` | an ordinary process of the outer host — macOS, Linux, or Windows | type boundaries, compile-fail diagnostics, codecs, source guards, plans, argv, documentation, and exercised native kernel/process protocols | live provider, container, cluster, or accelerator acceptance |
| `linux-cpu` substrate gate | the phase's own declared command | inside the realized Linux substrate — native Linux, a Lima/Colima VM, WSL2, or a container | that the gated process and its POSIX/container effects actually ran on the baseline substrate | that the same sources build and self-test on another outer host |
| Container `check-code` | `<project> check-code` in the derived image | inside the built container | the formatter (`fourmolu`) and linter (`hlint`), which are installed in the base image only | behaviour; it is a build-time guardrail |
| Live demo gate | `hostbootstrap run -- test init` then `test run all` | a disposable host with real Docker, provider, and cluster state | end-to-end lifecycle over real infrastructure | anything on a host it did not run on |

A container is named in that list because § JJ identifies a gate host by what it *is* rather than by how
it came to exist. It is not a cheaper substrate gate, and § JJ says so directly: what qualifies a run is
where the *effects of the lifecycle under test* execute, not where the binary happens to sit. Running a
static suite inside a container establishes nothing about a provider or a cluster. A selection whose cases
kill real processes and observe convergence, take the protected store's run-liveness lock under a real
project root, or dispatch a signed service to its exit does execute those effects in that Linux, and is
evidence for it. The distinction is worth stating because the difference between the two is invisible in
the run's output: both print the same green line.

The independent cluster-phase live gate is the bare binary's `hostbootstrap test run cluster-live` case.
It is a `linux-cpu` substrate gate rather than the demo gate: one Harness-owned Kind plan creates the
run-scoped cluster; the assertion performs read-only Kubernetes observation and concurrently asks Docker to
assign loopback ports to two isolated same-listener containers without supplying host numbers; the allocation
bracket requires distinct inspected ports and proves both exact containers absent. The ordinary exact reverse
then proves labelled-node absence plus survival of the run's durable sentinel.

The host static gate is not the complete quality gate: `fourmolu` and `hlint` live only in the container
`check-code`. See [code-check doctrine](code_check_doctrine.md).

A host static gate run is evidence for its **gate host**: the operating system, architecture, and toolchain
of the process running the gate. Bare metal, a virtual machine, a container, and a WSL2 distribution each
count as a gate host of their own OS family and architecture. The Linux family is split by architecture,
because every binary is built host-native and an x86_64 and an arm64 Linux gate host therefore compile and
self-test different code from one source tree. This is distinct from the outer host's provider and
substrate; a macOS static pass proves neither Windows portability nor a Linux/container lifecycle. The
[host-portability acceptance phase](../../DEVELOPMENT_PLAN/phase-28-host-portability-acceptance.md) owns the
separate dated Windows, macOS, x86_64 Linux, and arm64 Linux runs, including component durations, totals,
and platform-row coverage. A hardware set is visited once and records every gate-host result it can
produce, so those runs are collected on the substrate-acceptance visits rather than by convening extra
machines. The [development-plan index](../../DEVELOPMENT_PLAN/README.md) owns completion status.

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

Its static process fixture installs a temporary binary with fresh identity keys and sibling config,
then drives real duplex channels through compiled local clients. On a POSIX gate host it executes the
root/VM/container protocol locally. Where the POSIX row is unavailable, the same process cases assert the
row's refusal and the native receiver's rejection of a guest snapshot with a different canonical root.
`CoverageManifest` counts every case, including the Down-to-Destroy continuation and fresh Up rearm,
and reports which outcomes are refusals. These are local
protocol tests; live provider and container execution has its separate substrate gate.

The [host-providers-and-self-reference-lift
phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) records the separate native
Linux/x86_64 KVM/Incus provider gate. Its 2026-09-09 current-tree run passed all 2,497 static cases and
then the live component, including forced restart, post-restart guest readiness, execution of the installed
frame-child entry, conditional alias release, identity-conditional delete, the mutation-free Direct
refusal, and exact residue checks.

The [base-image-publication-and-opportunistic-warm-store
phase](../../DEVELOPMENT_PLAN/phase-23-base-image-and-warm-store.md) records its separate publication
gate. On 2026-09-09, the native Linux/x86_64 CPU pipeline passed its complete source preflight and
immutable local-ID consumer smoke before publishing; it then pulled and re-smoked exact Docker Hub digest
`sha256:e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5`.

The [test harness and run ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)
records realized-Linux acceptance of its recovery, ownership, process, interruption, exact-plan, and report
engine. The [test and context commands phase](../../DEVELOPMENT_PLAN/phase-20-test-and-context-commands.md)
records the concrete parser and filesystem command checks. These exercise the generic command machinery;
the [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns the live provider, cluster,
workload, recursive reverse, and same-run durable recreate gate. Dated totals belong in those phase records.

The [Apple Silicon acceptance phase](../../DEVELOPMENT_PLAN/phase-25-apple-silicon-substrate.md) combines
the pristine demo matrix through Lima and Metal with the native exact-plan direct-Colima lane. Its terminal
audit checks closed leases, released config and run-data ownership, absent demo VM and daemon, and unchanged
ambient Colima profiles and Docker context. Both live lanes exercise the same covered tree; their dated
results and source measurement belong in that phase.

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
