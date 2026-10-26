# Secrets and the Test-Secrets Seam

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../architecture/generic_project_model.md](../architecture/generic_project_model.md), [schema.md](schema.md), [testing.md](testing.md), [Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)

> **Purpose**: Define the scope-indexed `SecretRef` vocabulary `hostbootstrap-core` offers so a production
> `SecretRef` has no plaintext alternative, and the declared `test-secrets` seam through which a project
> injects Harness-only fixtures without coupling core to any secret store.

## TL;DR

- In a secrets-strict production `<project>.dhall`, every `SecretRef` field is a **secret pointer**:
  `SecretRef (Production projectId)` has no plaintext alternative, and its reflected wire schema has no
  plaintext branch. The pointer labels themselves (Vault mount/path/field, transit-key name, prompt label)
  and every project field outside `SecretRef` are free `Text`; keeping secret values out of them is project
  discipline, not a type guarantee.
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

The guarantee is narrower than "no secret bytes in production config". Each pointer payload is `Text`
(`VaultRef`'s `mount`, `path`, and `field`; the transit-key name; the prompt label), and project fields
outside `SecretRef` are whatever the project declares, so nothing in core stops a secret value being placed
in one of them. `SecretRef`'s `Show` is not redacted: it shows through `SecretRefView`, so showing a Harness
reference that holds `TestPlaintext` prints the fixture value.

## Implemented root-local scope boundary

[`HostBootstrap.Config.Vocab`](../../core/hostbootstrap-core/src/HostBootstrap/Config/Vocab.hs) owns the
re-export of the scope indices `Production` and `Harness` (defined in `HostBootstrap.ProjectScope`), the
constructor-hidden `SecretRef scope`, and its smart constructors and wire conversions:

| Function | Scope it yields | Authority it needs |
|---|---|---|
| `vaultSecret` (from a `VaultRef`) | any scope | none |
| `transitKeySecret` (from a key name) | any scope | none |
| `promptSecret` (from a prompt label) | any scope | none |
| `testPlaintextSecret` (from a `TestSecret`) | `Harness projectId runId` only | the matching `HarnessConfigAuthority projectId runId` |
| `productionSecretRef` (from a `ProductionSecretRefWire`) | `Production projectId` | none; the wire has no plaintext alternative |
| `harnessSecretRef` (from a `HarnessSecretRefWire`) | `Harness projectId runId` | the matching `HarnessConfigAuthority`, used for its plaintext alternative |

`harnessConfigAuthority` derives `HarnessConfigAuthority` from the generative `HarnessAuthority` the harness
opens for one run; neither authority has an exported constructor. `ProjectCodec`, `VerifiedConfigWire`, and
`ValidatedConfig` are constructor-hidden in `HostBootstrap.Config.Class` and `HostBootstrap.Config.Schema`.
Core ships no fixed project config type: each project supplies its own `cfg scope`.

[`HostBootstrap.Config.Schema`](../../core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs) owns
`withAssembledHarnessConfig`, whose exact signature lives there. It takes the declared `[ConfigInput]`
allowlist, the run's `HarnessAuthority`, the matching Harness `ProjectCodec`, a `ConfigAssembly` program
producing the Harness-scoped config, and a rank-2 continuation over the minted `VerifiedConfigWire` and
`ValidatedConfig`; it runs the assembly against the allowlist and returns `IO (Either String result)`.

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
[generic_project_model.md](../architecture/generic_project_model.md)) reads it during `HarnessAssembly`,
then uses the request's matching authority to substitute `TestPlaintext` for selected production pointers.

Core enforces two things here and no more. `psAssemblyInputs` is one allowlist shared by both request kinds,
so `ProductionAssembly` (run by `project init`) can read the declared test-secrets file too; and only
`TestPlaintext` construction is Harness-only, because `testPlaintextSecret` needs `HarnessConfigAuthority`.
Reading the fixture file only during `HarnessAssembly`, and never copying its cleartext into a pointer label
or another `Text` field of a production config, is project discipline that core does not check.

The root flow is:

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

implemented child flow:
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

### Where Harness plaintext lives

Fixture cleartext lives in two places. The first is the project's own test-secrets file. The second is the
rendered Harness config: `harnessSecretRefWire` renders each `TestPlaintext` back to its plaintext wire
alternative, so the `<project>.dhall` the harness writes beside the host binary (`./.build/<project>.dhall`,
see [schema.md](schema.md)) holds the fixture values for the run. Cleanup deletes that file only when its
bytes still match what the run wrote; otherwise the file, fixtures included, is retained and reported.

Core writes no ignore rule. The project git-ignores its test-secrets file and the `./.build/` directory that
holds the rendered config; this repository's `.gitignore` covers `.build/` (see
[gitignore_guardrails.md](gitignore_guardrails.md)).

### Core stays secret-agnostic

Core offers the scope-indexed `SecretRef` shape, the mapped-codec boundary, and the restricted assembler.
Where secrets live, how they unseal, and which fixtures stand in for them are the project's concern. This is
why core takes the generic `ProjectSpec cfg tcfg` rather than a fixed project config type: a secrets-strict
consumer's `cfg scope` is a different shape.

`ConfigAssembly` can perform only declared config and secret reads; it has no general `IO` and no lifecycle or
backend mutation capability.

`psTestSuite` carries the matrix `mkTestMatrix` validates out of stable variant drafts, while restricted
`psAssemble` injects each variant's test secrets only after the harness has opened that variant's fresh
project/run-scoped authority.

## Validation

- `DhallGenSpec`: Production and Harness wire alternatives round-trip separately; the production schema
  omits and rejects `TestPlaintext`; scoped plaintext requires the matching rank-2 Harness authority; the
  production wire decodes against the production type in `Core.dhall`; wire conversion preserves scope and
  pointer values; and the inventory cases require every type `Core.dhall` exports to have one exhaustive
  codec entry that is judgmentally equal to its `Core.dhall` type.
- `SchemaSpec`: the secrets-strict production codec omits and rejects `TestPlaintext`; matching Harness
  authority admits plaintext and mints a verified scoped config; `ConfigAssembly` reads only declared inputs;
  and the daemon snapshot log carries config metadata without secret content.
- `CompileFailSpec` fixtures `ProductionPlaintext`, `CrossRunPlaintext`, `HarnessConfigAsProduction`, and
  `ForgeHarnessAuthority` prove that plaintext cannot be built at Production scope or for another run, that
  a Harness config cannot stand in for a Production one, and that Harness authority cannot be forged.

## Cross-references

- [../architecture/generic_project_model.md](../architecture/generic_project_model.md) —
  `ProjectSpec cfg tcfg` and the identity-polymorphic `psAssemble`, the seam this doc plugs into.
- [testing.md](testing.md) — the standardized harness that drives the generated config.
- [schema.md](schema.md) — the project-defined, explicit config schema `SecretRef` fields live in.
