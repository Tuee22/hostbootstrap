# Derived project standards

**Status**: Authoritative source
**Supersedes**: the execution-model / lifecycle ("five rules" tied to Container/HostBinary/HostDaemon) derived-project doctrine
**Referenced by**: [../README.md](../README.md), [base_image.md](base_image.md), [warm_store.md](warm_store.md), [code_check_doctrine.md](code_check_doctrine.md), [in_cluster_registry.md](in_cluster_registry.md), [linking_and_optimization.md](linking_and_optimization.md), [derived_dockerfile.md](derived_dockerfile.md), [authoring_project_binaries.md](authoring_project_binaries.md), [library_hierarchy](../architecture/library_hierarchy.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md)

> **Purpose**: State the rules a derived project follows to build the one binary that extends
> `hostbootstrap-core`, contribute and finalize its lift **plan** and step actions, inherit the base image, gate on
> `check-code`, and materialize the binary at `./.build/`.

## TL;DR

- A derived project contributes one project binary and one project-owned lifecycle plan definition.
- It extends the fixed command/parser surface through typed chain steps, config codecs, cases, services,
  and code checks rather than adding top-level verbs.
- It builds host-native for host execution and derives its project image from the published base.
- Forward steps, each frame's declared descent, and each step's reverse effect (`reversedBy`) are one
  opaque validated `StepPlan`. The one checked single-assignment slot beside it is the forward-child
  projector (`addForwardChildPlan`). Receipt-driven recursive teardown and harness root isolation are
  interpreted from that same exact admitted plan.
- Its Dockerfile follows [derived Dockerfile](derived_dockerfile.md), the canonical home for the image
  shape and build-config delivery.

This is the single page a derived project's author reads before writing their `docker/Dockerfile`,
`cabal.project`, and project binary. It is the union of the doctrine docs under
[`engineering/`](.), in the form of rules with one-line explanations and a link to the authoritative
source. The model these rules instantiate — the chain-is-the-project, the exact current-frame Chain and
recursive `project up` interpreter, fractal bootstrap — is defined once in
[composition_methodology](../architecture/composition_methodology.md); this page defers to it and never
re-derives it.

## The derived project is one binary whose identity is its lift chain

A derived project ships **exactly one executable stanza** in exactly one *selected* top-level Cabal
file: auto-discovered when it is the only top-level `.cabal` file, otherwise chosen with `--cabal-file`.
Python requires the Cabal filename stem, package name, and executable stanza to match and writes
`.build/<identity>`. The Haskell
entrypoint then requires its declared project name to equal the invoked executable before dispatch. Once
the binary exists, command dispatch is governed by its sibling runtime config file,
[`<project>.dhall`](schema.md). See
[Python/Haskell boundary](../architecture/python_haskell_boundary.md).

The binary's primary contribution is **not** a set of noun verbs — it is one finalized plan assembled
from additive fragments:

```haskell
addSteps appSteps builder
finalizeProjectSpec builder :: Either ProjectSpecError (ProjectSpec cfg tcfg)
```

where `appSteps :: CanonicalProjectRoot scope rootId -> cfg scope -> [Step]`. Core validates the combined exact order into
an opaque `StepPlan`
(see [composition methodology](../architecture/composition_methodology.md#single-representation-the-chain-is-the-representation)):
host-management step kinds the core ships (deploy-vm, ensure-X, copy-source, build-pb, build-image,
context-init, deploy-kind, deploy-chart, expose-port) interleave freely with the project's own step kinds
(deploy-object-store, deploy-registry, push-image, accelerator-daemon placement, …). The operator runs
`project up` at the root frame; an operator invocation inside a nested frame is refused. The root runs
its own frame's segment of the resolved plan and, at each frame boundary, launches the binary in the next
frame as a storeless lifecycle child entered through `--hostbootstrap-lifecycle-child`, which executes
only the nodes the root grants over the authenticated handoff (see
[the recursive `project up` interpreter](../architecture/composition_methodology.md#the-recursive-project-up-interpreter)).
`project up --dry-run` renders the chain plan without executing its steps, but it is not free of
authority side effects: it takes Production mode and lease authority as an effectful `up` does (see
[the core library's current status](../architecture/hostbootstrap_core_library.md#current-status)). The `.dhall` carries **parameters + context + witness**, never the shape — each binary
verifies it is in the frame its `.dhall` describes, or fails fast.

The binary extends `hostbootstrap-core`'s command tree rather than re-implementing core verbs:

```haskell
import HostBootstrap.CLI
  ( addForwardChildPlan, addServices, addSteps, finalizeProjectSpec, projectSpec
  , runHostBootstrapCLI )
import System.Exit (die)

main :: IO ()
main = do
  let builder =
        addForwardChildPlan appForwardChildPlan
          ( addSteps appSteps
              ( addServices appServices
                  (projectSpec appTestSuite appCheckCode appArtifacts appTestCodec appTestInit appAssemble)
              )
          )
  spec <- either (die . show) pure (finalizeProjectSpec builder)
  runHostBootstrapCLI "app" spec
```

`projectSpec` takes the project's test suite, code-check action, schema artifacts, test codec,
`psTestInit`, and the single scope-aware restricted `psAssemble`. `addSteps`, `addArtifacts`,
`addAssemblyInputs`, and `addServices` append; an `addSteps` fragment is rank-2 in the admitted
`CanonicalProjectRoot`, so a step derives its project-relative paths from that one authority.
`addForwardChildPlan` installs the project's forward-child projector, which derives the exact next child
frame's config and its independently rebuilt child-local `StepPlan` from the parent's config, the parent
and child frame names, and the supplied lift. It is the builder's only single-assignment slot: installing
it zero times fails finalization with `MissingForwardChildPlan`, and more than once with
`DuplicateForwardChildPlan`. Each frame
but the innermost declares its descent into the next with `Step.descendsVia`, validated one-per-frame by
`mkStepPlan`, so the chain carries its own topology. A step that acquires a resource also declares the
effect that releases it with `Step.reversedBy`; a second declaration on one step
(`DuplicateStepReverse`), or any declaration on a `PreserveOnReverse` step, which never enters a reverse
projection (`ReverseOnPreservedStep`), is a construction error. There is no teardown slot beside the
plan. `runHostBootstrapCLI progName spec` composes
the project's chain, test suite, code-check action, and
the artifact delta onto the inherited tree (`project init|up|down|destroy`, `context`, `test init|run`,
`service init|schema|run`, `check-code`). The spec is generic: the chain consumes the project's `cfg`, the test suite must
be non-empty, the `check-code` action is required, duplicate case/artifact names are rejected, and project
artifacts feed the inherited `context` introspection registry.

Validation happens at two points:

- `finalizeProjectSpec` runs once, at startup, and rejects (`ProjectSpecError`) an empty test suite
  (`EmptyProjectTestSuite`), duplicate case ids, a project artifact that shadows a core artifact
  (`CoreArtifactShadowing`), duplicate project artifacts, duplicate assembly inputs, no `addSteps`
  fragment (`MissingStepPlan`), a missing or duplicated forward-child projector, and an invalid service
  registry (duplicate service variants).
- `mkStepPlan` runs per decoded config, when a command projects the plan for that config, and rejects
  (`StepPlanError`), among other cases, an empty plan, empty frame or step labels, duplicate step identities, conflicting
  frame labels, a non-contiguous frame return, a missing, duplicated, or innermost-frame descent, and a
  duplicated or dead reverse effect. A fragment that returns an empty list, or a missing `descendsVia`,
  therefore surfaces only when a command projects the plan, not at startup.

`ConfigArtifact` construction remains codec-backed. The bare `hostbootstrap` binary uses
`runBareHostBootstrapCLI` and is the only binary built without the `projectSpec` builder. It contributes
no project chain or services; its Production plan projection is refused as `EmptyStepPlan`, so its
`project up` has nothing to run. Its
test suite carries one core `cluster-live` harness case whose one-step plan creates a run-scoped,
harness-owned Kind cluster and releases it through the step's `reversedBy` effect. `project init` runs
without an active local config to write the root `<project>.dhall`; `service init` and `test init` are
likewise bootstrap writers. Static schema/render/path commands are config-free, `context inspect|show`
read a config without applying mutation authority, and `test run` generates its own run config. Commands
that act on an existing frame load that config and fail fast when it is missing or when the command is not
valid for the declared frame. There is
no Python-owned `hostbootstrap.dhall`; resource, context, and witness settings live in the binary-owned
root config. In the current demo, child config projection/delivery occurs in composite
bootstrap, the descent the `context-init` row declares, and deployment actions; that row's action body
is only an announcement. Under the
implemented generic project model a project supplies a `ProjectSpec cfg tcfg`; core ships no defaults and
the static spec supplies no installed-identity marker. `runHostBootstrapCLI` verifies the executable and
retains its generative identity while instantiating the config family. One restricted `psAssemble` is the structural default source for Production init and Harness
variant generation, while `psTestInit` constructs the distinct test config. The typed service registry
and full codec are jointly finalized under one digest; demo Web/Accelerator role projection is total
from explicit assembled fields and has no fallback literals (see
[authoring_project_binaries](authoring_project_binaries.md) and
[Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)).

Before parser dispatch, the entrypoint normalizes the actual invoked executable name (including a
Windows `.exe`) and requires it to equal `progName`. The Python build boundary has already required the
Cabal filename stem, package name, and sole executable name to equal that same artifact identity.

The worked consumer lives at `demo/` (the `hostbootstrap-demo` app): its `app/Main.hs` detects the
substrate, adds `demoServices`, `demoChainFor substrate`, and the `demoForwardChildPlan` projector to the
builder, finalizes it, then calls `runHostBootstrapCLI "hostbootstrap-demo" spec`.
Its `demoChainFor :: Substrate -> CanonicalProjectRoot scope rootId -> ProjectConfig scope -> [Step]`
(the root and the config share one `scope`) contributes the demo's
substrate-selected lift as a single `[Step]`: VM-backed lanes use host→VM→container→cluster (deploy VM,
build pb + image in the VM, then carry the project-container child config on the descent the in-VM
`context-init` step declares), while native Linux GPU uses a two-frame host→direct-container→nvkind
path.
Both continue through S3 store, registry, image push, chart, runtime-owned exposure, and accelerator placement as selected
for that lane. `project up` interprets the chosen current-frame segment; `context` visualizes the
composition. For each test config, `test run all` retains its exact Harness plan and directly wraps the
common current-frame forward/reverse boundaries around `demoTestSuite` assertions — reusing the plan
algebra, not shelling `project up` or building a separate per-case cluster.

## The three-level library hierarchy

The reusable surface is a three-level Cabal library hierarchy. Each level adds **only its delta** and
imports the level below it; nothing re-implements a lower level's verbs. Only L0 and the worked
`hostbootstrap-demo` consumer live in this repository; the L1 and L2 libraries and `mcts` are external
consumers in their own repositories (linked from
[library_hierarchy](../architecture/library_hierarchy.md#the-three-library-levels)):

| Level | Library | Consumers |
|-------|---------|-----------|
| L0 | `hostbootstrap-core` (this repository) | `mcts` and `hostbootstrap-demo` consume it directly; `daemon-substrate` imports it |
| L1 | `daemon-substrate` (external) | the daemon apps import it |
| L2 | `{jitML, infernix}` (external) | the leaf apps |

Every level, in this repository or outside it, extends through the same five **parallel extension
streams**, one additive merge idiom each (canonical statement:
[library_hierarchy](../architecture/library_hierarchy.md)):

| Stream | Merge idiom | Rule |
|--------|-------------|------|
| **the lift chain** | append a typed step delta into a validated plan | core ships host-management step kinds; a level adds disjoint project kinds; host and workload steps interleave without shadowing |
| **Dhall vocabulary** | `let C = ./Core.dhall` | embed and extend; never redefine `Core` |
| **schema-gen** `ConfigArtifact` registry | concatenate across levels | a level appends its own artifacts |
| **test-harness** `Seams` | supply the level's seams | the app supplies its seams + case matrix as a `TestSuite`, threaded into the inherited `test run` verb |
| **service handlers** | `addServices` | append handlers; duplicate variants are rejected |

This table is the current composition rule. Builder fragments append steps, artifacts, assembly inputs,
and typed services under duplicate checks; the forward-child projector (`addForwardChildPlan`) is the one
checked single-assignment slot, while each frame's descent and each step's reverse effect are declared on
their own plan nodes (`descendsVia`, `reversedBy`). `Step` and `StepPlan` constructors are opaque. `ConfigArtifact` still has its separate validated
codec constructor and registry duplicate checks.

Stream 1 is the workload-extension seam: a project contributes step kinds into the same `StepPlan` the
core interprets. "L0-direct" means consuming L0 without going through L1; it does not imply a second
base-image-only integration mechanism.

## One project-binary integration model

A hostbootstrap project adds `hostbootstrap-core` (or an extending library such as
`daemon-substrate`) as a Cabal dependency and ships one binary that calls
`runHostBootstrapCLI`. The base image contains no hostbootstrap project binary, no integration
`LABEL`, and no reusable project `ENTRYPOINT` contract. A container may use the base merely as a
toolchain image without becoming a hostbootstrap project; that is not a second integration mode.

## The rules

1. **Pull the published rolling base before a compatibility build.** A same-named local image is never
   evidence for the registry copy. A resolved digest may bind one pull-to-smoke transaction, but
   consumers follow the rolling tag and no input replay contract is implied. See
   [build_release.md](build_release.md).
2. **Use one Cabal project on the host and in the container.** It must not import an absolute
   `/opt/basecontainer/...` project or freeze. Add `hostbootstrap-core` as a
   `source-repository-package` with a full immutable commit `tag` (or a local sibling) dependency; its
   transitive closure may already be warm in the store. A moving branch or omitted remote `tag` is not
   a governed consumer source dependency. The demo uses `demo/cabal.project` unchanged in both
   environments. See [warm_store.md](warm_store.md).
3. **Follow the [derived Dockerfile](derived_dockerfile.md) shape: authenticate, gate on `check-code`,
   build, materialize, and add a tini-wrapped `ENTRYPOINT`.** That page is canonical; in summary:
   - *Build-time authentication.* The coordinator supplies the authenticated builder through the
     `hostbootstrap-builder` named context and the canonical image-build config through the
     `hostbootstrap-build-config` BuildKit secret; the Dockerfile installs both under
     `/usr/local/libexec` together with the public handoff and activation verification keys. The
     Dockerfile never runs `project init`, so the image cannot mint its own build config.
   - *Code-check.* `/usr/local/libexec/<project> check-code` runs under the narrow image-build frame with
     the signed build channel mounted as secrets, before the web build; the container is built on every
     substrate as the mandatory code-check gate.
   - *Final materialization.* After the source and web builds, the Dockerfile proves the in-image Cabal
     product is non-empty, copies the authenticated builder bytes with `dd` into a new regular
     `/usr/local/bin/<project>` runtime file, final-materializes its runtime config, public keys, and
     generated web output, removes the build-only libexec authority, and proves the runtime artifacts are
     non-empty.
   - *Runtime delivery.* The container frame skips the build at runtime. Recursive lifecycle verbs enter
     the container as a storeless lifecycle child (`--hostbootstrap-lifecycle-child`) whose canonical
     config travels inside the authenticated handoff; only the ordinary lift route, for non-lifecycle
     subcommands, streams a `<project>.dhall` over `stdin` in place. Neither bind-mounts a config. See
     [the runtime launch](derived_dockerfile.md#the-runtime-launch).

   See [code_check_doctrine.md](code_check_doctrine.md#derived-images) and
   [binary_context_config](../architecture/binary_context_config.md).
4. **Link executables statically.** Do not pass `--enable-executable-dynamic` or
   `--enable-executable-static`. Setting `shared: True` is the recommended companion: it builds the dyn
   way of the project's own local packages, which Template Haskell and GHCi load. It is not a
   requirement and does not affect warm-store reuse: a top-level project option reaches only that
   project's local packages, and store dependencies build as their own per-package defaults say (see
   [warm_store.md](warm_store.md#population-inputs)). The worked demo's `demo/cabal.project` sets only
   `optimization: 2` and passes `--enable-tests --enable-benchmarks` on the command line. See
   [linking_and_optimization.md](linking_and_optimization.md#recommended-policy).
5. **Treat the inherited store as an optimization.** `cabal build --dry-run` can diagnose reuse, but a
   third-party package in the plan is a permitted cache miss. Add broadly useful dependencies to the
   descriptive manifest under [`core/warm-deps/`](../../core/warm-deps/) when useful; do not contort
   consumer constraints merely to force a hit. Publication uses a dedicated real consumer as an online compatibility
   smoke, not an offline completeness proof. See [warm_store.md](warm_store.md#cache-behavior).

A project that follows all five rules has a small Dockerfile, opportunistic cache reuse,
a binary whose chain extends the core step algebra, and an image that cannot exist with code-check
violations.

## Build and run: where the binary lives

Every project produces a host binary at `./.build/<executable>`, built **host-native** on every
substrate:

- The Python bootstrapper ensures the host build toolchain (on Apple, Homebrew → `ghcup` →
  GHC/Cabal; the equivalent on Linux) and builds the single discovered executable stanza host-native
  into `./.build/<executable>`.
  A Linux ELF cannot exec on a general host such as Apple silicon, so the binary is always built for
  the host it runs on — there is no build-in-container, copy-out path. The Python bootstrapper is the
  **metal-frame instance** of the fractal bootstrap (provision the frame → build/install the pb in it →
  hand off `pb project up`); see
  [python_haskell_boundary](../architecture/python_haskell_boundary.md).
- A generic consumer may build a platform-locked artifact that cannot be produced inside a container on
  the **bare host** with no build VM and stage it into the cluster (the headless host-build shape,
  composition pattern #7). The demo's Windows GPU
  accelerator instead follows host-daemon pattern #6: `ensure cudawin` requires a preinstalled NVIDIA
  driver (it fails when `nvidia-smi` is absent) and installs the CUDA Toolkit, Visual Studio Build Tools,
  and LLVM via winget, and the accelerator daemon builds **and runs** the worker on the Windows host;
  nothing is staged into the cluster. See [composition_patterns.md](composition_patterns.md) and
  [cuda](../languages/cuda.md#windows-host-build-cuda-headless).

Building the project **container** is the invoked binary's job (its `check-code` gate), not the
bootstrapper's. A `./.build/<executable>` is always present after a successful bootstrap, regardless of
substrate. The notation `<project>` elsewhere on this page denotes the validated single build identity:
Cabal filename stem = package name = executable stanza = invoked/declared CLI program name. Broader
opaque plan/resource identity remains in the later lifecycle phases; see
[schema](schema.md#project-and-executable-identity).

## Worked compliant Dockerfile and `cabal.project`

The compliant Dockerfile shape, its parser directives, the build-stage ordering, and the runtime launch
are canonical in [derived Dockerfile](derived_dockerfile.md#the-reference-shape), with
`demo/docker/Dockerfile` as the worked instance; this page does not restate the skeleton.

A compliant consumer's `cabal.project`:

```cabal
packages: .

tests: True
benchmarks: True
shared: True
optimization: 2

source-repository-package
  type: git
  location: https://github.com/tuee22/hostbootstrap.git
  tag: <full-hostbootstrap-commit-id>
  subdir: core/hostbootstrap-core
```

Remote consumers replace the placeholder with one full immutable commit ID. The in-repository demo uses
the sibling local package instead, so it has no remote `tag` field.

The same project file is used host-native and in the derived container. It imports no base-owned freeze;
matching `hostbootstrap-core` dependencies may be warm, and missing ones compile normally.

The Dockerfile contains no `project init` line. The image-build-container `<project>.dhall` is the
canonical config the coordinator supplies through the `hostbootstrap-build-config` BuildKit secret;
build-time commands such as `check-code` load that config and refuse commands not valid for the
image-build frame. At runtime a recursive lifecycle verb enters the container as a storeless lifecycle
child whose canonical config travels inside the authenticated handoff; a Kubernetes service pod runs
`service run`, which reads its signed activation coordinates rather than a sibling config. See
[the runtime launch](derived_dockerfile.md#the-runtime-launch).

## Current Status

The implemented binary surface is the `project` chain, and the core command tree is exactly `project`,
`test`, `service`, `context`, and `check-code`. Hardware evidence and closure status belong in the
development plan:

- opaque validated `StepPlan` is consumed by the exact current-frame Chain. Production admits authenticated storeless children through the root catalog; reverse traversal is child-first.
- `context` is read-only introspection: `inspect` renders the lift composition with the current frame
  marked, `show` decodes a selected project-local config, `path` prints its canonical filename, and
  `schema`/`render` expose the separate static `ConfigArtifact` registry. The validated-codec
  project-local `cfg` shape is emitted by `service schema`.
- `test init` writes the sibling `<project>.test.dhall`; `test run <case-id>|all` runs a compiled case or
  the whole matrix with `all`. The help calls this root-only, but a root context gate is not currently
  enforced.
- `service init|schema|run` runs long-running roles as leaf-frame service handlers.
- `check-code` runs the project's fail-fast code-check gate. It resolves its formatter, linter and
  Cabal by name on `PATH` rather than by absolute path, so the same verb runs inside the derived image —
  whose `PATH` the base image sets from the build argument that decides where the style tools are
  installed — and on a host that has the three tools. A derived project that spells those paths as
  literals re-states a constant the bootstrapper owns, in a second language, and can only ever run its
  own gate inside the image.
- `ensure` is a reconciler library, not a command. Core exposes `ensureStep`, but the current demo
  invokes `runEnsure` from composite provider/build/accelerator actions.

The demo's deploy is the contributed
`demoChainFor :: Substrate -> CanonicalProjectRoot scope rootId -> ProjectConfig scope -> [Step]` value in
`demo/src/HostBootstrapDemo/Commands.hs` — a list of `Step` the core interprets across the selected fractal
descent. The demo contributes its `web` and `accelerator` service variants (run by `service run`; the
build-time bridge folds into the build-image step) and its VM/provider IO as chain steps — the surface is
fixed, so it adds no verbs. Its build-image step is the image-build coordinator: it supplies the
authenticated builder and the image-build config to the Dockerfile and probes the exported image.

A single `project up` is intended to stand up the live persistent stack — a cordoned kind cluster → the
runtime-owned loopback relay and its resolved registry endpoint → the in-cluster registry → the project image
pushed to that registry → the web chart pod → its resolved web endpoint serving HTTP 200. Stable
Service/NodePort targets remain cluster-internal and never select the host-side number. Teardown traverses the same plan child-first and conditionally releases each exact managed resource.
The target registry step is contributed from an opaque finalized plan that jointly binds client scope,
verified exposure, backing endpoint, and blob delivery. A consumer must not pass raw endpoints or
choose `storage.redirect.disable` independently; see
[network reachability](../architecture/network_reachability.md).
`test run all` drives the corresponding Harness-scoped current-frame plan directly; each harness config
carries a `HarnessRun` run profile, which `clusterProfileOf` maps to a run-scoped `TestCase` cluster
profile, so a run never touches the Production cluster or the durable `.data` root; see
[harness workflow](../architecture/harness_workflow.md).
`DEVELOPMENT_PLAN/` owns the phase status; this page describes the model and the worked `demo/` consumer
that realizes it.

## See also

* [composition_methodology](../architecture/composition_methodology.md) — the canonical model: chain-is-the-project, current-frame Chain, recursive `project up`, and fractal bootstrap
* [authoring_project_binaries](authoring_project_binaries.md) — how a consumer authors its `chain` and step actions
* [library_hierarchy](../architecture/library_hierarchy.md) — the extension-stream contract (stream 1 = the lift chain)
* [base_image.md](base_image.md) — what the base image ships, including the warm core closure
* [warm_store.md](warm_store.md) — the Cabal store cache-hit contract
* [code_check_doctrine.md](code_check_doctrine.md) — the build-time code-check gate
* [linking_and_optimization.md](linking_and_optimization.md) — linking and optimisation defaults
* [in_cluster_registry.md](in_cluster_registry.md) — consumer-owned project-image push resources over
  core's target reachability-safe planning vocabulary
* [binary_context_config](../architecture/binary_context_config.md) — the exact split between config-free
  writers/static routes, file readers, the harness-generated route, and commands gated by the runtime
  sibling config
