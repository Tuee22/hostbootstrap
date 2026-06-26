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
  (`docker`, `colima`, `cuda`, `homebrew`, `ghc`, each fail-fast on the wrong host), substrate
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
`chain :: cfg -> [Step]` function, and that `[Step]` **is the project's identity**: the ordered
list of host-management and workload steps that bring the project up. There is one representation of that
work (single representation, §W). The single lifecycle command `<binary> project init|up|down|destroy`
**interprets the chain recursively**. Each frame transition is the same **fractal bootstrap** — provision
the frame, build the project binary (the "pb") in it, then hand off `pb project up` into that frame so the
child pb owns its own segment of the chain. The Python bootstrapper is simply the **metal-frame instance**
of that pattern (provision the host frame → build the pb host-native → hand off to the binary), with the
VM and project-container frames descending the same way until recursion bottoms out at the container pb
running kind/Helm leaves.

The VM hop is provider-backed: on Apple Silicon the demo uses a Lima VM (`limactl shell <instance> -- …`)
started without Lima-managed containerd, native Linux uses an Incus VM (`incus exec <vm> -- …`), and on
Windows (planned) a WSL2 Ubuntu-24.04 distro (`wsl -d <distro> -- …`). The
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

> **Current state.** The fixed `project`/`test`/`service`/`context`/`check-code` command surface and the
> "chain is the project" model — the recursive `project init|up|down|destroy` lifecycle command and the
> `chain :: cfg -> [Step]` interpreter described above — are **implemented and real-run-validated**.
> On Apple Silicon (Lima) the demo reports `3/3 passed`, including the Playwright e2e case; on native Linux
> (Incus) a single `project up` drives the full lifecycle end to end, exit 0. The host-native bootstrapper,
> the self-reference lift primitive, the single-representation demo deploy, and the project-local
> binary-context command gate are implemented; Python derives the project name from the Cabal file and
> writes no Dhall; lifted runtime containers receive parent-mounted configs with topology frames and
> witnesses.
>
> The chain work is `Done`; **phase-19 (the generic project model)**, **phase-20 (the config-driven demo
> worked example)**, and **phase-21 (documentation/code consistency reconciliation)** are implemented and
> `Done`. The original scope (phases 0 through 21) is `Done`; **phases 2, 3, 6, 9, and 11 are now reopened
> (`Active`)** to weave in **Windows as the third metal substrate** (a native `hostbootstrap.exe`, WSL2 as
> the Lima/Incus peer, and CUDA as a headless host build) and to **retire the latent Tart reconciler** —
> all currently target work, tracked in
> [`DEVELOPMENT_PLAN/README.md`](DEVELOPMENT_PLAN/README.md).

Each consuming project ships **one binary** that extends `hostbootstrap-core` with its own
subcommands. The bare `hostbootstrap` binary is `hostbootstrap-core`'s own executable — the same
entrypoint with no project commands — so the core verbs behave identically everywhere. Like every
project binary it is built **host-native**; it is not baked into the base image.

## Bootstrap Flow

The Python bootstrapper does only what must run **before any project binary exists** — a short,
fail-fast sequence:

1. **Assert host minimums.** On Linux: Ubuntu 24.04, passwordless `sudo`, and hardware virtualization
   (Intel VT-x / AMD-V plus a usable `/dev/kvm`, which the nested VM providers need). On Apple: passwordless
   `sudo`, the Xcode Command Line Tools, and Homebrew. On Windows (target): winget, plus the
   virtualization / WSL2 feature the nested WSL2 provider needs. Missing minimums stop the run with a clear
   message; the bootstrapper does not attempt to install them.
2. **Ensure the host build toolchain.** The prerequisites needed to build the binary host-native — on
   Apple, Homebrew → `ghcup` → GHC/Cabal; the equivalent on Linux; on Windows (target) winget → GHC + MSVC.
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
  on Linux; on Windows (target) winget → GHC + MSVC), builds the binary host-native into
  `./.build/<project>`, and execs it.
- **Headless host build for platform-locked artifacts (planned).** On Windows the target shape builds
  CUDA artifacts on the bare host (`ensure cudawin` readies the NVIDIA driver, CUDA Toolkit, and MSVC via
  winget), stages them into the cluster, and never runs the workload in a build VM — composition pattern
  #7, owned by [phase 3](DEVELOPMENT_PLAN/phase-3-ensure-reconcilers.md). See
  [`documents/engineering/composition_patterns.md`](documents/engineering/composition_patterns.md).

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

The demo host-level `<project>.dhall` generated by a project binary has this top-level shape, with the
nested context fields carrying the role and command authority:

```text
{ dockerfile = "docker/Dockerfile"
, resources =
  { cpu = 6
  , memory = "10GiB"
  , storage = "80GiB"
  }
, context = ...
, deploy = { haReplicas = 1 }
, message = "Hello, world!"
}
```

> **The generic project model (phase 19, § BB) — implemented.** The shape above is the **demo's** config.
> `hostbootstrap-core` owns **no hardcoded defaults** and is parameterized over a project's own config type
> — `ProjectSpec cfg tcfg` — coupled to core only through the lift authority (`cfg -> BinaryContext`).
> Defaults live only in a project-owned `psInit`, which `project init` and the test harness share (DRY);
> `test.dhall` is a thin override the harness uses to **generate** the run's `<project>.dhall`; and a pure
> `SecretRef` vocabulary keeps a secrets-strict consumer's production configs plaintext-free. Under this
> model the demo **owns** its config type, so `hostbootstrap-core` ships no hardcoded defaults and no generic
> extra field. Phase 19 is `Done` (real-run-validated 2026-06-23: `test run all` reported `3/3 passed` from
> a harness-generated config). The `message` line above is **implemented** — it is the **phase-20** worked
> example (`Done`): a field on the demo's own cfg (default `"Hello, world!"`) demonstrated by a two-cluster
> run that flows the demo `message` config → the chart ConfigMap → the `Web` service → `BudgetView.message`
> → the SPA `#message` and a polymorphic e2e check (`test run all` reports `6/6` across the two message
> variants). See
> [`documents/architecture/generic_project_model.md`](documents/architecture/generic_project_model.md),
> [`DEVELOPMENT_PLAN/phase-19-generic-project-model.md`](DEVELOPMENT_PLAN/phase-19-generic-project-model.md),
> and [`DEVELOPMENT_PLAN/phase-20-config-driven-demo-worked-example.md`](DEVELOPMENT_PLAN/phase-20-config-driven-demo-worked-example.md).

The project value is also the command name. The `resources` budget is the host-level ceiling that the
project binary projects into child configs and enforces through cordons. Before bring-up the binary
verifies that budget against spare host capacity resolved per substrate — resolved `sysctl` on Apple
silicon, `/proc` on Linux, and the host APIs on Windows (target). See
[`documents/engineering/resource_budgeting.md`](documents/engineering/resource_budgeting.md).

## CLI Surface

Two programs share the `hostbootstrap` name: the **pipx-installed Python bootstrapper** (the host CLI
you install and run) and the **`hostbootstrap-core` command tree** that every built binary — the
bare `hostbootstrap` binary and each project binary — exposes.

The Python bootstrapper (installed with `pipx install …`) exposes only the **consumer** commands:

| Command | What it does |
|---|---|
| `hostbootstrap doctor` | Detect the host and assert the fail-fast host minimums for the detected substrate |
| `hostbootstrap build` | Run the bootstrap — build the project binary host-native into `./.build/`; no exec |
| `hostbootstrap run [args...]` | Build idempotently, then exec the project binary with `args` |
| `hostbootstrap update` | Explicitly update the pipx-installed Python bootstrapper |

The **maintainer** commands below are registered **only in a Poetry development install** of this repo
(they need the dev toolchain — ruff/black/mypy/pytest); they are hidden from the pipx-installed CLI, where
invoking them prints a plain `No such command`. Run them from the repo with `poetry run hostbootstrap …`:

| Command (dev-only) | What it does |
|---|---|
| `hostbootstrap base build` | Cold-rebuild the base image(s) locally (`--no-cache --pull`); no push. With no `--flavor`, cpu+cuda build concurrently (`--sequential` opts out) |
| `hostbootstrap base build-and-push` | Cold-rebuild and push the base image(s); with no `--flavor`, cpu+cuda build concurrently (`--sequential` opts out) |
| `hostbootstrap check-code` | Run the Python code-check gate (ruff → black → mypy); same as `python -m hostbootstrap.check_code` |
| `hostbootstrap test-all [pytest args...]` | Run the full pytest suite via the supported runner; same as `python -m hostbootstrap.test_all` |

Self-update is never run automatically by `doctor`, `build`, `run`, or `base`, and those commands must
not fail just because the wrapper is not at the latest commit.

The `hostbootstrap-core` command surface is **fixed**: every built binary exposes the **same** tree, and a
project adds **no verbs**. `hostbootstrap-core` is a library of composable tools (step kinds, reconcilers,
the self-reference lift, service handlers), not a CLI topology — a project's identity is its chain, Dhall
vocabulary, schema-gen artifacts, test seams, and service handlers, never bespoke commands.

| Command | What it does |
|---|---|
| `<binary> project init` | Write the root `<project>.dhall` (host-orchestrator, no parent); fail-fast unless a fresh host-level binary with no sibling `.dhall`; the target shape layers optional `--cpu/--memory/--storage/--ha-replicas` overrides over the project's `psInit` defaults (core ships no defaults) |
| `<binary> project up` | Recursively interpret `chain cfg` from the current frame; idempotent (reconcile-to-running); `--dry-run` renders the chain instead of running it |
| `<binary> project down` | Stop service/VM frames and tear down kind clusters while preserving durable host state (`.data`) |
| `<binary> project destroy` | Stop, then delete everything brought up; host `.data` is always preserved |
| `<binary> test init` | Write `test.dhall` (the case matrix + config overrides) using the same value-free builder as `project init`; needs no pre-existing `<project>.dhall` |
| `<binary> test run <suite>\|all` | Root-gated; per distinct test config, drives the real `project up` under a test-written `.dhall`, asserts in-frame, then `project destroy`; two fail-fast safety preconditions (refuse if a sibling `.build/<project>.dhall` exists — checked at `siblingProjectConfigPath`, not the project root — or a production cluster is running); uses `.test_data` |
| `<binary> service init\|schema\|run` | Run a long-running role: `service run` is a leaf-frame pod entrypoint dispatched over the project's `ServiceType` ADT, fail-fast unless the config declares a service role + variant; no `service down` (the controller owns lifetime) |
| `<binary> context` | Read-only: introspect **any** sibling `.dhall` uniformly and render the global lift composition with the **current frame highlighted** (absorbs `config show/schema/render`) |
| `<binary> check-code` | Run the inherited code-check surface; failed checks exit non-zero |

These core verbs behave identically whether invoked through the bare `hostbootstrap` binary or a project
binary. The fixed `project`/`test`/`service`/`context`/`check-code` surface, the harness driving the real
`project up`, and the `service` command are **implemented and real-run-validated** (the `ProjectCommand`
extension point and the demo `vm`/`incus`/`web` verbs are removed; `service` + its registry exist; the
harness drives `project up`). Full multi-arch republish and Harbor remain operator-scale steps that need
operator-only prerequisites (a host Docker Hub login + a republished `arm64` base). See
[`DEVELOPMENT_PLAN/README.md`](DEVELOPMENT_PLAN/README.md) and the "Current state" note in the Architecture
section above. See
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
core directly (L0-direct, like `mcts`) and contributes its own `demoChain :: ProjectConfig -> [Step]` value plus
the step actions, test suites, and Dhall vocabulary that go with it, so the **demo's deploy is its chain**
— interpreted by the single `project up` lifecycle command rather than a tree of noun verbs. It is the
end-to-end exercise of the extension-stream additive extension contract: the lift chain (`[Step]` = core host
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
| 2 | deploy VM | host → VM | Lima VM on Apple Silicon, Incus VM on Linux, WSL2 distro on Windows (planned) — the cordon / isolation wall |
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

> **Status.** This `[Step]` chain interpreted by `project up` is implemented and real-run-validated: a
> single `project up` brings up the cordon VM, runs the host-native build and the project-image build in the
> VM, and stands up kind → Harbor → the web service on the VM's Docker. The unified-harness / fixed-surface
> / resource-SSoT correction has **landed**: the demo's test seams drive that same `project up` under a test
> config (rather than a separate per-case cluster), the budget-doubling VM sizing collapses to budget = VM
> wall / cluster = slice, and `web serve` → `service run`. The Apple Silicon Lima run reported `3/3 passed`
> including the Playwright e2e case; the native Linux Incus run drives the full `project up` lifecycle end to
> end. **Phase-19 (the generic project model)** and **phase-20 (the config-driven demo worked example)** are
> both implemented and `Done`; phase-21 reconciles the documentation/code drift, so the original scope
> (phases 0 through 21) is `Done`. Phases 2, 3, 6, 9, and 11 are now reopened (`Active`) for the Windows
> third-substrate and Tart-retirement work (target); see
> [`DEVELOPMENT_PLAN/README.md`](DEVELOPMENT_PLAN/README.md).

### Spin it up

Build and exec the demo binary host-native through the Python bootstrapper, from the demo project root —
the same workflow every consumer follows (assert host minimums → ensure the host toolchain → build into
`./.build/` → exec). The whole lifecycle is the recursive `project` command over the demo's chain:

```bash
cd demo
hostbootstrap run -- project init \
  --cpu 6 --memory 10GiB --storage 80GiB --ha-replicas 1
hostbootstrap run -- project up --dry-run   # renders chain cfg without running it
hostbootstrap run -- project up             # interprets the chain recursively, brings up the stack
hostbootstrap run -- context                # render the lift composition, current frame highlighted
hostbootstrap run -- test run all           # root-gated suite against the live project up stack
hostbootstrap run -- project destroy        # stop then delete; host .data preserved
```

To build and run the binary directly against
the local core (no bootstrapper), use Cabal with the demo's own workspace:

```bash
cd demo
cabal build                           # builds hostbootstrap-demo against ../core/hostbootstrap-core
cabal run hostbootstrap-demo -- context
```

`service run` (the demo's `Web` service variant) is the long-running webserver role. It runs inside the
chart-launched pod, whose ConfigMap-delivered `hostbootstrap-demo.dhall` declares a service role and the
`Web` variant; a host-orchestrator config rejects it. The demo cfg carries a
`message` field that flows `hostbootstrap-demo.dhall` → the chart ConfigMap → the `Web` service (whose
handler reads its config) → `BudgetView.message` → the SPA `#message` element, making `message` the
implemented worked example (phase-20, `Done`) of a project-owned config value reaching the live workload. The integrated VM/cluster lifecycle is **not** a
separate chain of verbs: it is the demo's contributed `[Step]` chain above, interpreted recursively by
`project up`, whose `deploy-chart` step launches the pod whose entrypoint is `service run`, carrying cluster
bring-up, Harbor, the web service, and the NodePort **inside** the VM. The deploy-VM step is the metal-side
cordon step of that one chain, documented in the runbook.

### Run its test suite

The test surface **drives** deploy rather than duplicating it: `test run all` is root-gated and, per
distinct test config, runs the real `project up`, asserts the live stack, then tears it down. The demo
carries two test layers:

- **Haskell harness** — `hostbootstrap-demo test run all` drives the demo's case matrix
  (`pristine-bootstrap` / `web-build` / `e2e-tabs`; a single suite runs with
  `hostbootstrap-demo test run <suite>`). The harness is the **one** test engine and it *is* the chain,
  driven under a test config: per distinct test config it writes a test-specific `hostbootstrap-demo.dhall`,
  runs `project up` over the demo's own chain, runs the case assertions in the appropriate frame, and tears
  the stack down with `project destroy` (guaranteed via `finally`, preserving host `.data`). There is no
  separate `seamSetup` that stands a cluster up a second way — the bring-up a test exercises is the same
  chain production uses. Two fail-fast safety preconditions run before any test: the harness refuses if a
  sibling `hostbootstrap-demo.dhall` already exists (checked at `siblingProjectConfigPath`) or if a
  production cluster is running, and it deletes only the config and `.test_data` it created. A suite may
  declare **more than one config variant** and the harness stands each up,
  asserts, then tears it down in turn: the demo runs **two** variants (`"Hello, world!"` then
  `"Hello, Universe!"`), with a full `project up` → assert → `project destroy` between them, each config
  built functionally through the shared `psTestConfig` builder (reusing `psInit`, never shelling the CLI). The per-case assertions (`pristine-bootstrap` a live cluster,
  `e2e-tabs` the project image's base-provided Playwright runtime against the in-cluster webservice via its
  NodePort, `web-build` the `spago`/`esbuild` bundle) run on the **VM's** Docker, in the frame each needs.
  The harness recast onto `project up` is **implemented**, and `test run all` reports **`6/6`** on native
  Incus/Linux: the three cases (`pristine-bootstrap` / `web-build` / `e2e-tabs`) run across **both** message
  variants (`"Hello, world!"` and `"Hello, Universe!"`), 3 × 2 = 6. Every case runs in the **VM frame** —
  each reachability check is a pure probe folded into the VM by the self-reference lift (`incus exec <vm> --
  curl …` / `limactl shell <vm> -- curl …`), so it reaches the in-cluster NodePort whether or not the
  provider forwards the guest port to the host. See
  [`DEVELOPMENT_PLAN/README.md`](DEVELOPMENT_PLAN/README.md):

  ```bash
  cd demo
  hostbootstrap run -- test run all      # per test config: project up → assert → project destroy
  ```

- **Playwright e2e** — [`demo/playwright/`](demo/playwright/) is source/config only. The supported
  runner is the already-built `hostbootstrap-demo:local` project image, which inherits the base image's
  global Playwright install and browser cache (`/ms-playwright`). The `e2e-tabs` harness case starts that
  same project image on the kind Docker network, sets `BASE_URL` to the in-cluster NodePort service, sets
  `NODE_PATH` to the base image's global npm package directory so `@playwright/test` resolves, and runs
  `playwright test`. It does not pull `mcr.microsoft.com/playwright:*`, run `npm install`, or use `npx`
  during validation. The suite runs every spec on all three engines the base image installs (Chromium,
  Firefox, WebKit), so the `e2e-tabs` case is a `3 specs × 3 engines` matrix. The
  `e2e-tabs` spec is **polymorphic**: the harness exports `EXPECTED_MESSAGE` per variant and the spec asserts
  whichever message the active deployment set — reading the SPA `#message` element — so the same spec proves
  both the `"Hello, world!"` and `"Hello, Universe!"` clusters.

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
│   │   │   ├── Ensure.hs  Ensure/    # Docker, Colima, Cuda, Homebrew, Ghc
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
