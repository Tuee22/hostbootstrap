# Secrets and the Test-Secrets Seam

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../architecture/generic_project_model.md](../architecture/generic_project_model.md), [schema.md](schema.md), [testing.md](testing.md), [Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)

> **Purpose**: Define the scope-indexed `SecretRef` vocabulary `hostbootstrap-core` offers so plaintext
> cannot inhabit a production config, and the declared `test-secrets` seam through which a project
> injects Harness-only fixtures without coupling core to any secret store.

## TL;DR

- A secrets-strict production `<project>.dhall` carries **secret pointers, never raw `Text`**.
  `SecretRef (Production projectId)` cannot contain `TestPlaintext`, and its reflected wire schema has
  no plaintext branch.
- Core **never resolves** a secret — it has no Vault, prompt, or KMS dependency. Resolution is the
  project's job, performed at use time, well after the config is decoded.
- For tests, a project may supply a **project-specific** `test-secrets.dhall` (cleartext fixtures,
  git-ignored), declare it in `psAssemblyInputs`, and read it through restricted `ConfigAssembly`.
  `TestPlaintext` construction requires the exact generative
  `HarnessConfigAuthority projectId runId`; the generic harness never resolves it.
- Root-local scope construction, mapped codec admission, and canonical config validation are
  implemented. Authenticated config refinement and exact `ChildPlanAuthority` are also implemented;
  authenticated root-scope admission, catalog-matched storeless execution, recursive process adoption, and
  runtime secret channels remain phase-owned work and must not be inferred from the root-local proof.

## Current Status

The scope-indexed `SecretRef` boundary is implemented in `hostbootstrap-core`.
`HostBootstrap.Config.Vocab` hides secret and authority constructors, exposes pointer smart
constructors at any scope, and admits plaintext only through matching Harness authority. `Core.dhall`
exports distinct `ProductionSecretRef` and `HarnessSecretRef` wire types; mapped `ProjectCodec`s convert
untrusted wire into the matching project-owned `cfg scope`. The demo does not need secrets, but the
generic project model
([generic_project_model.md](../architecture/generic_project_model.md)) can host a secrets-strict consumer
such as `~/prodbox`; resolving secrets remains that consumer's responsibility.

## The scope-indexed `SecretRef` vocabulary

```dhall
ProductionSecretRef =
  < Vault : { mount : Text, path : Text, field : Text }   -- a coordinate in a secret store
  | TransitKey : Text                                       -- a named transit/KMS key
  | Prompt : Text                                           -- resolved by interactive prompt
  >

HarnessSecretRef =
  < Vault : { mount : Text, path : Text, field : Text }
  | TransitKey : Text
  | Prompt : Text
  | TestPlaintext : Text
  >
```

A project embeds `SecretRef scope` in its `cfg scope`. A raw plaintext string does not type-check where a
secret reference is required. The Dhall values above are untrusted wire types, not Haskell construction
authority: the Production wire cannot express plaintext, and a Harness wire becomes scoped only when
the matching mapped codec closes over exact run authority.

## Implemented root-local scope boundary

The implemented construction and root-local validation boundary is:

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

data ProductionSecretRefWire
data HarnessSecretRefWire
data ProjectCodec scope specDigest cfg -- constructor hidden
data HarnessConfigAuthority projectId runId -- constructor hidden
data VerifiedConfigWire scope configDigest configId -- constructor hidden
data ValidatedConfig scope specDigest configId config -- constructor hidden

harnessConfigAuthority
  :: HarnessAuthority projectId runId
  -> HarnessConfigAuthority projectId runId

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
```

`ProjectCfg cfg` installs an identity-generative Production mapped codec and, only inside a continuation carrying
exact `HarnessConfigAuthority`, a Harness mapped codec. `withAssembledHarnessConfig` canonical-renders,
hashes, strictly re-decodes, and checks byte-stable re-rendering before minting fresh rank-2
`VerifiedConfigWire` and `ValidatedConfig` identities. There is no direct `FromDhall` instance for a
secrets-strict scoped config, no raw context updater, and no conversion from Harness to Production.
Pointer-only Harness configs remain Harness-indexed.

## Downstream child and runtime target

Root-local validation does not authorize a child process. The implemented handoff/refinement boundary and
the remaining runtime target use the following opaque relations; the phase plan remains the status authority
for each named API:

```haskell
data RuntimeRoleWireBytes
data RoleCodec scope specDigest fields -- constructor hidden
data FinalizedRuntimeSpec scope specDigest fields -- constructor hidden
data VerifiedSecretBundle
  scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
  fields service rolePlanDigest permittedEffects -- constructor hidden
data ValidatedServiceRequest specDigest configId secretDigest fields service -- constructor hidden
data VerifiedRuntimeRoleActivation
  scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
  service rolePlanDigest permittedEffects -- constructor hidden
data AuthenticatedRootScope scope -- constructor hidden scope-first admission proof
data VerifiedHandoff scope brokerGeneration -- constructor hidden transport proof
data VerifiedConfigHandoff
  scope planDigest brokerGeneration parentFrame childFrame configId verb phase
  -- constructor hidden config/plan-coordinate refinement

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

The downstream constructors are also intended to remain opaque. Generative authority must never be
serialized, and direct `FromDhall` must not construct `TestPlaintext` or a scoped Harness config. An
authenticated child verifies its granted bytes, mints a fresh child `configId`, and obtains fresh local Harness
config authority and `ValidatedConfig` together; it does not receive or reconstruct the root's
`HarnessAuthority`. The narrowed child's identity is distinct from the parent's exact-byte identity.

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

In the downstream target, image-build config is not a third secret scope. The build-session verifier decodes a
`ProductionConfigWire` as `ProjectConfig (Production projectId)` and binds the installed project,
config digest, exact `buildId`, and measured source/context digest before yielding build-only
authority. It has no `TestPlaintext` constructor.

Production commands currently require `cfg (Production projectId)`, while `test run` can mint only the
matching `cfg (Harness projectId runId)`. There is no unscoped union, direct Harness
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

A project declares this path in `psAssemblyInputs`. Its typed restricted `psAssemble` (see
[generic_project_model.md](../architecture/generic_project_model.md)) may read it only during
`HarnessAssembly`, then use the request's matching authority to substitute `TestPlaintext` for selected
production pointers:

```text
implemented root flow:
test run : <project>.test.dhall --pure matrix validation--> NonEmpty VariantDraft
             --open one fresh run for this distinct variant-->
             HarnessAuthority projectId runId
             + declared test-secrets.dhall --restricted psAssemble HarnessAssembly-->
             cfg (Harness projectId runId)
             --matching mapped ProjectCodec + withAssembledHarnessConfig-->
             VerifiedConfigWire + ValidatedConfig
             --write--> <project>.dhall --hidden root-Up LifecycleEntry--> assert
             --exact current-frame reverse-->
             --cleanup--> delete only if the owned bytes still match; otherwise retain and report

downstream target:
root ValidatedConfig --build/bind root plan-->
             HarnessAuthority + exact live run evidence
             --signed root-scope capsule--> AuthenticatedRootScope
             --one-time handoff grant--> VerifiedHandoff
             --exact-byte verification--> VerifiedConfigWire + child HarnessConfigAuthority
             + ValidatedConfig --withVerifiedConfigHandoff--> VerifiedConfigHandoff
             --withChildProjectPlan-->
             ChildPlanAuthority + child ProjectPlan + PlanDigestBinding
             --exact-match root catalog frame--> storeless FrameExecutor
             --root-signed prepared grants / bounded observations-->
             --FrameComplete / ReceiptConfirm / ReceiptRecorded--> completion identity
```

The signed `AuthenticatedRootScope` capsule binds installed project and exact Production or Harness run
evidence before received config bytes introduce a phantom. Later root-signed rooted responses bind the exact
catalog/session/frame/node coordinates, but a child receives no `ProtectedStore`, cursor, or durable mutation
capability. `HostBootstrap.Handoff` owns only the scope, transport, recovery-package, and rooted-wire proofs;
`HostBootstrap.Config.Schema` owns
`VerifiedConfigHandoff`, and
`HostBootstrap.ProjectPlan.Construct` owns the opaque fully indexed `ChildPlanAuthority`. The Cabal-private
child boundary exact-matches that independently rebuilt plan/config/frame against the root catalog and admits
only a storeless `FrameExecutor`. The root prepares and settles every durable operation and receipt; the
executor runs only the exact local work named by a signed prepared response. The
[test-harness-and-run-ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)
supplies the generative Harness run evidence to the generic authenticated-scope producer. The
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) owns the
catalog, coordinator, executor, and recursive process adoption; current Harness uses the hidden root-Up entry
and exact reverse path shown above.

Core stays secret-agnostic: it offers the scope-indexed `SecretRef` shape, mapped-codec boundary, and
restricted assembler;
everything about
where secrets live, how they unseal, and which fixtures stand in for them is the project's concern. This is
why the generic `ProjectSpec cfg tcfg` (rather than a fixed `ProjectConfig`) is required — a
secrets-strict consumer's `cfg scope` is a different shape. `psTestMatrix` validates a pure
matrix of stable variant drafts, while restricted `psAssemble` injects each variant's test secrets only
after the harness has opened that variant's fresh project/run-scoped authority. Its
`ConfigAssembly` effect can perform only declared config/secret reads and has no general `IO` or
lifecycle/backend mutation capability.

## Cross-references

- [../architecture/generic_project_model.md](../architecture/generic_project_model.md) —
  `ProjectSpec cfg tcfg` and the identity-polymorphic `psAssemble`, the seam this doc plugs into.
- [testing.md](testing.md) — the standardized harness that drives the generated config.
- [schema.md](schema.md) — the project-defined, explicit config schema `SecretRef` fields live in.
