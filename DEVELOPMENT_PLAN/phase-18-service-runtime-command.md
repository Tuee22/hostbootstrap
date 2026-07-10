# Phase 18: Service Runtime Command

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-16-project-lifecycle-command.md](phase-16-project-lifecycle-command.md)

> **Purpose**: Add the third DSL-driven core command — `service` — that runs a project's long-running
> roles (the `HostDaemon`/service run-model) through a fixed `service init|schema|run` surface, a project-
> contributed `ServiceType` ADT + service-handler registry, leaf-frame fail-fast gating, and ConfigMap-
> delivered service config.

## Phase Status

**Status**: Active

**Reopened from Blocked then closed (2026-06-19):** the fixed command surface (phase-16) and the
binary-context contract (phase-15) it depended on are in place, the `service` command landed in code, and
the demo's `web serve` → `service run web` migration is **real-run-validated** — the live demo's web pod
runs `args: ["service","run","web"]` and serves **HTTP 200** at `localhost:30080` on the 16 GiB
Apple-Silicon host ([phase-13](phase-13-hostbootstrap-demo.md)), reading its ConfigMap-delivered
cluster-service config. No remaining work.

Forward-pointer: the demo's worked example has the `web` service handler (`serveWeb`) read its config and
render the demo's `message` field through `BudgetView.message` to the SPA. That config-driven message
plumbing is owned by
[phase-20-config-driven-demo-worked-example.md](phase-20-config-driven-demo-worked-example.md); the fixed
`service init|schema|run` surface this phase shipped is unchanged.

`service` is **new core scope** — there had never been a `service` command; the demo's long-running web
workload ran through the load-bearing `web serve` verb. This phase adds the generic command so a
project's long-running roles are reached through the fixed surface (development_plan_standards § AA), not a
per-project verb.

The code is built and code-check-validated (`cabal test all` green, `cabal build all --ghc-options=-Werror`
green, fourmolu/hlint clean on the demo):

- `HostBootstrap.Service` ships the `ServiceHandler` / `ServiceRegistry` extension stream (variant name +
  role action), `lookupServiceHandler`, `serviceVariantNames`, and `duplicateServiceVariants`; the registry
  may be empty.
- `HostBootstrap.Command.serviceCommandGroup` surfaces the fixed `service init|schema|run` on the core tree
  (`coreCommandNames` = `context` / `project` / `test` / `service` / `check-code`); there is **no
  `service down`** and no hidden command surface. `service run <variant>` gates as `Context.ServiceCommand`
  (the leaf-frame service-role gate) then dispatches on the variant; an unknown variant or empty registry
  fails fast.
- `HostBootstrap.CLI` threads the registry through `ProjectSpec` (`withServices`) alongside the other
  extension streams; the entrypoint rejects duplicate service variants.
- The demo registers the `web` variant (`demoServices`, `serveWeb`) and its chart pod's entrypoint is
  `service run web` (the former `web serve`); `CLISpec` covers `service schema`, the leaf-frame refusal, and
  the duplicate-variant rejection.

Real-run-validated (§ C): the demo's live `web` pod serves HTTP 200 via `service run web` on the NodePort
(the demo run, [phase-13](phase-13-hostbootstrap-demo.md)).

**Reopened 2026-07-09 for the accelerator daemon runtime.** The same fixed `service run`/handler registry
surface runs the accelerator daemon role in host and in-cluster placements. The protocol/runtime seam and
concrete local WebSocket path are implemented and unit-tested; real host/in-cluster integration runs, real
worker runs, and browser e2e closure remain open.

## Remaining Work

**Accelerator daemon runtime — open.**

- Done statically: `service run accelerator` is registered through the demo service-handler registry and
  goes through the existing `Context.ServiceCommand` gate, so host/project lifecycle authority is rejected
  before the handler can run.
- Done statically: `HostBootstrapDemo.Accelerator.Protocol` provides deterministic CBOR request/result/
  failure codecs and request-id correlation.
- Done statically: `HostBootstrapDemo.Accelerator.Daemon` provides the worker-supervision seam and a
  transport-injected daemon client loop covering reconnect, request timeout, graceful shutdown, backend
  metadata, and artifact hash propagation.
- Done locally: the concrete WebSocket daemon transport is plugged in, `/api/accelerator/daemon` registers
  the daemon connection, and `/api/accelerator/add` dispatches CBOR requests to the registered daemon with
  request-id correlation and a bounded response timeout. No daemon still yields
  `accelerator daemon unavailable`; the web server never computes the sum in process.
- Remaining: integration tests for in-cluster daemon connection by `ClusterIP` and host daemon connection
  by local-only `NodePort`.
- Remaining: browser e2e Add workflow proving the UI result came from a real JIT-built worker.

## Phase Objective

Provide a generic, fixed `service` command on the core tree so every project binary runs its long-running
roles uniformly: `service init` / `service schema` / `service run`, dispatched over a project-contributed
`ServiceType` ADT, gated to a service-role frame, with config delivered by a ConfigMap that overrides the
image's baked container `<project>.dhall`. There is no `service down` — a service's lifetime is owned by its
Kubernetes controller and torn down by `project destroy` (§ O, § Y).

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
  decoder, § Q); `service run` runs the selected role. No `service down`.
- `service run` is a **leaf-frame runtime command, never an orchestrator**: it assumes it is already placed
  in its frame (typically a k8s pod) and runs the role; it brings up no VM or cluster.

#### Validation

- The core CLI spec asserts `service` is present on every binary, `service run` fails fast when the config
  is not service-configured, and there is no `service down` subcommand.

#### Remaining Work

Built and code-check-validated: `serviceCommandGroup` surfaces `service init|schema|run` (no `service
down`); `service run` gates as `Context.ServiceCommand` (leaf-frame, never an orchestrator); `service init`
writes a `cluster-service`-role config; `service schema` prints the variants + reflected config schema.
`CLISpec` covers the leaf-frame refusal and `service schema`. Real-run-validated in the demo run ([phase-13](phase-13-hostbootstrap-demo.md)).

### Sprint 18.2: The `ServiceType` ADT and service-handler registry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`, `core/hostbootstrap-core/src/HostBootstrap/CLI.hs` (`withServices`), `core/hostbootstrap-core/test/CLISpec.hs`
**Docs to update**: `documents/architecture/library_hierarchy.md`, `system-components.md`

#### Objective

Let a binary define **more than one** service type and dispatch `service run` over them.

#### Deliverables

- A project contributes its service handlers as a **registry** threaded through `ProjectSpec` (one of the
  extension streams, § P, § T), keyed by a Dhall **ADT** `ServiceType = < Web : … | WorkloadOrchestrator :
  … >` with arbitrary per-variant parameters. `service run` dispatches on the variant.
- The registry **may be empty** — the fixed surface is unchanged and `service run` fails fast when no
  service is configured, so not every project ships a service.

#### Validation

- The CLI spec asserts dispatch over multiple variants, an empty registry still exposes `service` and fails
  fast, and a config naming an unknown variant exits non-zero.

#### Remaining Work

Built and code-check-validated: the `ServiceRegistry` is a list of `ServiceHandler`s (variant name + role
action) threaded through `ProjectSpec` via `withServices`; `service run` dispatches on the variant and fails
fast on an unknown variant or empty registry; the entrypoint rejects duplicate variants (`validateProjectSpec`,
`CLISpec`). The Dhall `ServiceType` ADT is modelled as the variant-name registry (the realistic L0 contract;
a richer per-variant-parameter ADT is an optional follow-up). Real-run-validated in the demo run.

### Sprint 18.3: Leaf-frame gating and ConfigMap-delivered config [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `demo/chart/templates/deployment.yaml`, `demo/chart/templates/configmap.yaml`
**Docs to update**: `documents/architecture/binary_context_config.md`, `documents/engineering/cluster_lifecycle.md`

#### Objective

Gate `service run` to a service-role frame and deliver its config the binary-context way.

#### Deliverables

- `service run` fails fast unless the effective `<project>.dhall` declares a **service role** and a valid
  **service variant** (§ X). A single config may declare project *and* service roles; `service run` checks
  the service capability.
- `project up`'s `deploy-chart` step deploys the pod whose entrypoint is `service run`; the pod's config
  arrives as a **ConfigMap overriding the image's baked container `<project>.dhall`** (§ X). `project up`
  *deploys* the service; `service run` *is* the service.

#### Validation

- A non-service-role config is refused; the chart pod runs `service run` and reads the ConfigMap-supplied
  config (exercised in the demo run).

#### Remaining Work

Built and code-check-validated: `service run` refuses a non-service-role config (the
`Context.ServiceCommand` gate — only `cluster-service` / `daemon` leaf contexts allow it; verified on the
real binary against a host-orchestrator config). The chart pod's entrypoint is `service run web` with the
cluster-service `<project>.dhall` delivered as the mounted ConfigMap (`demo/chart/templates`).
Real-run-validated: the live pod reads the ConfigMap-supplied config and serves HTTP 200 via `service run
web` (the demo run, [phase-13](phase-13-hostbootstrap-demo.md)).

### Sprint 18.4: Demo `web serve` → `service run` migration [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`demoServices`), `demo/app/Main.hs` (`withServices`), `demo/chart/templates/deployment.yaml`, `demo/docker/Dockerfile`
**Docs to update**: `documents/operations/demo_runbook.md`, `README.md`

#### Objective

Migrate the demo's long-running web workload off the `web` verb onto the generic `service` command — the
real-run gate for this phase.

#### Deliverables

- `web serve` → `service run` (`Web` variant of the demo's `ServiceType`); `web bridge` → the build-image
  chain step. The demo chart pod's entrypoint becomes `service run`, its config delivered by a ConfigMap.

#### Validation

- The full demo lifecycle brings up the stack and the web pod serves HTTP 200 via `service run` on the
  NodePort (the demo run, [phase-13](phase-13-hostbootstrap-demo.md)).

#### Remaining Work

Built and code-check-validated: `web serve` → `service run web` (the `web` 'ServiceHandler' in
`demoServices`, wired via `withServices`); `web bridge` → the build-image chain step (`runVmBootstrap`
generates the PureScript bridge before the image build, so the Dockerfile no longer invokes a `web bridge`
verb); the chart pod's `args` is `["service", "run", "web"]`. The `web` verb is removed. Real-run-validated:
the full demo lifecycle on the 16 GiB Apple-Silicon host serves HTTP 200 via `service run web` on the
NodePort (the demo run, [phase-13](phase-13-hostbootstrap-demo.md)).

### Sprint 18.5: Accelerator daemon runtime over CBOR WebSocket [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Accelerator/Protocol.hs`,
`demo/src/HostBootstrapDemo/Accelerator/Daemon.hs`
**Docs to update**: `documents/architecture/run_models.md`,
`documents/architecture/binary_context_config.md`, `documents/engineering/accelerator_daemon.md`

#### Objective

Add the accelerator daemon as a long-running service/daemon role that connects to the web server over CBOR
WebSocket and forwards add requests to a JIT-built worker.

#### Deliverables

- A demo accelerator service handler or daemon handler registered through the fixed service registry.
- CBOR request/result/failure codecs with request-id correlation.
- WebSocket client loop with reconnect, timeout, graceful shutdown, and backend/artifact metadata in
  replies.
- Worker-supervision seam used by the daemon after Phase 13's substrate-specific JIT build.
- Gate `service run accelerator` to daemon/service contexts only.

#### Validation

- Unit tests for CBOR codec round trips, invalid payload rejection, request correlation, and no in-process
  web fallback.
- Integration tests for in-cluster daemon connection by `ClusterIP` and host daemon connection by
  local-only `NodePort`.
- Browser e2e add test asserts the sum and daemon-returned backend/artifact metadata.

#### Remaining Work

Static/local runtime contract landed 2026-07-10: the demo registers `service run accelerator`, the existing
`Context.ServiceCommand` gate rejects non-service/project-lifecycle authority, the CBOR protocol round
trips request/result/failure messages and rejects invalid payloads, request-id correlation is unit-tested,
the worker-supervision seam wraps success/failure with backend + artifact metadata, the
transport-injected daemon loop is unit-tested for receive -> worker -> correlated response -> graceful
stop and reconnect-after-disconnect, and the concrete WebSocket client/server path is implemented.
Validation passed with the demo `-Werror` build and `cabal test all` from `demo/` (44 demo tests plus the
embedded 328 core tests).

The phase remains `Active` for live runtime closure: run host-daemon and in-cluster daemon integration
tests, build/run the real JIT workers in their lanes, and close the browser e2e Add workflow with
daemon-returned backend/artifact metadata.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/run_models.md` - the `HostDaemon`/service run-model reached via `service run`, the
  `ServiceType` ADT, and the service-handler registry.
- `documents/architecture/binary_context_config.md` - the service-role context and the ConfigMap-overrides-
  baked-`<project>.dhall` delivery.

**Engineering docs to create/update:**
- `documents/engineering/cluster_lifecycle.md` - the chart pod entrypoint `service run` and its config
  delivery.
- `documents/engineering/accelerator_daemon.md` - CBOR protocol seam, concrete WebSocket transport, and
  worker supervision.

**Cross-references to add:**
- `README.md` CLI Surface lists `service`; `system-components.md` adds the `service` command and the
  service-handler registry; `00-overview.md` names phase-18 in the cross-phase narrative.
