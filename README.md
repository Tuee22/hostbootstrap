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

`hostbootstrap-core` composes host management as **operations** — `ensure` reconcilers, cluster/deploy
steps, and the **self-reference lift** that crosses an execution-context boundary by re-invoking the
binary's *own* subcommand in a nested context (`incus exec <vm> -- <pb> …` for a VM,
`docker run --rm <image> …` for the project container, whose `ENTRYPOINT` is the binary). Each nested
call runs the same command tree, so a step runs "locally", unaware it was lifted — which is why
`helm`/`kind` resolve on the container `$PATH` rather than the host. The same algebra expresses both
deployment and runtime business logic (stateless roles over durable external stores). See
[`documents/architecture/composition_methodology.md`](documents/architecture/composition_methodology.md).

> **Current state.** The thin, host-native bootstrapper described in this README is **implemented**:
> `hostbootstrap/bootstrap.py` is the four-step pre-binary path (assert minimums → ensure the host
> build toolchain → build the binary host-native on every substrate → exec), with no Docker-ensure,
> container build, VM sizing, or copy-out. The host-management library — the `ensure` install-and-verify
> suite, the applied budget cordon, the standardized harness, and the incus host-provider — is
> implemented and unit-tested, and the **self-reference lift** (`HostBootstrap.Lift`) and the composition
> methodology have landed. Phases 5, 10, 11, 13, and 14 are `Active`: the remaining work is real-run-gated
> — the demo wiring the lift end-to-end, **real per-case test seams** (the current `demoSeams` are a
> hollow placeholder that assert only cluster existence), and the new `deploy --dry-run` / `role` verbs —
> tracked in [`DEVELOPMENT_PLAN/`](DEVELOPMENT_PLAN/README.md).

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
| `hostbootstrap build` | Run the bootstrap — build the project binary host-native into `./.build/`; no exec |
| `hostbootstrap run [args...]` | Build idempotently, then exec the project binary with `args` |
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
pipx install "git+https://github.com/tuee22/hostbootstrap.git#egg=hostbootstrap"
```

For local development against a checkout:

```bash
pipx install --force /path/to/hostbootstrap
```

## Demo App

[`demo/`](demo/) is `hostbootstrap-demo`, the worked consumer of `hostbootstrap-core`. It consumes the
core directly (L0-direct, like `mcts`) and extends the core command tree through
`runHostBootstrapCLI "hostbootstrap-demo" demoCommands`, so `hostbootstrap-demo --help` shows the
inherited core verbs (`ensure`, `config`, `cluster`, `test`, `check-code`) plus the demo's own
noun-first verbs (`incus` / `vm` / `harbor` / `web` / `deploy` / `role`) without re-implementing any core verb. It is the
end-to-end exercise of the four-stream additive extension contract: the CLI tree, the schema-gen
registry (`coreArtifacts ++ demoArtifacts`), the test harness (`demoCases` driven by `runMatrix`), and
the static-base config. Its static-base budget (`demo/hostbootstrap.dhall`) is the demo's one ceiling —
6 cores, 10 GiB memory, 80 GiB storage — feeding both the VM sizing cordon and the kind-node cap.

### The single lift sequence

The demo's end-to-end deploy is **one explicit lift sequence**, not a parallel chain that re-expresses
cluster bring-up, Harbor, web-serve, and e2e alongside the harness. There is **one operation, one
representation**: the standardized test harness (`HostBootstrap.Harness`: `runMatrix` + the per-case
`Seams`) is the context-agnostic test engine that brings up an isolated per-case environment, runs the
case body, and tears it down. It invokes its reconcilers (`clusterUp`, …) as `HostConfig -> IO ()`
"locally", unaware of any enclosing context — so the harness is a **lift target**, not a lift-aware
component, and carries no `LiftContext` of its own. Re-expressing the same work as a separate chain of
lifted ops would be a **redundant representation** that duplicates the harness (and double-creates
clusters when it lifts a harness case). The single canonical chain `demo deploy` is:

| Step | Context | Role |
|---|---|---|
| ensure incus | `local` | reconciler on metal |
| `vm up` | `local` | the cordon — the VM is the isolation wall |
| `vm pristine-bootstrap` | `local → VM` | host-native build **in** the VM, then the project-image build, **in** the VM |
| `test all` | `inContainer img (inVM vm localContext)` | the **only** lifted compute step |
| `vm down` | `local` | guarded teardown (host `.data` preserved) |

The one lifted compute step folds (per the [self-reference lift](documents/architecture/composition_methodology.md))
to `incus exec <vm> -- docker run --rm <image> test all`. Inside that lifted context the harness runs
`clusterUp` "locally" = on the **VM's Docker** (the mounted socket), so the kind cluster lives **in the
VM**, reached with no second "bring up a cluster" path. The doctrine — one operation, one
representation; the test workflow is a *lifted* operation, not a parallel representation — is stated
canonically in
[`documents/architecture/composition_methodology.md`](documents/architecture/composition_methodology.md).

> **Status — live-validated.** `demo deploy` as the single lift sequence above is implemented and validated
> on a real host: the literal `demo deploy` apply runs `ensure incus -> vm up -> pristine[#2+#3] -> lifted
> test all (3/3) -> vm down` clean, with the kind cluster on the **VM's Docker** (poller-confirmed in the
> VM, none on metal). The earlier metal-host in-container runs were a dev shortcut, superseded by the in-VM
> lift. See [`DEVELOPMENT_PLAN/`](DEVELOPMENT_PLAN/README.md) (Phase 13 Sprint 13.12). The two entry points
> below are the parts you run directly.

### Spin it up

Build and exec the demo binary host-native through the Python bootstrapper, from the demo project root —
the same workflow every consumer follows (assert host minimums → ensure the host toolchain → build into
`./.build/` → exec):

```bash
cd demo
hostbootstrap run -- --help           # inherited core verbs + the demo's incus/vm/harbor/web verbs
hostbootstrap run -- web schema       # the L0 + demo schema union (coreArtifacts ++ demoArtifacts)
hostbootstrap run -- web serve        # serve the warp/wai webservice + Halogen SPA on :8080
```

To build and run the binary directly against the local core (no bootstrapper), use Cabal with the
demo's own workspace:

```bash
cd demo
cabal build                           # builds hostbootstrap-demo against ../core/hostbootstrap-core
cabal run hostbootstrap-demo -- web serve
```

`demo web serve` brings up the webservice that `demo web bridge` (PureScript-bridge type generation) and
the Playwright e2e target against. The integrated VM/cluster lifecycle is **not** a separate chain of
verbs: in the target shape it is the single `demo deploy` lift sequence above, whose one lifted compute
step (`test all`) carries cluster bring-up, web-serve, and e2e **inside** the harness in the VM. The
`incus`/`vm` verbs are the metal-side cordon steps of that one sequence, documented in the runbook.

### Run its test suite

The demo carries two test layers:

- **Haskell harness** — `demo test all` drives `runMatrix` over the demo's case matrix
  (`pristine-bootstrap` / `web-build` / `e2e-tabs`; a single case runs with `demo test <case>`), each
  case bringing up an isolated per-case kind cluster in `seamSetup` and tearing it down in
  `seamTeardown` (guaranteed via `finally`, preserving host `.data`). The harness is the **one**
  representation of this work and the lift target — it invokes `clusterUp` as `HostConfig -> IO ()`
  "locally", with no `LiftContext` of its own. In the target shape the harness is reached **only** as the
  single lifted compute step of `demo deploy` (`incus exec <vm> -- docker run --rm <image> test all`), so
  `clusterUp` runs on the VM's Docker and the kind cluster lives in the VM. The per-case bodies
  (`pristine-bootstrap` a live cluster, `e2e-tabs` a Playwright container against the in-cluster
  webservice via its NodePort, `web-build` the `spago`/`esbuild` bundle) come up on the **VM's** Docker
  when run via `demo deploy` (live-validated, `3/3`); they can also be invoked directly on the metal host
  for a quick local check. The cases bind to the inherited `test` verb (the harness extension stream). These seams need Docker + kind,
  so they run inside the demo VM / project container — invoked directly for a local check, or as the
  lifted step of `demo deploy` end-to-end:

  ```bash
  cd demo
  hostbootstrap run -- test all        # or: cabal run hostbootstrap-demo -- test all
  ```

- **Playwright e2e** — [`demo/playwright/`](demo/playwright/) drives the served surface (the SPA tabs
  render and `/api/budget` returns the `fitsBudget` view). It targets the webservice the `demo/chart`
  deployment publishes — the in-cluster NodePort in a real run, `http://localhost:8080` against a manual
  `demo web serve` locally (override with `BASE_URL`):

  ```bash
  cd demo/playwright
  npm install
  npx playwright install --with-deps
  npx playwright test                  # BASE_URL=http://host:8080 npx playwright test to retarget
  ```

See the [feature-to-harness-case table](documents/operations/demo_runbook.md#feature-to-harness-case-table)
in the runbook for which case proves which slice of the surface.

## Repository Map

This map reflects the **target shape**: the Haskell `hostbootstrap-core` library and the bare-binary
`app/` alongside the shrunk Python bootstrapper. The phased migration from the current
all-Python layout to this shape is tracked in [`DEVELOPMENT_PLAN/`](DEVELOPMENT_PLAN/README.md).

```text
.
├── core/
│   ├── cabal.project                 # self-contained Cabal workspace (pins GHC; lists hostbootstrap-core)
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
│   └── warm-deps/                    # warm Cabal store package
├── demo/                             # hostbootstrap-demo: the worked L0-direct consumer
│   └── cabal.project                 # the consumer's own workspace (builds against core/hostbootstrap-core)
├── pyproject.toml                   # Poetry project: the hostbootstrap CLI distribution
├── hostbootstrap/                   # thin Python bootstrapper (pre-binary: minimums → toolchain → build → exec)
├── stubs/   tests/                  # mypy stubs + pytest suite
├── docker/basecontainer.Dockerfile
├── documents/                        # canonical documentation tree
└── DEVELOPMENT_PLAN/                 # phased implementation status
```

## License

MIT. See [LICENSE](LICENSE).
