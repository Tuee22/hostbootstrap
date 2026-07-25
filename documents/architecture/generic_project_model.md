# Generic Project Model

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [hostbootstrap_core_library.md](hostbootstrap_core_library.md), [harness_workflow.md](harness_workflow.md), [../engineering/schema.md](../engineering/schema.md), [../engineering/secrets.md](../engineering/secrets.md), [../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md)

> **Purpose**: Define `hostbootstrap-core` as a fully generic library with no hardcoded defaults,
> parameterized over a project's own config type; distinguish the current independent init/test callbacks
> and demo-only helper convention from target `psAssemble` structural reuse; and define how the harness
> generates the run's `<project>.dhall`.

## TL;DR

- `hostbootstrap-core` is a **library of pure shapes + the lift algebra + the harness**. It owns **no
  default config values** and **no fixed config type** — the project supplies both.
- The extension contract is `ProjectSpec cfg tcfg`, generic over the project's config type `cfg` (its
  `<project>.dhall`) and test-config type `tcfg` (its `<project>.test.dhall`). The current `ProjectCfg`
  class exposes `cfgContext` plus a required but production-unused `cfgWithContext` compatibility method;
  the latter is not authority. The target removes that raw updater and couples through validated,
  scope-correct codecs. Current `psServiceVariant :: cfg -> Either String String` is an arbitrary
  selector; the target runtime codec jointly binds a typed request/parameters to a fresh child-local
  `configId` and verified exact-byte wire identity; no full `ValidatedConfig` crosses that runtime
  boundary. Dispatch forms one existential
  config/frame/revision/instance/registry/effect-indexed `SelectedService` package internal to the
  core-owned masked run-to-Exit operation. Its handler receives only the matching project-owned role
  parameters, not the full `cfg`.
- Current `psInit`, `psTestInit`, and `psTestConfig` are independent callbacks. The demo shares
  `demoInitWithMessage` between `demoInit` and `demoTestConfig` by convention, while demo service
  projection has hard-coded port/timeout fallbacks. Target `psAssemble` is the sole default-bearing
  structural assembler and role projections cannot invent values.
- `<project>.test.dhall` is a **thin override**; the harness **generates** the run's `<project>.dhall`
  through the project's independent `psTestConfig` callback, runs the real `project up`, then deletes
  only matching generated config bytes; changed bytes remain in place and are reported rather than being
  deleted. The demo's callback shares a helper with `demoInit` by convention. The current sidecar guard
  is cooperative, not a resource-authoritative reservation or verified ownership receipt.
- A pure `SecretRef` vocabulary replaces raw secret `Text` with references and core never resolves
  secrets. Its `TestPlaintext` constructor is currently excluded from production by consumer policy, not
  by a scoped core type. The target `SecretRef scope` requires matching harness authority for
  `TestPlaintext` and gives the Production schema no such constructor.

## Current Status

The generic config boundary is implemented, while the development plan owns the target typed
case/variant identity, non-empty variant representation, and production-versus-harness secret scope.
Those refinements do not restore the former core-owned config type. `hostbootstrap-core` owns no
`defaultResources` / `defaultDeployConfig` / `defaultProjectConfig` and no fixed `ProjectConfig` type;
projects supply `ProjectSpec cfg tcfg`, `psInit`, `psTestInit`, and `psTestConfig`. `test init` writes a
thin `<project>.test.dhall` without a pre-existing production config, and `test run` generates each run's
`<project>.dhall`, drives the real `project up`, then removes the generated config on teardown only while
the recorded bytes still match. The current `psTestConfig` result is a string-labeled list and can
represent an empty list; the target replaces that illegal state with typed `CaseId`/`VariantId` and a
non-empty result. The
superseded concrete-config and pre-existing-config flows are listed in
[legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md). The canonical
contract statement is [development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## What is universal versus project-defined

The genuinely universal substrate is **not** the config record — it is the compositional lift and the test
engine:

| Universal (`hostbootstrap-core` owns) | Project-defined (the consumer owns) |
|---|---|
| `BinaryContext`, `ContextKind`, `ProviderKind`, `Capability` — the pure context shape | The config type `cfg` (its `<project>.dhall`) and test-config type `tcfg` |
| `childContext` / the `Step` and frame graph — the lift algebra | Current independent `psInit`/`psTestInit`/`psTestConfig` callbacks (with a demo-only shared helper); target sole default-bearing `psAssemble` plus role-specific projections |
| `runMatrix` / the harness engine, generic `.test_data` helper, safety preconditions | The chain `cfg -> [Step]`, the providers, the resource/VM budget (if any) |
| The `SecretRef` pure vocabulary (no resolution) | How secrets resolve (Vault, prompts, env) and `psTestConfig` |

The resource budget and VM cordon are a **provider** concern carried by a project's `cfg` — not a field
every consumer config must have. A secrets-strict, RKE2/EKS-sized consumer (`~/prodbox`) carries no VM
budget at all; the demo carries `Resources { cpu, memory, storage }`.

A field a project's workload reads and renders is likewise a field of **its own** `cfg`, never a core
slot. The demo's `cfg` carries a mandatory `message : Text` (its current `psInit` default
`"Hello, world!"`). The target flow is:

```text
parent ValidatedConfig scope specDigest configId (cfg scope)
  → role-specific descriptive wire + stable digest/manifest
  → ConfigMap
  → child-local wire verification + RoleCodec
  → fresh child configId + spec/config/secret-bound ValidatedServiceRequest
  → RoleParams specDigest configId secretDigest fields Web
  → BudgetView.message
  → SPA #message
```

The parent never transports an opaque request or reuses its `configId`; the service process validates
its exact mounted bytes and mints a fresh local identity before filtering parameters. Core owns no
project-specific field, and in particular **no generic
`extra : Map Text Text` slot**: a map would re-couple core to a demo concern, and its lookup is a runtime
`Maybe`, reintroducing exactly the decode-time optionality the strict-decode contract removes. A typed
`message : Text` on the demo's own `cfg` stays mandatory and strict-decoded, while its closed consumer
set makes it available to the service-projection plan and Web handler without exposing unrelated fields.

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
> **RIGHT (target)** — `message` is a typed mandatory project field whose consumer set includes the Web
> projection and handler:
>
> ```haskell
> -- demo config (cfg leaves core)
> data DemoConfig = DemoConfig { resources :: Resources, …, message :: Text }
>
> -- demo codec/schema declaration; exact constructors are opaque
> messageField ::
>   ProjectField
>     (VisibleTo '[Plan ClusterService, Service Web])
>     "message"
>     Text
>
> -- Web registry entry
> serveWeb ::
>   RoleParams specDigest configId secretDigest fields Web ->
>   ServiceProgram
>     scope specDigest planId configId secretDigest frame revision instanceId
>     ServePhase Web effects ()
> serveWeb params =
>   serveBudgetMessage (roleField @"message" params)
> ```
>
> Child-local codec validation creates the Web request and filtered parameters under the same fresh
> `configId`. `roleField` is total because the schema row proves that mandatory field is visible to Web;
> the handler receives neither `DemoConfig` nor a config-reading effect.

## The extension contract: `ProjectSpec cfg tcfg`

```haskell
data ProjectSpec cfg tcfg = ProjectSpec
  { psTestSuite     :: TestSuite                -- the project's runtime suite (safety, bring-up, [Case], assert, teardown)
  , psCheckCode     :: IO ()                    -- the project's code-check action
  , psArtifacts     :: [ConfigArtifact]         -- the project's schema-artifact delta
  , psServiceVariant :: cfg -> Either String String -- current arbitrary selector; not target authority
  , psServices      :: ServiceRegistry          -- the project's service-handler registry
  , psChain         :: cfg -> [Step]            -- the project's lift chain
  , psFrameContext  :: cfg -> StepFrame -> LiftContext
  , psTeardown      :: cfg -> Bool -> IO ()     -- chain-frame teardown: stop (False) vs delete (True)
  , psInit          :: InitArgs -> cfg          -- current project-init path; independent of test callbacks
  , psTestInit      :: InitArgs -> tcfg         -- build a complete, valid <project>.test.dhall
  , psTestConfig    :: tcfg -> IO [(Text, cfg)] -- current string-labeled list; Phase 19.6 makes it typed and NonEmpty
}
```

This is the **current** extension record, not the final lifecycle representation. In particular,
`psChain`, `psFrameContext`, and `psTeardown` are independently supplied functions and can disagree.
The target replaces those three fields with the opaque
`ProjectPlan scope specDigest planId configId cfg` defined in
[composition methodology](composition_methodology.md#single-representation-the-chain-is-the-representation):
one non-empty validated step sequence, with topology derived from it and reverse work derived from the
ownership receipts acquired while interpreting it.

The target also generalizes the project config as a family `cfg :: Type -> Type`. Production
init/decode/dispatch
uses only `cfg (Production projectId)`; the test projection requires opaque
`HarnessAuthority projectId runId` and returns only
`cfg (Harness projectId runId)`. The target's single default-bearing seam is
`psAssemble :: AssemblyRequest scope tcfg -> ConfigAssembly scope (cfg scope)`: `ProductionAssembly`
and `HarnessAssembly authority draft` are disjoint constructors of that sole closed request; the opaque
validated draft already contains its stable identity and typed override payload,
so identity/variant/default inputs occur once and cannot disagree. Init and test projection share
defaults without ever converting an already constructed Production value. `ConfigAssembly` is a restricted read-only effect for declared
config/secret inputs; it exposes neither general `IO` nor lifecycle/backend mutation. For a fresh
harness run, `withAssembledHarnessConfig` consumes its `HarnessAuthority`, scope-correct
`ProjectCodec scope specDigest cfg`, and assembled value, then canonical-renders, hashes, and strictly
re-decodes it while jointly yielding the root-local verified wire identity and
`ValidatedConfig scope specDigest configId (cfg scope)`.
`ProjectPlan scope specDigest planId configId cfg` construction requires
`ValidatedConfig scope specDigest configId (cfg scope)` and a
`NonEmpty (PlanDraft scope specDigest (cfg scope))`. Child projection preserves the exact scope and stable plan
revision but, because the narrowed child bytes differ, mints a fresh child `configId` linked to the
parent by an opaque `ProjectionBinding`; it does not reuse an exact-byte parent identity. A
secrets-strict config uses `SecretRef scope`, whose `TestPlaintext` constructor requires the matching
harness authority; the reflected Production Dhall schema has no plaintext alternative. A harness Dhall
payload decodes only to untrusted `HarnessConfigWire`. Grant verification through
`ProjectCodec (Harness projectId runId) specDigest cfg` checks its exact digest and bytes and jointly mints
`VerifiedConfigWire (Harness projectId runId) childConfigDigest childConfigId`, the exact
`VerifiedHandoff ... ConfigHandoff childConfigId verb phase`, a
child-local `HarnessConfigAuthority projectId runId`, and
`ValidatedConfig (Harness projectId runId) specDigest childConfigId
(cfg (Harness projectId runId))`.
Those values do not directly authorize dispatch: `withChildProjectPlan` consumes them with the closed
verb and `NonEmpty (PlanDraft (Harness projectId runId) specDigest
(cfg (Harness projectId runId)))` and jointly yields a fresh child
`ProjectPlan (Harness projectId runId) specDigest childPlanId childConfigId cfg`,
`PlanDigestBinding (Harness projectId runId) specDigest planDigest childPlanId`, and exact
`ChildPlanAuthority`; only `authorizeChildProject` consumes that narrow
authority. The child does not need the root's non-serializable authority before verification. There is
no raw-wire promotion, direct scoped `FromDhall`,
unscoped record update, or coercion from a harness config to Production. The detailed secret boundary is defined in
[secrets](../engineering/secrets.md).

Every field a project supplies is pure or project-owned. In the current compatibility API,
`ProjectCfg` requires `cfgContext :: cfg -> BinaryContext` and
`cfgWithContext :: BinaryContext -> cfg -> cfg`; only the reader has production call sites, while the
updater appears only in the class, instances, and tests. It must not be described as active lift
authority. The target deletes that raw updater: scope-correct `ProjectCodec scope specDigest cfg`,
verified wire identity, and `ValidatedConfig scope specDigest configId (cfg scope)` jointly govern child
projection/promotion. Current service dispatch uses the
unvalidated `ProjectSpec.psServiceVariant`; the target finalized spec jointly binds the hidden field
row, full `ProjectCodec scope specDigest cfg`, role-wire `RoleCodec`, and typed registry under one
`specDigest`. A parent can project only
`RuntimeRoleWire fields service`; child-local verification of the mounted bytes then yields
`ValidatedServiceRequest specDigest configId secretDigest fields service` under a fresh local `configId`
and verified secret-bundle digest. That request inseparably contains
`RoleParams specDigest configId secretDigest fields service`. The finalized typed registry and exact
one-use service command authority package the request and matching closed `ServiceProgram` handler
internally as
`SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase
fields`; its
`ServiceSelection scope specDigest planId configId secretDigest frame revision instanceId ServePhase
service effects` proves the handler's exact effect row is authorized. Before Acquire, the signed
placement's `permittedEffects` ceiling conservatively derives the acquisition plan's lease requirement;
callers cannot choose a no-lease branch, and Serve can select only a row proved within that same ceiling.
The core-owned masked `runVerifiedRuntimeRole` consumes the ready managed handles and inseparable retained
receipt/lease package and privately invokes `selectAndRunService`, which always returns a Drain advance;
each mutating effect seals its exact target/arguments under a call digest and threads every
prepare/call failure or unknown outcome with the sole session and retained package. Only the private
full-lineage same-key recovery transition may resume an unknown call. Project code never receives the
selected package as an arbitrary callback. Callers cannot choose the hidden field row, transport the parent
identity/request, project the full config/raw `IO` into the handler, or substitute a request, parameter,
handler, revision, instance, phase, or effect row.
Together with the current `FromDhall`/`ToDhall` constraints, core can strict-decode
and render `<project>.dhall`. Core's command tree
(`project`/`test`/`service`/`context`/`check-code`) stays fixed (§ P); only the **types** it threads become
generic.

## DRY init and the harness-generated config

Core currently stores `psInit`, `psTestInit`, and `psTestConfig` as independent callbacks, and
`testCommand` does not consume the init builder. The demo happens to call `demoInitWithMessage` from both
its `psInit` and `psTestConfig` paths, so some defaults are shared by convention, not by the generic
type. A future project—or a later edit to either callback—can still make them disagree. Current service
projection also substitutes hard-coded Web ports and accelerator timeout when the inherited optional
service constructor does not match. (`test init` produces a `tcfg` via the independent `psTestInit`
callback.) The harness does correctly build in process rather than shelling `project init`, but that
alone does not make the two callbacks one structural source.

The current demo flow is:

```text
project init  : InitArgs --projectConfigForRole (psInit)--> cfg ---write---> <project>.dhall
test init     : InitArgs --psTestInit (defaultTestConfig)--> tcfg --write--> <project>.test.dhall  (no pre-existing <project>.dhall needed)
test run      : <project>.test.dhall --demo psTestConfig (shares helper by convention + applies overrides)--> [(label, cfg)]  (current list; Phase 19.6 makes it typed and NonEmpty)
                  --write--> <project>.dhall --project up--> assert --project destroy-->
                  compare-and-delete generated <project>.dhall   (keep <project>.test.dhall)
```

Core also has a self-created `.test_data` ownership helper, but the demo's live plan currently selects
Production/`.data`; the presence of that generic helper does not make the demo run isolated. See
[harness workflow](harness_workflow.md).

`psTestConfig` is `IO` so a project can read extra inputs — e.g. a `test-secrets.dhall` — and weave them
in. Its current type returns a list of string-labeled `(label, cfg)` variants; the demo returns two, but
the type can represent an empty list or invalid/duplicate labels. Phase 19.6 replaces that surface with
validated IDs and a non-empty collection so those states cannot reach the harness.
The demo's `psTestConfig` returns two variants (labeled `"Hello, world!"` and `"Hello, Universe!"`, Sprint
20.3) whose labels are threaded into each variant's assertion env as the expected served message; a
secrets-strict consumer reads `test-secrets.dhall` and currently substitutes `TestPlaintext` for its `Vault`
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
> **TARGET** — one project-owned assembler feeds init, harness config, and every role projection:
>
> ```haskell
> psAssemble (ProductionAssembly inputs) =
>   DemoConfig { resources = validatedBudget inputs, message = "Hello, world!", … }
> -- plan construction consumes one ValidatedConfig scope specDigest configId (cfg scope);
> -- test run supplies HarnessAssembly authority draft to this same assembler;
> -- service projection invents no fallbacks
> ```

## Cross-references

- [hostbootstrap_core_library.md](hostbootstrap_core_library.md) — the module surface and the fixed
  command tree the generic `ProjectSpec` feeds.
- [harness_workflow.md](harness_workflow.md) — the harness that generates and cleans up the run's config.
- [../engineering/schema.md](../engineering/schema.md) — the project-defined, explicit config schema.
- [../engineering/secrets.md](../engineering/secrets.md) — `SecretRef` and the `test-secrets` seam.
