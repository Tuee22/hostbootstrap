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

This generic model is implemented and phase 19 is `Done`. `hostbootstrap-core` owns no
`defaultResources` / `defaultDeployConfig` / `defaultProjectConfig` and no fixed `ProjectConfig` type;
projects supply `ProjectSpec cfg tcfg`, `psInit`, `psTestInit`, and `psTestConfig`. `test init` writes a
thin `<project>.test.dhall` without a pre-existing production config, and `test run` generates each run's
`<project>.dhall`, drives the real `project up`, then removes the generated config on teardown. The
superseded concrete-config and pre-existing-config flows are listed in
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

A field a project's workload reads and renders is likewise a field of **its own** `cfg`, never a core slot.
The demo's `cfg` carries a mandatory `message : Text` (its `psInit` default `"Hello, world!"`) that flows
`<project>.dhall` → the chart `ConfigMap` → the `Web` service (whose `service run` handler reads its config)
→ `BudgetView.message` → the SPA `#message`. Core owns no project-specific field, and in particular **no
generic `extra : Map Text Text` slot**: a map would re-couple core to a demo concern, and its lookup is a
runtime `Maybe`, reintroducing exactly the decode-time optionality the strict-decode contract removes. A
typed `message : Text` on the demo's own `cfg` stays mandatory and strict-decoded.

> **WRONG** — a generic core escape hatch the project writes through:
>
> ```haskell
> -- core
> data ProjectConfig = ProjectConfig { …, extra :: Map Text Text }  -- demo stuffs "message" here
> -- web handler
> message = fromMaybe "" (Map.lookup "message" (extra cfg))  -- runtime Maybe; "" when absent
> ```
>
> This re-couples core to a demo concern, makes the message optional at decode time, and is deleted by the
> very phase that moves `cfg` out of core.
>
> **RIGHT** — `message` is a typed mandatory field on the demo's own `cfg`:
>
> ```haskell
> -- demo (cfg leaves core)
> data DemoConfig = DemoConfig { resources :: Resources, …, message :: Text }
> -- web handler
> message = message cfg   -- mandatory, strict-decoded, no lookup
> ```

## The extension contract: `ProjectSpec cfg tcfg`

```haskell
data ProjectSpec cfg tcfg = ProjectSpec
  { psTestSuite     :: TestSuite                -- the project's runtime suite (safety, bring-up, [Case], assert, teardown)
  , psCheckCode     :: IO ()                    -- the project's code-check action
  , psArtifacts     :: [ConfigArtifact]         -- the project's schema-artifact delta
  , psServices      :: ServiceRegistry          -- the project's service-handler registry
  , psChain         :: cfg -> [Step]            -- the project's lift chain
  , psFrameContext  :: cfg -> StepFrame -> LiftContext
  , psTeardown      :: cfg -> Bool -> IO ()     -- chain-frame teardown: stop (False) vs delete (True)
  , psInit          :: InitArgs -> cfg          -- the ONLY place defaults live (project-owned)
  , psTestInit      :: InitArgs -> tcfg         -- build a complete, valid test.dhall
  , psTestConfig    :: tcfg -> IO [(Text, cfg)] -- the run's NON-EMPTY list of labeled cfg variants the harness loops over
  }
```

Every field a project supplies is pure or project-owned. The universal coupling to `cfg` is **not** a
`ProjectSpec` field — it is the project's `ProjectCfg` instance (`cfgContext :: cfg -> BinaryContext` and
`cfgWithContext :: BinaryContext -> cfg -> cfg`) plus the `FromDhall`/`ToDhall` constraints core uses to
strict-decode and render `<project>.dhall`. Core's command tree
(`project`/`test`/`service`/`context`/`check-code`) stays fixed (§ P); only the **types** it threads become
generic.

## DRY init and the harness-generated config

`psInit` (the demo's `demoInit`) is the **only** default-bearing builder; it fills every omitted knob with
the demo's defaults and delegates to one concrete, value-taking assembler, `projectConfigForRole`, that is
the **single** shared call site for the two `cfg`-producing paths — `project init` and the harness's
run-config generation (`test run`). Each path passes its own `InitArgs` (flag overrides for `project init`,
the `test.dhall` override for the harness) through `psInit` into the same `projectConfigForRole`, so the
demo's defaults live in exactly one place and never drift. (`test init` produces a `tcfg` via `psTestInit`
— the demo's `defaultTestConfig` — not a `cfg` through `projectConfigForRole`.) Critically, the harness
builds its config **functionally — it calls `projectConfigForRole` directly and never shells the CLI**
(`project init`); shelling out would reintroduce a second path that could drift from the in-process builder.

`project init` and `test run` build the project config the **same** way — both through
`projectConfigForRole` (via `psInit` for `project init` and `psTestConfig` for `test run`, each reusing the
one `demoInitWithMessage` builder) — so the init default and the harness's run config can never drift:

```text
project init  : InitArgs --projectConfigForRole (psInit)--> cfg ---write---> <project>.dhall
test init     : InitArgs --psTestInit (defaultTestConfig)--> tcfg --write--> <project>.test.dhall  (no pre-existing <project>.dhall needed)
test run      : test.dhall --psTestConfig (reuses projectConfigForRole + applies overrides)--> [(label, cfg)]  (non-empty; harness loops per variant)
                  --write--> <project>.dhall --project up--> assert --project destroy-->
                  delete generated <project>.dhall + self-created .test_data   (keep test.dhall)
```

`psTestConfig` is `IO` so a project can read extra inputs — e.g. a `test-secrets.dhall` — and weave them
in, and it returns a **non-empty list of labeled `(label, cfg)` variants** the harness runs one at a time.
The demo's `psTestConfig` returns two variants (labeled `"Hello, world!"` and `"Hello, Universe!"`, Sprint
20.3) whose labels are threaded into each variant's assertion env as the expected served message; a
secrets-strict consumer's reads `test-secrets.dhall` and substitutes `TestPlaintext` for its `Vault`
pointers. See
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
> psInit args = DemoConfig { resources = demoBudget, message = "Hello, world!", … }   -- the one place defaults live
> -- deploy-VM reads cfg.resources; the Web handler renders cfg.message;
> -- test run derives cfg from test.dhall via psTestConfig (reusing projectConfigForRole / psInit)
> ```

## Cross-references

- [hostbootstrap_core_library.md](hostbootstrap_core_library.md) — the module surface and the fixed
  command tree the generic `ProjectSpec` feeds.
- [harness_workflow.md](harness_workflow.md) — the harness that generates and cleans up the run's config.
- [../engineering/schema.md](../engineering/schema.md) — the project-defined, explicit config schema.
- [../engineering/secrets.md](../engineering/secrets.md) — `SecretRef` and the `test-secrets` seam.
