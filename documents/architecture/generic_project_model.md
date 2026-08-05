# Generic Project Model

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [hostbootstrap_core_library.md](hostbootstrap_core_library.md), [harness_workflow.md](harness_workflow.md), [../engineering/schema.md](../engineering/schema.md), [../engineering/secrets.md](../engineering/secrets.md), [../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md)

> **Purpose**: Define `hostbootstrap-core` as a fully generic library with no hardcoded defaults,
> parameterized over a project's own scope-indexed config family; define the single restricted
> `psAssemble` boundary used by Production init and Harness generation; define the opaque finalized
> project/step/role-codec boundary; and distinguish those implemented root-local identities from later
> child-handoff and receipt-driven lifecycle contracts.

## TL;DR

- `hostbootstrap-core` is a **library of pure shapes + the lift algebra + the harness**. It owns **no
  default config values** and **no fixed config type** — the project supplies both.
- The finalized extension contract is opaque `ProjectSpec projectId cfg tcfg`, generic over the project's config family
  `cfg :: Type -> Type` (its `<project>.dhall`) and test-config type `tcfg` (its
  `<project>.test.dhall`). `ProjectCfg projectId cfg` exposes only `cfgContext` and installs distinct
  Production and authority-closed Harness `ProjectCodec`s. A closed typed service registry is jointly
  finalized with the full codec under one canonical `specDigest`; each opaque `RoleCodec` reflects a
  wire containing mandatory `FrameworkValidation` plus only that service's fields. `service run`
  verifies one canonical sibling snapshot, structurally selects exactly one request, and closes the
  handler over its typed role fields and safe `LocalContextView`; neither a string selector nor the full
  `cfg` reaches the handler. Effect-indexed, one-use `SelectedService` execution remains Sprint 18.6.
- `psAssemble` is the sole project-config default-bearing assembler. Its closed request distinguishes
  Production init from one exact generative Harness run, and its restricted effect permits only
  declared reads. `psTestInit` separately constructs the project's `tcfg`; the demo's Web ports and
  accelerator timeout are explicit assembled fields preserved through child projection, with no fallback
  literals or duplicated optional service payload.
- Raw `ProjectSpec`, `Step`, `StepKind`, `ProjectStepId`, role-request, and role-parameter constructors
  are hidden. Builder contributions append; teardown is a checked single-assignment slot.
  `mkStepPlan` preserves exact declaration order and rejects empty plans, duplicate typed
  identities, conflicting frame labels, non-contiguous `A → B → A` returns, invalid post-handoff
  placement, and any frame that does not declare exactly one descent (none, for the innermost) before
  any step interpreter is returned.
- `<project>.test.dhall` is a **thin override**; `TestCfg` validates the executable cases and pure
  `VariantDraft`s into an opaque total `TestMatrix`. The harness **generates** each run's `<project>.dhall`
  through the scope-aware restricted assembler, runs the real `project up`, then unlinks the generated
  config only while its bound kernel identity **and** its recorded payload both still match; anything
  else remains in place and is reported. That guard is
  `HostBootstrap.Harness.GeneratedConfig`, which holds all four § EE ownership clauses over the file —
  not the cooperative sidecar it replaced. A verified ownership *receipt* for the rest of the
  lifecycle's resources is still open.
- `SecretRef scope` replaces raw secret `Text` with references and core never resolves secrets.
  `TestPlaintext` requires exact `HarnessConfigAuthority projectId runId`; the Production schema has no
  plaintext constructor. Root assembly is scope-safe now. One-time child handoff and child plan
  authority remain downstream lifecycle work.

## Current Status

The generic scope-indexed config boundary, typed test-matrix foundation, and opaque project/step/service
specification are implemented. These
contracts do not restore the former core-owned config type. `hostbootstrap-core` owns no
`defaultResources` / `defaultDeployConfig` / `defaultProjectConfig` and no fixed `ProjectConfig` type;
projects finalize `ProjectSpec projectId cfg tcfg` from additive builder contributions, one
`psAssemble`, and `psTestInit`. Production commands
accept only `cfg (Production projectId)`. Each selected test variant opens a fresh Harness authority,
assembles only `cfg (Harness projectId runId)`, validates it through the matching mapped codec, writes
that run's `<project>.dhall`, drives the real `project up`, then removes the generated config on teardown
only while the recorded bytes still match. Project and core step identities are disjoint, the validated
`StepPlan` is the sole render/apply/frame-order input, and typed service definitions bind projection,
role codec, and handler without a separately supplied selector. Validated opaque `CaseId`/`VariantId` values, pure
`VariantDraft`s, and the total non-empty matrix relation replace the former string-labeled, possibly
empty result. The
superseded concrete-config and pre-existing-config flows are listed in
[legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md). The canonical
contract statement is [development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## What is universal versus project-defined

The genuinely universal substrate is **not** the config record — it is the compositional lift and the test
engine:

| Universal (`hostbootstrap-core` owns) | Project-defined (the consumer owns) |
|---|---|
| `BinaryContext`, `ContextKind`, `ProviderKind`, `Capability` — the pure context shape | The scope-indexed config family `cfg` (its `<project>.dhall`) and test-config type `tcfg` |
| `childContext` / opaque `Step` and validated `StepPlan` — the lift algebra | The single restricted `psAssemble`, separate `psTestInit`, and project-owned typed role projections |
| `runMatrix` / the harness engine, generic `.test_data` helper, safety preconditions | The chain `cfg -> [Step]`, the providers, the resource/VM budget (if any) |
| Validated `CaseId`/`VariantId`, opaque `TestMatrix`, pure `VariantDraft`, and the harness engine | Executable case handlers, `TestCfg` matrix projection, and project-owned draft assembly |
| Scope-indexed `SecretRef`, Production/Harness wire vocabulary, root-local codec validation, common framework envelope, and opaque role requests (no resolution) | How secrets resolve (Vault, prompts, env), which declared assembly input supplies test fixtures, and each service's typed fields/handler |

The resource budget and VM cordon are a **provider** concern carried by a project's `cfg` — not a field
every consumer config must have. A secrets-strict, RKE2/EKS-sized consumer (`~/prodbox`) carries no VM
budget at all; the demo carries `Resources { cpu, memory, storage }`.

A field a project's workload reads and renders is likewise a field of **its own** `cfg`, never a core
slot. The demo's `cfg` carries a mandatory `message : Text` (its `psAssemble` default
`"Hello, world!"`). The target flow is:

```text
parent/locally admitted ValidatedConfig scope specDigest configId (cfg scope)
  → role-specific descriptive wire + stable digest/manifest
  → ConfigMap
  → matching RoleCodec validation
  → fresh local configId + spec/config/secret-bound ValidatedServiceRequest
  → RoleParams specDigest configId secretDigest fields Web
  → BudgetView.message
  → SPA #message
```

The current service process validates one canonical mounted snapshot and mints an opaque request before
running the closed typed action. Future cross-process child handoff still mints a fresh child identity;
the parent never transports an opaque request or reuses its `configId`. Core owns no
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
> **RIGHT (implemented field boundary; effect program remains Sprint 18.6)** — `message` is a typed
> mandatory project field whose consumer set includes the Web
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

## The extension contract: `ProjectSpec projectId cfg tcfg`

```haskell
projectSpec
  :: TestSuite
  -> IO ()
  -> [ConfigArtifact]
  -> CodecWitness tcfg
  -> (InitArgs -> tcfg)
  -> (forall scope.
        AssemblyRequest projectId tcfg (TestVariant tcfg) scope
        -> ConfigAssembly scope (cfg scope))
  -> ProjectSpecBuilder projectId cfg tcfg

addSteps       :: (forall rootScope rootId. CanonicalProjectRoot rootScope rootId -> cfg (Production projectId) -> [Step]) -> ProjectSpecBuilder projectId cfg tcfg -> ProjectSpecBuilder projectId cfg tcfg
addArtifacts   :: [ConfigArtifact] -> ProjectSpecBuilder projectId cfg tcfg -> ProjectSpecBuilder projectId cfg tcfg
addServices    :: ServiceRegistry (cfg (Production projectId)) -> ProjectSpecBuilder projectId cfg tcfg -> ProjectSpecBuilder projectId cfg tcfg

finalizeProjectSpec
  :: ProjectSpecBuilder projectId cfg tcfg
  -> Either ProjectSpecError (ProjectSpec projectId cfg tcfg)

class TestCfg tcfg where
  type TestVariant tcfg
  projectTestMatrix
    :: [CaseId]
    -> tcfg
    -> Either TestMatrixError (TestMatrix (TestVariant tcfg))
```

This is the **current** public construction surface. `ProjectSpec`, its builder representation, `Step`,
and `StepKind` constructors are hidden. Step/artifact/input/service contributions append in declaration
order; duplicate identities are structured errors. Frame-context and teardown projections are explicit
single-assignment slots: absence or a second assignment prevents finalization. Each decoded Production
config is projected to one opaque `StepPlan`; validation preserves exact declaration order or rejects the
plan before effects. The later lifecycle target replaces the remaining separately supplied
teardown callback with the receipt-aware
`ProjectPlan scope specDigest planId configId cfg` defined in
[composition methodology](composition_methodology.md#single-representation-the-chain-is-the-representation):
one non-empty validated step sequence, with topology derived from it and reverse work derived from the
ownership receipts acquired while interpreting it.

The project config is a family `cfg :: Type -> Type`. Production init/decode/dispatch uses only
`cfg (Production projectId)`; Harness projection requires opaque
`HarnessAuthority projectId runId` and returns only
`cfg (Harness projectId runId)`. The single default-bearing seam is `psAssemble`:
`ProductionAssembly`
and `HarnessAssembly authority draft` are disjoint constructors of that sole closed request; the opaque
validated draft already contains its stable identity and typed override payload,
so identity/variant/default inputs occur once and cannot disagree. Init and test projection share
defaults without ever converting an already constructed Production value. `ConfigAssembly` is a restricted read-only effect for declared
config/secret inputs; it exposes neither general `IO` nor lifecycle/backend mutation. For a fresh
harness run, `withAssembledHarnessConfig` consumes its `HarnessAuthority`, scope-correct
`ProjectCodec scope specDigest cfg`, and assembled value, then canonical-renders, hashes, and strictly
re-decodes it while jointly yielding the root-local verified wire identity and
`ValidatedConfig scope specDigest configId (cfg scope)`.
Later `ProjectPlan scope specDigest planId configId cfg` construction requires
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

Every field a project supplies is pure or project-owned. `ProjectCfg projectId cfg` requires only
`cfgContext :: cfg scope -> BinaryContext`; the raw context updater is gone. Scope-correct
`ProjectCodec scope specDigest cfg`, verified wire identity, and
`ValidatedConfig scope specDigest configId (cfg scope)` govern root-local admission. Later child
projection/promotion adds the handoff and child-plan authority described above. Current service
finalization jointly binds the full `ProjectCodec scope specDigest cfg`, closed typed registry, and
opaque role-wire `RoleCodec` values under one canonical `specDigest`. Each definition binds identity,
structural projection, reflected role-field codec, and handler; there is no independent selector. A
parent/local admission can project only
`RuntimeRoleWire fields service`; child-local verification of the mounted bytes then yields
`ValidatedServiceRequest specDigest configId secretDigest fields service` under a fresh local `configId`
and verified secret-bundle digest. That request inseparably contains
`RoleParams specDigest configId secretDigest fields service`. Current `service run` verifies one
canonical sibling snapshot and keeps the selected handler action closed over those role fields plus a
safe `LocalContextView`; the full config does not cross the handler boundary. Sprint 18.6 replaces that
remaining raw `IO` action with an exact one-use service command authority and matching closed
`ServiceProgram`, packaged internally as
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

## One assembler and the harness-generated config

Core stores one scope-polymorphic `psAssemble` for project config and one `psTestInit` for the distinct
test-config type. Production init and Harness variant generation therefore share one structural default
source without converting a Production value into Harness. Demo service projection is total from that
assembled value: Web and Accelerator parameters are mandatory sibling fields, child projection preserves
both, and validated leaf context selects the one admitted role. There is no optional service payload or
fallback literal.

The current flow is:

```text
project init  : InitArgs --psAssemble ProductionAssembly--> cfg Production ---write---> <project>.dhall
test init     : InitArgs --psTestInit (defaultTestConfig)--> tcfg --write--> <project>.test.dhall  (no pre-existing <project>.dhall needed)
test run      : executable [CaseId] + tcfg --projectTestMatrix--> opaque total TestMatrix
                  --typed selection--> [VariantDraft payload]
                  --fresh HarnessAuthority + psAssemble HarnessAssembly--> cfg Harness
                  --matching ProjectCodec canonical validation-->
                  --write--> <project>.dhall --project up--> assert --project destroy-->
                  compare-and-delete generated <project>.dhall   (keep <project>.test.dhall)
```

Core also has a self-created `.test_data` ownership helper, but the demo's live plan currently selects
Production/`.data`; the presence of that generic helper does not make the demo run isolated. See
[harness workflow](harness_workflow.md).

`ConfigAssembly` can read only declared inputs — for example a project-specific
`test-secrets.dhall` — and otherwise has no arbitrary `IO`, process, write, backend, or lifecycle escape.
Harness assembly receives one already-validated pure `VariantDraft` and returns one exact-run-scoped
`cfg`; it cannot create, omit, duplicate, or relabel variants. `TestCfg.projectTestMatrix` owns the pure typed projection,
and `mkTestMatrix` rejects empty registries/rows, duplicate IDs/rows/pairs, unknown references, and
orphan variants before mutation.
The demo currently declares two drafts with stable IDs `hello-world` and `hello-universe` (Sprint 20.3).
The expected served message is read from the generated config after bring-up, rather than conflating an
assertion value with the stable variant identity. A
secrets-strict consumer reads `test-secrets.dhall` through the declared-input capability and can
construct `TestPlaintext` only with the matching Harness config authority. See
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
> **CURRENT ASSEMBLY AND ROLE PROJECTION** — one project-owned assembler feeds init and Harness config;
> the finalized role projection consumes that same validated value without fallbacks:
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
