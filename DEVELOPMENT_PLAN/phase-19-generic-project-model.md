# Phase 19: Generic Project Model and No Core Defaults

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [development_plan_standards.md](development_plan_standards.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), [phase-4-skeletal-dhall-and-command-tree.md](phase-4-skeletal-dhall-and-command-tree.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md), [phase-10-standardized-test-harness.md](phase-10-standardized-test-harness.md), [phase-15-binary-context-config.md](phase-15-binary-context-config.md), [phase-17-chain-driven-test-and-context-introspection.md](phase-17-chain-driven-test-and-context-introspection.md)

> **Purpose**: Make `hostbootstrap-core` a fully generic library with **no hardcoded defaults**,
> parameterized over a project's own config type, so `project init` and `test init`/`test run` share one
> project-owned config builder (DRY) and the harness *generates* the run's `<project>.dhall` — generic
> enough to host a secrets-strict, Vault-backed consumer such as `~/prodbox`.

## Phase Status

**Status**: Planned

This phase is documentation-only at present: it records the target generic-project-model contract
(`development_plan_standards.md` § BB) and reopens the surfaces it supersedes. No code has changed.
Phases [4](phase-4-skeletal-dhall-and-command-tree.md),
[8](phase-8-dhall-generation-and-extension.md),
[10](phase-10-standardized-test-harness.md),
[15](phase-15-binary-context-config.md), and
[17](phase-17-chain-driven-test-and-context-introspection.md) are reopened (`Active`) because their
`Done` scope claimed core-owned defaults, a fixed universal config type, and a `test`-reads-then-reuses
flow that this phase replaces. The superseded surfaces are listed in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with this phase as owner.

## Motivation

Three independent gaps surfaced while exercising the demo lifecycle and reviewing `~/prodbox`:

1. **Core owns defaults a consumer cannot override.** `defaultResources` (`4/8/20`),
   `defaultDeployConfig`, and `defaultProjectConfig` live in `HostBootstrap.Config.Schema`; `initAction`
   bakes them into the `project init` flags; `ProjectSpec` exposes no init hook. The demo's `deploy-VM`
   gate (`demoFullLifecycleResources = 6/10/80`, `demo/src/HostBootstrapDemo/Commands.hs`) is a *separate*
   constant, so the shipped default cannot pass the shipped gate — a fresh `project init` writes a config
   `project up` then rejects.
2. **`test init`/`test run` are inverted from § Z.** Today `test init` *reads* the existing
   `<project>.dhall` to seed `TestConfig.testResources`, and `demoTestUp` drives `project up` against that
   *pre-existing* config; the `testResources` override is read and printed but never applied. § Z already
   specifies the opposite (the harness *writes* the run's `<project>.dhall` from the overrides), so this is
   a code-vs-contract drift, not a new requirement.
3. **Core hardcodes the config *shape*.** `ProjectConfig { dockerfile, resources, context, deploy }` is a
   fixed universal type. A secrets-strict consumer (`~/prodbox`) has a different shape entirely — a Tier-0
   `{ parameters, context, witness }` record whose secret fields are `SecretRef` *pointers*
   (`Vault {mount,path,field}` / `TransitKey` / `Prompt` / `TestPlaintext`), with **no** VM resource
   budget at all (it sizes via RKE2/EKS). The resource budget / VM cordon is therefore a **provider**
   concern, not a core-universal field.

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
- **`test.dhall` is a thin override** (`tcfg`): mandatory test fields (suite selection, the `.test_data`
  durable dir) plus only the config overrides a test needs.
- **The harness generates and owns the run's config.** `test run` reads `test.dhall`, refuses if a
  `<project>.dhall` exists or a production cluster is running, builds the config via
  `psTestConfig :: tcfg -> IO cfg` (reusing `psInit`; `IO` so a project can read extra inputs such as a
  `test-secrets.dhall`), writes `<project>.dhall`, runs `project up`, asserts, `project destroy`, then
  deletes the **generated** `<project>.dhall` and self-created `.test_data` (keeping `test.dhall`).
- **Generic secrets shape.** Core offers a pure `SecretRef` union projects may embed in `cfg`; "no
  plaintext secrets in a production `<project>.dhall`" becomes type-level. Core never resolves secrets — a
  project's `psTestConfig` swaps `Vault` pointers for `TestPlaintext` read from its own `test-secrets.dhall`.

See [generic_project_model](../documents/architecture/generic_project_model.md) for the canonical design
and [secrets.md](../documents/engineering/secrets.md) for the `SecretRef` / `test-secrets` pattern.

## Sprints

### Sprint 19.1: Strip core defaults [PLANNED]

**Status**: Planned
**Docs to update**: `documents/engineering/schema.md`, `documents/engineering/resource_budgeting.md`

#### Objective

Remove `defaultResources` / `defaultDeployConfig` / `defaultProjectConfig` from `HostBootstrap.Config.Schema`
and the `fromMaybe (… defaultResources)` / `value (memory defaultResources)` defaults from
`HostBootstrap.Command.initAction`, so core owns no default config values.

#### Deliverables

- Strict-decode `<project>.dhall` / `test.dhall` (no field defaulted at decode or init by core).
- `project init` sources every default from the project-owned builder (Sprint 19.3), not core constants.

#### Validation

`cabal test` (incl. `DocValidator`); a `project init` that omits a project default fails fast.

#### Remaining Work

All of it — documentation-only at present.

### Sprint 19.2: Parameterize `ProjectSpec` over `cfg`/`tcfg` [PLANNED]

**Status**: Planned
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `documents/engineering/authoring_project_binaries.md`

#### Objective

Generalize `ProjectSpec` to `ProjectSpec cfg tcfg`, coupling core to `cfg` only via `psBinaryContext ::
cfg -> BinaryContext` and `psLiftChild :: BinaryContext -> cfg -> cfg`. Demote `ProjectConfig` /
`Resources` / `DeployConfig` to the demo's concrete instance.

#### Deliverables

- `ProjectSpec cfg tcfg` with config/test codecs and the two lift accessors; `runHostBootstrapCLI` generic.
- The resource budget / VM cordon documented as a provider concern carried by a project's `cfg`, not a
  universal field (§ O amended by § BB).

#### Validation

`cabal test`; the demo compiles against the parameterized spec with `cfg = ProjectConfig`.

#### Remaining Work

All of it — documentation-only at present.

### Sprint 19.3: DRY init + harness-generated config [PLANNED]

**Status**: Planned
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`

#### Objective

Add `psInit :: InitArgs -> cfg`, `psTestInit :: InitArgs -> tcfg`, and `psTestConfig :: tcfg -> IO cfg`;
flip `test run` to *generate* the run's `<project>.dhall` from `test.dhall` via `psTestConfig` (reusing
`psInit`) and delete the generated config + self-created `.test_data` on teardown (closing the § Z
code-vs-contract drift).

#### Deliverables

- `test init` writes `test.dhall` from `psTestInit` without requiring an existing `<project>.dhall`.
- `test run` generates → `project up` → assert → `project destroy` → delete generated config; keeps `test.dhall`.

#### Validation

`cabal test`; demo `test run all` runs from a generated config (no pre-existing `<project>.dhall`).

#### Remaining Work

All of it — documentation-only at present.

### Sprint 19.4: Generic `SecretRef` and `test-secrets` seam [PLANNED]

**Status**: Planned
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

`cabal test`; a worked secrets-strict fixture round-trips `SecretRef` and composes `TestPlaintext` for tests.

#### Remaining Work

All of it — documentation-only at present; `~/prodbox` migration is **out of scope** here (a future
consumer-side phase), but this phase keeps the seams generic enough to host it.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/generic_project_model.md` — the canonical generic-project-model design contract
- `documents/architecture/hostbootstrap_core_library.md` — `ProjectSpec cfg tcfg` and the lift accessors
- `documents/architecture/harness_workflow.md` — the harness-generates-then-cleans-up the run's config flow

**Engineering docs to create/update:**
- `documents/engineering/secrets.md` — the `SecretRef` pure type and `test-secrets.dhall` composition seam
- `documents/engineering/schema.md` — config type is project-defined and explicit (no core defaults)
- `documents/engineering/testing.md` — `test run` generates the run's `<project>.dhall` from `test.dhall`
- `documents/engineering/authoring_project_binaries.md` — the `psInit` / `psTestInit` / `psTestConfig` seams
- `documents/engineering/resource_budgeting.md` — the budget is a provider concern carried by a project's `cfg`

**Cross-references to add:**
- `development_plan_standards.md` § BB; `00-overview.md`, `README.md`, and `system-components.md` phase rows
- `legacy-tracking-for-deletion.md` Pending entries owned by this phase
