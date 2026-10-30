# Registry Credential Forwarding

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/composition_methodology.md](../architecture/composition_methodology.md), [../architecture/binary_context_config.md](../architecture/binary_context_config.md), [../operations/demo_runbook.md](../operations/demo_runbook.md)

> **Purpose**: Define how the host's Docker Hub credentials are forwarded down the self-reference lift,
> state the exact limits of the current risk-reducing transport, and define the capability-bound target.

## TL;DR

- Pulling images from Docker Hub inside a nested context (a VM `docker build`, a container's
  `kind`/`docker run`) hits Docker Hub's **unauthenticated** rate limit. The fix is to forward the host's
  existing Docker Hub login down the [self-reference lift](../architecture/composition_methodology.md) so
  the nested pull authenticates.
- The credential is intended as an **effect-only capability** modelled by `HostBootstrap.Registry`.
  `RegistryAuth` is opaque (its constructor is not exported), its `Show` is redacted, and it has **no
  `FromDhall`/`ToDhall` instance**. This reduces accidental config/`Show` leakage, but
  `registryConfigPayload :: RegistryAuth -> Text` is public, so arbitrary caller code can still log,
  serialize, or persist the bytes.
- Discovery is currently called on the outer host. Projection uses a **substring** key test
  (`"docker.io" isInfixOf key`), not a canonical Docker Hub registry parser, so the implementation does
  not prove that every forwarded entry is Docker Hub-only.
- Current forwarding avoids putting the value directly in the constructed command `argv`, but it does
  use process memory, pipes, a container environment variable, shell environment, and a temporary
  `DOCKER_CONFIG` file. A value forwarded through a container environment variable is stored in Docker's
  container configuration (readable through `docker inspect` until the container is removed) and stays in
  the container process's initial environment block for its lifetime. Ordinary trap/bracket cleanup is not
  guaranteed after `SIGKILL`, host crash, or abrupt VM termination.
- In the demo only the VM-frame `stdin` path carries a value. The container frame's pulls run
  anonymously; see [Current Status](#current-status).
- When the host is not logged in, discovery yields `Nothing` and every pull runs anonymously — a
  pristine host needs no Docker Hub login.

## Current Status

`HostBootstrap.Registry` implements discovery, the `stdin` wrapper, the environment consumer, and the
registry-aware lift described in [the model](#the-model-hostbootstrapregistry). The demo forwards a
credential over one path only: the metal host discovers it and pipes it on `stdin` to the in-VM build #3 and
to the in-VM published-base `docker pull`.

The container-frame path delivers no value. Core's admitted lifecycle container route
(`HostBootstrap.Handoff.Process.Route`) passes `-e HOSTBOOTSTRAP_REGISTRY_AUTH` with the name only, and
Docker forwards a name-only `-e` only when the launching Docker client's own environment already holds the
variable. No production frame sets it: the only code that exports a value is `liftSubcommandWithAuth`, and
only `RegistrySpec` calls it. The in-container `deploy-kind` node-image pull and the in-container
`docker run` probes therefore pull anonymously. The
[composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
owns the credential policy and that gap; the route itself belongs to the
[recursive lifecycle phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).

The module header of `HostBootstrap.Registry` describes leakage as unrepresentable and the credential as
never logged or persisted. This page's narrower statement is the accurate one: the public `Text` accessor
lets caller code log, serialize, or persist the bytes (see
[Why credentials are not in Dhall](#why-credentials-are-not-in-dhall)). The
[composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
owns that header.

The same phase owes two changes to the forwarding described on this page: Docker Hub entries selected by an
exact normalised key match instead of the `docker.io` substring test, with the in-container lifecycle of
`withForwardedRegistryAuth` and `discoverHostRegistryAuth` under test; and forwarding as a typed operation of
the binary that replaces the `dockerAuthStdinWrapper` shell wrapper and the provider shell script of
`registryAuthLiftPlan`, with the authenticated plan itself adding `-e HOSTBOOTSTRAP_REGISTRY_AUTH`. The
sections below describe the substring filter and the shell transport the tree implements.

The [target capability boundary](#target-capability-boundary) is a target only. No phase schedules it.

## Why credentials are not in Dhall

The binary-context contract (see [binary_context_config](../architecture/binary_context_config.md)) says
every project binary at every level reads a sibling `<project>.dhall` describing the whole composition
topology. Credentials must **never** be part of that picture: a `<project>.dhall` is generated, streamed
between contexts, and read for inspection (`context show`), so a credential placed in it would be streamed
into the VM and the cluster and would survive on disk. The library's ordinary generated-config path
respects this boundary because `RegistryAuth` has no Dhall codec. That is not a whole-program proof: its
public `Text` accessor can be fed to a user-defined codec, logger, file write, or environment operation.
Treat “not in Dhall/durable state” as required policy and tested library behavior, not a state Haskell
currently makes impossible.

## The model (`HostBootstrap.Registry`)

| Surface | Contract |
|---|---|
| `RegistryAuth` | Constructor-hidden newtype; `Show` is redacted and no Dhall/JSON instance is supplied. The public `registryConfigPayload` exposes its raw `Text`, so this is an accidental-leak guard rather than non-extractable authority. |
| `registryConfigPayload :: RegistryAuth -> Text` | The only accessor: the minimal `config.json` payload holding the projected Docker Hub `auths` entries. Any caller can log, serialize, or persist what it returns. |
| `discoverHostRegistryAuth :: IO (Maybe RegistryAuth)` | Reads `$DOCKER_CONFIG/config.json` (or `~/.docker/config.json`). Filters auth keys by a `docker.io` substring and inline credential presence; this may overmatch non-Hub hostnames. `Nothing` on read/parse/no-match failure. |
| `dockerHubAuthFromConfig` | The pure projection `discoverHostRegistryAuth` applies to the file bytes: keeps each `auths` entry whose key contains `docker.io` and that carries a non-empty `auth` or `identitytoken`; `Nothing` when no entry survives. |
| `registryAuthEnvVar` | The environment-variable name, `HOSTBOOTSTRAP_REGISTRY_AUTH`, that carries the payload into a container. |
| `dockerAuthStdinWrapper :: String -> String` | Wraps a shell command so it reads `stdin` into `mktemp -d/config.json` and registers an exit trap. The returned command string embeds no secret, but the file can survive an untrappable kill/crash. |
| `withForwardedRegistryAuth :: IO a -> IO a` | On a Linux frame, consumes a non-empty forwarded environment value into a temporary `DOCKER_CONFIG`, unsets the variable in the current process's environment array, and removes the directory on normal/exceptional `bracket` exit; with the variable unset or empty it runs the action unchanged. On a Windows frame a non-empty value is a fatal configuration error: the action never runs, and because the demo wraps every ordinary command in this function, every ordinary demo command fails on Windows while the variable is set. `unsetEnv` does not clear the process's initial environment block, Docker's stored container configuration, or anything observed before consumption, and uncatchable termination skips cleanup. |
| `registryAuthLiftPlan` | The pure plan behind `liftSubcommandWithAuth`. It returns a plan only for a two-layer `LiftContext` whose outer layer is one Incus, Lima, or WSL2 VM (`ViaVM`, `ViaLimaVM`, `ViaWsl2VM`) and whose terminal layer is a container (`ViaContainer`) without config delivery, with a non-empty subcommand. The plan is one provider-shell command that runs `export HOSTBOOTSTRAP_REGISTRY_AUTH="$(cat)"` and then `exec`s the container's `docker run`; the plan adds no `-e`, so the value reaches the container only when that container layer's extra arguments carry `-e HOSTBOOTSTRAP_REGISTRY_AUTH`. Other legal contexts yield `Nothing`: local, a lone VM or container, VM-only stacks, multiple VM crossings before a container, or staged config delivery. Empty argv also yields `Nothing`. A container before another layer is refused by `liftContextFromLayers` before a context exists. |
| `liftSubcommandWithAuth` (owner: `HostBootstrap.Registry`) | Runs `registryAuthLiftPlan`'s command with the payload on `stdin`. The value is absent from constructed `argv`, but exists in the shell/container environment and in Docker's stored container configuration. With `Nothing`, or with any context shape for which `registryAuthLiftPlan` returns `Nothing`, it runs the unauthenticated `liftSubcommand` and reports nothing, so the nested pull is anonymous. The [composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md) validates this policy-bearing ownership and the guarded direction in which Registry imports generic Lift while Lift imports no credential type. |

## How forwarding crosses each boundary

The current demo calls discovery on the outer host. The library offers two transient channels to a nested
pull; the demo delivers a value over the first only. The library does not place the value directly in constructed `argv`, Dhall, or an
image layer; “no durable state” depends on cleanup completing:

- **VM, raw `docker build`/`docker pull`** (the demo's build #3 base-image pull in `pristine-bootstrap`):
  the host pipes the minimal `config.json` on `stdin` to a command wrapped by `dockerAuthStdinWrapper`.
  The in-VM shell writes it to a `mktemp` `DOCKER_CONFIG`, runs the build, and the `trap` removes it on
  ordinary shell exit. `SIGKILL`, VM loss, or a host crash can leave the directory behind.
- **Container, environment forwarding**: core's admitted lifecycle container route
  (`HostBootstrap.Handoff.Process.Route`) adds `-e HOSTBOOTSTRAP_REGISTRY_AUTH` (the **name** only) to the
  `docker run` of the project container the chain hands `project up` into. Docker copies a name-only `-e`
  from the launching Docker client's own environment, so a value reaches the container only when that
  client's environment holds one; in the demo no frame sets it, so this path carries no value and the
  container frame's pulls run anonymously (see [Current Status](#current-status)). The Registry-owned
  consumer of the generic lift seam, `liftSubcommandWithAuth`, is the one producer of a value: for a
  container reached directly through one Incus, Lima, or WSL2 VM (the only shape `registryAuthLiftPlan`
  plans; every other shape falls back to the unauthenticated lift) it pipes the payload on `stdin` to the VM
  shell, which imports it with `export HOSTBOOTSTRAP_REGISTRY_AUTH="$(cat)"` and `exec`s the container's
  `docker run`, which passes the value only when the container layer's extra arguments carry
  `-e HOSTBOOTSTRAP_REGISTRY_AUTH`.
  When a value does arrive, the in-container binary's `withForwardedRegistryAuth` consumes it once at
  startup into a transient `DOCKER_CONFIG` for the binary's nested `kind`/`docker` pulls and attempts
  normal/exceptional cleanup through `bracket`. The value is not in the constructed `argv`, but Docker
  writes it into the container's stored configuration, where `docker inspect` returns it until the
  container is removed, and it stays in the container process's initial environment block (readable
  through `/proc/<pid>/environ` with the same privilege) for the process lifetime. Environment forwarding
  is therefore not a confidential transport.

The source boundary is one-way: `HostBootstrap.Registry` may import the lower `HostBootstrap.Lift` and its
generic quoting helper; generic Lift imports neither Registry nor `RegistryAuth`. That dependency boundary
is implemented and pinned by a source guard. The
[composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
records the exact blob-leaf argument coverage and complete gate.

This is the current forwarding idiom: the host binary knows it is
the outermost frame and holds the credential; each nested binary knows it may receive a forwarded
credential and consumes it locally for the duration of its pulls. The intended policy is not to retain
it as project state; the current type/API and kill behavior do not prove that property universally.

## Where the inline token comes from (per-host login)

Discovery reads an **inline** token only. For the ordinary Hub key,
`auths."https://index.docker.io/v1/"`, `dockerHubAuthFromConfig` keeps the matching entry verbatim —
both the `auth` (base64 `username:token`) and any `identitytoken` field — and forwards it. The current
filter matches keys containing `docker.io`; it does not canonicalize registry names. It
deliberately does **not** resolve credential stores
(`credsStore`/`credHelpers`) — no `docker-credential-*` helper is ever invoked. So the credential must
live inline in `config.json`, which is exactly what a plain `docker login` writes **when no credential
helper is configured**:

- **Linux** and **Windows (standalone Docker CLI, no Docker Desktop)** — a bare `docker.exe`/`docker`
  with no `credsStore` set writes the token inline on `docker login -u <user>` (paste a Docker Hub
  **Personal Access Token**). This is the symmetric, zero-configuration path: the same inline shape is
  discovered and forwarded on both. The Windows CLI is the static binary from
  `https://download.docker.com/win/static/stable/x86_64/` (no daemon, no Docker Desktop needed — `docker
  login` is a registry API call). Prefer a PAT over a password: inline is base64, plaintext at rest.
- **macOS (Docker Desktop → `osxkeychain`)** and **Windows with a helper (`wincred` / Docker Desktop
  `desktop`)** — the helper stores the secret in the OS keystore, leaving `config.json` with the
  `docker.io` key but **no** inline `auth`, so discovery yields `Nothing` and pulls run anonymously. The
  workaround is the `DOCKER_CONFIG` override: point it at a directory whose `config.json` carries a
  plaintext Docker Hub `auths` entry (a PAT), which `discoverHostRegistryAuth` reads in preference to
  `~/.docker/config.json`. See the [demo runbook](../operations/demo_runbook.md) per-substrate notes.

## Required Policy And Current Limits

The following are forbidden:

- a credential field, env-reference, or path in any `<project>.dhall`, `ConfigArtifact`, or `HostConfig`;
- writing the credential to a durable project file in the VM or a container image layer, or mounting the
  host Docker config into a VM or container;
- putting the credential value directly in constructed `argv`;
- requiring a Docker Hub login: with no host login, every pull runs anonymously and the run proceeds.

Current limits of the transport:

- `stdin` and a forwarded environment-variable name keep the value out of constructed `argv`, but an
  environment value is not out of band: OS and Docker inspection can read it, and Docker stores it in the
  container's configuration until the container is removed.
- The temporary `DOCKER_CONFIG` directories are removed by `trap` and `bracket` cleanup, which uncatchable
  termination skips.

> **Scope note.** This doctrine governs the **host Docker Hub credential** forwarded
> down the lift. It does **not** govern an in-cluster application secret — e.g. the
> `hostbootstrap-demo` `object-store-credentials` Kubernetes Secret (the root
> S3 credentials the `registry:2` s3 driver authenticates with). A k8s Secret is an
> in-cluster runtime resource rather than a `<project>.dhall` field. The demo currently
> hardcodes both values in `demo/src/HostBootstrapDemo/Commands.hs` and renders them into
> a manifest; Kubernetes Secret encoding does not make those source constants secret. See
> [in_cluster_registry.md](in_cluster_registry.md).

## Target Capability Boundary

The target does not expose credential bytes as `Text`. Discovery validates an exact canonical registry
identity and returns an opaque, scope/registry/credential-id-indexed capability. A plan-authorized pull
operation consumes that capability through one broker-owned transport and returns only a redacted
outcome; configuration, logging, and artifact APIs cannot accept it. A replayed, wrong-plan,
wrong-registry, or expired grant is rejected.

OS transport still has an honesty boundary. A supported strong mode must use a substrate mechanism whose
same-privilege visibility and crash cleanup can be stated precisely (for example, an inherited
descriptor/anonymous pipe owned by the child operation). A container receives the payload over such a
descriptor or `stdin`, never through an environment variable, because Docker persists environment values in
the container's configuration. If the substrate cannot meet the requested
confidentiality or cleanup guarantee, planning returns `Unsupported`; documentation must not upgrade
best-effort temporary-file/environment handling into “never exposed” or “always scrubbed.”

## Validation

- `RegistrySpec` covers the current substring projection fixtures (including dropping the tested
  unrelated registry key), redacted `Show`, `Nothing` fallback paths, that the generated stdin
  wrapper text embeds no fixture secret, the exact Incus, Lima, and WSL2 `registryAuthLiftPlan` commands
  and their freedom from payload bytes, the `Nothing` plan for every other context shape, and the ordinary
  lift `liftSubcommandWithAuth` falls back to. It does not prove canonical registry matching,
  same-privilege environment secrecy, or cleanup after uncatchable termination.
- The demo (`project up`, interpreting `demoChainFor` for the detected substrate) forwards the credential
  only over `stdin` from the metal host: build #3 and the published-base pull run authenticated in the VM
  when the host is logged in. No test observes an authenticated pull inside the project container, and in
  the demo none occurs (see [Current Status](#current-status)). A successful run shows no intended
  Dhall/image/argv write; it is not a proof against inspection or interrupted cleanup. See
  [demo_runbook](../operations/demo_runbook.md).
