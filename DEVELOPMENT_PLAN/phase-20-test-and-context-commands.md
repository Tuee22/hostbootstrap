# Phase 20 — `test` and `context` command semantics

**Status**: Active
**Depends on**: Phase 19 (test harness and exclusive run ownership)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`, plus the focused `CLISpec` and `ContextSpec`
groups inside a realized linux-cpu host
**Gate kind**: deferred
**Gate evidence**: 2026-09-09 ; x86_64 Ubuntu 24.04.4 LTS realized through WSL2 on Windows 11 Home 10.0.26200, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test hostbootstrap-core-test --ghc-options=-Werror --test-show-details=direct --test-options=--pattern=CLISpec` ; pass ; covers 1168c0e1694c1337ac62b2d1267a212e4b49f343ec032ac6acf0a5bf014d0861
**Gate evidence**: 2026-09-09 ; x86_64 Ubuntu 24.04.4 LTS realized through WSL2 on Windows 11 Home 10.0.26200, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test hostbootstrap-core-test --ghc-options=-Werror --test-show-details=direct --test-options=--pattern=ContextSpec` ; pass ; covers 1168c0e1694c1337ac62b2d1267a212e4b49f343ec032ac6acf0a5bf014d0861
**Evidence covers**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs` `core/hostbootstrap-core/test/CLISpec.hs` `core/hostbootstrap-core/test/ContextSpec.hs`

> **Purpose**: Fix the exact grammar and side-effect boundary of `test init`, `test run <case-id>|all`,
> `context`, and `check-code`.

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

### Sprint 20.4: Realized-Linux verb-sequence acceptance [Done]

**Status**: Done
**Implementation**: none — this sprint changes no source
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the live sequence this phase's grammar owes, as a sprint rather than as a preamble nothing counts.

#### Deliverables

- Zero production lines. Sprints 20.1 through 20.3 close on the host static gate; what is left is running
  the verbs where their side effects are real.
- The phase-owned concrete command fixture invokes the real parser for `test init`, `test run`, and `context`
  inside a realized Linux substrate. Its focused `CLISpec` and `ContextSpec` groups prove the side-effect
  boundary each verb's name implies — `context` reads and never writes, `test init` writes only the test
  config, and `test run` is the only verb that enters Harness mutation.
- The overwrite policy and the case-selector surface are exercised against their exact current shape,
  because a sequence run against an older grammar is evidence about that grammar.
- Dated evidence names the substrate realization and the outer host.

#### Validation

The focused real-parser groups. They assert nothing beyond this phase's static contract; running them inside
the realized substrate confirms that the exact current parser, typed fixture, filesystem effects, and process
exit behavior hold on linux-cpu without importing the worked demo's later provider and workload lifecycle.

Dated realized-host evidence: on 2026-08-22, inside a disposable Ubuntu 24.04 amd64 Incus VM on a Linux
outer host, `CLISpec` passed 57/57 with `--ghc-options=-Werror`, including the actual `test init` → exact
Harness `test run` paths, overwrite/refusal cases, selector/help grammar, and cleanup. `ContextSpec` plus the
matching `LiftContextSpec` selection passed 84/84 with `--ghc-options=-Werror`, including read-only rendering,
missing/decode refusals, topology/current-frame validation, and the pure lift composition.

#### Remaining Work

None.

### Sprint 20.5: The realized-host CLI and context run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated focused `CLISpec` and `ContextSpec` selection inside a realized linux-cpu host.

#### Deliverables

- one dated run of both groups with `--ghc-options=-Werror` inside a realized linux-cpu host.

#### Validation

On 2026-09-06, both focused groups passed inside a realized `linux-cpu` host — the published
`basecontainer-cpu-arm64` base at digest
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`, reporting `Linux aarch64`
with the pinned GHC 9.12.4 and Cabal 3.16.1.0. `CLISpec` passed `58/58` and `ContextSpec` passed
`85/85`, both under `-Werror`.

The run is recorded against a writable copy of the working tree inside the realization. A first attempt
mounted the tree read-only and four `CLISpec` cases refused with
`could not take the run liveness lock: … Read-only file system`. That is the harness being observed
correctly rather than a defect: those cases take the protected store's run-liveness lock under the
project root, so a root that cannot be written is a refusal the ownership seam is supposed to produce.
It is recorded because it is the difference between this gate having run and having appeared to.

On 2026-09-09, the focused `CLISpec` group passes 64/64 in 2.12 seconds and the `ContextSpec`
selection passes 85/85 in 0.23 seconds on Ubuntu 24.04.4 LTS through WSL2, using GHC 9.12.4
and Cabal 3.16.1.0. The complete core gate passes 2,504/2,504 in 190.86 seconds on that realization
and 2,499/2,499 in 499.45 seconds on the Windows outer host. All 971 tracked working-tree files
match the validated Linux copy byte for byte. The focused command selection retains the read-only
context and exact Harness mutation boundaries; its covered digest matches the header evidence.

#### Remaining Work

None.

### Sprint 20.6: The initializer carries the role it parsed [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

§ Z fixes this surface's grammar and its side-effect boundary. The initializer takes its default role
as rendered text and hands that text to a decision about installed identity, so the surface is where a
parsed value is turned back into a string and compared. This sprint is the command-surface half of that
change: the parser's default and help text are rendered from the role value rather than carrying a
second literal spelling of it.

#### Deliverables

- The initializer's role parameter is the parsed role kind.
- The parser default and its help text render that value.
- No literal role spelling remains at this surface.
- The command suite covers an aliased and a normalised spelling reaching the same parsed value.

#### Validation

The host static gate, plus this phase's focused command and context suites. The gate-evidence row
records both the full suite and the focused legs its gate names.

#### Remaining Work

None beyond the phase's own.

## Remaining Work

The initializer surface is owed the parsed role rather than its rendered text, and this
phase's gate evidence is owed a row that records both legs its gate names. **Sprint 20.6** owns both.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — the surfaced `test` and `context` grammar.
- `documents/architecture/binary_context_config.md` — read-only introspection.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the operator-facing test surface.

**Cross-references to add:**
- `development_plan_standards.md` § Z names this phase as the owner of the test/context grammar.
