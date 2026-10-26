# Accelerator Daemon Demo

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition methodology](../architecture/composition_methodology.md), [run models](../architecture/run_models.md), [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md)

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
lane is a GPU lane on Windows because the Windows worker is CUDA. On `windows-cpu` the demo chain carries
no accelerator step and `acceleratorBackendForSubstrate` refuses the substrate, so no daemon runs and an add
request answers `accelerator daemon unavailable`. The ingress placement, however, follows the binary context
rather than the substrate: `acceleratorPlacementForContext` returns `HostResidentDaemon` for every context
that is neither the explicit Linux GPU container nor beneath an Incus VM, so a `windows-cpu` Kind cluster
still renders the accelerator Service for a host daemon and its relay publishes a loopback accelerator
listener that nothing serves (see [Open gaps](#open-gaps)).

## WebSocket Contract

The web application exposes an accelerator-ingress WebSocket endpoint. The daemon dials that endpoint and
keeps the connection open. This direction matters:

- in-cluster daemon pods can reach the web service through a normal `ClusterIP` service;
- host-native Apple and Windows daemons can reach the web service through a runtime-owned loopback exposure;
- the web server does not need to know which host port a daemon might be listening on.

The payload is CBOR, not JSON. Arithmetic values are Haskell `Float` and every generated worker uses
IEEE Float32. The tiny codec uses CBOR float64 as a carrier for those already-quantized Float32 values.
Each message is one CBOR map whose keys are the field names below; the `type` key discriminates the three
messages. The codec is
[HostBootstrapDemo.Accelerator.Protocol](../../demo/src/HostBootstrapDemo/Accelerator/Protocol.hs):

```text
AcceleratorAddRequest { type : "request", requestId : Text, left : Float, right : Float }
AcceleratorAddResult  { type : "result",  requestId : Text, result : Float, backend : Text, artifactHash : Text }
AcceleratorAddFailure { type : "failure", requestId : Text, failureMessage : Text, backend : Text, artifactHash : Text }
```

The server owns request correlation: a reply whose `requestId` differs from the dispatched request is
refused. A UI request completes in exactly one of these ways:

| Completion | HTTP status | Produced by |
|---|---|---|
| the matching `AcceleratorAddResult` | 200 | the daemon |
| the matching `AcceleratorAddFailure` (for example `accelerator worker timeout`) | 503 | the daemon |
| `accelerator daemon unavailable`, when no daemon is registered | 503 | the server |
| `accelerator daemon unavailable: daemon is busy`, when another request holds the one daemon connection | 503 | the server |
| `accelerator daemon unavailable: daemon response timeout`, or a send, receive, decode, or correlation error | 503 | the server |

The response's `backend` names the lane and its `artifactHash` names the generated worker source (see
[JIT Build Rules](#jit-build-rules)).

The demo realizes this contract: the SPA has the Add controls and renders pending/error/result states,
`/api/accelerator/daemon` accepts the daemon WebSocket, and `/api/accelerator/add` dispatches CBOR work to
the registered daemon. It never computes the sum in process.

### Timeouts

Two timeouts apply, one on each side of the WebSocket.

- **Daemon worker timeout.** The Accelerator Dhall payload's `requestTimeoutSeconds`, from 1 to 30 seconds
  (`maxAcceleratorRequestTimeoutSeconds`), bounds one worker request. When it fires, the daemon returns an
  `AcceleratorAddFailure` (`accelerator worker timeout`) and invalidates the worker session.
- **Server dispatch timeout.** The web server waits a fixed 40 seconds — the largest permitted worker
  timeout plus 10 seconds — whatever the configured worker timeout is, so a responsive daemon's own
  timeout always fires first. When the server's timeout fires, or a send or receive fails, the server
  clears the registered daemon and closes its connection. The daemon's readiness marker clears with the
  connection, and the daemon reconnects after a one-second delay.

## Daemon And Worker Split

The Haskell daemon supervises a generated worker subprocess.

The project binary daemon owns:

- deterministic source generation into `.build/accelerator/<backend>/<hash>/`, where `<backend>` is the
  backend name (`apple-metal`, `linux-cpu`, `linux-gpu`, or `windows-gpu`);
- substrate build-stack ensure on Apple Silicon and Windows GPU only;
- closed-enum `HostTool` resolution, split by where the tool runs:

  | Lane | Host-resident ensure and probe tools | Worker compiler |
  |---|---|---|
  | Apple Silicon | `Swiftc`, `Xcrun`, `SystemProfiler` | `Swiftc` on the host |
  | Windows GPU | `NvidiaSmi`, `Winget`, `Vswhere`, `MsvcCl`, `Clang`, `Nvcc` | `Nvcc` on the host, with `MsvcCl` as its host compiler |
  | Linux CPU | none | `Clangxx` inside the daemon pod |
  | Linux GPU | none | `Nvcc` inside the daemon pod |

- build command selection and artifact caching;
- worker process lifecycle, serialized requests, one restart after failure, timeout invalidation, and shutdown cleanup;
- WebSocket connection management, reconnect after disconnect, and CBOR request/reply framing;
- echoing each request's `requestId`, the worker request timeout, and graceful shutdown.

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

**Not planned.** Binding the worker through Haskell FFI is an optional later optimization, worth considering
only once the artifact ABI is stable; no phase schedules it.

The deterministic worker source templates and build-command builders live in
`HostBootstrapDemo.Accelerator`: Swift/Metal for Apple Silicon, C++ for Linux CPU, and CUDA for Linux GPU
and Windows GPU. Unit tests cover template identity, artifact hashes, and pure build arguments; the daemon
runtime writes those sources, invokes the builders, keeps one worker session alive across requests, retries
once with a fresh session after failure, and returns backend/artifact metadata over the WebSocket response
path. CUDA calls and kernel launch/synchronization are checked; failures surface instead of producing a
silent result.

## JIT Build Rules

The code generator is idempotent: each backend has one fixed source template, so the same backend always
renders byte-identical source and the same artifact hash. The artifact hash is the 64-bit FNV-1a digest of
that rendered source text, as 16 lowercase hex digits (`stableSourceHash`), and the cache directory is
`.build/accelerator/<backend>/<hash>/`. A cache hit — an executable already present in that directory —
skips the build and launches the existing worker.

The hash covers the source text only. It does not cover the build arguments (`cppBuildArgs`,
`cudaBuildArgs`, `swiftMetalBuildArgs`), the compiler or SDK version, or the host compiler `nvcc` uses. A
change to any of those reuses a worker built before it; deleting `.build/accelerator` forces a rebuild.
Because the hash identifies the source template rather than the built binary, it is not proof that a
built worker ran (see [Tests](#tests)).

Per-substrate build rules:

- Apple Silicon renders a Swift source file that imports Metal and embeds the Metal kernel as source text,
  which it compiles at run time with `makeLibrary(source:)`. It compiles with
  `swiftc -O -sdk $(xcrun --sdk macosx --show-sdk-path)` and runs on the host Metal device. Because the
  kernel compiles at run time, neither the offline `metal` compiler nor full Xcode is needed; an explicit
  macOS SDK path is.
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
- **Windows GPU**: the `ensure cudawin` daemon build-stack reconciler verifies the NVIDIA driver
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
| Apple host daemon | web service gets a runtime-owned loopback relay exposure |
| Windows host daemon | web service gets a runtime-owned loopback relay exposure |

For the demo's kind-based clusters, local-only means the owned relay's Docker publication binds the host
listener to `127.0.0.1`, so the daemon can connect from the host without exposing the ingress on the LAN.
`HostBootstrap.Cluster.Lifecycle.acceleratorIngressPlan` is the pure implementation of this selection.
The chart renders a distinct accelerator Service: in-cluster daemons use the Dhall-configured `ClusterIP`
port (default 8081), while host-resident daemons target an internal NodePort selected by the plan. The generated
daemon URL carries the runtime-resolved loopback port, not that internal target. The relay publishes the
accelerator listener only when the context's placement is host-resident on a Kind cluster, which includes
`windows-cpu`, where no daemon runs (see [Substrate Matrix](#substrate-matrix)); in-cluster kind/nvkind routes
need no host exposure.

The host daemon is a post-handoff step on the metal frame: it runs after the deployment child's cluster
frame has closed, so it cannot reuse anything that child observed. To find the accelerator listener it
re-enters the provider frame that holds the cluster. On Apple it reopens the exact Lima provider the plan
owns and enters it through that provider's capability; on Windows it enters the plan-selected WSL2 provider
through the self-reference crossing (the WSL2 row of the [frame table](../README.md#glossary)). Inside that
provider frame, the read-only cluster observer opens the exact durable exposure row and re-inspects the
recorded Docker relay, then returns only the accelerator listener's loopback port. The host builds its
WebSocket URL from that fresh result; no value a child frame observed is copied into the parent's carrier.

That launch still needs a root-signed activation revision (see
[activated service composition](../architecture/composition_methodology.md#activated-service-composition)).
Before the [fractal descent](../architecture/composition_methodology.md#fractal-bootstrap) into child frames,
the root coordinator installs its admitted activation signing service in the root
[Chain](../architecture/composition_methodology.md#the-step-and-the-chain) carrier. Child frames sign through
the relayed signing service. After they close, the metal step submits its canonical activation manifest
through the same root route (`stepExecutionSignActivationManifest`; see
[what a node reaches](../architecture/composition_methodology.md#what-a-node-reaches)) and receives only the
signed grant. The signing key stays inside the root coordinator and never crosses a frame or enters plan
bytes.

The web pod has two linked listeners sharing one process-local hub: public HTTP on its configured port
(default 8080) and daemon WebSocket ingress on its distinct configured port (default 8081). The public service
target cannot upgrade daemon registration, and the private
listener rejects browser `Origin` headers. Local-only binding is network placement, not authentication.
Because the hub is process-local, the demo rejects `haReplicas /= 1`; a production HA design would require
authenticated ingress and shared routing state. The accelerator daemon is a `Deployment` with
`Recreate`, so its old pod stops before its new pod starts. The web workload is a `Deployment` from
[the demo chart](../../demo/chart/templates/deployment.yaml) that sets no strategy, so it takes the Kubernetes
default `RollingUpdate`. With one replica that default admits one surge pod and no unavailable pod: each
config-variant rollout starts the new web pod before it stops the old one, so two web pods, each with its
own process-local hub, briefly run at once against the same durable data. During that window the daemon may
still be registered with the old pod while the Service routes `/api/accelerator/add` to the new one, which
answers `accelerator daemon unavailable`; when the old pod stops, the daemon's connection drops and it
reconnects through the Service. See [Current Status](#current-status).

## Linux GPU Direct Cluster

The Linux GPU lane does not need an Incus VM. The project binary launches an `nvkind` cluster directly
on the host, using the project container with a `docker run --rm` invocation and the host Docker socket.
The binary-context topology expresses this as an explicit host-backed project-container frame, not only
the existing VM-backed `vm-project-container` frame. The explicit Linux GPU context carries a direct
topology witness so an ordinary host-to-container config cannot bypass the VM-ancestor rule. The CUDA
daemon pod then runs inside that cluster from the CUDA hostbootstrap base image and builds the CUDA worker
with `nvcc`.

Linux CPU keeps the Incus VM path and still runs a separate in-cluster daemon pod.

The lifecycle primitive lives in `HostBootstrap.Cluster.Lifecycle`: Linux GPU accelerator plans
select `NvkindDriver`, run the official nvkind volume-mount NVIDIA-runtime smoke, and create the cluster
with `nvkind cluster create --name=<cluster>` plus `nvkind-in-cluster.yaml`. That template carries only
cluster-internal targets on the control-plane and gives a worker the nvkind device-injection mount. The one
declared cluster envelope is divided across both node containers. Bring-up then installs the pinned
NVIDIA device-plugin chart only after an initial allocatable probe finds no positive GPU. A cluster with
positive allocation returns before any Helm or `kubectl` mutation; otherwise bring-up waits for the
plugin pods and refuses to proceed until a node advertises positive allocatable `nvidia.com/gpu`. The CUDA
daemon Deployment requests `nvidia.com/gpu: 1`. The nvkind creator installs the NVIDIA containerd handler and
its exact `nvidia` `RuntimeClass`; both plugin and workload select it with `runtimeClassName: nvidia`.

Direct teardown does not issue an unrecorded raw delete. The current child recovers the unique metal-side
source of its exact profile data bind and mounts it into a short-lived sibling project image. A fixed internal
entry then runs the core retained-cluster release, so deletion is conditional on the recorded node identities
and those records are erased only after absence is proved. This is what permits the same Harness run to rotate
its protected generation and recreate nvkind for durable-readback.

The context primitive `deriveLinuxGpuContainerContext` represents the host-backed project
container while the normal VM-backed container context still requires a VM ancestor. Direct-chain
selection calls this path in the demo shape.

## Tests

Unit tests alone cannot validate the hardware/runtime boundary. The acceptance contract combines static
and browser specifications with live substrate integration runs; current gate state belongs in the
development plan.

Static tests:

- CBOR request/result round trips, invalid payload rejection, and request-id correlation.
- deterministic source generation and artifact-hash stability for Swift/Metal, CUDA, and C++ workers.
- pure build command builders for Apple, Windows, Linux CPU, and Linux GPU.
- topology and endpoint selection: ClusterIP for in-cluster daemons, runtime-resolved loopback exposure for host daemons.
- a guard proving the web server has no in-process accelerator fallback path for the UI add operation.
- real-socket public/private isolation, request/reply, busy-request, linked-listener failure, idle persistence,
  and graceful shutdown.
- persistent session reuse/restart/timeout cleanup and always-on Float32 rounding at `2^24 + 1`.
- connection-owned readiness markers: daemon disconnect/startup failure clears readiness, and the
  in-cluster rollout waits for a built worker plus live WebSocket connection.

Integration tests:

- Linux CPU: Incus VM path, daemon pod from CPU base image, C++ worker built with `clang++`, CBOR
  WebSocket add returns the expected `Float` result and backend metadata.
- Linux GPU: direct host `nvkind` cluster launched through the project container, daemon pod from CUDA
  base image with NVIDIA runtime visible, CUDA worker built with `nvcc`, add returns through the
  WebSocket path.
- Apple Silicon: host daemon starts after `project up`, Apple Metal build-stack ensure runs on the host,
  Swift/Metal worker builds and runs, daemon connects through the exact resolved loopback exposure, add returns through
  the WebSocket path.
- Windows GPU: host daemon starts after `project up`, `ensure cudawin` verifies/installs CUDA + MSVC C++
  workload + LLVM clang, CUDA worker builds with `nvcc`, daemon connects through the exact resolved loopback exposure,
  add returns through the WebSocket path.

Implemented browser e2e specifications:

- The demo UI exposes two numeric inputs and an add button.
- When the harness reports a serving daemon, the test fills representative `Float` values, clicks add,
  waits for the asynchronous result, and asserts both `1.5 + 2.25 = 3.75` and Float32 rounding
  (`2^24 + 1 = 2^24`). It also asserts that the returned backend equals the lane's backend name and that
  the artifact hash has the right shape (16 lowercase hex digits). The hash check is a shape check only:
  the hash identifies the generated source template, which the server could compute itself. The guard
  against in-process computation is the static `WebServerSpec` case "accelerator dispatch has no
  in-process fallback", together with the Float32 and backend assertions.
- With no daemon lane, the test asserts the no-fallback `accelerator daemon unavailable` state.
- Existing message-variant coverage remains; the accelerator case is added to the suite rather than
  replacing the web/service checks.

## Current Status

The implementation includes
config-selected `service run` with real `Web`/`Accelerator` Dhall payloads; separate linked listeners;
dynamic rollout-hashed ConfigMaps; persistent workers; strict Float32 semantics; checked CUDA failures;
direct Linux GPU `nvkind`; in-cluster Linux CPU/GPU daemon manifests; and serialized host-daemon lifecycle
with absolute PID identity, symmetric PID/owner witnesses, graceful shutdown, force fallback, ambiguity
preservation, and a bounded 30-minute pristine-install/build/connect readiness gate.
Exact static-gate defects, test totals, live substrate evidence, and closure owners belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

The core service entry is activation-only. A launcher must install one immutable revision, provision its
public key separately, and pass their absolute paths plus the matching protected-store root. Kubernetes supplies
pod UID/restart count; a host launcher supplies a fresh invocation nonce. The demo chart installs its exact
root-signed revision in the Kind-shared durable root, mounts that revision and a shared authority store, and reads
the controller's current restart count through a pod-`get`-only runtime service account. Both concrete demo roles
are `serviceProgramDefinition` values with explicit role drafts and effect rows; `service run` has no full-config
or raw-`IO` compatibility path.

The accelerator is not part of the Helm chart transaction, so its own plan step carries a standalone activation
declaration with the derived daemon frame, `accelerator` role, and the `network-listen`/`process` effects its
`serviceProgramDefinition` declares. The root admits that declaration exactly like the chart-owned web
placement. That effect row does not match what the role does: the daemon binds no listener, and its one
network operation is the outbound WebSocket dial to the web service, which runs as plain IO inside the
served application and is not declared as `network-connect`. Linux pods mount the immutable revision and
authority store, query their own `daemon` container restart count, and enter `service run` with the downward-API
pod UID. Apple and Windows host placements measure the copied daemon executable, install the matching public key
and revision into durable state, and use a new host invocation nonce for every detached launch.

Web and accelerator share the authority store but not a lifetime-wide transaction lock. Each completes its
admission transaction before entering the role engine and then retains only its own service/frame generation
lease, allowing the two long-running roles to serve concurrently.

### The host-resident launch boundary

The host-resident launch is a sealed boundary — `HostBootstrap.Detached`, under
[unrepresentable_state](../architecture/unrepresentable_state.md). The demo does not choose a stdio
disposition, because there is no field to choose one in: it supplies the daemon executable, the
one `hostAcceleratorDaemonArgs` argv both the launch and the process-identity matcher read, the complete
child environment, an absolute working directory, and an absolute output sink. The boundary supplies the
rest. The daemon's standard input is the host's null device, so it is open and already at EOF; both of its
output streams are appended to
`.build/accelerator-daemon/hostbootstrap-demo.accelerator.output`, which is a lifecycle witness like the
pid, ready, and shutdown files and is removed with them. When readiness does not arrive, the launcher
reads that sink and quotes it under the failure
([§ CC](../../DEVELOPMENT_PLAN/development_plan_standards.md#cc-readiness-gated-lifecycle-steps-and-legible-failure)),
so the daemon names its own cause instead of collapsing to "the process is gone".

Two placements sit outside this boundary. The in-cluster placements inherit the kubelet's streams, and the
Windows host placement takes its separate hidden `Start-Process` path, whose short-lived PowerShell parent
owns the child's streams and therefore has no sink to quote.

### Live acceptance

Each daemon lane's live acceptance run is recorded in the phase that owns its substrate: Linux CPU in
[the worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md), Apple Silicon in
[the Apple Silicon substrate phase](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md), Linux GPU in
[the NVIDIA GPU substrate phase](../../DEVELOPMENT_PLAN/phase-27-nvidia-gpu-substrate.md), and Windows GPU in
[the Windows and WSL2 substrate phase](../../DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md).
Dated results and phase status live there and in [the development-plan index](../../DEVELOPMENT_PLAN/README.md),
not here.

### Open gaps

- **Web rollout overlap.** The web `Deployment` takes the default `RollingUpdate`, so a rollout briefly runs
  two web pods with separate process-local hubs (see [Cluster Exposure](#cluster-exposure)), which the
  single-replica rule exists to prevent. Setting `Recreate` on the web workload, or documenting the overlap
  as accepted, is owed by [the worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).
- **Accelerator effect row.** The accelerator role declares `network-listen` and `process` but only dials
  out, undeclared (see above). Declaring `network-connect` in place of `network-listen` is owed by
  [the worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).
- **Unserved accelerator ingress on `windows-cpu`.** The `windows-cpu` lane runs no daemon, yet its WSL2
  context selects `HostResidentDaemon`, so the chart renders the host-daemon accelerator Service and the relay
  publishes a loopback listener nothing serves (see [Substrate Matrix](#substrate-matrix)). Making the
  placement follow the lane, or recording the publication as accepted, is owed by
  [the worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

## See Also

- [composition_patterns](composition_patterns.md) - host-native daemon and headless host-build shapes.
- [ensure_reconcilers](ensure_reconcilers.md) - install-and-verify host reconciler contract.
- [base_image](base_image.md) - CPU and CUDA base image contents trusted by in-cluster daemon pods.
- [demo_runbook](../operations/demo_runbook.md) - the worked demo lifecycle this feature extends.
