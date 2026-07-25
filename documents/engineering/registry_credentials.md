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
  `DOCKER_CONFIG` file. Environment values can be observable through same-privilege process/container
  inspection, and ordinary trap/bracket cleanup is not guaranteed after `SIGKILL`, host crash, or abrupt
  VM termination.
- When the host is not logged in, discovery yields `Nothing` and every pull runs anonymously — a
  pristine host needs no Docker Hub login.

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
| `discoverHostRegistryAuth :: IO (Maybe RegistryAuth)` | Reads `$DOCKER_CONFIG/config.json` (or `~/.docker/config.json`). Filters auth keys by a `docker.io` substring and inline credential presence; this may overmatch non-Hub hostnames. `Nothing` on read/parse/no-match failure. |
| `dockerAuthStdinWrapper :: String -> String` | Wraps a shell command so it reads `stdin` into `mktemp -d/config.json` and registers an exit trap. The returned command string embeds no secret, but the file can survive an untrappable kill/crash. |
| `withForwardedRegistryAuth :: IO a -> IO a` | Consumes the forwarded environment value into a temporary `DOCKER_CONFIG`, unsets the variable in the current process, and removes the directory on normal/exceptional `bracket` exit. Same-privilege/container inspection before consumption and uncatchable termination remain outside that guarantee. |
| `liftSubcommandWithAuth` (`HostBootstrap.Lift`) | Pipes the payload to the VM shell and uses `-e HOSTBOOTSTRAP_REGISTRY_AUTH` (the name only) on `docker run`. The value is absent from constructed `argv`, but exists in the shell/container environment and may be visible through process or Docker inspection. |

## How forwarding crosses each boundary

The current demo calls discovery on the outer host. It then reaches a nested pull over one of two
transient channels. The library does not place the value directly in constructed `argv`, Dhall, or an
image layer; “no durable state” depends on cleanup completing:

- **VM, raw `docker build`/`docker pull`** (the demo's build #3 base-image pull in `pristine-bootstrap`):
  the host pipes the minimal `config.json` on `stdin` to a command wrapped by `dockerAuthStdinWrapper`.
  The in-VM shell writes it to a `mktemp` `DOCKER_CONFIG`, runs the build, and the `trap` removes it on
  ordinary shell exit. `SIGKILL`, VM loss, or a host crash can leave the directory behind.
- **Container, the persistent stack's in-container pulls**: the project container the chain hands
  `project up` into (`demoDeployImage`) carries `-e HOSTBOOTSTRAP_REGISTRY_AUTH` (the **name** only) on
  its `docker run`, so Docker forwards the value into the container's environment without putting the
  value in the constructed `argv`. That environment may be visible through `/proc`/same-privilege or
  Docker inspection until consumption. The in-container binary's `withForwardedRegistryAuth`
  consumes it once at startup into a transient `DOCKER_CONFIG`, so the `deploy-kind` step's `kind` node-
  image pull and the in-container `docker run` probes authenticate, then attempts normal/exceptional
  cleanup through `bracket`. The core lift seam
  `liftSubcommandWithAuth` supports the same shape for a container reached directly through a VM: it
  pipes the payload on `stdin` to the VM shell, which imports it with
  `export HOSTBOOTSTRAP_REGISTRY_AUTH="$(cat)"` and `exec`s a `docker run -e HOSTBOOTSTRAP_REGISTRY_AUTH`.

This is the current forwarding idiom: the host binary knows it is
the outermost frame and holds the credential; each nested binary knows it may receive a forwarded
credential and consumes it locally for the duration of its pulls. The intended policy is not to retain
it as project state; the current type/API and kill behavior do not prove that property universally.

## Where the inline token comes from (per-host login)

Discovery reads an **inline** token only. For the ordinary Hub key,
`auths."https://index.docker.io/v1/"`, `dockerHubAuthFromConfig` keeps the matching entry verbatim —
both the `auth` (base64 `username:token`) and any `identitytoken` field — and forwards it. The current
filter accepts any key containing `docker.io`, so canonical-key validation remains target work. It
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

- A credential field, env-reference, or path in any `<project>.dhall`, `ConfigArtifact`, or `HostConfig`.
- Writing the credential to a durable project file in the VM or a container image layer, or mounting the host
  Docker config into a VM or container.
- Putting the credential value directly in constructed `argv`. Current transport uses `stdin` and a
  forwarded environment name, but the resulting environment value is not “out of band” from OS/container
  inspection.
- A hard dependency on being logged in: with no host login, pulls run anonymously.

> **Scope note.** This doctrine governs the **host Docker Hub credential** forwarded
> down the lift. It does **not** govern an in-cluster application secret — e.g. the
> `hostbootstrap-demo` `minio-credentials` Kubernetes Secret (the MinIO root / S3
> credentials the `registry:2` s3 driver authenticates with). A k8s Secret is an
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
descriptor/anonymous pipe owned by the child operation). If the substrate cannot meet the requested
confidentiality or cleanup guarantee, planning returns `Unsupported`; documentation must not upgrade
best-effort temporary-file/environment handling into “never exposed” or “always scrubbed.”

## Validation

- `RegistrySpec` covers the current substring projection fixtures (including dropping the tested
  unrelated registry key), redacted `Show`, `Nothing` fallback paths, and that the generated stdin
  wrapper text embeds no fixture secret. It does not prove canonical registry matching, same-privilege
  environment secrecy, or cleanup after uncatchable termination.
- The demo (`project up`, interpreting `demoChainFor` for the detected substrate) exercises forwarding
  end to end: the
  metal frame's build #3 pulls the base image authenticated, and the container frame's `deploy-kind`
  step pulls the kind node image authenticated (with the in-container `docker run` probes likewise),
  using the current risk-reducing transport. A successful run shows no intended Dhall/image/argv write;
  it is not a proof against inspection or interrupted cleanup. See
  [demo_runbook](../operations/demo_runbook.md).
