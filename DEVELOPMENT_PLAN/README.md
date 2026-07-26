# Development Plan

**Status**: Governed orientation document
**Supersedes**: N/A
**Canonical homes**: [development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Name the phases in execution order, provide the single current cross-phase status table,
> and link to detailed ownership, validation, and component documentation.

## Foundation

`hostbootstrap` is a Haskell `hostbootstrap-core` library plus a thin Python pre-binary bootstrapper.
The Haskell library owns host/provider operations, configuration, lifecycle, test, service, and project
extension contracts. Python asserts the irreducible host floor, prepares the native Haskell toolchain,
builds the project binary host-native, and invokes it (POSIX process replacement with `exec`; Windows
child subprocess); it also owns the explicit operator-invoked base-image and pipx self-update surfaces.

The target command tree is fixed to `project`, `test`, `service`, `context`, and `check-code`.
Project behavior is supplied through typed extension streams, including one lifecycle chain, project
configuration, test components, and service handlers. The active repair program is intended to make those
boundaries enforceable through one opaque `ProjectPlan scope specDigest planId configId cfg`, plan/resource-indexed capabilities,
ownership- and phase-indexed lifecycle state, dependency-indexed total probes, structured
reconciliation, resource-authoritative reservations with verified ownership receipts, authenticated
one-time cross-process authority handoffs and operation sessions, durable delayed-permit fencing,
project-wide Production/Harness exclusion, exhaustive bound-run/migration/close recovery,
native rolling-base publication with real-consumer compatibility smoke, and typed test case/variant
configuration. The same repair program separates
production and harness config scope so test-only plaintext secrets are unrepresentable in production
configuration rather than excluded only by consumer policy. These are target contracts until their named
sprints close, not current implementation claims.

Historical test counts and real-run results live as dated validation evidence in the phase sprint that
produced them. They are not copied here as a mutable “current suite” claim.

## Current Phase Status

This table is the **sole cross-phase status source of truth**. Phase-local status and sprint ownership must
match it. `00-overview.md` and `system-components.md` describe responsibilities and inventory only; they
defer status to this table.

| Phase | Title | Status | Current open owner |
|-------|-------|--------|--------------------|
| 0 | [Documentation and governance](phase-0-documentation-and-governance.md) | Done | — |
| 1 | [hostbootstrap-core scaffolding](phase-1-hostbootstrap-core-scaffolding.md) | Done | — |
| 2 | [Host floor, tools, and config](phase-2-host-tools-and-config.md) | Done | — |
| 3 | [Ensure reconcilers](phase-3-ensure-reconcilers.md) | Done | — |
| 4 | [Project-local Dhall and command tree](phase-4-skeletal-dhall-and-command-tree.md) | Done | — |
| 5 | [Cluster lifecycle and resource cordoning](phase-5-cluster-lifecycle-and-resource-cordoning.md) | Active | Sprint 5.8 done; 5.7 waits on 11.10; Sprints 5.5 and 5.6 retain their native/live gates |
| 6 | [Base image and Python CLI surface](phase-6-base-image-and-thin-python-bootstrapper.md) | Done | — |
| 7 | [Consumer adoption](phase-7-consumer-migration.md) | Done | — |
| 8 | [Dhall generation and extension contract](phase-8-dhall-generation-and-extension.md) | Done | — |
| 9 | [Applied budget cordon and one canonical parser](phase-9-applied-cordon-and-one-parser.md) | Done | — |
| 10 | [Standardized test harness and execution shapes](phase-10-standardized-test-harness.md) | Active | Sprint 10.10 done; 10.9 waits on Sprints 5.7 and 15.9 |
| 11 | [Incus first-class host-provider](phase-11-incus-host-provider.md) | Active | Sprint 11.10 removed dead dispatch/builders and strengthened Incus; strong guest-alias/WSL ownership plus native Windows/Linux gates remain |
| 12 | [Opportunistic warm store](phase-12-layered-warm-store.md) | Done | — |
| 13 | [hostbootstrap-demo worked app](phase-13-hostbootstrap-demo.md) | Active | Sprint 13.19 done; 13.17 active; 13.20 registry route waits on 14.7; 13.18 waits on the integration chain |
| 14 | [Composition methodology](phase-14-composition-methodology.md) | Active | Sprint 14.7 is dependency-ready; Sprint 14.6 waits on 15.9 |
| 15 | [Binary context config and command gating](phase-15-binary-context-config.md) | Active | Sprint 15.8 active; 15.9 waits on Sprint 5.7 and the named type foundations |
| 16 | [Project lifecycle command](phase-16-project-lifecycle-command.md) | Active | Sprint 16.5 active; 16.6 waits on Sprints 5.7, 10.9, and 15.9 |
| 17 | [Chain-driven test and context introspection](phase-17-chain-driven-test-and-context-introspection.md) | Blocked | Sprint 17.4: waiting on Sprints 10.9 and 15.9 |
| 18 | [Service runtime command](phase-18-service-runtime-command.md) | Active | Sprint 18.5 native live lanes; Sprint 18.6 runtime authority/effects blocked by 14.6, 15.9, and 17.4 |
| 19 | [Generic project model](phase-19-generic-project-model.md) | Done | — |
| 20 | [Config-driven demo worked example](phase-20-config-driven-demo-worked-example.md) | Blocked | Sprint 20.5: waiting on Sprints 10.9 and 18.6; Sprints 19.7–19.8 are done |
| 21 | [Documentation/code consistency reconciliation](phase-21-documentation-code-consistency-reconciliation.md) | Blocked | Sprint 21.4: waiting on all named implementation owners |

The Windows GPU accelerator host-daemon lane is dated, accepted evidence for Phase 18; it is not open
live-lane work there. Phase 18 remains Active for Apple Silicon/native Linux CPU/GPU live lanes and the
blocked validated-service-selection repair. Other reopened phases own implementation defects and cannot
be closed by replaying that Windows result.

## Ownership Map

- Phase 2 owns host-tool resolution and the pre-binary host floor.
- Phases 5, 9, 10, 11, 15, and 16 split lifecycle work: backend storage operations/receipts; core state
  types; project-wide mode/profile opening; provider dispatch; independent root/command authority; and
  recursive plan interpretation/teardown.
- Phases 6 and 12 split base work: rolling publication/native/source-gate/pull enforcement and the
  single-project opportunistic warm-store policy.
- Phases 10, 17, 19, and 20 split test work: engine isolation plus the Harness mode/profile opener;
  command semantics; generic typed case/variant and production/harness secret-scope contracts; and demo
  config consumption.
- Phase 13 owns the worked demo's Production plan, test component, pulled base, and concrete
  reachability-safe registry/MinIO renderer and live route proof.
- Phase 14 owns the generic scope-indexed endpoint and proof-gated blob-delivery algebra; Phase 9 owns
  the identity-bound readiness/precondition value it consumes.
- Phase 21 follows the implementation phases and reconciles governed documentation, comments/help, and
  mechanical drift guards.

## Validation Policy

`Done` requires implementation, the phase's static gates, any named native real-run/build/publish gates,
aligned governed documentation, and no remaining work. A dated run validates only the behavior and
substrate it exercised. It cannot stand in for a different provider, architecture, concurrency race,
negative parser path, or newly introduced type boundary.

Exact test counts may be recorded in a sprint's validation evidence with a date. They must not be promoted
to a repository-wide “current count.” The operator publication workflow follows current-compatible
resolution → native build → complete quality gate → publish rolling tag → pull → real-consumer
compatibility smoke. A digest may identify that one pulled build, but does not imply locked inputs.

## Governance

- [development_plan_standards.md](development_plan_standards.md) defines plan structure and durable
  doctrine.
- [00-overview.md](00-overview.md) explains phase responsibilities and dependency flow without duplicating
  status.
- [system-components.md](system-components.md) inventories implementation surfaces and explicitly marks
  target-only/open contracts.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) records obsolete, duplicate, and
  definition-only surfaces.
- Each phase file owns its deliverables, validation, and remaining work.

## Authority

This directory is authoritative for development sequencing and completion state. Governed architecture
and engineering documents describe supported behavior only after the owning phase closes.
