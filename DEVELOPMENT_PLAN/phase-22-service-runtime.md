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
- Role parameters are least-authority: a handler receives only what its declared role needs. A
  `ServiceHandler` takes the opaque `RoleParams specDigest configId secretDigest fields service` bundle the
  role's own projection produced, and nothing else. It carries no `LocalContextView`, so a handler that
  needs a framework datum declares it as a role field and the projection supplies it; the demo's
  accelerator takes its source root that way. The indices are universally quantified, so a handler cannot
  pair a bundle from one finalization with another's.
- **What** a handler may do is bounded by the same discipline: it returns the effect-indexed
  `ServiceProgram` of Sprint 22.2, where an undeclared effect is a compile error. Least authority over the
  input and an unbounded result would be half a boundary — a web role could spawn a process and an
  accelerator role could reopen the sibling config — so the return type is part of this contract rather
  than a later tightening of it. Sprint 22.3 installs the signed activation the interpreter demands, which
  is why the two land together.
- The handler runs on the same bundle the validated request carries, not on a second projection of the config
  beside it, and `selectServiceAction` no longer takes a framework view at all.
- A missing service configuration produces a service-specific recovery message naming the variant and the field.
- The registry-selected action enters the role machine as its serve step, narrowed to an effect-indexed program.

#### Validation

`RoleLifecycleSpec` and `CLISpec` cover the typed selection, the immutable payload, and the missing-config
message. `CommandsSpec` covers the least-authority split on the demo's own registry twice over: the
accelerator's source root is reflected as a field of its own role wire and the web role does not carry it, and
each role's **declared effect row** is its own — the web role declares listen plus durable store, the
accelerator declares listen plus process spawn, and neither is the union, so a widening of either shows up as a
diff rather than passing silently.

`ServiceProgramSpec` covers the program against a real signed placement: an authorized program reaches the
backend once per effect with the acquired names in the handler's order, a resource the engine never acquired
has no handle to name, a backend failure is a typed failure naming its family, durable read and write are
core-executed under the admitted root while the backend stays untouched, and `..`, an embedded separator, an
absolute segment, and a bare dot are each refused a durable path.

`RoleLifecycleSpec` covers the row against a real signed ceiling in both directions: a narrower row is admitted
at its own row and drops the ceiling's lease requirement, the exact ceiling is admitted and keeps it, an empty
row is admitted under any ceiling, and a row naming an effect outside the ceiling is refused by service and
effect name. `CompileFailSpec`'s `UndeclaredServiceEffect.hs` is the load-bearing one: it pins that demanding
`DurableStore` under a listen-only row does not compile, and that the diagnostic names the effect.

- The effect row a role may use is a **type-level list** with a term-level twin that agrees by construction:
  `RoleEffect` promotes, `EffectName` is its per-effect tag (the shape `Network.ScopeName` uses), and
  `DeclaredEffects effects` is the row a definition declares. `declaredEffectList` reads back exactly the
  effects the type names — there is no reification class and no `Proxy`, the same way `reachableFrom` cannot
  disagree with `Reachability`.
- `HasEffect e es` is the membership constraint, and it has **no empty-row equation**: demanding an effect a row
  does not carry is an unsolved constraint naming the effect, not a runtime refusal.
- `authorizeServiceEffects` is the sole producer of `EffectAuthorization … effects`, and it admits a declared
  row only when the signed `VerifiedServicePlacement … permittedEffects` ceiling permits every member. The
  authorization carries the **declared** row rather than the ceiling — the registry fixes what a handler may do
  and the signature validates that choice — and the lease requirement is recomputed from the declaration, so a
  role that declares no exclusive effect does not inherit its ceiling's lease.

- `ServiceProgram payload service effects a` is the closed program a handler returns. Its constructors are
  private and there is no `IO`, `MonadIO`, or file/socket constructor: a project builds one only through the
  smart constructors and the `Monad` instance, so it can neither inject an effect nor write a second
  interpreter that skips the gate. `interpretServiceProgram` is the sole eliminator and demands the
  `EffectAuthorization`, so a program cannot run without the ceiling comparison having happened.
- The payload types are gathered under **one** `payload` index with associated types rather than four
  independent parameters, so a program and the backend that runs it agree by one type equality instead of four
  coincidences — and a caller cannot collapse two families by instantiating them to the same type.
- Every listener, peer, and worker argument is an `AcquiredResource service` whose sole producer is the Ready
  phase, so a handler cannot bind, connect, or spawn; it can only act on what the engine already acquired and
  probed. That is § AA's "Serve has no handler-visible open/bind/spawn escape hatch".
- **`hostbootstrap-core` has no `wai`, `warp`, or `network` dependency and must not acquire one**, so the split
  is by what core can actually hold. `DurableStore` is **core-executed** against a `DurablePath` minted only
  through `canonicalHostSubPath`, so a handler cannot name a path outside its own durable root — there is no
  way to spell `..` past it. The other three families reach a `ServiceBackend`, the same injected effect handle
  `ClusterExec` and `GuestExec` already are: core decides *whether* an effect may run, the backend is *how*.
- There is deliberately **no "unauthorized effect" failure**. The row a program is indexed by and the row its
  authorization admits agree by construction — `DeclaredEffects` is the term-level twin of the same type-level
  list, and `authorizeServiceEffects` mints the authorization from that one value — so a program demanding an
  unadmitted effect is not a state the interpreter can observe. Carrying a branch for it would claim the two can
  disagree. The authorization is a capability, not a lookup table.

#### Remaining Work

Adoption, and it is now one item rather than three.

`serviceDefinition` **does** take a declared row. It is a `DeclaredEffects effects` — the term-level twin of
the type-level list, so what a definition declares and what its type says cannot disagree — and it is carried
through finalization, `withSelectedServiceRequest`, and `selectServiceAction`, so the row a variant fixed is
observable at selection. `service run` prints the row it would authorize, which makes the declaration visible
before the authorization that will consume it exists. The demo declares two genuinely different rows: the web
role listens and reaches the durable root, the accelerator listens and runs a worker, and neither is the union.

What is left is the part that cannot land before activation installation does. Handlers still return `IO ()` and no
call site builds a `ServiceBackend`, because `interpretServiceProgram` demands an `EffectAuthorization`, whose
only producer needs a `VerifiedServicePlacement`, which needs a `VerifiedRuntimeRoleActivation` — and nothing
installs a signed activation yet. Changing the handler's return type before `service run` can obtain a
placement would leave the registry producing programs nothing can interpret, so it lands together with Sprint
22.3's activation installer and `service run` interpreter.

### Sprint 22.3: Role-machine adoption at `service run` [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Enter the service through the activation package rather than beside it.

#### Deliverables

- The activation installer signs one manifest per pod-template revision and installs the immutable
  digest-addressed config, secret, and manifest objects the role reads.
- `service run` measures its own binary, its mounted role wire, and its private bundle digests plus its instance
  identity, verifies the activation against the independently installed Activation key, and enters the phase machine.
- A verification failure refuses to start rather than starting unverified.
- This sprint changes only the two declared core modules. It does not edit `HostBootstrapDemo.Commands` or own
  Helm/chart mutation; the worked-demo phase joins these activation semantics to exact cluster readiness.

#### Validation

`ActivationSpec` and `RoleLifecycleSpec` cover the signing, the measurement comparison, and the refusal.

The [authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md) pins the
activation-signing tag pair, exact field shape, bounded codec, and keyless relay behavior at the private wire
boundary. The [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) proves that route
through the sealed process/Command adopter. This phase's gate then covers the activation consumer: the root's
relayed signature is byte-identical to local signing, a manifest without a rollout revision is refused, a
truncated or trailing wire is refused, and a multi-entry effect row remains distinct. No public test channel,
signing hook, or private-module exposure is part of that evidence.

#### Objective boundary

This sprint owns activation installation and service execution. The closed readiness-gated chart/workload
call is the [worked-demo phase](phase-24-worked-demo.md)'s, and it can only exist once the exact cluster
consumer can supply a `ClusterReadiness`.

#### Remaining Work

The activation consumer uses the root-coordinated route without lending signing or durable authority to a
child:

- The [authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md) owns authenticated
  root scope, scope-first receipt of the exact child edge, the activation-signing tags, and the structurally
  keyless relay. A frame that has not completed admission cannot submit a signing request.
- The [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns the installed root
  runtime, recursive catalog, process route, and sealed root relay service. A storeless `FrameExecutor` receives
  no project signing key, `ProtectedStore`, journal, cursor, or generic root callback.
- `activationManifestFromWire` is the decoder that makes the root a signer rather than a blind oracle. It
  rebuilds the manifest from the bytes that arrived and puts it back through the *same*
  `signActivationManifest` validation a local caller faces, so a relayed manifest gets no weaker check than a
  local one. A wire that does not decode is refused before the broker is reached at all.
- Cabal-private `linkSignActivation` signs locally only at the root; every other frame forwards canonical bytes
  through its already-admitted session and adopts the answer. The derived link is structurally keyless and stays
  inside a fixed branch-specific callback.
- `adoptRelayedActivationGrant` lets the relayed half hold its own answer. It is safe because an
  `ActivationGrant` is not authority: the only consumer is `verifyRuntimeRoleActivation`, which checks it
  against the independently installed Activation key, so adopting arbitrary bytes yields a grant that fails
  verification rather than one that authorizes anything.

The remaining work is the **activation and `service run` adoption** that consumes it: signing one manifest per
pod-template revision, installing the immutable digest-addressed config, secret, and manifest objects, and
`service run` measuring its own binary, mounted role wire, and bundle digests before entering the phase
machine. It lands together with Sprint 22.2's registry adoption; until then
`serviceDefinition` keeps its `IO ()` handler, because changing the registry's shape before there is anything
that can run a program would break `service run` for no gain.

There is still one lane that never needed the relay: the host-resident accelerator daemon is launched by a
post-handoff step in the metal frame, where the root authority is already in scope. Adopting the engine there
first remains possible but is the Apple/Windows placement only, so it stays a deliberate choice rather than an
obvious one.

## Remaining Work

Sprints 22.2 and 22.3 land together, because neither half stands alone: handlers still return `IO ()`
and no call site builds a `ServiceBackend`, since `interpretServiceProgram` demands an
`EffectAuthorization` whose only producer needs a `VerifiedServicePlacement`, which needs a
`VerifiedRuntimeRoleActivation` — and nothing installs a signed activation yet. Sprint 22.3 installs it
and interprets `service run`; Sprint 22.2's registry adoption and handler return type follow in the same
change.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — the fixed `service` surface.
- `documents/architecture/composition_methodology.md` — role adoption at `service run`.

**Engineering docs to create/update:**
- `documents/engineering/accelerator_daemon.md` — daemon startup ordering and teardown expectations.

**Cross-references to add:**
- `development_plan_standards.md` § AA names this phase as the owner of the service runtime.
