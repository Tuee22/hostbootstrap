# Phase 13: hostbootstrap-demo worked app

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md), [phase-12-layered-warm-store.md](phase-12-layered-warm-store.md)

> **Purpose**: Add a self-contained worked consumer under `demo/` whose test suite demonstrates every main
> feature end to end, centered on a from-zero pristine-host bootstrap performed inside a managed Linux VM
> (Lima on Apple Silicon, native Incus on Linux).

## Phase Status

**Status**: Active

**Reopened (2026-07-04, extended 2026-07-05) then closed (2026-07-05)** for the **in-cluster-registry
doctrine switch** (Harbor → single-binary `registry:2`) and the **cross-substrate reliability hardening** the
real-run gate surfaced. **Closed 2026-07-05** by a live Windows/WSL2 `hostbootstrap-demo test run all`
reporting **`test report: 6/6 passed`** across both message variants: `deploy-registry: in-cluster registry
rollout complete at http://localhost:30500` and `push-image: kind-loaded hostbootstrap-demo:local and pushed
localhost:30500/library/hostbootstrap-demo:demo` fired on **both** bring-ups (the single-binary `registry:2`
+ poll-to-Ready hardening), the web service was reachable at `localhost:30080`, and `project destroy` tore
down cleanly.
The demo's `deploy-harbor` step became `deploy-registry`, replacing the 8-pod Harbor Helm stack + the
`ghcr.io/octohelm/harbor/*` dual-arch mirror + the trivy scanner with a single `registry:2` (CNCF
`distribution`) Deployment applied via `kubectl` — natively multi-arch, anonymous, HTTP. Harbor was never
load-bearing (the web pod runs the `kind load`-ed project image; no assertion touches the registry), so the
change is confined to the demo's contributed `deploy-registry` / `push-image` steps; core is untouched.

**2026-07-05 real-run finding.** A live Windows/WSL2 `test run all` validated the full lifecycle up to
`deploy-registry` (WSL2 provision → in-place VM config → build #2/#3 → web build → `kind create` → cordon),
then exposed a bug: `deploy-registry` pre-loaded the **multi-arch** `registry:2` via `kind load
docker-image`, which fails (`ctr import --all-platforms` → "content digest not found"). **Fixed** (code
landed, `-Werror` green): `deployRegistryAction` no longer `kind load`s `registry:2`; the Deployment pulls
it (`imagePullPolicy: IfNotPresent`) so containerd selects the node platform from the multi-arch manifest —
the demo's own single-arch project image is still delivered locally by `push-image`'s `kind load`. The same
run surfaced demo-side reliability gaps (the `deploy-registry` rollout timeout on the kubelet pull, missing
registry readiness before `push-image`, `pushWithRetry` retrying non-transient failures, Production-profile
port reuse, `runVmUp` reconcile) tracked in `## Remaining Work`.

**Real-run-closed 2026-07-05: `6/6` with the `registry:2` pod-pull + poll-to-Ready fixes** — see Sprint 13.16,
`## Remaining Work`, and [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) (the retired
Harbor / `kind load registry:2` surfaces moved to Removed Surfaces on this closure).

**Reopened and closed (2026-07-02)** for **in-place child-config delivery** (development_plan_standards
§ U, § X; [phase-15](phase-15-binary-context-config.md) Sprint 15.7): the demo replaced the build-then-copy
VM config (`writeAndCopyVMConfig` writing `demo/.build/hostbootstrap-demo.vm.dhall` + `copyFileToDemoVM`) and
the build-then-mount container config (`mintContainerConfig` + the `demoDeployImage` config bind-mount of
`hostbootstrap-demo.runtime-container.dhall`) with a projection **streamed in-place**: the parent renders a
context-adjusted full child config and pipes it over the lift's `stdin` channel, and the descending binary writes its
own sibling `<project>.dhall` before dispatch. No host-side `.vm.dhall`, no `.runtime-container.dhall`, no
config bind-mount (the docker-socket and `/run/hostbootstrap` witness mounts are retained). **Closed
2026-07-02**: `streamVMConfig`, `containerConfigPayload` + `demoDeployImage payload`, and `contextInitAnnounce`
landed (demo `-Werror` build + suite green); a live Windows/WSL2 `test run all` reported **`6/6`** with both
in-place markers firing and no `.vm.dhall`/`.runtime-container.dhall`/config bind-mount. See Sprint 13.15 and
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

**Reopened (2026-06-19) and closed (2026-06-20)** for the unified-harness / fixed-command-surface /
budget-doubling correction: the demo's test surface drives the real `project up` (not a second bring-up
mirror), the budget-doubling VM sizing collapsed to budget = VM wall / cluster = slice, and the `web serve`
/ `web bridge` verbs moved to config-selected `service run` (`Web`) + the build-image step. **The closing gate is met,
real-run-validated end-to-end on a 16 GiB Apple-Silicon host (2026-06-20):** a full `project up` stands up
the live persistent stack (8-pod Harbor on `arm64` via the dual-arch `ghcr.io/octohelm/harbor/*` images,
config-selected `service run` serving the `Web` variant at **HTTP 200** on `localhost:30080`), and **`test
run all` reports `3/3 passed`** —
`pristine-bootstrap` + `web-build` (NodePort reachability from the harness frame) and `e2e-tabs` (the
Playwright run across chromium/firefox/webkit lifted into the VM frame) — driving the same `project up` and
tearing down with `project destroy`. See `## Remaining Work` for the validated
detail.

Forward-pointer: the demo's config-driven `message` worked example — the demo's `cfg` gains a
`message : Text` field that flows `<project>.dhall` → the binary-rendered ConfigMap → the web service → the SPA, plus
the two-variant run (`"Hello, world!"` then `"Hello, Universe!"`, full teardown + spin-up between) and the
polymorphic Playwright `e2e-tabs` spec — is owned by
[phase-20-config-driven-demo-worked-example.md](phase-20-config-driven-demo-worked-example.md). It is
additive; this phase's validated shape is unchanged.

The earlier chain-is-the-project migration remains real-run-validated end-to-end (2026-06-18): the
demo's deploy is the contributed chain stream, now substrate-selected by
`demoChainFor` (plus the historical `demoFrameContext` / `demoTeardown`) and
interpreted by the core `project up`, which stood up the full live persistent stack — the
3-frame recursive descent → `deploy-kind` → the 8-pod production Harbor → the 20GB image push → the web chart
pod → `localhost:30080` serving HTTP 200 — and tore it down with `project down` / `project destroy`
(§ Y). The hand-written `demoDeployChain` (`HostBootstrapDemo.Chain`) and all demo noun
verbs are deleted; their still-required behavior lives in chain-step actions and config-selected service
handlers. The interpreter it rests on is [phase-16](phase-16-project-lifecycle-command.md) (`Active` for
the current live accelerator gate). The original narrative below describes the historical shape that led
to the current implementation.

`hostbootstrap-demo` lives under `demo/` with a repo-local build path at `demo/.build`. It extends
`hostbootstrap-core` directly via `runHostBootstrapCLI "hostbootstrap-demo" projectSpec`, exercising the
extension streams: the substrate-selected lift chain (`demoChainFor`), schema-registry concat (`demoArtifacts`), Dhall
vocabulary use, the service-handler registry (`demoServices`), and the stack-driven `demoTestSuite`. Its
`ProjectSpec` supplies `demoChainFor substrate` (whose steps declare their own frame descents) /
`demoCheckCode`, `demoArtifacts`,
`demoServices`, and the non-empty `demoTestSuite` — no project verbs (the surface is fixed, § P).

Historical note: this phase was previously reopened for the **"the chain is the project"** migration (§ Y,
§ T). That migration is now closed: the hand-written `demoDeployChain` and its small interpreter in
`demo/src/HostBootstrapDemo/Chain.hs`, together with the demo's `vm`/`deploy`/`incus`/`harbor`/`web`/`role`
noun verbs, became `demoChain :: ProjectConfig -> [Step]` interpreted by the core `project` lifecycle.
That was the intermediate historical signature; substrate-aware direct Linux-GPU support later replaced
it with the current `demoChainFor :: Substrate -> ProjectConfig -> [Step]`.

The former demo deploy shape followed the single-representation doctrine (§ W). `demo deploy` was one
explicit lift sequence whose only lifted compute step was `test all` inside the project container in the
managed VM:

```text
vm ensure
vm up
vm pristine-bootstrap
<vm-provider-exec> -- docker run --rm <image> test all
vm down
```

Inside that lifted `test all`, the harness runs `clusterUp` locally on the VM's Docker, so the kind
cluster lives in the VM. The demo uses sibling `hostbootstrap-demo.dhall` files for each runtime context:
host, VM, VM project container, and service/daemon pod.

The demo covers these current supported surfaces through the fixed command tree:

- `project up`, `project down`, and `project destroy` interpret the substrate-selected chain, including VM
  provider reconciliation, host-native and project-image builds, kind/nvkind, the S3-backed registry, web
  chart, exposure, and accelerator daemon placement.
- `test run all` runs four harness cases over two generated config variants with fail-closed pre-existing
  state probes, per-variant teardown, and an expected `8/8` live result.
- Config-selected `service run` starts either the web role or accelerator daemon from the sibling Dhall
  `ServiceType`; the same handlers are pod and host-daemon entrypoints.
- `context` exposes generated schema/config artifacts, while `check-code` owns the project quality gate.

The Apple Silicon path uses Lima (not an Incus VM), and the runtime context is topology-strict: a direct
host/container fallback cannot run `test run all` against the wrong Docker daemon, because a
VM-project-container config requires a VM-orchestrator ancestor and runtime witnesses (the Dockerfile bakes
image-build authority only; the lifted runtime container receives the narrowed parent-generated config
in-place over the handoff's `stdin`, with no config bind-mount). The Lima fold, the topology-aware context enforcement, and the
full real Apple Silicon Lima lifecycle — including the Playwright e2e suite — validated that former
noun-verb shape before it was replaced by the fixed command surface.

**Reopened 2026-07-09 for the substrate-specific accelerator daemon demo.** The demo now has the real
accelerator path: the UI accepts two `Float` values, the web service dispatches CBOR work over WebSocket to
a separate project-binary daemon, and the daemon forwards the calculation to a persistent JIT-built
Swift/Metal, CUDA, or C++ worker depending on substrate. No fake in-process accelerator can satisfy this
feature.

The implementation is complete statically. The SPA has an `Accelerator` tab with two numeric inputs, an
Add action, pending/error/result states, and backend/artifact metadata. The Haskell web API has typed
request/result/failure records and two linked configured listeners (defaults: public HTTP 8080 and private
accelerator 8081), exposed through distinct Service target ports. The public listener cannot upgrade the
private daemon WebSocket route; linked-listener failure propagates; and a second concurrent request fails
with 503 while the single daemon is busy. The public add endpoint returns `accelerator daemon unavailable`
instead of computing locally when no daemon is connected. `HostBootstrapDemo.Accelerator` supplies
deterministic Swift/Metal, C++ and CUDA worker generation, stable artifact hashes, persistent worker
supervision, and `Float32` wire/worker semantics for every lane. The config-selected `service run` surface,
browser Add assertion, dynamic config delivery, placement-specific daemon lifecycle, and fail-closed test
safety are implemented; only the live substrate gates remain.

## Current Status

The demo's old noun-verb deploy shape is superseded. The current demo contributes
`demoChainFor :: Substrate -> ProjectConfig -> [Step]`, interpreted by the fixed `project up` /
`project down` / `project destroy` surface. The former `vm` / `incus` / `harbor` / `web` / `role` verbs and the separate
hand-written deploy interpreter are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), not current surface area. The demo's
stack-driven `TestSuite` drives the real `project up` under generated configs and tears down with
`project destroy`; config-selected `service run` owns both long-running service variants.

## Remaining Work

**Production-plan and provenance work — open (Sprint 13.18).** Thread one typed production
plan/`TestComponent`, consume freshly pulled rolling bases, and reconcile MinIO/registry metadata and
persistence assertions.

**Registry route repair — open (Sprint 13.20).** Replace the raw host-client/cluster-only-backend
combination with the Phase 14.7 finalized plan, then prove initial and repeated push, pull, and
registry-pod recreation. `/v2/` readiness and the historical initial-push run do not close this route.

**Accelerator daemon demo — implementation complete; honest live gates open.**

- **Landed (static):** mandatory `webServiceConfig` and `acceleratorServiceConfig` fields preserve both
  parameter sets; leaf context structurally selects the typed role through the finalized registry, with
  no positional service argument or fallback. The chart and daemon process both use `service run`.
- **Landed (static):** the UI, typed CBOR protocol, request correlation, bounded timeouts, no-in-process
  fallback, linked public/private listeners, distinct Service target ports, fail-closed listener errors,
  single-flight 503 behavior, and `haReplicas = 1` constraint. Playwright runs its three browser
  projects with one worker so their accelerator assertions exercise that single daemon serially instead
  of manufacturing cross-engine contention. The browser spec fills both inputs and
  asserts the daemon-returned `Float` result, backend, and artifact hash.
- **Landed (static):** deterministic Swift/Metal, C++ and CUDA generation; stable artifact hashing;
  persistent worker reuse; `Float32` protocol semantics (including `2^24 + 1 -> 2^24`); reconnect,
  timeout, shutdown, and failure propagation. The guarded real CUDA worker gate historically built and ran
  on an RTX 3090 and returned `Right 3.75`; the Apple worker smoke returned the same result on 2026-07-10.
- **Landed (static):** `HostBootstrapDemo.Commands` dynamically renders and applies the web and daemon
  ConfigMaps from the actual parent topology; exact config-byte hashes roll subPath-mounted pods. Linux
  CPU/GPU daemon Deployments apply and rollout-wait before connecting to the distinct accelerator
  `ClusterIP`, with a one-GPU request on the GPU lane. Apple/Windows use the host-native project-binary
  build/run path with strict process ownership and teardown.
- **Historical partial safety work:** `SafetyRefusal`, config/path guards, a direct-cluster probe, and
  teardown verification landed, but they are not exclusive identity-bearing ownership. Sprint 5.7
  supplies backend receipts; Sprint 10.9 opens the opaque harness profile over Sprint 15.9's root
  authority.

The dated 2026-07-15 static counts remain sprint evidence. The Windows GPU host-daemon lane later produced
an accepted `8/8` run; Apple Silicon and native Linux CPU/GPU lanes remain open. Sprint 13.18 also owns
Production-plan/TestComponent, base-digest, and registry/MinIO implementation repairs, so phase remaining
work is not live-only.

**Native Linux CPU lane closed 2026-07-29.** `hostbootstrap-demo test run all` reported **`10/10 passed`**
on a genuinely `linux-cpu`-detecting host (a fresh Ubuntu 24.04 Incus VM, whose kernel carries no NVIDIA
markers and no `nvidia-smi`, with the demo's own Incus VM nested inside it). The run brought up the
VM-backed stack through `cluster up: nodes Ready`, MinIO, the in-cluster registry, `push-image`,
`expose-port: web service reachable at http://localhost:30080/`, and
`deploy-accelerator-daemon: in-cluster accelerator daemon deployed (dials the web ClusterIP ingress)`,
with all five cases (`pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`,
`durable-readback`) passing on both config variants. The complete evidence block lives with the sprint
that owns the lane, [phase-5 Sprint 5.5](phase-5-cluster-lifecycle-and-resource-cordoning.md). This closes
**only** the Linux CPU lane; the Apple Silicon lane has no available host.


**Durable root end-to-end proof — OPEN.** The demo now creates host project-root `.data` and carries it
through provider share/alias, container, kind node, and pod. The remaining gate is the dedicated
write→destroy→up→read-back proof. The landed carry crosses **VM → project container** (a `Mount` on the
container launch), **project container → kind node** (`extraMounts` alongside port mappings), and **kind
node → pod** (a host-backed chart volume). This consumes
[phase-11](phase-11-incus-host-provider.md) Sprints 11.8/11.9 for the host share and initial VM alias;
Sprint 11.10 still owns direct-host totality/exclusive ownership, plus
[phase-5](phase-5-cluster-lifecycle-and-resource-cordoning.md) Sprint 5.6 (the durable-root contract) and the
demo's adoption of the type-level config newtypes (phase-9 Sprint 9.9). It is gated by the same real run
(§ C) those sprints share: write state through the running stack, run
`project destroy`, run `project up`, and read it back. Until that gate passes, no demo document may
claim the end-to-end persistence proof has passed. Documents must still describe the implemented host-root
and carry mechanism honestly — see
[durable_state](../documents/architecture/durable_state.md).

**In-cluster-registry switch + reliability hardening — CLOSED (real-run, § C, 2026-07-05).** The Harbor →
single-binary `registry:2` swap (Sprint 13.16) plus the demo-side reliability fixes are **real-run-validated
end to end**: a live Windows/WSL2 `hostbootstrap-demo test run all`, run **decoupled** from the Claude harness
as a Windows Scheduled Task (so a harness stop could not abort it), reported **`test report: 6/6 passed`**
across both message variants — `deploy-registry` stood up the pod-pulled `registry:2` (rollout complete on
both bring-ups), `push-image` kind-loaded the project image and pushed it to `localhost:30500`, the web
service served at `localhost:30080`, and `project destroy` tore down cleanly. The
retired Harbor / `kind load registry:2` surfaces move to **Removed Surfaces** in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). The demo-side reliability fixes that
closed the gate:

This dated closure proves the Harbor replacement and then-tested initial push path only. The later
repeated-blob failure discovered on 2026-07-25 is distinct follow-on scope in Sprint 13.20; it reopens
the route/persistence claim without falsifying Sprint 13.16's historical evidence.

- **Harden `deploy-registry` — landed.** The fixed fatal `rollout status --timeout=120s` is replaced by
  `waitRegistryRollout` (poll-to-Ready with backoff: 6 × up-to-60 s + 5 s backoff, so an unauthenticated
  `registry:2` pull under Docker Hub load is tolerated), and the registry Deployment carries a
  `readinessProbe` on `GET /v2/` (`:5000`, `failureThreshold: 60`) so the NodePort Service gets no endpoints
  until the registry actually serves. `push-image` is therefore not scheduled before an initial serving
  observation and also performs its own poll/retry; this does not claim the external service cannot
  become unavailable after observation.
- **`pushWithRetry` — landed.** It now retries **only** the known transient markers
  (`isTransientPushError`: digest/blob-upload races, connection resets, 5xx), and a non-transient failure
  dies immediately with full diagnostics instead of burning the retry budget. `push-image` first polls
  `GET /v2/` on the NodePort (`waitWebReachable`) before pushing.
- **Demo-side resource checks — historical intermediate; isolation remains open.** Budget-scaled
  `clusterSliceOfBudget` plus swap-headroom kind-node cordon landed with
  [Phase 9](phase-9-applied-cordon-and-one-parser.md), and the in-VM
  `productionClusterRunning` probe now actually fires. That probe is cooperative check-then-act, not
  mutual exclusion, and the demo still resolves its live `containerPlan` with the `Production` profile;
  Phase 10.9 owns the project-wide mode lease and Harness-only profile. `runVmUp` reconcile re-merges the
  WSL2 config and applies it only on the stopped-distro path with
  [Phase 11](phase-11-incus-host-provider.md); a running utility VM can retain an old live ceiling.

- **Staging robustness — landed (real-run finding).** An early Windows/WSL2 closure attempt (2026-07-05)
  reached the in-distro `pipx install` and failed `Directory '/root/hostbootstrap' is not installable`
  because the host staging `tar` hit a `Permission denied` on a transient, admin-owned `.pytest_cache` and
  produced a **truncated** archive (missing the repo-root `pyproject.toml`), which the "exit-1-but-tarball-
  written = non-fatal" path silently accepted. Fixed in `stageSource`: exclude the transient host caches
  (`.pytest_cache` / `.mypy_cache` / `.ruff_cache` / `__pycache__`) so the archive is complete and
  reproducible, **and** assert `pyproject.toml` is present after extraction so a truncated stage fails loudly
  at the source rather than as a confusing downstream `pipx` error. The reliability fixes themselves behaved
  correctly on that attempt (Phase 16 best-effort teardown fired, Phase 11 restored/removed `.wslconfig`,
  Phase 10 isolated both variants), confirming the guard paths.
- **Live output — landed (observability).** The demo binary now line-buffers `stdout`/`stderr`
  (`demo/app/Main.hs`) so every step announcement and any failure `die` streams live through the lifted
  `project up`/`test run` pipe instead of sitting in the default block buffer — behaviour-neutral, but it
  makes a long lifted run observable in real time (all frames inherit it, since they run the same binary).

Code-check gate (2026-07-05): the demo `-Werror` build (the in-container `check-code` gate) + demo/core
suites (14 + 292) green. **Real-run gate CLOSED 2026-07-05:** the decoupled Windows/WSL2 `test run all`
reported **`6/6 passed`** across both message variants (`REALRUN_EXIT=0`).

The retired Harbor surfaces and the removed `kind load registry:2` pre-load are now recorded in the
**Removed Surfaces** of [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

The contributed chain stream interpreted by `project up` is built and real-run-validated (2026-06-18);
the current implementation routes through `demoChainFor` so `linux-gpu` can use the direct host-container
path while other substrates keep the VM-backed chain. The unified-harness / budget-doubling / fixed-surface correction
(development_plan_standards § W, § O, § P, § AA) **landed in code (2026-06-19), code-check-validated**
(`cabal build all --ghc-options=-Werror` green; fourmolu/hlint clean on the demo `app`/`src`; the Python
gate green; verified on the real binary that the surface is fixed and `project up --dry-run` renders the
9-step chain):

- **Harness drives `project up`.** The `demoSeams` `seamSetup` mirror (`clusterCreate caseResources` →
  `kind load` → `deployChart`) and the per-case `caseResources` cluster model are **deleted**; the demo's
  `demoTestSuite` (the stack-driven `TestSuite`, [phase-10](phase-10-standardized-test-harness.md)) drives
  the real `project up` / `project destroy` via the binary self-reference and asserts against the live
  stack.
- **Historical budget doubling removed; later authority repair recorded.**
  `vmSizingWithHeadroom` was **removed**; at this landing creation used a raw context envelope and
  `deployKindAction` computed a smaller local cluster slice. Sprints 9.10/19.8 subsequently removed the
  duplicate and made top-level `resources` the sole project budget. The slice still does not reach every
  service leaf, existing provider walls are not uniformly reconciled, and direct Colima/Linux-GPU outer
  effects remain uncapped; those live integrations retain their later sprint owners.
- **Web role moved to `service`.** `web serve` → config-selected `service run` (the `Web` handler in
  `demoServices`, [phase-18](phase-18-service-runtime-command.md)); `web bridge` → the build-image chain
  step (`runVmBootstrap` runs `writeBridge` before the image build); the chart pod's entrypoint is
  `service run`, with the `Web` variant selected by its delivered config. The `vm`/`incus`/`web` verbs and the
  `ProjectCommand` extension are deleted; their IO is retained as library/step functions
  ([phase-16](phase-16-project-lifecycle-command.md)).

**Closing gate (real-run, § C) — MET on a 16 GiB Apple-Silicon host (2026-06-20):** the full demo lifecycle
+ `test run all` + `service run` all pass. The sizing fix makes the VM = budget fit the 16 GiB host (the old
2×-budget VM did not). `test run all` reports **`3/3 passed`** — `pristine-bootstrap` and `web-build`
(NodePort reachability from the harness frame) and `e2e-tabs` (the Playwright run across
chromium/firefox/webkit lifted into the VM frame) — by driving the **same** `project up` (no second
bring-up path, § W), then tearing the stack down with `project destroy`. The
harness's per-case assertions run in the frame appropriate to each (reachability from the harness frame, the
e2e lifted into the VM via the self-reference lift, § U).

`test run all` ran **`3/3` on both** Apple-Silicon/Lima (2026-06-20) and native Incus/Linux (2026-06-21)
in the pre-phase-20 single-message-variant matrix; phase-20's second message variant brought the current
run to **`6/6`**.
All three cases run in the **VM frame**: each reachability check is a pure probe folded into the VM by the
self-reference lift (`incus exec <vm> -- curl …` / `limactl shell <vm> -- curl …`, via
`HostBootstrap.Lift.reachLeaf`/`liftLeaf`), so it reaches the in-cluster NodePort whether or not the
provider forwards the guest port to the host. (The earlier Incus `1/3` — host-frame reachability assertions
Incus did not forward — was closed by that lift generalization; see
[phase-17](phase-17-chain-driven-test-and-context-introspection.md).)

**Real-run validation on the 16 GiB Apple-Silicon host (2026-06-19/20), with the operator Docker Hub login
in place — the full `project up` lifecycle completes end-to-end (exit 0):** the live persistent stack
serves **HTTP 200** at `localhost:30080` (`/api/budget` returns the `fitsBudget` view, `cpu=6 memory=10`
the VM wall with `podCpuLimit=1 podMemoryLimit=2` the cluster slice within it), all **8 Harbor pods Run**
on `arm64` (`harbor-core` = `ghcr.io/octohelm/harbor/harbor-core:v2.14.0`, the dual-arch mirror), and the
  web pod runs `args: ["service","run"]` with the `Web` variant selected by config (the `web serve` →
  `service run` migration, live). Reaching
this took the metal-frame validation below plus three real-run fixes (the two bugs noted at the end and the
dual-arch Harbor override):

- A new VM was provisioned at **exactly the then-selected raw context envelope**
  (6 CPU / 10 GiB / 80 GiB), confirming removal of the old 2× sizing calculation. This run did not prove
  a unique config budget authority, reconciliation of an existing VM, or caps on every topology effect.
- build #2 (host-native in the VM) of the **refactored** binary — fixed surface (self-proved with `context
  schema`), `service` command, removed verbs — succeeded; build #3 (image FROM the published `arm64` base,
  credential-forwarded pull) succeeded, with the in-image `check-code` (fourmolu / hlint / `cabal -Werror`)
  **passing** and the host-generated PureScript bridge + `spago` / `esbuild` web build succeeding;
  the then-current `context-init` path minted the project-container child config; **`deploy-kind` brought up the cordoned cluster**
  (the cluster **slice** within the VM wall — the node reported `MemoryPressure False`, so the slice sizing
  is sound).
- **`deploy-harbor` first failed on an upstream platform gap (now fixed in the chain):** every
  `goharbor/*` pod crash-looped with `exec format error` — the upstream Harbor images are **amd64-only
  single-arch manifests** (verified for `harbor-core` `v2.15.1` and `v2.12.2`), and the kind nodes are
  `arm64`. This is a substrate floor, not resources (the node reported `MemoryPressure False`). **Fix
  applied (2026-06-19):** `deployHarborAction` now pins the chart to `1.18.3` and overrides every Harbor
  component image to the dual-arch `ghcr.io/octohelm/harbor/*:v2.14.0` mirror (the approach the
  `mattandjames` sibling uses; `goharbor/*` is amd64-only, so `kind load` does not help — it loads the only,
  amd64, manifest). **This octohelm mirror was superseded (2026-07-04) by the single-binary `registry:2`,
which is natively multi-arch and needs no mirror — see Sprint 13.16 and
[in_cluster_registry.md](../documents/engineering/in_cluster_registry.md).** The full 8-pod Harbor →
  `push-image` → `deploy-chart` → `expose-port` lifecycle is also validated on the **Linux/amd64** path
  (2026-06-18), and those step actions are otherwise unchanged by this refactor (only `deploy-kind`'s cordon
  changed, to the slice). `project destroy` then deleted the VM and its disk (§ Y).
- **Two real-run bugs in this refactor were found and fixed:** (1) `.dockerignore` excluded
  `demo/web/src/Generated/`, which the old in-image `web bridge` regenerated but the re-homed host-side
  bridge step needs in the build context; (2) `runVmUp` always issued a VM *create*, breaking idempotent
  reconcile-to-running on a re-run — it now starts an existing instance (Lima/Incus).

The remaining real-run closure is the full registry lifecycle with the refactored code — resolved on every
substrate by the 2026-07-04 switch to the single-binary `registry:2`, which is natively multi-arch (so the
earlier "`arm64`-capable Harbor images" gap no longer exists); the open gate is now the `registry:2`
real-run validation (Sprint 13.16, `## Remaining Work`). The interpreter this drives is owned by
[phase-16](phase-16-project-lifecycle-command.md); the harness engine by
[phase-10](phase-10-standardized-test-harness.md); the service command by
[phase-18](phase-18-service-runtime-command.md).

## Phase Objective

Provide the canonical worked consumer and operations runbook. The demo's point is to demonstrate
`hostbootstrap` bootstrapping a **pristine** linux host from zero: because the metal host is not pristine,
the demo orchestrates a pristine managed Linux VM and runs the genuine first-run flow inside it
(`apt install pipx` -> `pipx install hostbootstrap` -> `hostbootstrap run`). This is a deliberate
**3-build** illustration on top of the standard host-native build (see
[development_plan_standards.md § N](development_plan_standards.md)): a metal orchestrator build plus,
inside the pristine VM, the host-native binary build (by `hostbootstrap run`) and the binary-driven
project-container build.

The demo is also the worked exercise of the resources hostbootstrap intends to own. The Python wrapper's
host minimums are the intentionally non-installing pre-binary gate; later reconcilers install dependencies
that are merely absent when a supported plan exists, while retaining wrong-host, non-installable,
conflict, safety, and verification failures. The full a→f lifecycle
(see [demo_runbook.md](../documents/operations/demo_runbook.md)): (a) the metal binary reconciles the VM
provider (Lima on Apple Silicon, Incus on Linux, WSL2 on Windows); (b) `ghcup` is installed and the binary is built **on the VM**; (c) the binary
installs Docker and builds the project container; (d) the project container spins up the kind cluster and
deploys the webservice; (e) the project image's base-provided Playwright runtime runs e2e against it from
a container on the VM; (f) on the dated successful path, `project destroy` stops/removes the provider and
deletes the provisioned VM **and its disk**, while the demo's `.data` lives at the host project root and
is carried into the guest/container/Kind/pod path outside that disk. This is happy-path evidence, not a
claim that every created resource is released: current teardown is not derived as a recursive inverse,
not every resource carries an identity-bearing ownership receipt, and interruption can leave work for
recovery. The dedicated write→destroy→up→read-back proof remains open. Dependencies in (a)–(f) with
supported install plans are driven through the `ensure` suite rather than documented as manual host
prerequisites.

## Sprints

### Sprint 13.1: `demo/` skeleton and the metal orchestrator binary [Done]

**Status**: Done
**Implementation**: `demo/hostbootstrap-demo.cabal`, `demo/cabal.project`, `demo/app/Main.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/operations/demo_runbook.md`, `system-components.md`

**Historical scope.** The appended `demoCommands`/demo-verb surface described below was later removed.
The retained consumer now supplies `ProjectSpec` extension values under the fixed command tree; only the
dated skeleton milestone, not those verbs, is recorded here.

#### Objective

Stand up the `demo/` tree and the metal orchestrator binary: the Cabal package extending
`hostbootstrap-core`, the appended project commands, and build #1.

#### Deliverables

- The `demo/` tree: the Cabal package extending `hostbootstrap-core` via `runHostBootstrapCLI` and
  `ProjectSpec`, the appended `demoCommands`, the required `demoCheckCode` image-build gate, and
  **Build #1** (the metal orchestrator) via the usual workflow.

#### Validation

- `hostbootstrap-demo --help` shows the inherited core verbs plus the demo verbs.

#### Remaining Work

None.

### Sprint 13.2: Linux Incus pristine VM path [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`incus ensure` / `vm up` / `vm down` drive the real incus host-provider surface)
**Docs to update**: `documents/operations/demo_runbook.md`

**Historical scope.** The noun verbs below were dissolved into `project up|down|destroy` chain actions.
They are not current commands; the provider IO and sizing behavior are the retained implementation.

#### Objective

Drive core's `ensure incus` and spin up a budget-sized pristine `ubuntu/24.04` VM (cordon #1) via the
demo's noun-first project verbs on native Linux. Apple Silicon Lima support is tracked in Sprint 13.14.

#### Deliverables

- The demo groups its project verbs under nouns (`incus`/`vm`/`harbor`/`web`), distinct from the
  inherited verb-first core verbs (`ensure`/`config`/`cluster`/`test`/`check-code`): `demo incus ensure`
  consumes core's `ensure incus` (install-and-verify: explicit Colima-backed Incus provider on Apple,
  native daemon on Linux)
  and, on Linux only, ensures the VM capability the core reconciler does not cover —
  `qemu-system-x86` + `ovmf` plus a daemon restart so incus re-detects QEMU; `demo vm up` derives the
  VM sizing from the one canonical parser (`incusSizingArgs`) and launches a
  budget-sized pristine `ubuntu/24.04` VM (**cordon #1**: the VM is the wall), formatting the sizing into
  `incus launch` flags (`-c limits.*`, `-d root,size=…`); `demo vm down` destroys it behind the
  name-prefix delete-guard (`destroyVMArgs "hostbootstrap-demo"`).

#### Validation

- **Done (live).** `sudo demo vm up` launched `hostbootstrap-demo-vm` and `incus config show` reported
  `limits.cpu: "6"`, `limits.memory: 10GiB`, and root device `size: 80GiB`; `incus list` showed it
  `RUNNING` as a `VIRTUAL-MACHINE`. `sudo demo vm down` destroyed it behind the guard. Exercised against
  real incus KVM VMs on a bare-metal host (nested-virt enabled) — the same real-run standard Phases
  5/10/11 follow.

#### Remaining Work

None. (The from-zero bootstrap **inside** the VM — `apt install pipx` → `pipx install hostbootstrap` →
`hostbootstrap run` — is Sprint 13.3.)

### Sprint 13.3: Historical pristine-host bootstrap inside the VM [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (historical `vm pristine-bootstrap` path),
`demo/docker/Dockerfile`, `demo/cabal.project` (build #3)
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Historical objective: run the genuine first-run flow inside the from-zero VM — the headline
demonstration.

#### Deliverables

- Historical deliverable: `demo vm pristine-bootstrap`: `apt install pipx` -> `pipx install` the local hostbootstrap wrapper
  (pushed into the VM) -> `hostbootstrap run`, which ensures the host toolchain prerequisites, builds the
  demo binary **host-native** (**build #2**), and execs it. The execed binary then ensures Docker
  (rebooting the VM if needed) and builds the demo container (**build #3**, the in-container `check-code`
  gate). Asserts a pristine VM reaches a runnable `hostbootstrap-demo` with no prior tooling.

#### Validation

- **Historical validation — build #2 live-validated (post-reorg, post-refactor code).** `sudo demo vm up` launched a
  budget-cordoned (cordon #1) pristine `ubuntu/24.04` VM with network egress; `sudo demo vm
  pristine-bootstrap` ran `apt install pipx` → ghcup + GHC 9.12.4 → `pipx install --force
  /root/hostbootstrap` → `hostbootstrap run`, doing a **cold, warm-store-less host-native build** of the
  full closure — all `hostbootstrap-core` modules plus all demo modules — linking the
  binary and running it (`config schema` printed the reflected `budget`/`podResources`/`kindNode`
  vocabulary). The VM was then destroyed behind the name-prefix guard (`vm down`). Builds #1 (metal) and #2
  (in-VM host-native) of the 3-build sequence are live-validated; build #3 (the project container) is
  live-validated on the host.

#### Remaining Work

None in the historical scope. The former pristine path (`pipx install --force /root/hostbootstrap`) was
live-validated end to end on a real host: `vm up` (cordon #1) -> cold in-VM build -> `config schema` ->
guarded `vm down`. Those appended verbs and `config schema` spelling were later removed; the retained
work now runs through the fixed command tree and project plan. On Linux, the first-run prerequisites were
ensured by the demo verbs and the bootstrapper:
`qemu-system-x86`/`ovmf`, the `incusbr0`<->Docker forwarding rule, pinned GHC 9.12.4, and
`zlib1g-dev`; Apple Silicon now uses Lima for the demo's pristine VM path (Sprint 13.14).

### Sprint 13.4: kind + Harbor on the VM and image push [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`harbor install` / `harbor push`)
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/engineering/in_cluster_registry.md`

#### Objective

Historical objective and delivery record: Harbor and the demo `harbor` verbs below were later removed. The current
replacement is the `registry:2`/MinIO path expressed as project steps under the fixed lifecycle surface.

Bring up kind (cordon #2) and Harbor inside the VM, then push the arch-explicit image tag to the in-VM
registry.

#### Deliverables

- Historical deliverable: inside the VM, core `cluster up` (**cordon #2**: applied `docker update` kind-node cap) + `demo harbor
  install` + `demo harbor push` of the arch-explicit image tag.

#### Validation

- **Historical validation — cordon #2 + the kind lifecycle are live-validated.** Driven by the demo harness inside the VM, core
  `clusterUp` created isolated per-case kind clusters, each carrying the budget-derived cap (observed:
  `docker update --cpus 2 --memory 2147483648 --memory-swap 2147483648 <name>-control-plane`), and
  `clusterDelete` tore them down preserving each case's `.test_data/<case>` path (the test profile's data
  path), leaving **no leftover clusters** (`kind get clusters`
  → "No kind clusters found"). Harbor install + the arch-explicit image push to the in-VM registry remain
  (below).

#### Remaining Work

None for the historical landing. At the time, `demo harbor install` and `demo harbor push` exercised
the registry push/pull mechanism. Those verbs and Harbor implementation are removed; current registry
behavior lives in the `registry:2`/MinIO plan steps, with current evidence and remaining gates owned by
the later active sprints.

### Sprint 13.5: The webservice, SPA, and idiomatic Dockerfile [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Web/{Api,Server,Bridge}.hs` (the `warp`/`wai`/`aeson` service + `purescript-bridge` codegen), `demo/web/` (Halogen SPA + `spago.yaml`), `demo/docker/Dockerfile`
**Docs to update**: `documents/engineering/derived_dockerfile.md`, `documents/languages/purescript.md`

#### Objective

Historical delivery record: the standalone `web bridge`/`web serve` spellings below were later removed.
`writeBridge` now belongs to the build-image step and the web handler is selected by `service run`.

Build the webservice, the `purescript-bridge`-fed Halogen SPA, and the idiomatic `docker/Dockerfile`
that is the reference shape derived projects copy.

#### Deliverables

- A `warp`/`wai` webservice (`Web.Server`) over an `aeson` `BudgetView` (`Web.Api`) whose `fits` field is
  the real `Cordon.fitsBudget` verdict; `Web.Bridge` reflects the API types into PureScript via
  `purescript-bridge` (included in the opportunistic warm-store manifest) — chosen over servant to
  improve cache reuse. A Halogen SPA
  (Overview/Budget/Status tabs); the idiomatic `docker/Dockerfile` (`FROM ${BASE_IMAGE}` -> install binary
  -> `RUN hostbootstrap-demo check-code` -> `web bridge` -> `spago build` + `esbuild` -> tini), the
  reference shape derived projects copy.

#### Validation

- **Web service + bridge done (host).** `demo web bridge` generated `HostBootstrapDemo.Web.Api.purs`
  (argonaut encode/decode for `BudgetView`); `demo web serve` (built `-threaded`, as warp needs)
  returned `GET /api/budget` → `{"cpu":6,…,"fits":true}` (the real `fitsBudget` verdict), the SPA shell at
  `/`, and 404 elsewhere — verified by `curl`. The Halogen SPA + `spago build`/`esbuild` bundle run in the
  project container (build #3, below).

#### Remaining Work

None. The Halogen SPA (`demo/web/`) compiles with `spago build` against the bridge-generated `BudgetView`
and bundles with `esbuild`; build #3 runs that web build in-container. The Dockerfile builds from the
**repo-root context**, so the one ordinary `demo/cabal.project` reaches the L0-direct core source in both
host and container layouts. Matching inherited store artifacts are reused opportunistically. Validated
historically by a real `docker build` + the Playwright e2e (9/9: 3 specs × chromium/firefox/webkit).

### Sprint 13.6: Harness cluster lifecycle + Playwright (in-cluster, via NodePort) [Done]

**Status**: Done
**Implementation**: the historical harness `Seams` (per-case kind cluster up + `finally`-backed
in-process teardown attempt) in `demo/src/HostBootstrapDemo/Commands.hs` (`demoSeams`);
`demo/playwright/` (config + e2e specs across chromium, firefox, webkit)
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/languages/playwright.md`

#### Objective

Historical delivery record: this per-case-cluster harness shape was superseded by reuse of the real
project lifecycle. The current demo still selects the Production plan; active harness/plan work owns the
separate `Harness demoProjectId runId` scope.

Drive isolated per-case clusters through the standardized harness (each torn down on completion), deploy the
webservice **into** the per-case kind cluster via `demo/chart`, and run the Playwright e2e suite from the
already-built project image on the kind network against the in-cluster service via its **NodePort**.

#### Deliverables

- `demoSeams`: each case's `seamSetup` brings up an isolated per-case kind cluster and `seamTeardown`
  attempts to tear it down (`clusterDelete`, preserving `.test_data/<case>`, guarded to the test-name
  prefix) through `runMatrix`'s `finally` on ordinary return or a caught in-process exception. The
  webservice is deployed into the per-case kind cluster via `demo/chart` (the
  pod runs `web serve`); the Playwright runner is the same `hostbootstrap-demo:local` project image on the
  kind network, using the base image's global Playwright install and browser cache (chromium, firefox, webkit) against the in-cluster
  service via its **NodePort** (the e2e target is the kind cluster).
- Per-case seams and harness-driven Playwright run against the in-cluster NodePort; `e2e-tabs` is
  live-validated.

#### Validation

- **Harness cluster lifecycle + cleanup done (live).** `hostbootstrap-demo test all` (rebuilt in-VM) ran all three
  cases; each did `cluster up` (cordon #2 applied) → body → `cluster delete` (`.test_data/<case>` preserved), and
  after the run `kind get clusters` reported **"No kind clusters found"** — the harness leaves no leftover
  clusters in that dated run (`test report: 3/3 passed`). `HarnessSpec` proves the teardown handler runs
  after a caught body failure; it does not prove cleanup after a hard kill or exclusive ownership. The
  per-case bodies are **real assertions**. **`demo test e2e-tabs`
  is live-validated end to end on a real host:** `cluster up` (chart deployed) → `kind load` the project
  image → NodePort readiness → the project image runs `playwright test` from `/workspace/demo/playwright`
  against the in-cluster service via its NodePort, all specs green on every engine (9 runs: 3 specs × chromium/firefox/webkit; tabs render, the Budget tab shows
  `fits: true`, `GET /api/budget` returns `fits:true`) → clean teardown (`1/1 passed`, no leftover cluster,
  source tree untouched).

#### Remaining Work

None. The harness cluster lifecycle, the real per-case seams, and the harness-driven Playwright
(`e2e-tabs`) are live-validated.

### Sprint 13.7: Retire `example/Main.hs` [Done]

**Status**: Done
**Implementation**: `documents/engineering/derived_project_standards.md`, `README.md`,
`legacy-tracking-for-deletion.md`
**Docs to update**: `documents/engineering/derived_project_standards.md`, `legacy-tracking-for-deletion.md`

#### Objective

Make `demo/` the documented worked consumer.

#### Deliverables

- Governed docs and derived-project standards point readers at `demo/` as the worked consumer.

#### Validation

- `cabal build all` succeeds; governed docs point to `demo/` for the worked consumer.

#### Remaining Work

None.

### Sprint 13.8: Wire the demo through the self-reference lift [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/architecture/composition_methodology.md`

#### Objective

Wire the demo through `HostBootstrap.Lift`: nested work runs by re-invoking the binary's own subcommand in
the target context.

#### Deliverables

- Historical delivered shape: `demo` composed metal -> VM -> container on `liftSubcommand`, made build #3
  available in the VM, and lifted the then-current `test all` workflow.
- Current retained result: recursive project-plan handoffs reuse the self-reference lift; the harness is
  not the deployment representation.

#### Validation

- `cabal build` (demo) succeeds; build #3 (the project container) builds `FROM` the base with the
  in-Dockerfile `check-code` gate.
- Historical 2026-06 validation: `demo deploy --dry-run` folded the lifted compute step to
  the selected VM provider followed by `docker run --rm <image> test all`.
- The integrated in-VM run exercises the harness inside the project container in the VM, so kind runs on
  the VM's Docker.

#### Remaining Work

None. The self-reference lift stays valid and is reused by the migrated plan. The demo's plan is no
longer a hand-composed `liftSubcommand` fold wired behind the removed `demo deploy` noun verb; its pure
step fragment is finalized into the opaque `StepPlan` that the core `project` interpreter folds onto
`liftSubcommand` at each frame transition (§ Y).

### Sprint 13.9: Real per-case seams [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`demoSeams`)
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/engineering/testing.md`

**Historical scope.** This entire objective/delivery/validation block records the original per-case
closure. The assertion bodies are retained, but the `cluster up`, `web serve`, `kind load`/Harbor, and
old `demo test` spellings below are not current commands or registry flow. Current execution uses the
fixed `test run`/project-plan surface and registry/MinIO; typed cases and final demo wiring remain open.
See the [deletion ledger](legacy-tracking-for-deletion.md).

#### Objective

Define per-case seams that assert the deployed workload, including Playwright in the `e2e-tabs` case.

#### Deliverables

- The demo ships `demo/chart` (a NodePort Service deploying the webservice **into** the per-case kind
  cluster); `cluster up` installs it (chart-conditional, fail-closed — Phase 5 Sprint 5.4). Per-case
  bodies: `pristine-bootstrap` asserts the live cluster; `web-build` asserts the `spago`/`esbuild` bundle;
  `e2e-tabs` starts the `hostbootstrap-demo:local` project image on the kind network and runs
  `/workspace/demo/playwright` against the in-cluster service via its NodePort, passing iff the spec
  passes.

#### Validation

- The chart is validated offline (`helm lint` / `helm template` render the NodePort Service + the
  Deployment running `hostbootstrap-demo:local web serve`). A failing deploy fails the case; the live
  deploy + NodePort reachability + the Playwright run are exercised on a real host (the project image is
  made available to the cluster via `kind load` or the Harbor pull).
- **Live (real host):** `demo test pristine-bootstrap` ran kind create → cordon → `helm upgrade --install:
  ok` (the chart deployed) → the per-case assertion → clean teardown (`test report: 1/1 passed`, no
  leftover cluster), confirming the fail-closed `cluster up` + chart-conditional deploy + per-case seam +
  teardown on a real host.
- **Live (real host):** `demo test e2e-tabs` is green end to end (`1/1 passed`): `cluster up` (chart
  deployed) → `kind load` the project image → NodePort readiness → the project image runs
  `playwright test` against the in-cluster NodePort (9 runs: 3 specs × chromium/firefox/webkit, all green) → clean teardown.
- **Live (in-container, the production path):** `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock
  --network host hostbootstrap-demo:local test web-build` is green (`1/1 passed`): the harness runs **inside
  the project container** — kind-in-container via the mounted socket → cordon → `helm upgrade --install: ok`
  → `assertWebBundle` confirms the in-image `web/public/app.js` bundle → guarded teardown, no leftover
  cluster. This validates the lifted in-container execution (build #3 running its own harness) and
  `web-build`'s assertion against the bundle build #3 produces.
- **Context-agnostic e2e runner.** `assertE2E` now uses the already-built project image as the Playwright
  runner with all three installed browser engines (chromium, firefox, webkit), so the specs and the base image's browser cache are available inside the same image whether the
  harness is invoked on the host or lifted into the VM project container. The run does not pull
  `mcr.microsoft.com/playwright:*`, run `npm install`, or use `npx` at validation time.

#### Remaining Work

None. The per-case seams (`assertClusterLive` / `assertWebBundle` / `assertE2E`, dispatched on the case id)
are live-validated: `pristine-bootstrap` and `e2e-tabs` on the host, `web-build` in-container; the e2e
runner is context-agnostic because it uses the project image.

### Sprint 13.10: Historical demo-local deploy interpreter [Done]

**Status**: Done
**Implementation**: no retained implementation; the removed demo-local interpreter is recorded in
`legacy-tracking-for-deletion.md`, and its current replacement is
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs` plus
`demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/engineering/composition_patterns.md`

#### Objective

Historical initial objective: reify the demo deploy/lift chain as a pure value behind
`demo deploy [--dry-run]`. This surface was later replaced by the core lifecycle plan and fixed command
tree.

#### Deliverables

- `HostBootstrapDemo.Chain`: the pure chain value + interpreter, wired as `demo deploy`; a pure unit test
  asserting the dry-run plan is a pure function of the chain value.

#### Validation

- `demo deploy --dry-run` prints the planned operation sequence with no side effects (verified); the pure
  `renderPlan` is a function of the chain value.

#### Remaining Work

None. The demo-local interpreter and `demo deploy` verb are removed. The current
`project up --dry-run`/apply paths consume the same `chain cfg` forward list alongside separate
frame-context and teardown callbacks. Phase 16.6 owns replacing those views with topology, forward
execution, and reverse teardown projections of one typed plan.

### Sprint 13.11: Historical F2 — `demo role serve`/`submit` (role over toy bus + object store) [Done]

**Status**: Done
**Implementation**: no retained demo implementation; the removed role surface is recorded in
`legacy-tracking-for-deletion.md`. The definition-only core successor currently lives at
`core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs` and is owned by Phase 14 Sprint 14.6.
**Docs to update**: `documents/engineering/composition_patterns.md`, `documents/architecture/run_models.md`

#### Objective

A stateless role (the `HostDaemon` run-model) over a hand-rolled toy bus + MinIO, dispatching to the
existing `fitsBudget` engine — the in-tree worked instance of the business-logic role shape.

#### Deliverables

- `HostBootstrapDemo.Role`: the role loop, the toy-bus stand-in, the MinIO artifact fetch, dispatch to
  `fitsBudget`; `demo role serve`/`submit`. A harness case asserts submit -> correct `fitsBudget`
  round-trips the bus. Warm-store dependency changes follow the base rebuild/republish rule.

#### Validation

- `demo role submit` then `demo role serve` round-trips the toy bus and returns the correct `fitsBudget`
  verdict against the capacity artifact (a filesystem object-store stand-in) — verified locally. The role
  drives through the L0 `runRole` lifecycle skeleton (Phase 14, `HostBootstrap.RoleLifecycle`).

#### Remaining Work

None.

### Sprint 13.12: Historical single-lift-sequence collapse [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/architecture/composition_methodology.md`

#### Objective

Historical objective: collapse the then-duplicated deployment paths into one lift sequence whose compute
leaf was `test all`. That 2026-06 framing proved VM placement, but was later superseded: the project-owned
lifecycle plan is now the deployment representation, and the harness drives that plan per variant rather
than representing deployment itself.

Historical demo chain (`demo deploy`, removed):

```text
vm ensure               local                                   -- reconciler on metal
vm up                   local                                   -- cordon #1 (the VM is the wall)
vm pristine-bootstrap   local -> VM                             -- build #2 (host-native) + build #3 (project image), IN the VM
test all                inContainer img (inVM vm localContext)  -- the ONLY lifted compute step; folds through the VM provider, then docker run --rm <image> test all
vm down                 local                                   -- guarded teardown (deletes the VM)
```

#### Deliverables

- Historical delivered shape: the demo-local `Chain.hs` sequence lifted `test all` into the VM container.
- `runVmBootstrap` (in `Commands.hs`) also builds **#3** (the project image) **in the VM**, so the lifted
  `test all` finds the image on the VM's Docker — no separate metal-side image path.
- Current replacement: the project lifecycle plan describes bring-up; the harness remains
  context-agnostic and consumes that lifecycle without becoming a second plan.

#### Validation

- Historical 2026-06 validation: `demo deploy --dry-run` printed the sequence (the lifted compute step was `test all`
  under `inContainer (inVM ...)`, folding through the selected VM provider and then `docker run --rm
  hostbootstrap-demo:local test all`).
- **Live (real host).** A staged run brought build #2 **and build #3** up in the VM (image on the VM's
  Docker), then the lifted `test all` passed `3/3` with a concurrent poller showing the kind control-plane
  node on the **VM's** Docker at every sampled second (t=30s…330s) and **none on metal**. The literal `demo
  deploy` apply then ran `vm ensure -> vm up -> pristine[#2+#3] -> lifted test all (3/3) -> vm down`,
  `DEPLOY_EXIT=0`, with no leftover VM and a clean metal host — kind genuinely comes up in the VM via the
  single lift sequence.

#### Remaining Work

None. The historical collapse removed its duplicate of the time. The current carrier is the project
lifecycle plan interpreted by `project up`; the harness drives it per variant. Phase 16.6 owns eliminating
the remaining disagreement risk among independently supplied forward/topology/reverse callbacks.

### Sprint 13.13: Migrate demo runtime configs [Done]

**Status**: Done
**Implementation**: `demo/hostbootstrap-demo.cabal`, `demo/docker/Dockerfile`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/engineering/derived_project_standards.md`, `documents/engineering/derived_dockerfile.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Move the worked demo to the project-local config contract: every copy of the
`hostbootstrap-demo` binary reads a sibling `hostbootstrap-demo.dhall`, and the role/capability
distinction lives inside the file content rather than the filename.

#### Deliverables

- Historical delivered scope, now superseded in its transport details by Sprint 13.15: host default
  config generated by `hostbootstrap-demo project init` as
  `demo/.build/hostbootstrap-demo.dhall`, with Dockerfile path and budget in the project-local config.
- VM-local config projected before the in-VM bootstrap/binary exec.
- Image-build config baked by the Dockerfile at `/usr/local/bin/hostbootstrap-demo.dhall` through
  `hostbootstrap-demo project init --role image-build-container`. The current Sprint 13.15 replacement
  streams the parent-generated VM-project-container config in place over stdin to the sibling path before
  exec; it does not mount the runtime file over the baked path.
- Service/daemon config is currently generated into a ConfigMap during cluster bring-up and mounted
  beside the binary; the pod dispatches the fixed `service run` surface, not the removed `web serve`
  command.

#### Validation

- `hostbootstrap-demo --help`, `project init`, and normal missing-config failure behavior are covered.
- Demo dry-run output shows the same single lift sequence through the project-local config gate.
- Real-run validation repeats the lightweight demo path enough to prove host, VM, container, and
  service contexts are each using their own sibling `hostbootstrap-demo.dhall`.
- Historical sprint-closure validation (date not recorded): `cabal build all` from `demo/` passed;
  `helm template hostbootstrap-demo demo/chart`
  renders the service config mount; `cabal run hostbootstrap-demo -- project init --role host-orchestrator
  --source-root /home/matt/hostbootstrap/demo --dockerfile docker/Dockerfile --cpu 6 --memory 10GiB
  --storage 80GiB --ha-replicas 1 --force` creates the host config; and `cabal run hostbootstrap-demo --
  project up --dry-run` renders the single lift sequence through the gate.

#### Remaining Work

None in this historical config-location sprint. Sprint 13.15 superseded its runtime delivery mechanism
with in-place streaming and the fixed service surface.

### Sprint 13.14: Apple Lima VM path and topology-strict runtime configs [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Lima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `demo/docker/Dockerfile`
**Docs to update**: `README.md`, `documents/architecture/binary_context_config.md`, `documents/architecture/composition_methodology.md`, `documents/operations/demo_runbook.md`, `documents/engineering/lima.md`, `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`, `legacy-tracking-for-deletion.md`

**Historical scope.** This is the original sprint-closure record. The Lima provider selection and
topology-strict runtime checks are retained; references below to removed commands and a config bind-mount
describe the superseded delivery. Current child config is authenticated and streamed in place under the
fixed command tree target. See the [deletion ledger](legacy-tracking-for-deletion.md).

#### Objective

Make the demo's VM provider substrate-aware and make its runtime configs fail fast when the binary is not
running in the topology frame the Dhall declares.

#### Deliverables

- Apple Silicon deploy uses Lima VM commands and lift folding, not Incus VM commands.
- Native Linux deploy keeps the Incus VM path.
- `vm up` fails fast when the host config budget is below the documented full-lifecycle floor
  (6 CPU / 10GiB memory / 80GiB storage), before launching an undersized VM.
- Dockerfile-baked config is image-build-only; lifted runtime containers receive a parent-generated
  VM-project-container config mounted over `/usr/local/bin/hostbootstrap-demo.dhall`.
- Direct `docker run <image> test all` with only the baked image-build config is not authorized, and
  standalone VM-project-container configs fail before cluster creation because the topology lacks a
  VM-orchestrator ancestor.

#### Validation

- Historical phase-close validation (superseded by the fixed command surface and in-place config
  delivery): `cabal build all` from `core/` passes; `cabal build all` from `demo/` passes;
  Apple Silicon `deploy --dry-run` folds to `limactl shell hostbootstrap-demo-vm -- docker run
  --rm ... test all`. The first real Lima lifecycle reached the in-VM Docker ensure; that exposed and
  fixed the missing Linux `docker` group/current-session socket reconciliation in `ensure docker`
  (now unit-tested and verified with `sg docker -c "docker info"` plus a `/var/run/docker.sock` ACL
  check in the disposable Lima VM). The next real Lima lifecycle reached the in-VM project-image build
  and exposed an undersized 20GiB generated host config; `vm up` now rejects budgets below the
  documented 6 CPU / 10GiB / 80GiB full-lifecycle floor before VM launch. A subsequent run exposed an
  unused Lima-managed containerd boot-script hang; `HostBootstrap.Lima.startVMArgs` now starts the VM
  with `--containerd none` and a bounded `--timeout 15m` because Docker is installed by the project
  binary inside the guest. The full Apple Silicon lifecycle now passes: `deploy` ran `vm ensure`, created
  the 6 CPU / 10GiB / 80GiB Lima VM, completed `vm pristine-bootstrap` including build #2 and the
  in-VM project image build, lifted `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock
  --network=host hostbootstrap-demo:local test all`, reported `test report: 3/3 passed` (`pristine-bootstrap`,
  `web-build`, `e2e-tabs`), and destroyed the Lima VM through guarded `vm down`.

The topology-strict split is implemented and covered by `ContextSpec` and `SchemaSpec`:
`ImageBuildContainer` permits build-time `check-code`/config generation only, `context create container`
is parent-derived, and `VMProjectContainer` requires a VM-orchestrator ancestor. Historical phase-close
validation (superseded by the fixed command surface and in-place config delivery):
`cabal test all` from `core/` passes (199 tests); `cabal build all` from `demo/` passes; and
`cabal run hostbootstrap-demo -- deploy --dry-run` renders the six-step chain with the VM-local
`context create container` step and the runtime config/witness mounts on the lifted `docker run`.

#### Remaining Work

None. The full real Apple Silicon Lima lifecycle is validated end to end (2026-06-16): `deploy` ran
`vm ensure` → `vm up` (the 6 CPU / 10 GiB / 80 GiB Lima VM — cordon #1, sized
`--cpus 6 --memory 10 --disk 80`) → `vm pristine-bootstrap` (build #2 host-native in the VM, base
`basecontainer-cpu-arm64` pulled (authenticated via the forwarded host Docker Hub credential — excluded
from Dhall, durable project/image state, and `argv`), build #3 the `hostbootstrap-demo:local` project image with the
in-Dockerfile `check-code` gate of `fourmolu`/`hlint`/`cabal -Werror`) → `context create container` (the
VM-local runtime config) → the single lifted compute step
`limactl shell hostbootstrap-demo-vm -- docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v …runtime-container.dhall:/usr/local/bin/hostbootstrap-demo.dhall:ro -v /run/hostbootstrap:ro --network=host -e HOSTBOOTSTRAP_CURRENT_FRAME=vm-project-container-2 -e HOSTBOOTSTRAP_REGISTRY_AUTH hostbootstrap-demo:local test all`,
where the harness brought up the per-case kind clusters on the **VM's** Docker (cordon #2 applied:
`docker update --cpus 2 --memory 2147483648 --memory-swap 2147483648 hostbootstrap-demo-test-e2e-tabs-control-plane`;
the in-container `kind`/e2e pulls authenticated through the same forwarded credential, consumed into an
ephemeral `DOCKER_CONFIG`) and reported `test report: 3/3 passed` (`pristine-bootstrap`, `web-build`, and
`e2e-tabs` — the e2e Playwright run is green across chromium, firefox, and webkit: 9 runs, 3 specs × 3
engines) → guarded `vm down`. `DEMO_DEPLOY_EXIT=0`, no leftover VM.

### Sprint 13.15: In-place child-config delivery [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (with the generic capability in
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs` + `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
owned by [phase-15](phase-15-binary-context-config.md) Sprint 15.7)
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/binary_context_config.md`, `documents/engineering/config_generation.md`,
`documents/engineering/dhall_topology.md`, `legacy-tracking-for-deletion.md`

#### Objective

Replace the demo's build-then-copy VM config and build-then-mount container config with a projection
**streamed in-place** over the lift's `stdin` channel (development_plan_standards § U, § X), so no host-side
child config file and no config bind-mount is produced.

#### Deliverables

- The VM-config rewrite (`streamVMConfig`): render the context-adjusted full VM config and stream it into the VM,
  written to the VM's sibling `<project>.dhall`; remove `demo/.build/hostbootstrap-demo.vm.dhall` and the
  config `copyFileToDemoVM` (`stageFileEffects`, used by `stageSource`, is retained).
- The container-config rewrite: stream the projection on the container handoff's `stdin` with an entrypoint
  wrapper that writes the sibling before exec; remove `mintContainerConfig`, `vmRuntimeContainerConfigPath`
  (`hostbootstrap-demo.runtime-container.dhall`), and the config `Mount` in `demoDeployImage` (the
  docker-socket and `/run/hostbootstrap` witness mounts are retained).
- Keep the metal-side `/run/hostbootstrap/vm-provider` witness minting and a VM-frame `context-init` anchor
  so `vm-orchestrator-1` stays a real frame in the chain.

#### Validation

- Demo build green; `LiftSpec` / `ChainSpec` fixtures updated (config-delivery on `stdin`, absent from
  `argv`).

#### Remaining Work

None. Closed **2026-07-02**: the demo `-Werror` build and suite pass, and a live Windows/WSL2 `test run all`
reported **`test report: 6/6 passed`** across both message variants (`"Hello, world!"` and
`"Hello, Universe!"`; `pristine-bootstrap`/`web-build`/`e2e-tabs` × 2). Both in-place markers fired
(`streamed parent-derived VM config …` and `context-init: … streamed … in-place on handoff (stdin, no config
bind-mount)`), the container `docker run` carried **no** `-v …hostbootstrap-demo.dhall` mount, **no**
`hostbootstrap-demo.vm.dhall`/`hostbootstrap-demo.runtime-container.dhall` were produced, and
`project destroy` restored `.wslconfig`.

### Sprint 13.16: In-cluster registry — Harbor → single-binary registry:2 [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`deployRegistryAction`, `pushImageAction`),
`demo/kind.yaml`
**Docs to update**: `documents/engineering/in_cluster_registry.md`,
`documents/operations/demo_runbook.md`, `legacy-tracking-for-deletion.md`

#### Objective

Replace the demo's in-cluster registry — the 8-pod Harbor Helm stack (with the `ghcr.io/octohelm/harbor/*`
dual-arch mirror and the trivy scanner) — with a single-binary `registry:2` (CNCF `distribution`), so the
registry step fits the tight substrates (a 16 GiB Windows host) without the memory pressure that made the
Harbor `push-image` stage flake, and so the demo demonstrates the same lightweight registry real consumers
deploy. Harbor is not load-bearing (the web pod runs the `kind load`-ed image; no assertion touches the
registry), so this is confined to the demo's contributed `deploy-registry` / `push-image` steps — core is
untouched.

#### Deliverables

- `deployHarborAction` → `deployRegistryAction`: a single `registry:2` Deployment + NodePort-30500 Service
  applied with `kubectl` (no Helm, no multi-pod chart), the Deployment rollout-waited. `registry:2` is
  natively multi-arch, so no per-component override and no trivy; the registry pod **pulls** `registry:2`
  (`imagePullPolicy: IfNotPresent`) — it is **not** `kind load`-ed, which cannot import a multi-arch image
  (the 2026-07-05 real-run finding).
- `pushImageAction` simplified: keep `kind load`; drop `docker login` / `waitHarborLogin` (the registry is
  anonymous, HTTP, `localhost`-insecure); keep the bounded `pushWithRetry`.
- Rename `deploy-harbor` → `deploy-registry`, `harborEndpoint` → `registryEndpoint`; delete
  `harborImageOverrides` / `harborChartVersion` / `harborImageTag` / `harborAdminPassword`.
- Docs: retire `documents/engineering/harbor.md` → `in_cluster_registry.md` (supersede + repointed links);
  update the demo_runbook and the § J harmony docs; record the retired Harbor surfaces in the ledger.

#### Validation

- Demo `-Werror` build green (the in-container `check-code` gate passes on the `Commands.hs` change,
  including the pod-pull fix); `cabal test` (`DocValidator`) green after the doc rename + link repoints.
  Re-validated 2026-07-05 on the Windows host: core `cabal build all --ghc-options=-Werror` + `cabal test
  all` (**281**), the demo `-Werror` build, and the Python gate (`check_code` + `test_all` 181) are all
  green, and `project up --dry-run` renders the `deploy-registry (registry:2, NodePort 30500)` chain.

#### Remaining Work

None. **Closed (real-run, § C, 2026-07-05):** a live `project up` → `test run all` → `project destroy` on
Windows/WSL2, run **decoupled** as a Windows Scheduled Task, stood up the pod-pulled `registry:2`, pushed the
project image to `localhost:30500`, and reported **`test report: 6/6 passed`** (`REALRUN_EXIT=0`) across both
message variants, then tore down cleanly. The four Harbor entries **and** the removed
`kind load registry:2` pre-load are moved from `## Pending` to `## Removed Surfaces` in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with this validation stamp.

### Sprint 13.17: Substrate accelerator daemon worked example [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Accelerator.hs`,
`demo/src/HostBootstrapDemo/Web/*`, `demo/web/`, `demo/playwright/`,
`demo/test/AcceleratorSpec.hs`
**Docs to update**: `documents/engineering/accelerator_daemon.md`,
`documents/operations/demo_runbook.md`, `documents/architecture/run_models.md`,
`documents/architecture/binary_context_config.md`

#### Objective

Generalize the demo UI and runtime so the same project binary can run as a substrate-specific numerical
accelerator daemon and perform real `Float` addition through the correct native worker.

#### Deliverables

- UI: two `Float` inputs, Add action, async pending/error/result states, and backend/artifact metadata.
- Web server: CBOR WebSocket accelerator-ingress endpoint, daemon registration, request correlation, and
  no in-process addition fallback.
- Daemon: same project binary, daemon context, JIT source generation, idempotent build, worker subprocess
  supervision, CBOR WebSocket loop, and graceful teardown.
- Workers:
  - Swift + Metal on Apple Silicon host.
  - C++ + `clang++` inside the Linux CPU daemon pod.
  - CUDA + `nvcc` inside the Linux GPU daemon pod.
  - CUDA + host `nvcc` on Windows GPU.

#### Validation

- Unit/static tests for CBOR codecs, source generation, build command builders, and no-fallback web
  dispatch.
- Integration tests:
  - Linux CPU: Incus VM, daemon pod from CPU base, C++ worker built with `clang++`, add result returned.
  - Linux GPU: direct `nvkind`, CUDA daemon pod from CUDA base, `nvcc` worker built and executed.
  - Apple Silicon: host daemon, Apple Metal ensure, Swift/Metal worker built and executed.
  - Windows GPU: host daemon, hardened CudaWin ensure, CUDA worker built and executed.
- Browser e2e: fill the add UI, click Add, wait for the asynchronous result, assert the sum and returned
  backend/artifact metadata.

#### Remaining Work

Implementation and static validation are complete:

- Mandatory Web/Accelerator parameter records survive child projection; leaf context structurally
  selects the typed role through the finalized registry, and both chart and host-daemon argv omit a
  positional variant.
- The web server runs linked configured public and private listeners (defaults 8080/8081). Separate Service
  target ports and the local-only `127.0.0.1:30081` host mapping keep the daemon route private; the public
  listener cannot upgrade it. Listener failures propagate, a second concurrent request fails 503, and the
  single-daemon contract constrains HA replicas to one.
- The daemon uses persistent, idempotently built workers and `Float32` semantics across CBOR and native
  processes. Static/guarded coverage includes `2^24 + 1 -> 2^24`; the historical RTX 3090 real-worker gate
  built CUDA with `nvcc -ccbin <msvc>` and returned `Right 3.75`.
- `HostBootstrapDemo.Commands` dynamically generates/applies both service ConfigMaps before workload
  deployment and hashes the exact mounted bytes for rollout. Linux CPU/GPU daemon Deployments rollout-wait,
  dial the distinct configured accelerator `ClusterIP`, and request one GPU on the GPU lane. `Recreate`
  plus connection-owned readiness prevents overlapping/unconnected peers. Apple/Windows run the project
  daemon from a host-native build with symmetric pid/owner and absolute executable/argv identity, shutdown,
  and a bounded pristine-install/build/connect readiness gate.
- The Playwright Add spec asserts the daemon-returned sum, backend, and artifact hash. The later
  post-ensure direct-cluster/VM checks and `SafetyRefusal` are fail-closed, but the initial cooperative
  precondition currently maps an unavailable provider/Docker probe tool to “not running”; it may mutate
  setup before the later refusal and holds none of the § EE ownership clauses. Sprint 10.9 owns that fail-closed
  reservation/receipt replacement and verified teardown.

The accelerator implementation has dated static evidence, but current work is not limited to live closure:
Sprint 13.18 also owns the typed Production plan/TestComponent, freshly pulled rolling base, and
registry/MinIO metadata/provenance repair.

**Native Linux GPU real-run closure (2026-07-28).** The direct-`nvkind` lane reported **`10/10 passed`**
across both variants; the full evidence, including the `nvcc` discovery defect it exposed and fixed, is
recorded once with
[Sprint 5.5](phase-5-cluster-lifecycle-and-resource-cordoning.md). This closes only that lane.

The daemon Deployment rolled out, dialed the accelerator `ClusterIP`, and the Playwright `e2e-tabs` case
asserted the daemon-returned sum on both variants. The native **Apple** host-daemon lane and the native
Linux **CPU** in-cluster lane remain open.

### Sprint 13.18: Production-plan demo wiring and artifact provenance [Blocked]

**Status**: Blocked
**Blocked by**: Sprints 5.7, 10.9, 13.20, 14.6, 15.9, 16.6, 17.4, and 20.5
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `demo/app/Main.hs`, `demo/docker/Dockerfile`,
`demo/kind*.yaml`, `demo/nvkind-in-cluster.yaml`
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/engineering/testing.md`, `documents/engineering/build_release.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Make the worked demo exercise a typed production plan without hard-coded harness variants or stale
registry/object-store metadata, and consume a freshly pulled published rolling base.

#### Deliverables

- Define one scope-polymorphic demo plan **definition/builder**, then instantiate it separately as
  `ProjectPlan (Production demoProjectId) specDigest planId configId DemoConfig` for `project up` and
  `ProjectPlan (Harness demoProjectId runId) specDigest planId configId DemoConfig` for the threaded
  `TestComponent`. The two
  instances share plan shape, not indexed values or journals. The test component receives only opaque
  `HarnessAuthority demoProjectId runId` and cannot construct or consume the Production instance.
- Pull the selected published rolling base before each derived-image build, verify substrate
  flavor/architecture selection, and prevent a same-named local image from substituting for the
  publication. A resolved digest may bind that invocation without becoming a permanent consumer lock.
- Reconcile the current MinIO-backed registry path across step names, manifests, case metadata, and
  assertions; remove stale Harbor/appended-verb metadata rather than preserving it as compatibility text.
- Make durable-registry assertions prove the MinIO/PVC state actually claimed, with explicit ownership
  and cleanup behavior.
- Derive a non-empty complete workload resource set—including web, MinIO, registry, accelerator, and
  replica counts—from the same scoped plan values that render Kubernetes requests/limits. Reject an
  over-budget plan before its first mutation permit so the visible budget verdict and applied manifests
  cannot diverge.
- Default registry/web/MinIO host mappings to loopback unless the scoped plan carries explicit
  authenticated exposure authority. Replace anonymous/source-hard-coded registry/MinIO access with
  project/run-scoped secret capabilities delivered only to the matching workload identities.
- Consume Phase 19 typed case/config values and Phase 20 config-driven variant generation; this sprint
  owns demo wiring, not those generic types.

#### Validation

- Golden/structural tests prove the production chain and test component share one step plan and contain no
  stale Harbor identifiers.
- Derived-image tests prove pull-before-build, digest use, and correct CPU/CUDA/native architecture
  selection.
- Structural and negative tests prove the complete workload set drives both the budget gate and
  manifests, over-budget plans mint no prepared-operation authorization, unauthenticated mappings do not bind
  non-loopback, and Production/Harness secret capabilities cannot cross scopes.
- The demo matrix validates MinIO readiness, registry metadata/provenance, persistence, browser behavior,
  and cleanup on at least one accepted representative native lane. That integration result does not
  close the separately owned Apple/Linux accelerator real-run lanes.

#### Remaining Work

Blocked on the named type, ownership, lifecycle, command, base, service, config-driven-demo, and static
test prerequisites. After they close, introduce and thread the production plan/test component, enforce
published-base pull/digest consumption, reconcile MinIO/registry metadata, and rerun the demo gates.
Sprint 13.17 and the accelerator lanes in Sprints 15.8, 16.5, and 18.5 remain independently Active; this
sprint's representative-lane integration does not close them by proxy.

Dated native Linux GPU evidence (2026-07-25): the direct lane accepted the canonical absolute host
`.data` bind, created and cordoned the nvkind nodes, advertised `nvidia.com/gpu`, and brought MinIO plus
the in-cluster registry Ready. The subsequent `docker push` uploaded every project-image layer but failed
when the registry finalized the manifest (`error from registry: unknown error`) in both variants. This is
the current concrete registry/MinIO repair input; it is not accepted matrix or durability evidence.

### Sprint 13.19: Threaded static demo test component [Done]

**Status**: Done
**Implementation**: `demo/hostbootstrap-demo.cabal`,
`demo/test/Spec.hs`
**Docs to update**: `README.md`, `documents/engineering/testing.md`,
`documents/operations/demo_runbook.md`, `legacy-tracking-for-deletion.md`

#### Objective

Restore the canonical static demo gate by giving `hostbootstrap-demo-test` the threaded RTS contract its
Warp server tests require.

#### Deliverables

- Apply the same threaded runtime requirement used by the demo executable to the test component without
  weakening or skipping the Warp tests.
- Keep `cabal test all` as the one static demo workspace command; do not replace the failing component
  with a narrower ad hoc invocation.
- Remove the known-failure limitation only after the canonical command passes.

#### Validation

- From `demo/`, `cabal test all --ghc-options=-Werror` passes with the Warp server tests enabled.
- A negative build/test fixture or Cabal assertion prevents removal of the threaded option while those
  tests depend on the GHC timer manager.

**Passed 2026-07-25.** The canonical command completed with all **101 demo tests** and the embedded
**379-test core suite** green under `-Werror`; `WebServerSpec` remained enabled, including its real
listener and WebSocket cases. The new component-contract case reads the test stanza and requires
`-threaded -rtsopts "-with-rtsopts=-N"`. Pinned Fourmolu and HLint are clean on the changed test entry
module.

#### Remaining Work

None.

### Sprint 13.20: Reachability-safe registry route and persistence proof [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/test/RegistrySpec.hs`,
`demo/test/HarnessSpec.hs`
**Docs to update**: `README.md`, `documents/engineering/in_cluster_registry.md`,
`documents/operations/demo_runbook.md`, `legacy-tracking-for-deletion.md`

#### Objective

Replace the demo's independently rendered registry exposure, cluster-only MinIO endpoint, and implicit
redirect default with one reachability-safe finalized registry plan.

#### Deliverables

- Construct the host-client→NodePort-registry→cluster-only-MinIO topology through Sprint 14.7's opaque
  API; proxy delivery must be selected by construction and render
  `storage.redirect.disable: true`.
- Require the exact `ReadyBlobRoute` before project-image push; Deployment Ready and `/v2/` alone must
  not authorize the operation.
- Remove raw registry/store endpoint assembly and stale tests that treat an initial empty-registry push
  as persistence evidence.

#### Validation

- Golden tests prove the demo manifests derive exposure, MinIO endpoint, and proxy configuration from
  one plan and contain no independently selected redirect flag.
- A negative live fixture returns an out-of-scope `307` and proves push admission refuses.
- On at least one supported native lane, initial push, repeated push, pull, tag lookup, registry-pod
  recreation, and post-recreation pull all pass; client-visible responses contain no cluster-only MinIO
  location.

#### Remaining Work

None. Completed 2026-07-30.

**One plan, and the redirect is output.** `demoRegistryPlan` is the demo's single finalized registry
plan, built through Sprint 14.7's API from a host-local client, the loopback NodePort exposure, and the
cluster-only MinIO endpoint. That topology admits **no** `Reachability` constructor, so
`hostServedRegistryPlan` can only produce `ProxyBlobs` — proxy delivery is selected by construction rather
than by policy. `registryConfigYaml` renders its `storage.redirect` stanza from
`renderStorageRedirect`, and `minioClusterEndpoint`, `registryEndpoint`, and the chart's NodePort are all
projections of the same plan, so the rendered configuration and the dialled endpoint cannot disagree.

The defect this replaces was concrete: the demo previously emitted a `storage` stanza with **no**
`redirect` key at all, leaving Distribution's default in force. It survived every prior run — including
both `10/10`s — because `push` and `tags/list` never fetch blob bytes from the host client.

**Live negative fixture (2026-07-30).** Against a local MinIO-backed `registry:2` running the demo's
rendered config with the redirect stanza removed — i.e. exactly the pre-fix configuration — a blob `HEAD`
answers:

```text
307  Location: http://<minio>:9000/registry/docker/registry/v2/blobs/sha256/ca/…?X-Amz-Algorithm=…
```

With the plan-rendered `redirect: disable: true`, the same request answers `200` with **no** `Location`.
`settleBlobRoute` refuses the former against a proxying plan, so push admission refuses exactly the
topology the sprint names.

**`/v2/` no longer authorizes the push.** `push-image` now seeds a canary blob through the registry API
and settles a real blob `HEAD` against the plan before tagging or pushing; `pushImageBlob` takes the
`ReadyBlobRoute`, so a push without that proof does not type-check. Three API details were established
empirically against a MinIO-backed `registry:2` rather than assumed, and each is recorded at its call
site because each produced a silent or misleading failure first:

- `POST …?digest=` answers `202` and stores **nothing** on `registry:2`, so a fail-fast check cannot tell
  it from success and the later `HEAD` is a genuine `404`;
- putting the bytes in the final `PUT` works on a filesystem-backed registry but fails on the S3 driver
  with `InvalidRequest: You must specify at least one part`, so the `PATCH` step is mandatory;
- curl's `-d` sends form encoding and the registry answers `bad Content-Type`; the header is written
  without a space after the colon (which HTTP permits) so every argument stays space-free for the
  host→guest quoting path (§ CC).

The `Location` is parsed in Haskell — handling absolute and relative forms — rather than by a guest shell
pipeline, and re-seeding the same canary is idempotent.

**Real-run closure (2026-07-30).** On the native Linux CPU lane, `hostbootstrap-demo test run all`
reported **`10/10 passed`** across both variants with
`push-image: kind-loaded hostbootstrap-demo:local and pushed
localhost:30500/library/hostbootstrap-demo:demo`. That line is reachable only through a settled
`ReadyBlobRoute`, because `pushImageBlob` consumes it. Initial push, repeated push (the second variant
re-pushes into the same MinIO-backed store), tag lookup, registry-pod recreation, and post-recreation
lookup are all covered by the passing `registry-persistence` case on both variants, and no client-visible
response carried a cluster-only MinIO location.

Static gates (2026-07-30): core **744** and demo **110** under `-Werror`; `fourmolu --mode check app src`
clean; the in-container `check-code` gate (`fourmolu`, `hlint`, `cabal -Werror`) passed inside the pulled
published base.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/durable_state.md` - what `.data` is, the removal-set guarantee's exact scope,
  the implemented host-root/provider-share/container/Kind/pod carry, and the still-open
  write→destroy→up→read-back and ownership proof.
- `documents/architecture/network_reachability.md` - the reachability and delivery doctrine consumed
  by the demo registry plan.

**Engineering docs to create/update:**
- `documents/engineering/derived_dockerfile.md` - the idiomatic derived Dockerfile (in-Dockerfile
  `check-code` gate; the `purescript-bridge` -> `spago` -> `esbuild` web build; the build-stage ordering).
- `documents/engineering/accelerator_daemon.md` - substrate-specific daemon/JIT worker contract and tests.

**Operations docs to create/update:**
- `documents/operations/demo_runbook.md` - current `project`/`test`/`service`/`context` flow, generated
  per-frame configs, the 3-builds explanation, durable carry, and explicit open gates; removed `deploy`,
  `role`, and other appended verbs appear only as dated history or in the deletion ledger.

**Cross-references to add:**
- `documents/engineering/in_cluster_registry.md`, `documents/languages/purescript.md`,
  `documents/languages/playwright.md`, and `documents/engineering/derived_project_standards.md` reference
  the demo.
- `system-components.md` adds the `hostbootstrap-demo` worked-consumer subsection.
- `legacy-tracking-for-deletion.md` records obsolete compatibility surfaces.
