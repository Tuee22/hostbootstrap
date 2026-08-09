# Phase 20 — `test` and `context` command semantics

**Status**: Active
**Depends on**: Phase 19 (test harness and exclusive run ownership)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, plus a live `test init` / `test run` /
`context` sequence on linux-cpu

> **Purpose**: Fix the exact grammar and side-effect boundary of `test init`, `test run <case-id>|all`,
> `context`, and `check-code`.

Every sprint below is `Done` and the static half of the gate passes. What the phase still owes is its own
declared **live linux-cpu sequence**: `test init`, `test run`, and `context` run against a real host. The
overwrite policy and the case-selector surface are exactly what that sequence exercises, so it is owed against
their current shape rather than an earlier one.

## Phase Objective

The engine exists; this phase is the surface an operator actually types. Two properties matter: each verb's
grammar names what it operates on in the project's own typed vocabulary, and each verb's side effects are
exactly what its name implies — `context` reads and never writes, `test init` writes only the test config, and
`test run` is the only verb that mutates infrastructure.

## Sprints

### Sprint 20.1: `test init` and its overwrite policy [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Write the test config, and be explicit about replacing one.

#### Deliverables

- `test init` writes `<project>.test.dhall` from the project's own typed test-config vocabulary.
- The writer request is opaque: a caller supplies the project's typed values, not a rendered file, so core cannot
  be asked to write arbitrary bytes.
- The overwrite policy is stated rather than implied: an existing config is refused unless replacement is
  requested explicitly, and the refusal names the file.
- On a host with no build directory, `test run` refuses by naming the missing test config, which is the documented
  sequence rather than a defect.

#### Validation

`CLISpec` covers the grammar, the typed request, both overwrite branches, and the missing-config refusal:
a first `test init` writes, a second refuses and leaves an operator's edit byte-identical, and `--replace`
is the only route that overwrites. `cabal test all --ghc-options=-Werror` from `core/` passed 998/998 on
2026-08-05 (aarch64-osx, GHC 9.12.4), and the demo suite passed 112/112.

#### Remaining Work

None.

### Sprint 20.2: `test run <case-id>|all` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Select compiled cases by their typed identity.

#### Deliverables

- The selector takes a validated `CaseId` or `all`; an unknown case is refused by naming the compiled set rather
  than running nothing and reporting success.
- Help text and metavariables name a case, not a suite, so the surface matches the typed vocabulary.
- `test run` is the only verb in this phase with infrastructure side effects, and it enters through the harness
  ownership bracket.
- `check-code` is the project's canonical quality gate verb and is supplied by construction.

#### Validation

`CLISpec` covers selection, the unknown-case refusal — which exits non-zero naming the compiled set rather
than reporting an empty success — and the rendered help itself: the metavariable is `CASE-ID`, the
whole-matrix selector is named, and no surface text says "suite", asserted against the real `--help` output
of a subprocess running the actual parser.

#### Remaining Work

None.

### Sprint 20.3: Read-only `context` introspection [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Show the composition without touching anything.

#### Deliverables

- `context` renders the explicit binary context and the global compositional lift sequence for **every**
  `<project>.dhall` uniformly, without special-casing a frame.
- It performs no write of any kind — no config, no state, no provider call.
- It reads the plan's own frames, so what it prints is what the interpreter would descend.

#### Validation

`ContextSpec` covers the rendering for each frame and asserts no write occurs.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — the surfaced `test` and `context` grammar.
- `documents/architecture/binary_context_config.md` — read-only introspection.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the operator-facing test surface.

**Cross-references to add:**
- `development_plan_standards.md` § Z names this phase as the owner of the test/context grammar.
