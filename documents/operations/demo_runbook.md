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
- `project up` recursively descends the chain. Current `project down`/`destroy` do not recursively invoke
  the lifecycle verb in every child; they perform current-frame cleanup plus a project hook.
- The chain includes MinIO before the registry and places the accelerator daemon after the workload.
- Host `.data` is carried through the stable `/var/tmp/hostbootstrap-demo-data` Linux alias into
  kind/nvkind and the pod. The live destroy/up/readback proof is still missing.
- `test run <case-id>|all` selects compiled cases. The parser does not enforce the documented root gate,
  and the demo currently selects Production/`.data`; use the long gate only on a disposable host with no
  production demo state.

## Current Status

The host-native binary, frame handoff, provider folds, project-image build, kind/nvkind lifecycle, MinIO
and registry deployment, chart, web/accelerator services, and compiled harness cases exist. Static tests
cover many pure builders and failure paths. Current native-hardware closure, exact test totals, and dated
evidence belong only in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

Open operator-significant defects are:

- readiness capabilities are publicly forgeable and mutation gating is incomplete;
- the direct-host durable-alias probe throws on a clean absent path;
- derived image builds may reuse a stale local mutable base tag because the builder omits `--pull`;
- the supported `demo/` static entry `cabal test all` currently fails because
  `hostbootstrap-demo-test` lacks `-threaded`, which Warp's timer manager requires;
- teardown is not recursive and ownership receipts are not universal;
- the demo harness resolves the Production profile and `.data`;
- no live gate proves workload write → destroy → up → host-and-workload readback;
- bare Linux has no runtime storage quota or image-GC wall.

## Build and Config

The Python entry point builds the sole Cabal executable host-native into `.build/<executable>` and hands
off its arguments. It discovers exactly one top-level Cabal file, runs `cabal update`, and is not an
offline path. See [Python/Haskell boundary](../architecture/python_haskell_boundary.md).

The demo host build uses `demo/cabal.project`. The later Linux image build uses
`demo/docker/container.cabal.project`, which imports the base image's absolute freeze. Do not use the
container project for the host build. The current mutable-base defect and digest target are documented in
[build and run model](../architecture/build_and_run_model.md).

Initialize the executable-sibling root config with:

```text
hostbootstrap-demo project init
```

Normal commands load that sibling `hostbootstrap-demo.dhall`. Current child configs adjust context but
retain the full demo project record and raw parent envelope; they are not least-privilege parameter
types. Their ownership is also split: the composite pristine-bootstrap derives/streams the VM config,
`psFrameContext` derives the container payload that the handoff streams, and deployment actions render
service/daemon ConfigMaps. The named `context-init` action only announces the container handoff and
anchors that frame. VM/container payloads are written at the child's executable-sibling path before
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
`SubstrateProvider`/`LiftLayer`; older `HostTarget` helpers are not the live dispatch model.

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
  -> /var/tmp/hostbootstrap-demo-data
  -> kind/nvkind node /var/lib/hostbootstrap-demo-data
  -> pod /var/lib/hostbootstrap-demo-data/web
```

`/var/tmp/hostbootstrap-demo-data` is a stable Docker-visible alias, not the canonical store. It hides
whether the underlying host directory arrived through WSL drvfs, an Incus disk device, a Lima mount, or
the direct Linux host, allowing one kind `hostPath` across lanes.

Cluster teardown omits the configured data path from its removal set. That narrow fact does not prove
end-to-end durability; see [durable state](../architecture/durable_state.md).

## Down and Destroy

```text
hostbootstrap-demo project down
hostbootstrap-demo project destroy
```

Current commands perform cluster cleanup only in an owning current frame and then call the project's
teardown hook. The hook may stop or remove the provider, but the command does not first dispatch the same
verb through every reachable child. Cleanup is best-effort and aggregates some failures, but it does not
yet carry verified ownership receipts for every resource and cannot promise orphan-free recovery after a
hard kill.

The provider disk may be removed by `destroy`; host `<project-root>/.data` is shared from outside that
disk and is not intentionally included in cluster removal. Do not infer successful reattachment until
the destroy/up/readback gate passes.

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
data TestConfig = TestConfig
  { testSuites    :: [Text]
  , testResources :: Resources
  }
```

`testSuites` is informational/redundant; case selection uses the compiled matrix, and config variants
use `testResources`. The harness creates two message variants, drives the real `project up`, asserts, and
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
