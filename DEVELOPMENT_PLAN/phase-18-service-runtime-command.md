# Phase 18: Service Runtime Command

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-16-project-lifecycle-command.md](phase-16-project-lifecycle-command.md)

> **Purpose**: Add the third DSL-driven core command — `service` — that runs a project's long-running
> roles (the `HostDaemon`/service run-model) through a fixed `service init|schema|run` surface, a project-
> contributed `ServiceType` ADT + service-handler registry, leaf-frame fail-fast gating, and ConfigMap-
> delivered service config.

## Phase Status

**Status**: Blocked

**Blocked by**: phase-16 (the fixed command surface the `service` verb slots into), phase-15 (the
binary-context contract: the service-role config and forwarded-parameter generation `service` reads).

`service` is **new core scope** — there has never been a `service` command; the demo's long-running web
workload runs today through the load-bearing `web serve` verb. This phase adds the generic command so a
project's long-running roles are reached through the fixed surface (development_plan_standards § AA), not a
per-project verb. It is a forward dependency on the earlier reopened phases (§ A: a later phase names its
earlier prerequisites; no earlier phase is blocked by this one). The contract is documented now; the code
lands once the fixed surface (phase-16) and the multi-role/forwarded-parameter context (phase-15) are in
place, and is real-run-gated by the demo's `web serve` → `service run` migration ([phase-13](phase-13-hostbootstrap-demo.md)).

## Phase Objective

Provide a generic, fixed `service` command on the core tree so every project binary runs its long-running
roles uniformly: `service init` / `service schema` / `service run`, dispatched over a project-contributed
`ServiceType` ADT, gated to a service-role frame, with config delivered by a ConfigMap that overrides the
image's baked container `<project>.dhall`. There is no `service down` — a service's lifetime is owned by its
Kubernetes controller and torn down by `project destroy` (§ O, § Y).

## Sprints

### Sprint 18.1: The `service init|schema|run` command surface [Blocked]

**Status**: Blocked
**Blocked by**: phase-16
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

All of the above is the open, real-run-gated work; blocked on the fixed surface from phase-16.

### Sprint 18.2: The `ServiceType` ADT and service-handler registry [Blocked]

**Status**: Blocked
**Blocked by**: phase-16
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

All of the above; blocked on phase-16.

### Sprint 18.3: Leaf-frame gating and ConfigMap-delivered config [Blocked]

**Status**: Blocked
**Blocked by**: phase-15, phase-16
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

All of the above; blocked on phase-15 and phase-16.

### Sprint 18.4: Demo `web serve` → `service run` migration [Blocked]

**Status**: Blocked
**Blocked by**: phase-13
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

All of the above; blocked on the demo verb removal in phase-13.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/run_models.md` - the `HostDaemon`/service run-model reached via `service run`, the
  `ServiceType` ADT, and the service-handler registry.
- `documents/architecture/binary_context_config.md` - the service-role context and the ConfigMap-overrides-
  baked-`<project>.dhall` delivery.

**Engineering docs to create/update:**
- `documents/engineering/cluster_lifecycle.md` - the chart pod entrypoint `service run` and its config
  delivery.

**Cross-references to add:**
- `README.md` CLI Surface lists `service`; `system-components.md` adds the `service` command and the
  service-handler registry; `00-overview.md` names phase-18 in the cross-phase narrative.
