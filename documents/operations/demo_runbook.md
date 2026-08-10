# hostbootstrap-demo Runbook

**Status**: Authoritative source
**Supersedes**: the fully validated, recursively torn-down, test-scoped demo narrative
**Referenced by**: [documents index](../README.md), [testing](../engineering/testing.md), [binary context](../architecture/binary_context_config.md), [WSL2](../engineering/wsl2.md)

> **Purpose**: Give operators an honest guide to the demo's current command surface, lift chain,
> durable path, harness behavior, and validation limitations.

## TL;DR

- `hostbootstrap-demo` is a project binary that depends on `hostbootstrap-core` and contributes one
  substrate-selected `chain :: ProjectConfig -> [Step]`. There is no base-image LABEL/ENTRYPOINT
  integration mode.
- Current `project up` executes the exact current-frame Chain and fails closed when it reaches a declared
  nested entry. Current `project down`/`destroy` execute the retained plan's current-frame reverse
  projection. The **target** recursively authenticates each child invocation; the operator sequence remains
  root-only, with no nested form to type. The authenticated-handoff phase supplies the child-plan authority
  substrate, while the
  [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) owns
  Production descent, child acquisition integration, and recursive forward/reverse traversal.
- The chain includes MinIO before the registry and places the accelerator daemon after the workload.
- Host `.data` is carried through the stable `/var/tmp/hostbootstrap-demo-data` Linux alias into
  kind/nvkind and the pod. The same-run destroy/up/readback assertion remains open.
- `test run <case-id>|all` selects compiled cases. The parser does not enforce the documented root gate,
  but each variant is admitted under an exact Harness plan and owns `.test_data/<runId>`. The long gate
  still creates real provider, Docker, and cluster state, so use a disposable host with no production demo
  state.

## Current Status

The host-native binary, frame handoff, provider folds, project-image build, kind/nvkind lifecycle, MinIO
and registry deployment, chart, web/accelerator services, and compiled harness cases exist. Static tests
cover many pure builders and failure paths. Current native-hardware closure, exact test totals, and dated
evidence belong only in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

Open operator-significant defects are:

- opaque plan/resource-indexed readiness exists, but live mutation gating is incomplete;
- teardown is not recursive and ownership receipts are not universal;
- Harness keeps an exact run-scoped plan, but cluster/provider/mount/teardown consumers still receive
  config-derived profile/root terms independently;
- the same-run `durable-readback` recreate transition is not implemented;
- bare Linux has no runtime storage quota or image-GC wall.
- the registry may redirect a repeated host-client blob request to cluster-only
  `minio.default.svc`; `/v2/` and Deployment readiness do not prove the blob route.
- terminal Apple, NVIDIA, and Windows acceptance reruns remain owned by their substrate phases.

## Build and Config

The Python entry point builds the sole Cabal executable host-native into `.build/<executable>` and hands
off its arguments. It discovers exactly one top-level Cabal file, runs `cabal update`, and is not an
offline path. See [Python/Haskell boundary](../architecture/python_haskell_boundary.md).

The demo host build and later Linux image build both use `demo/cabal.project`. It contains no
base-owned absolute import; the container inherits the warm store opportunistically and may compile
cache misses. Published-base pull behavior is documented in
[build and run model](../architecture/build_and_run_model.md).

Initialize the executable-sibling root config with:

```text
hostbootstrap-demo project init
```

Normal commands load that sibling `hostbootstrap-demo.dhall`. Current child configs adjust context but
retain the full demo project record and raw parent envelope; they are not least-privilege parameter
types. Their ownership is also split: the composite pristine-bootstrap derives/streams the VM config,
the descent the `context-init` step declares carries the container payload that the handoff streams, and
deployment actions render service/daemon ConfigMaps. That step's action body only announces the
container handoff and anchors the frame. VM/container payloads are written at the child's executable-sibling path before
dispatch; there is no config bind-mount. The target plan owns projection/delivery as one operation and
emits a role-specific payload.

## Inspect Before Mutating

The read-only context surface is:

```text
hostbootstrap-demo context inspect
hostbootstrap-demo context path
hostbootstrap-demo context show [FILE]
hostbootstrap-demo context schema
hostbootstrap-demo context render [--artifact NAME]
```

Use `project up --dry-run` to render the selected step chain without applying it.

## Bring-up Chain

VM-backed lanes descend host → provider VM → project container. Native Linux GPU uses a direct
host → GPU-enabled project-container path and nvkind. The provider abstraction is
`SubstrateProvider`/`LiftLayer`, with no parallel target dispatcher.

The workload segment is ordered:

```text
deploy-kind or nvkind
  -> deploy-minio
  -> deploy-registry
  -> push-image
  -> deploy-chart
  -> expose-port
  -> accelerator-daemon placement
```

MinIO creates the S3 backing and bucket before the registry. The accelerator daemon is in-cluster for
Linux CPU/GPU and host-native after private ingress for Apple Silicon/Windows GPU.

Run:

```text
hostbootstrap-demo project up
```

Most reconcilers currently return `IO ()`; “reconcile-to-running” is an operational intention, not a
typed report of created/adopted/repaired/unchanged state.

## Durable Data

The current data path is:

```text
<project-root>/.data
  -> provider-specific share/mount
  -> provider guest /var/tmp/hostbootstrap-demo-data
  -> kind/nvkind node /var/lib/hostbootstrap-demo-data
  -> pod /var/lib/hostbootstrap-demo-data/web
```

`/var/tmp/hostbootstrap-demo-data` is a provider-guest Docker-visible projection, not the canonical
store. WSL2, Incus, and Lima use it after carrying the canonical host root into their guest. Direct
Linux instead binds the canonical absolute host `.data` path; the guest alias remains a
provider-local projection for VM-backed lanes only.

Cluster teardown omits the configured data path from its removal set. The `durable-readback` harness case
specifies the end-to-end proof — write through the running service, perform a same-run `project destroy`
and fresh `project up`, then read the same bytes — but deliberately reports failure until the engine owns
that recreate transition. See
[durable state](../architecture/durable_state.md).

## Down and Destroy

```text
hostbootstrap-demo project down
hostbootstrap-demo project destroy
```

Each verb is a projection of the same validated plan: cluster cleanup runs only in an owning current
frame, and every other node runs the reverse effect its own step declared. Those may stop or remove the
provider, but the command does not first dispatch the same verb through every reachable child. Cleanup is best-effort and aggregates some failures, but it does not
yet carry verified ownership receipts for every resource and cannot promise orphan-free recovery after a
hard kill.

On Apple and Linux, `project down` returns the provider VM's CPU and memory to the host. On Windows it
first restores the journalled `.wslconfig` origin, including an absent origin, and then invokes the
global `wsl --shutdown`. That ordering makes the next cold boot read the restored configuration; the
shutdown stops every distro and releases the shared utility VM's memory balloon. The current Windows
gate proves this wall-release observable, not the broader recursive-teardown or durable-readback work.

The managed six-hour idle timeouts are a backstop only when a run is interrupted before teardown. In
that case an operator can run `wsl --shutdown` manually, after accounting for its disclosed effect on
every WSL distro. See [wsl2](../engineering/wsl2.md) § Wall release.

The provider disk may be removed by `destroy`; the canonical host durable root is shared from outside
that disk and is not intentionally included in cluster removal. Structural preservation is implemented,
but same-run reattachment/readback remains the worked-demo acceptance obligation on every lane.

## Demo Harness

Initialize and run:

```text
hostbootstrap-demo test init
hostbootstrap-demo test run <case-id>
hostbootstrap-demo test run all
```

The compiled case ids are `pristine-bootstrap`, `web-build`, `e2e-tabs`,
`registry-persistence`, and `durable-readback`. They are Haskell code, not dynamically defined by
`<project>.test.dhall`. The demo test file decodes as:

```haskell
data TestConfig = TestConfig
  { testResources :: Resources
  , testVariants :: [TestVariantConfig]
  }
```

Case selection uses opaque compiled `CaseId`s and a validated total `TestMatrix`; `all` is only a parser
selector. `testVariants` declares the two stable message variants, and `demoTestMatrix` projects every
compiled case across them before the run acquires anything. The command retains one exact Harness plan,
drives the common current-frame forward interpreter, runs assertion-only cases, and drives the common
reverse projection directly.

Important safety warning: help describes this as root-only, but the parser does not enforce a root context
gate. The command's independent Harness authority prevents Production plan admission and the owned run root
is `.test_data/<runId>`, but profile/root terms remain independently consumed until the
[worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) completes exact plan-owned projection.
Existing-config and production-cluster preconditions reduce collision risk; the long gate still belongs on
a disposable host because it creates real host infrastructure.

The case intentions are:

| Case id | Assertion scope |
|---|---|
| `pristine-bootstrap` | provider/bootstrap/build path |
| `web-build` | image check-code and web artifact path |
| `e2e-tabs` | SPA/API/accelerator behavior |
| `registry-persistence` | registry data across registry-pod recreation |
| `durable-readback` | target: web write → same-run destroy → fresh same-run up → web read from `.test_data/<runId>`; currently deliberately fails before that transition |

Those cases do not replace recursive teardown, receipt-bound ownership, same-run recreate, or
native-substrate acceptance gates.

## Safe Operating Guidance

- Do not run the long harness on a machine carrying production demo state.
- Treat the public web (`30080`), registry (`30500`), and MinIO (`30900`) NodePorts as
  development-only listeners: current kind configs bind them to `0.0.0.0`. The registry is anonymous
  HTTP, and MinIO uses fixed source credentials rendered into a Kubernetes Secret. Only accelerator
  ingress `30081` is loopback-bound.
- Treat a wrong or occupied durable alias as a conflict; do not delete it by pathname alone.
- Do not point a derived build at a locally rebuilt base. Pull the published tag; the host-native lane
  requires its repository digest and refuses an image with no registry digest.
- On Windows, follow [durable Windows runs](../engineering/durable_windows_runs.md) for the long gate.
- Follow explicit recovery guidance when a command emits it. Structured recovery dispositions are target
  behavior, not universal today; do not manually unregister/delete a provider unless you have separately
  established ownership.

## Related

- [harness workflow](../architecture/harness_workflow.md) — exact Harness plan ownership and remaining
  profile/root consumer adoption.
- [lifecycle state model](../architecture/lifecycle_state_model.md) — typed transition and ownership
  contract.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — current kind/nvkind operations.
- [accelerator daemon](../engineering/accelerator_daemon.md) — service placement and remaining live gates.
