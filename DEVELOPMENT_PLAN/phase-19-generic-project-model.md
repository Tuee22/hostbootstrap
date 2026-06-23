# Phase 19: Generic Project Model and No Core Defaults

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [development_plan_standards.md](development_plan_standards.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), [phase-20-config-driven-demo-worked-example.md](phase-20-config-driven-demo-worked-example.md)

> **Purpose**: Make `hostbootstrap-core` a fully generic library with **no hardcoded defaults**,
> parameterized over a project's own config type, so `project init` and `test init`/`test run` share one
> project-owned config builder (DRY), the harness *generates* the run's `<project>.dhall`, and the Python
> bootstrapper no longer initializes config — generic enough to host a secrets-strict, Vault-backed
> consumer such as `~/prodbox`.

## Phase Status

**Status**: Done

Phase 19 **generalizes** the config surfaces that phases 4, 8, 10, 15, and 17 delivered, **without
reopening or undoing them**. Those phases stay `Done` — their config schema, Dhall generation, harness
engine, binary-context gate, and chain-driven-test deliverables are built and validated; Phase 19 builds
**on top of** them, adding the generic `cfg`/`tcfg` parameterization, the project-owned init builder, the
harness-generated run config, and the no-auto-init Python boundary. The specific sub-surfaces this phase
supersedes — core default values, the fixed universal config type, the `test`-reuses-existing-config flow,
and the Python `config init --if-missing` trigger — are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with this phase as owner.

The generic project model is **implemented and validated**: it is code-check-validated (core `cabal build
all --ghc-options=-Werror` clean + `cabal test all` 237 passed; demo `cabal build -Werror` clean + its own
suite 13 passed) and **real-run-validated 2026-06-23** — from a clean slate, `test init` wrote `test.dhall`
with no pre-existing project config, then `test run all` *generated* the run's `<project>.dhall` via
`psTestConfig`, drove the real `project up` on Incus/linux-cpu, reported `3/3 passed`
(pristine-bootstrap / web-build / e2e-tabs), and tore down with `project destroy` (VM deleted, generated
config removed). It reopened no earlier phase; the superseded surfaces are in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Motivation

Three independent gaps surfaced while exercising the demo lifecycle and reviewing `~/prodbox`:

1. **Core owns defaults a consumer cannot override.** `defaultResources` (`4/8/20`),
   `defaultDeployConfig`, and `defaultProjectConfig` live in `HostBootstrap.Config.Schema`; `initAction`
   bakes them into the `project init` flags; `ProjectSpec` exposes no init hook. The demo's `deploy-VM`
   gate (`demoFullLifecycleResources = 6/10/80`, `demo/src/HostBootstrapDemo/Commands.hs`) is a *separate*
   constant, so the shipped default cannot pass the shipped gate — a fresh `project init` writes a config
   `project up` then rejects. The same root cause makes the Python bootstrapper's `config init --if-missing`
   trigger incoherent: it fabricates a default config the project's own rules reject, and it defeats the
   harness's "refuse if a production config exists" safety precondition by guaranteeing one always exists.
2. **`test init`/`test run` are inverted from § Z.** Today `test init` *reads* the existing
   `<project>.dhall` to seed `TestConfig.testResources`, and `demoTestUp` drives `project up` against that
   *pre-existing* config; the `testResources` override is read and printed but never applied. § Z already
   specifies the opposite (the harness *writes* the run's `<project>.dhall` from the overrides), so this is
   a code-vs-contract drift, not a new requirement. The harness's existence precondition also checks the
   wrong path (`getCurrentDirectory`) while `project up` reads the executable-sibling
   `.build/<project>.dhall` (`siblingProjectConfigPath`), so the guard never fires on the config that
   actually exists.
3. **Core hardcodes the config *shape*.** `ProjectConfig { dockerfile, resources, context, deploy }` is a
   fixed universal type. A secrets-strict consumer (`~/prodbox`) has a different shape entirely — a Tier-0
   `{ parameters, context, witness }` record whose secret fields are `SecretRef` *pointers*
   (`Vault {mount,path,field}` / `TransitKey` / `Prompt` / `TestPlaintext`), with **no** VM resource
   budget at all (it sizes via RKE2/EKS). The resource budget / VM cordon is therefore a **provider**
   concern, not a core-universal field. A project's own config fields (such as the demo's `message`, added
   in [phase-20](phase-20-config-driven-demo-worked-example.md)) live on the project's `cfg`, never as a
   core-owned slot.

The lift algebra (`BinaryContext` + `childContext` + the `Step`/frame graph + `ProviderKind`) and the
harness are the genuinely universal substrate; the config *type* and its defaults are not.

## Target Contract

The full statement is [development_plan_standards.md § BB](development_plan_standards.md). In brief:

- **No core defaults.** `hostbootstrap-core` ships pure shapes + the lift algebra + the harness and owns
  no default config values. The only place defaults live is a project-supplied init builder.
- **Explicit, fail-fast configs.** Every `<project>.dhall` / `test.dhall` field is mandatory; a missing
  field fails the strict Dhall decode before any side effect (no `//`-merge, no `fromMaybe` in decode).
- **Generic over the config type.** The extension contract becomes `ProjectSpec cfg tcfg`, coupling core
  to `cfg` only through the lift authority (`cfg -> BinaryContext`, `BinaryContext -> cfg -> cfg`).
  `ProjectConfig` / `Resources` / `DeployConfig` become the *demo's* concrete `cfg`/`tcfg`, not core types.
- **One init builder, reused (DRY).** `psInit :: InitArgs -> cfg` is the only default-bearing function;
  `project init` calls it and `test run` reuses it through `psTestConfig` — never by shelling `project init`.
- **The binary owns config creation; Python does not.** Python builds the host-native binary and execs it;
  it does **not** initialize or trigger config creation. A normal command fails fast (exit 1) when no
  sibling `<project>.dhall` exists; the first config is written by an explicit `project init` or generated
  by the harness — never fabricated by the bootstrapper.
- **`test.dhall` is a thin override** (`tcfg`): mandatory test fields (suite selection, the `.test_data`
  durable dir) plus only the config overrides a test needs.
- **The harness generates and owns the run's config.** `test run` reads `test.dhall`, refuses if a sibling
  `.build/<project>.dhall` exists or a production cluster is running, builds the config via
  `psTestConfig :: tcfg -> IO cfg` (reusing `psInit`; `IO` so a project can read extra inputs such as a
  `test-secrets.dhall`), writes `<project>.dhall`, runs `project up`, asserts, `project destroy`, then
  deletes the **generated** `<project>.dhall` and self-created `.test_data` (keeping `test.dhall`).
- **Generic secrets shape.** Core offers a pure `SecretRef` union projects may embed in `cfg`; "no
  plaintext secrets in a production `<project>.dhall`" becomes type-level. Core never resolves secrets — a
  project's `psTestConfig` swaps `Vault` pointers for `TestPlaintext` read from its own `test-secrets.dhall`.

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

- Strict-decode `<project>.dhall` / `test.dhall` (no field defaulted at decode or init by core).
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

Generalize `ProjectSpec` to `ProjectSpec cfg tcfg`, coupling core to `cfg` only via `psBinaryContext ::
cfg -> BinaryContext` and `psLiftChild :: BinaryContext -> cfg -> cfg`. Demote `ProjectConfig` /
`Resources` / `DeployConfig` to the demo's concrete instance.

#### Deliverables

- `ProjectSpec cfg tcfg` with config/test codecs and the two lift accessors; `runHostBootstrapCLI` generic.
- The resource budget / VM cordon documented as a provider concern carried by a project's `cfg`, not a
  universal field (§ O amended by § BB).
- A project's own config fields live on its `cfg` (the demo's `message` is added on the demo's `cfg` in
  phase-20) — core owns no project-specific field and no generic `extra` slot.

#### Validation

`cabal test all`; the demo compiles against the parameterized spec with `cfg = ProjectConfig`. Validation
substrate: linux-cpu (code-check).

#### Remaining Work

Code complete and validated (2026-06-23): `ProjectSpec cfg tcfg` is parameterized via the new
`HostBootstrap.Config.Class.ProjectCfg` typeclass (`cfgContext` / `cfgWithContext`); `ProjectConfig` /
`Resources` / `DeployConfig` / `TestConfig` (and `Container`) moved to the demo
(`HostBootstrapDemo.Config` / `.Container`), so core owns no config type. The `message` field lands on the
demo's own cfg in [phase-20](phase-20-config-driven-demo-worked-example.md). Verified by core `cabal build
-Werror` + `cabal test all` (232) and demo `cabal build -Werror` + its own suite (13). Real-run-validated
2026-06-23 (test run all 3/3 from a generated config).

### Sprint 19.3: DRY init + harness-generated config + sibling-path precondition [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`

#### Objective

Add `psInit :: InitArgs -> cfg`, `psTestInit :: InitArgs -> tcfg`, and `psTestConfig :: tcfg -> IO cfg`;
flip `test run` to *generate* the run's `<project>.dhall` from `test.dhall` via `psTestConfig` (reusing
`psInit`) and delete the generated config + self-created `.test_data` on teardown (closing the § Z
code-vs-contract drift). Fix the harness existence precondition to check the executable-sibling
`siblingProjectConfigPath` (`.build/<project>.dhall`), not `getCurrentDirectory`/the project root.

#### Deliverables

- `test init` writes `test.dhall` from `psTestInit` without requiring an existing `<project>.dhall`.
- `test run` generates → `project up` → assert → `project destroy` → delete generated config; keeps `test.dhall`.
- `demoTestSafety` checks the sibling `.build/<project>.dhall` so the fail-fast guard fires on the config
  `project up` actually reads; the value-free `projectConfigForRole` builder is shared by `project init`,
  `test init`, and the harness (never shelling the CLI).

#### Validation

`cabal test all`; demo `test run all` runs from a generated config (no pre-existing `<project>.dhall`).
Validation substrate: linux-cpu (the harness real-run on native Incus/Linux).

#### Remaining Work

Code complete and validated (2026-06-23): `psInit` / `psTestInit` / `psTestConfig` added; `test init`
needs no pre-existing `<project>.dhall`; `test run` generates the run's config via `psTestConfig`, drives
the real `project up`, asserts, `project destroy`, then deletes the generated config (keeping `test.dhall`);
`demoTestSafety` now checks the executable-sibling `siblingProjectConfigPath`, not the project root.
Verified by `cabal test all` (232) + the demo suite (13). Real-run-validated 2026-06-23 (test run all 3/3
from a generated config).

### Sprint 19.4: Generic `SecretRef` and `test-secrets` seam [Done]

**Status**: Done
**Docs to update**: `documents/engineering/secrets.md`, `documents/architecture/generic_project_model.md`

#### Objective

Add the pure `SecretRef = < Vault | TransitKey | Prompt | TestPlaintext >` vocabulary to core (no Vault
dependency), so a secrets-strict consumer can keep production `<project>.dhall` plaintext-free and inject
test secrets through `psTestConfig` reading a project-specific `test-secrets.dhall`.

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
anti-drift and round-trip tests (`cabal test all`: 237 passed). The `~/prodbox` consumer migration
(composing a `test-secrets.dhall` via `psTestConfig`) remains a future consumer-side phase, out of scope
here — the seam is generic enough to host it.

### Sprint 19.5: Remove the Python config auto-init [Done]

**Status**: Done
**Implementation**: `hostbootstrap/bootstrap.py`, `tests/test_bootstrap.py`, `tests/test_cli.py`
**Docs to update**: `documents/architecture/python_haskell_boundary.md`, `documents/architecture/binary_context_config.md`, `documents/engineering/config_generation.md`, `documents/architecture/build_and_run_model.md`, `documents/engineering/schema.md`, `development_plan_standards.md` (§§ M/N/Q/X/Y), `00-overview.md`, `system-components.md`, `DEVELOPMENT_PLAN/README.md`, `legacy-tracking-for-deletion.md`, `README.md`

#### Objective

Remove the Python bootstrapper's `project init --if-missing` trigger. Python builds the host-native binary
and execs it; the binary owns its Dhall. This is the boundary consequence of the generic config model (no
core defaults + harness-generates-config): a project's first config is an explicit choice (`project init`)
or a harness-generated artifact (`psTestConfig`), never a fabricated default. Removing the trigger also
restores the harness safety precondition's meaning — the "refuse if a production config exists" guard can
finally observe a clean slate.

#### Deliverables

- `hostbootstrap run` builds + execs with no config step; a normal command on an absent sibling
  `<project>.dhall` fails fast (exit 1) and points the user to `project init`.
- The `project_init_command` trigger removed from `hostbootstrap/bootstrap.py`; the §§ M/N/Q/X/Y boundary
  prose and the indexes describe build + exec only (and use `project init`, not the legacy `config init`).
- `legacy-tracking-for-deletion.md` records the removed trigger; the two Removed-Surfaces self-contradictions
  are corrected.

#### Validation

`poetry run python -m hostbootstrap.check_code` clean; `test_all` 100% (the removed-trigger assertion
replaces the prior "Python triggers init" tests); live fresh-host bootstrap → `project init` → `project up`.
Validation substrate: linux-cpu.

#### Remaining Work

None — landed and validated (2026-06-23): `hostbootstrap/bootstrap.py` builds the host-native binary and
execs it with no config-init step (the `project_init_command` trigger is deleted), so a normal command
fails fast when no sibling `<project>.dhall` exists. `poetry run python -m hostbootstrap.check_code` is
clean (ruff / black / mypy) and `test_all` reports 166 passed.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/generic_project_model.md` — the canonical generic-project-model design contract
- `documents/architecture/hostbootstrap_core_library.md` — `ProjectSpec cfg tcfg` and the lift accessors
- `documents/architecture/harness_workflow.md` — the harness-generates-then-cleans-up the run's config flow
- `documents/architecture/python_haskell_boundary.md` — Python builds + execs only; the binary owns config init (no auto-init trigger)
- `documents/architecture/binary_context_config.md` — the binary fails fast on an absent sibling config; no Python trigger
- `documents/architecture/build_and_run_model.md` — config is absent post-build until `project init` / harness generation

**Engineering docs to create/update:**
- `documents/engineering/secrets.md` — the `SecretRef` pure type and `test-secrets.dhall` composition seam
- `documents/engineering/schema.md` — config type is project-defined and explicit (no core defaults; strict decode)
- `documents/engineering/config_generation.md` — the shared value-free builder; config absent until created by user/harness
- `documents/engineering/testing.md` — `test run` generates the run's `<project>.dhall` from `test.dhall`
- `documents/engineering/authoring_project_binaries.md` — the `psInit` / `psTestInit` / `psTestConfig` seams
- `documents/engineering/resource_budgeting.md` — the budget is a provider concern carried by a project's `cfg`

**Cross-references to add:**
- `development_plan_standards.md` §§ M/N/Q/X/Y (the Python boundary) and § BB; `00-overview.md`, `README.md`,
  and `system-components.md` phase rows
- `legacy-tracking-for-deletion.md` Pending entries owned by this phase
- `phase-20-config-driven-demo-worked-example.md` (the demo realization that depends on this phase)
