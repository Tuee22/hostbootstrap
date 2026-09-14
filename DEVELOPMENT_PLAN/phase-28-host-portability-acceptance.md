# Phase 28 — Host-portability acceptance

**Status**: Active
**Depends on**: Phase 24 (the worked demo)
**Substrates**: none (static)
**Gate**: the host static gate — `cabal build all` and `cabal test all` from `core/`,
`poetry run python -m hostbootstrap.check_code`, and `poetry run python -m hostbootstrap.test_all` — passing
host-native on a Windows gate host, a macOS gate host, an x86_64 Linux gate host, and an arm64 Linux gate
host, each recorded with its own dated evidence
**Gate kind**: deferred
**Gate evidence**: 2026-09-11 ; x86_64 Windows 11 Home 10.0.26200, AMD Ryzen 7 5700G, GHC 9.12.4,
Cabal 3.16.1.0, repository-venv Python 3.14.7, Poetry 2.4.1 ; `cabal build all --ghc-options=-Werror` and `cabal test all --ghc-options=-Werror` from `core/`, then `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` ; pass ; covers c9c91d0b5dcfbbe1c18be2c54f8563d2767a5c6dc8113f11bfe35c539f8e4e65
**Gate evidence**: 2026-09-14 ; `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS, Linux 7.0.0-28-generic,
GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1 ; `cabal build all` and `cabal test all` from `core/`, then `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` ; pass ; covers 6186d83e0e060bf70b4090ee8176abf944debb25ebb5ad6fc7176e99df1ab2b0
**Gate evidence**: 2026-09-11 ; `MacBookPro`, native arm64 macOS 26.6.2 (build 25G83), Apple M1 Max,
GHC 9.12.4, Cabal 3.16.1.0, Python 3.14.3, Poetry 2.3.2 ; `cabal build all --ghc-options=-Werror` and `cabal test all --ghc-options=-Werror` from `core/`, then `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` ; pass ; covers c9c91d0b5dcfbbe1c18be2c54f8563d2767a5c6dc8113f11bfe35c539f8e4e65
**Gate evidence**: 2026-09-11 ; aarch64 Ubuntu 24.04.4 LTS container, Linux 6.8.0-100-generic, carried by
the Apple visit's MacBook Pro through Colima 0.10.3, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3,
Poetry 2.4.1 ; `cabal build all --ghc-options=-Werror` and `cabal test all --ghc-options=-Werror` from `core/`, then `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` ; pass ; covers c9c91d0b5dcfbbe1c18be2c54f8563d2767a5c6dc8113f11bfe35c539f8e4e65
**Evidence covers**: `core/hostbootstrap-core/src` `core/hostbootstrap-core/internal` `core/hostbootstrap-core/app` `core/hostbootstrap-core/test` `core/hostbootstrap-core/provider-live` `core/hostbootstrap-core/dhall` `core/hostbootstrap-core/hostbootstrap-core.cabal` `core/cabal.project` `hostbootstrap` `tests` `pyproject.toml`

> **Purpose**: Confirm on real machines that the sources § N builds host-native everywhere do in fact build
> and self-test on every supported gate host family.

## Phase Objective

This is an **acceptance phase** (§ II, § JJ). Nothing depends on it, so a machine with access to only one
family stops at the worked-demo phase. It declares no substrate: outer-host portability is not a substrate
declaration (§ II), and running a static suite on a Linux gate host does not establish live provider or container acceptance.
Compiled local fixtures can prove the native process and kernel behavior they actually exercise.

Per § G this phase is **expected to sit `Active` between runs**, and that is not a report of unfinished
work in this tree. Its covers set is the host-portable source itself, so any ordinary source change expires
the claim for every cell until each family re-runs. Reading `Active` here as a defect would invite the one
outcome the phase exists to prevent: quietly carrying a stale portability claim because re-recording it is
inconvenient. `Done` is reachable only in the window between the last source change and the next, with all
four cells freshly recorded.

It exists because of an ownership hole that would otherwise have no owner. § JJ obliges every phase to hold
the five harness rules over its own suites, and that obligation is mechanical — the absence guards check it
on any gate host. But *confirming the portability claim itself* needs three machines, and § C forbids a
baseline phase carrying a closure obligation for hardware it does not declare. Without this phase, either
every § JJ-touching sprint silently acquires a three-machine closure condition, or the claim that the suites
are host-portable is never confirmed at all. Here it is confirmed once, by the phase that declares it.

## What this phase confirms

- the complete host static gate passes host-native on a **Windows** gate host;
- it passes host-native on a **macOS** gate host;
- it passes host-native on an **x86_64 Linux** gate host and on an **arm64 Linux** gate host;
- the differences between those runs are the ones the suites *declare* — a case skipped on one family
  carries an explicit platform condition naming the frame it needs — and never an undeclared difference in
  totals;
- the § JJ absence guards are non-vacuous on each family, so a host-shaped idiom reintroduced on any of them
  fails the gate there.

The Linux family is split by architecture because § N builds every binary host-native: an x86_64 and an
arm64 Linux gate host compile and self-test genuinely different code from one source tree, so neither is
evidence for the other (§ JJ). The other two families are single-architecture in practice and carry no
such split.

This phase owns two of the five cells § JJ's coverage matrix names — `linux-cpu` on x86_64 and `linux-cpu`
on arm64 — plus the three gate-host families. The remaining three cells are substrate acceptances owned by
the [Apple-Silicon](phase-25-apple-silicon-substrate.md),
[NVIDIA-GPU](phase-26-nvidia-gpu-substrate.md), and
[Windows-and-WSL2](phase-27-windows-and-wsl2-substrate.md) phases. Because a hardware set is visited once
(§ JJ), those three visits also produce every gate-host result this phase needs, and this phase requires no
machine of its own: the Apple visit supplies the macOS gate host and an arm64 Linux gate host, the
Linux/NVIDIA visit supplies an x86_64 Linux gate host, and the Windows visit supplies the Windows gate host.
This phase never demands a fresh machine for a cell one of those visits already fills.

What this phase does **not** confirm is anything about a substrate. A gate host is identified by what it is
rather than by how it came to exist (§ JJ), so bare metal, a virtual machine, a container, and a WSL2
distribution each count as a gate host of their own family and architecture — and none of them is a
`linux-cpu` substrate gate. Each of the three substrate phases keeps its own declared gate.

## Sprints

### Sprint 28.1: Windows gate-host acceptance [Done]

**Status**: Done
**Implementation**: none — this sprint changes no source
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the host static gate passing host-native on a Windows gate host.

#### Deliverables

- One dated run naming the gate host's OS version, architecture, GHC and Cabal versions, test total, and
  duration. A gate host is identified by what it is rather than by how it came to exist, so metal, a virtual machine, and a container each count.
- The per-family differences this run's total reflects are enumerated against the suites' own platform
  conditions, so a difference in totals is explained by a condition a reader can find rather than by the
  run.
- The run asserts nothing the suites do not already assert. It confirms that what they assert holds here.

#### Validation

The dated run.

Completed 2026-09-05 on native x86_64 Microsoft Windows 11 Home 10.0.26200 with GHC 9.12.4,
Cabal 3.16.1.0, Python 3.12.10, and Poetry 2.4.1. `cabal build all --ghc-options=-Werror` passed,
`cabal test all --ghc-options=-Werror` passed 2,477/2,477, the Python code check passed, and the Python
suite passed 231/231. The reported component durations totalled 6 minutes: 20 seconds for the Cabal build,
327 seconds for the Haskell suite, 7 seconds for the Python code check, and 5 seconds for the Python suite.

The fixed coverage manifest reported the expected Windows realization: all POSIX ownership and shipped
guest-alias cases asserted their rows' declared refusal, while the Windows ownership families exercised the
Win32 kernel, `WslGlobalWallHostSpec` exercised its Windows host row, and three of four
`WslGlobalWallWindowsSpec` cases exercised the Windows kernel. No case in these fixed manifest families
was skipped.

The five-case difference from the POSIX total follows the explicit `mingw32_HOST_OS` conditions in
`HostToolSpec.windowsResolutionCases` (two Windows-only discovery cases), `LiftSpec.shellQuoteCases`
(one POSIX-only shell round-trip), `LiftSpec.effectCases` (five POSIX cases versus one Windows case),
and `LifecycleSpec.snapshotFilesystemFailureCases` (two POSIX-only filesystem cases). The manifest's fixed
families do not cover these conditional groups; the run is evidence for the cases its suite assembled.

Final working-tree refresh on 2026-09-05 on the same native Windows gate host passed
`cabal build all --ghc-options=-Werror` in 159.47 seconds and the complete core suite at
2,489/2,489 in 886.48 seconds (1,243.94 seconds including test compilation). The Python code check
passed and its suite passed 231/231 in 10.23 seconds. This includes Production closure, typed service
definitions, and the final architecture/documentation guards. The five-case difference from the final
macOS and Linux runs is the source selection enumerated above.

#### Remaining Work

None.

### Sprint 28.2: macOS gate-host acceptance [Done]

**Status**: Done
**Implementation**: none — this sprint changes no source
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the host static gate passing host-native on a macOS gate host.

#### Deliverables

- One dated run naming the gate host's OS version, architecture, GHC and Cabal versions, test total, and
  duration. The same rule applies, and Apple hardware is the only place this family can be obtained.
- The per-family differences this run's total reflects are enumerated against the suites' own platform
  conditions, so a difference in totals is explained by a condition a reader can find rather than by the
  run.
- The run asserts nothing the suites do not already assert. It confirms that what they assert holds here.

#### Validation

On 2026-09-05, native arm64 macOS 26.6.2 (build 25G83), with GHC 9.12.4, Cabal 3.16.1.0,
Python 3.14.3, and Poetry 2.3.2, passed `cabal build all` in 146.13 seconds, the Python code check
in 9.74 seconds, and the Python suite at 231/231 in 4.48 seconds (1.94 seconds of pytest execution).
`cabal test all --ghc-options=-Werror --test-show-details=direct` passed 2,482/2,482 in 509.20 seconds
including test compilation; the suite itself took 375.83 seconds. Successful component durations totalled
669.55 seconds (11 minutes 10 seconds).

The fixed coverage manifest exercised the POSIX ownership, host-wall, and shipped guest-alias rows against
the Darwin kernel. The Windows ownership families and the three platform-row cases in
`WslGlobalWallWindowsSpec` asserted their declared refusal; its platform-neutral case remained present.
The total matches Linux. The five-case difference from Windows is the explicit source selection described
in Sprint 28.1; this run does not establish coverage for a case another host does not execute.

Final working-tree refresh on 2026-09-05 on the same native arm64 macOS 26.6.2 gate host passed
`cabal build all --ghc-options=-Werror` and the complete core suite at 2,494/2,494 in 402.88 seconds.
The Python code check passed and its suite passed 231/231 in 1.35 seconds. This includes Production closure,
typed service definitions, and the final architecture/documentation guards. Platform accounting retains
the same five-case source-condition difference from Windows.

#### Remaining Work

None.

### Sprint 28.3: Linux gate-host acceptance [Done]

**Status**: Done
**Implementation**: none — this sprint changes no source
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the host static gate passing host-native on an x86_64 Linux gate host.

#### Deliverables

- One dated run naming the gate host's OS version, architecture, GHC and Cabal versions, test total, and
  duration. Per § JJ bare metal, a virtual machine, a container, and a WSL2 distribution are each a Linux
  gate host of their own right, so this cell does not require separate metal.
- The per-family differences this run's total reflects are enumerated against the suites' own platform
  conditions, so a difference in totals is explained by a condition a reader can find rather than by the
  run.
- The arm64 Linux cell is a separate one, because § N compiles different code for each architecture. It is
  recorded by Sprint 28.4 on the Apple visit that can produce it, and this sprint makes no claim about it.
- The run asserts nothing the suites do not already assert. It confirms that what they assert holds here.

#### Validation

Completed 2026-09-05 on x86_64 Ubuntu 24.04.4 LTS under WSL2, identified as a Linux gate host by
the guest OS rather than by its substrate, with GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, and
Poetry 2.4.3. A cold `cabal build all` passed, `cabal test all --ghc-options=-Werror` passed
2,482/2,482, the Python code check passed, and the Python suite passed 231/231. The recorded
successful component durations totalled 17 minutes 17 seconds: 863 seconds for the cold Cabal
build, 168 seconds for the Haskell suite, 3 seconds for the Python code check, and 2 seconds for
the Python suite.

The fixed coverage manifest reported the expected Linux realization: every `WslGlobalWallHostSpec`
POSIX-row case, every POSIX ownership case, and every shipped guest-alias case exercised its row
against the Linux kernel. Every Windows ownership case and the three platform-row cases in
`WslGlobalWallWindowsSpec` asserted their declared refusal; that family's fourth, platform-neutral
case remained in the fixed family total. No case in these fixed manifest families was skipped. The
five-case difference from Windows follows the source conditions enumerated in Sprint 28.1.

Final working-tree refresh on 2026-09-05 also passed on native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, and Poetry 2.4.1.
`cabal build all --ghc-options=-Werror` passed; the complete core suite passed 2,494/2,494 in
148.63 seconds. The Python code check passed and its suite passed 231/231 in 1.34 seconds.
The final documentation-only revalidation passed 3/3 in 0.95 seconds after status reconciliation.

#### Remaining Work

None.

These are three sprints rather than one because the three runs are independent evidence obtained on
independent machines. Bundled into a single sprint, a family that is available cannot be recorded until the
family that is not becomes available, and the phase reports nothing while holding two thirds of its answer.
A family whose run is not available is named as owed rather than assumed, because a dated run is evidence
for the gate host that produced it and for no other (§ II).

### Sprint 28.4: The current-tree portability run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the host static gate passing host-native on each gate-host cell against the current tree: a
Windows gate host, a macOS gate host, an x86_64 Linux gate host, and an arm64 Linux gate host.

#### Deliverables

- four dated runs, one per gate-host cell, each naming its family, architecture, machine, and toolchain
  versions;
- the per-family difference in totals enumerated against the suites' own platform conditions;
- each run collected on a visit already owed to a substrate acceptance, so this sprint adds no visit of its
  own (§ JJ). A cell still owed is named as owed, never inferred from a neighbouring cell.

#### Validation

On 2026-09-11, the current source passes the native Windows family gate on x86_64
Windows 11 Home 10.0.26200 with an AMD Ryzen 7 5700G, GHC 9.12.4, Cabal 3.16.1.0,
repository-venv Python 3.14.7, and Poetry 2.4.1. From `core/`, the warning-clean build passes and
`cabal test all --ghc-options=-Werror` passes 2,500/2,500 in 338.12 seconds of suite execution; the
provider-live component reports its declared no-request `Unsupported` outcome. From the repository
root, `poetry run python -m hostbootstrap.check_code` passes and
`poetry run python -m hostbootstrap.test_all` passes 235/235 in 3.92 seconds. The Windows ownership
families execute their native rows, and the POSIX-only process fixtures assert their declared refusals,
which is the platform condition the Windows total reflects. That core run carries the documentation
validator, so it is also the run under which this plan's current text passes.

The Python environment is reconstructed from `pyproject.toml` on this gate host, because `poetry.lock`
is deliberately untracked and each family resolves its own. That is what makes a per-family Python run
evidence about that family's resolved toolchain rather than a replay of another's.

On the same date, the current source passes the x86_64 Linux cell on `matt-junction`, native x86_64
Ubuntu 24.04.4 LTS, Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, and Poetry 2.4.1.
From `core/`, `cabal build all --ghc-options=-Werror` passes in 114.56 seconds and
`cabal test all --ghc-options=-Werror` passes 2,505/2,505 core cases in 169.73 seconds of suite
execution (174.20 seconds for the complete Cabal command). Both components run: the core suite reports
its Apple lane as `Unsupported: native direct-Colima lane not requested`, and the provider-live component
compiles and reports `Unsupported: provider-live not requested`. Each is the declared no-request outcome
of a row that cannot hold its clause on this gate host, which § NN counts as evidence rather than as a
missing case. From the repository root, `poetry run python -m hostbootstrap.check_code` passes
and `poetry run python -m hostbootstrap.test_all` passes 235/235 in 1.59 seconds. The POSIX ownership,
host-wall, and shipped guest-alias rows execute against the Linux kernel, while the Windows ownership
families and the three platform rows in `WslGlobalWallWindowsSpec` assert their declared refusals. The
five-case difference from the Windows total is the source selection enumerated in Sprint 28.1.

This cell was collected on the visit [phase 26](phase-26-nvidia-gpu-substrate.md) already required, which
is the § JJ rule working as intended: the machine convened for the nvidia substrate also carries the
x86_64 Linux gate host, and recording both in one sitting removes any later reason to return to it.

The Python environment on this gate host is likewise reconstructed from `pyproject.toml`, resolving
Python 3.12.3 rather than replaying the Windows family's 3.14.7.

On the same date, the current source passes the macOS cell on `MacBookPro`, native arm64 macOS 26.6.2
(build 25G83) on an Apple M1 Max, with GHC 9.12.4, Cabal 3.16.1.0, Python 3.14.3, and Poetry 2.3.2. From
`core/`, `cabal build all --ghc-options=-Werror` passes in 215.73 seconds and
`cabal test all --ghc-options=-Werror --test-show-details=direct` passes 2,505/2,505 core cases in
412.49 seconds of suite execution (590.05 seconds for the complete Cabal command). Both components run:
the core suite reports its Apple lane as `Unsupported: native direct-Colima lane not requested`, which is
the declared no-request outcome of an opt-in lane [phase 25](phase-25-apple-silicon-substrate.md) records
live, and the provider-live component compiles and reports `Unsupported: provider-live not requested`. From
the repository root, `poetry run python -m hostbootstrap.check_code` passes and
`poetry run python -m hostbootstrap.test_all` passes 235/235 in 5.71 seconds of pytest execution. The fixed
coverage manifest exercises the POSIX ownership, host-wall, and shipped guest-alias rows against the Darwin
kernel, while the eleven Windows ownership cases and three of the four `WslGlobalWallWindowsSpec` cases
assert their declared refusals. The total matches both Linux cells, and the five-case difference from the
Windows total is the source selection enumerated in Sprint 28.1.

On the same date, the current source passes the arm64 Linux cell on an aarch64 Ubuntu 24.04.4 LTS
container, Linux 6.8.0-100-generic with 9 CPUs and 31 GiB, carried by that same Apple visit through
Colima 0.10.3, with GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, and Poetry 2.4.1. Its covered source is
byte-identical to the macOS cell's. From `core/`, a clean `cabal build all --ghc-options=-Werror` passes in
122.71 seconds and `cabal test all --ghc-options=-Werror --test-show-details=direct` passes 2,505/2,505
core cases in 148.69 seconds of suite execution (250.78 seconds for the complete Cabal command), with the
same two declared no-request outcomes. From the repository root,
`poetry run python -m hostbootstrap.check_code` passes and
`poetry run python -m hostbootstrap.test_all` passes 235/235 in 1.68 seconds. The fixed coverage manifest
reports the same Linux realization the x86_64 cell reports, row for row and count for count, which is what
makes the two architectures comparable evidence rather than one standing in for the other.

A container gate host runs under a reaping PID 1. `ColimaSpec`'s hard-parent-death case proves that the
runner's process group dies with its parent by polling the grandchild with signal 0, and a PID 1 that never
reaps leaves that grandchild a zombie the probe still finds. The kernel behaviour under test is the same on
either arrangement; only a reaping init lets the case observe it. This is a property of how a gate host is
assembled (§ JJ), not of the source, and it is named here so the next container visit does not rediscover
it.

The Python environment on each of these two gate hosts is likewise reconstructed from `pyproject.toml`,
resolving Python 3.14.3 on the macOS cell and Python 3.12.3 on the arm64 Linux cell.

The core suite carries the documentation validator, so this plan's text is itself gated by these runs. After
the status reconciliation this sprint's closure entails, that validator passes 5/5 against the current text
on both cells, which is what makes the recorded runs evidence for the document a reader is holding rather
than for an earlier draft of it.

#### Remaining Work

None. Every cell this sprint owns has current-source evidence. Any further host-portable source change
expires all four and requires fresh coverage from each.

### Sprint 28.5: The host-portability acceptance against the current tree [Active]

**Status**: Active
**Implementation**: none — this sprint records a run
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`

#### Objective

This phase's evidence covers the host-portable tree, so ordinary source change expires its claim —
which § G names as the expected state for an acceptance phase between runs rather than as an unclosed
phase. The claim is re-established by running the gate on each gate host family, not by re-recording a digest
over a tree nothing re-tested. The four gate-host runs this phase records are produced by three visits; no fourth machine is required.

#### Deliverables

- The phase's declared gate is re-run in full on the hardware it declares.
- A gate-evidence row records the date, the gate host, the command as run, and the result.
- The row names which program ran where two share a name, and prefers an invocation against the tree over a separately installed one.
- The covers digest is re-measured over this phase's own paths and recorded.
- Every cell this hardware can produce is recorded in the same visit, so the machine is not owed a second one.

#### Validation

The phase's own gate, on its own hardware. Re-recording the digest without the run is the one thing
this sprint may not do.

#### Remaining Work

The Windows, macOS and arm64 Linux cells are owed at the next visit to each. The x86_64 Linux cell is
recorded: on 2026-09-14, on the host its row names, `cabal build all` and `cabal test all` from `core/`
passed 2,546/2,546 in 200.71 seconds, `poetry run python -m hostbootstrap.check_code` passed, and
`poetry run python -m hostbootstrap.test_all` passed 251/251 with the coverage configuration's
`fail_under = 100` satisfied at 1,413/1,413 statements. That row's digest is the current one; the other
three still carry the digest of the tree they measured, which is what marks them owed.

## Remaining Work

Three of this phase's four cells are owed against the current tree — Windows, macOS, and arm64 Linux —
each at the next visit to the hardware that carries it. The x86_64 Linux cell is current.
**Sprint 28.5** owns the remaining three.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the gate-host term, the five harness rules, and where the dated
  cross-family evidence lives.

**Cross-references to add:**
- `DEVELOPMENT_PLAN/README.md` records the dated runs against this phase rather than repeating them in each
  baseline phase.
- `development_plan_standards.md` § JJ names this phase as the owner of cross-family confirmation.
