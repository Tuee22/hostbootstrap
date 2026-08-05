# Phase 17: Chain-driven test and context introspection

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [00-overview.md](00-overview.md), [README.md](README.md)

> **Purpose**: Converge config writers on explicit typed requests/overwrite policy, converge the test
> surface on a `test init` writer and target root-only `test run <case-id>|all` runner gated on typed
> `<project>.test.dhall` and **decoupled from any second deploy representation**, and make each read-only `context`
> route explicit about the config input it reads.

## Phase Status

**Status**: Blocked
**Blocked by**: Sprints 10.9 and 15.9
**Satisfied prerequisite**: Sprint 19.8

**Reopened 2026-07-24.** Sprint 17.4 owns discrepancies between the documented and parsed init-writer,
`test`, and `context` semantics. Earlier positive real runs do not validate the negative parser/gate or
overwrite-policy surface.

**Reopened (2026-06-19) and closed (2026-06-20)**: `test run` drives the real `project up`, enforces the two
fail-fast safety preconditions, uses the L0 `.test_data` self-created-only delete-guard, and deletes only
what it created; `context` is uniform over all `<project>.dhall`s and read-only. Real-run-validated on a 16
GiB Apple-Silicon host (2026-06-20): `test run all` reported `3/3 passed` driving the same `project up` and
tearing down with `project destroy` (see `## Remaining Work`).

The current parser selects a single compiled case ID (or `all`) and drives the project's `TestSuite`
through `runMatrix`, but it does not yet prove the documented root-only/context gate and older prose
incorrectly describes suites and an existing-config requirement for `test init`. Sprint 17.4 owns that
repair. The read-only `context` command renders the
global lift composition (`topologyFrames` / `parentChain`) with the current frame highlighted
(`HostBootstrap.Context.renderComposition` + `context inspect`, `ContextSpec`), absorbing the former
`config schema` / `config show FILE` / `config path` / static `config render` surfaces; it performs no
mutation. The standardized harness (`HostBootstrap.Harness`) stays the one context-agnostic lift-target
engine the split surface invokes (§ W).

For each decoded variant, `test run` generates the run's project config, drives the real `project up`,
asserts against that acquired stack, and attempts `project destroy`; it does not attach to an arbitrary
already-running stack. The recursive apply is owned by
[phase-16](phase-16-project-lifecycle-command.md), and exclusive run ownership/failure isolation by
[phase-10](phase-10-standardized-test-harness.md).

The implemented command/config-input matrix that Sprint 17.4 must preserve or deliberately refine is:

| Surface | Current config behavior |
|---|---|
| Help | Config-free |
| `project init`, `service init`, `test init` | Config-free writers |
| `service schema`, `context path`, `context schema`, `context render` | Static and config-free |
| `context inspect` | Reads the executable-sibling `<project>.dhall`; no command-authority gate |
| `context show [FILE]` | Reads the selected/default file; no command-authority gate |
| `test run <case-id>\|all` | Reads `<project>.test.dhall` and installs each run variant through the four § EE ownership clauses of `HostBootstrap.Harness.GeneratedConfig` — a found config is refused before any mutation, and cleanup unlinks only on an exact re-observed kernel identity and payload, but currently does not prove the target root authority; Phase 10.9 still owns verified receipts for the rest of this path |
| `project up\|down\|destroy`, `service run`, `check-code` | Read and gate on the sibling `<project>.dhall` |

The current shared init parser gives `project init` `--role`, repeatable `--also-role`, `--output`,
`--force`, and `--if-missing`; no policy flags means a fresh sibling host-orchestrator root and an
existing output is refused. `--force` overwrites, `--if-missing` is a no-op on an existing output, and
supplying both currently gives `--force` precedence. `test init` has no such flags and currently writes
its test config without an explicit existing-file policy. Sprint 17.4 owns the target opaque
writer-specific request types and one explicit overwrite-policy model; Phase 15.9 owns whether a
requested role combination may mint command authority.

## Remaining Work

**Current:** Sprint 17.4 is Blocked by Sprints 10.9 and 15.9; Sprint 19.8 is closed. It then owns exact writer
request/overwrite behavior, parser/gate semantics for `test init`, `test run <case-id>|all`, and
input-specific read-only `context`.

[Phase 19](phase-19-generic-project-model.md) builds **forward** on this surface (the generic project
model, § BB): `<project>.test.dhall` becomes a thin override and `test run` *generates* the run's `<project>.dhall`
from it via the Harness request of the project-owned scope-aware `psAssemble`, and `test init` no longer
requires a pre-existing
`<project>.dhall`. The superseded `test`-reuses-existing-config flow is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with phase 19 as owner. Sprint 17.4 now
reopens this phase for the remaining parser/gate mismatch.

**Native-Linux test parity — DONE (2026-06-21).** `test run all` now reports **`3/3 passed` on native
Incus/Linux** as well as Apple-Silicon/Lima. The fix generalized the self-reference lift's leaf
(`HostBootstrap.Lift`: `LiftLeaf = SelfSub | RawCmd`, `foldLeaf`, `liftLeaf`, `reachLeaf`; `foldLift` is now
the `SelfSub` special case), so a reachability check is a pure probe placed in the frame where the NodePort
is published (the VM). The demo's `pristine-bootstrap` / `web-build` assertions now fold their `curl` into
the VM frame (`incus exec <vm> -- curl …` / `limactl shell <vm> -- curl …`) like `e2e-tabs`, so they pass
on both providers with zero provider-specific assertion code; the ad-hoc `runInVMCapture` provider switch
was removed. Validated by `cabal test` (5 new `LiftSpec` `foldLeaf` cases) and a real `test run all` →
`3/3 passed` on this Incus host (2026-06-21).

Make the test surface **drive** `project up` and enforce the safety contract
(development_plan_standards § Z).

**Landed in code (2026-06-19), code-check-validated** (`cabal test all` green):

- The stack-driven `TestSuite` (phase-10) makes `test run` drive the real `project up` and tear down with
  `project destroy` — one bring-up per distinct test config, no second bring-up path. The demo wires
  `demoTestUp` (`project up`) / `demoTestDown` (`project destroy`) via the binary self-reference.
- Two **cooperative fail-fast negative checks** are enforced by `testSafetyPreconditions` before
  bring-up: refuse an already-visible production config and refuse an already-visible metal Kind or
  managed provider VM (the demo's `demoTestSafety` supplies the detector). These checks do not reserve
  absence atomically and cannot exclude a concurrent starter; Sprint 10.9 owns the authoritative
  project-mode lease and identity-bearing reservations.
- The read-only `context` command already treats all `<project>.dhall`s uniformly and has **absorbed** the
  former `config schema` / `config show FILE` / `config path` / static `config render` surfaces (the
  `context` group is `inspect` / `show` / `schema` / `render` / `path`); the `context create` mutation verb
  is gone. Child projection/delivery is internal `project up` work and is currently split from the
  announcing `context-init` row. No mutation surface remains on `context`.
  `inspect` reads the executable sibling, `show` reads its selected/default file, and
  `path`/`schema`/`render` are static and config-free.

**Real-run-validated (2026-06-20):** on a 16 GiB Apple-Silicon host, `test run all` enforced the safety
preconditions, drove the real `project up`, asserted against the live stack in-frame (NodePort reachability
from the harness frame + the `e2e-tabs` Playwright run lifted into the VM frame), and tore down with
`project destroy` — **`3/3 passed`** ([phase-13](phase-13-hostbootstrap-demo.md)).

**`.test_data` self-created-only delete-guard landed (2026-06-20)** (co-owned with the L0 engine,
[phase-10](phase-10-standardized-test-harness.md)): `runSuiteSelection` wraps each run's bring-up / assert /
teardown in `HostBootstrap.Harness.withSelfCreatedTestData testDataRoot`, so `test run` creates `.test_data`
under the self-created-only guard and removes only what it created — never a `.test_data` (or `.data`) it
found (the pure `selfCreatedTestDataRemoval` is unit-tested). **Historical 2026-06-20 shape:** the reflected
record carried `testSuites` + a `testResources` override (`TestConfig`
in `HostBootstrap.Config.Schema`); `test init` writes it and `test run` decodes and reports the test-config
resources before running (round-trip unit-tested, tracked in
[phase-10](phase-10-standardized-test-harness.md)). `testSuites` was confirmed dead configuration and
removed by Phase 19.6; path-based cleanup is replaced by Phase 10.9 ownership receipts.

## Phase Objective

Land the chain-driven test surface and the read-only composition-introspection command:

- Opaque writer-specific init requests rather than one permissive shared argument bag: the current
  `project init` role/output/policy flags retain their fresh-root default, while project, service, and test
  writers expose only semantically valid fields and one explicit overwrite policy. Phase 15.9 validates
  the resulting role/class authority.
- A `test init` command that writes the per-project `<project>.test.dhall` (which may carry test-specific
  configuration) without requiring a pre-existing sibling `<project>.dhall`.
- A `test run <case-id>|all` command that runs one registered typed case or all registered cases is
  **root-only** and fails fast without typed `<project>.test.dhall` or from any non-root context.
- The test surface is **decoupled** from a second deploy representation: per variant the harness drives
  the real `project up`, asserts, and destroys that stack rather than re-expressing bring-up as a parallel
  chain of lifted operations
  ([development_plan_standards.md § W](development_plan_standards.md)).
- The standardized harness (`HostBootstrap.Harness`) stays the one context-agnostic lift-target engine the
  split surface invokes; the test surface adds no `LiftContext` to the harness.
- A **read-only** `context` command with explicit inputs: `inspect` reads the executable sibling,
  `show [FILE]` reads the selected/default file, and `path`/`schema`/`render` are static and config-free.
  `inspect`/`show` render the global lift composition (`topologyFrames` / `parentChain`) with the current
  frame highlighted. No route mutates; child-config creation is internal `project up` work, currently
  split from the announcing `context-init` row and targeted for one plan-owned operation
  ([development_plan_standards.md § Y](development_plan_standards.md)), not a `context` subcommand.

## Sprints

### Sprint 17.1: `test init` writer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`

#### Objective

Add a `test init` command that writes the per-project `<project>.test.dhall`, which may carry test-specific
configuration over the project's reusable Dhall vocabulary. Phase 19 later removed the pre-existing
`<project>.dhall` requirement, so this bootstrap path now works from a clean slate.

#### Deliverables

- A `test init` subcommand on the surfaced core command tree
  ([development_plan_standards.md § P, § Z](development_plan_standards.md)) that writes `<project>.test.dhall` next
  to the executable-sibling config path without requiring a production `<project>.dhall`.
- A `<project>.test.dhall` schema and writer using the admitted test-config codec, carrying
  test-specific configuration alongside the project's reusable Dhall vocabulary
  ([development_plan_standards.md § Q](development_plan_standards.md)). Closed Phase 8 Sprint 8.7
  rejects encoder/decoder type-expression drift by construction.
- The writer is the only surface that materializes `<project>.test.dhall`. The current parser exposes no
  `--force` or `--if-missing` flags and writes through the generic writer, replacing an existing test
  config; Sprint 17.4 must replace that implicit behavior with the explicit writer-specific overwrite
  policy without documenting unsupported current options.

#### Validation

- Historical tests covered the initial writer. Blocked Sprint 17.4 owns clean-slate and existing-file
  matrix validation for the current/target request semantics; that follow-on does not reopen this sprint.
- Schema round-trip tests prove the rendered `<project>.test.dhall` decodes back to the harness configuration type.
- `cabal test all` from `core/` and `poetry run python -m hostbootstrap.test_all` pass.

#### Remaining Work

None for the initial writer landing. Current behavior works from a clean slate and overwrites an existing
test config without a policy flag. The typed case/variant replacement landed in Phase 19.6, and blocked
Sprint 17.4 owns the later opaque request and explicit overwrite-policy refinement; neither reopens this
completed writer landing.

### Sprint 17.2: Historical initial `test run <suite>|all` contract [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

This sprint records the initial suite/root-gate contract as historical evidence. Current semantics are
owned by Sprint 17.4 and use `<case-id>|all`.

Add a `test run <suite>|all` command that runs one or more named test suites against the persistent stack
`project up` brings up, where `all` is always a suite, the command is **root-only**, and it fails fast
without a `<project>.test.dhall` or from any non-root context.

#### Deliverables

- A `test run <suite>|all` subcommand that resolves the requested suite (or the always-present `all` suite)
  from the project's non-empty `TestSuite` ([development_plan_standards.md § T](development_plan_standards.md))
  and drives it through `HostBootstrap.Harness` (`runMatrix` over the project's `Seams`).
- A **root-only** gate: the command fails fast with exit code 1 when invoked without a sibling `<project>.test.dhall`
  or from any non-root context, enforced through the binary context
  ([development_plan_standards.md § X, § Z](development_plan_standards.md)) so a VM-scoped or
  cluster-service copy of the binary refuses the run.
- **Decoupling** from deploy: `test run all` validates the already-running `project up` stack and does not
  re-run the chain or re-express deploy bring-up as a parallel set of lifted operations
  ([development_plan_standards.md § W](development_plan_standards.md)); the harness remains the one
  context-agnostic lift-target engine with no `LiftContext` added to it.

#### Validation

- Unit tests prove `test run <suite>` and `test run all` dispatch to the resolved suites, that `all` always
  resolves, and that an unknown suite name fails fast.
- Context-gate tests prove `test run` fails fast (exit code 1) with no side effects when `<project>.test.dhall` is
  absent or when the command runs from a non-root frame.
- Demo validation: with a `project up` stack standing, `test run all` reports the demo's report card
  (the `e2e-tabs` Playwright case included) against the live stack; `cabal test all` and
  `poetry run python -m hostbootstrap.test_all` pass.

#### Remaining Work

None for the historical landing. It resolved a selector from the threaded `TestSuite` through
`runSuiteSelection`, and the demo's lifted step used `test run all`
through the then-current demo chain (the removed historical module is recorded in the legacy ledger).
The current code no longer proves the old root/config gates and
the harness now drives `project up`; blocked Sprint 17.4 owns the current `<case-id>|all` parser/gate
contract rather than reopening this historical sprint.

### Sprint 17.3: Read-only `context` composition introspection [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`
**Docs to update**: `documents/architecture/binary_context_config.md`, `documents/engineering/dhall_topology.md`, `documents/operations/demo_runbook.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

#### Objective

Make `context` a **read-only** composition-introspection command that renders the global lift composition
with the current frame highlighted and performs no mutation.

#### Deliverables

- A `context inspect` command that introspects the sibling `<project>.dhall` and renders the global
  compositional sequence of lifts — the `topologyFrames` frame graph and the `parentChain` links
  ([development_plan_standards.md § X, § Z](development_plan_standards.md)) — with the **current frame**
  highlighted, so the whole `metal → VM → container → cluster` chain and this binary's place in it are
  visible at a glance.
- Absorption of the former read-only inspection surfaces (`config schema`, `config show FILE`,
  `config path`, static `config render`) under `context`
  ([development_plan_standards.md § X](development_plan_standards.md)), with explicit inputs:
  `path`/`schema`/`render` are config-free, `inspect` reads the executable sibling, and `show [FILE]`
  reads its selected/default file. The independent config-free surfaces also include help, the
  three init writers, and `service schema`.
- A **no-mutation** guarantee: `context` carries no child-config creation surface. Projection/delivery is
  internal `project up` work, currently split from the announcing `context-init` row and targeted for one
  plan-owned operation ([development_plan_standards.md § Y](development_plan_standards.md)); the old
  mutation verb is tracked in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

#### Validation

- Unit tests prove `context` renders the `topologyFrames` / `parentChain` composition with the current
  frame marked, runs without a writable filesystem effect, and exposes no child-config mutation.
- The current route behavior is `context path|schema|render` without a sibling, `context inspect` against
  the sibling, and `context show [FILE]` against the selected/default file. Sprint 17.4 owns the complete
  table-driven negative test matrix; the landed no-mutation tests remain this sprint's validation.
- Demo validation: `context` against the demo configs renders the `metal → VM → container → cluster` chain
  with the running frame highlighted; `cabal test all` passes.

#### Remaining Work

None. The pure `HostBootstrap.Context.renderComposition` renders the `topologyFrames` / `parentChain`
chain with the current frame highlighted and performs no mutation. `context inspect` uses the sibling;
`context show [FILE]` uses the selected/default file; `context path|schema|render` are static and
config-free. The former `context create vm|container|service` mutation verb is retired and child-config
creation is internal `project up` work, currently split from the announcing `context-init` row. Sprint
17.4 remains blocked for the complete parser/gate matrix, without reopening this delivered no-mutation
surface; Sprint 16.6 owns the target unified plan node.

### Sprint 17.4: Exact init/test/context command semantics [Blocked]

**Status**: Blocked
**Blocked by**: Sprints 10.9 and 15.9
**Satisfied prerequisite**: Sprint 19.8
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Fields.hs` (introduced by Sprint 19.8),
`core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/binary_context_config.md`,
`documents/architecture/dhall_generation.md`,
`documents/architecture/hostbootstrap_core_library.md`,
`documents/engineering/config_generation.md`,
`documents/engineering/schema.md`, `legacy-tracking-for-deletion.md`

#### Objective

Make the parser, typed init requests, overwrite policy, command gates, and docs agree exactly on the
three config writers, `test run`, selectors, missing-config behavior, root-only execution, and read-only
`context` introspection.

#### Deliverables

- Define one grammar for `test init` and `test run <case-id>|all`; reject undocumented aliases, appended
  verbs, unsupported `test init --force|--if-missing`, unknown/duplicate selectors, and selector/config
  ambiguity before side effects.
- Replace the current `test run` `SUITE` metavar and “suite”/already-root-only help text with exact
  case-ID/`CASE_ID` wording and help that matches the implemented authority gate. Add an exact-help
  regression so parser behavior and user-visible claims cannot drift independently.
- Replace the shared permissive init argument bag with opaque writer-specific requests constructed by the
  parser. The project request retains the implemented `--role`, repeatable `--also-role`, `--output`,
  `--force`, and `--if-missing` surface and its fresh-root default; service and test requests expose only
  fields meaningful to those writers. Phase 15.9, not this sprint, decides whether the requested roles can
  mint compatible command authority.
- Represent output handling as one explicit overwrite policy rather than independent Booleans. Define and
  test fresh/refuse-existing, force-overwrite, and idempotent-if-missing behavior, reject ambiguous policy
  combinations before writing. For `project init`, no policy flag means `RefuseExisting`, `--force`
  means `ReplaceExisting`, `--if-missing` means `KeepExisting`, and supplying both flags is rejected.
  Target `service init` and `test init` expose no overwrite flag and use `RefuseExisting`; they never
  silently replace an existing file. The writer performs one race-safe transition, never
  check-then-truncate: every policy writes and flushes an invocation-indexed same-directory temporary.
  `RefuseExisting` and `KeepExisting` atomically install it only if the destination is absent (`EEXIST`
  becomes structured `RefusedExisting` or `KeptExisting`); `ReplaceExisting` atomically replaces the
  destination. A platform without the required no-replace/replace primitive returns `Unsupported`
  instead of exposing a partially written destination. `Written`/`Replaced` is reported only after file
  and parent-directory durability (`fsync` or the Windows equivalent). A failure preserves
  the prior complete file and returns a typed `WriteError` or `PublicationUnknown`; retry re-probes
  without append/truncate and recovers or reports only its invocation-indexed orphan temp. Equal bytes
  after `EEXIST` may yield non-authorizing `ObservedEquivalent`, but
  never prove that this invocation created or owns the file—another writer may have emitted identical
  content.
- Make `test init` independent of a project config, while `test run` requires the typed
  `<project>.test.dhall`,
  refuses a production sibling config, and runs only at the root authority.
- Keep `context` uniformly read-only while preserving its input split: `path`/`schema`/`render` are
  config-free, `inspect` reads the executable sibling, and `show [FILE]` reads the selected/default file.
  Consume Sprint 19.8's jointly finalized `FrameworkEnvelopeCodec`, closed full-vs-role wire
  discriminator, and descriptive Production/Harness scope-kind discriminator. `inspect`/`show` render a
  `LocalContextView` for full project, cluster-service, and daemon
  role wires without exposing service parameters. Remove documentation for parser shapes not present in
  code.
- Preserve the existing-frame boundary: only `project up|down|destroy`, `service run`, and `check-code`
  read the sibling config through the command gate; the common envelope first identifies its wire kind,
  then full-project routes invoke only `ProjectCodec` and `service run` invokes only `RoleCodec`. A valid
  wrong-kind wire returns a structured authority/route refusal rather than a misleading malformed-config
  error. `test run` continues to refuse that sibling and generate the run config it owns.
- Replace the shared loader's unconditional `project init` missing-config hint with command-indexed
  recovery. Project lifecycle/check-code name `project init`; `service run` names the exact owning
  parent/controller projection, or `service init` together with the authorized manifest/identity
  installer. It must not imply that the descriptive role wire alone grants runtime authority. A recovery
  hint must describe a path capable of satisfying the complete requested gate.
- Consume Phase 19's typed case ID/variant schema and Phase 10's structured outcomes without owning
  either implementation.

#### Validation

- Parser/gate table tests cover every allowed command and every missing/malformed/wrong-context case with
  exact exit class and no mutation, including every row in the phase-level config-input matrix.
- Exact diagnostic tests prove each config-consuming command names only a writer/projection capable of
  producing its required context; no service-leaf failure recommends root `project init`.
- Writer tests cover the fresh-root default, every supported `project init` role/output/policy flag,
  ambiguous overwrite-policy rejection, service/test request field rejection, and existing-file behavior.
  Concurrent-writer tests prove atomic no-replace installation has one winner; fault injection
  before/during temp write, file flush, no-replace/replace installation, and directory flush proves no
  partial destination and preservation of the
  prior complete file. Crash-after-publish-before-return yields `PublicationUnknown`; retry tests prove
  each outcome is idempotent, invocation-indexed orphan temps are recovered without touching foreign
  temps, and identical foreign bytes never mint ownership.
- Read-only filesystem tests prove every `context` route leaves the tree unchanged and inspect root-full,
  cluster-service-role, and daemon-role wires through the common envelope. Routing tests prove valid
  wrong-kind wires receive exact refusals without attempting the wrong second-stage decoder. Missing,
  unknown, disagreeing, and structurally overlapping Production/Harness scope evidence returns an
  explicit ambiguous/display error; authority routing never infers scope from the descriptive tag.
- End-to-end `test init` → edit typed config → selected case/all runs prove the documented semantics.

#### Remaining Work

Blocked until Sprints 10.9, 15.9, and 19.8 land structured harness outcomes, command authority, and the
finalized common full/role envelope codec. Then introduce the opaque
writer-specific request and atomic overwrite-policy transitions, reconcile
parser and gate behavior—including the current `SUITE`/“suite”/“root-only” help mismatch—remove stale
command prose/aliases, consume the typed IDs, and run the full command-semantics matrix. Prior
`3/3`/`6/6` runs did not validate this complete negative surface.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/harness_workflow.md` - the test split `test init` / `test run <case-id>|all`,
  root-gated and `<project>.test.dhall`-backed, with no second deployment representation; the harness drives
  `project up` for each generated variant and then destroys what it acquired.
- `documents/architecture/binary_context_config.md` - the read-only `context` introspection command, its
  absorption of the former `config schema` / `config show FILE` / `config path` / static `config render`
  surfaces, and the no-mutation guarantee.
- `documents/architecture/dhall_generation.md` - typed `<project>.test.dhall` overrides kept distinct from runtime
  parameters/context/witness configs; the input-specific read-only `context` routes and generated
  `context-init` step.

**Engineering docs to create/update:**
- `documents/engineering/config_generation.md` - current project-init flags/fresh-root behavior and the
  target writer-specific request/overwrite-policy model.
- `documents/engineering/testing.md` - `test init` / `test run <case-id>|all`, root-gated, gated on
  `<project>.test.dhall`, and driving the one `project up` lifecycle per generated variant rather than defining a
  parallel deployment path.
- `documents/engineering/dhall_topology.md` - topology frames drive both the recursive chain and the
  read-only `context` rendering (`topologyFrames` / `parentChain`).

**Cross-references to add:**
- `00-overview.md`, `README.md`, `system-components.md`, and `development_plan_standards.md` (§ Z) name
  Phase 17 and link to the chain-driven test surface and the read-only `context` command.
- [phase-16-project-lifecycle-command.md](phase-16-project-lifecycle-command.md) (the `project` lifecycle
  command, the recursive `[Step]` interpreter, and the `context-init` step) and
  [phase-10-standardized-test-harness.md](phase-10-standardized-test-harness.md) (the harness engine and
  the split test surface) name Phase 17 as the owner of this new work.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) records the dissolved
  `config schema|show|path|render` and `context create vm|container|service` verbs absorbed by the
  read-only `context` command.
