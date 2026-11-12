# Binary Context and Authenticated Configuration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [composition methodology](composition_methodology.md), [Dhall generation](dhall_generation.md), [hostbootstrap core library](hostbootstrap_core_library.md)

> **Purpose**: Describe how a binary's declared frame, exact plan, installed identity, authenticated
> handoff, and service activation combine without treating configuration text as authority.

## TL;DR

The sibling `<project>.dhall` contains parameters, descriptive context, and locally checkable witnesses.
There is no separate context file; `Context` exposes no standalone context-file reader or writer.
The plan lives in code. An installed root, authenticated child handoff, verified build invocation, or signed
service activation supplies authority independently of the decoded description.

An authenticated child installs its exact payload beside its executable through the Production or
Harness sibling-config installer. A regular file with identical bytes is an idempotent replay; foreign
bytes are a conflict and stay intact. A symlink or non-regular destination is unsafe, and a symlinked
install lock refuses before its target is opened. Publication uses the native create-if-absent hard link
under the sibling lock, so concurrent installers converge on one creator and one replay. Post-publication
inspection always attempts temporary removal in a finalizer; cleanup is best-effort and cannot overturn a
completed publication. An unavailable reread after a successful link likewise cannot report that completed
install as failed, while a readable foreign replacement retains its explicit conflict or unsafe refusal.

One root coordinator owns the protected store and recursive catalog. Children are storeless executors of
catalog-selected grants. A service uses a narrowed immutable role wire and a restartable signed activation;
it never reads the sibling full project config to decide what it may do.

[Composition methodology](composition_methodology.md) owns plan authoring.
[Lifecycle state model](lifecycle_state_model.md) owns journals, recovery, reverse traversal, and closure.
The [development-plan index](../../DEVELOPMENT_PLAN/README.md) owns dated evidence and phase status.

## The Contract

A descriptive frame tag cannot widen a command's authority. Root entry joins executable-bound installed
identity, protected-store origin, root liveness, exact scope/plan/frame, closed verb, and one-use admission.
The command-reservation kernel in
[Authority.Kernel](../../core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs) records each
invocation identity once: the first writer wins and a conflicting record refuses. A consumed record refuses a
second delivery with one exception, `reverseRootReplayEligible`: a root `project down` or `project destroy`
reservation in the Teardown phase whose stored record is byte-identical re-delivers authority under that
record's version instead of refusing. Every other verb and phase stays strictly one-use.
A command authority retains the store origin of its indexed broker epoch. A boundary receiving a
store separately checks `commandAuthorityMatchesStore` before effects; an authority from another
store fails that check even when the installed project is the same. The public authority error sum
contains only refusals constructed by a kernel or gate. The all-library source guard distinguishes
construction from declarations, message-rendering arms and other pattern occurrences.

The private `Chain.EntryPolicy` module owns four ordered current-frame checks before Chain opens its
journal: the authority belongs to the supplied store; its acquisition origin matches the cursor; their
retained frames agree; and that frame belongs to the admitted topology. The policy consumes the real
lower-unit authority and store. Main supplies the actual cursor-origin predicate and descriptive cursor
frame and ordered topology frames. Main and tests import one compiled `chain-entry-internal` unit;
the policy imports no main cursor or topology representation and creates no authority. `VerbUp` and
`ExecutePhase` are fixed by the entry's types and checked by the named compiler refusals.

The replay decision enumerates every member of the closed verb and phase vocabularies. Only Down
and Destroy paired with Teardown admit byte-identical replay; adding a verb or phase therefore
requires an explicit decision. The canonical length-prefixed identity includes project, store, plan,
frame, epoch, verb and phase. Project/store mismatches refuse before reservation writes, and foreign
bytes at its digest key refuse without consuming or overwriting them.

Child entry independently verifies the installed key, authenticated root scope, exact payload and edge, and
catalog-selected grant. Service entry verifies the independently installed activation and measured instance.

The root's scope is either Production or one generative Harness run. Public parsing of a run name cannot
recreate the Harness identity. Scope introduction occurs only inside a rank-2 producer or verifier; its
nominal indices remain attached to the plan, wire, lease, and authority.

## The .dhall: Parameters, Context, And Witness

| Component | Meaning | Authority limit |
|---|---|---|
| Parameters | Project-owned resource, deployment, and role values | Cannot select arbitrary plan operations |
| Context | Binary identity, current frame, role and topology description | Must agree with independently admitted evidence |
| Witnesses | Facts the binary can check at its interpreting frame | A matching description does not mint a capability |

Core supplies no project config type or default values. Production and Harness use mapped codecs over the
project's config family. `CodecWitness` validates encoder/decoder schema agreement; `ProjectCodec` retains
scope and specification identity. The finalized service registry stamps its role codecs with that same
specification digest.

### Context Shape

`ContextKind` describes host orchestrator, VM orchestrator, image-build container, VM project container,
cluster service, daemon, one-shot job, and test harness positions. Topology gives frames semantic identities,
parent relationships, providers, roles, and required witness declarations. The validating constructors reject
duplicate, disconnected, cyclic, illegal-placement, and incomplete graphs.
Exactly one root, resolving every parent, and rejecting cycles already establish reachability in a finite
graph. A disconnected graph therefore receives its specific root-count, missing-parent, or cycle refusal.

Placement follows the declared frame kind, provider, and parent kind. The ancestor relation covers every
context kind, and command placement checks distinguish root and non-root frames. `addRole` consults that
placement before adding `ClusterService`: a host-resident daemon cannot gain the role's Kubernetes
capabilities through this union. Only a cluster-daemon or cluster-service placement admits that additional
role.

`CurrentFrame`, `ProjectFrame`, and `ValidatedContext` are pure evidence derived together from the admitted
plan and description. They do not open a protected store, journal, cursor, or invocation. The root lifecycle
entry joins that package to the exact durable origin before it interprets effects.

### Installed Identity and the Lower Authority Kernel

[Identity.Install](../../core/hostbootstrap-core/src/HostBootstrap/Identity/Install.hs) provisions identity
beside the installed executable. [Authority](../../core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Authority.hs)
verifies that executable identity and the exact protected-store origin and introduces the live root scope.
Private kernels own constructors; public consumers receive only the evidence and eliminators they require.

`verifyOsPrincipal` creates and removes a probe in the exact protected records directory. Its opaque
`VerifiedOsPrincipal` retains that store's identity. Both fresh and existing root kernels refuse evidence
issued for another store with `AuthorityOperatorRefused`, before delivering a root callback or changing
that store's records. The principal supplies no lifecycle verb, scope, plan or broker epoch by itself.

`authorizeRootProject` receives the original executable-verified `InstalledProjectIdentity` through
`Command.LifecycleEntry`. It compares that identity's name with the root's retained project and returns
`AuthorityStoreNotOurs` before reservation on disagreement. The verified name also supplies its plan and
snapshot project checks, alongside matching root frame, lifecycle context, cursor, and verb evidence. The sealed
`Command.LifecycleEntry` owns the root store and exact plan through forward and reverse execution. Operator
`project up|down|destroy` starts at the installed root; authenticated children enter through the private
process route, not by asking a descriptive nested config to mint root authority.

That same verified identity reaches `reserveCurrentLifecycleCommandKernel` inside its existing
protected entry. The bridge revalidates live journal, source and current-cursor evidence, then supplies
the identity directly to the reservation kernel. It does not reconstruct the comparator from the
journal's recorded project name.

Durable cursor frame limits count encoded UTF-8 bytes. The canonical record bounds and exact no-write
resume behavior belong to the [lifecycle state model](lifecycle_state_model.md#lifecycle-profile-authority).

`ValidatedLifecycleContext` retains the jointly admitted frame views and the root-owned store; it remains
inert and has no public store or authority projection. Its public admission and private membership boundary
are defined in the [lifecycle state model](lifecycle_state_model.md#lifecycle-profile-authority).

## Topology Shape

The demo's VM-backed route has metal, VM, and project-container frames. The Direct Linux GPU route has metal
and a direct project container. The finalized project projector derives the exact child configuration and
plan for each declared edge. The root catalog recursively validates those edges before effects and retains
the canonical payload, digest binding, one-layer lift route, and projected node keys.

A frame has one declared descent where its successor becomes meaningful. VM bootstrap establishes the child
binary first; a container image already contains it. The node's action may announce that boundary, while the
interpreter performs the authenticated descent bound to the same plan node.

### The Closed Required-Witness Relation

Topology determines which local witnesses are required. Validation checks the exact declared set and then
observes it in the frame that interprets it. A guest path is checked with guest POSIX grammar even if it was
derived on Windows; a host path uses the host grammar. `Effect.Vocabulary.framePathGrammar` and the shared
Lift fold carry that distinction into command interpretation.
Witness-set refusals identify each missing and unexpected witness by kind and name, and include the value
for an environment-equality witness. A stale current-frame declaration therefore reports both the expected
and declared values.

A host-side conventional path, arbitrary provider name, or copied context record cannot substitute for the
exact provider/share or cluster dependency selected by the plan. Unsupported observation is a refusal before
effects, not permission to omit a witness.

## Per-Frame Fail-Fast On Handoff

The [authenticated handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
owns the bounded canonical wire, scope capsule, binding, challenge/grant, and keyless relay.
The [recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
owns its installed root/child process consumer.

The root link signs one `AuthenticatedRootScope` capsule from its live broker and exact scope. Nested links
retain those exact bytes and receive no signer. The receiver verifies the capsule against the independently
installed identity and key before interpreting the payload. Ordinary offers bind exact configuration bytes;
recovery offers retain the complete `RecoveryChildPackage` and distinct `RootedPayloadBinding`. Truncated,
trailing, mismatched, or noncanonical packages refuse.

The nominal `AuthenticatedRootScope scope` proves installed project scope and key identity only; it has
no broker-generation index and conveys no root, Harness, command, store or signing authority. Its seven
frames carry the codec domain, fixed Word64BE version, installed project, closed scope kind, exact run,
installed-key digest and 64-byte signature. Production has an empty run; Harness has a canonical nonempty
run. The producer derives those fields from its live broker and matching scope under private admission.
Verification uses independently installed project identity and key before either scope callback runs.

Capsule framing preserves `HandoffWireTruncated` and `HandoffWireTooLarge`: a declared 64-byte signature
truncated to 63 bytes is `HandoffWireTruncated 64 63`. A complete 63-byte signature frame instead has the
semantic wrong-width `HandoffBindingMismatch`. Domain, version, project, key, kind and run checks retain
their specific binding-mismatch details; an extra trailing frame retains the shared decoder's trailing
binding mismatch. After valid framing and semantic checks, cryptographic verification failure yields
`HandoffAuthenticatedRootScopeSignatureInvalid`. These primitive scope/codec checks supply no Offer,
receiver-placement or lifecycle-coordinator integration evidence.

The scope-first receiver keeps the Offer's four bounded opaque fields unchanged. Structural decoding may
bound and split those fields before capsule verification; binding and payload semantics wait for the
verified capsule's closed Production/Harness continuation. A valid Harness capsule selects the Harness
branch, whose binding must agree with that authenticated scope. Outer missing/excess field refusals retain
`ProtocolWrongFieldCount` or `ProtocolExcessFields` through `ReceiverProtocolFailure`. Before an Offer has
been decoded, there is no active request identity to answer, so the receiver emits no refusal frame.
Accepted parent refusals and acknowledgements consumed by either Receiver or Relay update the same real
child protocol state before a later failure can attempt to announce anything. That terminal state also
blocks later report sends and relay requests locally, before another protocol frame can be written.
Relay's own successfully transmitted upstream refusal closes that same retained edge and preserves the
original error. A local validation failure before transmission leaves it open for Receiver's refusal.

After scope authentication, the receiver bounds the embedded Offer payload at 7,340,032 bytes before
reading its installed-key digest or binding, sending a Challenge, or selecting a branch. Exactly that
size is allowed; one byte more refuses. This semantic sub-ceiling is separate from Protocol's 8 MiB
total-body limit, which also includes the other Offer fields and framing overhead.

`RootedPayloadBinding` separately frames the signed complete-payload and child-config digests. The direct
config signer requires private signing admission and a live broker, refuses recovery-kind offers, empty
payload/config bytes and unequal nonempty configuration bytes, and retains the broker's exact verb check.
Its matching config path derives both claims from the same exact configuration bytes. Broker generation
is nominal; the immediate-edge payload digest is already fixed by the opaque `mkHandoffOffer` producer. That producer's
refusal and the offer's private constructor/fields and nominal roles establish this immutable invariant;
a genuine offer cannot exercise the final signer backstop with a mismatched immediate payload digest.

`Handoff.Rooted` owns the pure canonical codec. The `Handoff` facade fixes the signature domain and gates
signing through private `Handoff.Internal` admission. Verification requires the exact `VerifiedHandoff`
and independently installed key. Durable token consumption belongs to root-side grant issuance;
child verification is stateless. Ed25519 imports are confined to the actual production owners `HostBootstrap.Activation`,
`HostBootstrap.Handoff` and `HostBootstrap.Build`; the rooted codec
introduces no generic signing capability.

`RecoveryChildPackage` is exactly two canonical length-framed nonempty fields: child configuration and
recovery adapter. Its complete wire, including both headers, is bounded at 8 MiB. The public facade
exposes the abstract value and renderer; the hidden neutral codec owns construction, decoding and field
access. The package signer accepts that value, derives both digests and requires the offer to carry its
exact canonical bytes, without independent caller-supplied config bytes or digest claims.

After handoff and rooted authentication, strict package decoding precedes the join's embedded-config
digest comparison. Malformed-package validation retains valid prior authentication and the intended
extracted-config digest so that a later digest refusal cannot mask truncation, empty-field, trailing-byte
or oversized-field diagnostics. The ordinary handoff bound already refuses a complete oversized package
before this public join; the neutral codec's own bound remains a separate source/API contract.

`RecoveryProjectionBindingInput` retains its three descriptive coordinates behind private record labels.
The existing `requestedRecoveryPlanDigest`, `requestedRecoveryParentFrame` and `requestedRecoveryChildFrame`
names are ordinary getters. They preserve the generative bracket's nominal indices without permitting
field replacement or type-changing record updates. The private `ReceivedRecoveryDescent` retains the
verified rooted binding, package, closed verb, projection, grant and verified adapter. Its six-argument
eliminator passes the received edge, rendered package, closed verb, authenticated adapter bytes, rendered
projection and grant signature. It forces the rooted binding without exposing the retained typed
package/projection/grant/wire proofs; the four byte views come only from that evidence.

Root-backed `BrokerLink` constructors retain live root brokers and their admission predicates, including
the coordinator-specific root links. The relayed constructor retains only its authenticated route,
request identity, installed-key digest and duplex channel; it carries no signing key or root-store authority.
`offerHandoffEdge` opens the exact narrowed project config bytes. Recovery edges use the existing
reverse-descent opener. `brokerRelayFromRouteWire` checks all five authenticated-route coordinates and
all seven supplied opening-request coordinates before constructing a relay. The shared exact-offer
decoder preserves `HandoffWireTrailingBytes n` for bytes after its three frames; the rooted-signing
route returns that failure as `RelayHandoffFailure` and sends an `unauthenticated` refusal to its peer.

The sealed requester envelope carries one to 256 nonempty UTF-8 components, each at most 4,096 encoded
bytes, in root-nearest-to-leaf order. Receive-side grammar and admitted-child/path-origin checks precede
forwarding or root-service entry. Boundary DATA controls capture the exact path and request at that
service and return a declared sentinel refusal; 256 components or a 4,096-byte component does not mean
256 nested processes or successful lifecycle execution. Received outer refusal code/detail bytes and
signed inner `Refused` remain distinct, without translation or re-signing by the relay.

Duplex channel-loss validation distinguishes failure before root action, with no admission callback or
protected-state change, from loss after a durable grant. Retrying the same offer and challenge requires
a fresh legitimate route to the same still-live root broker and preserves the deterministic response and
settled token bytes/version. That route setup is accounted for separately from the retried request;
the nested link gains no signer or coordinator admission policy.

Root registration publishes the exact canonical binding as a planned one-use edge before grant issuance.
Admitted registration runs its plan predicate once; rejection preserves that reason and creates no edge.
`grantHandoff` checks the live broker and registered binding without rerunning that predicate. Broker and
offer retain one nominal generation. The first grant records its transcript; an identical retry retains
the same bytes, record version and deterministic signature, while a different transcript is consumed.
Concurrent identical requests converge through the broker lifetime guard and protected entry; this
serialization does not imply a forced competing-CAS interleaving. After a failed first-grant write, a
private pure DATA policy distinguishes exact granted bytes, exact planned bytes, absence, another retained
row and reread failure. Exact granted bytes succeed; planned bytes or absence retain the original write
failure, another row is consumed, and a reread failure retains that actual failure. The policy performs
no store operations and grants no authority.

`HandoffBinding` stores its thirteen admitted coordinates behind private record labels. Its existing
public readers are ordinary functions, so they expose no record-update path or type-changing phantom
update. Canonical binding bytes and nominal scope/broker roles retain their contracts. Public parser
tables distinguish structural request decoding from semantic required-field admission; received token
commitments are checked against the actual offer bytes. Installed signing and verification key reads
catch ordinary IO failures while asynchronous exceptions propagate. The
[binding boundary rationale](../../DEVELOPMENT_PLAN/rationale.md#handoff-bindings-retain-their-admitted-fields)
records the compiler and value-level controls.

Canonical config validation and authenticated byte admission jointly produce `VerifiedConfigWire` and
`ValidatedConfig` under one fresh `configId`, retaining the same canonical digest. Recovery specification
reindexing preserves that identity, digest and decoded value. `withVerifiedConfigHandoff` checks the config
payload kind, signed child digest against the verified wire, signed specification digest against the
validated config, requested verb, and closed prepare/execute/teardown phase in order. The wire-digest check
also covers the validated config's digest through their joint provenance. Refinement retains the existing
opaque config identity while introducing signed plan/frame indices inside its rank-2 continuation.

`withChildProjectPlan` carries that refinement into local plan admission. Project, protected-store origin,
broker generation and lifecycle scope are derived from the signed binding; verb, config identity and digest
retain their prior refinement. The opaque drafts supply the canonical root and undergo root, specification,
configuration and structural admission before the rebuilt stable plan digest is compared with the signed
revision. `ChildPlanAuthority` proves this admission without granting execution capability. The
[lifecycle state model](lifecycle_state_model.md#cross-process-authority-handoff) distinguishes these
Production/Harness DATA proofs from coordinator integration.

Handoff's production implementations have one compiled owner in the Cabal-private
`handoff-implementation-internal` unit. Main reexports the 29 public members and retains its existing
104-module effective facade. Its 19 additional private implementation imports grant no public route;
core-test's explicit mixin selects only `Handoff.Protocol`, `Handoff.Receiver`, `Handoff.Relay` and
`Handoff.Internal` from the same unit. Five implementation modules remain unexposed within that unit.
This component boundary permits value-level tests of the real implementations without constructing a
second broker, binding or authority identity. The [Cabal layout](../engineering/cabal_layout.md#package-stanzas)
states the source ownership and independent DATA exceptions; the
[compiler-context rules](../engineering/testing.md#one-toolkit-for-reading-this-repositorys-own-sources)
state the required visibility and identity controls.

The protocol decoder consumes only the closed tag's expected bounded fields.
`ProtocolExcessFields tag expected excessBytes` reports the actual unconsumed body bytes after those fields.
An outer declaration above the 8 MiB body limit yields `ProtocolBodyTooLarge`; an oversized nested field
declaration yields `ProtocolFieldTooLarge` without allocating its claimed payload. Truncation and bytes following
the complete outer frame retain separate refusals.

Codec/FSM DATA validation requires canonical encode/decode positives, exact malformed-input constructors
and coordinates, and genuine successful setup transitions before testing each invalid child receive/send
state/tag pair. Request and acknowledgement checks compare the exact request identity and derived bytes.
The rooted request/response tags each carry one bounded field. Only `ChildRunning` may send a
rooted request; `ChildAwaitingResponse` retains its request identity and sole expected response tag.
A matching rooted response resumes `ChildRunning`. After completion, `ChildAwaitingAcknowledgement`
checks request identity before acknowledgement bytes; a matching acknowledgement or refusal finishes.
An unsolicited, duplicate or post-terminal rooted response is an invalid transition. Before any offer
has established a request identity, `ChildAwaitingOffer` may receive a refusal and finish without that
identity comparison. Connected-pipe DATA observations preserve this initial exception while checking
the later exact identity, waiting-state and acknowledgement rules.
These checks cover the shared codec and child-state implementation; recursive process adoption remains with
the [recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).

The root catalog is the sole authority for selecting a lifecycle edge and node. `OpenFrame` has no caller
chosen session coordinate; its sealed external envelope supplies ancestry. A verified `Opened` response
returns the admitted path, root-issued session, stage, and ordinal. Subsequent requests bind path, session,
nonce, ordinal, and predecessor digest. The root requires inner path, envelope, and retained session path
to agree before any mutation. Response variants remain paired with the exact request family.

A `FrameExecutor` is created only after this verification. A signed `Prepared` answer contains the exact
node, dependencies, operation gate, and projected gates; the executor compares all of them with its locally
reconstructed plan before reifying a prepared gate. It performs the local effect and returns observations.
The root alone writes journal settlement and receipt state.

Completion follows Published → signed `FrameComplete` → `ReceiptConfirm` → Received → signed
`ReceiptRecorded`. Exact replay converges under the retained request identity; a sibling path, changed nonce,
wrong ordinal, or different predecessor cannot borrow the result. Reverse traversal uses the same root
catalog and waits for exact child subtree settlement before proceeding to the parent.

The process owner renders its route through the one Lift fold, isolates inherited descriptors, bounds
handshake/control frames, handles cancellation and process groups, and reaps the child. This protocol checks
cooperating-interpreter ancestry; it does not claim identity against a malicious launching parent.

## The `context` Command: Read-Only Introspection

The [command surface inventory](hostbootstrap_core_library.md#surfaced-commands) is canonical for the
`context` subcommands and their flags; [Dhall topology](../engineering/dhall_topology.md) covers the
Dhall side. In summary: `context inspect` reads the executable-sibling config and marks the current frame
in the rendered composition. `context show [FILE]` reads the selected file; its default is the bare
`<project>.dhall` filename, resolved against the current directory. `context path` prints the canonical
config filename (`<project>.dhall`), not a path; the canonical file lives beside the executable.
`context schema` and `context render` inspect the static `ConfigArtifact` registry, not the project-local
service schema. `service schema` prints that separate service vocabulary.

These commands do not acquire lifecycle authority or mutate providers. They describe the frame and artifacts
that effectful commands must independently admit.

### Context Creation Is Internal Lifecycle Work, Not a Verb

Python builds and launches the native binary; it never writes Dhall. The binary rejects a declared project
name that differs from its executable identity before dispatch.

`project init` is config-free. Its no-flag default writes the executable-sibling host-orchestrator config and
refuses an existing output. Explicit role/output/write-policy flags remain supported: `--force` overwrites and
`--if-missing` preserves. They are mutually exclusive spellings of one `ExistingOutputPolicy`, so
asking for both does not parse rather than being resolved by a precedence rule. Role additions still pass the
closed compatibility validator. A written description is not installed authority.

Canonical role names come from `configRoleNames`, derived from `allContextKinds`, and are shared by
parsing, help, and unknown-role diagnostics. The explicit short aliases are `host`, `vm`, `container`,
`ad-hoc-container`, `image-build`, `service`, `one-shot`, and `test`. Parsing trims surrounding whitespace,
ignores case, and treats underscores as hyphens.

Two routes provision the installed identity, and both call `provisionInstalledIdentity` in
[Identity.Install](../../core/hostbootstrap-core/src/HostBootstrap/Identity/Install.hs) for the running
executable:

1. The Python builder invokes the binary's private `--hostbootstrap-install-identity` entry immediately
   after copying a newly built binary to its stable path. That entry is listed with the other
   [entries before the parser](hostbootstrap_core_library.md#entries-before-the-parser).
2. `project init` provisions when the **parsed role** is its default (host orchestrator) and the output
   resolves to the executable's own sibling `<project>.dhall`. The decision does not depend on a write:
   `--if-missing` over an existing sibling config preserves the file and still provisions, while the
   default refuse policy over an existing file fails before provisioning. `--role` accepts aliases and
   normalises case and separators, so `host`, `host-orchestrator`, and `HOST_Orchestrator` name one role
   and provision alike; an alternate output path or any other role provisions nothing.

Provisioning installs or validates five sibling artifacts: the handoff signing seed and its public half
(`<executable>.handoff.key`, `<executable>.handoff.pub`), the distinct build signing seed
(`<executable>.build.key`), and the distinct activation signing seed and its public half
(`<executable>.activation.key`, `<executable>.activation.pub`). It is idempotent: existing valid
identities are retained across rebuilds and a missing public half is repaired from its retained seed,
but a public key without its secret, or a mismatched pair, is refused rather than replaced.

The initialization fixtures bracket the sibling config and identity paths. They restore the exact
bytes of files present beforehand and remove files created at originally absent paths, including
when a case exits exceptionally. Identities installed by the suite driver remain part of its setup.

`service init` is the third writer of a project-local `<project>.dhall`. It takes the same flags and
`ExistingOutputPolicy` as `project init`, defaults to the cluster-service role, and never provisions
installed identity.

`test init` writes the thin test configuration. The Harness assembles each exact run configuration under its
own generative authority and owns the generated sibling file. Service deployment projects a narrowed role
wire and installs an immutable activation revision. No missing-config path silently invokes an initializer.

## Docker Defaults And Service Overrides

The image's build configuration describes `ImageBuildContainer` and supports the build-time vocabulary.
It does not authorize an attested build by itself. The build consumer verifies an ephemeral
`BuildInvocationAuthority` against the engine's exact source/config measurements and running executable,
consumes one channel presentation, and records the terminal outcome. The output image digest is a build
result, not an input known before the build.

Runtime parent/child execution uses the root catalog's authenticated package. The receiver verifies the
scope, installed key, exact payload, and edge before dispatch. A baked config and a reachable Docker socket
cannot together manufacture project lifecycle authority.

## Config Snapshot And Daemons

A service definition packages its config projection, typed declared effect row, immutable resource draft,
resource backend, payload backend, and `ProgramServiceHandler`. The handler receives only the selected
opaque `RoleParams` and returns `ServiceProgram payload service effects ()`. It cannot inject arbitrary IO.

Deployment installs a signed digest-addressed revision containing narrowed role wire, private bundle,
manifest, signature, and verification metadata. Exact installation retry converges; conflicting members are
not overwritten. The platform supplies absolute revision, independent activation-key, and authority-store
coordinates. `service run` measures its executable and installed payloads, derives the pod UID/restart count
or host invocation nonce, and verifies that complete activation before it decodes the selected role.

The runtime admits or exactly reopens one role plan, compares the declared effect row to the signed ceiling,
and then releases the global protected entry. Prereq → Acquire → Ready → Serve → Drain → Exit runs under the
service/frame generation lease. Ready supplies the only acquired handles the program may name; Drain
attempts every release and aggregates failures. Independent services may serve concurrently under the same
store because neither retains the global store lock throughout Serve.

Restart uses the immutable activation and measured instance. It does not require the original project-Up
broker and cannot authorize project lifecycle mutation. `service run` never loads sibling full project
configuration, selects an arbitrary sibling service, or rereads a second config projection beside its request.

## Demo Contexts

The VM/provider, project-container, cluster service, and host daemon placements are consequences of the exact
project plan. The CPU floor is `linux-cpu`; Apple, NVIDIA, and Windows capabilities affect the provider or
execution placement selected by the plan. The [demo runbook](../operations/demo_runbook.md) describes actual
operator commands and the owning acceptance phases record live evidence.

## Secrets Are Never In The Context

Context contains no secret value. `SecretRef` is scope-indexed; Harness plaintext requires exact run authority
and is absent from Production schema. Core does not resolve Vault, KMS, or project secrets. A service's private
bundle is independently measured and verified with its activation, and diagnostic errors do not print it.
See [secrets](../engineering/secrets.md) and [registry credentials](../engineering/registry_credentials.md).

## Current Status

Installed root entry, scope-first authenticated child admission, root-owned recursive settlement, recovery,
and signed service runtime are implemented. Pure context and wire values remain descriptive deliberately;
they are consumed beside independently verified authority, not promoted into it. Exact signatures live in
`Authority`, `ProjectPlan`, `Handoff`, `Command.LifecycleEntry`, `Service`, `Activation`, and `RoleLifecycle`.

The public `Config.Schema.withSiblingProjectConfigContext` gate reads the executable's sibling project
config through the scoped codec, admits its canonical source root, and checks its runtime context before
running the callback. Missing config, undecodable bytes, and a context that refuses the command each
produce a diagnostic and exit status 1 without reaching that callback.

`context inspect` and `context show` decode the selected file with the binary's one Production
`ProjectCodec`, the only project codec a command obtains without a run's `HarnessConfigAuthority`. The
rendered composition is a `BinaryContext`, which carries no scope, so the output asserts none: a
Harness-written config whose wire is also a valid Production wire renders, and one carrying a Harness-only
value fails the decode. Today a service role wire also fails as a generic decode diagnostic. Refusing a role
wire through the first-stage envelope check before any decode, and naming the Production codec in the
decode-failure line, are owed by the
[`test`-and-`context`-commands phase](../../DEVELOPMENT_PLAN/phase-20-test-and-context-commands.md).

## Validation

Run `cabal test all` from `core/`. Configuration and CLI cases verify schema, selection,
help, wrong-wire-kind messages, and missing-coordinate refusals. Handoff and recursive process cases verify
exact scope/package/edge/session correspondence, bounded protocol, descriptor ownership, settlement, and
receipt order. Activation and role cases verify immutable installation, measured execution, one-use admission,
Ready-only handles, effect ceilings, and drain behavior. Compile-fail cases pin nominal indices and private
constructors; documentation and source guards prevent obsolete authority routes from returning.
`ContextSpec` exercises the public sibling gate's missing, invalid-UTF-8, and context-refused paths,
checking exact stderr, exit status, and an untouched callback while restoring any prior sibling bytes.

A compiled local child proves native protocol and root-store behavior. It is not evidence that a VM, container,
or accelerator ran; the live acceptance phases own those gates. Unsupported platform rows assert their actual
refusal and retain their declared case counts. See [testing](../engineering/testing.md).

## See Also

- [Lifecycle state model](lifecycle_state_model.md)
- [Composition methodology](composition_methodology.md)
- [Dhall generation](dhall_generation.md)
- [Dhall topology](../engineering/dhall_topology.md) — the Dhall-side topology, generated child configs,
  and the configuration set
- [hostbootstrap core library](hostbootstrap_core_library.md#surfaced-commands) — the canonical command
  inventory, including the `context` subcommands
- [Unrepresentable state](unrepresentable_state.md)
