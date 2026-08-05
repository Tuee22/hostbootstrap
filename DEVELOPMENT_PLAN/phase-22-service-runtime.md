# Phase 22 — Service runtime

**Status**: Active
**Depends on**: Phase 20 (`test` and `context` command semantics), Phase 21 (composition and network algebra)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, plus a live `service run` on linux-cpu

> **Purpose**: Make a project's long-running workload a config-selected service variant reached through one
> fixed command, driven by the role phase machine.

## Phase Objective

`project up` *deploys* a service; `service run` *is* the service. A project therefore defines no long-running
verb of its own — a web server is `service run` on its `Web` variant. This phase fixes the command surface, the
typed selection, and the immutable payload a handler receives, and adopts the role machine at the real call
site.

## Sprints

### Sprint 22.1: The `service` command surface [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Three verbs, closed at this layer.

#### Deliverables

- `service init`, `service schema`, and `service run` are the whole surface; a project contributes variants, not
  verbs.
- `service schema` emits the service vocabulary as an exact snapshot, pinned by a golden test.
- The variant is selected from decoded configuration; there is no environment variable or flag that overrides it.

#### Validation

`CLISpec` covers each verb, the selection, and the schema snapshot.

#### Remaining Work

None.

### Sprint 22.2: Typed service selection and the immutable handler payload [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Give a handler exactly one immutable, config-derived input.

#### Deliverables

- A selected service is a typed value drawn from the project's finalized registry, so an unknown variant is a
  decode refusal rather than a runtime lookup miss.
- One immutable config-derived payload is handed to the handler; a handler reads no ambient state and cannot
  mutate its input.
- Role parameters are least-authority: a handler receives only what its declared role needs.
- A missing service configuration produces a service-specific recovery message naming the variant and the field.
- The registry-selected action enters the role machine as its serve step, narrowed to an effect-indexed program.

#### Validation

`RoleLifecycleSpec` and `CLISpec` cover the typed selection, the immutable payload, the least-authority
parameters, and the missing-config message.

#### Remaining Work

The typed registry and the payload shape exist; the effect-indexed narrowing and the least-authority parameter
split are not built, so a handler still receives a wider input than its role declares.

### Sprint 22.3: Role-machine adoption at `service run` [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Enter the service through the activation package rather than beside it.

#### Deliverables

- The deploy step signs one activation manifest per pod-template revision and installs the immutable
  digest-addressed config, secret, and manifest objects the role reads.
- `service run` measures its own binary, its mounted role wire, and its private bundle digests plus its instance
  identity, verifies the activation against the independently installed project key, and enters the phase machine.
- A verification failure refuses to start rather than starting unverified.

#### Validation

`ActivationSpec` and `RoleLifecycleSpec` cover the signing, the measurement comparison, and the refusal.

#### Remaining Work

All of it. The role machine, the activation package, and the root authority gate all exist, but a signed manifest
needs an activation broker at the **nested** deploy call site, and the current gate is root-frame only. This item
waits on the in-binary receiver and duplex root relay in the authenticated-handoff phase.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — the fixed `service` surface.
- `documents/architecture/composition_methodology.md` — role adoption at `service run`.

**Engineering docs to create/update:**
- `documents/engineering/accelerator_daemon.md` — daemon startup ordering and teardown expectations.

**Cross-references to add:**
- `development_plan_standards.md` § AA names this phase as the owner of the service runtime.
