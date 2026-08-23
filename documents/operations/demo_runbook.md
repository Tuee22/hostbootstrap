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
- At a chart reverse node, the shared command projects the exact chart from the retained plan, reads only its
  plan/frame/resource-keyed ownership record, verifies those coordinates, and derives Helm cleanup identity
  from that chart. Missing records are foreign, mismatches fail before mutation, and released tombstones retry
  as an already-converged result.
- The chain includes MinIO before the registry and places the accelerator daemon after the workload.
- Before lifecycle adapters consume that chain, the pure exact-slice projection classifies its typed operations
  into provider, cluster, workload, service, and assertion roles. VM and Direct plans retain distinct provider
  prefixes but both require one immediate provider-to-cluster edge and cluster-local workload suffix. The
  projection refuses unknown identities, missing or duplicate singleton roles, wrong-frame workloads, broken
  dependency prefixes, or a config whose canonical digest differs from the admitted plan.
- On the `linux-cpu` Incus lane, the VM deployment action now receives its exact `StepExecution`. Before
  share attachment, cluster work, or descent, it resolves only that node's plan-owned provider resource,
  prepares and settles provision, prepares and settles a live Ready probe, records the settled provider
  identity, and registers the invocation-local pending provider dependency package. A failed, foreign, or
  provisional path registers no package. This is host-static adoption evidence; live Incus acceptance remains
  with the worked-demo acceptance sprint.
- The Direct Linux GPU lane applies the same exact producer discipline to its current-metal-frame provider
  reservation without inventing a VM. After Docker discovery and before CUDA, image construction, cluster
  work, or descent, the build action settles the plan-owned Direct reservation and verifies the canonical
  project root plus the configured base-image egress probe. Only its managed Ready result records the
  `reserved` reverse identity and registers the Direct invocation-local dependency package. Direct reverse
  remains journal terminalization only; this does not claim a physical host-provider release.
- The VM chain now has an explicit `copy-source` node between provider settlement and VM descent. On Incus it
  freshly opens the invocation-local provider dependency, resolves only its own durable-share resource, and
  keeps both provider and managed share handles inside one continuation while attaching the canonical host
  durable root at the provider-selected absolute guest target. Mount validation and exact guest-alias
  reconciliation finish before the continuation returns. No share handle is carried into the later descent node, and the
  Direct chain declares no copy-source action.
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

Both VM-backed and Direct project-image builds pull and resolve the published base to a repository digest,
measure a clean Docker context and the selected builder, and sign a fresh `hostbootstrap/build/v1` binding with
the separately provisioned `<executable>.build.key`. Build authority, its public key, coordinator identity,
and image-build config are transient BuildKit secrets; the measured builder is supplied through the read-only
`hostbootstrap-builder` named build context. The Dockerfile runs authenticated, no-cache
`check-code` before compiling the final binary; it no longer mints an image-build config from its own arguments.

Cluster creation has one closed backend selected by the plan-owned cluster package. A Kind plan requires the
resolved Kind, Docker, Kubectl, and Helm identities; an nvkind plan requires nvkind instead of Kind and never
falls back to it. Discovery mints no backend when a required tool is absent, and later operations refuse a
changed driver, config bytes/digest, or ownership identity before mutation. Operators therefore repair the
declared host-tool installation or regenerate the exact admitted plan; substituting a similarly named binary
or editing the rendered cluster config in place is not a recovery path.

The `deploy-kind`/nvkind node now consumes the authenticated provider package carried into its child frame.
It fresh-probes that exact parent-owned generation, derives its cluster package from the node's opaque admitted
execution projection, writes the canonical config, reconciles ownership, applies the budget cordon, verifies
fresh readiness, and publishes only the pending cluster dependency package for the chart successor. A refusal
at any stage leaves no readiness/package to consume; rerun `project up` after correcting the reported provider,
tool, ownership, or config mismatch.

Open operator-significant defects are:

- opaque plan/resource-indexed readiness exists; Linux CPU Incus and Direct provider producers, the writable
  share/alias consumer, and the exact cluster reconcile/cordon/readiness consumer use it, while workload
  consumers remain incomplete;
- chart teardown is exact and record-authenticated; ownership receipts are not yet universal across every
  declared project callback;
- Harness keeps an exact run-scoped plan, and provider/share/cluster consumers use its admitted projections;
  mount and teardown consumers remain incomplete;
- the same-run destroy/recreate acceptance transition is owned by the worked-demo live gate;
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
the chart transaction renders the service ConfigMap while the daemon action renders its own ConfigMap. The
context-init step's action body only announces the
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

VM-backed lanes descend host → provider VM → project container. Their exact plan authors the provider at the
descended VM frame. Native Linux GPU authors a distinct Direct reservation provider at the metal frame and uses a direct
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

Before backend selection, the command projects the singular cluster operation from the admitted plan and
renders canonical config bytes. VM-backed lanes select Kind and preserve their provider-visible writable
durable target. The Direct Linux GPU lane selects nvkind, adds its GPU worker, and contains no VM/share/alias
fiction. The renderer fixes these loopback-only publications:

The cluster action accepts neither a selected executable nor a cluster name. VM/container lanes open the
carried `core:deploy-vm` provider through `runtime://provider/demo-vm-readiness`; Direct opens its admitted
`core:deploy-vm` host reservation through `runtime://provider/demo-direct-readiness`, independently of its
preceding `core:build-image` action. Both then follow the same
reconcile → ownership carry → cordon → fresh readiness → cluster-package registration sequence.
The following `deploy-chart` node carries an exact stable chart declaration. It opens that acknowledged
cluster package, performs a nonce-bound fresh readiness probe, and sends canonical values to the
producer-owned Helm/Kubectl service. The chart owns the service ConfigMap, image identity, Deployment rollout,
release, and namespace as one transaction; no separate `kubectl apply` or compatibility chart mutator runs.

| Driver | Published ports |
|---|---|
| Kind | registry `30500`, web `30080`, accelerator `30081`, MinIO `30900` |
| nvkind | registry `30500`, web `30080`, MinIO `30900` |

Every mapping binds `127.0.0.1`; duplicate, wildcard, out-of-range, undeclared, digest-mismatched, or
noncanonical input refuses before any cluster filesystem or subprocess action.

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
frame, and every other node runs the reverse effect its own step declared. The command authenticates chart
cleanup against the exact plan/frame/resource ownership record and runs it before cluster cleanup; provider,
share, alias, and service callbacks remain authorized by their exact projected local-work nodes. Cleanup
aggregates failures, but it does not yet carry verified ownership receipts for every declared callback and
cannot promise orphan-free recovery after a hard kill.

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
| `durable-readback` | web POST → GET of the exact marker through the plan-owned `.test_data/<runId>` durable root; the live acceptance gate additionally proves it across same-run destroy/recreate |

Those cases do not replace recursive teardown, receipt-bound ownership, same-run recreate, or
native-substrate acceptance gates.

## Safe Operating Guidance

- Do not run the long harness on a machine carrying production demo state.
- Treat web (`30080`), registry (`30500`), MinIO (`30900`), and Kind accelerator ingress (`30081`) as
  development-only listeners. Canonical Kind/nvkind config binds every published port to `127.0.0.1`;
  the registry is still anonymous HTTP, and MinIO uses fixed source credentials rendered into a Kubernetes
  Secret.
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
