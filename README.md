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
Docker Hub and a binary-owned project-local Dhall contract that lets each project binary know where it is
running in the composed topology.

The deep technical material lives under [`documents/`](documents/README.md); the honest, phased
implementation status lives under [`DEVELOPMENT_PLAN/`](DEVELOPMENT_PLAN/README.md). This README is
the orientation layer and points at those canonical homes rather than duplicating them.

## Architecture

`hostbootstrap` splits host management between a Haskell core and a deliberately small Python layer.

- **`hostbootstrap-core` (Haskell)** owns host-tool resolution, the `ensure` reconcilers
  (`docker`, `colima`, `cuda`, `homebrew`, `ghc`, `tart`, each fail-fast on the wrong host), substrate
  detection, the binary-context contract and command gate, cluster-lifecycle semantics with kind resource
  cordoning, and the `optparse-applicative` command tree that project binaries extend through
  `runHostBootstrapCLI progName projectSpec`. See
  [`documents/architecture/hostbootstrap_core_library.md`](documents/architecture/hostbootstrap_core_library.md).
- **The Python bootstrapper** is thin: it does only the **minimum to build the project binary** —
  assert the fail-fast host minimums, ensure the host toolchain prerequisites needed to **build** the
  binary, build it **host-native** into `./.build/`, and exec it. Those host minimums are the **only hard
  fail-fast surface** in the system. Once the binary runs it is **never blocked by an
  absent-but-installable dependency** — the `ensure` suite installs whatever it needs (Docker, incus,
  the cluster tooling, …); the binary, not the bootstrapper, owns Docker, the project container, the
  cordon, the VM, the cluster, the webservice, and teardown. The ownership boundary is described in
  [`documents/architecture/python_haskell_boundary.md`](documents/architecture/python_haskell_boundary.md).
  The self-update command is the bootstrapper's own pipx distribution surface; it is explicit, never
  automatic, and documented in
  [`documents/engineering/self_update.md`](documents/engineering/self_update.md).

`hostbootstrap-core` composes host management as **operations** — `ensure` reconcilers, cluster/deploy
steps, and the **self-reference lift** that crosses an execution-context boundary by re-invoking the
binary's *own* subcommand in a nested context. The VM hop is provider-backed: on Apple Silicon the demo
uses a Lima VM (`limactl shell <instance> -- …`) started without Lima-managed containerd, while native Linux uses an Incus
VM (`incus exec <vm> -- …`). The project-container hop is `docker run --rm <image> …`, whose
`ENTRYPOINT` is the binary. Each nested call runs the same command tree. That nested process is explicit
rather than blind: before normal dispatch, the binary reads the sibling `<project>.dhall` that tells it
which segment of the global composition it occupies. The target model is a context-aware topology in the
Dhall value — an ordered set of execution frames plus the current frame and runtime witnesses — so a copy
of the binary can fail fast when it is not actually running where the Dhall says it is. That context gates
commands, so a cluster service cannot run host-orchestrator verbs, a daemon command cannot start unless
the context declares a daemon/service role, and a kind-cluster workflow cannot be represented as valid
when it is running outside the VM/container frame that minted it. The same algebra expresses both
deployment and runtime business logic (stateless roles over durable external stores). See
[`documents/architecture/composition_methodology.md`](documents/architecture/composition_methodology.md).

> **Current state.** The host-native bootstrapper, self-reference lift, single-representation demo deploy,
> and project-local binary-context command gate are implemented as recorded in
> [`DEVELOPMENT_PLAN/`](DEVELOPMENT_PLAN/README.md). Python now derives the project name from the Cabal
> file and writes no Dhall. Normal command gating reads the context section inside the sibling
> `<project>.dhall`; `config init` and parent child-projection commands generate the host, VM, container,
> and service/daemon local configs. Phases 13, 14, and 15 remain open to harden the context topology:
> the demo lift chooses validated Lima on Apple Silicon and Incus on Linux, but the Dhall/context
> contract is being tightened so the complete arbitrary topology and its runtime witnesses are encoded and
> enforced instead of relying on permissive flat roles.
>
> The host-native build half is implemented: `hostbootstrap/bootstrap.py` derives the project name from
> the Cabal file, asserts minimums, ensures the host build toolchain, builds the binary host-native on
> every substrate, and execs, with no Dhall read/write, Docker-ensure, container build, VM sizing, or
> copy-out. The explicit `hostbootstrap update` command is implemented as the pipx self-update surface
> and is never run automatically by normal commands.

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
4. **Exec the binary**, forwarding the requested command. If the command needs config and
   `./.build/<project>.dhall` is absent, the binary fails fast and points the user to its config
   initialization command.

Ensuring Docker, building the project container, applying the resource cordon, the VM provider, the
cluster lifecycle, the webservice, and teardown are **not** the bootstrapper's job — the execed binary owns
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

## Configuration: Binary-Owned Local Dhall

Configuration is typed Dhall with a strict binary-owned split:

- **Local runtime config — `<project>.dhall`**, read by the project binary from next to its executable.
  It carries user/project settings such as Dockerfile, resources, deploy knobs, and the runtime context
  authority that says which role this copy may perform.
- **Generated child configs — `<project>.dhall` at each child executable location**, produced by a parent
  binary before VM/container/service/daemon handoff. These are narrower projections, not copies of the host
  config.
- **Rich project-level Dhall** (roles, cluster bootstrap), generated by the project binary, which also
  emits its own schema.
- **Per-case test Dhall**, generated by the project binary for each test case.

Python derives the project name from the Cabal file and does not read or write Dhall. The project binary
owns config initialization, context validation, child-config projection, and the richer generated tiers. See
[`documents/engineering/dhall_topology.md`](documents/engineering/dhall_topology.md) and
[`documents/architecture/binary_context_config.md`](documents/architecture/binary_context_config.md).

The host-level `<project>.dhall` generated by a project binary has this top-level shape, with the nested
context fields carrying the role and command authority:

```text
{ dockerfile = "docker/app.Dockerfile"
, resources =
  { cpu = 4
  , memory = "8GiB"
  , storage = "20GiB"
  }
, context = ...
, deploy = { haReplicas = 1 }
}
```

The project value is also the command name. The `resources` budget is the host-level ceiling that the
project binary projects into child configs and enforces through cordons. Before bring-up the binary
verifies that budget against spare host capacity resolved per substrate — resolved `sysctl` on Apple
silicon, `/proc` on Linux. See
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
| `hostbootstrap update` | Explicitly update the pipx-installed Python bootstrapper |
| `hostbootstrap base build` | Cold-rebuild the base image(s) locally (`--no-cache --pull`); no push |
| `hostbootstrap base build-and-push` | Cold-rebuild and push the base image(s) |

Self-update is never run automatically by `doctor`, `build`, `run`, or `base`, and those commands must
not fail just because the wrapper is not at the latest commit.

The `hostbootstrap-core` command tree (exposed by every built binary; project binaries add their own
verbs on top):

| Command | What it does |
|---|---|
| `<binary> ensure <tool>` | Reconcile a single host dependency (`docker`, `colima`, `cuda`, `homebrew`, `ghc`, `tart`); fail-fast on the wrong host |
| `<binary> config init\|path\|schema\|show FILE` | Initialize, locate, inspect, and describe the binary-owned `<project>.dhall` config |
| `<binary> config render` | Emit static typed Dhall artifact examples from the in-scope registry; this is an inspection surface and does not require an active context |
| `<binary> context create vm\|container\|service OUTPUT` | Create a child `<project>.dhall` for a nested binary context after validating the active context |
| `<binary> cluster up\|down\|delete\|status` | Drive the kind/Helm cluster lifecycle from the active context's project, source root, and resource envelope, preserving host `.data` |
| `<binary> test CASE` / `<binary> check-code` | Run the inherited test and code-check surfaces after context validation; failed cases/checks exit non-zero |

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
pipx install "hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@main"
```

Update the pipx app explicitly with:

```bash
hostbootstrap update
```

For local development against a checkout:

```bash
pipx install --force /path/to/hostbootstrap
```

## Demo App

[`demo/`](demo/) is `hostbootstrap-demo`, the worked consumer of `hostbootstrap-core`. It consumes the
core directly (L0-direct, like `mcts`) and extends the core command tree through a
`ProjectSpec` (`demoCommands`, `demoCases`, `demoCheckCode`, `demoArtifacts`), so `hostbootstrap-demo --help` shows the
inherited core verbs (`ensure`, `config`, `cluster`, `test`, `check-code`) plus the demo's own
noun-first verbs (`incus` / `vm` / `harbor` / `web` / `deploy` / `role`) without re-implementing any core verb. It is the
end-to-end exercise of the four-stream additive extension contract: the CLI tree, the schema-gen
registry (`coreArtifacts ++ demoArtifacts`), the test harness (`demoCases` driven by `runMatrix`), and
the binary-owned local config. Its target `hostbootstrap-demo.dhall` budget is the demo's one ceiling —
6 cores, 10 GiB memory, 80 GiB storage — feeding both the VM sizing cordon and the kind-node cap. `vm up`
fails fast below that full-lifecycle floor so the demo does not discover an undersized VM during Docker
layer extraction.

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
| `vm ensure` | `local` | reconciler on metal: Lima VM provider on Apple Silicon, native Incus provider on Linux |
| `vm up` | `local` | the cordon — the VM is the isolation wall |
| `vm pristine-bootstrap` | `local → VM` | host-native build **in** the VM, then the project-image build, **in** the VM |
| `test all` | `inContainer img (inVM vm localContext)` | the **only** lifted compute step |
| `vm down` | `local` | guarded teardown (host `.data` preserved) |

The one lifted compute step folds (per the [self-reference lift](documents/architecture/composition_methodology.md))
to `limactl shell <instance> -- docker run --rm <image> test all` on Apple Silicon and
`incus exec <vm> -- docker run --rm <image> test all` on native Linux. Inside that lifted context the harness runs
`clusterUp` "locally" = on the **VM's Docker** (the mounted socket), so the kind cluster lives **in the
VM**, reached with no second "bring up a cluster" path. The doctrine — one operation, one
representation; the test workflow is a *lifted* operation, not a parallel representation — is stated
canonically in
[`documents/architecture/composition_methodology.md`](documents/architecture/composition_methodology.md).

> **Status.** The single lift sequence remains the supported demo shape. Its Apple Silicon dry-run now
> folds through Lima VM execution rather than an Incus VM. The Lima VM is still a pristine Linux host:
> Docker is installed and verified inside the guest by the project binary, not supplied by Lima's
> containerd setup. Real Lima lifecycle validation passes; the stricter Dhall topology/witness gate is open work in
> [`DEVELOPMENT_PLAN/`](DEVELOPMENT_PLAN/README.md). The earlier Incus real-run remains a historical Linux
> validation point, not proof that Apple Silicon can run the Incus VM path.

### Spin it up

Build and exec the demo binary host-native through the Python bootstrapper, from the demo project root —
the same workflow every consumer follows (assert host minimums → ensure the host toolchain → build into
`./.build/` → exec):

```bash
cd demo
hostbootstrap run -- --help
hostbootstrap run -- config init \
  --output ./.build/hostbootstrap-demo.dhall \
  --source-root "$PWD" \
  --dockerfile docker/Dockerfile \
  --cpu 6 --memory 10GiB --storage 80GiB --ha-replicas 1
hostbootstrap run -- config show ./.build/hostbootstrap-demo.dhall
hostbootstrap run -- config schema
hostbootstrap run -- config render --artifact demoWeb
hostbootstrap run -- deploy --dry-run
```

To build and run the binary directly against the local core (no bootstrapper), use Cabal with the
demo's own workspace:

```bash
cd demo
cabal build                           # builds hostbootstrap-demo against ../core/hostbootstrap-core
cabal run hostbootstrap-demo -- config schema
cabal run hostbootstrap-demo -- config render --artifact budget
```

`demo web serve` is the service-role webserver command. It normally runs inside the chart-launched
service context, whose mounted `hostbootstrap-demo.dhall` authorizes `ServiceCommand`; a host-orchestrator
config should reject it. `demo web bridge` remains the host-side config-generation command for
PureScript-bridge output. The integrated VM/cluster lifecycle is **not** a separate chain of verbs: it is
the single `demo deploy` lift sequence above, whose one lifted compute step (`test all`) carries cluster
bring-up, web-serve, and e2e **inside** the harness in the VM. The `incus`/`vm` verbs are the metal-side
cordon steps of that one sequence, documented in the runbook.

### Run its test suite

The demo carries two test layers:

- **Haskell harness** — `hostbootstrap-demo test all` drives `runMatrix` over the demo's case matrix
  (`pristine-bootstrap` / `web-build` / `e2e-tabs`; a single case runs with
  `hostbootstrap-demo test <case>`), each
  case bringing up an isolated per-case kind cluster in `seamSetup` and tearing it down in
  `seamTeardown` (guaranteed via `finally`, preserving host `.data`). The harness is the **one**
  representation of this work and the lift target — it invokes `clusterUp` as `HostConfig -> IO ()`
  "locally", with no `LiftContext` of its own. In the supported shape the harness is reached **only** as the
  single lifted compute step of `demo deploy` (`limactl shell <instance> -- docker run --rm <image> test all`
  on Apple Silicon, `incus exec <vm> -- docker run --rm <image> test all` on Linux), so `clusterUp` runs
  on the VM's Docker and the kind cluster lives in the VM. The per-case bodies
  (`pristine-bootstrap` a live cluster, `e2e-tabs` the project image's base-provided Playwright runtime
  against the in-cluster webservice via its NodePort, `web-build` the `spago`/`esbuild` bundle) come up on the **VM's** Docker
  when run via `demo deploy`; direct host invocation is a development smoke, not the authoritative deploy
  context. The context-topology hardening now being tracked will make illegal direct-host representations
  fail before cluster creation. The cases bind to the inherited `test` verb (the harness extension stream).
  These seams need Docker + kind, so the supported end-to-end path is the lifted step of `demo deploy`:

  ```bash
  cd demo
  hostbootstrap run -- test all        # or: cabal run hostbootstrap-demo -- test all
  ```

- **Playwright e2e** — [`demo/playwright/`](demo/playwright/) is source/config only. The supported
  runner is the already-built `hostbootstrap-demo:local` project image, which inherits the base image's
  global Playwright install and browser cache (`/ms-playwright`). The `e2e-tabs` harness case starts that
  same project image on the kind Docker network, sets `BASE_URL` to the in-cluster NodePort service, sets
  `NODE_PATH` to the base image's global npm package directory so `@playwright/test` resolves, and runs
  `playwright test`. It does not pull `mcr.microsoft.com/playwright:*`, run `npm install`, or use `npx`
  during validation.

See the [feature-to-harness-case table](documents/operations/demo_runbook.md#feature-to-harness-case-table)
in the runbook for which case proves which slice of the surface.

## Repository Map

This map reflects the implemented shape: the Haskell `hostbootstrap-core` library and the bare-binary
`app/` alongside the thin Python bootstrapper. Current phase status is tracked in
[`DEVELOPMENT_PLAN/`](DEVELOPMENT_PLAN/README.md).

```text
.
├── core/
│   ├── cabal.project                 # self-contained Cabal workspace (pins GHC; lists hostbootstrap-core)
│   ├── hostbootstrap-core/           # Haskell core package
│   │   ├── hostbootstrap-core.cabal
│   │   ├── src/HostBootstrap/        # host-tool resolution, ensure reconcilers,
│   │   │   │                         #   substrate detection, project-local Dhall config,
│   │   │   │                         #   cluster lifecycle, command tree
│   │   │   ├── HostTool.hs  HostConfig.hs  HostPrereqs.hs  Substrate.hs
│   │   │   ├── Ensure.hs  Ensure/    # Docker, Colima, Cuda, Homebrew, Ghc, Tart
│   │   │   ├── Config/Schema.hs      # project-local Dhall config schema/defaults
│   │   │   ├── Cluster/              # Lifecycle.hs, Cordon.hs
│   │   │   ├── Command.hs  CLI.hs    # core command tree + ProjectSpec entrypoint
│   │   │   └── DocValidator.hs
│   │   ├── app/Main.hs               # bare hostbootstrap binary (core tree, no project commands)
│   │   ├── dhall/                    # Core.dhall vocabulary + config schema artifacts
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
