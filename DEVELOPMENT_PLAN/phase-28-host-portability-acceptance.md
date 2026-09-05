# Phase 28 — Host-portability acceptance

**Status**: Active
**Depends on**: Phase 24 (the worked demo)
**Substrates**: none (static)
**Gate**: the host static gate — `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/`,
`poetry run python -m hostbootstrap.check_code`, and `poetry run python -m hostbootstrap.test_all` — passing
host-native on a Windows, a macOS, and a Linux gate host, each recorded with its own dated evidence

> **Purpose**: Confirm on real machines that the sources § N builds host-native everywhere do in fact build
> and self-test on every supported gate host family.

## Phase Objective

This is an **acceptance phase** (§ II, § JJ). Nothing depends on it, so a machine with access to only one
family stops at the worked-demo phase. It declares no substrate: outer-host portability is not a substrate
declaration (§ II), and running a static suite on a Linux gate host proves nothing about a provider, a
container, or a POSIX process boundary.

It exists because of an ownership hole that would otherwise have no owner. § JJ obliges every phase to hold
the four harness rules over its own suites, and that obligation is mechanical — the absence guards check it
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
`WslGlobalWallWindowsSpec` cases exercised the Windows kernel. The manifest and total remained fixed; no case
was skipped.

#### Remaining Work

None.

### Sprint 28.2: macOS gate-host acceptance [Planned]

**Status**: Planned
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

The dated run.

#### Remaining Work

The run. As of 2026-09-05 the active Windows workspace has no configured macOS SSH target and this
repository has no GitHub Actions workflow or other macOS runner, so obtaining the dated host-native
evidence requires access to an Apple gate host.

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
case remained in the fixed family total. No case was skipped.

#### Remaining Work

None.

These are three sprints rather than one because the three runs are independent evidence obtained on
independent machines. Bundled into a single sprint, a family that is available cannot be recorded until the
family that is not becomes available, and the phase reports nothing while holding two thirds of its answer.
A family whose run is not available is named as owed rather than assumed, because a dated run is evidence
for the gate host that produced it and for no other (§ II).

## Remaining Work

Sprint 28.2 must record the macOS host-static run.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the gate-host term, the four harness rules, and where the dated
  cross-family evidence lives.

**Cross-references to add:**
- `DEVELOPMENT_PLAN/README.md` records the dated runs against this phase rather than repeating them in each
  baseline phase.
- `development_plan_standards.md` § JJ names this phase as the owner of cross-family confirmation.
