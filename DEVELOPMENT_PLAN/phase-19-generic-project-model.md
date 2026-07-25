# Phase 19: Generic project model

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [development_plan_standards.md](development_plan_standards.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), [phase-20-config-driven-demo-worked-example.md](phase-20-config-driven-demo-worked-example.md)

> **Purpose**: Make `hostbootstrap-core` a fully generic library with **no hardcoded defaults**,
> parameterized over a project's own config type, so `project init` and `test init`/`test run` share one
> project-owned config builder (DRY), the harness *generates* the run's `<project>.dhall`, and the Python
> bootstrapper no longer initializes config — generic enough to host a secrets-strict, Vault-backed
> consumer such as `~/prodbox`, with production and harness secret scopes that make test plaintext
> unrepresentable in production configuration.

## Phase Status

**Status**: Active

**Reopened 2026-07-24.** The typed test-case/variant contract and the production-versus-harness secret
scope are not implemented. Earlier validation proves the generic config boundary and the unscoped
`SecretRef` seam only. The public `ProjectSpec`/`Step` construction and replacement combinators also
still admit contradictory or silently erased extension state, and `ProjectCfg` still requires a raw
`cfgWithContext` compatibility updater that has no production caller.

Phase 19 **generalizes** the config surfaces that phases 4, 8, 10, 15, and 17 delivered. Its earlier
generic `cfg`/`tcfg` parameterization, project-owned init builder, harness-generated run config, and
no-auto-init Python boundary remain implemented. Sprints 19.6–19.8 keep this phase open because
case/variant identity is still stringly, `testSuites` is dead configuration, and the current unscoped
`SecretRef` lets `TestPlaintext` inhabit a production config unless consumer code-check policy rejects
it; public project/step values can also be empty, reordered, shadow core identities, or replace prior
chain/context/teardown/service contributions.
The specific sub-surfaces this phase
supersedes — core default values, the fixed universal config type, the `test`-reuses-existing-config flow,
and the Python `config init --if-missing` trigger — are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with this phase as owner.

The completed Sprints 19.1–19.5 slice is **implemented and validated**: it is code-check-validated (core
`cabal build all --ghc-options=-Werror` clean + `cabal test all` 237 passed; demo `cabal build -Werror`
clean + its own suite 13 passed) and **real-run-validated 2026-06-23** — from a clean slate, `test init`
wrote `<project>.test.dhall` with no pre-existing project config, then `test run all` *generated* the run's
`<project>.dhall` via `psTestConfig`, drove the real `project up` on Incus/linux-cpu, reported `3/3
passed` (pristine-bootstrap / web-build / e2e-tabs), and tore down with `project destroy` (VM deleted,
generated config removed). That evidence does not validate the open typed-identity or secret-scope
contracts.

## Remaining Work

Sprint 19.6 is Planned and ready. Sprints 19.7–19.8 are Blocked on the named foundations:

- introduce validated `CaseId`/`VariantId` types and the generic project-owned test-config projection,
  remove `TestConfig.testSuites`, and reject invalid/duplicate/unknown identities before mutation; and
- replace the unscoped `SecretRef`/consumer-policy boundary with scope-indexed `SecretRef scope` and
  project-owned `ProjectConfig scope`, where `TestPlaintext` exists only at harness scope and cannot be
  decoded, constructed, or passed to production commands; remove the raw `cfgWithContext` method in
  favor of scope-correct codec verification and a read-only context projection; and
- replace public record/list construction and replacement combinators with an opaque validated project
  and step specification that preserves order and cannot shadow or erase prior contributions.

Phase 20 owns the demo mapping and Phase 10 owns harness execution/isolation.

## Historical Motivation (Superseded)

The original phase opened after three independent gaps surfaced while exercising the demo lifecycle and
reviewing `~/prodbox`. Sprints 19.1–19.5 superseded these historical surfaces:

1. **Core owned defaults a consumer could not override.** `defaultResources` (`4/8/20`),
   `defaultDeployConfig`, and `defaultProjectConfig` lived in `HostBootstrap.Config.Schema`; `initAction`
   baked them into the `project init` flags; and `ProjectSpec` exposed no init hook. The demo's `deploy-VM`
   gate used a separate `demoFullLifecycleResources = 6/10/80` constant, so a fresh config could not pass
   the shipped gate. The Python bootstrapper's `config init --if-missing` trigger also fabricated that
   unsuitable default and defeated the harness's production-config precondition. Sprints 19.1–19.3 and
   19.5 removed these surfaces.
2. **`test init`/`test run` were inverted from § Z.** Before Sprint 19.3, `test init` read the existing
   `<project>.dhall` to seed `TestConfig.testResources`, while `demoTestUp` drove `project up` against that
   pre-existing config; the override was read and printed but never applied. The existence precondition
   also checked `getCurrentDirectory` even though `project up` read the executable-sibling
   `.build/<project>.dhall`. Sprint 19.3 replaced that flow with harness-generated config and the sibling
   path guard.
3. **Core hardcoded the config *shape*.** Before Sprint 19.2,
   `ProjectConfig { dockerfile, resources, context, deploy }` was a fixed universal type. A secrets-strict
   consumer such as `~/prodbox` needed a different Tier-0 `{ parameters, context, witness }` record and no
   VM resource budget because it sizes through RKE2/EKS. Sprint 19.2 made the config project-owned; the
   resource budget / VM cordon is a provider concern carried only by projects that need it.

The lift algebra (`BinaryContext` + `childContext` + the `Step`/frame graph + `ProviderKind`) and the
harness are the genuinely universal substrate; the config *type* and its defaults are not.

## Target Contract

The baseline generic-model statement and current unscoped-secret limitation are
[development_plan_standards.md § BB](development_plan_standards.md). The planned scope-indexed refinement
is specified here in Sprint 19.7. In brief:

- **No core defaults.** `hostbootstrap-core` ships pure shapes + the lift algebra + the harness and owns
  no default config values. Current `psInit`, `psTestInit`, and `psTestConfig` are independent callbacks;
  the demo shares `demoInitWithMessage` between `demoInit` and `demoTestConfig` by convention, while its
  service projection still contains fallback ports/timeouts. Sprint 19.8 makes the scope-aware assembler
  the sole default-bearing structural path.
- **Explicit, fail-fast configs.** Every `<project>.dhall` / `<project>.test.dhall` field is mandatory; a missing
  field fails the strict Dhall decode before any side effect (no `//`-merge, no `fromMaybe` in decode).
- **Generic over the config type.** The implemented extension contract is `ProjectSpec cfg tcfg`. Core
  currently reads descriptive context through `cfgContext`; the required `cfgWithContext` compatibility
  method has no production caller and grants no authority. Core may carry an explicit command-specific
  projection when a fixed command needs project-owned data. The current example is
  `psServiceVariant :: cfg -> Either String String`, installed by `withServiceConfig`; it can return an
  arbitrary key and does not prove a relation among config, placement, and registry. Sprint 19.8 replaces
  it with a project-owned `RoleCodec` jointly finalized with the full config codec/hidden field schema.
  A parent projects a role-specific descriptive wire; child-local verification produces the opaque
  `ValidatedServiceRequest specDigest configId secretDigest fields service` under a fresh local identity
  and verified secret-bundle digest. Finalization/dispatch
  produces an existential
  `SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase
  fields` internal to the core-owned masked run-to-Exit operation. Core imposes no universal field
  names or value types: the project schema assigns every field a closed `VisibleTo consumers` set, and a
  closed filter constructs only
  `RoleParams specDigest configId secretDigest fields service` for `Service service`, and the handler is a closed
  `ServiceProgram` rather than raw `IO`. Framework-only context/request metadata and frame-specific
  plan inputs therefore need not be mislabeled as handler data.
  Sprint 19.7 generalizes
  that seam over a project-owned config family `cfg :: Type -> Type`, so production commands consume
  `cfg (Production projectId)` and a run consumes only `cfg (Harness projectId runId)`. `ProjectConfig` / `Resources` /
  `DeployConfig` remain the *demo's* concrete types, not core-owned records.
- **One scope-aware assembler, reused (DRY).** Current `psInit :: InitArgs -> cfg`, `psTestInit`, and
  `psTestConfig` are independent callbacks; the target replaces them with the single default-bearing
  `psAssemble :: AssemblyRequest scope tcfg -> ConfigAssembly scope (cfg scope)`. Independently verified
  Production inputs and
  harness-authorized run identity/draft/overrides are disjoint constructors of that one closed request;
  no second `InitArgs` or scope input can disagree. A pure `psTestMatrix`
  validates stable case/variant drafts; the engine then opens a fresh harness run/lease for each distinct
  config variant and projects it through the same assembler. `ConfigAssembly` permits only declared
  config/secret reads and exposes no general `IO` or lifecycle/backend mutation, so the unbound lease
  interval cannot hide an unjournaled effect. `project init` and harness assembly never
  shell
  `project init`, converting a `cfg (Production projectId)`, or copying a second defaults builder.
- **The binary owns config creation; Python does not.** Python builds and invokes the host-native binary
  (POSIX `exec`; Windows child subprocess); it does **not** initialize or trigger config creation. A
  normal command fails fast (exit 1) when no
  sibling `<project>.dhall` exists; the first config is written by an explicit `project init` or generated
  by the harness — never fabricated by the bootstrapper.
- **`<project>.test.dhall` is a thin project-owned override** (`tcfg`): it carries only the test-specific
  config overrides the project declares. The typed matrix and CLI parser own case-ID/`all` selection;
  the opaque Harness profile/plan derives `.test_data/<runId>`. Neither selection nor a caller-supplied
  durable-directory path is an independent `tcfg` field.
- **The harness generates and owns the run's config.** `test run` reads `<project>.test.dhall`, refuses if a sibling
  `.build/<project>.dhall` exists or a production cluster is running, and currently builds labeled
  variants through `psTestConfig :: tcfg -> IO [(Text, cfg)]`. The target is
  `psTestMatrix :: tcfg -> Either TestConfigError (TestMatrix VariantDraft)`, followed within each
  distinct variant's fresh rank-2 harness continuation by
  `psAssemble (HarnessAssembly authority draft)`, producing only
  `cfg (Harness projectId runId)`. `CaseId` and
  `VariantId` are stable reporting identities; generative `runId` is the ownership identity. The builder
  reuses project-owned defaults through the scope-aware assembler without ever constructing or coercing
  a Production config. Before plan construction,
  `withAssembledHarnessConfig` consumes the exact `HarnessAuthority`,
  `ProjectCodec scope specDigest cfg`, and assembled value; canonical render/hash/strict re-decode
  jointly yields the root-local `VerifiedConfigWire` identity and
  `ValidatedConfig scope specDigest configId (cfg scope)` in a rank-2 continuation, without a child
  handoff or external effect, and
  remains effectful so a project can read
  extra inputs such as `test-secrets.dhall`. For each variant the current harness writes
  `<project>.dhall`, runs `project up`, asserts, and attempts `project destroy` plus matching-artifact
  cleanup. Cleanup preserves a differing config in quarantine for explicit recovery. These guards are
  neither resource-authoritative reservations nor verified identity-bearing ownership;
  Phase 10.9 owns that upgrade. Teardown errors fail the variant; independent teardown actions
  are all attempted and aggregated. A true pre-effect `SafetyRefusal` owns nothing; any later
  conflict/failure rolls back every separately journaled preparation this run owns instead of using a
  refusal label to skip cleanup.
- **Scope-indexed secrets and project config.** The implemented Sprint 19.4
  `SecretRef = < Vault | TransitKey | Prompt | TestPlaintext >` is unscoped, so excluding
  `TestPlaintext` from production is currently consumer/code-check policy. Sprint 19.7 replaces it with
  `SecretRef scope` and a project-owned `ProjectConfig scope`:
  `SecretRef (Production projectId)` has only
  `Vault`/`TransitKey`/`Prompt`, while `TestPlaintext` requires opaque
  `HarnessConfigAuthority projectId runId` and constructs only
  `SecretRef (Harness projectId runId)`. Normal init, decode, child projection, and command dispatch
  preserve the project-indexed Production scope. Pure `psTestMatrix` supplies variant drafts; only after
  the engine opens a fresh run does `psAssemble` receive `HarnessAuthority projectId runId` and produce
  the matching harness-scoped config from project-owned `test-secrets.dhall`. Core never
  resolves secrets, and no exported coercion may turn a harness config into a production config.

See [generic_project_model](../documents/architecture/generic_project_model.md) for the canonical design
and [secrets.md](../documents/engineering/secrets.md) for the `SecretRef` / `test-secrets` pattern.

## Sprints

### Sprint 19.1: Strip core defaults [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`, `core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/resource_budgeting.md`

#### Objective

Remove `defaultResources` / `defaultDeployConfig` / `defaultProjectConfig` from `HostBootstrap.Config.Schema`
and the `fromMaybe (… defaultResources)` / `value (memory defaultResources)` defaults from
`HostBootstrap.Command.initAction`, so core owns no default config values.

#### Deliverables

- Strict-decode `<project>.dhall` / `<project>.test.dhall` (no field defaulted at decode or init by core).
- `project init` sources every default from the project-owned builder (Sprint 19.3), not core constants.

#### Validation

`cabal test all` (incl. `DocValidator`); a `project init` that omits a project default fails fast.
Validation substrate: linux-cpu (code-check).

#### Remaining Work

Code complete and validated (2026-06-23): `defaultResources` / `defaultDeployConfig` /
`defaultProjectConfig` and the `initAction` flag defaults are removed from core; `project init` builds its
config from the project-owned `psInit`. Verified by `cabal build all --ghc-options=-Werror` (clean) and
`cabal test all` (232 passed). Real-run-validated 2026-06-23 (test run all 3/3 from a generated config).

### Sprint 19.2: Parameterize `ProjectSpec` over `cfg`/`tcfg` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`, `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `documents/engineering/authoring_project_binaries.md`, `documents/architecture/generic_project_model.md`

#### Objective

Generalize `ProjectSpec` to `ProjectSpec cfg tcfg`, coupling core to `cfg` through generic contextual
authority and explicit project-provided projections, never through a fixed core config record. Demote
`ProjectConfig` / `Resources` / `DeployConfig` to the demo's concrete instance.

#### Deliverables

- `ProjectSpec cfg tcfg` with config/test codecs and contextual lift accessors;
  `runHostBootstrapCLI` generic. Fixed commands may add narrow projections over `cfg` without adding a
  universal field: Phase 18's `psServiceVariant` / `withServiceConfig` is the current example.
- The resource budget / VM cordon documented as a provider concern carried by a project's `cfg`, not a
  universal field (§ O amended by § BB).
- A project's own config fields live on its `cfg` (the demo's `message` is added on the demo's `cfg` in
  phase-20) — core owns no project-specific field and no generic `extra` slot.

#### Validation

`cabal test all`; the demo compiles against the parameterized spec with `cfg = ProjectConfig`. Validation
substrate: linux-cpu (code-check).

#### Remaining Work

Code complete and validated (2026-06-23): `ProjectSpec cfg tcfg` is parameterized via the new
`HostBootstrap.Config.Class.ProjectCfg` typeclass (`cfgContext` plus the currently unused
`cfgWithContext` compatibility method); `ProjectConfig` /
`Resources` / `DeployConfig` / `TestConfig` (and `Container`) moved to the demo
(`HostBootstrapDemo.Config` / `.Container`), so core owns no config type. The `message` field lands on the
demo's own cfg in [phase-20](phase-20-config-driven-demo-worked-example.md). Verified by core `cabal build
-Werror` + `cabal test all` (232) and demo `cabal build -Werror` + its own suite (13). Real-run-validated
2026-06-23 (test run all 3/3 from a generated config). A later Phase 18 extension now carries
`psServiceVariant` through `ProjectSpec` and installs the demo-specific implementation with
`withServiceConfig`; that narrow projection preserves this phase's generic-config contract and does not
reopen it.

### Sprint 19.3: DRY init + harness-generated config + sibling-path precondition [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`

#### Objective

Add `psInit :: InitArgs -> cfg`, `psTestInit :: InitArgs -> tcfg`, and `psTestConfig :: tcfg -> IO [(Text, cfg)]`;
flip `test run` to *generate* the run's `<project>.dhall` from `<project>.test.dhall` via the independent
`psTestConfig` callback. The demo calls `demoInitWithMessage` from `demoInit` and `demoTestConfig` by
convention; the generic contract does not make `psTestConfig` reuse `psInit`. Clean up only the generated
config + self-created `.test_data` that it still owns (closing
the § Z code-vs-contract drift). Fix the harness existence precondition to check the executable-sibling
`siblingProjectConfigPath` (`.build/<project>.dhall`), not `getCurrentDirectory`/the project root.

#### Deliverables

- `test init` writes `<project>.test.dhall` from `psTestInit` without requiring an existing `<project>.dhall`.
- `test run` applies cooperative path/byte ownership guards to its generated config and `.test_data`, then
  generates → `project up` → assert → `project destroy` → delete only matching artifacts; it keeps
  `<project>.test.dhall`, and any differing config remains in reported quarantine. This sprint did not deliver
  resource-authoritative reservations and verified identity-bearing receipts.
- An ordinary failure after acquisition triggers root teardown; `SafetyRefusal` skips that teardown because
  the harness did not acquire ownership. Teardown failure fails the variant, while project teardown tries
  independent cleanup actions and reports their aggregate failures.
- `demoTestSafety` checks the sibling `.build/<project>.dhall` so the fail-fast guard fires on the config
  `project up` actually reads. `demoInit` and `demoTestConfig` call `demoInitWithMessage` by convention;
  `test init` independently uses `psTestInit`, and the harness never shells the CLI.

#### Validation

`cabal test all`; demo `test run all` runs from a generated config (no pre-existing `<project>.dhall`).
Validation substrate: linux-cpu (the harness real-run on native Incus/Linux).

#### Remaining Work

Code complete and validated (2026-06-23): `psInit` / `psTestInit` / `psTestConfig` added; `test init`
needs no pre-existing `<project>.dhall`; `test run` generates the run's config via `psTestConfig`, drives
the real `project up`, asserts, `project destroy`, then deletes config bytes only while they still match
the generated payload under the cooperative sidecar guard (keeping `<project>.test.dhall`; changed bytes remain in
the reported locked quarantine). This is neither a resource-authoritative reservation nor verified
identity-bearing ownership;
`demoTestSafety` checks the executable-sibling `siblingProjectConfigPath`, not the project root. Verified
at phase close by `cabal test all` (232) + the demo suite (13), and real-run-validated 2026-06-23 (`3/3`
from a generated config).

The current harness further distinguishes `SafetyRefusal`, fails a variant on teardown failure, attempts
independent cleanup, and preserves differing config bytes. Its lock/path convention remains cooperative
and race-prone; Phase 10.9 supplies resource-authoritative reservations and verified identity-bearing
ownership receipts. That open engine work does not change this sprint's Done generic-config status or its
dated evidence.

### Sprint 19.4: Generic `SecretRef` and `test-secrets` seam [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Vocab.hs`
**Docs to update**: `documents/engineering/secrets.md`, `documents/architecture/generic_project_model.md`

#### Objective

Add the initial pure, unscoped `SecretRef = < Vault | TransitKey | Prompt | TestPlaintext >` vocabulary to
core (no Vault dependency), so a secrets-strict consumer can keep production `<project>.dhall`
plaintext-free by policy and inject test secrets through `psTestConfig` reading a project-specific
`test-secrets.dhall`.

#### Deliverables

- `SecretRef` in the core Dhall vocabulary + `HostBootstrap.Config.Vocab`.
- The `~/prodbox`-class pattern (Tier-0 config, `SecretRef` pointers, `test-secrets.dhall` composed in
  `psTestConfig`) documented as a supported shape, validated against the parameterized spec.

#### Validation

`cabal test all`; a worked secrets-strict fixture round-trips `SecretRef` and composes `TestPlaintext` for
tests. Validation substrate: linux-cpu (code-check).

#### Remaining Work

Core deliverable complete and validated (2026-06-23): the pure `SecretRef = < Vault | TransitKey | Prompt
| TestPlaintext >` union is in `Core.dhall` and mirrored in `HostBootstrap.Config.Vocab` with the
anti-drift and round-trip tests (`cabal test all`: 237 passed). This sprint did not make production
exclusion type-level: because `TestPlaintext` inhabits the same union, exclusion remains
consumer/code-check policy. Sprint 19.7 owns the scope-indexed replacement; the `~/prodbox` consumer
migration remains consumer-side work.

### Sprint 19.5: Remove the Python config auto-init [Done]

**Status**: Done
**Implementation**: `hostbootstrap/bootstrap.py`, `tests/test_bootstrap.py`, `tests/test_cli.py`
**Docs to update**: `documents/architecture/python_haskell_boundary.md`, `documents/architecture/binary_context_config.md`, `documents/engineering/config_generation.md`, `documents/architecture/build_and_run_model.md`, `documents/engineering/schema.md`, `development_plan_standards.md` (§§ M/N/Q/X/Y), `00-overview.md`, `system-components.md`, `DEVELOPMENT_PLAN/README.md`, `legacy-tracking-for-deletion.md`, `README.md`

#### Objective

Remove the Python bootstrapper's `project init --if-missing` trigger. Python builds and invokes the
host-native binary; the binary owns its Dhall. This is the boundary consequence of the generic config model (no
core defaults + harness-generates-config): a project's first config is an explicit choice (`project init`)
or a harness-generated artifact (`psTestConfig`), never a fabricated default. Removing the trigger also
restores the harness safety precondition's meaning — the "refuse if a production config exists" guard can
finally observe a clean slate.

#### Deliverables

- `hostbootstrap run` builds and invokes with no config step; a normal command on an absent sibling
  `<project>.dhall` fails fast (exit 1) and points the user to `project init`.
- The `project_init_command` trigger removed from `hostbootstrap/bootstrap.py`; the §§ M/N/Q/X/Y boundary
  prose and the indexes describe build + platform-specific invocation only (and use `project init`, not
  the legacy `config init`).
- `legacy-tracking-for-deletion.md` records the removed trigger; the two Removed-Surfaces self-contradictions
  are corrected.

#### Validation

`poetry run python -m hostbootstrap.check_code` clean; `test_all` 100% (the removed-trigger assertion
replaces the prior "Python triggers init" tests); live fresh-host bootstrap → `project init` → `project up`.
Validation substrate: linux-cpu.

#### Remaining Work

None — landed and validated (2026-06-23): `hostbootstrap/bootstrap.py` builds and invokes the host-native
binary with no config-init step (the `project_init_command` trigger is deleted), so a normal command
fails fast when no sibling `<project>.dhall` exists. `poetry run python -m hostbootstrap.check_code` is
clean (ruff / black / mypy) and `test_all` reports 166 passed.

### Sprint 19.6: Typed test variants and case identity [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/harness_workflow.md`, `documents/engineering/schema.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Replace stringly/dead test configuration with a generic typed schema in which the user's selected cases
and generated config variants have stable, validated identities.

#### Deliverables

- Introduce validated `CaseId` and `VariantId` newtypes with non-empty syntax and duplicate rejection at
  construction/decode.
- Define a project-owned typed `tcfg` projection that validates into an opaque `TestMatrix`: a non-empty
  unique Haskell case registry, a non-empty unique variant registry, and exactly one
  `CaseId -> NonEmpty VariantId` row for every registered case. Every declared variant must be referenced
  by at least one row and every referenced variant must exist; shared variants and multiple variants per
  case remain explicit valid relations.
- Keep stable `VariantId` separate from ownership and expose only pure `VariantDraft`s plus the validated
  case-to-variant relation. A draft contains no run, plan, config, lease, or cleanup authority. Sprint
  19.7 later assembles scope-indexed config, while Sprint 10.9 opens fresh generative runs and enforces
  sequential ownership for distinct variants.
- Remove the dead `TestConfig.testSuites :: [Text]` shape and any parallel hard-coded suite list; `all` is
  a parser selector over registered typed case IDs, not stored config data.
- Keep `ProjectSpec cfg tcfg` generic: Phase 19 owns the types/contracts, Phase 20 owns the demo's
  config-driven variant mapping, and Phase 10 owns execution/isolation.

#### Validation

- Decode/construction tests reject empty case/variant registries, a missing or empty registered-case row,
  duplicate/unknown/ambiguous references, duplicate pairs, and an orphan variant. `all` proves total
  coverage of every registered handler.
- Generic fixture projects prove one case can map to multiple variants and multiple cases can share one
  variant without core knowing project fields.
- Pure projection tests prove distinct variants remain distinct, shared variants appear once in the
  draft registry, case selection preserves the validated relation, and no draft contains runtime
  run/plan/config or cleanup authority. Runtime identity and unresolved-cleanup blocking are deferred to
  Sprint 10.9.
- API/source tests prove `testSuites` and stringly selector plumbing are absent; the Haskell quality gate
  passes.

#### Remaining Work

Design the typed IDs and pure matrix/draft projection, migrate selector/schema plumbing, remove the dead
field, and hand the concrete mapping to Phase 20. Runtime harness ownership and scope-indexed config
integration remain blocked Sprints 10.9 and 19.7, not closure criteria for this ready foundation. The
earlier generic `cfg`/`tcfg` work remains valid but did not deliver this typed test contract.

### Sprint 19.7: Scope-indexed production and harness secrets [Blocked]

**Status**: Blocked
**Blocked by**: Sprints 8.7 and 19.6
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Vocab.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/Fixture.hs`,
`demo/src/HostBootstrapDemo/Config.hs`,
`demo/test/ConfigSpec.hs`
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/engineering/secrets.md`, `documents/engineering/schema.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Replace consumer convention with a type boundary that makes `TestPlaintext` impossible in a production
project config while retaining an explicit harness-only plaintext seam for test fixtures.

#### Deliverables

- Introduce a closed production-versus-harness config scope and `SecretRef scope`. The pointer
  constructors (`Vault`, `TransitKey`, and `Prompt`) are available at both scopes;
  `TestPlaintext :: HarnessConfigAuthority projectId runId -> TestSecret ->
  SecretRef (Harness projectId runId)` is available only for the exact installed project and harness run.
- Require secrets-strict projects to define `ProjectConfig scope` (or an equivalent project-owned
  `cfg :: Type -> Type`) whose `cfg scope` secret fields carry the same scope index. Thread that config family through the
  generic `ProjectSpec` boundary without adding a core-owned config record or project-specific fields.
- Remove `cfgWithContext` from the generic boundary. It is currently required by `ProjectCfg` but has no
  production caller; child config construction/promotion must instead pass through
  `ProjectCodec scope specDigest cfg`, verified wire identity, and
  `ValidatedConfig scope specDigest configId (cfg scope)`, so no public raw context record update
  can substitute for the authenticated transition.
- Replace the current `psInit`/parallel test-builder shape with one project-owned
  `psAssemble :: AssemblyRequest scope tcfg -> ConfigAssembly scope (cfg scope)`. Production
  init/decode uses only `ProductionAssembly` with independently verified project values.
  `psTestMatrix` first produces the typed, non-empty Sprint 19.6 `VariantDraft`s
  without run authority; for each distinct variant the engine opens a fresh run and passes
  one `HarnessAssembly authority draft` carrying the matching opaque
  `HarnessAuthority projectId runId` to `psAssemble`, which
  produces only `cfg (Harness projectId runId)`. `ConfigAssembly` has an allowlisted read-only
  config/secret capability and no `MonadIO`/backend mutation escape; assembly cannot create state before
  a bound plan/journal/permit exists. `withAssembledHarnessConfig` then uses
  `ProjectCodec scope specDigest cfg`—the installed-project/scope wrapper around Phase 8.7's lower
  `CodecWitness`—to jointly mint the root-local verified wire identity and
  `ValidatedConfig scope specDigest configId (cfg scope)` required for the first plan. Neither path can
  coerce the other scope, and all shared defaults remain in that single assembler. Child config
  projection preserves the scope but mints a
  distinct frame config identity for its distinct narrowed bytes.
- Reflect separate Dhall schemas/codecs so a production schema has no `TestPlaintext` alternative and
  rejects it before command mutation. The harness schema decodes to untrusted `HarnessConfigWire`, not
  directly to a generative scoped config. A `HandoffGrant ... ConfigHandoff configDigest verb phase`
  plus exact-byte verification through the scope-correct opaque
  `ProjectCodec (Harness projectId runId) specDigest cfg` jointly yields
  `VerifiedConfigWire (Harness projectId runId) configDigest configId`,
  `VerifiedHandoff ... ConfigHandoff configId verb phase`, child-local
  `HarnessConfigAuthority projectId runId`, and
  `ValidatedConfig (Harness projectId runId) specDigest configId
  (cfg (Harness projectId runId))` inside one
  rank-2 continuation. Those values enter `withChildProjectPlan` with the closed verb and
  `NonEmpty (PlanDraft (Harness projectId runId) specDigest
  (cfg (Harness projectId runId)))`; only that rank-2 gate yields the fresh child plan/binding and exact
  `ChildPlanAuthority` later
  consumed by `authorizeChildProject`. The child does not need the root's non-serializable authority
  first. Raw wire
  cannot be promoted merely because the caller has run authority; pointer-only harness configs still
  acquire the Harness index. Core still never resolves secret material.
- Remove consumer code-check policy as the enforcement boundary. A consumer may retain a textual scan as
  defense in depth, but correctness cannot depend on it, and no exported constructor/coercion may widen a
  harness config into production.

#### Validation

- Compile-fail/API fixtures prove `TestPlaintext` cannot construct
  `SecretRef (Production projectId)`, a
  `ProjectConfig (Harness projectId runId)` cannot be passed to a production command, another installed
  project, or a different harness run, and child projection cannot change scope.
- Dhall tests prove production decode rejects a `TestPlaintext` alternative before side effects. Harness
  tests round-trip the untrusted wire form, then prove only a matching config-handoff grant and matching
  bytes plus the scope-correct codec can jointly mint the generic verified wire/handoff and validated
  config, and only `withChildProjectPlan` can mint the corresponding child authority/plan/binding; raw
  wire, wrong project/run/config identity/hash, a recovery-kind handoff, direct `FromDhall` to scoped
  config, and pointer-only scope confusion are rejected.
- Generic fixtures cover a secrets-strict indexed config and a secret-free config, proving core still
  owns neither project fields nor defaults.
- Anti-drift tests cover both reflected schemas; the Haskell quality gate passes.

#### Remaining Work

Blocked until Sprints 8.7 and 19.6 land the validated lower codec and typed variant projection. Then
design the scope kind and indexed codecs, generalize `ProjectCfg`/`ProjectSpec` over `cfg scope`, migrate
fixtures/consumers, and add negative construction/decode tests. The current unscoped `SecretRef` remains
supported behavior only until this sprint lands; it is not the target production-safety contract.

### Sprint 19.8: Opaque validated project and step specification [Blocked]

**Status**: Blocked
**Blocked by**: Sprints 19.6–19.7
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Fields.hs` (new),
`core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`demo/src/HostBootstrapDemo/Config.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`demo/app/Main.hs`,
`core/hostbootstrap-core/test/Fixture.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/SchemaSpec.hs`,
`core/hostbootstrap-core/test/StepSpec.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/composition_methodology.md`,
`documents/architecture/library_hierarchy.md`,
`documents/architecture/run_models.md`,
`documents/engineering/derived_project_standards.md`, `legacy-tracking-for-deletion.md`

#### Objective

Replace the public record/update surface that can erase or contradict project contributions with one
opaque validated specification whose plan, step identities, frame order, command selectors, and reverse
policies cannot represent an invalid combination.

#### Deliverables

- Hide raw `ProjectSpec` and `Step` constructors behind a validation builder. Finalization requires a
  non-empty lifecycle plan, unique typed step identities, resolvable parent frames, and an explicit
  cleanup policy for every mutating step before any interpreter or command selector is returned.
- Split core and project step identity into disjoint constructors. A project cannot shadow a core
  `context-init`, build, deploy, or teardown identity by choosing the same `Text`; rendered labels remain
  presentation only and never select behavior.
- Preserve the declared global chain order exactly, or reject a non-contiguous return to a closed frame.
  The current first-frame grouping must not transform `A → B → A` into `A → A → B`. Derive topology,
  current-frame work, child handoffs, and reverse order from the same validated sequence.
- Replace `withChain`, `withFrameContext`, `withTeardown`, and `withServiceConfig` record replacement with
  additive, typed builder operations or explicitly named single-assignment slots. A second assignment is
  a construction error rather than silent erasure; independent contributions merge under checked,
  associative combinators. Optional service/artifact registries may be explicitly empty, but declared
  keys, cases, artifacts, contexts, and teardown policies must be unique and internally resolvable.
- Remove arbitrary `psServiceVariant :: cfg -> Either String String` from the finalized specification.
  The project-owned schema/assembler hides its field row and jointly finalizes the full
  `ProjectCodec scope specDigest cfg`,
  `RoleCodec scope specDigest fields`, and closed typed service registry, so callers cannot choose `fields`, pair
  independently obtained codecs, or register a stringly selector. Compute a canonical `specDigest` and
  retain it on all codecs, validated configs, plans, requests, and registry entries. Register the full
  project schemas as separately named `Production` and `Harness` `ConfigArtifact`s for
  `context schema|render`; derive the `service schema` role-wire
  registry/union from the same `RoleCodec`, with separately named `Production` and `Harness` families
  rather than conflating their scope-indexed secret vocabularies. Include a structured empty result for
  both families when the registry is explicitly empty.
- Jointly derive one opaque `FrameworkEnvelopeCodec`, closed full-vs-role wire discriminator, and closed
  descriptive Production/Harness scope-kind discriminator into the full
  `ProjectCodec scope specDigest cfg` and every `RoleCodec`. It yields only a safe
  `LocalContextView` for pre-routing and
  read-only inspection; it cannot expose `RoleParams` or authority. A scope-erased reader selects one
  named codec from the tag and requires that codec to validate the same tag; absent/unknown,
  disagreeing, or overlapping scope evidence is explicitly ambiguous and cannot mint a display witness.
  Authority routing still gets scope only from the verified root/handoff/activation package. Sprint 17.4 consumes it for uniform
  `context inspect|show` and wrong-wire-kind routing rather than trying the full decoder on every sibling
  file.
- Make the pure role projection structural. A validated parent can render only
  `RuntimeRoleWire fields service`; child-local verification through the inseparable role codec binds an
  opaque `ValidatedServiceRequest specDigest configId secretDigest fields service` and its
  `RoleParams specDigest configId secretDigest fields service` to a fresh local `configId` and verified
  secret-bundle digest. The wire contains mandatory
  `FrameworkValidation` fields plus fields tagged `Service service`; the handler parameters contain only
  the latter, while plan/build/deploy-only fields cross neither boundary. Neither the request nor parent
  config identity is serialized. Core makes no unverifiable claim that it can diagnose semantic
  “relatedness” in an arbitrary selector—the arbitrary selector API is removed.
- Finalize typed registry definitions that bind one service index to its declared effect row and handler
  contribution, but do not duplicate runtime ownership here. Sprint 18.6 consumes this finalized
  registry/codec/request relation to own service-command authorization, placement/effect verification,
  `SelectedService`, `ServiceProgram` interpretation, raw-`IO` handler migration, one-use execution, and
  service diagnostics. The signed placement's `permittedEffects` ceiling conservatively derives the
  acquisition plan's lease requirement before Acquire; callers cannot choose a no-lease branch, and
  finalized registry selection must prove its exact effect row is within that same ceiling. The selected package remains
  internal to Sprint 18.6's core-owned masked run-to-Exit operation and never reaches a project callback.
- Make role parameter projection total from the single Sprint 19.7 `psAssemble` result. The demo's Web
  ports and accelerator timeout are explicit root/role parameters, not fallback literals in
  `serviceTypeForContext`/`serviceTypeForProjection`; one optional constructor never discards the other
  role's configured values. The demo limits host Dockerfile, VM, context/control, and deploy-only fields
  to their framework/plan consumers, so those declarations cannot inhabit its service/daemon
  `RoleParams`.
- Make `project`, `test`, `service`, `context`, artifact generation, and code-check dispatch consume only
  the finalized opaque specification and its projections. No public record update or raw list can bypass
  full validation.

#### Validation

- Public-package compile-fail fixtures prove consumers cannot construct raw `ProjectSpec`/`Step` values,
  shadow a core step identity, replace a prior chain/context/teardown/service selector, or obtain a
  command interpreter from an unfinished builder.
- Property tests generate valid and invalid frame sequences, including `A → B → A`, and prove validation
  either preserves the exact declared order or rejects it before effects; it never reorders by first
  frame occurrence.
- Merge-law tests prove independently authored project fragments compose associatively without erasing
  earlier steps, artifacts, services, test cases, context projections, or cleanup policies. Duplicate
  identities and conflicting single-assignment fields return structured errors.
- Compile-fail service-schema fixtures prove callers cannot choose the hidden field row, combine codecs
  from different finalizations, duplicate a service identity, or pair a registry definition with the
  wrong service/effect indices. Full-config/role-codec properties prove the demo's Web/Accelerator wires
  contain exactly framework-validation plus selected-service fields, while their `RoleParams` contain
  only selected-service fields. They also prove child verification creates a fresh local identity,
  requests carry honest consumer tags, each role retains its explicitly assembled parameters, and no
  fallback default exists. Schema goldens require separate full named `Production` and `Harness`
  `ConfigArtifact`s and distinguish each from the corresponding role-wire `service schema` family; they
  also cover the explicit empty registry. Runtime selection, effect rejection,
  handler escape-hatch, replacement-race, and repeated-execution fixtures belong to Sprint 18.6.
- Common-envelope properties decode root full, cluster-service role, and daemon role wires to the same
  framework view, preserve their closed wire-kind and descriptive scope-kind discriminators, and reject
  cross-finalization codecs. Missing, unknown, changed, and codec-overlap scope tags produce an explicit
  ambiguous/error result; pointer-only Production and Harness payloads are never classified by trial
  decoding.
  Compile-fail/API tests prove the view cannot yield role parameters or command authority. Same-shaped
  codecs/requests/drafts from distinct `specDigest`s cannot combine.
- End-to-end fixtures finalize both a minimal service-free project and the demo, then prove every
  selected mutating step has one plan-derived frame, dependency set, operation key, and reverse policy.
  The Haskell quality gate passes.

#### Remaining Work

Blocked until Sprints 19.6–19.7 land typed case/variant identities and the scope-aware assembler/config
identity that the finalized registry must retain. Then design the opaque builder and typed identifiers,
migrate current record updates and raw `Step`
construction, make all command projections consume the finalized value, and add the negative/property
fixtures. Existing `ProjectSpec` validation covers only a small subset and remains the current behavior
until this sprint lands.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/generic_project_model.md` — the canonical generic-project-model design contract
- `documents/architecture/hostbootstrap_core_library.md` — `ProjectSpec cfg tcfg`, contextual lift
  authority, the current arbitrary service-selector projection, and its target replacement by the
  codec-produced request/finalized typed registry/`SelectedService` relation
- `documents/architecture/harness_workflow.md` — the harness-generates-then-cleans-up the run's config flow
- `documents/architecture/python_haskell_boundary.md` — the ordinary Python project path builds and
  invokes only (POSIX `exec`; Windows child subprocess); the binary owns config init (no auto-init
  trigger), while explicit distribution/maintainer commands remain separate
- `documents/architecture/binary_context_config.md` — the binary fails fast on an absent sibling config; no Python trigger
- `documents/architecture/build_and_run_model.md` — config is absent post-build until `project init` / harness generation

**Engineering docs to create/update:**
- `documents/engineering/secrets.md` — current unscoped `SecretRef`, the scope-indexed target, and the
  harness-only `test-secrets.dhall` composition seam
- `documents/engineering/schema.md` — config type is project-defined and explicit (no core defaults; strict decode)
- `documents/engineering/config_generation.md` — current independent callbacks, the demo-only shared
  helper, target `psAssemble`, and config absence until explicit user/harness creation
- `documents/engineering/testing.md` — `test run` generates the run's `<project>.dhall` from `<project>.test.dhall`
- `documents/engineering/authoring_project_binaries.md` — the `psInit` / `psTestInit` / `psTestConfig` seams
- `documents/engineering/resource_budgeting.md` — the budget is a provider concern carried by a project's `cfg`

**Cross-references to add:**
- `development_plan_standards.md` §§ M/N/Q/X/Y (the Python boundary) and § BB; `00-overview.md`, `README.md`,
  and `system-components.md` phase rows
- `legacy-tracking-for-deletion.md` Pending entries owned by this phase
- `phase-20-config-driven-demo-worked-example.md` (the demo realization that depends on this phase)
