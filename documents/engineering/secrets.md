# Secrets and the Test-Secrets Seam

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../architecture/generic_project_model.md](../architecture/generic_project_model.md), [schema.md](schema.md), [testing.md](testing.md), [../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md)

> **Purpose**: Define the pure `SecretRef` vocabulary `hostbootstrap-core` offers so a project keeps
> secrets out of its production `<project>.dhall`, and the `test-secrets` seam through which a project
> injects test secrets without coupling core to any secret store.

## TL;DR

- A production `<project>.dhall` carries **secret pointers, never plaintext**. Core offers a pure
  `SecretRef` union for that; the rule is **type-level** (secret fields are `SecretRef`, not `Text`).
- Core **never resolves** a secret — it has no Vault, prompt, or KMS dependency. Resolution is the
  project's job, performed at use time, well after the config is decoded.
- For tests, a project supplies a **project-specific** `test-secrets.dhall` (cleartext fixtures, git-ignored)
  and weaves it into the test-time config inside `psTestConfig`, substituting `TestPlaintext` for its
  production `Vault` pointers. The harness knows nothing about secrets.

## Current Status

The pure `SecretRef` vocabulary is implemented in `hostbootstrap-core` and phase 19 is `Done`. It is
mirrored in `Core.dhall` and `HostBootstrap.Config.Vocab`, with anti-drift and round-trip tests. The demo
does not need secrets, but the generic project model
([generic_project_model.md](../architecture/generic_project_model.md)) can host a secrets-strict consumer
such as `~/prodbox`; resolving secrets remains that consumer's responsibility.

## The `SecretRef` vocabulary

```dhall
SecretRef =
  < Vault : { mount : Text, path : Text, field : Text }   -- a coordinate in a secret store
  | TransitKey : Text                                       -- a named transit/KMS key
  | Prompt : Text                                           -- resolved by interactive prompt
  | TestPlaintext : Text                                    -- test-only inline value; never in production
  >
```

A project embeds `SecretRef` in its `cfg`. Because a production secret field has type `SecretRef`, a
plaintext string does not type-check there — "no secrets in a production `<project>.dhall`" is enforced by
the schema, not by a linter. `TestPlaintext` is the **only** inline-value variant, reserved for the
test-secrets seam below; a production config that uses it is a project-level code-check failure, not a core
concern.

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
`TestPlaintext` for the `Vault` pointers when building the test-time `<project>.dhall`:

```text
test run : test.dhall + test-secrets.dhall --psTestConfig--> cfg (Vault pointers -> TestPlaintext)
             --write--> <project>.dhall --project up--> assert --project destroy--> delete generated cfg
```

Core stays secret-agnostic: it offers the `SecretRef` shape and calls `psTestConfig`; everything about
where secrets live, how they unseal, and which fixtures stand in for them is the project's concern. This is
why the generic `ProjectSpec cfg tcfg` (rather than a fixed `ProjectConfig`) is required — a secrets-strict
consumer's `cfg` is a different shape, and `psTestConfig` is the seam that injects its test secrets.

## Cross-references

- [../architecture/generic_project_model.md](../architecture/generic_project_model.md) — `ProjectSpec cfg
  tcfg` and `psTestConfig`, the seam this doc plugs into.
- [testing.md](testing.md) — the standardized harness that drives the generated config.
- [schema.md](schema.md) — the project-defined, explicit config schema `SecretRef` fields live in.
