# Registry Credential Forwarding

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../architecture/composition_methodology.md](../architecture/composition_methodology.md), [../architecture/binary_context_config.md](../architecture/binary_context_config.md), [../operations/demo_runbook.md](../operations/demo_runbook.md)

> **Purpose**: Define how the host's Docker Hub credentials are forwarded down the self-reference lift to
> authenticate nested image pulls, modelled so that leaking the credential is unrepresentable, and never
> placed in Dhall, a persisted file, or a process listing.

## TL;DR

- Pulling images from Docker Hub inside a nested context (a VM `docker build`, a container's
  `kind`/`docker run`) hits Docker Hub's **unauthenticated** rate limit. The fix is to forward the host's
  existing Docker Hub login down the [self-reference lift](../architecture/composition_methodology.md) so
  the nested pull authenticates.
- The credential is an **effect-only, non-serialisable capability** modelled by `HostBootstrap.Registry`.
  `RegistryAuth` is opaque (its constructor is not exported), its `Show` is redacted, and it has **no
  `FromDhall`/`ToDhall` instance** — so it **cannot** appear in a `<project>.dhall`, a log line, or a
  generated config artifact. Leaking it is unrepresentable by construction.
- It is **discovered only on the host** (from the host's own `~/.docker/config.json`), carries **only the
  Docker Hub auth entries** (never the host's other registry credentials), and is **never written into
  `HostConfig`, the binary context, or any generated file**.
- It is forwarded only over **ephemeral channels**, never `argv`: piped on `stdin` into a transient
  `DOCKER_CONFIG` that is removed when the command exits, or carried into a container by an environment
  variable the in-container binary consumes once into a transient `DOCKER_CONFIG` and never persists.
- When the host is not logged in, discovery yields `Nothing` and every pull degrades to the previous
  anonymous behaviour — the pristine-host story is unchanged.

## Why credentials are not in Dhall

The binary-context contract (see [binary_context_config](../architecture/binary_context_config.md)) says
every project binary at every level reads a sibling `<project>.dhall` describing the whole composition
topology. Credentials must **never** be part of that picture: a `<project>.dhall` is generated, mounted,
copied between contexts, and read for inspection (`context show`), so a credential placed in it would be
copied into the VM and the cluster and would survive on disk. The type system enforces the boundary:
`RegistryAuth` has no Dhall codec, so it is not expressible in the schema, the context, or any
`ConfigArtifact`. The credential is a *runtime effect*, resolved at the moment of a pull, not *state*.

## The model (`HostBootstrap.Registry`)

| Surface | Contract |
|---|---|
| `RegistryAuth` | Opaque newtype; constructor unexported; `Show` prints `RegistryAuth <redacted>`; no Dhall/JSON-serialising instance the schema can reach. Carries the minimal Docker-Hub-only `config.json`. |
| `discoverHostRegistryAuth :: IO (Maybe RegistryAuth)` | Reads `$DOCKER_CONFIG/config.json` (or `~/.docker/config.json`) — the host is where the credential lives. Projects out only the `docker.io` auth entries. `Nothing` on any failure or no Docker Hub login. |
| `dockerAuthStdinWrapper :: String -> String` | Pure: wraps an in-context shell command so it reads the payload from `stdin` into a throwaway `DOCKER_CONFIG` (`mktemp -d`), runs the command, and removes the directory on exit (`trap`). The secret is **not** in the returned string. |
| `withForwardedRegistryAuth :: IO a -> IO a` | The in-container side: consumes the forwarded environment variable once into a transient `DOCKER_CONFIG`, points the process at it for the duration (via `bracket`), drops the raw variable, and scrubs the directory afterwards. A no-op when the variable is absent. |
| `liftSubcommandWithAuth` (`HostBootstrap.Lift`) | The lift seam: forwards the credential into a container-reached-through-a-VM frame by piping the payload on `stdin` and adding `-e HOSTBOOTSTRAP_REGISTRY_AUTH` (the **name** only) to the `docker run`. With `Nothing` it is exactly `liftSubcommand` (anonymous). |

## How forwarding crosses each boundary

The host binary discovers the credential (the only place it is read). It then reaches a nested pull over
one of two ephemeral channels, chosen by the boundary — never `argv`, never a persisted file, never Dhall:

- **VM, raw `docker build`/`docker pull`** (the worked demo's build #3 base-image pull): the host pipes
  the minimal `config.json` on `stdin` to a command wrapped by `dockerAuthStdinWrapper`. The in-VM shell
  writes it to a `mktemp` `DOCKER_CONFIG`, runs the build, and the `trap` removes it on exit. The
  credential touches the VM only in that transient directory and is gone when the build returns.
- **Container, the lifted `test all`**: `liftSubcommandWithAuth` pipes the payload on `stdin` to the VM
  shell, which imports it into the environment with `export HOSTBOOTSTRAP_REGISTRY_AUTH="$(cat)"` (so the
  value never appears in a process listing) and `exec`s a `docker run -e HOSTBOOTSTRAP_REGISTRY_AUTH`
  (the **name** only). Docker forwards the value into the container's environment; the in-container
  binary's `withForwardedRegistryAuth` consumes it once into a transient `DOCKER_CONFIG` so its nested
  `kind` (node image) and `docker run` (e.g. the e2e `curl` probe) pulls authenticate, then scrubs it.

This is the "every project binary at every level has global knowledge" idiom: the host binary knows it is
the outermost frame and holds the credential; each nested binary knows it may receive a forwarded
credential and consumes it locally for the duration of its pulls. The credential is never stored at any
level.

## What is explicitly forbidden

- A credential field, env-reference, or path in any `<project>.dhall`, `ConfigArtifact`, or `HostConfig`.
- Writing the credential to a persisted file in the VM or a container image layer, or mounting the host
  Docker config into a VM or container.
- Putting the credential value in `argv` (it would show in `ps`/process listings) — it travels on `stdin`
  or, into a container, as a forwarded environment **name** whose value Docker supplies out of band.
- A hard dependency on being logged in: with no host login, pulls run anonymously exactly as before.

## Validation

- `RegistrySpec` (run through the canonical code-check) covers the Docker-Hub-only projection (the host's
  other registry credentials are dropped), the redacted `Show`, the `Nothing` anonymous-fallback paths,
  and that the `stdin` wrapper embeds no secret.
- The worked demo (`project up`, interpreting the demo's `demoChain`) exercises forwarding end to end:
  build #3 pulls the base image authenticated, and the lifted `test all` pulls the kind node image and
  the e2e probe image authenticated, all without the credential appearing in Dhall, a persisted file, or
  `argv`. See [demo_runbook](../operations/demo_runbook.md).
