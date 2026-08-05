# Phase 15 — Host providers and the self-reference lift

**Status**: Active
**Depends on**: Phase 8 (ensure reconcilers), Phase 14 (the four ownership clauses and host-local
reservations)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, plus a live Incus/direct-host provider
lifecycle on linux-cpu

> **Purpose**: Provide one dispatch path for every host provider, so a lifecycle step names an operation
> rather than a provider.

## Phase Objective

A deployment runs across frames on different machines, and each frame is provided by something: an Incus
container, a Lima VM, a WSL2 distro, or the host itself. This phase makes those one interface — provision,
reconcile to ready, stop, delete, mount a durable share, project a guest alias — so a step above it names
the operation and never the provider.

The baseline realizations are Incus and the direct host. The Apple and Windows realizations are written
here but confirmed by their own substrate phases (§ II).

## Sprints

### Sprint 15.1: The provider interface and dispatch [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

One `SubstrateProvider` every frame operation goes through.

#### Deliverables

- `ProviderKind` is closed over Incus, Lima, WSL2, and the direct host; dispatch is total.
- Each operation — provision, reboot-to-ready, stop, delete, share, alias — has one signature across providers,
  so a step cannot branch on provider identity.
- A provider that cannot perform an operation reports `Unsupported` with a cause; it never silently no-ops.
- A total discovery probe reports the provider's daemon reachability, permissions, VM capability, and egress,
  and the capability it yields retains what it probed, so a later call cannot assume more than was observed.
- The probe reports the guest userland's own facts — the file-locking primitive and the `stat` dialect — so
  guest-side operations are probed rather than assumed.

#### Validation

`ProviderSpec` covers dispatch for each kind, the `Unsupported` branch, and the discovery probe's retained
capability.

#### Remaining Work

None.

### Sprint 15.2: The Incus and direct-host realizations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Incus.hs`,
`core/hostbootstrap-core/test/IncusSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Close the baseline provider lane.

#### Deliverables

- Incus provisioning applies the project's declared sizing rather than a default profile.
- Reboot-to-ready is a reconcile: the provider is brought to ready and the readiness is observed, not slept for.
- The durable host-path share is mounted per-substrate through one primitive, so a frame's durable root is the
  host's root rather than a copy inside the guest.
- The direct-host realization performs the same operations without a guest, so a single-frame deployment uses
  the same interface.

#### Validation

`IncusSpec` covers the argument shapes, the readiness reconcile, and the share primitive. Dated live evidence:
the Incus provider lifecycle gate reported `10/10` on native linux-cpu.

#### Remaining Work

None.

### Sprint 15.3: The clause-holding guest alias backend [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Own a guest-side durable alias under all four clauses.

#### Deliverables

- One backend serves every guest, because all provider guests run the same Linux image: a guest-side file lock,
  a host-side origin record, and `stat`-based identity binding close the alias on every lane together.
- The userland primitives the backend needs are read off the discovery probe's retained capability rather than
  assumed, so a BSD userland is handled by observation.
- A found alias is a reported conflict; release unlinks only on an exact re-observed identity.
- The alias operation is a prepared operation: the effect is reached through a `PreparedGate`, so it mints a
  `Managed` share handle with a receipt rather than an unowned link.

#### Validation

`ProviderAliasSpec` covers each clause, the conflict, the probe-reported userland branches, and the
`Unsupported` outcome where a clause cannot be held.

#### Remaining Work

The backend holds all four clauses and is gated, but no production call site consumes it: a lifecycle step
cannot yet reach a `PreparedGate`, so it cannot mint the `Managed` handle the prepared alias call requires.
The remaining item is that adoption, and it waits on the step-reaches-a-gate item in the prepared-operations
phase and the step-result item in the step-algebra phase.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — the provider interface and total dispatch.
- `documents/architecture/ownership_invariant.md` — the durable-share and guest-alias primitives as clause holders.

**Engineering docs to create/update:**
- `documents/engineering/incus.md` — the baseline provider realization.

**Cross-references to add:**
- `development_plan_standards.md` § U and § DD name this phase as the owner of the provider axis.
