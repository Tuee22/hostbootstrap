# Phase 13 — Authenticated handoff and child admission

**Status**: Active
**Depends on**: Phase 12 (the step algebra and the single project plan)
**Substrates**: linux-cpu
**Gate**: `cabal test all -j1` from `core/`, after focused `HandoffSpec`,
public compile-fail boundary, `ProjectPlanSpec`, and `DocValidatorSpec` runs
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate

> **Purpose**: Define the bounded root-authenticated handoff and keyless rooted-transport contracts, and the
> frame-child entry with its one-transaction process bracket. The phase constructs no recursive child and
> claims no successful rooted process exchange.

## Phase Objective

The recursive lifecycle crosses machine boundaries from a host frame into VMs and containers. This phase
defines the authentication and bounded transport contracts used at that boundary. The root coordinator holds
the independently provisioned signing identity, a child issues a fresh challenge and verifies the root's exact
edge grant against the independently installed project key, and intermediate frames can relay canonical rooted
bytes without acquiring a signing key, protected store, or root command authority.

The wire distinguishes transported payload identity from child-configuration identity, authenticates scope
before untrusted bytes can introduce its phantom, and carries recovery config and adapter bytes as one
canonical package. The rooted request/response vocabulary includes the shapes later used by terminal receipt
exchange. The frame-crossing entry lets this binary recognize, before its parser, that it is the far side of
a frame crossing. Its one-transaction bracket launches that child in its own process group, exchanges one
request and one answer over the child's pipes, and ends and reaps the child's process tree. Phase 13 owns
only those authentication, codec, transport, and frame-crossing contracts. Phase 17 (the recursive lifecycle
command) owns the root catalog, retained session path, response production and fixed-signer invocation at
the root endpoint, durable prepare/settle/replay/receipt semantics, storeless frame execution, lifecycle
process ownership, and recursive command adoption. Recursive child construction, a successful rooted process exchange, and the
rooted service the root endpoint runs are that phase's too: this one validates the structure of a rooted
request and carries whatever answer comes back.

## Sprints

### Sprint 13.1: Challenge/grant wire foundation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
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
  invocation. Its grant transcript is `frame("hostbootstrap/handoff-grant") <> frame(Word64BE 1) <>
  frame(installed verification-key digest) <> frame(canonical binding) <> exact token frame <>
  frame(challenge)`; the same broker signs only a fixed, closed set of other domains (rooted payload binding,
  authenticated root scope, rooted lifecycle response, recovery wire), each owned by a later sprint here.
- Child verification consumes the independently installed project verification key and yields only the
  transport-level `VerifiedHandoff scope brokerGeneration` proof; `verifyHandoff` recomputes the payload
  digest and token commitment from the exact received frames. Missing, unreadable, and malformed key files
  are typed `HandoffSigningKeyUnavailable`/`HandoffVerificationKeyUnavailable` refusals, and an asynchronous
  exception raised during the read propagates rather than becoming a key refusal.
- Bounded decoding and sequencing distinguish malformed, truncated, stale, replayed, wrong-edge, and
  wrong-domain inputs before admitting an edge. A body holding bytes beyond a tag's expected field count is
  reported with its tag, expected count, and excess byte count, never as an invented field count.
- `HandoffBinding` exports read-only accessor functions and no record field labels, so code outside
  `HostBootstrap.Handoff` can neither rewrite a signed field by record update nor relabel the `scope` and
  `brokerGeneration` phantoms through a type-changing update.
- The hidden handoff owners (`Handoff.Protocol`, `Handoff.Receiver`, `Handoff.Relay`, `Handoff.Internal`)
  are importable by `hostbootstrap-core-test` and by no consumer package, so their refusals are exercised by
  value while the public compile-fail import fixtures keep refusing consumer imports.

#### Validation

`HandoffSpec` covers signing, exact binding checks, one-use grants, replay refusals, and installed-key
verification. Closure requires these cases to exist and pass under the phase gate:

- A value-level `Handoff.Protocol` table: `decodeProtocolMessage` returns the exact `ProtocolTruncated`,
  `ProtocolBodyTooLarge`, `ProtocolFieldTooLarge`, `ProtocolTrailingBytes`, `ProtocolBadMagic`,
  `ProtocolUnsupportedVersion`, `ProtocolUnknownTag`, `ProtocolZeroRequestId`, and
  `ProtocolWrongFieldCount` constructor for one crafted wire each; `childProtocolReceive` and
  `childProtocolSend` return `ProtocolInvalidTransition` for each illegal (state, tag) pair, including a relay
  request sent from any state other than `ChildRunning`.
- Pure refusal tables for `handoffBindingInputFromWire` (round trip plus each refusal),
  `withHandoffBindingFromWire` over mutated canonical bindings (unknown payload kind, 7-byte generation, empty
  required field, non-UTF-8 field, trailing bytes, another installed project), and `handoffChallengeFromBytes`
  with 31 and 33 bytes.
- The "every caller-bound field changes the rendering" case includes `input{requestedPayloadKind =
  RecoveryAdapterWire}`.
- The redaction case asserts that the offer's token bytes, the 32-byte signing seed, and the verification-key
  bytes appear in no `show` of the offer, broker, or grant in raw, hex, or `show` form, and asserts the
  redaction marker on each value's `show` separately.
- Compile-fail fixtures refuse a record update of a `HandoffBinding` field and a type-changing update that
  relabels its `brokerGeneration` phantom.
- The "empty required field" case sets each required `Text` field of `HandoffBindingInput` to `""` in turn
  (`requestedSpecDigest`, `requestedPlanRevision`, `requestedParentFrame`, `requestedChildFrame`,
  `requestedChildConfigDigest`, and `requestedPhase`) and asserts `HandoffBindingMismatch` with that field's own detail.
- A `verifyHandoff` case rebuilds an otherwise valid offer wire around a different well-formed 32-byte token
  and asserts `HandoffBindingMismatch "the received token does not match the bound token commitment"`.
- An `OfferRequestTag` body carrying one valid field followed by three stray bytes, and one followed by five
  extra frames, each return the excess-bytes `ProtocolError` with the excess byte count rather than
  `ProtocolWrongFieldCount OfferRequestTag 1 2`.
- Every `HandoffSpec` "is absent from Cabal" seam check tests the seam against the module names of every
  Cabal stanza field (comma- and inline-tolerant), not against whole lines equal to the module name.
- `HandoffSpec`'s ordered-fragment check matches over `SourceGuard.haskellTokens` rather than raw
  whitespace-normalized text, and reports the first unmatched fragment. Value-level cases on its pure core
  `fragmentsInOrder :: [String] -> String -> Either String ()` cover three inputs. A fragment `ProjectUp`
  against the source `-- ProjectUp: refused\nx = y` returns `Left "ProjectUp"`. The same fragment against
  `x = "ProjectUp"` also returns `Left "ProjectUp"`, while the quoted fragment `"\"ProjectUp\""` returns
  `Right ()`. Two fragments given in reverse order return `Left` naming the second.

Source and ownership guards remain a structural supplement to these value-level cases.

#### Remaining Work

- Make `Handoff.Protocol`, `Handoff.Receiver`, `Handoff.Relay`, and `Handoff.Internal` importable by
  `hostbootstrap-core-test` only — for example a private Cabal library in the `effect-internal` pattern, or an
  equivalent test-only route — so no consumer package can import them. `ImportHandoffRelay.hs` and the other
  hidden-module import fixtures keep refusing; the `HandoffSpec` guard that requires no runtime test to import
  the hidden owners instead requires that only `hostbootstrap-core-test` does.
- Add the value-level `Handoff.Protocol` decoder and child-state-machine table listed under Validation, one
  case per `ProtocolError` constructor and per illegal (state, tag) pair.
- Stop exporting `HandoffBinding`'s field labels: rename the record fields privately (or make the constructor
  positional) and export plain accessor functions under the current public names. Add compile-fail fixtures
  `UpdateHandoffBindingField.hs` (`b { handoffChildFrame = "elsewhere" }`) and
  `RelabelHandoffBindingGeneration.hs` (`b { handoffPhase = handoffPhase b } :: HandoffBinding scope g'`), each
  refused with the field not in scope.
- Add the binding-input, binding, and challenge parser refusal tables listed under Validation, each asserting
  the exact `HandoffError`.
- Add `requestedPayloadKind` to the rendering-variants list, and strengthen the redaction case as listed under
  Validation.
- Rewrite the "empty required field" case as the per-field traversal listed under Validation, and add the
  substituted-token `verifyHandoff` case.
- `decodeFields` in `Handoff.Protocol`: when the expected fields are consumed and bytes remain, return a new
  `ProtocolExcessFields ProtocolTag Int Int` (tag, expected count, excess byte count) rendered by
  `protocolErrorMessage` without a field count it never measured; add the two excess-body cases listed under
  Validation.
- `installedProjectSigningKey` and `installedVerificationKey` catch `IOException` only (not `SomeException`),
  so asynchronous exceptions propagate; a `HandoffSpec` source guard pins `countHaskellIdentifier
  "SomeException"` at zero in `Handoff.hs`, and the existing missing/unreadable/malformed key cases keep
  passing.
- Replace every whole-line seam check in `HandoffSpec` (a `notElem` over `map (unwords . words) (lines
  cabalSource)`) with one shared helper over the module names of every Cabal stanza field, as listed under
  Validation.
- Rebuild `HandoffSpec`'s `assertFragmentsInOrder` on a pure `fragmentsInOrder`. That function tokenizes the
  source and each fragment with `SourceGuard.haskellTokens`, so comments are dropped and a string literal is
  one token. It then matches each fragment's token sequence as a contiguous run after the previous match, and
  returns `Left` with the first unmatched fragment. `assertFragmentsInOrder` puts that fragment in its failure
  message. Every caller drops its `normalizeWhitespace` argument. A fragment that names a string literal, for
  example `frame-complete` or `receipt-recorded`, is written quoted so it matches only that literal. A fragment
  that names part of a token is rewritten to whole tokens. Add the value-level cases listed under Validation.

### Sprint 13.2: Verified config-handoff refinement [Active]

**Status**: Active
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

`HandoffSpec` covers transport/config separation and the verb refusal ("an up handoff cannot be refined as a
teardown config edge"); `SchemaSpec` covers `verifyHandoff`'s payload-digest refusal and raw-wire refusal.
Compile-fail fixtures pin every nominal and rank-2 mismatch. Closure requires one `HandoffSpec` case per
remaining `withVerifiedConfigHandoff` guard, each asserting `Left (HandoffBindingMismatch detail)` with the
exact detail: a recovery-kind `VerifiedHandoff` ("the authenticated payload is not a project config"), a
mismatched `VerifiedConfigWire` digest ("the handoff and verified config wire digests differ"), a mismatched
`ValidatedConfig` digest ("the handoff and validated config digests differ"), a mismatched specification digest
("the handoff and validated config specification digests differ"), and an unknown phase string ("the handoff
names an unknown lifecycle phase").

#### Remaining Work

- Add the five `withVerifiedConfigHandoff` refusal cases listed under Validation to `HandoffSpec`, each built
  from an otherwise valid verified handoff so that only the named guard can refuse.

### Sprint 13.3: Child-plan authority [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Construct.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Child/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Admit the exact fresh child plan named by a refined config handoff without granting lifecycle execution. The
check that the signed child frame is the frame the admitting binary runs is the recursive lifecycle command
phase's (Phase 17), whose child entry supplies the running frame.

#### Deliverables

- `withChildProjectPlan` consumes one `VerifiedConfigHandoff`, the same verified wire/configuration, and
  non-empty plan drafts.
- Admission verifies the signed stable plan revision, installed project, protected store, scope, broker
  generation, configuration digests, and verb. The specification digest is bound by the
  `withVerifiedConfigHandoff` refinement the admitted `VerifiedConfigHandoff` already passed.
- One rank-2 continuation jointly receives the fresh local `ProjectPlan`, exact `PlanDigestBinding`, and
  fully indexed opaque `ChildPlanAuthority`.
- Child-local plan and configuration identities are generative, and tokens, receipts, and generative
  handles are never serialized as plan authority.
- `ChildPlanAuthority` contains no `ProtectedStore`, acquisition journal, lifecycle cursor,
  `CommandAuthority`, root invocation authority, or signing capability.

#### Validation

`ProjectPlanSpec` covers the stable-plan-digest refusal. Compile-fail fixtures reject construction, escape,
and cross-index substitution. The case "an authenticated config edge jointly admits the exact child plan and
authority" proves admission returned `Right` only: its callback is an `IO ()` of two `@?=` assertions,
`withChildProjectPlan` is pure, and the case binds the resulting inner action to `_` (`_ <- expectRight
configAdmission`), so the `childPlanAuthorityBinding` and stable-plan-digest assertions never run.

`withChildProjectPlan`'s own verb, verified-wire-digest, and validated-config-digest checks cannot refuse for
a well-typed caller: `ProjectVerb verb` is a singleton shared with the refined handoff's `verb` index, the
wire and config share the generative `configId` the refinement already consumed, and
`withVerifiedConfigHandoff` refuses all three mismatches first (Sprint 13.2 owns those runtime cases).

Closure requires these `ProjectPlanSpec` cases to exist and pass under the phase gate:

- The joint-admission case returns the observed pair `(childPlanAuthorityBinding authority,
  stablePlanSnapshotDigest (renderSnapshot childPlan))` out of the callback and compares it with
  `(relayBinding relay, planDigest)` after both admissions return, so dropping the result is a type error.
- A Harness-scoped admission (handoff scope `Harness <run>`) whose admitted child plan's
  `projectPlanProfileName` is exactly `"harness:<run>"`.
- One runtime case per reachable `withChildProjectPlan` refusal, each asserting the exact `AuthorityError`
  text: a plan drafted for another installed project, another protected store, and another broker
  generation.

#### Remaining Work

- Delete the never-constructed `HandoffFrameMismatch` constructor and its message arm from
  `HostBootstrap.Handoff`.
- Add the `ProjectPlanSpec` refusal cases listed under Validation, each built from the existing successful
  admission fixture with exactly one coordinate changed.
- Rewrite "an authenticated config edge jointly admits the exact child plan and authority" so the
  `withChildProjectPlan` callback returns the observed `(binding, plan digest)` pair and the case compares it
  with `@?=` after `expectRight configAdmission`, rather than binding an unrun `IO ()` to `_`.
- Add the Harness-scope admission case listed under Validation, asserting `projectPlanProfileName` is
  `"harness:<run>"` (the `childProfileName` Harness row).

Phase 17 (the recursive lifecycle command) owns coordinator admission and execution of this exact child plan.

### Sprint 13.4: Build invocation authority protocol [Active]

**Status**: Active
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
- The source digest is a function of the tree's regular-file relative paths (as raw platform name bytes,
  joined with `/`) and their bytes only, independent of the measuring root and process locale. Modes, empty
  directories, and symlink-versus-copy are not measured. A non-regular entry (FIFO, socket, device) under the
  source root, or at the builder path, is a typed refusal before any open, never a blocking read.
- The channel decoder bounds every declared frame length as a `Word64` before narrowing it, through
  `Handoff`'s exported `takeHandoffFrame`, so an oversized length is `BuildChannelMalformed`, never an empty
  field.

#### Validation

`BuildAuthoritySpec` covers provisioned-key and signature-domain checks, coordinator lifetime, distinct
non-ASCII filenames, binary measurement, one-use phase consumption, and typed refusals. Its "moving bytes to a
different name" case writes `Renamed.hs` and keeps an emptied `Main.hs`, so the tree gains an entry and a
path-blind digest still passes it. No case measures one tree under two roots, no golden digest exists, no
verification case runs without its builder or source root, and the only malformed-channel case truncates the
signature and accepts any `BuildChannelMalformed`. "A build backend with no channel is Unsupported, not a
fallback" drives only `readBuildChannel`; the no-fallback decision is `check-code`'s in `Command.hs`.

Closure requires these `BuildAuthoritySpec` cases to exist and pass under the phase gate:

- The same nested tree written under two different temporary roots measures equal digests, and a fixed
  two-file tree (`a.hs` = `"x"`, `src/b.hs` = `"y"`) measures a literal golden hex digest.
- The move case deletes `Main.hs`, so the entry count is unchanged; a boundary-shift pair (`{a: "bc"}`
  against `{ab: "c"}`) measures different digests.
- On POSIX hosts, two files whose names are the single undecodable bytes `0xFF` and `0xFE` measure different
  digests (the `Text.pack` path hashes both names as U+FFFD, so they collide).
- On POSIX hosts, a FIFO created under the source root, and a FIFO passed as `builderPath`, return
  `BuildSourceUnavailable` / `BuildBinaryUnavailable` within a 5-second `timeout`.
- `verifyFixture` with the builder deleted returns `Left (BuildBinaryUnavailable _)`, and with the source root
  deleted returns `Left (BuildSourceUnavailable _)`.
- A decoder table over `readBuildChannel` asserts the exact `BuildChannelMalformed` detail for a header shorter
  than 8 bytes, a field body shorter than its declared length, a declared length of `0xFFFFFFFFFFFFFFFF`, a
  non-UTF-8 field, and trailing bytes after the signature frame. Through `verifyFixture`, a channel with an
  empty image-build frame name returns `BuildChannelMalformed "the image-build frame is empty"`, and a
  signature frame carrying a 63-byte payload returns `BuildSignatureInvalid` with the parse-failure detail.
- The no-channel case is named for the reader-level property it checks (`readBuildChannel` returns
  `BuildChannelUnavailable`).

#### Remaining Work

- `takeFrames` in `Build.hs` decodes each field with `Handoff.takeHandoffFrame` (or compares the `Word64`
  length against the remaining body and a maximum before `fromIntegral`), so a length with the top bit set is
  `BuildChannelMalformed`; add the decoder table and the short-signature case listed under Validation.
- `measureSourceDigest` enumerates names without locale decoding (`System.Directory.OsPath.listDirectory`) and
  hashes each relative path's raw platform bytes joined with `/`, never `Text.pack` of a decoded `FilePath`;
  add the two-root, golden, and undecodable-name cases listed under Validation.
- `measureSourceDigest`'s traversal and `measureBinaryDigest` refuse a non-directory entry that is not a
  regular file before opening it, with `BuildSourceUnavailable` naming its relative path or
  `BuildBinaryUnavailable` naming `builderPath`; add the POSIX FIFO cases listed under Validation.
- Correct the `measureSourceDigest` Haddock: it names exactly what the digest covers (regular-file relative
  paths and bytes) and what it does not (modes, empty directories, symlink-versus-copy), replacing "two
  different trees cannot measure the same".
- Correct the `HostBootstrap.Build` module header. It says the derived image runs `project init --role
  image-build-container` and then `check-code`, authorizing from a baked config, and it describes the concrete
  command/channel seam as future work. The demo's `docker/Dockerfile` installs the canonical image-build config from the
  `hostbootstrap-build-config` BuildKit secret and runs no `project init`. Its `check-code` RUN mounts
  `hostbootstrap-build-channel`, `hostbootstrap-build-verification`, and `hostbootstrap-build-coordinator` as
  one-RUN secrets, and `Command`'s `check-code` passes them to `verifyBuildInvocation` with
  `Context.sourceRoot` and `getExecutablePath`. The header states that consumer, and states that this verifier
  does not establish that those two paths are the engine's actual context and the running builder, and keeps
  no durable replay registry.
- Rewrite the move case to delete `Main.hs`, add the boundary-shift pair, and add the two `verifyFixture`
  cases with a missing builder and a missing source root.
- Rename "a build backend with no channel is Unsupported, not a fallback" to the reader-level property it
  checks.

The worked-demo phase owns trusted engine/runtime derivation and the actual Docker-build consumer.

### Sprint 13.5: Runtime activation package [Active]

**Status**: Active
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
- Verification validates both the selected and the received manifest, and compares them field by field with
  the permitted-effect rows compared as lists, so `["a,b"]` and `["a", "b"]` are different rows.
- Activation grants no lifecycle authority until the origin-bound one-use role admission (the composition
  phase's role phase machine) consumes it.
- The service-runtime phase owns manifest installation, relayed signing consumption, deployment, and the
  live `service run` entry.

#### Validation

`ActivationSpec` covers provisioned-key verification, the dedicated signature domain, the service-field
manifest mismatch, measurement comparison, broker expiry, wire decoding, instance validation, and the
empty-revision and empty-service signing refusals.

`firstManifestMismatch` compares the permitted-effect rows through `Text.intercalate ","`, and
`validateManifest` admits a comma inside an effect identity, so a selected `["a,b"]` matches a signed
`["a", "b"]` and the continuation runs with the signed row; the selected manifest is never validated. Every
`ActivationSignatureInvalid` case uses a well-formed 64-byte signature, so the `CryptoFailed` branch runs in no
test, and the external-signing helper builds its material from production `frameWire` and
`renderActivationManifest`, so no fixed-bytes vector exists.

Closure requires these `ActivationSpec` cases to exist and pass under the phase gate:

- A `validateManifest` table driven through both `signActivationManifest` and `verifyRuntimeRoleActivation`
  (received side and selected side): one row per required field set to `""` (scope, plan digest, spec digest,
  binary digest, frame, rollout revision, config digest, service identity, role-plan digest, secret channel),
  an empty effect identity, and a duplicated effect identity, each asserting `ActivationManifestInvalid` with
  that field's exact detail.
- `activationSigningPolicy` refuses `[]` ("the signing policy is empty"), `[baseManifest, baseManifest]`
  ("the signing policy contains a duplicate manifest"), and a list holding one invalid member (that member's
  `validateManifest` detail).
- The exact-selection case is table-driven over every compared field except revision (caught earlier as
  `ActivationRevisionStale`): for each, the policy admits the variant, verification against `baseManifest`
  returns `ActivationManifestMismatch` naming that field. One row selects `["read,write"]` against a signed
  `["read", "write"]` and asserts the `"permitted effects"` mismatch.
- The effect-row framing case also compares `["read,write"]` with `["read", "write"]`, and pins
  `renderActivationManifest baseManifest` against a literal SHA-256 hex digest.
- The external-signing helper builds its signed material from literal bytes, and a literal signature for
  seed 97 over `baseManifest` verifies.
- The secret-digest decoder refuses `Text.replicate 63 "a"`, `Text.replicate 65 "a"`, `""`, and
  `Text.replicate 64 "g"`; the positive control `manifestWireWithSecretDigest (activationSecretDigestText
  baseSecretDigest) baseManifest @?= renderActivationManifest baseManifest` holds; and
  `activationSecretDigestText baseSecretDigest` equals the SHA-256 hex of `baseSecretBundle`.
- "A genuine activation verifies and exposes its bound package" asserts all eleven
  `VerifiedRuntimeRoleActivation` accessors against `baseManifest`'s distinct field values.
- Verification with `adoptRelayedActivationGrant ""`, with a 63-byte grant, and with a truncated installed
  `activation.sig` returns `ActivationSignatureInvalid` carrying the parse-failure detail.

#### Remaining Work

- `firstManifestMismatch` compares `manifestPermittedEffects` as lists (rendering the row for the diagnostic
  only), and `verifyRuntimeRoleActivation` runs `validateManifest` on the selected manifest before comparing;
  add the comma-split mismatch row and the selected-side validation rows listed under Validation.
- Add the `validateManifest` and `activationSigningPolicy` refusal tables listed under Validation.
- Table-drive the exact-selection case over every compared field except revision.
- Add the comma-split framing row, the rendered-manifest golden digest, the literal external signing
  material and signature vector, and the secret-digest length, positive-control, and SHA-256 cases listed
  under Validation.
- Assert all eleven accessors in the bound-package case, and add the three malformed-grant
  `ActivationSignatureInvalid` cases.

Runtime deployment and complete admission recovery belong to their lower-dependent consumer phases.

### Sprint 13.6: Registered one-use edge [Active]

**Status**: Active
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
  conflicting challenge or binding. A failed first-grant write whose record still holds the planned binding
  is a `HandoffStoreFailure`; only a record holding a different granted transcript is `HandoffTokenConsumed`.
- `grantHandoff` re-checks the offer's binding against the live broker's project, generation, protected store,
  scope, and verb, so a binding minted under another broker is refused even when its token row is present.

#### Validation

`HandoffSpec` covers root registration, refusal of an unregistered edge, idempotent retry, conflicting reuse,
cross-edge token isolation, and concurrent identical grant requests converging on one signature. Closure
additionally requires:

- Cross-broker grant cases: a binding minted under one `withRootBroker` bracket and granted under a second
  bracket on the same store with another generation, another verb, and (on a second store) another protected
  store, each refused with the `HandoffBindingMismatch` detail `brokerRelay` gives for that field.
- A rejected-admission case: `registerAdmittedHandoffEdge` with a refusing admission predicate returns
  `Right (Left reason)`, and a following `grantHandoff` for that binding returns `HandoffEdgeUnregistered`.
- A value-level case for the post-compare-and-swap classification: a re-read record equal to the planned
  binding yields `HandoffStoreFailure`, the exact granted transcript yields success, and any other record
  yields `HandoffTokenConsumed`.

#### Remaining Work

- `consumeRegisteredEdge`: after a failed compare-and-swap, a re-read record equal to `plannedEdgeRecord
  binding` returns `Left (HandoffStoreFailure writeFailure)`; keep `HandoffTokenConsumed` for a record that
  holds a different transcript. Factor that classification into a pure total function so the value-level case
  under Validation tests it without a failing store.
- Add the cross-broker `grantHandoff` cases and the rejected-admission `registerAdmittedHandoffEdge` case
  listed under Validation.
- Rename the `HandoffSpec` case "failed child verification cannot consume the root token" to "granting one
  edge does not consume another edge's token", which is the `grantHandoff` property its body checks;
  `verifyHandoff` is pure and takes no store, so verification-side consumption is excluded by its type.

### Sprint 13.7: Keyless duplex relay foundation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportHandoffRelay.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Let an admitted nested frame reach root-owned handoff services through a structurally keyless link. The
per-link capability sets of the root coordinator links `rootForwardBrokerLink` and `rootReverseBrokerLink`
belong to the recursive lifecycle command phase, which owns those coordinator shapes and the config-open
restriction on the forward link; this sprint documents only that they are key-backed.

#### Deliverables

- `BrokerLink` is the private route to root-owned edge open/grant, activation signing, and recovery-wire
  signing services.
- A root link retains the live brokers and admission predicates, while a relayed link retains only its
  authenticated route, request identity, installed-key digest, and duplex channel.
- `offerHandoffEdge` opens a narrowed-project-config edge through the link, performs the child exchange, and
  then serves admitted relay requests until completion or refusal; it refuses a recovery-kind binding input.
- `brokerRelayFromRouteWire` refines a relayed binding against the authenticated route and the opening request,
  and refuses another generation, verb, store, or opening-request field before any grant.
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

Closure additionally requires `HandoffSpec` cases that call `brokerRelayFromRouteWire` with a binding minted
under another broker generation, another verb, and another protected store than the route names, and with an
opening request (`Just input`) that differs in each compared field, each asserting `HandoffBindingMismatch`
with the detail naming that field. The single positive call stays. It also requires:

- the recovery-signing trailing-bytes case: through Sprint 13.1's test-only route, a child relays a
  recovery-signing request whose offer wire carries n appended bytes after the offer's three frames; the
  parent's `offerHandoffEdge` returns `Left (RelayHandoffFailure (HandoffWireTrailingBytes n))` with n equal
  to the appended byte count, and the child receives a `RefusedTag` whose code is `unauthenticated`
  (observed as `RelayRefusedByPeer "unauthenticated" _`);
- the payload-argument guard: `HandoffSpec` takes the `Relay.hs` section from `offerHandoffEdge ::` to
  `offerHandoffEdge _ _ 0` with `requiredSourceSection` and asserts that it contains `the exact narrowed
  project config bytes` and does not contain `recovery-adapter bytes`;
- the existing "sender-side Offer payload bound" section (from `maxEmbeddedOfferPayloadBytes :: Int` to
  `awaitChallenge ::`) and its ordered fragments still pass after the constant moves;
- the four frozen `handoffDigest` assertions in `HandoffSpec` equal the SHA-256 of `Handoff.hs` after this
  sprint's Haddock move.

The phase **Gate** runs these cases.

#### Remaining Work

- Rewrite the Haddock on `offerHandoffEdge`'s payload argument (`Relay.hs`, today `-- | the exact narrowed
  config or recovery-adapter bytes`) to read "the exact narrowed project config bytes", naming
  `offerReverseDescentKernel` as the opener for recovery edges, and add the payload-argument guard named
  under Validation.
- Add the `brokerRelayFromRouteWire` refusal cases listed under Validation.
- Place `maxEmbeddedOfferPayloadBytes` with its own `-- |` comment immediately above the
  `{- | Open one edge ... -}` block in `Relay.hs` (today it sits under that block), so the block documents
  `offerHandoffEdge` and the sender-side payload-bound section in `HandoffSpec` still starts at the constant
  and spans `offerHandoffEdge`.
- Rewrite the `BrokerLink` Haddock (today "the two constructors below are the only ways to build one, and
  only one of them has a key behind it") to state that `rootBrokerLink` is the root's key-backed link, that
  the root coordinator variants elsewhere in this module are also key-backed, and that
  `relayedBrokerLinkKernel` is the only keyless one. Drop "This is the only 'BrokerLink' with a signing
  capability behind it" from the `rootBrokerLink` Haddock. Per-link capability wording for
  `rootForwardBrokerLink` and `rootReverseBrokerLink` stays out of this sprint.
- `adoptRelayedOffer` (shared by `serveGrant` and `serveRecoverySigning`) refuses trailing bytes after the
  offer's three frames with `RelayHandoffFailure (HandoffWireTrailingBytes n)` instead of
  `RelayMalformedMessage GrantRequestTag 2`; add the recovery-signing trailing-bytes case named under
  Validation, asserting both the parent's `Left` and the child's `unauthenticated` refusal code.
- Move the "Exact request fields: canonical binding, then adapter wire." Haddock in `Handoff.hs` from
  `providerDependencyPackageFields` to `recoveryRequestFields`, and give `providerDependencyPackageFields` a
  one-field description. Then re-pin the four frozen `handoffDigest @?=` literals in `HandoffSpec` (in the
  "rooted lifecycle request ownership ...", "rooted lifecycle response pairing ...", "scope-first transport
  remains acyclic ...", and "rooted carrier adoption ..." cases, today near lines 4388, 4800, 8118, and 8486)
  to the new SHA-256 of `Handoff.hs`.

### Sprint 13.8: Closed rooted outer vocabulary [Active]

**Status**: Active
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
- Exact private-source guards pin every stable protocol-v1 tag byte (24 tags in the tree: this sprint's
  rooted pair, Sprint 13.18's `FrameTransactionTag`/`FrameOutcomeTag`, and the three `ProviderDependency`
  tags among them), both one-field rooted shapes, and the total
  encode/decode/field-count tables; the response-waiting transitions, including the request-identity
  comparison in `requireRequest`, are exercised by value through Sprint 13.1's test-only route, which no
  consumer package can import.

#### Validation

`HandoffSpec` reads the exact hidden source and pins every protocol-v1 tag byte, both rooted outer field
counts, the total encode/decode tables, and every new state transition call site. The generic codec remains
one total implementation, and the phase gate compiles it with `-Werror`; Phase 17's proof-complete host-static
gate owns real-process exercise of the rooted pair. Closure requires value-level `childProtocolReceive` cases:
from `ChildAwaitingResponse 7 tag`, the expected response tag carrying request id 8 returns
`Left (ProtocolRequestMismatch 7 8)` and carrying 7 returns `ChildRunning 7`; the same mismatch and match pair
for `AcknowledgedTag` from `ChildAwaitingAcknowledgement` and for `RefusedTag`; and an unsolicited, duplicate,
or post-`ChildFinished` rooted response returns `ProtocolInvalidTransition`.

Dated 2026-08-12 evidence: the combined library/test `-Werror -j1` build passed; `HandoffSpec` passed 68/68;
the public compile-fail boundary passed 452/452; `DocValidatorSpec` passed 2/2; and canonical
`cabal test all --ghc-options=-Werror -j1` passed 1913/1913. At landing `Handoff.Protocol` measured 463
significant lines, 17 above its 446-line baseline and well below this sprint's 160-line cap, with SHA-256
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`; Sprint 13.18 and the provider-dependency
tags re-stamp that file, so the figure is this sprint's landing measurement, not a live pin. No Cabal row, public export,
named type, runtime importer, or real-process claim was added.

#### Remaining Work

- Add the value-level `childProtocolReceive` request-identity and transition cases listed under Validation,
  run through Sprint 13.1's test-only route to `Handoff.Protocol`.

### Sprint 13.9: Rooted payload and child-config binding [Active]

**Status**: Active
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
private-source and public cryptographic guards. Every verifier case signs with a test-local oracle, so the
production config signer's own refusals run in no test. Closure requires a refusal table that drives the
production rooted config signer (`signRootedPayloadBindingKernel`, whose checks are
`validateRootedConfigSigning`) with the real
`recoverySigningKernel` capability obtained through Sprint 13.1's test-only route, asserting the exact
`HandoffBindingMismatch` detail for: a recovery-kind offer ("recovery signing requires canonical
RecoveryChildPackage admission"), an empty payload, an empty child config, a payload that differs from the
child config, an immediate edge that does not bind the payload digest, and an offer minted under another
broker.

`expectBindingRefusal` accepts any `HandoffBindingMismatch`, so the rooted parser's two size bounds are
unpinned: without the whole-wire bound the all-zero oversized wire is refused as trailing bytes, and without
the per-frame bound the oversized edge header is refused as truncated. Closure requires the oversized-wire row
to assert the "is larger than the bounded authentication field" detail and the oversized-edge-header row the
"contains an oversized field" detail. It also requires the ownership guard to assert that the modules
importing `Crypto.PubKey.Ed25519` across `src/`, `internal/`, and `app/` are exactly `Activation.hs`,
`Build.hs`, and `Handoff.hs`, and that the facade's `HostBootstrap.Handoff.*` imports equal an exact
allow-list rather than avoid five named modules.

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

- Add the production rooted-config-signer refusal table listed under Validation to `HandoffSpec`, using the
  real `recoverySigningKernel` from Sprint 13.1's test-only route rather than the test oracle.
- Give `expectBindingRefusal` an expected detail fragment (matched with `isInfixOf`), and pass the two
  rooted size-bound details listed under Validation at the oversized-wire and oversized-edge-header call sites.
- Replace the "the facade alone owns rooted cryptography" assertion with an exact importer set for
  `Crypto.PubKey.Ed25519` (`Activation.hs`, `Build.hs`, `Handoff.hs`), and replace the five-module facade
  import blacklist in "the hidden handoff modules and sealed folds have exact production owners" with the
  exact list of `HostBootstrap.Handoff.*` modules `Handoff.hs` imports.

### Sprint 13.10: Canonical recovery child package [Active]

**Status**: Active
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

The malformed-package rows of the cryptographic matrix sign every malformed wire with the digest of an
unrelated config, so the final config-digest join refuses each of them whatever the decoder does; they do
not isolate the strict decoder. Closure requires each structural row to be the wire's only defect: the
empty-adapter, missing-adapter, and trailing-frame wires are signed over `childConfigDigest childConfig`, the
empty-config wire over `childConfigDigest ""`, and each row asserts `HandoffBindingMismatch` whose detail
names its own refusal ("has an empty recovery adapter", "has an empty child config", "has trailing bytes",
"is not canonical", or the truncation and oversize details). It also requires a refusal table that drives
`signRecoveryChildPackageBindingKernel` with the real `recoverySigningKernel` from Sprint 13.1's test-only
route, asserting the exact detail for a non-recovery edge, an offer whose payload is not the exact canonical
package, an immediate edge that does not bind the complete package digest, and an offer minted under another
broker.

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

- Rewrite `HandoffSpec`'s `expectPackageRefusal` so each malformed package is signed over the digest of the
  config a lax decoder would extract, and assert the specific "recovery child package ..." refusal detail per
  row, as listed under Validation.
- Add the production `signRecoveryChildPackageBindingKernel` refusal table listed under Validation.
- In "recovery child package ownership is bounded, hidden, additive, and exactly attributed", delete the
  derived `(handoffAttribution, recoveryAttribution, sum)` tuple assertion: `handoffAttribution` is the
  already-pinned facade count plus a literal 6, so it cannot fail apart from that pin. Keep the measured
  `significantHaskellLineCount` pins.

Sprint 13.13 owns receiver-carrier adoption; Sprint 17.30 owns the catalog-derived production call site.

### Sprint 13.11: Authenticated root scope [Active]

**Status**: Active
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

The matrix's `assertRefused` accepts any `Left`, so a row whose input also trips a later guard does not pin
the guard it names: the malformed-UTF-8 Harness run is refused by the canonical-run-character check whatever
the decoder does, the short signature by the Ed25519 parse whatever the width guard does, and the oversized
declared field by frame parsing whatever the per-field bound does. Closure requires `assertRefused` to take the
expected `HandoffBindingMismatch` detail (or `HandoffAuthenticatedRootScopeSignatureInvalid` for the
cryptographic rows) and each row to assert its own: "the authenticated root scope signature has the wrong
width" for the short signature, the per-field bound's detail for the oversized declared field, and the UTF-8
decode detail for the malformed run, with any row that cannot isolate its guard relabelled to name the guard
that does refuse it.

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

- Make the root-scope matrix's `assertRefused` take the expected refusal and give each row its own detail,
  as listed under Validation.
- Delete the orphaned `{- | Recover only the narrow configuration authority from an already authenticated
  Harness scope capsule ... -}` block in `Handoff.hs`, which documents no declaration (no such projection
  exists).
- In "authenticated root scope remains nominal, scope-only, and exactly attributed", delete the literal
  `exportAttribution = 4`, `receivedProjectionAttribution = 2`, and `errorAttribution = 3` terms and the
  tuple assertion that compares them with themselves; keep the measured `scopeSectionAttribution` and
  `receivedConstructorAttribution` pins.

Relay/Receiver/Offer adoption of the capsule is Sprint 13.12 work.

### Sprint 13.12: Scope-first receiver adoption [Active]

**Status**: Active
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
- The receiver's refusal announcement goes through `childProtocolSend`: once the parent has sent a
  `RefusedTag` or `AcknowledgedTag` on any path, the child sends no further frame, and a parent refusal is
  never echoed back as a child refusal.

#### Validation

`HandoffSpec` covers the unchanged four-field outer shape, strict leading-capsule cardinality, wrong
scope/project/run/key, root-versus-relay capsule identity, replay, semantic binding/payload use before scope
verification, refusal delivery, and rank-2 escape through public cryptographic behavior plus exact
private-source/ownership guards. It pins that Protocol performs structural bounding only and has zero delta.
The recursive-lifecycle-command phase owns the first real relaunched-child consumer and process fixture.

No test produces a `ReceiverError` from the receiver itself. Closure requires an in-process harness, reached
through Sprint 13.1's test-only route, that runs `withReceivedHandoffEdge` on a pipe-pair `HandoffChannel`
against a scripted parent and asserts both the returned `ReceiverError` and the `RefusedTag` code the parent
reads: an Offer naming another installed-key digest (`ReceiverKeyMismatch`, code `installed-key-mismatch`), a
capsule for another project or scope, an Offer with three or five fields (`ReceiverMalformedMessage OfferTag
n`), a Grant with the wrong arity (`ReceiverMalformedMessage GrantTag n`), and a parent that refuses after the
child is running, after which the harness reads no further frame from the child.

Dated 2026-08-12 production/API evidence: the three production owners add 100 significant lines against the
400-line budget: `HostBootstrap.Handoff.Relay` adds 16, `HostBootstrap.Handoff.Receiver` adds 76, and
`HostBootstrap.Handoff.Receiver.Internal` adds 8. This sprint adds no named type. The private
`rootBrokerLink` now consumes the matching `HandoffScope` and mints the one root-issued capsule before
constructing a link; a relayed link copies only the capsule retained by its authenticated parent edge.
`withReceivedHandoffEdge` now consumes the independently installed identity and key and exposes only the
closed Production-config, Production-recovery, Harness-config, and Harness-recovery fixed-unit continuations
after scope verification. `ReceivedEdge` retains the exact typed capsule beside its verified ordinary edge.
This sprint changes neither the Handoff facade, Protocol, the Cabal file, nor the four-field Offer. An
independent security audit passed.

Dated 2026-08-12 validation evidence: the combined library/test `-Werror -j1` build passed;
`HandoffSpec` passed 79/79; the public compile-fail boundary passed 457/457; `ProjectPlanSpec` passed 68/68;
`DocValidatorSpec` passed 2/2; and canonical `cabal test all --ghc-options=-Werror -j1` passed 1,929/1,929
tests in 397.18 seconds. SHA-256 values measured at landing are
`d940f18d34f086447d4c6c5a61b48eae92e22b1bd5f24f6d0bd4c34309d488a5` for Relay,
`bdc76856fcf8a1aeaedf512cf84a44cb2ccb4454b7a68a78e4bf88feab2e1ea9` for Receiver, and
`5f6bb3b569ee73b5a391b21ac08965e66bb5e71a4c4e1450cba57b66b178ae13` for Receiver.Internal, with the
Handoff, Protocol, and Cabal SHA-256 values unchanged from Sprint 13.11 at
`89cd5a7a9e08c5742abdc0419cf169cff1bb2ac46b64d177b141583abcc15239`,
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877`, respectively.

#### Remaining Work

- `announceRefusal` tracks the child protocol state alongside the active request id and sends its
  `RefusedTag` only when `childProtocolSend` admits it; a `RefusedTag` or `AcknowledgedTag` received from the
  parent on any path (including a refused terminal report or a refused relay request) leaves nothing to
  announce.
- Add the scripted-parent receiver harness and the refusal cases listed under Validation to `HandoffSpec`.
- Correct the `withReceivedHandoffEdge` Haddock: a continuation's `Left` or exception is announced to the
  parent as a refusal only while no terminal report has been acknowledged; after an acknowledged report the
  child returns `ReceiverDeclined` and sends nothing. The scripted-parent harness adds that case: the
  continuation reports `Completed`, the parent acknowledges, the continuation returns `Left`, and the harness
  reads no further frame.
- In "received packages and branch-specific relay links remain closed", replace the `IO (Either ReceiverError
  ())` and `IO (Either Text ())` fragments (each a substring of a fragment the case already requires) with
  matches of each signature's complete tail, `) -> IO (Either ReceiverError ())` anchored at the end of
  `withReceivedHandoffEdge`'s type and the fold's own final result in `Receiver/Internal.hs`, and add a
  fragment for the Harness config callback's unit result.

Sprint 13.13 owns rooted-binding and recovery-package carrier adoption; Phase 17 retains ownership of the first
real-process receiver fixture.

### Sprint 13.13: Rooted carrier and recovery-package receiver adoption [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
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
  adapter, projection, or grant. `RecoveryProjectionBindingInput` exports read-only accessor functions and no
  record field labels, so a record update can neither replace a coordinate's text under its existing index nor
  retag the value with caller-chosen `planDigest`, `parentFrame`, or `childFrame` indices.
- This lower sprint produces no real recovery package and composes none on the reverse route:
  `RecoveryAdmission` authenticates only the extracted adapter, while Sprint 17.30's catalog-backed
  `EdgeAdmission` owns the complete package configuration
  and payload digest before the exact Offer is routed to the installed root signer.
- Work remains one private offer/receive carrier adoption across the three named production owners, adds no
  named type or application producer, and grants no signer, store, journal, cursor, command, or lifecycle
  authority. Sprint 17.30 remains the sole real catalog-derived package producer.

#### Validation

`HandoffSpec` covers lower config and package-aware recovery success; exact nested cardinalities; the
independent authoritative Protocol total-body refusal; wrong capsule,
key, rooted binding, projection, grant, payload kind, package, config field, adapter, signer, edge, and
cross-pairing; strict package failures; relayed exact-byte signing; severed-route refusal; and no callback
before every join. Exact source/ownership guards
pin three production owners, one carrier adoption, no new type or public signer, `RecoveryAdmission`'s
adapter-only responsibility, and zero catalog/application producers. Phase 17 owns the first real
package-producing process fixture.

The receiver-level refusals run in no test. Closure requires, on Sprint 13.12's scripted-parent harness: an
Offer whose embedded payload is one byte over 7 MiB refused with `ReceiverWrongEdge "the embedded Offer payload
exceeds its strict sub-ceiling"` before any branch is exposed; a recovery Offer whose binding phase is not
`teardown` refused with the "a recovery adapter must authorize teardown" detail; and a recovery Offer with a
cross-paired rooted proof refused before the recovery continuation runs. It also requires compile-fail
fixtures that record-update each `RecoveryProjectionBindingInput` field and retag its indices by a
type-changing update, all refused.

The 7 MiB sub-ceiling is pinned only as source text (the constant's spelling and the
`requireOfferPayloadBound payload` call order), so `requireOfferPayloadBound _ = pure ()` passes. Closure
also requires: an Offer whose embedded payload is exactly `maxEmbeddedOfferPayloadBytes` admitted by the
receiver; `offerHandoffEdge` (through Sprint 13.1's test-only route to `Handoff.Relay`) refusing a payload of
`maxEmbeddedOfferPayloadBytes + 1` bytes with its `RelayError` before any edge is opened; a recovery binding
with an unsupported verb and phase `teardown` refused with a detail naming the verb, not the phase. In
"rooted carrier adoption is bounded, acyclic, exactly attributed, and freezes shared surfaces", the receive
bound's message names the order the receiver has (after the scope capsule is verified with the installed key,
before installed-key digest, binding, or branch interpretation), and the case asserts no line budget: its
three line counts are literals compared with themselves, and `7 * 1024 * 1024 < 8 * 1024 * 1024` is a
constant.

Dated 2026-08-12 production/API evidence: the three production owners add 145 significant lines against the
400-line budget: `HostBootstrap.Handoff.Relay` adds 119, `HostBootstrap.Handoff.Receiver` adds 9, and
`HostBootstrap.Handoff.Receiver.Internal` adds 17. The sprint adds no named type or real package producer.
An independent security audit passed.

Dated 2026-08-12 focused validation evidence: the serialized combined library/test `-Werror -j1` build passed;
`HandoffSpec` passed 82/82 in 22.71 seconds; the public compile-fail boundary passed 457/457 in 107.53
seconds; `ProjectPlanSpec` passed 68/68 in 12.73 seconds; and `DocValidatorSpec` passed 2/2 in 0.25 seconds.
Canonical `cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all 1,932 tests in
402.38 seconds; the suite passed.
SHA-256 values measured at landing are
`bf577a55a33c76e4636a9b80019adc31988831990d0261f1bbb3bf5036ba2457` for Relay,
`47d1b8826240bc15bf85561292af77fb8f9a615a417db6b44ceba1531c7316fc` for Receiver, and
`b3720a38158b963f2b7aa63a96b20658ffde57cda42efda8ec6df39d8d48cad8` for Receiver.Internal, with the
Handoff, Protocol, Rooted, Recovery, Handoff.Internal, and Cabal SHA-256 values unchanged by this sprint at
`89cd5a7a9e08c5742abdc0419cf169cff1bb2ac46b64d177b141583abcc15239`,
`c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8`,
`b2ea6e78f665459a70d35db8a054a9f7481d78bb9fad5dae9b98df6de9cfac1c`,
`15244530789cfe080ff84c543881158422143758cf9e15885ad47f08839424d1`,
`c1f780692658e80d79e7e1033ba520a0c7ac684041fd45de1a5849b262d9acd7`, and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877`, respectively.

#### Remaining Work

- Stop exporting `requestedRecoveryPlanDigest`, `requestedRecoveryParentFrame`, and
  `requestedRecoveryChildFrame` as record fields: rename the fields privately and export plain getters under
  the current names, as `BrokerRoute`'s accessors are. Add compile-fail fixtures
  `UpdateRecoveryProjectionInputField.hs` and `RetagRecoveryProjectionInput.hs`, each refused.
- Add the receiver sub-ceiling, recovery-phase, and cross-paired-proof cases listed under Validation to
  `HandoffSpec`.
- Add the exact-limit admitted case and the `offerHandoffEdge` over-limit refusal case listed under Validation.
- Split the recovery-classification fallback in `Receiver.hs`: a binding whose phase is `teardown` but whose
  verb is not `down`, `destroy`, or `up` is refused with `ReceiverWrongEdge` naming the unsupported verb; any
  other phase keeps "a recovery adapter must authorize teardown, received <phase>". Add the verb case listed
  under Validation.
- Correct the `ReceivedRecoveryDescent` Haddock in `Receiver/Internal.hs`: its sole eliminator,
  `withReceivedRecoveryDescent`, hands the continuation rendered bytes (package, adapter wire, projection,
  grant signature) and forces but never exposes the `RootedPayloadBinding`, so typing ends at that boundary.
- In the carrier case, delete `frozenCarrierRelayLines`, `frozenCarrierReceiverLines`,
  `frozenCarrierReceiverInternalLines`, `sprintDelta`, their self-comparisons, and the `<= 400` bound, and
  delete the literal `7 * 1024 * 1024 < 8 * 1024 * 1024` assertion; reword the receive-bound message as listed
  under Validation.

Sprint 17.30 retains ownership of the first catalog-derived recovery-package producer and real
package-producing process fixture.

### Sprint 13.14: Closed rooted lifecycle request [Active]

**Status**: Active
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
  cardinality, encoding, emptiness, zero ordinal, digest, nonce, path, and size violations. This sprint
  changes neither the singleton `RootedLifecycleRequestTag` field nor Protocol's independent 8 MiB
  total-body bound. The opaque tenth frame gains no semantic claim here: Sprint 13.17 uses the sealed
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

The public `withVerifiedRootedLifecycleResponse` decodes the exact request with
`rootedLifecycleRequestFromWireKernel` before any signature work, and only a wrong-domain request is ever fed
to it. Closure requires a table of malformed exact requests, each otherwise canonical and each passed to
`withVerifiedRootedLifecycleResponse` with a correctly signed response, asserting `HandoffBindingMismatch` with
the decoder's specific detail: version 2, an unknown discriminator, a `NextNode` request with eight and with
ten frames, an empty requester path, a 257-component path, a 4,097-byte path component, an empty or invalid-UTF-8
session and stage, a 4,097-byte session, a predecessor digest of 63 characters and one with uppercase hex, a
zero ordinal and a 7-byte ordinal, a 31-byte nonce, an empty observation on `SettleNode`, and trailing bytes.

The request-ownership guard's budget assertions bind `frozenRootedRequestLines`, `rootedRequestDelta`, and
`frozenRootedRequestDigest` as literals and compare them with themselves and with `<= 340`; they measure no
source and cannot fail. Closure requires them deleted, leaving the 335/340 attribution below as dated landing
evidence only.

Dated 2026-08-12 production/API evidence: at landing `HostBootstrap.Handoff.Rooted`, the sole production
owner, measured 504 significant lines. The request adds 335 lines to the 169-line rooted-binding owner, within the
340-line budget. The sprint adds no other production owner or runtime seam, and an independent security/source
audit passed. Its SHA-256 measured at landing is
`45ca89f24b43cbf4b02e2d82186e8c33db5e2aaedb6978d2111e039ae6933281`, with the Handoff, Protocol, and Cabal
SHA-256 values unchanged by this sprint at
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

- Add the malformed-request table listed under Validation to `HandoffSpec`, run through the public
  `withVerifiedRootedLifecycleResponse`, one row per decoder refusal class with its exact detail.
- Delete the literal-against-literal line-count, delta, `<= 340` budget, and digest assertions from the
  rooted-request ownership guard, as listed under Validation.

Sprint 13.17 owns transport through the already-reserved singleton outer field.

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
  the neutral Receiver-internal pair/path folds. This sprint changes neither Protocol nor Cabal, and Phase 17
  alone assigns body semantics, lawful successors, freshness, terminality, and replay.

#### Validation

Exactly three `HandoffSpec` source-guard cases pin all seven discriminators, exact 9/11 cardinalities, every
scalar/body/total bound, canonical rerender/no trailing bytes, the four-field nested `Prepared` body, seven
unsigned builders plus the sole signature-attaching kernel, absence of a signature-placeholder builder, the exact
request-family matrix, path/session/nonce echo, receipt/predecessor equality, outer-only open refusal, the
closed fold, single neutral owner, one-type budget, and absence of authority, cryptography, facade, storage,
testing-companion, or semantic/process/durable imports. Phase 17 owns semantic report/body, ordering, and
durable replay tests.

Dated 2026-08-12 production/API evidence: at landing `HostBootstrap.Handoff.Rooted`, the sole production
owner, measured 754 significant lines. The response adds 250 lines to the 504-line request/binding owner, within
the 280-line budget. The sprint adds no other production owner or runtime seam, and an independent
security/source audit passed. Its SHA-256 measured at landing is
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

### Sprint 13.16: Rooted lifecycle response signing [Active]

**Status**: Active
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
  `RootedLifecycleResponse`, while `Handoff.Rooted` stays the sole structural owner; this sprint changes
  neither Protocol nor Cabal.
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
signature/request/family/body cross-pairs and canonical-report refusal, and exact source/ownership guards
for the live-broker signer, specialized existing capability, no new named type, no generic unsigned/signing
surface, frozen Protocol bytes, frozen handoff package rows, and three production owners. The package rows
are this phase's own — its module rows in the main library, plus that library's dependency set — rather than
the whole package description, because a sprint freezes what it owns (§ C). The budget guard measures the
live facade and `Handoff.Internal`, subtracts three later allowances (30, 54, and 129 lines), and pins the
remainder at 236 against a 240-line ceiling; it does not enforce this sprint's 180-line budget, whose own
measurement at landing is the 139/180 figure below. Because `(handoffLines, internalLines, rootedLines)` is
already pinned to exact counts, the derived tuple and the `<= 240` bound are arithmetic over constants and
cannot fail apart from that pin; closure requires them deleted, keeping the measured count pins.

The "independently authenticates all seven closed families" case asserts only acceptance: deleting the
signature check in `withVerifiedRootedLifecycleResponse` leaves it green. Closure requires that, inside its
per-family loop, the same unsigned bytes signed with another seed and, separately, under the domain
`hostbootstrap/rooted-lifecycle-response/not-v1` each return `Left HandoffRootedLifecycleSignatureInvalid`
for every family.

The verification matrix accepts any `Left` (`assertRefused`), so no row isolates the guard it names: the
malformed `Prepared`-body and empty-`Refused`-detail wires are built for `nextRequest` and verified against
`closeRequest`, so request pairing refuses them whatever their bodies, and the cross-request replay row is
refused by the signature. Closure requires: `assertRefused` takes the expected `HandoffBindingMismatch`
detail; each malformed-body wire is built for the request it is verified against, so its body is the only
defect; one row signs a correct-family response that names another request's digest over the exact request,
so only the digest-pairing check ("names a different rooted lifecycle request") refuses it; and a refusal
table drives the production `signRootedLifecycleResponseKernel` with the real `recoverySigningKernel` from
Sprint 13.1's test-only route — an unpaired request/response family, a response naming another request, a
`FrameComplete` whose report fails canonical lifecycle-report verification, and a non-canonical unsigned
response — each asserting its exact detail.

Dated 2026-08-12 production/API evidence: the response-authentication additions to the public facade are
exactly the abstract `RootedLifecycleResponse`, `renderRootedLifecycleResponse`, the fixed
`signRootedLifecycleResponseKernel :: RecoverySigningKernel -> RootBroker ... -> ByteString -> ByteString ->
IO (Either HandoffError RootedLifecycleResponse)` signer, and
`withVerifiedRootedLifecycleResponse :: ProjectVerificationKey -> ByteString -> ByteString ->
(RootedLifecycleResponse -> result) -> Either HandoffError result`. The signer fixes the transcript to framed
domain `hostbootstrap/rooted-lifecycle-response/v1`, installed verification-key digest, exact complete
canonical request, and exact complete canonical unsigned response. The verifier independently parses and
pairs, verifies that transcript, validates a `FrameComplete` lifecycle report, and only then enters its fixed
CPS continuation. The value remains descriptive signed data rather than authority. This sprint adds no
production caller of the signer; its production callers are Phase 17's root-service endpoints in
`Handoff/Relay.hs`. Sprint 13.17's originating typed Relay operation is the verifier's production transport
caller. An independent security/source audit passed.

The exact production delta is 139/180 significant lines: `HostBootstrap.Handoff` +126,
`HostBootstrap.Handoff.Internal` +13, and the structural owner `HostBootstrap.Handoff.Rooted` +0. Their
respective SHA-256 hashes measured at landing are
`6bbbd828b453173cf8f4be9cd1989eb0a6ddfc2cc5a9639b29d76558c0121fe5`,
`305dc09a9e9ae617161f0b7ec35309aeb31d0152894988a8bc53f415cebca2bf`, and
`c035f05ec6c0951165d9141c8d6fccd1ce45b00266f88e5d9753dbbdf618460e`. This sprint left Protocol and Cabal
unchanged at `c125f3471ea90fd11fd8d1145ffc211e7f4ae1eb2207ccb427b51b797f3a32c8` and
`73dd215e353820db5ff37d249be7968b3cff3d8a19239e5df7aea12694118877` respectively.

Dated 2026-08-12 focused validation evidence: the serialized combined library/test warnings-as-errors build
passed; `HandoffSpec` passed 91/91 in 27.91 seconds; the public compile-fail boundary passed 457/457 in
106.40 seconds; and `ProjectPlanSpec` passed 68/68 in 12.98 seconds. `DocValidatorSpec` passed 2/2 in 0.26
seconds. Canonical `cabal test all --ghc-options=-Werror -j1 --test-show-details=direct` passed all
1,941/1,941 tests in 403.54 seconds; the suite reported PASS.

#### Remaining Work

- Make `assertRefused` in the rooted response verification case take the expected refusal detail, rebuild the
  malformed `Prepared`-body and empty-`Refused`-detail wires for the request they are verified against, and add
  the digest-only cross-request row, as listed under Validation.
- Add the production `signRootedLifecycleResponseKernel` refusal table listed under Validation.
- Delete the derived budget tuple and `<= 240` bound from "rooted lifecycle response authentication is
  capability-specialized, ordered, acyclic, and exactly budgeted", and add the per-family signature refusals
  to the seven-family verification case, as listed under Validation.

Sprint 13.17 owns the first transport adopter; Phase 17 owns all durable semantics.

### Sprint 13.17: Rooted duplex relay adoption [Active]

**Status**: Active
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
  of the already-reserved outer tag; this sprint makes no change to `HostBootstrap.Handoff.Protocol`.
- Each hop prepends only its already-admitted requester component to a sealed external envelope in
  root-nearest-to-leaf order while preserving the inner request bytes. The envelope has one to 256 non-empty
  UTF-8 components of at most 4,096 encoded bytes each and is rejected before forwarding when that grammar
  fails. For `OpenFrame`, whose inner value contains only its nonce, this envelope is the sole ancestry input.
- One outstanding request alternates with one structurally paired response across every hop. Transport checks
  the strict canonical inner shape, exact request/response family and request binding, then returns the same
  inner bytes without interpreting a response body, signature, session token, stage, ordinal, predecessor, or
  lifecycle meaning.
- The existing outer `Refused` and an exact signed rooted `Refused` are distinct uninterpreted transport
  outcomes: a relay never translates, constructs, or re-signs either one. The root endpoint performs
  structural validation (requester path and served provenance) and then answers through the
  `RootedLifecycleService` its root link is built with; this sprint supplies no such service, and Sprint 17.36
  owns the root service that answers.
- An intermediate relay holds no project signing key, `RootBroker`, protected store, root catalog, retained
  session path, session constructor, lifecycle authority, request/response constructor, semantic
  freshness/replay/receipt decision, or process owner. Phase 17 owns root response production, fixed-signer
  invocation, semantic session-path comparison, durable replay and receipt ordering, storeless execution,
  recursive call-site adoption, and the first real-process rooted exchange. This sprint adds no named type, public export, Cabal
  row, command caller, or process caller.

#### Validation

`HandoffSpec` pins singleton outer fields, bounded requester-envelope construction, exact inner-byte
preservation, structural family/request pairing, one-request/one-response alternation, the root endpoint's
structural validation ahead of its service, and uninterpreted refusal propagation without importing the hidden
module. The public
compile-fail boundary retains `ImportHandoffRelay.hs`; private-source guards prove no relay-to-signer,
relay-to-store, semantic, durable, process, or recursive-command route exists. Run focused `HandoffSpec`, the
public compile-fail boundary, `ProjectPlanSpec`, and `DocValidatorSpec`, then the canonical warnings-as-errors
`-j1` phase gate. Phase 17 owns every real-process rooted fixture.

The envelope guard matches source fragments for the render-side depth bound only; the receive-side parser
(`parseRequesterPath`, `takeRequesterPathFrame`) and the served-requester provenance checks
(`requireRootedRequesterPath`, `requireServedProvenance`, `requireServedRequester`) run in no test. Closure
requires value-level cases through Sprint 13.1's test-only route to `Handoff.Relay`: a 257-component path wire,
an empty component, an invalid-UTF-8 component, and a declared component width of 4,097 bytes with a short body
each refused with its exact `RelayError`; 256 components and a 4,096-byte component accepted; and a rooted
request whose envelope names a frame other than the authenticated served child, or opens an edge for another
parent, refused with its exact `RelayError`. The transport budget guard pins a frozen Relay figure of 2,203
lines plus the live `Receiver.Internal` count (232 against a frozen 184), giving 399 against a 400-line
ceiling; it does not enforce this sprint's 390-line budget, whose own measurement at landing is the 275/390
figure below. Its Relay term is two literals (`frozenTransportRelayLines - frozenRelayLines`), so `Relay.hs`
is never measured and the "within 400 significant lines" message constrains only `Receiver/Internal.hs`.
Closure requires that budget assertion and its literal Relay terms deleted, keeping the transport-section
digest. The same case's forbidden-identifier row for `"System.Process"` can never match, because
`countHaskellIdentifier` compares single `lex` tokens; closure requires it replaced by
`countHaskellTokenSequence ["System", ".", "Process"]` over the section plus `importsModule
"System.Process"` over the whole `Relay.hs` and `Receiver/Internal.hs` sources. Its
no-rank-N-callback row tests `"forall"` against `words`, which misses `(forall`; closure requires
`countHaskellIdentifier "forall" transportOnly @?= 0`.

Dated 2026-08-12 production/API evidence: the transport adds exactly 275/390 significant lines across the two
declared owners. `HostBootstrap.Handoff.Relay` grows by 227 lines from 1,852 to 2,079 and has SHA-256
`d751ce667d2b7e4871628028f3765954942d96d2a8c5017e87c90fb784d55006`;
`HostBootstrap.Handoff.Receiver.Internal` grows by 48 lines from 122 to 170 and has SHA-256
`0a481b39e02ef02f4e1c4e47ca306794e8727ff8e15f2baae6d579e6554a2834` at landing. This sprint left the Handoff
facade, neutral Rooted owner, Protocol, and Cabal file unchanged at, respectively,
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

- Add the receive-side requester-envelope bound cases and the served-requester provenance refusal cases listed
  under Validation to `HandoffSpec`, each asserting the exact `RelayError`.
- In "rooted relay transport is keyless, acyclic, exactly owned, frozen, and budgeted", delete the
  literal-only Relay budget term and its `<= 400` assertion, and replace the `"System.Process"` and
  `words`-based `forall` rows with the token-based checks listed under Validation.

This sprint makes no change to Protocol; this boundary validates a rooted request's structure at the root and carries whatever
answer comes back, and which answer a request receives, along with every semantic or process adopter, is
Phase 17 work.

### Sprint 13.18: The frame-child entry [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/ChildGroup.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/Spec.hs`
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
- `runCLI` reads `argv` once and dispatches it over a closed, ordered set of pre-parser entries — the
  installed-identity entry, the exposure relay entry, the shipped-command entry, the forward lifecycle child,
  and this frame-child classifier — before the parser; the classifier is the entry this phase owns, and a
  source guard pins the complete ordered dispatch so an added pre-parser reader is a gate failure. The bare
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
  outcome, and ends the child's whole process tree. The platform rows live in the shared
  `Effect.ChildGroup`: on POSIX hosts the child's process group is signalled, given a grace, and killed.
  Sprint 13.20 owns the Windows row, a kill-on-close Job Object. `Handoff.Transaction`
  itself carries no CPP and is compiled unchanged on every host (§ JJ). The bracket places no time bound on
  the crossing; cancelling the caller ends the tree through the same path.
- The child's descriptor isolation is *the* one this phase owns rather than a copy of it: the private-pair
  bracket becomes `Handoff.Protocol`'s single entry, the receiver and the frame child both reach it, and
  the protocol pair is private while the global streams are redirected — so guest bytes cannot forge a
  control report and no report needs encoding to prevent it. An exception at any step, including one raised
  partway through acquiring the duplicates or redirecting the two global handles, closes every duplicate
  already taken and restores every global handle already redirected.
- Phase 13 interprets no transaction. A frame with no interpreter installed answers a refusal on the wire
  rather than falling silent, and the near side's answer reader is a total function of the request it must
  answer and the answer it received, so an outcome, a refusal, and a reply to another request are three
  decisions rather than one branch reachable only by launching a process (§ NN).

#### Validation

The classifier is total and is covered exhaustively over its argument space, including every shape that
must **not** be a marker. The child body is exercised across a real process boundary through the suite's own
re-invocation route. Closure requires these to exist and pass under the phase gate:

- The `runCLI` guard pins the complete ordered pre-parser dispatch, beginning with
  `argv == installedIdentityEntryArguments`, as an exact match over the comment-stripped token stream rather
  than an in-order fragment subset of raw text, and the case carries no exact
  `significantHaskellLineCount transactionSource` equality.
- The marker-uniqueness case searches `src/` for each marker both quoted in full and with its leading dashes
  stripped, so an optparse `long "hostbootstrap-frame-child"` declaration fails it.
- The real-process crossing sends a transaction whose answer is known — one the shipped interpreter refuses
  with a fixed message — and asserts the exact answer or refusal text.
- The suite executable launched at `frameChildArguments` with empty standard input, with non-protocol bytes,
  and with a well-formed message under another tag each exits non-zero with a `frame child:` diagnostic on
  standard error; for the well-formed message under another tag, and for a `FrameTransactionTag` message with
  two fields, standard output also carries exactly one `RefusedTag` frame echoing that message's request id.
- A `serveOneFrameTransaction` case with an interpreter that throws reads one `RefusedTag` answer on the
  channel before the exception propagates.
- A behavioural isolation case runs `withPrivateProtocolStdio` in a re-invoked suite process whose callback
  writes a marker to `stdout`: the marker arrives on standard error and not on the protocol outbound handle,
  and a write to `stdout` after the bracket returns reaches the original standard output.

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

- Remove the `timeout launchMicros` wrapper around `handoffChannel` in `withFrameChildTransaction` (that call
  does no I/O with the child) together with its unreachable "the child never opened its protocol channel"
  diagnostic, drop the unused `CPP` pragma from `Handoff.Transaction`, and correct the
  `withFrameChildTransaction` Haddock to name `Effect.ChildGroup` as the owner of the platform rows; a
  `HandoffSpec` source guard pins that `Transaction.hs` contains neither `timeout` nor `launchMicros` nor
  `{-# LANGUAGE CPP #-}`. `Effect.ChildGroup.launchMicros` then has one importer, `Handoff.Process`, whose own
  no-op `timeout launchMicros (handoffChannel ...)` is Phase 17's; the constant is deleted with that last use.
- Correct the `HostBootstrap.CLI` module header: it says "There are no hidden commands", while `runCLI`
  dispatches five pre-parser argv entries (installed identity, exposure relay, shipped command, lifecycle
  child, frame child). The header names that closed, ordered set and each entry's effect when an operator
  types it (the installed-identity entry writes the `.handoff`, `.build`, and `.activation` key files beside
  the executable and exits 0; the frame child refuses unless standard input and output decode as the protocol
  channel), and states that none is in `--help`; the `runCLI` dispatch guard above pins the same set.
- Rewrite the `runCLI` guard as an exact comment-stripped token match of the complete pre-parser dispatch,
  drop its `significantHaskellLineCount transactionSource @?= 260` equality, and extend the marker-uniqueness
  search to the dash-stripped marker.
- `serveOneFrameTransaction`: a well-framed message with the wrong tag or field count answers `RefusedTag`
  under its request id before returning `Left`, and an interpreter exception is caught narrowly, answered
  with `RefusedTag`, and re-thrown, so the module header's "answers a refusal rather than closing the pipe"
  holds; add the cases listed under Validation.
- `openProtocolStdio` closes the handles it has already duplicated when a later `hDuplicate` or the null-sink
  `openFile` throws (per-step `onException` or nested brackets), and `isolateGlobalStdio` restores `stdin`
  from the saved duplicate when redirecting `stdout` throws; add the behavioural isolation case listed under
  Validation.
- Make the crossing case assert the exact answer for a transaction with a known outcome.
- Add the three malformed-stdin frame-child process cases listed under Validation.

The crossing carries whatever transaction it is given and returns whatever answer comes back; which
transactions exist, and which frame answers them with an outcome rather than a refusal, belong to the phases
that own the objects a transaction concerns.

### Sprint 13.19: Rooted kernel coordinates are distinct nominal types [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Rooted.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Give every coordinate role that the hidden rooted kernels take or return its own private nominal type (§ HH).
Swapping two adjacent arguments is then a type error, not a well-formed signed value with its roles exchanged.
The six rooted lifecycle request kernels and `rootedOpenedResponseUnsignedKernel` are called only from modules
the recursive lifecycle command phase introduces (`Handoff.Process.Route`, `Lifecycle.FrameExecutor`,
`Lifecycle.Rooted`), so retyping them and adopting the newtypes at those callers and at `Command.Child` is
that phase's Sprint 17.73.

#### Deliverables

- `Handoff.Rooted` defines private newtypes `PayloadDigest`, `ChildConfigDigest`, `RequestDigest`,
  `PredecessorDigest`, `LifecycleSession`, `LifecycleStage`, and `LifecycleOrdinal`. Each has one validating
  smart constructor and a total eliminator. The digests accept 64 lowercase hex characters, session and stage
  accept non-empty bounded UTF-8, and the ordinal accepts a nonzero `Word64`.
- `rootedPayloadBindingKernel` and `renderRootedPayloadUnsignedPartsKernel` take `PayloadDigest` and
  `ChildConfigDigest` instead of two `Text` values.
- The `rooted*ResponseUnsignedKernel` builders that `Handoff.Relay` calls (`Prepared`, `Descend`, `Settled`,
  `FrameComplete`, `ReceiptRecorded`, and `Refused`) take `RequestDigest`, `LifecycleSession`, and
  `LifecycleStage`.
- The canonical bytes these kernels render are byte-identical to the current wire. The change is type-level
  only.
- Each of this phase's callers constructs the newtypes at its own boundary: `Handoff`, `Handoff.Internal`,
  `Relay`, and `Receiver.Internal`. Callers beyond the three production modules or 400 lines § G allows this
  sprint are adopted by a following sprint.

#### Validation

Closure requires these to exist and pass under the phase gate:

- The existing `HandoffSpec` golden-byte and round-trip cases pass unchanged, which proves wire stability.
- Compile-fail fixture `SwapRootedPayloadDigests.hs` passes a `ChildConfigDigest` where a `PayloadDigest` is
  expected. `SwapLifecycleSessionStage.hs` swaps session and stage in a call to
  `rootedSettledResponseUnsignedKernel`.
- Both fixtures are registered in `CompileFailSpec` with a `Couldn't match expected type` diagnostic naming
  the two newtypes. They are not registered with a hidden-module diagnostic, so they compile through Sprint
  13.1's test-only route.
- A value-level table refuses each smart constructor's malformed input: 63 and 65 hex characters, uppercase
  hex, an empty session or stage, and ordinal 0.

#### Remaining Work

- Introduce the seven newtypes in `Handoff.Rooted` and retype the payload-binding kernels and the six response
  builders `Handoff.Relay` calls.
- Extend Sprint 13.1's test-only route to `Handoff.Rooted`, so a fixture reaches the kernels and fails on the
  swap rather than on the import.
- Adopt the newtypes at `Handoff`, `Handoff.Internal`, `Relay`, and `Receiver.Internal`. Split the adoption
  into a following sprint if it exceeds the § G module cap.
- Add the two swap compile-fail fixtures with their type-mismatch diagnostics, and the smart-constructor
  refusal table.

### Sprint 13.20: Frame-child process trees end on Windows [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/ChildGroup.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Make the Windows row of `Effect.ChildGroup` end a launched child's whole process tree, as the POSIX row
does. The frame-child bracket's "ends the child's whole process tree" then holds on every outer host (§ JJ).
On Windows, `askChildGroupToStop` and `killChildGroup` call `terminateProcess` on the direct child
only, so a grandchild it started outlives the bracket. The ask step is the same hard termination as the kill
step, so on Windows the grace gives the child no graceful stop.

#### Deliverables

- On Windows, `Effect.ChildGroup` assigns each launched child to a Job Object created with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` before the child can start descendants.
- Ending the group terminates and closes the job, which ends every process in it. The job handle is closed on
  every exit path of the bracket, including an exception.
- The Windows code stays inside `Effect.ChildGroup`. `Handoff.Transaction` carries no CPP and calls the same
  launch and end functions on every host.

#### Validation

Closure requires a Windows-gated `HandoffSpec` case that is a no-op on POSIX gate hosts. It launches a child
through `Effect.ChildGroup` that starts a long-lived grandchild and reports the grandchild's process id. It
then ends the child group and asserts that the grandchild has exited within the termination grace. The case
runs in the host static gate (`cabal test all` from `core/`) on a Windows gate host, and that run is recorded
here as dated evidence. A Windows gate host is outer-host portability, not a `windows` substrate declaration.

#### Remaining Work

- Implement the kill-on-close Job Object launch and end path in `Effect.ChildGroup` for Windows.
- Add the Windows-gated grandchild-termination case listed under Validation, and record its run on a Windows
  gate host.

### Sprint 13.21: Child-group teardown follows the captured process group [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/ChildGroup.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Make the POSIX row of `Effect.ChildGroup` end the launched child's whole process group even after the leader
has exited. `signalChildGroup` reads the group id from `getPid child` at each signal, and `getPid` returns
`Nothing` once `getProcessExitCode` has reaped the leader, so a later group signal is silently skipped.
`awaitChildExit` waits for the leader only, and `Transaction.endChildGroup` signals nothing when the leader has
already exited. A descendant left in the group (a provider or nested tool the child started, or one that traps
`TERM`) outlives the bracket.

#### Deliverables

- `Effect.ChildGroup` captures the child's process-group id once, immediately after launch and before any
  `getProcessExitCode`, as an opaque `ChildGroup` value; every signal and wait takes that value, never the
  `ProcessHandle`'s live pid.
- The grace wait polls group presence with `signalProcessGroup nullSignal` on the captured id (the shape
  `Effect.Run`'s `awaitGroupExit` already uses), not the leader's exit code.
- Ending a group always asks the captured group to stop, waits the grace, and sends `SIGKILL` to the group when
  it is still present, whether or not the leader has exited; the leader is then reaped and the pipes closed.
- `Handoff.Transaction.endChildGroup` and `Handoff.Process`'s teardown both use that path; neither skips the
  group because the leader already exited.

#### Validation

Closure requires these POSIX-gated `EffectSpec` cases to exist and pass under the phase gate (the Windows row
is Sprint 13.20's):

- A child launched through `Effect.ChildGroup` into its own group starts a descendant that traps `TERM` and
  sleeps, prints the descendant's pid, and exits. Ending the group signals the captured group, and after the
  grace the descendant is gone (`signalProcess nullSignal` on its pid fails).
- A leader that traps `TERM` itself is killed after the grace, and the bracket returns with the group absent.

#### Remaining Work

- Introduce the captured `ChildGroup` value, the `nullSignal` group-presence wait, and the unconditional
  ask/grace/kill path in `Effect.ChildGroup`, and adopt it in `Transaction.endChildGroup` and `Handoff.Process`.
- Add the two POSIX-gated `EffectSpec` cases listed under Validation.

### Sprint 13.22: Activation manifests and measurements are constructed validated [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Activation.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/test/ActivationSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Apply § HH to the activation package. `Activation` exports `ActivationManifest (..)` and `MeasuredInstance
(..)`, so `KubernetesInstance "" 0` and a manifest with an empty revision are well-typed values that are refused
only late, by `validateMeasuredInstance` and `validateManifest` inside signing or verification.
`verifyRuntimeRoleActivation` takes the selected and the received manifest as adjacent `ActivationManifest`
arguments, so transposing them compiles and swaps the two values in every mismatch diagnostic.

#### Deliverables

- `ActivationManifest` and `MeasuredInstance` are exported abstractly. One validating producer each
  (`activationManifest` over a plain input record, `kubernetesInstance`, `hostServiceInstance`) runs the checks
  `validateManifest` and `validateMeasuredInstance` hold today and is the only way in; read-only accessors
  replace the record field labels.
- `verifyRuntimeRoleActivation` takes `SelectedActivationManifest` and `ReceivedActivationManifest`, two
  distinct newtypes, so passing them in the other order is a type error.
- `renderActivationManifest` and the canonical wire stay byte-identical.
- Each caller constructs the values at its own boundary. Callers beyond the three production modules § G
  allows this sprint (`Command`, `Command.LifecycleEntry`, `Handoff.Relay`, `Lifecycle.Execution`,
  `RoleLifecycle`, and the demo's `Commands`) are adopted by a following sprint.

#### Validation

Closure requires these to exist and pass under the phase gate:

- The existing `ActivationSpec` round-trip and signing cases pass unchanged in wire bytes.
- Compile-fail fixtures `ConstructActivationManifest.hs` (applies the constructor) and
  `SwapActivationManifests.hs` (passes the received manifest in the selected position), each refused with its
  exact diagnostic.
- A value-level table refuses each producer's malformed input with the exact `ActivationManifestInvalid` or
  `ActivationInstanceInvalid` detail: an empty required field, an empty and a duplicated effect identity, an
  empty pod UID, and an empty host invocation nonce.

#### Remaining Work

- Hide the `ActivationManifest` and `MeasuredInstance` constructors behind validating producers and accessors,
  and adopt them in `Service`.
- Add the `SelectedActivationManifest` and `ReceivedActivationManifest` newtypes to
  `verifyRuntimeRoleActivation`.
- Add the two compile-fail fixtures and the producer refusal table listed under Validation.

### Sprint 13.23: Build coordinates are distinct nominal types [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/BuildAuthoritySpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Apply § HH to the build authority. `verifyBuildInvocation`, the sole producer of `ImageBuildFrame` and
`BuildInvocationAuthority`, takes the project name, spec digest, config digest, and coordinator digest as four
`Text` values and the source root and builder path as two `FilePath` values, and `BuildBinding` and
`renderBuildBinding` carry the same roles as bare `Text`. A transposition at the coordinator and the verifier is
then self-consistent from mint to wire and no test distinguishes it.

#### Deliverables

- `Build` defines one newtype per coordinate role (`BuildProjectName`, `BuildSpecDigest`,
  `BuildConfigDigest`, `BuildIdentifier`, `BuildSourceDigest`, `CoordinatorDigest`, `BuilderDigest`,
  `BuildFrameName`, `BuildSourceRoot`, `BuilderPath`), shared by `verifyBuildInvocation`, `BuildBinding`, and
  `renderBuildBinding`.
- The canonical binding bytes are byte-identical to the current wire.
- `Command`'s `check-code` gate and the demo's coordinator construct the newtypes at their own boundary.

#### Validation

Closure requires these to exist and pass under the phase gate:

- The existing `BuildAuthoritySpec` round-trip, signing, and verification cases pass unchanged in wire bytes.
- Compile-fail fixtures `SwapBuildDigests.hs` (spec digest in the config-digest position) and
  `SwapBuildPaths.hs` (source root in the builder-path position), each refused with a `Couldn't match expected
  type` diagnostic naming the two newtypes.

#### Remaining Work

- Introduce the build coordinate newtypes in `Build` and retype `verifyBuildInvocation`, `BuildBinding`, and
  `renderBuildBinding`; adopt them in `Command` and the demo's `Commands`.
- Add the two swap compile-fail fixtures listed under Validation.

### Sprint 13.24: Build, Handoff and Activation hash and frame through Digest [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Build.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Activation.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`

#### Objective

`HostBootstrap.Digest` exports the lowercase-hex `sha256Hex` and the 8-byte big-endian length prefix
`frameWire`, and the build-authority, handoff and activation modules hash and frame with those exports rather
than with byte-identical local copies, so a digest recomputed in one module cannot drift from the one another
module compares it against.

#### Deliverables

- `Build` imports `sha256Hex` from `HostBootstrap.Digest` and defines no SHA-256 helper of its own;
  `measureSourceDigest` and `measureBinaryDigest` render their lowercase hex through it.
- `Handoff` re-exports `HostBootstrap.Digest.frameWire` in place of its own definition, so `Build`,
  `Activation` and every other importer of `HostBootstrap.Handoff (frameWire)` frame through the one export.
- `childConfigDigest` and `recoveryWireDigest` are `HostBootstrap.Digest.sha256Hex`, and `Handoff` defines no
  `digestBytes`.
- `Activation` imports `sha256Hex` from `HostBootstrap.Digest` and defines no SHA-256 helper of its own.

#### Validation

`BuildAuthoritySpec`, `HandoffSpec` and `ActivationSpec` pass unchanged inside
`cabal test all --ghc-options=-Werror` from `core/`, so every digest and frame these modules compute is
byte-identical, and the host static gate (§ JJ) passes.

#### Remaining Work

- Delete `sha256Hex` from `core/hostbootstrap-core/src/HostBootstrap/Build.hs` and import it from
  `HostBootstrap.Digest`.
- Delete `frameWire` and `digestBytes` from `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs` (its
  `word64BigEndian` stays, since the version and generation words call it); re-export `HostBootstrap.Digest.frameWire` from the
  export list and define `childConfigDigest` and `recoveryWireDigest` as `HostBootstrap.Digest.sha256Hex`.
- Delete `sha256Hex` from `core/hostbootstrap-core/src/HostBootstrap/Activation.hs` and import it from
  `HostBootstrap.Digest`.

### Sprint 13.25: The authenticated sibling config install fails closed [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Install/Native.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

A child frame installs the configuration its parent authenticated beside its own executable through
`installAuthenticatedProductionSiblingConfig` and `installAuthenticatedHarnessSiblingConfig`, which take an
`AuthenticatedConfigPayload` and publish with Phase 7's create-if-absent hard link (`linkNoReplace`). The
install fails closed: it never follows a link at the destination or its lock, and a completed install is
never reported as failed nor leaves its temporary behind.

#### Deliverables

- A symlinked or non-regular destination is `SiblingConfigUnsafeDestination`, and a symlinked lock path is
  `SiblingConfigInstallFailed`; neither touches the link target or directory.
- Once `linkNoReplace` succeeds, the temporary is removed best-effort in a `finally`, so neither a throwing
  post-link inspection nor a failed cleanup leaves a `.hostbootstrap-config.tmp*` file or reports a completed
  install as failed.
- Concurrent installers of one payload converge: exactly one reports `SiblingConfigInstalled` and the other
  `SiblingConfigAlreadyPresent`, and a foreign replacement is `SiblingConfigConflict` with its bytes kept.

#### Validation

`HandoffSpec` "authenticated sibling install is atomic, idempotent, and conflict-preserving" covers the
hard-link install, the concurrent replay, and the conflict. The sprint closes when these cases also exist and
pass under `cabal test all` from `core/`:

- `HandoffSpec`: with the sibling path pre-created as a symlink, and separately as a directory,
  `installAuthenticatedProductionSiblingConfig` returns `Left (SiblingConfigUnsafeDestination path)` and the
  link target or directory is untouched; with `<path>.hostbootstrap-handoff.lock` pre-created as a symlink it
  returns `Left (SiblingConfigInstallFailed path)`. Each symlink case skips with a stated reason where the
  host cannot create symlinks.
- `HandoffSpec`: `installAuthenticatedHarnessSiblingConfig` installs and then replays as
  `SiblingConfigAlreadyPresent` under a fixture harness payload.
- `HandoffSpec`: `linkNoReplace` onto a taken destination throws and leaves the destination's bytes intact.
- After every sibling-install case, the binary's directory holds no `.hostbootstrap-config.tmp*` file.
- `HandoffSpec` "authenticated sibling install is atomic, idempotent, and conflict-preserving" forks both
  installers blocked on one shared start `MVar ()` that the test fills only after both threads are waiting,
  and repeats that race 50 times (removing the sibling and its lock between rounds), each round asserting
  exactly one `Right SiblingConfigInstalled` and one `Right SiblingConfigAlreadyPresent`. The sibling path is
  one other specs also write; that sharing is safe only because `test/Spec.hs` runs the tree under
  `localOption (NumThreads 1)`, and a comment on the case says so.

#### Remaining Work

- Wrap the post-link inspection in `createSiblingConfig` (`Config/Schema.hs`) as an action followed by
  `finally removeTemporary` inside the mask, and make `removeTemporary` catch `IOException`, so a cleanup
  failure cannot overturn a completed install.
- Add the `HandoffSpec` symlink, directory, lock, Harness-replay, taken-destination, and no-temporary cases
  listed under Validation.
- Rewrite the `HandoffSpec` concurrent-install race as Validation states.

## Remaining Work

- Sprint 13.1: Test-only route to the hidden handoff owners; value-level Protocol, binding, and challenge
  refusal tables; accessor-only `HandoffBinding`; `ProtocolExcessFields`; `IOException`-only key loaders;
  shared Cabal-seam helper; token-based ordered-fragment helper.
- Sprint 13.2: Five `withVerifiedConfigHandoff` refusal cases.
- Sprint 13.3: delete `HandoffFrameMismatch`; `ProjectPlanSpec` coordinate refusal cases; run the
  joint-admission assertions; Harness profile-name case.
- Sprint 13.4: Bounded `Word64` channel-frame decoding; locale-free, regular-file-only source and builder
  measurement; accurate digest Haddock and module header; two-root, golden, boundary-shift, missing-input, FIFO, and decoder
  refusal cases.
- Sprint 13.5: List-exact effect-row comparison and selected-manifest validation; manifest and policy refusal
  tables; per-field selection mismatches; golden wire and signature vectors; malformed-grant cases.
- Sprint 13.6: A failed CAS on a still-planned record reports `HandoffStoreFailure`; cross-broker and
  rejected-admission cases; rename the cross-edge token-isolation case.
- Sprint 13.7: Config-only payload and `BrokerLink` Haddocks with a payload-argument guard; `adoptRelayedOffer`
  trailing-byte refusal; `brokerRelayFromRouteWire` refusal cases; re-pinned `Handoff.hs` digests.
- Sprint 13.8: Value-level `childProtocolReceive` request-id and transition cases.
- Sprint 13.9: Production rooted-payload signer refusal table; detail-bearing `expectBindingRefusal`; exact
  Ed25519 importer set and facade import allow-list.
- Sprint 13.10: Unmasked malformed-package cases with specific details; production package-signer refusal
  table; delete the derived attribution tuple.
- Sprint 13.11: Root-scope matrix asserts each row's own refusal; delete the orphaned Harness-capsule Haddock
  and the self-comparing attribution literals.
- Sprint 13.12: `announceRefusal` gated by `childProtocolSend`; scripted-parent receiver harness; corrected
  `withReceivedHandoffEdge` Haddock; full signature-tail fragments.
- Sprint 13.13: Getter-only `RecoveryProjectionBindingInput`; 7 MiB sub-ceiling, recovery-phase, verb, and
  cross-paired-proof cases; corrected `ReceivedRecoveryDescent` Haddock; delete literal budget terms.
- Sprint 13.14: Malformed-request table through `withVerifiedRootedLifecycleResponse`; delete
  literal-against-literal guard assertions.
- Sprint 13.16: Detail-bearing `assertRefused` with rebuilt malformed wires; production response-signer
  refusal table; per-family signature refusals; delete the derived budget tuple.
- Sprint 13.17: Requester-envelope bound and provenance refusal cases; token-based Relay guard rows.
- Sprint 13.18: Remove the dead launch timeout and CPP pragma; refusal answers from
  `serveOneFrameTransaction`; leak-free stdio acquisition; exact-token `runCLI` guard; exact crossing
  answer; malformed-stdin process cases; `CLI` header names the five pre-parser entries.
- Sprint 13.19: Private nominal types for the rooted kernel coordinates, adopted by the payload-binding kernels
  and the `Relay` response builders, with swap compile-fail fixtures.
- Sprint 13.20: Kill-on-close Job Object for frame-child process trees on Windows, with a grandchild case.
- Sprint 13.21: POSIX child-group teardown keyed on the group id captured at launch, with a group-presence
  grace and a surviving-descendant case.
- Sprint 13.22: Validating producers for `ActivationManifest` and `MeasuredInstance`; distinct selected and
  received manifest newtypes.
- Sprint 13.23: One newtype per build coordinate role across `verifyBuildInvocation`, `BuildBinding`, and its
  renderer.
- Sprint 13.24: `Build`, `Handoff` and `Activation` take `sha256Hex` and `frameWire` from
  `HostBootstrap.Digest`.
- Sprint 13.25: Sibling-install refusal and temp-cleanup cases, the post-link `finally` cleanup, and a
  barriered install race.

Closing the phase runs the declared **Gate** exactly on a linux-cpu host, and its `**Gate evidence**` row
records each leg by name: focused `HandoffSpec`, the public compile-fail boundary, `ProjectPlanSpec`, and
`DocValidatorSpec`, then `cabal test all -j1` from `core/`.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — the surface this phase changes in it.
- `documents/architecture/build_and_run_model.md` — the surface this phase changes in it.

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
- `documents/README.md` — the surface this phase changes in it.

- `development_plan_standards.md` §§ X, Y, EE, and HH name this phase as the owner of authenticated handoff,
  root scope, rooted wire/receipt vocabulary, and keyless relay transport.
- Phase 17 (the recursive lifecycle command) consumes these contracts for root-owned durable coordination and
  storeless frame execution.
- Phase 19 (test harness and run ownership) supplies the exact Harness run evidence consumed by the generic
  authenticated-scope producer.
- Phase 24 (the worked demo) consumes Build authority and confirms the recursive lifecycle on its live
  provider chain.
