# Phase 13 — Authenticated handoff and child admission

**Status**: Active
**Depends on**: Phase 12 (the step algebra and the single project plan)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`, including the cross-process fixtures

> **Purpose**: Let a parent frame hand authority to a child process across a real process boundary, exactly
> once, without ever giving the child or an intermediary a signing key.

## Phase Objective

The recursive lifecycle crosses machine boundaries: a host frame launches a VM, which launches a container.
Each child needs to act with authority it cannot mint itself, and the naive answer — hand it a token —
means anything that sees the token becomes the parent.

The shape here instead: the child issues a fresh challenge, the **root** broker signs a grant bound to that
challenge and to the exact edge, and the child verifies the signature against an independently installed
project public key — never one the envelope supplied. Intermediate frames relay to the root and hold no
signing capability at all.

## Sprints

### Sprint 13.1: The handoff protocol [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/test/HandoffProtocolSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Define the wire shape and its refusals before anything transports it.

#### Deliverables

- A challenge is fresh per edge; a grant is bound to the challenge, the exact plan revision, the broker
  generation, the child config digest, the verb, and the phase.
- Verification is against an independently installed project public key. A key carried by the envelope is
  refused, because a self-certifying envelope certifies nothing.
- A replayed grant, a recorded transcript, a stale broker generation, a wrong project/plan/frame/scope/config
  identity, and a truncated envelope each refuse with their own cause.
- A bring-up token cannot be reused at teardown; every later edge, including teardown, mints a fresh one.
- Tokens never travel through Dhall, `argv`, an environment variable, or durable config — see
  [rationale.md](rationale.md).

#### Validation

`HandoffProtocolSpec` covers the round trip and each refusal, including replay and the envelope-supplied key.

#### Remaining Work

None.

### Sprint 13.2: Verified wire, verified handoff, and child plan authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Make raw bytes un-promotable, and make a verified value authorize only a plan.

#### Deliverables

- Grant verification and byte verification through the scope-correct project codec **jointly** mint
  `VerifiedConfigWire` and the exact `VerifiedHandoff`. Neither alone suffices, so raw wire cannot be promoted
  merely because run authority exists.
- Those values do not authorize a command. `withChildProjectPlan` consumes them with the closed verb and a
  non-empty plan draft, verifies the stable revision, and jointly yields a fresh local plan, its digest
  binding, and the exact `ChildPlanAuthority` inside a rank-2 continuation.
- `authorizeChildProject` consumes that authority and never receives root, harness-root, or signing authority.
- A recovery-kind grant and a config-kind grant are distinct types; swapping them is a compile-time failure.
- A child reprobes stable records and mints fresh local values under its own plan and config identities;
  generative handles, journals, receipts, and consumed tokens are never serialized.

#### Validation

`HandoffSpec` covers the joint mint, the raw-wire refusal, the child authority's narrowness, and the
compile-fail fixture for swapped grant kinds.

#### Remaining Work

None.

### Sprint 13.3: Build authority and the activation package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`

#### Objective

Gate an image build and a runtime role activation on authority rather than on baked configuration.

#### Deliverables

- `BuildInvocationAuthority` is the capability an in-image `check-code` requires, so the gate is authorized
  rather than implied by the presence of a config file.
- `ActivationManifest` is signed per pod-template revision and names the immutable digest-addressed objects a
  role reads.
- `VerifiedRuntimeRoleActivation` is minted only by verifying the manifest against the independently installed
  project key, together with the role's own measured binary, wire, and bundle digests.
- A one-use lifecycle admission accompanies it, so an activation authorizes exactly one entry.

#### Validation

`BuildAuthoritySpec` and `ActivationSpec` cover the mint, the measurement comparison, and each refusal.

#### Remaining Work

None.

### Sprint 13.4: The in-binary receiver and duplex root relay [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Transport the protocol over the real child boundary.

#### Deliverables

- The child entrypoint carries an in-binary **receiver** for the handoff, so delivery is a typed exchange
  rather than a shell writer piping bytes into a file.
- An immediate parent holds a **duplex relay** to the root broker and no signing or delegation key, so a nested
  frame can obtain a grant it cannot itself issue.
- The root broker stays live through bring-up, assertion, and recursive teardown; each child sends one one-use
  command/handoff identity into an atomically opened versioned session after the current broker has admission.
- Nested-edge tests prove children relay rather than sign.
- Broker loss before prepare refuses; loss after a prepared backend call reprobes rather than replaying.

#### Validation

Cross-process fixtures cover the real exchange, the nested relay, broker loss on both sides of prepare, and
that an intermediary cannot sign.

#### Remaining Work

All of it. The protocol, the verified values, and the authority types exist and are gated in-process, but the
transport is still a shell writer: there is no in-binary receiver and no duplex relay. This is what stops the
root authority gate from extending past the root frame, and it is what the service-runtime phase's activation
signing at a nested deploy call site waits on.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/binary_context_config.md` — the challenge/grant protocol, the relay, and the
  independently installed key.

**Engineering docs to create/update:**
- `documents/engineering/build_release.md` — build authority and the in-image gate.

**Cross-references to add:**
- `development_plan_standards.md` § EE and § X name this phase as the owner of the handoff protocol.
