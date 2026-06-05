---
name: schema-reference
description: The hostbootstrap.dhall project-config schema, how it is parsed, and how illegal states are rejected.
type: reference
---

# hostbootstrap.dhall schema

Every project that adopts hostbootstrap ships a `hostbootstrap.dhall` that builds
one typed value against the [Dhall schema](../../hostbootstrap/dhall/package.dhall)
the CLI bundles and injects as `H` (no import line, nothing vendored). We use
**Dhall** rather than YAML for one reason: its union types let us make illegal
configurations *unrepresentable at the type level*. A project declares **what its
workload needs** (an acceleration requirement) and **never names a host**, so a
CUDA-on-Apple pairing is not a runtime check we have to remember to write — it is
simply unwritable. See [`spec.py`](../../hostbootstrap/spec.py) for the consuming
side.

## Top-level shape

The CLI injects the schema as `H` before rendering, so the file carries **no
import line** and usually opens directly at production-mode `H.config`:

```dhall
-- `H` (the schema) is injected by the CLI.
H.config
  { project = "<name>"          -- image / container / unit name
  , targets =                   -- one entry per acceleration requirement
    [ H.target <accel> <model> ]
  }
```

* `<accel>` is `H.Accel.Cpu`, `H.Accel.Cuda`, or `H.Accel.Metal` — the hardware
  the workload *requires*, not the host it runs on.
* `<model>` is one of the three execution models below, chosen **per target**.

`H.target` lowers the typed model union into a JSON-friendly record (`dhall-to-json`
strips union tags, so it injects an explicit `tag`). `H.config` is a typed
constructor that pins the top-level shape and sets `development = False`. Projects
that need local-only development behavior opt in explicitly with
`H.configWithDevelopment True { … }`.

## Acceleration requirements and host resolution

The host is detected at runtime ([`substrate.py`](../../hostbootstrap/substrate.py));
the CLI then selects the declared target the host can satisfy. A host provides at
most one accelerator, so a single `Cpu` target is portable everywhere while an
accelerated target is bound to its hardware:

| detected host | satisfies |
|---|---|
| `apple-silicon` (arm64) | `Cpu`, `Metal` |
| `linux-cpu` (amd64 / arm64) | `Cpu` |
| `linux-gpu` (amd64 / arm64) | `Cpu`, `Cuda` |

When several declared targets are satisfiable (e.g. a project declares both `Cpu`
and `Cuda` and runs on `linux-gpu`), the resolver picks the **most specific** —
the accelerated path wins over the always-available `Cpu` fallback. The base-image
family is *derived* from the resolved `Accel` (`Cpu`/`Metal` → cpu base, `Cuda` →
cuda base); there is no `flavor` field to set inconsistently.

## The three models

### `H.Model.Container` — build an image and run it
hostbootstrap builds a thin image `FROM` the base tag and runs it. The container
owns any cluster/upload work; **no system unit is ever created** for this model.
For one-shot `hostbootstrap run`, the image must declare an `ENTRYPOINT`; trailing
tokens are passed as arguments to that entrypoint, not interpreted as a raw
container command. Hostbootstrap parses its own `run` options only before the
first project argument; after that boundary, option-looking tokens are forwarded
unchanged (`hostbootstrap run test --help` forwards `test --help`).

| field | type | required | default | meaning |
|---|---|---|---|---|
| `dockerfile` | `Text` | yes | — | project Dockerfile; must declare `ARG BASE_IMAGE`, `FROM ${BASE_IMAGE}`, and a runtime `ENTRYPOINT` |
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

`CtrArtifact = { dockerfile : Text }`. `HostReqs = { ghc : Bool }` (default
`False`). Metal/Tart tooling is not a free flag: it is required exactly when the
resolved target is `H.Accel.Metal`, which only ever resolves on Apple silicon.

## How it is parsed and validated

1. The CLI provisions a native `dhall-to-json` (see [prerequisites](prerequisites.md)),
   wraps the project file in `let H = env:HOSTBOOTSTRAP_PACKAGE in ( … )` so the
   bundled schema is in scope as `H`, and renders it to JSON. **Dhall type-checks
   during this step**, so an ill-typed config fails here.
2. [`spec.py`](../../hostbootstrap/spec.py) reads the JSON: each target carries an
   `accel` plus a `model` with a `tag` (`Container` / `HostBinary` / `HostDaemon`)
   and exactly one populated payload, mapped into a frozen dataclass.
3. It then runs the residual checks Dhall cannot express and fails fast with a
   `SpecError`: **no duplicate accel**, and **at least one target must be runnable
   on the detected host**.

## What the type system rejects (WRONG vs. RIGHT)

> **WRONG** — a CUDA workload pinned to Apple hardware
>
> There is no way to write this: a project declares an `Accel`, never a host. A
> `Cuda` target resolves only on a CUDA-capable host, so CUDA-on-Apple cannot be
> expressed in the first place.
>
> **RIGHT** — declare the requirement; the resolver binds it to capable hosts
>
> ```dhall
> H.target H.Accel.Cuda (H.Model.Container H.Container::{ dockerfile = "docker/infer.Dockerfile" })
> ```

> **WRONG** — a base `flavor` on a container
>
> ```dhall
> H.Model.Container H.Container::{ dockerfile = "d", flavor = H.Flavor.Cuda }
> ```
>
> Aborts: `Container` has no `flavor` field and `H.Flavor` no longer exists. The
> base family is derived from the target's `Accel`, so a CPU container can never
> claim a CUDA base.

> **WRONG** — a daemon on a container
>
> ```dhall
> H.Model.Container H.Container::{ dockerfile = "d", daemon = ".build/x serve" }
> ```
>
> `Container` has no `daemon` field, so a container can never spawn a host unit.

> **WRONG** — a `HostDaemon` without its required `daemon`, or `mounts` on a
> `HostBinary`, or an unknown `H.Accel.Gpu`
>
> Each aborts during `dhall-to-json`: the unit rule is structural (no `daemon`
> declared ⇒ no unit, and `HostDaemon` requires one); only a `Container` is
> bind-mounted; and `Accel` is the closed enum `<Cpu | Cuda | Metal>`.

Duplicate accels and a config with no host-runnable target are not expressible as
Dhall type errors, so [`spec.py`](../../hostbootstrap/spec.py) rejects them with a
`SpecError` instead.

## Worked examples (by archetype)

A generic CPU service that runs on every host — Apple, linux-cpu, linux-gpu,
amd64 and arm64 — from one declaration:

```dhall
H.config
  { project = "demo"
  , targets =
    [ H.target H.Accel.Cpu
        ( H.Model.Container
            H.Container::{
            , dockerfile = "docker/demo.Dockerfile"
            , service = True
            , mounts =
              [ H.Mount::{ host = "./.data", container = "/opt/demo/.data" }
              , H.Mount::{ host = "/var/run/docker.sock", container = "/var/run/docker.sock" }
              ]
            }
        )
    ]
  }
```

Its Dockerfile installs the project command and makes it the tini-wrapped
entrypoint, so `hostbootstrap run test all` passes `test all` to it:

```dockerfile
RUN install -m 0755 "$(cabal list-bin exe:demo)" /usr/local/bin/demo
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/demo"]
```

A mixed project: a Metal host daemon on Apple silicon, a CUDA service container on
NVIDIA hosts, and a CPU container fallback everywhere else. The resolver picks the
most specific target the detected host can satisfy:

```dhall
[ H.target H.Accel.Metal
    ( H.Model.HostDaemon
        H.HostDaemon::{
        , build = H.Build::{ cabal = "cabal install --installdir .build exe:infer", host = H.HostReqs::{ ghc = True } }
        , daemon = ".build/infer inference --serve"
        }
    )
, H.target H.Accel.Cuda
    ( H.Model.Container H.Container::{ dockerfile = "docker/infer.Dockerfile", service = True } )
, H.target H.Accel.Cpu
    ( H.Model.Container H.Container::{ dockerfile = "docker/infer.Dockerfile", service = True } )
]
```

A local development project that uses normal container build/run behavior but does
not promise headless pre-login Docker after a reboot:

```dhall
H.configWithDevelopment
  True
  { project = "demo"
  , targets =
    [ H.target H.Accel.Cpu
        (H.Model.Container H.Container::{ dockerfile = "docker/demo.Dockerfile" })
    ]
  }
```
