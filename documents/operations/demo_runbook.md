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
- `project up` recursively descends the chain, and `project down`/`destroy` drive the same plan's reverse
  projection, descending into each child frame to invoke the verb there. The **operator** sequence is
  unchanged by that and stays root-only: you run these verbs at the project root, exactly as below, and
  there is no nested form to type. Admitting the descent's nested invocation is a target contract owned by
  [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md);
  until it lands, teardown settles the frames one binary can reach and reports the rest outstanding.
- The chain includes MinIO before the registry and places the accelerator daemon after the workload.
- Host `.data` is carried through the stable `/var/tmp/hostbootstrap-demo-data` Linux alias into
  kind/nvkind and the pod. The live destroy/up/readback proof passed on the native Linux GPU lane.
- `test run <case-id>|all` selects compiled cases. The parser does not enforce the documented root gate,
  and the demo currently selects Production/`.data`; use the long gate only on a disposable host with no
  production demo state.

## Current Status

The host-native binary, frame handoff, provider folds, project-image build, kind/nvkind lifecycle, MinIO
and registry deployment, chart, web/accelerator services, and compiled harness cases exist. Static tests
cover many pure builders and failure paths. Current native-hardware closure, exact test totals, and dated
evidence belong only in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

Open operator-significant defects are:

- opaque plan/resource-indexed readiness exists, but live mutation gating is incomplete;
- teardown is not recursive and ownership receipts are not universal;
- the demo harness resolves the Production profile and `.data`;
- bare Linux has no runtime storage quota or image-GC wall.
- the registry may redirect a repeated host-client blob request to cluster-only
  `minio.default.svc`; `/v2/` and Deployment readiness do not prove the blob route.
- the registry/MinIO and ownership items above are the open ones; the Apple Silicon lane is not. It
  passed `test run all` at `10/10` on 2026-08-03 once the host-daemon launch boundary was sealed, so
  every supported substrate now has a passing worked-demo run.

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
host → GPU-enabled project-container path and nvkind. The active provider abstraction is
`SubstrateProvider`/`LiftLayer`; the former parallel `HostTarget` helpers have been removed.

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
Linux instead binds the canonical absolute host `.data` path (Sprint 5.6.1); the guest alias remains a
provider-local projection for VM-backed lanes only.

Cluster teardown omits the configured data path from its removal set, and the `durable-readback` harness
case proves the end-to-end path: a marker written through the running service survives `project destroy`
and is read back after `project up`. It has now passed on the native Linux GPU lane and, on 2026-08-03,
on the Apple Silicon/Lima lane on both config variants. See
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

The provider disk may be removed by `destroy`; host `<project-root>/.data` is shared from outside that
disk and is not intentionally included in cluster removal. Reattachment is proved by the
`durable-readback` case on the direct Linux lane; do not infer it for a provider lane that has not run
that case.

## Demo Harness

Initialize and run:

```text
hostbootstrap-demo test init
hostbootstrap-demo test run <case-id>
hostbootstrap-demo test run all
```

The compiled case ids are `pristine-bootstrap`, `web-build`, `e2e-tabs`,
`registry-persistence`, and `durable-readback`. They are Haskell code, not dynamically defined by `<project>.test.dhall`. The demo test
file currently decodes as:

```haskell
newtype TestConfig = TestConfig { testResources :: Resources }
```

Case selection uses opaque compiled `CaseId`s and a validated total `TestMatrix`; `all` is only a parser
selector. The demo's current Haskell projection creates two stable message variants using
`testResources` (Phase 20 will move that concrete mapping into config). The harness drives the real
`project up`, asserts, and
invokes `project destroy`.

Important safety warning: help describes this as root-only, but the parser does not enforce a root
context gate. More seriously, demo plan resolution hardcodes `Production`, so the live test stack uses
the production cluster identity and `.data`, not the generic Test/`.test_data` helpers. Existing-config
and production-cluster preconditions reduce one class of collision but do not make this safe around real
production state.

The case intentions are:

| Case id | Assertion scope |
|---|---|
| `pristine-bootstrap` | provider/bootstrap/build path |
| `web-build` | image check-code and web artifact path |
| `e2e-tabs` | SPA/API/accelerator behavior |
| `registry-persistence` | registry data across registry-pod recreation |
| `durable-readback` | web write → project destroy → project up → web read from host `.data` |

Those cases do not replace the missing `Harness projectId runId` profile, recursive-teardown, or
native-substrate gates.

## Safe Operating Guidance

- Do not run the long harness on a machine carrying production demo state.
- Treat the public web (`30080`), registry (`30500`), and MinIO (`30900`) NodePorts as
  development-only listeners: current kind configs bind them to `0.0.0.0`. The registry is anonymous
  HTTP, and MinIO uses fixed source credentials rendered into a Kubernetes Secret. Only accelerator
  ingress `30081` is loopback-bound.
- Treat a wrong or occupied durable alias as a conflict; do not delete it by pathname alone.
- Do not point a derived build at a locally rebuilt base. Pull the published tag and, once implemented,
  require its registry digest.
- On Windows, follow [durable Windows runs](../engineering/durable_windows_runs.md) for the long gate.
- Follow explicit recovery guidance when a command emits it. Structured recovery dispositions are target
  behavior, not universal today; do not manually unregister/delete a provider unless you have separately
  established ownership.

## Related

- [harness workflow](../architecture/harness_workflow.md) — current DSL/profile mismatch and target.
- [lifecycle state model](../architecture/lifecycle_state_model.md) — typed transition and ownership
  contract.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — current kind/nvkind operations.
- [accelerator daemon](../engineering/accelerator_daemon.md) — service placement and remaining live gates.
