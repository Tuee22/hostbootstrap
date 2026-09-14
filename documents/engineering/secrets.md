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
  authenticated root-scope admission and catalog-matched storeless execution verify the complete child package.
  Service activation independently verifies its installed narrowed wire and private bundle; a root-local
  config proof alone does not establish that runtime channel.

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

## Authenticated Child and Runtime Boundaries

Root-local config validation does not authorize a child. The receiver first verifies the root-signed
`AuthenticatedRootScope` against the independently installed identity and key. It then verifies the exact
ordinary payload binding or complete recovery package. `withChildProjectPlan` proves correspondence to the
canonical plan; the root catalog grants only storeless local execution. No child receives root signing or
protected-store authority.

Service deployment projects only the selected role fields and installs an immutable signed activation
revision. `withInstalledServiceActivation` recomputes the revision identity and role/private-bundle digests
before yielding installed bytes inside the verified activation continuation. `withDecodedServiceProgram`
selects the signed service's exact finalized codec, decodes that narrowed wire, and retains the request,
declared effect row, resource backend, and program together. `service run` never loads the sibling full config.

The private bundle is measured independently of the public role wire. Core verifies its binding but does not
resolve project secret references. Runtime mismatch diagnostics name the failing evidence and do not print
secret contents. A role handler receives opaque `RoleParams` and returns an effect-indexed `ServiceProgram`;
it has no generic IO escape to reopen another role's config or private channel.

The [authenticated handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
owns wire authentication, the [recursive lifecycle phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
owns its process consumer, and the [service runtime phase](../../DEVELOPMENT_PLAN/phase-22-service-runtime.md)
owns immutable installation and signed leaf execution. Exact signatures live in `Handoff`, `Activation`,
`Service`, and `RoleLifecycle`, rather than in a second illustrative API sketch.

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
secrets-strict consumer's `cfg scope` is a different shape. `psTestSuite` carries the matrix `mkTestMatrix` validates out of stable
variant drafts, while restricted `psAssemble` injects each variant's test secrets only
after the harness has opened that variant's fresh project/run-scoped authority. Its
`ConfigAssembly` effect can perform only declared config/secret reads and has no general `IO` or
lifecycle/backend mutation capability.

## Cross-references

- [../architecture/generic_project_model.md](../architecture/generic_project_model.md) —
  `ProjectSpec cfg tcfg` and the identity-polymorphic `psAssemble`, the seam this doc plugs into.
- [testing.md](testing.md) — the standardized harness that drives the generated config.
- [schema.md](schema.md) — the project-defined, explicit config schema `SecretRef` fields live in.
