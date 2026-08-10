# Development Plan

**Status**: Governed orientation document
**Supersedes**: N/A
**Canonical homes**: [development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md),
[rationale.md](rationale.md)

> **Purpose**: Name the phases in execution order and carry the single cross-phase status table.

## How to read this plan

The plan is a **build recipe**. Phases 0 through 28 construct `hostbootstrap` from nothing, and the numbers
*are* the order: at phase *n* only the artifacts of phases ≤ *n* exist. Nothing later contradicts or reverses
anything earlier, so following the numbers in order and validating each phase as you go is the supported way
to develop the project.

`linux-cpu` is the baseline substrate. Phases 0–24 and 28 close on it or on pure-static gates. Phases 25–27
are **acceptance phases**: each adds any remaining non-baseline substrate-only realizations and confirms the build on
it. Where a cross-substrate provider realization is already built below, the acceptance phase confirms that
realization rather than redefining it. Nothing depends on them, so a machine without that hardware stops at
phase 24 rather than being blocked.

[development_plan_standards.md](development_plan_standards.md) § A states the doctrine and § II the substrate
rule. [rationale.md](rationale.md) explains why the architecture has the shape these phases build, including
the shapes it deliberately does not have.

## Current Phase Status

This table is the **sole cross-phase status source of truth**. Each phase file's own `**Status**` must match
its row here.

| # | Phase | Status | Substrate | Open |
|---|-------|--------|-----------|------|
| 0 | [Governance and documentation standards](phase-0-governance-and-documentation-standards.md) | Done | — | — |
| 1 | [Python pre-binary floor](phase-1-python-pre-binary-floor.md) | Done | linux-cpu | — |
| 2 | [Haskell core scaffolding](phase-2-haskell-core-scaffolding.md) | Done | — | — |
| 3 | [Host tools and substrate detection](phase-3-host-tools-and-substrate-detection.md) | Done | linux-cpu | — |
| 4 | [Protected store](phase-4-protected-store.md) | Done | linux-cpu | — |
| 5 | [Installed identity, operator verification, and authority kernels](phase-5-operator-root-and-command-authority.md) | Done | — | — |
| 6 | [Canonical quantities and reconcile results](phase-6-canonical-quantities-and-reconcile-results.md) | Done | — | — |
| 7 | [Dhall configuration and the generic project model](phase-7-dhall-configuration-and-project-model.md) | Done | — | — |
| 8 | [Ensure reconcilers](phase-8-ensure-reconcilers.md) | Done | linux-cpu | — |
| 9 | [Lifecycle modes and run leases](phase-9-lifecycle-modes-and-run-leases.md) | Done | linux-cpu | — |
| 10 | [Sessions, journal, and fences](phase-10-sessions-journal-and-fences.md) | Done | linux-cpu | — |
| 11 | [Prepared operations](phase-11-prepared-operations.md) | Done | linux-cpu | — |
| 12 | [Step algebra and the project plan](phase-12-step-algebra-and-project-plan.md) | Done | linux-cpu | — |
| 13 | [Authenticated handoff and child admission](phase-13-authenticated-handoff-and-child-admission.md) | Done | linux-cpu | — |
| 14 | [Ownership clauses and reservations](phase-14-ownership-clauses-and-reservations.md) | Done | linux-cpu | — |
| 15 | [Host providers and the lift](phase-15-host-providers-and-the-lift.md) | Active | linux-cpu | 15.22 native Linux/x86_64 provider-live build and KVM/Incus run |
| 16 | [Cluster lifecycle and cordoning](phase-16-cluster-lifecycle-and-cordoning.md) | Active | linux-cpu | 16.2 exact cluster consumer; 16.4 exact direct-Colima consumer; fresh phase gate |
| 17 | [Recursive lifecycle command](phase-17-recursive-lifecycle-command.md) | Active | linux-cpu | 17.3 forest/frame-index propagation and local/foreign sum; 17.4 operator/authenticated child entries; 17.5 authenticated forward/reverse traversal and live acceptance |
| 18 | [Recovery and migration](phase-18-recovery-and-migration.md) | Active | linux-cpu | 18.4–18.19 resource records, migration recovery, recovered closure, interruption fixtures |
| 19 | [Test harness and run ownership](phase-19-test-harness-and-run-ownership.md) | Active | linux-cpu | targeted `recovery-interruption` and live `test run all` acceptance |
| 20 | [`test` and `context` commands](phase-20-test-and-context-commands.md) | Active | linux-cpu | live linux-cpu verb sequence (phase gate) |
| 21 | [Composition and network algebra](phase-21-composition-and-network-algebra.md) | Active | linux-cpu | 21.2 blob-leaf arguments; reopened 21.3 role authority/transition/recovery audit; focused suites; fresh gate |
| 22 | [Service runtime](phase-22-service-runtime.md) | Active | linux-cpu | 22.2/22.3 registry adoption and the deploy step |
| 23 | [Base image and warm store](phase-23-base-image-and-warm-store.md) | Done | linux-cpu | — |
| 24 | [The worked demo](phase-24-worked-demo.md) | Active | linux-cpu | 24.3 same-run readback; 24.4 plan-owned profile/root; 24.5 workload/slices; 24.6 alias; 24.7 authenticated derived-image gate |
| 25 | [Apple Silicon substrate](phase-25-apple-silicon-substrate.md) | Active | **apple-silicon** | 25.3 acceptance re-run |
| 26 | [NVIDIA GPU substrate](phase-26-nvidia-gpu-substrate.md) | Active | **nvidia** | 26.3 acceptance re-run |
| 27 | [Windows and WSL2 substrate](phase-27-windows-and-wsl2-substrate.md) | Active | **windows** | 27.3 acceptance re-run |
| 28 | [Documentation reconciliation](phase-28-documentation-reconciliation.md) | Planned | — | all |

## The current frontier

The lowest-numbered open phase is **15**. Phase 6 owns the validated provider-neutral canonical
`ResourceBudget`, capacity, parsing, verification, sizing, and storage-policy foundation. Phase 7 owns the
validated configuration-facing cordon facade and public pure `HostBootstrap.Lift.Context`. Phase 8 owns the
validated generic resolved-tool `HostBootstrap.Lift` fold and effect dispatch. Phases 9–14 are also Done, so
the current constructive boundary is Phase 15's host-provider lifecycle and lift realization. Its work is
split into small opaque-descriptor, realization-adoption, discovery, prepared-lifecycle, provider-bound
execution, alias, node-route, and provider-live adoption sprints. Sprints 15.1–15.21 and the complete static
gate are closed; the lowest unfinished sprint is 15.22's native Linux/x86_64 provider-live acceptance.

**The lower capacity and Lift boundary is closed.** The pure context module carries the
Incus/Lima/WSL2 target records, container/config-delivery data, constructors, canonical mount projection, and
inner transport argv. Generic Lift reexports that vocabulary, resolves only the outer host tool, folds the
nested command, and imports no provider realization or Registry module. The active host-provider phase owns
the realization layer that consumes those lower values. Its full static gate is closed, while phase closure
still requires the declared native Linux/x86_64 KVM/Incus provider-live build and run. The
composition/network phase owns the additive reachability/blob helpers and
Registry-owned authenticated lift entry. Those phases remain Active until their own source guards and fresh
gates pass; the numerical frontier is Phase 15.

**The single indexed project plan is closed.** Phase 12 joins one lifecycle profile,
scope-correct validated config, canonical root, and non-empty draft stream into the generative
`ProjectPlan scope specDigest planId configId cfg`. Forward order, topology, the stable snapshot, pure
plan-local current-frame evidence, the ordered fresh snapshot-persistence/lease-binding protocol, and
read-only admission of an existing Production snapshot under one local plan identity are implemented. Pure
refinement of that exact Open package into its five-index recovered Production profile and reconstruction of
its fixed-identity plan are also implemented. The plan-bound acquisition journal, same-broker cursor,
plan-owned resource/edge projections, and exact local `authorizeProjectUp` gate are implemented as well. That
gate checks the lease's complete protected origin, then atomically revalidates live mode, lease, snapshot,
acquisition source, and current cursor together with its one-use reservation. The exact pure reverse route
is implemented too: `ProjectPlan` plus its admitted `CurrentFrame` produces the nominally framed
`TeardownPlan`, and the projection-only forest opener accepts no duplicate plan or frame witness. The
forest remains deliberately unframed. Production dispatch now retains or reconstructs one exact plan per
invocation: dry rendering, snapshot persistence/binding, journal and cursor admission, `project up`
authorization, Chain interpretation, and current-frame teardown all consume that value. The Production
forward/reverse compatibility modules and the public plan-only command-authority APIs are absent. The exact
reconciliation descriptor producer now consumes one `ProjectPlan` plus its matching `PlannedStep`; its
plan/configuration/node/frame/operation views and the carried-resource indices cannot be relabelled with
`coerce`. Public Chain now consumes the exact plan's current-frame `forward` projection plus matching
execute-phase command authority and lifecycle cursor, revalidates their protected origin and current row at
each transition, and keeps rendering, effects, observations, prepared gates, and carried resources on the
same plan indices. The test-harness phase's Sprint 19.3 owns the Harness consumer: command dispatch retains
one exact Harness plan through generated-config ownership and drives the common forward/reverse interpreter,
while assertion-only `TestSuite` code receives no lifecycle action. Its 2026-08-09 focused/static evidence is
closed; the phase still owes its declared live linux-cpu gate. Sprint 12.29 closes the Production
current-frame foundation. Sprint 12.30 owns only generic Budget admission from one exact plan's resource and
topology projections. Sprint 12.31 closes the package- and source-level absence guards; dated gate evidence
for all three sprints lives in the Phase 12 document. Phase 16 later adopts
the generic package at the cluster and direct-Colima consumers, and Phase 24 supplies the demo's concrete
workload and slices. Nested
`up|down|destroy` entry refuses before
effects until the authenticated-handoff and recursive-lifecycle phases supply its proof; exact
`down`/`destroy` authorization is likewise Phase 17 work rather than an authority inferred from the pure
reverse projection.

**The authenticated handoff boundary is closed.** Phase 13 owns the closed v1 protocol vocabulary, exact
config refinement, child-plan authority substrate, ordinary and multi-hop relays, and the reusable Build and
Activation authority packages. Handoff, Build, and Activation use distinct independently provisioned
long-lived keys and runtime-closed signer brackets. Recovery binds protected-store origin, broker generation,
exact teardown verb, plan and frame coordinates, and wire digest; repository-sealed requester paths constrain
ordinary `BrokerLink` use while exact root admission remains the authorization boundary for deliberately raw
channel writers. Constructor, escape, hidden-module, protocol-separation, and full-index nominal failures have
exact diagnostics, and the phase's fresh exact gate passes. A recursive verb has two entries, and they
are two types rather than one command class asked to mean both: an operator-initiated teardown validates at
the topology root, and a descent-initiated one is admitted in a nested frame only by verifying the recovery
wire its parent minted from the forest's own authorization point. Phase 12 has given the reverse projection
its frame index; Phase 17 propagates that existing index through the forest and supplies the closed
local/foreign sum, so whether an offered node belongs to this frame is structural rather than a comparison of
frame names.

That shape continues through independently gated downstream phases: the
[authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md) owns the recovery tag pair
and is closed; the [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) propagates the existing
frame index through its forest and owns the two entries; and the
[recovery phase](phase-18-recovery-and-migration.md) finally consumes the same wire at its own nested
boundary. Until those stages close, `project destroy` settles the frames one binary can reach and reports
the rest outstanding.

**Live acceptance owed.** Phase 18 builds deterministic interruption fixtures and closes on its host-static
gate. The later test-harness phase reruns the targeted `recovery-interruption` Cabal group on linux-cpu, then
runs `hostbootstrap run -- test run all` against live infrastructure. Phase 20 has every deliverable built and
closed by the host static gate and still owes its own declared live linux-cpu sequence.

**Machinery without a production call site.**

- **18.2**'s broker, old-permit fence set, verified session/operation manifest, and recorded-session
  interpreter have landed, and a **completed** migration is resumed from the durable stable key rather than
  inferred from current config. **18.3**'s digest-level migration spine has also landed: the profile builders,
  freeze, lineage compare-and-swap, activation transition, and configless post-CAS classification. The
  remaining work is split by contract and adoption: **18.4–18.7** build durable complete resource-record
  rehydration; **18.8–18.13** make prospective, completed, frozen, recovered, committed, and activated migration
  consume real plans and the exact set; **18.14–18.16** derive recovered frames, consume the shared recovery
  wire, and drive abandoned resources child-first; **18.17–18.18** retain Production lifecycle ownership and
  consume settled destroy as project-closure evidence; and **18.19** installs the deterministic interruption
  matrix that the later test-harness live gate confirms on linux-cpu.
- **22.2**'s effect algebra and its closed `ServiceProgram` have landed: an undeclared effect is a compile
  error, a row outside the signed ceiling has no authorization, and there is no `IO` constructor. The
  **declared row** has now landed with it — `serviceDefinition` takes a `DeclaredEffects`, the registry carries
  it through finalization and selection, and the demo's two roles declare genuinely different rows. What
  remains is the handler return type and the `ServiceBackend` call site, which cannot precede the deploy step
  that installs a signed activation, so they land with **22.3**.
- **22.3**'s relayed activation signing has **landed**: a distinct `ActivationSignRequest`/`Response` tag pair
  reachable only from an admitted child, a manifest wire codec so the root signs a value it decoded rather than
  opaque bytes, `linkSignActivation` on `BrokerLink` with the root signing locally and every other frame
  relaying, and the round-trip plus negative-path coverage this repository pins for every protocol tag. A
  nested frame can now reach the root for a signature, so what 22.3 owes is the deploy-step adoption that
  consumes it — signing one manifest per pod-template revision and having `service run` measure and verify —
  which is wiring rather than a protocol extension and lands with 22.2's registry adoption.
- **24.4**'s published-base consumption is now enforced: every derived build passes `--pull`, and the
  host-native lane resolves the published tag to its repository digest and builds `FROM` that, refusing an
  image that has no repo digest because that is exactly the stale-local case. The digest is a within-run
  handoff rather than a committed pin, which is what § FF requires. The existing config-derived Harness
  profile/root isolation is not the target boundary: 24.4 still replaces those independent consumer terms with
  the exact plan-owned projection. **24.5** then projects the demo's concrete workload, overhead, partition,
  and slices into the Phase-16 consumers. **24.6** adopts the clause-holding guest-alias route with the
  plan-minted `StepExecution`; that behavior is observable only inside a live guest. **24.7** then connects
  Phase 13's reusable build protocol to the static command seam and real Docker secret/session channel and
  proves it inside the derived container.

Every one of those depends only on lower-numbered phases, so they can be taken in order.

## Validation policy

`Done` requires the phase's own declared gate to pass, aligned governed documentation, and no remaining work
in its scope. A phase closes on **its own** gate; it never carries a closure obligation needing hardware it
does not declare.

A dated run validates only the behaviour and substrate it exercised. It cannot stand in for a different
provider, architecture, concurrency race, negative parser path, or newly introduced type boundary — which is
why each acceptance phase lists what it confirms, and why a change to a behaviour a lane exercises makes that
lane's acceptance owed again.

Exact test counts are dated evidence recorded against the gate that produced them, never a repository-wide
"current count".

Two limits worth stating rather than assuming: `fourmolu` and `hlint` run only inside the container
`check-code`, so the host static gate is not the complete quality gate; and the long demo gate brings up real
provider VMs, Docker state, and clusters on the host it runs on. A harness run's cluster identity, removable
state, host ports, and durable root are now its own rather than production's, so the gate no longer takes the
operator's project identity — but it still mutates real host infrastructure, so a disposable host remains the
supported way to run it.

## Governance

- [development_plan_standards.md](development_plan_standards.md) — the doctrine (§ A–§ J, § II) and the
  normative technical contracts (§ K–§ HH).
- [00-overview.md](00-overview.md) — phase responsibilities and the dependency flow, without status.
- [system-components.md](system-components.md) — the implementation surface inventory.
- [rationale.md](rationale.md) — why the design is what it is, and what it is not.
- [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md) — code still standing that the
  architecture does not want, each row naming the phase whose completion deletes it (§ I).
- Each phase file owns its objective, sprints, validation, and remaining work.

## Authority

This directory is authoritative for development sequencing and completion state. Governed architecture and
engineering documents describe supported behaviour; where a contract is not yet fully built, the owning phase
is `Active` and says so.
