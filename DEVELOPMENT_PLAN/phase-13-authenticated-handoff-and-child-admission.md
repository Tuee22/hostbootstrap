# Phase 13 — Authenticated handoff and child admission

**Status**: Done
**Depends on**: Phase 12 (the step algebra and the single project plan)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror -j1` from `core/`, after focused `HandoffSpec`,
public compile-fail boundary, `ProjectPlanSpec`, and `DocValidatorSpec` runs

> **Purpose**: Define the bounded root-authenticated handoff and keyless rooted-transport contracts without
> constructing a recursive child or claiming a successful rooted process exchange.

## Phase Objective

The recursive lifecycle crosses machine boundaries from a host frame into VMs and containers. This phase
defines the authentication and bounded transport contracts used at that boundary. The root coordinator holds
the independently provisioned signing identity, a child issues a fresh challenge and verifies the root's exact
edge grant against the independently installed project key, and intermediate frames can relay canonical rooted
bytes without acquiring a signing key, protected store, or root command authority.

The wire distinguishes transported payload identity from child-configuration identity, authenticates scope
before untrusted bytes can introduce its phantom, and carries recovery config and adapter bytes as one
canonical package. The rooted request/response vocabulary includes the shapes later used by terminal receipt
exchange. Phase 13 owns only those authentication, codec, and transport contracts; Phase 17 (the recursive
lifecycle command) owns the root catalog, retained session path, response production and fixed-signer
invocation at the root
endpoint, durable prepare/settle/replay/receipt semantics, storeless frame execution, process ownership, and
recursive command adoption. Recursive child construction, a successful rooted process exchange, and the
rooted service the root endpoint runs are that phase's too: this one validates the structure of a rooted
request and carries whatever answer comes back.

## Sprints

### Sprint 13.1: Challenge/grant wire foundation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Define the bounded challenge/grant exchange and its independently verified signing identity.

#### Deliverables

- Every edge carries one fresh `HandoffChallenge` and one one-use token commitment in canonical,
  length-delimited protocol-v1 bytes.
- `HandoffGrant` binds the challenge to the installed project, scope, plan revision, broker generation,
  parent/child edge, payload kind, verb, and lifecycle phase.
- A short-lived `RootBroker` narrows the provisioned project signing identity to one verified root
  invocation and signs only the `hostbootstrap/handoff-grant/v1` domain.
- Child verification consumes the independently installed project verification key and yields only the
  transport-level `VerifiedHandoff scope brokerGeneration` proof.
- Bounded decoding and sequencing distinguish malformed, truncated, stale, replayed, wrong-edge, and
  wrong-domain inputs before admitting an edge.

#### Validation

`HandoffSpec` covers signing, exact binding checks, one-use grants, replay refusals, installed-key
verification, and the hidden protocol's bounded framing and sequencing surface through exact
source/ownership guards. The protocol remains Cabal-private and has no testing facade.

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

Make transport proof and raw bytes insufficient to choose config or plan coordinates.

#### Deliverables

- `VerifiedHandoff scope brokerGeneration` remains transport-only and selects no plan, frame,
  configuration, verb, or lifecycle-phase phantom.
- `withVerifiedConfigHandoff` consumes the transport proof, exact `VerifiedConfigWire`, matching
  `ValidatedConfig`, and closed `ProjectVerb` in one refinement.
- The refinement checks the signed payload kind, exact configuration digest, specification digest, verb,
  and closed `Prepare | Execute | Teardown` phase.
- Successful refinement yields fully indexed `VerifiedConfigHandoff scope planDigest brokerGeneration
  parentFrame childFrame configId verb phase` only inside a rank-2 continuation.
- Config-kind and recovery-kind grants remain distinct at the type boundary, so one kind cannot satisfy
  the other's refinement.

#### Validation

`HandoffSpec` and `SchemaSpec` cover transport/config separation, exact digest/specification/verb/phase
checks, and raw-wire refusal. Compile-fail fixtures pin every nominal and rank-2 mismatch.

#### Remaining Work

None.

### Sprint 13.3: Child-plan authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Child/Internal.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Admit the exact fresh child plan named by a refined config handoff without granting lifecycle execution.

#### Deliverables

- `withChildProjectPlan` consumes one `VerifiedConfigHandoff`, the same verified wire/configuration, and
  non-empty plan drafts.
- Admission verifies the signed stable plan revision, installed project, scope, broker generation,
  specification, configuration, verb, and child-frame binding.
- One rank-2 continuation jointly receives the fresh local `ProjectPlan`, exact `PlanDigestBinding`, and
  fully indexed opaque `ChildPlanAuthority`.
- Child-local plan and configuration identities are generative, and tokens, receipts, and generative
  handles are never serialized as plan authority.
- `ChildPlanAuthority` contains no `ProtectedStore`, acquisition journal, lifecycle cursor,
  `CommandAuthority`, root invocation authority, or signing capability.

#### Validation

`ProjectPlanSpec` and `AuthoritySpec` cover exact admission and every stable-plan, project, scope, broker,
frame, specification, configuration, and verb refusal. Compile-fail fixtures reject construction, escape,
and cross-index substitution.

#### Remaining Work

None. Phase 17 (the recursive lifecycle command) owns coordinator admission and execution of this exact
child plan.

### Sprint 13.4: Build invocation authority protocol [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`

#### Objective

Define the signed, measured authority protocol consumed by an image-build frame.

#### Deliverables

- `BuildBinding` binds the project/spec/config identity to measured source-root and builder-path inputs.
- Verification uses the independently installed Build key and a coordinator-scoped signed grant.
- One verified exchange jointly yields `ImageBuildFrame` and `BuildInvocationAuthority` inside its
  bounded continuation.
- Each returned authority authorizes each narrow build/check-code phase at most once, and absence of a
  coordinator is a typed refusal.
- The protocol grants no ordinary developer command authority; the worked-demo phase owns the concrete
  derived-image delivery and consumer.

#### Validation

`BuildAuthoritySpec` covers provisioned-key and signature-domain checks, coordinator lifetime, exact UTF-8
path and binary measurements, one-use phase consumption, and typed refusals.

#### Remaining Work

None. The worked-demo phase owns trusted engine/runtime derivation and the actual Docker-build consumer.

### Sprint 13.5: Runtime activation package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Define the signed activation package for one measured runtime-role entry.

#### Deliverables

- `ActivationManifest` is signed per immutable pod-template revision and names every digest-addressed
  object the role reads.
- `VerifiedRuntimeRoleActivation` requires the independently installed Activation key and exact measured
  binary, wire, bundle, and runtime-instance identity.
- Activation grants no lifecycle authority until the origin-bound one-use role admission consumes it.
- The fixed-size admission record binds the exact plan digest, frame, revision, and measured instance
  coordinates under a dedicated domain.
- The service-runtime phase owns manifest installation, relayed signing consumption, deployment, and the
  live `service run` entry.

#### Validation

`ActivationSpec` covers provisioned-key verification, the dedicated signature domain, manifest and
measurement comparison, broker expiry, wire decoding, instance validation, and refusals.

#### Remaining Work

None. Runtime deployment and complete admission recovery belong to their lower-dependent consumer phases.

### Sprint 13.6: Registered one-use edge [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Make edge registration root-owned and relaying strictly weaker than signing.

#### Deliverables

- `registerHandoffEdge` is the root's sole edge opener and mints the one-use token for an exact canonical
  binding.
- Registration records the edge durably under the store's exclusive entry before any grant request can
  name it.
- `grantHandoff` answers only for the exact registered edge and root-plan admission predicate.
- Tagged planned and settled records distinguish an unconsumed binding from the transcript that consumed
  it.
- Exact-version compare-and-swap gives one winner, makes an identical retry deterministic, and refuses a
  conflicting challenge or binding.

#### Validation

`HandoffSpec` covers root registration, refusal of an unregistered edge, idempotent retry, conflicting reuse,
and concurrent identical grant requests converging on one signature.

#### Remaining Work

None.

### Sprint 13.7: Keyless duplex relay foundation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportHandoffRelay.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Let an admitted nested frame reach root-owned handoff services through a structurally keyless link.

#### Deliverables

- `BrokerLink` is the private route to root-owned edge open/grant, activation signing, and recovery-wire
  signing services.
- A root link retains the live brokers and admission predicates, while a relayed link retains only its
  authenticated route, request identity, installed-key digest, and duplex channel.
- `offerHandoffEdge` opens through the link, performs the child exchange, and then serves admitted relay
  requests until completion or refusal.
- An admitted child can raise only the closed request tags allowed by `ChildRunning`, and each response
  returns over the same exact request route.
- Route loss before a durable action refuses cleanly; route loss after an identical settled request
  replays the same deterministic response.

#### Validation

`HandoffSpec` pins the private route, request/response ownership, keyless import graph, and both broker-loss
branches without importing the hidden Relay module. `ImportHandoffRelay.hs` proves that external code cannot
import the relay owner; the private-source graph proves that its relayed arm has no signing route. Dated
evidence on 2026-08-08 (aarch64-osx, GHC 9.12.4): the library built with `-Werror`, the Phase 13
exact-diagnostic matrix passed 87/87, the focused severed-route regression passed 1/1, and
`cabal test all --ghc-options=-Werror` passed 1626/1626 cases.

#### Remaining Work

None.

### Sprint 13.8: Closed rooted outer vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 160 lines in one production module
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Reserve the only two protocol-v1 outer tags used by the rooted lifecycle exchange.

#### Deliverables

- `ProtocolTag` adds exactly `RootedLifecycleRequestTag` and `RootedLifecycleResponseTag` to the closed
  protocol-v1 vocabulary.
- Each rooted outer message carries exactly one bounded canonical field whose inner codec is owned by a
  later sprint in this phase.
- `ChildProtocolState` permits a rooted request only after admission reaches `ChildRunning` and moves every
  admitted request family into one exact response-waiting state.
- That state retains the sole expected response tag and session request identity; a second request,
  unsolicited/wrong response, duplicate, out-of-order, or post-terminal traffic refuses.
- Exact private-source guards pin all 19 stable tag bytes, both one-field rooted shapes, the total
  encode/decode/field-count tables, and every request/response transition without exposing a testing seam.

#### Validation

`HandoffSpec` reads the exact hidden source and pins every protocol-v1 tag byte, both rooted outer field
counts, the total encode/decode tables, and every new state transition/refusal without importing or exposing
the private module. The generic codec remains one total implementation, and the phase gate compiles it with
`-Werror`; Phase 17's proof-complete host-static gate owns real-process exercise of the rooted pair.

Dated 2026-08-12 evidence: the combined library/test `-Werror -j1` build passed; `HandoffSpec` passed 68/68;
the public compile-fail boundary passed 452/452; `DocValidatorSpec` passed 2/2; and canonical
`cabal test all --ghc-options=-Werror -j1` passed 1913/1913. `Handoff.Protocol` is 463 significant lines,
17 above its frozen 446-line baseline and well below this sprint's 160-line cap; SHA-256 is
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`. No Cabal row, public export,
named type, runtime importer, or real-process claim was added.

#### Remaining Work

None.

### Sprint 13.9: Rooted payload and child-config binding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 360 lines across three production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Add an exact rooted binding whose transported payload and child configuration have separately framed signed
identities.

#### Deliverables

- New opaque all-nominal `RootedPayloadBinding scope brokerGeneration` is this sprint's sole named type and
  retains separately framed non-empty `payloadDigest` and `childConfigDigest` claims in canonical signed bytes.
- Config signing and verification require both digests to name the same exact received configuration bytes.
  At this sprint's boundary, production recovery signing refuses pending Sprint 13.10. Even after that package
  boundary lands, verification of a rooted recovery value alone establishes only two unequal signed claims;
  package membership and child-config-field admission require the package-aware verified join.
- The rooted codec owns unsigned canonical bytes; the facade signs/verifies its fixed domain only through the
  package-private admission and a live `RootBroker`, with no generic signer or import cycle.
- Existing immediate-edge `HandoffBinding` remains byte-compatible and truthfully binds its one payload; no
  adapter digest is relabelled as a child-config digest before a rooted package exists.
- Source and compile-fail guards pin the two nominal roles, separately framed digest fields, config equality,
  recovery inequality, canonical round trip, constructor hiding, and every cross-binding refusal.

#### Validation

`HandoffSpec` covers canonical binding round trips, exact config-kind equality, recovery claim distinction and
non-admission, signature/domain coverage, legacy-byte stability, and nominal refinement failures through exact
private-source and public cryptographic guards.

Dated 2026-08-12 evidence: the combined library/test `-Werror -j1` build passed; `HandoffSpec` passed 71/71;
the public compile-fail boundary passed 453/453; `ProjectPlanSpec` passed 68/68; `DocValidatorSpec` passed 2/2;
and canonical `cabal test all --ghc-options=-Werror -j1` passed the 1,917-test suite. Production attribution is
309 significant lines against the 360-line budget: `HostBootstrap.Handoff` adds 140 lines,
`HostBootstrap.Handoff.Rooted` adds 169, and `HostBootstrap.Handoff.Internal` adds zero. Frozen SHA-256 values
are `1fd1a7606e05b04fa15295a0502e8b8b7fed8ec8877694fd79c2657356ea9553` for the facade,
`b2ea6e78f665459a70d35db8a054a9f7481d78bb9fad5dae9b98df6de9cfac1c` for the rooted codec,
`c1f780692658e80d79e7e1033ba520a0c7ac684041fd45de1a5849b262d9acd7` for the hidden admission leaf, and
`e51df058db9dfcd1b867461bdee2f1d5f69c5b2af065bd652daaaa819736ee55` for the Cabal file.

#### Remaining Work

None.

### Sprint 13.10: Canonical recovery child package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Recovery.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`
**Production budget**: at most 320 lines across two production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Define the bounded recovery child package and join it to the exact authenticated recovery edge as a neutral
lower layer independent of the receiver and catalog producer.

#### Deliverables

- New opaque `RecoveryChildPackage` is this sprint's sole named type. Its neutral hidden module owns exactly
  the canonical two-frame `{non-empty child config bytes, non-empty adapter bytes}` value; complete canonical
  bytes are at most 8 MiB, and strict decode requires canonical rerender while refusing wrong cardinality,
  empty, oversized, truncated, or trailing input. The public facade exposes the abstract value and renderer,
  not a constructor, parser, or field eliminator.
- Sprint 13.9's config signer and verifier remain additive and exact, with their existing signature and equal
  payload/config requirement. A distinct `signRecoveryChildPackageBindingKernel` consumes the package-private
  recovery-signing capability, a live `RootBroker`, the exact recovery `HandoffOffer`, and one
  `RecoveryChildPackage`; it accepts no separately caller-supplied config bytes or digest pair.
- The facade derives `payloadDigest` from the offer's exact complete package bytes and `childConfigDigest`
  from the package's exact extracted configuration, exact-matches those bytes to the canonical package, and
  refuses a non-recovery edge or any independently chosen payload/config pair before signing.
- `withVerifiedRecoveryChildPackage` requires the already-authenticated `VerifiedHandoff` and treats its
  supplied opaque `RootedPayloadBinding` as untrusted signed data. It rerenders and cryptographically
  reverifies those canonical bytes against that exact handoff and its installed project key before decoding
  the package only from the already-authenticated payload, recomputing both digests, exact-matching the
  immediate edge and complete package, and exposing the two fields inside the successful continuation.
  Package bytes or either signed value alone admit nothing and grant no lifecycle, store, or signing authority.
- This sprint adds no receiver carrier or application producer: Sprint 13.13 adopts the inseparable recovery
  branch in the scope-first receiver, while Sprint 17.30 owns the one real catalog-derived package-production
  call site. Cabal metadata and tests do not count as production owners or against the two-module budget.

#### Validation

`HandoffSpec` covers the exact two-frame shape, non-empty fields, the complete 8 MiB bound, canonical round
trips, strict decoder failures, and constructor hiding. Its public cryptographic matrix proves that the
package-aware join reverifies supplied rooted bytes and refuses the wrong handoff, rooted binding, package
shape, digest, payload kind, signer, or cross-paired package. Because this sprint deliberately has no package
producer, the hidden recovery-package signer has no runtime call site: exact source/DAG guards pin that it
derives both claims from one offer/package, while runtime and compile-fail checks pin strict hidden-capability
application. The same guards pin one new type, the two production owners, the hidden codec boundary, and zero
receiver or catalog call sites.

Dated 2026-08-12 evidence: the production library and combined library/test `-Werror -j1` builds passed;
`HandoffSpec` passed 73/73; the public compile-fail boundary passed 455/455; `ProjectPlanSpec` passed 68/68;
`DocValidatorSpec` passed 2/2; an independent security audit passed; and canonical
`cabal test all --ghc-options=-Werror -j1` passed all 1,921 tests. Production attribution is 179 significant
lines against the 320-line budget: `HostBootstrap.Handoff` adds 101 lines and
`HostBootstrap.Handoff.Recovery` adds 78. Frozen SHA-256 values are
`c8d33baf1cf5fc3825f2eb1f983a6af4f91e85a65ee9dd0793e65ff59c535210` for the facade,
`15244530789cfe080ff84c543881158422143758cf9e15885ad47f08839424d1` for the recovery codec, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877` for the Cabal file.

#### Remaining Work

None. Sprint 13.13 owns receiver-carrier adoption; Sprint 17.30 owns the catalog-derived production call site.

### Sprint 13.11: Authenticated root scope [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 300 lines in one production module
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Define the root-signed primitive that authenticates an exact Production or Harness scope without claiming
Offer, receiver, route, or edge integration.

#### Deliverables

- New opaque nominal `AuthenticatedRootScope scope` is this sprint's sole named type. Its strict canonical
  wire has exactly seven frames: inner codec domain, fixed Word64BE version 1, installed project name, closed
  `production | harness` discriminator, exact run field, installed verification-key digest, and a fixed
  64-byte Ed25519 signature; Production requires an empty run and Harness requires a canonical non-empty run.
- The sole producer consumes a matching `HandoffScope scope` and live `RootBroker scope brokerGeneration verb`,
  derives every field, and accepts no caller-supplied project, kind, run, key digest, signature domain, store,
  generation, verb, Offer, or edge. It signs `frame(hostbootstrap/authenticated-root-scope/v1) <>
  frame(keyDigest) <> frame(canonical unsigned first-six frames)`.
- The verifier consumes an `InstalledProjectIdentity projectId`, independently installed
  `ProjectVerificationKey`, and raw capsule bytes; it enforces total/per-field bounds, exact cardinality and
  canonical rerender, local project/key equality, the closed kind/run relation, and the signature before a
  callback can observe authenticated scope.
- Its closed fold yields `AuthenticatedRootScope (Production projectId)` plus the matching Production
  `HandoffScope`, or introduces fresh `forall runId. AuthenticatedRootScope (Harness projectId runId)` plus the
  matching received Harness `HandoffScope`. Verified run text never mints `HarnessAuthority`, and no
  caller-fixed `runId` parser or result-polymorphic escape exists.
- The capsule proves only project scope and installed-key identity. It has no `brokerGeneration` index and
  grants no Offer, edge, payload, root/Harness-root, command, store, lifecycle, relay, or signing authority;
  Relay/Receiver placement is exclusively Sprint 13.12 and the Phase 19 call site supplies live Harness
  producer evidence.

#### Validation

`HandoffSpec` and compile-fail fixtures cover both scope kinds; exact seven-frame bytes; wrong project, key,
run, kind, domain, and version; cross-key and cross-scope substitution; malformed, oversized, truncated, and
trailing bytes; expired-broker refusal; constructor/coercion refusal; absence of a caller-fixed parser; and
rank-2 Harness escape. The public runtime matrix uses no private import or testing signer seam.

Dated 2026-08-12 production/API evidence: `HostBootstrap.Handoff` is the sole production owner and adds
205 significant lines against the 300-line budget. Its public facade exposes the abstract
`AuthenticatedRootScope`, `renderAuthenticatedRootScope`, the hidden-capability live-broker
`signAuthenticatedRootScopeKernel` producer, and the closed rank-2
`withAuthenticatedRootScopeFromWire` verifier/fold. `HostBootstrap.Handoff.Protocol`,
`HostBootstrap.Handoff.Relay`, and `HostBootstrap.Handoff.Receiver` have zero production delta for this
sprint, and the existing four-field `Offer` is unchanged and has not adopted the capsule. An independent
security audit passed. The frozen `HostBootstrap.Handoff` SHA-256 is
`89cd5a7a9e08c5742abdc0419cf169cff1bb2ac46b64d177b141583abcc15239`.

Dated 2026-08-12 validation evidence: the combined library/test warning-clean build passed;
`HandoffSpec` passed 76/76; the public compile-fail boundary passed 457/457; `ProjectPlanSpec` passed 68/68;
and `DocValidatorSpec` passed 2/2. Canonical
`cabal test all --ghc-options=-Werror -j1` passed 1,926/1,926 tests in 397.84 seconds.

#### Remaining Work

None. The capsule remains Handoff-only at this boundary; Relay/Receiver/Offer adoption is exclusively Sprint
13.12 work.

### Sprint 13.12: Scope-first receiver adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 400 lines across three production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Adopt the Offer's authenticated scope prelude as the first semantic boundary of the in-binary receiver.

#### Deliverables

- A root `BrokerLink` retains the exact live-broker-produced scope capsule; every relayed link retains and
  forwards only those same root-issued canonical bytes, with no capsule signer, project signing key, or route
  for minting a different scope.
- Protocol keeps the existing outer `OfferTag` shape byte-compatible at exactly four bounded opaque fields:
  payload, token, binding, and authentication. It may structurally bound and split all four before capsule
  verification, but performs no binding/payload semantic parse and adds no tag, field, or `Protocol.hs` change.
- `withReceivedHandoffEdge` accepts installed project identity and the independently installed key instead of
  a caller-created `HandoffScope`; it opens only the authentication field's leading capsule, verifies it, and
  enters the closed rank-2 Production/Harness fold before semantically parsing binding or payload.
- Inside that scope continuation the receiver exact-matches the remaining Offer fields, mints the fresh
  challenge locally, verifies the grant with the same installed key, and then preserves the existing closed
  config/recovery classification. Sprint 13.13 solely owns rooted-binding and `RecoveryChildPackage` carrier
  adoption.
- `BrokerLink` and `ReceivedEdge` retain the exact authenticated capsule for descendant/recovery comparison;
  every refusal is sent before return, diagnostics remain on `stderr`, protocol bytes alone use `stdout`, and
  neither scope nor broker-generation evidence escapes its continuation.

#### Validation

`HandoffSpec` covers the unchanged four-field outer shape, strict leading-capsule cardinality, wrong
scope/project/run/key, root-versus-relay capsule identity, replay, semantic binding/payload use before scope
verification, refusal delivery, and rank-2 escape through public cryptographic behavior plus exact
private-source/ownership guards. It pins that Protocol performs structural bounding only and has zero delta.
The recursive-lifecycle-command phase owns the first real relaunched-child consumer and process fixture.

Dated 2026-08-12 production/API evidence: the three production owners add 100 significant lines against the
400-line budget: `HostBootstrap.Handoff.Relay` adds 16, `HostBootstrap.Handoff.Receiver` adds 76, and
`HostBootstrap.Handoff.Receiver.Internal` adds 8. This sprint adds no named type. The private
`rootBrokerLink` now consumes the matching `HandoffScope` and mints the one root-issued capsule before
constructing a link; a relayed link copies only the capsule retained by its authenticated parent edge.
`withReceivedHandoffEdge` now consumes the independently installed identity and key and exposes only the
closed Production-config, Production-recovery, Harness-config, and Harness-recovery fixed-unit continuations
after scope verification. `ReceivedEdge` retains the exact typed capsule beside its verified ordinary edge.
The Handoff facade, Protocol, and Cabal file are frozen at their Sprint 13.11 bytes, and the existing
four-field Offer remains unchanged. An independent security audit passed.

Dated 2026-08-12 validation evidence: the combined library/test `-Werror -j1` build passed;
`HandoffSpec` passed 79/79; the public compile-fail boundary passed 457/457; `ProjectPlanSpec` passed 68/68;
`DocValidatorSpec` passed 2/2; and canonical `cabal test all --ghc-options=-Werror -j1` passed 1,929/1,929
tests in 397.18 seconds. Frozen SHA-256 values are
`d940f18d34f086447d4c6c5a61b48eae92e22b1bd5f24f6d0bd4c34309d488a5` for Relay,
`bdc76856fcf8a1aeaedf512cf84a44cb2ccb4454b7a68a78e4bf88feab2e1ea9` for Receiver, and
`5f6bb3b569ee73b5a391b21ac08965e66bb5e71a4c4e1450cba57b66b178ae13` for Receiver.Internal. The frozen
Handoff, Protocol, and Cabal SHA-256 values remain
`89cd5a7a9e08c5742abdc0419cf169cff1bb2ac46b64d177b141583abcc15239`,
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877`, respectively.

#### Remaining Work

None. Sprint 13.13 owns rooted-binding and recovery-package carrier adoption; Phase 17 retains ownership of
the first real-process receiver fixture.

### Sprint 13.13: Rooted carrier and recovery-package receiver adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 400 lines across three production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Adopt one lower post-open rooted-proof carrier so config and recovery branches expose bytes only after their
exact signed binding and package-aware join, without constructing a real production recovery package.

#### Deliverables

- The unchanged four-field Offer's nested authentication value has strict closed shapes: config carries exact
  capsule/key/rooted fields; recovery carries exact capsule/key/rooted/projection/grant fields. Relay and
  Receiver enforce a 7 MiB embedded Offer-payload sub-ceiling. That sub-ceiling is not a whole-frame guarantee:
  Protocol's authoritative 8 MiB total-body check may still refuse after the other Offer fields and framing
  overhead are included. Wrong size, cardinality, trailing bytes, kind, signer, edge, or cross-paired proof
  refuses before branch exposure.
- The one private carrier requests rooted signing only after an exact `HandoffOffer` exists. Its root route uses
  the already-installed package-private signing kernel and live broker; a nested link relays canonical signing
  request/response bytes only and receives no signing capability. Config admission preserves identical
  payload/config bytes, while recovery uses the package-aware verified join so neither rooted signed data nor
  package bytes alone exposes either package field.
- `ReceivedRecoveryDescent` retains the exact `ReceivedEdge`, verified `RootedPayloadBinding`, opaque
  `RecoveryChildPackage`, closed verb, typed `RecoveryProjectionBinding`, typed `RecoveryWireGrant`, and
  `VerifiedRecoveryWire`. Its existing six-argument eliminator derives the package bytes, authenticated adapter,
  rendered projection, and grant signature from those retained values; it accepts no independently supplied raw
  adapter, projection, or grant.
- This lower sprint produces no real recovery package and composes none on the reverse route:
  `RecoveryAdmission` authenticates only the extracted adapter, while Sprint 17.30's catalog-backed
  `EdgeAdmission` owns the complete package configuration
  and payload digest before the exact Offer is routed to the installed root signer.
- Work remains one private offer/receive carrier adoption across the three named production owners, adds no
  named type or application producer, and grants no signer, store, journal, cursor, command, or lifecycle
  authority. Sprint 17.30 remains the sole real catalog-derived package producer.

#### Validation

`HandoffSpec` covers lower config and package-aware recovery success; exact nested cardinalities; the stricter
7 MiB embedded-payload sub-ceiling and the independent authoritative Protocol total-body refusal; wrong capsule,
key, rooted binding, projection, grant, payload kind, package, config field, adapter, signer, edge, and
cross-pairing; strict package failures; relayed exact-byte signing; severed-route refusal; and no callback
before every join. Exact source/ownership guards
pin three production owners, one carrier adoption, no new type or public signer, `RecoveryAdmission`'s
adapter-only responsibility, and zero catalog/application producers. Phase 17 owns the first real
package-producing process fixture.

Dated 2026-08-12 production/API evidence: the three production owners add 145 significant lines against the
400-line budget: `HostBootstrap.Handoff.Relay` adds 119, `HostBootstrap.Handoff.Receiver` adds 9, and
`HostBootstrap.Handoff.Receiver.Internal` adds 17. The sprint adds no named type or real package producer.
An independent security audit passed.

Dated 2026-08-12 focused validation evidence: the serialized combined library/test `-Werror -j1` build passed;
`HandoffSpec` passed 82/82 in 22.71 seconds; the public compile-fail boundary passed 457/457 in 107.53
seconds; `ProjectPlanSpec` passed 68/68 in 12.73 seconds; and `DocValidatorSpec` passed 2/2 in 0.25 seconds.
Canonical `cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all 1,932 tests in
402.38 seconds; the suite passed.
Frozen SHA-256 values are
`bf577a55a33c76e4636a9b80019adc31988831990d0261f1bbb3bf5036ba2457` for Relay,
`47d1b8826240bc15bf85561292af77fb8f9a615a417db6b44ceba1531c7316fc` for Receiver, and
`b3720a38158b963f2b7aa63a96b20658ffde57cda42efda8ec6df39d8d48cad8` for Receiver.Internal. The unchanged
Handoff, Protocol, Rooted, Recovery, Handoff.Internal, and Cabal SHA-256 values remain
`89cd5a7a9e08c5742abdc0419cf169cff1bb2ac46b64d177b141583abcc15239`,
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`,
`b2ea6e78f665459a70d35db8a054a9f7481d78bb9fad5dae9b98df6de9cfac1c`,
`15244530789cfe080ff84c543881158422143758cf9e15885ad47f08839424d1`,
`c1f780692658e80d79e7e1033ba520a0c7ac684041fd45de1a5849b262d9acd7`, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877`, respectively.

#### Remaining Work

None. Sprint 17.30 retains ownership of the first catalog-derived recovery-package producer and real
package-producing process fixture.

### Sprint 13.14: Closed rooted lifecycle request [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 340 lines in one production module
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Define the complete bounded request vocabulary for the later storeless frame-executor exchange with the root
coordinator.

#### Deliverables

- The existing hidden `HostBootstrap.Handoff.Rooted` module adds one non-indexed opaque
  `RootedLifecycleRequest` with exactly the closed variants `OpenFrame`, `NextNode`, `SettleNode`,
  `DescendResult`, `CloseFrame`, and `ReceiptConfirm`; `Rooted.hs` is the sole production owner and Protocol
  has zero byte/line delta.
- `OpenFrame` has exactly four top-level length-delimited frames: domain
  `hostbootstrap/rooted-lifecycle-request`, canonical Word64BE version 1, discriminator `open-frame`, and an
  exact 32-byte nonce. It carries no requester path, session, stage, ordinal, predecessor-response digest,
  observation, descent result, or caller-selected verb.
- `NextNode`, `CloseFrame`, and `ReceiptConfirm` have exactly nine top-level frames: the same domain/version,
  exact discriminator and path, non-empty session and stage, nonzero Word64BE ordinal, exact 32-byte nonce,
  and exactly 64 lowercase hexadecimal bytes for the digest of the exact complete prior canonical signed
  response field. Their discriminators are `next-node`, `close-frame`, and `receipt-confirm`; `SettleNode`
  and `DescendResult` use `settle-node` and `descend-result` and append one non-empty opaque observation or
  descent-result wire as a tenth frame.
- A post-open requester path is one to 256 nested non-empty UTF-8 component frames, each at most 4,096 bytes,
  in root-nearest-to-leaf Relay order: the first component is the exact child admitted by the serving root or
  hop and the last is the originating requester/current parent. Session and stage are root-issued opaque UTF-8
  tokens echoed byte-exact and each at most 4,096 bytes; a complete request is at most 7 MiB and an opaque
  observation/result field at most 6 MiB.
- Strict decode requires exact canonical rerendering and no trailing bytes, and rejects unknown variants,
  cardinality, encoding, emptiness, zero ordinal, digest, nonce, path, and size violations. The existing
  singleton `RootedLifecycleRequestTag` field and Protocol's independent 8 MiB total-body bound remain
  byte-for-byte frozen. The opaque tenth frame gains no semantic claim here: Sprint 13.17 uses the sealed
  external requester envelope as `OpenFrame` ancestry and structurally checks intermediate suffixes and root
  equality. Phase 17 resolves that path against authenticated scope/runtime/catalog/session before mutation
  and owns retained-session equality, typed-body canonicality/admission, session/stage meaning, freshness,
  ordinal derivation, predecessor correspondence, ordering, and replay.

#### Validation

Three `HandoffSpec` source-guard cases cover all six exact discriminators, the exact 4/9/10 top-level
cardinalities, nested root-nearest-to-leaf requester-path order, every scalar and total bound, canonical
rerender/no trailing bytes, and malformed/unknown/cross-variant refusal branches. They inspect the exact hidden
source without importing or executing the codec. Source and import guards pin the single hidden owner, frozen
Protocol bytes, non-indexed type, closed fold, and absence of authority, protected-store, cryptography,
command, generic storage operations, a testing companion, or semantic/process/durable importers. Sprint 13.17
adds the sole neutral Receiver-internal path fold for Relay transport.

Dated 2026-08-12 production/API evidence: `HostBootstrap.Handoff.Rooted` is the sole production owner and has
504 significant lines. The request adds 335 lines to the frozen 169-line rooted-binding owner, within the
340-line budget. The sprint adds no other production owner or runtime seam, and an independent security/source
audit passed. Its frozen SHA-256 is
`45ca89f24b43cbf4b02e2d82186e8c33db5e2aaedb6978d2111e039ae6933281`. The unchanged Handoff, Protocol, and
Cabal SHA-256 values remain
`89cd5a7a9e08c5742abdc0419cf169cff1bb2ac46b64d177b141583abcc15239`,
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877`, respectively.

Dated 2026-08-12 focused validation evidence: the serialized combined library/test `-Werror -j1` build passed
in 41.85 seconds; `HandoffSpec` passed 85/85 in 23.54 seconds (42.67 seconds wall); the public compile-fail
boundary passed 457/457 in 107.68 seconds (107.75 seconds wall); and `ProjectPlanSpec` passed 68/68 in 12.55
seconds (12.63 seconds wall).
Canonical `cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all 1,935 tests in
404.84 seconds; the suite reported PASS.

#### Remaining Work

None. This sprint intentionally adds no hidden runtime/testing seam; Sprint 13.17 owns transport through the
already-reserved singleton outer field.

### Sprint 13.15: Closed rooted lifecycle response [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 280 lines in one production module
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Define the complete bounded neutral response vocabulary paired structurally with one rooted request.

#### Deliverables

- The existing hidden `HostBootstrap.Handoff.Rooted` module adds this sprint's sole named contract: one
  non-indexed opaque `RootedLifecycleResponse` with exactly the closed variants `Opened`, `Prepared`,
  `Descend`, `Settled`, `FrameComplete`, `ReceiptRecorded`, and `Refused`; their exact discriminators are
  `opened`, `prepared`, `descend`, `settled`, `frame-complete`, `receipt-recorded`, and `refused`.
- `Opened` has exactly nine top-level frames: domain `hostbootstrap/rooted-lifecycle-response`, canonical
  Word64BE version 1, discriminator, 64 lowercase hexadecimal bytes for the digest of the exact canonical
  `OpenFrame` request, the nested admitted requester path, non-empty session and stage, a nonzero Word64BE next
  ordinal, and an exact 64-byte signature. Every other response has exactly eleven: the same first four,
  canonical path, session, response stage, response ordinal, exact 32-byte request nonce, one body, and the
  signature. Path has one to 256 non-empty UTF-8 components of at most 4,096 encoded bytes; session and stage
  are non-empty UTF-8 of at most 4,096 bytes.
- The one post-open body is at most 6 MiB. `Prepared` is exactly four nested non-empty frames for node,
  dependencies, operation gate, and projected gates, each at most 6 MiB and together at most 6 MiB;
  `Descend`/`Settled` are non-empty opaque bytes; `FrameComplete` is a non-empty lifecycle-report wire;
  `ReceiptRecorded` is exactly the 64-lowercase-hex digest of the matching `FrameComplete`; and `Refused` is
  non-empty UTF-8 of at most 4,096 bytes. The complete response is at most 7 MiB.
- The neutral exact-pair check accepts only `OpenFrame -> Opened`, `NextNode -> Prepared | Descend | Refused`,
  `SettleNode | DescendResult -> Settled | Refused`, `CloseFrame -> FrameComplete | Refused`, and
  `ReceiptConfirm -> ReceiptRecorded | Refused`; it checks the exact request digest, post-open path/session/
  nonce echo, and receipt-body/predecessor equality. An `OpenFrame` failure uses Protocol's existing outer
  `Refused`, never a rooted `Refused`; response stage and ordinal are structurally valid successor coordinates,
  not copies of the request coordinates.
- Exactly seven checked unsigned builders return only canonical `ByteString`; the separate private
  `rootedLifecycleResponseFromUnsignedKernel` strict-decodes those unsigned bytes and attaches an exact 64-byte
  signature. Strict signed decode/render and one closed total fold enforce canonical rerender,
  scalar/body/total bounds, and no trailing bytes without a caller-supplied signature-placeholder builder,
  lifecycle meaning, or lifecycle-report validation. The resulting opaque response is descriptive signed data,
  not authority, and may be retained as an ordinary value. No cryptography, Handoff facade, store, process,
  testing companion, or semantic/process/durable importer enters this neutral owner; Sprint 13.17 adds only
  the neutral Receiver-internal pair/path folds. Protocol and Cabal remain byte-for-byte frozen, and Phase 17
  alone assigns body semantics, lawful successors, freshness, terminality, and replay.

#### Validation

Exactly three `HandoffSpec` source-guard cases pin all seven discriminators, exact 9/11 cardinalities, every
scalar/body/total bound, canonical rerender/no trailing bytes, the four-field nested `Prepared` body, seven
unsigned builders plus the sole signature-attaching kernel, absence of a signature-placeholder builder, the exact
request-family matrix, path/session/nonce echo, receipt/predecessor equality, outer-only open refusal, the
closed fold, single neutral owner, one-type budget, and absence of authority, cryptography, facade, storage,
testing-companion, or semantic/process/durable imports. Phase 17 owns semantic report/body, ordering, and
durable replay tests.

Dated 2026-08-12 production/API evidence: `HostBootstrap.Handoff.Rooted` remains the sole production owner
and has 754 significant lines. The response adds 250 lines to the frozen 504-line request/binding owner, within
the 280-line budget. The sprint adds no other production owner or runtime seam, and an independent
security/source audit passed. Its frozen SHA-256 is
`c035f05ec6c0951165d9141c8d6fccd1ce45b00266f88e5d9753dbbdf618460e`.

Dated 2026-08-12 focused validation evidence: the direct hidden-module warnings-as-errors compile and the
serialized combined library/test warnings-as-errors build passed; `HandoffSpec` passed 88/88 in 25.63 seconds;
the public compile-fail boundary passed 457/457 in 107.86 seconds; and `ProjectPlanSpec` passed 68/68 in 13.18
seconds. `DocValidatorSpec` passed 2/2 in 0.26 seconds. Canonical
`cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all 1,938/1,938 tests in 401.83
seconds; the suite reported PASS.

#### Remaining Work

None. Sprint 13.16 owns cryptographic signing/verification, Sprint 13.17 owns transport, and Phase 17 owns
response production and semantics.

### Sprint 13.16: Rooted lifecycle response signing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 180 lines across three production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Authenticate one structurally paired rooted response through the live root broker and independently installed
project key.

#### Deliverables

- This sprint adds no named type: the Handoff facade signs and verifies Sprint 13.15's exact
  `RootedLifecycleResponse`, while `Handoff.Rooted` remains the sole structural owner and Protocol/Cabal remain
  byte-for-byte frozen.
- The signer has the fixed kernel shape `RecoverySigningKernel -> RootBroker ... -> ByteString -> ByteString ->
  IO (Either HandoffError RootedLifecycleResponse)`: its byte arguments are the exact request and canonical
  unsigned response. Under the live broker it strict-decodes both, repeats the neutral exact-pair check,
  validates the response body owned by this layer, signs, and attaches the real signature through
  `rootedLifecycleResponseFromUnsignedKernel`; no typed or raw placeholder-signature builder, generic unsigned
  renderer, arbitrary-message signer, callback, or caller-selectable domain/material is exposed.
- The signature transcript is exactly a frame of fixed domain
  `hostbootstrap/rooted-lifecycle-response/v1`, a frame of the live broker's installed verification-key digest,
  a frame of the exact complete canonical request, and a frame of the exact complete canonical unsigned
  response. Signing requires the matching live `RootBroker`; verification requires the independently installed
  project identity/key and exact request, then repeats canonical decode, request pairing, and signature checks.
- The facade requires `FrameComplete`'s body to pass the existing canonical lifecycle-report verifier before
  signing. Its installed-key verifier has the fixed key -> exact-request bytes -> complete-signed-wire -> CPS
  shape: it strict-decodes and structurally pairs first, verifies the exact transcript next, validates the
  `FrameComplete` report last, and only then enters the fixed response fold. The lower `Prepared`, `Descend`, and `Settled` bodies remain
  opaque until Phase 17, while `ReceiptRecorded`/`Refused` retain Sprint 13.15's exact digest/text rules.
- `Handoff.Internal` only specializes the existing unconstructible `RecoverySigningKernel` for this fixed
  response signer. No second capability, signing key, root broker, signature-attaching constructor, or semantic
  lifecycle authority escapes; an opaque response remains descriptive signed data. Phase 17 alone owns
  production, successor law, settlement, receipt mutation, and replay.

#### Validation

Exactly three `HandoffSpec` cases cover public installed-key/domain verification and exact-request pairing,
every signature/request/family/body cross-pair and canonical-report refusal, and exact source/ownership guards
for the live-broker signer, specialized existing capability, no new named type, no generic unsigned/signing
surface, frozen Protocol bytes, frozen handoff package rows, three production owners, and the 180-line
budget. The package rows are this phase's own — its module rows in the main library, plus that library's
dependency set — rather than the whole package description, because a sprint freezes what it owns (§ C).

Dated 2026-08-12 production/API evidence: the response-authentication additions to the public facade are
exactly the abstract `RootedLifecycleResponse`, `renderRootedLifecycleResponse`, the fixed
`signRootedLifecycleResponseKernel :: RecoverySigningKernel -> RootBroker ... -> ByteString -> ByteString ->
IO (Either HandoffError RootedLifecycleResponse)` signer, and
`withVerifiedRootedLifecycleResponse :: ProjectVerificationKey -> ByteString -> ByteString ->
(RootedLifecycleResponse -> result) -> Either HandoffError result`. The signer fixes the transcript to framed
domain `hostbootstrap/rooted-lifecycle-response/v1`, installed verification-key digest, exact complete
canonical request, and exact complete canonical unsigned response. The verifier independently parses and
pairs, verifies that transcript, validates a `FrameComplete` lifecycle report, and only then enters its fixed
CPS continuation. The value remains descriptive signed data rather than authority. The signer has no
production runtime caller; Sprint 13.17's originating typed Relay operation is the verifier's sole production
transport caller. An independent security/source audit passed.

The exact production delta is 139/180 significant lines: `HostBootstrap.Handoff` +126,
`HostBootstrap.Handoff.Internal` +13, and the frozen structural owner `HostBootstrap.Handoff.Rooted` +0. Their
respective frozen SHA-256 hashes are
`6bbbd828b453173cf8f4be9cd1989eb0a6ddfc2cc5a9639b29d76558c0121fe5`,
`305dc09a9e9ae617161f0b7ec35309aeb31d0152894988a8bc53f415cebca2bf`, and
`c035f05ec6c0951165d9141c8d6fccd1ce45b00266f88e5d9753dbbdf618460e`. Protocol and Cabal remained
byte-for-byte frozen at `c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8` and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877` respectively.

Dated 2026-08-12 focused validation evidence: the serialized combined library/test warnings-as-errors build
passed; `HandoffSpec` passed 91/91 in 27.91 seconds; the public compile-fail boundary passed 457/457 in
106.40 seconds; and `ProjectPlanSpec` passed 68/68 in 12.98 seconds. `DocValidatorSpec` passed 2/2 in 0.26
seconds. Canonical `cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all
1,941/1,941 tests in 403.54 seconds; the suite reported PASS.

#### Remaining Work

None. Sprint 13.17 owns the first transport adopter; Phase 17 owns all durable semantics.

### Sprint 13.17: Rooted duplex relay adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Production budget**: at most 390 lines across two production modules
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Adopt the closed rooted request/response bytes in the existing admitted package-private duplex relay as a
transport-only contract. This sprint constructs no recursive child and completes no successful rooted process
exchange.

#### Deliverables

- The admitted package-private serve loop carries one exact rooted request or response as the singleton field
  of the already-reserved outer tag; `HostBootstrap.Handoff.Protocol` remains byte-for-byte frozen.
- Each hop prepends only its already-admitted requester component to a sealed external envelope in
  root-nearest-to-leaf order while preserving the inner request bytes. The envelope has one to 256 non-empty
  UTF-8 components of at most 4,096 encoded bytes each and is rejected before forwarding when that grammar
  fails. For `OpenFrame`, whose inner value contains only its nonce, this envelope is the sole ancestry input.
- One outstanding request alternates with one structurally paired response across every hop. Transport checks
  the strict canonical inner shape, exact request/response family and request binding, then returns the same
  inner bytes without interpreting a response body, signature, session token, stage, ordinal, predecessor, or
  lifecycle meaning.
- The existing outer `Refused` and an exact signed rooted `Refused` are distinct uninterpreted transport
  outcomes: a relay never translates, constructs, or re-signs either one. The Phase 13 root endpoint performs
  structural validation but remains unavailable, so every rooted request that reaches it returns the existing
  outer `Refused` until Sprint 17.36 installs the root service.
- An intermediate relay holds no project signing key, `RootBroker`, protected store, root catalog, retained
  session path, session constructor, lifecycle authority, request/response constructor, semantic
  freshness/replay/receipt decision, or process owner. Phase 17 owns root response production, fixed-signer
  invocation, semantic session-path comparison, durable replay and receipt ordering, storeless execution,
  recursive call-site adoption, and the first real-process rooted exchange. This sprint adds no named type, public export, Cabal
  row, command caller, or process caller.

#### Validation

`HandoffSpec` pins singleton outer fields, bounded requester-envelope construction, exact inner-byte
preservation, structural family/request pairing, one-request/one-response alternation, the unavailable root
endpoint, and uninterpreted refusal propagation without importing the hidden module. The public
compile-fail boundary retains `ImportHandoffRelay.hs`; private-source guards prove no relay-to-signer,
relay-to-store, semantic, durable, process, or recursive-command route exists. Run focused `HandoffSpec`, the
public compile-fail boundary, `ProjectPlanSpec`, and `DocValidatorSpec`, then the canonical warnings-as-errors
`-j1` phase gate. Phase 17 owns every real-process rooted fixture.

Dated 2026-08-12 production/API evidence: the transport adds exactly 275/390 significant lines across the two
declared owners. `HostBootstrap.Handoff.Relay` grows by 227 lines from 1,852 to 2,079 and has SHA-256
`d751ce667d2b7e4871628028f3765954942d96d2a8c5017e87c90fb784d55006`;
`HostBootstrap.Handoff.Receiver.Internal` grows by 48 lines from 122 to 170 and has SHA-256
`0a481b39e02ef02f4e1c4e47ca306794e8727ff8e15f2baae6d579e6554a2834`. The frozen Handoff facade,
neutral Rooted owner, Protocol, and Cabal file remain respectively
`6bbbd828b453173cf8f4be9cd1989eb0a6ddfc2cc5a9639b29d76558c0121fe5`,
`c035f05ec6c0951165d9141c8d6fccd1ce45b00266f88e5d9753dbbdf618460e`,
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877`. The carrier adds no named type,
public export, Cabal row, semantic caller, process caller, signer, broker, store, catalog, or retained session
path. An independent transport/security/source audit passed.

Dated 2026-08-12 focused validation evidence (aarch64-osx, GHC 9.12.4): the serialized combined library/test
warnings-as-errors build passed; `HandoffSpec` passed 94/94 in 28.61 seconds; the public compile-fail boundary
passed 457/457 in 106.11 seconds; `ProjectPlanSpec` passed 68/68 in 12.80 seconds; and `DocValidatorSpec` passed
2/2 in 0.26 seconds. Canonical `cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all
1,944/1,944 tests in 395.84 seconds; the suite reported PASS.

#### Remaining Work

None. Protocol remains frozen, this boundary validates a rooted request's structure at the root and carries
whatever answer comes back, and which answer a request receives, along with every semantic or process
adopter, is Phase 17 work.

### Sprint 13.18: The frame-child entry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`
**Production budget**: at most 400 significant lines across the owners above
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/build_and_run_model.md`, `documents/README.md`

#### Objective

Let a process of this binary recognize that it is the one on the far side of a frame crossing, so the
channel this phase already frames has an end that can be reached.

#### Deliverables

- One total pure classifier over `argv` decides whether this process is a frame child. It runs before the
  parser, takes no coordinates, and returns a value carrying none: no path, no authority, no
  caller-selected action, and no route to a `ProjectSpec` extension stream (§ P).
- The classifier is the only argv reader outside the parser, and `runCLI` consults it once. The bare
  binary and every project binary use the same route, because a frame child is a frame child regardless of
  which spec built it.
- The marker is absent from `--help`, names nothing an operator could usefully type, and refuses unless
  standard input and output decode as the protocol channel.
- Two tags pair and join the closed vocabulary — one carrying a transaction, one carrying its outcome,
  each with exactly one field — so a frame child speaks the framing this phase already owns rather than a
  second one. Extending the vocabulary is what re-stamps the shared `Handoff.Protocol` digest and line
  count the phase's other sprints pin, and each of those keeps its own attribution by measuring the file
  less what its siblings own (§ C).
- `Handoff.Transaction` brackets a child on a dispatch the lift fold produced, sends one request, reads one
  outcome, and terminates the group. It is compiled on every host and conditionalized at its signal call
  sites, so no host family loses it from the build (§ JJ).
- The child's descriptor isolation is *the* one this phase owns rather than a copy of it: the private-pair
  bracket becomes `Handoff.Protocol`'s single entry, the receiver and the frame child both reach it, and
  the protocol pair is private while the global streams are redirected — so guest bytes cannot forge a
  control report and no report needs encoding to prevent it.
- Phase 13 interprets no transaction. A frame with no interpreter installed answers a refusal on the wire
  rather than falling silent, and the near side's answer reader is a total function of the request it must
  answer and the answer it received, so an outcome, a refusal, and a reply to another request are three
  decisions rather than one branch reachable only by launching a process (§ NN).

#### Validation

The classifier is total and is covered exhaustively over its argument space, including every shape that
must **not** be a marker. A source guard pins `runCLI`'s exact argv-reading body, so a second reader is a
gate failure rather than a review note. The child body is exercised across a real process boundary through
the suite's own re-invocation route.

Stated honestly: the seam between "argv was classified" and "the child body ran" is proved by source shape
rather than by execution, because the suite executable's own `main` is not `runCLI`. The
[recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) proves the joined path when it
adopts this entry for a lifecycle conversation.

Dated 2026-08-18 production evidence (x86_64-windows, GHC 9.12.4): the entry adds 343/400 significant
lines across its owners and removes 63 from the receiver that now shares the isolation.
`HostBootstrap.Handoff.Transaction` is 275 significant lines with SHA-256
`a79ff17159608e65392de29817ea39e1463ce0832205d13e1f14f39fa94ae8b6`;
`HostBootstrap.Handoff.Protocol` grows by 63 to 526 significant lines and
`HostBootstrap.CLI` by 5 to 451. Their SHA-256 values are
`04f069429b164e3d6b99ff68b900996c090e73947bc5c874859049ce49a696a4` and
`ced91a317786e5c19f05bd14b52b70094fd7180a29774a79e3ee582d1e47d95a`, and
`HostBootstrap.Handoff.Receiver` is `514941f9d28ccb29ab6acb883f5f4797e6552842f9cc5e40c089684415544615`.
The entry names no protected store, broker link, installed identity, signing or verification key, project
spec, command authority, environment lookup, or second argv reader.

Dated 2026-08-18 validation evidence (x86_64-windows 11 Home 10.0.26200, GHC 9.12.4, Cabal 3.16.1.0):
canonical `cabal test all --ghc-options=-Werror` from `core/` passed 1,957/1,957 in 238.84 seconds;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

None. The crossing carries whatever transaction it is given and returns whatever answer comes back;
which transactions exist, and which frame answers them with an outcome rather than a refusal, belong to
the phases that own the objects a transaction concerns.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**

- `documents/architecture/binary_context_config.md` — challenge/grant admission, authenticated scope,
  recovery package, and private duplex transport.
- `documents/architecture/lifecycle_state_model.md` — root-owned coordination, storeless child exchange,
  signed responses, and receipt order.
- `documents/architecture/unrepresentable_state.md` — hidden constructors, rank-2 scope admission, closed
  rooted vocabulary, and keyless relay boundaries.
- `documents/architecture/harness_workflow.md` — the Harness producer of exact run evidence for the generic
  authenticated-scope capsule.

**Engineering docs to create/update:**

- `documents/engineering/build_release.md` — reusable Build authority and its concrete consumer boundary.
- `documents/engineering/config_generation.md` — exact config projection inside config and recovery payloads.
- `documents/engineering/secrets.md` — independently installed project/Build/Activation verification keys
  and the keyless child/intermediary rule.

**Cross-references to add:**

- `development_plan_standards.md` §§ X, Y, EE, and HH name this phase as the owner of authenticated handoff,
  root scope, rooted wire/receipt vocabulary, and keyless relay transport.
- Phase 17 (the recursive lifecycle command) consumes these contracts for root-owned durable coordination and
  storeless frame execution.
- Phase 19 (test harness and run ownership) supplies the exact Harness run evidence consumed by the generic
  authenticated-scope producer.
- Phase 24 (the worked demo) consumes Build authority and confirms the recursive lifecycle on its live
  provider chain.
