# Phase 22 — Service runtime

**Status**: Active
**Depends on**: Phase 20 (`test` and `context` command semantics), Phase 21 (composition and network algebra)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`, plus a live `service run` on linux-cpu
**Gate kind**: deferred
**Gate evidence**: 2026-09-13 ; static leg on x86_64 Ubuntu 24.04.4 LTS (Linux 7.0.0-28-generic, GHC
9.12.4, Cabal 3.16.1.0), live `service run` leg in an x86_64 Linux container from the published
`basecontainer-cpu-amd64` base with no accelerator device visible, built and run there with that same
pinned toolchain mounted in ;
`cabal test all --ghc-options=-Werror --test-show-details=direct --test-options=--hide-successes` from
`core/`, then `cabal test hostbootstrap-core:test:hostbootstrap-core-test --ghc-options=-Werror
--test-show-details=direct --test-options="--pattern CLISpec"` from `core/` in that container ; pass ;
covers c14b03715891c9d46bdef4928b644507fe406df3d412070652289014fe478044
**Evidence covers**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs` `core/hostbootstrap-core/src/HostBootstrap/Service` `core/hostbootstrap-core/src/HostBootstrap/Activation.hs` `core/hostbootstrap-core/src/HostBootstrap/Command.hs` `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`

> **Purpose**: Make a project's long-running workload a service variant, selected by a signed activation and
> reached through one fixed command, driven by the role phase machine.

## Phase Objective

`project up` *deploys* a service; `service run` *is* the service. A project therefore defines no long-running
verb of its own — a web server is `service run` on its `Web` variant. This phase fixes the command surface, the
typed selection, and the immutable payload a handler receives, and adopts the role machine at the real call
site.

It also owns the crash-safety layer `development_plan_standards.md` § AA lists as target: the runtime holds
role receipts in process memory and journals nothing per service effect, so Sprints 22.10 through 22.13 add a
durable per-call service-effect journal, durable role receipts, predecessor-instance recovery, and an
exclusive-lease transfer barrier.

## Sprints

### Sprint 22.1: The `service` command surface [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Three verbs, closed at this layer. With `service` in place the core command surface is complete, so this
sprint also pins the whole top-level verb list against the parser both entrypoints build.

#### Deliverables

- `service init`, `service schema`, and `service run` are the whole surface; a project contributes variants, not
  verbs. There is no `service down`.
- `service init` writes a service-configured `<project>.dhall` whose context kind is `ClusterService`
  (`initParserInfo … Context.ClusterService`).
- `service schema` emits the registered variants, the full project schema, and the role-wire schema families as
  one exact snapshot, pinned whole by a golden test.
- The variant `service run` executes is the one the signed activation names (`activationService`). `service run`
  reads no project config: it takes three absolute platform-installed coordinates —
  `HOSTBOOTSTRAP_SERVICE_ACTIVATION` (the immutable revision directory), `HOSTBOOTSTRAP_ACTIVATION_KEY`, and
  `HOSTBOOTSTRAP_AUTHORITY_STORE` — plus exactly one measured instance identity, and there is no variant
  argument or flag. A missing or relative coordinate, a revision directory whose name is not a canonical
  SHA-256 digest, and an activation naming a service the finalized registry does not hold each refuse before
  Prereq.
- The top-level parser both entrypoints build from `HostBootstrap.Command.coreCommands` offers exactly the
  five verbs `context`, `project`, `test`, `service`, and `check-code`, in that order, and no `ensure` verb.
  The exported `coreCommandNames` names that same list, and the suite holds it against the parser's own
  rendered command list rather than against a copy of the constant.

#### Validation

`CLISpec` covers a positional variant argument refused by the parser and `service run verifies activation and
dispatches exactly its signed program variant`, which runs the actual command under `withArgs` against a signed,
installed revision and shows the `accelerator` handler runs while `web` does not. `service schema lists variants
without a config` checks only that the command exits successfully, `the fixed service surface has no down command`
checks only `ExitFailure 1`, and the `service_schema_consumer.txt` golden holds only the header lines
`serviceSchemaOutline` keeps. Closure needs the `service init` case, the whole-output `service schema` golden, the
parser-level `down` assertion, and the activation-level refusal cases listed under Remaining Work, each asserting
its specific output or diagnostic rather than only the exit code, passing under `cabal test all` from `core/`.
Closure also requires the `CLISpec` case "core command surface has five user-facing verbs and no ensure
command" to read the parser rather than the constant: it runs `schemaFixtureOutput "top-level-help"` and
`schemaFixtureOutput "bare-top-level-help"`, takes from each output the command names listed under the
`Available commands:` heading (the first word of each indented line up to the next blank line), and asserts
each list equals `["context", "project", "test", "service", "check-code"]` and equals `coreCommandNames`, so
adding an `ensure` (or any sixth) verb to `coreCommands`, or dropping one, fails the case while the constant
stays unchanged.

#### Remaining Work

- Add a `CLISpec` case that runs `withArgs ["service", "init"]` against a temporary project directory and
  asserts the written `<project>.dhall` decodes with context kind `ClusterService`.
- Make the `service schema` golden pin the whole command output: drop the `serviceSchemaOutline` filter from
  `consumer service schema command output owns the project-config snapshot`, normalise only an unstable
  digest if one appears, and regenerate `test/golden/service_schema_consumer.txt` from the full output.
- Rewrite the `service run` refusal cases on top of `withVerifiedServiceRuntime` (signed, installed revision with
  every coordinate set) so each fails for its own reason, and assert the diagnostic text: an activation naming a
  service absent from the registry (`activation selects unknown service`), an empty registry (`this binary
  registers no services`), a registry whose finalized spec digest differs from the signed one (`does not match
  finalized registry`), each coordinate missing (`missing platform runtime coordinate <NAME>`) and relative
  (`must be an absolute path`).
  Delete `service run fails fast on a non-service-role config` and `service run rejects a forged multi-role
  orchestrator even when ServiceCommand is granted`, which test a config gate `service run` does not have, and
  the `withMultiRoleHostServiceConfig` fixture they alone use.
- Rewrite the `serviceCommandGroup` Haddock in `Command.hs` to describe the runtime as built: no
  `Context.ServiceCommand` context gate, no `cluster-service`/`daemon` leaf-kind gate, and no project-config read
  at `service run` (the opening paragraph's "@run@ loads the effective project config" included); the variant
  comes from the signed activation reached through the three platform coordinates, and the gate is the
  activation signature plus the measured binary, role wire, private bundle, and instance identity. Rewrite the
  `run` subcommand's `progDesc` ("Run the config-selected service variant (leaf-frame; needs a service-role
  config)") to the same contract, for example "Run the service variant the signed activation names (needs the
  platform activation coordinates)".
- Make `the fixed service surface has no down command` assert the parser surface: run `service down` through the
  subprocess fixture and assert stderr contains optparse's ``Invalid argument `down'``, and capture
  `service --help` and assert its command list is exactly `init`, `schema`, `run`; drop the
  `withServiceProjectConfig` wrapper, which has no bearing on the outcome.
- Make `service schema lists variants without a config` check what it names: capture the output through the
  subprocess fixture with no `<project>.dhall` present and assert it contains `service variants:` followed by
  `  web`, or rename it `service schema succeeds without a config`.
- `core/hostbootstrap-core/test/CLISpec.hs` `runSchemaFixture`: add a `"top-level-help"` branch running
  `withArgs ["--help"] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))` and a
  `"bare-top-level-help"` branch running `withArgs ["--help"] (CLI.runBareHostBootstrapCLI ...)` with the
  executable's project name, as the existing `"bare"` branch does (`--help` prints to standard output and exits
  successfully, as the `"test-run-help"` fixture relies on). Rewrite the command-surface case "core command
  surface has five user-facing verbs and no ensure command" to parse the `Available commands:` block of both
  outputs and compare each against the literal five-name list and against `coreCommandNames`, as stated in
  Validation.

### Sprint 22.2: Typed service selection and the immutable handler payload [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service/Program.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Give a handler exactly one immutable, config-derived input.

This sprint owns core's program, selection, and interpreter. The demo's payload family and backend — its
`ListenApp` is `IO ()`, its web application binds its ports from config and writes its durable root directly,
and no demo handler uses `writeDurable`, `call`, or `work` — are the
[worked-demo phase](phase-24-worked-demo.md)'s to narrow onto the acquired listener and `writeDurable`.

#### Deliverables

- A selected service is a definition drawn from the project's finalized registry. At deploy time
  `withSelectedServiceProgram` selects the one definition whose projection of the effective project config
  answers `Just`; at run time `withDecodedServiceProgram` selects the definition the signed activation names and
  decodes the narrowed role wire through that definition's own codec. An activation naming a service the
  registry does not hold is refused at that registry lookup, before Prereq.
- One immutable config-derived payload is handed to the handler; a handler reads no ambient state and cannot
  mutate its input.
- Role parameters are least-authority: a handler receives only what its declared role needs. A
  `ProgramServiceHandler payload effects fields` takes the opaque `RoleParams specDigest configId secretDigest fields service` bundle the
  role's own projection produced, and nothing else. It carries no `LocalContextView`, so a handler that
  needs a framework datum declares it as a role field and the projection supplies it; the demo's
  accelerator takes its source root that way. The indices are universally quantified, so a handler cannot
  pair a bundle from one finalization with another's.
- **What** a handler may do is bounded by the same discipline: it returns the effect-indexed
  `ServiceProgram` of Sprint 22.2, where an undeclared effect is a compile error, so the program can request
  only the effect families its row declares and only on handles the engine supplies. The *contents* of a
  `ListenApp`, `CallRequest`, or `WorkRequest` payload are the project's own types, run by the project's own
  `ServiceBackend`: core does not inspect them. A project that instantiates `ListenApp` to `IO ()` therefore
  keeps arbitrary IO inside its listener application, and the effect row bounds that IO only as far as the
  project's payload types and backend do. Sprint 22.3 installs the signed activation the interpreter demands,
  which is why the two land together.
- The handler runs on the same bundle the validated request carries, not on a second projection of the config
  beside it. `withSelectedServiceProgram` and `withDecodedServiceProgram` retain the request, declared row,
  resource backend, payload backend, and program in one existential package.
- Selection refusals are typed and name what was registered: a config that selects no definition is refused with
  `effective project config selects no registered service` followed by the registered variants (or `this binary
  registers no services`); a config two definitions both select is refused naming each; a definition whose
  projection fails is refused with the service identity prefixed; at run time an unknown activation service, a
  role wire that is not UTF-8, and a duplicated identity are each refused by name.
- The registry-selected action enters the role machine as its serve step, narrowed to an effect-indexed program.

#### Validation

`ActivationSpec`'s signed narrowed-role execution and `CLISpec`'s `service run` dispatch case cover the
single-match selection and the immutable payload; the selection refusals listed in Deliverables need the cases
named under Remaining Work. `CommandsSpec` covers the least-authority split on the demo's own registry twice
over: the accelerator's source root is a field of its own role-wire schema family and the web family does not
carry it, and
each role's **declared effect row** is its own — the web role declares listen plus durable store, the
accelerator declares listen plus process spawn, and neither is the union, so a widening of either shows up as a
diff rather than passing silently.

`ServiceProgramSpec` covers the program against a real signed placement: an authorized program reaches the
backend once per effect with the acquired names in the handler's order, a handler receives Ready handles only
inside the closed program, `lookupAcquiredResource` misses a name outside the Ready set, a `serve` backend
failure is `EffectFailure "network-listen" …`, a durable write is read back through the interpreter, and `..`,
an embedded `/`, an absolute `/` segment, and a bare dot are each refused a durable path. Closure needs the
cases under Remaining Work: the `call` and `work` families, the durable file asserted at its exact on-disk path,
the exact `ProjectRootSegmentUnsafe` refusal for each escape including a backslash and a drive-letter segment,
every case run through `interpretServiceProgramWithReady`, and `CompileFailSpec` fixtures pinning that a project
cannot mint an `AcquiredResource`.

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
  and the signature validates that choice — and its lease requirement is recomputed from the declaration.
  Sprint 22.7 makes that authorization precede the lifecycle and govern its lease.

- `ServiceProgram payload service effects a` is the closed program a handler returns. Its constructors are
  private and there is no `IO`, `MonadIO`, or file/socket constructor: a project builds one only through the
  smart constructors and the `Monad` instance, so it can neither inject an effect nor write a second
  interpreter that skips the gate. `interpretServiceProgramWithReady` is the sole eliminator: it demands the
  `EffectAuthorization` and the engine's `ReadyServiceHandles`, so a program cannot run without the ceiling
  comparison having happened and every `withReadyServiceHandles` callback sees the set Ready probed.
- The payload types are gathered under **one** `payload` index with associated types rather than four
  independent parameters, so a program and the backend that runs it agree by one type equality instead of four
  coincidences — and a caller cannot collapse two families by instantiating them to the same type.
- Every listener, peer, and worker argument is an `AcquiredResource service` whose sole producer is the Ready
  phase: `readyServiceHandles` is exported only from a package-private module, not from the exposed
  `HostBootstrap.Service.Program`, so a handler can name only a resource the engine acquired and probed. That is
  § AA's "Serve has no handler-visible open/bind/spawn escape hatch" at the program level; what a project's own
  payload does inside an acquired listener is bounded as the effect-row bullet above states.
- **`hostbootstrap-core` has no `wai`, `warp`, or `network` dependency and must not acquire one**, so the split
  is by what core can actually hold. `DurableStore` is **core-executed** against a `DurablePath` whose every
  segment passes `canonicalHostSubPath`, so no segment spells `..`, a separator, or an absolute path. Sprint 22.6
  ties the path to the role's own engine-minted durable root. The other three families reach a
  `ServiceBackend`, the same injected effect handle `ClusterExec` and `GuestExec` already are: core decides
  *whether* an effect may run, the backend is *how*.
- There is deliberately **no "unauthorized effect" failure**. The row a program is indexed by and the row its
  authorization admits agree by construction — `DeclaredEffects` is the term-level twin of the same type-level
  list, and `authorizeServiceEffects` mints the authorization from that one value — so a program demanding an
  unadmitted effect is not a state the interpreter can observe. Carrying a branch for it would claim the two can
  disagree. The authorization is a capability, not a lookup table.

#### Remaining Work

- Add a `visibility: private` sublibrary (the pattern `effect-internal` uses) whose module
  `HostBootstrap.Service.Handle.Internal` defines `AcquiredResource`, `ReadyServiceHandles`, and
  `readyServiceHandles`; the main library and the test suite depend on it. `HostBootstrap.Service.Program`
  re-exports the types, `acquiredResourceName`, `readyServiceHandleNames`, and `lookupAcquiredResource` but not
  `readyServiceHandles`. (The main library's other-modules `HostBootstrap.Service.Internal` imports
  `HostBootstrap.Service.Program` and is invisible to the test suite, so the producer cannot live there.) Add a
  `CompileFailSpec` fixture in which a consumer imports `readyServiceHandles` from
  `HostBootstrap.Service.Program` and fails naming it as not exported.
- Replace `a resource the engine never acquired has no handle to name` with a case named for what it checks
  (lookup misses a name outside the Ready set), and make the "no other producer" property the compile-fail
  fixture's job.
- Delete `interpretServiceProgram` (the empty-Ready eliminator with no production caller) and run every
  `ServiceProgramSpec` case through `interpretServiceProgramWithReady` with the Ready set the case's role plan
  acquired. Rewrite the `HostBootstrap.Service.Program` module Haddock to name that one eliminator.
- Add `ServiceProgramSpec` cases for the other two backend families: authorize `NetworkConnect` and run
  `call`, authorize `ProcessSpawn` and run `work`; with `recordingBackend` assert the handle name reached
  `backendCall`/`backendWork` and the reply returned, and with `failingBackend` assert
  `Left (ServiceEffectFailed (EffectFailure "network-connect" …))` and `(EffectFailure "process-spawn" …)`.
- In `durable read and write are core-executed under the admitted root`, assert `doesFileExist` and the exact
  bytes `"durable-v1"` at `directory </> ".data" </> "marker"`, and assert `durablePathValue marker` equals that
  canonical path rather than an `isInfixOf` match.
- In `a handler cannot name a durable path outside its own root`, assert
  `Left (ProjectRootSegmentUnsafe <segment>)` for each escape and add `["a\\b"]` and `["C:"]`.
- Add selection-refusal cases with the fixture registry: `withSelectedServiceProgram` with zero matches, with two
  definitions whose projections both answer `Just` (the `Left` names both), and with a projection returning
  `Left`; `withDecodedServiceProgram` with an unknown service name and with invalid UTF-8 wire bytes. Each
  asserts the refusal text listed in Deliverables.
- Rewrite the `HostBootstrap.Service.Program` module Haddock's least-authority paragraph to state the
  payload boundary the effect-row deliverable states: the program bounds families and handles, and a
  project's `ListenApp`/`CallRequest`/`WorkRequest` contents are bounded only by the project's own types and
  backend.

#### Implementation Record

The core program has `withReadyServiceHandles` and
`interpretServiceProgramWithReady`: the former keeps the exact Ready-phase set inside the closed DSL, so a
handler can remain a function of only `RoleParams`; the latter is the sole service-runtime eliminator that
supplies that engine-owned set. `ServiceProgramSpec` pins this path against a real signed placement. Registry
definitions have `serviceProgramDefinition`: its immutable role draft, resource backend, payload-specific
`ServiceBackend`, typed declared row, handler, and role codec survive finalization in one existential package.
`withDecodedServiceProgram` selects the service named by the signed activation from the narrowed installed wire,
not from the full sibling project config. `withRuntimeRolePlanForRequest` retains that decoded request's exact
config/secret/service indices through placement authorization, so the interpreter cannot cross-pair a
same-shaped program. Every definition uses this program boundary; no unbounded handler constructor or
IO-returning selection API is exposed. `IOServiceHandler.hs` rejects an IO action at the handler boundary,
and the registry ownership guard prevents the removed aliases and constructors from returning.

### Sprint 22.3: Role-machine adoption at `service run` [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
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
- Admission reserves or reopens the exact role plan inside one protected-store transaction, then closes that
  transaction before the long-running role lifecycle begins. The lifecycle holds only its service/frame-specific
  generation lease, so independently admitted services sharing one authority store can serve concurrently.
- This sprint changes only the three declared core modules. It does not edit `HostBootstrapDemo.Commands` or own
  Helm/chart mutation; the worked-demo phase joins these activation semantics to exact cluster readiness.

#### Validation

`ActivationSpec` and `RoleLifecycleSpec` cover the signing, the measurement comparison, and the refusal. The
aggregate gate and live concurrent-role confirmation pass: web and accelerator independently enter Serve from
signed immutable revisions while sharing one authority store, and each retains only its own service/frame
generation lease after admission releases the global transaction lock. Closure needs the `ActivationSpec` cases
under Remaining Work — the installed-revision opener's key, directory-identity, and unparseable-manifest
refusals, the revision-path shape refusals, an exact-constructor secret-safe diagnostic, and a read-back of the
consumed admission record — passing under `cabal test all` from `core/`.

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

#### Implementation Record

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

The immutable activation installer and opener are now implemented in `HostBootstrap.Service`.
`installServiceActivationRevision` validates the role-wire and private-bundle digests before signing, publishes
the canonical manifest twice beside its signature and independently provisioned public key, writes every member
through a flushed temporary, and atomically renames the complete digest-addressed revision. Exact retry and exact
partial-staging completion are admitted; a contradictory member is never overwritten.
`withInstalledServiceActivation` re-reads those installed bytes, recomputes the revision identity and both
payload measurements, and yields the role wire and private bundle only inside the callback of
`verifyRuntimeRoleActivation`. `ActivationSpec` now pins successful reopen, exact retry, digest refusal,
partial-staging resume, immutable conflict, missing-member refusal, measured-binary refusal, and secret-safe
diagnostics (34 focused tests under `-Werror`).

The production adopter is implemented. `service run` accepts only absolute platform-installed coordinates for
the immutable revision, independently installed Activation public key, and protected authority store. It hashes
its own executable, derives either the pod-UID/restart-count or host-invocation instance, verifies and decodes the
narrowed installed role wire, reserves or exactly reopens its one-use plan, authorizes the definition's declared
effect row against the signed ceiling, and runs the selected program only in Serve with Ready's exact handles.
It never loads the sibling full project config. Activation, registry, decode, plan-draft, and admission
refusals exit before Prereq; the effect-row authorization runs inside `engineServe`, after Acquire and Ready,
until Sprint 22.7 moves it ahead of the lifecycle.

The protected entry covers only admission and exact plan opening. Its rank-2 continuation returns the sealed
lifecycle action without running it; `runInstalledServiceProgram` releases the global transaction lock and only
then executes Prereq through Exit under the plan's distinct service/frame liveness lease. `ActivationSpec` enters
the protected store again from Serve, which would refuse or deadlock if the global transaction leaked across the
callback.

`ActivationSpec` has 35 focused cases, including a genuinely signed narrowed-role execution through
Prereq → Acquire → Ready → Serve → Drain → Exit and exact consumed-plan reopen. `CLISpec` runs the actual
`service run` command on linux-cpu against a measured test executable and proves that the signed accelerator
variant runs while the unselected web variant does not. The exact phase gate passed on 2026-08-22.

There is still one lane that never needed the relay: the host-resident accelerator daemon is launched by a
post-handoff step in the metal frame, where the root authority is already in scope. Adopting the engine there
first remains possible but is the Apple/Windows placement only, so it stays a deliberate choice rather than an
obvious one.

#### Remaining Work

- Add `ActivationSpec` cases for `withInstalledServiceActivation`'s own refusals: overwrite an installed
  revision's `activation.pub` with another key's bytes and expect `ServiceActivationInvalid` naming the
  independently installed key; copy the revision to another 64-lowercase-hex directory name, open it there,
  and expect `ServiceActivationConflict <that directory>`; corrupt `expected.manifest` and expect
  `ServiceActivationVerification`; pass a relative root to `installRelayedServiceActivationRevision` and expect
  `ServiceActivationInvalid "the activation root is not absolute"`.
- Add pure `serviceActivationRevision` cases asserting `Left (ServiceActivationInvalid …)` for a relative path,
  a 63-character name, an uppercase-hex name, and a name containing `g`, and `Right` for an absolute path whose
  last segment is 64 lowercase hex characters.
- Tighten `runtime measurement failures refuse without exposing secret bytes`: assert
  `Left (ServiceActivationVerification (ActivationMeasurementMismatch "binary" "binary-1" "wrong-binary"))`,
  check the diagnostic contains neither `hunter2` nor the `show`-escaped bundle, and add a sibling case that
  tampers the installed `secret.bundle` (the secret-mismatch path) with the same leak checks.
- In `a signed narrowed role enters Acquire, Ready, Serve, Drain, and Exit`, read the role-admission record from
  the protected store after the first run (as `RoleLifecycleSpec`'s one-use admission cases do) and assert it
  holds the `consumed <digest>` value `withRuntimeRolePlanForRequest` writes at consumption, and assert
  the second `runInstalledServiceProgram` leaves that record's version unchanged, so a reservation re-grant
  cannot pass as the consumed-plan reopen.

### Sprint 22.4: The live service run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated live `service run` on linux-cpu.

#### Deliverables

- one dated live `service run` naming its host and the activation-selected leaf service it ran.

#### Validation

On 2026-09-06, the live `service run` case passed inside a realized `linux-cpu` host — the published
`basecontainer-cpu-arm64` base reporting `Linux aarch64` with GHC 9.12.4 and Cabal 3.16.1.0. The case
`service run verifies activation and dispatches exactly its signed program variant` reported
`role exit: turned at Serve`: activation was verified and exactly the signed `accelerator` variant was
dispatched, while the unselected `web` handler did not run. The surrounding `CLISpec` group passed `58/58`
under `-Werror`.

This lane's evidence is an in-process `CLISpec` execution: the test runs the real `service run` command under
`withArgs` against a test executable it measures and a revision it signs and installs, on a realized host. It
exercises no separately installed binary, pod, or platform-provisioned coordinates.

#### Remaining Work

None.

### Sprint 22.5: The service-runtime gate records both its legs [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

This phase's gate is a composition: the static suite *and* a live service run on a realized
`linux-cpu` host. Its evidence records a focused pattern from the first half. A row that names the
cheaper leg claims something narrower than the gate, and the check that would catch that does not exist
yet — § G now states the rule, so the row is brought up to it.

#### Deliverables

- The declared gate is re-run in full, both legs.
- The evidence row names each leg, the gate host, and the command as run, rather than a focused subset of one.
- The covers digest is re-measured over this phase's own paths and recorded.
- Where the gate genuinely closes in two sittings, the row says so with two entries.

#### Validation

The phase's own gate, both legs. On 2026-09-13 both legs ran and one row records both. The static leg is
the complete 2,536/2,536 `cabal test all` from `core/` on the x86_64 Linux gate host. The live leg is
the `CLISpec` group, 64/64, built and run inside a realized `linux-cpu` container from the published
`basecontainer-cpu-amd64` base; `service run verifies activation and dispatches exactly its signed
program variant` reported `role exit: turned at Serve` there, so activation was verified and exactly the
signed `accelerator` variant was dispatched before the role turned. The row's covers digest
`c14b0371…` is measured over `Service.hs`, `Service/`, and `Activation.hs` at the tree that run used, which
includes the
`Activation.hs` and `Service/Program.hs` sources committed with it. The live leg is the same in-process
`CLISpec` execution Sprint 22.4 describes.

#### Remaining Work

None. The dead service-entry-point names in this phase's governed pages are owned by the documentation
reconciliation phase.

### Sprint 22.6: The durable store is confined to an engine-minted role root and writes atomically [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service/Program.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

`DurableStore` is the one family core executes itself, so core alone decides where it lands. This sprint makes
the durable root an engine-minted value for the selected service rather than caller-chosen segments, makes a
write atomic so a killed generation never leaves a torn record that reads back as valid, and makes a durable
or backend IO failure a typed `ServiceProgramError` rather than an escaping exception.

#### Deliverables

- `ServiceDurableRoot service` has a private constructor; it and its only producer live in the private
  `HostBootstrap.Service.Handle.Internal` sublibrary module Sprint 22.2 adds, and the producer is called by
  `runInstalledServiceProgram`, which mints it from a fourth
  absolute platform coordinate `HOSTBOOTSTRAP_SERVICE_DURABLE_ROOT` (read by `service run` beside the other
  three) joined with the activation's service identity.
- The program reaches that root only inside the closed DSL, the way it reaches Ready handles
  (`withServiceDurableRoot`), and `serviceDurablePath` takes the `ServiceDurableRoot service` plus the inner
  segments only; it takes no `CanonicalProjectRoot` and no caller-supplied root segments, and its
  `service` index is the root's.
- `WriteDurable` writes a sibling temporary in the same directory, flushes it, and renames it over the
  destination, removing the temporary on exception; `ReadDurable` therefore sees either the previous record or
  the new one.
- An `IOException` from either durable branch is
  `Left (ServiceEffectFailed (EffectFailure "durable-store" <detail>))`, and an exception thrown by a backend
  member is `Left (ServiceEffectFailed (EffectFailure <that family> <detail>))`, so `ServiceProgramError` is the
  only way a program fails, as its Haddock states.

#### Validation

`ServiceProgramSpec`: a program for service `web` writes through `writeDurable` and the bytes are at exactly
`<durable root>/web/<segments>` on disk; a stale temporary left beside an existing record does not change what
`readDurable` returns and is replaced by the next write, and no temporary remains after a successful write;
a durable path whose parent is a regular file yields `EffectFailure "durable-store" …` rather than an exception;
a backend whose `backendServe` throws yields `EffectFailure "network-listen" …`. `CompileFailSpec`: a fixture that
constructs or mints a `ServiceDurableRoot` from consumer code fails naming it. `CLISpec`: `service run` without
`HOSTBOOTSTRAP_SERVICE_DURABLE_ROOT` refuses with `missing platform runtime coordinate`. All pass under
`cabal test all` from `core/`.

#### Remaining Work

- Add `ServiceDurableRoot`, its private producer, and `withServiceDurableRoot`; change `serviceDurablePath`'s
  signature to take it; thread the coordinate from `runServiceRun` through `runInstalledServiceProgram`.
- Replace `ByteString.writeFile` in the `WriteDurable` branch with temporary-plus-rename and wrap both durable
  branches and the three backend calls in `try @IOException`, mapping to `ServiceEffectFailed`.
- Write the `ServiceProgramSpec`, `CompileFailSpec`, and `CLISpec` cases listed under Validation.

### Sprint 22.7: Effect authorization precedes the lifecycle and governs its lease [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

The declared effect row decides both whether a role may run and which lease it holds. A row outside the signed
ceiling is refused before Prereq, and a role whose declared row names no exclusive effect runs without the
exclusive generation lease even when its ceiling would permit one.

#### Deliverables

- `runInstalledServiceProgram` calls `authorizeServiceEffects placement declared` once, after plan opening and
  before `runRoleLifecycle`; a refusal returns `ServiceRuntimeRole` naming the service and the effect, and Prereq
  never runs.
- `runRoleLifecycle` takes the `EffectAuthorization` (or its `authorizedLeaseRequirement`) and brackets the
  generation lease by that requirement instead of `placementLeaseRequirement placement`; `engineServe` receives
  the same authorization rather than minting its own.

#### Validation

`ActivationSpec`: a signed narrowed-role execution whose declared row is outside the signed ceiling refuses
with `ServiceRuntimeRole` and records no `prereq` event; a role declaring only `NetworkListen` under a ceiling
that also permits an exclusive effect runs while another live instance holds that service/frame's generation
lease. `RoleLifecycleSpec`: `runRoleLifecycle` driven with a `NoExclusiveEffects` authorization takes no lease,
and with `RequiresGenerationLease` refuses when the lease is held. All pass under `cabal test all` from `core/`.

#### Remaining Work

- Move the `authorizeServiceEffects` call out of `engineServe` in `runInstalledServiceProgram` to before
  `runRoleLifecycle`, and change `runRoleLifecycle` to take the authorization's lease requirement.
- Write the `ActivationSpec` and `RoleLifecycleSpec` cases listed under Validation and update the existing
  `runRoleLifecycle` call sites in `RoleLifecycleSpec`.

### Sprint 22.8: Activation revision installation survives interrupted and repeated installs [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

A revision's directory name is fixed by its manifest bytes, so anything the installer leaves behind or publishes
wrongly poisons that name for every later attempt. The installer publishes only a grant that verifies, recovers
from a partial write, leaves no staging copy of the private bundle, and checks a revision's identity before
reading its members.

#### Deliverables

- `installRelayedServiceActivationRevision` verifies the grant's signature over the rendered manifest with the
  supplied verification key, reusing the `HostBootstrap.Activation` verifier, before creating anything, and
  refuses with `ServiceActivationVerification`.
- An already-installed target is detected before the staging directory is created and verified in place; when a
  rename fails and the target verifies, the staging directory is removed. No retry leaves `installing-<digest>/`.
- A `<member>.installing` temporary is scratch, never evidence: it is truncated and rewritten (or deleted and
  recreated) on every attempt and removed when its write fails. The exact-bytes conflict check applies only to
  published member names.
- `withInstalledServiceActivation` reads `expected.manifest`, checks the directory name against its SHA-256, and
  only then reads the other members, as the `ServiceActivationRevision` Haddock states.

#### Validation

`ActivationSpec`: a relayed install with a grant from another key refuses and leaves `root` absent; both digest
mismatch refusals leave `root` absent (`doesDirectoryExist root` is `False`), not only return the named reason;
a retry of an installed revision returns the same path and leaves no `installing-<rev>` entry; a staging
directory holding a foreign `role.dhall` refuses with `ServiceActivationConflict <staging>`, leaves `foreign` in
place, and publishes no `root </> rev`; a staging directory holding a truncated `secret.bundle.installing`
completes the install; a relabelled revision directory refuses before `secret.bundle` is read (shown by
replacing the relabelled copy's `secret.bundle` with a directory, which fails any read on every host, and
observing `ServiceActivationConflict`, not `ServiceActivationIO`). All
pass under `cabal test all` from `core/`.

#### Remaining Work

- Add grant verification before staging in `installRelayedServiceActivationRevision`.
- Check the target first, remove staging after a verified failed rename, and treat `.installing` files as
  scratch in `writeExact`.
- Reorder `withInstalledServiceActivation` to check the directory identity before reading the other members.
- Write the `ActivationSpec` cases listed under Validation.

### Sprint 22.9: Registry finalization derives its scope kind from the codec [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

The scope kind stamped into every role codec and written into every role-wire envelope has one source: the
`ProjectCodec`'s own `scope` index. `withFinalizedServiceRegistry` takes no free `ScopeKind` term, so a
Production codec cannot be finalized as Harness or the reverse, and `service schema` renders only the family
the registry actually belongs to.

#### Deliverables

- `ProjectCodec` carries the `ScopeKind` its producer fixed: `withProductionProjectCodec` sets
  `ProductionScope` and `withHarnessProjectCodec` sets `HarnessScope`; the field has no public setter.
- `withFinalizedServiceRegistry` drops its `ScopeKind` parameter and stamps `internalRoleScopeKind` from the
  codec; its callers in `HostBootstrap.ProjectPlan.Construct.Internal`, the tests, and the demo drop the argument.
- `serviceRoleSchemaFamilies` renders one family, named for the registry's scope kind, and its Haddock says so.

#### Validation

`CLISpec`: `service registries compose additively across layers` and the `service schema` golden show exactly one
family heading for a Production registry. A harness-scoped finalization yields role wires whose envelope carries
`HarnessScope` and decodes only under a Harness codec. `CompileFailSpec`: a fixture passing a `ScopeKind` to
`withFinalizedServiceRegistry` fails to compile. All pass under `cabal test all` from `core/`, and the demo suite
under `cabal test all` from `demo/`.

#### Remaining Work

- Add the codec scope-kind field and set it in both codec producers; remove the `ScopeKind` parameter from
  `withFinalizedServiceRegistry` and update every caller.
- Render only the matching family in `serviceRoleSchemaFamilies`; update the `CLISpec` empty-family assertions,
  `CommandsSpec`'s family assertions, and the `service schema` golden.
- Write the harness-envelope and compile-fail cases listed under Validation.

### Sprint 22.10: Every mutating service effect is sealed in a durable per-call journal [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service/Program.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

An effect row is family permission, never retry authority. The interpreter journals each mutating call
(`writeDurable`, `call`, `work`) in the protected store before it runs, so a crash between the call and its
acknowledgment leaves a durable record a later run resolves by same-key reprobe or retry rather than an
unknown mutation.

#### Deliverables

- Each mutating call is sealed with its exact target (the durable path or the acquired handle name) and the
  digest of its arguments under a per-call key derived from the role plan, the instance, and the call's ordinal
  in the program, and its unknown phase is published through `recordDurableUnknown` under the run's fence
  before the backend or durable write runs.
- After the call returns, the record moves to `done` (or `failed` with the typed `EffectFailure`) by
  compare-and-swap against the version the prepare returned.
- A run that finds its own call key in the unknown phase reprobes the target (for `DurableStore`, compares the
  on-disk bytes with the sealed argument digest) or retries under the same key; it never issues a second call
  under a fresh key.
- `serve` and `readDurable` are not journaled: they mutate nothing the journal fences.

#### Validation

`ServiceProgramSpec`: a `writeDurable` whose backend is killed after the prepare and before the write leaves an
unknown-phase journal record read back from the protected store, and the next run under the same plan and
instance completes the write once and moves the record to `done`; a kill after the write and before the
acknowledgment is resolved by reprobe without a second write (asserted by a recording backend's call count for
`call` and `work`); a call whose arguments differ from the sealed digest under the same key refuses. All pass
under `cabal test all` from `core/`.

#### Remaining Work

- Add the per-call journal key, the prepare through `recordDurableUnknown`, and the `done`/`failed` completion
  to the mutating branches of `interpretServiceProgramWithReady`, threading the protected session and fence from
  `runInstalledServiceProgram`.
- Add same-key reprobe and retry for a call found in the unknown phase.
- Write the `ServiceProgramSpec` kill-point and same-key cases listed under Validation.

### Sprint 22.11: Role receipts are durable, so an uncatchably killed instance's resources are recovered [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

`runRoleLifecycle` holds its `RoleReceipt` list in process memory, so Drain releases only what the running
process holds and a `SIGKILL`ed instance leaves its acquisitions behind. This sprint writes each receipt to the
protected store before and after `engineAcquire`, so the acquisitions of an instance that never reached Drain
are a durable set a successor can enumerate.

#### Deliverables

- `RolePlan` carries the activation's plan digest and the service name besides its frame, revision, instance,
  requests, and store origin; `withRuntimeRolePlanForRequest` and `resumeRuntimeRolePlanOpenForRequest` fill
  them from `activationPlanDigest activation` and the service text both already receive.
- A receipt record's key is `role-receipt.<group>.<member>`: `<group>` is `sha256Hex` over the `frameWire`-framed
  fields `hostbootstrap/role-receipt/v1`, plan digest, frame, and service; `<member>` is `sha256Hex` over the
  framed instance text and resource name. The key is 142 characters, inside the store's 200-character limit,
  and `listProtectedRecords` filtered on the `role-receipt.<group>.` prefix enumerates every instance's receipts
  for one plan digest, frame, and service.
- A receipt record's bytes are the `frameWire`-framed fields `hostbootstrap/role-receipt/v1`, state (`unknown` or
  `owned`), plan digest, frame, service, instance text, resource name, exclusivity (`exclusive` or `shared`),
  and failure text (empty until a release fails).
- Each receipt transition opens its own `withProtectedEntry store` (the store `runRoleLifecycle` already
  receives), so the store-exclusive entry is never held across a project callback: before `engineAcquire` the
  lifecycle publishes the record in state `unknown` with `ExpectAbsent`; `Acquired` moves it to `owned` by
  `compareAndSwapProtectedRecord`; a `Released` drain deletes it by `compareAndDeleteProtectedRecord`; a
  `ReleaseFailed` drain rewrites it by compare-and-swap with its state unchanged and the failure text set.
- The receipt set of one plan digest, frame, and service is readable from the protected store without the
  process that wrote it.

#### Validation

`RoleLifecycleSpec`, kill point: the parent self-execs the test binary (`getExecutablePath`, `spawnProcess`)
with a new `--hostbootstrap-role-receipt-kill-probe <storeRoot> <readyPath>` flag dispatched in `test/Spec.hs`.
The child runs `runRoleLifecycle` over a two-resource plan; its `engineAcquire` returns `Acquired` for both, and
its `engineProbe`, which runs only after both acquisitions are acknowledged and persisted, writes `readyPath`
and blocks. The parent waits for `readyPath`, then calls `terminateProcess` and `waitForProcess`; neither
`TerminateProcess` nor `SIGTERM` reaches a `mask` handler or `guarded`, so Drain never runs, and the case passes
natively on Windows and POSIX. The parent then opens the store and reads back exactly two receipt records, both
in state `owned`, with the plan's instance and resource names. Further cases: a lifecycle that reaches Exit
cleanly leaves no `role-receipt.` record; a lifecycle whose second release returns `ReleaseFailed` leaves
exactly that resource's record, with the failure text. All pass under `cabal test all` from `core/`.

#### Remaining Work

- Add the plan digest and service name to `RolePlan` in
  `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`, filled at both construction sites.
- Persist `RoleReceipt` transitions in `runRoleLifecycle`'s Acquire and Drain steps by opening
  `withProtectedEntry store` for each transition, with the key and byte encoding stated under Deliverables.
- Add the receipt-set reader, over `listProtectedRecords` and the `role-receipt.<group>.` prefix, that the
  predecessor recovery of Sprint 22.12 consumes.
- Add the `--hostbootstrap-role-receipt-kill-probe` dispatch to `core/hostbootstrap-core/test/Spec.hs` and write
  the `RoleLifecycleSpec` kill-point, clean-exit, and failed-release cases listed under Validation.

### Sprint 22.12: A recovery-required admission settles its predecessor instances instead of refusing [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

`withRoleLifecycleAdmission` returns `RoleAdmissionRecoveryRequired` for a contradictory predecessor row and
`runInstalledServiceProgram` turns it into `ServiceRuntimeRole "predecessor recovery is required at …"`, with no
core path that settles the old instance. This sprint adds that path inside `service run`, with no new verb.

#### Deliverables

- On `RoleAdmissionRecoveryRequired`, `runInstalledServiceProgram` enumerates the predecessor instances of the
  same plan digest, frame, and service, and for each one reads its durable receipt set (Sprint 22.11) and its
  unknown-phase journal records (Sprint 22.10).
- Each predecessor receipt is released through the definition's resource backend and each unknown journal call
  is reprobed; only when every one settles is the predecessor's admission row cleared by compare-and-swap and
  the successor's admission reserved.
- A predecessor that does not settle refuses the run with a `ServiceRuntimeRole` naming the unsettled resource
  or call, and Prereq never runs.

#### Validation

`ActivationSpec`: a predecessor admission row with one `ReceiptOwned` receipt and no live holder is settled by
the next `service run` instance (the receipt's resource is released once, the row is cleared, and the
successor reaches Serve); a predecessor whose release fails refuses with `ServiceRuntimeRole` naming that
resource and records no `prereq` event. All pass under `cabal test all` from `core/`.

#### Remaining Work

- Add predecessor enumeration and settlement to the `RoleAdmissionRecoveryRequired` branch of
  `runInstalledServiceProgram`, using the receipt reader and the journal reprobe.
- Write the `ActivationSpec` settle and refuse cases listed under Validation.

### Sprint 22.13: An exclusive lease transfers only after the predecessor's mutations are fenced [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

`withRunLiveness` is a kernel lock the OS releases on process death, so it excludes only a live predecessor: a
successor can take the exclusive lease while a dead predecessor's prepared or in-flight backend mutation is
still unresolved. This sprint makes taking the exclusive lease a transfer that advances a durable fence and
resolves the predecessor's open journal entries before the successor's first mutation.

#### Deliverables

- Under `RequiresGenerationLease`, after `withRunLiveness` admits the run, the lifecycle advances the
  service/frame's durable fence generation by compare-and-swap before Prereq.
- Every unknown-phase journal record under an older fence generation for that service and frame is reprobed or
  settled before the successor's first mutating call; one that cannot be settled refuses the run before Prereq.
- The journal prepare of Sprint 22.10 carries the fence generation, and a prepare under a superseded generation
  is refused rather than published.

#### Validation

`RoleLifecycleSpec`: a predecessor killed after a prepare and before its acknowledgment, followed by a
successor under an exclusive row, shows the predecessor's record resolved before the successor's first backend
call (the recording backend's call order); a prepare stamped with the superseded generation is refused; a
non-exclusive row neither advances the fence nor waits on the predecessor. All pass under `cabal test all` from
`core/`.

#### Remaining Work

- Add the fence-generation record and its advance to the `RequiresGenerationLease` bracket in
  `runRoleLifecycle`.
- Settle older-generation journal records before Prereq and refuse a superseded-generation prepare.
- Write the `RoleLifecycleSpec` transfer, stale-fence, and non-exclusive cases listed under Validation.

### Sprint 22.14: The service runtime hashes through Digest [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`

#### Objective

`HostBootstrap.Digest` exports the lowercase-hex `sha256Hex`. The service runtime spells its manifest config
digest, revision directory and measured role-wire digest through `Show (Digest SHA256)`, which renders the
same lowercase hex; importing the export makes that agreement a single definition rather than a coincidence of
two, so a digest the activation installer recorded cannot drift from the one `service run` measures.

#### Deliverables

- `Service` imports `sha256Hex` from `HostBootstrap.Digest` and defines no SHA-256 helper of its own.
- Every manifest config digest, revision directory name and measured config digest keeps the bytes
  `ActivationSpec` and `CLISpec` pin.

#### Validation

The cases that hold those bytes pass unchanged: the `ActivationSpec` case "an incomplete staging revision
resumes only from exact members", which writes `installing-<digestBytes manifest>`; the `ActivationSpec` case "a
signed narrowed role enters Acquire, Ready, Serve, Drain, and Exit", which runs `runInstalledServiceProgram`
against `manifestConfigDigest = digestBytes roleWire`; and the `CLISpec` case "service run verifies activation
and dispatches exactly its signed program variant", which reaches `service run` through
`withVerifiedServiceRuntime`. All run under `cabal test all --ghc-options=-Werror` from `core/`, and the host
static gate (§ JJ) passes.

#### Remaining Work

- Delete `sha256Hex` and the then-unused `import qualified Crypto.Hash as Hash` from
  `core/hostbootstrap-core/src/HostBootstrap/Service.hs`, and add `import HostBootstrap.Digest (sha256Hex)`.

## Remaining Work

- Sprint 22.1: add the `service init` case, golden the whole `service schema` output, rewrite the `service run`
  refusal cases on a signed installed revision with exact diagnostics, assert the missing `down` verb and the
  config-free variant listing by their output, correct the `serviceCommandGroup` Haddock and the `run`
  `progDesc`, and make the five-verb command-surface case read both entrypoints' rendered top-level command
  list.
- Sprint 22.2: make `readyServiceHandles` package-private with a compile-fail fixture, delete
  `interpretServiceProgram`, and add the `call`/`work`, exact durable-path, exact refusal, and selection-refusal
  cases.
- Sprint 22.3: add the installed-revision opener refusals, revision-path shape refusals, exact secret-safe
  diagnostic, and consumed-admission read-back to `ActivationSpec`.
- Sprint 22.6: mint the durable root per service from a platform coordinate, write durably by
  temporary-plus-rename, and map durable and backend IO failures to `ServiceEffectFailed`.
- Sprint 22.7: authorize the declared effect row before the lifecycle and bracket the lease by its
  requirement.
- Sprint 22.8: verify relayed grants before staging, leave no staging residue, treat `.installing` files as
  scratch, and check revision identity before reading members.
- Sprint 22.9: derive the finalization scope kind from the codec and render one schema family.
- Sprint 22.10: seal each mutating service effect in a durable per-call journal with same-key reprobe or retry.
- Sprint 22.11: persist role receipts so an uncatchably killed instance's acquisitions are enumerable.
- Sprint 22.12: settle predecessor instances on `RoleAdmissionRecoveryRequired` instead of refusing.
- Sprint 22.13: advance a durable fence and settle the predecessor's open journal entries before an exclusive
  lease transfers.
- Sprint 22.14: `Service` takes `sha256Hex` from `HostBootstrap.Digest`.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — the fixed `service` surface.
- `documents/architecture/composition_methodology.md` — role adoption at `service run`.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the gate kinds this phase closes on and the run it records.
- `documents/engineering/accelerator_daemon.md` — daemon startup ordering and teardown expectations.

**Cross-references to add:**
- `development_plan_standards.md` § AA names this phase as the owner of the service runtime.
