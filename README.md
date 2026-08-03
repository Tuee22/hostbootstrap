# hostbootstrap

**Status**: Governed orientation document
**Supersedes**: prior root README without metadata
**Canonical homes**: [documents/README.md](documents/README.md), [DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md), [documents/architecture/hostbootstrap_core_library.md](documents/architecture/hostbootstrap_core_library.md)

> **Purpose**: Orient consumers to the Haskell core, thin Python bootstrapper, fixed project-binary
> surface, and the canonical documentation and implementation-status homes.

`hostbootstrap` is the reusable host-management layer for the project family. It combines:

- `hostbootstrap-core`, a Haskell library used by project binaries; and
- a thin Python CLI that establishes the minimum host build floor, builds the project binary
  host-native into `./.build/`, and executes it.

Canonical architecture and engineering guidance lives under [documents/](documents/README.md).
Implementation state, reopened work, acceptance criteria, and dated evidence live under
[DEVELOPMENT_PLAN/](DEVELOPMENT_PLAN/README.md). This README is intentionally an orientation layer, not
a second design or status authority.

## Architecture

Every consumer ships one project binary over a fixed command tree. Projects contribute configuration,
steps, test cases, generated artifacts, and service handlers through `ProjectSpec`; they do not add
verbs.

The implemented forward representation is an opaque validated `StepPlan`. `project up` interprets that
plan recursively: when it reaches another frame, the parent provisions the frame, builds or installs the
project binary there, projects a narrower sibling `<project>.dhall`, and invokes the child's own
`project up`. The Python bootstrapper is the outer, metal-frame instance of that same
provision → build-pb → handoff pattern.

`ProjectSpec`, `Step`, and `StepPlan` are opaque. Builder finalization rejects empty/duplicate,
non-contiguous, shadowed, or replacement-lossy contributions and preserves the exact accepted forward
order; every step carries a reverse policy, operation key, and validated dependency prefix. Frame-context
and teardown are still separate checked single-assignment contributions. The downstream target is one
opaque `ProjectPlan scope specDigest planId configId cfg` whose resource graph, frame placement, forward
operations, child handoffs, and reverse traversal are derived together. See
[composition methodology](documents/architecture/composition_methodology.md) and the canonical
[lifecycle state model](documents/architecture/lifecycle_state_model.md).

The demo's main substrate paths are:

| Host | Provider frame | Container/cluster path |
|---|---|---|
| Apple Silicon | Lima VM | Docker project container → kind |
| Native Linux CPU | Incus VM | Docker project container → kind |
| Windows | WSL2 distro | Docker project container → kind |
| Native Linux GPU | Direct host path | Docker project container → nvkind |

The sibling `<project>.dhall` contains project parameters plus descriptive frame context and witnesses;
it never contains the chain. Current gates validate useful mismatches, but decoded context is not yet
opaque authority. The target separates description from project-, scope-, plan-, frame-, verb-, phase-,
config-, revision-, instance-, and operation-indexed authority. Cross-process config handoff, delayed recovery,
controller restarts, and build checks each use distinct authenticated gates; config text or a stable
resource name cannot mint authority.

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
- child frames currently receive narrower descriptive context/capability declarations but retain the
  demo's full parameter record and resource envelope; the target uses role-specific parameter/resource
  projections plus separately verified opaque authority.

The demo's config includes its own resources, deploy settings, context, and message fields.
`hostbootstrap-core` owns no universal project config or project defaults. The extension is generic over
`ProjectSpec projectId cfg tcfg`, with `cfg :: Type -> Type`:
`cfg (Production projectId)` cannot be confused with `cfg (Harness projectId runId)`.

`SecretRef scope` makes plaintext constructible only with matching
`HarnessConfigAuthority projectId runId`, and the Production wire schema has no plaintext alternative.
Root-local assembly and codec validation enforce this now. Normal parent-to-child handoff and
restartable-controller runtime verification remain later lifecycle work; the runtime target reads the
activation-bound private channel internally and mints no `HarnessConfigAuthority`. See
[generic project model](documents/architecture/generic_project_model.md) and
[secrets](documents/engineering/secrets.md).

Projects with a provider budget carry one host-level ceiling. Current code validates decoded scalars and
host/provider capacity, but the complete topology-derived workload set is not yet passed through
`fitsBudget` before effects, and the demo chart does not yet apply matching requests/limits. That
full-plan gate is target work, not current evidence. See
[resource budgeting](documents/engineering/resource_budgeting.md).

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

| Command | Current behavior |
|---|---|
| `project init` | Write the project-owned sibling config; current shared init flags are broader than the target typed request |
| `project up` | Recursively interpret the forward chain; `--dry-run` renders it |
| `project down` | Current-frame cleanup plus stop-mode project hook; typed recursive reverse traversal is open |
| `project destroy` | Current-frame cleanup plus delete-mode project hook; typed recursive reverse traversal is open |
| `test init` | Write `<project>.test.dhall` without requiring a project config |
| `test run <case-id>\|all` | Generate each current variant, drive the real `project up`, assert, then attempt destroy |
| `service init\|schema\|run` | Initialize/inspect service config or run one config-selected leaf service |
| `context inspect\|path\|show\|schema\|render` | Read-only context/config introspection |
| `check-code` | Run the inherited project quality gate |

See [the library surface](documents/architecture/hostbootstrap_core_library.md) for exact parser and
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
pushes the image, deploys the web and accelerator services, and verifies exposure. In current manifests,
the registry, web, and MinIO host mappings are not all loopback-only, and MinIO defaults are
source-hardcoded; the target security repair is plan-owned.
The current S3 route also permits Distribution to redirect the host Docker client to cluster-only
`minio.default.svc`, so a repeated push can fail even when `/v2/` is Ready. The reopened target binds
client scope, exposure, backend, and delivery in one opaque plan; this topology can select only registry
proxy delivery. See [network reachability](documents/architecture/network_reachability.md) and the
[in-cluster registry guide](documents/engineering/in_cluster_registry.md).

The stable `/var/tmp/hostbootstrap-demo-data` pathname is a provider-guest projection of the project's
host-backed durable root, not a portable direct-host path or the canonical store. The target resolves
descriptive `sourceRoot` once into opaque canonical-root authority: direct-host Docker binds the actual
absolute `<project-root>/.data`, while WSL2, Incus, and Lima may reconcile their own typed guest alias.
That direct-host repair is reopened as Sprint 5.6.1; the target harness uses `.test_data/<runId>`. See
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

The live demo harness is separate:

```bash
cd demo
hostbootstrap run -- test init
hostbootstrap run -- test run all
```

Current safety checks refuse an existing sibling project config or detected production cluster, but the
demo planner still resolves Production/`.data`, some provider/Docker preparation precedes refusal, and
ownership receipts/recursive teardown are incomplete. Run the long gate only on a
disposable host with no production demo state. On Windows the gate also holds the project's full
CPU/memory budget in the shared WSL2 utility VM while it runs; normal `project down` restores the
journalled `.wslconfig` origin and then shuts that VM down globally to release the wall (see
[documents/engineering/wsl2.md](documents/engineering/wsl2.md)). Its Playwright case executes the
already-built project image with `--network host` in the VM frame and points `BASE_URL` at that VM's
localhost NodePort.
Authoritative current evidence and remaining live substrates are in the
[development-plan index](DEVELOPMENT_PLAN/README.md).

## Current Status

The implemented code is usable, but the stronger target is deliberately open. Planned repairs cover:

- total, plan/resource-indexed readiness and reconciliation;
- opaque validated polling/probes, closed prepare-time precondition sets, and backend effects that accept
  only the matching fresh prepared pair;
- versioned one-use operation sessions with durable initial/rotated fences and crash-recoverable acquisition,
  repair, phase-change, adoption, teardown, and migration journals;
- one ownership invariant every substrate can satisfy — an OS-released exclusive lock, a durable origin
  record written before the first mutation, binding to the object's kernel identity rather than its
  pathname, and release conditioned on re-observing that identity — plus exact ownership receipts and
  foreign-state refusal
  (see [documents/architecture/ownership_invariant.md](documents/architecture/ownership_invariant.md));
- one validated forward/topology/reverse plan;
- authenticated normal/recovery handoffs and controller/build config gates;
- a project-wide Production/Harness mode lease, exact bound-Production recovery profiles, exhaustive
  bound-run recovery, and restartable Open→Closing terminal harness cleanup; and
- opaque project/step/config constructors that cannot represent contradictory states.

Phase status, blockers, and deletion work are authoritative only in
[DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md) and
[legacy tracking](DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

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
