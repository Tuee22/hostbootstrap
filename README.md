# hostbootstrap

**Status**: Governed orientation document
**Supersedes**: prior root README without metadata
**Canonical homes**: [documents/README.md](documents/README.md), [DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md), [documents/architecture/hostbootstrap_core_library.md](documents/architecture/hostbootstrap_core_library.md)

> **Purpose**: Orient new readers and consumers (`daemon-substrate`, `infernix`, `jitML`, `mcts`)
> to the shape, scope, and intent of the host-management layer, and point at the canonical homes for
> documentation and development planning.

`hostbootstrap` is the reusable host-management layer for the project family. It is a Haskell
`hostbootstrap-core` library plus a thin Python bootstrapper that together replace per-project
bootstrap shells and redundant multi-language Dockerfiles with one shared toolchain pulled from
Docker Hub and one declarative, typed `hostbootstrap.dhall` per project.

The deep technical material lives under [`documents/`](documents/README.md); the honest, phased
implementation status lives under [`DEVELOPMENT_PLAN/`](DEVELOPMENT_PLAN/README.md). This README is
the orientation layer and points at those canonical homes rather than duplicating them.

## Architecture

`hostbootstrap` splits host management between a Haskell core and a deliberately small Python layer.

- **`hostbootstrap-core` (Haskell)** owns host-tool resolution, the `ensure` reconcilers
  (`docker`, `colima`, `cuda`, `homebrew`, `ghc`, `tart`, each fail-fast on the wrong host), substrate
  detection, the static-base-Dhall decoder, cluster-lifecycle semantics with kind resource cordoning, and
  the `optparse-applicative` command tree that project binaries extend through
  `runHostBootstrapCLI progName projectCommands`. See
  [`documents/architecture/hostbootstrap_core_library.md`](documents/architecture/hostbootstrap_core_library.md).
- **The Python bootstrapper** is thin: it does only the **minimum to build the project binary** —
  assert the fail-fast host minimums, ensure the host toolchain prerequisites needed to **build** the
  binary, build it **host-native** into `./.build/`, and exec it. Those host minimums are the **only
  hard fail-fast surface** in the system. Once the binary runs it is **never blocked by an
  absent-but-installable dependency** — the `ensure` suite installs whatever it needs (Docker, incus,
  the cluster tooling, …); the binary, not the bootstrapper, owns Docker, the project container, the
  cordon, the VM, the cluster, the webservice, and teardown. The ownership boundary is described in
  [`documents/architecture/python_haskell_boundary.md`](documents/architecture/python_haskell_boundary.md).

> **Current state.** The thin, host-native bootstrapper described in this README is **implemented**:
> `python/hostbootstrap/bootstrap.py` is the four-step pre-binary path (assert minimums → ensure the host
> build toolchain → build the binary host-native on every substrate → exec), with no Docker-ensure,
> container build, VM sizing, or copy-out. The host-management library — the `ensure` install-and-verify
> suite, the applied budget cordon, the standardized harness, and the incus host-provider — is
> implemented and unit-tested; the layered warm store (Phase 12) and the demo's live in-VM run
> (Phase 13) are the remaining infra-gated work, tracked in
> [`DEVELOPMENT_PLAN/`](DEVELOPMENT_PLAN/README.md).

Each consuming project ships **one binary** that extends `hostbootstrap-core` with its own
subcommands. The bare `hostbootstrap` binary is `hostbootstrap-core`'s own executable — the same
entrypoint with no project commands — so the core verbs behave identically everywhere. Like every
project binary it is built **host-native**; it is not baked into the base image.

## Bootstrap Flow

The Python bootstrapper does only what must run **before any project binary exists** — a short,
fail-fast sequence:

1. **Assert host minimums.** On Linux: Ubuntu 24.04 and passwordless `sudo`. On Apple: passwordless
   `sudo`, the Xcode Command Line Tools, and Homebrew. Missing minimums stop the run with a clear
   message; the bootstrapper does not attempt to install them.
2. **Ensure the host build toolchain.** The prerequisites needed to build the binary host-native — on
   Apple, Homebrew → `ghcup` → GHC/Cabal; the equivalent on Linux.
3. **Build the project binary host-native** into `./.build/<project>`. The build is the same on every
   substrate; the binary is never copied out of a container, because a Linux ELF cannot exec on a
   general host such as Apple silicon.
4. **Exec the binary**, forwarding the requested command.

Ensuring Docker, building the project container, applying the resource cordon, the cluster lifecycle,
the incus VM, the webservice, and teardown are **not** the bootstrapper's job — the execed binary owns
them. The binary is **never blocked by a dependency that simply isn't installed**: that is the whole
purpose of the `ensure` suite (install-and-verify), and the host minimums in step 1 are the **only** hard
fail-fast surface in the system. See
[`documents/engineering/ensure_reconcilers.md`](documents/engineering/ensure_reconcilers.md).

## Build And Run Model

The host binary is built **host-native** on every substrate — the same way everywhere — because a
Linux ELF cannot exec on a general host such as Apple silicon, so there is no build-in-container,
copy-out path:

- The Python bootstrapper ensures the host toolchain (on Apple, `ghcup` via Homebrew; the equivalent
  on Linux), builds the binary host-native into `./.build/<project>`, and execs it.
- **Tart is build-only** on Apple (Swift/Metal build environments) and is never a runtime.

The base image bakes **no** `hostbootstrap` binary — a Linux ELF cannot run on Apple silicon, so it
could not be copied out to every host. Instead the base image warms `hostbootstrap-core`'s
dependencies into the frozen Cabal store so every project's host-native binary build hits the warm
store. The project **container** the binary later builds (`FROM` the base) hits the same store. See
[`documents/architecture/build_and_run_model.md`](documents/architecture/build_and_run_model.md).

## Configuration: Three-Tier Dhall

Configuration is typed Dhall in three tiers:

- **Tier 1 — the static-base `hostbootstrap.dhall`**, read by the Python bootstrapper. It declares only
  the project name, its Dockerfile, and a resource budget.
- **Tier 2 — the rich project-level Dhall** (roles, cluster bootstrap), generated by the project
  binary, which also emits its own schema.
- **Tier 3 — the per-case test Dhall**, generated by the project binary for each test case.

Python reads only the static-base tier; the project binary owns the richer tiers. See
[`documents/engineering/dhall_topology.md`](documents/engineering/dhall_topology.md).

The static-base `hostbootstrap.dhall` at a project root looks like this:

```dhall
{ project = "app"
, dockerfile = "docker/app.Dockerfile"
, resources =
  { cpu = 4
  , memory = "8GiB"
  , storage = "20GiB"
  }
}
```

The `project` value is also the command name. The `resources` budget is the ceiling the **project
binary** enforces once running — sizing the per-project Colima VM on Apple, capping the kind nodes on
Linux. The Python bootstrapper reads the static-base config only to learn the `project` name it builds
and execs host-native; it does not size any VM or interpret the budget. See
[`documents/engineering/resource_budgeting.md`](documents/engineering/resource_budgeting.md).

## CLI Surface

Two programs share the `hostbootstrap` name: the **pipx-installed Python bootstrapper** (the host CLI
you install and run) and the **`hostbootstrap-core` command tree** that every built binary — the
bare `hostbootstrap` binary and each project binary — exposes.

The Python bootstrapper (installed with `pipx install …`):

| Command | What it does |
|---|---|
| `hostbootstrap doctor` | Detect the host and assert the fail-fast host minimums for the detected substrate |
| `hostbootstrap up [args...]` | Run the bootstrap — build the project binary into `./.build/`, then exec it with `args` |
| `hostbootstrap base build` | Cold-rebuild the base image(s) locally (`--no-cache --pull`); no push |
| `hostbootstrap base build-and-push` | Cold-rebuild and push the base image(s) |

The `hostbootstrap-core` command tree (exposed by every built binary; project binaries add their own
verbs on top):

| Command | What it does |
|---|---|
| `<binary> ensure <tool>` | Reconcile a single host dependency (`docker`, `colima`, `cuda`, `homebrew`, `ghc`, `tart`); fail-fast on the wrong host |
| `<binary> config show <FILE>` | Decode a static-base `hostbootstrap.dhall` and print its fields |
| `<binary> cluster up\|down\|delete <FILE>` | Drive the kind/Helm cluster lifecycle within the cordoned budget, preserving host `.data` |

These core verbs behave identically whether invoked through the bare `hostbootstrap` binary or a
project binary. See
[`documents/architecture/hostbootstrap_core_library.md`](documents/architecture/hostbootstrap_core_library.md)
for the command-tree extension contract.

## Installing The CLI

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

Then install `hostbootstrap` as an isolated host CLI app:

```bash
pipx install "git+https://github.com/tuee22/hostbootstrap.git#subdirectory=python&egg=hostbootstrap"
```

For local development against a checkout:

```bash
pipx install --force /path/to/hostbootstrap/python
```

## Repository Map

This map reflects the **target shape**: the Haskell `hostbootstrap-core` library and the bare-binary
`app/` alongside the shrunk Python bootstrapper. The phased migration from the current
all-Python layout to this shape is tracked in [`DEVELOPMENT_PLAN/`](DEVELOPMENT_PLAN/README.md).

```text
.
├── haskell/
│   ├── hostbootstrap-core/           # Haskell core package
│   │   ├── hostbootstrap-core.cabal
│   │   ├── src/HostBootstrap/        # host-tool resolution, ensure reconcilers,
│   │   │   │                         #   substrate detection, static-base-Dhall decoder,
│   │   │   │                         #   cluster lifecycle, command tree
│   │   │   ├── HostTool.hs  HostConfig.hs  HostPrereqs.hs  Substrate.hs
│   │   │   ├── Ensure.hs  Ensure/    # Docker, Colima, Cuda, Homebrew, Ghc, Tart
│   │   │   ├── Config/Schema.hs      # static-base-Dhall decoder
│   │   │   ├── Cluster/              # Lifecycle.hs, Cordon.hs
│   │   │   ├── Command.hs  CLI.hs    # core command tree + runHostBootstrapCLI
│   │   │   └── DocValidator.hs
│   │   ├── app/Main.hs               # bare hostbootstrap binary (core tree, no project commands)
│   │   ├── dhall/                    # static-base schema (Type.dhall, Core.dhall) + example.dhall
│   │   └── test/                     # tasty suite (incl. the documentation validator)
│   └── haskell-deps/                 # warm Cabal store package
├── demo/                             # hostbootstrap-demo: the worked L0-direct consumer
├── python/
│   ├── pyproject.toml
│   ├── hostbootstrap/                # thin Python bootstrapper (pre-binary: minimums → toolchain → build → exec)
│   ├── stubs/   tests/
│   └── README.md
├── cabal.project                     # pins GHC; points at haskell/hostbootstrap-core
├── docker/basecontainer.Dockerfile
├── documents/                        # canonical documentation tree
└── DEVELOPMENT_PLAN/                 # phased implementation status
```

## License

MIT. See [LICENSE](LICENSE).
