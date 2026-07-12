# Accelerator Daemon Demo

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition methodology](../architecture/composition_methodology.md), [run models](../architecture/run_models.md), [phase 13](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md)

> **Purpose**: Define the demo generalization where the same project binary also runs as a
> substrate-specific accelerator daemon, JIT-builds a tiny native worker, connects to the web service over
> CBOR WebSocket, and performs real `Float` addition through the correct local substrate.

## TL;DR

- The demo adds a real accelerator path: the UI accepts two `Float` values, sends an add request, and
  displays the result returned by a daemon-backed native worker.
- The web server never computes the sum in process. It accepts a daemon WebSocket on a private listener,
  dispatches one serialized CBOR request at a time, correlates the reply, and returns it to the UI;
  concurrent requests receive an immediate busy response.
- The daemon is the same project binary in every placement. On startup it generates substrate-specific
  source, ensures host build tools only when running on host substrates, builds the worker, connects to the
  web service, and serves work.
- The generated accelerator is real in every lane: Swift + Metal on Apple Silicon, CUDA via `nvcc` on
  Linux GPU and Windows GPU, and C++ via `clang++` on Linux CPU.
- Linux CPU and Linux GPU run the accelerator daemon inside Kubernetes as a separate pod backed by the
  hostbootstrap base container. Apple Silicon and Windows GPU run the accelerator daemon host-native
  because their device/compiler paths are host-resident.
- The Haskell daemon supervises one persistent newline-delimited worker subprocess rather than binding the
  generated Swift/CUDA/C++ artifact through Haskell FFI.

## Substrate Matrix

| Substrate | Cluster shape | Daemon placement | Worker implementation | Build tools | Ensure behavior |
|---|---|---|---|---|---|
| `apple-silicon` | existing kind-in-VM demo cluster | host-native daemon started after `project up` exposes the local-only ingress | generated Swift program using Metal | `swiftc`, `xcrun` macOS SDK, host Metal runtime | project binary runs Apple Metal build-stack ensure on the host |
| `linux-cpu` | existing Incus VM path | in-cluster daemon pod | generated C++ add worker | `clang++` from the CPU base image | no ensure in the container; trust the base image |
| `linux-gpu` | direct host `nvkind` cluster, no Incus VM | in-cluster daemon pod | generated CUDA add worker | `nvcc` from the CUDA base image | the metal step runs `ensure docker` + `ensure cuda`; no ensure in the container, which trusts the CUDA base image |
| `windows-gpu` | WSL2-hosted cluster plus host bridge | host-native daemon started after `project up` exposes the local-only ingress | generated CUDA add worker | `nvcc`, MSVC host compiler, LLVM `clang` | project binary runs Windows CUDA/clang build-stack ensure on the host |

`windows-cpu` remains a supported hostbootstrap substrate for the core lifecycle, but the accelerator demo
lane is a GPU lane on Windows because the intended Windows worker is CUDA.

## WebSocket Contract

The web application exposes an accelerator-ingress WebSocket endpoint. The daemon dials that endpoint and
keeps the connection open. This direction matters:

- in-cluster daemon pods can reach the web service through a normal `ClusterIP` service;
- host-native Apple and Windows daemons can reach the web service through a local-only `NodePort`;
- the web server does not need to know which host port a daemon might be listening on.

The payload is CBOR, not JSON. Arithmetic values are Haskell `Float` and every generated worker uses
IEEE Float32. The tiny codec uses CBOR float64 as a carrier for those already-quantized Float32 values.
The message family is:

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

The Haskell daemon supervises a generated worker subprocess.

The project binary daemon owns:

- deterministic source generation into `.build/accelerator/<substrate>/<hash>/`;
- substrate build-stack ensure on Apple Silicon and Windows GPU only;
- closed-enum host-tool resolution for host-resident probes: `Swiftc`, `Xcrun`, and `SystemProfiler` on
  Apple Silicon; `Clangxx` for Linux CPU daemon builds; `NvidiaSmi`, `Nvcc`, `Clang`, `MsvcCl`, and
  `Vswhere` on Windows GPU;
- build command selection and artifact caching;
- worker process lifecycle, serialized requests, one restart after failure, timeout invalidation, and shutdown cleanup;
- WebSocket connection management and CBOR request/reply framing;
- request correlation, timeout, and graceful shutdown.

The generated worker owns only the numerical operation. It speaks a persistent newline-delimited text
protocol over stdin/stdout: each input line contains two Float32 values and each output line contains one
Float32 result. CBOR remains the network protocol between daemon and web service, not the local process
protocol.

```text
<left> <right>\n
<result>\n
```

This subprocess boundary is preferable to Haskell FFI for the initial demo because Swift/Metal, CUDA, and
C++ have different ABI, linker, runtime-library, and crash-failure shapes. A subprocess keeps the Haskell
daemon portable, makes rebuild/restart simple, and isolates worker crashes from the WebSocket control
plane. The cost is irrelevant for a demo operation that adds two floats.

FFI is still a reasonable later optimization once the artifact ABI is stable and worth hardening.

The deterministic worker source templates and build-command builders live in
`HostBootstrapDemo.Accelerator`: Swift/Metal for Apple Silicon, C++ for Linux CPU, and CUDA for Linux GPU
and Windows GPU. Unit tests cover template identity, artifact hashes, and pure build arguments; the daemon
runtime writes those sources, invokes the builders, keeps one worker session alive across requests, retries
once with a fresh session after failure, and returns backend/artifact metadata over the WebSocket response
path. CUDA calls and kernel launch/synchronization are checked; failures surface instead of producing a
silent result.

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
builds successfully or fails loudly. Before the direct Linux GPU handoff, the metal step runs `ensure
docker` and the tightened `ensure cuda`: the NVIDIA runtime becomes Docker's default with CDI enabled,
volume-mount injection is enabled, Docker is restarted, and the official nvkind `/dev/null` mount smoke
must see a GPU. That host-runtime reconciliation is distinct from installing tools inside the pod.

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
`HostBootstrap.Cluster.Lifecycle.acceleratorIngressPlan` is the pure implementation of this selection.
The chart renders a distinct accelerator Service: in-cluster daemons use `ClusterIP` port 8081, while
host-resident daemons use NodePort 30081. Placement-specific kind configs publish that NodePort only in
the host-daemon topology, bound to `127.0.0.1`; the in-cluster kind/nvkind configs omit it. The existing
web, registry, and MinIO NodePorts keep their current bindings.

The web pod has two linked listeners sharing one process-local hub: public HTTP on container port 8080 and
daemon WebSocket ingress on 8081. Public NodePort 30080 cannot upgrade daemon registration, and the private
listener rejects browser `Origin` headers. Local-only binding is network placement, not authentication.
Because the hub is process-local, the demo rejects `haReplicas /= 1`; a production HA design would require
authenticated ingress and shared routing state.

## Linux GPU Direct Cluster

The Linux GPU lane does not need an Incus VM. The project binary launches an `nvkind` cluster directly
on the host, using the project container with a `docker run --rm` invocation and the host Docker socket.
The binary-context topology can express this as an explicit host-backed project-container frame, not only
the existing VM-backed `vm-project-container` frame. The explicit Linux GPU context carries a direct
topology witness so an ordinary host-to-container config cannot bypass the VM-ancestor rule. The CUDA
daemon pod then runs inside that cluster from the CUDA hostbootstrap base image and builds the CUDA worker
with `nvcc`.

Linux CPU keeps the Incus VM path and still runs a separate in-cluster daemon pod.

The lifecycle primitive is implemented in `HostBootstrap.Cluster.Lifecycle`: Linux GPU accelerator plans
select `NvkindDriver`, run the official nvkind volume-mount NVIDIA-runtime smoke, and create the cluster
with `nvkind cluster create --name=<cluster>` plus `nvkind-in-cluster.yaml`. That template keeps the
public demo mappings on a control-plane and gives a worker the nvkind device-injection mount. The one
declared cluster envelope is divided across both node containers. Bring-up then installs the pinned
NVIDIA device-plugin chart, waits for its pods, and refuses to proceed until a node advertises a positive
allocatable `nvidia.com/gpu`. The CUDA daemon Deployment requests `nvidia.com/gpu: 1`.

The Phase 15 context primitive is also implemented: `deriveLinuxGpuContainerContext`
represents the host-backed project container while the normal VM-backed container context still requires a
VM ancestor. Phase 16's direct-chain selection calls this path in the live demo shape; the remaining Linux
GPU gate is a real `nvkind` run with the CUDA daemon pod and worker.

## Tests

This feature is not closed by unit tests alone. Static and browser specifications are implemented; the
remaining closure gates are live substrate integration runs.

Static tests:

- CBOR request/result round trips, invalid payload rejection, and request-id correlation.
- deterministic source generation and artifact-hash stability for Swift/Metal, CUDA, and C++ workers.
- pure build command builders for Apple, Windows, Linux CPU, and Linux GPU.
- topology and endpoint selection: ClusterIP for in-cluster daemons, local-only NodePort for host daemons.
- a guard proving the web server has no in-process accelerator fallback path for the UI add operation.
- real-socket public/private isolation, request/reply, busy-request, linked-listener failure, idle persistence,
  and graceful shutdown.
- persistent session reuse/restart/timeout cleanup and always-on Float32 rounding at `2^24 + 1`.

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

Implemented browser e2e specifications:

- The demo UI exposes two numeric inputs and an add button.
- The test fills representative `Float` values, clicks add, waits for the asynchronous result, and asserts
  both `1.5 + 2.25 = 3.75` and Float32 rounding (`2^24 + 1 = 2^24`).
- The e2e assertion also checks returned backend metadata and artifact hash, so a fake in-process
  implementation cannot pass.
- Existing message-variant coverage remains; the accelerator case is added to the suite rather than
  replacing the web/service checks.

## Current Status

The implementation is statically green at 357 core tests and 83 demo tests under `-Werror`. It includes
config-selected `service run` with real `Web`/`Accelerator` Dhall payloads; separate linked listeners;
dynamic rollout-hashed ConfigMaps; persistent workers; strict Float32 semantics; checked CUDA failures;
direct Linux GPU `nvkind`; in-cluster Linux CPU/GPU daemon manifests; and serialized host-daemon lifecycle
with strict PID identity, graceful shutdown, force fallback, and ambiguity preservation.

Historical Apple Metal and Windows CudaWin host-tool smokes passed on 2026-07-10. The owning phases remain
`Active` because static evidence cannot replace the unavailable live closure matrix: a real Linux GPU
`ensure cuda` no-op, native Linux CPU/GPU daemon connectivity and `nvkind` execution, Apple host-daemon
lifecycle, and final per-substrate browser/harness runs. No live `8/8` result is recorded yet.

## See Also

- [composition_patterns](composition_patterns.md) - host-native daemon and headless host-build shapes.
- [ensure_reconcilers](ensure_reconcilers.md) - install-and-verify host reconciler contract.
- [base_image](base_image.md) - CPU and CUDA base image contents trusted by in-cluster daemon pods.
- [demo_runbook](../operations/demo_runbook.md) - the worked demo lifecycle this feature extends.
