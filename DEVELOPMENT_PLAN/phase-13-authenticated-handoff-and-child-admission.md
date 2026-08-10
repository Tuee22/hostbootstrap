# Phase 13 — Authenticated handoff and child admission

**Status**: Done
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

### Sprint 13.1: The handoff protocol and its closed tag vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/test/HandoffProtocolSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Define the wire shape, its closed tag vocabulary, and its refusals before anything transports it.

#### Deliverables

- A challenge is fresh per edge; a grant is bound to the challenge, the exact plan revision, the broker
  generation, protected-store identity, the child config digest, the verb, and the phase.
- Verification is against an independently installed project public key. A key carried by the envelope is
  refused, because a self-certifying envelope certifies nothing.
- The long-lived provisioned project signing/verification identity is distinct from the Build and Activation
  identities. A short-lived `RootBroker` narrows it for one verified root invocation; handoff grants use the
  framed `hostbootstrap/handoff-grant` domain plus protocol version 1, and an escaped broker refuses.
- A replayed grant, a recorded transcript, a stale broker generation, a wrong project/plan/frame/scope/config
  identity, and a truncated envelope each refuse with their own cause.
- A bring-up token cannot be reused at teardown; every later edge, including teardown, mints a fresh one.
- Tokens never travel through Dhall, `argv`, an environment variable, or durable config — see
  [rationale.md](rationale.md).
- **This phase owns every v1 protocol tag.** `ProtocolTag` is closed here and each member's exact field
  shape, round trip, and negative paths are pinned here, whatever later phase consumes it. A tag is a
  wire-format commitment, so the phase that owns the wire owns the vocabulary; a consumer that minted its
  own tag would leave this phase's stated surface incomplete on its own gate.
  - the **config-admission** set — offer, challenge, grant, accepted, completed, refused — plus the
    relay request/response pairs an admitted child raises;
  - the **activation-signing** pair, by which a nested frame asks the root to sign one activation
    manifest. It is deliberately distinct from the grant edges: the two carry different material and are
    answered by different keypairs, so they must not be substitutable;
  - the **recovery** pair, by which a parent admits a nested frame to a teardown or recovery edge. A
    nested teardown and a nested recovery are one edge, so they share one tag.
- Every request tag is reachable from an **admitted** child only, so a frame that has not completed its
  own admission cannot raise one.

#### Validation

`HandoffProtocolSpec` covers the closed tag vocabulary and exact frame round trips. `HandoffSpec` covers
cryptographic verification, replay, and refusal of an envelope-supplied key; together they make a new tag
or field shape visible to this phase's gate.

#### Remaining Work

None.

### Sprint 13.2: Verified config-handoff refinement [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/SchemaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Make raw bytes and a transport-only proof insufficient to choose config/plan coordinates.

#### Deliverables

- `HostBootstrap.Handoff` verifies the signature and one-use transport edge and yields only
  `VerifiedHandoff scope brokerGeneration`; transport verification does not choose plan, frame,
  configuration, verb, or lifecycle-phase phantoms.
- `HostBootstrap.Config.Schema.withVerifiedConfigHandoff` refines that transport proof with the exact
  `VerifiedConfigWire`, matching `ValidatedConfig`, and closed `ProjectVerb`. It checks the signed payload
  kind, wire/config digest, specification digest, verb, and closed `Prepare | Execute | Teardown` phase before
  yielding fully indexed
  `VerifiedConfigHandoff scope planDigest brokerGeneration parentFrame childFrame configId verb phase`
  inside a rank-2 continuation. Raw wire or a transport proof alone cannot be promoted.
- A recovery-kind grant and a config-kind grant are distinct types; swapping them is a compile-time failure.

#### Validation

`HandoffSpec`/`SchemaSpec` cover transport/config separation, exact wire/config/specification/verb/phase
checks, and the raw-wire refusal. Compile-fail cases pin the nominal fully indexed refinement.

#### Remaining Work

None.

### Sprint 13.3: Child plan and command authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Child/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/ProjectPlan.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Admit the exact child plan named by a refined config handoff and mint only its narrow command authority.

#### Deliverables

- `HostBootstrap.ProjectPlan.Construct.withChildProjectPlan` consumes `VerifiedConfigHandoff`, the same
  verified wire/config, and non-empty drafts; verifies the signed stable revision and protected
  project/store/broker origin; and jointly yields the fresh local plan, `PlanDigestBinding`, and opaque fully
  indexed `ChildPlanAuthority` inside a rank-2 continuation.
- `HostBootstrap.Authority.ProjectPlan.authorizeChildProject` consumes that authority with the matching
  plan, journal, frame, cursor, and validated context and rechecks every signed/runtime coordinate before
  the one-use command reservation. It never receives root, harness-root, or signing authority.
- A child mints fresh local plan/config identities; generative handles, journals, receipts, and consumed
  tokens are never serialized.
- This sprint establishes authority only. The
  [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns Production descent,
  child acquisition-journal/cursor opening, and recursive forward/reverse consumption.

#### Validation

`ProjectPlanSpec` and `AuthoritySpec` cover the exact positive path plus stable-plan, retained-store-origin,
parent-frame, current-child-frame, and lifecycle-phase runtime refusals before reservation. The safe public
API cannot compose installed-project, broker-generation, specification, configuration, or verb mismatches;
exact compile-fail diagnostics reject those nominal/rank-2 substitutions, construction, escape, and every
cross-index use.

#### Remaining Work

None. The package-private refinement that joins authenticated indices to the fresh child journal/frame/cursor
package and the recursive Production/Harness consumers are owned by Phase 17.

### Sprint 13.4: Build invocation authority protocol [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`

#### Objective

Define and verify the authority protocol an image-build frame can later consume.

#### Deliverables

- `BuildBinding`, coordinator grant, `ImageBuildFrame`, and `BuildInvocationAuthority` bind the source-root
  and builder-path measurements supplied to the verifier. Each returned authority can authorize each narrow
  build/check-code phase at most once.
- The reusable verifier does not decide that those paths are the build engine's context and running executable,
  and it does not globally consume a signed channel across separate verification calls. The
  [worked-demo phase](phase-24-worked-demo.md) owns those concrete consumer guarantees.
- The protocol is distinct from ordinary developer `check-code`; absence of a coordinator is an explicit
  refusal rather than fallback authority.
- This sprint does **not** claim that current `checkCodeCommand` or the derived Dockerfile receives or requires
  this authority. The [worked-demo phase](phase-24-worked-demo.md) owns the concrete consumer seam,
  Docker-build channel, and live container evidence.

#### Validation

`BuildAuthoritySpec` covers provisioned keys, signature-domain and coordinator-lifetime enforcement, UTF-8
source-path and binary-content measurement, per-returned-authority phase consumption, and the protocol's typed
refusals.

#### Remaining Work

None. The static command consumer and concrete derived-image delivery are owned by Sprint 24.7, including
trusted engine/runtime path derivation and acknowledgement or durable `buildId` admission for a second signed
channel presentation.

### Sprint 13.5: Runtime activation package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Define and verify the signed activation package for one measured runtime role entry.

#### Deliverables

- `ActivationManifest` is signed per pod-template revision and names the immutable digest-addressed objects a
  role reads.
- `VerifiedRuntimeRoleActivation` is minted only by verifying the manifest against the independently installed
  Activation key together with the role's measured binary, wire, bundle, and runtime-instance identity.
- Activation itself confers no lifecycle authority. The sole one-use admission is
  `RoleLifecycle.withRoleLifecycleAdmission`, which accepts only the activation's privately retained
  protected-store origin; its plan consumer and engine entry repeat that origin check before their own effects.
- That admission uses a fixed-size legal record key, `role-admission.<sha256>`, over the domain-separated,
  `frameWire`-framed exact plan digest, frame, revision, and measured instance kind/coordinates. It prevents a
  second use but does not rehydrate a reservation or consumed plan after callback/acknowledgement loss; that
  recovery protocol remains Phase 21 work.
- This sprint owns the protocol, not deployment or `service run` consumption. The
  [service-runtime phase](phase-22-service-runtime.md) owns manifest installation, relayed signing, and live
  runtime entry.

#### Validation

`ActivationSpec` covers provisioned-key signing/verification, the dedicated signature domain, manifest and
measurement comparison, broker expiry, wire decoding, measured-instance validation, and each refusal.
`RoleLifecycleSpec` covers the activation-origin-bound one-use reservation and plan-opening checks; the full
crash/lost-acknowledgement rehydration protocol remains explicitly owned by Phase 21.

#### Remaining Work

None. Service deployment and `service run` consumption are owned by Phase 22; complete reservation
rehydration after callback or acknowledgement loss is owned by Phase 21.

### Sprint 13.6: The in-binary receiver [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/test/HandoffReceiverSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Let the receiving binary run the child half of the exchange itself.

#### Deliverables

- A `HandoffChannel` is a handle pair — `stdin` inbound, `stdout` outbound — because those are the only
  descriptors a `docker run` / `limactl shell` / `wsl -d` boundary carries. A receiving binary's diagnostics
  therefore belong on `stderr`; `stdout` carries protocol frames and nothing else.
- `withReceivedHandoffEdge` runs the child half: receive the offer, mint a **fresh** challenge, answer, verify
  the grant against the independently installed key, admit the exact config bytes, and report completion.
- A `ReceiverExpectation` names only what a child can state before it has any config — its project, scope tag,
  verb, and payload kind. Everything else is authenticated by the root's signature over the canonical binding
  rather than guessed. `withVerifiedConfigHandoff` introduces the signed parent/child-frame indices only after
  exact config refinement, and `authorizeChildProject` later rechecks the current child frame.
- The offer's key digest is compared against the installed key and is never used as one, so an envelope that
  certifies itself certifies nothing.
- Every refusal is **sent** before the receiver returns, so a parent learns its child declined instead of
  inferring it from a closed pipe.
- The message order is checked by `ChildProtocolState`, not by the order of statements, so a receiver cannot
  answer a grant it never asked for.
- The installed opaque `HandoffScope scope` fixes the receiver's scope before parsing. The continuation is
  rank-2 only in the authenticated broker generation, so wire bytes cannot choose either index and an edge
  cannot escape the generation that verification introduced.

#### Validation

`HandoffReceiverSpec` drives the receiver over real pipes against a live root broker, and across a **real
process boundary** — the test binary relaunches itself as the child, exchanging on its own `stdin`/`stdout`
with its diagnostics on `stderr`. It covers the authenticated round trip, the recorded-transcript replay, the
installed-key mismatch, wrong project/scope/verb edges, a parent refusal, and a child that declines after
admitting.

#### Remaining Work

None.

### Sprint 13.7: The registered edge [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Make relaying strictly weaker than signing.

#### Deliverables

- `registerHandoffEdge` is the root's sole opener: it mints the one-time token, builds the canonical binding,
  and records the edge durably — under the store's exclusive entry, keyed by the token commitment, expecting
  absence — before anything can ask for a grant over it.
- `grantHandoff` answers only for an edge that record already holds. An edge the root never opened is
  `HandoffEdgeUnregistered`, so a frame that can carry a request still cannot invent one: without this, a root
  that signs any well-formed request has given an intermediary the signer's power one message removed.
- The record's two states are tagged, so "the planned binding" and "the transcript that consumed it" are told
  apart by construction rather than by their shapes not colliding.
- Consumption is a compare-and-swap at the exact version observed, so a concurrent peer loses the swap rather
  than issuing a second first-grant. An identical retry observes the settled transcript and returns the same
  deterministic signature; any other challenge is a reuse refusal.

#### Validation

`HandoffSpec` covers the opened edge authenticating once, the invented edge refused while the same root still
authorizes an edge it did open, the idempotent retry, the reuse refusal, and concurrent identical requests
converging on one signature.

#### Remaining Work

None.

### Sprint 13.8: The duplex root relay [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/test/HandoffRelaySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Let a nested frame obtain an edge it cannot issue.

#### Deliverables

- A `BrokerLink` is a frame's route to root-owned edge open/grant, activation signing, and recovery-wire
  signing. `rootBrokerLink` holds the live handoff/activation brokers and the plan's edge/recovery admission
  predicates. Its verification route and installed-key digest are derived from the broker rather than
  redundantly supplied by the caller.
- `relayedBrokerLink` derives the authenticated `BrokerRoute`, installed-key digest, channel, request identity,
  and current frame from `ReceivedEdge`; it does not retain the public verification key itself. It holds no
  broker or signing key, so there is no function from it to a `RootBroker`.
- Recovery signing reuses neither config-grant bytes nor an Activation/Build identity: its canonical
  `RecoveryProjectionBinding` retains scope, protected-store identity, broker generation, exact teardown verb,
  plan and parent/child frames, and wire digest, and the project key signs it under the distinct
  `hostbootstrap/recovery-wire/v1` domain. The verified wire/handoff values retain the matching generative
  digest identity and closed `down | destroy` verb indices.
- `offerHandoffEdge` is one descent implementation for every frame: open through the link, offer to the child,
  then stay on the channel serving whatever the child relays upward. At the root that means signing; at an
  intermediate frame it means relaying one hop further out.
- The channel becomes duplex at `ChildRunning`: an admitted child may raise edge-opening and grant requests
  and receive their answers, and the run ends only at completion or a refusal. A frame cannot ask before it
  has been admitted itself.
- A refusal is announced at every point a peer is already waiting — including before any offer exists, which
  the child accepts on its face because it has no request identity yet.
- Losing the route to the broker before anything durable refuses and leaves the opened edge intact for a
  retry. Losing it after the root consumed the edge reprobes: the identical transcript returns the identical
  signature rather than opening or consuming a second edge.

#### Validation

`HandoffRelaySpec` launches a **real chain of processes** — the test binary as root, a middle frame, and a
leaf frame the middle launches. It confirms that both edges were opened at the root (the middle asked; it did
not mint), that a grandchild edge the root's plan does not name is refused even when a middle frame asks for
it, and both broker-loss behaviours. The compile-fail fixture `RelaySignsWithoutBroker.hs` pins that a relayed
link is not a broker.

Dated evidence: on 2026-08-08 (aarch64-osx, GHC 9.12.4), the library built with `-Werror`; the Phase
13-specific exact-diagnostic compile-fail matrix passed 87/87; the focused severed-route regression passed
1/1; and the fresh exact phase gate, `cabal test all --ghc-options=-Werror` from `core/`, passed 1626/1626
cases in 89.28 seconds, including all 315 public compile-fail boundaries and both governed-documentation
checks. After the status/frontier update, the focused governed-documentation check passed 2/2 again.

#### Remaining Work

None. In accordance with § HH the sealed `BrokerLink` requester path is not an end-to-end cryptographic claim
against an external or deliberately raw channel writer; exact root admissions remain the authorization
boundary. Driving this transport from recursive descent is owned by the
[recursive lifecycle command](phase-17-recursive-lifecycle-command.md) phase.

## Remaining Work

None. Production descent and child journal/acquisition integration are owned by Phase 17. The concrete
command/Dockerfile build-authority consumer belongs to Phase 24, while deployment and `service run`
activation consumption belong to Phase 22; none is Phase 13 scope.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/binary_context_config.md` — the challenge/grant protocol, the relay, and the
  independently installed key.

**Engineering docs to create/update:**
- `documents/engineering/build_release.md` — build authority and the in-image gate.

**Cross-references to add:**
- `development_plan_standards.md` § EE and § X name this phase as the owner of the handoff protocol,
  config-handoff refinement, and child-plan authority substrate; Phase 17 owns recursive consumption.
