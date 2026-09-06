# Binary Context and Authenticated Configuration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [composition methodology](composition_methodology.md), [Dhall generation](dhall_generation.md), [hostbootstrap core library](hostbootstrap_core_library.md)

> **Purpose**: Describe how a binary's declared frame, exact plan, installed identity, authenticated
> handoff, and service activation combine without treating configuration text as authority.

## TL;DR

The sibling `<project>.dhall` contains parameters, descriptive context, and locally checkable witnesses.
The plan lives in code. An installed root, authenticated child handoff, verified build invocation, or signed
service activation supplies authority independently of the decoded description.

One root coordinator owns the protected store and recursive catalog. Children are storeless executors of
catalog-selected grants. A service uses a narrowed immutable role wire and a restartable signed activation;
it never reads the sibling full project config to decide what it may do.

[Composition methodology](composition_methodology.md) owns plan authoring.
[Lifecycle state model](lifecycle_state_model.md) owns journals, recovery, reverse traversal, and closure.
The [development-plan index](../../DEVELOPMENT_PLAN/README.md) owns dated evidence and phase status.

## The Contract

A descriptive frame tag cannot widen a command's authority. Root entry joins executable-bound installed
identity, protected-store origin, root liveness, exact scope/plan/frame, closed verb, and one-use admission.
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

`CurrentFrame`, `ProjectFrame`, and `ValidatedContext` are pure evidence derived together from the admitted
plan and description. They do not open a protected store, journal, cursor, or invocation. The root lifecycle
entry joins that package to the exact durable origin before it interprets effects.

### Installed Identity and the Lower Authority Kernel

[Identity.Install](../../core/hostbootstrap-core/src/HostBootstrap/Identity/Install.hs) provisions identity
beside the installed executable. [Authority](../../core/hostbootstrap-core/src/HostBootstrap/Authority.hs)
verifies that executable identity and the exact protected-store origin and introduces the live root scope.
Private kernels own constructors; public consumers receive only the evidence and eliminators they require.

`authorizeRootProject` consumes matching root frame, lifecycle context, cursor, and verb evidence. The sealed
`Command.LifecycleEntry` owns the root store and exact plan through forward and reverse execution. Operator
`project up|down|destroy` starts at the installed root; authenticated children enter through the private
process route, not by asking a descriptive nested config to mint root authority.

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

`context inspect` reads the sibling config and marks the current frame in the rendered composition.
`context show [FILE]` reads the selected or default file. `context path` prints the canonical config path.
`context schema` and `context render` inspect the static `ConfigArtifact` registry, not the project-local
service schema. `service schema` prints that separate service vocabulary.

These commands do not acquire lifecycle authority or mutate providers. They describe the frame and artifacts
that effectful commands must independently admit.

### Context Creation Is Internal Lifecycle Work, Not a Verb

Python builds and launches the native binary; it never writes Dhall. The binary rejects a declared project
name that differs from its executable identity before dispatch.

`project init` is config-free. Its no-flag default writes the executable-sibling host-orchestrator config and
refuses an existing output. Explicit role/output/write-policy flags remain supported: `--force` overwrites,
`--if-missing` preserves, and force takes precedence when both are present. Role additions still pass the
closed compatibility validator. A written description is not installed authority.

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

## Validation

Run `cabal test all --ghc-options=-Werror` from `core/`. Configuration and CLI cases verify schema, selection,
help, wrong-wire-kind messages, and missing-coordinate refusals. Handoff and recursive process cases verify
exact scope/package/edge/session correspondence, bounded protocol, descriptor ownership, settlement, and
receipt order. Activation and role cases verify immutable installation, measured execution, one-use admission,
Ready-only handles, effect ceilings, and drain behavior. Compile-fail cases pin nominal indices and private
constructors; documentation and source guards prevent obsolete authority routes from returning.

A compiled local child proves native protocol and root-store behavior. It is not evidence that a VM, container,
or accelerator ran; the live acceptance phases own those gates. Unsupported platform rows assert their actual
refusal and retain their declared case counts. See [testing](../engineering/testing.md).

## See Also

- [Lifecycle state model](lifecycle_state_model.md)
- [Composition methodology](composition_methodology.md)
- [Dhall generation](dhall_generation.md)
- [Unrepresentable state](unrepresentable_state.md)
