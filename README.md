# hostbootstrap

**Status**: Governed orientation document
**Supersedes**: prior root README without metadata
**Canonical homes**: [documents/README.md](documents/README.md), [DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md), [documents/architecture/hostbootstrap_core_library.md](documents/architecture/hostbootstrap_core_library.md), [documents/architecture/unrepresentable_state.md](documents/architecture/unrepresentable_state.md)

> **Purpose**: Orient consumers to the Haskell core, thin Python bootstrapper, fixed project-binary
> surface, and the canonical documentation and implementation-status homes.

`hostbootstrap` is the reusable host-management layer for the project family. It combines:

- `hostbootstrap-core`, a Haskell library used by project binaries; and
- a thin Python CLI that establishes the minimum host build floor, builds the project binary
  host-native into `./.build/`, and executes it.

Canonical architecture and engineering guidance lives under [documents/](documents/README.md).
Implementation state, open work, acceptance criteria, and dated evidence live under
[DEVELOPMENT_PLAN/](DEVELOPMENT_PLAN/README.md). This README is intentionally an orientation layer, not
a second design or status authority.

## Architecture

Every consumer ships one project binary over a fixed command tree. Projects contribute configuration,
steps, test cases, generated artifacts, and service handlers through `ProjectSpec`; they do not add
verbs.

A project authors an opaque validated `StepPlan`; dispatch admits it into one exact
`ProjectPlan scope specDigest planId configId cfg`. The root coordinator retains the protected store,
lease, snapshot, recursive catalog, and per-frame journals. At each declared descent it authenticates a
storeless child executor, grants only the selected node's prepared operations, and settles the returned
observations. Reverse traversal visits children before parents and releases only resources whose exact
ownership is established. Production closure requires settled destroy evidence or a verified pre-effect
refusal, and interrupted closure resumes through durable redo records.

`ProjectSpec`, `Step`, and `StepPlan` are opaque. Finalization rejects empty, duplicate, non-contiguous,
shadowed, or replacement-lossy contributions and preserves the accepted forward order. Every step carries
a reverse policy, operation key, and validated dependency prefix. See
[composition methodology](documents/architecture/composition_methodology.md) and the canonical
[lifecycle state model](documents/architecture/lifecycle_state_model.md).

The demo has one universal CPU floor, `linux-cpu`, realized through the outer host's provider. The
hostbootstrap DSL then lifts the application into the plan-selected hardware context, which may add Metal,
NVIDIA, or Windows-host CUDA capabilities and placement:

| Outer host | `linux-cpu` realization | Container/cluster path |
|---|---|---|
| Apple Silicon | Lima/Colima Linux VM | Docker project container → kind |
| Native Linux CPU | native Linux runtime (with Incus where the plan declares a VM frame) | Docker project container → kind |
| Windows | WSL2 Linux VM | Docker project container → kind |
| Native Linux GPU | native Linux runtime plus the NVIDIA acceptance dimension | Docker project container → nvkind |

The outer host tag selects transport, ownership, and provider mechanics. The hardware context selected by
the plan determines the real execution target and its typed capabilities; every such route retains
`linux-cpu` as the portable baseline rather than replacing it. The host-native binary establishes the
selected realization and re-enters the project binary at each declared frame.

The sibling `<project>.dhall` contains project parameters plus descriptive frame context and witnesses;
it never contains the chain. Decoded context remains descriptive by design and never becomes authority.
The implemented lower gate independently verifies executable-bound installed identity, OS access to the
exact protected store, broker generation, root scope, and one-use reservation. Lifecycle gates then join
that foundation to project-, plan-, frame-, verb-, phase-, config-, revision-, instance-, and
operation-indexed evidence. Cross-process config handoff, delayed recovery, controller restarts, and build
checks each use distinct authenticated gates; config text or a stable resource name cannot mint
authority.

The handoff receiver verifies a root-signed scope capsule against the independently installed identity
and key before admitting any payload. Nested links relay exact bytes without signing or storage authority.
The root validates the catalog, requester path, session, ordinal, nonce, and predecessor digest before
signing a response or changing durable state. Exact replay converges; mismatched ancestry or evidence
refuses. See [binary context and authenticated handoff](documents/architecture/binary_context_config.md).

## Ownership Boundary

In the ordinary `doctor`/`build`/`run` project path, the Python bootstrapper owns only work that must
happen before a project binary exists:

1. assert irreducible host minimums;
2. establish the native Haskell build toolchain and Cabal index;
3. build the project binary host-native into `./.build/`; and
4. execute it with the requested arguments.

It does not initialize Dhall, ensure Docker, provision the VM, build the project image, create the
cluster, deploy services, or tear them down. Those are Haskell/project-binary responsibilities. See the
[Python/Haskell boundary](documents/architecture/python_haskell_boundary.md) and
[prerequisites](documents/engineering/prerequisites.md).

Two explicit distribution/maintainer surfaces sit outside that project-runtime boundary:
`hostbootstrap update` updates the pipx application, and the repository-only `base` command builds or
publishes base images when an operator requests it. Neither surface becomes a child lifecycle step or
gives Python ownership of project config, providers, images, clusters, services, or teardown.

The rolling base image contains the container-build toolchain and an opportunistic Cabal store; it does
not contain the host-native project binary. Builds discover current compatible upstream versions, and
host/container consumers use one ordinary `cabal.project` with online cache misses allowed. Published
`docker.io/tuee22/hostbootstrap:basecontainer-<flavor>-<arch>` tags are the derived-build source of
truth. Base Dockerfile or warm-store changes require rebuilding and republishing the affected tag before
consumers pull it; publication/live compatibility smoke requires explicit operator authorization. See
[base image](documents/engineering/base_image.md).

## Configuration

Configuration is strict, binary-owned Dhall:

- `<project>.dhall` is the project/frame runtime config next to the executable.
- `<project>.test.dhall` is the project-defined test input written by `test init`.
- Opaque `ConfigArtifact` values contribute generated vocabulary/schema/render artifacts through one
  admitted `CodecWitness`, so schema, decode, and render share a validated encoder/decoder type.
- child frames receive role-specific parameter and resource projections: the finalized projector derives
  each exact child configuration, and a service or daemon consumer receives only its narrowed
  `RuntimeRoleWire` together with separately verified opaque authority.

The demo's config includes its own resources, deploy settings, context, and message fields.
`hostbootstrap-core` owns no universal project config or project defaults. The extension is generic over
`ProjectSpec cfg tcfg`, with `cfg :: Type -> Type`:
`cfg (Production projectId)` cannot be confused with `cfg (Harness projectId runId)`.

Host exposure is intentionally not another Dhall setting. Project config names semantic services and their
stable cluster-internal targets; after cluster readiness, the container runtime atomically assigns
loopback-only host ports to an owned relay. Only authenticated inspection of that exact runtime resource
produces the resolved endpoints used by registry, web, MinIO, accelerator, and test clients. See
[network reachability](documents/architecture/network_reachability.md).

`SecretRef scope` makes plaintext constructible only with matching
`HarnessConfigAuthority projectId runId`, and the Production wire schema has no plaintext alternative.
Root-local assembly and codec validation enforce this now. Normal parent-to-child handoff and
restartable-controller runtime verification remain later lifecycle work; the runtime target reads the
activation-bound private channel internally and mints no `HarnessConfigAuthority`. See
[generic project model](documents/architecture/generic_project_model.md) and
[secrets](documents/engineering/secrets.md).

Projects with a provider budget carry one host-level ceiling. `Cluster.Budget` admits the
topology-derived workload set against it, and an applied cordon proves that concurrent slices plus
overhead fit. See [resource budgeting](documents/engineering/resource_budgeting.md) and
[applied cordon](documents/engineering/applied_cordon.md), which own that contract.

## CLI Surface

Two programs use the `hostbootstrap` name.

The pipx-installed Python CLI exposes:

| Command | Purpose |
|---|---|
| `hostbootstrap doctor` | Detect the host and verify irreducible minimums |
| `hostbootstrap build` | Build the project binary host-native; do not execute it |
| `hostbootstrap run [args...]` | Build, then execute the project binary |
| `hostbootstrap update` | Explicitly update the pipx app |

The supported maintainer context is the repository Poetry environment, which additionally exposes
`base`, `check-code`, and `test-all`. The parser verifies the canonical checkout, its in-project Poetry
interpreter, lock/project metadata, and development tools before minting opaque maintainer authority;
making development modules importable in a consumer pipx environment does not expose those commands.
Self-update is never implicit.

Every Haskell project binary exposes the fixed tree:

| Command | Behavior |
|---|---|
| `project init` | Write the project-owned sibling config |
| `project up` | Interpret the admitted plan and authenticate each declared descent, granting the child only its selected node's prepared operations; `--dry-run` renders the admitted plan |
| `project down` | Child-first reverse traversal plus stop-mode project hook, releasing only resources whose ownership is established |
| `project destroy` | Child-first reverse traversal plus delete-mode project hook, closing only on settled destroy evidence or a verified pre-effect refusal |
| `test init` | Write `<project>.test.dhall` without requiring a project config |
| `test run <case-id>\|all` | Generate each variant, directly drive its exact Harness current-frame forward/reverse around assertions, then close only after settled destroy |
| `service init\|schema\|run` | Initialize/inspect service config or run one config-selected leaf service |
| `context inspect\|path\|show\|schema\|render` | Read-only context/config introspection |
| `check-code` | Run the inherited project quality gate |

That tree is the whole surface a project or an operator reaches; projects add no verb. One internal
marker exists beside it and is deliberately not a command: it is how a binary recognizes that it is the
process on the far side of a frame crossing, which no verb can express, and it carries no coordinates,
path, authority, or caller-selected action. See
[the library surface](documents/architecture/hostbootstrap_core_library.md) for exact parser and
dispatch behavior.

## Install

Install `pipx`, then install the CLI:

```bash
pipx install "hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@main"
```

Update it explicitly:

```bash
hostbootstrap update
```

For a local checkout:

```bash
pipx install --force /path/to/hostbootstrap
```

## Demo

[`demo/`](demo/) is the worked `hostbootstrap-core` consumer. Its chain provisions the selected provider,
builds the project image, creates kind/nvkind, deploys MinIO and the anonymous HTTP in-cluster registry,
pushes the image, deploys the web and accelerator services, and verifies exposure. Automatic host exposure is
runtime-owned: host-port numbers are absent from Dhall and Kind/nvkind rendering, the container runtime
atomically selects loopback ports for identity-owned relays, and application clients consume only the
authenticated resolved endpoints. Stable Kubernetes Service/NodePort values remain internal targets.
The registry route binds client scope, exposure, backend, and delivery in one opaque plan, so the host
Docker client cannot be redirected to cluster-only MinIO. See
[network reachability](documents/architecture/network_reachability.md) and the
[in-cluster registry guide](documents/engineering/in_cluster_registry.md).

The stable `/var/tmp/hostbootstrap-demo-data` pathname is a provider-guest projection of the project's
host-backed durable root, not a portable direct-host path or the canonical store. The target resolves
descriptive `sourceRoot` once into opaque canonical-root authority: direct-host Docker binds the actual
absolute `<project-root>/.data`, while WSL2, Incus, and Lima may reconcile their own typed guest alias.
The Harness profile uses `.test_data/<runId>`. See
[durable state](documents/architecture/durable_state.md).

From `demo/`, the normal consumer flow is:

```bash
hostbootstrap run -- project init \
  --cpu 6 --memory 10GiB --storage 80GiB --ha-replicas 1
hostbootstrap run -- project up --dry-run
hostbootstrap run -- project up
hostbootstrap run -- context inspect
hostbootstrap run -- project destroy
```

The root `project init` also installs or validates the executable-sibling handoff key pair and the separate
build-signing key. Rebuilds and `--force` retain valid identities; inconsistent material refuses instead of
silently rotating the project trust root.

The current `context-init` row's action body is only an announcement. VM config is produced/streamed
inside the composite VM bootstrap action; container config rides the descent that same `context-init`
row declares, so the announced boundary and the delivered bytes are one plan node; and service config is
delivered through a ConfigMap. The target gives projection and authenticated delivery one plan-owned
operation.

## Tests

Run the supported fast suites from their project roots:

```bash
# Repository root: Python
poetry run python -m hostbootstrap.test_all

# core/: Haskell core + documentation validator
cabal test all

# demo/: demo + local core workspace
cabal test all
```

The demo command is the canonical static entry point. Its test component carries the same threaded RTS
contract as the executable because `WebServerSpec` starts Warp; a component-contract test prevents that
option from being removed silently.

Do not invoke `pytest` directly; the supported Python runner establishes the suite sentinel.

These fast suites are the **host static gate**. The project binary is built host-native on every
substrate, so they run as ordinary processes of the outer host and are expected to pass host-native on
macOS, Linux, and Windows alike — no WSL2 distro, container, or durable launcher involved. That is a
different thing from a `linux-cpu` substrate gate, whose process and POSIX/container effects execute
inside the realized Linux environment. The gate kinds, what each proves, and the portability rules the
harness holds are in [documents/engineering/testing.md](documents/engineering/testing.md#gate-kinds).

The live demo harness is separate:

```bash
cd demo
hostbootstrap run -- test init
hostbootstrap run -- test run all
```

Current safety checks refuse an existing sibling project config or detected production cluster. Each
variant assembles a Harness-scoped config, retains one exact Harness `ProjectPlan` through generated
config ownership, and invokes the common recursive forward and reverse interpreters; assertion code has
no lifecycle route and durable state is isolated under `.test_data/<runId>`. The `durable-readback` case
declares two assertion phases around an engine-owned settled destroy, protected fresh invocation, exact
plan rebind, and second forward while retaining one report row. Run the long gate only on a
disposable host with no production demo state. On Windows the gate also holds the project's full
CPU/memory budget in the shared WSL2 utility VM while it runs; normal `project down` restores the
journalled `.wslconfig` origin and then shuts that VM down globally to release the wall (see
[documents/engineering/wsl2.md](documents/engineering/wsl2.md)). Its Playwright case executes the
already-built project image with `--network host` in the VM frame and points `BASE_URL` at that VM's
exact runtime-resolved web exposure.
Authoritative current evidence and remaining live substrates are in the
[development-plan index](DEVELOPMENT_PLAN/README.md).

## Current Status

The contracts this README describes are built. Readiness and reconciliation are plan- and
resource-indexed; polling, probes and prepare-time precondition sets are opaque and validated;
operation sessions are versioned and one-use over durable fences with crash-recoverable journals; the
four-clause ownership invariant holds over one closed seam with a platform row beneath it; there is one
validated forward/topology/reverse plan; handoffs are authenticated in both the normal and recovery
directions; the Production/Harness mode lease is project-wide; and project, step and config
constructors cannot represent contradictory states. Spawning a child that outlives its launcher is a
closed boundary whose stdio disposition, descriptor inheritance, session, environment and working
directory are properties of a type rather than fields a call site fills in — see
[`Detached`](core/hostbootstrap-core/src/HostBootstrap/Detached.hs). The method every one of those
boundaries applies is stated once in
[documents/architecture/unrepresentable_state.md](documents/architecture/unrepresentable_state.md), and
each claim of unrepresentability ships a registered compile-fail fixture.

The host static gate passes host-native on every supported outer host, and the suites assert from none
of them in particular: the host-portability acceptance phase records separate native Windows, macOS and
Linux runs, and the per-platform difference in their totals is enumerated against the suites' own
declared platform conditions rather than left to the run.

**The plan currently carries open work.** Phase status, what each open phase owes, and the deletion
ledger are authoritative only in
[DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md) and
[design rationale](DEVELOPMENT_PLAN/rationale.md). This page deliberately does not restate them: a root
document that carries its own status list becomes a second authority that drifts from the first, which
is what [the documentation standard](documents/documentation_standards.md) forbids.

## Repository Map

```text
.
├── core/hostbootstrap-core/    # Haskell library, bare binary, Dhall, tests
├── core/warm-deps/             # container warm-store package
├── demo/                       # worked project consumer and its Cabal workspace
├── hostbootstrap/              # thin Python CLI
├── tests/  stubs/              # Python tests and typing stubs
├── docker/                     # published base-image definition
├── documents/                  # canonical architecture/engineering/operations guidance
└── DEVELOPMENT_PLAN/           # implementation status, phases, and deletion ledger
```

## License

MIT. See [LICENSE](LICENSE).
