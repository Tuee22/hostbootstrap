---
name: schema-reference
description: The hostbootstrap.dhall project-config schema, how it is parsed, and how illegal states are rejected.
type: reference
---

# hostbootstrap.dhall schema

Every project that adopts hostbootstrap ships a `hostbootstrap.dhall` that builds
one typed value against the [Dhall schema](../../hostbootstrap/dhall/package.dhall)
the CLI bundles and injects as `H` (no import line, nothing vendored). We use
**Dhall** rather than YAML for one reason: its
union types let us make illegal configurations *unrepresentable at the type
level*. A `Container` record simply has no `daemon` field, so writing one is a
type error before the CLI ever runs — not a runtime check we have to remember to
write. See [`spec.py`](../../hostbootstrap/spec.py) for the consuming side.

## Top-level shape

The CLI injects the schema as `H` before rendering, so the file carries **no
import line** and usually opens directly at production-mode `H.config`:

```dhall
-- `H` (the schema) is injected by the CLI.
H.config
  { project = "<name>"          -- image / container / unit name
  , substrates =                -- one entry per supported substrate
    [ H.entry <substrate> <model> ]
  }
```

* `<substrate>` is `H.Substrate.AppleSilicon`, `H.Substrate.LinuxCpu`, or
  `H.Substrate.LinuxGpu`.
* `<model>` is one of the three execution models below, chosen **per substrate**.
  A project that behaves differently across substrates simply lists a different
  model per entry; there is no separate "multi-substrate" model.

`H.entry` lowers the typed union into a JSON-friendly record (`dhall-to-json`
strips union tags, so it injects an explicit `tag`). `H.config` is a typed
constructor that pins the top-level shape and sets `development = False`.
Projects that need local-only development behavior opt in explicitly:

```dhall
H.configWithDevelopment
  True
  { project = "<name>"
  , substrates =
    [ H.entry <substrate> <model> ]
  }
```

Development mode is intentionally narrow: it keeps substrate, build, and Docker
checks, but Apple Silicon `doctor` skips the FileVault and system-Colima
pre-login checks. For `HostDaemon`, `cluster up` builds and prints the daemon
command instead of creating a LaunchDaemon/systemd unit; `cluster down` and
`cluster delete` skip unit removal. Production mode remains the default.

## The three models

### `H.Model.Container` — build an image and run it
hostbootstrap builds a thin image `FROM` the base tag and runs it. The container
owns any cluster/upload work; **no system unit is ever created** for this model.
For one-shot `hostbootstrap run`, the image must declare an `ENTRYPOINT`; trailing
tokens are passed as arguments to that entrypoint, not interpreted as a raw
container command.

| field | type | required | default | meaning |
|---|---|---|---|---|
| `dockerfile` | `Text` | yes | — | project Dockerfile; must declare `ARG BASE_IMAGE`, `FROM ${BASE_IMAGE}`, and a runtime `ENTRYPOINT` |
| `flavor` | `<Cpu \| Cuda>` | no | `Cpu` | base family inherited (use `Cuda` on `linux-gpu`) |
| `service` | `Bool` | no | `False` | `True` ⇒ `cluster up` runs it detached, `--restart unless-stopped`; `False` ⇒ one-shot `--rm` |
| `mounts` | `List Mount` | no | `[]` | bind mounts applied to runs |

`Mount = { host : Text, container : Text, ro : Bool }` (`ro` default `False`;
`host` may use `${VARS}` and relative paths, resolved against the project root).
Prefer a tini-wrapped exec-form entrypoint:

```dockerfile
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/<project>"]
```

### `H.Model.HostBinary` — build a host binary, hand off its lifecycle
hostbootstrap builds the binary (Apple: native via brew→ghcup; Linux: inside the
base container, extracted to `.build/`), optionally a container counterpart, then
runs the binary's own lifecycle commands. **No system unit** — the binary owns
its own services (e.g. an RKE2 systemd unit it installs).

| field | type | required | default | meaning |
|---|---|---|---|---|
| `build` | `Build` | yes | — | `{ cabal : Text, host : HostReqs }` — the build command + host prereqs |
| `handoff` | `Handoff` | yes | — | `{ up, down : Text, delete : Optional Text }` run after the builds |
| `container` | `Optional CtrArtifact` | no | `None` | optional image counterpart (the binary pushes it) |

`build.cabal` must place the binary at `.build/<project>` (e.g. `cabal install
--installdir .build --install-method=copy --overwrite-policy=always exe:<name>`).

### `H.Model.HostDaemon` — run a host daemon under a system unit
For a long-running **host-native** daemon (e.g. Apple-silicon Metal inference).
This is the **only** model with a `daemon` field — and it is **required** — so a
[LaunchDaemon / systemd unit](prerequisites.md) exists *if and only if* this
model is chosen in production mode. `cluster up` creates it; `cluster down`
removes it. Development mode is the explicit exception: the daemon is built, but
the unit is not created or removed.

| field | type | required | default | meaning |
|---|---|---|---|---|
| `build` | `Build` | yes | — | as above |
| `daemon` | `Text` | yes | — | host command wrapped in the system unit |
| `container` | `Optional CtrArtifact` | no | `None` | optional image counterpart |

`CtrArtifact = { dockerfile : Text, flavor : <Cpu \| Cuda> }`.
`HostReqs = { ghc, tart, metal : Bool }` (all default `False`).

## How it is parsed and validated

1. The CLI provisions a native `dhall-to-json` (see [prerequisites](prerequisites.md)),
   wraps the project file in `let H = env:HOSTBOOTSTRAP_PACKAGE in ( … )` so the
   bundled schema is in scope as `H`, and renders it to JSON. **Dhall type-checks
   during this step**, so an ill-typed config fails here. (Because `H` is injected
   rather than imported, the file only type-checks through the CLI — standalone
   `dhall-to-json` sees `H` as unbound.)
2. [`spec.py`](../../hostbootstrap/spec.py) reads the JSON: each entry's `model`
   carries `development` plus model entries. Each entry's `model` carries a
   `tag` (`Container` / `HostBinary` / `HostDaemon`) and exactly one populated
   payload, which it maps into a frozen dataclass.
3. It then runs the residual checks Dhall cannot express and fails fast with a
   `SpecError`: **no duplicate substrate**, and the **detected substrate must be
   declared**.

## What the type system rejects (WRONG vs. RIGHT)

> **WRONG** — a daemon on a container
>
> ```dhall
> H.Model.Container H.Container::{ dockerfile = "d", daemon = ".build/x serve" }
> ```
>
> `dhall-to-json` aborts: `Error: Expression doesn't match annotation { + daemon : … }`.
> `Container` has no `daemon` field, so a container can never spawn a host unit.
>
> **RIGHT** — a daemon belongs to `HostDaemon`
>
> ```dhall
> H.Model.HostDaemon H.HostDaemon::{ build = H.Build::{ cabal = "…" }, daemon = ".build/x serve" }
> ```

> **WRONG** — a `HostDaemon` without its required `daemon`
>
> ```dhall
> H.Model.HostDaemon H.HostDaemon::{ build = H.Build::{ cabal = "…" } }
> ```
>
> Aborts: `Error: Expression doesn't match annotation { - daemon : … }`. The unit
> rule is structural: no daemon declared ⇒ no unit, and `HostDaemon` *requires* one.

> **WRONG** — `mounts` on a host binary
>
> ```dhall
> H.Model.HostBinary H.HostBinary::{ build = …, handoff = …, mounts = [] : List H.Mount.Type }
> ```
>
> Aborts: `Error: Expression doesn't match annotation { + mounts : … }`. Only a
> `Container` is bind-mounted; a host binary has no container to mount into.

> **WRONG** — an unknown flavor
>
> ```dhall
> H.Container::{ dockerfile = "d", flavor = H.Flavor.Gpu }
> ```
>
> Aborts: `Error: Missing constructor: Gpu`. `flavor` is the enum `<Cpu | Cuda>`.

Duplicate substrates and an undeclared detected substrate are not expressible as
Dhall type errors, so [`spec.py`](../../hostbootstrap/spec.py) rejects them with
a `SpecError` instead.

## Worked examples (by archetype)

A pure-container CLI — no cluster, one-shot (a compose replacement):

```dhall
H.config
  { project = "tool"
  , substrates =
    [ H.entry H.Substrate.LinuxCpu
        (H.Model.Container H.Container::{ dockerfile = "docker/tool.Dockerfile" })
    ]
  }
```

Its Dockerfile should install the project command and make it the tini-wrapped
entrypoint:

```dockerfile
RUN install -m 0755 "$(cabal list-bin exe:tool)" /usr/local/bin/tool
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/tool"]
```

Then `hostbootstrap run test all` passes `test all` to `tool`; it does not run a
raw `/usr/bin/test` inside the container.

A long-running, self-restarting service container that bootstraps its own
cluster and uploads its own image:

```dhall
H.entry H.Substrate.LinuxCpu
  ( H.Model.Container
      H.Container::{
      , dockerfile = "docker/app.Dockerfile"
      , service = True
      , mounts =
        [ H.Mount::{ host = "./.data", container = "/opt/app/.data" }
        , H.Mount::{ host = "/var/run/docker.sock", container = "/var/run/docker.sock" }
        , H.Mount::{ host = "\${HOME}/.docker/config.json", container = "/root/.docker/config.json", ro = True }
        ]
      }
  )
```

A host-binary cluster manager on every substrate (the binary owns its own
service units, e.g. RKE2):

```dhall
H.entry H.Substrate.LinuxCpu
  ( H.Model.HostBinary
      H.HostBinary::{
      , build = H.Build::{ cabal = "cabal install --installdir .build --install-method=copy --overwrite-policy=always exe:mgr" }
      , handoff = H.Handoff::{ up = ".build/mgr cluster up", down = ".build/mgr cluster down" }
      }
  )
```

A mixed project: a host daemon (Metal) on Apple silicon, a service container on
Linux GPU:

```dhall
[ H.entry H.Substrate.AppleSilicon
    ( H.Model.HostDaemon
        H.HostDaemon::{
        , build = H.Build::{ cabal = "cabal install --installdir .build exe:infer", host = H.HostReqs::{ ghc = True, tart = True, metal = True } }
        , daemon = ".build/infer inference --serve"
        }
    )
, H.entry H.Substrate.LinuxGpu
    ( H.Model.Container
        H.Container::{ dockerfile = "docker/infer.Dockerfile", flavor = H.Flavor.Cuda, service = True }
    )
]
```

A local development project that uses normal container build/run behavior but
does not promise headless pre-login Docker after a reboot:

```dhall
H.configWithDevelopment
  True
  { project = "tool"
  , substrates =
    [ H.entry H.Substrate.AppleSilicon
        (H.Model.Container H.Container::{ dockerfile = "docker/tool.Dockerfile" })
    ]
  }
```
