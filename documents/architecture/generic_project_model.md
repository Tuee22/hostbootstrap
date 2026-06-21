# Generic Project Model

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [hostbootstrap_core_library.md](hostbootstrap_core_library.md), [harness_workflow.md](harness_workflow.md), [../engineering/schema.md](../engineering/schema.md), [../engineering/secrets.md](../engineering/secrets.md), [../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md)

> **Purpose**: Define `hostbootstrap-core` as a fully generic library with no hardcoded defaults,
> parameterized over a project's own config type, so `project init` and the test harness share one
> project-owned config builder and the harness generates the run's `<project>.dhall`.

## TL;DR

- `hostbootstrap-core` is a **library of pure shapes + the lift algebra + the harness**. It owns **no
  default config values** and **no fixed config type** — the project supplies both.
- The extension contract is `ProjectSpec cfg tcfg`, generic over the project's config type `cfg` (its
  `<project>.dhall`) and test-config type `tcfg` (its `test.dhall`). Core couples to `cfg` only through the
  **lift authority**: `cfg -> BinaryContext` and `BinaryContext -> cfg -> cfg`.
- Defaults live **only** in a project-owned `psInit :: InitArgs -> cfg`. `project init` calls it; the
  harness reuses it (DRY), so there is one config builder, not two that drift.
- `test.dhall` is a **thin override**; the harness **generates** the run's `<project>.dhall` from it via
  the project's own init logic, runs the real `project up`, then deletes the generated config.
- A pure `SecretRef` vocabulary lets a secrets-strict consumer keep production configs plaintext-free; core
  never resolves secrets.

## Current Status

This document defines the **target** generic model. The current implementation is concrete: core owns
`defaultResources` / `defaultDeployConfig` / `defaultProjectConfig` and a fixed `ProjectConfig` type, and
the test harness drives `project up` against the **pre-existing** `<project>.dhall` rather than generating
it. The generalization is reopened, documentation-only work tracked in
[phase-19-generic-project-model.md](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md) and the
superseded surfaces are listed in
[legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md). The canonical
contract statement is [development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## What is universal versus project-defined

The genuinely universal substrate is **not** the config record — it is the compositional lift and the test
engine:

| Universal (`hostbootstrap-core` owns) | Project-defined (the consumer owns) |
|---|---|
| `BinaryContext`, `ContextKind`, `ProviderKind`, `Capability` — the pure context shape | The config type `cfg` (its `<project>.dhall`) and test-config type `tcfg` |
| `childContext` / the `Step` and frame graph — the lift algebra | The init builder `psInit` (the **only** place defaults live) |
| `runMatrix` / the harness engine, `.test_data` lifecycle, safety preconditions | The chain `cfg -> [Step]`, the providers, the resource/VM budget (if any) |
| The `SecretRef` pure vocabulary (no resolution) | How secrets resolve (Vault, prompts, env) and `psTestConfig` |

The resource budget and VM cordon are a **provider** concern carried by a project's `cfg` — not a field
every consumer config must have. A secrets-strict, RKE2/EKS-sized consumer (`~/prodbox`) carries no VM
budget at all; the demo carries `Resources { cpu, memory, storage }`.

## The extension contract: `ProjectSpec cfg tcfg`

```haskell
data ProjectSpec cfg tcfg = ProjectSpec
  { psConfigCodec   :: DhallCodec cfg          -- strict decode + render <project>.dhall
  , psTestCodec     :: DhallCodec tcfg          -- strict decode + render test.dhall
  , psBinaryContext :: cfg -> BinaryContext     -- the ONLY universal coupling: frame/role/lift authority
  , psLiftChild     :: BinaryContext -> cfg -> cfg   -- mint a child-frame cfg (host -> VM -> container)
  , psInit          :: InitArgs -> cfg          -- the ONLY place defaults live (project-owned)
  , psTestInit      :: InitArgs -> tcfg         -- build a complete, valid test.dhall
  , psTestConfig    :: tcfg -> IO cfg           -- derive the test-time cfg; reuses psInit (IO for extra inputs)
  , psChain         :: cfg -> [Step]
  , psFrameContext  :: cfg -> StepFrame -> LiftContext
  , psTeardown      :: cfg -> Bool -> IO ()
  , psServices      :: ServiceRegistry
  , psArtifacts     :: [ConfigArtifact]
  , psCheckCode     :: IO ()
  , psCases         :: [Case]
  }
```

Every field a project supplies is pure or project-owned. Core's command tree
(`project`/`test`/`service`/`context`/`check-code`) stays fixed (§ P); only the **types** it threads become
generic.

## DRY init and the harness-generated config

`project init` and `test run` build the project config the **same** way — through `psInit` — so the init
default and the test config can never drift:

```text
project init  : InitArgs --psInit--> cfg ---write---> <project>.dhall
test run      : test.dhall --psTestConfig (reuses psInit + applies overrides)--> cfg
                  --write--> <project>.dhall --project up--> assert --project destroy-->
                  delete generated <project>.dhall + self-created .test_data   (keep test.dhall)
```

`psTestConfig` is `IO` so a project can read extra inputs — e.g. a `test-secrets.dhall` — and weave them
in. The demo's `psTestConfig` is effectively pure (apply the override resources); a secrets-strict
consumer's reads `test-secrets.dhall` and substitutes `TestPlaintext` for its `Vault` pointers. See
[harness_workflow.md](harness_workflow.md) for the full flow and [secrets.md](../engineering/secrets.md)
for the secrets seam.

### WRONG / RIGHT

> **WRONG** — two independent defaults that drift:
>
> ```haskell
> -- core
> defaultResources = Resources 4 "8GiB" "20GiB"   -- project init writes this
> -- demo
> demoFullLifecycleResources = Resources 6 "10GiB" "80GiB"  -- deploy-VM rejects anything smaller
> ```
>
> The shipped `project init` default cannot pass the shipped gate; the budget is declared twice and must be
> kept in sync by hand.
>
> **RIGHT** — one project-owned builder feeds init, the gate, and the test config:
>
> ```haskell
> psInit args = DemoConfig { resources = demoBudget, … }   -- the one place the budget lives
> -- deploy-VM reads cfg.resources; test run derives cfg from test.dhall via psTestConfig (reusing psInit)
> ```

## Cross-references

- [hostbootstrap_core_library.md](hostbootstrap_core_library.md) — the module surface and the fixed
  command tree the generic `ProjectSpec` feeds.
- [harness_workflow.md](harness_workflow.md) — the harness that generates and cleans up the run's config.
- [../engineering/schema.md](../engineering/schema.md) — the project-defined, explicit config schema.
- [../engineering/secrets.md](../engineering/secrets.md) — `SecretRef` and the `test-secrets` seam.
