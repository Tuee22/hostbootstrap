# Accelerator Daemon Demo

**Status**: Draft
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition methodology](../architecture/composition_methodology.md), [run models](../architecture/run_models.md), [phase 13](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md)

> **Purpose**: Define the planned demo generalization where the same project binary also runs as a
> substrate-specific accelerator daemon, JIT-builds a tiny native worker, connects to the web service over
> CBOR WebSocket, and performs real `Float` addition through the correct local substrate.

## TL;DR

- The demo adds a real accelerator path: the UI accepts two `Float` values, sends an add request, and
  displays the result returned by a daemon-backed native worker.
- The web server never computes the sum in process. It accepts a daemon WebSocket, dispatches CBOR work
  messages asynchronously, correlates replies by request id, and returns the result to the UI.
- The daemon is the same project binary in every placement. On startup it generates substrate-specific
  source, ensures host build tools only when running on host substrates, builds the worker, connects to the
  web service, and serves work.
- The generated accelerator is real in every lane: Swift + Metal on Apple Silicon, CUDA via `nvcc` on
  Linux GPU and Windows GPU, and C++ via `clang++` on Linux CPU.
- Linux CPU and Linux GPU run the accelerator daemon inside Kubernetes as a separate pod backed by the
  hostbootstrap base container. Apple Silicon and Windows GPU run the accelerator daemon host-native
  because their device/compiler paths are host-resident.
- The first implementation should supervise a long-running worker subprocess from Haskell rather than
  bind the generated Swift/CUDA/C++ artifact directly through Haskell FFI.

## Substrate Matrix

| Substrate | Cluster shape | Daemon placement | Worker implementation | Build tools | Ensure behavior |
|---|---|---|---|---|---|
| `apple-silicon` | existing kind-in-VM demo cluster | host-native daemon started after `project up` exposes the local-only ingress | generated Swift program using Metal | `swiftc`, `xcrun` macOS SDK, host Metal runtime | project binary runs Apple Metal build-stack ensure on the host |
| `linux-cpu` | existing Incus VM path | in-cluster daemon pod | generated C++ add worker | `clang++` from the CPU base image | no ensure in the container; trust the base image |
| `linux-gpu` | direct host `nvkind` cluster, no Incus VM | in-cluster daemon pod | generated CUDA add worker | `nvcc` from the CUDA base image | no ensure in the container; trust the base image and NVIDIA runtime |
| `windows-gpu` | WSL2-hosted cluster plus host bridge | host-native daemon started after `project up` exposes the local-only ingress | generated CUDA add worker | `nvcc`, MSVC host compiler, LLVM `clang` | project binary runs Windows CUDA/clang build-stack ensure on the host |

`windows-cpu` remains a supported hostbootstrap substrate for the core lifecycle, but the accelerator demo
lane is a GPU lane on Windows because the intended Windows worker is CUDA.

## WebSocket Contract

The web application exposes an accelerator-ingress WebSocket endpoint. The daemon dials that endpoint and
keeps the connection open. This direction matters:

- in-cluster daemon pods can reach the web service through a normal `ClusterIP` service;
- host-native Apple and Windows daemons can reach the web service through a local-only `NodePort`;
- the web server does not need to know which host port a daemon might be listening on.

The payload is CBOR, not JSON. The minimal message family is:

```text
AddRequest  { requestId : Text, left : Float, right : Float }
AddResult   { requestId : Text, result : Float, backend : Text, artifactHash : Text }
AddFailure  { requestId : Text, error : Text, backend : Text, artifactHash : Text }
```

The server owns request correlation and timeouts. A UI request is not complete until the daemon returns the
matching `AddResult`. The response includes a backend identity and artifact hash so tests can prove the UI
path reached the built worker rather than an in-process fallback.

Current demo behavior preserves that invariant: the SPA has the Add controls and renders pending/error/
result states, `/api/accelerator/daemon` accepts the daemon WebSocket, and `/api/accelerator/add`
dispatches CBOR work to the registered daemon with request-id correlation and a bounded response timeout.
When no daemon is connected, the endpoint returns `accelerator daemon unavailable` rather than computing
locally.

## Daemon And Worker Split

The Haskell daemon should supervise a generated worker subprocess for the first implementation.

The project binary daemon owns:

- deterministic source generation into `.build/accelerator/<substrate>/<hash>/`;
- substrate build-stack ensure on Apple Silicon and Windows GPU only;
- closed-enum host-tool resolution for host-resident probes: `Swiftc`, `Xcrun`, and `SystemProfiler` on
  Apple Silicon; `Clangxx` for Linux CPU daemon builds; `NvidiaSmi`, `Nvcc`, `Clang`, `MsvcCl`, and
  `Vswhere` on Windows GPU;
- build command selection and artifact caching;
- worker process lifecycle, restart, stderr/stdout capture, and health probes;
- WebSocket connection management and CBOR request/reply framing;
- request correlation, timeout, and graceful shutdown.

The generated worker owns only the numerical operation. It can speak a tiny local protocol to the Haskell
daemon, for example length-prefixed CBOR over stdin/stdout:

```text
WorkerAdd { left : Float, right : Float }
WorkerSum { result : Float }
```

This subprocess boundary is preferable to Haskell FFI for the initial demo because Swift/Metal, CUDA, and
C++ have different ABI, linker, runtime-library, and crash-failure shapes. A subprocess keeps the Haskell
daemon portable, makes rebuild/restart simple, and isolates worker crashes from the WebSocket control
plane. The cost is irrelevant for a demo operation that adds two floats.

FFI is still a reasonable later optimization once the artifact ABI is stable and worth hardening.

The deterministic worker source templates and build-command builders now live in
`HostBootstrapDemo.Accelerator`: Swift/Metal for Apple Silicon, C++ for Linux CPU, and CUDA for Linux GPU
and Windows GPU. Unit tests cover template identity, artifact hashes, and pure build arguments; the daemon
runtime writes those sources, invokes the builders, supervises the subprocess, and returns backend/artifact
metadata over the WebSocket response path.

## JIT Build Rules

The code generator is idempotent. Given the same substrate, worker kind, and source template version, it
renders byte-identical source and the same artifact hash. A cache hit skips rebuild and launches the
existing worker.

Per-substrate build rules:

- Apple Silicon renders a Swift source file that imports Metal, embeds or loads a minimal Metal kernel,
  compiles with `swiftc -O -sdk $(xcrun --sdk macosx --show-sdk-path)`, and runs on the host Metal device.
  This mirrors the proven jitML headless finding: an explicit macOS SDK path matters, full Xcode and the
  offline `metal` compiler are not part of the demo requirement.
- Linux CPU renders C++ and builds it with `clang++` from the CPU base image.
- Linux GPU renders CUDA and builds it with `nvcc` from the CUDA base image.
- Windows GPU renders CUDA and builds it with host `nvcc`; `nvcc` uses the MSVC C++ build tools as its
  host compiler, and LLVM `clang` is also ensured as the base C++ compiler stack.

Containers do not run host ensure. If a Linux CPU or Linux GPU daemon pod cannot find `clang++` or `nvcc`,
that is a bad image/base contract, not an in-pod remediation event.

## Ensure Boundaries

Only host-resident daemon lanes run accelerator build-stack ensure:

- **Apple Silicon**: the Apple Metal build-stack reconciler applies only to `apple-silicon`. It verifies a
  visible Metal device, the macOS SDK via `xcrun --sdk macosx --show-sdk-path`, and a Swift compiler that
  can build and run a tiny Swift + Metal probe headlessly. The pre-binary host floor already requires Xcode
  Command Line Tools and Homebrew; the reconciler must not require the full Xcode app, keychain state,
  Tart, or a VM.
- **Windows GPU**: the hardened `ensure-cudawin` daemon build-stack path verifies the NVIDIA driver
  (`nvidia-smi`), installs/verifies the CUDA Toolkit (`Nvidia.CUDA`) with `winget`, installs Visual Studio
  Build Tools with the C++ workload (`Microsoft.VisualStudio.2022.BuildTools` plus the VCTools workload)
  for `nvcc`'s host compiler, installs/verifies LLVM clang (`LLVM.LLVM`) with `winget`, then compiles a
  smoke artifact through `nvcc -ccbin <resolved-msvc-cl-directory>`.

Linux CPU and Linux GPU daemon pods use the published base images. The CPU base carries the LLVM/clang
stack; the CUDA base carries CUDA development tooling and the same hostbootstrap toolchain. The pod either
builds successfully or fails loudly.

## Cluster Exposure

The accelerator ingress is a web-service endpoint, not a daemon service exposed to the host.

| Daemon lane | Kubernetes exposure |
|---|---|
| Linux CPU daemon pod | `ClusterIP` endpoint for the daemon to dial the web service |
| Linux GPU daemon pod | `ClusterIP` endpoint for the daemon to dial the web service |
| Apple host daemon | web service gets a local-only `NodePort` mapping bound to `127.0.0.1` |
| Windows host daemon | web service gets a local-only `NodePort` mapping bound to `127.0.0.1` |

For the demo's kind-based clusters, local-only means the kind `extraPortMappings` entry binds the host
listener to `127.0.0.1`, so the daemon can connect from the host without exposing the ingress on the LAN.
`HostBootstrap.Cluster.Lifecycle.acceleratorIngressPlan` is the pure implementation of this selection:
in-cluster daemons render `ClusterIP`, host-resident daemons render `NodePort` with the local-only kind
listen address. The demo reserves `30081` as the local-only accelerator ingress mapping in `demo/kind.yaml`;
the existing web, registry, and MinIO NodePorts keep their current bindings.

## Linux GPU Direct Cluster

The Linux GPU lane does not need an Incus VM. The project binary should launch an `nvkind` cluster directly
on the host, using the project container with a `docker run --rm` invocation and the host Docker socket.
The binary-context topology can express this as an explicit host-backed project-container frame, not only
the existing VM-backed `vm-project-container` frame. The explicit Linux GPU context carries a direct
topology witness so an ordinary host-to-container config cannot bypass the VM-ancestor rule. The CUDA
daemon pod then runs inside that cluster from the CUDA hostbootstrap base image and builds the CUDA worker
with `nvcc`.

Linux CPU keeps the Incus VM path and still runs a separate in-cluster daemon pod.

The lifecycle primitive is implemented in `HostBootstrap.Cluster.Lifecycle`: Linux GPU accelerator plans
select `NvkindDriver`, run a Docker NVIDIA-runtime smoke, and create the cluster with
`nvkind cluster create` and `--name=<cluster>` (with `kind.yaml` supplied as an `nvkind` config template when host port mappings
are published). The Phase 15 context primitive is also implemented: `deriveLinuxGpuContainerContext`
represents the host-backed project container while the normal VM-backed container context still requires a
VM ancestor. Phase 16's direct-chain selection calls this path in the live demo shape; the remaining Linux
GPU gate is a real `nvkind` run with the CUDA daemon pod and worker.

## Tests

This feature is not closed by unit tests alone. It needs static, integration, and browser e2e coverage.

Static tests:

- CBOR request/result round trips, invalid payload rejection, and request-id correlation.
- deterministic source generation and artifact-hash stability for Swift/Metal, CUDA, and C++ workers.
- pure build command builders for Apple, Windows, Linux CPU, and Linux GPU.
- topology and endpoint selection: ClusterIP for in-cluster daemons, local-only NodePort for host daemons.
- a guard proving the web server has no in-process accelerator fallback path for the UI add operation.

Integration tests:

- Linux CPU: Incus VM path, daemon pod from CPU base image, C++ worker built with `clang++`, CBOR
  WebSocket add returns the expected `Float` result and backend metadata.
- Linux GPU: direct host `nvkind` cluster launched through the project container, daemon pod from CUDA
  base image with NVIDIA runtime visible, CUDA worker built with `nvcc`, add returns through the
  WebSocket path.
- Apple Silicon: host daemon starts after `project up`, Apple Metal build-stack ensure runs on the host,
  Swift/Metal worker builds and runs, daemon connects through the local-only NodePort, add returns through
  the WebSocket path.
- Windows GPU: host daemon starts after `project up`, `ensure-cudawin` verifies/installs CUDA + MSVC C++
  workload + LLVM clang, CUDA worker builds with `nvcc`, daemon connects through the local-only NodePort,
  add returns through the WebSocket path.

Browser e2e tests:

- The demo UI exposes two numeric inputs and an add button.
- The test fills representative `Float` values, clicks add, waits for the asynchronous result, and asserts
  the expected sum.
- The e2e assertion also checks returned backend metadata and artifact hash, so a fake in-process
  implementation cannot pass.
- Existing message-variant coverage remains; the accelerator case is added to the suite rather than
  replacing the web/service checks.

## Current Status

This document is target design plus current implementation status for the accelerator daemon as a whole.
Phase 2's host-tool enumeration, Phase 3's reconciler implementation, Phase 5's cluster/exposure
primitives, Phase 13's demo UI/codegen/web slices, Phase 15's daemon/direct-container context substrate,
Phase 16's hook/direct-chain/host-daemon lifecycle substrate, and Phase 18's protocol/runtime/WebSocket seam
are validated locally:
the daemon lanes have closed `HostTool` constructors (`Swiftc`/`Xcrun`/`SystemProfiler`, `Clangxx`, and
the Windows CUDA/MSVC probes) plus `ensure-apple-metal` / hardened `ensure-cudawin` code and unit tests, and the cluster lifecycle has `NvkindDriver`, the NVIDIA Docker
runtime probe, and pure ingress exposure planning. The demo SPA now exposes the Accelerator tab, the
Haskell worker templates/build builders exist, and the web service has the no-fallback CBOR WebSocket
daemon ingress. The context layer now gives daemon contexts `service run`
authority without project lifecycle authority, distinguishes host-resident and in-cluster daemon
placements, and models the explicit Linux GPU direct project-container topology. The lifecycle layer now
has `PostHandoff` ordering, `demoChainFor` selects the direct Linux GPU host -> project-container
`nvkind` chain while preserving the Linux CPU VM-backed chain, and the Apple/Windows host-daemon hook
writes a daemon config, starts a copied project binary, records a pid, and stops it during teardown. The
runtime seam now registers `service run accelerator`, has CBOR request/result/failure codecs with
request-id correlation, tests a transport-injected daemon loop that supervises a worker and returns backend/
artifact metadata, and includes the concrete WebSocket client/server path. Phase 3
closed its Apple Silicon smoke run 2026-07-10 on an M1 Max host (`ensure apple-metal: present (no-op)`) and
the local Apple worker smoke also built/reused the Swift/Metal worker and returned `Right 3.75` for
`1.5 + 2.25`. Phase 3 still needs the real Windows GPU smoke run before it can close; Phase 5 still needs
the live Linux CPU/GPU daemon connectivity and e2e gates. The remaining owning phases stay reopened in the
development plan: Phase 13 for real integration/e2e tests, Phase 16 for real host/in-cluster daemon
lifecycle runs, and Phase 18 for real host/in-cluster transport integration with daemon-returned worker
metadata.

## See Also

- [composition_patterns](composition_patterns.md) - host-native daemon and headless host-build shapes.
- [ensure_reconcilers](ensure_reconcilers.md) - install-and-verify host reconciler contract.
- [base_image](base_image.md) - CPU and CUDA base image contents trusted by in-cluster daemon pods.
- [demo_runbook](../operations/demo_runbook.md) - the worked demo lifecycle this feature extends.
