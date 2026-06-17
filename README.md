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

A project's deploy is **not a sequence of noun verbs** — it is a pure value. Each project contributes a
`chain :: RootConfig -> [Step]` function, and that `[Step]` **is the project's identity**: the ordered
list of host-management and workload steps that bring the project up. There is one representation of that
work (single representation, §W). The single lifecycle command `<binary> project init|up|down|destroy`
**interprets the chain recursively**. Each frame transition is the same **fractal bootstrap** — provision
the frame, build the project binary (the "pb") in it, then hand off `pb project up` into that frame so the
child pb owns its own segment of the chain. The Python bootstrapper is simply the **metal-frame instance**
of that pattern (provision the host frame → build the pb host-native → hand off to the binary), with the
VM and project-container frames descending the same way until recursion bottoms out at the container pb
running kind/Helm leaves.

The VM hop is provider-backed: on Apple Silicon the demo uses a Lima VM (`limactl shell <instance> -- …`)
started without Lima-managed containerd, while native Linux uses an Incus VM (`incus exec <vm> -- …`). The
project-container hop is `docker run --rm <image> …`, whose `ENTRYPOINT` is the binary. Each descent
runs the same `project up` interpreter over the same chain.

The sibling `<project>.dhall` carries **parameters + context + witness** — never the chain shape. It
records the project's tuned parameters, which segment of the global composition this frame occupies, and
the runtime witnesses for the current frame. Because the chain shape lives in code and only its parameters
live in Dhall, a copy of the binary can **fail fast** when it is not actually running in the frame its
`.dhall` describes — a cluster-frame binary cannot run host-orchestrator steps, and a kind-cluster workflow
cannot be represented as valid outside the VM/container frame that minted it. The same algebra expresses
both deployment and runtime business logic (stateless roles over durable external stores). When a nested
context needs to pull from Docker Hub, the host binary forwards its Docker Hub login down the lift to
authenticate the pull — an effect-only capability that is never in Dhall, never persisted, and never in
`argv` (see
[`documents/engineering/registry_credentials.md`](documents/engineering/registry_credentials.md)). See
[`documents/architecture/composition_methodology.md`](documents/architecture/composition_methodology.md).

> **Current state.** Phases 0–15 are built and validated end to end by a real Apple Silicon Lima run
> (`3/3 passed`, including the Playwright e2e case), as recorded in
> [`DEVELOPMENT_PLAN/README.md`](DEVELOPMENT_PLAN/README.md). The host-native bootstrapper, the
> self-reference lift primitive, the single-representation demo deploy, and the project-local
> binary-context command gate are implemented; Python derives the project name from the Cabal file and
> writes no Dhall; lifted runtime containers receive parent-mounted configs with topology frames and
> witnesses.
>
> The "chain is the project" refactor — the recursive `project init|up|down|destroy` lifecycle command and
> the `chain :: RootConfig -> [Step]` interpreter described above — is the **target architecture and is in
> progress, not yet implemented**. Phases 4, 5, 10, 13, 14, and 15 are reopened (`Active`) and phases 16–17
> are added to carry it (see
> [`DEVELOPMENT_PLAN/README.md`](DEVELOPMENT_PLAN/README.md)). Today's implemented command surface is the
> flat verbs — `ensure`, `config`, `context create`, `cluster`, `test`, plus the demo's `vm`/`deploy`.

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

The `hostbootstrap-core` command surface (exposed by every built binary; the project's primary CLI
contribution is its chain value, not noun verbs):

| Command | What it does |
|---|---|
| `<binary> project init` | Write the root `<project>.dhall` (host-orchestrator, no parent); fail-fast unless a fresh host-level binary with no sibling `.dhall`; takes optional `--cpu/--memory/--storage/--ha-replicas` |
| `<binary> project up` | Recursively interpret `chain rootCfg` from the current frame; idempotent (reconcile-to-running); `--dry-run` renders the chain instead of running it |
| `<binary> project down` | Stop the services/clusters/VMs the chain spun up (incus/limactl **stop**) without deleting anything |
| `<binary> project destroy` | Stop, then delete everything brought up; host `.data` is always preserved |
| `<binary> context` | Read-only: introspect the sibling `.dhall` and render the global lift composition with the **current frame highlighted** (absorbs `config show/schema/render`) |
| `<binary> test init` | With an existing `project.dhall`, write `test.dhall` (may carry test-specific config) |
| `<binary> test run <suite>\|all` | Root-gated, decoupled from deploy; run one suite or `all` (always a suite) against the live stack; fail-fast otherwise |
| `<binary> check-code` | Run the inherited code-check surface; failed checks exit non-zero |
| `<binary> ensure <tool>` | **Hidden debug** surface that reconciles a single host dependency (`docker`, `colima`, `cuda`, `homebrew`, `ghc`, `tart`); normally invoked as a chain step within `project up` |

These core verbs behave identically whether invoked through the bare `hostbootstrap` binary or a
project binary. The above is the **target** surface; today's implemented surface is the flat verbs
(`ensure`, `config`, `context create`, `cluster`, `test`, plus the demo's `vm`/`deploy`) — see
[`DEVELOPMENT_PLAN/README.md`](DEVELOPMENT_PLAN/README.md) and the "Current state" note in the
Architecture section above. See
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
core directly (L0-direct, like `mcts`) and contributes its own `chain :: RootConfig -> [Step]` value plus
the step actions, test suites, and Dhall vocabulary that go with it, so the **demo's deploy is its chain**
— interpreted by the single `project up` lifecycle command rather than a tree of noun verbs. It is the
end-to-end exercise of the four-stream additive extension contract: the lift chain (`[Step]` = core host
steps + the demo's workload steps), the schema-gen registry (`coreArtifacts ++ demoArtifacts`), the test
suites, and the binary-owned local config. Its target `hostbootstrap-demo.dhall` budget is the demo's one
ceiling — 6 cores, 10 GiB memory, 80 GiB storage — feeding both the VM sizing cordon and the kind-node
cap. The deploy-VM step fails fast below that full-lifecycle floor so the demo does not discover an
undersized VM during Docker layer extraction.

### The demo chain

The demo's end-to-end deploy is **one chain value**, not a parallel set of verbs that re-express cluster
bring-up, Harbor, web-serve, and e2e. There is **one operation, one representation** (single
representation, §W): the ordered `[Step]` chain is THE representation, and the standardized test harness
stays the one test-engine / lift-target. The chain interleaves core host-management steps with the demo's
contributed workload steps, and `project up` interprets it recursively:

| # | Step | Frame | Role |
|---|---|---|---|
| 1 | host-pb | host (metal) | provision the host frame, build the pb, hand off `pb project up` (the Python bootstrapper's metal-frame instance) |
| 2 | deploy VM | host → VM | Lima VM on Apple Silicon, Incus VM on Linux — the cordon / isolation wall |
| 3 | copy source + ensure GHC in VM | VM | stage the source into the VM and reconcile the GHC toolchain there |
| 4 | build pb in VM | VM | build the project binary host-native **in** the VM |
| 5 | ensure docker in VM | VM | reconcile Docker inside the guest (not supplied by Lima's containerd) |
| 6 | build image | VM | build the project container image on the VM's Docker |
| 7 | deploy kind | VM → container | bring up the kind cluster on the VM's Docker |
| 8 | deploy harbor | container | the demo's workload step: stand up the in-cluster Harbor registry |
| 9 | launch web | container | the demo's workload step: launch the webservice |
| 10 | expose NodePort | container → host | the demo's workload step: expose the NodePort back to the host |

Steps 1–7 are core step kinds (deploy-VM, copy-source, ensure-X, build-pb, build-image, deploy-kind);
steps 8–10 are the demo's contributed step kinds (deploy-harbor, launch-web, expose-port) — host and
workload steps interleave freely in the same `[Step]`. The recursive interpreter folds each frame
transition through the [self-reference lift](documents/architecture/composition_methodology.md) so kind,
Harbor, and the webservice run **in the VM** on the VM's Docker, reached with no second "bring up a
cluster" path. The doctrine is stated canonically in
[`documents/architecture/composition_methodology.md`](documents/architecture/composition_methodology.md).

> **Status.** This `[Step]` chain interpreted by `project up` is the **target** demo shape and is not yet
> implemented — today the demo runs the flat `deploy`/`vm` verbs against the hand-written deploy chain
> (`demo/src/HostBootstrapDemo/Chain.hs`). That flat shape is validated by the full real Apple Silicon Lima
> lifecycle — it brought up the cordon VM, ran the host-native build and the project-image build in the
> VM, lifted `test all` with the per-case kind clusters on the VM's Docker, reported `3/3 passed` including
> the Playwright e2e case, and tore the VM down behind the guard. The Incus real-run remains a historical
> Linux validation point. The migration of that hand-written chain to a core-interpreted `[Step]` value is
> tracked under the reopened phases and phases 16–17.

### Spin it up

Build and exec the demo binary host-native through the Python bootstrapper, from the demo project root —
the same workflow every consumer follows (assert host minimums → ensure the host toolchain → build into
`./.build/` → exec). In the **target** shape the whole lifecycle is the recursive `project` command over
the demo's chain:

```bash
cd demo
hostbootstrap run -- project init \
  --cpu 6 --memory 10GiB --storage 80GiB --ha-replicas 1
hostbootstrap run -- project up --dry-run   # renders chain rootCfg without running it
hostbootstrap run -- project up             # interprets the chain recursively, brings up the stack
hostbootstrap run -- context                # render the lift composition, current frame highlighted
hostbootstrap run -- test run all           # root-gated suite against the live project up stack
hostbootstrap run -- project destroy        # stop then delete; host .data preserved
```

That `project`/`context`/`test run` surface is the **target**; today the demo drives the flat verbs
(`config init`, `config show/schema/render`, `deploy --dry-run`, `deploy`, `vm`) — see
[`DEVELOPMENT_PLAN/README.md`](DEVELOPMENT_PLAN/README.md). To build and run the binary directly against
the local core (no bootstrapper), use Cabal with the demo's own workspace:

```bash
cd demo
cabal build                           # builds hostbootstrap-demo against ../core/hostbootstrap-core
cabal run hostbootstrap-demo -- context
```

`demo web serve` is the service-role webserver command. It normally runs inside the chart-launched
service context, whose mounted `hostbootstrap-demo.dhall` authorizes `ServiceCommand`; a host-orchestrator
config should reject it. In the target model the integrated VM/cluster lifecycle is **not** a separate
chain of verbs: it is the demo's contributed `[Step]` chain above, interpreted recursively by
`project up`, whose frame transitions carry cluster bring-up, Harbor, web, and the NodePort **inside** the
VM. The deploy-VM step is the metal-side cordon step of that one chain, documented in the runbook.

### Run its test suite

The test surface is **decoupled from deploy** in the target model: `test run all` is root-gated and
validates the live `project up` stack, rather than deploy carrying the harness as a lifted step. The demo
carries two test layers:

- **Haskell harness** — `hostbootstrap-demo test run all` drives the demo's case matrix
  (`pristine-bootstrap` / `web-build` / `e2e-tabs`; a single suite runs with
  `hostbootstrap-demo test run <suite>`), each case bringing up an isolated per-case kind cluster in setup
  and tearing it down in teardown (guaranteed via `finally`, preserving host `.data`). The harness remains
  the **one** test-engine and lift target — it invokes `clusterUp` as `HostConfig -> IO ()` "locally", with
  no `LiftContext` of its own. Run against the live stack, `clusterUp` runs on the VM's Docker and the
  per-case kind cluster lives in the VM. The per-case bodies (`pristine-bootstrap` a live cluster,
  `e2e-tabs` the project image's base-provided Playwright runtime against the in-cluster webservice via its
  NodePort, `web-build` the `spago`/`esbuild` bundle) come up on the **VM's** Docker; direct host
  invocation is a development smoke, not the authoritative context. Illegal direct-host VM-container
  representations fail before cluster creation because the topology lacks the VM ancestor and runtime
  witnesses. `test run all` is the **target** surface (today the harness is reached as the lifted compute
  step of the flat `deploy` verb — `limactl shell <instance> -- docker run --rm <image> test all` on Apple
  Silicon, `incus exec <vm> -- docker run --rm <image> test all` on Linux); see
  [`DEVELOPMENT_PLAN/README.md`](DEVELOPMENT_PLAN/README.md):

  ```bash
  cd demo
  hostbootstrap run -- project up        # bring up the stack (target; flat: deploy)
  hostbootstrap run -- test run all      # validate the live stack (target; flat: test all via deploy)
  ```

- **Playwright e2e** — [`demo/playwright/`](demo/playwright/) is source/config only. The supported
  runner is the already-built `hostbootstrap-demo:local` project image, which inherits the base image's
  global Playwright install and browser cache (`/ms-playwright`). The `e2e-tabs` harness case starts that
  same project image on the kind Docker network, sets `BASE_URL` to the in-cluster NodePort service, sets
  `NODE_PATH` to the base image's global npm package directory so `@playwright/test` resolves, and runs
  `playwright test`. It does not pull `mcr.microsoft.com/playwright:*`, run `npm install`, or use `npx`
  during validation. The suite runs every spec on all three engines the base image installs (Chromium,
  Firefox, WebKit), so the `e2e-tabs` case is a `3 specs × 3 engines` matrix.

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
