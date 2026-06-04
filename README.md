# hostbootstrap

A small host-installed Python CLI and a tiny family of prebuilt base
container images. Together they replace per-project bootstrap shells and
redundant multi-language Dockerfiles with one shared toolchain pulled from
Docker Hub and one declarative, **typed** `hostbootstrap.dhall` per project.

> **Adopting hostbootstrap**: install the CLI on the host, write a
> `hostbootstrap.dhall` (the CLI bundles and injects its typed schema — no import
> line, nothing to vendor), inherit your project Dockerfile `FROM` the base tag
> the CLI selects. Everything else —
> substrate detection, prereqs, build, cluster lifecycle, and (only where a
> project asks for it) a system service unit — is the CLI's job.

The full config schema is
[`documents/engineering/schema.md`](documents/engineering/schema.md).
Detailed language/engineering notes live under [`documents/`](documents/README.md).

---

## What you get

* **Four prebuilt base images** on Docker Hub —
  `docker.io/tuee22/hostbootstrap:basecontainer-{cpu,cuda}-{amd64,arm64}` —
  carrying the shared toolchain (GHC 9.12, Cabal, Go, Node + PureScript +
  Playwright, Python + Poetry, kube tools, LLVM/C++, Rust, optional CUDA, with
  fourmolu/hlint and a warm Haskell store baked in).
* **One CLI** (`hostbootstrap`) that detects your substrate, validates host
  prerequisites, drives `docker build` / `docker run`, manages cluster
  lifecycle, and installs a system-level
  service unit.

Single-arch tags only — never manifest lists. The CLI always knows the
substrate, so it references the one correct arch tag directly.

---

## Installing the CLI

Install `pipx` first:

```bash
# Apple Silicon / macOS
brew install pipx
pipx ensurepath

# Ubuntu 24.04
sudo apt update
sudo apt install -y pipx
pipx ensurepath
```

Then install hostbootstrap as an isolated host CLI app:

```bash
pipx install "git+https://github.com/tuee22/hostbootstrap.git#egg=hostbootstrap"
```

For local development against a checkout:

```bash
pipx install --force /path/to/hostbootstrap
```

Use `pipx` because hostbootstrap is a command-line application, not a library
dependency of downstream projects. `pipx` gives the app its own virtual
environment, exposes only the `hostbootstrap`, `check-code`, and `test-all`
commands on `PATH`, avoids polluting project virtualenvs, and avoids
externally-managed Python conflicts on Homebrew and modern Linux distributions.

hostbootstrap provisions its own native `dhall-to-json` binary on first use. It
**always** downloads a pinned, SHA256-verified static release into
`~/.cache/hostbootstrap/` and uses that one exclusively — it never uses a
`dhall-to-json` found on `PATH`, so the host toolchain cannot affect how your
config is parsed.

To develop hostbootstrap itself, the repo uses Poetry with an in-project
`.venv` (`poetry.toml` sets `virtualenvs.in-project = true`):

```bash
poetry install
poetry run check-code
```

---

## The config: `hostbootstrap.dhall`

Each project ships a typed `hostbootstrap.dhall` that builds one typed value
against the schema the CLI bundles
([`hostbootstrap/dhall/package.dhall`](hostbootstrap/dhall/package.dhall)). We use
**Dhall** rather than YAML for one reason: its union types make illegal
configurations *unrepresentable at the type level* — a `Container` has no
`daemon` field, so writing one is a type error before the CLI ever runs.

The schema is **injected by the CLI as `H`**: your `hostbootstrap.dhall` needs no
import line and nothing vendored. `H.config { … }` is production mode by
default.

```dhall
-- `H` (the typed schema) is injected by the CLI.
H.config
  { project = "example"
  , substrates =
    [ H.entry H.Substrate.LinuxCpu
        (H.Model.Container H.Container::{ dockerfile = "docker/example.Dockerfile" })
    ]
  }
```

One `H.entry` per substrate (`H.Substrate.AppleSilicon`, `.LinuxCpu`, or
`.LinuxGpu`); each picks exactly one of the three models below. See the full
field reference in [`documents/engineering/schema.md`](documents/engineering/schema.md).

For local-only work that is not meant to survive a headless pre-login reboot,
use the explicit development flag:

```dhall
H.configWithDevelopment
  True
  { project = "example"
  , substrates =
    [ H.entry H.Substrate.AppleSilicon
        (H.Model.Container H.Container::{ dockerfile = "docker/example.Dockerfile" })
    ]
  }
```

Development mode keeps Docker/build checks, but skips the Apple Silicon
FileVault and system-Colima pre-login checks. For `HostDaemon`, `cluster up`
builds and prints the daemon command instead of creating a LaunchDaemon/systemd
unit; `cluster down` and `cluster delete` also skip unit mutation.

---

## The three model archetypes

Every substrate picks **one model**. Choose by lifecycle:

* **No cluster, just build + run** → **Container**.
* **A host binary that owns its own lifecycle** → **HostBinary**.
* **A long-running host-native daemon** → **HostDaemon**.

### Container

hostbootstrap builds a thin image `FROM` the base tag and runs it. `service :
Bool` — `False` ⇒ a one-shot `docker run --rm`; `True` ⇒ `cluster up` runs it
detached with `--restart unless-stopped`. `mounts` are bind mounts; `flavor` is
`cpu` or `cuda`. The container itself does any cluster bootstrap / image upload.
**No system unit is ever created** for this model.

This is the compose-replacement case — pure container apps with no cluster are
first-class. The win over compose is faster builds (the prebuilt base tag) plus
a default-pull / `--build-base` "pull-or-build-local" switch compose lacks.

```dhall
H.entry H.Substrate.LinuxCpu
  ( H.Model.Container
      H.Container::{
      , dockerfile = "docker/example.Dockerfile"
      , service = True
      , mounts =
        [ H.Mount::{ host = "./.data", container = "/opt/example/.data" }
        , H.Mount::{ host = "/var/run/docker.sock", container = "/var/run/docker.sock" }
        , H.Mount::{ host = "\${HOME}/.docker/config.json", container = "/root/.docker/config.json", ro = True }
        ]
      }
  )
```

### HostBinary

hostbootstrap builds a binary that runs **on the host** (Apple: native via
brew → ghcup; Linux: inside the base container, extracted to `.build/`), plus an
optional container counterpart. The binary owns its own lifecycle: `handoff`
declares `up` / `down` (and optional `delete`) commands that `cluster up` /
`cluster down` / `cluster delete` invoke. **hostbootstrap creates no system
unit** — the binary manages its own services (e.g. an RKE2 systemd unit it
installs).

```dhall
H.entry H.Substrate.LinuxCpu
  ( H.Model.HostBinary
      H.HostBinary::{
      , build = H.Build::{ cabal = "cabal install --installdir .build --install-method=copy --overwrite-policy=always exe:mgr" }
      , handoff = H.Handoff::{ up = ".build/mgr cluster up", down = ".build/mgr cluster down" }
      }
  )
```

### HostDaemon

A long-running **host-native** daemon (e.g. Apple-silicon Metal inference). This
is the **only** model with a `daemon` field — and it is **required**. `cluster
up` wraps the daemon command in a system-level unit: a **LaunchDaemon** in
`/Library/LaunchDaemons` on macOS (**never** a per-user LaunchAgent) or a
system-scope systemd unit on Linux — so it starts before any user logs in
(headless remote SSH). `cluster down` removes it.

In development mode, hostbootstrap still builds the daemon binary but does not
create or remove the system unit; `cluster up` prints the command to run
manually.

```dhall
H.entry H.Substrate.AppleSilicon
  ( H.Model.HostDaemon
      H.HostDaemon::{
      , build =
          H.Build::{
          , cabal = "cabal install --installdir .build exe:infer"
          , host = H.HostReqs::{ ghc = True, tart = True, metal = True }
          }
      , daemon = ".build/infer inference --serve"
      }
  )
```

Because the `daemon` field exists **only** on `HostDaemon`, a system unit is
created **if and only if** a project declares that model — the rule is
structural, not a runtime check (illegal states are unrepresentable in the Dhall
types). See [`documents/engineering/schema.md`](documents/engineering/schema.md)
for the full type story.

---

## Adoption patterns

The three models compose into a handful of recurring project shapes. Each is
described by its **substrate → model** mapping; pick the one your project
matches. None of these requires Kubernetes — cluster, Helm, and image upload are
opt-in downstream concerns, used only by the patterns that explicitly reach for
them.

### Single-substrate container service — the compose replacement

A web app or service that runs only on Linux, as one long-running container with
persistent state and (often) the Docker socket so it can drive its own image
builds/pushes from inside. This is the canonical `docker compose` replacement:
one substrate, one **Container** with `service = True`, a `.data` bind mount that
survives every `cluster down`/`delete`, and no cluster at all.

| Substrate | Model |
|---|---|
| `linux-cpu` | `Container` (`service = True`, `.data` + socket mounts) |

```dhall
H.entry H.Substrate.LinuxCpu
  ( H.Model.Container
      H.Container::{
      , dockerfile = "docker/app.Dockerfile"
      , service = True
      , mounts =
        [ H.Mount::{ host = "./.data", container = "/opt/app/.data" }
        , H.Mount::{ host = "/var/run/docker.sock", container = "/var/run/docker.sock" }
        ]
      }
  )
```

### Multi-substrate container — same image, CPU vs CUDA

A compute project (heavy native cores — C++/pybind11, ML stacks, a service layer
on top) that runs in a container on both Linux CPU and Linux GPU hosts. It is the
**same model and the same Dockerfile twice**, differing only by `flavor`: `Cpu`
selects the `basecontainer-cpu-*` base, `Cuda` selects `basecontainer-cuda-*`.
Because the heavy toolchain is in the pulled base, each build compiles only the
project's own code.

| Substrate | Model |
|---|---|
| `linux-cpu` | `Container` (`flavor = H.Flavor.Cpu`) |
| `linux-gpu` | `Container` (`flavor = H.Flavor.Cuda`) |

```dhall
[ H.entry H.Substrate.LinuxCpu
    (H.Model.Container H.Container::{ dockerfile = "docker/app.Dockerfile", flavor = H.Flavor.Cpu })
, H.entry H.Substrate.LinuxGpu
    (H.Model.Container H.Container::{ dockerfile = "docker/app.Dockerfile", flavor = H.Flavor.Cuda })
]
```

### Per-substrate model split — container on Linux, daemon on Apple silicon

An inference / ML project that runs as an in-cluster **Container** on Linux but
needs **host-native Metal GPU** access on Apple silicon, which cannot run in a
container. There is **no "multi-substrate" model** — a project that must behave
differently per substrate simply declares a *different model per substrate*:
`Container` for the Linux substrates, `HostDaemon` for `AppleSilicon`. The daemon
gets a system-level LaunchDaemon on `cluster up`; the Linux containers never do.

| Substrate | Model |
|---|---|
| `linux-cpu` | `Container` (`flavor = H.Flavor.Cpu`) |
| `linux-gpu` | `Container` (`flavor = H.Flavor.Cuda`) |
| `apple-silicon` | `HostDaemon` (Tart + Metal) |

```dhall
[ H.entry H.Substrate.LinuxCpu
    (H.Model.Container H.Container::{ dockerfile = "docker/app.Dockerfile", flavor = H.Flavor.Cpu })
, H.entry H.Substrate.LinuxGpu
    (H.Model.Container H.Container::{ dockerfile = "docker/app.Dockerfile", flavor = H.Flavor.Cuda })
, H.entry H.Substrate.AppleSilicon
    ( H.Model.HostDaemon
        H.HostDaemon::{
        , build = H.Build::{ cabal = "cabal install --installdir .build exe:infer", host = H.HostReqs::{ ghc = True, tart = True, metal = True } }
        , daemon = ".build/infer inference --serve"
        }
    )
]
```

You can declare the daemon entry to **fix the contract before the binary
exists** — the Apple-silicon side may still be work-in-progress while the Linux
container side ships and runs today.

### Host-binary cluster manager

A host-native control plane (e.g. a Haskell-built cluster manager) that creates
and owns a local cluster and **installs its own service unit** (such as an RKE2
systemd unit) — so hostbootstrap creates **no** unit for it. On Linux the binary
is built *inside the base container* and extracted to `.build/`, keeping the
toolchain off the host. `cluster up`/`down`/`delete` invoke the `handoff`
commands; the binary reaches in-cluster services over loopback NodePorts only.

| Substrate | Model |
|---|---|
| `linux-cpu` | `HostBinary` (`handoff` up/down/delete; owns its own services) |

```dhall
H.entry H.Substrate.LinuxCpu
  ( H.Model.HostBinary
      H.HostBinary::{
      , build = H.Build::{ cabal = "cabal install --installdir .build --install-method=copy --overwrite-policy=always exe:mgr" }
      , handoff = H.Handoff::{ up = ".build/mgr cluster up", down = ".build/mgr cluster down", delete = Some ".build/mgr cluster delete" }
      }
  )
```

### Projects with their own runtime virtualenv

Some projects (e.g. Python inference adapters) maintain their **own** host-level
`.venv`. hostbootstrap must **never** be installed into that venv — it is
installed as an isolated host CLI app with `pipx` (see
[Installing the CLI](#installing-the-cli)). By the time the project runs, the
tool's job is done; it has no place in the project's runtime environment. This
isolation is the project's responsibility, not something the tool enforces.

---

## Migrating an existing project

Adopting hostbootstrap is mostly *deletion*. Across every pattern above the same
things go away and the same things stay:

**Delete**

* `compose.yaml` — replaced by a `Container` model + `hostbootstrap cluster up`.
* `bootstrap/*.sh` substrate-detection, prereq, and cluster-setup scripts —
  absorbed into `hostbootstrap doctor` (and, for host binaries, into `handoff`).
* The heavy multi-language toolchain layers in your Dockerfile (GHC, Node,
  Python, Playwright, CUDA, …) — now baked into the pulled base image.
* Ad-hoc build/lifecycle shell glue for host binaries and daemons.

**Keep**

* Your own source, and a now-thin Dockerfile that only `FROM`s the base tag and
  runs the project's own build steps.
* The new `hostbootstrap.dhall` (no import line — the CLI injects the schema).
* Your `.data` directory (bind-mounted; the tool never deletes it).
* For host binaries/daemons: the binary's own source, including any service-unit
  logic it installs itself (e.g. an RKE2 systemd unit).
* Any project-local runtime `.venv`, kept isolated from the host tool.

Projects standardizing their Haskell builds should target **GHC 9.12** to match
the single GHC the base image ships.

---

## Command reference

| Command | What it does |
|---|---|
| `hostbootstrap doctor` | Detect substrate; validate + idempotently install host prereqs |
| `hostbootstrap build` | Idempotently build the project artifact for the current substrate |
| `hostbootstrap cluster up` | Bring the whole stack to running (build, then run the container / invoke the binary's `handoff up` / install the daemon unit) |
| `hostbootstrap cluster down` | Tear the cluster down — **never deletes host `.data`** |
| `hostbootstrap cluster delete` | Thorough teardown (cluster + derived state) — still preserves `.data` |
| `hostbootstrap run <cmd…>` | Build if needed, then dispatch to the binary or container per the substrate's model |
| `hostbootstrap base build` | Build a base tag locally (used inside this repo and by downstream `--build-base`) |
| `hostbootstrap base push` | Push a base tag to Docker Hub |

All commands are **idempotent**: re-running on a healthy host is a no-op.

---

## How the base images get built

Versions, download URLs, the architecture string, and the CUDA base image are
all resolved on the host by
[`hostbootstrap/base_image.py`](hostbootstrap/base_image.py) and passed via
`docker build --build-arg`. The Dockerfile
([`docker/basecontainer.Dockerfile`](docker/basecontainer.Dockerfile)) consumes
ARGs only — no `if`/`case`/version probing.

Plain `docker build`. No buildx, no emulation; a build can only ever produce the
host-native arch.

* **Default** for downstream projects: pull the base from Docker Hub.
* **`--build-base`**: build the base locally from this repo's Dockerfile,
  tagging it with the identical name.

---

## Repository layout

```
hostbootstrap/                   # the Python package (flat layout)
  dhall/
    package.dhall                # the typed project-config schema (bundled + CLI-injected)
  cli.py                         # Click entrypoint
  substrate.py                   # apple-silicon | linux-cpu | linux-gpu
  prereqs.py                     # host prereq checks/installers
  spec.py                        # hostbootstrap.dhall → JSON → frozen dataclasses
  dhall_tool.py                  # provision/run native dhall-to-json
  process.py                     # async subprocess wrapper
  docker_ops.py                  # build/run arg-builders + runners
  base_image.py                  # version/URL/CUDA resolvers + build helpers
  units.py                       # system unit (LaunchDaemon / systemd) management
  check_code.py                  # ruff → black → mypy strict
  models/
    container.py
    host_binary.py
    host_daemon.py
docker/
  basecontainer.Dockerfile       # logic-free; all values via ARG
support/
  haskell-deps/                  # warm Cabal store
documents/                       # SSoT documentation tree
stubs/                           # mypy .pyi shims
pyproject.toml                   # Poetry; hostbootstrap + check-code scripts
poetry.toml                      # in-project .venv (dev only)
```

---

## Invariants the tool enforces

* The host `.data` bind mount is preserved across `cluster down` and
  `cluster delete` — neither ever deletes it.
* On Apple Silicon container hosts, production-mode `doctor` enforces the
  headless reboot contract directly: FileVault must be off, Docker must be
  reachable, and Colima must be started by a bootstrapped system LaunchDaemon
  under `/Library/LaunchDaemons`. The plist may use any label as long as it runs
  `colima start -f` / `colima start --foreground` directly or through a wrapper
  script; per-user LaunchAgents are rejected. Development mode keeps Docker
  reachability but skips the FileVault and system-Colima checks.
* In production mode, a system unit is created **if and only if** a substrate
  uses the HostDaemon model. Such units are system-scope (systemd /
  LaunchDaemon), not user-scope LaunchAgents — so they survive a reboot and
  start pre-login (supporting headless remote SSH). Development mode never
  creates or removes HostDaemon units.
* `.build/` exists only for HostBinary / HostDaemon projects and is never
  bind-mounted into a container.

### Downstream guidance (conventions, not enforced)

* Run fourmolu/hlint **inside** the container — invoked by the project's
  Dockerfile against the prebuilt tools the base ships.
* Reach in-cluster services from a host binary over loopback (`127.0.0.0/8`)
  NodePorts only — never off-host.
* **Playwright end-to-end tests run from *outside* the cluster, against its
  gateway** — never from inside a pod. They exercise the deployed stack the same
  way a real client would (the gateway is reached over the loopback NodePort
  above). Playwright and its browsers are **already in the base image**, so no
  project installs them. How the suite is launched follows the substrate's model:
  - **Container** substrates run Playwright **inside the project container** —
    the very image that ships the app already carries the browsers, so the tests
    run there directly.
  - **HostBinary / HostDaemon** substrates have no long-running app container, so
    they launch the suite as a one-shot **`docker run --rm` against the built
    project image** (again reusing the base's bundled Playwright) — pointed at the
    cluster gateway.

See [`documents/README.md`](documents/README.md) for the deep docs.
