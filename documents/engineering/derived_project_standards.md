# Derived project standards

**Status**: Authoritative source
**Supersedes**: the execution-model / lifecycle ("five rules" tied to Container/HostBinary/HostDaemon) derived-project doctrine
**Referenced by**: [../README.md](../README.md), [base_image.md](base_image.md), [warm_store.md](warm_store.md), [code_check_doctrine.md](code_check_doctrine.md), [in_cluster_registry.md](in_cluster_registry.md), [linking_and_optimization.md](linking_and_optimization.md), [binary_context_config](../architecture/binary_context_config.md)

> **Purpose**: State the rules a derived project follows to build the one binary that extends
> `hostbootstrap-core`, contribute and finalize its lift **plan** and step actions, inherit the base image, gate on
> `check-code`, and materialize the binary at `./.build/`.

## TL;DR

- A derived project contributes one project binary and one project-owned lifecycle plan definition.
- It extends the fixed command/parser surface through typed chain steps, config codecs, cases, services,
  and code checks rather than adding top-level verbs.
- It builds host-native for host execution and derives its project image from the published base.
- Forward steps are one opaque validated `StepPlan`; frame-context/teardown are checked single-assignment
  slots. Receipt-driven recursive teardown and harness root isolation remain plan-owned target work.

This is the single page a derived project's author reads before writing their `docker/Dockerfile`,
`cabal.project`, and project binary. It is the union of the doctrine docs under
[`engineering/`](.), in the form of rules with one-line explanations and a link to the authoritative
source. The model these rules instantiate — the chain-is-the-project, the recursive `project up`
interpreter, fractal bootstrap — is defined once in
[composition_methodology](../architecture/composition_methodology.md); this page defers to it and never
re-derives it.

## The derived project is one binary whose identity is its lift chain

A derived project currently ships **exactly one executable stanza** in exactly one top-level Cabal file.
Python requires the Cabal filename stem, package name, and executable stanza to match and writes
`.build/<identity>`; ambiguous discovery requires explicit `--cabal-file` selection. The Haskell
entrypoint then requires its declared project name to equal the invoked executable before dispatch. Once
the binary exists, command dispatch is governed by its sibling runtime config file,
[`<project>.dhall`](schema.md). See
[Python/Haskell boundary](../architecture/python_haskell_boundary.md).

The binary's primary contribution is **not** a set of noun verbs — it is one finalized plan assembled
from additive fragments:

```haskell
addSteps appSteps builder
finalizeProjectSpec builder :: Either ProjectSpecError (ProjectSpec projectId cfg tcfg)
```

where `appSteps :: cfg (Production projectId) -> [Step]`. Core validates the combined exact order into
an opaque `StepPlan`
(see [composition methodology](../architecture/composition_methodology.md#single-representation-the-chain-is-the-representation)):
host-management step kinds the core ships (deploy-VM, ensure-X, copy-source, build-pb, build-image,
context-init, deploy-kind, deploy-chart, expose-port) interleave freely with the project's own step kinds
(deploy-minio, deploy-registry, push-image, accelerator-daemon placement, …). `project up` interprets
the resolved plan from the current frame
and hands off `pb project up` into the next frame; `project up --dry-run` renders the chain plan without
executing it. The `.dhall` carries **parameters + context + witness**, never the shape — each binary
verifies it is in the frame its `.dhall` describes, or fails fast.

The binary extends `hostbootstrap-core`'s command tree rather than re-implementing core verbs:

```haskell
import HostBootstrap.CLI
  ( addServices, addSteps, finalizeProjectSpec, projectSpec
  , runHostBootstrapCLI, setFrameContext, setTeardown )

main :: IO ()
main = do
  spec <- either (fail . show) pure
    ( finalizeProjectSpec
        ( addServices appServices
            ( addSteps appSteps
                ( setFrameContext appFrameContext
                    ( setTeardown appTeardown
                        (projectSpec appTestSuite appCheckCode appArtifacts appTestCodec appTestInit appAssemble)
                    )
                )
            )
        )
    )
  runHostBootstrapCLI "app" spec
```

`projectSpec` takes the project's test suite, code-check action, schema artifacts, test codec,
`psTestInit`, and the single scope-aware restricted `psAssemble`. `addSteps`, `addArtifacts`,
`addAssemblyInputs`, and `addServices` append. `setFrameContext` and `setTeardown` are checked
single-assignment slots; a second assignment is a construction error. `runHostBootstrapCLI progName spec` composes
the project's chain, test suite, code-check action, and
the artifact delta onto the inherited tree (`project init|up|down|destroy`, `context`, `test init|run`,
`service init|schema|run`, `check-code`). The spec is generic: the chain consumes the project's `cfg`, the test suite must
be non-empty, the `check-code` action is required, duplicate case/artifact names are rejected, and project
artifacts feed the inherited `context` introspection registry. Finalization and plan projection require
a non-empty contiguous plan, disjoint unique typed step identities, consistent frame labels, explicit
reverse policy, unique artifacts/inputs/services/cases, and exactly one frame-context/teardown
projection. `ConfigArtifact` construction remains codec-backed. The bare `hostbootstrap` binary uses
`runBareHostBootstrapCLI`; it is the only intentional empty-chain/empty-suite binary. `project init` runs
without an active local config to write the root `<project>.dhall`; `service init` and `test init` are
likewise bootstrap writers. Static schema/render/path commands are config-free, `context inspect|show`
read a config without applying mutation authority, and `test run` generates its own run config. Commands
that act on an existing frame load that config and fail fast when it is missing or when the command is not
valid for the declared frame. There is
no Python-owned `hostbootstrap.dhall`; resource, context, and witness settings live in the binary-owned
root config. In the current demo, child config projection/delivery occurs in composite
bootstrap/frame-context/deployment actions and the `context-init` row is only an announcer. Under the
implemented generic project model a project supplies a `ProjectSpec projectId cfg tcfg`; core ships no
defaults. One restricted `psAssemble` is the structural default source for Production init and Harness
variant generation, while `psTestInit` constructs the distinct test config. The typed service registry
and full codec are jointly finalized under one digest; demo Web/Accelerator role projection is total
from explicit assembled fields and has no fallback literals (see
[authoring_project_binaries](authoring_project_binaries.md) and
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md)).

Before parser dispatch, the entrypoint normalizes the actual invoked executable name (including a
Windows `.exe`) and requires it to equal `progName`. The Python build boundary has already required the
Cabal filename stem, package name, and sole executable name to equal that same artifact identity.

The worked consumer lives at `demo/` (the `hostbootstrap-demo` app): its `app/Main.hs` detects the
substrate, adds `demoChainFor substrate`, `demoServices`, `demoFrameContext`, and `demoTeardown` to the
builder, finalizes it, then calls `runHostBootstrapCLI "hostbootstrap-demo" spec`.
Its `demoChainFor :: Substrate -> ProjectConfig -> [Step]` contributes the demo's
substrate-selected lift as a single `[Step]`: VM-backed lanes use host→VM→container→cluster (deploy VM,
build pb + image in the VM, then carry the project-container child config through the
frame-context/handoff seam), while native Linux GPU uses a two-frame host→direct-container→nvkind path.
Both continue through MinIO, registry, image push, chart, NodePort, and accelerator placement as selected
for that lane. `project up` interprets the chosen chain to stand up the persistent stack; `context`
visualizes the composition; and `test run all` **drives that same `project up`**
under a test config (one per distinct test config), asserting the live stack with `demoTestSuite` and tearing it
down with `project destroy` — reusing the chain, not a separate per-case cluster.

## The three-level library hierarchy

The reusable surface is a three-level Cabal library hierarchy. Each level adds **only its delta** and
imports the level below it; nothing re-implements a lower level's verbs:

| Level | Library | Consumers |
|-------|---------|-----------|
| L0 | `hostbootstrap-core` | `mcts` and `hostbootstrap-demo` consume it directly; `daemon-substrate` imports it |
| L1 | `daemon-substrate` | the daemon apps import it |
| L2 | `{jitML, infernix}` | the leaf apps |

The target has the same **parallel extension streams**, one additive merge idiom each (canonical statement:
[library_hierarchy](../architecture/library_hierarchy.md)):

| Stream | Merge idiom | Rule |
|--------|-------------|------|
| **the lift chain** | append a typed step delta into a validated plan | core ships host-management step kinds; a level adds disjoint project kinds; host and workload steps interleave without shadowing |
| **Dhall vocabulary** | `let C = ./Core.dhall` | embed and extend; never redefine `Core` |
| **schema-gen** `ConfigArtifact` registry | concatenate across levels | a level appends its own artifacts |
| **test-harness** `Seams` | supply the level's seams | the app supplies its seams + case matrix as a `TestSuite`, threaded into the inherited `test run` verb |
| **service handlers** | `withServices` | append handlers; duplicate variants are rejected |

This table is the current composition rule. Builder fragments append steps, artifacts, assembly inputs,
and typed services under duplicate checks; frame context and teardown are checked single-assignment
slots. `Step` and `StepPlan` constructors are opaque. `ConfigArtifact` still has its separate validated
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
3. **Build the binary, materialize the image-build context, run `<project> check-code`, and add a
   tini-wrapped `ENTRYPOINT`.** Image-build context materialization is explicit: the Dockerfile runs the
   binary once to write its image-build-container `<project>.dhall` after the binary is installed and
   before any normal command. The check then runs under the narrow image-build frame and before any
   expensive backend work; the container is built on every substrate as the mandatory code-check gate. The
   container frame skips the build step at runtime — `docker run img project up` enters the chain already
   built. Runtime launchers receive a parent-generated runtime `<project>.dhall` **streamed in-place**
   (over the launch `stdin`, written before dispatch — no config bind-mount). In the current demo the
   payload is derived by `psFrameContext`, not by the announcing `context-init` action; the target plan
   unifies projection and delivery.
   See [code_check_doctrine.md](code_check_doctrine.md#derived-images) and
   [binary_context_config](../architecture/binary_context_config.md).
4. **Link executables statically; build libraries with `shared: True`.** Do not pass
   `--enable-executable-dynamic` or `--enable-executable-static`. See
   [linking_and_optimization.md](linking_and_optimization.md#recommended-policy).
5. **Treat the inherited store as an optimization.** `cabal build --dry-run` can diagnose reuse, but a
   third-party package in the plan is a permitted cache miss. Add broadly useful dependencies to the
   descriptive manifest under [`core/warm-deps/`](../../core/warm-deps/) when useful; do not contort
   consumer constraints merely to force a hit. Publication uses the real demo as an online compatibility
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
- A platform-locked artifact that cannot be produced inside a container is built on the **bare host**
  with no build VM (the headless host-build shape, composition pattern #7), then staged into the
  cluster — never run in a VM. The first worked instance is CUDA-on-Windows (`ensure cudawin`: NVIDIA
  driver + CUDA Toolkit + MSVC via winget), whose nvcc artifacts are produced on the Windows host and
  copied out. See [composition_patterns.md](composition_patterns.md).

Building the project **container** is the invoked binary's job (its `check-code` gate), not the
bootstrapper's. A `./.build/<executable>` is always present after a successful bootstrap, regardless of
substrate. The notation `<project>` elsewhere on this page denotes the validated single build identity:
Cabal filename stem = package name = executable stanza = invoked/declared CLI program name. Broader
opaque plan/resource identity remains in the later lifecycle phases; see
[schema](schema.md#project-and-executable-identity).

## Worked compliant Dockerfile shape

```dockerfile
# check=skip=InvalidDefaultArgInFrom

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace/app

COPY . /workspace/app

RUN cabal build --enable-tests --enable-benchmarks all \
    && install -m 0755 "$(cabal list-bin --enable-tests --enable-benchmarks exe:app)" /usr/local/bin/app

RUN app project init --role image-build-container --output /usr/local/bin/app.dhall

RUN app check-code

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/app"]
```

The `# check=skip=InvalidDefaultArgInFrom` parser directive on line 1 silences a BuildKit lint
warning: the linter evaluates `FROM ${BASE_IMAGE}` against the static empty `ARG` default (the value
is supplied as a build arg) and reports an "invalid base image name." The directive is required
boilerplate for every derived project that follows the `FROM ${BASE_IMAGE}` pattern.

Its `cabal.project`:

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

The `project init --role image-build-container` line is the container-image bootstrap hook. It is the only
binary entry point in the Dockerfile that may run before the sibling config file exists; later build-time
commands such as `check-code` load that config and refuse commands not valid for the image-build frame. At
runtime the parent lifecycle **streams** the role-specific `<project>.dhall` into the container
in-place — piped on the `docker run` `stdin`, written to `/usr/local/bin/<project>.dhall` by the entrypoint
before dispatch (no config bind-mount). The current payload comes from `psFrameContext`; target
projection/delivery is one plan node. The container enters the chain with `project up` (a Kubernetes
service pod instead receives a ConfigMap override).

## Current Status

The implemented binary surface is the `project` chain, and the core command tree is exactly `project`,
`test`, `service`, `context`, and `check-code`. Hardware evidence and closure status belong in the
development plan:

- opaque validated `StepPlan` is recursively interpreted by `project up`. Current `down`/`destroy` perform
  current-frame cleanup plus a project hook; recursive child-to-parent teardown remains a target.
- `context` is read-only introspection: `inspect` renders the lift composition with the current frame
  marked, `show` decodes a selected project-local config, `path` prints its canonical filename, and
  `schema`/`render` expose the separate static `ConfigArtifact` registry. The validated-codec
  project-local `cfg` shape is emitted by `service schema`.
- `test init` writes the sibling `<project>.test.dhall`; `test run <case-id>|all` runs a compiled case or
  the whole matrix with `all`. The help calls this root-only, but a root context gate is not currently
  enforced.
- `service init|schema|run` runs long-running roles as leaf-frame service handlers.
- `check-code` runs the project's fail-fast code-check gate.
- `ensure` is a reconciler library, not a command. Core exposes `ensureStep`, but the current demo
  invokes `runEnsure` from composite provider/build/accelerator actions.

The demo's deploy is the contributed `demoChainFor :: Substrate -> ProjectConfig -> [Step]` value in
`demo/src/HostBootstrapDemo/Commands.hs` — a list of `Step` the core interprets across the selected fractal
descent. The demo contributes its `web` and `accelerator` service variants (run by `service run`; the
build-time bridge folds into the build-image step) and its VM/provider IO as chain steps — the surface is
fixed, so it adds no verbs. The image-build hook runs as `project init --role image-build-container`.

A single `project up` is intended to stand up the live persistent stack — a cordoned kind cluster
(kind `extraPortMappings` publish NodePorts to the VM localhost) → the in-cluster registry
(NodePort 30500) → the project image pushed to that registry → the web chart pod →
`localhost:30080` serving HTTP 200. Current teardown performs owned current-frame cleanup plus a project
hook; the target recursive child-first inverse remains open.
The target registry step is contributed from an opaque finalized plan that jointly binds client scope,
verified exposure, backing endpoint, and blob delivery. A consumer must not pass raw endpoints or
choose `storage.redirect.disable` independently; see
[network reachability](../architecture/network_reachability.md).
`test run all` drives that same chain, but the demo currently resolves its cluster with the Production
profile and `.data`; see [harness workflow](../architecture/harness_workflow.md).
`DEVELOPMENT_PLAN/` owns the phase status; this page describes the model and the worked `demo/` consumer
that realizes it.

## See also

* [composition_methodology](../architecture/composition_methodology.md) — the canonical model: chain-is-the-project, the recursive `project up` interpreter, fractal bootstrap
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
