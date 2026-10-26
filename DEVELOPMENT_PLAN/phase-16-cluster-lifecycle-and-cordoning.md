# Phase 16 — Cluster lifecycle, budgets, and cordoning

**Status**: Active
**Depends on**: Phase 12 (the generic plan-indexed budget boundary), Phase 14 (the four ownership clauses
and the ownership seam), Phase 15 (host providers and the self-reference lift)
**Substrates**: linux-cpu
**Gate**: `cd core && cabal test all` on the gate host that runs it (§ C;
cross-family confirmation belongs to the
[host-portability acceptance phase](phase-29-host-portability-acceptance.md)), composed with
the bare core binary's `hostbootstrap test run cluster-live` on linux-cpu
**Gate kind**: deferred
**Gate evidence**: 2026-09-13 ; x86_64 Ubuntu 24.04.4 LTS, Linux 7.0.0-28-generic, Docker 29.7.1,
Kind 0.32.0, kubectl 1.37.0 against a Kubernetes 1.36.1 server, GHC 9.12.4, Cabal 3.16.1.0 ;
`cabal test all --ghc-options=-Werror --test-show-details=direct --test-options=--hide-successes` from
`core/`, composed with the bare core binary `hostbootstrap test run cluster-live` ; pass ;
covers d65409e63b895e9acfc5249a5be7836ff2769b84d91273ae9ba4d8f619659cd5
**Evidence covers**: `core/hostbootstrap-core/src/HostBootstrap/Cluster` `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs` `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima` `core/hostbootstrap-core/internal/colima-backend` `core/hostbootstrap-core/internal/cluster-backend` `core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs` `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs` `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`

> **Purpose**: Bring a cluster up inside a declared resource budget, cordon what the project may consume, and
> keep the durable host root outside everything the lifecycle may delete.

## Phase Objective

A cluster is the innermost frame most deployments end in. Three things must be true of it: it fits inside a
budget the project declared, its compute slice is applied at the cluster while storage is enforced at a
supported provider wall or retained as an explicit unsupported runtime decision, and its teardown cannot
reach the durable state the project exists to keep. This phase builds those mechanics into the exact cluster
consumer and the direct-Colima library boundary. The provider-neutral capacity/sizing/cordon foundation
comes from Phase 6, the generic plan-indexed budget algebra comes from Phase 12, and the worked demo later
supplies its concrete workload, overhead, partition, and slice projection.

Three boundaries are worth naming because they sit close to this phase's own. Recursive and demo call-site
adoption of the cluster consumers belongs to the
[recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) and the
[worked-demo phase](phase-24-worked-demo.md), not here. The direct-Colima adapter has no such adoption: it
is a library boundary that no recursive Production route and no demo call site consumes, and no phase
schedules one, because the worked demo's Apple Silicon path provisions through Lima. And the direct-Colima
driver's *static* coverage closes on any POSIX gate host once its classification is pure, so no sprint here
waits on Apple hardware; only the live confirmation does, and the
[Apple-Silicon-substrate phase](phase-26-apple-silicon-substrate.md) lists it among what it confirms.

## Sprints

### Sprint 16.1: Closed cluster execution backend [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

Make the executor that can mint cluster backend facts a closed, bounded capability.

#### Deliverables

- `StrongClusterBackend` lives in `HostBootstrap.Cluster.Backend.Internal`, a hidden module (`other-modules`)
  of the main library built from `internal/cluster-backend`. It retains the typed `HostConfig`, the closed
  driver, the plan-owned config bytes and digest, the ownership identity, the plan-owned kubeconfig path, and
  the readiness-observation counter, and carries no executor or interpreter.
- `discoverStrongClusterBackend` takes the typed `HostConfig` and the plan-owned config package and admits the
  backend only when the driver's tools, `Docker`, `Kubectl`, and `Helm` are resolved in it; it probes nothing
  and a missing tool is `Unsupported` with no capability minted. An nvkind package never falls back to Kind
  for creation; it requires `Nvkind` and also `Kind`, which lists, reads back, and deletes its cluster (the
  `Kind` requirement for nvkind is Sprint 16.46's owed work).
- Every effect the backend performs is a described `HostCommand` run by the one interpreter over the
  configuration's resolved tools; no caller-supplied executor, tool path, or command string reaches it. The
  per-command deadline and process-group reaping belong to the bounded cluster interpreter that Sprint 16.40
  owes; `interpretHostCommand` runs each command untimed today.
- Public call-result constructors remain opaque and nominal. Sprint 16.46 owns the absence of an embedded
  interpreter program and of an injected executor.

#### Validation

`ClusterBackendSpec` covers admission with every tool resolved, refusal of a configuration missing
one tool, nvkind discovery that does not fall back to Kind, refusal of a package whose driver differs from the
discovered one (the assertions that admission runs no probe and that the refusal issues no command are
Sprint 16.46's owed cases), and the source guard that the hidden backend module retains capability data and no injected
executor. Compile-fail fixtures `ImportClusterBackendInternal.hs`, `ForgeStrongClusterBackend.hs`, and
`OpenClusterBackendExecutor.hs` reject the hidden module and backend construction from a downstream component.

#### Remaining Work

None.

### Sprint 16.1a: Semantic cluster exposure intent [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Make a stable cluster-internal TCP target the complete pre-effect exposure declaration.

#### Deliverables

- A plan names each exposed service and its stable cluster-internal target; it never contains a selected host
  port.
- Opaque `ExposureIntent` (declared in `HostBootstrap.Cluster.Lifecycle` and re-exported by
  `HostBootstrap.Cluster.Backend`) retains a bounded service identity and cluster target, fixes TCP as the only
  admitted protocol, and refuses empty, malformed, or out-of-range terms before backend entry.
  `mkPlanExposureIntent` applies the same service bound the recorded-exposure readback applies
  (`validExposureService`: non-empty, at most 128 characters, no NUL, `/`, `\`, `:`, CR, LF, or tab), so
  every intent it admits can later be reopened from its managed record.

#### Validation

The sprint closes when `ClusterBackendSpec` contains and passes, beside the existing exact-retention and
port-0/port-65536 cases: a 129-character service identity refused with `Left (Failure _)`; a 128-character
service admitted; a service containing NUL refused; each separator character in the service refused; and an
empty target host and a target host containing a space refused. Source and compile-fail guards prove the
public preparation surface contains no caller-selected host port. The phase gate runs them.

#### Remaining Work

- `mkPlanExposureIntent` in `Cluster/Lifecycle.hs` admits a service identity of any length and permits NUL,
  while `observeRecordedClusterExposure` and `validManagedExposureRecord` in `Cluster/Backend.hs` refuse a
  service over 128 characters or containing NUL. Move the service predicate into `Cluster/Lifecycle.hs` as
  the one definition, call it from `mkPlanExposureIntent`, and have `Cluster/Backend.hs` use it in place of
  its local `validExposureService`.
- Add the malformed-service and malformed-target cases listed under Validation to `ClusterBackendSpec`
  (through `mkExposureIntent`), each asserting `Left (Failure _)`.

### Sprint 16.1b: Plan-bound prepared exposure [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Bind semantic exposure intent to the exact applied cluster cordon and immutable relay image.

#### Deliverables

- Opaque `PreparedClusterExposure` retains the exact plan resource, cluster name and identity, generation,
  ownership root, node set, immutable `repository@sha256` image, and non-empty unique semantic service set.
- Preparation accepts only the already-applied cluster cordon and refuses a mutable image reference, duplicate
  service, empty set, or over-broad set before effects.

#### Validation

The sprint closes when `ClusterBackendSpec` contains and passes, beside the existing admissions of a valid
`repository@sha256` image with one and two distinct services, one refusal case per guard of
`withPreparedClusterExposure`: a mutable `repository:tag` image, an empty intent list, two intents with the
same service, and `maxExposureCount + 1` (129) distinct intents, each asserting `Left (Failure _)` before any prepared
exposure exists; and the images `@sha256:<64 hex>` and `--label=x@sha256:<64 hex>`, each refused with
`DoNotRetry` before any exposure record is published. The complete host-static gate checks the nominal
cluster indices under `-Werror`.

#### Remaining Work

- Add the four refusal cases listed under Validation to `ClusterBackendSpec`, each calling
  `withPreparedClusterExposure` on the already-applied fixture cordon that the existing runtime-exposure
  cases use. Every existing call passes a valid image and a valid non-empty unique set, so no guard of the
  function is exercised today.
- `immutableImage` (`Cluster/Backend.hs`) takes the prefix of `Text.breakOnEnd "@sha256:"`, which still
  contains the separator, so `@sha256:<hex>` with no repository is admitted, and a reference starting with `-`
  reaches `docker container run` as an option. Require a non-empty repository before `@sha256:` that does not
  start with `-` and matches Docker's reference grammar (lowercase path components separated by `/`, an
  optional registry host with port). Add the two image refusal cases listed under Validation.

### Sprint 16.1c: Opaque runtime-resolved exposure [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeResolvedExposure.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Make exact authenticated runtime inspection the only producer of a local endpoint authority.

#### Deliverables

- Authenticated runtime inspection of the exact relay identity is the only producer of
  `ResolvedExposure scope planId clusterId service`. It binds service identity, loopback address, protocol,
  selected host port, internal target, relay/container identity, cluster generation, and ownership operation.
  A rendered request, free-port probe, process output, or caller-supplied number cannot mint it. The constructor
  is private and service lookup opens it only through a rank-2 continuation.
- `ResolvedExposure` and `PreparedClusterExposure` declare nominal roles for every index, so `coerce` cannot
  move a resolved or prepared exposure to another scope, plan, cluster, frame, or service.

#### Validation

Focused cases cover exact lookup and cross-service absence. Compile-fail coverage rejects raw construction and
the removed caller-selected preparation surface. The sprint closes when a compile-fail fixture
`CoerceResolvedExposureRoles.hs`, registered in `CompileFailSpec`, coerces a `ResolvedExposure` across each
of its four indices and a `PreparedClusterExposure` across each of its four indices, and every coercion is
rejected, under `cd core && cabal test all`.

#### Remaining Work

- `ResolvedExposure scope planId clusterId service` and `PreparedClusterExposure scope planId clusterId
  clusterFrame` (`Cluster/Backend.hs`) carry no role annotation, so their phantom indices are inferred phantom
  and `Data.Coerce.coerce` re-indexes them (`CoerceExposureAuthorityRoles.hs` covers only
  `HostBootstrap.Network.Exposure`). Enable `RoleAnnotations` and declare
  `type role ResolvedExposure nominal nominal nominal nominal` and
  `type role PreparedClusterExposure nominal nominal nominal nominal`; add the fixture listed under
  Validation.

### Sprint 16.1d: Binary-owned bounded relay process [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Exposure/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`, `core/hostbootstrap-core/hostbootstrap-core.cabal`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Give every derived project binary one private multi-listener TCP relay entry with no shell or ambient proxy.
The relay's process exit is not its cleanup: its sockets and threads are released on every path while the
process still runs.

#### Deliverables

- The hidden marker is classified before public command parsing and is absent from the command tree.
- The relay opens one listener per declared target and, per accepted connection, copies bytes in both
  directions as transparent TCP: a clean EOF in one direction half-closes the other socket's send side
  (`ShutdownSend`) and the opposite direction keeps flowing; the connection is torn down only when both
  directions have ended, or at once when either direction ends with an exception.
- A per-connection `accept` failure does not stop the relay. `ECONNABORTED` and `EINTR` are retried at once,
  `EMFILE` and `ENFILE` after a short back-off; only an error meaning the listener socket itself is invalid
  ends that listener and, through it, the relay.
- Listener acquisition, the wait for a stopped listener, and every forked listener and connection thread are
  bracketed: a later bind failure closes the listeners already opened, and an asynchronous exception delivered
  to the relay closes every listener and connection socket and kills every thread it forked.
- The implementation uses the already-warmed Haskell `network` dependency and introduces no executable selector,
  shell, Python program, or caller-supplied command.

#### Validation

The sprint closes when `ExposureRelaySpec` in the core test-suite contains and passes these cases, run in-process
against loopback sockets the test opens: a client that sends a request and then half-closes its write side
receives the complete response an upstream sends only after reading EOF; the accept-failure classifier answers
retry for `ECONNABORTED`, `EINTR`, `EMFILE`, and `ENFILE` and stop for `EBADF` and `EINVAL`; a relay whose
second listener port is already bound fails and leaves the first port bindable again; and a relay thread
killed while a connection is open leaves every listener port bindable again and the connected client
observing EOF. Compile-fail coverage still rejects downstream import of the entry
(`ImportClusterExposureInternal.hs`), and shared-surface guards freeze only their own rows. The phase gate runs
them on every host.

#### Remaining Work

- `relayConnection` in `internal/cluster-backend/HostBootstrap/Cluster/Exposure/Internal.hs` takes the first
  `completed` signal and then shuts down both sockets and kills both copy threads, so a client that
  half-closes after writing loses the upstream response. Take `completed` once per direction, tear down
  early only on a `Left` (exception) outcome, and add the half-close case.
- `acceptForever` lets any `IOException` from `accept` end the listener thread, which makes `runRelay` kill
  every listener and exit. Add a pure `classifyAcceptFailure :: IOException -> AcceptDisposition` (retry,
  retry after back-off, stop) keyed on the errno, loop on retry inside `acceptForever`, and add the
  classifier cases.
- `runRelay` opens listeners with `mapM` outside a bracket and waits on `takeMVar` with no `finally`, and
  `acceptForever` does not track the connection threads it forks. Acquire the listeners under one bracket,
  put the kill-and-close block in `finally`, track each listener's connection threads and kill them when the
  listener ends, and add the bind-failure and asynchronous-kill cases.
- The relay entry sits in the main library's `other-modules`, which the test-suite cannot import. Move
  `HostBootstrap.Cluster.Exposure.Internal` into a `visibility: private` sublibrary (as `ownership-internal`
  is) that the main library and the core test-suite depend on, export `classifyAcceptFailure` and an
  in-process relay runner from it, keep `ImportClusterExposureInternal.hs` rejecting downstream import, and
  register the new `core/hostbootstrap-core/test/ExposureRelaySpec.hs` that holds the relay cases.

### Sprint 16.1e: Owned relay reconcile, recovery, and release [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`, `core/hostbootstrap-core/test/FakeCluster.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`, `documents/architecture/durable_state.md`

#### Objective

Make the runtime bind, exact inspection, recovery, and release one clause-holding cluster-adjacent operation.

#### Deliverables

- The backend creates one identity-bound relay on the cluster container network and asks the runtime to publish
  every listener on `127.0.0.1` without a host number; selection and binding are one runtime operation.
- The relay and every selected mapping are one owned cluster-adjacent resource. Recovery re-inspects the exact
  identity and mapping set; replacement, wildcard binding, missing/additional mapping, or changed target is a
  conflict. Cluster release removes the relay by identity before the cluster and retains the ownership record
  until both absences are observed.
- The protected record is published before relay creation, binds a fresh 256-bit operation nonce and immutable
  specification digest, and is replaced with the inspected identity/mapping set by compare-and-swap.
- Cluster cleanup refuses while the exposure record exists, enforcing relay-before-cluster release under the
  same exclusive store entry.
- A stopped owned relay stays releasable and recoverable. Release authenticates it by name, `.Id`, and labels
  and accepts an empty port map when the relay is not running (Docker reports `Ports {}` for a stopped
  container); reconcile removes a stopped owned relay by identity and recreates it.
- Port inspection ignores the `null` entries Docker emits for an image's `EXPOSE` ports and requires the
  non-null set to equal the expected listeners; relay creation tolerates an image pull's progress on standard
  error.
- A replaced relay or a replaced node is a `Conflict` (`DoNotRetry`) naming what it found, as the cordon,
  cleanup, and readiness calls report it; a refused relay removal retains the relay and its record.

#### Validation

`ClusterBackendSpec` drives a real second-process container-runtime fixture through creation, exact inspection,
recovery, wildcard/mapping/replacement conflict, release ordering, and identity-conditional release. The
sprint closes when the cases in Remaining Work exist and pass under `cd core && cabal test all`.

#### Remaining Work

- Stopped relay: `releaseClusterExposureCall` and `releaseRecordedClusterExposure` (`Cluster/Backend.hs`)
  require the live port map to equal the record, so a relay Docker reports as exited (no `--restart` policy,
  `Ports {}`) is never released and blocks `project down`/`up`. Authenticate release by name, `.Id`, and the
  `io.hostbootstrap.*` labels, accept an empty map when `.State.Running` is false, and have reconcile remove a
  stopped owned relay by identity and recreate it. `FakeCluster` gains a stopped-relay arm (empty mappings,
  not running). `ClusterBackendSpec` cases: release of a stopped owned relay removes it and forgets the record;
  reconcile over a stopped owned relay recreates it with fresh mappings.
- `null` port entries: `parsePortBindings` and `parseRecordedPortBindings` refuse the `null`-valued
  keys Docker emits for image `EXPOSE` ports. Ignore `null`-valued keys and require the non-null key set to
  equal the expected listeners. Case: a `FakeCluster` relay whose inspection carries an extra `"8080/tcp":
  null` resolves and is recorded.
- Pull progress: `createRelay` runs through `successfulCommand`, which refuses any standard-error
  output, so a first run that pulls the image fails. Pass `--quiet` to `docker container run` (or pull with
  `docker image pull --quiet` and run with `--pull never`). Case: a `FakeCluster` arm whose `container run`
  writes pull progress to standard error and succeeds yields a resolved exposure.
- Tampered record: `ClusterBackendSpec` cases write the exposure record as invalid UTF-8, as the
  canonical text plus trailing whitespace, and as a re-spaced `show`; each makes recorded observation and
  release return the not-UTF-8 or not-canonical conflict, and `FakeCluster.recordedClusterMutations` shows no
  `relay-delete`.
- Relay target model: `FakeRelay` stores the parsed (service, listener, target host, target
  port) tuples, and `parseRelayRun` requires `--network kind` before the image and a `/tcp` suffix on every
  `--publish`. Case: through `FakeCluster.readRelays`, the host port resolved for `web` belongs to the
  listener whose recorded target is (`<cluster>-control-plane`, 30080), and `registry` to 30500.
- Refused removal: a one-shot `FakeCluster.armRelayRemovalRefusal` makes `container rm --force` exit
  with status 1. Cases: `releaseClusterExposureCall` and `releaseRecordedClusterExposure` each return `Left`, the relay
  stays in `readRelays`, and the exposure record stays.
- Fault disposition: `runClusterExposureCall` and `releaseClusterExposureCall` map `replacedIdentity`
  and `standsUnderNoRecord` faults to `Conflict` (`DoNotRetry`). Case: a replaced control-plane node makes
  the exposure call return that `Conflict`.
- Exact refusals: the cases "recorded observation refuses a replacement relay identity" and "reverse
  refuses a replacement relay and retains the exposure record" assert the `Conflict` whose cause contains
  "another relay stands at the recorded name" with `DoNotRetry`, not any `Left`.
- Fixture identities: `FakeCluster.createRelay` mints `replicate 56 'e' <> padNumber n` from a
  monotonic counter file (as `next-host-port` is), not from `length relays + 1`, so a relay created after a
  removal never reuses a live relay's identity.

### Sprint 16.1f: Concurrent runtime allocation acceptance [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/engineering/testing.md`

#### Objective

Make automatic host-port allocation and exact cleanup part of the phase's existing live harness case.

#### Deliverables

- After the fresh Kind cluster is ready, `cluster-live` starts two isolated containers concurrently against
  the same immutable node image and asks Docker to publish the same container listener on `127.0.0.1` with no
  host-side number.
- The case inspects both immutable container identities, requires two distinct numeric loopback mappings, and
  removes both identities in a bracket on every success or failure path.
- Post-cleanup inspection proves both names absent before the ordinary cluster reverse and durable-root
  sentinel assertions may pass.

#### Validation

The warning-clean core gate builds the case on every host. The phase-level composed linux-cpu gate executes the
two concurrent allocations against the live Docker runtime and proves exact end-state absence.

#### Remaining Work

None.

### Sprint 16.2: Durable cluster ownership namespace [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

Establish clauses 1 and 2 of locked-origin ownership for the cluster state namespace.

#### Deliverables

- The cluster's durable namespace is the [protected store](phase-4-protected-store.md) opened at the plan's
  own state directory (`<durable root>/cluster/<driver>/state`). Clause 1 is that store's exclusive entry and
  clause 2 its compare-and-swap; `withClusterTransaction` opens the store once per transaction and holds one
  entry across the whole of it, so no cluster operation holds a different notion of its exclusive entry.
- The cluster's own record lives under the cluster's declared name and binds this run's ownership claim and,
  once created, the control-plane container identity; every other declared node carries its own record beside
  it (Sprint 16.44).
- Every record is published over an explicit absence before the creating command runs, and is bound from the
  runtime's answer afterwards. A record standing under another claim, or a cluster standing under no record of
  this project's, is a structured refusal rather than an adoption or absence.
- Traversal, durable publication, readback, and the store's own lock are the protected store's guarantees
  and are tested by its owning phase; this sprint adds none of its own.

#### Validation

`ClusterBackendSpec` covers that the durable record lives under the plan's own state directory and that a
cluster no record of this project's claims is foreign and is not touched. `ClusterOwnershipSpec` covers
publication before the creating command, recovery without a second create after a client that dies after its
create, a durable publication failure that binds nothing, and refusal of an unclaimed cluster. `AuthoritySpec`
covers a record round-tripping through one exclusive entry.

#### Remaining Work

None.

### Sprint 16.3: Identity-bound cluster reconcile and status [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/readiness.md`

#### Objective

Run creation and observation against the plan-owned config and immutable backend identities.

#### Deliverables

- Both the Production and the Harness profile bind a plan-owned rendered config at
  `<durable root>/cluster/<driver>/config.yaml`, and creation passes that path to the driver as `--config`.
  The binding of the bytes at that path to the prepared digest is Sprint 16.7's.
- Creation uses a private isolated kubeconfig rather than ambient `$HOME/.kube/config`: the creating client
  stages locally and the exact credential is published at the plan-owned durable kubeconfig path inside the
  same transaction, before any node identity is bound.
- Driver-list, runtime identity, and Kubernetes reports are classified strictly: a command that produced no
  child, a non-zero exit, a success that wrote stderr, a duplicate name, and malformed output are each a
  refusal; failure never collapses into absence.
- The created control-plane container ID is raw backend identity. Each declared node's own record binds its
  container ID, and no caller-provided journal generation substitutes for it.
- The status route is read-only, uses the closed backend, and returns present, absent, or a structured probe
  failure without minting mutation authority.

#### Validation

`ClusterBackendSpec` covers a Harness package retaining its isolated driver configuration, the exact package
projecting absolute backend paths, local staging with the exact credential landing in durable state, first
creation, the identity bound being the one the runtime answered for the control plane, an exact repeat
creating nothing more, the status classification being total over what a driver can say, a command that
produced no child, non-zero exit and noisy success refusals, and the read-only status path.
`ClusterOwnershipSpec` covers per-node binding and a worker replaced under an owned cluster.

#### Remaining Work

None.

### Sprint 16.4: Identity-conditional raw cluster operations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/engineering/applied_cordon.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Supply clause-3/4 cordon, readiness, and release operations over the retained cluster identity.

#### Deliverables

- Cordon re-enters the exact lock/record namespace, revalidates the retained control-plane and complete node
  IDs, and addresses Docker updates by immutable container ID rather than a reusable node name.
- Readiness revalidates that same identity, the Kubernetes API, and exactly the declared node set under finite
  bounds; an added, missing, unready, or replaced node cannot report Ready.
- Cleanup accepts only the exact retained record/state/lock identity, conditionally deletes the matching
  cluster, and independently proves every retained node container absent before releasing origin state.
- A replacement, partial deletion, driver-list failure, runtime-probe failure, or durable-unlink failure
  preserves the origin and returns structured conflict/failure.
- All raw reports are strict, plan-independent backend facts. They cannot be constructed or settled as exact
  plan authority by public callers.

#### Validation

`ClusterOwnershipSpec` (the Sprint 16.45 drivers) covers identity-matched cordon, readiness, and release; a
node replaced while the readiness probe ran, while the wall was applied, and during the removal; node-ID
targeting of the wall; exact readiness membership (a node that has not joined, a control plane that has not
come up, an undeclared node set); a second release finding nothing to do; a record published over a create
that never happened; and a created-and-never-bound cluster authorizing no removal. `ClusterBackendSpec` covers
strict report framing. Serialization between operations is the protected store's exclusive entry, which every
transaction takes through `withClusterTransaction`; it is the protected store's own guarantee and this sprint
claims no separate case for it.

#### Remaining Work

None.

### Sprint 16.5: Exact plan-owned cluster consumer [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/engineering/resource_budgeting.md`

#### Objective

Join the exact cluster package projected by one admitted `ProjectPlan`.

#### Deliverables

- `PlanOwnedCluster` has two constructors. `withPlanOwnedCluster` builds the plan-side one from one
  `ProjectPlan`, its matching cluster and provider `PlannedResource`s, the exact retained `DerivedTopology`,
  and the matching cluster `ResourceSlice` from Phase 12, and derives the owner binding from the stable plan
  snapshot digest and the cluster resource key.
- `withExecutionOwnedCluster` builds the execution-side `ExecutionOwnedCluster` from the executing
  `StepExecution`, the cluster and provider `PlannedResource`s, and the cluster `ResourceSlice`, with no
  `ProjectPlan` and no topology. Its checks are different and are these: the executing node's operation key
  and frame are the cluster resource's; the provider's key and frame are among the executing node's
  dependencies; the slice names the cluster resource in that frame. Its profile, project, and root come from
  the execution package, and its owner binding from the execution's plan digest and the cluster resource key.
- Shared nominal indices and term checks reject a foreign resource, topology, edge, frame, or slice. Neither
  constructor accepts a compatibility lifecycle plan, caller profile/root, or independently assembled graph.
- The package derives the Production or generative Harness cluster identity, removable state directory,
  durable root, placement, ownership binding, node names, and optional absolute driver-config path.
- This phase selects and binds an existing config path; it does not render the demo's concrete Kind/nvkind
  YAML or choose its internal Service/NodePort targets. That semantic projection belongs to the worked demo;
  Sprint 16.1 generically owns runtime assignment of the distinct host-side exposure.
- The config binder `withPlanOwnedClusterConfig` derives the closed driver from the joined package's resolved
  plan, as it derives paths and node identities; no caller supplies a driver.

#### Validation

`ClusterReconcileSpec` covers Production and Harness derivation, exact resource/topology/slice agreement, and
term-level mismatch refusal for the plan-side constructor. `CrossPlanClusterConsumer.hs` and
`CompatibilityClusterInputs.hs` reject foreign plan members and the compatibility consumer shape. The
execution-side constructor is reached by the worked demo's forward cluster action. The sprint closes when the
cases in Remaining Work exist and pass under `cd core && cabal test all` and `cd demo && cabal test all`.

#### Remaining Work

- `withPlanOwnedClusterConfig` (`Cluster/Lifecycle.hs`) takes a free `ClusterDriver` argument and derives
  every binder check from it, while its Haddock says the driver is the base package's. Derive the driver from
  `planOwnedClusterResolvedPlan base` and drop the parameter; the demo's call in
  `demo/src/HostBootstrapDemo/ClusterConfig.hs` stops passing one. `ClusterReconcileSpec` case: binding a Kind
  fixture and an nvkind fixture yields packages whose driver equals each plan's own.
- The case "preparation projects the complete exact cluster package" asserts, through
  `withClusterPlanFixtureM`, `owner == stablePlanSnapshotDigest (renderSnapshot plan) <> ":core:deploy-kind"`,
  `stateDirectory == durableRoot </> "cluster" </> "kind" </> "state"`, and the exact cluster name, instead of
  a `"core:deploy-kind"` suffix check.

### Sprint 16.6: Backend-minted Running-provider dependency [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`,
`documents/engineering/cluster_lifecycle.md`

#### Objective

Pair the exact managed Running provider with the fresh reprobe owned by the backend that minted it.

#### Deliverables

- `RunningProviderDependency` has two package-private constructors and two producers, both in
  `HostBootstrap.Substrate.Provider.Reconcile`. `withFreshRunningProviderDependency` builds
  `RunningProviderDependency` from the managed Running handle and reprobe that the strong provider backend's
  binding (`ProviderBackendBinding`) yields, retaining the exact provider origin.
  `withFreshCarriedRunningProviderDependency` builds `RecoveredRunningProviderDependency` for a successor that
  does not hold the parent's backend: its authority is the authenticated parent-carried runtime-dependency
  package, the carried managed handle and receipt rebound to the plan's provider resource and validated, and a
  nonce-bound package probe whose generation must equal the carried handle's. Its reprobe re-invokes that
  package probe under a fresh sequenced nonce. The carried producer's sequencing and recovery contract is
  the worked demo's Sprint 24.10.
- Public consumers can neither supply a `DependencyProbe` nor recover the generic managed provider handle.
- A Provisioned, Stopped, foreign-plan, or role-coerced provider cannot inhabit the dependency package.
- Cluster preparation consumes this package and reruns its real probe instead of trusting a retained
  observation.

#### Validation

`ClusterReconcileSpec` covers the provider probe running internally before preparation is offered, and
`ProviderBackendSpec` covers `withFreshRunningProviderDependency`. The carried producer's success and refusal
cases are Sprint 24.10's. `CallerForgedClusterProbe.hs`,
`ProvisionedProviderClusterDependency.hs`, `ForgeClusterAuthorities.hs`, and
`CoerceClusterAuthorityRoles.hs` pin construction, phase, and nominal-role boundaries.

#### Remaining Work

None.

### Sprint 16.7: Prepared cluster reconcile transaction [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/engineering/cluster_lifecycle.md`

#### Objective

Prepare one exact cluster reconcile call only after its plan package, provider dependency, and journal gate
agree.

#### Deliverables

- `PreparedClusterReconcile` retains the complete `PlanOwnedCluster`, exact observed cluster handle, prepared
  operation, preconditions, operation digest, attempt, and journal version.
- Preparation consumes `RunningProviderDependency` and builds the dependency precondition internally; there
  is no caller-built snapshot, probe, digest, frame, profile, or root.
- Both profiles bind the plan-owned rendered config: `withPlanOwnedClusterConfig` admits the in-memory bytes
  only with their SHA-256, at most 1 MiB, with no host port or host publication, at the plan-derived path, and
  preparation records that path and digest with the call. The backend refuses a package whose bytes or digest
  differ from the ones it was discovered with.
- The creating command reads exactly the prepared bytes. Inside the same exclusive entry, immediately before
  `kind create cluster`, the backend writes the prepared bytes into the creating command's private staging
  directory (beside the staged kubeconfig), re-reads the staged file and compares its SHA-256 with the
  prepared digest, refuses on mismatch with no create issued, and passes the staged path as `--config`. The
  file a consumer wrote at the plan-derived path is never what the driver reads, so replacing, removing, or
  symlinking it between preparation and creation cannot change the created cluster.

#### Validation

The sprint closes when these cases exist and pass. `ClusterReconcileSpec`: exact Production preparation binds
the plan-derived config digest; a Harness plan retains its run key and exact isolated config; the provider
probe runs internally before preparation is offered; and operation/precondition lineage is stable.
`ClusterBackendSpec`: after preparation the plan-derived `config.yaml` is overwritten with different bytes,
and in a second case removed, and in each the fixture's recorded create receives a `--config` file whose
bytes equal the prepared bytes; and an unchanged package creates the cluster from the prepared bytes. The
binder's refusals are value cases on `withPlanOwnedClusterConfig`, one perturbed argument each, as Remaining
Work lists. Public constructor and compatibility compile-fail fixtures remain registered. The
phase gate runs them.

#### Remaining Work

- `PreparedClusterConfig` in `Cluster/Reconcile.hs` holds only the plan-derived path and the digest of the
  in-memory rendering, and nothing in `Cluster/` reads the file before `kind create --config` reads it:
  `validateReconcileBinding` in `Cluster/Backend.hs` compares two in-memory projections of one package and
  `runCreateCommand` in `Cluster/Ownership.hs` passes the consumer-written path. Change
  `OwnedCluster.ownedClusterConfig` to carry the prepared bytes and digest (from `StrongClusterBackend`),
  have `runCreateCommand` stage, re-read, and digest-check them inside its private staging directory and pass
  the staged path, and remove the staged file on every exit as it does the kubeconfig.
- Rewrite the Haddock on `PreparedClusterConfig` ("exact bytes observed at preparation ... revalidates both
  under the ownership lock") to state what it holds and where the bytes are bound.
- Teach `FakeCluster` to record the bytes of the file named by `--config` at each `create`, and add the
  overwritten-file and removed-file cases listed under Validation to `ClusterBackendSpec`.
- Replace the `ClusterReconcileSpec` text scan "the config binder is closed over both drivers and every
  independent mismatch", which reads `Lifecycle.hs` through a cwd-relative `readFile`, with value cases on
  `withPlanOwnedClusterConfig`, perturbing one argument per case: wrong digest, wrong state path, wrong config
  path, bytes containing `hostPort:` or `extraPortMappings:`, an empty and a duplicate intent list, the other
  driver's node mappings, and an empty and a duplicate workload. Each asserts
  `Left (ClusterPackageMismatch "<exact message>")`, and the unperturbed call is `Right`.
- The case "Production preparation binds the exact plan-derived config digest" checks only a path suffix and
  `Text.length digest == 64`. Assert `digest == childConfigDigest (preparedClusterConfigBytes prepared)` and
  `path == preparedClusterDurableRoot prepared </> "cluster" </> "kind" </> "config.yaml"`.

### Sprint 16.8: Identity-bound cluster settlement [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Settle raw cluster facts into managed authority without confusing journal generation with backend identity.

#### Deliverables

- `ManagedClusterHandle` retains the exact resource handle, ownership receipt, and immutable backend identity;
  the journal generation remains the separate version minted by reconciliation.
- `ClusterReconcileSettlement` exposes managed authority only through its owned branch and retains a foreign
  result without manufacturing a handle or receipt.
- Created and healthy observations settle only against the exact prepared call. Unhealthy, failed, and
  replacement observations remain typed refusal or failure with no adoption or automatic deletion.
- `ClusterUnhealthy` is produced only for this plan's own owned cluster whose bound node containers are not
  all running (Sprint 16.46). Its `Conflict` names it as that — this plan's owned cluster with stopped node
  containers, with its identity — and its remedy is to start the stopped node containers or run
  `project down`, which releases the cluster through its ownership record. It never calls the cluster
  same-named or foreign and never directs out-of-band removal while its records are bound, because removing
  it by hand leaves bound records over an absent cluster (`NodeVanished`), which no later `up` or `down`
  completes.
- Constructors and plan indices remain hidden or nominal across the public library boundary.

#### Validation

`ClusterReconcileSpec` covers created/healthy settlement, backend-identity versus journal-generation
separation, foreign and unhealthy branches, and replacement refusal. The sprint closes when its unhealthy
case ("an unhealthy same-named cluster is a Conflict, never deleted", renamed to describe an owned cluster
with stopped node containers) also asserts that the `Conflict`'s observed text names this plan's owned cluster
and the identity, that its remedy names `project down`, and that neither field contains "same-named" or
"by hand". The separation case reads the retained backend identity and the foreign cases read the observed
container identity, as Remaining Work states. Forge and role-coercion fixtures reject public authority
construction and cross-plan relabelling. The phase gate runs them.

#### Remaining Work

- `settleClusterReconcile` in `Cluster/Reconcile.hs` renders `ClusterUnhealthy` as "an unhealthy same-named
  cluster" with the remedy "resolve or remove the unhealthy cluster by hand; a same-named cluster is never
  auto-deleted". Rewrite the observed text and remedy as the deliverable states, and extend and rename the
  `ClusterReconcileSpec` unhealthy case as Validation states.
- The case "a created backend identity stays separate from the prepared journal generation" compares the
  managed generation with the prepared one and never reads the backend identity. Also assert
  `managedClusterBackendIdentity managed` equals `FakeCluster.fixtureNodeIdentity` of the control-plane node.
- The foreign-cluster cases assert only `foreignIdentity`, which is the plan's resource key
  (`"core:deploy-kind"`). Also assert that `foreignDetail` contains the planted container identity
  (`foreignIdentityFor 0`).

### Sprint 16.9: Applied cluster cordon [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/applied_cordon.md`,
`documents/engineering/cluster_lifecycle.md`

#### Objective

Apply the exact admitted cluster slice only to the exact managed cluster identity.

#### Deliverables

- `PreparedClusterCordon` is derived from the exact prepared package and matching managed cluster; callers
  cannot independently supply the budget, nodes, state path, or ownership identity.
- The backend re-observes every bound node identity under the same exclusive entry before and after applying
  the CPU and memory caps. It also retains the typed bare-Linux/Docker-node unsupported-storage decision;
  storage remains a preflight/provider-wall constraint rather than a `docker update` argument.
- The cluster slice is one envelope for the whole cluster. Each of the N declared node containers receives
  its own share — every dimension floored to `slice div N`, so the shares never sum past the slice — and a
  slice smaller than N in any dimension is refused before any `update` runs. The share is computed by one
  function that both the clause-holding driver (`cordonOwnedCluster`) and the descriptive
  `clusterNodeCordonArgs` call.
- `AppliedClusterCordon` is minted only after exact application. A replaced identity, invalid slice, failed
  driver call, or malformed report yields no applied authority.
- The lower provider-neutral budget and cordon calculations remain Phase 6 concerns; this sprint is their
  exact cluster consumer.

#### Validation

The sprint closes when these cases exist and pass. `ClusterOwnershipSpec`: the wall case ("the wall lands on
every declared node, by its bound identity") asserts each node's limits equal the per-node share of
`declaredBudget` across its two declared nodes rather than the whole budget, and that the shares' CPU and
memory sums do not exceed the budget; a budget whose CPU is smaller than the node count is refused with no
`update` in the mutation log. `ClusterBackendSpec`: a runtime that refuses `update` (non-zero exit) yields
`ClusterCordonFailed` and `settleClusterCordon` returns no `AppliedClusterCordon`; a runtime whose `update`
succeeds but writes stderr yields the same. `LifecycleSpec`: the two share-function refusal cases assert the
exact message, `Left "cluster node cordon: CPU slice is smaller than the node count"` for one CPU across the
two nvkind nodes and `Left "cluster node cordon: the plan declares no nodes"` for an empty topology, rather
than any `Left`. `CordonSpec` covers the argv projection, and `BudgetSpec` ("a kind
node container is Unsupported, never a silent success") covers the typed unsupported-storage branch.
`ClusterReconcileSpec` covers ordering after ownership settlement and replacement conflict. The phase gate runs
them.

#### Remaining Work

- `cordonOwnedCluster` in `Cluster/Ownership.hs` sets `limits = kindNodeCordonLimits budget` once and applies
  it to every bound node, so an N-node cluster (nvkind's control plane plus GPU worker) is capped at N times
  its slice. Compute each node's share with the one share function, refuse a slice smaller than the node count
  before any `update`, and apply the share to each node.
- Rewrite the `ClusterOwnershipSpec` wall case, which asserts `replicate (length held) declaredLimits`, and add
  the too-small-slice case, as Validation states.
- Add an `armUpdateRefusal` and an `armUpdateStderr` switch to `FakeCluster` and the two failing-cordon cases to
  `ClusterBackendSpec`.
- `kindNodeCordonArgs` in `Cluster/Cordon.hs` renders a whole-budget argv for the control plane only and has
  no production caller; only `CordonSpec` reaches it. Delete it and rewrite its `CordonSpec` cases against
  `kindNodeCordonArgsFor` or the share function.
- The `LifecycleSpec` cases "multi-node cordon refuses a CPU slice smaller than its node count" and
  "cordoning rejects an empty declared topology" accept any `Left`. With one CPU across two nodes, deleting the
  `budgetCpu budget < naturalCount` guard still yields a `Left` (the zero per-node share is refused later as a
  non-positive CPU), so the named guard is untested. Replace both `Left _ -> True` checks with `@?=` on the
  exact messages Validation names.

### Sprint 16.10: Identity-bound cluster readiness [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`,
`documents/engineering/cluster_lifecycle.md`

#### Objective

Offer cluster dependency readiness only after the exact cordon is applied and the same cluster is ready.

#### Deliverables

- `ClusterReadiness` has two producers and no public one. `settleClusterReadiness` and
  `withFreshClusterReadiness` settle it from the matching `AppliedClusterCordon` and a fresh read-only backend
  observation. The recovered producer, which reconstructs readiness from a carried managed handle for a
  successor (`withFreshClusterRuntimeDependency` in `Cluster/Backend.hs`, Sprint 24.22), lives in the hidden
  `HostBootstrap.Cluster.Observation.Internal`, is called only by `Cluster.Backend`, and consumes the
  verified runtime-dependency probe response rather than a raw `Word64`.
- Every `ClusterReadiness`'s reprobe re-runs a real observation: the cordon-settled one re-runs the backend
  readiness call, and the recovered one re-invokes the runtime-dependency probe under a fresh sequenced nonce
  and verifies the response, as the carried provider dependency does (Sprint 16.6); neither replays a
  retained version.
- The readiness call re-observes immutable cluster identity, verifies the Kubernetes API, and verifies every
  declared node Ready under finite bounds.
- A same-identity not-ready observation is a legible failure; a different identity is a `Conflict`; a probe
  failure never collapses into absence or readiness.
- The separate status call is read-only and reports present, absent, or structured probe failure without
  acquiring mutation authority.

#### Validation

`ClusterReconcileSpec` covers readiness evidence being unavailable until the managed generation is ready,
same-identity not-ready retry versus replacement conflict, readiness dependency probes rerunning the real
backend, and the lexical readiness opener entering only after its own fresh observation; `ClusterOwnershipSpec`
covers API/all-node readiness. The sprint closes when, in addition, a compile-fail fixture
`ImportRecoveredClusterReadiness.hs` that imports `withRecoveredClusterReadiness` from
`HostBootstrap.Cluster.Reconcile` is registered in `CompileFailSpec` and rejected with "does not export", and
a `ClusterBackendSpec` case shows that reprobing recovered readiness twice issues two runtime-dependency probe
requests with distinct nonces, and that a refused second probe yields `Left` rather than a version. The phase
gate runs them.

#### Remaining Work

- `withRecoveredClusterReadiness` is exported from the exposed `HostBootstrap.Cluster.Reconcile` and mints
  `ClusterReadiness` for any caller-chosen phase from any managed cluster `ResourceHandle` (reachable through
  the public `withCarriedManagedResourceOfKind`) and any positive `Word64`, with no `AppliedClusterCordon` and
  no observation. Move it and the `RecoveredClusterReadiness` construction into
  `HostBootstrap.Cluster.Observation.Internal`, remove it from `Cluster.Reconcile`'s export list, have it take
  the verified probe response, and add the `ImportRecoveredClusterReadiness.hs` fixture.
- Its reprobe returns the caller's number once and then refuses, while `reprobeClusterReadiness`'s Haddock
  says it reruns the backend-bound probe. Make the recovered reprobe re-invoke the runtime-dependency probe
  under a fresh sequenced nonce, and add the two-reprobe `ClusterBackendSpec` case.

### Sprint 16.11: Conditional cluster cleanup [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/durable_state.md`

#### Objective

Delete only the exact managed cluster whose immutable backend identity still matches its origin.

#### Deliverables

- `releaseRetainedCluster` in `Cluster/Backend.hs` is the one cluster cleanup. Every root `down`/`destroy`,
  failed-`up` cleanup, and child reverse reaches it, because a retained reverse holds the canonical cluster
  plan but not the forward action's lexical managed handle; the ownership store under the plan's state
  directory is the authority. Its body reads the typed `HostConfig` and a retained-cluster projection from
  `Cluster/Lifecycle.hs` carrying the cluster name, the declared node names, the state directory, and the
  kubeconfig path, built once from the `ClusterPlan` at entry, and reads no durable root. Its exported
  signature taking that projection in place of the `ClusterPlan` is the worked-demo phase's, because its
  callers include `Command/Child/Reverse.hs`.
- Inside one protected entry it refuses while the cluster's exposure record exists, re-reads the claim and
  every bound node identity, invokes deletion only while they match, and forgets the records only over a
  reported absence.
- Exact absence settles cleanup. A replacement is left standing with its records retained; a failed
  deletion, a node still reported present, or a store or report failure preserves the uncertain state and
  is a typed failure.
- No test-only prepared cleanup shape stands beside it.

#### Validation

The sprint closes when these cases exist and pass. `ClusterBackendSpec`: retained reverse conditionally
deletes the cluster and retires its record; retained Harness reverse resolves the exact run-scoped store;
`releaseRetainedCluster` refuses while the exposure record exists and leaves the cluster and both records
in place (rewritten from the case "cluster cleanup refuses until the owned relay has been released"); a
driver that refuses `delete` yields `Left (Failure _)` with every record retained. `ClusterOwnershipSpec`:
release removes the cluster and forgets every record, a second release finds nothing to do, a record over a
create that never happened is forgotten, a created-and-never-bound cluster authorizes no removal, and a
replacement that took a node's name is left standing. `ClusterBackendSpec`: the retained-cluster projection
of a Harness `ClusterPlan` carries that run's state directory and kubeconfig path. A source guard asserts that `Cluster/Backend.hs` and
`Cluster/Reconcile.hs` define none of `PreparedClusterCleanup`, `runClusterCleanupCall`, or
`settleClusterCleanup`. The phase gate runs them.

#### Remaining Work

- Production never calls `withPreparedClusterCleanup`, `runClusterCleanupCall`, or `settleClusterCleanup`;
  only `ClusterReconcileSpec`, `ClusterBackendSpec`, and the `ForeignClusterCleanup.hs`,
  `ForgeClusterAuthorities.hs`, and `CoerceClusterAuthorityRoles.hs` fixtures reach them. Delete
  `PreparedClusterCleanup`, `withPreparedClusterCleanup`, `ClusterCleanupCallResult`,
  `ClusterCleanupResultView`, `clusterCleanupResultView`, and `settleClusterCleanup` from `Cluster/Reconcile.hs`
  and the raw cleanup observation from `Cluster/Observation/Internal.hs`, delete `runClusterCleanupCall` from
  `Cluster/Backend.hs`, delete `ForeignClusterCleanup.hs` and the cleanup rows of the other two fixtures and
  `CompileFailSpec`, and delete the `ClusterReconcileSpec` case "cleanup retains the exact package and refuses a
  replacement".
- The exposure-record refusal lives only in `releaseClusterAfterExposure`, which only `runClusterCleanupCall`
  uses; production releases the relay and then the cluster in two separate entries. Run the same refusal
  inside `releaseRetainedCluster`'s protected entry before `releaseRetainedOwnedCluster`, and rewrite the
  `ClusterBackendSpec` relay-first case against `releaseRetainedCluster`. The rewritten case asserts the
  failure whose cause contains "the owned exposure relay must be released before the cluster", not any
  `Failure`, then releases the relay through `releaseRecordedClusterExposure` and asserts the same
  `releaseRetainedCluster` call now removes the cluster and forgets its records.
- `releaseRetainedCluster`'s body reads the plan's `dataPath` (the durable root) through
  `clusterRuntimeStateDirectory` and `clusterKubeconfigPath`. Add the retained-cluster projection to
  `Cluster/Lifecycle.hs` with its constructor from a `ClusterPlan`, have the body build it once at entry and
  read only it, and add the `ClusterBackendSpec` projection case named in Validation.
- Add `armDeleteRefusal` to `FakeCluster` and the refused-delete case to `ClusterBackendSpec`.

### Sprint 16.12: Structural durable-root exclusion [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Make the never-delete-durable-state invariant structural.

#### Deliverables

- The cluster teardown partition never places its durable data path in the removal set.
- `down` may remove an ephemeral cluster but no durable root, provider frame, or provider disk; `destroy` may
  release project-owned provider state while the host-durable root remains outside that state.
- A durable-root plan node uses `PreserveOnReverse`, and the reverse projection excludes every such node rather
  than relying on a delete call site's path exception.
- This sprint proves exclusion and scheduling structure only. It does not claim that a live destroy followed
  by up reads the same bytes.

#### Validation

`LifecycleSpec` covers the per-verb teardown partition ("down removes nothing on disk and preserves .data",
"delete removes derived state but never .data", and the test-profile case), and `TeardownSpec` covers structural
`PreserveOnReverse` exclusion from the reverse forest. The worked-demo phase owns same-run durable readback.

#### Remaining Work

None. The end-to-end destroy/up/read assertion remains Sprint 24.3.

### Sprint 16.13: Journal-bound provider-wall reservation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget/Internal.hs`,
`core/hostbootstrap-core/test/BudgetSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Make the pre-call provider-wall reservation evidence of one exact protected journal transition.

#### Deliverables

- The only public `ProviderWallReservation` producer jointly consumes one `ProjectPlan`, its matching provider
  `PlannedResource`, exact wall/partition lineage, and the opaque `PreparedGate` recorded for that operation.
- The reservation derives its fence, attempt, session, and journal version from the gate; no positive number,
  descriptive wall, or partition alone can mint it.
- Runtime checks bind the gate's plan digest and operation key to the retained plan/provider resource before a
  prepared wall call exists. `preparePlanOwnedProviderWallCall` re-checks the reservation it joins: the
  retained plan digest is the supplied plan's and the retained operation key is the supplied provider
  resource's `plannedResourceKey`, so a reservation journaled for one provider operation cannot size another
  provider's wall.
- Pure budget validation, capability, workload fit, partition, slice, and unsupported-storage algebra remains
  Phase 12.30's effect-free contract and gains no mutation authority here.
- The `ProviderWallReservation` constructor is not exported and every index of the type is nominal, so no
  public client can construct one or coerce it across plan or fence indices.
- Phase 16 revalidates, but does not re-own, the `Type`-kinded `scope`/`planId` quantification of `StepAction`
  in `HostBootstrap.Step` and Phase 12.30's existential resource-slice traversal needed by the exact
  consumers.

#### Validation

`BudgetSpec` covers exact gate admission and wrong plan, operation, and fence refusal. Named compile-fail
diagnostics pin `CallerFenceProviderWallReservation.hs`, `CrossPartitionProviderWallReservation.hs`, and the
hidden internal module (`ImportBudgetInternal.hs`). The sprint closes when the two `BudgetSpec` cases in
Remaining Work (distinct fence/attempt/version values, and the cross-provider join refusal) pass, and two
further fixtures are registered
in `CompileFailSpec` and rejected: `ForgeProviderWallReservation.hs`, which applies the
`ProviderWallReservation` constructor and is rejected with "Illegal term-level use of the type constructor
'ProviderWallReservation'", and `CoerceProviderWallReservationRoles.hs`, which coerces a reservation from one
plan index to another and from one fence index to another and is rejected with "Couldn't match type 'PlanA'
with 'PlanB' arising from a use of 'coerce'" and the matching fence diagnostic. These run in the same
warnings-as-errors static gate as the Phase 12.30 dependency, without changing that lower sprint's status.

#### Remaining Work

- Add `core/hostbootstrap-core/test/compile-fail/ForgeProviderWallReservation.hs` and
  `core/hostbootstrap-core/test/compile-fail/CoerceProviderWallReservationRoles.hs` and register both in
  `CompileFailSpec` with the diagnostics listed under Validation. No fixture today uses the constructor or
  coerces the roles that `Cluster/Budget/Internal.hs` declares, so removing the role annotation or exporting
  the constructor would pass the compile-fail suite.
- `preparePlanOwnedProviderWallCall` (`Cluster/Budget.hs`) matches the reservation as
  `ProviderWallReservation _plan _operation ...` and never compares either field, and `withProviderWallReservation`
  ignores its wall argument, so a reservation minted from provider A's gate joins a prepared call that sizes
  provider B's wall (the two share a fence, so the fence pre-check passes). Bind both fields as
  `reservedPlan`/`reservedOperation` and add `requirePackage "the reservation was journaled for another provider
  operation" (reservedOperation == plannedResourceKey providerResource)` and `requirePackage "the reservation was
  journaled under another project plan" (reservedPlan == stablePlanSnapshotDigest (renderSnapshot plan))`.
  `BudgetSpec` case: in a plan
  with two provider resources, a reservation minted from the first resource's gate passed with the second
  resource to `preparePlanOwnedProviderWallCall` returns exactly
  `Left (InvalidProviderPackage "the reservation was journaled for another provider operation")`.
- The case "the exact journal gate mints the provider reservation fence" mints fence 1 and attempt 1 over a
  fresh journal version 1 and asserts `Right 1`, so swapping the three `Word64` fields of
  `ProviderWallReservation` (or reading the attempt in `providerWallCallFence`) passes. Mint the gate with
  `gateForValues planDigest operationKey "session-1" 7 3` and assert `Right 7`.

### Sprint 16.14: Exact prepared provider start [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile/ProviderStart/Internal.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Prepare the real provider start as one opaque journal-bound `Observed` to `Running` operation.

#### Deliverables

- `PreparedProviderStart` consumes the exact plan, planned provider, observed provider handle, call digest, and
  current `PreparedGate`; it retains the inseparable operation/preconditions pair.
- The plan graph must authorize the provider's direct `Observed` to `Running` transition and its exact zero-
  dependency precondition set.
- Public code cannot project the retained journal pair or manufacture the package-private owning backend
  result required to complete the start.
- Completion preserves the generic observed resource generation; a provider-specific machine epoch cannot
  replace it.
- The generalized completion kernel changes only the target phase and retains all existing prepared-operation
  mismatch and foreign-result checks.

#### Validation

`ReconcileSpec` and the owning Colima adapter cases cover exact preparation and completion. Named compile-fail
fixtures reject constructor use, nominal role coercion, the hidden projection/completion capability, and
direct import of the internal module. `GenericProviderHandleAsManaged.hs` and
`GenericProviderHandleAsBoundExec.hs` reject using a generic `ResourceHandle ... ProviderResource Managed`
as provider-backend or exec authority. The sprint closes when the Haddock in Remaining Work states that
boundary, under `cd core && cabal test all`.

#### Remaining Work

- The `PreparedProviderStart` Haddock (`Reconcile.hs`) says a public caller "cannot turn a descriptive backend
  observation into @Managed Running@ authority". A public route does exactly that without touching this
  package: `plannedProjectOperation` over a `ProviderResource`, `completeReconcile` with the public
  `BackendCreated` observation, `planProviderBoot`, and the exported `verifyPhaseTransition` yield a
  `ResourceHandle ... ProviderResource Managed Running`, and `ReconcileSpec` already takes it. Reword the
  Haddock to claim only what holds: the package cannot be constructed or completed without the hidden
  capability, and a generic managed provider handle is not provider-backend or exec authority, citing
  `GenericProviderHandleAsManaged.hs` and `GenericProviderHandleAsBoundExec.hs` as the fixtures that pin it.

### Sprint 16.15: Backend-produced provider-wall settlement permit [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget/Internal.hs`,
`core/hostbootstrap-core/test/BudgetSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Prevent a caller-shaped raw wall observation from minting plan-indexed live authority.

#### Deliverables

- Opaque `ProviderWallSettlementPermit` retains the provider-resource, reservation, fence, operation key,
  call digest, attempt, journal version, and exact successful backend observation it authorizes.
- The provider-neutral package-internal mint accepts only the exact prepared wall call, gate, operation, and
  preconditions; it has no dependency on Colima or any other owning backend.
- `settleProviderWallCall` consumes the permit itself and accepts no separately supplied raw observation.
- The permit retains a closed successful observation with a positive epoch: applied, already exact, or
  migrated (an existing wall resized to the declaration, with its receipt); § O's "unchanged/migrated/refused"
  results for an existing wall make migrated a lawful success. Applied settles as `Created`, already-exact as `Unchanged`, migrated as `Repaired`;
  these are the sole producers of `LiveProviderWall` and `ProviderWallAuthority`. Refused, failed, uncertain,
  and zero-epoch observations are refused at the mint and never reach settlement.
- Every match over `WallAcquireObservation` and `ProviderKey` in the mint and in settlement names each
  constructor, so a new observation or provider is a compile error at the site that decides authority and
  the WSL global-wall lease.
- Public clients can neither import the mint nor manufacture or role-coerce a permit across plan, operation,
  reservation, or fence indices. Inside the package, only `Cluster/Budget.hs` and
  `Ensure/Colima/Settlement/Internal.hs` import `HostBootstrap.Cluster.Budget.Internal`, whose exported
  `ProviderWallReservation (..)` and `PreparedProviderWallCall (..)` constructors would otherwise let any
  library module forge a prepared call's argv under genuine gate lineage.

#### Validation

`BudgetSpec` covers gate/prepared-call agreement and refusal branches; owning-adapter settlement is exercised
later by `ColimaSpec`. Named compile-fail diagnostics reject construction, hidden-module import, the former
raw-observation settle shape, and plan/operation role coercion. The sprint closes when the `BudgetSpec`
cases in Remaining Work (migrated settlement, zero-epoch migrated refusal, the WSL and ordinary live-wall
branches, and the importer allow-list guard) pass under `cd core && cabal test all`.

#### Remaining Work

- `withProviderWallSettlementPermitFromObservation` (`Cluster/Budget/Internal.hs`) refuses `WallMigrated` as a
  "non-owning migrated observation" with `DoNotRetry`, while `settleProviderWallCall` (`Cluster/Budget.hs`)
  settles it as `Changed Repaired` and `documents/engineering/wsl2.md` and § O name migrated as a lawful
  acquisition result; the `Repaired` arm, the `WallRefused`/`WallAcquireFailed`/`WallAcquireUncertain` arms,
  and the `epoch == 0` guard in `settleAuthorized` are unreachable. Introduce a package-private
  `SettledWallObservation = SettledApplied Word64 | SettledAlreadyExact Word64 | SettledMigrated Word64 String`
  that the mint builds only for a positive epoch (admitting `WallMigrated epoch receipt | epoch > 0`), store it
  in the permit, and make `settleAuthorized` total over it with no failure arms and no epoch guard.
- Replace the mint's trailing `_ -> nonOwning "invalid epoch"` with explicit `WallApplied _`,
  `WallAlreadyExact _`, and `WallMigrated _ _` fallbacks, and replace the `_ ->` arm of `successful` over
  `ProviderKey` with explicit `ColimaProviderKey`, `LimaProviderKey`, `IncusProviderKey`,
  `DockerNodeProviderKey`, and `BareLinuxProviderKey` arms beside `Wsl2ProviderKey`.
- `BudgetSpec` cases: a prepared call's permit minted from `WallMigrated 7 "resized"` settles to a live wall
  whose `providerWallEpoch` is 7 and whose change view is `Changed Repaired`; `WallMigrated 0 "resized"` is
  refused by the mint with exactly `Failure (FailureDetail "settle provider wall" "the owning provider adapter
  returned a non-owning invalid epoch observation" DoNotRetry)`; a `Wsl2ProviderKey` call settles through
  `withLiveProviderWall`'s WSL continuation and a `ColimaProviderKey` call through its ordinary one.
- Importer allow-list: a `BudgetSpec` source-guard case lists every module under `src/`, `internal/`, and
  `app/` that imports `HostBootstrap.Cluster.Budget.Internal` and asserts the set is exactly
  `Cluster/Budget.hs` and `Ensure/Colima/Settlement/Internal.hs`, and that the latter's import list names
  neither `ProviderWallReservation (..)` nor `PreparedProviderWallCall (..)`.

### Sprint 16.16: Canonical Colima root/data storage-wall binding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/test/BudgetSpec.hs`,
`core/hostbootstrap-core/test/CordonSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Bind Colima admission and storage preparation to one exact total writable-storage ceiling.

#### Deliverables

- Colima admission requires an exactly representable whole-GiB total strictly larger than its fixed 20 GiB
  writable root disk.
- The canonical call fixes `--root-disk 20` and renders `--disk TOTAL-20`; workload-visible data plus provider
  root therefore equals, rather than exceeds, the declared total wall.
- Provider-wall and storage-wall preparation both delegate to the same canonical argv builder and retain the
  total declared bytes as the settlement ceiling.
- The fixed non-activating/template/SSH/mount/Kubernetes/network flags remain part of the exact call digest.
- The renderer and quantity refusal remain Phase 6.1's provider-neutral cordon contract, and the pure indexed
  budget evidence remains Phase 12.30's contract; this sprint is only their direct-Colima adoption and
  revalidation.

#### Validation

`CordonSpec` and `BudgetSpec` pin the 20 GiB root, remainder data disk, exact argv order, `<=20 GiB` refusal,
and total settlement ceiling. The full Phase 16 static gate revalidates the Phase 6.1/12.30 implementation
without changing those completed lower-phase statuses.

#### Remaining Work

None. The storage-wall settlement permit and the agreement of the storage-wall argv with the renderers
production launches with are Sprint 16.59's.

### Sprint 16.17: Trusted resolver wire protocol [Active]

**Status**: Active
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Protocol.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Define one strict private report that can describe, but not itself authorize, a trusted Apple toolchain.

#### Deliverables

- The resolver protocol distinguishes ready, missing-Colima-with-trusted-Brew, and unsupported outcomes.
- Ready reports bind every executable and helper-search directory the direct backend will use, together with
  their canonical identity and toolchain fingerprint inputs.
- The decoder accepts one canonical bounded report and rejects missing fields, duplicates, extra output,
  malformed numbers/digests, CR, or non-canonical paths.
- One protocol validator holds the content checks (canonical tool paths free of `,` `;` TAB CR LF NUL,
  formula/Docker allowlist paths, absolute unique helper-path entries, nonzero device/inode, helper bindings
  agreeing with the helper path). The decoder applies it, and `settleTrustedProtocol` applies it to the
  in-process native protocol, so production resolution and the fixture wire share every check.
- Brew evidence exists only in the missing-Colima branch; a ready/live/cleanup toolchain is not coupled to
  unrelated later Brew drift.
- The protocol module is an `other-modules` member of the Cabal-private `colima-backend-internal` component;
  that component boundary, not a hidden constructor, keeps the exported `TrustedDirectoryBinding`,
  `ResolvedTool`, and `TrustedResolverProtocol` constructors from producing public authority.

#### Validation

`ColimaSpec` covers canonical round trips and malformed, duplicated, decorated, truncated, and cross-branch
reports under the host-static test gate through `Resolver.Testing`'s descriptive protocol views and
layout-matched decoder. Closing this sprint also requires exact-reason `ColimaSpec` cases over single-field
mutations of a valid fixture report: `resolver-colima-path`, `resolver-docker-path`, `resolver-lima-path`,
`resolver-brew-path`, `resolver-tool-path`, `resolver-tool-device`,
`resolver-tool-inode`, `resolver-tool-identity`, `resolver-helper-path`, `resolver-helper-binding-paths`,
`resolver-helper-binding-shape`, and `resolver-invalid-reason`, plus the native-route refusal and the framing
cases named below, all passing under `cd core && cabal test all`.

#### Remaining Work

- Factor the content checks of `parseTrustedResolverOutputWithLayout` (`Resolver/Protocol.hs`) into one
  `validateTrustedProtocol :: ResolverProtocolLayout -> TrustedResolverProtocol -> Either String ()` and call
  it from `settleTrustedProtocol` (`Resolver.hs`) as well as from the decoder. Test: a fixture layout whose
  Colima Cellar version directory contains `:` (`.../Cellar/colima/1:x/bin/colima`) is refused with
  `resolver-helper-path` on the native fixture route (`executeNativeResolverFixture` then settlement), not
  only on the decoder.
- Add the exact-reason mutation cases listed in Validation to `ColimaSpec`'s trusted-resolver group: each
  takes the valid READY or MISSING_COLIMA wire from the fixture harness, mutates one field (Colima path
  outside the Cellar, a `..` version segment, a wrong binary name, a Docker path neither formula nor app,
  a Brew path mismatch, device `0`, inode `x`, a reordered binding), and asserts the exact `Left` reason
  from `parseResolverFixtureProtocolView`.
- The case "the resolver rejects malformed, decorated, truncated, and cross-branch reports" accepts any
  `Left` through `assertResolverRejected`, and each decorated input is rejected by a check other than the
  embedded newline/CR check of `strictProtocolBody`, so removing that check fails no case. Assert the exact
  reason per input (`resolver-protocol-framing` versus `resolver-protocol-shape`), and add the inputs
  `output ++ "\n"` and `init output ++ "\r\n"`, each refused with `resolver-protocol-framing`.
- Reword the Haddock on `trustedDirectoryBindingsFingerprint` in `Resolver/Protocol.hs`: it says the
  constructor is hidden while the module exports `TrustedDirectoryBinding (..)`; state that the private
  component boundary is what confines construction.

### Sprint 16.18: Trusted resolver program [Active]

**Status**: Active
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Native.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Resolve the complete direct-Colima toolchain from a fixed Apple trust policy rather than ambient execution
state.

#### Deliverables

- `Resolver.Native` inspects, in process and without launching a resolver program, only the closed Apple
  candidate table (`productionLayout`) for Colima, Docker, Lima, and the optional install-time Brew route.
  It inspects no Python candidate; removing the `/usr/bin/python3` candidate the table still carries is
  Sprint 16.49's owed work.
- Every admitted executable is an absolute canonical non-symlink regular file with exact owner, mode, and
  opened-versus-path identity checks; helper directories are derived only from admitted paths.
- Homebrew's administrative anchor allowance is explicit while formula and binary directories retain the
  stricter ownership/mode policy.
- The owner and mode policy is one total function of (layout kind, path, owner, mode, effective uid) that the
  production and fixture layouts both evaluate, and the executable and directory owner rules agree under
  `/Applications/Docker.app`, so a static case exercises the production policy.
- The resolver reads no ambient `PATH`, `HOME`, current directory, Docker context, or caller-provided tool.
- Missing, ambiguous, mutable, or untrusted candidates produce a strict unsupported report rather than a
  best-effort executable choice.

#### Validation

`ColimaSpec` drives `Resolver.Native` over the Cabal-private `Resolver.Testing` fixture layout
(`executeNativeResolverFixture`) and its decoder to cover canonical candidates, formula-root symlink refusal,
executable write-mode refusal, the Docker Desktop fallback, helper-directory replacement, an effective home
outside the admitted user root, the Brew-only missing branch, and hostile ambient home/path/working
directory. Production resolution inspects only `productionLayout` (`Resolver/Native.hs`), whose wire form is
`productionProtocolLayout` (`Resolver/Protocol.hs`). The sprint closes when the policy cases and the
hostile-ambient case in Remaining Work exist and pass under `cd core && cabal test all`.

#### Remaining Work

- `admittedOwner` and `admittedDirectoryOwner` (`Resolver/Native.hs`) short-circuit to `owner == user` when
  `layoutFixture` is set, so no static case evaluates the production owner policy. Lift the policy into one
  exported total function of (layout kind, path, owner, mode, effective uid) used by both layouts, and make the
  directory rule admit what the executable rule admits under `layoutApplications` (today a user-owned
  directory under `/Applications/Docker.app` is refused while a user-owned executable there is admitted).
  `ColimaSpec` table cases over the production layout: a root-owned `/usr/local/bin` entry is admitted and a
  user-owned one refused; a user-owned Homebrew Cellar entry is admitted; a root-owned and a user-owned
  `/Applications/Docker.app` executable and its containing directory are each admitted; a group-writable
  directory is refused; and the fixture layout evaluates the same table.
- The case "fixed candidates ignore hostile ambient home, path, and working directory" never runs the resolver
  under a hostile environment. Plant executable `colima`, `docker`, and `limactl` in `ambient/bin`,
  `ambient/home`, and `ambient/cwd`, run the resolver with those as its effective `PATH`, `HOME`, and working
  directory (a subprocess, or `setEnv` plus `withCurrentDirectory`), and assert the settled paths are the
  fixture Cellar targets; otherwise delete the case.

### Sprint 16.19: Bounded direct-Colima runner and supervisor [Active]

**Status**: Active
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/Run.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Bound every direct-Colima tool process without leaking descendants or swallowing cancellation.

#### Deliverables

- Each tool runs through `runShippedCommand`: the installed binary's hidden command-transaction entry leads a
  retained process group under `runBoundedGroupedWithInput`, with an explicit finite deadline (1 to 900
  seconds) and parent-death supervision through the entry's retained stdin.
- Timeout and successful-leader-exit paths quiesce the complete retained group before identifiers may be
  reused, close or drain both pipes within bounds, and reap the leader without an unbounded wait.
- Interrupt, terminate, and kill escalation reaches the group, including a descendant that ignores TERM or
  keeps stdout/stderr open after the leader exits.
- Output retention is bounded and parser-visible truncation or pipe failure is a structured backend failure.
- Haskell asynchronous exceptions terminate/reap the group and propagate unchanged.

#### Validation

`ColimaSpec` drives one real process through `runShippedCommand`: hard death of the owning process with a
TERM-ignoring descendant, after which the descendant is gone. Closing this sprint requires real-process
`ColimaSpec` cases, without a real Colima installation, for each remaining runner behaviour listed below,
passing under `cd core && cabal test all`.

#### Remaining Work

- Timeout: `runShippedCommand 1` over a child that sleeps past the deadline returns `BoundedToolTimedOut`,
  and a descendant PID the child published is gone afterwards.
- Output bound: a child that writes past the retained-output limit returns
  `BoundedToolFailed "output-limit"`.
- Leader exits first: a child that exits while a background descendant keeps stdout open returns within the
  deadline as `BoundedToolCompleted`, and the descendant is gone.
- Cancellation: `killThread` on the thread running `runShippedCommand` re-raises `ThreadKilled` unchanged in
  that thread, and the published descendant PID is gone.
- The shipped command transaction (`Runner.hs`) spawns its tool child with `std_in = NoStream`, the
  disposition `Effect/Detached.hs` documents as having wedged the accelerator daemon, and it is the one
  transitional entry in `DetachedSpec`'s `NoStream` drift guard. Open the null device read-only (as
  `Detached.hs` does) and spawn with `std_in = UseHandle` on it, closing it once the child is reaped, and
  delete the `Runner.hs` transitional entry from `DetachedSpec` in the same change. Real-process `ColimaSpec`
  case: a shipped child that reads its standard input to end of file reports 0 bytes read and exits within
  the deadline.

### Sprint 16.20: Trusted resolver facade [Active]

**Status**: Active
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Authority.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Override.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Expose a private opaque toolchain only after native resolution, strict settlement, and revalidation.

#### Deliverables

- The facade obtains the effective user's home from the OS account database and freshly admits only Apple
  silicon before `resolveTrustedAppleToolchain` runs the in-process native resolver (`Resolver.Native`) and
  settles its protocol through `settleTrustedProtocol`.
- `TrustedAppleToolchain` retains canonical executable/helper identities and one deterministic fingerprint;
  its constructors and revalidation details remain private.
- The facade preserves the distinct missing-Colima-with-trusted-Brew result for the later owning adapter; it
  does not itself install a package or turn Brew evidence into a ready toolchain.
- Ready acquisition, live Docker, and cleanup revalidate only their retained ready toolchain immediately
  before and after effects.
- Unsupported, malformed, missing, or drifted resolution yields no backend capability. Revalidation compares
  a fresh resolution with the retained value through one pure classifier per branch, refusing with
  `trusted-apple-toolchain-changed`, `trusted-colima-missing`, `trusted-apple-brew-changed`, or
  `trusted-colima-now-present`.
- Production resolution carries no test branch (§ NN): `resolveTrustedAppleToolchain` and
  `discoverDirectColimaBackendAt` consult no process-global override. Host-static tests reach the resolver
  through the fixture-layout entry `executeNativeResolverFixture` and the pure settlement and revalidation
  functions that `Resolver.Testing` re-exposes as descriptive views.

#### Validation

`ColimaSpec` covers ready, missing, unsupported, effective-home refusal, helper-directory fingerprint drift,
and timeout/execution-failure/stderr/exit-failure/bootstrap-identity settlement refusals through
`Resolver.Testing`. `ImportColimaResolverTesting.hs` is a named downstream import failure. Closing this
sprint requires the four revalidation cases below and a `SourceGuard` case asserting that no module under
`internal/colima-backend` or `src/HostBootstrap/Ensure` names `ResolverOverride` or
`currentTrustedResolverOverrideHomeForTesting`, all passing under `cd core && cabal test all`.

#### Remaining Work

- Delete the test-only resolver override: `Resolver/Override.hs` (and its `other-modules` entry), the
  override arm of `resolveTrustedAppleToolchain` (`Resolver.hs`), `currentTrustedResolverOverrideHomeForTesting`
  and the fixture-home arm of `discoverDirectColimaBackendAt` (`src/HostBootstrap/Ensure/Colima.hs`),
  `withTrustedResolverFixture` (`Resolver/Testing.hs`), and
  the `ImportColimaResolverOverride.hs` compile-fail fixture with its `CompileFailSpec` entry; drop
  `Override.hs` from this sprint's Implementation. No test calls `withTrustedResolverFixture`.
- Factor `revalidateTrustedAppleToolchain` and `revalidateTrustedAppleBrew` into pure classifiers over
  (retained value, fresh `TrustedResolverResult`) that `Resolver.Testing` re-exposes. `ColimaSpec` cases over
  the fixture harness: resolve READY, replace the Colima Cellar target with a new inode at the same path,
  resolve again, and assert `Left "trusted-apple-toolchain-changed"`; remove the Colima alias and assert
  `Left "trusted-colima-missing"`; in the missing-Colima state replace the Brew binary and assert
  `Left "trusted-apple-brew-changed"`, then restore Colima and assert `Left "trusted-colima-now-present"`.
- Fingerprint sensitivity in `ColimaSpec`: resolve an unchanged fixture tree twice and assert equal
  `trustedAppleToolchainFingerprint` values; replace one tool's target file so its inode changes and assert the
  fingerprint changes. Delete the always-true non-null and `isReadyProtocol` assertions these replace.

### Sprint 16.21: Descriptor-held filesystem and profile-lock primitives [Active]

**Status**: Active
**Implementation**:
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Provide no-follow descriptor-relative primitives for the exact Colima ownership transaction. Colima adopts
the shared `ownership-internal` component's POSIX row and protected store rather than carrying its own.

#### Deliverables

- Component-wise traversal retains parent descriptors, never follows a symbolic component (it records the
  link and its target bytes), refuses foreign-owned or group/other-writable components, and validates type
  and opened-versus-path identity before use.
- Directory creation, regular-file open, no-replace publication, replacement, and unlink operate relative to
  validated descriptors rather than a re-resolved pathname.
- File and containing-directory synchronization plus authoritative readback close every publication and
  removal boundary.
- The reusable profile-global lock remains synchronization-only, is opened no-follow, and is held by its exact
  descriptor/inode across the complete transaction.
- Record and stage operations retain expected descriptors, identities, and bytes so an identical-byte inode
  replacement is a conflict rather than adoption.

#### Validation

`OwnershipPosixSpec` covers authoritative absence, created directory/file identities, link-preserved
identity, final-component symbolic-link refusal on create, open, and remove, no-replace collision, whole-file
writes, parent-durable removal, and the kernel releasing the exclusive open when its holding process dies.
`OwnershipSpec` covers clause-4 refusal of a replaced identity, which is how an identical-byte inode
replacement surfaces. A sync or readback failure has no static case, because § NN admits no fault-injection
branch to produce one. Closing this sprint requires the manifest-walk cases below, passing under
`cd core && cabal test all` on a POSIX gate host, with the walk family declared in `CoverageManifest` so a
host that cannot arrange a case (a foreign owner needs a second account) reports it rather than renaming it
green.

#### Remaining Work

- `OwnershipPosixSpec` case: `posixObserveOwnershipManifest` over a tree holding a symbolic link to a
  populated directory records one symbolic-link entry carrying the exact target bytes and no entry for any
  file behind the link.
- `OwnershipPosixSpec` case: `posixObserveOwnershipManifest` refuses a tree containing a group-writable
  directory (mode `0775`) with the `is group/other writable` `OwnershipOccupied` fault, and refuses a regular
  file with a second hard link with the `is not an exact owned manifest file` fault.
- The rest of `posixObserveOwnershipManifest`'s refusals are reached by no test. `OwnershipPosixSpec` cases,
  each asserting its exact fault: a group-writable root; a `0o666` regular file; a FIFO made with
  `createNamedPipe`; a regular file over 4 MiB observed in immutable mode; and, where the host can arrange a
  second owner, a foreign-owned descendant. A kind case observes a file, a directory, a symbolic link, and a
  bound Unix socket and asserts the entry kinds `m`, `d`, `l`, and `s` (and `f` for the same file observed
  immutable).
- The walk reads entry names with `readDirStreamMaybe` and link targets with the `String` `readSymbolicLink`,
  both decoded through the process locale, so an undecodable byte becomes a surrogate escape and the stored
  bytes depend on `LANG`. Read names and targets as raw bytes (`System.Posix.Directory.ByteString` and
  `System.Posix.Files.ByteString.readSymbolicLink`, or the `PosixPath` variants) and hand the manifest raw
  bytes (Sprint 16.60 makes the manifest carry them). Case: a directory holding a file named with the byte
  `0xff` and a symbolic link whose target is `caf\xc3\xa9`, observed once under `LC_ALL=C.UTF-8` and once
  under `LC_ALL=C` in a child process, yields byte-identical rendered manifests.
- Each entry is described by `getSymbolicLinkStatus` and `readSymbolicLink` on the ambient path
  `absolute </> name`, so a symbolic link or socket entry can be recorded from a directory renamed in during
  the walk. Describe entries relative to the parent descriptor with `fstatat(parentFd, name,
  AT_SYMLINK_NOFOLLOW)` and `readlinkat` (FFI bindings where `unix` has none), and close the duplicated
  descriptor in `directoryNames` when `fdopendir` fails. Case: the walk over a tree whose parent directory is
  observed through its descriptor records the same manifest as before, and a source guard asserts
  `posixObserveOwnershipManifest` calls neither `getSymbolicLinkStatus` nor the path `readSymbolicLink`.

### Sprint 16.22: Isolated Colima home/data namespace [Active]

**Status**: Active
**Implementation**:
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`

#### Objective

Bind every mutable Colima/Lima/cache/temp path to one short, isolated, identity-checked profile namespace.

#### Deliverables

- The 128-bit namespace key derives the isolated `COLIMA_HOME` (`<passwd home>/.h<key>`) plus exact Lima,
  cache, temporary, and data paths, and the Docker config sits beside the plan-root record
  (`<record path>.docker`); Production, Harness, and concurrent runs cannot share one mutable namespace
  accidentally.
- The backend supplies a closed environment, helper `PATH`, effective passwd home, and fixed working directory;
  ambient `HOME`, `PATH`, `COLIMA_HOME`, `LIMA_HOME`, temp, Docker config, and cwd are ignored.
- Every namespace component, including the Docker config's parent chain below the plan root, is
  created/opened no-follow and represented by an identity bound in a shared origin record that live use and
  cleanup re-enter.
- Socket-path length is checked before mutation, so an unsupported effective-home layout cannot partially
  create a profile.
- Foreign, missing-after-ownership, or identity-changed home/data components are conflicts and are not
  recreated during live use or cleanup.

#### Validation

`ColimaSpec` covers the derived profile's `h-` prefix and eight-character length, real-kernel home and
Docker-config directory acquisition, exact re-entry and release through shared origin records, idempotent
namespace preparation to `Prepared`, and refusal of an added Docker-config file before any Docker command.
Closing this sprint requires the cases below, passing under `cd core && cabal test all`.

#### Remaining Work

- Replace `createDirectoryIfMissing True (takeDirectory (namespaceDockerConfig namespace))` in
  `runPreparedColimaWallCall` (`src/HostBootstrap/Ensure/Colima.hs`) with creation inside the driver's
  namespace preparation (`Ownership.hs`) through the shared no-follow primitives under the protected entry,
  binding each created parent's identity in an origin record that cleanup releases. `ColimaSpec` case: with
  the Docker config's parent planted as a symbolic link to another directory, `prepareColimaNamespaces`
  refuses and creates nothing behind the link.
- Factor the socket-length test of `ownershipBackendFromToolchain` into a pure predicate over (passwd home,
  namespace key, profile). `ColimaSpec` cases: a home that puts the Lima socket path at 104 bytes or more is
  refused, one byte shorter is admitted.
- `ColimaSpec` driver cases: `prepareColimaNamespaces` refuses when the Colima home is a pre-planted symbolic
  link; after acquisition, a removed home makes `runManagedColimaDockerWith` refuse with no command run and
  leaves the home absent.

### Sprint 16.23: Docker-context ownership and release manifest [Active]

**Status**: Active
**Implementation**:
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Own Colima's Docker-context side effect as an isolated named resource with a durable conditional-release
manifest. The name-checked context listing and the deletion of the lax Colima listing parser belong to
Sprint 16.66. The kernel face's refusal to release a `ReportedObject` record belongs to Sprint 16.65, which
follows this sprint because this sprint takes manifest remainders off `releaseOwnedObject`.

#### Deliverables

- Before the isolated `DOCKER_CONFIG` directory is created, acquisition lists Docker contexts and refuses
  while `colima-<profile>` is named. The directory's own absence is clause 1 of its creation, so neither the
  path nor the named context exists before Colima can mutate it.
- Acquisition fingerprints the exact Docker directory/context artifacts and publishes their identity/content
  manifest before the origin becomes managed.
- Managed-state log or metadata drift may rebuild the manifest only before cleanup durably enters releasing;
  releasing and later stages freeze the exact teardown proof.
- Cleanup models both lawful Colima behaviors: named-context deletion, or retention of the exact previously
  owned context; a foreign or replacement context is never removed. Before `docker context rm`, cleanup
  decides presence from the context listing, because `classifyDockerContextInspect` classifies an absent
  context and a failed tool alike as `ColimaToolExit`. An unlisted `colima-<profile>` skips removal. A listed
  one is inspected, and `dockerContextFingerprint` over the re-observed identity of the context directory
  bound at `colimaContextKey` and the inspected value is compared with the releasing record's
  `managedContextDigest`; a different fingerprint refuses and the context stays.
- Exact context/config removal is descriptor-relative, identity-conditional, synchronized, and independently
  re-observed absent before origin release: the context listing is re-read after removal and before
  `ColimaContextReleased` is written.
- Namespace remainders are bounded by the retained manifest at `colimaManifestKey`, not by the current
  observation. Its `docker/` entries, with that segment stripped, are relative to the Docker-config root; its
  `colima/` entries, with that segment stripped and `cache` and `tmp` excluded, are relative to the Colima
  home. A retained entry now observed absent is already released (Colima's delete or `docker context rm`
  removed it) and is skipped. A present entry whose identity differs, or a current entry outside the
  manifest, is a conflict and stays in place.
- Each remainder is released by `releaseManifestRemainder` in `Ownership/Primitive.hs`, a producer that takes
  the remainder's absolute target and its retained `ObjectIdentity` inside the protected entry, observes the
  target, and removes and parent-syncs it only when the observed identity is the retained one. It is exported
  from the private `ownership-internal` library only, so no public module can reach it.

#### Validation

`ColimaSpec` covers canonical Docker-context fingerprinting (whitespace and key order are authority-neutral),
manifest publication before `Managed`, refusal of an added Docker-config file before any Docker command, and
one value-driven cleanup that removes the context and Docker-config directory (the cleanup script in "the
direct driver describes every tool effect without running it"). The sprint closes when these cases exist and
pass under `cd core && cabal test all`:

- `ColimaSpec`, over `acquireManagedColimaProfileWith`: an interpreter whose first `context ls` names
  `colima-<profile>` refuses with `ColimaMutationProfileConflict`, the Docker-config directory does not exist
  afterwards, and the interpreter records no `start` command. The existing acquisition scripts gain the
  leading `context ls` step, answered with a listing that does not name the context.
- `ColimaSpec`, over `cleanupManagedColimaProfileWith`: the existing cleanup script gains `context ls`
  (naming the context) and `context inspect` before `context rm`, and a `context ls` that does not name it
  after `context rm`.
- `ColimaSpec`, over `cleanupManagedColimaProfileWith`: a first `context ls` that does not name the context
  completes to `ColimaReleased` with no `context inspect` or `context rm` recorded.
- `ColimaSpec`, over `cleanupManagedColimaProfileWith`: a listed context whose `context inspect` answers a
  different endpoint refuses with `ColimaMutationProfileConflict`, and no `context rm` is recorded.
- `ColimaSpec`, over `cleanupManagedColimaProfileWith`: a `context rm` that exits 0 while the following
  `context ls` still names the context refuses with `ColimaMutationProfileConflict` and leaves the stage at
  `ColimaReleasing`.
- `ColimaSpec`, over `cleanupManagedColimaProfileWith`: an interpreter that creates a file under the Docker
  config while it runs `delete` (after the pre-delete manifest check) makes cleanup refuse, and the file
  survives.
- `ColimaSpec`, over `cleanupManagedColimaProfileWith`: an acquisition whose `start` creates a context
  metadata file under the Docker config, and a cleanup whose `context rm` removes that file, reaches
  `ColimaReleased`: the retained entry `context rm` deleted is skipped as already released.
- `OwnershipSpec`, `releaseManifestRemainder` against `unreachableRow fullCapabilities` with
  `rowObserveIdentity` overridden: an absent answer returns `Right ()` and reaches no other primitive; a
  different identity returns `OwnershipConflict` and reaches no `rowRemoveObject`; the retained identity,
  with `rowRemoveObject` and `rowSyncParent` overridden to count their calls, removes and syncs exactly once.

#### Remaining Work

- In `applyAcquisition` (`acquireManagedColimaProfileWith`, `Ensure/Colima/Ownership.hs`), when the retained
  stage is absent or earlier than `ColimaContextStaged`, run `listDockerContextsCommand` through
  `classifyDockerContextListing` before `prepareColimaNamespacesInside`, and refuse with
  `ColimaMutationProfileConflict` when `colima-<profile>` is listed. Add the acquisition case in Validation and
  the leading `context ls` step to the existing acquisition scripts.
- In `finishNamespaces`, before `removeDockerContextCommand`, run `listDockerContextsCommand` through
  `classifyDockerContextListing`. If `colima-<profile>` is not listed, skip removal. If it is listed, run
  `inspectDockerContextCommand ("colima-" ++ profile)` through `classifyDockerContextInspect`, re-enter and
  re-observe the context directory's bound identity at `colimaContextKey` (refusing, never acquiring, when the
  record is absent), and return `ColimaMutationProfileConflict` when `dockerContextFingerprint contextIdentity
  value` differs from `managedContextDigest` of the releasing record's evidence. Add the absent-context and
  replaced-context cleanup cases in Validation, and rescript the existing cleanup case.
- After `removeDockerContextCommand`, and before `ColimaContextReleased` is written, run
  `listDockerContextsCommand` through `classifyDockerContextListing` and refuse with
  `ColimaMutationProfileConflict` while `colima-<profile>` is still listed. Add the still-listed case in
  Validation.
- `releaseNamespaceRemainders` reads the retained manifest from `colimaManifestKey` with
  `parseOwnershipManifest`, keeps the entries under its root's prefix (`colima/` for the home, `docker/` for
  the Docker config) with the prefix stripped, and releases them deepest first. It refuses with
  `OwnershipConflict` for a current entry outside the retained set. Add the concurrent-file and
  already-released cases in Validation.
- Add `releaseManifestRemainder` to `Ownership/Primitive.hs` as the Deliverables describe, applying
  `clauseRefusal` for `ClauseRelease` and `ClauseRecord` before its first primitive. `releaseEntries` calls it
  in place of building an in-memory `ReportedObject` record and releasing it through `reenterOwnedObject`,
  `reobserveOwnedIdentity`, and `releaseOwnedObject`. Add the three `OwnershipSpec` cases in Validation.

### Sprint 16.24: Durable direct-Colima origin transaction [Active]

**Status**: Active
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Define one self-bound, crash-recoverable origin state machine shared by acquisition, live use, and cleanup.

#### Deliverables

- Canonical reserved/home-staged/home-ready/context-staged/prepared/managed/releasing/context-released/released
  `ColimaStageRecord` values bind the owner token, lineage, acquisition invocation digest, and, from
  releasing on, the cleanup invocation digest. The owner token is a deterministic projection of the plan's
  owner seed, the namespace paths, the helper path, and the toolchain fingerprint; the lineage is the SHA-256
  of the 128-bit namespace key; per-invocation freshness comes from the invocation digest, which carries the
  gate's operation, session, attempt, and journal version. No nonce enters the record.
- The record lives under one protected-store entry; every write is a compare-and-swap on the stored record
  version, so a copied or replaced record is a version conflict rather than adoption.
- Prepared is the sole pre-call outcome-unknown state: it records prior profile and data-disk absence in shared
  origin records and binds the exact wall and invocation before `colima start`.
- Managed carries `ColimaManagedEvidence`: machine identity and epoch, context digest, manifest digest,
  directory-chain digest, and the CPU, memory, data-disk, and root-disk wall.
- Recovery accepts only the same owner/lineage/invocation and a canonical state-specific combination; copied
  records, partial stages, or mismatched artifacts fail closed. `decideColimaStage` is the one decision table,
  and the driver's acquisition and cleanup take each step from it.
- Cleanup stages bind the distinct teardown invocation digest and retain enough frozen state to resume only
  the same conditional release.
- The protected-store entry is synchronization-only; release completion lives in the stage record, and a
  `Released` record admits a later acquisition, which opens a new lineage from `Reserved`.

#### Validation

`ColimaSpec` covers the closed stage vocabulary, canonical record parser/renderer, idempotent re-entry and
every adjacent transition with skipped/reversed/cross-lineage refusal, the total `decideColimaStage` table,
and one real-kernel acquire, settle, cleanup sequence that ends at `ColimaReleased`. Crash windows reachable
only by fault injection have no static case (§ NN). Closing this sprint requires the cases below, passing
under `cd core && cabal test all`.

#### Remaining Work

- `acquireInside` (`Ownership.hs`) treats a `ColimaReleased` record as a fresh start: it compare-and-swaps
  that record to `Reserved` under the new owner/lineage/invocation before `applyAcquisition`, instead of
  refusing with "managed stage belongs to another lineage". `ColimaSpec` case: acquire, clean up, then
  acquire again on the same state root and profile with a new invocation yields `ColimaManagedApplied` and a
  `ColimaManaged` stage record.
- Route the driver's stage choices through `decideColimaStage`: `acquireInside`,
  `startPreparedColimaProfileInside`, and `cleanupInside` classify their observation into
  `ColimaStageObservation` and act on the returned `ColimaStageDecision`, mapping `Left` to
  `ColimaMutationProfileConflict`. A `SourceGuard` case asserts `decideColimaStage` has a caller in
  `Ownership.hs`.
- `ColimaSpec` replay case over `cleanupManagedColimaProfileWith`: a second cleanup with the same cleanup
  invocation after `ColimaReleased` returns `Right ()` and issues no command.

### Sprint 16.25: Locked direct-Colima acquisition program [Active]

**Status**: Active
**Implementation**:
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`

#### Objective

Execute one exact acquisition entirely inside the reusable profile lock and durable origin transaction.

#### Deliverables

- Acquisition opens the exact state/lock namespace, holds the retained profile lock, and strictly observes
  profile, context, home/data, wall, and origin before any mutation.
- Fresh acquisition publishes prior absence, creates/binds the isolated namespaces, enters prepared, runs the
  bounded non-activating start, and then re-observes all stable identities before managed publication.
- A prepared record with an unexpectedly present profile is outcome-unknown conflict, never evidence that the
  current profile belongs to this operation.
- Same-name unowned profiles are foreign; incompatible, malformed, changing, or partially observed state is a
  conflict or failure and is left untouched.
- `ColimaManagedApplied` and `ColimaManagedAlreadyExact` carry the started machine identity and epoch plus
  the artifact observation (data disk, context digest, manifest) that settlement and later exact calls
  re-check.

#### Validation

`ColimaSpec` covers value-driven fresh acquisition (`ColimaManagedApplied`) and exact re-entry
(`ColimaManagedAlreadyExact`) without a start command, `Prepared` retained when the start command is
unavailable, and strict Colima-list and machine-identity report refusals. The absent/exact-running/exact-stopped
and incompatible-profile cases drive `classifyColimaWall`, which the driver never calls and which Sprint 16.30
deletes; the driver's own classification is covered by the value-driven acquisition cases. Closing this sprint
requires the cases below, passing under `cd core && cabal test all`.

#### Remaining Work

- `startPreparedColimaProfileInside` (`Ownership.hs`) returns `ColimaMutationProfileConflict` for a
  `Prepared` record whose profile is already present, instead of adopting it through `settleRunning`; the
  `decideColimaStage` row `(AcquireColima, ColimaPrepared, ColimaProfileExact)` becomes `Left` and its
  `ColimaSpec` table entry moves to the refused set. The conflict names the profile and the `Prepared` record
  so the operator can resolve the outcome-unknown start. Case: a `Prepared` record plus an interpreter that
  lists the exact running profile refuses and issues no machine-identity read.
- `ColimaSpec` value cases: a start command exiting non-zero returns `ColimaMutationStartFailed` with the
  stage left at `Prepared`; a listing that still lacks the profile after start returns the "profile remained
  absent after start" conflict. Each of the following post-start readbacks returns its exact refusal with the
  stage left at `Prepared`: a running wall that differs from the prepared wall (4 CPUs against 8), status
  `Stopped`, runtime `containerd`, a listing that names the profile twice, and a `Prepared` stage record of
  another lineage.
- `ColimaSpec` exclusion case: two threads run `acquireManagedColimaProfileWith` on the same state root and
  profile with a counting interpreter; exactly one start command is issued, one result is
  `ColimaManagedApplied`, and the other is `ColimaManagedAlreadyExact` or an entry refusal.

### Sprint 16.26: Opaque direct-Colima acquisition backend facade [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Report.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportColimaBackendRunner.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Run acquisition as one in-process driver transaction whose result the owning adapter alone turns into
authority.

#### Deliverables

- `acquireManagedColimaProfileWith` runs acquisition in process under one protected-store entry, taking the
  state root, profile, owner, lineage, invocation, home, Docker config, wall split, and canonical start argv.
- Every Colima, Docker, and Lima effect is a described `HostCommand` from `HostBootstrap.Ensure.Colima.Command`;
  the owning adapter interprets it through `runShippedCommand` in the closed namespace.
- Each tool result passes one of `HostBootstrap.Ensure.Colima.Report`'s strict total classifiers; exit, stderr,
  framing, shape, or duplicate faults are `ColimaMutationReportRefused`.
- Success is `ColimaManagedApplied` or `ColimaManagedAlreadyExact`; every other outcome is a
  `ColimaProfileMutationFault` that stays descriptive until `runPreparedColimaWallCall` matches it to its
  prepared package.
- The bounded runner and resolver stay in the Cabal-private `colima-backend-internal` component.

#### Validation

`ColimaSpec` pins the argv of every described tool effect, the strict classifier refusals, and the
value-driven `ColimaManagedApplied`/`ColimaManagedAlreadyExact` acquisitions. `ImportColimaBackendRunner.hs`
rejects a downstream import of the runner.

#### Remaining Work

None. Removing the driver module itself, with its caller-supplied interpreter, from the public library surface
is Sprint 16.29's.

### Sprint 16.27: Exact project/lifecycle Colima profile identity [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Derive one collision-resistant direct-Colima namespace authority, plus its socket-safe local profile, from the
installed project and exact lifecycle profile.

#### Deliverables

- A stable 128-bit namespace key derives from `projectPlanProjectName`, `projectPlanProfileName`, the exact
  provider resource/frame, and canonical plan root; no caller-selected name enters that key.
- Production, distinct Harness run IDs, and concurrent Harness runs map to distinct isolated Colima homes.
  The short six-hex Colima profile (`h-` plus six hex) is local to that unique home and is never `default`.
- The protected-store entry at the plan root keys its stage and origin records by the short profile; the
  lineage (SHA-256 of the 128-bit key) is the collision guard inside that store, so two keys whose short
  profiles coincide in one plan root fail closed with a lineage conflict rather than sharing authority.
- The 128-bit home key, socket-safe local profile, origin record name, and owner seed are deterministic
  projections of the same full plan/lifecycle inputs, and the durable owner/record binds both derived names.
- `deriveColimaNames` rejects an invalid project name, an unknown lifecycle profile, or an invalid Harness run
  key before any backend call.
- These projections remain descriptive until combined with the prepared gate and closed backend.

#### Validation

`ColimaSpec` covers the derived profile's `h-` prefix and eight-character length. Its shared-default case
applies `validColimaProjectProfileName`, a predicate production never calls, so the production refusal in
`validateProfileName` has no case yet. Constructor/role fixtures preserve the plan/profile seal. Closing this
sprint requires the derivation cases below, passing under `cd core && cabal test all`.

#### Remaining Work

- Move `deriveColimaNames` from `src/HostBootstrap/Ensure/Colima.hs` into the private sublibrary Sprint 16.29
  creates (the public module imports it and keeps it unexported), and add `ColimaSpec` cases: `production` and `harness:<run>` for the same project, resource, frame, and root yield different
  128-bit keys and homes; two distinct valid run keys yield different keys; the same inputs yield the same
  pair twice; an invalid run key and an unknown lifecycle profile are refused with their named
  `ReconcileError`. The determinism case also asserts the profile is `h-` followed by six lowercase hex
  digits, and that a second fixture project yields a different profile.
- `validColimaProjectProfileName` duplicates the `"default"` check of `validateProfileName`, which
  `deriveColimaNames` calls, and only `ColimaSpec` calls it. Define it as `isRight . validateProfileName` (or
  delete it with its export), and add a `ColimaSpec` case: `deriveColimaNames "default" "production" ...`
  returns `Left (Conflict detail)`, the exact `ConflictDetail "colima profile identity" "a project-specific
  profile" "default" "the shared default Colima profile is never project authority"`.
- `ColimaSpec` case: two namespace keys forced to share one short profile in one plan root (same state root
  and profile, different lineage) make the second `acquireManagedColimaProfileWith` refuse with the lineage
  conflict and leave the first record untouched.

### Sprint 16.28: Exact plan-owned direct-Colima preparation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/resource_budgeting.md`

#### Objective

Prepare one exact Colima start from the plan-owned provider and inseparable budget/journal package.

#### Deliverables

- `PreparedColimaWallCall` consumes one `ProjectPlan`, matching provider resource and observed handle,
  `DerivedTopology`, validated budget/capability/wall/fit/partition/reservation, and current `PreparedGate`.
- Preparation creates the exact `PreparedProviderStart`, retaining its operation/preconditions pair and the
  journal-derived wall reservation fence in one opaque package.
- The call derives the profile, state root, origin path, owner seed, canonical root/data argv, and acquisition
  invocation digest. That digest binds the plan, gate, wall, and mutation inputs; the execution-bound owner
  separately binds the closed namespace and complete trusted-toolchain fingerprint, and the durable record and
  settlement jointly validate both values.
- No compatibility lifecycle plan, binary context, caller profile/root/envelope, independent reservation, or
  mutable argv enters the package.
- Public projections reveal only non-authorizing profile/diagnostic views; mutation arguments and constructors
  remain sealed.

#### Validation

`ColimaSpec` covers exact package construction, call digest and argv binding, cross-plan/gate/refusal cases,
and prepared-start lineage. Compile-fail fixtures reject cross-plan consumers, construction, role coercion,
and mutation-argument projection.

#### Remaining Work

None. The adapter is a library boundary: no recursive Production route and no demo call site consumes it,
and no sprint schedules one, because the worked demo's Apple Silicon path provisions through Lima. Its live
confirmation is the Apple-Silicon phase's direct-Colima lane.

### Sprint 16.29: Closed resolver/backend adoption [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Install.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportColimaBackendRunner.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Resolve and retain the sole private execution namespace used by every exact Colima effect.

#### Deliverables

- Public acquisition, live Docker, and cleanup accept no `HostConfig`, executable, interpreter, environment,
  current directory, or executor; only the private trusted resolver can supply them. The driver module
  `HostBootstrap.Ensure.Colima.Ownership`, whose entry points take a caller interpreter or `HostConfig` and
  caller strings, lives in a `visibility: private` sublibrary that the public library and the test suite
  depend on, so `HostBootstrap.Ensure.Colima` is the only public route to a Colima effect.
- Fresh Apple detection, effective passwd home, trusted toolchain resolution, optional bounded install, and
  full rediscovery occur before an owning backend exists.
- The private `Resolver.Install` kernel orders retained Brew revalidation, the bounded fixed Brew invocation,
  and a fresh complete resolver pass. Its structured result distinguishes changed Brew, install exit,
  timeout, execution failure, still-missing Colima, resolver refusal, and a newly ready toolchain; the public
  adapter cannot reorder or bypass those steps.
- The retained backend fixes Colima, Docker, Lima, closed helper `PATH`, short Colima namespace, isolated
  Docker config, working directory, and one complete toolchain fingerprint. It binds no Python; the
  `ownershipPythonPath` field it still carries is removed by Sprint 16.49.
- The owner token and invocation namespace bind those exact paths and fingerprints; revalidation occurs around
  every acquisition, live, and cleanup effect.
- Unsupported substrate, long namespace, resolver/install failure, or tool drift yields no owning observation.

#### Validation

`ColimaSpec` covers trusted ready/install routes, install revalidation/failure/timeout/still-missing branches,
fresh rediscovery, hostile ambient home/path/working directory, and helper-directory fingerprint drift. The
private-backend import fixture and `ImportColimaResolverInstall.hs` remain named compile failures. No static
case drives the public `runPreparedColimaWallCall`, `settleColimaWallCall`, `runLiveColimaDocker`, or
`runColimaCleanup` chain: it needs a real Apple toolchain, and its live confirmation is the Apple-Silicon
phase's (the opt-in `HOSTBOOTSTRAP_COLIMA_LIVE=1` lane). Closing this sprint requires the module move and the
compile-fail fixture below, passing under `cd core && cabal test all`.

#### Remaining Work

- Move `HostBootstrap.Ensure.Colima.Ownership` out of the public library's `exposed-modules` into a new
  `visibility: private` sublibrary (with the `HostBootstrap.Effect.*` and `HostConfig` modules it needs
  reachable from there), depended on by the public library and `hostbootstrap-core-test`; delete the
  `HostConfig`-taking variants `startPreparedColimaProfile`, `observeColimaArtifacts`,
  `acquireManagedColimaProfile`, `cleanupManagedColimaProfile`, `runManagedColimaDocker`, and
  `observeColimaProfiles`, leaving only the interpreter-taking (`With`) forms the adapter and `ColimaSpec`
  use.
- Add compile-fail fixture `ImportColimaOwnership.hs`, registered in `CompileFailSpec`, that imports
  `HostBootstrap.Ensure.Colima.Ownership` and calls `runManagedColimaDockerWith` and
  `cleanupManagedColimaProfileWith` with a caller interpreter; it must fail to compile against the public
  library.

### Sprint 16.30: Clause-holding direct-Colima acquisition [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Execute one prepared Colima call and retain only the exact closed-backend ownership result.

#### Deliverables

- The adapter (`runPreparedColimaWallCall`) derives the expected CPU, memory, root-disk, and data-disk wall
  from the immutable prepared argv and runs `acquireManagedColimaProfileWith` with the closed-namespace
  interpreter.
- It revalidates the trusted toolchain before and after the backend call and rejects any changed execution
  route.
- An owned observation retains the exact invocation, namespace, profile, state/record/lock, machine/context,
  directory-chain, artifact, and root/data wall identities plus the opaque backend result.
- Unowned foreign/conflict/unsupported/failure outcomes remain descriptive and cannot enter settlement.
- Start failure, timeout, malformed output, identity drift, uncertain recovery, or backend mismatch mints no
  provider or wall authority.

#### Validation

`ColimaSpec` covers raw Colima JSONL as plan-independent data and the driver's applied/exact results.
Compile-fail guards reject raw-observation authority paths. Tool drift at the adapter needs a real Apple
toolchain and is confirmed by the Apple-Silicon phase's live lane; a malformed wall argv cannot be built,
because the prepared call is sealed. Closing this sprint requires the cases below, passing under
`cd core && cabal test all`.

#### Remaining Work

- Factor the `Left` arms of `acquireObservation` (`src/HostBootstrap/Ensure/Colima.hs`) into a pure
  `ColimaProfileMutationFault -> WallAcquireObservation` function in the private sublibrary of Sprint 16.29.
  `ColimaMutationOwnershipRefused` (an unowned or mismatched origin record) maps to `WallRefused` with a
  `ConflictDetail`, as `cleanupMutationError` already classifies it, instead of falling through to a
  retryable `WallAcquireFailed`. `ColimaSpec` cases: `ColimaMutationProfileConflict` and
  `ColimaMutationOwnershipRefused` map to `WallRefused`; `ColimaMutationStartFailed`,
  `ColimaMutationReportRefused`, and `ColimaMutationCommandUnavailable` map to `WallAcquireFailed` with
  `ReprobeBeforeRetry`.
- Delete `classifyColimaWall` and `ColimaWallDecision` (`src/HostBootstrap/Ensure/Colima.hs`) and their
  public exports: the driver never calls them, and they ignore ownership and the root disk. Delete the two
  `ColimaSpec` cases that drive them ("absent, exact-running, and exact-stopped observations classify before
  mutation" and "an incompatible same-name profile is refused as data"). `renderExpected` stays, because the
  acquisition conflict renders the complete wall through it.

### Sprint 16.31: Backend-produced provider-start and wall settlement [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Settlement/Internal.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Settle the generic provider start and provider wall inseparably from one exact successful backend invocation.

#### Deliverables

- The unexposed owning bridge (`withColimaWallSettlement`) is the only code that can inspect
  `ColimaWallSettlementApplied`/`ColimaWallSettlementAlreadyExact`, which `runPreparedColimaWallCall` builds
  from the driver's `ColimaManagedApplied`/`ColimaManagedAlreadyExact`, project the exact prepared
  provider-start journal pair, and invoke the provider-neutral permit mint.
- `settleColimaWallCall` checks the owned observation's state root, namespace key, record path, Docker config,
  bound owner, and invocation digest (which carries the gate's operation, session, attempt, and journal
  version) against the prepared call before producing authority.
- Applied maps to generic provider `Created`; exact replay maps to `Repaired`; both preserve the original
  observed provider generation and return its exact managed `Running` handle and receipt.
- `LiveColimaWall` is produced only after both wall and provider-start settlement succeed and retains their
  change views plus all backend identity needed by live and cleanup.
- Foreign, conflict, unsupported, failed, cross-call, or replay-mismatched results cannot settle either side.

#### Validation

Named compile-fail fixtures reject both hidden bridges, start/permit construction, old raw settlement, and
nominal role coercion. `settleColimaWallCall` runs only in the opt-in Apple lane. Closing this sprint
requires the static settlement cases below, passing under `cd core && cabal test all`; live confirmation
stays the Apple-Silicon phase's.

#### Remaining Work

- Move the `ColimaWallObservation`/`ColimaOwnedObservation` constructors and
  `HostBootstrap.Ensure.Colima.Settlement.Internal` into the private sublibrary of Sprint 16.29 (still absent
  from the public library; update `ImportColimaSettlementInternal.hs`'s expected message), and let
  `Resolver.Testing` return a fixture-resolved `TrustedAppleToolchain` from the native fixture layout.
- `ColimaSpec` settlement cases over `withPreparedTestCallForGateAndEnvelope`: an owned applied observation
  settles to a `LiveColimaWall` whose provider change is `Created`; an owned exact observation settles to
  `Repaired` at the same observed generation; an owned observation whose invocation digest comes from a gate
  differing only in session, attempt, or journal version, or whose state root, namespace key, or record path
  differs, is refused with the "outside the exact plan/fence namespace" `Failure`; unowned `WallRefused`
  settles to `Conflict`, `WallAcquireFailed` to `Failure`, and `ColimaWallOwnershipUnsupported` to
  `Unsupported`.

### Sprint 16.32: Settled live Colima Docker route [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/engineering/ensure_reconcilers.md`

#### Objective

Make the settled live wall the sole route to Docker in the exact Colima namespace.

#### Deliverables

- `runLiveColimaDocker` consumes only `LiveColimaWall`; it accepts no caller `HostConfig`, executable,
  environment, context root, or current directory.
- `runManagedColimaDockerWith` re-enters the same protected-store entry and revalidates the `Managed` stage,
  owner/lineage/invocation, machine binding, Docker context, complete manifest, and running profile on both
  sides of the Docker command; the adapter revalidates the toolchain before and after.
- Docker always names `colima-<profile>` under the retained isolated `DOCKER_CONFIG` through
  `routedDockerCommand`, which refuses arguments that override the route; it never relies on or mutates the
  process-global current context.
- A command the interpreter cannot complete (including the bounded runner's timeout) is
  `ColimaMutationCommandUnavailable`; it never becomes a completed run.
- A Docker command that ran is reported as having run. A failed post-call toolchain re-check is reported
  beside the captured run, never in place of it, so a caller can tell a command that never ran from one that
  ran with a given exit and must not be repeated.
- Neither the live wall's constructor nor an alternate raw Docker route is public.

#### Validation

`ColimaSpec` covers the exact routed argv and route-override refusal, refusal of manifest drift before any
Docker command, the routed command's output, and post-command identity refusal. Authority forge/coercion
fixtures pin the live wall's constructor. The raw-route half of the last deliverable holds once Sprint
16.29's module move and `ImportColimaOwnership.hs` land. Closing this sprint requires the cases below,
passing under `cd core && cabal test all`.

#### Remaining Work

- `ColimaSpec` case: `runManagedColimaDockerWith` whose interpreter answers the Docker command with
  `Left "native Colima command timed out"` returns `ColimaMutationCommandUnavailable` and leaves the stage
  record `ColimaManaged`.
- `ColimaSpec` case: `runManagedColimaDockerWith` with a different owner, lineage, or acquisition invocation
  than the `Managed` record refuses with "Docker route is not owned by this Managed lineage", and the
  interpreter never receives the routed Docker command; the same holds against a record at `ColimaReleased`
  after the value-driven cleanup.
- `runLiveColimaDocker` (`src/HostBootstrap/Ensure/Colima.hs`) replaces the captured result with
  `Left "live Docker toolchain changed after execution: ..."` when the post-call re-check fails. Return a
  result type that distinguishes a command that never ran (`Left` reason) from one that ran, carrying the
  `CapturedRun` and an optional post-call re-check failure, built by a pure function of (the driver's answer,
  the re-check's answer). `ColimaSpec` cases over that function: a completed run with a failed re-check keeps
  the exit code and output and carries the re-check reason; a driver refusal with any re-check is the
  not-run answer.

### Sprint 16.33: Provider force-destroy transition [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Represent `colima delete --force --data` as its real provider-only `Running` to `Destroyed` transition.

#### Deliverables

- `planProviderForceDestroy` accepts only the exact managed `Running` provider handle and names the explicit
  `destroyed-force` successor; it is not mislabeled as an ordinary stop.
- `plannedProjectPhaseOperation` binds the transition to the matching project plan, planned provider,
  ownership receipt, current generation, and cleanup call digest.
- The generic phase-transition preparation/completion kernel retains the exact source receipt and can advance
  only the prepared target phase.
- No `Observed` to `Provisioned` acquisition descriptor is reused to authorize deletion.

#### Validation

`ReconcileSpec` covers journal-prepared provider `Running` to `Destroyed`, completion at the retained
generation, and refusal of a wrong observed generation, empty call digest, replacement receipt, or wrong
resource/phase. Compile-fail fixtures reject forged or cross-phase advances.

#### Remaining Work

None.

### Sprint 16.34: Exact Colima cleanup authority [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Derive deletion authority only from the exact settled live wall and its managed provider receipt.

#### Deliverables

- `ColimaCleanupAuthority` has no public constructor and is produced only by eliminating an exact
  `LiveColimaWall`.
- It retains the profile, the `ColimaOwnedObservation` (toolchain, namespace key and paths, state root,
  record path, owner, lineage, machine identity, context digest, expected wall, acquisition invocation), the
  wall epoch, the managed `Running` provider handle and receipt, and the reservation fence. Lock, record, and
  manifest identities are not retained; cleanup re-checks them against the protected-store records at effect
  time.
- A descriptive profile observation, prepared acquisition, generic managed provider, or caller-supplied
  handle/receipt cannot mint cleanup authority, and no public route deletes the profile without it.
- Nominal roles prevent cross-plan, profile, provider, epoch, or fence relabelling.

#### Validation

Constructor, role, generic-handle, and cross-plan compile-fail fixtures pin the authority's construction.
`withColimaCleanupAuthority` runs only in the opt-in Apple lane. The "no public route deletes the
profile" half holds once Sprint 16.29's module move and `ImportColimaOwnership.hs` land. Closing this sprint
requires the case below, passing under `cd core && cabal test all`.

#### Remaining Work

- `ColimaSpec` case: `cleanupManagedColimaProfileWith` with an owner, lineage, or acquisition invocation
  differing from the `Managed` record refuses with "managed stage belongs to another lineage", leaves the
  record at `ColimaManaged`, and the interpreter never receives the delete command.

### Sprint 16.35: Journal-prepared Colima cleanup call [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Prepare deletion under a distinct current teardown gate that cannot replay acquisition authority.

#### Deliverables

- `prepareColimaCleanupCall` consumes the exact plan/planned provider, current cleanup `PreparedGate`, and
  retained `ColimaCleanupAuthority`.
- The gate fence must match the live wall, while operation, session, attempt, and journal version are the
  teardown's own current values rather than acquisition's values.
- Preparation builds the exact provider force-destroy descriptor, zero-dependency preconditions, and opaque
  `PreparedPhaseTransition Running Destroyed`.
- `colimaCleanupCallDigest` binds the profile, owner token, lineage, machine identity, context digest, wall
  epoch, managed resource generation, receipt operation key, and fence; the namespace key enters through the
  lineage and the toolchain fingerprint and namespace paths through the owner token. The cleanup invocation
  digest adds the teardown gate's plan, operation, and fence, which stay the same across retries of one
  journalled teardown operation, so a retry under a new session, attempt, or journal version resumes the same
  durably bound release instead of being refused as another invocation. Record, lock, and manifest identities
  are re-checked against the protected store at effect time rather than hashed.
- A second gate, plan, provider, receipt, call digest, or acquisition package cannot enter the call.

#### Validation

Constructor, role, cross-gate (`ColimaAcquireCallAsCleanupGate.hs`), and cross-phase
(`WrongColimaCleanupPhase.hs`) fixtures retain the opaque boundary. `prepareColimaCleanupCall` runs only
in the opt-in Apple lane. Closing this sprint requires the cases below, passing under
`cd core && cabal test all`.

#### Remaining Work

- `ColimaSpec` cases over the static `LiveColimaWall` of Sprint 16.31's settlement cases:
  `prepareColimaCleanupCall` with a teardown gate at the live wall's fence succeeds; a gate at another fence
  returns the "cleanup gate fence" `Conflict`.
- `colimaCleanupInvocationDigest` (`src/HostBootstrap/Ensure/Colima.hs`) hashes the gate's session, attempt,
  and journal version, so a retry of a committed release under a new gate is refused by the driver's
  invocation fence. Hash the call digest with the gate's plan, operation, and fence only. `ColimaSpec` cases:
  two teardown gates differing only in session, attempt, or journal version yield the same cleanup invocation
  digest; gates differing in operation or fence yield different ones.

### Sprint 16.36: Conditional direct-Colima cleanup backend [Active]

**Status**: Active
**Implementation**:
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Execute conditional release inside the driver without exposing a deletion interpreter or successful result
constructor.

#### Deliverables

- `cleanupManagedColimaProfileWith` takes the state root, profile, owner, lineage, acquisition invocation,
  cleanup invocation, home, Docker config, and data-disk path, and enters the existing protected-store entry,
  holding it through every check and effect.
- Before `colima delete --force --data`, it requires the same owner/lineage/acquisition invocation, revalidates
  the complete manifest, requires the profile listed exactly once, and re-observes the machine identity and the
  data disk's kernel identity against their bound origin records.
- The releasing record durably binds the cleanup invocation before mutation; only that same invocation may
  resume an interrupted delete, context release, namespace removal, or origin release.
- Delete is bounded and followed by a strict profile-absence readback and the data disk's kernel observation;
  failure, uncertainty, or replacement leaves foreign state and origin intact.
- Owned context, Docker config, Colima/Lima/cache/temp/data artifacts, manifest, and origin records are
  released identity-conditionally, and empty Colima scaffolding is pruned.
- Acquisition and cleanup share the protected-store entry, so no cooperating reacquisition enters the release
  interval.
- The result is `Either ColimaProfileMutationFault ()`: a fresh deletion and an exact `ColimaReleased` replay
  under the same cleanup invocation are both `Right ()`; the `ColimaReleased` stage record distinguishes them.
  Malformed, decorated, truncated, or stderr-bearing reports are `ColimaMutationReportRefused`.

#### Validation

`ColimaSpec` covers one value-driven cleanup from `Managed` to `ColimaReleased` with the home and Docker
config removed and the profile and disk records forgotten. The live delete runs in the opt-in Apple lane.
Closing this sprint requires the scripted-interpreter cases below over `cleanupManagedColimaProfileWith`,
passing under `cd core && cabal test all`.

#### Remaining Work

- Delete failure: an interpreter whose delete exits non-zero returns `ColimaMutationDeleteFailed` with the
  stage at `ColimaReleasing` and both origin records retained; a second cleanup with the same cleanup
  invocation and a succeeding delete resumes to `ColimaReleased`.
- Identity change: an interpreter reporting a different machine identity before delete returns the "profile
  identity changed before delete" conflict and never receives the delete command.
- Resume fencing: against an interrupted `ColimaReleasing` record, a cleanup with a different cleanup
  invocation refuses and issues no command.
- Absence readback: an interpreter whose listing still names the profile after a successful delete returns
  the "profile remained present after delete" conflict and the stage stays `ColimaReleasing`.
- Context removal failure: an interpreter whose `docker context rm` exits non-zero leaves the stage before
  `ColimaContextReleased` and the Docker config in place.

### Sprint 16.37: Exact Colima cleanup execution and phase completion [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Adopt the private conditional cleanup result and advance the provider only after exact release succeeds.

#### Deliverables

- `runColimaCleanup` consumes only the opaque prepared cleanup call and freshly resolves the retained closed
  tool/namespace route; a caller cannot supply an executor, environment, handle, receipt, or backend result.
- Cleanup discovery never installs: a resolver answer of `TrustedResolverMissingColima` during cleanup is a
  typed refusal, and only acquisition may run the bounded Homebrew install.
- The adapter requires the freshly resolved route to equal the live wall's retained toolchain and namespace,
  builds the complete private request, and revalidates the toolchain after the backend returns.
- A `Right ()` from `cleanupManagedColimaProfileWith` (a fresh deletion or the exact `ColimaReleased` replay)
  completes the retained prepared `Running` to `Destroyed` phase transition at the original managed resource
  generation; a post-call toolchain re-check failure after a committed release is reported beside that
  completion rather than withholding it.
- Conflict, unsupported, malformed, timeout, or failure before the release commits returns a typed error and
  yields no `PhaseAdvance`.
- The public surface exposes neither the private cleanup request/result constructors nor a unit-returning
  deletion route that could bypass typed phase completion. Today `cleanupManagedColimaProfile` and
  `cleanupManagedColimaProfileWith` are exported from the public `HostBootstrap.Ensure.Colima.Ownership`;
  moving that module into a private sublibrary is Sprint 16.29's owed work, and this deliverable holds
  only once it lands.

#### Validation

`runColimaCleanup` resolves a real Apple toolchain, so no static case runs it; it runs only in the opt-in
`HOSTBOOTSTRAP_COLIMA_LIVE=1` lane, and its live confirmation is the
[Apple-Silicon-substrate phase](phase-26-apple-silicon-substrate.md)'s. The static evidence is the driver's
scripted-interpreter cases (Sprints 16.24 and 16.36: failed-delete resume, changed-invocation refusal, and the
`ColimaReleased` replay), the pure completion and install-policy functions below, and the compile-fail fixtures
that reject cleanup construction, backend import, and forged or cross-phase advances. Closing this sprint
requires the cases in Remaining Work and Sprint 16.29's `ImportColimaOwnership.hs` fixture, all passing under
`cd core && cabal test all`.

#### Remaining Work

- `runColimaCleanup` (`src/HostBootstrap/Ensure/Colima.hs`) withholds `completePreparedPhaseTransition` when
  `revalidateOwnershipBackend` fails after `cleanupManagedColimaProfileWith` returned `Right ()`. Factor the
  completion into a pure function of (the driver's `Either ColimaProfileMutationFault ()`, the post-call
  re-check's `Either ReconcileError ()`) returning whether to complete the transition and any re-check
  diagnostic: a driver `Right ()` completes regardless of the re-check, which is reported beside the
  `PhaseAdvance`; a driver `Left` completes nothing. `ColimaSpec` cases over that function cover the four
  combinations. A retry of a committed release under a new teardown gate reaches the driver's `ColimaReleased`
  replay through the retry-stable cleanup invocation Sprint 16.35 owes.
- Give cleanup a non-installing discovery: `discoverDirectColimaBackendAt` takes an install policy, and
  `runColimaCleanup` (and `runLiveColimaDocker`) pass the policy that maps `TrustedResolverMissingColima` to a
  `Failure` (`ReprobeBeforeRetry`) instead of calling `installAndRediscover`. Make that mapping a pure
  function of (install policy, `TrustedResolverResult`); `ColimaSpec` cases: under the cleanup policy a
  `TrustedResolverMissingColima` result is that `Failure`, and under the acquisition policy it is the install
  branch.

### Sprint 16.38: Independent Linux cluster gate [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/app/Main.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Expose the independent bounded cluster acceptance case through the binary's fixed test command.

#### Deliverables

- `hostbootstrap test run cluster-live` owns one isolated Harness plan and resolves Docker, Kind, and
  kubectl before resource creation.
- The plan prepares creation, readiness, cordoning, and exact reverse cleanup through the shared cluster
  backend (`HostBootstrap.Cluster.Backend` over `HostBootstrap.Cluster.Ownership`), with its bounded process
  and polling policies. The case does not call the `HostBootstrap.Cluster.Lifecycle` drivers
  `clusterCreate`/`clusterDelete`, which run every tool through the unbounded `runTool`, issue
  `kind create cluster` without `--wait`, export into the operator's shared kubeconfig, and apply no wall on a
  non-Linux outer host.
- The assertion observes the Kubernetes client/server versions and runtime-selected loopback publications.
  It supplies no host port number and proves both exact relay containers absent after release.
- The exact reverse proves labelled-node absence and re-reads the durable sentinel outside cluster state.
- `EffectSpec` requires the repository's non-ignored source tree to contain no shell, PowerShell, batch,
  or command script. The operator reaches the gate through the same five-verb command tree as other work.

#### Validation

`EffectSpec` checks the script-free tree. The phase-level composed baseline acceptance below records the
binary's cluster lifecycle and absence/readback assertions, but every recorded run went through the legacy
`clusterCreate`/`clusterDelete` route rather than the owned cluster transaction. Closing this sprint requires
the source-guard case below under `cd core && cabal test all` and a fresh `hostbootstrap test run cluster-live`
on linux-cpu through the backend route, recorded with the phase gate.

#### Remaining Work

- Rewrite `bareClusterStep`/`bareClusterAction` (`CLI/Bare.hs`) to bring the run-scoped cluster up through the
  plan-owned backend: `withExecutionOwnedCluster` over the step execution, `withPlanOwnedClusterConfig`,
  `discoverStrongClusterBackend`, `runClusterReconcileCall`, the applied cordon, and
  `runClusterReadinessCall`; the step's reverse is `releaseRetainedCluster` over the retained projection, not
  `clusterDelete`. Every command goes through the bounded cluster interpreter Sprint 16.40 owes.
- Delete the legacy cluster drivers that lose their only production caller: `clusterCreate`, `clusterDelete`,
  `clusterTeardown`, `createCluster`, `clusterHealthy`, and `applyLinuxCordon` in `Cluster/Lifecycle.hs`, with
  the `LifecycleSpec` cases that drive them (the `clusterHealthyFromProbe` group and the aggregate
  `clusterDelete` teardown case), keeping the pure `teardown` partition. A `ClusterBackendSpec` source-guard
  case asserts `CLI/Bare.hs` names neither `clusterCreate` nor `clusterDelete` and does name
  `runClusterReconcileCall` and `releaseRetainedCluster`.
- Delete the unexported, uncalled `_clusterUp` and `_clusterStatus` in `Cluster/Lifecycle.hs`, and
  `statusReport` with its `LifecycleSpec` case, since `_clusterStatus` is its only non-test consumer; the
  `clusterCreate` Haddock that names `clusterUp` goes with `clusterCreate`. The same source-guard case asserts
  `Cluster/Lifecycle.hs` defines neither `_clusterUp` nor `_clusterStatus`.

### Sprint 16.39: Cluster suite host neutrality [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`,
`documents/engineering/cluster_lifecycle.md`

#### Objective

Assert this phase's cluster preparation, settlement, and readiness boundary from every supported outer
host realization.

#### Deliverables

- Every host `HostConfig` tool table in the phase's suites uses native absolute paths. Pure projection
  cases use the fixture-path constructor from the
  [Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md); process cases use the running
  test executable as the cluster client.
- Process cases drive the shipped interpreter and real protected store. Their client reports describe
  observations for protocol and transaction tests; real Kind and Docker acceptance remains the live gate.
- In-container and in-cluster paths stay POSIX. A kubeconfig path inside a node container, a mounted
  durable root, the injected kind/runtime/kubectl triple, and a guest command name files on a different
  machine, and only the host side moves.
- Every `ClusterBackendSpec` and `ClusterReconcileSpec` case runs on every gate host. Guest path
  descriptors remain POSIX while real fixture files use the native filesystem grammar. A Linux-frame
  descriptor does not make a pure admission or local protocol case conditional on Linux (§§ JJ/MM).
- The work is test-harness only: no production module, no named type, and no change to any cluster
  contract the phase already states.

#### The frame a cluster spec belongs to

A `ClusterSpec`'s state directory is the path the locked ownership program receives *inside* the realized
Linux substrate, which is why its absoluteness check is POSIX and why the production resolved backend is
itself Linux-only. When the cluster step runs, the machine the binary calls "host" is that Linux frame,
so the host `</>` that derives the directory from the canonical project root and the POSIX check that
admits it agree.

On Windows, the fixture keeps that descriptor separate from the native directory used for its real
protected store. The test client implements the protocol locally; the live command establishes WSL2 and
re-enters the binary there before cluster work. Local protocol coverage and Linux substrate acceptance
therefore have distinct gates without silently omitting static cases.

#### Validation

`cabal test all --ghc-options=-Werror` from `core/`, run host-native and recorded against the outer host
that ran it (§ II), on a POSIX outer host and on Windows. The phase's existing static evidence below
records the POSIX side. The separate live cluster gate runs `hostbootstrap test run cluster-live` inside the realized Linux
substrate; its route through the cluster backend and that backend's bounded execution are Sprints 16.38 and
16.40.

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal test all --ghc-options=-Werror` from `core/` host-native at 1,877/1,877 in 211.76 seconds.
That historical total predates the shared native client fixture. Current cross-host evidence and fixed
case-family accounting are recorded by the
[host-portability acceptance phase](phase-29-host-portability-acceptance.md).

#### Remaining Work

None.

### Sprint 16.40: The read-only cluster status is a decision [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

The cluster's read-only status observation as one bounded run and one total function.

#### Objective boundary

This sprint takes the smallest of the phase's four interpreter programs, and takes it on its own because
§ G's budget makes a sprint one contract. It changes nothing about *what* the status path asks — the
driver's own listing, exactly as before — and nothing about the clause-holding driver beside it, which is
the next sprint's whole subject.

#### Deliverables

- The read-only status path issues the driver's own listing as an argument vector this module owns, so no
  program is shipped to an interpreter for it (§ KK). It and every other cluster command (the
  `interpret` used by `HostBootstrap.Cluster.Ownership`) run under a finite per-command deadline with
  process-group reaping; today they run through `interpretHostCommand`, whose `runCaptured` is an untimed
  `readProcessWithExitCode`, so a hung `kind` or `docker` blocks the path indefinitely.
- What the listing means is `classifyClusterStatus`, a total function of the runner's own outcome:
  exported, so what a suite covers is the decision rather than an arrangement that produces its input. It
  maps the answer of Sprint 16.42's `classifyClusterListing` onto the status observation, so the status path
  and the clause-holding driver share one listing classifier.
- The refusals are `classifyClusterListing`'s. A non-zero exit, anything on standard error, a body
  that does not end in exactly one newline, a carriage return, a byte outside ASCII, a name outside the
  portable alphabet, and a repeated name are each the driver contradicting itself — and each is a refusal
  rather than an absence, because absence authorizes creation and a refusal must not.

#### Validation

Every refusal and both admissions are reached by application over values, so none of them needs a process
arranged to produce the shape it is about and none can pass against a stand-in for one (§ NN). The two
cases whose subject is the effect — that the path creates nothing and that a failing driver is not read as
absence — keep driving a real program. Because the decision is now a function rather than a program's
output, its family runs on every gate host instead of only the POSIX ones (§ JJ).

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,227/2,227 in 310.17 seconds; the same host
passed `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
at 231. § II makes this a gate-host record: this host does not run the phase's POSIX cluster family, whose
host-portability the next sprint's driver is what removes.

Closing this sprint requires the bounded-interpreter cases in Remaining Work, passing under
`cd core && cabal test all`.

#### Remaining Work

- Add one bounded cluster interpreter beside `interpretHostCommand`: it resolves the `HostCommand` through
  `resolveLaunch` and runs it with `runBoundedGroupedWithInput` under a `RunBounds` chosen by a total function
  of the command (the creation command's deadline exceeds its rendered `--wait 10m`; every listing, inspect,
  update, delete, and API query carries a short finite deadline), mapping a timeout to a named
  `ClusterOwnershipReport` fault rather than to absence. `Ownership.interpret` and `runClusterStatusCall` use
  it. `ClusterBackendSpec` case: a `FakeCluster` arm that makes `kind get clusters` sleep past its deadline
  makes `runClusterStatusCall` return the probe-failure observation within the bound, never an absence, and
  leaves no child process behind. `ClusterCommandSpec` case pins the deadline function's value for the
  creation command and one listing command.
- The `ClusterBackendSpec` case "the read-only status path asks the driver and decides from the bytes"
  discards the reconcile result between its two status calls and never checks that the status calls change
  nothing. Assert the reconcile result is the created observation, and assert that
  `FakeCluster.recordedClusterMutations` and the records under the state directory (`recordsUnder`) are the
  same before and after each `runClusterStatusCall`.

### Sprint 16.41: The described cluster commands [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Report.hs`,
`core/hostbootstrap-core/test/ClusterCommandSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Every cluster effect as a value in the one closed effect vocabulary.

#### Objective boundary

This sprint renders the argument vectors and nothing else. What an answer *means* is Sprint 16.42's, where
a transaction *stands* is Sprint 16.43's, and which clauses are held around them is Sprint 16.44's. The
split is § G's budget: a module that both rendered a vector and decided what came back would be one sprint
carrying two contracts, and the rendering is exactly the half a suite can compare by application.

#### Deliverables

- `HostBootstrap.Cluster.Command` renders every cluster effect as a `HostCommand`: the driver's listing,
  kubeconfig read, creation, and removal; the container runtime's node listing, identity readback, run-state
  readback, and cordon application; and the API server's readiness and node queries.
- Three roles answer, and which one a question belongs to is a property of the question. The driver owns
  the cluster as a named object, the container runtime owns the node containers clause 3's identity comes
  from, and the API server owns a readiness view that is not an ownership fact at all. `clusterCommandTools`
  declares the four tools that realize them: `Kind` and `Nvkind` for the driver (an nvkind creation targets
  `Nvkind`, every other driver command `Kind`), `Docker` for the runtime, and `Kubectl` for the API server.
- A node container is matched on its exact whole name, anchored on both ends and untruncated, because a
  substring match makes "which container is this node" depend on what else exists and a shortened
  identifier is a prefix rather than an identity. Docker evaluates the `name` filter as a regular
  expression, so the name is escaped before it is anchored: a `.` the cluster-name alphabet admits matches
  only itself.
- A cordon addresses the container identity the durable record bound rather than the node's name, which is
  the distinction a replacement erases.
- The kubeconfig an API question needs travels on standard input and is named as `/dev/stdin`, so a live
  control-plane credential never appears in a process listing.
- Creation gives Kind one private, unique staging path on the platform-local filesystem. The command layer
  never asks Kind to write its initial credential through a provider-mounted durable path; the ownership
  driver alone decides when the exact credential is ready for durable publication.
- Creation carries a ten-minute driver-side readiness bound. That bound remains finite, but it covers the
  Apple/Lima cold-start path where a healthy control plane takes longer than five minutes to answer, which
  otherwise leaves the transaction in its created-unbound recovery standing.
- A failing Kind command keeps Kind's own diagnostic. Kind's global `--quiet` swaps in a no-op logger and
  discards its error stream, including the top-level error it logs on failure, so the mutating and
  diagnostic-bearing Kind commands (`create cluster`, `delete cluster`, `get kubeconfig`) carry no `--quiet`
  and their success is classified by exit status, as `classifyNvkindCreateReport` already does, with the
  first standard-error line kept on failure.

#### Validation

Every case is an equality between a rendered command and the vector it is supposed to be, which is only
possible because a renderer cannot run anything (§ NN). Three properties are asserted over the whole set
rather than case by case, because each is true of every command until one day it is not: every command
names one of the four tools `clusterCommandTools` declares, every command is interpreted by a process of the outer host, and the only
two commands carrying standard input are the two that must not put a credential in `argv`.

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,336/2,336 in 300.51 seconds, including the
eighteen cases of `ClusterCommandSpec`.

On 2026-08-26, Apple Silicon/macOS validation passed the focused described cluster-command gate at 19/19.
The cases pin the ten-minute readiness bound, private platform-local creation staging, and the exact command
vocabulary without granting the renderer publication authority.

Closing this sprint requires the cases in Remaining Work, passing under `cd core && cabal test all`.

#### Remaining Work

- Drop `--quiet` from `createClusterCommand`'s Kind arm, `deleteClusterCommand`, and
  `readKubeconfigCommand` (`Cluster/Command.hs`); keep it only on `listClustersCommand`, whose empty answer
  is otherwise a `No kind clusters found.` line on standard error. Classify the Kind create and delete
  reports by exit status (Kind's progress on standard error is not a refusal) and the kubeconfig read by exit
  status plus the strict body classifier, keeping the first standard-error line as the
  `ClusterCommandExited` diagnostic. Update the frozen vectors in `ClusterCommandSpec`.
- Make `FakeCluster` model real quiet mode: under `--quiet` its refusals write nothing to standard error.
  `ClusterOwnershipSpec` case: a create the driver refuses surfaces the fixture's own refusal line in the
  `ClusterCommandExited` fault, not "no diagnostic".
- `listNodeContainerCommand` (`Cluster/Command.hs`) escapes the node name through one shared regex quoter
  (every `.` becomes `\.`; the rest of the admitted alphabet carries no regex meaning) before anchoring it,
  and `FakeCluster`'s `stripAnchoredName` unescapes it. `ClusterCommandSpec` case:
  `listNodeContainerCommand "demo.v1-control-plane"` renders `name=^/demo\.v1-control-plane$`.
  `ClusterOwnershipSpec` case: with a dotted cluster name `demo.v1` and an unrelated container standing at
  `demo-v1-control-plane`, reconcile creates and binds the dotted cluster's own control plane.
- Rewrite the `readNodeContainerIdCommand` Haddock to say the inspection is addressed by the node's name, so
  the answer shows a container replaced at that name since the listing (as `observeOwnedNode` uses it), and
  rename its parameter from `container` to `nodeName`.

### Sprint 16.42: The cluster report classifiers [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Report.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterReportSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

What each answer means, as a total function of the bytes that came back.

#### Objective boundary

This sprint classifies answers and holds no clause. Where a transaction *stands* given those answers is
Sprint 16.43's, and which clauses are held around them is Sprint 16.44's.

#### Deliverables

- `HostBootstrap.Cluster.Report` carries one classifier per question Sprint 16.41 asks: the cluster
  listing, the container standing at a node's exact name, that container's own identifier read back, its
  run state, the kubeconfig body, the API server's readiness answer, and the node list it returns. The
  read-only status path's `classifyClusterStatus` (Sprint 16.40) maps `classifyClusterListing`'s answer, so
  the listing has one classifier.
- The framing refusals are one computation rather than one per caller: a non-zero exit, anything on
  standard error, a body that does not end in exactly one newline, a carriage return, a byte outside
  ASCII, an empty row, and a line past the admitted bound are each the answering tool contradicting
  itself. Empty output is an empty listing rather than a malformed one, because a tool that names nothing
  writes nothing.
- Telling "the tool says this is not here" apart from "the tool did not answer" is the classifier's whole
  job, because the first authorizes a mutation and the second must not.
- Two answers deliberately do not refuse, and they are the two that are facts about the cluster rather than
  about the tool. An API server that will not answer its readiness endpoint is `ApiNotReady`, because a
  control plane that has not come up is what a readiness poll is polling for, and that answer carries
  kubectl's first standard-error line so an exhausted poll names what kubectl said. A `kubectl` that never
  launched is not an API server answering, so it is the `ClusterCommandUnrun` refusal rather than
  `ApiNotReady`. A well-formed node list
  naming a different node set is `NodesUnexpected`, because it is a true statement about a cluster this run
  is not looking at yet. A malformed node document is still a refusal.
- The node list is held to the same framing as every other report (ASCII only, within a byte bound) before
  it is decoded, and the declared node set is compared as a set: the order the API server lists nodes in
  never decides readiness.

#### Validation

Every classification and every refusal is reached by application over values, so none needs a process
arranged to produce the shape it is about (§ NN). The forty-eight cases of `ClusterReportSpec` run and are
counted on every gate host, because a function applied to a value needs no POSIX (§ JJ).

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,336/2,336 in 300.51 seconds, including the
forty-eight cases of `ClusterReportSpec`.

Closing this sprint requires the cases in Remaining Work, passing under `cd core && cabal test all`.

#### Remaining Work

- The shared framing refusals in `reportLines` are tested directly rather than through
  `classifyClusterListing`, whose `safeClusterName` rejects the same inputs on its own. `ClusterReportSpec`
  cases replace the three `isLeft` listing cases: `classifyClusterReport clusterReportLineBound (answered "a\r\n")`
  is `Left (ClusterReportUnreadable "the cluster report carries a carriage return")`, `answered "a\xe9\n"` is
  `... "the cluster report carries a byte outside ASCII"`, and `answered "a\n\n"` is
  `... "the cluster report carries an empty row"`.
- `classifyApiReadiness` (`Cluster/Report.hs`) returns `Either ClusterReportFault ApiReadiness`: a `Left` from
  the runner (kubectl never launched) is `Left (ClusterCommandUnrun cause)`, and `ExitFailure` or a noisy
  success stays `ApiNotReady` carrying the first standard-error line. `observeOwnedClusterReadiness`
  (`Cluster/Ownership.hs`) maps the refusal to a `ClusterOwnershipReport` fault, which the readiness call
  reports as a failure instead of a not-ready poll. `ClusterReportSpec` cases: `Left "kubectl not found"` is
  `Left (ClusterCommandUnrun "kubectl not found")`; `ExitFailure 1` with `"Unauthorized\n"` on standard error
  is `ApiNotReady` carrying `"Unauthorized"`.
- `classifyApiNodes` (`Cluster/Report.hs`) skips the ASCII and size refusals `reportLines` and
  `classifyKubeconfig` apply, then decodes `LazyChar8.pack body`, which keeps only the low byte of each
  `Char`, so a node label with `é` decodes as invalid UTF-8 or as different text. Refuse a body that is not
  all ASCII or exceeds the report byte bound with `ClusterReportUnreadable`, before decoding. `ClusterReportSpec`
  cases: a node list carrying `"é"` in a label value is refused with that message; one carrying `"\x122"` is
  refused rather than decoded as a `"`.
- `nodeReadiness` compares `nub names /= nub declared` as ordered lists, so declared workers `x-worker2` ..
  `x-worker10` listed by the API server as `x-worker`, `x-worker10`, `x-worker2` are `NodesUnexpected` for ever.
  After the duplicate check, compare `sort names == sort declared`. `ClusterReportSpec` case: a Ready node list
  in lexicographic order over a declaration in numeric worker order is `NodesReady`.

### Sprint 16.43: The cluster resumption decisions [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Resume.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterResumeSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Where a cluster transaction stands, as a total function of three values.

#### Deliverables

- A closed standing vocabulary over the four prefixes of the one clause order: no record and nothing
  there, a record whose creating command has not taken effect, an object standing under this record with
  clause 3 unheld, and this record's own object with all three clauses held.
- **A cluster carries no claim, and the record's own existence is what stands in for one.** A provider
  stamps this run's owner tag onto the instance as it creates it; the cluster driver has nowhere to put
  such a tag, because what it creates is a name and a set of node containers and neither carries a byte
  this project chose. What answers instead is that a record is published only from `ClusterNothingDone` —
  the driver naming no cluster and the runtime naming no container — inside the store's exclusive entry, so
  a published record is proof that this transaction found the name free and took it. The record does not
  reserve the name in Kind's namespace, so a record must not outlive a create that did not take effect: when
  the driver refuses the create and the name re-observes absent, the unbound records are forgotten inside the
  same entry (Sprint 16.44). A process that dies between publication and the create's outcome leaves an
  unbound record, and the module states that this record adopts whatever cluster later stands at the name.
- The two authorities must **agree** for that to be a standing. A driver that names the cluster while the
  runtime names no container, and a container that outlives the cluster the driver names, are each one
  authority contradicting the other, and each is `ClusterOutcomeUnknown` or its bound-record equivalent
  rather than a state a clause could be held over.
- Identity closes the window in the other direction. Clause 3 binds the node container's own identifier, so
  a cluster deleted and recreated out of band under the same name presents a different identifier and is a
  replacement rather than the same object.
- `nodeStanding` is the same decision with the driver's answer removed, for a node that is an owned object
  *inside* the cluster rather than the cluster itself.
- The record's claim is part of the standing. A record is a `ReportedObject` carrying the claim minted from
  the plan's ownership identity, and a record carrying a different claim belongs to another plan generation:
  it is a conflict, never this run's `ClusterOwned`, so a plan whose configuration changed does not adopt and
  re-cordon the previous generation's cluster.

#### Validation

Every standing and every conflict is reached by application over values, including the outcome-unknown
window between the durable record and the identity binding — the one interval a live run cannot be steered
into (§ NN). The record values are built through the ownership vocabulary's own constructors, so no case
asserts about a record shape the store could never hold.

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,336/2,336 in 300.51 seconds, including the
twenty-six cases of `ClusterResumeSpec`.

Closing this sprint requires the claim cases in Remaining Work, passing under `cd core && cabal test all`.

#### Remaining Work

- `clusterStanding` and `nodeStanding` (`Cluster/Resume.hs`) take the expected `OwnerClaim`, and
  `claimedRecord` refuses a `ReportedObject` whose claim differs with a new `RecordClaimedByAnotherGeneration`
  conflict; `ownedClusterStanding` and `requireOwnedNode` (`Cluster/Ownership.hs`) pass
  `ownedClusterClaim owned`, and `releaseRetainedOwnedCluster` passes the claim it reads with
  `retainedClaim`. `ClusterResumeSpec` cases: a bound and an unbound record under another claim each yield
  that conflict. `ClusterOwnershipSpec` case: reconcile with one claim, then reconcile the same cluster name
  with a different claim, refuses and issues no `docker update`.
- Rewrite the `Cluster/Resume.hs` module Haddock paragraph "A cluster carries no claim, and the record is
  what stands in for one": it calls a `ClusterCreatedUnbound` standing this transaction's own half-made
  cluster, but an unbound record that outlived an interrupted create maps a later same-named cluster to the
  same standing. State the residual window as the deliverable does.

### Sprint 16.44: The owned cluster and its reconcile driver [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

The cluster as an owned object, and the one transaction that creates it.

#### Objective boundary

This sprint lands the object, its observation, and the create transaction. Readiness, cordon, and cleanup
are Sprint 16.45's — three transactions over the same object, and § G's budget makes them their own
session rather than a second contract inside this one.

#### Deliverables

- `OwnedCluster` is the cluster a transaction owns: its declared name, the control-plane node whose
  container carries clause 3's identity, every other declared node, the configuration snapshot where the
  plan declares one, the file this run has opened for the credential, and this run's own owner binding.
  `HostBootstrap.Cluster.Ownership` is reachable only from the cluster backend and the test suite, so no
  downstream component can build an `OwnedCluster` or call a clause-holding transaction without the managed
  handle, the prepared package, and the backend's exposure-record check.
- **Every node is an owned object.** Clause 3 binds exactly one identity per record, so the cluster's own
  record binds the control-plane container and each other node carries its own record beside it — exactly
  as a share is an object inside a provider instance. That is what lets a later cordon address a node by
  the identity this run bound rather than by the name a replacement inherits.
- **Every record is published before the creating command.** One `kind create cluster` brings every node
  container into existence at once, so there is no per-node moment at which a record could be written
  first; all of them are published over an explicit absence before the create runs and bound afterwards
  from what the runtime reports. Each publication is its own short-lived entry rather than a nest of them,
  because clause 2's publication is idempotent and re-entering to bind re-asserts the same fact. Workers bind
  before the control plane, so the cluster record's binding is the commit point: an interrupted bind leaves
  the cluster `ClusterCreatedUnbound` and the next entry resumes it, and an owned cluster beside an unbound
  worker record whose container stands binds that worker rather than refusing.
- The observation asks the node's name **twice** — once of the listing and once of the inspection — rather
  than asking the listing and then re-asking the identifier it produced. Addressing the second question by
  the identifier would confirm only that the identifier still resolves; asking the name is what makes a
  container replaced between the two answer differently.
- The cluster-creating effect between the published records and the bound identities travels as a
  described `HostCommand`, so the outcome-unknown window keeps its durable meaning and the driver keeps no
  way to run a string.
- A successful creation obtains the exact credential from Kind and atomically publishes it at the
  plan-owned durable kubeconfig path before any node identity is bound: the temporary file is synced before
  the rename and the parent directory after it, so a bound row never reaches disk ahead of its credential,
  and the already-owned path re-reads and re-publishes a missing or differing credential. A named publication failure retains
  the created-unbound standing; recovery from that standing repeats exact readback and publication before
  binding, without issuing a second create.
- Reconcile answers with three end states an operator can tell apart: a first creation, a resumed entry
  whose cluster already existed under this record, and an entry that found all clauses held. The
  already-owned path still re-observes every worker, because the cluster's own identity says nothing about
  the other nodes.
- `FakeCluster` is the driver, container runtime, and API server as real processes — this suite's own
  executable, entered by an environment variable held for exactly the span of a fixture and resolved under
  a separate file name per tool, so a command sent to the wrong tool is refused. A vector it does not
  recognize is a refusal rather than a silent success. Its answers are fixture-authored models of Kind,
  Docker, kubectl, and Helm: it proves sequencing, clause order, and the driver's handling of each modelled
  answer, while agreement with the real tools' output is the live gate's evidence, and its header says so.

#### Validation

Every decision is covered by application over values, and the clause-holding effects run against a real
protected store in a temporary directory and a real cluster client process, so no case reaches a
substitution point and none can pass against one (§ NN).

Three cases are the ones a fake could not have produced honestly. A client that really performs its create
and really dies before reporting it is recovered on the next entry **without creating again**, and the
mutation log proves the count. A cluster standing at the name under no record of this project's is refused
and leaves the mutation log empty. And a worker whose container is replaced under an otherwise owned
cluster is refused, which is the case the per-node records exist for.

The family runs and is counted on every gate host, because the client is this suite's own executable and
its durable state is ordinary files (§ JJ).

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,336/2,336 in 300.51 seconds, including the
fifteen cases of `ClusterOwnershipSpec`.

On 2026-08-26, macOS arm64 with GHC 9.12.4 and Cabal 3.16.1.0 passed the warning-clean focused
`ClusterOwnershipSpec` gate at 30/30 and `ClusterBackendSpec` at 34/34. The real-process fixture observed
exact durable credential bytes, publication before node binding, a named publication refusal, and recovery
that published and bound without issuing a second create. The complete warning-clean core gate passed all
2,464 tests in 387.72 seconds.

Closing this sprint requires the cases in Remaining Work, passing under `cd core && cabal test all`.

#### Remaining Work

- `bindNodeRecords` (`Cluster/Ownership.hs`) binds every worker before the control plane, and
  `requireOwnedWorkers`/`ownedClusterNodes` route a worker whose `nodeStanding` is `ClusterCreatedUnbound`
  under a `ClusterOwned` cluster through `bindOneNode` instead of `createLostItsNode`/`nodeNoLongerOwned`.
  `FakeCluster` gains an arm that fails the worker's identity readback once. `ClusterOwnershipSpec` cases on a
  two-node cluster: reconcile with that arm fails; the next reconcile binds the worker and returns
  `ClusterRecovered` with exactly one create in the mutation log; a cluster record bound beside an unbound
  worker record (reached through the same arm under the old order) is bound by reconcile and released by
  `releaseOwnedCluster`.
- Move `HostBootstrap.Cluster.Ownership` (with `Cluster.Command`, `Cluster.Report`, and `Cluster.Resume` if
  nothing public needs them) from the public library's `exposed-modules` into `other-modules` or a
  `visibility: private` sublibrary that `hostbootstrap-core-test` depends on. Compile-fail fixture
  `ImportClusterOwnership.hs`, registered in `CompileFailSpec`, imports it and calls `releaseOwnedCluster`
  from a downstream component and must fail to compile.
- Give each cluster tool its own executable in the fixture: `clusterHostConfig` (`ClusterBackendSpec`, and
  the fixture tables in `ClusterOwnershipSpec` and `ClusterReconcileSpec`) maps `Kind`, `Nvkind`, `Docker`,
  `Kubectl`, and `Helm` to copies or hard links of the test executable named `kind`, `nvkind`, `docker`,
  `kubectl`, and `helm`, and `FakeCluster.runFakeClusterClient` refuses a vector whose tool family differs
  from `takeBaseName <$> getExecutablePath`. `ClusterBackendSpec` case: a `HostConfig` that maps `Docker` to
  the `kubectl` copy makes the first exposure call fail with the fixture's wrong-tool refusal.
- Rewrite the `FakeCluster` module header: it is a sequencing fixture whose tool answers are authored here,
  not § NN evidence that the real tools answer this way; live agreement is the cluster live gate's.
- `atomicPublishKubeconfig` (`Cluster/Ownership.hs`) syncs the temporary file before `renameFile` and the
  parent directory after it, and the `ClusterAlreadyOwned` path re-reads the kubeconfig through the driver and
  re-publishes it when the durable file is missing or differs; correct the module header's claim that the
  module holds no durable byte of its own. `ClusterOwnershipSpec` case: after a first reconcile, delete the
  durable kubeconfig; the next reconcile answers `ClusterAlreadyOwned` and the file holds the fixture's bytes
  again, with one create in the mutation log.
- `ClusterOwnershipSpec` case "every fault renders through the one renderer" renders one value of every
  `ClusterOwnershipFault` constructor and asserts the delegation exactly:
  `clusterOwnershipFaultMessage (ClusterOwnershipReport f) == clusterReportFaultMessage f`, the `Standing`
  branch equals `clusterStandingConflictMessage`, and the `Kubeconfig` branch starts with
  `"cluster kubeconfig: "`.
- `createThenBind` (`Cluster/Ownership.hs`) returns the refused create's fault and leaves every published
  unbound record in place, so a later same-named cluster created outside the store is adopted as
  `ClusterCreatedUnbound` and then cordoned, deployed into, and deleted. When the create report is refused,
  re-observe the cluster and the control-plane node inside the same session; on (`ClusterAbsent`,
  `OriginAbsent`) forget the unbound worker and cluster records by compare-and-delete before returning the
  fault, and leave them when anything stands. `FakeCluster` gains an arm whose `kind create cluster` exits 1
  and creates nothing. `ClusterOwnershipSpec` case: reconcile under that arm fails with the create fault and
  `remainingRecords session == []`; a cluster then stood up at the name by `standUpCluster` is refused by the
  next reconcile with `ClusterUnderNoRecord` and no mutation.
- Observation and reconcile cases assert exact values: "a present node answers with the identity it reports
  for itself" asserts `Right (OriginPresent identity)` with `identity` the `mkObjectIdentity` of the planted
  64 `'a'` characters; the published kubeconfig is compared as bytes (`ByteString.readFile`) against
  `ByteStringChar8.pack (FakeCluster.fixtureKubeconfig clusterName)` in every case that reads it with `readFile'`;
  and "a cluster nothing claims is refused rather than adopted" asserts
  `outcome == Left (ClusterOwnershipStanding ClusterUnderNoRecord)`, `remainingRecords session == []`, and
  `FakeCluster.recordedKubeconfigPaths root == []`.

### Sprint 16.45: The readiness, cordon, and cleanup drivers [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Report.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/ClusterCommandSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

The remaining cluster operations on the same face.

#### Objective boundary

Three transactions over the object Sprint 16.44 landed, and nothing else. The interpreter program the
cluster backend still ships is Sprint 16.46's, and this sprint neither removes nor reaches it.

#### Deliverables

- **One re-entry step, used by all three.** Each transaction begins by asking the driver whether the
  cluster is still named and then asking the runtime about every declared node under that node's own
  record, answering with the keys as well as the identities. A transaction that goes on to forget records
  forgets exactly the ones it re-observed, rather than deriving them a second time and having two answers
  to which key a node's record is under.
- Readiness re-enters from the durable record, asks the API server through the kubeconfig the driver hands
  back, and answers with the total node-readiness classification. A node replaced while the probe ran is a
  conflict rather than a readiness. None of its four answers is a fault: a control plane that has not come
  up, a node that has not joined, and a node set the plan does not declare are three different true
  statements about a live cluster, and a poll that treated any of them as a refusal could not wait.
- Cordon applies each node's limits to the container identity the durable record bound rather than to the
  node's name, and re-observes every node on both sides of the application. The wall itself is the one
  budget renderer's value: the argv-shaped renderer is that list with the verb in front and the container
  behind it, so what a cluster budget caps is stated once and this driver only decides where it lands. What
  each node receives is its per-node share of the slice, which Sprint 16.9 owns and owes.
- Cleanup re-observes every owned node under the record, removes the cluster through the one interpreter,
  and forgets the records only over a reported absence. A same-named replacement is left standing, because
  clause 4 compares the identity rather than the name. Two standings short of ownership are releases rather
  than refusals — nothing at all is nothing to do, and a record published over a cluster that was never
  created is forgotten with no command issued — while a cluster created and never bound authorizes no
  removal at all, because no identity has been bound for clause 4 to compare.
- Cleanup resumes after its own delete. A bound record whose cluster is unlisted and whose node containers
  are all absent is the standing a delete leaves when anything between `kind delete` and the last forget
  fails or the process dies; release treats it as a removal to finish (forget the remaining worker records,
  then the cluster record through the tape), and refuses only when a different identity stands at a node's
  name. A delete the driver accepted while a bound node still stands retains every record
  (`ClusterStillPresent`).
- The tools the driver reaches come from the frame table, so a tool it drives and a row that holds its
  clauses are declared in one place. The declaration is exact in both directions: a tool named by a
  described command and missing from it, and a tool named in it that no command reaches, are each a
  failure rather than a silence.

#### Validation

Every conflict is reachable by application over values, and the clause-holding effects run against a real
protected store and a real cluster client process.

Three of the fifteen new cases are the ones a fake could not have produced honestly, and each is reached by
the client itself doing the thing rather than by a patch point (§ NN). A node replaced *while the readiness
probe ran* is reached by the API server putting a different container at the name after the node list it
answered — the window the transaction holds the store's exclusive entry across, which nothing outside it can
act inside. A node replaced *while the wall was applied* is reached the same way, after the first `update`
the runtime accepted. And a container that took a node's name *during the removal* is reached by the driver
performing the delete and the runtime then standing something else at the control plane's name; the case
asserts both that the replacement is left exactly as it was found and that no record was forgotten over it.

Two standings the earlier sprints could not reach are now reachable, and both by a client that really
refuses rather than by durable state written behind the driver's back: a create the driver refused without
performing leaves clause 2 durable and nothing else, which release forgets with no command issued; and a
create the client performed and then died reporting leaves a cluster created and never bound, which release
refuses.

Dated 2026-08-21 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,351/2,351 in 309.21 seconds, including the six
readiness, three cordon, and five release cases of `ClusterOwnershipSpec` and the exact tool declaration in
`ClusterCommandSpec`. The cordon wall case asserts `replicate (length held) declaredLimits`, the whole budget
on every node; its rewrite to per-node shares is Sprint 16.9's.

Closing this sprint requires the release cases in Remaining Work, passing under `cd core && cabal test all`.

#### Remaining Work

- `releaseOwnedCluster` and `releaseRetainedOwnedCluster` (`Cluster/Ownership.hs`) handle the post-delete
  standing instead of passing the fault through: when `ownedClusterStanding` yields `NodeVanished` (bound
  record, cluster unlisted, control plane absent), re-observe every declared node; if every node is absent,
  forget the worker records and then the cluster record through `releaseReportedObject` over `OriginAbsent`
  and return `ClusterReleased`; if a bound node still stands under its bound identity, re-issue
  `deleteClusterCommand`; a different identity at any node's name stays the `replacedUnderRelease` refusal.
  A vanished bound worker beside a present control plane is resumed the same way. `FakeCluster` gains an arm
  that performs `kind delete cluster` and then exits non-zero. `ClusterOwnershipSpec` cases: release with that
  arm fails; a second release returns `ClusterReleased`, forgets every record, and issues no second delete;
  a following reconcile creates afresh.
- `FakeCluster` gains `armDeleteNoop`, whose `kind delete cluster` exits 0 and removes no node container.
  `ClusterOwnershipSpec` case: `releaseOwnedCluster` returns `Right ClusterStillPresent` and the store's
  records are byte-identical before and after; `ClusterBackendSpec` case: `releaseRetainedCluster` under the
  same arm returns a `Failure` with `ReprobeBeforeRetry` and leaves the records in place.
- `forgetEveryRecord` (`Cluster/Ownership.hs`) forgets the worker records before the cluster's own record, as
  `removeOwnedCluster` does, and the `ClusterNothingDone` release branch forgets any worker record that still
  stands under the cluster's name before answering `ClusterAlreadyReleased`. `ClusterOwnershipSpec` case: a
  store holding only a worker record (cluster record already forgotten, nothing listed) is released to
  `ClusterAlreadyReleased` with the worker record gone, and a following reconcile under a new claim creates
  the cluster.
- Refusal cases for the retained release, which takes its claim from the stored record (`retainedClaim`):
  `ClusterOwnershipSpec` cases on `releaseRetainedOwnedCluster` — a created-but-unbound cluster is refused
  with the mutation log `["create"]`; a non-`ReportedObject` record published at the cluster key returns
  `Left (ClusterOwnershipClause (OwnershipMalformed _))` with no delete issued; a control-plane replacement
  (`FakeCluster.writeNodes`) is refused and the replacement stays listed. `ClusterBackendSpec` cases on
  `releaseRetainedCluster`: a plan with no nodes returns the `DoNotRetry` "declares no nodes" failure; a
  replaced control plane returns `Left (Failure _)` naming the replacement, the cluster stays listed, and the
  record is retained; an absent record returns `Left (Failure _)` carrying "the cluster ownership record is
  absent" with no delete in the mutation log.
- Pin the re-entry guard: the case "a cluster the driver no longer names cannot be re-entered" asserts
  `Left (ClusterOwnershipClause (OwnershipProbeFailed "re-enter the owned cluster" _))` instead of `isLeft`,
  and a sibling case runs `cordonOwnedCluster` on a cluster cleared from the listing and asserts the same
  refusal with no `update` in the mutation log.
- The refusal cases that run a setup `_ <- reconcileOwnedCluster ...` assert the setup outcome is
  `Right (ClusterCreated _)` before the step under test, and the two replacement cases ("a node replaced
  while the probe ran" and "a node replaced while the wall was applied") assert
  `Left (ClusterOwnershipStanding (NodeReplaced _ _))` instead of `isLeft`.
- The case "a replacement that took a node's name is left standing" asserts the exact record set after the
  refused release, the cluster key and `ownedNodeRecordKey owned worker`, instead of `not (null records)`.

### Sprint 16.46: The cluster's interpreter program is gone [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Observation/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

The cluster boundary carries no program written in another language.

#### Objective boundary

The cluster's own. The Colima programs are Sprint 16.47's and the guest alias program is the
[worked-demo phase](phase-24-worked-demo.md)'s, and neither is touched here.

#### Deliverables

- The cluster backend resolves no interpreter and no locking front end, because every clause it holds is
  the seam's and every effect it performs is a described command. The 646-line embedded program, the
  protocol its reports were parsed back out of, and the eight-field kernel-object binding those reports
  carried are all gone; a binding is now the one thing clause 3 binds, which is the container identity.
- **The backend is a join rather than a driver.** What is left is deriving the owned object from the
  prepared plan-owned package, opening the protected store under the plan's own state directory, taking the
  exclusive entry once per transaction, and mapping the driver's answer onto the observation the reconciler
  classifies. The four calls are one transaction shape with four continuations, so no operation can come to
  hold a different notion of what its exclusive entry is. `releaseRetainedCluster` is the one exception: the
  recursive reverse holds no backend, so it opens the store under the retained plan's state directory and
  takes `withProtectedEntry` itself. The already-owned reconcile answers its running
  check inside the same entry that observed the identity it reports, and readiness reports the identity the
  transaction re-observed rather than echoing the handle's.
- **A backend is a value the declaration decides**, exactly as the provider's is. Discovery takes the typed
  `HostConfig`, admits it when every tool the cluster's commands reach is resolved in it — the driver
  (`Kind`, and for an nvkind package `Nvkind` *and* `Kind`, because listing, kubeconfig readback, and
  deletion go through Kind), `Docker`, `Kubectl`, and `Helm` for the chart workload — and probes nothing:
  what a discovery once proved — a writable state directory, a locking front end, an interpreter — is the
  protected store's own to establish when the first transaction enters it.
- The private component's injected executor goes with it, and so does the component: a suite that wants the
  driver to have been answered a particular way supplies a program the one interpreter can launch, not a
  function it can call.
- **`ClusterUnhealthy` keeps a producer.** An owned cluster is asked one further question the creation path
  does not need — whether every node container the record bound is still running — because that is the
  container runtime's answer rather than the API server's, and an owned cluster whose containers are stopped
  is a conflict an operator resolves rather than something to recreate. `ownedClusterRunning` is that
  question, and it is what keeps the run-state command and its classifier from being a vocabulary nobody
  reaches.
- A source guard holds the absence, naming the [rationale](rationale.md) entry that says why a program in
  a string is refused.

#### Validation

The guard fires on a reintroduced program and stays quiet on the legitimate uses elsewhere in the tree. It
names the retired spellings exactly — the two host-tool constructors the program resolved, the one it
deliberately refused, the interpreter's own program flag, and the injected executor — and it asserts the
positive half too: a guard that only forbade the old names would stay quiet over a backend that had stopped
driving anything at all, so it also requires the described commands and the clause-holding driver to still
be reached. A second guard case requires the hidden capability module
`internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs` to exist as an `other-modules` member of
the main library and to name none of the forbidden spellings; no case checks that the Cabal file declares no
separate cluster-backend library.

The cluster family runs and is counted on every gate host now that the program only a POSIX host could
interpret is gone (§ JJ). Two consequences are worth stating. `ClusterBackendSpec`'s conditional row family
is deleted from `CoverageManifest` rather than shrunk, because its subject — a `flock(2)` namespace, an
inherited no-follow descriptor, and `/proc/self/fd` paths — no longer exists; and `ClusterReconcileSpec`'s
settlement, readiness, and cleanup cases are no longer compiled away on a Windows outer host, so the twelve
that a native Windows gate could not previously run now run there.

Every one of those cases reaches its standing by arranging what the tools report rather than by handing a
canned protocol line to an injected function (§ NN). A cluster nothing claims is a cluster the fixture's
runtime really holds; a driver contradicting its own listing really lists the same name twice; an owned
cluster that went unhealthy really has stopped containers; a replacement really takes a node's name between
two commands; and the standing an operator leaves by discarding this project's origin while its cluster
stays up is reached through the protected store's own compare-and-delete.

Dated 2026-08-21 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,328/2,328 in 318.16 seconds, and
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` passed at
231. The total is lower than the previous run's and that is the point: forty-six cases whose subject was the
retired program are gone, and twelve that a Windows gate host previously compiled away now run.

Closing this sprint requires the cases in Remaining Work, passing under `cd core && cabal test all`.

#### Remaining Work

- `discoverStrongClusterBackend` (`Cluster/Backend.hs`) requires `Kind` for every driver, adding `Nvkind`
  for an nvkind package, beside `Docker`, `Kubectl`, and `Helm`; the per-driver list is a function
  `clusterDriverTools :: ClusterDriver -> [HostTool]` beside `clusterCommandTools` in `Cluster/Command.hs`, and
  `ClusterCommandSpec` asserts every command a driver's transactions render names a tool in that list. Rewrite the `ClusterBackendSpec` case "nvkind discovery requires nvkind and
  does not fall back to Kind" to also assert that a configuration carrying Nvkind but no Kind is
  `Unsupported` with no backend minted.
- Make the tool declaration govern production: `discoverStrongClusterBackend` replaces its local
  `requiredTools` with `clusterDriverTools driver`, which includes `Helm` (invoked by the chart workload calls in
  `Cluster/Backend.hs`), so `clusterCommandTools` and discovery cannot disagree. `ClusterCommandSpec` builds its
  checked command set from a list `Cluster/Command.hs` exports rather than a hand-written one, and a
  `SourceGuard` case asserts every `hostCommand <Tool>` in `Cluster/*.hs`, including the inline Helm, Kubectl,
  and Docker commands of `Cluster/Backend.hs`, names a tool in `clusterDriverTools`.
- `clusterCallTarget` (`Cluster/Backend.hs`) derives every declared node's record key (`ownedNodeRecordKey`
  over `mkRecordKey`'s 200-character bound) and refuses before anything is opened when one does not fit.
  `ClusterBackendSpec` case: a 99-character cluster name with an nvkind worker
  (`<name>.<name>-worker`, 206 characters) is refused by `clusterCallTarget` with `DoNotRetry` and the
  state directory holds no record.
- The case "a driver that contradicts its own listing fails closed" (`ClusterReconcileSpec`) asserts the
  failure cause contains "the driver listed the same cluster more than once", that
  `FakeCluster.recordedKubeconfigPaths root == []` (no create attempted), and that the protected store under
  the prepared state directory holds no record; `settleContradictoryListing` returns the fixture root.
- The case "an unhealthy same-named cluster is a Conflict, never deleted" asserts, beside the `Conflict`,
  that `FakeCluster.recordedClusterMutations root == ["create"]` and `FakeCluster.readClusters root` still
  names the cluster; `settleUnhealthy` returns the fixture root. (Sprint 16.8 owns the conflict's remedy
  text; this bullet owns the mutation-log evidence.)
- `runClusterReconcileCall` answers `ClusterAlreadyOwned` inside one `withClusterTransaction`: the
  continuation runs `Owned.reconcileOwnedCluster` and, on `ClusterAlreadyOwned`, `Owned.ownedClusterRunning`
  under the same session. `ClusterBackendSpec` source-guard case: `runClusterReconcileCall` contains exactly
  one `withClusterTransaction`.
- `Owned.observeOwnedClusterReadiness` returns the control-plane identity it re-observed with its outcome, and
  `runClusterReadinessCall` stamps that identity, so `identity == expectedIdentity` compares two
  observations. `ClusterBackendSpec` case: release and recreate the cluster under a fresh record between the
  cordon and the readiness call; the readiness result is `ClusterNotReady` naming the new identity and the
  readiness counter does not advance.
- `ClusterBackendSpec` discovery and join cases prove what their names state. "a configuration carrying all
  three is admitted with no probe" and "a discovered Kind backend refuses an nvkind package before a command"
  run inside `withBackend` and assert `FakeCluster.recordedClusterMutations` is empty and no process
  invocation is logged across the call (or are renamed to drop the claim). "a fresh reconcile creates the
  plan's own cluster and binds its nodes" runs over a fixture that declares a worker and asserts both node
  records are bound, or is renamed to the control plane it binds.
- The positive source guard "the backend still reaches the described commands and the clause-holding
  driver" matches `HostBootstrap.Cluster.Ownership` anywhere in `Backend.hs`, which its module Haddock also
  names. Assert the import with `SourceGuard.importsModule`, which reads comment-stripped tokens. The case
  "the hidden backend component retains capability data and no injected executor" asserts the field types of
  the `StrongClusterBackend` constructor (no function-typed field) rather than the absence of five names.

### Sprint 16.47: The direct-Colima ownership driver [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/applied_cordon.md`

#### Objective

The six durable Colima stages as one Haskell state machine over the seam.

#### Deliverables

- Acquisition, cleanup, and live Docker hold their clauses through the seam, with the stage graph a pure
  total transition function (`decideColimaStage`) from state and observation to the next state or a typed
  refusal. The driver takes each stage step from it once Sprint 16.24's owed routing lands; today the driver
  decides inline beside it.
- Every durable stage is resumable from the state its own interruption leaves. Cleanup resumes from
  `ColimaReleasing` over an absent profile and from `ColimaContextReleased` without re-running the pre-delete
  checks or the delete; `ColimaReleased` is published only after the tmp, cache, and home directories are
  released and the manifest record is forgotten; a `Prepared` stage whose creation records are already bound
  re-enters them; and an origin record left unbound by an interrupted directory acquisition is resumed or
  forgotten rather than refused for ever.
- Live-Docker admission checks the stage and lineage before any effect, and re-enters the context directory
  without ever acquiring one. `Managed` settlement re-enters the context directory the same way and compares
  the data disk's bound identity with the identity the artifact observation read, so it never creates a
  context directory and never settles a disk replaced since binding.
- `ColimaStageRecord` and `ColimaManagedEvidence` are sealed: their producers are the only way to build or
  change one, so no caller can publish a stage record its own parser refuses.
- The bounded command the driver supervises is a transaction shipped to this machine, because its
  parent-death watch — the group kill that fires when the owning process disappears without running any
  handler — is not something the launcher's own bracket can promise.
- Every artifact identity, namespace binding, and directory-chain digest the stages record is expressed in
  the shared record vocabulary rather than a driver-local encoding.
- The tool candidates and their canonical bindings stay a fixed table in an unexposed component (§ K); the
  refactor changes what holds the clauses, not who may choose a candidate.

#### Validation

The stage graph, the argument vectors, and the classification of each tool result are pure and are covered
by application over values, so the suite needs no stand-in executable on `PATH` to reach them (§ NN). The
clause-holding effects run against the real kernel, which the static gate reaches on any POSIX gate host.
Live confirmation against real Colima is the
[Apple-Silicon-substrate phase](phase-26-apple-silicon-substrate.md)'s, which lists it among what it confirms.
Crash windows are covered by re-entry cases that start from the durable stage record an interruption leaves;
the shipped request carries no crash-point field and no fault-injection argument exists. Closing this sprint
requires the resumption, admission, and sealing cases in Remaining Work, passing under
`cd core && cabal test all`.

The focused `ColimaSpec` gate passed 51/51 on 2026-08-21 (x86_64-linux, GHC 9.12.4, Cabal
3.16.1.0) in 80.56 seconds. It covers the closed durable-stage vocabulary, canonical parser/renderer,
idempotent re-entry, every adjacent transition, and refusals for skipped, reversed, and cross-lineage
transitions. A second focused run passed 51/51 in 74.66 seconds after the retained record reader and
stage-file matcher were changed to derive their admitted names from that vocabulary, removing the
embedded program's duplicate hand-written state set.

The ownership vocabulary now lives in the private `ownership-internal` sublibrary, below both the public
library and `colima-backend-internal`; `cabal build all --ghc-options=-Werror` passed after that dependency
recut. The Colima compatibility identity is backed by the shared `ObjectIdentity` encoding while retaining
the existing two-word wire view. The focused gate then passed 66/66 in 74.01 seconds.

The native driver now describes its complete Colima/Lima/Docker effect set as `HostCommand` values in
`HostBootstrap.Ensure.Colima.Command`: the exact three-tool membership and all list, start, delete,
machine-identity, disk, context, and routed-Docker argument vectors are pinned by application. Route
override refusal is a single private pure decision shared with the compatibility backend. The repository
built under `-Werror`; the focused command check passed in the 51-test `direct` slice in 1.09 seconds (the
whole `ColimaSpec` had passed 52/52 in 76.10 seconds immediately before the route decision was centralized).
`HostBootstrap.Ensure.Colima.Report` now supplies strict, total Colima-list and machine-identity result
classification, including exit/stderr/framing/shape/duplicate refusals and the canonical machine epoch.
Those value tests and the centralized route refusal passed again in the 51-test `direct` slice in 1.20
seconds.
The stage graph is now also total over intent, durable stage, and authoritative observation. It distinguishes
successor publication from the start/delete/namespace-release mutations that must retain their current
stage until re-observation, and refuses every other product input. Its exact focused case passed in 0.01
seconds.
`HostBootstrap.Ensure.Colima.Ownership` now derives the stage/home/context/disk record keys from the fixed
profile and holds them under one shared protected-store entry; invalid profile identities mint no entry.
The `direct` slice exercised a real protected store and compare-and-swap under that entry and passed 51/51
in 1.09 seconds.
The same native entry now interprets the total-profile observation through the sole effect interpreter;
an unresolved command was exercised as a typed refusal while a real kernel entry was held. Home/context
directory acquisition and release now compose the shared enter, durable-origin, create, bind, reobserve,
and identity-conditional release producers over shared `OriginRecord` bytes. The real-kernel acquire/release
case and result classifiers passed in the 51-test `direct` slice in 1.17 seconds.
The durable stage record now has one canonical owner/lineage/invocation codec, with non-canonical bytes
refused. Native namespace preparation publishes `Reserved`, acquires and identity-binds the exact home and
Docker-config directories through shared artifact records, advances only adjacent stages to `Prepared`, and
idempotently re-enters both identities on retry. That real-kernel transaction passed in the 51-test
`direct` slice in 1.07 seconds.
Native profile start now keeps `Prepared` durable across the outcome-unknown window, observes and starts
only through the described-command interpreter, and publishes shared reported-origin records for both the
profile and its data disk before the creating command. A value-driven interpreter test (no executable
stand-in) covered absent → origin publication → start → exact running readback → machine identity; an
unavailable production interpreter retained `Prepared`. The `direct` slice passed 51/51 in 1.04 seconds.
The profile's reported machine identity and the data disk's kernel identity now bind their pre-start shared
origins. `Managed` has a canonical evidence-bearing stage record (machine/epoch/context/complete wall), and
the sole `Prepared` → `Managed` publisher requires both bindings plus exact context-directory re-entry.
Managed evidence persists across cleanup successors and an evidence-free Managed record is unrepresentable.
The value-driven start, real-kernel bindings, and Managed settlement passed in the 51-test `direct` slice in
1.20 seconds.
Docker context inspection now has a strict total classifier, and its semantic JSON value is hashed together
with the shared context-directory identity so whitespace and object-key ordering cannot change authority.
The canonical-equivalence test and native transaction checks passed in the 51-test `direct` slice in 1.16
seconds.
Native clause-4 cleanup now binds the cleanup invocation durably before delete, revalidates the bound
machine and kernel disk identities, performs the described delete, proves both artifacts absent before
forgetting their shared records, and identity-conditionally releases the context and home namespaces in
stage order. The same entry now carries routed Docker execution, with the Managed lineage, context,
running profile, and machine binding revalidated on both sides of the command. Real-kernel/value-report
coverage for both transactions passed in the four-case `direct` slice in 0.86 seconds; the test launches no
stand-in executable.
The native artifact observer now admits exactly the derived Lima disk name/directory/instance/size tuple,
reads the real data-file identity, and joins canonical Docker-context JSON to the already-bound context
directory identity. Its value-reported commands and real-kernel identity observation passed with cleanup and
post-Docker replacement refusal in the four-case `direct` slice in 0.85 seconds.
The private shared seam now supplies one canonical `OwnershipManifest`: a sorted, duplicate-free set of
canonical relative paths paired with opaque kernel identities, with strict parser/renderer and SHA-256
digest. Reordering is authority-neutral while traversal and duplicate names are refused. The manifest value
case and native driver transactions passed in the four-case `direct` slice in 1.08 seconds after
`cabal build all --ghc-options=-Werror` succeeded.
The manifest vocabulary now distinguishes mutable files, immutable payload-bound files, directories,
symbolic links with exact target bytes, and sockets while retaining mode and kernel identity. The POSIX row
walks home and Docker-config descriptor-relatively without following file or directory links, and the native
artifact observer persists their merged, namespaced manifest. Managed settlement, live Docker, and cleanup
must reproduce it; an added context file refuses before any Docker command. These real-kernel cases passed
in the four-case `direct` slice in 0.85 seconds.
Acquisition is now one protected-entry native transaction with explicit `Applied` versus `AlreadyExact`
results. Exact re-entry re-observes the running wall, machine epoch, Lima disk, Docker context, complete
manifest, and both retained identity bindings without issuing start. The public prepared-wall adapter,
settlement seam, routed Docker call, and cleanup path now consume that native result and run the described
commands in the bounded Haskell runner's closed namespace; none calls the embedded acquire, live-Docker,
or cleanup backend. That public lifecycle runs only in the opt-in `HOSTBOOTSTRAP_COLIMA_LIVE=1` lane;
`ColimaSpec` has no static case for failed-delete resume, cleanup-invocation fencing, or `ColimaReleased`
replay, which are the scripted-interpreter cases Sprints 16.24 and 16.36 owe.
`cabal build all --ghc-options=-Werror` also passed after the adapter recut.
The bounded native command is now shipped to a hidden entry in the installed Haskell binary. Its request
is a length-framed absolute executable plus argv, and the owning runner keeps the entry's private stdin
pipe open for exactly the transaction lifetime. Kernel EOF after hard parent death makes the entry kill
its complete process group; ordinary completion returns through the shared bounded capture. The public
lifecycle case passed through this shipped entry in 1.24 seconds, and the complete repository again built
under `-Werror`. The dedicated gate hard-kills the owning process after its descendant publishes a real
PID, then proves the descendant is gone; it passed in 0.30 seconds. The entry polls both its retained
kernel parent identity and the nonblocking EOF channel, so the non-threaded runtime cannot suspend the
death watch in a blocking foreign wait.
The backend contains only the native acquire, cleanup, live-Docker, namespace, and shipped-command
transactions; driver-local identity/directory-chain codecs and crash-point request fields are absent. The
test matrix exercises values and real kernel objects without stand-in Colima, Docker, or Lima binaries.
`Resolver.Native` inspects the fixed production or
fixture candidate table in Haskell, validates canonical formula targets, executable ownership/mode, home
shape, Docker Desktop fallback, and every helper-directory identity, then feeds the same strict opaque
authority settlement. Its eight-case adversarial slice passed 8/8 in 0.04 seconds; fixture candidates are
inert executable identity objects and are never invoked.
On 2026-08-21, `cabal build all --ghc-options=-Werror` and
`cabal build hostbootstrap-core-test --ghc-options=-Werror` passed on x86_64 Linux with GHC 9.12.4 and
Cabal 3.16.1.0. The focused `ColimaSpec` gate passed all 17 value, kernel, and process cases in 0.37
seconds, including the hard-parent-death group kill, native resolver adversarial matrix, and mechanical
absence guard for interpreter sources and stand-in behavior. `git diff --check` passed and the tree
contained no `.log` artifact.

On 2026-09-05, native Windows 11 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal build all --ghc-options=-Werror` and the complete warning-clean core suite at 2,477/2,477 in
318.23 seconds. POSIX-only imports and private helpers are conditional; every Colima case on Windows
checks the resolver’s `apple-silicon-required` result and the shipped entry’s explicit refusal. Native
Linux 7.0.0-28-generic x86_64 passed the same suite at 2,482/2,482 in 139.04 seconds. The focused
macOS arm64 Colima/effect/documentation gate passed 36/36 in 5.29 seconds. Both remote hosts also
passed the Python code gate and 231 tests. The remote runs used isolated working-tree copies.

#### Remaining Work

- Post-delete resumption in `cleanupInside` (`Ensure/Colima/Ownership.hs`), acting on the
  `decideColimaStage` rows Sprint 16.24 routes the driver through: at `ColimaReleasing` with the same cleanup
  invocation and the profile absent from the listing, skip `revalidateColimaManifest` and the delete,
  re-observe the disk's absence, forget whichever of the profile and disk records remain (an already
  forgotten record is accepted), and continue to the context release; at `ColimaContextReleased` with the
  same invocation, resume at the namespace release. `ColimaSpec` cases with a scripted interpreter: an
  interpreter whose delete succeeds and whose post-delete listing call fails once, then a second cleanup with
  the same invocation reaches `ColimaReleased` without a second delete; a stage record written at
  `ColimaContextReleased` with the same invocation completes to `ColimaReleased`.
- `finishNamespaces` publishes `ColimaReleased` only after `pruneEmptyColimaScaffolding`, the tmp, cache, and
  home `releaseColimaDirectory` calls, and the manifest `compareAndDeleteProtectedRecord`; until then the
  stage stays `ColimaContextReleased`, and the replay short-circuit for `ColimaReleased` holds only because
  nothing remains. `ColimaSpec` case: a non-empty Colima scaffold makes cleanup refuse with the stage at
  `ColimaContextReleased` and the home, cache, tmp, and manifest records present; after emptying it, the same
  invocation releases them and publishes `ColimaReleased`.
- `requireReportedOrigin` (in `startPreparedColimaProfileInside`) and `verifyOrigin` (in
  `bindReportedRecord`) accept the claimed record bound or unbound, comparing kind and origin, and require
  an existing binding to equal the identity being bound now. `ColimaSpec` case: acquisition whose settlement
  fails after `bindColimaCreationIdentitiesInside` (manifest drift injected by the interpreter) is followed by
  an acquisition with the same invocation that settles `ColimaManaged` without a second start.
- `ensureColimaDirectory` resumes a retained unbound directory origin: `OriginAbsent` with the target still
  absent creates and binds it under the held entry; a present target is `OwnershipOccupied`; an
  `OriginPresent` unbound record over an absent target is forgotten by compare-and-delete before a fresh
  acquisition. `ColimaSpec` case: a first preparation that fails because the home's parent is missing, then
  a retry after creating the parent, reaches `ColimaPrepared`.
- `validateStanding` (live-Docker admission) reads the stage record and refuses a non-`Managed` stage or a
  different owner, lineage, or invocation before any effect, and re-enters the context directory with
  `reenterOwnedObject` plus `reobserveOwnedIdentity`, refusing an absent record, instead of calling
  `ensureColimaDirectory`. `ColimaSpec` case: `runManagedColimaDockerWith` against a `ColimaReleased` record
  refuses, the interpreter receives no command, and no context directory or context record is created.
- `settleManagedColimaProfileInside` (`Ensure/Colima/Ownership.hs`), whose Haddock says `Managed` is
  published only after the context directory re-enters exactly, calls `ensureColimaDirectory`, which creates
  and binds a fresh directory when the context record is absent, and accepts the disk binding as any
  `Right _`. Re-enter the context directory with `reenterOwnedObject` plus `reobserveOwnedIdentity`, refusing
  an absent record, and take the expected data-disk identity as a parameter (acquisition passes
  `artifactDiskIdentity`) and refuse when the bound identity differs. `ColimaSpec` cases over the exported
  `settleManagedColimaProfile`: a `Prepared` stage whose context record was deleted is refused and no context
  directory or record is created; a disk identity differing from the binding is refused with the stage left
  at `Prepared`.
- Seal the stage types in `Backend/Stage.hs`: export `ColimaManagedEvidence` abstractly with plain accessor
  functions, and make `ColimaStageRecord`'s fields non-label accessors so record-update syntax cannot reach
  them. `CompileFailSpec` compiles fixtures against the public library only, where the private component is
  already hidden, so the evidence is a `ColimaSpec` source-guard case over `Backend/Stage.hs`: its export list
  names `ColimaManagedEvidence` without `(..)`, and neither type is declared with record-field syntax.
- `mkColimaStageRecord` and the parser's `validateBase` (`Backend/Stage.hs`) admit only printable-ASCII
  owners (`'!'`..`'~'`), so `renderColimaStageRecord`'s `ByteString.Char8.pack` cannot truncate an owner
  into a different one. `ColimaSpec` cases: an owner containing `'\x100'` or `'é'` is `Left "stage-owner"`,
  and an admitted owner round-trips through render and parse unchanged.
- Rewrite the `colimaBounds` Haddock (`Backend/Runner.hs`): the wall is the caller's timeout as given (no
  five-times scaling, no thirty-second floor), with the 16 MiB transcript ceiling and six-second grace.

### Sprint 16.48: The live cluster gate as a harness case [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/app/Main.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/engineering/testing.md`, `documents/architecture/dhall_generation.md`

#### Objective

Make the live gate a verb an operator already knows.

#### Deliverables

- The bare binary carries a real test suite with one live cluster case, reached by `test run`. A gate is
  something the fixed command tree already expresses (§ P), so it needs no second surface.
- The case takes its exclusive run, its lease, its clause-holding cleanup, and its report from the harness
  rather than arranging each itself.
- The cluster identity the case brings up is the harness run's own. The case's action lists the driver's
  clusters itself (`bareClusterAction` runs `kind get clusters`) and returns `StepRefused` when the
  run-scoped name is already listed, before it writes the sentinel or creates anything.
- The durable root the case reads back is outside everything the case may delete, which is the property
  the gate exists to prove.
- Every assertion failure carries its reason to the report card: the live and reversed assertions return
  `Fail reason` or throw `LifecycleFailure`, never `System.Exit.die`, whose `ExitFailure 1` renders as a
  cause-less `BROKEN` or `LEAKED?` row.
- The runtime-allocation assertion removes every container it may have created, by name as well as by
  identity, so a `docker container run` that created a container and then failed to start it leaves nothing
  behind.
- The case reads its sibling project config through the installed Harness codec
  (`withHarnessProjectCodec` and `decodeProjectCodecFile`), so the read carries the codec witness and the
  installed-identity and scope binding every other project-config read carries.

#### Validation

`hostbootstrap test run cluster-live` on a disposable linux-cpu host: a fresh cluster reaches node
readiness, answers a read-only observation, is deleted, leaves no labelled node container, and leaves the
durable-root sentinel byte-identical. Record the date, host, architecture, toolchain versions, duration,
and result with the phase acceptance below.

**2026-08-21 — passed.** On Linux 7.0.0-28-generic x86_64 with Docker 29.7.1, Kind 0.32.0,
kubectl 1.36.4, and Kubernetes 1.36.1, the bare binary's `test run cluster-live` exited 0 in 30
seconds. Its generative `run-53dce11d81dc3` plan created and cordoned
`hostbootstrap-test-run-53dce11d81dc3`, reached node readiness, returned the client/server version and
non-empty node observation, deleted the cluster through that same closed-over plan, proved no matching
labelled node container remained, and re-read the exact sentinel under
`.test_data/run-53dce11d81dc3`. The harness then released its own data generation. The client binary was
downloaded from the official Kubernetes distribution and matched its published SHA-256 before the run;
the temporary gate directory and generated test config were removed afterward.

Closing this sprint requires the value cases in Remaining Work, including the codec-read source guard,
passing under `cd core && cabal test all`.

#### Remaining Work

- `readBareConfig` (`CLI/Bare.hs`) decodes the sibling project config with `Dhall.inputFile Dhall.auto`,
  bypassing the codec witness and the installed-identity and scope binding. Decode it through
  `withHarnessProjectCodec` and `decodeProjectCodecFile` instead, and drop the plain `Dhall` decoder import
  if nothing else uses it. Closure case: a `ProjectPlanSpec` source-guard case asserts `CLI/Bare.hs` names
  no `Dhall.inputFile` and does name `decodeProjectCodecFile`.
- Replace every `die` in `assertLive`, `assertReversed`, `runtimeExposureAssertion`'s `cleanupCreated`, and
  `readBarePlan` (`CLI/Bare.hs`) with `Fail reason` where the assertion returns a `CaseResult`, and with
  `throwIO (LifecycleFailure reason)` elsewhere (`resolveBareHostConfig` included). `HarnessSpec` already
  pins how `LifecycleFailure` renders; the closure case is a `ProjectPlanSpec` source-guard case asserting
  `CLI/Bare.hs` names no `die`.
- `cleanupCreated` removes both fixed names (`<cluster>-exposure-a`, `-exposure-b`) with
  `docker container rm --force <name>` regardless of which `docker container run` answers succeeded, then
  verifies absence by name.
- Expose `successfulLine`, the mapping parser inside `inspectMapping` (as a pure
  `parseLoopbackMapping :: String -> Either String String`), `bareStepPlan`, and `bareInit` to the test suite
  (a private module or the existing test-visible surface). Table cases: `successfulLine` over empty output,
  one line, two lines, a missing trailing newline, stderr on success, and a non-zero exit;
  `parseLoopbackMapping` over `127.0.0.1:43123` (accepted), `0.0.0.0:43123`, `[::1]:43123`, `127.0.0.1:`,
  and `127.0.0.1:4x`; `bareStepPlan` with no harness run name is `Left EmptyStepPlan`.
- Bind the Kubernetes observation to the run's cluster: `assertLive`'s `kubectl version -o json` and
  `kubectl get nodes -o name` carry `--kubeconfig <clusterKubeconfigPath plan>` (the plan-owned credential the
  backend route of Sprint 16.38 publishes), built by one exported pure `bareKubectlArguments :: ClusterPlan ->
  [String] -> [String]`. Table case: both observation vectors start with `--kubeconfig` and the plan's path,
  and neither reads the operator's default kubeconfig or current context.
- Take the relay creation out of `bracket`'s acquire in `runtimeExposureAssertion`: the acquire only fixes
  the two names, `createBoth` runs inside the body, and the release (`cleanupCreated` by name, as above) runs
  whatever the creation threads answered, so an asynchronous exception while `takeMVar` waits still removes
  both containers. Case: `runtimeExposureAssertion` with `Docker` resolved to the `FakeCluster` client, armed
  so `container run` records its container and then blocks; `UserInterrupt` thrown to the assertion thread
  during creation leaves no relay in `FakeCluster.readRelays` once the exception has propagated.
- The `runBareHostBootstrapCLI` Haddock (`CLI.hs`) says the `cluster-live` case body "performs read-only node
  observation". Its `assertLive` first runs `runtimeExposureAssertion`, which creates two detached relay
  containers on the host Docker daemon, inspects their loopback mappings, and force-removes them. Reword the
  Haddock to say the case body creates and removes two named exposure-relay containers before its read-only
  Kubernetes observation.

### Sprint 16.49: The enumeration names what the binary drives [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Native.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Narrow the `HostTool` enumeration to the tools the binary still delegates to, and pin it there.

#### Deliverables

- `Python3`, `Flock`, and `Lockf` leave the enumeration. § K admits a tool the project genuinely
  **delegates** to; these three are how an interpreter and a locking front end performed ownership on the
  binary's behalf, and Sprints 16.44 and 16.47 replace that with the binary's own typed operation over one
  platform row. The names go with the last driver that needed them.
- The cluster's tool list names no `Flock` or `Python3`: the local `requiredTools` in
  `discoverStrongClusterBackend` and `clusterCommandTools` in `HostBootstrap.Cluster.Command` are its homes.
  The provider alias (`HostBootstrap.Substrate.Provider.Alias`) ships one closed symbolic-link act to the
  project binary installed in the guest, with no guest interpreter and no discovered `flock`, `stat`, or
  Python front end.
- The direct-Colima toolchain names no Python either. Nothing the driver runs is Python, so the native
  resolver neither inspects nor fingerprints `/usr/bin/python3`, and no ownership record carries a Python
  path: a missing or replaced system Python neither refuses Colima nor changes its authority.
- `Lockf` leaves with them. It exists only as the discriminator that refuses a host offering `lockf` where
  `flock` is required, and a discriminator for a front end the binary no longer resolves has nothing to
  discriminate.
- `HostToolSpec` gains the **exact** membership pin — `allHostTools` compared against the complete list,
  not a subset check — so a tool the project does not delegate to cannot re-enter the set. That is the
  absence guard for the shape this sprint removes (§ I), which is why it ships here rather than with the
  boundary.

#### Validation

`HostToolSpec`'s exact membership assertion, proved non-vacuous by naming the complete set rather than a
lower bound; `ClusterBackendSpec` and `ProviderBackendSpec` over the narrowed discovery.

On 2026-08-21, `cabal build all --ghc-options=-Werror` and
`cabal build hostbootstrap-core-test --ghc-options=-Werror` passed on x86_64 Linux with GHC 9.12.4 and
Cabal 3.16.1.0. The focused exact-membership, cluster-backend, and provider-backend gate passed all 65
cases in 2.91 seconds. Fixture `HostConfig` values contain only the tools their tested production route
actually resolves.

Closing this sprint requires the resolver cases in Remaining Work, passing under `cd core && cabal test all`.

#### Remaining Work

- Remove the Python candidate from the direct-Colima toolchain: drop `/usr/bin/python3` from the native
  resolver's layouts (`Resolver/Native.hs`), the trusted protocol (`trustedPythonCandidate`,
  `protocolPythonPath` in `Resolver/Protocol.hs`), `validateBootstrapPython` and the Python
  `ResolvedTool` in `Resolver.hs`, `trustedApplePythonPath`, the fixture's `resolverFixturePython`, and the
  never-read `ownershipPythonPath` field of `src/HostBootstrap/Ensure/Colima.hs`, so the toolchain
  fingerprint does not cover it. `settleTrustedResolverResultForTesting` and the fixture views drop the
  bootstrap device and inode parameters, and the `resolver-python-identity` settlement case goes with them.
  `ColimaSpec` case: a fixture layout with no `usr/bin/python3` resolves READY, and the trusted-resolver wire
  carries no python field. A `SourceGuard` case asserts no module under `internal/colima-backend` or
  `src/HostBootstrap/Ensure` names `python3`.

### Sprint 16.50: The live cluster gate run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated `hostbootstrap test run cluster-live` run on linux-cpu against the current tree.

#### Deliverables

- one dated run naming its host, the cluster identity it created, and its result.

#### Validation

On 2026-09-06, `hostbootstrap test run cluster-live` reported `1/1 passed` on arm64 macOS 26.6.2
(build 25G83) realizing `linux-cpu` through Colima 0.10.3, with kind 0.31.0 and a Kubernetes v1.35.0
server. The run created the harness-owned cluster `hostbootstrap-test-run-19b169b97b438`, observed its
nodes Ready through `kubectl`, and its reverse projection deleted the cluster; `kind get clusters`
afterwards listed only the ambient unrelated cluster, and `.test_data` was left present and empty.

The Apple outer host reports `cordon: Apple substrate — the prepared per-project provider VM owns the
outer wall`. That line is the non-Linux arm of `applyLinuxCordon`, which applies no wall: this run went
through an ambient Colima profile rather than a per-project provider VM, so its cluster ran uncordoned. The
run is evidence for creation, readiness, and deletion only; the cordon on this route is Sprint 16.38's owed
backend route.

An earlier attempt on the same day recorded `1/2 passed` with the teardown refusing
(`no installed signing key`), because the binary had been built but its installed identity had not been
provisioned. That is the documented install order rather than a defect in this lane, and it is recorded
here because the refusal left a cluster standing that had to be removed by hand.

#### Remaining Work

None.

### Sprint 16.51: One owner selects the cluster configuration [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Core derives a cluster configuration filename from the driver, and its only consumer computes the
plan from core and then overwrites that field with its own three-way selection. So the decision has two
owners and core's is never exercised — which is why core's accelerator answer can name a file that
exists nowhere in the tree without anything noticing. One owner decides; the other stops deciding.

#### Deliverables

- The driver-to-configuration mapping names files that exist, and a case asserts each resolves.
- The consumer stops overwriting the field, or core stops deriving it — one of the two, stated in this sprint as the decision it is.
- The accelerator template the GPU driver names is the one the repository ships.
- A case pins that the selected configuration file resolves for every driver.

#### Validation

**The decision is that core stops deriving it.** The alternative — core keeps a mapping and the consumer
stops overwriting — was rejected on three grounds, and the grounds are the point rather than the outcome.
The templates are files in a *project's* own source root, so a library that names one is naming a file it
cannot know exists. The choice is not a function of the driver: the consumer's selection turns on where
the project places its accelerator daemon, which the resolved plan does not carry. And the library's
answer for the GPU driver was `nvkind.yaml`, which the repository does not ship, so the mapping was
already wrong in the one case its consumer did not overwrite.

`driverConfigFile` is deleted and a resolved plan carries `Nothing`, which `clusterConfigPresence`
already reads as *the driver's own default template*. That was not a new meaning invented for this
sprint; it was the meaning a harness-profile plan already had.

Two things the change surfaced. First, the failure mode was real rather than theoretical:
`createCluster` fails closed on a named-but-missing config, so a Production nvkind plan that reached
creation without the consumer's overwrite would have died on `nvkind.yaml`. Second, `clusterCreateArgs`
carried `maybe "kind.yaml" id` as a default that could never be reached, because the guard above it
already required the field to be present. Both are gone: the argument builder now renders the named
template or no flag, and the two conditions cannot disagree about which case it is.

**The templates the project ships are identical for two of the three answers.** `kind.yaml` and
`kind-in-cluster.yaml` differ only in their comment. That is the consumer's to resolve, not this
sprint's, and it is recorded here rather than silently collapsed: deleting a shipped template is a
change to the worked demo's artifacts and belongs to the phase that owns them. The worked-demo phase
resolved it in Sprint 24.44, which deleted the duplicate and left the selector branching twice.

Dated 2026-09-12 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `LifecycleSpec` passed
154/154 with a new case pinning that both drivers resolve to no template, and the demo suite passed
150/150 with a new case that walks the project's three contexts and asserts the file each selects is
present on disk. The direct-GPU context selects the nvkind template, the Incus-VM context the in-cluster
kind template, and the WSL2-VM context the host-resident one.

#### Remaining Work

None. Backend-complete wall admission, the ingress sum, the shared gate commitment and the singleton
state directory are Sprints 16.52 to 16.55, each with its own scope.

### Sprint 16.52: Backend-complete admission at the cluster wall [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/applied_cordon.md`

#### Objective

The per-backend half of the plan-indexed budget-admission contract: every backend answers for its own
sizing at the admission site. That algebra (`withValidatedBudget`, `admitProviderBudget`,
`verifyPlannedWorkloadFit`, `withBudgetPartition`, `withProviderWallReservation`) has no production caller;
the only consumer that requires it, `prepareColimaWallCall`, is reached only by `ColimaSpec` and a
compile-fail fixture. Production applies its walls through the `Cluster.Cordon` facades over a
`ResourceEnvelope` (the provider sizing renderers in `Substrate.Provider` and the kind node cordon), and the
cluster slice comes from `withActionResourceSlice`. `BudgetSpec`'s admission, fit, partition, and reservation
cases are therefore evidence about the algebra, not about an applied wall; production adoption of the chain
is owed where `development_plan_standards.md` § O ("What runs today") places it.

#### Deliverables

- Every backend constructor is named at the admission site, with its own sizing decision.
- A backend that inherits whole-unit sizing says so deliberately, with the reason it does.
- The budget suite covers each backend rather than the three that were named.
- The budget has three dimensions, CPU, memory, and storage, in `ResourceEnvelope` and in
  `preflightBudget`/`preflightHostBudget` alike. Device capacity is deliberately not a budget dimension: a
  GPU request is attached by the accelerator placement, and an occupied GPU surfaces as that workload's
  readiness failure, not as a preflight refusal.

#### Validation

Two of the three deliverables were already met when this sprint opened, and saying so is more useful than
restating them as work. `validateBackendExactness` already matched on all six constructors with no
wildcard, and `-Wall` with warnings-as-errors already made a seventh a compile error there. The budget
suite already asserted all six answers rather than the three the wildcard once covered.

What was missing is the third: three backends shared one grouped comment — *"the three guest-VM walls take
whole gibibytes and nothing finer"* — which states the rule without stating why any of them holds. Each
now carries its own reason, and the reasons are not the same fact three times. Lima's `--memory` and
`--disk` take whole gibibytes, so a finer budget has no argv that expresses it. Incus renders
`limits.memory` and the root volume size as `<n>GiB` strings. WSL2's `.wslconfig` takes `memory=<n>GB`,
and its storage figure is not a `.wslconfig` key at all — the VHDX cap is applied at install time — but it
is checked anyway because the install argument it does reach takes the same unit. That last one is the
case a grouped comment hides: its two dimensions reach two different mechanisms.

Dated 2026-09-12 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `BudgetSpec` passed
27/27, and the phase gate below.

#### Remaining Work

None.

### Sprint 16.53: Accelerator ingress is a closed sum [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

The ingress plan is a record with a string discriminant and two optional fields that are present
exactly when that string holds one value. Its producer is correct and nothing else enforces the
correlation, while the constructor is exported — so the invalid combinations are constructible by any
consumer and only prose says they are wrong.

#### Deliverables

- The ingress plan becomes a sum with a case per service type, each carrying exactly the fields that case has.
- The correlated optional fields disappear because the invalid combinations have no constructor.
- The state-directory accessor stops repeating one body across two constructors.
- Rendering is total over the new sum.

#### Validation

`AcceleratorIngressPlan` is now `ClusterIpIngress Int | NodePortIngress Int Int String` — one case per
Kubernetes service type, each carrying exactly the fields that case has. The type string and the two
correlated optional fields are gone, so a `ClusterIP` carrying a node port and a `NodePort` carrying none
are no longer terms (§ HH). The four accessors survive as total functions over the sum, which is what
kept both consumers — the Helm value list and the rendered values file — unchanged.

The state-directory accessor no longer repeats its body, and neither does any of its neighbours.
`planOwnedClusterResolvedPlan` eliminates the two owner constructors once, and the eight accessors that
read the resolved plan became compositions on it. That removed one of the two `error` calls the legacy
ledger names; Sprint 16.55 removes the shape that made the call possible.

Dated 2026-09-12 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `LifecycleSpec` passed
154/154 with the two ingress cases rewritten against the constructors, and the demo suite passed 150/150.

#### Remaining Work

None.

### Sprint 16.54: One prepared-gate commitment [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`, `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`, `core/hostbootstrap-core/test/BudgetSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Two backends commit to the same six prepared-gate fields in the same order and then hash them
differently — one length-frames and digests, the other joins with a separator. Two answers to one
question, differing where nobody compares them.

#### Deliverables

- The field projection has one home beside the prepared gate itself.
- Both backends commit through it with the same construction.
- The sprint states which construction is canonical, and checks whether any recorded durable state depends on the one being replaced.

#### Validation

`preparedGateFields` and `preparedGateCommitment` live in `HostBootstrap.Lifecycle.Prepared`, beside the
gate they are about, and both backends commit through them. The provider's local
`providerGateCommitment` and the cluster's `clusterGateCommitment` are deleted.

**The length-framed digest is canonical; the colon join is not.** A separator that can occur inside a
field admits two different gates with the same commitment, and this library constrains neither the
operation key nor the session name to exclude a colon. Framing removes the question instead of answering
it per-field. The shared construction also digests UTF-8 bytes rather than the provider's former
Char8 truncation, so a non-ASCII field can no longer collide with a different one.

**No recorded durable state depends on the construction being replaced.** Gate commitments reach only
runtime-dependency packages, and every use of those packages' wire is authenticated handoff transport
inside one run's process tree — `Handoff.hs` and `Handoff/Process.hs`, both invocation-scoped. Nothing
writes a package to the protected store, and the one golden-bytes case in the dependency suite pins
literal placeholder fields rather than a real commitment, so no golden moved.

A `BudgetSpec` case asserts that two gates differing only in where a colon falls between two fields —
`("plan:digest", "operation")` against `("plan", "digest:operation")` — commit differently. That pair
separates the length-framed construction from a colon join only: an unframed concatenation, a join on any
other separator, and a return to Char8 truncation all pass it, and the case's first assertion,
`preparedGateCommitment gate @?= preparedGateCommitment gate`, compares a pure function's result with itself
and touches neither backend.

Dated 2026-09-12 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `BudgetSpec` passed
27/27, and the phase gate below.

The sprint closes when the golden, non-ASCII, and backend-level cases in Remaining Work pass under
`cd core && cabal test all`.

#### Remaining Work

- Delete `preparedGateCommitment gate @?= preparedGateCommitment gate` from the `BudgetSpec` case "one gate has
  one commitment, and a separator cannot forge it", and add a golden: the commitment of
  `gateForValues "plan-digest" "operation-key" "session-1" 3 4` equals a fixed hex digest literal, which pins
  the length framing, the domain tag, and the UTF-8 encoding at once.
- Add a non-ASCII pair: two gates whose plan-digest fields are `"\x4e00"` and `"\x4f00"` (equal low bytes)
  commit differently, which a Char8 truncation would not.
- Backend-level cases: in `ClusterReconcileSpec`, the runtime-dependency package `Cluster/Backend.hs` registers
  for a prepared cluster call carries `preparedGateCommitment gate` for the gate it was prepared under; in
  `ProviderBackendSpec`, the same for both packages `Substrate/Provider/Backend.hs` registers. Each case
  rebuilds the commitment from the gate value, so a backend that reverts to a local construction fails it.

### Sprint 16.55: The resolved cluster plan retains one state directory [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

A resolved cluster plan carried `derivedPaths :: [FilePath]`, and every construction site set exactly one
element. Reading it therefore needed an `error` for the empty case that no construction could produce —
a partial function guarding against a state the type admitted and the code did not.

#### Deliverables

- The field is one directory rather than a list, and its name says so.
- The `error` disappears because the empty case has no term.
- The teardown partition and the status report read it directly.
- The ledger row is removed in the same change.
- The state directory cannot be the durable root or an ancestor of it. A `TestCase` profile carries a run
  key admitted by `validHarnessRunKey` (at most 48 characters of ASCII alphanumerics and `-`), produced only
  by a validating constructor, so no caller can splice `..` or a separator into `derivedStatePath`; and
  `teardown` refuses a removal set that equals `dataPath` or contains an ancestor of it.

#### Validation

`derivedStatePath :: FilePath` replaces `derivedPaths :: [FilePath]`, and
`planOwnedClusterStateDirectory` is a composition with no case and no `error`. `teardown` builds its
removal and preservation sets from the one path, and `statusReport` prints it without `unwords`.

One test did construct a two-element list: the aggregate-teardown case that proves `cluster delete`
attempts every cleanup step rather than stopping at the first failure. It exploited the list shape that
no production site produced. The property it checks does not need two derived paths — the aggregate is
still the kind deletion plus the directory removal — so the case keeps its assertions with one, and its
name now says "every cleanup step" rather than "every path".

Dated 2026-09-12 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `LifecycleSpec` passed
154/154 and the demo suite 150/150, and the phase gate below.

Closing this sprint requires the run-key and teardown cases in Remaining Work, passing under
`cd core && cabal test all` and `cd demo && cabal test all`.

#### Remaining Work

- Export `ClusterProfile` from `Cluster/Lifecycle.hs` without the `TestCase` constructor, add
  `mkTestCaseProfile :: Text -> Either ClusterPackageError ClusterProfile` applying `validHarnessRunKey`
  (shared with `profileFromPlanName`), and a pattern-free accessor for the run key; `CLI/Bare.hs`
  (`bareClusterStep`, `readBarePlan`) and the demo's harness-profile construction go through it.
  `LifecycleSpec` cases: `mkTestCaseProfile "x/../../.."`, an empty key, and a 49-character key are refused;
  `run-42` is admitted.
- `teardown` (`Cluster/Lifecycle.hs`) returns a refusal when a path in its removal set equals `dataPath` or
  is an ancestor of it after normalisation. `LifecycleSpec` case: a hand-built `ClusterPlan` whose
  `derivedStatePath` is the parent of its `dataPath` is refused by `teardown Delete`.

### Sprint 16.56: The cluster gate against the port-carrying tree [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

This phase's evidence covers `HostBootstrap.Cluster`. The reachability algebra's admitted port reaches
three modules under that path — the backend's resolved exposure, the plan's exposure intent, and the
shipped exposure codec — so the covered tree changes and this phase's claim expires with it. The claim
is re-established by re-running the gate, not by assuming a type change was harmless.

#### Deliverables

- The phase's declared gate is re-run in full: the static suite and the live `linux-cpu` leg, not one of
  the two.
- A gate-evidence row records both legs, the gate host, and the command as run.
- The covers digest is re-measured over this phase's own paths and recorded.

#### Validation

The phase's own gate, both legs.

On 2026-09-13 the bare core binary's `test run cluster-live` reported `1/1 passed` and exited 0 in
27 seconds on x86_64 Ubuntu 24.04.4 (Docker 29.7.1, Kind 0.32.0, kubectl 1.37.0 against a Kubernetes
1.36.1 server). It generated the run config, created and cordoned
`hostbootstrap-test-run-c4456ff0010cb` with
`docker update --cpus 2 --memory 2147483648 --memory-swap 4294967296`, exported its kubeconfig, reached
node readiness, returned the client and server versions through a read-only query, deleted the cluster
through the retained plan, and left `.test_data/run-c4456ff0010cb` in place. The static leg is the
`cabal test all` from `core/` that the header's `**Gate evidence**` row records.

This run is the second of 2026-09-13. The first closed the phase against the tree as it then stood; the
reachability algebra's admitted port reached three modules under `HostBootstrap.Cluster` and the
repository-wide reformat reached all of them, so the header row records only this run.

**This host's kubectl.** `/usr/local/bin/kubectl` is the dangling symlink into a removed RKE2 installation
that the 2026-09-12 entry of the Phase-Level Baseline Acceptance section records. This run resolved the tool
by installing the current stable client — v1.37.0, the version `resolve_kubectl_version` itself selects — at
`~/.local/bin/kubectl`, which precedes the dangling link on `PATH`. That is a change to the host.

#### Remaining Work

None.

### Sprint 16.57: The direct-Colima command boundary is typed and byte-exact [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Command.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Routing.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

The described Colima commands, the routed-Docker guard, and the shipped-command framing state exactly what
they admit: a profile and a Docker context are distinct types, the route guard refuses route overrides and
nothing else, and an argument reaches the supervised child byte-for-byte.

#### Deliverables

- `ColimaProfile` (private constructor, produced only by the `ownershipKeys` profile validator) and
  `DockerContextName` (derived only from a `ColimaProfile`) are the argument types of
  `deleteColimaProfileCommand`, `removeDockerContextCommand`, `readColimaMachineIdCommand`,
  `inspectDockerContextCommand`, and the routed-Docker builder; the `"colima-" ++ profile` spelling exists once.
- `startColimaProfileCommand` takes a typed start-argument value that fixes the `start --profile <p>` prefix.
- `validRoutedDockerArguments` refuses an empty argv, a leading `-`, the denied subcommands
  (`context`, `login`, `logout`, `buildx`), and global route flags only where Docker parses them (before the
  subcommand); arguments after the subcommand (`sh -c ...`, `grep -H`, `--config=` given to a container
  program) are admitted. A forbidden subcommand has its own refusal message distinct from a route override.
- The shipped-command frame carries each executable and argument as the OS byte string (UTF-8 encoded, or the
  launcher's filesystem encoding) and the supervisor spawns from those bytes, so no code point is truncated to
  its low byte and no Latin-1 re-encoding runs under `LC_ALL=C`; an unencodable argument is an explicit
  refusal.
- `HostBootstrap.Ensure.Colima.Command` exports only commands the direct-Colima owner runs, and its tool set
  is read from the commands themselves rather than restated as a literal no production code reads.

#### Validation

`ColimaSpec` table cases over `routedDockerCommand`: every exact override flag as a separate token and every
attached prefix (`-Hunix://x`, `--host=tcp://x`, `--context=other`, `--config=/x`, `--tlscert=/x`) before the
subcommand is refused; each denied subcommand, a leading `-`, and `[]` are refused with their own messages;
`["exec","ctr","sh","-c","echo hi"]`, `["run","--rm","alpine","grep","-H","x","/etc/hosts"]`, and
`["inspect","my-context-volume"]` are admitted. Framing cases: `encodeCommand`/`readCommand` round-trip an
argument containing `é` and `Ŝ` byte-exactly, and a real-process `runShippedCommand` case echoes a non-ASCII
argument back unchanged. The tool-set case derives its expected set from the described command list. All pass
under `cd core && cabal test all`.

#### Remaining Work

- Add `ColimaProfile`/`DockerContextName` newtypes and retype the Colima command builders and their callers in
  `Ensure/Colima/Ownership.hs` and `Ensure/Colima.hs`; typed start-argument value for
  `startColimaProfileCommand`.
- Restrict `validRoutedDockerArguments` to the global-flag region and give forbidden subcommands their own
  refusal; add the routed-Docker table cases above.
- Replace `ByteString.pack . map (fromIntegral . fromEnum)` in `encodeCommand` and the Latin-1 decode in
  `readCommand` with an exact byte encoding, and spawn the supervised child from raw bytes; add the framing and
  non-ASCII real-process cases.
- Delete `colimaCommandTools` from `Ensure/Colima/Command.hs`: no production code reads it, and the trusted
  toolchain is built independently in `nativeHostConfig`. Replace the `ColimaSpec` assertion
  `colimaCommandTools @?= [Colima, Docker, Lima]`, which restates the literal, with a case that collects the
  target tool of every command in the described command list and asserts the set is `[Colima, Docker, Lima]`.
  Correct the module header so it describes only effects the owner runs (`listDockerContextsCommand` is one
  once Sprint 16.23's post-removal listing lands).

### Sprint 16.58: The direct-Colima suite asserts what its cases name [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Every `ColimaSpec` case proves the property its name states. Each classifier refusal, stage-transition
refusal, fingerprint sensitivity and destructive-command target is reached by a case that fails when that
guard is removed, and a host that cannot run a case reports that through a declared `CoverageManifest` row
instead of a renamed green line.

#### Deliverables

- Every Colima report classifier refusal (`ColimaToolExit`, `ColimaReportDecode`, `ColimaReportShape`,
  `ColimaReportFraming`, `ColimaReportDuplicate`) is reached by a value case for each classifier.
- `advanceColimaStage` is checked over every pair of stages, not three of the refused ones.
- Fingerprint and manifest digests are shown to be sensitive to the fields they bind, and to be deterministic.
- Scripted interpreters pin the exact profile, context and start vectors, and record every command they
  receive.
- The host-independent pure assertions run on every gate host. The Windows refusal is asserted once, under a
  declared `CoverageManifest` family.
- The opt-in live lane and the parent-death probe cannot pass vacuously.

#### Validation

The cases in Remaining Work exist and pass under `cd core && cabal test all` on a POSIX gate host and on
Windows. The Windows run reports the declared Colima family count. The routed-Docker table is Sprint 16.57's
and the profile-derivation cases are Sprint 16.27's.

#### Remaining Work

- Classifier value cases in `ColimaSpec`. `classifyLimaDiskListing`: dir `"relative/disk"`, dir `"/a/../b"`
  and size `0` each give `Left ColimaReportShape`; two rows with the same name give
  `Left ColimaReportDuplicate`; `"not json\n"` gives `Left ColimaReportDecode`; `ExitFailure 1` with empty
  stderr gives `Left ColimaToolExit`. `classifyDockerContextInspect`: `"[]"` and `"[{},{}]"` give
  `Left ColimaReportShape`, `"not json"` gives `Left ColimaReportDecode`, and `ExitFailure 1` gives
  `Left ColimaToolExit`. `classifyColimaListing`: a row whose name contains a space gives
  `Left ColimaReportShape`, and `ExitFailure 1` with empty output gives `Left ColimaToolExit`, never
  `Right []`. `classifyMachineIdentity`: 31- and 33-character ids and a missing newline are refused.
- Stage transitions: the case "the durable Colima stage graph admits only idempotence and one successor"
  enumerates every (current, observed) pair of `ColimaStage` values and expects `Right observed` exactly when
  `observed == current` or `observed` is the next constructor, and `Left "stage-transition"` for every other
  pair.
- Sensitivity cases. Assert `isRight manifest` before comparing digests. A context JSON with a different
  `Endpoints.docker.Host` gives a different `dockerContextFingerprint`. A different `ObjectIdentity` gives a
  different fingerprint and a different `ownershipManifestDigest`. The traversal entry `"../foreign"` gives
  its exact fault. A repeat acquisition whose interpreter returns altered inspect JSON refuses with the exact
  'managed context evidence differs' conflict.
- Pin targets in every scripted interpreter. Delete must be
  `["delete","--profile",profileName,"--force","--data"]`; context removal
  `["context","rm","--force","colima-" ++ profileName]`; machine-id reads
  `["ssh","--profile",profileName,"--","cat","/etc/machine-id"]`; inspect
  `["context","inspect","colima-" ++ profileName]`; and the start step `args == canonicalStartArgs`. Make the
  start-flow interpreter step-indexed and argument-checked. Any other vector returns `Left`.
- The drift case records every command its interpreter receives. It asserts that none starts with
  `--context`, and that the fault is exactly `ColimaMutationOwnershipRefused (OwnershipMalformed "the current
  Colima namespace manifest differs from its retained authority")`.
- Once Sprint 16.29 deletes the `HostConfig` variants, replace the `observeColimaProfiles` and
  `startPreparedColimaProfile` unresolved-command cases with a case on `resolveLaunch` over a tool map that
  lacks `Colima`. The failed-start case through `startPreparedColimaProfileWith` re-reads the stage and
  asserts `Just ColimaPrepared` with no profile or disk creation record.
- Rename the case 'the Colima backend admits only native shipped effects' to an absence guard for the removed
  Program and CrashPoint stand-ins, and make it scan every file under `test/`.
- Move the pure assertions of the 'describes every tool effect' case (the effect descriptions,
  `routedDockerCommand`, and the listing, machine-identity, disk, and context classifiers) out of
  `onOwnershipHost` into their own unwrapped case, so they run on the Windows gate. Declare the remaining
  conditional cases as a `CoverageManifest` family keyed on a backend capability value, and assert the Windows
  refusal once, in a dedicated case. The live case reads `HOSTBOOTSTRAP_COLIMA_LIVE`: `"1"` runs the lane,
  unset prints 'not requested', any other value fails the case, and 'Unsupported' is printed only on a host
  that is not Apple Silicon or has no Colima. Register the case with a declared reason. In the parent-death
  probe, the child writes its pid to a temporary name and renames it into place, `waitForPath` polls until the
  content parses as a positive integer, and the python probe exits 3 only on `ProcessLookupError`; any other
  non-zero exit fails the case.

### Sprint 16.59: The storage wall settles only through a package-private permit [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/BudgetSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

`AppliedStorageWall` is the proof that a declared storage ceiling is in force, so it is minted the way
`ProviderWallAuthority` is: from a package-private permit joined to the live provider wall, never from an
observation a caller built. The storage token it prepares is the one production providers launch with, so
the storage-wall cases test the renderer production uses rather than a parallel copy. No production path
calls `prepareStorageWallCall` or `settleStorageWallCall`; production adoption of the budget chain is placed
by § O ("What runs today"), and this sprint does not claim it.

#### Deliverables

- `settleStorageWallCall` consumes an opaque `StorageWallSettlementPermit` minted only in
  `HostBootstrap.Cluster.Budget.Internal` from the exact prepared storage call, its `PreparedGate`, and the
  live `ProviderWallAuthority` for the same `wallSpecId` and fence; `StorageWallObservation`'s constructors are
  not exported from `HostBootstrap.Cluster.Budget`.
- `AppliedStorageWall` carries the live wall's `wallEpoch` index rather than a fresh one, so the proof is
  joined to the authority whose wall applied it.
- Refused settles to `Conflict`, failed to `Failure`, and uncertain to `Failure` with `ReprobeBeforeRetry`;
  none produces an `AppliedStorageWall`.
- The Lima, Incus, and WSL2 storage tokens come from the renderers production launches with:
  `limaSizingArgsForBudget`, `incusSizingArgsForBudget`, and one `wsl2VhdSizeArgForBudget` in
  `Cordon/Foundation.hs` that the WSL2 launch in `Substrate/Provider.hs` also calls.

#### Validation

The sprint closes when the cases in Remaining Work exist and pass under `cd core && cabal test all`, and the
`RawStorageWallObservation.hs` fixture is registered in `CompileFailSpec` and rejected.

#### Remaining Work

- Add `StorageWallSettlementPermit` and its mint to `Cluster/Budget/Internal.hs`, mirroring
  `withProviderWallSettlementPermitFromObservation`; change `settleStorageWallCall` to take the permit and
  the live `ProviderWallAuthority`, refusing a permit whose fence differs; stop exporting
  `StorageWallObservation (..)` from `Cluster/Budget.hs`. Compile-fail fixture `RawStorageWallObservation.hs`
  that builds `StorageWallApplied 1 n` from `HostBootstrap.Cluster.Budget`, rejected with "Not in scope: data
  constructor 'StorageWallApplied'".
- `BudgetSpec` cases settling each non-success observation through the permit path: refused yields exactly
  `Left (Conflict detail)`, failed yields `Left (Failure detail)`, uncertain yields
  `Left (Failure (FailureDetail "apply storage wall" detail ReprobeBeforeRetry))`, and in each the consume
  continuation never runs (it writes an `IORef` the case reads back unchanged).
- Replace the inline `["--disk", show storageGiB]`, `["-d", "root,size=" ...]`, and `["--vhd-size", ...]`
  arms of `prepareStorageWallCall` with the storage token of `limaSizingArgsForBudget`,
  `incusSizingArgsForBudget`, and a new `wsl2VhdSizeArgForBudget :: ResourceBudget -> Either String String`;
  the `windows` provider's `spLaunch` in `Substrate/Provider.hs` renders its `vhd` value through the same
  function instead of `show (gibibytes ...) ++ "GB"`. Rename the `BudgetSpec` case "every VM provider applies
  the declared storage ceiling exactly" to "the storage-wall call renders each provider's launch token", and
  have it assert, for one budget, that each provider's `storageWallCallArgs` equals the storage token of the
  renderer that provider's launch uses.

### Sprint 16.60: The ownership manifest is validated, byte-exact, and host-neutral [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Manifest.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

The Colima namespace manifest is the allow-list cleanup deletes from and the record revalidation compares
against. Every entry in it satisfies the validating producers, its paths are the bytes the kernel named, and
its grammar is the same on every host, so a retained manifest means one thing wherever it is read.

#### Deliverables

- `OwnershipManifestEntry` has a non-record constructor; `manifestEntryPath`, `manifestEntryIdentity`,
  `manifestEntryMode`, and `manifestEntryKind` are functions defined by pattern, so no importer can bypass
  `entry`'s path, mode, and link-target checks by record update.
- `prefixOwnershipManifest` rebuilds every prefixed entry through `entry`, so the length and canonicality
  checks apply to the prefixed path.
- Manifest paths are carried as raw bytes from the walker (Sprint 16.21) and hex-encoded directly; the parser
  returns the same bytes, with no `Text.pack` or locale round-trip, so a name that is not valid UTF-8 survives
  rendering and parsing unchanged.
- Path validation uses the POSIX grammar on every host: split on `'/'`, refuse an empty, `.`, or `..`
  component, a leading `'/'`, and any `\r`, `\n`, or NUL byte, independent of the compiling host's
  `System.FilePath`.
- A host-independent pure suite covers the vocabulary on every gate host, and the Windows row's
  `OwnershipUnsupported` answer is asserted once.

#### Validation

The sprint closes when the new `OwnershipManifestSpec` cases in Remaining Work pass under
`cd core && cabal test all` on a POSIX gate host and on Windows, and the `UpdateOwnershipManifestEntry.hs`
fixture is registered in `CompileFailSpec` and rejected.

#### Remaining Work

- Replace the record declaration in `Manifest.hs` with a positional constructor and pattern-defined accessors.
  Compile-fail fixture `UpdateOwnershipManifestEntry.hs` that writes `e { manifestEntryPath = "../x" }`,
  rejected with "Not in scope: record field 'manifestEntryPath'". `prefixOwnershipManifest` maps each entry
  through `entry` with the prefixed path and propagates its refusal.
- Carry paths as `ByteString` (or `PosixPath`) in the entry, render them with `hexBytes` directly, and have
  `parseOwnershipManifest` keep the decoded hex bytes rather than `decodeUtf8'`; `releaseEntries` and the other
  consumers in `Ensure/Colima/Ownership.hs` join the bytes onto the root through the same raw-path API.
- Rewrite `validRelative` over a `'/'` split with the component check above, dropping `isAbsolute`,
  `normalise`, and `splitDirectories` from `System.FilePath`.
- Add `test/OwnershipManifestSpec.hs`, registered in the test suite and run outside `onOwnershipHost`, and move
  the pure manifest assertions of `ColimaSpec` into it. Cases: `parseOwnershipManifest` refuses a missing final
  newline, a wrong header, a wrong field count, odd and non-hex path bytes, a bad identity, a non-octal mode, a
  tag/detail mismatch, an unknown tag, and bytes that parse but do not re-render identically, each with the
  exact `OwnershipMalformed` fault the parser raises for it; the producers refuse an empty and a
  4097-byte link target, a mode of `0o10000`, a duplicate path (through `mkOwnershipManifest` and through
  `mergeOwnershipManifests`), and an invalid prefix, each with its exact message; one entry of each kind
  (`m`, `f`, `d`, `l`, `s`), including a path holding the byte `0xff`, round-trips through
  `renderOwnershipManifest` and `parseOwnershipManifest`; `"profile/colima.yaml"` is admitted on every host.
  A `mingw32`-only case asserts `observeOwnershipManifestForHost` returns `OwnershipUnsupported`.

### Sprint 16.61: The WSL idle-timeout Haddocks state what the timeout bounds [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`

#### Objective

The WSL sizing Haddocks in `Cordon/Foundation.hs` justify their idle timeout with a gate duration the
project does not observe; they state what the timeout bounds.

#### Deliverables

- The `wsl2SizingArgsForBudget` and `managedWslIdleTimeoutHours` Haddocks say each timeout bounds the idle gap
  after the last WSL session, not the length of a run, and cite the observed Windows gate (up to 4 h 3 min,
  2026-10-22) when explaining why six hours is safe; they carry no account of earlier values.

#### Validation

The sprint closes when the two Haddocks read as Deliverables state and `cd core && cabal test all` passes.

#### Remaining Work

- Rewrite the `wsl2SizingArgsForBudget` and `managedWslIdleTimeoutHours` Haddocks as Deliverables state,
  dropping "the demo gate runs 25–50 minutes", "an order of magnitude beyond", and "they previously used".

### Sprint 16.62: The direct Linux GPU host answers its budget with a typed decision [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/engineering/applied_cordon.md`

#### Objective

§ O's ring is "applied everywhere or typed refusal". On the direct Linux GPU topology the outer image build
and the direct project container run on the host with no CPU, memory, or storage wall; only the later nvkind
nodes receive caps. The direct-host provider's `spLaunch` ignores its `ResourceEnvelope` argument and
answers `Right [RunDirectHost RealizeDirectHost]`, so the gap is a silent success. This sprint makes the
direct host answer its envelope with a typed decision, as the cluster consumer already receives the typed
bare-Linux unsupported-storage decision.

#### Deliverables

- The direct-host provider's provision plan consumes the declared `ResourceEnvelope` and returns, beside its
  `RealizeDirectHost` effect, a typed unsupported-wall decision naming the CPU, memory, and storage
  dimensions the direct host does not cap; it is never an untyped success and never a `ProviderUnsupported`
  refusal of the GPU route.
- The demo's direct reservation step (`runDirectProviderReservation` in `demoLinuxGpuChainAt`) receives
  that decision and reports it, so the plan report states that the outer build and project container run
  uncapped.

#### Validation

The sprint closes when the `ProviderSpec` case in Remaining Work passes under `cd core && cabal test all`
and the demo case passes under `cd demo && cabal test all`.

#### Remaining Work

- Give the direct provider's launch a typed unsupported-wall decision for the envelope in
  `Substrate/Provider.hs`, and carry it through `planProviderProvision`. Rewrite the `ProviderSpec` provision
  case whose direct-host assertion is `Right [RunDirectHost RealizeDirectHost]` to assert the decision names
  all three uncapped dimensions for `env`.
- Have `runDirectProviderReservation` (`demo/src/HostBootstrapDemo/Commands.hs`) report the decision; a
  `CommandsSpec` case asserts the direct reservation's report names the uncapped outer build and project
  container.

### Sprint 16.63: The Colima reconciler hashes through Digest [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`

#### Objective

`HostBootstrap.Digest` exports the lowercase-hex `sha256Hex`, and the Colima reconciler derives its profile
namespace digest, ownership lineages, field digests and owner seeds with that export over the UTF-8 encoding
of the text rather than with a Text-input local copy, so a Colima-derived name recomputed elsewhere cannot
drift from the one the reconciler recorded.

#### Deliverables

- `Ensure.Colima` computes every digest it derives with `HostBootstrap.Digest.sha256Hex` over
  `Text.Encoding.encodeUtf8` of the text, and defines no `sha256Text`.
- Every Colima profile, lineage, field digest and owner seed keeps the bytes `ColimaSpec` pins.

#### Validation

`ColimaSpec` passes unchanged inside `cabal test all --ghc-options=-Werror` from `core/`, so every
Colima-derived name is byte-identical, and the host static gate (§ JJ) passes.

#### Remaining Work

- Delete `sha256Text` from `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs` and replace its five
  call sites with `sha256Hex . Text.Encoding.encodeUtf8`, importing `sha256Hex` from `HostBootstrap.Digest`.

### Sprint 16.64: Dependency probes are minted from backend evidence and carry their readiness kind [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Production modules**: `HostBootstrap.Reconcile`, `HostBootstrap.Readiness`,
`HostBootstrap.Lifecycle.Dependency.Internal` (3; cap 3)
**Sprint budget**: one new index on an existing type and one edge field; the other call sites change by one
expression each.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`, `documents/architecture/lifecycle_state_model.md`

#### Objective

A `DependencyProbe` is a re-observation the backend performs at prepare time, never a value a caller wraps
around an arbitrary `IO` action, and it names the readiness condition it observes, so the traversal Phase 11's
prepare runs cannot be satisfied by a retained constant or by readiness of the wrong kind. The raw wrapper is
applied in Phase 15's provider alias module and in this phase's cluster reconciler and running-provider and
provider-share dependencies, so closing it lands here, where every file it touches exists.

#### Deliverables

- The `DependencyProbe` constructor and the raw `dependencyProbe` wrapper live in the package-private
  `lifecycle-dependency-internal` sublibrary; neither `HostBootstrap.Reconcile` nor `HostBootstrap.Readiness`
  exports `dependencyProbe`.
- The public producers are typed constructors over opaque backend evidence: `planDependencyProbe` over a
  `Probe` minted by `withBackendProbe`, `clusterReadinessProbe` over `ClusterReadiness`, and running-provider
  and provider-share constructors over `RunningProviderDependency` and `ProviderShareDependency`.
- `DependencyProbe` carries a readiness-kind index (`ClusterApiReady`, `GpuPluginReady`, `ProviderResponding`,
  and the other `BackendProbeKey` kinds) and records it as a term, so `planDependencyProbe` keeps the
  `dependency` index of its `Probe`.
- Each edge of an `OperationDescriptor` carries the readiness kind the plan requires of its dependency, and the
  traversal refuses with a `Conflict` an entry whose probe kind differs from its edge's.
- The `DependencyProbe` Haddock in `Reconcile.hs` and the `planDependencyProbe` Haddock in `Readiness.hs` state
  exactly which producers exist and what each re-observes.

#### Validation

The sprint closes when these exist and pass under `cabal test all` from `core/` and from `demo/`: a
`CompileFailSpec` fixture importing `dependencyProbe` from `HostBootstrap.Reconcile`, with the diagnostic
`Module 'HostBootstrap.Reconcile' does not export 'dependencyProbe'`; a `ReconcileSpec` case "a GPU-plugin
readiness probe cannot satisfy a cluster-API edge" that registers a `GpuPluginProbe`-kind probe for the cluster
dependency of a chart operation whose edge requires `ClusterApiReady` and asserts the traversal's `Conflict` with
no prepared pair; and the existing chart, cluster, provider, and alias preparation cases passing unchanged
through the typed producers.

#### Remaining Work

- `dependencyProbe :: IO (Either ReconcileError Word64) -> DependencyProbe ...` is exported from
  `HostBootstrap.Reconcile` (and re-exported by `HostBootstrap.Readiness`) and applied directly in
  `Cluster/Reconcile.hs` (around `runningProviderDependencyReprobe`, `providerShareDependencyReprobe`, and in
  `clusterReadinessProbe` around `reprobeClusterReadiness`), in `Substrate/Provider/Alias.hs`
  (`dependencyProbe shareProbe`), and in the demo's `withPreparedProviderShare ... (dependencyProbe reprobe)` in
  `Commands.hs`, so `dependencyProbe (pure (Right n))` seals a fresh-looking observation that polls nothing.
  Move the constructor and wrapper into `HostBootstrap.Lifecycle.Dependency.Internal`, add the typed producers
  named in Deliverables, rewrite the five call sites through them (the demo receives a `DependencyProbe` from
  `withFreshRunningProviderHandle` rather than a raw reprobe action, and the `CommandsSpec` source pin on that
  line follows), route the constant probes in `ProviderBackendSpec` and `ProviderReconcileSpec` through the
  typed producers or the test component's internal import, and add the compile-fail fixture named in
  Validation.
- `planDependencyProbe` returns `DependencyProbe scope planId id resource`, dropping its `Probe`'s `dependency`
  index, and edges carry only text keys, so a probe of any readiness kind satisfies any edge on the same
  resource. Add the readiness-kind index and term, the per-edge required kind on `OperationDescriptor`, the
  traversal refusal, and the `ReconcileSpec` case named in Validation.
- Rewrite the `DependencyProbe` Haddock ("A plan-owned probe that produces a /fresh/ phase-observation version"),
  which promises freshness a caller-built constant defeats today, to name the typed producers once they exist.

### Sprint 16.65: The reported face records only a reported object [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`
**Production modules**: `HostBootstrap.Ownership.Primitive` (1; cap 3)
**Sprint budget**: one changed parameter type, one unexported helper, and one refusal arm in
`releaseOwnedObject`; the eight call sites in four owner modules change by one expression each.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

The reported face's clause 2 records only an object another authority owns, so a `Recorded` token minted
without a row cannot reach the kernel face's `createOwnedDirectory` or `publishOwnedFile` as a directory
or file to create, bypassing the kernel face's clause-1 observation and clause-2 gate. Today
`recordReportedOrigin` accepts any `ObjectKind`. The parameter becomes an `OwnerClaim`, which Phase 15's
claimed object introduces, and the signature change reaches callers in Phase 15's shipped and provider
owners and this phase's cluster and Colima owners, so it lands here, where every file it touches exists.
The kernel face's `releaseOwnedObject` likewise removes only an object this run owns: it refuses a
`ReportedObject` record, as `createOwnedDirectory` and `publishOwnedFile` already do. That refusal reaches
Phase 15's shipped owner, whose `giveBack` releases whatever bound record its key holds, and this phase's
Colima owner, whose manifest remainders leave `releaseOwnedObject` in Sprint 16.23, so it lands here, after
that sprint.

#### Deliverables

- `recordReportedOrigin :: Entered session object -> OwnerClaim -> (OriginRecord -> IO (Either
  OwnershipFault ())) -> IO (Either OwnershipFault (Recorded session object))` records
  `ReportedObject claim`.
- The clause-2 computation both faces share is one unexported helper in `Primitive.hs`,
  `recordOrigin :: Entered session object -> ObjectKind -> (OriginRecord -> IO (Either OwnershipFault ()))
  -> IO (Either OwnershipFault (Recorded session object))`, which `recordOwnedOrigin` calls with its
  `kind` after its clause gate and `recordReportedOrigin` calls with `ReportedObject claim`.
- Every production caller passes the claim it now wraps: `Cluster/Ownership.hs` (one site, `claim`),
  `Ensure/Colima/Ownership.hs` (two sites, `claim`), `Ownership/Shipped.hs` (three sites,
  `symbolicLinkClaim linkTarget`) and `Substrate/Provider/Ownership.hs` (two sites, `ownedShareClaim share`
  and `claim`).
- `releaseOwnedObject` refuses a `Releasable` token whose record kind is `ReportedObject` with
  `OwnershipMalformed` before `rowRemoveObject`. A shipped `ShipGiveBackObject` over a key that holds a
  symbolic-link record is therefore refused and the link stays; the link is given back through
  `ShipGiveBackSymbolicLink`, which releases it through `releaseReportedObject`.

#### Validation

The sprint closes when these hold in `OwnershipSpec` and `OwnershipShippedSpec` and
`cabal test all --ghc-options=-Werror` from `core/` passes:

- the three `reportedTests` cases "the origin a record describes is the observation the caller was
  handed", "clause 2 mints no token when the caller's durable write refuses" and "clause 3 binds the
  identity the owning authority reported" pass `mkOwnerClaim "reported"` in place of `OwnedDirectory`,
  and the first also asserts `fmap originRecordKind recorded @?= Just (ReportedObject (mkOwnerClaim
  "reported"))`;
- "a kernel producer refuses a record about an object it does not answer for" passes
  `mkOwnerClaim "one attempt"` directly and keeps its two `OwnershipUnsupported` assertions;
- the guard "both faces settle each shared clause through one computation" asserts the normalized texts
  `Nothing -> recordOrigin entered kind publish` and
  `recordReportedOrigin entered claim publish = recordOrigin entered (ReportedObject claim) publish` in
  place of `Nothing -> recordReportedOrigin entered kind publish`;
- a new `OwnershipSpec` case binds `originRecord (ReportedObject (mkOwnerClaim "reported")) OriginAbsent` to
  an identity in memory, re-enters it, and re-observes it against `unreachableRow fullCapabilities` with
  `rowObserveIdentity` answering that identity, so a `Releasable` token is minted; `releaseOwnedObject` on
  that token returns `OwnershipMalformed`, its forget continuation is never invoked, and `rowRemoveObject`
  stays the diverging primitive, so reaching it would not finish;
- a new `OwnershipShippedSpec` row case takes a symbolic link with `ShipTakeSymbolicLink`, asserts that
  `ShipGiveBackObject` on the same frame is refused and the link survives, and then asserts that
  `ShipGiveBackSymbolicLink` gives it back.

#### Remaining Work

- `Primitive.hs`: move the body of `recordReportedOrigin` into the unexported `recordOrigin`, have
  `recordOwnedOrigin` call `recordOrigin entered kind publish`, change `recordReportedOrigin`'s second
  parameter to `OwnerClaim` and define it as `recordOrigin entered (ReportedObject claim) publish`, and
  correct its Haddock to say the reported face records only a reported object.
- Drop the `ReportedObject` wrapper at the eight production call sites named in Deliverables.
- `OwnershipSpec`: rewrite the four `recordReportedOrigin` cases and the shared-computation guard string
  as listed in Validation.
- `Primitive.hs`: add a `ReportedObject` arm to `releaseOwnedObject` that refuses with `OwnershipMalformed`
  before `rowRemoveObject`, and add the `OwnershipSpec` release-refusal case and the `OwnershipShippedSpec`
  give-back case listed in Validation.

### Sprint 16.66: The Colima report classifiers check every name they return [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Report.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`

#### Objective

Every Colima and Docker listing the direct-Colima owner reads passes through one strict classifier that
checks exit, standard error, framing, shape, and duplicates, so a context or profile name the owner compares
against is a well-formed name. The Docker-context listing applies the same name-shape check the Colima
listing applies, and the lax Colima listing parser, which applies none of those checks, is deleted.

#### Deliverables

- `classifyDockerContextListing` refuses with `ColimaReportShape` a context name that is empty, longer than
  255 characters, or holds a character outside `'!'`..`'~'`, the check `classifyColimaListing` applies to
  `ciName`.
- `HostBootstrap.Ensure.Colima.Report` defines no `parseColimaInstances`, and the public
  `HostBootstrap.Ensure.Colima` does not re-export it; Colima listings are read only through
  `classifyColimaListing`.

#### Validation

The sprint closes when these `ColimaSpec` cases exist and pass under `cd core && cabal test all`:

- `classifyDockerContextListing (CapturedRun ExitSuccess "{\"Name\":\"\"}\n" "")` and a listing whose name
  holds a space are each `Left ColimaReportShape`;
- the case "raw Colima JSONL remains plan-independent observation data" runs `classifyColimaListing` over a
  `CapturedRun ExitSuccess` of its two rows (`demo` running on `docker`, `other` stopped on `incus`) and
  asserts the same two `ColimaInstance` values.

#### Remaining Work

- `Ensure/Colima/Report.hs`: apply the name-shape check to every `dockerContextName` in
  `classifyDockerContextListing`, and add the two shape cases in Validation.
- Delete `parseColimaInstances` from `Ensure/Colima/Report.hs` and its export and import in
  `Ensure/Colima.hs` (nothing in production calls it), and move the "raw Colima JSONL" case onto
  `classifyColimaListing` as Validation states.

## Static Validation Evidence

On 2026-08-10, the published
`docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64` image at
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`, running Linux
6.8.0-100-generic on aarch64 with GHC 9.12.4 and Cabal 3.16.1.0, passed a clean
`cabal test all --ghc-options=-Werror` from `core/`: all 1,835 tests passed in 154.12 seconds. A supporting
macOS arm64 run passed the same 1,835 tests in 346.23 seconds. The Linux result closes the static portion of
the phase gate; the exact composed static-plus-live result is recorded below.

On 2026-08-20, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all --ghc-options=-Werror` from `core/`: all 2,336 tests passed in 300.51 seconds, including
the described cluster commands, the cluster report classifiers, the cluster resumption decisions, and the
owned cluster's reconcile driver against a real protected store and a real cluster client process. The
same host passed `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231. § II makes this a gate-host record rather than a
substrate declaration, and it does not substitute for the composed live gate below.

On 2026-08-21, the same Windows host and toolchain passed `cabal test all --ghc-options=-Werror` from
`core/`: all 2,351 tests passed in 309.21 seconds, including the readiness, cordon, and release
transactions Sprint 16.45 adds — each against a real protected store and a real cluster client process,
with the three replacement windows reached by that client rather than by a patch point. The same host
passed `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
at 231. § II makes this a gate-host record rather than a substrate declaration, and it does not substitute
for the composed live gate below.

## Phase-Level Baseline Acceptance

After the implementation sprints pass their static checks, run the exact phase gate on a disposable
linux-cpu host:

```text
(cd core && cabal test all --ghc-options=-Werror) && hostbootstrap test run cluster-live
```

The run must create a fresh isolated Kind cluster, wait for all nodes Ready, perform a read-only status
observation, delete the cluster, prove its labelled node containers absent, and re-read the exact durable-root
sentinel outside the deletion boundary. Record the date, host/OS/architecture, GHC/Cabal/Kind/Kubernetes
versions, duration, and result here.

On 2026-08-10 the live half passed on its own in the published arm64 Linux CPU base environment against the
host Docker engine after creating and deleting a fresh Kind cluster. That independent result validates the
live mechanics separately from the composed result.

**2026-08-10 — passed.** The composed gate of that date ran in the published
`docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64` image at
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`, on Linux
6.8.0-100-generic aarch64 with GHC 9.12.4, Cabal 3.16.1.0, Kind v0.32.0, kubectl client v1.36.3, and
Kubernetes node v1.36.1. It exited 0 in 455 seconds. The static half passed all 1,835 tests, and the live
half created `hostbootstrap-phase16-19575488ca6342ebaeebffa2`, waited for its nodes to become Ready,
performed the required read-only node observation, deleted the cluster, proved its labelled node containers
absent, and re-read the durable-root sentinel with its exact original contents.

**2026-08-21 — passed.** On Linux 7.0.0-28-generic x86_64 with GHC 9.12.4, Cabal 3.16.1.0,
Docker 29.7.1, Kind 0.32.0, kubectl 1.36.4, and Kubernetes 1.36.1, the final composed gate exited 0.
The static half passed all 2,300 tests in 135.52 seconds. The live half then created and cordoned
`hostbootstrap-test-run-53dce11d81dc3`, reached node readiness, returned the client/server version,
deleted the cluster through the exact same closed-over plan, proved no matching container remained, and
re-read the byte-identical sentinel outside the deletion boundary. The harness reported 1/1 passed.

That dated evidence covers cluster ownership/readiness/cordon/release without the active automatic-exposure
contract. It remains valid for those subjects but does not close Sprint 16.1 or the rewritten phase gate.

**2026-08-22 — passed.** On Linux 7.0.0-28-generic x86_64 with GHC 9.12.4, Cabal 3.16.1.0,
Docker 29.7.1, Kind 0.32.0, kubectl 1.36.4, and Kubernetes 1.36.1, the final rewritten gate passed.
The warning-clean static half passed all 2,435 tests in 233.39 seconds; the same tree also passed the
Python code gate and all 231 Python tests. The live half created and cordoned
`hostbootstrap-test-run-5a2ebba3ffefc`, reached node readiness, concurrently asked Docker for two
loopback-only publications of the same container listener without either host port, authenticated two
distinct runtime-selected mappings, removed both exact container identities, and proved both names absent.
It then returned the Kubernetes client/server version, deleted the Kind cluster through the retained plan,
proved no matching node container remained, re-read the byte-identical durable-root sentinel, and reported
1/1 passed. A prerequisite run without `kubectl` additionally refused before cluster creation with the exact
missing-tool diagnostic instead of timing out.

**2026-09-12 — passed.** On Linux 7.0.0-28-generic x86_64 with GHC 9.12.4, Cabal 3.16.1.0,
Docker 29.7.1, Kind 0.32.0, kubectl 1.32.0, and Kubernetes 1.36.1, the composed gate passed after the
four closing sprints. The static half passed all 2,533 tests in 182.70 seconds; the same tree also
passed the `demo/` leg at 150 plus 2,533, the Python code gate, and all 251 Python tests. The live half
exited 0 in 28 seconds: it created and cordoned `hostbootstrap-test-run-c08210e51f916` with
`docker update --cpus 2 --memory 2147483648 --memory-swap 4294967296`, reached node readiness, returned
the Kubernetes client and server versions, deleted the cluster through the retained plan, and left the
durable root in place, reporting 1/1 passed.

**A note on this host's kubectl.** `/usr/local/bin/kubectl` is a dangling symlink into a removed RKE2
installation, so the first attempt could not resolve the tool. The run above used a v1.32.0 client placed
ahead of it on `PATH`; nothing on the host was changed. A prerequisite refusal for a missing `kubectl`
is the behaviour the 2026-08-22 entry already records, so this was a host condition rather than a defect.

**2026-09-13 — passed.** On x86_64 Ubuntu 24.04.4 with Docker 29.7.1, Kind 0.32.0, and kubectl 1.37.0
against a Kubernetes 1.36.1 server, the composed gate the header's `**Gate evidence**` row records passed;
the live half created and cordoned `hostbootstrap-test-run-c4456ff0010cb` and reported 1/1 passed. Sprint
16.56's Validation carries the full record.

## Remaining Work

- Sprint 16.1a: one shared service predicate bounds `mkPlanExposureIntent`; malformed service and target cases.
- Sprint 16.1b: exposure-preparation refusal cases, and an image reference grammar that refuses `@sha256:` with no repository.
- Sprint 16.1c: nominal roles on `ResolvedExposure` and `PreparedClusterExposure`, with a coercion compile-fail fixture.
- Sprint 16.1d: half-close, accept-retry, and bracketed relay, with `ExposureRelaySpec`.
- Sprint 16.1e: stopped-relay release and recovery, `null` port entries, pull-tolerant creation, tampered-record and refused-removal cases, `Conflict` dispositions, and exact relay refusals.
- Sprint 16.5: the config binder derives its driver from the plan; exact package-projection assertions.
- Sprint 16.7: the creating command reads only the staged prepared config bytes; binder value cases; an exact digest assertion.
- Sprint 16.8: `ClusterUnhealthy` names the owned cluster and remedies with `project down`; identity assertions in the settlement and foreign cases.
- Sprint 16.9: per-node cordon share, failing-cordon cases, exact share-refusal messages, and deletion of `kindNodeCordonArgs`.
- Sprint 16.10: the recovered readiness producer is private and re-probes.
- Sprint 16.11: `releaseRetainedCluster` is the one cleanup (exposure refusal, a body that reads only the
  retained-cluster projection); deletion of the test-only prepared cleanup.
- Sprint 16.13: `ProviderWallReservation` forge and coerce compile-fail fixtures; the prepared-call join checks the reservation's plan and operation; distinct fence, attempt, and version values in the fence case.
- Sprint 16.14: the `PreparedProviderStart` Haddock claims only the boundary its fixtures pin.
- Sprint 16.15: a closed successful permit observation with migrated as `Repaired`, explicit observation and provider arms, and the `Budget.Internal` importer allow-list.
- Sprint 16.17: one shared protocol validator, exact-reason mutation and framing cases, and the binding Haddock.
- Sprint 16.18: one owner/mode policy evaluated by both layouts, and a hostile-ambient case that runs the resolver.
- Sprint 16.19: real-process timeout, output-limit, leader-exit, and cancellation cases; the shipped child's standard input is the null device.
- Sprint 16.20: deletion of the test-only resolver override, pure revalidation classifiers, and fingerprint sensitivity cases.
- Sprint 16.21: manifest-walk refusal and entry-kind cases, raw-byte names and link targets, and descriptor-relative entry description.
- Sprint 16.22: no-follow Docker-config parent creation, a socket-length predicate, and namespace driver cases.
- Sprint 16.23: a pre-context listing refusal at acquisition, listing-decided presence and a fingerprint check before context removal with a readback after it, and manifest-bounded release through `releaseManifestRemainder`.
- Sprint 16.24: re-acquire after `Released`, driver routed through `decideColimaStage`, and the `Released` replay case.
- Sprint 16.25: `Prepared` plus a present profile fails closed; start-failure, readback-refusal, and exclusion cases.
- Sprint 16.27: private `deriveColimaNames` with derivation cases, the shared-profile lineage case, and one `default` refusal.
- Sprint 16.29: private `Ensure.Colima.Ownership` sublibrary and the `ImportColimaOwnership.hs` fixture.
- Sprint 16.30: pure acquisition-fault mapping with ownership refusals as `WallRefused`; deletion of `classifyColimaWall`.
- Sprint 16.31: private settlement constructors and static settlement cases.
- Sprint 16.32: live-Docker timeout and lineage cases; a run that executed is reported as executed.
- Sprint 16.34: cleanup lineage-refusal case.
- Sprint 16.35: retry-stable cleanup invocation digest and cleanup-call preparation cases.
- Sprint 16.36: scripted-interpreter cleanup failure, fencing, and readback cases.
- Sprint 16.37: committed-release completion as a pure decision, and non-installing cleanup discovery.
- Sprint 16.38: `cluster-live` through the owned backend; deletion of the legacy `Lifecycle` drivers and dead entry points.
- Sprint 16.40: a bounded cluster interpreter, and a read-only status case that proves nothing changes.
- Sprint 16.41: Kind diagnostics without `--quiet`, a regex-escaped node name, and the readback Haddock.
- Sprint 16.42: direct framing refusals, an `Either`-valued API readiness, an ASCII-framed node list, and set comparison of nodes.
- Sprint 16.43: claim-checked standings and the residual-window Haddock.
- Sprint 16.44: worker-first bind, private `Cluster.Ownership`, per-tool fixture executables, kubeconfig fsync and republication, forgetting records after a refused create, and exact observation assertions.
- Sprint 16.45: post-delete release resumption, `ClusterStillPresent` and retained-release refusal cases, record-forget order, and exact refusal assertions.
- Sprint 16.46: Kind required for nvkind, a tool declaration that governs discovery, bounded record keys, single-entry reconcile, observed readiness identity, and discovery and source-guard cases that prove their names.
- Sprint 16.47: Colima stage resumption, `Released` published last, re-entry-only admission and settlement, sealed stage types, ASCII owners, and the `colimaBounds` Haddock.
- Sprint 16.48: the sibling config decoded through the codec witness, Bare reports through `Fail`, name-based relay cleanup, kubectl bound to the run's kubeconfig, value tests, and a `runBareHostBootstrapCLI` Haddock that names the relay containers.
- Sprint 16.49: removal of the Python candidate from the Colima resolver, protocol, fingerprint, and backend.
- Sprint 16.54: a golden commitment, a non-ASCII pair, and backend-level commitment cases in place of the identity assertion.
- Sprint 16.55: a validated run key and a teardown that cannot reach the durable root.
- Sprint 16.57: typed Colima profile and context arguments, a subcommand-aware route guard, byte-exact command framing, and deletion of `colimaCommandTools`.
- Sprint 16.58: Colima classifier, stage-transition, sensitivity, and pinned-vector cases; pure cases on every gate host; non-vacuous live and parent-death cases.
- Sprint 16.59: a package-private storage-wall permit, non-success settlement cases, and storage tokens shared with the production launch renderers.
- Sprint 16.60: a positional manifest entry, validated prefixing, raw-byte paths, a POSIX path grammar, and a pure manifest suite.
- Sprint 16.61: WSL idle-timeout Haddocks that state the bound and cite the observed gate.
- Sprint 16.62: the direct Linux GPU host answers its `ResourceEnvelope` with a typed unsupported-wall decision that the demo's direct reservation reports.
- Sprint 16.63: `Ensure.Colima` drops `sha256Text` for `HostBootstrap.Digest.sha256Hex`.
- Sprint 16.64: make `dependencyProbe` package-private, mint every `DependencyProbe` from backend evidence, and
  index it by readiness kind so a probe of the wrong kind cannot satisfy an edge.
- Sprint 16.65: `recordReportedOrigin` takes an `OwnerClaim` through one shared clause-2 helper, with its
  eight callers and the reported-face cases adapted; `releaseOwnedObject` refuses a `ReportedObject` record.
- Sprint 16.66: a name-checked Docker-context listing, and deletion of `parseColimaInstances`.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — settled backend routes and their consumers.
- `documents/architecture/durable_state.md` — the never-delete invariant and the preserve policy.
- `documents/architecture/hostbootstrap_core_library.md` — exact cluster and direct-Colima library surfaces.
- `documents/architecture/lifecycle_state_model.md` — raw observations versus exact prepared and settled
  packages.
- `documents/architecture/ownership_invariant.md` — the cluster and Colima locked-origin clause holders.
- `documents/architecture/readiness.md` — backend-minted dependencies, the readiness-kind-indexed dependency
  probe, and identity-bound cluster readiness.
- `documents/architecture/unrepresentable_state.md` — provider-start, settlement, live, and cleanup authority
  boundaries and their named compile-fail evidence.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the gate kinds this phase closes on and the run it records.
- `documents/engineering/cluster_lifecycle.md` — exact plan-owned bring-up, status, readiness, and teardown.
- `documents/engineering/applied_cordon.md` — the pure preflight and the applied constructive slice.
- `documents/engineering/resource_budgeting.md` — generic budget admission and exact cluster/Colima consumers.
- `documents/engineering/ensure_reconcilers.md` — why the direct Colima wall is not a config-free reconciler.

**Cross-references to add:**
- `development_plan_standards.md` § K records the fixed private direct-Colima resolver as a closed host-tool
  resolution form; § O names this phase as the owner of the applied cordon; §§ EE/HH bind ownership and
  bounded child lifetime to the exact consumer.
