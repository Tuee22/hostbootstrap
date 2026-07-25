# Build and Run Model

**Status**: Authoritative source
**Supersedes**: the `HostTarget` runtime narrative, recursive-teardown claim, and offline-capable claim
**Referenced by**: [documents index](../README.md), [Python/Haskell boundary](python_haskell_boundary.md), [composition methodology](composition_methodology.md), [base image](../engineering/base_image.md), [lifecycle state model](lifecycle_state_model.md)

> **Purpose**: Describe how the host-native project binary and Linux project image are built, and how
> that binary currently drives the persistent stack.

## TL;DR

The host binary and Linux image intentionally use different Cabal projects. Current derived builds can
reuse a stale local mutable base tag, lifecycle readiness/teardown are incomplete, and demo tests use
Production state; the target selects a freshly pulled published base by digest and applies the typed
lifecycle contract.

## Current Status

The sections below describe the working two-build chain and identify its open reproducibility and
lifecycle defects. Delivery status and closure evidence live in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Two builds and two Cabal projects

The outer Python bootstrap builds the project executable **host-native** into
`<project-root>/.build/<executable>` and hands the requested arguments to it. This uses the project's
host-native `cabal.project`. In this repository, `demo/cabal.project` includes the demo package and local
`hostbootstrap-core`; it does not import an absolute in-image freeze.

The project binary later builds the Linux project image. The demo Dockerfile copies
`demo/docker/container.cabal.project` over `cabal.project` inside the image. That container-only project
imports `/opt/basecontainer/haskell-deps/core.freeze`, which exists in the published base image.

These configurations must remain separate:

| Build | Project file | Store/pins |
|---|---|---|
| Host-native binary | `demo/cabal.project` | host `.build/cabal-store`; local core source; no in-image absolute import |
| Linux project image | `demo/docker/container.cabal.project` | `/opt/cache/cabal`; imports the base image's freeze |

Teaching one `cabal.project` for both environments is incorrect because the absolute freeze path is not
available on the host.

## Network behavior

The bootstrap is not offline-capable:

- Python runs `cabal update` before every host-native build.
- A missing Linux GHCup is installed with `curl ... | sh`.
- Windows downloads a pinned GHCup executable with PowerShell.
- Base and derived builds download/pull toolchains, packages, and images.

An already-installed tool avoids its install fallback, but that does not make the whole build offline;
the unconditional package-index refresh still needs network. Download provenance and offline targets are
documented in [Python/Haskell boundary](python_haskell_boundary.md) and
[base image](../engineering/base_image.md).

## Project image source

Derived images must build from the **published** base, never from a same-named local base left in a Docker
daemon. The current demo builder passes a mutable tag and does not add `--pull`, so it can silently use a
stale local tag. This is an open reproducibility defect.

The target is:

1. explicitly pull the required published tag;
2. resolve and record its registry digest;
3. pass `BASE_IMAGE=<repository>@sha256:<digest>`;
4. reject a derived build that has only a mutable/local tag;
5. report the digest in build output and deployment provenance.

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
shell, copy, share, stop, and destroy. The older `HostTarget`/`runInTarget` and
`rebootDockerToReady` symbols remain in source but have no live demo call sites. They are stale surfaces,
not the architecture. See [Incus](../engineering/incus.md) and [WSL2](../engineering/wsl2.md).

## Lifecycle truth

Bring-up has several bounded waits and fail-closed command checks, but readiness is not universally
type-gated and `Ready` is forgeable. Reconcilers mostly return `IO ()`, not explicit
create/adopt/repair/no-op/conflict results.

Teardown is also not recursive. Root `project down`/`destroy` cleans the current cluster only when that
frame owns it and then invokes the project teardown hook. VM deletion or direct-container cleanup handles
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

- immutable base selection by digest;
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
