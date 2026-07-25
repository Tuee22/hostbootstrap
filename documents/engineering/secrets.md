# Secrets and the Test-Secrets Seam

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../architecture/generic_project_model.md](../architecture/generic_project_model.md), [schema.md](schema.md), [testing.md](testing.md), [../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md)

> **Purpose**: Define the pure `SecretRef` vocabulary `hostbootstrap-core` offers so a project keeps
> secrets out of its production `<project>.dhall`, and the `test-secrets` seam through which a project
> injects test secrets without coupling core to any secret store.

## TL;DR

- A secrets-strict production `<project>.dhall` carries **secret pointers, never raw `Text`**. Core
  offers a pure `SecretRef` union, but its `TestPlaintext` constructor is still representable in a
  production-shaped value; excluding that constructor is currently a project code-check policy.
- Core **never resolves** a secret — it has no Vault, prompt, or KMS dependency. Resolution is the
  project's job, performed at use time, well after the config is decoded.
- For tests, a project supplies a **project-specific** `test-secrets.dhall` (cleartext fixtures, git-ignored)
  and weaves it into the test-time config inside `psTestConfig`, substituting `TestPlaintext` for its
  production `Vault` pointers. The harness knows nothing about secrets.
- The target separates production and harness secret types so `TestPlaintext` cannot decode into or
  inhabit a production-scoped config. Phase 19 owns that migration.

## Current Status

The pure, unscoped `SecretRef` vocabulary is implemented in `hostbootstrap-core`. The development plan
owns typed test identity and replacement with the scoped boundary below. It is mirrored in `Core.dhall`
and `HostBootstrap.Config.Vocab`, with round-trip and explicit type-equality coverage. The demo
does not need secrets, but the generic project model
([generic_project_model.md](../architecture/generic_project_model.md)) can host a secrets-strict consumer
such as `~/prodbox`; resolving secrets remains that consumer's responsibility.

## The `SecretRef` vocabulary

```dhall
SecretRef =
  < Vault : { mount : Text, path : Text, field : Text }   -- a coordinate in a secret store
  | TransitKey : Text                                       -- a named transit/KMS key
  | Prompt : Text                                           -- resolved by interactive prompt
  | TestPlaintext : Text                                    -- intended test-only; policy-enforced today
  >
```

A project embeds `SecretRef` in its `cfg`. A raw plaintext string does not type-check where a
`SecretRef` is required. `TestPlaintext` is nevertheless an inline-value constructor of that same union,
reserved for the test-secrets seam below; a production config that uses it is currently a project-level
code-check failure, not a state the core type excludes.

## Scoped target

The target removes `TestPlaintext` from the production vocabulary and indexes project config by lifecycle
scope:

```haskell
data Production projectId
data Harness projectId runId

data SecretRef scope where
  Vault      :: VaultCoordinate -> SecretRef scope
  TransitKey :: TransitCoordinate -> SecretRef scope
  Prompt     :: PromptLabel -> SecretRef scope
  TestPlaintext
    :: HarnessConfigAuthority projectId runId
    -> TestSecret
    -> SecretRef (Harness projectId runId)

data ProjectConfig scope

data ProductionConfigWire
data HarnessConfigWire
data RuntimeRoleWireBytes
data ProjectCodec scope specDigest cfg -- constructor hidden
data RoleCodec scope specDigest fields -- constructor hidden
data FinalizedRuntimeSpec scope specDigest fields -- constructor hidden
data VerifiedSecretBundle
  scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
  fields service rolePlanDigest permittedEffects -- constructor hidden
data ValidatedServiceRequest specDigest configId secretDigest fields service -- constructor hidden
data VerifiedRuntimeRoleActivation
  scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
  service rolePlanDigest permittedEffects
  -- hidden; activation, projection, and protected secret-channel locator are inseparable
data HarnessConfigAuthority projectId runId -- constructor hidden
data VerifiedConfigWire scope configDigest configId -- constructor hidden
data ConfigHandoff
data VerifiedHandoff
  scope planDigest brokerGeneration parentFrame childFrame
  payloadKind payloadId verb phase -- constructor hidden
data ValidatedConfig scope specDigest configId config -- constructor hidden

rootHarnessConfigAuthority
  :: HarnessAuthority projectId runId
  -> HarnessConfigAuthority projectId runId

handoffHarnessConfigAuthority
  :: VerifiedHandoff
       (Harness projectId runId) planDigest brokerGeneration parentFrame childFrame
       ConfigHandoff configId verb phase
  -> HarnessConfigAuthority projectId runId

withProductionConfig
  :: InstalledProjectIdentity projectId
  -> ProjectCodec (Production projectId) specDigest ProjectConfig
  -> ProductionConfigWire
  -> (forall configId.
        ValidatedConfig
          (Production projectId) specDigest configId (ProjectConfig (Production projectId))
        -> a)
  -> Either ConfigError a

withVerifiedProductionWire
  :: HandoffGrant
       (Production projectId) planDigest brokerGeneration parentFrame childFrame
       ConfigHandoff configDigest verb phase
  -> ProjectCodec (Production projectId) specDigest ProjectConfig
  -> ProductionConfigWire
  -> (forall configId.
        VerifiedConfigWire (Production projectId) configDigest configId
        -> VerifiedHandoff
             (Production projectId) planDigest brokerGeneration parentFrame childFrame
             ConfigHandoff configId verb phase
        -> ValidatedConfig
             (Production projectId) specDigest configId (ProjectConfig (Production projectId))
        -> a)
  -> Either ConfigError a

withVerifiedHarnessWire
  :: HandoffGrant
       (Harness projectId runId) planDigest brokerGeneration parentFrame childFrame
       ConfigHandoff configDigest verb phase
  -> ProjectCodec (Harness projectId runId) specDigest ProjectConfig
  -> HarnessConfigWire
  -> (forall configId.
        VerifiedConfigWire (Harness projectId runId) configDigest configId
        -> VerifiedHandoff
             (Harness projectId runId) planDigest brokerGeneration parentFrame childFrame
             ConfigHandoff configId verb phase
        -> HarnessConfigAuthority projectId runId
        -> ValidatedConfig
             (Harness projectId runId)
             specDigest
             configId
             (ProjectConfig (Harness projectId runId))
        -> a)
  -> Either ConfigError a

withAssembledHarnessConfig
  :: HarnessAuthority projectId runId
  -> ProjectCodec (Harness projectId runId) specDigest cfg
  -> cfg (Harness projectId runId)
  -> (forall configDigest configId.
        VerifiedConfigWire
          (Harness projectId runId) configDigest configId
        -> ValidatedConfig
             (Harness projectId runId)
             specDigest
             configId
             (cfg (Harness projectId runId))
        -> a)
  -> Either ConfigError a

withVerifiedRuntimeSecretBundle
  :: VerifiedRuntimeRoleActivation
       scope planDigest specDigest binaryDigest frame revision instanceId
       configDigest secretDigest service rolePlanDigest permittedEffects
  -> FinalizedRuntimeSpec scope specDigest fields
  -> (VerifiedSecretBundle
        scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
        fields service rolePlanDigest permittedEffects
        -> IO a)
  -> IO (Either SecretBundleError a)

withVerifiedProductionRuntimeRoleWire
  :: VerifiedRuntimeRoleActivation
       (Production projectId) planDigest specDigest binaryDigest frame revision instanceId
       configDigest secretDigest service rolePlanDigest permittedEffects
  -> FinalizedRuntimeSpec (Production projectId) specDigest fields
  -> VerifiedSecretBundle
       (Production projectId) planDigest specDigest binaryDigest frame revision instanceId
       configDigest secretDigest fields service rolePlanDigest permittedEffects
  -> RuntimeRoleWireBytes
  -> (forall configId.
        VerifiedConfigWire (Production projectId) configDigest configId
        -> ValidatedServiceRequest specDigest configId secretDigest fields service
        -> a)
  -> Either ConfigError a

withVerifiedHarnessRuntimeRoleWire
  :: VerifiedRuntimeRoleActivation
       (Harness projectId runId) planDigest specDigest binaryDigest frame revision instanceId
       configDigest secretDigest service rolePlanDigest permittedEffects
  -> FinalizedRuntimeSpec (Harness projectId runId) specDigest fields
  -> VerifiedSecretBundle
       (Harness projectId runId) planDigest specDigest binaryDigest frame revision instanceId
       configDigest secretDigest fields service rolePlanDigest permittedEffects
  -> RuntimeRoleWireBytes
  -> (forall configId.
        VerifiedConfigWire (Harness projectId runId) configDigest configId
        -> ValidatedServiceRequest specDigest configId secretDigest fields service
        -> a)
  -> Either ConfigError a
```

Constructors and `HarnessAuthority` are opaque. Generative authority is never serialized, so
`FromDhall` does **not** construct `TestPlaintext` or a scoped harness config directly. The reflected
production wire schema contains only `Vault | TransitKey | Prompt`; `withProductionConfig` supplies only
`ProjectConfig (Production projectId)` inside a fresh
`ValidatedConfig (Production projectId) specDigest configId
(ProjectConfig (Production projectId))` continuation. That
rank-2 decoder is for an independently authorized root-local config; it does not invent a matching
identity for a child handoff. `withVerifiedProductionWire` instead verifies the child bytes against the
grant's exact `configDigest`, creates the fresh child `configId` inside its continuation, and returns both
the opaque verified wire and same-`specDigest` `ValidatedConfig` under that identity.

A separate untrusted `HarnessConfigWire` may contain inline fixture payloads.
Only `withVerifiedHarnessWire` verifies the grant, run scope, and actual bytes; it mints the same generic
`VerifiedConfigWire (Harness projectId runId) configDigest configId` used by every scope, the exact
`VerifiedHandoff`, a child-local
`HarnessConfigAuthority projectId runId`, and the corresponding
`ValidatedConfig (Harness projectId runId) specDigest configId
(ProjectConfig (Harness projectId runId))` together inside one rank-2
continuation. The child does not need the root's non-serializable `HarnessAuthority` before it can verify
the handoff. Root-side pure `psTestMatrix` never receives authority or secrets. After a fresh run opens,
the restricted `psAssemble (HarnessAssembly authority draft)` constructs only that run's scoped value;
`withAssembledHarnessConfig` then uses the same validated project codec to canonical-render, hash, and
strictly re-decode it. The gate jointly yields the root-local verified wire identity and
`ValidatedConfig` required by `withProjectPlan`, without requiring a child handoff and without
authorizing an external effect. Neither authority form can mint Production. Raw wire cannot be promoted, the
narrowed child's `configId` is not the parent's identity, and a pointer-only harness config remains
Harness-indexed.

A controller restart does not replay `ConfigHandoff`. Its independently installed, signed deployment
manifest binds project/run scope, parent-plan digest, frame, immutable rollout revision, exact
role-wire/config digest, finalized-spec and expected binary/image digests, separate secret-bundle digest,
selected service, narrowed role-plan digest, permitted effects, and the controller/template identity
allowed to instantiate it. The concrete process does not exist when that manifest is signed. Platform
verification therefore pairs the signed revision with a measured `instanceId`—pod UID plus container
restart count, or a protected OS-service invocation nonce—and yields one opaque
`VerifiedRuntimeRoleActivation`; callers cannot separate or cross-pair its activation, role-plan
projection, and protected secret-channel locator.

Runtime role ConfigMaps are always non-secret. Production carries only pointer coordinates and accepts
the canonical empty bundle; Harness carries typed secret handles and supplies fixture bytes only through
a run-scoped Kubernetes Secret/private OS channel. The bundle verifier accepts no caller-constructed
Harness input and needs no `HarnessConfigAuthority`: it internally reads the activation-bound channel,
hashes the actual bytes, matches handles one-for-one, and rejects missing/extra/duplicate entries or a
wrong run/revision/instance before yielding `VerifiedSecretBundle`. That proof carries the full
scope/plan/spec/binary/frame/revision/instance/config/secret/role-plan/effect-ceiling lineage.
`withVerifiedProductionRuntimeRoleWire` or
`withVerifiedHarnessRuntimeRoleWire` then consumes that proof plus the matching finalized runtime spec,
hashes the actual narrowed wire, and mints a fresh local verified request—not a full
`ValidatedConfig`. A changed ConfigMap/Secret, mismatched spec/binary/projection, or another project/run
cannot promote; even an identical secret digest from another activation cannot cross-pair. The
Kubernetes Secret object or private OS channel is the sole secret-bearing runtime
payload. No cleartext fixture appears in the non-secret ConfigMap, pod template, signed activation
manifest, `LocalContextView`, logs, or diagnostic output.

Image-build config is not a third secret scope. The build-session verifier decodes a
`ProductionConfigWire` as `ProjectConfig (Production projectId)` and binds the installed project,
config digest, exact `buildId`, and measured source/context digest before yielding build-only
authority. It has no `TestPlaintext` constructor.

Production commands require `ProjectConfig (Production projectId)`, while `test run` can mint only the
matching `ProjectConfig (Harness projectId runId)`. There is no unscoped union, direct harness
`FromDhall` instance, raw-wire promotion, or
record update that can move `TestPlaintext` into production, promote a different payload with a valid
run authority, or move one harness run into another.

This type boundary prevents scope confusion; it does not itself prevent a project resolver from logging
resolved bytes. Resolver redaction and effect handling remain project responsibilities.

> **WRONG** — a plaintext secret field:
>
> ```dhall
> { aws = { secret_access_key = "AKIA…/plaintext" } }   -- a Text secret leaks into the config
> ```
>
> A committed or mounted production config now carries a live credential.
>
> **RIGHT** — a pointer resolved at use time:
>
> ```dhall
> { aws = { secret_access_key = SecretRef.Vault { mount = "secret", path = "gateway/aws", field = "secret_access_key" } } }
> ```

## The test-secrets seam

A project's production config has no usable secrets, so its test suite needs a way to supply them without
standing up the real secret store. That is a **project-specific** file — for example `test-secrets.dhall`:

```dhall
-- test-secrets.dhall (git-ignored, test-only cleartext fixtures)
{ vault_operator_password = "test-unlock-password"
, aws_admin_for_test = { access_key_id = "TESTKEY", secret_access_key = "test-secret", region = "us-west-2" }
}
```

The project's `psTestConfig :: tcfg -> IO [(Text, cfg)]` (see
[generic_project_model.md](../architecture/generic_project_model.md)) reads it and substitutes
`TestPlaintext` for the `Vault` pointers when building the current unscoped test-time
`<project>.dhall`:

```text
current:
test run : <project>.test.dhall + test-secrets.dhall --psTestConfig--> cfg (Vault pointers -> TestPlaintext)
             --write--> <project>.dhall --project up--> assert --project destroy
             --cleanup--> delete only if the owned bytes still match; otherwise retain and report

target:
test inputs --pure matrix validation--> NonEmpty VariantDraft
             --open one fresh run/lease for this distinct variant-->
             HarnessAuthority projectId runId
             --restricted psAssemble (HarnessAssembly authority draft)-->
             ProjectConfig (Harness projectId runId)
             --withAssembledHarnessConfig / ProjectCodec-->
             VerifiedConfigWire + ValidatedConfig --build/bind root plan-->
             HarnessConfigWire
             --one-time ConfigHandoff grant + exact-byte verification-->
             VerifiedConfigWire + VerifiedHandoff + child HarnessConfigAuthority
             + ValidatedConfig --withChildProjectPlan-->
             ChildPlanAuthority + child ProjectPlan + PlanDigestBinding
             --authorizeChildProject--> child
```

Core stays secret-agnostic: it offers the `SecretRef` shape and, currently, calls `psTestConfig`;
everything about
where secrets live, how they unseal, and which fixtures stand in for them is the project's concern. This is
why the generic `ProjectSpec cfg tcfg` (rather than a fixed `ProjectConfig`) is required — a
secrets-strict consumer's `cfg` is a different shape. In the target, `psTestMatrix` validates a pure
matrix of stable variant drafts, while restricted `psAssemble` injects each variant's test secrets only
after the harness has opened that variant's fresh project/run-scoped authority. Its
`ConfigAssembly` effect can perform only declared config/secret reads and has no general `IO` or
lifecycle/backend mutation capability.

## Cross-references

- [../architecture/generic_project_model.md](../architecture/generic_project_model.md) — `ProjectSpec cfg
  tcfg` and `psTestConfig`, the seam this doc plugs into.
- [testing.md](testing.md) — the standardized harness that drives the generated config.
- [schema.md](schema.md) — the project-defined, explicit config schema `SecretRef` fields live in.
