# Build and Run Model

**Status**: Authoritative source
**Supersedes**: the `HostTarget` runtime narrative, recursive-teardown claim, and two-project/freeze
consumer claim
**Referenced by**: [documents index](../README.md), [Python/Haskell boundary](python_haskell_boundary.md), [composition methodology](composition_methodology.md), [base image](../engineering/base_image.md), [lifecycle state model](lifecycle_state_model.md)

> **Purpose**: Describe how the host-native project binary and Linux project image are built, and how
> that binary currently drives the persistent stack.

## TL;DR

The host binary and Linux image use the same Cabal project. The Python host build retains its explicit
offline option, while image builds are ordinary online distribution builds and may compile Cabal cache
misses. Published rolling bases are explicitly pulled before compatibility smoke-testing; lifecycle
readiness/teardown remain incomplete, and demo tests still use Production state.

## Current Status

The sections below describe the working two-build chain and identify its open lifecycle defects.
Delivery status and closure evidence live in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Two builds and one Cabal project

The outer Python bootstrap builds the project executable **host-native** into
`<project-root>/.build/<executable>` and hands the requested arguments to it. The project binary later
builds the Linux project image from the same source. In this repository, `demo/cabal.project` includes
the demo package and local `hostbootstrap-core`; the Docker build copies both packages into matching
relative locations and uses that same file unchanged.

| Build | Project file | Store/pins |
|---|---|---|
| Host-native binary | `demo/cabal.project` | host `.build/cabal-store`; local core source |
| Linux project image | `demo/cabal.project` | inherited `/opt/cache/cabal`; local core source; online misses allowed |

No project file imports `/opt/basecontainer/...`, and the Dockerfile does not swap in a
container-specific configuration. The inherited store improves performance when keys match; it does not
control the consumer solver.

## Network behavior

The ordinary online bootstrap probes tools first, downloads a pinned/digest-verified GHCup binary only
when absent, refreshes a missing/stale Cabal index, and lets Cabal resolve uncached build inputs.
`--offline` instead requires every tool and the index to be present, adds Cabal's `--offline` mode, and
fails clearly when the local index/store cannot satisfy the build. An unchanged located binary is not
recopied to `.build/`.

Base and derived image builds remain online distribution operations: they pull images and may download
toolchains/packages. The rolling base workflow queries authoritative release metadata for current
compatible inputs; it has no committed replay lock. Its selection contract is documented in
[Python/Haskell boundary](python_haskell_boundary.md) and
[base image](../engineering/base_image.md).

## Project image source

Derived compatibility smoke builds consume the **published** rolling base, never a same-named local
image left in a Docker daemon. The publisher explicitly pulls the tag and may use the resolved digest to
bind that one smoke to the pulled artifact. Ordinary consumers use the rolling tag and pull it through
the normal published-base workflow; the digest is not a permanent configuration or reproducibility
contract.

See [base image](../engineering/base_image.md) and [build and release](../engineering/build_release.md).

## Persistent-stack chain

The VM-backed demo chain currently descends through host, VM, and project-container frames. Its workload
segment is:

```text
deploy-kind
  -> deploy-minio
  -> deploy-registry
  -> push-image
  -> deploy-chart
  -> expose-port
  -> host or in-cluster accelerator-daemon placement
```

The direct Linux GPU lane skips the provider VM, builds the CUDA project image on the host, enters that
container with GPU access, creates nvkind, and deploys the in-cluster GPU daemon.

`deploy-minio` is not optional narrative detail: it creates the S3 backing and bucket used by the
registry. Linux CPU/GPU deploy an in-cluster daemon after the web service; Apple Silicon/Windows GPU start
a host daemon after the private ingress is reachable.

## Provider dispatch

The active provider abstraction is `SubstrateProvider` plus its `LiftLayer` and generic folds for launch,
shell, copy, share, stop, and destroy. The former parallel `HostTarget`/`runInTarget` module and
result-free reboot loop have been deleted. See [Incus](../engineering/incus.md) and
[WSL2](../engineering/wsl2.md).

## Lifecycle truth

Bring-up has several bounded waits and fail-closed command checks. Plan-indexed readiness is now opaque,
resource-bound, and unforgeable at the Phase 9 API boundary, but live effects are not universally
type-gated and mostly still consume non-authorizing compatibility observations. Reconcilers mostly
return `IO ()`, not the implemented explicit create/adopt/repair/no-op/conflict foundation.

Teardown is also not recursive. Root `project down`/`destroy` cleans the current cluster only when that
frame owns it, and every other node runs the reverse its own step declared. VM deletion or
direct-container cleanup handles
nested resources without dispatching the verb through every child frame first.

The target typed transitions, opaque capabilities, ownership tokens, and validation gates live in
[lifecycle state model](lifecycle_state_model.md).

## Durable and test state

Durable carry is implemented from host `.data` through provider share,
`/var/tmp/hostbootstrap-demo-data`, kind/nvkind, and the pod. It has not passed a workload write →
destroy → up → host-and-workload readback gate.

The demo test runner currently resolves a Production cluster plan and uses `.data`, despite generic Test
profile/`.test_data` helpers. The claim that the live test path never touches production storage is false.
See [durable state](durable_state.md) and [harness workflow](harness_workflow.md).

## Command surface

The fixed top-level command groups are `project`, `test`, `service`, `context`, and `check-code`.
`context` has five read-only subcommands:

```text
context inspect
context path
context show [FILE]
context schema
context render [--artifact NAME]
```

The test-group help describes `test run` as root-only, but neither `test init` nor `test run` currently
applies a root context gate. The actual demo `<project>.test.dhall` contains a suite-name list and
resources; compiled Haskell owns the case bodies and the selector (currently one case ID or `all`, despite
the source help's stale suite terminology).

## Validation

Static unit suites validate many pure builders and classifiers. They do not close:

- remaining native rolling-base publication/compatibility lanes;
- universal readiness/ownership typing;
- recursive teardown;
- target `Harness projectId runId` isolation;
- native Linux CPU/GPU daemon gates;
- durable destroy/up/readback.

Status and sequencing belong in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [composition methodology](composition_methodology.md) — frame/chain model.
- [Python/Haskell boundary](python_haskell_boundary.md) — outer bootstrap.
- [derived Dockerfile](../engineering/derived_dockerfile.md) — image build.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — kind/nvkind behavior.
