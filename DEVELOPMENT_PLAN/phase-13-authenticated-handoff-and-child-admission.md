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

### Sprint 13.4: The in-binary receiver [Done]

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
  rather than guessed, and the child frame is checked by `authorizeChildProject` once the config it names is
  admitted.
- The offer's key digest is compared against the installed key and is never used as one, so an envelope that
  certifies itself certifies nothing.
- Every refusal is **sent** before the receiver returns, so a parent learns its child declined instead of
  inferring it from a closed pipe.
- The message order is checked by `ChildProtocolState`, not by the order of statements, so a receiver cannot
  answer a grant it never asked for.
- The continuation is rank-2 in the edge's indices: an authenticated edge is evidence about itself and cannot
  be unified with a scope the child already holds.

#### Validation

`HandoffReceiverSpec` drives the receiver over real pipes against a live root broker, and across a **real
process boundary** — the test binary relaunches itself as the child, exchanging on its own `stdin`/`stdout`
with its diagnostics on `stderr`. It covers the authenticated round trip, the recorded-transcript replay, the
installed-key mismatch, wrong project/scope/verb edges, a parent refusal, and a child that declines after
admitting.

#### Remaining Work

None.

### Sprint 13.5: The registered edge [Done]

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

### Sprint 13.6: The duplex root relay [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/test/HandoffRelaySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Let a nested frame obtain an edge it cannot issue.

#### Deliverables

- A `BrokerLink` is a frame's route to the root's two capabilities — **open** an edge and **grant** one.
  `rootBrokerLink` holds the live broker and an `EdgeAdmission` naming which edges the plan contains;
  `relayedBrokerLink` holds a channel and a request identity and **nothing else**, so it is structurally
  keyless and there is no function from it to a `RootBroker`.
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
link is not a broker. `cabal test all --ghc-options=-Werror` from `core/` passed 971/971 on 2026-08-05
(aarch64-osx, GHC 9.12.4); the demo suite passed 112/112 and the Python suite 231/231 on the same host and
date.

#### Remaining Work

None. Driving this transport from the recursive descent's own call site is the
[recursive lifecycle command](phase-17-recursive-lifecycle-command.md) phase, which owns that interpreter.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/binary_context_config.md` — the challenge/grant protocol, the relay, and the
  independently installed key.

**Engineering docs to create/update:**
- `documents/engineering/build_release.md` — build authority and the in-image gate.

**Cross-references to add:**
- `development_plan_standards.md` § EE and § X name this phase as the owner of the handoff protocol.
