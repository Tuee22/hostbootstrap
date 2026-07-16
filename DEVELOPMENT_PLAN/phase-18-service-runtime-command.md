# Phase 18: Service Runtime Command

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-16-project-lifecycle-command.md](phase-16-project-lifecycle-command.md)

> **Purpose**: Add the third DSL-driven core command — `service` — that runs a project's long-running
> roles (the `HostDaemon`/service run-model) through a fixed `service init|schema|run` surface, a project-
> contributed service ADT and internal handler registry, leaf-frame fail-fast gating, and dynamically
> rendered ConfigMap-delivered service config.

## Phase Status

**Status**: Active

`service` is **new core scope** — there had never been a `service` command; the demo's long-running web
workload previously ran through the load-bearing `web serve` verb. The generic command now reaches every
project role through the fixed surface (development_plan_standards § AA), not a per-project verb.

The current implementation is built and statically validated (364 core tests and 87 demo tests):

- `HostBootstrap.Service` ships the possibly empty `ServiceRegistry` of internal handler keys and actions.
  `HostBootstrap.CLI` threads it through `ProjectSpec` with `withServices`, rejects duplicate keys, and
  independently carries the config-specific selector with `withServiceConfig` / `psServiceVariant`.
- `HostBootstrap.Command.serviceCommandGroup` surfaces the fixed `service init|schema|run` tree. There is
  no `service down` and no positional variant argument: `service run` gates as
  `Context.ServiceCommand`, asks the effective project config for its selected variant, and dispatches that
  internal key through the registry.
- The demo owns the real Dhall service model:
  `ServiceType = < Web : WebServiceConfig | Accelerator : AcceleratorServiceConfig >`, stored as the
  mandatory `service : Optional ServiceType` project-config field. `Web` carries distinct public and
  accelerator ports; `Accelerator` carries its request timeout. `configuredServiceVariant` maps those
  payload-bearing constructors to the internal registry keys and validates their placement.
- `demo/src/HostBootstrapDemo/Commands.hs` renders each parent-derived service config and its ConfigMap
  manifest at deployment time. Helm receives the current frame, exact config-byte hash, and placement;
  the hash annotation rolls the pod whenever the mounted bytes change. There is no static chart ConfigMap.
- The web role binds linked public and private listeners: public HTTP uses its configured port (default
  8080) behind NodePort 30080;
  accelerator WebSocket traffic uses the configured distinct port (default 8081) through a cluster-only
  Service or a local-only NodePort 30081.
  Registration is unavailable on the public listener, and the private listener rejects browser-originated
  registration. A process-local accelerator hub requires exactly one web replica and preserves an active
  request when a concurrent request receives the single-flight 503 response. `Recreate` rollouts prevent
  temporary peer overlap, and daemon connection readiness is explicit for both pod and host placement.
- The accelerator daemon keeps a serialized, persistent newline-delimited worker session, restarts it once
  after a worker failure, and clears it on request timeout. Worker arithmetic is semantically `Float32`
  across Haskell, Swift, C++, and CUDA; CBOR float64 is only the transport carrier. CUDA failures surface
  as failures rather than fabricated results.

Historical live evidence remains valid for the behavior it exercised: on 2026-06-19 the then-current
three-argument web entrypoint (`service run web`) served HTTP 200 at `localhost:30080` on the 16 GiB
Apple-Silicon host ([phase-13](phase-13-hostbootstrap-demo.md)) while reading its ConfigMap-mounted config.
That evidence predates the current config-selected two-argument entrypoint and the accelerator matrix; it
is not a live validation claim for the current four-lane accelerator gate.

**Reopened 2026-07-09 for the accelerator daemon runtime.** The protocol, concrete socket path, dynamic
configuration, two-listener web boundary, and persistent real-worker supervision are implemented and
covered by static/local tests. The cross-substrate live gates below remain open, so the phase stays Active.

## Remaining Work

**Accelerator daemon live-runtime closure — open.** Static and local validation, including the browser
workflow specification and guarded real-worker cases, is implemented. Completion still requires:

- real socket integration through the in-cluster `ClusterIP` and host-daemon local-only `NodePort` paths;
- the browser Add workflow against those live deployments, proving the result and metadata came from the
  selected JIT-built worker rather than from the web process; and
- the four required substrate/placement lanes: Apple Silicon host daemon, Linux CPU in-cluster daemon,
  Linux GPU direct nvkind/in-cluster daemon, and Windows GPU host daemon. On each lane the harness runs
  four cases across two message variants, so the required result is `8/8`; no current live `8/8` result
  is claimed here.

## Phase Objective

Provide a generic, fixed `service` command on the core tree so every project binary runs its long-running
roles uniformly: `service init` / `service schema` / `service run`. The effective project config selects a
project-owned service ADT value; a project-supplied projection maps it to an internal handler key. The
command is gated to a service/daemon frame, and deployment config is delivered by a dynamically rendered
ConfigMap that overrides the image's baked container `<project>.dhall`. There is no `service down`: the
leaf process may run in a Kubernetes pod or as a host daemon, and its enclosing controller or project
lifecycle owns teardown (§ O, § Y).

For the accelerator reopening, extend that surface with a daemon variant that connects to the web service
instead of serving HTTP itself. The daemon is still a leaf role: it performs no cluster bring-up and no
project lifecycle work.

## Sprints

### Sprint 18.1: The `service init|schema|run` command surface [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs` (`serviceCommandGroup`), `core/hostbootstrap-core/src/HostBootstrap/Service.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Docs to update**: `documents/architecture/run_models.md`, `README.md`

#### Objective

Put `service` on the fixed core tree (`project` / `test` / `service` / `context` / `check-code`) so every
project binary inherits it.

#### Deliverables

- `service init` writes a service-configured `<project>.dhall` from passed parameters (forwarded from a
  parent where applicable, § X); `service schema` prints the service config schema (reflected from the
  decoder, § Q); `service run` runs the role selected by the effective config. No `service down`.
- `service run` is a **leaf-frame runtime command, never an orchestrator**: it assumes it is already placed
  in its frame (a k8s pod or host daemon) and runs the role; it brings up no VM or cluster.

#### Validation

- The core CLI spec asserts `service` is present on every binary, `service run` fails fast when the config
  is not service-configured, and there is no `service down` subcommand.

#### Remaining Work

None. `serviceCommandGroup` surfaces `service init|schema|run` (no `service down`); `service run` gates as
`Context.ServiceCommand` and is a leaf-frame command, never an orchestrator. `CLISpec` covers the
leaf-frame refusal and `service schema`. The 2026-06-19 demo run is historical live evidence for the
pre-selector web form of the command ([phase-13](phase-13-hostbootstrap-demo.md)); current live matrix
closure is tracked by Sprint 18.5.

### Sprint 18.2: The `ServiceType` ADT and service-handler registry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`, `core/hostbootstrap-core/src/HostBootstrap/CLI.hs` (`withServices`, `withServiceConfig`), `core/hostbootstrap-core/test/CLISpec.hs`, `demo/src/HostBootstrapDemo/Config.hs`, `demo/app/Main.hs`
**Docs to update**: `documents/architecture/library_hierarchy.md`, `system-components.md`

#### Objective

Let a binary define **more than one** payload-bearing service type and have `service run` dispatch the
variant selected by its effective config.

#### Deliverables

- A project contributes a possibly empty internal handler **registry** through `withServices` and a
  config-specific selector through `withServiceConfig` / `psServiceVariant`. The selector validates the
  project-owned Dhall ADT and maps the selected constructor to a registry key; the registry itself is not
  the Dhall ADT.
- The demo's real model is
  `ServiceType = < Web : WebServiceConfig | Accelerator : AcceleratorServiceConfig >`. The Web payload
  carries `publicPort` and `acceleratorPort`; the Accelerator payload carries `requestTimeoutSeconds`.
  `ProjectConfig.service` is a mandatory field whose value is optional so non-service frames remain
  representable.
- The registry may be empty — the fixed surface is unchanged and `service run` fails fast when no service
  is selected or no handler matches the selected key, so not every project ships a service.

#### Validation

- The CLI and demo specs assert config-selected dispatch over multiple variants, no positional variant
  argument, an empty registry that still exposes `service` but fails fast, payload/placement validation,
  and an unknown selected key exiting non-zero.

#### Remaining Work

None. The distinct registry and config-selector seams, the real payload-bearing demo ADT, duplicate-key
rejection, placement validation, and config-selected dispatch are built and covered by the current static
suite. Sprint 18.5 owns live validation of both constructors and placements.

### Sprint 18.3: Leaf-frame gating and ConfigMap-delivered config [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `demo/src/HostBootstrapDemo/Commands.hs`, `demo/chart/templates/deployment.yaml`
**Docs to update**: `documents/architecture/binary_context_config.md`, `documents/engineering/cluster_lifecycle.md`

#### Objective

Gate `service run` to a service-role frame and deliver its config the binary-context way.

#### Deliverables

- `service run` fails fast unless the effective `<project>.dhall` declares a **service role** and contains
  a valid service value for that placement (§ X). A single config may declare project *and* service roles;
  `service run` checks the service capability and uses the configured selector.
- `project up`'s `deploy-chart` step deploys the pod whose entrypoint is `service run`; the pod's config
  arrives as a **dynamically rendered ConfigMap overriding the image's baked container
  `<project>.dhall`** (§ X). The deployer hashes the exact mounted bytes into the pod template annotation.
  `project up` *deploys* the service; `service run` *is* the service.

#### Validation

- A non-service-role config is refused; manifest tests prove that the chart pod runs `service run`, reads
  the generated ConfigMap, and rolls when the exact config bytes change. The earlier web-only delivery
  path was exercised in the historical demo run.

#### Remaining Work

None for implementation. `service run` refuses a non-service-role config; the deployer renders the actual
parent-derived service config and ConfigMap, applies it, and passes Helm only the current frame,
config-byte hash, and placement. The chart args are `service run` with no positional variant. The
2026-06-19 web run remains historical evidence for mounted-config behavior; current live closure belongs
to Sprint 18.5.

### Sprint 18.4: Demo web role on config-selected `service run` [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`demoServices`), `demo/app/Main.hs` (`withServices`), `demo/chart/templates/deployment.yaml`, `demo/docker/Dockerfile`
**Docs to update**: `documents/operations/demo_runbook.md`, `README.md`

#### Objective

Run the demo's long-running web workload through the generic command and select its payload-bearing `Web`
constructor from the effective project config.

#### Deliverables

- `web serve` → `service run`, with `withServiceConfig` selecting `Web` and `withServices` resolving the
  internal `web` handler key; `web bridge` → the build-image chain step. The demo chart pod's entrypoint is
  `service run`, and its generated config selects the Web payload.

#### Validation

- Static manifest/CLI tests cover the current config-selected path. Historical live evidence proves the
  migrated web handler served HTTP 200 on the NodePort before the selector replaced the positional key
  ([phase-13](phase-13-hostbootstrap-demo.md)).

#### Remaining Work

None. The `web` verb is removed; `runVmBootstrap` generates the PureScript bridge before image build;
`demo/app/Main.hs` installs both the handler registry and config selector; and the chart args are
`["service", "run"]`. The current path is statically validated. The 2026-06-19 HTTP 200 run is retained as
explicitly historical evidence, not as current matrix closure.

### Sprint 18.5: Accelerator daemon runtime over CBOR WebSocket [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `demo/src/HostBootstrapDemo/Web/Server.hs`,
`demo/src/HostBootstrapDemo/Accelerator/Protocol.hs`,
`demo/src/HostBootstrapDemo/Accelerator/Daemon.hs`, `demo/test/WebServerSpec.hs`,
`demo/test/AcceleratorRuntimeSpec.hs`
**Docs to update**: `documents/architecture/run_models.md`,
`documents/architecture/binary_context_config.md`, `documents/engineering/accelerator_daemon.md`

#### Objective

Add the accelerator daemon as a config-selected long-running service/daemon role that connects to the
web server's private listener over CBOR WebSocket and forwards add requests to a persistent JIT-built
worker session.

#### Deliverables

- A payload-bearing `Accelerator` config value projected to the daemon handler through the fixed service
  registry, with `requestTimeoutSeconds` supplied by config rather than a positional CLI argument.
- CBOR request/result/failure codecs with request-id correlation.
- Separate linked web listeners: public application HTTP and private accelerator registration, with
  distinct ports, Origin rejection on the private path, and no registration route on the public path.
- WebSocket client loop with reconnect, configured request timeout, graceful shutdown, and backend/artifact
  metadata in replies. Idle socket lifetime is independent of the per-request worker timeout.
- Serialized persistent worker sessions used after Phase 13's substrate-specific JIT build, with
  newline-delimited request/reply framing, one restart after worker failure, timeout cleanup, and
  end-to-end `Float32` arithmetic semantics.
- Gate config-selected `service run` to daemon/service contexts only.

#### Validation

- Unit tests for CBOR codec round trips, invalid payload rejection, request correlation, single-flight
  contention, listener isolation, worker-session reuse/restart/timeout, precision, and no in-process web
  fallback.
- Integration tests for in-cluster daemon connection by `ClusterIP` and host daemon connection by
  local-only `NodePort`.
- Browser e2e add test asserts the sum and daemon-returned backend/artifact metadata.

#### Remaining Work

The implementation and current static/local contract are complete and green (364 core tests, 87 demo
tests). The effective config selects `Accelerator`; the existing `Context.ServiceCommand` gate rejects
project-lifecycle authority; the dynamic manifest supplies the placement-specific connection target and
timeout; and deterministic CBOR codecs preserve request IDs, metadata, and failures. The web process owns
a single-flight hub on its private listener but never computes the sum itself. Public and private ports are
separate, the private path rejects Origin-bearing clients, linked listener failures terminate the role,
and process-local hub state is guarded by an exact-one-replica invariant.

The daemon keeps one serialized worker process per session, communicates over newline-delimited standard
input/output, reuses a healthy worker, retries once after a worker crash or protocol failure, and clears
the worker on timeout or shutdown. The configured request timeout applies to worker requests, not idle
WebSocket connectivity. Haskell, Swift, C++, and CUDA workers implement `Float32` semantics; CBOR's
float64 value is only the protocol carrier, and CUDA/runtime errors are returned as failures. Static tests
cover precision, persistence, recovery, listener isolation, contention, generated manifests, and the
guarded real-worker/browser workflows.

Historical local-worker evidence is retained: on 2026-07-10 the guarded `AcceleratorRuntimeSpec` built
the CUDA worker on the RTX 3090 with `nvcc -ccbin <msvc>` and returned `Right 3.75` (the then-current gate
reported 46 demo tests). That proves the native worker path used in that run; it is not a live daemon
socket, lifecycle, or browser-matrix result.

The phase remains Active for real socket and browser closure across the in-cluster `ClusterIP` and
host-daemon local-only `NodePort` routes, including the durable Windows GPU run, native Apple Silicon
host-daemon lane, and Linux CPU/GPU in-cluster lanes. No new live `8/8` result is claimed.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/run_models.md` - the `HostDaemon`/service run-model reached via `service run`, the
  project-owned `ServiceType` ADT, config selector, and distinct service-handler registry.
- `documents/architecture/binary_context_config.md` - the service-role context and dynamically generated
  ConfigMap-overrides-baked-`<project>.dhall` delivery.

**Engineering docs to create/update:**
- `documents/engineering/cluster_lifecycle.md` - the chart pod entrypoint `service run`, exact-byte config
  hashing, and placement-specific service delivery.
- `documents/engineering/accelerator_daemon.md` - CBOR protocol seam, concrete WebSocket transport, and
  persistent worker supervision.

**Cross-references to add:**
- `README.md` CLI Surface lists `service`; `system-components.md` adds the `service` command and the
  service-handler registry; `00-overview.md` names phase-18 in the cross-phase narrative.
