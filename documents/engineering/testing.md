# Testing

**Status**: Authoritative source
**Supersedes**: the root-gated suite-selector and isolated-`.test_data` descriptions
**Referenced by**: [documents index](../README.md), [harness workflow](../architecture/harness_workflow.md), [cluster lifecycle](cluster_lifecycle.md), [demo runbook](../operations/demo_runbook.md), [code-check doctrine](code_check_doctrine.md), [build and run model](../architecture/build_and_run_model.md), [durable Windows runs](durable_windows_runs.md), [Haskell toolchain](../languages/haskell.md)

> **Purpose**: Define the supported fast test entry points, name the gate kinds and what each proves, and
> describe the exact-plan demo lifecycle harness, including its command gate, assertion boundary,
> ownership, and the gaps between the tree and its live gate contract.

## TL;DR

- Run Python tests from the repository root with
  `poetry run python -m hostbootstrap.test_all`; do not invoke `pytest` directly.
- Run Haskell suites from their Cabal project roots with `cabal test all`. The formatter and linter are
  not part of these suites; [code-check doctrine](code_check_doctrine.md#where-the-style-tools-run) is
  canonical for where they run.
- The **host static gate** is the four legs spelled once in
  [development_plan_standards.md § JJ](../../DEVELOPMENT_PLAN/development_plan_standards.md#jj-host-portable-static-gate-and-test-harness):
  the two Cabal suites, the Python suite, and the Python `check_code` leg. Because the project binary is
  built host-native on every substrate, they run as ordinary processes of the outer host and pass
  host-native on macOS, Linux, and Windows alike. Running them natively on Windows is an outer host
  realization, not a substrate.
- A **`linux-cpu` substrate gate** is a different thing: its process and POSIX/container effects execute
  inside the realized Linux substrate. Neither gate substitutes for the other.
- The demo command is `test init` followed by `test run <case-id>|all`. Cases are compiled Haskell with
  validated `CaseId`s; the current `<project>.test.dhall` contains resource overrides and declarative
  variants, not case bodies or lifecycle actions.
- The test surface is described as root-only, but the parser applies no binary-context root gate; see
  [Current Status](#current-status).
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
| Host static gate | all four commands in [the canonical host static gate](../../DEVELOPMENT_PLAN/development_plan_standards.md#jj-host-portable-static-gate-and-test-harness) | an ordinary process of the outer host — macOS, Linux, or Windows | type boundaries, compile-fail diagnostics, codecs, source guards, plans, argv, documentation, and exercised native kernel/process protocols | live provider, container, cluster, or accelerator acceptance |
| `linux-cpu` substrate gate | the phase's own declared command | inside the realized Linux substrate — native Linux, a Lima/Colima VM, WSL2, or a container in which the selected lifecycle effects execute | that the gated process and its POSIX/container effects actually ran on the baseline substrate | that the same sources build and self-test on another outer host |
| Derived-image `check-code` | `<project> check-code` in the derived image build | inside the image build | the project's formatter, linter, and warning-clean build checks over its own sources | behaviour; it is a build-time guardrail |
| Live demo gate | the Python bootstrapper's `poetry run hostbootstrap run -- test init`, then `poetry run hostbootstrap run -- test run all` | a disposable host with real Docker, provider, and cluster state | end-to-end lifecycle over real infrastructure | anything on a host it did not run on |

Whether a container run is substrate evidence follows one rule from § JJ: what qualifies a run is where
the *effects of the lifecycle under test* execute, not where the binary happens to sit.

- A container is a valid `linux-cpu` substrate gate host for a selection whose lifecycle effects execute
  inside it: cases that kill real processes and observe convergence, take the protected store's
  run-liveness lock under a real project root, or dispatch a signed service to its exit.
- A static suite run in a container is host static gate evidence for a Linux gate host of that
  architecture, and is not substrate evidence: it establishes nothing about a provider or a cluster.
- The live demo gate needs a guest VM, because that gate brings up its own provider guest and therefore
  needs nested virtualization rather than only a namespace.

The rule is worth stating because the two container runs are indistinguishable in their output: both
print the same green line.

One consequence is easy to miss on a developer workstation. An outer Linux host with a visible
accelerator realizes `linux-gpu`, so it is not itself a `linux-cpu` gate host, however Linux it is.
Detection, absent a bootstrapper statement, classifies a Linux as `linux-cpu` only when neither
`/proc/driver/nvidia/version` nor `/dev/nvidiactl` exists **and** `nvidia-smi -L` reports no device. The
`linux-cpu` gate host on such a workstation is therefore a container started with no accelerator device
passed to it, or a guest VM that passes the same three checks. A WSL2 distribution on an NVIDIA Windows
host whose `nvidia-smi -L` reports the paravirtualized GPU realizes `linux-gpu`, not `linux-cpu`. Either
way the gate host's toolchain is the one inside it, and is recorded as such. The base ships the pinned family
compiler, which is the one every workspace here selects, so a container leg builds with the image's own
GHC and its evidence row names that. A leg that supplies a compiler from outside the image is doing
something the pin exists to make unnecessary, and says so.

The independent cluster-phase live gate is the bare Haskell binary's `hostbootstrap test run cluster-live`
case, not a Python bootstrapper verb. It is a `linux-cpu` substrate gate rather than the demo gate: one Harness-owned Kind plan creates the
run-scoped cluster; the assertion performs read-only Kubernetes observation and concurrently asks Docker to
assign loopback ports to two isolated same-listener containers without supplying host numbers; the allocation
bracket requires distinct inspected ports and proves both exact containers absent. The ordinary exact reverse
then proves labelled-node absence plus survival of the run's durable sentinel.

The host static gate is not the complete quality gate: it runs neither `fourmolu` nor `hlint`. Those run
in the repository source gate that `base build` and `base build-and-push` run on the host before Docker,
in a derived image's `check-code`, and in the base image's tool smoke;
[code-check doctrine](code_check_doctrine.md#where-the-style-tools-run) is canonical for which sources
each reads.

A host static gate run is evidence for its **gate host**: the operating system, architecture, and toolchain
of the process running the gate. Bare metal, a virtual machine, a container, and a WSL2 distribution each
count as a gate host of their own OS family and architecture. The Linux family is split by architecture,
because every binary is built host-native and an x86_64 and an arm64 Linux gate host therefore compile and
self-test different code from one source tree. This is distinct from the outer host's provider and
substrate; a macOS static pass proves neither Windows portability nor a Linux/container lifecycle. The
[host-portability acceptance phase](../../DEVELOPMENT_PLAN/phase-29-host-portability-acceptance.md) owns the
separate dated Windows, macOS, x86_64 Linux, and arm64 Linux runs, including component durations, totals,
and platform-row coverage. A hardware set is visited once and records every gate-host result it can
produce, so those runs are collected on the substrate-acceptance visits rather than by convening extra
machines. The [development-plan index](../../DEVELOPMENT_PLAN/README.md) owns completion status.

### One toolkit for reading this repository's own sources

A source guard asserts something about a set of modules, so a guard that is wrong about which modules it
enumerated asserts nothing and does so silently. `core/hostbootstrap-core/test/SourceGuard.hs` is the
core suite's shared toolkit for enumerating and analysing its own sources, in two halves: a lexical
reader (tokens, imports, exports, identifier and token-sequence counts, repo-relative paths and module
names) and a structural one (the package-root bracket, sorted source walkers, component and common-stanza
readers, module fields, and significant-line counts). A guard that
enumerates modules or turns a path into a module name does so through it rather than writing another
walker. A guard over one named module reads that file with an ordinary `readFile` under the driver's
UTF-8 locale and, where it needs tokens, hands the text to the lexical half. Both the core and demo
suite drivers initialize that locale before tests run.

`componentStanzas` reads every library, executable, test suite, benchmark, and foreign library, including
source directories inherited through common stanzas. `namedStanza`, `fieldValues`, and `fieldModules`
share case-insensitive field reading across inline, continued, and comma-separated values.
`listComponentSources` walks those effective roots; `listTestSources` and `forEachTestSourceBut` cover
every test-suite root while excluding compile-fail inputs that are compiled separately.

Library module readers use the source directories declared by every library stanza, deduplicate
overlapping paths, and retain the module declaration's identity when its file moves. A lookup that
expects one module home refuses a missing or ambiguous result. The architecture drift validator
checks every matching forbidden-boundary module under the production `src` and `internal` trees,
so moving a kernel into a private unit cannot silently remove its absence checks. Synthetic cases
exercise main-library, private-unit, and simultaneous homes and assert the reported source paths.

`transitiveHostBootstrapImports` resolves a module's complete first-party import closure against
that same library inventory. Qualified imports follow the same path as unqualified ones, cycles
terminate, and a missing or ambiguous module reports its importing module and source path. The
authority kernel's dependency guard therefore includes private library roots and rejects configuration
or reconciliation dependencies reached through another module.

Compile-fail registration uses that library inventory to check first-party modules and imported names
against genuine definition positions. Declaration readers include private constructors, fields, class
members and foreign binders, and reject unsupported forms; an identifier occurrence in a type, pattern,
import, comment or literal is insufficient. The registered fixture set must match the files exactly once.
A separate token inventory pins the exposed facades that import hidden/private implementation and the
locally sealed registry plan, while every named library stanza must explicitly remain private.

The enumeration is checked rather than frozen: each declared module resolves under its component's
effective source directories, and every enumerated module file belongs to a component. The same inventory
drives warning-policy checks across the core and demo packages: every component imports the shared
warnings stanza, component flags cannot weaken it, and source modules carry no `OPTIONS_GHC` or `OPTIONS`
pragma. The package metadata supplies `-Werror` and `-Wpartial-fields`.

### Harness portability

The host static gate must pass host-native on every supported outer host, so the harness itself is
host-portable. Five rules hold, and each is a property of how a guard is *written* — a host-portable
guard proves the same thing everywhere, which is exactly why it may not be written in terms of one host.

- **A guard over source bytes reads bytes.** A frozen source digest is computed from the file's own
  bytes rather than by decoding to text and re-encoding, so it is a property of the file and not of the
  process locale or the platform's newline translation. Both suite drivers make
  `setLocaleEncoding utf8` their first IO action, before argument dispatch, source reads or the
  runner's first demand of a standard handle. A spec therefore reads source or captured command
  output using the same locale encoding on every gate host. The demo's runtime locale assertion
  checks that selected encoding; its unchanged Unicode case names also exercise Tasty output in
  the complete demo gate.
- **A repo-relative module path is separator-neutral.** An import allow-list, importer set, or
  module-ownership list compares canonical forward-slash paths, so a native path separator cannot make a
  satisfied allow-list fail.
- **A host tool-path fixture is absolute on the host that runs it; a guest path stays POSIX.** A host
  tool is resolved and invoked by the outer host and is admitted by the same total absolute-path
  constructor production uses. A guest path names a file on a different machine reached through one
  host-provider command, so it is unaffected. Fixtures respect the same split the invocation boundary
  does. `PlatformPath.hostFixturePath` supplies the host root and discards drive or root decorations
  from the supplied segments, including drive-letter spellings, so its result remains host-absolute.
- **A conditional expectation follows the subject, not the package.** A platform row exists on every gate
  host, so what varies is what it *answers* there: the kernel result where the row can hold its
  obligations, the total refusal where it cannot. A case reads that from the row's own declaration —
  `posixOwnershipSupported`, `windowsOwnershipSupported`, `hostOwnershipSupported`,
  `windowsGlobalWallSupported`, and `localGuestAliasSupported` — rather than from a build symbol the
  suite repeats, so the expectation cannot drift from the subject it is about. A compile-fail fixture expects
  one diagnostic, because the module it names is built everywhere.
- **No case is skipped, and no module is excluded from the build.** A case whose subject is unavailable on
  this gate host asserts the refusal its row declares; it does not disappear. A conditional that changes
  an *expectation* keeps the evidence, while one that removes the case removes it — and a green total that
  quietly shrank on one family is the most complete form of spoofing available, because the number reads
  the same. Platform rows are therefore compiled everywhere and stubbed to a total refusal where they
  cannot apply, so the package description carries no `os()`-, `arch()`-, or `flag()`-conditional module
  or `buildable` field, including `elif` branches and mixed-case field names; only the platform library
  a row binds to is conditional.

Cases that genuinely need POSIX — the real kernel lock namespace, process-group signal and reap probes,
symlink-root probes, and the fork-based cross-process races — carry explicit platform conditions. On a
gate host that cannot run one, the case asserts the declared refusal and is counted, so the manifest and
the total both stay honest.

The host-tool System32 resolution family keeps its two cases on every host: Windows checks the actual
SystemRoot-derived paths and other hosts assert the exact unavailable answers. The effect runner's
POSIX process family similarly retains five cases, with direct probe or native-entry refusals where
POSIX execution is unavailable. Both families participate in the observed-completion manifest.

`CoverageManifest` is where that declaration lives. Each row names a family, the number of cases it has
on *every* gate host, how many of those drive a platform row, and why the row is conditional; the driver
assembles the manifest from the same list it hands the runner, so what the manifest counts is what runs.
Each structural case names the expected branch. The shared `ConditionalCase` combinators record which
row or refusal callback completes without an exception; the driver resets those counters before the
suite starts. The manifest's final case, "every conditional family ran the branch its row declares",
runs after the other groups finish through tasty `after AllFinish`, reports each family's observed
row/refusal completion counts, and compares them with `familyRowCases` and `familyRowHolds`.

Missing recording, missing executions, opposite-branch completions, extra completions, and callbacks
that throw cannot satisfy those counts. A callback that returns `()` supplies completion evidence only:
the combinator cannot establish that an arbitrary callback contains a meaningful assertion. The refusal
callbacks retain their real row calls and refusal assertions, whose contents remain part of review and
the behavioral cases.

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

The protected-store contention probe (the suite re-invoked with its protected-entry probe argument) and
that liveness case carry no Windows condition, unlike the POSIX ownership row's lock probe. The store's
exclusive entry is `base`'s portable `hLock`/`hTryLock`, which is `flock`/`fcntl` on POSIX and `LockFileEx`
on Windows, and the probes reach it through the suite's own re-invocation route rather than a POSIX-only
primitive, so they exercise the real kernel lock on every gate host.

The suite's liveness probe returns 0 for acquisition, 3 for a live peer and 4 for a typed refusal.
Authority cases exercise a live peer before/after release, invalid names before filesystem effects,
timeouts and short acquisition interruptions, and the original body's exception after release.
Separate cases retain each record-operation IO action past an entry, invoke it inside a later entry,
and try a live session from a foreign thread; each must refuse before touching records. These test the
private revocable session token, beyond rank-2 provenance or a compile-fail coercion fixture.

Command-reservation cases allocate and bind a real broker epoch, leave its entry, and give each
competitor a fresh protected entry that verifies the principal, reifies the allocated epoch, and
reopens the existing root. Thread and process races require one authority and one consumed refusal
with one invocation record. The process probe signals readiness before its entry attempt; the parent
holds the entry until both competitors are ready, then releases them to contend. Identity-field,
project/store mismatch, conflict and reverse-root replay cases exercise the same reservation kernel.

The protected-store codec cases exhaustively enumerate short one- and two-segment identity paths,
checking the inverse, case-fold injectivity and exclusion of the tuple separator. Real records cover
case/underscore/dotted tuples, and actual copied executables provide installed project identities for
mode, Harness ownership, liveness and hard-kill recovery; no installed identity is forged for a fixture.
Old/unknown/empty identity envelopes and populated identity-less stores must refuse with their bytes
unchanged. Runtime ownership cases exercise exact encoded provider-share recovery against the fixture
client process and the real protected store.

Durable publication has a source-order guard over the complete publisher and its platform helpers:
write/close, file synchronization, rename, parent synchronization, and Darwin's subsequent regular-file
full device flush remain inside the temporary cleanup extent. Existing record/CAS cases additionally
check for no `.rec.tmp-` leftovers. This checks implementation order and actual record operations;
power loss and mid-write disk failure are not simulated as passing runtime evidence.

The suite recognizes its probe arguments before ordinary test parsing. An unrecognized argument beginning
with `--hostbootstrap-` writes an "unrecognized probe" diagnostic to standard error, leaves standard
output empty, and exits with status 97, so a misspelled probe cannot silently run the whole suite.

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
- **a compile-fail fixture that fails for its named reason**, with a nonempty list of contiguous phrases
  matched to distinct error diagnostics. The compiler suppresses caret/source excerpts, and the matcher
  normalizes wrapping and quotes within each block before assigning one block per expected rejection;
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
[development_plan_standards.md § NN](../../DEVELOPMENT_PLAN/development_plan_standards.md#nn-evidence-and-what-cannot-count-as-it).

The two ownership rows are not symmetric. Seven clauses the POSIX row's families assert have no Windows
case at all — four symbolic-link behaviours and three that are not platform-specific (a probe that
cannot answer is a fault, the kernel releases the exclusion when the holding process dies, and removing
an absent object is a fault). `CoverageManifest` freezes the
deficit at that size, so a Windows row that loses another clause fails, but the deficit is a coverage gap
in the Windows row rather than a property of Windows (see [Current Status](#current-status)).

## Current Status

The reusable engine runs a compiled, five-field `TestSuite` and aggregates `CaseResult`s into a report.
Those fields are the safety precondition, assertion-environment opener, case matrix, per-case assertion,
and post-reverse absence assertion. For each variant, `HostBootstrap.Command` retains one exact
Harness-scoped plan and supplies an opaque `HarnessLifecycle`. The ownership bracket first recovers abandoned
Harness state under project liveness, then evaluates the safety precondition before allocating that variant's
fresh lease, data root, config, or plan. The engine invokes its forward action,
opens the assertion environment, runs the selected cases, and for `AssertAcrossRestart` cases invokes an
intermediate reverse, a protected fresh same-run forward, and an `AfterRestart` assertion before its one final
reverse and absence assertion. Both assertion phases retain one report row. A non-refusal bring-up
failure still enters the same reverse path. Only a refusal that the command independently verifies
preceded project-resource acquisition becomes `SafetyRefusal` and skips reverse; a late refusal is
classified as refused but still tears down. The demo generates two
project-config variants with different messages and runs the selected compiled cases against each.

The demo's post-reverse assertion checks the host daemon through its current protected claim store,
taking the lifecycle entry before observing the owner record and PID. A held entry, retained record,
or failed observation refuses a clean teardown; empty retained store scaffolding is allowed. On Windows,
the same assertion checks the global wall's active record through the production wall-location API.
The wall's monotonic fence remains after release and is not active ownership. These checks supplement
the exact provider or direct-cluster absence probe. Behavior tests publish current protected records
and hold their entries in temporary stores, so checking obsolete paths cannot make the tests pass.

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
Linux/x86_64 KVM/Incus provider gate. That gate runs the static cases and then the live component,
covering forced restart, post-restart guest readiness, execution of the installed
frame-child entry, conditional alias release, identity-conditional delete, the mutation-free Direct
refusal, and exact residue checks. Its dated run and totals belong to that phase.

The [base-image-publication-and-opportunistic-warm-store
phase](../../DEVELOPMENT_PLAN/phase-23-base-image-and-warm-store.md) records its separate publication
gate. That pipeline passes a complete source preflight and an immutable local-ID consumer smoke before
publishing, then pulls the published tag back and re-smokes it against the exact Docker Hub digest. The
dated publication and that digest belong to that phase.

The [test harness and run ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)
records realized-Linux acceptance of its recovery, ownership, process, interruption, exact-plan, and report
engine. The [test and context commands phase](../../DEVELOPMENT_PLAN/phase-20-test-and-context-commands.md)
records the concrete parser and filesystem command checks. These exercise the generic command machinery;
the [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns the live provider, cluster,
workload, recursive reverse, and same-run durable recreate gate. Dated totals belong in those phase records.

The [Apple Silicon acceptance phase](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md) combines
the pristine demo matrix through Lima and Metal with the native exact-plan direct-Colima lane. Its terminal
audit checks closed leases, released config and run-data ownership, absent demo VM and daemon, and unchanged
ambient Colima profiles and Docker context. The same visit hard-kills the demo's host accelerator daemon,
and separately the `project up` launching it before readiness, on the Darwin kernel, and requires the
next `project up` to resolve the stale claims without an operator deleting records. Both
live lanes exercise the same covered tree; their dated results and source measurement belong in that phase.

The [Windows and WSL2 acceptance phase](../../DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md) runs
the live demo matrix on a native Windows host through the durable launcher
([durable Windows runs](durable_windows_runs.md)), then a terminal ownership and WSL wall audit: closed
leases, an empty per-user WSL registration inventory, no active wall record, the original `.wslconfig`
bytes and file identity restored, and WSL shut down only after that restoration is verified. The same
visit hard-kills the demo's host accelerator daemon, and separately the `project up` holding its lifecycle
operation, and requires the supported `project down` and `project up` sequence to resolve the stale claims
without an operator deleting records. Its dated results and source measurement belong in that phase.

Three gaps separate the tree from this page's target contract:

- **No root gate.** The `test` command's description calls the surface root-only, but the parser applies
  no binary-context root gate to `test init` or `test run`; root authority rests on the harness safety
  preconditions and the invocation location. No test pins an off-root refusal. The
  [`test` and `context` commands phase](../../DEVELOPMENT_PLAN/phase-20-test-and-context-commands.md)
  owns this gap; [harness workflow](../architecture/harness_workflow.md#current-status) states it in full.
- **No runtime tripwire on `.data` or the production cluster.** The Harness profile derives the run-scoped
  cluster name and `.test_data/<runId>`, so no Harness plan names either production target, but no
  runtime check fails a run that touches them. The
  [test harness and run ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)
  owns this gap.
- **The Windows ownership row asserts fewer clauses than the POSIX row.** The seven clauses named under
  [What counts as evidence](#what-counts-as-evidence) have no Windows case. The
  [ownership clauses and reservations phase](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md)
  owns closing it, against a Windows gate host.

## Supported Fast Test Entries

From the repository root:

```text
poetry run python -m hostbootstrap.test_all
```

`hostbootstrap.test_all` sets the required sentinel and invokes `pytest tests` in-process. With no
forwarded arguments it measures line and branch coverage of `hostbootstrap` and fails below the
configured 100% floor. Modules imported before measurement are reloaded in dependency order so their
module bodies count and their imported class identities agree. Forwarded pytest options retain the
default `tests` target; a forwarded path or node id replaces that target. Runs with forwarded arguments
do not enforce whole-suite coverage. Direct `pytest` invocation is intentionally rejected by
`tests/conftest.py`.

`hostbootstrap.check_code` invokes Ruff, Black and strict mypy through the current interpreter's
`-m` entries, with the repository root as their working directory.

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
readback gates. With the Python `check_code` leg (`poetry run python -m hostbootstrap.check_code`, which
runs `ruff`, `black`, and `mypy`) they make up the host static gate described above, whose four legs
[§ JJ](../../DEVELOPMENT_PLAN/development_plan_standards.md#jj-host-portable-static-gate-and-test-harness)
spells once, so they are expected to pass host-native on macOS, Linux, and Windows.

## Demo Command Surface

```text
<project> test init
<project> test run <case-id>
<project> test run all
```

`test init` requires no production `<project>.dhall`; it writes the executable-sibling
`<project>.test.dhall`. When that file already exists, `test init` refuses and leaves it unchanged;
`test init --replace` is the only route that overwrites it, for example to regenerate it after a
test-config schema change. `test run` reads that file, validates the project-owned typed matrix projection,
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
every variant is used. Construction also rejects duplicate rows/pairs and unknown/orphan references. An
empty variant list, duplicate variant names, or a name that is not a valid identity (an empty name among
them) is refused while the matrix is being built — `EmptyVariantRegistry`, `DuplicateVariantIds`, and
`InvalidVariantDeclaration` respectively — which is before the run acquires anything. Selection, generation, and reporting consume that relation.

## Current Safety Boundaries

- `test init` and `test run` carry no binary-context root gate (see [Current Status](#current-status));
  `test run` refuses without `<project>.test.dhall`, and its Harness safety preconditions run inside the
  protected transaction before any variant's lease, data root, config, or plan is allocated.
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
common forward/reverse interpretation. Every adapter consumes a matching operation/preconditions pair
and returns an explicit reconcile result with owned evidence or a foreign observation. Cleanup accepts only
verified records and walks child-to-parent while each child remains reachable.

The explicit pure zero-dependency operation and phase entries derive their empty preconditions rather
than accepting a retained set, and refuse any descriptor with dependencies. Their empty branch needs
no dependency probe IO. Generic operation and phase preparation still accept caller-retainable sets;
the matching step does not establish when their observations ran. Complete gate-first snapshot
admission is the target owned by the
[prepared-operations phase](../../DEVELOPMENT_PLAN/phase-11-prepared-operations.md), separately from
the already checked protected journal gate and the still-public low-level gate-writer limitation.

The durable-readback program uses the engine-owned two-phase assertion form and a protected fresh
lifecycle-invocation generation under the same run, config, durable root, and plan. No lifecycle action enters
`TestSuite` to implement that choreography.

The full algebra, including the limits of non-linear Haskell values and cross-process receipt
rehydration, is canonical in
[lifecycle state model](../architecture/lifecycle_state_model.md).

## Live Gate Contract

The live demo gate is held to the items below, each labelled with how the tree holds it.
[Harness workflow](../architecture/harness_workflow.md#safety-contract) is canonical for the command-side
safety contract, and its [Validation](../architecture/harness_workflow.md#validation) section names the
tests.

| # | Item | How the tree holds it |
|---|---|---|
| 1 | an off-root command is refused before any lifecycle read or mutation | **owed**: no root gate exists (see [Current Status](#current-status)) |
| 2 | the documented `<project>.test.dhall` schema and selector have one source of truth | held: the compiled case registry and the typed matrix projection, pinned by the schema and matrix tests |
| 3 | demo bring-up records the exact Harness plan/profile, run-scoped name, and `.test_data/<runId>` path, and touches neither `.data` nor the production cluster | recording held by the demo gate; exclusion held by profile derivation alone, with no runtime tripwire (see [Current Status](#current-status)) |
| 4 | concurrent runs prove exclusive ownership, and an interrupted run releases only resources whose ownership receipts match | held without a production fault hook: cross-profile race and run-lease tests prove exclusion, and interruption is reached either by killing a real process (`RecoveryInterruptionSpec`) or by reconstructing an Applying descriptor from a real transition's records and original physical versions through [`HostBootstrap.Lifecycle.Session.Testing`](../../core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session/Testing.hs) and re-entering the ordinary entry point |
| 5 | `down` and `destroy` visit all child frames before stopping or deleting the parent | held: the local root/VM/container process cases, and the live recursive reverse of the worked demo gate |
| 6 | the engine allocates a fresh same-run lifecycle invocation, a workload writes durable bytes, the full stack is destroyed and recreated, and both host and pod read the same bytes before the final settled destroy closes the run | held: `AssertAcrossRestart` in the engine, exercised live by the worked demo gate |

Transaction codec and redo evidence are separate. The existing `Session.Testing` vocabulary forwards
the real pure `decodeCoordinator` beside its encoder; this observes data and adds no permit producer
or runner. The already private `lifecycle-transaction-internal` unit exposes only `Session.Testing`;
`Lifecycle.Transaction` is in its `other-modules`, and the main library retains its own hidden copy.
The bounded reconstruction matrix below supplies its own redo observations, separately from this
module-list boundary.

## Validation

- The host static gate's suites hold every static claim on this page; [§ JJ](../../DEVELOPMENT_PLAN/development_plan_standards.md#jj-host-portable-static-gate-and-test-harness)
  spells the gate.
- `CoverageManifest` holds the per-family case inventory and observed successful branch completions of
  [Harness portability](#harness-portability). Its comparator and callback cases prove missing or wrong
  counts and throwing callbacks are detected. `PortabilitySpec` holds source-byte, locale-order,
  host-path, probe-refusal, component-enumeration, warning-policy, and conditional-build absence guards.
- `CLISpec` holds the `test init` overwrite policy and the `test run` missing-config and unknown-case
  refusals.
- The prepare kill-point is the `SessionSpec` case "a prepare records the unknown phase before the adapter
  runs": the durable operation record names the effect that may be in flight before any adapter effect
  runs, so a crash after that point leaves a journaled unknown phase rather than an unrecorded effect.
- `ReconcileSpec`'s explicit zero-dependency preparation controls require a genuine matching pair,
  direct nonempty-edge refusal, exact gate-coordinate/attempt refusals and a managed force-destroy
  preparation. A dependency-bearing managed phase must still succeed through the generic factory
  while the zero-phase entry refuses the same descriptor without delivering its continuation.
  These validation targets preserve the full phase capability; they claim no generic fresh-probe
  timing, live cleanup or hardware confirmation.
- Transaction wire controls independently observe Unicode descriptor-plan data through the actual
  encoder and pure decoder, the public ASCII-only session-name refusal, and a genuine ASCII
  `TxnOpenSession` AfterApplying recovery with an absent new target. Only the last exercises journal
  recovery; the Unicode data case grants no identity or redo authority.
- Coordinator text is strict UTF-8 and numeric fields are bounded canonical `Word64` spellings.
  Accepted coordinator and recognized stamped-envelope bytes must round-trip their complete encoders;
  coordinator trailing line feeds and valid uppercase hex distinguish this from scalar-only validation. Ordinary
  journal/target readers pin exact `SessionRecordCorrupt` projections and post-mutation preservation,
  including coordinator and stamp overflow. Canonical stamped and legitimate unstamped payloads
  containing FF/NUL remain opaque; Session's Prepared Char8 fields are unchanged. These controls claim
  neither a process killed at each write nor live provider acceptance.
- The redo matrix retains twenty-five prefix cases across eight kinds, plus its shared
  `faithfulDescriptorCase` (twenty-six checks). A real transition supplies target keys, roles, payloads,
  sequence and committed successor; the fixture restores the original directory snapshot and physical
  versions before publishing Applying and a bounded prefix. The initial project case obtains Idle 0
  through the ordinary missing-journal read before its snapshot. Applying readback precedes recovery,
  recovered Open state is observed before journal opening, and the successor version must equal the
  uninterrupted capture. The fixture checks one target per kind except two for register-intent, with
  `0 <= prefix <= target count` before publication; those counts are specific to these eight kinds.
- Descriptor refusals independently cover requested-plan mismatch, out-of-plan ownership, wrong role
  order, an ordinary third state and a raw Production third state. Exact mapped errors and post-setup
  images hold admission and conflict behavior. The Production conflict baseline follows a valid earlier
  project-target prefix and a same-byte lease version change, so it proves the real sequence diagnostic
  without claiming rollback of a previously applied prefix.
- `PortabilitySpec` retains the shipped-source named crash-point absence guard. The well-typed
  `ForgeTransactionPermitFromDescriptor.hs` controls require DATA compilation with only the testing
  unit exposed and hidden-package refusal in the ordinary public context. In that testing-unit-only
  context, `ImportTransactionRunnerFromTestingUnit.hs` must instead refuse for a hidden Transaction
  module; a hidden-package refusal does not establish this boundary. `SessionSpec`'s SourceGuard
  stanza check requires private visibility, the exact Testing-only exposed list, Transaction in
  `other-modules`, and the main library's hidden copy. These controls construct no transaction permit.
  The runtime path has no fixture stop branch or injected crash counter.
- `CompileFailSpec` holds the prepared-pair fixtures: `ForgePreconditionSet.hs` (a caller cannot build an
  `OperationPreconditionSet` or a `DependencySnapshot`), `ForgePreparedGate.hs` (nor construct or relabel a
  `PreparedGate`), and `MismatchPreparedPairRoles.hs` (nor pair a `PreparedOperation` with
  `PreparedPreconditions` from a different operation or attempt).
- The live items above are held by the phase gates named in [Current Status](#current-status); their dated
  runs belong in those phases.

## Related

- [build and run model](../architecture/build_and_run_model.md) — the host-native build the gate kinds follow from.
- [code-check doctrine](code_check_doctrine.md) — where the formatter and linter run: the base publisher's host source gate, a derived image's `check-code`, and the base image smoke.
- [durable Windows runs](durable_windows_runs.md) — why only the long gate needs a durable launcher on Windows.
- [Haskell toolchain](../languages/haskell.md) — the host-portability idioms a suite uses.
- [harness workflow](../architecture/harness_workflow.md) — command/DSL/profile contract.
- [durable state](../architecture/durable_state.md) — the durable root, `.data` carry, and the gates that prove destroy/up/readback.
- [readiness](../architecture/readiness.md) — readiness witnesses and legible failure.
- [demo runbook](../operations/demo_runbook.md) — operator-facing demo commands and cautions.
