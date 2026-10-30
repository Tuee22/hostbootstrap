# Phase 21 — Composition and network algebra

**Status**: Active
**Depends on**: Phase 16 (cluster lifecycle, budgets, and cordoning), Phase 17 (the recursive lifecycle
command)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-13 ; x86_64 Ubuntu 24.04.4 LTS, Linux 7.0.0-28-generic, GHC 9.12.4,
Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror --test-show-details=direct
--test-options=--hide-successes` from `core/` ; pass ; covers in-gate

> **Purpose**: Supply the scope-indexed endpoint and reachability algebra, the proof-gated blob delivery it
> enables, and the opaque role phase machine a long-running workload is driven by.

## Phase Objective

Two reusable algebras sit above the cluster and below the service surface. The first is network reachability:
an endpoint is indexed by the scope that can reach it, so a client cannot be handed an address its own scope
cannot resolve — and a redirect is only delivered once there is a proof the client can reach the target. The
second is the role phase machine: a long-running workload's lifecycle is an opaque cursor rather than a bag of
callbacks a caller can skip.

## Sprints

### Sprint 21.1: Scope-indexed endpoints and resolved reachability [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Network.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`, `core/hostbootstrap-core/test/RegistryPlanSpec.hs`,
`core/hostbootstrap-core/test/LiftSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`

#### Objective

Make "this client can reach this endpoint" a typed fact.

#### Deliverables

- An endpoint is indexed by the scope that can reach it, so a cluster-only address cannot be handed to a host
  client.
- `Reachability` has exactly four constructors — `HostReachesHost`, `VmReachesVm`, `VmReachesCluster`,
  `ClusterReachesCluster` — and every other pair (host→cluster, host→VM, VM→host, cluster→host,
  cluster→VM) is unreachable. The term-level `reachableFrom` is derived from the GADT through an exhaustive
  decision with no wildcard clause, so the two views cannot drift.
- An endpoint authority is a non-empty host with an optional `:port` admitted by `mkPort`. Surrounding
  whitespace, a scheme, a path, an empty host, or a second colon is refused, never stripped or passed through.
- A reachability proof is produced by observation, not assertion, and carries the scope it was taken in.
- A host- or provider-local endpoint is projected only from the cluster backend's exact
  `ResolvedExposure`; configuration and rendered cluster bytes carry semantic service identity and the
  cluster-internal target, never the selected host port.
- The selected port is an invocation/runtime result carried in the dependency package with the exact relay,
  cluster generation, and ownership operation. It is neither serialized back into Dhall nor reconstructed
  from a conventional port number on restart.
- Route readiness is its own observation. The `/v2/` readiness witness (`ObservedReady`) only orders the
  route probe after the registry answers; the route proof is the blob-request observation `settleBlobRoute`
  consumes (Sprint 21.2), because a listening registry is not a working delivery path.
- `reachLeaf` is the additive smart constructor that renders the reachability probe through the lower generic
  Lift. This phase owns the constructor; the fold it renders through, `foldLeaf`, is the lower Lift's and
  is not owned here.

#### Validation

`RegistryPlanSpec` covers each scope pairing, projection from an exact resolved exposure,
cross-service/cluster/generation refusal, and the refusal when scopes do not match. `LiftSpec` covers the
`reachLeaf` fold for the local, Incus, Lima, and WSL2 contexts. Compile-fail coverage rejects a host endpoint
made from text or a raw port. `RegistrySpec`'s source guard checks that `reachLeaf :: String -> LiftLeaf`
stays in the lower generic Lift and that `Network.hs` carries no `30500` literal.

The sprint closes when the cases named under Remaining Work exist and pass under `cabal test all` from
`core/`.

#### Completion Evidence

`RegistrySpec` passes all 21 cases under `-Werror`, including the source guard that keeps `reachLeaf` in the
lower Lift and the dependency direction guard; the `reachLeaf` argument shapes pass in `LiftSpec`.

#### Remaining Work

- `Network.hs`: the `Reachability` Haddock drops the sentence saying a cluster client reaches a
  host-published port, and names the four constructors and the five absent pairs instead. The module stays
  free of any `ClusterOnly`→`HostLocal` constructor.
- `Network.hs`: add `decideReachability :: ScopeName client -> ScopeName endpoint -> Maybe (Reachability
  client endpoint)` as nine explicit clauses with no wildcard, and define `reachableFrom` through it. The
  `RoleLifecycle.hs` Haddock on `DeclaredEffects` cites it as precedent only once that holds. Test: a
  `RegistryPlanSpec` case that, for all nine `ScopeName` pairs, checks `isJust (decideReachability c e)`
  against `reachableFrom (scopeNameOf c) (scopeNameOf e)`. For each `Just` witness it also checks that
  `reachabilityClientScope` and `reachabilityEndpointScope` report `(c, e)`.
- `Network.hs`: `mkEndpoint` parses the authority as a non-empty host plus an optional `:port` admitted
  through `mkPort`, and refuses surrounding whitespace with `InvalidEndpointAuthority` instead of stripping
  it. `clusterServiceExposure` refuses a service name that is empty, carries whitespace, or contains `:`.
  Test: `RegistryPlanSpec` cases asserting `InvalidEndpointAuthority` for `":9000"`, `"minio:80:9000"`,
  `"minio:99999"`, `"minio:abc"`, and `" minio:9000"`, and a refusal of `clusterServiceExposure " svc" 9000`
  and `clusterServiceExposure "" 9000`.
- `RegistryPlanSpec`: add `clusterOnlyEndpoint "http://minio.default.svc:9000"` and assert
  `InvalidEndpointAuthority` carries the message `an endpoint authority is host:port, not a URL with a
  scheme`, so the scheme guard cannot be reordered behind the path guard.
- `RegistryPlanSpec`: "a local exposure retains the exact runtime identity" uses the `resolved` list
  `withRuntimeExposure` supplies. It reads the expected relay, generation, operation, and host port through
  `withResolvedExposure` with `resolvedExposureRelayIdentity`, `resolvedExposureClusterGeneration`,
  `resolvedExposureOwnershipOperation`, and `resolvedExposureHostPort`, and asserts equality with the
  exposure's `exposureRuntimeIdentity` and `exposurePort`. Non-emptiness alone is not the check.

### Sprint 21.2: Proof-gated blob delivery [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Registry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RegistryPlan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`, `core/hostbootstrap-core/test/RegistryPlanSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeReadyBlobRoute.hs`,
`core/hostbootstrap-core/test/compile-fail/RawRegistryPlan.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`

#### Objective

Never redirect a client to something it cannot reach.

#### Deliverables

- A blob route is delivered only behind a settled route proof; liveness of the front door is not evidence that
  the backing store is reachable from the client's scope.
- The finalized registry plan renders the registry's blob-delivery and store-address configuration as output.
  `renderStorageRedirect` derives `redirect: disable` from the delivery. The store authority the registry's
  storage driver dials is rendered from `registryPlanStore`, so the registry receives the plan's store
  address rather than a second literal.
- A redirecting delivery settles only on a `3xx` observation whose `Location` authority is the planned
  store's; any other status refuses with `BlobRouteMismatch`.
- `RegistryPlan` and `ReadyBlobRoute` keep their data constructors private, and the compile-fail fixtures
  fail on that privacy rather than on kind arity.
- An image push requires a settled route rather than a successful ping.
- `blobUploadSessionLeaf`, `blobUploadPatchLeaf`, `blobUploadFinishLeaf`, and `blobHeadLeaf` are additive
  Lift smart constructors owned by this blob-delivery sprint, not by the lower generic fold.
- `HostBootstrap.Registry` owns `liftSubcommandWithAuth`: registry policy consumes the lower Lift and its
  generic `shellQuoteArgs`; `HostBootstrap.Lift` never imports Registry or its credential type.
- Both the container invocation and its provider crossing are rendered by `foldLeaf`. Registry inserts the
  stdin-to-environment policy between those two folds and owns no provider or container argument builder.
  Credentials remain absent from argv and are supplied only at the existing stdin effect boundary.

#### Validation

`RegistryPlanSpec` covers the finalized redirect rendering and the refusal when the route is not settled: a
`/v2/` answer, a stale revision, a proxying plan that redirects or errors, a redirect to an unplanned
authority, and a probe of a different published port. `RegistrySpec` pins all four blob leaf argument shapes
and registry-auth lift planning, and its source guard pins the `Registry -> Lift` dependency direction. The
compile-fail fixture `HostLocalClusterRedirect.hs` proves an unreachable configuration cannot be given a
redirecting delivery.

The sprint closes when the cases named under Remaining Work exist and pass under `cabal test all` from
`core/`, including the two rewritten compile-fail fixtures.

#### Completion Evidence

`RegistrySpec` passes 21/21 and `RegistryPlanSpec` passes 22/22 under `-Werror`. The former pins every
argument of the upload-session, upload-patch, upload-finish, and blob-head leaves. The source guard proves
Registry depends on lower Lift and that generic Lift imports no credential policy.

#### Remaining Work

- `RegistryPlan.hs`: add a renderer of the storage driver's store address,
  `renderStorageStoreEndpoint :: RegistryPlan client store lifecycleScope planId clusterId service -> [Text]`,
  that returns `["  s3:", "    regionendpoint: http://" <> endpointAuthority (registryPlanStore plan)]`.
  Test: a `RegistryPlanSpec` case builds a host-served plan over
  `clusterOnlyEndpoint "object-store.default.svc:9000"` and asserts exactly those two lines. A second case
  builds a plan over a different store authority and asserts that the rendered line follows it.
- `RegistryPlan.hs`: on the `RedirectBlobs` path, `settleBlobRoute` requires `observedStatus` in
  `300..399` and otherwise refuses with `BlobRouteMismatch` whose actual text is `status <n>`. Test:
  `RegistryPlanSpec` cases on the in-cluster plan. Status `307` to the planned authority settles. Status
  `404` and status `200`, each carrying the planned `Location`, refuse. Sprint 21.8 owns the redirect's scope:
  its observation carries no caller-asserted scope.
- `test/compile-fail/ForgeReadyBlobRoute.hs` declares
  `forged :: ReadyBlobRoute 'HostLocal 'ClusterOnly scope planId clusterId service`, and `CompileFailSpec`
  expects `Illegal term-level use of the type constructor ‘ReadyBlobRoute’`.
- `test/compile-fail/RawRegistryPlan.hs` fully applies the six indices, passes an
  `Exposure 'HostLocal scope planId clusterId service` in the exposure position, and `CompileFailSpec`
  expects `Illegal term-level use of the type constructor ‘RegistryPlan’`. Both fixtures then fail only
  because the data constructors are private.

### Sprint 21.3: The opaque role phase machine [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/test/RoleLifecycleSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeRoleCursor.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Drive a long-running role through phases a caller cannot skip.

#### Deliverables

- `RolePlan` and `RoleCursor` are opaque; the machine is reached only through a verified activation, then a
  verified role-plan draft, then a one-use lifecycle admission. Project code contributes a per-resource
  `RoleEngine` callback record (prereq, acquire, probe, serve, release); the engine owns the sequencing, so
  no callback can reorder or omit a phase.
- The one-use lifecycle admission consumes Phase 13's verified activation under `roleAdmissionKey`, the
  fixed-width key `role-admission.<sha256>` over the framed domain `hostbootstrap/role-admission/v1`, the
  exact plan digest, frame, revision, and measured instance coordinates.
- The lease requirement is **derived** from the signed effect ceiling rather than declared, and an exclusive
  branch holds a real kernel lock across acquire-through-drain. An `EffectAuthorization` carries no lease
  requirement of its own.
- A caller holds only the one-use `RoleCursor … PrereqPhase`. `runRoleLifecycle` consumes it, sequences
  Prereq → Acquire → Ready → Serve → Drain → Exit internally, and returns one `RoleExitReport` naming the
  phase where the role turned. Drain attempts every release and aggregates the failures. An unknown
  acquisition whose release fails stays in the report's unknown set.
- A prerequisite refusal turns at its own phase and acquires nothing; a readiness failure, including a probe
  that throws, cannot reach serve.
- A catchable asynchronous exception during Serve is an orderly shutdown (`ServeShutdown`), not a serve
  failure. Callback results are forced to normal form inside the masked boundary, so no exception escapes
  the typed report.
- A resource name is one plain line: it carries no control character and no Unicode line or paragraph
  separator. The generation lease name is a domain-separated digest over framed service and frame fields, so
  two distinct `(service, frame)` pairs never share a lease and the name has a fixed length.

#### Validation

`RoleLifecycleSpec` covers the admission chain, the derived lease requirement, each phase transition including
failures, the aggregate drain, and a live exclusive holder refusing a peer before it acquires anything. Its
"one-use lifecycle admission" group covers the bounded admission key, its rehydration, and the protected-store
key-length limit.

The sprint closes when the cases named under Remaining Work exist and pass under `cabal test all` from
`core/`, with the retargeted `ForgeRoleCursor.hs` fixture still rejected.

#### Completion Evidence

`RoleLifecycleSpec` passes 42/42 under `-Werror`. It covers the one-use cursor, a distinct measured peer
refused by the live exclusive kernel holder before acquisition, forced delayed failures, a callback-thrown
`ThreadKilled` reaching Drain, clean shutdown reporting, and Reserved/Consumed lost-acknowledgement
recovery. `CoerceRoleLifecycleAuthorityRoles.hs` pins every nominal axis of the plan, binding, placement,
effect authorization, and cursor. Unknown acquisition cleanup has the documented narrow total
reprobe-and-release contract. Adoption at `service run` is Phase 22's work.

#### Remaining Work

- `RoleLifecycle.hs`: delete the exports and declarations of `AcquirePhase`, `ReadyPhase`, `ServePhase`,
  `DrainPhase`, and `ExitPhase`, which no signature uses. `ForgeRoleCursor.hs` forges
  `RoleCursor s p f i PrereqPhase` and keeps its `Illegal term-level use of the type constructor 'RoleCursor'`
  expectation.
- `RoleLifecycle.hs`: delete `authorizedLeaseRequirement` and the `LeaseRequirement` field of
  `EffectAuthorization`. The `authorizeServiceEffects` Haddock drops the sentence that a narrower row does
  not inherit its ceiling's lease, and states that the run's lease is the ceiling's
  (`placementLeaseRequirement`). The three `RoleLifecycleSpec` cases that read `authorizedLeaseRequirement`
  assert `authorizedEffects` and `placementLeaseRequirement` instead.
- `RoleLifecycle.hs`: in `servePhase`, a `SomeAsyncException` caught by `guarded` maps to `ServeShutdown`;
  a synchronous exception stays `ServeFailed`. Test: a `RoleLifecycleSpec` case whose `engineServe` blocks on
  an `MVar` while a second thread delivers `throwTo` with `UserInterrupt`. It asserts `exitTurnedAtPhase ==
  Serve`, an `exitReason` beginning `shutdown: `, every release in the trace, and `roleExitReportOk`.
- `RoleLifecycle.hs`: `guarded` forces each outcome to normal form before leaving `Exception.try`, so a
  lazy failure inside a detail `Text` is caught. Forcing the detail `Text` with `Text.length` inside the
  guarded action needs no new dependency; `deepseq` is not yet a dependency of the package.
  Test: `engineAcquire` returns `AcquireFailed (error "late detail")`. The case asserts that
  `renderRoleExitReport` and `roleExitReportOk` evaluate without throwing and that Drain ran.
- `RoleLifecycle.hs`: `mkRoleResourceRequest` refuses any `isControl` character and U+0085, U+2028, and
  U+2029. Test: `RoleLifecycleSpec` cases for `""`, `"a\0b"`, `"db\rrole exit"`, `"a\x2028b"`, and
  `"two\nlines"`, each asserting `RoleDraftInvalid` with its specific message.
- `RoleLifecycle.hs`: the generation lease name is `"role-lease." <> sha256Hex` over the `frameWire`-framed
  service and frame, as `roleAdmissionKey` builds its key. Test: two placements, service `a.b` in frame `c`
  and service `a` in frame `b.c`, run concurrently under `RequiresGenerationLease`, and neither is refused
  with the lease-held text. A second case uses a 300-character service name and asserts that the lease is
  taken rather than refused as unavailable.
- `RoleLifecycleSpec`: the length-prefix case compares `draftOf [request "xsharedy" False]` with
  `draftOf [request "x" False, request "y" False]`, which collide without framing. The signed-digest case
  is renamed to what it checks, or asserts `rolePlanDigestBindingPlanDigest binding == "plan-1"` (the
  manifest's plan digest).
- `RoleLifecycleSpec`: add a case where `engineProbe` throws, asserting that release runs for every acquired
  resource and the report is not ok. Add a case where `AcquireUnknown` on `worker` meets a `ReleaseFailed`
  release, asserting `exitUnknownResources == ["worker"]`, a drain failure naming `worker`, and
  `roleExitReportOk == False`. The asynchronous-acquisition case delivers
  `ThreadKilled` with `throwTo` from another thread while `engineAcquire` blocks on an `MVar`, and asserts
  that Drain ran and that `exitReason` names the unknown acquisition of `worker`. The other-store refusal
  case asserts that `protectedStoreRoot other </> "liveness"` does not exist after the run.

## Completion Evidence

The lifecycle route validates its closed launch policy but derives every provider crossing through
`foldLeaf`/`lifecycleProcessLeaf`; Registry authentication likewise builds on lower Lift. Thus § LL has one
crossing renderer. On 2026-08-22 the exact gate `cabal test all --ghc-options=-Werror` passed all 2,375
tests in 147.50 seconds. The architecture and engineering documents named below record the resulting
network, admission, interruption, recovery, and authoring contracts.

That dated evidence covers blob delivery and the role machine. The final resolved-exposure evidence follows.

On 2026-08-22 the final exact gate `cabal test all --ghc-options=-Werror` passed all 2,437 tests in
225.41 seconds on Linux x86_64 with GHC 9.12.4 and Cabal 3.16.1.0. `RegistryPlanSpec` passed all 21
network, exposure, finalized-plan, and route-readiness cases. Its exposure fixtures project a real
second-process relay inspection into a host-local exposure, and a hand-built observation that mismatches the
service, port, relay identity, cluster generation, or ownership operation cannot settle readiness. Compile-fail
coverage rejects raw host endpoint/port construction and coercion across lifecycle-scope, plan, cluster, or
service roles. The source guard proves `Network` consumes `Cluster.Backend`, exposes no raw local constructor
or conventional host-port constant, and leaves `reachLeaf` in the lower generic Lift.

On 2026-09-05 the final Linux x86_64 gate passed all 2,492 tests in 141.73 seconds with GHC 9.12.4
and Cabal 3.16.1.0. Authenticated forwarding uses `foldLeaf` for both crossings; exact Incus, Lima, and
WSL argument checks, unsupported frame shapes, and the nonvacuous duplicate-renderer guard pass. The native
macOS registry and finalized-plan checks also passed 42/42 in 20.08 seconds.

### Sprint 21.4: A port is a value, and there is one of it [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/network-port/HostBootstrap/Network/Port.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Network.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RegistryPlan.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/RegistryPlanSpec.hs`
**Production modules**: `HostBootstrap.Network.Port` is the sprint's one new named contract; the changed
modules are `HostBootstrap.Network`, `HostBootstrap.Cluster.Backend`, and `HostBootstrap.RegistryPlan`
(3 changed; cap 3).
**Sprint budget**: one new named type and its two surfaces; at most 120 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`

#### Objective

This phase owns the reachability algebra, where an endpoint is deliberately not interchangeable text.
The port inside it is a bare integer, and the predicate that decides whether one is in range is
defined twice with identical bodies in two modules — so the range is agreed by coincidence rather than
by construction, and every consumer re-decides whether its integer was checked.

#### Deliverables

- A port is a value with a validating producer, in the module that owns the reachability vocabulary.
- The exposure and registry surfaces carry the value rather than a bare integer.
- A case pins the refusal of an out-of-range port at the producer rather than at each consumer.
- The copies of the range predicate in those modules are deleted.

#### Validation

The host static gate; the registry and network suites cover the exposure paths.

#### Remaining Work

None. `HostBootstrap.Network.Port` is a leaf private library owning `Port`, `mkPort`, and `portNumber`,
and `HostBootstrap.Network` re-exports all three so the reachability vocabulary stays where a reader
looks for what a port is. It is a leaf because the cluster backend sits *below* the reachability
vocabulary — `Network` imports `Cluster.Backend`, not the other way round — so a definition inside
`Network` could not have reached the backend at all. `Exposure` and `ResolvedExposure` carry `Port` for
their host and target ports, `BlobRouteObservation` carries it for the port a probe dialled, and
`clusterServiceExposure` mints through the producer so `InvalidEndpointPort` is raised in one place.
`RegistryPlanSpec` pins the closed range at the producer — `minBound`, `-1`, `0`, `1`, `8080`, `65535`,
`65536`, `maxBound` — and the exposure refusal at `0` and `65536`. On 2026-09-13 the warning-clean
`-Werror` build and the complete 2,536/2,536 core host-static gate passed, with the demo consumer's
150/150 beside it.

The two range predicates that survive in `HostBootstrap.Cluster.Shipped` and
`HostBootstrap.Cluster.Lifecycle`, and the one in the runtime dependency package, belong to
**Sprint 21.5**; this sprint's own two are gone.

### Sprint 21.5: The last three range decisions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`
**Production modules**: `HostBootstrap.Cluster.Lifecycle`, `HostBootstrap.Cluster.Shipped`,
`HostBootstrap.Lifecycle.Dependency.Internal` (3; cap 3)
**Sprint budget**: no new named type and three call-site adoptions; at most 80 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`

#### Objective

Sprint 21.4 left the producer as the only definition of the range in the two modules it touched. Three
byte-identical copies of the old predicate stand elsewhere: the plan's exposure intent, the shipped
exposure codec, and the runtime dependency package. Each still decides for itself what a port is.

#### Deliverables

- The three remaining copies are deleted; every range decision routes through the one producer.
- The plan's exposure intent and the runtime dependency exposure rows carry the value.
- The shipped exposure codec, which returns a number to a consumer outside this phase, asks the producer
  for its admission rather than restating the bound.

#### Validation

The host static gate, plus the cluster and dependency suites that cover those three surfaces.

#### Remaining Work

None. `ExposureIntent` carries `Port`, `mkPlanExposureIntent` mints through `mkPort`, and the runtime
dependency exposure rows are `(Text, Text, Port, Text, Port, Text, Word64, Text)` — so
`renderRuntimeDependencyExposureResponse` needs no port validity clause, and the resolved exposure the
cluster backend builds from those rows does not re-mint one. The shipped codec keeps its `Int` result for
its cross-frame consumer and admits it through `mkPort`. No `validPort` predicate stands under `core/`; the
worked consumer's own `Port` and port-range check belong to the worked-demo phase. On 2026-09-13 the
warning-clean `-Werror` build and the complete 2,536/2,536 core host-static gate passed, with the demo
consumer's 150/150 beside it.

Routing the runtime dependency package through the shared producer needed the
`lifecycle-dependency-internal` private library to depend on the new leaf, which is what keeps the
`Port` a test sees through that library identical to the one it sees through
`HostBootstrap.Network`.

### Sprint 21.6: One fenced admission path [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/test/RoleLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

The one-use lifecycle admission has one consume path and one reopen path, the ones the service runtime calls.
A Consumed row reopens a plan only while no run has started from it, so a lost acknowledgement is recoverable
and a duplicated activation is not a second run.

#### Deliverables

- `withRuntimeRolePlanForRequest` and `resumeRuntimeRolePlanOpenForRequest` are the only consume and
  reopen entries. One private consume core and one private reopen core hold the store-origin check, the
  `ProtectedVersionMismatch` → `RoleAdmissionAlreadyConsumed` mapping, and the consumed-row match.
- `RolePlan` privately carries its admission key and the version of the Consumed row it was opened from.
  Before Prereq, `runRoleLifecycle` compare-and-swaps that row from `consumed <digest>` at that version to
  `opened <digest>` inside `withProtectedEntry` on the store it is given. A version mismatch exits through
  `exitWithNoRoleResources` with `the lifecycle admission was already opened`, before any callback runs.
- The reopen entry hands out a cursor only for a row reading `consumed <digest>`; of two reopeners of one
  row, exactly one wins the `opened` transition. A row reading `opened <digest>` refuses with
  `RoleAdmissionAlreadyConsumed`.
- `withRoleLifecycleAdmission` classifies `opened <digest>` as `RoleAdmissionRefused` naming the admission
  key, never as `RoleAdmissionOpenUnknown`.

#### Validation

Every consume, reopen, origin, and fence case in `RoleLifecycleSpec` drives the request-indexed entries, and
each refusal the service runtime can receive from admission is produced by a test. The sprint closes when the
cases below exist and pass under `cabal test all` from `core/`.

#### Remaining Work

- `RoleLifecycle.hs`: delete `withRuntimeRolePlan` and `resumeRuntimeRolePlanOpen` and factor the shared
  consume and reopen cores. Every `RoleLifecycleSpec` case that calls them calls the request-indexed entry
  instead, with a `ValidatedServiceRequest` obtained through the activation decode path `ActivationSpec`
  uses.
- `RoleLifecycleSpec`: ten `RoleActivationRequestMismatch` cases, one per guard (config digest, spec digest,
  selected service, frame, leaf context kind) on each of the two entries. Each request differs from the
  activation in exactly one coordinate. Each case asserts the guard's own message and that the admission row
  still reads `reserved <digest>` (consume entry) or `consumed <digest>` (reopen entry).
- `RoleLifecycleSpec`: reserve once to learn the key, then compare-and-swap the row, at the version
  `readProtectedRecord` reports, to `reserved <foreign digest>` and in a second case to
  `consumed <foreign digest>`. Each asserts `RoleAdmissionRecoveryRequired key persisted` and unchanged record
  bytes. A third case replaces the row's record file with a directory and asserts `RoleAdmissionUnknown`.
- `RoleLifecycleSpec`: the lost-reservation case captures both keys, asserts that they are equal, and consumes
  the rehydrated reservation to `Right`. The cross-store case asserts that `readProtectedRecord` on the
  admission key in `other` returns `Right Nothing` after the refused attempt, before the legitimate admission
  reserves afresh.
- `RoleLifecycleSpec` fence cases. After one completed run, a second `withRoleLifecycleAdmission` with the
  same activation returns `RoleAdmissionRefused`, and the row reads `opened <digest>`. Two reopeners of one
  Consumed row both obtain cursors and run in turn: the second report turns at Prereq with `the lifecycle
  admission was already opened`, and its engine trace is empty. A consume whose cursor is discarded unused
  reopens and runs to Exit.

### Sprint 21.7: A local exposure's scope and identity come from its inspection [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Network.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RegistryPlan.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/RegistryPlanSpec.hs`, `core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Production modules**: one new leaf module owning `NetworkScope` and `ScopeName`; the changed modules are
`HostBootstrap.Network`, `HostBootstrap.Cluster.Backend`, and `HostBootstrap.RegistryPlan` (3 changed; cap 3).
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`

#### Objective

A local exposure's network index is the scope its relay listens in, and its runtime identity crosses the
exposure boundary as typed coordinates. Today `resolvedHostExposure` and `resolvedVmExposure` stamp the same
loopback `ResolvedExposure` with whichever scope the caller picks. The relay, generation, and operation also
leave as an anonymous `(Text, Word64, Text)` whose two `Text` coordinates can be transposed silently.

#### Deliverables

- `NetworkScope` and `ScopeName` live in a leaf private library below `Cluster.Backend`, re-exported by
  `HostBootstrap.Network`, the way `HostBootstrap.Network.Port` is.
- `ResolvedExposure` carries a `network` index fixed where the relay inspection mints it, from the
  `ScopeName` of the frame the inspection runs in. One projection,
  `resolvedLocalExposure :: ResolvedExposure network lifecycleScope planId clusterId service -> Exposure network
  lifecycleScope planId clusterId service`, is the only way to build a local exposure.
- The runtime identity is a record of the newtypes `RelayIdentity`, `ClusterGeneration`, and
  `OwnershipOperation`. `Cluster.Backend`, `exposureRuntimeIdentity`, and `observedRuntimeIdentity` share
  the record.
- The `HostBootstrap.Network` module Haddock and the `Endpoint` Haddock state each producer's guarantee:
  `clusterOnlyEndpoint` validates authority text, and a local endpoint is projected from an inspected
  loopback exposure in the inspecting frame's scope.

#### Validation

Compile-fail fixtures reject a relabelled exposure and a transposed identity coordinate, and the exposure cases
read the expected scope and identity from the inspection rather than from the exposure under test. The sprint
closes when the cases below exist and pass under `cabal test all` from `core/` and from `demo/`.

#### Remaining Work

- Add the leaf library `internal/network-scope/HostBootstrap/Network/Scope.hs` with its Cabal stanza, move
  `NetworkScope`, `ScopeName`, and `scopeNameOf` into it, and re-export them from `HostBootstrap.Network`.
- `Cluster/Backend.hs`: index `ResolvedExposure` by `network` and set it from the inspecting frame's
  `ScopeName` where `resolvedExposureFromFields` mints it. `Network.hs`: replace `resolvedHostExposure` and
  `resolvedVmExposure` with `resolvedLocalExposure`. The worked consumer's two call sites
  (`demoRegistryPlan` and the `withResolvedExposure` consumer in `demo/src/HostBootstrapDemo/Commands.hs`)
  call it. Test: compile-fail fixture `RelabelVmExposureAsHost.hs` passes a `ResolvedExposure 'VmLocal …`
  where an `Exposure 'HostLocal …` is expected, and `CompileFailSpec` expects
  `Couldn't match type 'VmLocal' with 'HostLocal'`. A `ClusterBackendSpec` case asserts that an inspection
  run in the host frame yields exposures whose endpoint scope is `HostLocal`.
- `Network.hs`, `Cluster/Backend.hs`, `RegistryPlan.hs`: replace the `(Text, Word64, Text)` tuple with the
  identity record and its three newtypes. Test: compile-fail fixture `SwapExposureRelayOperation.hs` passes an
  `OwnershipOperation` where a `RelayIdentity` is expected, and `CompileFailSpec` expects
  `Couldn't match expected type ‘RelayIdentity’ with actual type ‘OwnershipOperation’`. The
  `RegistryPlanSpec` identity case compares the record field by field with the coordinates the inspection
  returned.
- `Network.hs`: rewrite the module and `Endpoint` Haddocks to the guarantee each producer holds.

### Sprint 21.8: The blob-route observation is minted from an inspection and an answer [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RegistryPlan.hs`,
`core/hostbootstrap-core/test/RegistryPlanSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`,
`documents/engineering/in_cluster_registry.md`

#### Objective

`settleBlobRoute` refuses an observation whose service, port, relay, generation, operation, or revision
differ from the plan. Those checks only mean something if the observation records what was dialled and who
answered. Today `BlobRouteObservation (..)` is a public record, and its one producer copies those fields from
the plan it is checked against. Only the status and the `Location` text are actually observed. This sprint
makes the observation a value only a probe result can produce.

#### Deliverables

- `BlobRouteObservation` is exported without its constructor. Its one producer takes the service, dialled
  port, relay, generation, and operation from a `ResolvedExposure`, which only the backend's relay inspection
  mints. It takes the status and the `Location` authority from the probe's
  `curl -w "%{http_code} %{redirect_url}"` answer.
- The inspection a route observation uses is run for that probe, after the blob HEAD's preconditions. It is
  never the inspection the plan was built from, so a different relay, generation, or operation answering on
  the dialled port refuses.
- The observation records the `Location` authority only. `settleBlobRoute` refuses every authority other
  than the planned store's, so the store's scope follows from that equality and the plan's `Reachability`
  witness rather than from a caller's claim.
- An unreadable answer refuses with a typed `RegistryPlanError`, not a caller-side string.

#### Validation

`RegistryPlanSpec` builds every observation through the producer from runtime-exposure fixtures and literal
answers, and a compile-fail fixture rejects a hand-built observation. The sprint closes when the cases below
exist and pass under `cabal test all` from `core/` and from `demo/`.

#### Remaining Work

- `RegistryPlan.hs`: export `BlobRouteObservation` abstractly. Add the producer `blobRouteObservation ::
  RegistryPlan client store lifecycleScope planId clusterId service -> ResolvedExposure network lifecycleScope
  planId clusterId service' -> BlobProbe -> Text -> Either RegistryPlanError BlobRouteObservation` and the
  refusal `BlobRouteUnreadable Text`. Narrow `observedRedirect` to `Maybe Text` (the authority parsed from
  the `Location` URL) and drop the scope guard in `settleBlobRoute`.
- `demo/src/HostBootstrapDemo/Commands.hs`: delete `parseBlobRouteAnswer`. `awaitBlobRoute` runs the
  backend's runtime exposure inspection before the blob HEAD and builds its observation with
  `blobRouteObservation`.
- `RegistryPlanSpec`: `servedBlob` and `redirectedBlob` build through the producer from `withRuntimeExposure`
  fixtures with answers `"200 "` and `"307 http://minio.default.svc:9000/registry/blob"`. Add a case where an
  inspection of a second relay process settles against the first plan and refuses with `BlobRouteMismatch`
  `a different runtime exposure identity`. Add a case where the answer `"abc"` refuses with
  `BlobRouteUnreadable`. Add a case where a `Location` to `somewhere.else:9000` refuses.
- Compile-fail fixture `ForgeBlobRouteObservation.hs` applies `BlobRouteObservation` positionally, and
  `CompileFailSpec` expects `Illegal term-level use of the type constructor ‘BlobRouteObservation’`.

### Sprint 21.9: The forwarded Docker Hub credential is exact and scrubbed [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Registry.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/registry_credentials.md`

#### Objective

The forwarded payload holds Docker Hub entries and nothing else, and the in-container half removes every
trace of the credential when its action ends. Today `isDockerHubKey` keeps any key containing `docker.io`,
and the credential lifecycle that `withForwardedRegistryAuth` and `discoverHostRegistryAuth` implement is not
called by any test.

#### Deliverables

- A Docker Hub entry is selected by exact match after normalisation (drop an `https://` or `http://` prefix
  and a trailing `/`, lowercase) against `index.docker.io/v1`, `index.docker.io`, `docker.io`, and
  `registry-1.docker.io`. The module Haddock and the `isDockerHubKey` comment name exactly that set.
- A Hub entry without a non-empty inline `auth` or `identitytoken` is not a credential.
- `withForwardedRegistryAuth` writes the payload as UTF-8 bytes and removes its temporary directory even when
  the write fails. It unsets `HOSTBOOTSTRAP_REGISTRY_AUTH` for the action and restores the prior
  `DOCKER_CONFIG` whatever the action does.
- `discoverHostRegistryAuth` reads `$DOCKER_CONFIG/config.json` and yields `Nothing` for an absent or
  unreadable file.
- The module header and the `RegistryAuth` Haddock state what the type guarantees and no more: the
  constructor is hidden, `Show` is redacted, and there is no Dhall or JSON instance, so the library never
  writes the credential into Dhall, a `show`-based log, or a generated artifact. `registryConfigPayload`
  returns the raw bytes, and a caller holding them can log or persist them.

#### Validation

`RegistrySpec` covers each key spelling, each non-credential entry shape, and the full credential lifecycle,
including an action that throws. The sprint closes when the cases below exist and pass under
`cabal test all` from `core/`.

#### Remaining Work

- `Registry.hs`: rewrite `isDockerHubKey` as the exact normalised match and align the Haddocks. Test:
  `dockerHubAuthFromConfig` yields `Just` for each of `https://index.docker.io/v1/`, `index.docker.io`,
  `docker.io`, and `registry-1.docker.io` carrying `{"auth":"eA=="}`. It yields `Nothing` for
  `{"auths":{"https://index.docker.io/v1/":{}}}`, for an entry whose `auth` is `""`, for
  `docker.io.mirror.corp:5000`, and for `harbor.docker.io.corp.example`.
- `Registry.hs`: `withEphemeralDockerConfig` writes `Data.ByteString.writeFile` of `encodeUtf8 payload`, and
  holds the `mkdtemp` directory in its own `bracket` so a failed write still removes it. Test: a payload
  carrying `é` reads back byte-exact from `config.json` inside the action, and no `hb-registry-*` directory
  remains under the test's `TMPDIR` afterwards.
- `RegistrySpec` (POSIX): set `HOSTBOOTSTRAP_REGISTRY_AUTH` and `DOCKER_CONFIG=/prev`, then run
  `withForwardedRegistryAuth` with an action that records the auth variable, `DOCKER_CONFIG`, and the
  `config.json` bytes, then throws. Assert that the auth variable was unset inside the action and the bytes
  equal the payload. Assert that afterwards `DOCKER_CONFIG` is `/prev` and the recorded directory is gone. A
  second case starts with `DOCKER_CONFIG` unset and asserts it is unset afterwards. These cases run
  sequentially because they mutate the process environment.
- `RegistrySpec` (POSIX): `discoverHostRegistryAuth` under a temporary `DOCKER_CONFIG` yields `Just` for a
  valid Hub config and `Nothing` when `config.json` is absent or is a directory.
- `Registry.hs`: rewrite the module header (lines 4-31) and the `RegistryAuth` Haddock to the guarantee
  above. They drop "unrepresentable", "never logged", "never persisted", and "cannot leak into Dhall, logs,
  or generated artifacts", and name `registryConfigPayload` as the accessor that hands out the raw bytes,
  matching `documents/engineering/registry_credentials.md`.

### Sprint 21.10: Credential forwarding without interpreter text [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Registry.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`, `core/hostbootstrap-core/test/EffectSpec.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/registry_credentials.md`

#### Objective

§ KK keeps interpreter text inside the guest bootstrap module. `HostBootstrap.Registry` forwards the
credential with two shell programs: `dockerAuthStdinWrapper`'s `mktemp`/`trap`/`cat` wrapper, and
`registryAuthLiftPlan`'s `bash -lc "export HOSTBOOTSTRAP_REGISTRY_AUTH=\"$(cat)\"; exec docker …"`. The
second reaches the container only when the caller's `clExtraArgs` happens to carry
`-e HOSTBOOTSTRAP_REGISTRY_AUTH`, and it consumes the stdin a config-delivering container layer needs. This
sprint makes forwarding a typed operation of the binary.

#### Deliverables

- `HostBootstrap.Registry` carries no shell text; `dockerAuthStdinWrapper` and the provider shell script do
  not exist.
- In a frame where the project binary is established, the provider-frame step of an authenticated lift is
  the binary's own typed operation, lifted through `foldLeaf`. The binary reads the payload from stdin, makes
  it visible as `HOSTBOOTSTRAP_REGISTRY_AUTH` to its Docker child only, and launches the container leaf
  through the one runner.
- A forwarding needed before the binary is established in a frame is a step of the guest bootstrap
  vocabulary, not Registry text.
- The authenticated plan adds `-e HOSTBOOTSTRAP_REGISTRY_AUTH` to the container invocation itself. A
  container layer that takes its config over stdin (`clConfigDelivery = Just _`) has no authenticated plan.
- An in-VM `docker build` or `docker pull` that needs the credential uses the same typed operation.
- `Registry.hs` carries no interpreter token, and the `RegistrySpec` source guard fails if one returns to the
  module.

#### Validation

`RegistrySpec` pins the authenticated plan's exact argv per provider, with no interpreter token, and a source
guard keeps shell text out of `Registry.hs`. The sprint closes when the cases below exist and pass under
`cabal test all` from `core/` and from `demo/`.

#### Remaining Work

- `Registry.hs`: delete `dockerAuthStdinWrapper` and the `bash -lc` script in `registryAuthLiftPlan`, and
  the module header names the typed operation as the `stdin` forwarding channel. `registryAuthLiftPlan` lifts the self binary's credential-forwarding entry with the container's
  `foldLeaf`-rendered Docker argv plus `-e HOSTBOOTSTRAP_REGISTRY_AUTH`, and returns `Nothing` for a
  container layer with `clConfigDelivery = Just _`. Test: `RegistrySpec` exact-argv cases for Incus, Lima,
  and WSL2 name the self binary and contain none of `bash`, `sh`, `-c`, or `-lc`. A container layer with
  `clExtraArgs = []` still yields `-e HOSTBOOTSTRAP_REGISTRY_AUTH` in the Docker argv. A config-delivering
  container layer yields `Nothing`.
- `demo/src/HostBootstrapDemo/Commands.hs`: `buildProjectImage` and `resolvePublishedBaseInVM` forward the
  credential through the typed operation instead of `dockerAuthStdinWrapper`.
- `RegistrySpec`: the anonymous-lift case compares `liftSubcommandWithAuth cfg Nothing` with
  `liftSubcommand` on `inContainer authContainer (inVM (IncusVM "incus-vm" "image") emptyVMStack)`, a
  context that has an authenticated plan. The comparison is of described dispatches, not two tool-resolution
  failures. The no-secret substring checks on functions that never receive the credential are removed; the
  remaining checks are exact golden comparisons.
- `RegistrySpec` source guard: `Registry.hs` contains none of `"bash"`, `"-lc"`, `mktemp`, or `trap`.

### Sprint 21.11: The project container receives the forwarded credential [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Registry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`demo/app/Main.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/registry_credentials.md`

#### Objective

The project container's nested pulls authenticate whenever the outer host holds a Docker Hub login. The
admitted container route, `admittedContainer` in `HostBootstrap.Handoff.Process.Route` (built by the
recursive-lifecycle phase), adds `-e HOSTBOOTSTRAP_REGISTRY_AUTH` with the name only. Docker fills a
name-only `-e` from the launching client's own environment, and no production frame sets the variable:
`liftSubcommandWithAuth`, the only code that exports a value, is called only by `RegistrySpec`. The
in-container `deploy-kind` node-image pull and the in-container `docker run` probes therefore pull
anonymously, and the route names a variable that never carries anything. This sprint owns the credential
policy across that route; the route's other arguments stay the recursive-lifecycle phase's.

#### Deliverables

- The credential the outer host discovers crosses each lifecycle edge down to the project container on a
  channel the edge owns, never in argv and never in Dhall.
- The admitted container launch names `HOSTBOOTSTRAP_REGISTRY_AUTH` only when its frame holds a forwarded
  credential, and then hands the value to the Docker child alone through Sprint 21.10's typed forwarding
  operation. With no credential the launch carries no registry-auth argument.
- The container-frame binary consumes the value once through `withForwardedRegistryAuth`, as every
  ordinary demo command already does on entry.

#### Validation

Route cases pin the admitted container argv with and without a credential, and an end-to-end case reads the
payload back in the container frame's launch environment. The sprint closes when the cases below exist and
pass under `cabal test all` from `core/` and from `demo/`.

#### Remaining Work

- `Handoff/Process/Route.hs`: `admittedContainer` adds `-e HOSTBOOTSTRAP_REGISTRY_AUTH` only for a launch that
  carries a forwarded credential, and that launch supplies the payload to the Docker child through the
  typed forwarding operation. Test: `ProjectPlanSpec` exact-argv cases for the admitted container route. With
  no credential the argv contains no `HOSTBOOTSTRAP_REGISTRY_AUTH`; with one it contains
  `-e HOSTBOOTSTRAP_REGISTRY_AUTH`, the Docker child's environment holds the payload bytes, and no argv element
  contains them. The source-fragment case that lists `"HOSTBOOTSTRAP_REGISTRY_AUTH"` in the route's fixed
  argument list asserts the conditional form instead.
- `Registry.hs` and the lifecycle edge: the host's discovered credential travels with each lifecycle
  crossing to the frame that launches the project container. Test: a `RegistrySpec` case drives a
  `[provider, container]` route from a fixture `DOCKER_CONFIG` and asserts that the container launch's
  Docker child environment holds the payload, and a second case with no host login asserts the launch is
  byte-identical to the anonymous route.

### Sprint 21.12: A route witness names the plan it was settled for [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RegistryPlan.hs`,
`core/hostbootstrap-core/test/RegistryPlanSpec.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`

#### Objective

A `ReadyBlobRoute` holds only the plan revision. Core refuses a zero revision and generates none, and the
worked consumer builds every registry plan at revision `1`, so a replacement plan that keeps the revision
but changes the store or the exposure's runtime identity is indistinguishable to the witness. The
`InvalidRegistryRevision` comment calls the revision "generative", which nothing enforces. This sprint
binds the witness to the plan it was settled for.

#### Deliverables

- `ReadyBlobRoute` carries the settled plan's identity: revision, store authority, delivery, and the
  exposure's relay identity, cluster generation, ownership operation, and host port.
- `readyBlobRouteFor :: RegistryPlan client store lifecycleScope planId clusterId service ->
  ReadyBlobRoute client store lifecycleScope planId clusterId service -> Either RegistryPlanError ()`
  accepts a witness only against the plan it was settled for, and refuses any other with
  `BlobRouteStalePlan` naming the first differing field.
- `InvalidRegistryRevision` documents the rule core enforces, a strictly positive revision; telling
  replacements apart is the witness identity's job, not a caller-generated revision.
- The worked consumer's `pushImageBlob` checks its witness against the plan it pushes through before it
  pushes.

#### Validation

`RegistryPlanSpec` settles a route against one plan and checks it against same-revision replacements. The
sprint closes when the cases below exist and pass under `cabal test all` from `core/` and from `demo/`.

#### Remaining Work

- `RegistryPlan.hs`: extend `ReadyBlobRoute` with the plan identity, add `readyBlobRouteFor` and the refusal
  `BlobRouteStalePlan Text`, and rewrite the `InvalidRegistryRevision` comment to "the plan revision must be
  strictly positive". Test: `RegistryPlanSpec` settles a route against a host-served plan over
  `clusterOnlyEndpoint "object-store.default.svc:9000"` at revision `1`. Checking it against a revision-`1`
  plan over `other-store.default.svc:9000` refuses with `BlobRouteStalePlan` naming the store; checking it
  against a revision-`1` plan built from a second relay process's inspection refuses naming the runtime
  identity; checking it against its own plan returns `Right ()`.
- `demo/src/HostBootstrapDemo/Commands.hs`: `pushImageBlob` takes the plan and calls `readyBlobRouteFor`
  before the push.

### Sprint 21.13: The role phase machine hashes through Digest [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`

#### Objective

`HostBootstrap.Digest` exports the lowercase-hex `sha256Hex`, and the role phase machine derives its role
plan-draft digest and role admission keys with that export rather than with a byte-identical local copy, so a
draft digest recomputed by the signing broker cannot drift from the one the role compares against.

#### Deliverables

- `RoleLifecycle` imports `sha256Hex` from `HostBootstrap.Digest` and defines no SHA-256 helper of its own.
- `rolePlanDraftDigest` and `roleAdmissionKey` keep the bytes `RoleLifecycleSpec` pins.

#### Validation

`RoleLifecycleSpec` passes unchanged inside `cabal test all --ghc-options=-Werror` from `core/`, and the host
static gate (§ JJ) passes.

#### Remaining Work

- Delete `sha256Hex` from `core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs` and import it from
  `HostBootstrap.Digest`.

### Sprint 21.14: The registry and network Haddocks name the generic object store [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/RegistryPlan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Network.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/network_reachability.md`

#### Objective

Phase 12 names the in-cluster S3 store by its role (`ObjectStoreResource`, family key
`project:deploy-object-store`). The `RegistryPlan` and `Network` module Haddocks illustrate a pod-reachable
store address with the product-named `minio.default.svc:9000`; their example address names the same role.

#### Deliverables

- The `RegistryPlan.hs` and `Network.hs` module Haddocks use the generic address
  `object-store.default.svc:9000`.
- No code, export, or durable byte changes.

#### Validation

`cabal test all` from `core/` passes, and no production source under `core/hostbootstrap-core/src/` contains
the text `minio`.

#### Remaining Work

- Reword the `minio.default.svc:9000` examples in the `RegistryPlan.hs` and `Network.hs` module Haddocks to
  `object-store.default.svc:9000`.

## Remaining Work

- Sprint 21.1: derive `reachableFrom` from `Reachability`, correct its Haddock, parse endpoint authorities
  strictly, and pin the scheme refusal and the exact retained runtime identity.
- Sprint 21.2: render the store address from the plan, require `3xx` on the redirect path, and make the
  `RawRegistryPlan`/`ForgeReadyBlobRoute` fixtures fail on constructor privacy.
- Sprint 21.3: delete the unused phase tags and the declared-row lease accessor, classify an asynchronous
  shutdown in Serve, force callback results fully, harden resource and lease names, and add the missing
  engine cases.
- Sprint 21.6: route every consume and reopen through the request-indexed entries and fence reopening of a
  Consumed admission with a durable `opened` transition.
- Sprint 21.7: index `ResolvedExposure` by the inspecting frame's scope and type the runtime identity
  coordinates.
- Sprint 21.8: make `BlobRouteObservation` opaque and mint it from a fresh inspection and the probe's answer.
- Sprint 21.9: select Docker Hub entries exactly, test the credential lifecycle end to end, and state the
  `Registry` Haddocks' guarantee without overclaiming.
- Sprint 21.10: replace Registry's `bash -lc` and `mktemp`/`trap` forwarding with a typed binary operation
  held by a `RegistrySpec` source guard.
- Sprint 21.11: deliver the host's credential to the project container's Docker child, and name
  `HOSTBOOTSTRAP_REGISTRY_AUTH` on the admitted container route only when a value is forwarded.
- Sprint 21.12: bind `ReadyBlobRoute` to the identity of the plan it was settled for, and state the revision
  rule core enforces.
- Sprint 21.13: `RoleLifecycle` takes `sha256Hex` from `HostBootstrap.Digest`.
- Sprint 21.14: the `RegistryPlan` and `Network` Haddocks use the generic `object-store.default.svc:9000`
  address.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/network_reachability.md` — scope-indexed endpoints and proof-gated delivery.
- `documents/architecture/composition_methodology.md` — the role phase machine.

**Engineering docs to create/update:**
- `documents/engineering/composition_patterns.md` — using the role machine.

**Cross-references to add:**
- `development_plan_standards.md` § GG and § AA name this phase as the owner of these algebras.
