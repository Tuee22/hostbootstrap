---
name: schema-reference
description: The hostbootstrap.dhall project-config schema, how it is parsed, and how illegal states are rejected.
type: reference
---

# hostbootstrap.dhall schema

Every project that adopts hostbootstrap ships a `hostbootstrap.dhall` that builds
one typed value against the [Dhall schema](../../hostbootstrap/dhall/package.dhall)
the CLI bundles and injects as `H`. The schema is substrate-keyed: a project
declares one entry for each hardware target it supports, and each hardware
target chooses exactly one execution model.

## Top-Level Shape

The CLI injects the schema as `H` before rendering, so the file carries no
import line:

```dhall
let container =
      H.Model.Container
        H.Container::{ dockerfile = "docker/app.Dockerfile" }

in  H.config
      { project = "app"
      , substrates =
        [ H.entry H.Substrate.AppleSilicon (H.noCluster container)
        , H.entry H.Substrate.LinuxCpu (H.noCluster container)
        , H.entry H.Substrate.LinuxGpu (H.noCluster container)
        ]
      }
```

- `project` is the project command name. Containers expose it as
  `/usr/local/bin/<project>`; host-native models build `.build/<project>`.
- `substrates` is a list of `H.entry <substrate> <lifecycle>`.
- `<substrate>` is `H.Substrate.AppleSilicon`, `H.Substrate.LinuxCpu`, or
  `H.Substrate.LinuxGpu`.
- `<lifecycle>` is `H.cluster <model>` or `H.noCluster <model>`.
- `<model>` is one of `H.Model.Container`, `H.Model.HostBinary`, or
  `H.Model.HostDaemon`.

## Host Resolution

The host is detected at runtime by
[`substrate.py`](../../hostbootstrap/substrate.py). By default, build/run/cluster
commands select the entry matching the detected host. For single-machine matrix
validation, those commands accept `--force-target <substrate>` to select a
different declared entry:

```bash
hostbootstrap cluster up --force-target apple-silicon
```

`doctor` does not accept `--force-target`; it validates the actual host.

The selected substrate also derives the base-image flavor:

| selected substrate | base flavor |
|---|---|
| `apple-silicon` | `cpu` |
| `linux-cpu` | `cpu` |
| `linux-gpu` | `cuda` |

The base flavor is independent of the execution model. A `linux-gpu` entry can use
`H.Model.Container`; that means a one-shot project container built from the CUDA-flavored base,
not a host-binary handoff.

## Lifecycles

### `H.cluster`

Cluster lifecycle means hostbootstrap forwards `cluster up`, `cluster down`, and
`cluster delete` to the project command. The project command owns the actual
cluster and all cluster state. hostbootstrap only builds the selected model and
performs the handoff.

For `HostDaemon` targets, cluster lifecycle still means cluster lifecycle only.
Run the daemon as a separate foreground process with `hostbootstrap daemon run`
after `hostbootstrap cluster up`; terminate that foreground process before
`hostbootstrap cluster down` or `hostbootstrap cluster delete`.

### `H.noCluster`

No-cluster lifecycle means the target supports `hostbootstrap build` and
`hostbootstrap run`, but does not support `hostbootstrap cluster ...`. Cluster
commands fail fast for this target.

This is the right shape for command-oriented projects such as MCTS.

## Models

### `H.Model.Container`

hostbootstrap builds a thin image `FROM` the selected base tag and runs it. The
Dockerfile must declare a tini-wrapped project entrypoint:

```dockerfile
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/<project>"]
```

| field | type | required | default | meaning |
|---|---|---|---|---|
| `dockerfile` | `Text` | yes | - | project Dockerfile; must declare `ARG BASE_IMAGE`, `FROM ${BASE_IMAGE}`, and the project `ENTRYPOINT` |
| `mounts` | `List Mount` | no | `[]` | bind mounts applied to runs |

`Mount = { host : Text, container : Text, ro : Bool }` (`ro` defaults to
`False`; relative host paths resolve against the project root).

For `H.noCluster`, `hostbootstrap run test all` becomes a one-shot
`docker run --rm <image> test all`. For `H.cluster`, `hostbootstrap cluster up`
becomes a one-shot `docker run --rm <image> cluster up`.

No container run emitted by hostbootstrap includes `--restart`.

Project commands receive `HOSTBOOTSTRAP_TARGET`, `HOSTBOOTSTRAP_MODEL`, and
`HOSTBOOTSTRAP_LIFECYCLE` for every `hostbootstrap run ...` and cluster handoff.
Projects that need target-specific behavior should derive it from this selected
target context rather than declaring explicit handoff commands.

### `H.Model.HostBinary`

hostbootstrap builds the project command into `.build/<project>` using the
standard Cabal install command:

```bash
cabal install --installdir .build --install-method=copy --overwrite-policy=always exe:<project>
```

On Apple Silicon the build runs on the host. On Linux the build runs inside the
selected base container with the source mounted, so the Haskell toolchain does
not need to be installed on the Linux host.

| field | type | required | default | meaning |
|---|---|---|---|---|
| `container` | `Optional CtrArtifact` | no | `None` | optional image counterpart |

`CtrArtifact = { dockerfile : Text }`.

For `H.cluster`, hostbootstrap forwards `.build/<project> cluster up/down/delete`.
There is no explicit handoff field in the schema.

### `H.Model.HostDaemon`

HostDaemon is HostBinary plus one normal foreground daemon command.
`hostbootstrap cluster up/down/delete` still only forwards
`.build/<project> cluster up/down/delete`. `hostbootstrap daemon run` builds the
host binary if needed and then executes `.build/<project> <daemon args>` in the
foreground. The invoking shell, test harness, launchd unit, or systemd unit owns
that process and observes crashes directly.

| field | type | required | default | meaning |
|---|---|---|---|---|
| `daemon` | `Text` | yes | - | arguments appended to `.build/<project>` by `hostbootstrap daemon run` |
| `container` | `Optional CtrArtifact` | no | `None` | optional image counterpart |

hostbootstrap does not create PID files, redirect daemon logs, restart crashed
daemons, or create/remove launchd/systemd units.

## Parsing And Validation

1. The CLI provisions a native `dhall-to-json` (see
   [prerequisites](prerequisites.md)), wraps the project file in
   `let H = env:HOSTBOOTSTRAP_PACKAGE in ( ... )`, and renders it to JSON.
2. [`spec.py`](../../hostbootstrap/spec.py) reads the JSON: each substrate entry
   carries a lifecycle tag (`Cluster` / `NoCluster`) and exactly one model tag
   (`Container` / `HostBinary` / `HostDaemon`).
3. Residual checks reject duplicate substrates and missing selected targets.

## What The Type System Rejects

> **WRONG** - a daemon field on a container
>
> ```dhall
> H.Model.Container H.Container::{ dockerfile = "d", daemon = "serve" }
> ```
>
> **RIGHT** - put daemon arguments on HostDaemon
>
> ```dhall
> H.Model.HostDaemon H.HostDaemon::{ daemon = "serve" }
> ```

> **WRONG** - a handoff field on HostBinary
>
> ```dhall
> H.Model.HostBinary H.HostBinary::{
> , handoff = H.Handoff::{ up = ".build/app cluster up", down = ".build/app cluster down" }
> }
> ```
>
> **RIGHT** - hostbootstrap derives handoff from `project`
>
> ```dhall
> H.Model.HostBinary H.HostBinary::{=}
> ```

> **WRONG** - a base flavor on a container
>
> ```dhall
> H.Model.Container H.Container::{ dockerfile = "d", flavor = "cuda" }
> ```
>
> **RIGHT** - select the hardware substrate
>
> ```dhall
> H.entry H.Substrate.LinuxGpu (H.cluster (H.Model.Container H.Container::{ dockerfile = "d" }))
> ```

Duplicate substrates are not a Dhall type error, so
[`spec.py`](../../hostbootstrap/spec.py) rejects them with `SpecError`.

## Worked Examples

### NoCluster Container

```dhall
let app =
      H.Model.Container
        H.Container::{ dockerfile = "docker/app.Dockerfile" }

in  H.config
      { project = "app"
      , substrates =
        [ H.entry H.Substrate.AppleSilicon (H.noCluster app)
        , H.entry H.Substrate.LinuxCpu (H.noCluster app)
        , H.entry H.Substrate.LinuxGpu (H.noCluster app)
        ]
      }
```

### Clustered Substrate Matrix

```dhall
let linuxContainer =
      H.Model.Container
        H.Container::{
        , dockerfile = "docker/worker.Dockerfile"
        , mounts =
          [ H.Mount::{ host = "./.data", container = "/workspace/.data" }
          , H.Mount::{ host = "/var/run/docker.sock", container = "/var/run/docker.sock" }
          ]
        }

let hostDaemon =
      H.Model.HostDaemon
        H.HostDaemon::{ daemon = "service --role worker --config dhall/worker.dhall" }

in  H.config
      { project = "worker"
      , substrates =
        [ H.entry H.Substrate.AppleSilicon (H.cluster hostDaemon)
        , H.entry H.Substrate.LinuxCpu (H.cluster linuxContainer)
        , H.entry H.Substrate.LinuxGpu (H.cluster linuxContainer)
        ]
      }
```
