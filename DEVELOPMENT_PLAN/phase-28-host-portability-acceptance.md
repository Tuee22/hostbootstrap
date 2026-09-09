# Phase 28 — Host-portability acceptance

**Status**: Active
**Depends on**: Phase 24 (the worked demo)
**Substrates**: none (static)
**Gate**: the host static gate — `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/`,
`poetry run python -m hostbootstrap.check_code`, and `poetry run python -m hostbootstrap.test_all` — passing
host-native on a Windows, a macOS, and a Linux gate host, each recorded with its own dated evidence
**Gate kind**: deferred

> **Purpose**: Confirm on real machines that the sources § N builds host-native everywhere do in fact build
> and self-test on every supported gate host family.

## Phase Objective

This is an **acceptance phase** (§ II, § JJ). Nothing depends on it, so a machine with access to only one
family stops at the worked-demo phase. It declares no substrate: outer-host portability is not a substrate
declaration (§ II), and running a static suite on a Linux gate host does not establish live provider or container acceptance.
Compiled local fixtures can prove the native process and kernel behavior they actually exercise.

It exists because of an ownership hole that would otherwise have no owner. § JJ obliges every phase to hold
the five harness rules over its own suites, and that obligation is mechanical — the absence guards check it
on any gate host. But *confirming the portability claim itself* needs three machines, and § C forbids a
baseline phase carrying a closure obligation for hardware it does not declare. Without this phase, either
every § JJ-touching sprint silently acquires a three-machine closure condition, or the claim that the suites
are host-portable is never confirmed at all. Here it is confirmed once, by the phase that declares it.

## What this phase confirms

- the complete host static gate passes host-native on a **Windows** gate host;
- it passes host-native on a **macOS** gate host;
- it passes host-native on a **Linux** gate host;
- the differences between those runs are the ones the suites *declare* — a case skipped on one family
  carries an explicit platform condition naming the frame it needs — and never an undeclared difference in
  totals;
- the § JJ absence guards are non-vacuous on each family, so a host-shaped idiom reintroduced on any of them
  fails the gate there.

What this phase does **not** confirm is anything about a substrate. A gate host is identified by what it is
rather than by how it came to exist (§ JJ), so a virtual machine, a container, and a WSL2 distribution each
count as a gate host of their own family — and none of them is a `linux-cpu` substrate gate. The
[Apple-Silicon](phase-25-apple-silicon-substrate.md),
[NVIDIA-GPU](phase-26-nvidia-gpu-substrate.md), and
[Windows-and-WSL2](phase-27-windows-and-wsl2-substrate.md) acceptance phases own the hardware-context
confirmations, and each keeps its own declared gate.

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

Record the host static gate passing host-native on a Linux gate host.

#### Deliverables

- One dated run naming the gate host's OS version, architecture, GHC and Cabal versions, test total, and
  duration. Per § JJ a WSL2 distribution and a container are each a Linux gate host of their own right, so this family does not require separate metal.
- The per-family differences this run's total reflects are enumerated against the suites' own platform
  conditions, so a difference in totals is explained by a condition a reader can find rather than by the
  run.
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

### Sprint 28.4: The current-tree portability run [Active]

**Status**: Active
**Implementation**: none — this sprint records a run
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the host static gate passing host-native on a Windows, a macOS, and a Linux gate host against
the current tree.

#### Deliverables

- three dated runs, one per gate family, each naming its host and toolchain versions;
- the per-family difference in totals enumerated against the suites' own platform conditions.

#### Validation

On 2026-09-09, the current source passes the native Windows family gate on x86_64
Windows 11 Home 10.0.26200 with GHC 9.12.4, Cabal 3.16.1.0, Python 3.14.7, and Poetry 2.4.1.
The warning-clean core build passes; `cabal test all --ghc-options=-Werror` passes 2,500/2,500
in 504.50 seconds, and the provider-live component reports its declared no-request Unsupported
outcome. The Python code check and 235/235 tests pass. The documentation-only check subsequently
passes 5/5 in 6.36 seconds. The Windows ownership families execute their native rows; POSIX-only
process fixtures assert their declared refusals.

The same source's complete core gate also passes inside an Ubuntu 24.04.4 WSL guest at 2,505/2,505
in 291.83 seconds with GHC 9.12.4 and Cabal 3.16.1.0. Its real separate-process recursive fixtures
and Linux ownership rows execute; the five-case total difference follows the suite's platform
conditions. This is Linux guest core evidence, not a complete native Linux outer-host family gate.
That task-created guest is removed at the user-requested pause. A current-source macOS family
result and a complete native Linux family result remain owed.

#### Remaining Work

Run the complete current-source host-static gate on native macOS and native Linux gate hosts.
The Windows family passes; the Linux guest core result is supplementary evidence. Any further
host-portable source change requires fresh coverage from every affected family.

## Remaining Work

Sprint 28.4 owns the current-source macOS and native Linux family runs and their platform accounting.
Access to those gate hosts is required; the available Windows family has passing evidence.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the gate-host term, the five harness rules, and where the dated
  cross-family evidence lives.

**Cross-references to add:**
- `DEVELOPMENT_PLAN/README.md` records the dated runs against this phase rather than repeating them in each
  baseline phase.
- `development_plan_standards.md` § JJ names this phase as the owner of cross-family confirmation.
