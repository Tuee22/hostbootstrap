# Phase 16 — Cluster lifecycle, budgets, and cordoning

**Status**: Done
**Depends on**: Phase 12 (the generic plan-indexed budget boundary), Phase 14 (the four ownership clauses
and the ownership seam), Phase 15 (host providers and the self-reference lift)
**Substrates**: linux-cpu
**Gate**: `cd core && cabal test all` on the gate host that runs it (§ C;
cross-family confirmation belongs to the
[host-portability acceptance phase](phase-29-host-portability-acceptance.md)), composed with
the bare core binary's `hostbootstrap test run cluster-live` on linux-cpu
**Gate kind**: deferred
**Gate evidence**: 2026-11-10 ; x86_64 Ubuntu 24.04.5 LTS under WSL2 (Linux 6.18.54.1-microsoft-standard-WSL2), Docker 29.9.3, Kind 0.32.0, kubectl v1.36.3 client against a Kubernetes v1.36.1 server, Helm 4.3.1, GHC 9.12.4 and Cabal 3.16.1.0 ; `cabal test all --test-show-details=direct --test-options=--hide-successes` from `core/` (5336 tests, 6787 seconds), composed with the bare core binary `hostbootstrap test run cluster-live` ; pass ; covers 5da4b257fc6eefe93883fb07eea32da530cbd1f0accec054734c35bad8ec1e8f
**Evidence covers**: `core/hostbootstrap-core/src/HostBootstrap/Cluster` `core/hostbootstrap-core/internal/cluster-ownership` `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs` `core/hostbootstrap-core/internal/colima-backend` `core/hostbootstrap-core/internal/cluster-backend` `core/hostbootstrap-core/internal/cluster-exposure` `core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs` `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs` `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs` `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs` `core/hostbootstrap-core/internal/reconcile-error` `core/hostbootstrap-core/hostbootstrap-core.cabal` `core/hostbootstrap-core/internal/effect-command` `core/hostbootstrap-core/internal/colima-ownership` `core/hostbootstrap-core/internal/wall-observation` `core/hostbootstrap-core/internal/provider-start`

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
  for creation; it requires `Nvkind` and also `Kind`, which lists, reads back, and deletes its cluster.
- Every effect the backend performs is a described `HostCommand` run by the one interpreter over the
  configuration's resolved tools; no caller-supplied executor, tool path, or command string reaches it. The
  per-command deadline and process-group reaping belong to the shared bounded cluster interpreter of Sprint 16.38, which resolves each described launch once
  and retains its standard input through the one grouped runner.
- Public call-result constructors remain opaque and nominal. Sprint 16.46d pins the physical import
  and exact non-function capability fields.

#### Validation

`ClusterBackendSpec` covers admission with every tool resolved, refusal of a configuration missing
one tool, nvkind discovery that does not fall back to Kind, refusal of a package whose driver differs from the
discovered one (the assertions that admission runs no probe and that the refusal issues no command are
Sprint 16.46d's owed cases), and the source guard that the hidden backend module retains capability data and no injected
executor. Compile-fail fixtures `ImportClusterBackendInternal.hs`, `ForgeStrongClusterBackend.hs`, and
`OpenClusterBackendExecutor.hs` reject the hidden module and backend construction from a downstream component.

#### Remaining Work

None.

### Sprint 16.1a: Semantic cluster exposure intent [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
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

One Lifecycle predicate governs both plan intent construction and Backend managed-record/readback.
The predicate is ordinary data validation and grants no authority. The export inventory names its
one public definition. The constructor's target and internal-port checks retain their behavior.

Twelve new cases call the public mkExposureIntent route. The exact 128-character service is retained;
129 characters, NUL, empty service, each of slash/backslash/colon/CR/LF/tab, and empty/spaced target
hosts refuse with Left (Failure _). Existing exact-retention and port-0/65536 cases remain.
Before the production change ten cases pass and the overlong/NUL cases fail for incorrect admission.
All twelve boundaries and 25 portability cases pass on Linux (4.90 reported seconds). All 312 focused
cluster backend, lifecycle, portability, sealed-export and documentation cases pass natively on Windows.

Plain builds with tests enabled pass on Linux core (47.529525 wall seconds), Linux demo (24.329188)
and native Windows core (10.348829). The complete host-static gate passes on 2026-11-06 UTC in
hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0
and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T02:42:47.335437+00:00 | 2026-11-06T02:55:21.191846+00:00 | 753.935635 | 4731 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T02:42:47.335681+00:00 | 2026-11-06T02:55:02.720934+00:00 | 735.462546 | 4731 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T02:42:47.335569+00:00 | 2026-11-06T02:42:48.135056+00:00 | 0.799570 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T02:42:47.340616+00:00 | 2026-11-06T02:42:53.205594+00:00 | 5.865592 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1175-file source snapshot before and after in both trees.
The production change is 15 non-empty lines in Lifecycle (9) and Backend (6); all other 198
production modules and all 708 compile-fail fixtures retain baseline bytes. Changed files retain LF.
The backslash protocol datum uses the same character-code convention as PortabilitySpec, keeping
the guard intact. The initial full attempt reports only that literal-data guard failure; the corrected
complete run is recorded above. The phase remains Active with its other named implementation and
composed live gate still owed.

#### Remaining Work

None.

### Sprint 16.1b: Plan-bound prepared exposure [Done]

**Status**: Done
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

Nine new cases call the actual preparation boundary through the existing already-applied fixture
cordon. They assert exact DoNotRetry failures for a mutable image, empty or duplicate service set,
129 distinct services, empty repository and CLI-option prefix. Each invocation compares the stored
records, fixture mutation history and relay state before and after; preparation publishes nothing.
The grammar vectors retain canonical named digests, registry ports, bracketed IPv6 registries, tags,
the exact 255-character path and 128-character tag bounds, and canonical sha256 image IDs. They refuse
invalid repository components, empty or malformed tags/ports/registries, larger bounds, noncanonical
digests and repeated digest separators. Before the change five cases pass and four fail because
invalid images are admitted; all nine corrected cases pass (3.84 reported seconds).

A private pure parser validates the Docker named-reference grammar and exactly one canonical digest;
no dependency, executor or public export is added. All 321 focused backend, lifecycle, portability,
sealed-export and documentation cases pass natively on Windows (54.86 reported seconds).
Plain builds with tests enabled pass on Linux core (27.261489 wall seconds), Linux demo (39.205250)
and native Windows core (28.167769). The complete host-static gate passes on 2026-11-06 UTC in
hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0
and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T03:08:01.051418+00:00 | 2026-11-06T03:19:00.102944+00:00 | 659.098624 | 4740 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T03:08:01.051325+00:00 | 2026-11-06T03:18:32.251600+00:00 | 631.245796 | 4740 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T03:08:01.050715+00:00 | 2026-11-06T03:08:01.940596+00:00 | 0.889946 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T03:08:01.050324+00:00 | 2026-11-06T03:08:07.311411+00:00 | 6.261563 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1175-file source snapshot before and after in both trees.
The production change is 71 non-empty lines in Backend; all other 199 production modules and all
708 compile-fail fixtures retain baseline bytes. Changed files retain LF. The phase remains Active
with its other named implementation and composed live gate still owed.

#### Remaining Work

None.

### Sprint 16.1c: Opaque runtime-resolved exposure [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeResolvedExposure.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/CoerceResolvedExposureRoles.hs`
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

RoleAnnotations and two four-index nominal role declarations seal the prepared and resolved
exposure datatypes. The registered CoerceResolvedExposureRoles fixture attempts eight distinct
coercions: resolved scope, plan, cluster and service, and prepared scope, plan, cluster and frame.
Before the production change the complete fixture compiles, reproducing the gap. Afterward the
fixture fails compilation with all eight exact type-mismatch diagnostic categories. Raw constructor
forgery and the network exposure role fixture also remain rejected. All 38 focused compiler and
loopback exposure cases pass (5.45 reported seconds), including exact runtime lookup and cross-service
absence. No runtime producer, command or serialized representation changes.

All 322 focused backend, lifecycle, portability, sealed-export, documentation and new coercion cases
pass natively on Windows (63.66 reported seconds). Plain builds with tests enabled pass on Linux core
(25.127186 wall seconds), Linux demo (38.323464) and native Windows core (30.732727).
The complete host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5 x86_64
under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T03:23:56.520565+00:00 | 2026-11-06T03:35:20.882551+00:00 | 684.398761 | 4741 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T03:23:56.520355+00:00 | 2026-11-06T03:34:55.371299+00:00 | 658.886648 | 4741 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T03:23:56.520984+00:00 | 2026-11-06T03:23:57.498574+00:00 | 0.977644 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T03:23:56.520834+00:00 | 2026-11-06T03:24:03.188779+00:00 | 6.668324 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1176-file source snapshot before and after in both trees.
The production change is three non-empty lines in Backend; all other 199 production modules and all
708 existing compile-fail fixtures retain baseline bytes. One new compile-fail fixture is added.
Changed files retain LF. The phase remains Active
with its other named implementation and composed live gate still owed.

#### Remaining Work

None.

### Sprint 16.1d: Binary-owned bounded relay process [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-exposure/HostBootstrap/Cluster/Exposure/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ExposureRelaySpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/Spec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/engineering/cabal_layout.md`, `documents/architecture/hostbootstrap_core_library.md`,
`documents/engineering/testing.md`, `DEVELOPMENT_PLAN/system-components.md`

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

The relay is compiled once in the private cluster-exposure-internal unit consumed by Main and
core-test. Its public marker route retains the same validated argument parser. The downstream
ImportClusterExposureInternal fixture refuses the actual hidden private-package category.
The exact production-source guard includes the new source root, and the module inventory and
canonical layout, library, testing and cluster documentation describe that owner.

Twelve new cases pass with real in-process loopback sockets and ordinary errno values. A client
half-closing its request receives the complete 98304-byte response. A later occupied-listener bind
refuses and the earlier endpoint cannot be connected to and can be rebound. Cancellation while two
upstream connections are open joins workers, makes both clients observe an exact empty read, and
leaves both listener endpoints absent and bindable. The fixture occupies the same wildcard address
without reuse. The errno cases check immediate retries for ECONNABORTED/EINTR, backoff for EMFILE,
ENFILE, other and missing errno, and stop for EBADF/EINVAL/ENOTSOCK.

Worker groups close admission, shut down and close owned listeners and accepted/connecting sockets,
then cancel and join every retained worker. This order wakes native Windows socket calls before
waiting for them. Each copy direction signals separately; a clean first EOF waits for the opposite
completion while an exception releases both. Listener acquisition is bracketed across later bind
failures. No shell, proxy executable or new upstream dependency is introduced.

All 88 selected relay, hidden-import, source-root, portability, sealed-export and documentation cases
pass on Linux (10.13 reported seconds) and native Windows (18.43). The initial Linux selection passes
160 of 161 cases, refusing only the old import-message expectation. The initial Windows cleanup run
is terminated after its verified owned process stalls; closing before cancellation and orderly socket
shutdown remove that stall and preserve EOF, as the final native run establishes. The full CLI cases
in those initial selections complete; the final Linux gate below includes the complete suites.

Final plain builds with tests enabled pass on Linux core (15.534844 wall seconds), Linux demo
(10.701408) and native Windows core (0.823574, up to date after the native build). The complete
host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2,
UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T04:04:18.320587+00:00 | 2026-11-06T04:16:06.212907+00:00 | 707.910727 | 4753 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T04:04:18.325186+00:00 | 2026-11-06T04:15:36.640194+00:00 | 678.332704 | 4753 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T04:04:18.324837+00:00 | 2026-11-06T04:04:19.110265+00:00 | 0.785451 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T04:04:18.336684+00:00 | 2026-11-06T04:04:24.158885+00:00 | 5.822385 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1177-file source snapshot before and after in both trees.
One production module moves to its private root: 143 changed non-empty logical lines, or 357 when
the removed and added files are counted in full. All other 199 production modules and all 709
existing compile-fail fixtures retain baseline bytes. One test module is added; changed files retain
LF. The phase remains Active with its other named implementation and composed live gate still owed.

#### Remaining Work

None.

### Sprint 16.1e: Owned relay reconcile, recovery, and release [Done]

**Status**: Done
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

- A newly created relay already stopped returns a bounded retryable failure; the next call may recover
  its pending ownership record and recreate it.

#### Validation

Backend distinguishes an authenticated stopped relay from a running inspection. Only a running
inspection may mint resolved endpoints. Both release routes authenticate stopped identity/name/
labels with an empty publication map; forward recovery removes that exact owned relay, proves its
absence and forgets the old record before creating fresh ownership, identity and runtime mappings
under the same protected entry. A fresh creation already stopped refuses once; the next invocation
can recover its pending record. Null image EXPOSE entries are filtered while the non-null set must
remain exact. Quiet creation retains strict container-ID framing and admits successful pull progress
on stderr before authenticated inspection. Replaced node/relay identity and corrupt-record refusals
are precise Conflict values; other command failures retain their retry disposition.

The real second-process fixture stores running state and full service/listener/host/target tuples,
requires the kind network and TCP publications, models pull/null/removal outcomes and mints identities
from a persistent monotonic counter. Thirteen new cases prove both stopped-release routes, fresh
managed and pending recovery, null-port handling through recorded observation/release, pull progress,
exact target association, observed node-replacement identity, both refused-removal routes, and invalid
UTF-8/trailing-whitespace/re-spaced record refusal before mutation. Two existing replacement cases
now require the exact Conflict reason. Relay contents, record presence and mutation history are
preserved on the refused paths. All 15 focused lifecycle and exact-refusal cases pass on Linux
(1.98 reported seconds); all 334 backend, lifecycle, portability, sealed-export and documentation
cases pass natively on Windows (63.63).

Plain builds with tests enabled pass on Linux core (29.186712 wall seconds), Linux demo (22.966036)
and native Windows core (24.437509), after the warning policy caught one unused stopped-branch
binding. The complete host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T04:34:03.099333+00:00 | 2026-11-06T04:47:31.755934+00:00 | 808.670451 | 4766 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T04:34:03.098722+00:00 | 2026-11-06T04:46:56.255560+00:00 | 773.170150 | 4766 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T04:34:03.099005+00:00 | 2026-11-06T04:34:03.971872+00:00 | 0.872881 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T04:34:03.099111+00:00 | 2026-11-06T04:34:09.555218+00:00 | 6.456230 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1177-file source snapshot before and after in both trees.
The production change is 118 non-empty lines in Backend; all other 199 production modules and
all 709 compile-fail fixtures retain baseline bytes. Changed files retain LF. The phase remains
Active with its other named implementation and composed live gate still owed.

#### Remaining Work

None.

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

### Sprint 16.5: Exact plan-owned cluster consumer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/CrossPlanClusterConsumer.hs`,
`demo/src/HostBootstrapDemo/ClusterConfig.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/engineering/resource_budgeting.md`

#### Objective

Join the exact cluster package projected by one admitted `ProjectPlan`.

#### Deliverables

- `PlanOwnedCluster` has two constructors. `withPlanOwnedCluster` builds the plan-side one from one
  `ProjectPlan`, its matching cluster and provider `PlannedResource`s, the exact retained `DerivedTopology`,
  and the matching cluster `ResourceSlice` from Phase 12, retains the project's closed driver declaration, and derives the owner binding from the stable plan
  snapshot digest and the cluster resource key.
- `withExecutionOwnedCluster` builds the execution-side `ExecutionOwnedCluster` from the executing
  `StepExecution`, the cluster and provider `PlannedResource`s, the cluster `ResourceSlice`, and the
  project's closed driver declaration, with no
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
- Driver selection is retained at the initial declaration join; rendered-config binding cannot rewrite
  the base package's driver or node set. Both Kind and nvkind therefore remain expressible before binding.
- The config binder `withPlanOwnedClusterConfig` derives the closed driver from the joined package's resolved
  plan, as it derives paths and node identities; no caller supplies a driver.

#### Validation

The plan-side and execution-side cluster joins retain the project's closed driver declaration
when they build the resolved plan. Core and demo config binders read that retained choice, take
no driver argument and cannot rewrite driver or node suffixes. The demo moves its existing
context-selected driver to the execution join. A narrow ordinary-data planOwnedClusterDriver
projection is registered in the public export inventory; the complete resolved plan stays private.

Two new Kind/nvkind cases pass. Their common fixture independently asserts the initial joined
package's driver equals the declaration, then the bound config driver equals the retained package.
The complete-package case compares the exact admitted project name, the durable root plus
cluster/kind/state path, and stablePlanSnapshotDigest (renderSnapshot plan) plus :core:deploy-kind,
beside exact placement, provider key and budget. The existing CrossPlanClusterConsumer fixture
retains all four foreign resource/topology/slice inputs and the four intended compiler mismatch
categories after adding an ordinary Kind declaration. RawPlanAsClusterReconcileSource remains
rejected. All 97 focused package, compiler, portability, export and documentation cases pass on
Linux (12.70 reported seconds) and native Windows (20.14).

Plain builds with tests enabled pass on Linux core (58.979859 wall seconds), Linux demo (53.864598)
and native Windows core (52.151227). The initial build refused imports of the deliberately private
resolved-plan projection; consumers now use the narrow driver projection. The complete host-static
gate passes on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2, UID 1000,
GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T05:02:34.747957+00:00 | 2026-11-06T05:13:28.490412+00:00 | 653.750491 | 4768 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T05:02:34.748272+00:00 | 2026-11-06T05:13:06.575903+00:00 | 631.835402 | 4768 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T05:02:34.748506+00:00 | 2026-11-06T05:02:35.520674+00:00 | 0.772177 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T05:02:34.748622+00:00 | 2026-11-06T05:02:40.592060+00:00 | 5.843509 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1177-file source snapshot before and after in both trees.
The production change is 43 non-empty lines in three modules: Lifecycle (32), demo ClusterConfig (7)
and demo Commands (4). All other 197 production modules and 708 unchanged compile-fail fixtures
retain baseline bytes; only CrossPlanClusterConsumer changes its ordinary driver argument.
Changed files retain LF. The phase remains Active with its other named implementation and composed
live gate still owed.

#### Remaining Work

None.

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

### Sprint 16.7: Prepared cluster reconcile transaction [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`,
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

The ownership descriptor retains the StrongClusterBackend's prepared bytes and SHA-256. In the
same protected entry, creation writes those bytes beside its private kubeconfig, reads the config
back and hashes it before passing its private path to the creating process. A mismatched digest
returns ClusterOwnershipConfig without issuing a create. A bracket removes both files and the
private directory on completion or refusal; withBinaryFile also closes the credential handle on
exception. Retained release needs no creation config.

FakeCluster reads and records the actual file named by each create's --config argument. Three
backend cases compare that recorded body with preparedClusterConfigBytes when the consumer file
is unchanged, overwritten, or removed, and verify that the staged config and directory are gone.
The wrong-digest ownership case observes no create invocation or mutation; a refused child create
records the exact config bytes and leaves neither staging file nor directory.

Eleven binder value cases exercise both Kind and nvkind: an exact positive, wrong digest, wrong
state and config paths, hostPort and extraPortMappings bytes, empty and duplicate intents, the
other driver's mappings, and empty and duplicate workloads. Each refusal equals its exact
ClusterPackageMismatch message. Production preparation compares the entire plan-derived path
and childConfigDigest of the retained bytes. The previous cwd-relative binder source scan is
absent. Existing public-constructor and compatibility compile-fail fixtures retain their bytes.

All 167 focused cluster and documentation cases pass on Linux (18.75 reported seconds) and
native Windows (63.57). Production builds pass in core and demo on Linux and core on Windows;
explicit core test builds pass on both systems. Initial compilation caught a shadowed local name
and a now-unused text-search import; both were corrected before the successful checks. The
complete host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5 x86_64
under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T05:28:51.109024+00:00 | 2026-11-06T05:40:57.320093+00:00 | 726.217922 | 4783 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T05:28:51.109330+00:00 | 2026-11-06T05:41:05.446521+00:00 | 734.344112 | 4783 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T05:28:51.108891+00:00 | 2026-11-06T05:28:52.403741+00:00 | 1.294860 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T05:28:51.109254+00:00 | 2026-11-06T05:28:57.702748+00:00 | 6.593560 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1177-file source snapshot before and after in both trees.
The production change is 89 non-empty lines across three modules: Ownership (73), Backend (9)
and Reconcile (7). All other 197 production modules and all 709
compile-fail fixtures retain baseline bytes. Changed files retain LF. The phase remains Active
with its other named implementation and composed live gate still owed.

#### Remaining Work

None.

### Sprint 16.8: Identity-bound cluster settlement [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
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
  all running (Sprint 16.46b). Its `Conflict` names it as that — this plan's owned cluster with stopped node
  containers, with its identity — and its remedy is to start the stopped node containers or run
  `project down`, which releases the cluster through its ownership record. It never calls the cluster
  same-named or foreign and never directs out-of-band removal while its records are bound, because removing
  it by hand leaves bound records over an absent cluster (`NodeVanished`), which no later `up` or `down`
  completes.
- Constructors and plan indices remain hidden or nominal across the public library boundary.

#### Validation

The managed handle retains its actual backend identity separately from the prepared journal
generation. The public managedClusterBackendIdentity projection exposes only ordinary identity text;
the handle constructor and binding remain private and all existing nominal roles remain unchanged.
The export inventory pins that projection.

An owned cluster with stopped node containers yields a Conflict naming this plan's ownership and
actual control-plane identity. Its remedy starts the containers or runs project down through the
ownership record. The strengthened case checks the exact observed text, the record-owned release
route and refusal of automatic deletion, and rejects foreign-cluster and manual-removal advice.
It fails against the unmodified conflict message, then passes with the declared recovery wording.

Both foreign settlement cases retain the resource key and actual planted container identity,
including when a prior commit proof is supplied. Their stronger assertions exposed the backend's
refusal-message projection. The backend now observes the control plane with the ordinary two-query
ownership observation under the same protected entry and retains its actual immutable identity.
No managed handle is offered. An absent control plane remains a probe failure; a new process case
asserts that exact failure and zero mutations. ClusterBackendSpec also compares the raw foreign
observation with its exact planted identity. The generation separation case reads the actual
managed backend identity and compares it with fixtureNodeIdentity of the declared control plane.

All 158 focused cluster, export inventory, constructor-forgery, nominal-role and documentation cases
pass on Linux (18.07 reported seconds) and native Windows (57.16). Production and test builds pass
in Linux core and demo and native Windows core. The complete host-static gate passes on
2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4,
Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T05:52:26.089117+00:00 | 2026-11-06T06:02:33.976883+00:00 | 607.892625 | 4784 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T05:52:26.082983+00:00 | 2026-11-06T06:02:51.118625+00:00 | 625.040630 | 4784 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T05:52:26.088855+00:00 | 2026-11-06T05:52:26.895742+00:00 | 0.806890 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T05:52:26.109391+00:00 | 2026-11-06T05:52:32.394947+00:00 | 6.285603 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1177-file source snapshot before and after in both trees.
The production change is 28 non-empty lines across three modules: Backend (21), Reconcile (5)
and Observation.Internal (2). All other 197 production modules and all
709 compile-fail fixtures retain baseline bytes. Changed files retain LF.
The phase remains Active with its other implementation and composed live gate still owed.

#### Remaining Work

None.

### Sprint 16.9: Applied cluster cordon [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`,
`core/hostbootstrap-core/test/CordonSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/applied_cordon.md`,
`documents/engineering/cluster_lifecycle.md`,
`documents/engineering/resource_budgeting.md`

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

clusterNodeBudgetShare divides every canonical budget dimension by the exact node count with
integer floors. It refuses empty and negative counts, or CPU, memory or storage below that count,
before a renderer or ownership query. Both clusterNodeCordonArgs and cordonOwnedCluster consume
the same calculation. The ownership driver renders one node's share and still compares every
bound container identity before and after application.

The two-node wall case compares exact one-CPU/two-GiB limits on each node, checks that both CPU
and memory sums fit the declared two-CPU/four-GiB slice, and retains two actual update mutations.
It fails against the undivided driver. A smaller CPU slice refuses with its exact typed budget
message before even an ownership query, and records no update. Six new CordonSpec value cases
pin floors, aggregate conservation, zero and negative counts, and all three undersized dimensions.
LifecycleSpec's existing CPU and empty-topology cases now compare exact refusal messages.

The numeric Docker-limit fixtures preserve their complete renderer refusals before ownership
queries. CPU, minimum-memory and byte-precision failures use the declared two-node shares.
Swap overflow uses one actual declared node: a valid two-node canonical memory envelope cannot
produce that overflow after division. The initial focused run caught the invalid doubled envelope;
the corrected fixture declares and creates its exact topology and preserves the refusal proof.

FakeCluster has one-shot actual child-process update-refusal and update-stderr switches. The two
new backend cases observe ClusterCordonResultFailed and settle to Failure, offering no applied
authority. A refused update records no mutation; a successful noisy update records the effect but
still grants no AppliedClusterCordon. The unused whole-budget kindNodeCordonArgs function and
export are absent; its value cases use the explicit node renderer, the public export inventory
pins the shared calculation, and the legacy ledger no longer lists the removed function.
Three governed cordon/budget documents describe the actual per-node cap.

All 491 focused cordon, lifecycle, ownership, backend, export and documentation cases pass on Linux
(67.78 reported seconds) and native Windows (75.96). All-component builds with tests enabled pass
in Linux core and demo and native Windows core. Werror caught three test-helper field-name
collisions; their arguments are renamed. BudgetSpec's typed unsupported node-storage case and the
constructor/compatibility compiler cases pass in the complete host-static gate on 2026-11-06 UTC
in hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4,
Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T06:18:47.099968+00:00 | 2026-11-06T06:29:41.613548+00:00 | 654.518142 | 4793 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T06:18:47.100529+00:00 | 2026-11-06T06:29:17.423645+00:00 | 630.327519 | 4793 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T06:18:47.100158+00:00 | 2026-11-06T06:18:47.865779+00:00 | 0.765629 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T06:18:47.100639+00:00 | 2026-11-06T06:18:53.129207+00:00 | 6.028610 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1177-file source snapshot before and after in both trees.
The production change is 59 non-empty lines across three modules: Cordon (26), Lifecycle (24)
and Ownership (9). All other 197 production modules and all 709
compile-fail fixtures retain baseline bytes. Changed files retain LF. The phase remains Active
with its other implementation and composed live gate still owed.

#### Remaining Work

None.

### Sprint 16.10: Identity-bound cluster readiness [Done]

**Status**: Done
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

ClusterReadiness and its recovered constructor live in the hidden cluster observation module.
The public Reconcile facade exports the abstract readiness type and no recovered producer. The
export inventory pins that boundary, and ImportRecoveredClusterReadiness.hs is registered with
the exact does-not-export diagnostic. Existing constructor-forgery and nominal-role proofs still
reject authority fabrication and plan relabelling after the representation move.

A private nominal VerifiedClusterProbeResponse binds a canonical positive response to the carried
resource and logical generation, package commitment and nonce. The private recovered producer
consumes that checked response; an ordinary Word64 is no construction route. The backend retains
the actual runtime-service invocation, allocates a fresh sequence nonce for every reprobe, verifies
each returned response and refuses sequence exhaustion instead of wrapping. No retained observation
version is replayed. The initial and later responses keep logical package generation separate from
native readiness observation versions.

The existing chart fixture drives the clause-holding backend and its cluster client process against
temporary state, applies the cordon, registers its real runtime service and opens recovered readiness. Its fixture-owned carrier wraps the existing
service only to record canonical probe nonces, then delegates unchanged to that same service. It
uses the already permitted core representation and pure wire parser; no hidden execution module
is made visible and no substitute service supplies observations. Two new backend cases call the
recovered probe twice, observe distinct initial/first/second nonces and advancing real versions.
Arming FakeCluster's actual API-unready child behavior before the second call yields the runtime's
not-ready Failure rather than a cached version. Both cases and the public import proof fail against
unchanged production, then pass after the producer and reprobe changes.

All 173 focused cluster, workload, export, constructor, nominal-role and documentation cases pass
on Linux (20.86 reported seconds) and native Windows (75.97). All-component builds with tests enabled
pass in Linux core and demo and native Windows core. The complete host-static gate passes on
2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4,
Cabal 3.16.1.0 and Poetry 2.4.3. Governed readiness and cluster-lifecycle docs describe the hidden
producer, verified service responses and fresh reprobes; both profiles' staged config binding is explicit.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T06:48:47.636332+00:00 | 2026-11-06T07:00:42.460659+00:00 | 714.828851 | 4796 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T06:48:47.636464+00:00 | 2026-11-06T07:00:23.370808+00:00 | 695.738750 | 4796 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T06:48:47.635870+00:00 | 2026-11-06T06:48:48.566377+00:00 | 0.930511 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T06:48:47.659819+00:00 | 2026-11-06T06:48:54.133128+00:00 | 6.473347 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1178-file source snapshot before and after in both trees.
The production change is 176 non-empty lines across three modules: Reconcile (48), Backend (54)
and Observation.Internal (74). All other 197 production modules and all
709 existing compile-fail fixtures retain baseline bytes; the one new import fixture
has LF. Changed files retain LF. The phase remains Active with its other implementation and
composed live gate still owed.

#### Remaining Work

None.

### Sprint 16.11: Conditional cluster cleanup [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/durable_state.md`

#### Objective

Delete only the exact managed cluster whose immutable backend identity still matches its origin.

#### Deliverables

- `releaseRetainedCluster` in `Cluster/Backend.hs` is the one cluster cleanup. Every root
  `down`/`destroy`, failed-`up` cleanup and child reverse reaches it. A retained reverse holds
  the canonical cluster plan, and the ownership store under that plan's state directory supplies
  the claim and bound identities that authorize conditional deletion.
- Inside one protected entry it refuses while the cluster's exposure record exists, re-reads the claim and
  every bound node identity, invokes deletion only while they match, and forgets the records only over a
  reported absence.
- Exact absence settles cleanup. A replacement is left standing with its records retained; a failed
  deletion, a node still reported present, or a store or report failure preserves the uncertain state and
  is a typed failure.
- No test-only prepared cleanup shape stands beside it.

#### Validation

releaseRetainedCluster holds one protected entry while refusing an outstanding exposure record,
recovering the recorded claim and conditionally releasing every bound node. A relay record returns
the exact owned-exposure refusal before deletion. The rewritten backend case drives this production
API, observes both records and the cluster/relay unchanged, releases the relay through its recorded
route, then invokes the same retained release and observes exact absence with records retired.
The case fails against unchanged production, which deleted the fixture cluster while its relay row
still stood.

A new FakeCluster delete-refusal switch makes the actual child client refuse before mutation.
The retained-delete case observes the typed release Failure and its real diagnostic, unchanged
cluster and node state, every protected record still present and no delete mutation. Production
and Harness retained-reverse cases still release the exact run-scoped state. ClusterOwnershipSpec
continues to pin normal/absent/pending-origin release, no removal of a never-bound cluster, and
preservation of a same-named replacement.

The unused prepared-cleanup type, call result, result view, factory, projections, observation and
settlement no longer exist in the public facades or private observation representation. Only their
test callers, ForeignClusterCleanup.hs and its registration, and the two cleanup-only constructor/
role diagnostic categories are removed. The other thirteen constructor and eleven plan-role
categories remain rejected. A new source guard rejects the obsolete authority names in Backend
and Reconcile while requiring runExactClusterCleanupKernel, the real lifecycle entry used by
Command.LifecycleEntry. The public export inventory and legacy ledger match this surface.

All 204 focused cleanup, ownership, remaining compiler boundaries, export and documentation cases
pass on Linux (21.87 reported seconds) and native Windows (72.92). All-component builds with tests
enabled pass in Linux core and demo and native Windows core. The complete host-static gate passes
on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4,
Cabal 3.16.1.0 and Poetry 2.4.3. Governed cluster lifecycle and durable-state docs describe the
single retained cleanup transaction and its exposure/deletion refusal behavior.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T07:24:33.108687+00:00 | 2026-11-06T07:36:22.537999+00:00 | 709.433469 | 4796 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T07:24:33.108825+00:00 | 2026-11-06T07:35:54.335952+00:00 | 681.231122 | 4796 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T07:24:33.109116+00:00 | 2026-11-06T07:24:34.049790+00:00 | 0.940673 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T07:24:33.109203+00:00 | 2026-11-06T07:24:39.986536+00:00 | 6.877373 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1177-file source snapshot before and after in both trees.
The production change is 191 non-empty added/removed lines across three modules: Reconcile (110),
Backend (68) and Observation.Internal (13). All other 197 production modules and
707 unchanged compile-fail fixtures retain baseline bytes. Only the two remaining
cluster authority fixtures change their cleanup rows; the obsolete foreign-cleanup file is removed.
Changed files retain LF. The phase remains Active with its other implementation and composed live
gate still owed; the retained coordinate projection has its own following sprint.

#### Remaining Work

None.

### Sprint 16.11a: Retained cluster cleanup projection [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/durable_state.md`

#### Objective

Describe exactly the retained cluster coordinates that conditional cleanup reads. The public release
signature's adoption of this projection in place of a ClusterPlan belongs to the worked-demo phase,
whose callers include `Command/Child/Reverse.hs`.

#### Deliverables

- An ordinary retained-cluster projection in `Cluster/Lifecycle.hs` carries only cluster name, declared
  node names, state directory and kubeconfig path. Its constructor derives them together from one
  `ClusterPlan`; the projection grants no ownership authority and exposes no durable root.
- `releaseRetainedCluster` constructs that projection once at entry and reads only its projections
  while opening the protected store and constructing the owned descriptor. The public signature
  remains `HostConfig -> ClusterPlan -> IO (Either ReconcileError ())`.
- The conditional transaction still reads its claim and bound identities under the same protected entry;
  the data projection does not substitute for any ownership clause.

#### Validation

RetainedClusterProjection is ordinary descriptive data with a hidden constructor and four selectors:
cluster name, declared node names, state directory and kubeconfig path. Its pure constructor derives
them together from one ClusterPlan and stores no durable root or ownership authority.
releaseRetainedCluster keeps its public HostConfig/ClusterPlan signature, constructs the projection
once and reads only these coordinates to open the store and describe the owned cluster. The same
protected entry still checks exposure absence, recovers the recorded claim and conditionally releases
the bound identities; no ownership clause moves into the data projection.

ClusterBackendSpec's `retained Harness projection contains the exact run-scoped coordinates` applies
the constructor to both kind and nvkind plans and compares the literal per-run name, complete declared
node list, `.test_data/run-17/cluster/<driver>/state` and its `cluster.kubeconfig` path. Its
`retained release reads only one projection without a durable root` pins the single construction,
all four coordinate reads and absence of direct plan/durable-root accessors in the release body.
Existing `retained reverse conditionally deletes the cluster and retires its record`,
`retained Harness reverse resolves the exact run-scoped store`, relay-first refusal and driver-delete
refusal cases pass against the protected store and real fixture client process. The sealed export
inventory admits only the ordinary type, constructor function and four selectors.

All 360 focused backend, lifecycle, ownership, export and documentation checks pass on Linux
(62.60 reported seconds) and native Windows (66.67). All-component builds with tests enabled pass
in Linux core and demo and native Windows core. The full host-static gate passes on 2026-11-06 UTC
in hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and
Poetry 2.4.3. The cluster lifecycle and durable-state docs describe the exact coordinate view and
its lack of ownership authority.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T07:45:38.688361+00:00 | 2026-11-06T07:56:41.601932+00:00 | 662.917366 | 4798 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T07:45:38.688005+00:00 | 2026-11-06T07:56:14.358439+00:00 | 635.674077 | 4798 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T07:45:38.686965+00:00 | 2026-11-06T07:45:39.565954+00:00 | 0.878991 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T07:45:38.688098+00:00 | 2026-11-06T07:45:44.902460+00:00 | 6.214400 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1177-file snapshot before and after in both trees. The production
change is 46 non-empty added/removed lines across two modules: Lifecycle (29) and Backend (17).
All other 198 production modules and all 709 compile-fail fixtures
retain baseline bytes. Changed files retain LF. The public release signature's caller adoption is
still owned by the worked-demo phase; the phase remains Active with its other work and composed
live gate owed.

#### Remaining Work

None.

### Sprint 16.12: Structural durable-root exclusion [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Teardown.hs`,
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

### Sprint 16.13: Journal-bound provider-wall reservation [Done]

**Status**: Done
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

preparePlanOwnedProviderWallCall binds the reservation's retained plan digest and provider operation
key and compares both against the exact supplied plan and provider resource before preparing the call.
The private ProviderWallReservation representation and all ten nominal roles retain baseline bytes;
the public constructor stays hidden. The lower pure budget algebra and Step action quantification
are unchanged.

BudgetSpec's `a reservation cannot size another provider operation sharing its fence` admits one
real plan containing two distinct provider resources and a cluster. Both real protected-store gates
use fence 7, attempt 3 and first-write journal version 1. For provider B's wall, B's own reservation
prepares a call with fence 7; A's reservation returns exactly
`Left (InvalidProviderPackage "the reservation was journaled for another provider operation")`.
Against unchanged production the same case fails because both preparations return `Right 7`.
The existing `the exact journal gate mints the provider reservation fence` now also uses the distinct
7/3/1 values and asserts `Right 7`, so reading the attempt or journal version cannot pass accidentally.
Wrong-plan, wrong-operation and zero-fence reservation cases still return their exact refusals.

CompileFailSpec registers `ForgeProviderWallReservation.hs`, rejected for illegal term-level use of
the hidden constructor, and `CoerceProviderWallReservationRoles.hs`, rejected independently for its
PlanA/PlanB and FenceA/FenceB coercions. The existing caller-fence, cross-partition and hidden-internal
fixtures remain rejected. All 110 focused budget, compiler, export and documentation checks pass on
Linux (8.15 reported seconds) and native Windows (9.88). All-component builds with tests enabled pass
in Linux core and demo and native Windows core. The resource-budgeting and lifecycle-state docs
state the exact reservation join and preserve the separate unchecked gate-producer gap.

The complete host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5 x86_64
under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T08:03:58.451797+00:00 | 2026-11-06T08:14:33.749268+00:00 | 635.301090 | 4801 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T08:03:58.451517+00:00 | 2026-11-06T08:14:04.937677+00:00 | 606.489616 | 4801 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T08:03:58.451197+00:00 | 2026-11-06T08:03:59.204307+00:00 | 0.753111 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T08:03:58.451862+00:00 | 2026-11-06T08:04:04.438219+00:00 | 5.986390 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1179-file snapshot before and after in both trees. The production
change is 11 non-empty added/removed lines in Budget alone. Budget.Internal and all other
198 production modules retain baseline bytes, as do all 709 existing
compile-fail fixtures; only the two named reservation fixtures are added. Changed and added files
retain LF. Phase 12.30 stays Done: this sprint revalidates its pure boundary without changing it.
The phase remains Active with its other work and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.14: Exact prepared provider start [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/internal/provider-start/HostBootstrap/Reconcile/ProviderStart/Internal.hs`,
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

PreparedProviderStart's Haddock now describes exactly its boundary: its constructor is private,
projection of the retained journal pair needs the package-private projection capability, and
completion needs the owning backend result from the hidden module. It also states that generic
reconciliation can produce a managed provider ResourceHandle, including Running, and that this
is neither the owning provider backend's managed wrapper nor bound-exec authority. The lifecycle
state model and unrepresentable-state docs state the same distinction and cite the existing fixtures.

No executable Haskell or test code changes. ReconcileSpec's
`provider force destroy is journal-prepared from the exact running handle` still exercises the
generic created/booted Running route. CompileFailSpec continues to reject
`ForgePreparedProviderStart.hs`, `CoercePreparedProviderStartRoles.hs`,
`ImportProviderStartInternal.hs`, `GenericProviderHandleAsManaged.hs` and
`GenericProviderHandleAsBoundExec.hs` for their registered constructor, role, hidden-module and
managed-wrapper diagnostics. All 203 focused reconciliation, compiler, export and documentation
checks pass on Linux (13.25 reported seconds) and native Windows (20.63). All-component builds with
tests enabled pass in Linux core and demo and native Windows core.

The full host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under
WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T08:20:00.866468+00:00 | 2026-11-06T08:30:44.558687+00:00 | 643.695844 | 4801 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T08:20:00.866025+00:00 | 2026-11-06T08:30:18.766641+00:00 | 617.904091 | 4801 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T08:20:00.866652+00:00 | 2026-11-06T08:20:01.643853+00:00 | 0.777206 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T08:20:00.866149+00:00 | 2026-11-06T08:20:06.665089+00:00 | 5.798972 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1179-file snapshot before and after in both trees. The only source
change is 11 non-empty added/removed Haddock lines in Reconcile; removing block comments yields
byte-identical executable source. ProviderStart.Internal, the other 198 production
modules, every existing test module and all 711 compile-fail fixtures retain baseline
bytes. Changed files retain LF. The phase remains Active with its other work and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.15: Backend-produced provider-wall settlement permit [Done]

**Status**: Done
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

The hidden permit's observation field is now SettledWallObservation, the closed applied,
already-exact and migrated success sum. The mint constructs it only for positive epochs and
explicitly refuses each invalid-epoch and non-owning raw observation constructor. Settlement is
total over those three successes: Created, Unchanged and Repaired respectively. It no longer
contains unreachable raw failure branches or a second epoch guard. Its provider decision names
all six constructors, producing the WSL global-wall lease only for Wsl2ProviderKey.

BudgetSpec's five `private provider-wall settlement` cases link the actual built Main-unit kernel
through the repository's existing temporary private-interface compiler pattern. The regular test
mixin, package visibility and public compiler refusals are unchanged. The control uses real
Fixture/PrepareFixture plan and journal gates with fence 7, attempt 3 and physical version 1, seals
an operation/preconditions pair through generic preparation, and joins that exact lineage to its
fixture prepared wall call. Typed HUnit assertions run in the temporary executable; it substitutes
no settlement function or observation interpreter.

`a migrated wall settles its positive epoch as Repaired` observes epoch 7 and Changed Repaired.
`a zero-epoch migrated wall is refused at the mint` compares the exact settle-provider-wall Failure,
invalid-epoch diagnostic and DoNotRetry disposition. Before the fix both cases fail because the
actual mint returns a non-owning migrated observation. The WSL applied case returns epoch 7,
Changed Created and the WSL continuation; the Colima already-exact case returns epoch 7, Unchanged
and the ordinary continuation. The non-owning case separately compares exact refusal values for
zero applied/already-exact epochs, conflict, failure and uncertainty.

`only the budget facade and owning Colima bridge import the private kernel` enumerates every
Haskell source under src/, internal/ and app/, reads UTF-8 bytes, lexically checks the complete
importer set, and requires the bridge's explicit import list to contain neither reservation nor
prepared-call constructors. Existing forge, role, raw-observation and hidden-module compile-fail
fixtures remain rejected. All 120 focused budget, compiler, export and documentation cases pass on
Linux (14.91 reported seconds) and native Windows (16.49). All-component builds with tests enabled
pass in Linux core and demo and native Windows core. Both governed docs state the success-only
permit, migrated result, WSL branch and private importer boundary.

The full host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under
WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3. These are static private-kernel controls,
not a live provider resize or native Colima acceptance run.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T08:47:43.782066+00:00 | 2026-11-06T08:58:35.419864+00:00 | 651.641442 | 4807 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T08:47:43.782568+00:00 | 2026-11-06T08:58:06.982985+00:00 | 623.203907 | 4807 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T08:47:43.786288+00:00 | 2026-11-06T08:47:44.614429+00:00 | 0.828143 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T08:47:43.782378+00:00 | 2026-11-06T08:47:50.154278+00:00 | 6.371934 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1179-file source snapshot before and after in both trees. The
production change is 76 non-empty added/removed lines in two modules: Budget (52) and Budget.Internal
(24). All other 198 production modules and all 711 existing compile-fail
fixtures retain baseline bytes. Changed files retain LF. The phase remains Active with its other
work and composed live gate owed; Sprint 16.16 is already Done, so the next open sprint is 16.17.

#### Remaining Work

None.

### Sprint 16.16: Canonical Colima root/data storage-wall binding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Cordon/Foundation.hs`,
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

### Sprint 16.17: Trusted resolver wire protocol [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Protocol.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver.hs`,
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

validateTrustedProtocol owns the content policy for both the wire decoder and settleTrustedProtocol,
including native in-process observations. Both carry the exact production or fixture layout. Tool
paths, formula/Docker allowlists, positive device/inode identities, ordered unique helper paths and
complete helper-directory bindings are checked before authority construction. Wire parsing separately
checks canonical Word64 decimal spelling and exact one-report framing. Native typed identities do
not supply an alternate content policy. The binding-fingerprint Haddock now names the private
component boundary that confines its exported constructor.

ColimaSpec's `exact content refusals` has seventeen single-field/tag mutations of valid READY and
MISSING_COLIMA reports built from the native harness's layout. Both positive report branches are
admitted before mutation. Cases pin exact Colima, Docker, Lima, Brew, tool-path, device, inode,
identity, helper-path, helper-binding-paths, helper-binding-shape and invalid-reason refusals; they
also distinguish malformed and noncanonical decimal identities. These pure cases run on every
host. The formula-prefix check uses the layout host's path separator so the Windows fixture grammar
is tested as well as the Linux one.

`the resolver rejects malformed, decorated, truncated, and cross-branch reports` compares exact
framing or shape reasons for all eleven inputs, including doubled output, output plus a newline
and CRLF decoration. `native settlement rejects a colon in the Colima helper directory` observes
the filesystem-backed native fixture returning a READY protocol from a 1:x Colima version, then
observes the same shared settlement return exactly resolver-helper-path without decoding its wire.
The Testing view returns descriptive execution/settlement views only. Linux executes that native
filesystem case; Windows executes the native resolver's declared Apple-platform refusal and the shipped runner's
Windows refusal. The pure content/framing cases execute on both.

All 78 focused resolver, hidden-import, export and documentation checks pass on Linux (5.88 reported
seconds) and native Windows (6.63). All-component builds with tests enabled pass in Linux core and
demo and native Windows core. The ensure-reconciler and ownership-invariant docs describe the shared
validation boundary and distinguish descriptive wire data from authority.

The complete host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5 x86_64
under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3. No live Colima VM or Apple host
acceptance is claimed by these fixture and pure-protocol checks.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T09:14:08.408455+00:00 | 2026-11-06T09:25:41.623779+00:00 | 693.219206 | 4825 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T09:14:08.408047+00:00 | 2026-11-06T09:25:12.347584+00:00 | 663.943254 | 4825 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T09:14:08.408365+00:00 | 2026-11-06T09:14:09.200331+00:00 | 0.791972 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T09:14:08.407702+00:00 | 2026-11-06T09:14:14.520274+00:00 | 6.112602 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify the same 1179-file snapshot before and after in both trees. The production
change is 285 non-empty added/removed lines in three private resolver modules: Protocol (143),
Resolver (126) and Testing (16). All other 197 production modules and all
711 existing compile-fail fixtures retain baseline bytes. Changed files retain LF.
The phase remains Active with its other work and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.18: Trusted resolver program [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Native.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/PortabilitySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`, `DEVELOPMENT_PLAN/rationale.md`

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

Resolver.Native applies one total owner/mode policy to executable and directory observations.
Production and fixture kinds explicitly name their different owner anchors, then share mode checks
and logical Apple administrative-directory exceptions. Docker Desktop files and directories admit
root or the effective user; formula versions and binary directories retain stricter rules. Thirty-two
pure table cases exercise the production and fixture kinds on every host.

Every admitted entry is opened with no-follow, close-on-exec and nonblocking flags. Its kind and
owner/mode policy are checked, and its device/inode must match pathname observations before and
after opening. Helper bindings carry this checked descriptor identity. ColimaSpec's `native admission
refuses when the kernel cannot open a descriptor` warms a real child and ready fixture, then sets
that child's soft descriptor limit to zero. The case fails against the lstat-only observer with a
ready report and passes against descriptor admission with exactly resolver-system-error.

The hostile-ambient case plants nine executable candidates, saves/sets/checks/restores PATH/HOME
and the working directory, then observes and settles the fixed native targets. PortabilitySpec
confines its one PATH write to that named bracketed probe. Compiler fixtures compare actual GHC
version and canonical library directory, allowing equivalent versioned and selected launchers
while retaining the pin and actual Cabal test/Main-unit bindings.

ProviderBackendSpec's `concurrent creation preserves one origin and permits an explicit retry`
accepts only one creator plus either retained admission or the precise store.lock busy refusal
at protected-store opening or entry. The exact lock-path and busy/locked diagnostics remain
required. One hundred consecutive real-process runs pass, followed by the complete suites below.

All-component builds with tests enabled pass from core and demo in Linux and native Windows.
All 141 focused resolver, portability, documentation, private-import, export and provider-wall
kernel cases pass in Linux and Windows. Linux executes the native POSIX fixture; Windows asserts
the native Apple-platform and shipped-runner refusals and executes the shared pure policy.
No live Colima acceptance is claimed.

The complete four-command host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Each command verifies the same 1179-file snapshot in both source trees before and after. Haskell
temporary files use a bounded 3 GiB tmpfs mount; these are real-kernel static cases and do not claim
crash-durability acceptance.

| Linux command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T13:39:03.506552+00:00 | 2026-11-06T13:48:38.120441+00:00 | 574.622272 | 4858 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T13:39:23.000884+00:00 | 2026-11-06T13:48:20.960052+00:00 | 537.967038 | 4858 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T13:39:03.511444+00:00 | 2026-11-06T13:39:18.528032+00:00 | 15.016811 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T13:39:03.512268+00:00 | 2026-11-06T13:39:23.206639+00:00 | 19.694656 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 175 non-empty added/removed lines in Native (163) and Testing (12).
Resolver and all other 197 production modules retain baseline bytes, as do all
711 compile-fail fixtures. Changed files retain LF. The ownership/reconciler docs and rationale
align with the code. The phase remains Active with its other work and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.19: Bounded direct-Colima runner and supervisor [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/Run.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/DetachedSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Bound every direct-Colima tool process without leaking descendants or swallowing cancellation.

#### Deliverables

- Each tool runs through `runShippedCommand`: the installed binary's hidden transaction entry starts a
  dedicated group under `runBoundedGroupedWithInput`, then retains its PID while supervising the tool
  from the owning parent's group. A finite deadline (1 to 900 seconds) and retained stdin bound the
  command and supervise parent death.
- Timeout and successful tool-exit paths quiesce the complete retained group before its reserved identifier
  may be reused, close or drain both pipes within bounds, and reap without an unbounded wait.
- Terminate and kill escalation reaches the retained group, including a descendant that ignores TERM or
  keeps stdout/stderr open after the leader exits. A completed process handle permits no later group signal.
- Output retention is bounded and parser-visible truncation or pipe failure is a structured backend failure.
  Capture cleanup stops its pipe-reader threads before closing handles, including exceptional exit.
- Haskell asynchronous exceptions terminate/reap the group and propagate unchanged.
- Tool stdin is a readable binary null device with close_fds enabled; the child reads actual EOF.
  DetachedSpec admits no shipped-runner exception to its descriptor-closing disposition guard.

#### Validation

The hidden transaction starts a dedicated group and launches its tool there, then supervises
from its owning parent's group. Its live PID reserves the tool group through final signals and
bounded quiescence. Tool exit kills residual members before returning its status; owner death
kills the retained group and supervisor. Tool stdin is a readable binary null device with
close_fds enabled, so a read observes actual EOF.

Generic escalation retains its unreaped leader before the last group signal and permits a
signal only while the process handle still retains that leader. A completed handle disarms late
exception teardown. Only a missing-process probe establishes group absence. Pipe-reader threads
stop before their Handle locks are taken for closure, on normal and exceptional capture exit.
Cancellation still propagates unchanged; excessive output is exactly output-limit.

ColimaSpec's seven bounded shipped runner cases and hard-parent-death case exercise actual
Python and installed-entry processes without Colima. They prove timeout with a TERM-ignoring
descendant; output above 16 MiB; leader exit with retained and closed pipes; a writer that leaves
the process group while keeping a pipe open; unchanged ThreadKilled; null-stdin zero-byte EOF;
and cleanup after owner death. PIDs publish atomically after handler installation and complete
writing. The kernel probe requires a positive ASCII decimal PID and exact successful gone/present
output; probe errors cannot count as absence. The escaped writer has private marker cleanup,
so the fixture never signals an unreserved PID. It exceeds the old capture's teardown bound
and passes the fixed capture's five-second outer deadline. Three earlier process cases also
have a failing baseline; all eight actual-process checks pass with this source.

DetachedSpec's production scan permits no runner exception for closed stdin, and the matching
legacy-ledger row is absent. All-component builds with tests enabled pass in Linux and native
Windows from core and demo. All 145 focused ColimaSpec, EffectSpec, DetachedSpec and DocValidatorSpec
cases pass on both hosts. Linux exercises the actual POSIX process cases; Windows executes the
declared native Apple-platform and shipped-entry refusals. No live Colima acceptance is claimed.

The complete four-command host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Each command verifies the same 1179-file snapshot in both source trees before and after. Haskell
temporary files use a bounded 3 GiB tmpfs mount for real-kernel static cases; these runs do not
claim crash-durability acceptance.

| Linux command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T15:04:31.918715+00:00 | 2026-11-06T15:13:54.020598+00:00 | 562.107199 | 4865 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T15:04:31.918512+00:00 | 2026-11-06T15:13:25.425509+00:00 | 533.512050 | 4865 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T15:04:31.918512+00:00 | 2026-11-06T15:04:32.710201+00:00 | 0.791695 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T15:04:31.918610+00:00 | 2026-11-06T15:04:37.540161+00:00 | 5.621605 | 376 Python cases; 100% coverage; exit 0 |

An additional native Windows x86_64 `cabal test all` from `core/` passes all 4865 cases on
identical production code before the two unconditional POSIX PID checks: 2026-11-06T14:47:51.657748+00:00
to 2026-11-06T14:59:09.130666+00:00, 677.479545 wall seconds. Its source check passes;
removing exactly those two fixture lines reproduces its 1179-file snapshot. Fresh Windows builds
and all 145 focused cases pass on the final tree. This is additional core evidence, not a
four-command Windows gate.

Production changes are 167 non-empty added/removed lines in Runner (74) and Effect.Run (93),
within two source modules. All other 198 production modules and all 711 compile-fail
fixtures retain baseline bytes. Changed files retain LF. The ownership/reconciler docs and rationale
align with the implementation. The phase remains Active with its other work and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.20: Trusted resolver revalidation [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Classify retained ready-toolchain or missing-Colima Brew evidence against fresh resolution through
one total pure classifier per branch. The native-only facade and its effect-site adoption are
owned by Sprint 16.20a; this sprint owns the revalidation policy and descriptive fixture views.

#### Deliverables

- `revalidateTrustedAppleToolchain` and `revalidateTrustedAppleBrew` resolve freshly, then use
  shared pure classifiers over the retained value and fresh `TrustedResolverResult`.
- The ready classifier distinguishes unchanged evidence, `trusted-apple-toolchain-changed` and
  `trusted-colima-missing`; the Brew classifier distinguishes unchanged evidence,
  `trusted-apple-brew-changed` and `trusted-colima-now-present`. Both preserve unsupported reasons.
- `Resolver.Testing` exposes descriptive fixture settlement and classifier results without
  a callback into production resolution.
- Native fixture observations prove the four changed/missing/present refusals through actual
  target replacement and alias removal/restoration, with exact unchanged evidence admitted.
- Toolchain fingerprints agree across unchanged native observations and differ after a tool's
  target identity changes. Assertions hold these relationships rather than mere non-null values
  or a branch predicate already established by its surrounding pattern match.

#### Validation

Both production IO revalidation functions resolve freshly, then apply the same total pure
classifier that the descriptive fixture view uses. Ready evidence admits exact equality and
refuses changed toolchains or missing Colima. Missing-Colima Brew evidence admits exact equality
and refuses changed Brew evidence or newly present Colima. Both preserve fresh unsupported reasons.
The testing view settles actual observations and returns only Either String (); it carries no
callback into production resolution and exposes no authority value.

ColimaSpec's nine-case retained resolver revalidation group uses actual native files and aliases.
It covers both unchanged branches, the four named changed/missing/present refusals, and native
refusal propagation in both branches. Replacement keeps the original inode alive under another
name, preventing reuse from weakening the premise. A fingerprint case compares repeated native
observations and a new tool identity. Existing ready/missing/install cases compare actual
observations and native/wire settlement fingerprints. The adjacent protocol/tool projections
retain their exact baseline bytes.

All-component builds with tests enabled pass in Linux and native Windows, from core and demo.
All nine native cases and all 150 focused resolver, privacy, portability, documentation, export
and provider-wall kernel cases pass on Linux. The same 150 focused cases pass on Windows,
which executes the declared native Apple-platform and shipped-entry refusals. No live Colima
acceptance is claimed.

The complete four-command host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Each command checks the same 1179-file source snapshot in both trees before and after.
Haskell temporary files use a bounded 3 GiB tmpfs mount for real-kernel static cases; these
runs do not claim crash-durability acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T15:38:14.382934+00:00 | 2026-11-06T15:47:58.092784+00:00 | 583.714972 | 4874 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T15:38:14.383482+00:00 | 2026-11-06T15:47:32.458797+00:00 | 558.080220 | 4874 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T15:38:14.383590+00:00 | 2026-11-06T15:38:15.190564+00:00 | 0.806983 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T15:38:14.383530+00:00 | 2026-11-06T15:38:20.029818+00:00 | 5.646338 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 86 non-empty added/removed lines in Resolver (30) and Testing (56),
within two source modules. All other 198 production modules and all 711 compile-fail
fixtures retain baseline bytes. Changed files retain LF. The canonical ownership/reconciler docs
align with the implementation. The phase remains Active with its other work and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.20a: Native trusted resolver facade [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`, `DEVELOPMENT_PLAN/rationale.md`

#### Objective

Expose a private opaque toolchain only after native resolution, strict settlement and fresh
revalidation. The retained/fresh classification policy and descriptive views are owned by
Sprint 16.20. This facade admits the actual host and effective-user namespace before effects.

#### Deliverables

- The facade obtains the effective user's home from the OS account database and freshly admits
  only Apple silicon before the in-process native resolver and strict protocol settlement.
- `TrustedAppleToolchain` retains canonical executable/helper identities and one deterministic
  fingerprint. Constructors and revalidation details remain inside the private component.
- Missing Colima retains the distinct trusted-Brew result. The facade neither installs a package
  nor converts Brew evidence into ready-toolchain authority.
- Production resolution carries no process-global test branch. The native resolver and direct
  backend discovery inspect the actual OS namespace; tests use fixture observation and pure
  settlement/revalidation views without redirecting a production producer.
- Ready acquisition, live Docker and cleanup freshly revalidate their retained ready toolchain
  immediately before and after effects. Unsupported, malformed, missing or drifted resolution
  yields no backend capability.

#### Validation

Production resolution uses the fixed native observer after bootstrap identity validation.
Direct discovery freshly admits the actual Apple-silicon host and reads the effective user's
home from the OS account database. The retained discovery branch equals its baseline after
removing only its outer indentation. The account-database lookup, settlement, install-and-
rediscover path and subsequent effect/revalidation code retain their exact baseline bytes.
Ready and missing-Colima Brew evidence remain distinct, and the pure testing views cannot
redirect production discovery or mint backend authority.

ColimaSpec's production source absence guard reads every Haskell module under both nonempty
source roots. It excludes resolver test-branch names from the backend and ensure modules;
the baseline has matching production names in three modules. The actual native fixture cases
continue to assert effective-home refusal, ready/missing/unsupported settlement, helper drift
and strict content/framing refusals. Windows executes its declared native Apple-platform refusal.
The private component import and sealed public export checks pass. No live Colima acceptance
is claimed.

All-component builds with tests enabled pass from core and demo on Linux and native Windows.
The same 150 focused resolver, source-absence, privacy, portability, documentation, export and
provider-wall cases pass on both gate hosts. All 710 retained compile-fail fixtures preserve
their baseline bytes; the deleted private module has no package entry or import fixture.

The complete four-command host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Each command checks the same 1177-file source snapshot in both trees before and after.
Haskell temporary files use a bounded 3 GiB tmpfs mount for real-kernel static cases; these
runs do not claim crash-durability acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T16:01:52.079702+00:00 | 2026-11-06T16:11:28.979316+00:00 | 576.904531 | 4874 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T16:01:52.079664+00:00 | 2026-11-06T16:11:02.205434+00:00 | 550.130460 | 4874 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T16:01:52.079854+00:00 | 2026-11-06T16:01:52.831457+00:00 | 0.751611 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T16:01:52.079699+00:00 | 2026-11-06T16:01:57.640704+00:00 | 5.561053 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 127 nonempty added/removed lines across three modules: Resolver (37),
Ensure.Colima (47), and the deleted private module (43). All other 197 production
modules retain baseline bytes. Changed files retain LF, and the governed ownership/reconciler
docs align with the native-only producer. The phase remains Active with its other work and
composed live gate owed.

#### Remaining Work

None.

### Sprint 16.21: Manifest-walk kernel behavior and refusals [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/OwnershipPosixSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

The shared POSIX ownership manifest observer admits exact entry kinds and refuses unsafe
objects against the real kernel. Colima uses the shared ownership component and protected store.

#### Deliverables

- A symbolic link to a populated directory contributes only its link entry and exact target bytes.
- Root and descendant directories refuse group/other write permission. Regular files refuse a
  second hard link or group/other write permission; FIFOs refuse as unsupported object kinds.
- Immutable regular files over 4 MiB refuse before content admission. Mutable and immutable
  observation retain the declared file, directory, symbolic-link and Unix-socket entry kinds.
- A foreign-owned descendant refuses where the gate host can arrange that owner. CoverageManifest
  declares both manifest-walk and foreign-owner families, including their unavailable branches.
- Existing descriptor-held creation, open, no-replace publication, removal and synchronization
  primitives keep their kernel coverage; OwnershipSpec retains exact-identity release refusal.

#### Validation

Eight manifest-walk kernel cases pass. A link to a populated external directory yields
exactly its link entry and exact target bytes. Group-writable roots and descendant directories,
a regular file with another hard link, mode 0666 files, FIFOs and immutable files over 4 MiB
each assert the complete expected fault. A bound Unix socket and actual file, directory and
symbolic link keep their m/d/l/s kinds; immutable observation changes the file kind to f.
No production fault token or substitute kernel observation is involved.

CoverageManifest declares the eight-case walk and the one-case foreign-owner family. The
foreign-owner capability is measured by an actual attempted owner change in a private fixture,
including on confined root hosts. The ordinary UID 1000 run asserts the actual permission denial
and reports that subject unavailable. Every Windows case stays and asserts the POSIX manifest
row's exact Unsupported result. Its declared counts and refusal callbacks remain in the gate.

A supplementary UID 0 process changes an actual fixture's owner and asserts the exact foreign-
owner OwnershipOccupied fault. Its output explicitly confirms the exercised row and contains no
unavailable-branch marker. This run checks the same frozen source before and after: 2026-11-06T16:21:02.138402+00:00 to 2026-11-06T16:21:02.415338+00:00; 0.276929 wall seconds; one case; exit 0.

All-component builds with tests enabled pass from core and demo on Linux and native Windows.
All 183 focused ownership, documentation and portability cases pass on both gate hosts. Existing
OwnershipSpec release-identity cases and the POSIX primitive/kernel-lock-death cases also pass.

The complete four-command host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Each command checks the same 1177-file source snapshot in both trees before and after.
Haskell temporary files use a bounded 3 GiB tmpfs mount for real-kernel static cases; these
runs do not claim crash-durability acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T16:22:26.343599+00:00 | 2026-11-06T16:32:20.952046+00:00 | 594.613437 | 4885 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T16:22:26.343650+00:00 | 2026-11-06T16:31:47.157081+00:00 | 560.818147 | 4885 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T16:22:26.343625+00:00 | 2026-11-06T16:22:27.148110+00:00 | 0.804492 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T16:22:26.343644+00:00 | 2026-11-06T16:22:31.910066+00:00 | 5.566470 | 376 Python cases; 100% coverage; exit 0 |

This sprint changes no production Haskell: all 199 production modules and all 710
compile-fail fixtures retain baseline bytes. Only two test modules, the aligned ownership/durable-
state docs and plan metadata differ. Changed files retain LF. The phase remains Active with
its other work and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.21a: Descriptor-relative manifest entry observations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Manifest entry identities and link targets belong to the retained parent descriptor, including
when that directory is renamed and a different tree occupies its former pathname.

#### Deliverables

- Component traversal retains parent descriptors, opens children no-follow, and checks ownership,
  permissions, type and opened-versus-observed identity before use.
- Entry metadata uses fstatat with AT_SYMLINK_NOFOLLOW and link bytes use readlinkat relative to
  that parent. Ambient pathname metadata does not describe entries in the walk.
- Each walk opens an independent directory stream relative to its held parent. Failed fdopendir
  closes that fresh descriptor; successful streams own and close theirs. The descriptor-taking
  walk is the normal path observer's actual implementation.

#### Validation

The ordinary path observer opens its root no-follow and delegates to the descriptor observer.
Root and child descriptors supply the namespace. fstatat with AT_SYMLINK_NOFOLLOW reads entry
metadata; readlinkat supplies exact target bytes. FileStatus uses the pinned unix/base native
stat storage. The bounded link read has one byte beyond the manifest bound, so an overlong
or truncated target cannot be admitted as a valid target.

Every directory stream opens dot relative to its held descriptor with an independent read
offset. Successful streams own and close that descriptor; failed fdopendir closes it through
onException. Repeated observation of one held descriptor therefore starts from a complete
listing rather than inheriting a prior stream's end position.

The kernel rename case observes five actual entries through the root descriptor, renames the
tree and populates its old pathname with different files, a different link target and a distinct
bound socket. The repeated descriptor observation equals the original five-entry manifest;
observation through the replaced pathname differs. Its assertion bytes match the retained
failing evidence exactly. A lexical source guard checks both observers and their native
metadata/link helpers, excluding ambient getSymbolicLinkStatus/readSymbolicLink and requiring
the descriptor-native calls. Windows asserts both observers' exact Unsupported result.

CoverageManifest declares ten walk-family cases, of which nine execute the native row where
available; the lexical guard runs on every gate host. The foreign-owner family retains its
actual availability probe. A supplementary UID 0 process exercises the exact foreign-owner
refusal against the final descriptor implementation, with an explicit exercised-row marker
and no unavailable marker: 2026-11-06T16:57:20.529881+00:00 to 2026-11-06T16:57:20.805791+00:00; 0.275910 wall seconds; one case; exit 0.

All-component builds with tests enabled pass from core and demo on Linux and native Windows.
All 523 focused ownership, authority/export, documentation and portability cases pass on both gate hosts.
The complete four-command host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Each command checks the same 1177-file source snapshot in both trees before and after.
Haskell temporary files use a bounded 3 GiB tmpfs mount for real-kernel static cases; these
runs do not claim crash-durability acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T16:58:35.458588+00:00 | 2026-11-06T17:08:01.946752+00:00 | 566.492861 | 4887 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T16:58:35.459196+00:00 | 2026-11-06T17:07:29.634211+00:00 | 534.179450 | 4887 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T16:58:35.466080+00:00 | 2026-11-06T16:58:36.189301+00:00 | 0.723228 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T16:58:35.479381+00:00 | 2026-11-06T16:58:41.014319+00:00 | 5.534984 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 87 nonempty added/removed lines in one POSIX primitive module. The
other 198 production modules and all 710 compile-fail fixtures retain baseline
bytes. Changed files retain LF, and the ownership/durable-state docs align with the descriptor
walk. The phase remains Active with its other work and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.21b: Raw manifest paths and native consumer adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Manifest.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`, `core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/Spec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`,
`DEVELOPMENT_PLAN/phase-29-host-portability-acceptance.md`

#### Objective

A manifest stores the exact bytes the POSIX kernel names, and its consumers address those same
bytes without a Text or locale round-trip. Its grammar is independent of the gate host.

#### Deliverables

- Directory names are read as raw bytes, including names outside UTF-8; the descriptor observer
  supplies the raw symbolic-link targets.
- Entry paths are ByteString or PosixPath, hex-encoded directly and parsed to the same bytes.
  Prefixing and Colima cleanup adopt those paths through the matching raw-path operations.
- Relative path validation splits only on slash and refuses empty, dot and dot-dot components,
  a leading slash, CR, LF or NUL independently of System.FilePath and the host locale.
- Observing one actual tree under UTF-8 and ASCII filesystem locales produces identical rendered
  bytes. Linux uses LC_ALL=C.UTF-8 and LC_ALL=C; another gate host selects a real UTF-8 locale.
- Raw-name cleanup rechecks the bound root and target identities, traverses no-follow parent
  descriptors, removes with unlinkat, synchronizes the parent and reads back authoritative absence.

#### Validation

Manifest entry paths, prefixing, rendering and parsing carry raw bytes. The POSIX slash-only
relative grammar refuses empty, dot and dot-dot components, leading/trailing or repeated slash,
CR, LF and NUL independently of the compiling host. Native directory names and link targets
stay bytes through descriptor-relative metadata, child opens and settlement; only diagnostics
escape non-ASCII bytes. Regular-file opens are nonblocking before their opened kind is checked.

The Colima remainder consumer keeps its stored-parent re-entry and fresh parent observation.
Its bound root identity and actual entry reach the shared raw-name release primitive. That
primitive revalidates the path, opens/checks the bound root, traverses parents no-follow, and
checks target identity, kind, owner and writable modes before unlinkat. Parent fsync and an
authoritative descriptor-relative absence observation complete removal. The stored-parent source
guard requires the caller's retained evidence and the primitive's actual identity/no-follow/
synchronization/readback operations. The exact export inventory pins the real new primitive.

All seven raw-manifest cases pass. Two exercise the byte vocabulary on every gate host: an
exact byte-ff render/parse round trip and the POSIX relative grammar, including the canonical
profile path. Five native rows cover cross-locale observation; exact removal of raw-named files,
a raw-name directory, a link and a bound socket; target replacement; root replacement; and a
symbolic-parent refusal. Replacement cases retain originals to prevent inode reuse and compare
actual identities and immutable content observations before/after refusal.

The child locale case removes GHC_CHARENC, reports its actual filesystem encoding and proves
UTF-8 versus ASCII, with byte-identical complete manifests. Its actual tree holds byte-ff and
byte-fe names and a link with the exact caf-c3-a9 target bytes. This Linux run selects C.UTF-8
and C; another host can select an available real UTF-8 locale. CoverageManifest declares seven
cases and five native rows; unavailable rows retain and assert the shared total refusal.

All-component builds with tests enabled pass from core and demo on Linux and native Windows.
All 617 focused ownership, Colima, authority/export, documentation and portability cases pass
on Linux, including the updated stored-parent guard. A supplementary UID 0 process exercises
the real foreign-owner refusal with the final implementation and an explicit exercised-row
marker: 2026-11-06T17:47:59.066895+00:00 to 2026-11-06T17:47:59.377658+00:00; 0.310766 wall seconds; one case; exit 0.

The supplementary Windows runtime attempt is interrupted by Microsoft Defender quarantining
the generated test executable and its identity-test copy as Program:Win32/Contebrew.A!ml
(threat 251873). Exit 0 without a completed case total is not passing evidence. No Windows
security setting changes or alternate-copy execution bypass occur. Native Windows runtime
acceptance remains owed by the host-portability phase, whose declared gate hosts own that
confirmation; this sprint closes on its phase's linux-cpu gate host (? C).

The complete four-command host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Each command checks the same 1177-file source snapshot in both trees before and after.
Haskell temporary files use a bounded 3 GiB tmpfs mount for real-kernel static cases; these
runs do not claim crash-durability acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T17:49:14.225721+00:00 | 2026-11-06T17:59:06.824005+00:00 | 592.603203 | 4895 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T17:49:14.225695+00:00 | 2026-11-06T17:58:47.639194+00:00 | 573.418259 | 4895 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T17:49:14.225663+00:00 | 2026-11-06T17:49:23.770846+00:00 | 9.545259 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T17:49:14.225714+00:00 | 2026-11-06T17:49:30.630742+00:00 | 16.405164 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 204 nonempty added/removed lines across Manifest (39), Posix (141)
and Ensure.Colima.Ownership (24). The other 196 production modules and all 710
compile-fail fixtures retain baseline bytes. Changed files retain LF. Ownership/durable-state
docs align with the raw-byte contract, and the Windows interruption is recorded in its owning
acceptance phase. The phase remains Active with its other work and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.22: Colima socket admission and home lifecycle [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`

#### Objective

The isolated Colima namespace fits Darwin's socket ceiling before profile mutation, and home
acquisition/live use refuse symbolic or vanished owned paths without recreating them.

#### Deliverables

- A pure socket predicate over effective passwd home, namespace key and profile is the actual
  backend admission policy. It counts UTF-8 bytes, admits 103 bytes and refuses 104 or more.
- The closed backend environment retains its helper PATH, passwd home and fixed working directory;
  ambient home, tool path, Colima/Lima, temporary and Docker variables do not choose the namespace.
- A pre-planted Colima-home symbolic link refuses acquisition. After acquisition, a removed owned
  home makes the managed Docker driver refuse without running a command or recreating that home.

#### Validation

The backend admission calls the pure colimaSocketNamespaceFits producer over the complete
derived socket path in UTF-8 bytes. ColimaSpec's namespace admission cases "the socket
ceiling admits 103 bytes and refuses 104" and "the socket ceiling counts UTF-8 bytes rather
than characters" cover the exact ASCII and multibyte boundary. The real-kernel case
"a pre-planted home link refuses acquisition without touching its target" requires
OwnershipOccupied, preserves the foreign directory's sole sentinel and exact bytes, and
proves no Docker-config directory appears. CoverageManifest declares three cases and one
native row; the unavailable branch retains and asserts its total refusal.

In ColimaSpec's existing "the direct driver describes every tool effect without running it"
case, the acquired home's actual inode is parked while its original path is absent.
The managed Docker call must return ColimaMutationOwnershipRefused, leave its existing
command collector unchanged and keep the home path absent. The inode is restored for the
fixture's later checks. Before correction this fails with command count 7 instead of 5:
the driver performs listing and machine probes before evaluating the local manifest refusal.
Stage, namespace manifest and retained-binding checks now finish before those probes, in
both pre-command and post-command validation. The unchanged assertion passes after this
production correction. All 621 focused ownership, Colima, authority/export, documentation
and portability cases pass; the three namespace cases pass separately. The multibyte
literal's actual UTF-8 c3a9 bytes are verified after targeted checks catch an initial ASCII
substitution. No new executor, fake binary or production testing branch is introduced.
These checks claim local admission and kernel namespace refusal, with no live Colima claim.

All-component builds with tests enabled pass from core and demo on Linux and native Windows.
Windows is supplementary compilation-only evidence; phase 29 owns its runtime acceptance.
All four host-static commands pass on 2026-11-06 UTC in hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and
Poetry 2.4.3. Each verifies the same 1177-file source snapshot before and after in both
trees. Haskell temporary files use the bounded 3 GiB tmpfs for real-kernel static cases;
these runs do not claim crash durability. Earlier interrupted WSL build preflight is
not passing evidence.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T18:37:12.456197+00:00 | 2026-11-06T18:46:45.405854+00:00 | 572.954303 | 4899 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T18:37:12.456225+00:00 | 2026-11-06T18:46:28.090339+00:00 | 555.638621 | 4899 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T18:37:12.456142+00:00 | 2026-11-06T18:37:16.214971+00:00 | 3.758860 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T18:37:12.456225+00:00 | 2026-11-06T18:37:21.284046+00:00 | 8.827898 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 59 nonempty added/removed lines across Ensure.Colima (7) and
Ensure.Colima.Ownership (52). The other 197 production modules and all 710
compile-fail fixtures retain baseline bytes. Changed files retain LF. Ensure-reconciler
and durable-state docs align with socket admission and home refusal. The phase remains
Active with its other work and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.22a: No-follow parent traversal for POSIX observation and acquisition [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

Identity observation, directory/file creation and exclusive opening use retained parent
descriptors, so an intermediate symbolic link cannot redirect acquisition.

#### Deliverables

- One private component-wise parent traversal holds every opened directory no-follow until
  the primitive completes; the row vocabulary and total Windows refusal remain unchanged.
- Identity lookup is descriptor-relative without following the final link. Directory creation
  and exclusive file creation/opening name the final component relative to the retained parent.
- File synchronization and regular-kind checks remain intact. The reusable profile lock is
  synchronization-only and retains its actual descriptor/inode and process-death lifetime.
- Kernel cases retain outside directory/file identities and bytes across intermediate-link
  refusal, with all native/refusal counts declared.

#### Validation

The shared POSIX row's private withPathParent opens each existing component relative to
its held directory with directory/no-follow/close-on-exec flags, retaining the chain for
the primitive. Identity lookup uses fstatat with AT_SYMLINK_NOFOLLOW at the final component,
so it still observes a final link's own identity. mkdirat creates a directory; openFdAt
creates exclusive whole-file objects and opens the reusable synchronization file relative
to the retained parent. The opened regular-kind check, file fsync and exact kernel-held
fcntl lock remain. The row vocabulary and its total Windows refusal do not change.

OwnershipPosixSpec's four parent traversal cases are "identity lookup refuses a symbolic
parent", "directory creation refuses a symbolic parent", "file creation refuses a symbolic
parent" and "exclusive opening refuses a symbolic parent". Each plants a real parent link
to a populated fixture directory. Immutable manifest observations, explicit root identity
and sentinel bytes compare the actual outside namespace before/after; absent create names
remain absent. An unexpectedly admitted handle is closed before the assertion fails.
All four cases fail against the previous implementation, which follows that parent; all
four pass with this correction and byte-identical test assertions. CoverageManifest declares
four cases and four native rows; unavailable rows retain and assert the total refusal.

All 626 focused ownership, Colima, authority/export, documentation and portability cases
pass, including positive identity/create/write/publication checks and the existing exact
lock and real process-death cases. A supplementary UID 0 run exercises the actual foreign
owner change and requires its refusal marker, with no unavailable-row fallback:
2026-11-06T18:54:08.327793+00:00 to 2026-11-06T18:54:08.593647+00:00; 0.265852 wall seconds; one case; exit 0.

All-component builds with tests enabled pass from core and demo on Linux and native Windows.
Windows remains supplementary compilation-only evidence; phase 29 owns runtime acceptance.
All four host-static commands pass on 2026-11-06 UTC in hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and
Poetry 2.4.3. Every command verifies the same 1177-file source snapshot before/after in
both trees. Haskell temporaries use the bounded 3 GiB tmpfs for real-kernel static cases,
with no crash-durability acceptance claim.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T18:54:23.034377+00:00 | 2026-11-06T19:03:55.290065+00:00 | 572.260323 | 4904 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T18:54:23.034341+00:00 | 2026-11-06T19:03:29.709666+00:00 | 546.679754 | 4904 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T18:54:23.034317+00:00 | 2026-11-06T18:54:23.764907+00:00 | 0.730595 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T18:54:23.034379+00:00 | 2026-11-06T18:54:28.679280+00:00 | 5.644946 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 65 nonempty added/removed lines in Posix alone. The other
198 production modules and all 710 compile-fail fixtures retain baseline bytes.
Changed files retain LF. Ownership and durable-state docs describe the acquisition scope.
The ambient-parent legacy row remains until Sprint 16.22a1 adopts the helper for publication,
removal, synchronization and manifest root opens. The phase stays Active with its other
implementation and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.22a1: Retained parents for POSIX publication, removal and manifest roots [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

Adopt the shared no-follow parent traversal for the remaining parent-sensitive POSIX row
operations and manifest root opens, preserving identity, synchronization and readback.

#### Deliverables

- No-replace publication holds both source and target parent descriptors and performs the
  hard link relative to them; its collision, unsupported and cross-mount faults remain.
- Removal observes the final object through its parent and unlinks that name relative to the
  same parent, refusing a final symbolic link. Parent synchronization uses the held directory.
- Path-based manifest observation and manifest-entry release open their root through the
  same no-follow parent traversal; supplied-descriptor observation keeps its existing meaning.
- Existing stored identity, record/stage, identical-byte replacement, raw-name, process-death
  and authoritative removal-readback checks stay intact. Conditional family counts cover every row.

#### Validation

The shared POSIX row's no-replace publication holds both source and target parents
and calls linkat with flags zero. Removal reads the final name through its held parent,
refuses a final symbolic link and uses unlinkat with the observed directory/file kind.
Parent synchronization fsyncs its held directory. Both path-based manifest observation
and raw-entry release now hold their no-follow parent traversal while opening and using
the root descriptor. Existing exact root/entry identities, owner/mode checks, raw bytes,
parent synchronization and authoritative removal readback remain.

OwnershipPosixSpec's parent settlement family covers publication through a symbolic source
parent, publication through a symbolic target parent, file removal, directory removal,
parent synchronization, manifest observation beneath a symbolic root ancestor and raw-entry
removal beneath that ancestor. Each fixture holds a real populated outside tree; immutable
manifest observations, explicit root identity and sentinel bytes require its unchanged
contents and identities. The target publication name remains absent and its staged source
retains identity and bytes. Manifest removal uses the actual observed root identity and
leaf entry. All seven cases fail on the preceding implementation, which follows parents;
all seven pass with this correction and byte-identical assertions. CoverageManifest declares
seven cases and seven native rows; unavailable branches retain their total refusal.

OwnershipSpec's "POSIX namespace operations retain descriptor-relative parent lookup"
case reads the physical Posix source, forbids the old ambient status/create/link/remove
identifiers, and requires all nine parent-sensitive operations to use the retained-parent
helper. It checks the helper's actual openFdAt/no-follow/directory/cloexec/bracket/close
operations and verifies its lexer against each forbidden identifier control. This eighth
targeted case also fails before correction and passes unchanged afterward. The existing
stored-parent/root/entry identity guard remains intact. The ambient-parent legacy row is
removed only with the implementation and its passing absence guard.

All 635 focused ownership, Colima, authority/export, documentation and portability cases
pass, including existing positive publication, collision, cross-mount, removal, lock and
real process-death checks. A supplementary UID 0 run exercises a real foreign-owner change
and its refusal, requiring the exercised marker without the unavailable-row fallback:
2026-11-06T19:10:20.190573+00:00 to 2026-11-06T19:10:20.866205+00:00; 0.675639 wall seconds; one case; exit 0.

All-component builds with tests enabled pass from core and demo on Linux and native Windows.
Windows is supplementary compilation-only evidence; phase 29 owns its runtime acceptance.
All four host-static commands pass on 2026-11-06 UTC in hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and
Poetry 2.4.3. Each verifies the same 1177-file source snapshot before/after in both
trees. Haskell temporary files use bounded 3 GiB tmpfs for real-kernel static cases;
these runs do not claim crash durability.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T19:11:14.628150+00:00 | 2026-11-06T19:20:41.613300+00:00 | 566.989850 | 4913 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T19:11:14.627713+00:00 | 2026-11-06T19:20:18.410126+00:00 | 543.786915 | 4913 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T19:11:14.627713+00:00 | 2026-11-06T19:11:15.374775+00:00 | 0.747065 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T19:11:14.628090+00:00 | 2026-11-06T19:11:20.307628+00:00 | 5.679584 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 54 nonempty added/removed lines in Posix alone. The other
198 production modules and all 710 compile-fail fixtures retain baseline bytes.
Changed files retain LF. Ownership and durable-state docs align with retained parent entry,
publication, removal and synchronization. The phase remains Active with its other work
and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.22b: Colima Docker-config parent origin records [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`, `documents/architecture/ownership_invariant.md`

#### Objective

The driver owns the Docker-config parent chain below the plan root through shared origin
records and no-follow primitives, retaining those bindings during live use and cleanup.

#### Deliverables

- The 128-bit key derives isolated COLIMA_HOME, Lima, cache, temporary and data paths. Docker
  config stays beside its plan-root record as record-path.docker; mutable namespaces are distinct.
- Namespace preparation creates/opens every required parent component under the protected entry
  through the shared no-follow row, with a bound origin identity for each created parent.
- Live use and cleanup re-enter the retained parent identities. Missing-after-ownership, foreign
  and replaced components refuse rather than being recreated or adopted.
- Cleanup releases created parent records/directories in safe child-before-parent order, preserving
  any shared or foreign contents. No unscoped recursive parent creation precedes acquisition.

#### Validation

The prepared driver delegates context-parent creation to the owned namespace transaction;
its recursive mkdir and unused directory imports are removed. Context parent paths must be
strictly below the protected plan root. Stable root-relative parent keys use length-prefixed
character words and SHA-256, so shared profiles re-enter the same origin records without
lossy filename encoding. Reserved acquisition creates and binds the parents under the entry.
Later preparation, start, artifact observation, settlement, exact managed observation, Docker
use and cleanup re-enter those retained identities rather than acquiring missing records.
Cleanup checks actual identities before and after its read-only manifest observation,
releases empty parents child-first, and preserves nonempty parents with their records.
Completed cleanup can repeat without recreating parents or invoking another tool command.

ColimaSpec's context parents family has eight cases and seven native rows. It covers:
the prepared driver's absence of unscoped parent creation; nested acquisition and exact
re-entry with byte-identical protected records; refusal of an existing unrecorded parent;
a parent link to a populated directory with no child created behind it; a missing owned
parent without recreation; a replaced parent while the original context/child inodes
survive; two profiles sharing the same parent identities and record bytes; and an outside-
root context refused before its directory or home is created. Actual identities, immutable
manifests and sentinel bytes establish the filesystem outcomes. Unavailable native rows
retain their explicit total refusal; all cases compile on Windows.

The baseline targeted run has seven failures out of eight. It exposes missing nested-parent
creation, adoption of an unrecorded parent, the recursive mkdir still in production and an
accepted outside-root context. The symbolic-parent refusal already passes through the shared
no-follow row; the other identity cases initially stop at their missing-parent acquisition
precondition. All eight targeted cases pass after implementation, including their actual
post-acquisition missing/replacement and sharing checks. CoverageManifest declares 8/7.

The existing managed-stage fixture in ColimaSpec's "the direct driver describes every tool
effect without running it" now uses the nested context namespace. Normal cleanup removes
the created parent directories and their records. A fourth SharedParents scenario prepares
a real second profile without starting it, then proves cleanup preserves that profile's
home/context identities, exact Prepared stage and shared parent record bytes. Repeated
cleanup leaves the existing command collector unchanged. The live Docker route also refuses
a missing parent and a replacement parent with preserved child/context identities before
any additional command call. Existing stored-home replacement and captured-version refusals
remain. These additions reuse the existing collector; no new executor, fake binary or
production testing branch is added. The claim is local admission and real-kernel parent
lifecycle behavior; live Colima confirmation remains owned by Apple acceptance.

All 644 focused ownership, Colima, authority/export, documentation and portability cases
pass. All-component builds with tests enabled pass from core and demo on Linux and native
Windows. Those preflights use exactly the final code and tests; only the resolved legacy
ledger row differs from the final gate snapshot. Windows remains supplementary compilation-
only evidence, with native runtime acceptance owed to phase 29.

All four host-static commands pass on the same 1177-file snapshot, checked in both source
trees before and after every command. The gate host is hostbootstrap-linux-d, Ubuntu
24.04.5 x86_64 under WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC
9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3. The Python legs completed before the session
break. Both original Cabal runs ended with SIGHUP and no completed core total; neither
is passing evidence. After the dedicated distro restarted, its empty scratch directory
was verified, its bounded 3 GiB tmpfs restored and UID 1000 write access proved. The
unchanged source's two Cabal legs were then rerun. These real-kernel static runs do not
claim crash durability.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T20:32:53.133900+00:00 | 2026-11-06T20:44:57.692020+00:00 | 724.558112 | 4922 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T20:32:53.133900+00:00 | 2026-11-06T20:44:37.429457+00:00 | 704.295551 | 4922 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T19:43:48.748618+00:00 | 2026-11-06T19:43:52.803185+00:00 | 4.054596 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T19:43:48.748932+00:00 | 2026-11-06T19:43:57.483217+00:00 | 8.734356 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 161 nonempty added/removed lines in Ensure.Colima (4) and
Ensure.Colima.Ownership (157). The other 197 production modules and all 710
compile-fail fixtures retain baseline bytes. Changed files retain LF. The three canonical
docs align with parent provenance and safe cleanup. The legacy row is removed with its
passing physical-source absence guard. The phase remains Active with its other implementation
and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.23: Docker-context admission before namespace acquisition [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Require the named Docker context to be absent before allocating its isolated namespace. The
name-checked listing codec and deletion of the lax Colima parser remain Sprint 16.66's work.

#### Deliverables

- Acquisition whose retained stage is absent or earlier than ColimaContextStaged lists Docker
  contexts before prepareColimaNamespacesInside. A named colima-<profile> returns
  ColimaMutationProfileConflict before directory creation or start.
- The actual admission and stage-threshold decisions are pure total producers over reported
  names and stage values. Resumption at ContextStaged or later keeps its owned context.
- The shipped acquisition uses listDockerContextsCommand and classifyDockerContextListing;
  report/runner refusals remain typed and issue no subsequent acquisition command.

#### Validation

The production acquisition uses the same two pure producers the cases apply.
colimaContextAcquisitionNeedsProbe requires a listing for an absent stage, Reserved,
HomeStaged and HomeReady. ContextStaged and every later stage do not repeat that initial
absence probe. admitColimaContextAcquisition compares the exact colima-<profile> name
and returns ColimaMutationProfileConflict on a collision, without minting authority.

applyAcquisition reads the retained stage under the protected entry. When needed, it
runs listDockerContextsCommand through classifyDockerContextListing and the pure
admission producer before calling applyOwnedAcquisition/prepareColimaNamespacesInside.
A command, report or collision refusal returns without namespace preparation or start.
Existing Managed exact-observation and later-lineage refusals remain intact. The export
inventory pins exactly the two real pure producers added to the ownership module.

ColimaSpec's context acquisition admission group has fourteen cases: an empty listing;
unrelated names and partial matches; the exact name at each listing position; an absent
stage; each of the nine named stages; and the physical consumer guard. The guard requires
the actual stage/listing/classification/admission calls before namespace preparation.
All fourteen pass. The existing one-entry acquisition collector records its leading
context ls, then its original acquisition and Managed re-entry sequence with shifted
step numbers. All 658 focused ownership, Colima, authority/export, documentation and
portability cases pass. No new executor, fake executable or injected native row is added.
These checks establish the actual pure decision and its call-site adoption; the existing
collector is not live provider evidence.

A supplementary real Docker CLI probe uses Docker version 29.9.3, build 5457199, as UID
1000 with a fresh DOCKER_CONFIG target below a missing parent in its temporary directory.
Actual context ls succeeds, reports only the default context and leaves both the target
and parent absent. It uses the real installed executable, an isolated child environment,
no daemon mutation and no existing user configuration. Its dated result is:
2026-11-06T20:59:08.995348+00:00 to 2026-11-06T20:59:09.415252+00:00; 0.419900 wall seconds; exit 0.

All-component builds with tests enabled pass in core and demo on Linux and native Windows.
Windows is supplementary compilation-only evidence; phase 29 owns native runtime acceptance.
All four host-static commands pass on the same 1177-file source snapshot, verified in both
trees before and after every command. The gate host is hostbootstrap-linux-d, Ubuntu
24.04.5 x86_64 under WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC
9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3. Haskell temporaries use the bounded 3 GiB tmpfs
for real-kernel static cases; these runs do not claim crash durability or live Colima
acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T20:59:34.225163+00:00 | 2026-11-06T21:10:14.312427+00:00 | 640.087264 | 4936 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T20:59:34.225166+00:00 | 2026-11-06T21:09:48.333356+00:00 | 614.108190 | 4936 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T20:59:34.225262+00:00 | 2026-11-06T20:59:37.320741+00:00 | 3.095480 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T20:59:34.225131+00:00 | 2026-11-06T20:59:42.719652+00:00 | 8.494524 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 26 nonempty added/removed lines in Ensure.Colima.Ownership alone.
The other 198 production modules and all 710 compile-fail fixtures retain
baseline bytes. Changed files retain LF. The two canonical namespace docs align with the
admission boundary. The phase remains Active with conditional context removal, retained
manifest settlement, its other implementation and the composed live gate owed.

#### Remaining Work

None.

### Sprint 16.23a: Conditional Docker-context removal and absence readback [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Release the named context only while the listing and fingerprint prove it is the retained
owned object, then prove absence before publishing ColimaContextReleased.

#### Deliverables

- Decide presence from classifyDockerContextListing, because inspect cannot distinguish an
  absent context from a failed tool. An unlisted context skips inspect and removal.
- For a listed context, re-enter the stored context-directory binding without acquisition,
  observe its exact identity and compare dockerContextFingerprint with managedContextDigest.
  Foreign or replacement contexts return ColimaMutationProfileConflict and stay in place.
- After successful removal, re-read the context listing. A still-listed name refuses and
  keeps the stage at ColimaReleasing; only authoritative absence permits ContextReleased.

#### Validation

finishNamespaces calls removeOwnedContext before publishing ContextReleased.
The actual context listing is classified first. An unlisted exact name skips inspection
and removal. A listed name requires retained managed evidence and the stored owned
context-directory origin; a missing binding is refused rather than acquired. The
strict helper revalidates parent bindings, re-enters the stored directory and observes
its real identity. Identity and protected-record version must remain equal across
context inspection, and dockerContextFingerprint must match managedContextDigest.
Only then may the removal command run. A successful command is followed by a fresh
classified listing; a still-listed exact name refuses and retains ColimaReleasing.

The three total policy producers cover removal presence, fingerprint equality and
post-removal absence. All nine context conditional removal cases pass, including the
physical call-site guard that requires these producers and the strict stored-binding
helper. The export inventory pins the new producers. All 667 focused ownership,
Colima, authority/export, documentation and portability cases pass.

The existing managed fixture now stores the artifact observation's actual context
digest rather than a placeholder. Its collector covers normal and shared-parent
cleanup, absent context (no inspect or removal), foreign endpoint (no removal),
still-listed context (no stage advancement), missing protected context binding
(no reacquisition), and real directory replacement (both live inodes and the old
record preserved). Its existing parent-replacement and profile-version-conflict
cases remain. Normal completed cleanup repeats without extra commands. These are
pure-policy, real-kernel namespace and local driver checks; the collector is not
live Docker/Colima evidence. No new executor, fake executable or injected row is added.

All-component builds with tests enabled pass in core and demo on Linux and native
Windows. Windows is supplementary compilation-only evidence; phase 29 owns native
runtime acceptance. All four host-static commands pass on the same 1177-file source
snapshot, verified in both trees before and after every command. The gate host is
hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2, Linux
6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry
2.4.3. Haskell temporaries use bounded 3 GiB tmpfs for real-kernel static cases;
these runs do not claim crash durability or live Colima acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T03:44:14.864746+00:00 | 2026-11-07T03:53:46.253761+00:00 | 571.389012 | 4945 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T03:44:14.864746+00:00 | 2026-11-07T03:53:24.128936+00:00 | 549.264187 | 4945 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T03:43:28.320489+00:00 | 2026-11-07T03:43:29.013026+00:00 | 0.692533 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T03:43:28.320489+00:00 | 2026-11-07T03:43:33.613620+00:00 | 5.293126 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 83 nonempty added/removed lines in Ensure.Colima.Ownership
alone. The other 198 production modules and all 710 compile-fail fixtures
retain baseline bytes. Changed files retain UTF-8 and LF. Both canonical ownership
docs align with conditional context release. The phase remains Active with retained
manifest settlement, its other implementation and the composed live gate owed.

#### Remaining Work

None.

### Sprint 16.23b: Private manifest-remainder release boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Remainder.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Provide the private releaseManifestRemainder producer over retained parent authority and
raw manifest entries, preserving the byte-exact descriptor-relative foundation.

#### Deliverables

- Keep releaseManifestRemainder inside the private ownership-internal library. Place its
  composition above primitive/platform modules to avoid an import cycle; it consumes the
  live bound parent and retained raw entry, never a fabricated ReportedObject record.
- Apply ClauseRelease and ClauseRecord capability refusals before the first filesystem
  primitive. Unavailable hosts retain a total Unsupported result.
- Within a verified bound root, an authoritatively absent remainder is already released.
  A different present identity refuses; the exact identity removes and syncs once, with
  descriptor-relative absence readback. Missing/replaced roots still refuse.

#### Validation

The private ownership-internal module Ownership.Remainder exports only
releaseManifestRemainder. It consumes a live Bound parent and a retained raw
OwnershipManifestEntry. The selected real row must hold ClauseRelease and
ClauseRecord before the first native effect. The existing pure capability matrix
covers all eight declarations. reobserveOwnedIdentity checks the actual protected
entry and owner thread, then requires the retained root identity. Only an owned
directory created from OriginAbsent may authorize remainder release.

The descriptor-relative POSIX producer opens and verifies the bound root before
descending. A genuinely absent leaf or intermediate descendant is already released;
failed probes, symbolic components and missing/replaced roots do not become absence.
Raw path components remain bytes. A different present entry identity refuses. Exact
removal retains kind/owner/mode safety checks, unlinks relative to its held parent,
synchronizes that descriptor and reads absence back. Intermediate descriptors remain
bracketed, including the absent-open path.

All ten manifest remainder cases pass: exact removal and repeat; absent leaf with
unchanged root; absent intermediate directory; replacement entry with both live
inodes and their bytes retained; missing root; replacement root with both directories
preserved; symbolic parent refusing without reaching its target; byte-ff removal
through the bound-root producer; escaped release after actual protected-entry exit;
and the physical private/capability guard. The nine native/refusal rows are declared
in CoverageManifest and compiled on Windows as well. Their unavailable branches
assert the actual POSIX Unsupported producer; no fabricated Bound token, injected
row, fake executable or production testing branch is added.

The private export pin lives separately from the public facade inventory. Its guard
checks exact export tokens, ownership-internal membership and absence from main-library
reexports. Existing raw-name, locale, stored-parent and capability cases remain.
All 678 focused ownership, Colima, authority/export, documentation and portability
cases pass.

All-component builds with tests enabled pass in core and demo on Linux and native
Windows. Windows is supplementary compilation-only evidence; phase 29 owns native
runtime acceptance. All four host-static commands pass on the same 1178-file source
snapshot, verified in both trees before and after every command. The gate host is
hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2, Linux
6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry
2.4.3. Haskell temporaries use bounded 3 GiB tmpfs for real-kernel static cases;
these runs do not claim crash durability or live Colima acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T04:04:58.581623+00:00 | 2026-11-07T04:14:43.054243+00:00 | 584.472617 | 4956 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T04:04:58.581622+00:00 | 2026-11-07T04:14:19.438256+00:00 | 560.856630 | 4956 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T04:04:40.826113+00:00 | 2026-11-07T04:04:47.939225+00:00 | 7.113110 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T04:04:40.826112+00:00 | 2026-11-07T04:04:52.703157+00:00 | 11.877043 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 74 nonempty added/removed lines across two modules: 29 in
Ownership.Posix and 45 in the new private Ownership.Remainder composition. The other
198 production modules and all 710 compile-fail fixtures retain baseline bytes.
Changed files retain UTF-8 and LF. Both canonical ownership docs align. The phase
remains Active with retained-manifest consumer adoption, manifest refresh, its other
implementation and the composed live gate owed.

#### Remaining Work

None.

### Sprint 16.23c: Retained-manifest bounded namespace cleanup [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Manifest.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Make the retained release manifest, rather than a fresh observation, bound every removed
namespace remainder, including objects already removed by lawful tool cleanup.

#### Deliverables

- Read and parse colimaManifestKey. Project docker/ entries relative to the Docker-config
  root and colima/ entries relative to home, excluding the complete cache/tmp subtrees.
- Refuse current entries outside the retained set or with a replacement identity. Keep raw
  paths throughout comparison and deepest-first ordering; do not reintroduce a FilePath decode.
- Skip retained entries now authoritatively absent and release present exact entries through
  releaseManifestRemainder under retained parent evidence. Preserve directory and record cleanup.

#### Validation

The pure projectOwnershipManifest producer strips only an exact raw namespace
prefix. admitOwnershipManifestRemainders merges canonical path-sorted retained and
current entries: absent retained entries are skipped, exact entries return retained
authority, and an added or changed entry is OwnershipOccupied. Equality includes
identity, kind, mode and immutable payload/link evidence. Canonical exclusions cover
complete raw subtrees, so cache/tmp descendants are excluded while prefix lookalikes
remain subject to admission. Neither projection nor comparison decodes path bytes.

Cleanup reads and parses colimaManifestKey through revalidateColimaManifest before
external delete. The parsed retained value is carried through releaseProfile,
settleAbsence and finishNamespaces; no later observation replaces that release
authority. Home projects colima/ with mutable observation and complete cache/tmp
exclusions; Docker-config projects docker/ with immutable observation. The stored
directory origin is still strictly re-entered and its actual identity checked.
Only admitted present entries are ordered deepest-first by raw slash count and
released through the private releaseManifestRemainder producer. Empty-directory
and exact protected-record cleanup retain their previous boundaries.

All twelve retained namespace remainder cases pass: non-UTF-8 projection, exact
prefix selection, malformed-prefix refusal, exact admission, present subset, empty
current namespace, new path, replacement identity, changed mode, changed kind,
complete subtree exclusions with lookalike/invalid-exclusion controls, and the
physical consumer guard. The guard pins pre-delete capture, retained-value
threading, deepest-first raw ordering and private release adoption. The stored-parent
guard now follows that private producer rather than a direct POSIX delete.

The existing managed fixture also passes two added variants. A real late.txt created
during the existing delete collector refuses home cleanup before any context
command: its bytes and retained manifest envelope remain, and the stage stays
ColimaReleasing. Initial context metadata removed by the existing context rm
collector is already absent and is skipped, allowing cleanup to reach ColimaReleased.
Earlier normal, shared-parent, foreign/still-listed context, missing/replaced
binding, parent-replacement and version-conflict cases remain. All 690 focused
ownership, Colima, authority/export, documentation and portability cases pass,
including the real raw-name release cases. No new executor, fake executable,
injected row or production testing branch is added. Collectors are local driver
evidence, not live Docker/Colima acceptance.

All-component builds with tests enabled pass in core and demo on Linux and native
Windows. Windows is supplementary compilation-only evidence; phase 29 owns native
runtime acceptance. All four host-static commands pass on the same 1178-file source
snapshot, verified in both trees before and after every command. The gate host is
hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2, Linux
6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry
2.4.3. Haskell temporaries use bounded 3 GiB tmpfs for real-kernel static cases;
these runs do not claim crash durability or live Colima acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T04:22:45.203481+00:00 | 2026-11-07T04:32:41.768493+00:00 | 596.565009 | 4968 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T04:22:45.203480+00:00 | 2026-11-07T04:32:17.284367+00:00 | 572.080883 | 4968 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T04:22:26.213402+00:00 | 2026-11-07T04:22:34.201489+00:00 | 7.988083 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T04:22:26.213402+00:00 | 2026-11-07T04:22:38.954892+00:00 | 12.741485 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 95 nonempty added/removed lines across two modules: 59 in
Ensure.Colima.Ownership and 36 in Ownership.Manifest. The other 198 production
modules and all 710 compile-fail fixtures retain baseline bytes. Changed files retain
UTF-8 and LF. Both canonical ownership docs align. The phase remains Active with
Managed manifest refresh, its other implementation and the composed live gate owed.

#### Remaining Work

None.

### Sprint 16.23d: Managed manifest refresh and releasing freeze [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Permit legitimate managed metadata drift to refresh its manifest before releasing, while
freezing the exact teardown proof once cleanup enters ColimaReleasing or a later stage.

#### Deliverables

- Acquisition continues to publish the identity/content manifest before becoming Managed.
- A matching Managed lineage may rebuild the manifest from its actual owned namespaces
  before entering releasing, updating its retained evidence coherently under the entry.
- Releasing and later stages never rebuild from a fresh observation. Missing/malformed
  proof or new/replaced release entries refuse rather than expanding teardown authority.

#### Validation

refreshColimaManifestRecord is a total Managed-only producer. It validates refreshed
manifest/directory-chain digests while preserving machine identity/epoch, context
fingerprint, wall, owner, lineage and invocation. Earlier stages and every releasing
or later stage refuse refresh. Acquisition still publishes canonical proof before
first becoming Managed.

refreshManagedColimaManifest checks the real selected row's release/record capabilities,
the actual protected stage version and record, canonical retained proof, context parents,
and the strictly stored home/context/cache/tmp directory bindings. It retains all four
identity/version pairs across actual namespace observation, rechecks parents, then
compare-and-swaps the manifest before publishing refreshed Managed evidence at the
exact stage version. Missing/malformed proof is not acquired. Identical proof changes
neither record version. A manifest-first partial update remains Managed and can reconcile
without rewriting already-published bytes. Ordinary revalidateColimaManifest readers
require both retained digests to match stage evidence, so they refuse incoherent proof.
Cleanup invokes this route only for Managed, then uses its returned version to freeze
ColimaReleasing. Releasing and later proof cannot broaden from observation.

All fourteen managed manifest refresh checks pass: policy at each of the nine stages;
preserved facts/lineage; unchanged-record identity; malformed new digest refusals;
physical publication/consumer ordering; and the selected host's declared capabilities
or actual Unsupported result. The shared strict directory helper retains stored origin
provenance and identity/version checks; the existing context guard follows its real
composition. Missing or replaced directory bindings now refuse during pre-freeze
validation, before any tool command or acquisition.

The existing real namespace/protected-store fixture passes automatic Managed metadata
drift cleanup and a detailed two-record reconciliation variant. That variant first
refreshes actual metadata and proves both versions advance once while home/context
origin records and the context fingerprint remain unchanged. It then writes a new
canonical manifest through the actual protected CAS without changing its Managed
stage, constructing the manifest-first interruption state. An ordinary Docker route
refuses that incoherent proof without extra commands. Refresh repairs stage evidence
once while preserving the exact manifest envelope/version; an identical retry changes
nothing, and a stale stage version refuses without writes. This proves reconciliation
of an actual persisted partial state, not a process-kill or crash-durability gate.

A frozen variant retains the original metadata inode, installs a distinct replacement,
and proves both the explicit refresh and cleanup refuse. The releasing stage and
manifest remain unchanged; original and replacement bytes survive; no tool command
runs. Earlier acquisition, bounded-remainder, parent/binding replacement and version
cases remain. All 704 focused ownership, Colima, authority/export, documentation and
portability cases pass. No new executor, fake executable, injected row or production
testing branch is added. Existing collectors remain local driver evidence, not live
Docker/Colima acceptance. The export inventory pins the real owned refresh producer.

All-component builds with tests enabled pass in core and demo on Linux and native
Windows. Windows is supplementary compilation-only evidence; phase 29 owns native
runtime acceptance. All four host-static commands pass on the same 1178-file source
snapshot, verified in both trees before and after every command. The gate host is
hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2, Linux
6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry
2.4.3. Haskell temporaries use bounded 3 GiB tmpfs for real-kernel static cases;
these runs do not claim crash durability or live Colima acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T04:45:59.420389+00:00 | 2026-11-07T04:55:51.179934+00:00 | 591.759542 | 4982 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T04:45:59.420485+00:00 | 2026-11-07T04:55:25.487841+00:00 | 566.067356 | 4982 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T04:45:59.420441+00:00 | 2026-11-07T04:46:00.227810+00:00 | 0.807370 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T04:45:59.420485+00:00 | 2026-11-07T04:46:05.283599+00:00 | 5.863116 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 171 nonempty added/removed lines across two modules: 152 in
Ensure.Colima.Ownership and 19 in Backend.Stage. The other 198 production
modules and all 710 compile-fail fixtures retain baseline bytes. Changed files retain
UTF-8 and LF. Both canonical ownership docs align. The legacy ledger carries no
in-memory reported-origin remainder row: release consumes retained parent/manifest
authority through the private producer. The phase remains Active with its other
implementation and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.24: Durable direct-Colima origin transaction and released-record reuse [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
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
  with released-record reuse, acquisition adoption and cleanup adoption as separate bounded steps.
- Cleanup stages bind the distinct teardown invocation digest and retain enough frozen state to resume only
  the same conditional release.
- The protected-store entry is synchronization-only; release completion lives in the stage record, and a
  `Released` record admits a later acquisition, which opens a new lineage from `Reserved`.

#### Validation

The stage decision table returns BeginColimaLineage only for acquisition from
Released with authoritative namespace absence. This opens a new Reserved transaction;
advanceColimaStage still refuses a backward Released-to-Reserved transition.

acquireInside refuses replay of the completed acquisition invocation. For a fresh
invocation, it observes actual home/context origins through the real kernel row
and live entry without acquiring anything, then reads every prior home, context,
cache, temporary, profile, disk and manifest record. Both objects and all those
records must be absent. The resulting ColimaNamespaceAbsent observation is passed
to decideColimaStage, and only BeginColimaLineage permits a compare-and-swap of
the exact retained Released version to the new Reserved record. Incompatible
objects/records remain untouched; decision refusals remain typed conflicts.
Shared context-parent records are not confused with this profile's artifact keys.

The existing complete table matrix includes the new row and retains every refused
combination and adjacent-stage invariant. A new physical consumer guard requires
the real decision, invocation check, namespace/record observations and exact stage
CAS; its origin observer reaches the actual live-entry kernel producer and never
records or acquires an origin. All three targeted checks pass: this guard, the
complete stage table/codec case, and the existing native driver fixture.

That fixture's existing acquisition collector now continues through actual cleanup
and a second acquisition. After its original fresh/exact acquisition, cleanup
reaches Released at command count 19. Same-cleanup replay and old-acquisition replay
issue no command. A real unrecorded home with a retained inode/bytes refuses without
changing Released. A genuine home-origin payload retained from the first actual
acquisition, persisted as a residual record through the protected CAS, also refuses
without stage mutation or commands. Once those test-owned obstructions are withdrawn,
a fresh invocation reaches ColimaManagedApplied/Managed at count 26 with a later
stage version and its own invocation. The old cleanup then refuses without touching
that new stage or issuing commands. No new executor, fake executable, injected row
or production testing branch is added. These are pure decisions, real filesystem/
protected-store effects and local collector checks, not live Colima acceptance.

All 705 focused ownership, Colima, authority/export, documentation and portability
cases pass. All-component builds with tests enabled pass in core and demo on Linux
and native Windows. Windows is supplementary compilation-only evidence; phase 29
owns native runtime acceptance. All four host-static commands pass on the same
1178-file source snapshot, verified in both trees before and after every command.
The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2, Linux
6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry
2.4.3. Haskell temporaries use bounded 3 GiB tmpfs for real-kernel static cases;
these runs do not claim crash durability or live Colima acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T05:07:37.929870+00:00 | 2026-11-07T05:17:15.248344+00:00 | 577.318469 | 4983 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T05:07:37.929878+00:00 | 2026-11-07T05:16:54.510199+00:00 | 556.580320 | 4983 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T05:07:24.490684+00:00 | 2026-11-07T05:07:25.213598+00:00 | 0.722910 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T05:07:24.490689+00:00 | 2026-11-07T05:07:29.838329+00:00 | 5.347640 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 45 nonempty added/removed lines across two modules: 43 in
Ensure.Colima.Ownership and 2 in Backend.Stage. The other 198 production
modules and all 710 compile-fail fixtures retain baseline bytes. Changed files retain
UTF-8 and LF. Both canonical ownership docs align. The phase remains Active with
acquisition/cleanup decision-table adoption, its other implementation and the composed
live gate owed.

#### Remaining Work

None.

### Sprint 16.24a: Acquisition consumes the Colima stage decision table [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Drive acquisition and Prepared start from the one total stage decision table using
classified actual namespace/profile observations.

#### Deliverables

- acquireInside and the namespace preparation steps classify their retained stage and
  actual namespace observations into ColimaStageObservation and consume decideColimaStage.
- startPreparedColimaProfileInside takes its start/refusal choice from the same table.
  A Prepared record with an already-present profile is refused unless its retained claimed
  binding matches the freshly observed machine identity. Successful fresh start still requires actual
  readbacks, artifact binding, manifest publication and wall settlement before Managed.
- Matching Managed re-entry consumes KeepColimaStage only after its exact observations;
  Left maps to ColimaMutationProfileConflict and no independent choice bypasses the table.

#### Validation

Acquisition namespace preparation, Prepared start, exact Managed re-entry and
evidence-bearing settlement now consume decideColimaStage results. Namespace
preparation chooses its advance before effects, records a vacant initial scope
only after actual object/record absence, and strictly verifies retained staged
directories before further advances. Prepared re-entry verifies home, context,
cache and temporary bindings and consumes KeepColimaStage without reconstructing
missing origins. Native stage refusals keep their closed fault class; the mutation
consumer maps them to ColimaMutationProfileConflict.

The complete table includes legitimate Reserved/home-bound resumption and
Prepared/context-exact retention. Existing-profile exactness under Prepared requires a matching bound profile claim and fresh machine
identity; an unbound origin cannot establish which invocation created it. Fresh successful
start readbacks and joined artifact/wall evidence use the distinct
ColimaCreatedProfileExact observation when publishing Managed. Exact Managed
re-entry consumes KeepColimaStage only after all observed wall, machine, binding,
context and manifest checks. Initial acquisition still publishes its manifest
before Managed.

The existing collector checks Prepared-present refusal in each native fixture:
one exact listing is consumed, no machine/start command runs, profile/disk creation
origins remain absent, and the exact Prepared stage/version remains unchanged.
The same collector then resets to its original fresh-start outcomes and completes
the real namespace/protected-store sequence. Earlier fresh/exact acquisition,
released reuse, foreign/retained-record refusals, bounded release, metadata refresh,
interrupted proof and frozen replacement cases remain.

The total stage matrix covers every intent/stage/observation combination, including
the new created-profile distinction and all refusals. Physical consumer guards
require the actual namespace/start/Managed/settlement table calls, strict Prepared
directory readers and the real live-entry absence observer. They reject the old
Prepared reconstruction/adoption helpers. All four targeted checks and all 706
focused ownership, Colima, authority/export, documentation and portability cases
pass. No new executor, fake executable, injected row or production testing branch
is added. Existing collectors are local driver checks, not live Colima acceptance.

All-component builds with tests enabled pass in core and demo on Linux and native
Windows. Windows is supplementary compilation-only evidence; phase 29 owns native
runtime acceptance. All four host-static commands pass on the same 1178-file source
snapshot, verified in both trees before and after every command. The gate host is
hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2, Linux
6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry
2.4.3. Haskell temporaries use bounded 3 GiB tmpfs for real-kernel static cases;
these runs do not claim crash durability or live Colima acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T05:27:55.657266+00:00 | 2026-11-07T05:37:42.519896+00:00 | 586.862632 | 4984 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T05:27:55.657196+00:00 | 2026-11-07T05:37:12.377678+00:00 | 556.720478 | 4984 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T05:27:55.657236+00:00 | 2026-11-07T05:27:56.412664+00:00 | 0.755429 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T05:27:55.657257+00:00 | 2026-11-07T05:28:01.444974+00:00 | 5.787717 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 266 nonempty added/removed lines across two modules: 256 in
Ensure.Colima.Ownership and 10 in Backend.Stage. The other 198 production
modules and all 710 compile-fail fixtures retain baseline bytes. Changed files retain
UTF-8 and LF. Both canonical ownership docs align. The locked-acquisition sprint
retains its distinct failure/readback/concurrency cases; its already-fulfilled
Prepared-present implementation/case debt is not scheduled again. The phase remains
Active with cleanup decision adoption, its other implementation and the composed
live gate owed.

#### Remaining Work

None.

### Sprint 16.24b: Cleanup consumes the Colima stage decision table [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Use actual profile/namespace observations and the single table to choose conditional
cleanup steps while retaining the exact teardown invocation and frozen manifest.

#### Deliverables

- cleanupInside and its stage-changing settlement steps classify actual observations
  into ColimaStageObservation and act on decideColimaStage results. Left becomes
  ColimaMutationProfileConflict; no fabricated observation authorizes a mutation.
- Managed manifest refresh precedes freeze, and actual profile identity/wall/origin
  checks precede conditional deletion. Namespace release retains the frozen manifest,
  context absence readback, parent bindings and exact protected-record versions.
- A completed release repeated with the same cleanup invocation returns Right () and
  issues no tool command. Another lineage/invocation or incompatible partial state
  refuses rather than acquiring new authority.

#### Validation

Cleanup now consumes decideColimaStage for profile deletion, both release-stage
advances, final namespace removal and completed replay. Managed-only manifest refresh
still precedes freeze. A matching live CPU/memory/data-disk wall, Docker runtime,
machine identity/epoch and bound profile/disk identities are required before the
exact Managed version is replaced by Releasing with its distinct cleanup invocation.
Only DeleteColimaProfile authorizes the external delete. Already-Releasing entry
retains its matching cleanup invocation and frozen proof.

Actual post-delete listing absence and kernel disk absence feed settlement; the
captured release-stage version and record must still match before ContextReleased
publication. Conditional Docker-context removal retains its fingerprint, binding
and absence readback. The frozen pre-delete manifest still bounds all remainder
removal. Before final namespace removal, home/cache/tmp bindings are re-entered,
and context object plus context/profile/disk record absence are verified. The
ReleaseColimaNamespace decision authorizes only that observed remainder.

Completed replay observes actual home/context and all seven prior artifact-record
absences before accepting KeepColimaStage. It issues no tool command. Existing
foreign roots and residual protected origins remain unchanged and refuse; another
lineage, cleanup invocation or incompatible partial stage acquires no authority.

The existing collector now exercises absent and duplicate profile reports, changed
CPU, memory, disk or runtime, and a different reported machine identity before
delete. Each refusal retains the exact Managed stage/version and real data disk;
the duplicate preserves ColimaMutationReportRefused ColimaReportDuplicate. A genuine
persisted same-invocation Releasing record over actual Managed proof resumes the
bounded cleanup. The completed acquisition/release/reuse cycle also verifies that
foreign roots and residual origins refuse cleanup without changing its 19-command
count or Released record. Existing context, parent, frozen-manifest, unretained-file
and origin-version cases retain their assertions.

A physical guard pins the actual cleanup decision consumers and retained-version
checks; existing manifest authority guards follow the added stage-version arguments.
The full pure decision matrix, consumer guards and native fixture pass in five targeted
checks. All 707 focused ownership, Colima, authority/export, documentation and
portability cases pass. These are local collector and real-kernel static checks;
no new executor, injected row, fake executable, production test branch, crash-durability
claim or live Colima acceptance is added.

All-component builds with tests enabled pass in core and demo on Linux and native
Windows. Windows supplies compilation-only evidence; native runtime acceptance stays
with phase 29. All four host-static commands pass on the same 1178-file source
snapshot, verified in both trees before and after each command. The gate host is
hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2, Linux
6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry
2.4.3. Haskell temporaries use bounded 3 GiB tmpfs for real-kernel static cases.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T05:47:46.422952+00:00 | 2026-11-07T05:57:28.510249+00:00 | 582.087293 | 4985 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T05:47:46.423025+00:00 | 2026-11-07T05:57:01.105882+00:00 | 554.682857 | 4985 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T05:47:46.423006+00:00 | 2026-11-07T05:47:47.204022+00:00 | 0.781018 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T05:47:46.423022+00:00 | 2026-11-07T05:47:52.192830+00:00 | 5.769808 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 114 nonempty added/removed lines in Ensure.Colima.Ownership.
The other 199 production modules and all 710 compile-fail fixtures retain baseline
bytes. Changed files retain UTF-8 and LF. Both canonical ownership docs align.
The inline-stage-choice legacy row is deleted: namespace preparation, start, exact
Managed entry, settlement, released reuse and cleanup consume the single decision
table. The phase remains Active with its remaining implementation and composed
live gate owed.

#### Remaining Work

None.

### Sprint 16.25: Locked direct-Colima acquisition program [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
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
- A prepared record with an unexpectedly present profile is outcome-unknown unless its bound claimed identity
  matches the fresh machine observation.
- Same-name unowned profiles are foreign; incompatible, malformed, changing, or partially observed state is a
  conflict or failure and is left untouched.
- `ColimaManagedApplied` and `ColimaManagedAlreadyExact` carry the started machine identity and epoch plus
  the artifact observation (data disk, context digest, manifest) that settlement and later exact calls
  re-check.

#### Validation

The existing native acquisition fixture now covers the remaining start and
post-start refusal cases. A start exiting 7 returns ColimaMutationStartFailed;
a successful start whose listing stays empty returns the exact remained-absent
conflict. Changed CPU wall, Stopped status, containerd runtime and duplicate profile
reports retain their exact conflict or ColimaMutationReportRefused ColimaReportDuplicate.
Each case uses its own real temporary Prepared ownership scope, checks the exact
unchanged stage/version and issued-command count, and observes no created disk.
The separate wrong-lineage Prepared call refuses before any collector invocation
and preserves the original record. Unexpected present profiles remain the
outcome-unknown conflict validated by the acquisition stage-table sprint.

The existing one-entry collector now runs two actual acquisition threads on the
same state root/profile. The first is held at its initial described command while
the second starts its call; both execute through the real protected-store entry.
Both threads have bounded waits and bracketed cleanup, and asynchronous failures
are transported by forkFinally rather than leaving an empty result slot. Exactly
one result is ColimaManagedApplied and exactly one described start is issued;
the peer must return ColimaManagedAlreadyExact or ColimaMutationEntryRefused.
An exact retry after any entry refusal normalizes the existing full-cycle checks.
The subsequent cleanup/reuse cycle retains its 19-command Released and 26-command
fresh-Managed checkpoints, verifies a second total start only for the later genuine
acquisition invocation, and retains foreign/residual/old-invocation refusals.

These additions reuse the existing described-command collectors and real temporary
namespaces/protected records. No new executor, injected row, fake executable or
production testing branch is added. They establish local driver and real-entry-lock
behavior; live Colima confirmation remains owed to Apple Silicon acceptance. The
expanded native driver case and all 707 focused ownership, Colima, authority/export,
documentation and portability checks pass.

All-component builds with tests enabled pass in core and demo on Linux and native
Windows. Windows is compilation-only evidence; phase 29 retains native runtime
acceptance. All four host-static commands pass on the same 1178-file source
snapshot, verified in both trees before and after each command. The gate host is
hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2, Linux
6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry
2.4.3. Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries; no crash
durability or live Colima result is claimed.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T06:02:16.151689+00:00 | 2026-11-07T06:11:45.860886+00:00 | 569.709251 | 4985 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T06:02:16.151690+00:00 | 2026-11-07T06:11:19.430101+00:00 | 543.278464 | 4985 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T06:02:16.151775+00:00 | 2026-11-07T06:02:20.676985+00:00 | 4.525211 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T06:02:16.151773+00:00 | 2026-11-07T06:02:25.450024+00:00 | 9.298253 | 376 Python cases; 100% coverage; exit 0 |

No production source changes are required: all 200 production Haskell modules and
all 710 compile-fail fixtures retain baseline bytes. ColimaSpec changes by 87 nonempty
added/removed lines within its existing native collector fixture. The engineering
reconciler and durable-state docs align; changed files retain UTF-8 and LF. The phase
remains Active with exact profile identity, its other implementation and composed
live gate still owed.

#### Remaining Work

None.

### Sprint 16.26: Opaque direct-Colima acquisition backend facade [Done]

**Status**: Done
**Implementation**:
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Command.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Report.hs`,
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
is Sprint 16.29a's.

### Sprint 16.27: Shared refusal vocabulary for private Colima naming [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/internal/reconcile-error/HostBootstrap/Reconcile/Error.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportReconcileError.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Let the private naming policy return the same descriptive reconciler refusals as
its public consumer without a dependency cycle through the public library.

#### Deliverables

- A leaf private reconcile-error-internal library owns the unchanged descriptive
  ReconcileError, ConflictDetail, SafetyDetail, UnsupportedDetail, FailureDetail and
  RecoveryDisposition types. It depends only on base and text and imports no effect,
  plan, ownership or lifecycle authority.
- The public Reconcile module imports and reexports exactly the existing constructors
  and selectors. No public naming-policy entry point or new authority is introduced.
- Private policy components can depend on this leaf vocabulary without importing the
  main library. The named hidden-package compile failure and exact export guard keep
  the implementation module outside the public package surface.

#### Validation

The six descriptive refusal types now have one declaration home in
HostBootstrap.Reconcile.Error, owned by the private reconcile-error-internal leaf
library. That unit depends only on base and text. Public HostBootstrap.Reconcile
imports and reexports the same constructors and selectors; its exact public export
inventory is unchanged. The extracted declaration block is byte-identical to its
baseline, including all fields, constructor order and Eq/Show instances.

The physical boundary guard verifies one private declaration owner, the exact
private export inventory, private visibility, the leaf dependency set, the public
import, and absence of effect/plan/ownership/lifecycle imports. The registered
ImportReconcileError fixture fails for its complete named hidden-package diagnostic.
Existing public reconciler consumers compile against the imported declarations on
both native host families. No public naming-policy function or authority is added.

Both targeted boundary checks, the production-scanner inventory and all 709 focused ownership, Colima, authority/export,
documentation and portability checks pass. All-component builds with tests enabled
pass in core and demo on Linux and native Windows. Windows is compilation-only
evidence; phase 29 still owns native runtime acceptance.

All four host-static commands pass on one frozen 1180-file snapshot, verified in
both trees before and after each command. The gate host is hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000,
GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3. Bounded 3 GiB tmpfs supplies Haskell
real-kernel test temporaries; these are static checks, not crash-durability or live
Colima acceptance. No executor, injected row, fake executable or production testing
branch is added.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T06:33:17.681826+00:00 | 2026-11-07T06:42:47.000954+00:00 | 569.350493 | 4987 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T06:33:17.681857+00:00 | 2026-11-07T06:42:19.409972+00:00 | 541.757965 | 4987 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T06:33:17.681905+00:00 | 2026-11-07T06:33:18.476010+00:00 | 0.794151 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T06:33:17.681905+00:00 | 2026-11-07T06:33:23.511645+00:00 | 5.830062 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 90 nonempty added/removed lines across two modules: 43 in
public Reconcile and 47 in the new private Error module. The other 199 production
modules and all 710 existing compile-fail fixtures retain baseline bytes; one named
private-import fixture is added. Changed files retain UTF-8 and LF. The engineering
reconciler and lifecycle-state docs align. The phase stays Active with the naming
policy, its other implementation and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.27a: Exact project/lifecycle Colima profile identity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Names.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportColimaNames.hs`
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

The project/lifecycle naming policy and actual home projection now live in the
existing private colima-backend-internal unit as Backend.Names. The public adapter
imports derivation and home projection without exporting them, and reexports the
same diagnostic project predicate. That predicate is isRight . validateProfileName,
so it shares actual production admission rather than duplicating it. The private
policy uses the shared refusal vocabulary and canonical UTF-8 SHA-256 helper; its
unchanged derivation domain and byte order retain the known profile/key vector.

Ten pure/physical policy checks cover full-input determinism, a six-lowercase-hex
local profile and 128-bit key, Production/Harness and distinct-run key/home separation,
project/resource/frame/root sensitivity, and exact default/project/lifecycle/run-key
refusals. The default is the exact production ConflictDetail. The public predicate
is checked against the actual derivation admission. The home checks apply the real
colimaHomePath function used by ownershipNamespaceFor and colimaSocketNamespaceFits.
Physical guards pin those consumers, the admitted-plan projections, private unit
and export boundary, shared error dependency and absence of public duplicate policy.
ImportColimaNames fails for its complete named hidden-package diagnostic.

The existing native acquisition collector derives two genuine namespace keys and
their canonical SHA-256 lineages, deliberately forcing them through one short
profile in the same real state root. After the first becomes Managed, the second
lineage returns the exact managed-stage-belongs-to-another-lineage conflict. The
first stage/version, protected manifest and disk bytes remain unchanged, with the
command count still 11. The complete cleanup/reuse cycle, concurrent-acquisition
single-start assertions and earlier bounded-release refusals remain passing.

All twelve targeted policy/import/native-driver checks and all 719 focused ownership,
Colima, authority/export, documentation, portability and source-root-scanning checks
pass. Both workspaces build with tests enabled on Linux and native Windows. Windows
supplies compilation-only evidence; phase 29 retains native runtime acceptance.

All four host-static commands pass on one frozen 1182-file source snapshot, verified
in both trees before and after every command. The gate host is hostbootstrap-linux-d,
Ubuntu 24.04.5 x86_64 under WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000,
GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3. Bounded 3 GiB tmpfs supplies Haskell
real-kernel test temporaries. Existing collectors and real kernel/store entry checks
remain local static evidence; no live Colima or crash-durability claim, new executor,
injected row, fake executable or production test branch is introduced.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T06:52:22.252977+00:00 | 2026-11-07T07:01:58.074088+00:00 | 575.843798 | 4998 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T06:52:22.252902+00:00 | 2026-11-07T07:01:30.687441+00:00 | 548.456144 | 4998 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T06:52:22.252987+00:00 | 2026-11-07T06:52:23.025441+00:00 | 0.772489 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T06:52:22.252947+00:00 | 2026-11-07T06:52:27.954658+00:00 | 5.701936 | 376 Python cases; 100% coverage; exit 0 |

Production changes are 198 nonempty added/removed lines in two modules: 94 in public
Colima and 104 in the new private Names module. The other 200 production modules and
all 711 existing compile-fail fixtures retain baseline bytes; one named private-import
fixture is added. The duplicate-predicate legacy row is deleted. Both canonical docs
align, and changed files retain UTF-8 and LF. The phase stays Active with closed
resolver/backend adoption, its other implementation and composed live gate owed.

#### Remaining Work

None.

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

### Sprint 16.29: A reusable command-vocabulary package boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/effect-command/HostBootstrap/Effect/Vocabulary.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/EffectSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/library_hierarchy.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Let private effect consumers use the one command vocabulary without depending on
the public library that consumes them.

#### Deliverables

- The unchanged Effect.Vocabulary module has one physical declaration home in a
  private effect-command-internal library, depending only on base and the private
  HostTool declaration owner. No new command representation or interpreter appears.
- The public library reexports the same vocabulary module and keeps its existing
  Effect facade and interpreter API. Private backend components can depend on the
  vocabulary unit without a dependency back into the public library.
- The old main-library source file is absent, preventing a second home-module copy.
  Exact source/export and package graph guards pin the one owner and public reexport.
  Existing public-only effect consumers compile and retain their behavior.

#### Validation

Effect.Vocabulary now has one physical declaration home in the private
effect-command-internal library. Every module byte is retained: SHA-256
29f03b9611b4cb7bbfd05ee29d2d73cc4035ca5cfea8c6554172bbce69bc91a7.
The old main-library source file is absent. The leaf depends only on base and
the private HostTool declaration owner; no public-library dependency, command
representation, interpreter, effect or authority is added.

The public library reexports the same vocabulary module. Its existing Effect
facade and interpreter, downstream consumer, and public-only effect tests compile
against that reexport. The exact export guard pins private visibility, source root,
dependencies, sole declaration owner, unchanged public exports and absence of a
direct private-unit dependency in the test component.

The production-source root inventory includes the new unit. Substrate.Frame,
which now imports a private-unit declaration through the shared vocabulary, has
its unchanged public export list pinned and is removed from the unpinned-module
exception list. The complete exposed/required sealed inventory agrees. The source
guard decodes UTF-8 explicitly on every host. Both architecture docs and the host-tool
phase's canonical source-home citation point at the one actual declaration owner.

All three targeted package/source/export guards and all 767 focused effect,
ownership, Colima, authority/export, documentation, portability and source-scanning
checks pass. Both workspaces build with tests enabled on Linux and native Windows.
Windows supplies compilation-only evidence; phase 29 retains native runtime
acceptance.

All four host-static commands pass on one frozen 1182-file source snapshot,
verified in both trees before and after every command. The gate host is
hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2, Linux
6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry
2.4.3. Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries.
These are static checks, not crash-durability or live Colima acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T07:22:15.222096+00:00 | 2026-11-07T07:32:12.272352+00:00 | 597.063227 | 4999 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T07:22:15.222089+00:00 | 2026-11-07T07:31:39.706321+00:00 | 564.496550 | 4999 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T07:22:15.222066+00:00 | 2026-11-07T07:22:16.000889+00:00 | 0.778846 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T07:22:15.221911+00:00 | 2026-11-07T07:22:21.170177+00:00 | 5.948431 | 376 Python cases; 100% coverage; exit 0 |

The source relocation contains 183 nonempty lines, 366 added/removed lines across
the two physical paths of one logical module, within the sprint budget. There is
no production-body change. The other 201 production modules and all 712 compile-fail
fixtures retain baseline bytes. All changed text retains UTF-8 and LF. No new
executor, injected row, fake executable or production test branch is introduced.
The phase remains Active with private driver adoption, its other implementation
and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.29a: Closed resolver/backend adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Command.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Report.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Install.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportColimaOwnership.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Resolve and retain the sole private execution namespace used by every exact Colima effect.

#### Deliverables

- Public acquisition, live Docker, and cleanup accept no `HostConfig`, executable, interpreter, environment,
  current directory, or executor; only the private trusted resolver can supply them. The driver module
  `HostBootstrap.Ensure.Colima.Ownership`, whose private entry points take an interpreter and
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

The owning driver and its Command and Report dependencies have one physical home in the
private colima-ownership-internal library. The public library reexports the same descriptive
Command and Report APIs; Ownership is unavailable to downstream consumers. The main Colima
adapter supplies the retained trusted resolver. All six HostConfig-taking wrappers and their
unused observation fault are absent; the interpreter-taking forms retain their existing bodies.

The named ImportColimaOwnership compile failure verifies the complete hidden-package diagnostic
for a public consumer attempting caller-interpreter Docker and cleanup calls. The private export
inventory, actual Cabal ownership, old-path absence, public descriptive reexports and both private
consumers are pinned. Production scanning includes the new private source root. Source guards read
that actual home with explicit UTF-8. The pure missing-Colima resolveLaunch case runs without a
host capability wrapper. Existing native collector cases retain their real protected-store and
kernel operations. Canonical documentation and plan paths agree with the actual source homes.

ColimaSpec cases `the owning driver is private and exposes no HostConfig wrapper` and
`missing Colima is refused by the shared pure launch resolver`, and CompileFailSpec fixture
`ImportColimaOwnership.hs`, pass. All three targeted cases and all 769 focused ownership, Colima,
effect, authority/export, documentation, portability and source-scanning checks pass. Both
workspaces build with tests enabled on Linux and Windows. Windows supplies compile-only evidence;
native runtime acceptance remains owed by the host-portability phase. The complete public Apple
toolchain chain still requires Apple Silicon acceptance.

All four host-static commands pass on one frozen 1183-file source snapshot, verified in both
trees before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64
under WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and
Poetry 2.4.3. Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These checks do
not claim crash durability or live Colima acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T07:47:16.219578+00:00 | 2026-11-07T07:57:00.756706+00:00 | 584.545547 | 5002 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T07:47:16.219385+00:00 | 2026-11-07T07:56:34.253876+00:00 | 558.042524 | 5002 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T07:47:16.219586+00:00 | 2026-11-07T07:47:24.988693+00:00 | 8.769235 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T07:47:16.219385+00:00 | 2026-11-07T07:47:29.685432+00:00 | 13.466238 | 376 Python cases; 100% coverage; exit 0 |

The three relocated logical modules have a rename-neutral production delta of 106 nonempty
lines, all in Ownership, within the sprint budget. Command and Report retain every byte; the other
199 production modules and all 712 existing compile-fail fixtures retain baseline bytes. One
new compile-fail fixture raises that inventory to 713. Changed text retains UTF-8 and LF. No new
executor, injected row, fake executable or production test branch is introduced. The phase remains
Active with its remaining implementation and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.30: Shared descriptive provider-wall observations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/wall-observation/HostBootstrap/Cluster/Budget/Observation.hs`,
 `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/BudgetSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportWallObservation.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Give private owning-backend policy and public budget descriptions the same descriptive observation
type without a dependency from a private library into the public authority kernel.

#### Deliverables

- `WallAcquireObservation` has one declaration home in a private `wall-observation-internal` leaf.
  Its six constructors, field types, Eq and Show instances remain unchanged.
- The public budget module reexports the same type through its existing hidden kernel. The leaf
  depends only on base and the shared reconciler-refusal leaf, and holds no settlement authority.
- The source/export inventory pins private ownership and the unchanged public surface; a named
  compile-fail fixture rejects direct public import of the private declaration module.

#### Validation

WallAcquireObservation has one declaration home in the private wall-observation-internal
leaf. Its complete declaration is byte-identical to the baseline: all six constructors, field
types and Eq/Show derivation remain unchanged. The existing public budget API reexports the same
type through its hidden kernel. The leaf depends only on base and reconcile-error-internal and
contains no settlement permit, executable command or plan-indexed authority.

BudgetSpec case `provider-wall observations have one private descriptive declaration home`
pins private visibility, sole source root, exact exports and dependencies, declaration uniqueness,
and the existing kernel's import/reexport. CompileFailSpec fixture `ImportWallObservation.hs`
fails for the complete hidden-package diagnostic. The production-source inventory includes the
new leaf. The exact public export inventory remains unchanged.

Both targeted checks and all 832 focused budget, ownership, Colima, effect, export/authority,
documentation, portability and production-scanning checks pass. BudgetSpec's five existing
private provider-wall settlement cases continue to exercise migrated, zero-epoch, WSL, ordinary
Colima and non-owning observations against the same constructors. Both workspaces build with
tests enabled on Linux and native Windows. Windows supplies compilation-only evidence; native
runtime acceptance remains owed by the host-portability phase.

All four host-static commands pass on one frozen 1185-file source snapshot, checked in both
trees before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5
x86_64 under WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0
and Poetry 2.4.3. Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are
static checks, not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T08:04:04.150180+00:00 | 2026-11-07T08:13:45.900704+00:00 | 581.756516 | 5004 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T08:04:04.150154+00:00 | 2026-11-07T08:13:14.535933+00:00 | 550.391448 | 5004 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T08:04:04.150182+00:00 | 2026-11-07T08:04:04.918035+00:00 | 0.767862 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T08:04:04.150101+00:00 | 2026-11-07T08:04:09.899919+00:00 | 5.749875 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 30 nonempty added/removed lines across two modules: 12 in the existing
budget kernel and 18 in the new descriptive declaration module. The other 201 production modules
and all 713 existing compile-fail fixtures retain baseline bytes. One new compile-fail fixture
raises that inventory to 714. Changed text retains UTF-8 and LF. No executor, injected row, fake
executable or production test branch is introduced. The phase remains Active with acquisition
classification, its remaining implementation and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.30a: Clause-holding direct-Colima acquisition [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
 `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
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

The private ownership driver's pure colimaMutationAcquireObservation classifies profile
conflicts and ownership-origin refusals as WallRefused with ConflictDetail. Entry, command,
report, start and delete failures remain WallAcquireFailed with ReprobeBeforeRetry. The public
acquireObservation adapter consumes this one decision and supplies renderExpected's complete
CPU, memory, data-disk and root-disk description. Owned applied/exact outcomes retain their
existing closed-backend observation and settlement path.

ColimaSpec's `acquisition mutation refusal classification` group applies the real pure function
to all seven fault constructors, checks the exact conflict or failure details and recovery
instructions, and verifies preservation of the complete supplied expected wall. Its case
`the public acquisition adapter consumes the private refusal classification` checks the actual
adapter definition, its rendered wall input, and absence of a second classification. The unused
public classifier and decision datatype, their private-only helpers and two obsolete classifier
cases are absent. The complete public and private export inventories pin the resulting boundary, and the live-definition
and registration inventories confirm that every negative fixture targets an existing library definition.

All ten targeted cases and all 840 focused budget, ownership, Colima, effect, authority/export,
documentation, portability and production-scanning checks pass. Existing native ownership cases
continue to use their real protected-store transactions. Both workspaces build with tests enabled
on Linux and Windows. Windows supplies compilation-only evidence; native runtime acceptance
remains owed by the host-portability phase. Static checks do not claim to execute the complete
public Apple toolchain chain, whose live confirmation remains Apple Silicon acceptance.

All four host-static commands pass on one frozen 1185-file source snapshot, checked in both
trees before and after every command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5
x86_64 under WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0
and Poetry 2.4.3. Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are
static checks, not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T08:33:11.847825+00:00 | 2026-11-07T08:43:10.562206+00:00 | 598.717552 | 5010 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T08:33:11.847817+00:00 | 2026-11-07T08:42:40.126308+00:00 | 568.281500 | 5010 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T08:33:11.855053+00:00 | 2026-11-07T08:33:12.692560+00:00 | 0.837509 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T08:33:11.854194+00:00 | 2026-11-07T08:33:17.907583+00:00 | 6.053421 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 121 nonempty added/removed lines across two modules: 96 in the public
Colima adapter and 25 in the private owning driver, within the sprint budget. The other 201
production modules and all 714 compile-fail fixtures retain baseline bytes. Changed text retains UTF-8 and LF. No new
executor, injected row, fake executable or production test branch is introduced. The phase
remains Active with provider-start settlement, its remaining implementation and composed live
gate owed.

#### Remaining Work

None.

### Sprint 16.31: Shared private provider-start capabilities [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/provider-start/HostBootstrap/Reconcile/ProviderStart/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/lifecycle_state_model.md`, `documents/architecture/unrepresentable_state.md`

#### Objective

Give the generic provider lifecycle and closed private owning bridge one declaration home for the
capabilities that complete or inspect a provider start.

#### Deliverables

- Reconcile.ProviderStart.Internal lives in a private provider-start-internal leaf with only base
  as a dependency. Its three declarations and complete module bytes remain unchanged.
- The main library imports the leaf without exposing or reexporting its module. Public consumers
  cannot construct backend results, projection authority or fresh-managed-phase authority.
- The private export inventory, actual source ownership and named compile-fail diagnostics pin
  this boundary, and production scanning includes the leaf.

#### Validation

Reconcile.ProviderStart.Internal has one physical declaration home in the private
provider-start-internal leaf. All module bytes are retained, SHA-256
5535f83118f0c237707a320b4fbdeaec1363324566171fdcf692806667ce16e5. Its three declarations,
constructors and module exports are unchanged. The leaf depends only on base, and the main library
imports it without exposing or reexporting its module. Generic provider lifecycle, fresh-phase
ownership and the closed settlement bridge retain the same private capability types.

ColimaSpec case `provider-start capabilities have one private base-only declaration home` pins
private visibility, sole source root, exact exports and dependencies, all three declarations,
old-path absence and the actual main-library dependency. CompileFailSpec's
`ImportProviderStartInternal.hs` fails for the complete private-package diagnostic, while
`ProjectManagedPhaseWithoutAuthority.hs` fails for the exact fresh-managed-phase authority type
rather than unit. The production-source root inventory includes the leaf. Canonical capability
source homes in both owning phase documents and all three architecture/engineering documents
agree with the actual source. The providers phase's deferred evidence paths retain their bytes.

All six targeted package/type/inventory checks and all 841 focused budget, ownership, Colima,
effect, authority/export, documentation, portability, production-scanning and fixture-inventory
checks pass. Both workspaces build with tests enabled on Linux and native Windows. Windows
supplies compilation-only evidence; native runtime acceptance remains owed by the host-portability
phase. The complete owned static Colima joins and public Apple execution chain are separate scopes.

All four host-static commands pass on one frozen 1185-file source snapshot, verified in both trees
before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under
WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are static checks,
not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T08:55:02.698484+00:00 | 2026-11-07T09:04:45.971807+00:00 | 583.275541 | 5011 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T08:55:02.698448+00:00 | 2026-11-07T09:04:11.014620+00:00 | 548.318256 | 5011 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T08:55:02.697874+00:00 | 2026-11-07T08:55:07.068001+00:00 | 4.370147 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T08:55:02.698480+00:00 | 2026-11-07T08:55:12.029023+00:00 | 9.330580 | 376 Python cases; 100% coverage; exit 0 |

The relocation contains 23 nonempty lines, 46 added/removed lines across two physical paths of
one logical module, within the sprint budget. There is no production-body change. The other
202 production modules and all 714 compile-fail fixtures retain baseline bytes. Changed text
retains UTF-8 and LF. No executor, injected row, fake executable or production test branch is
introduced. The phase remains Active with private owned observations, its remaining implementation
and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.31a: Closed owned Colima observations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Observation.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Settlement/Internal.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportColimaObservation.hs`,
 `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Retain the raw owned backend observation in the private component while the public API exposes its
opaque wall-observation type.

#### Deliverables

- The wall-observation, owned-observation, expected-wall and native settlement-observation declarations have one physical private
  home. Their fields and Eq/Show derivations are unchanged.
- The public Colima adapter imports those declarations and reexports only the same opaque public
  wall-observation type. Its ready toolchain and exact backend identities remain private.
- Export, source and named import boundaries pin the private home, and existing native acquisition
  cases continue to exercise the unchanged adapter.

#### Validation

The four plan-independent observation declarations have one physical private home in
HostBootstrap.Ensure.Colima.Observation: ColimaWallObservation, ColimaOwnedObservation,
ExpectedColimaWall and ColimaWallSettlementObservation. Each complete data declaration,
including fields and Eq/Show derivation, is byte-identical to its baseline. Moving the native
settlement observation with the owned record avoids a dependency from the private data into the
main authority implementation. The main adapter imports these definitions and reexports the same
opaque public wall-observation type; its complete public export list is unchanged.

The existing hidden settlement bridge imports and reexports the same native settlement observation.
The observation declaration home preserves the opaque public boundary. Owning producers and the
typed generic join consume these same private facts. The private data module imports no public
authority implementation. The private driver unit's exact four-module inventory and the new private
observation export list are pinned.

ColimaSpec case `owned Colima observations have one private declaration home` checks actual declaration
uniqueness, both consumers, private exports and import boundaries. Its existing private driver guard
continues to check the closed unit. ImportColimaObservation.hs fails for the complete private-package
diagnostic. ForgeColimaAuthorities.hs still rejects public construction. Both fixture registration
and live-definition inventories pass. The architecture's authority table and Current Status agree
with the actual private driver and opaque public boundary.

All six targeted checks and all 842 focused budget, ownership, Colima, effect, authority/export,
documentation, portability, production-scanning and fixture-inventory checks pass. Both workspaces
build with tests enabled on Linux and native Windows. Windows supplies compilation-only evidence;
native runtime acceptance remains owed by the host-portability phase. Complete owned static joins and
the public Apple execution chain remain separate scopes.

All four host-static commands pass on one frozen 1187-file source snapshot, verified in both trees
before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under
WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are static checks,
not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T09:12:35.678639+00:00 | 2026-11-07T09:22:29.053082+00:00 | 593.376045 | 5013 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T09:12:35.678603+00:00 | 2026-11-07T09:21:59.631424+00:00 | 563.954341 | 5013 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T09:12:35.678685+00:00 | 2026-11-07T09:12:40.172624+00:00 | 4.493954 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T09:12:35.678686+00:00 | 2026-11-07T09:12:45.017306+00:00 | 9.338644 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 92 nonempty added/removed lines across three modules: 37 in the public
adapter, six in the existing settlement bridge and 49 in the new private data module, within the
sprint budget. The other 201 production modules and all 714 existing compile-fail fixtures retain
baseline bytes. One new private-import fixture raises that inventory to 715. Changed text retains
UTF-8 and LF. No executor, injected row, fake executable or production test branch is introduced.
The phase remains Active with the private settlement producer, its remaining implementation and
composed live gate owed.

#### Remaining Work

None.

### Sprint 16.31b: Private Colima settlement producer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Settlement/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/BudgetSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Produce the provider-start and wall observations only from a closed native backend result, then
join their actual generic settlement kernels inseparably.

#### Deliverables

- The private settlement bridge is the sole inspector of native applied/exact settlement variants.
  It produces the corresponding private provider-start result and projection capability with the
  same wall epoch; it imports no public authority implementation.
- The public Colima adapter's unexported continuation consumes those capabilities to project the
  exact prepared journal pair, mint the provider-wall permit and complete the provider start. A
  failed join yields no LiveColimaWall.
- Applied preserves Created and exact replay preserves Repaired at the original observed provider
  generation. The public interface gains no callback, executor, raw observation or capability.
- Actual importers, export ownership, hidden-package diagnostics and the one closed production route
  are pinned. The private eliminator is pure; tests introduce no stand-in effect executor.

#### Validation

The native settlement producer has one physical home in the private
colima-ownership-internal library. Its pure eliminator inspects only the closed native applied/exact
observation and supplies the matching provider-start result, wall epoch and private projection
capability. It imports no public authority implementation. The old main-library source is absent;
the exact five-module private inventory, export list and actual import boundary are pinned.

The public adapter's unexported withColimaProviderSettlement continuation retains the existing
rank-n generic join. Its complete signature is unchanged apart from the helper name; its journal,
permit, wall and provider-start join body is byte-identical apart from consuming the projection
value supplied by the private producer. Namespace and invocation admission still precede this
join. Neither a callback nor an authority constructor enters the public interface, whose complete
export list is unchanged. Only successful wall and provider-start settlement reaches LiveColimaWall.

ColimaSpec's `private Colima settlement producer` cases apply the actual pure eliminator to native
applied/exact values, force the projection capability and inspect Created/Repaired with the exact
input wall epoch. Its case `the private settlement producer feeds one unexported generic join`
pins the actual producer, consumer, required generic kernels and absence of a second classification.
BudgetSpec's `only the budget facade and owning Colima adapter import the private kernel` checks
the two actual generic-kernel consumers. ImportColimaSettlementInternal.hs fails for the complete
private-package diagnostic. Registration, live-definition and the closed driver inventory pass.

All eight targeted checks and all 845 focused budget, ownership, Colima, effect, authority/export,
documentation, portability, production-scanning and fixture-inventory checks pass. Both workspaces
build with tests enabled on Linux and native Windows. Windows supplies compilation-only evidence;
native runtime acceptance remains owed by the host-portability phase. Complete owned static joins
are the static settlement sprint's scope; the public Apple execution chain remains Apple Silicon acceptance.

All four host-static commands pass on one frozen 1187-file source snapshot, verified in both trees
before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under
WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are static checks,
not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T09:35:24.778282+00:00 | 2026-11-07T09:45:13.626121+00:00 | 588.848825 | 5016 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T09:35:24.778279+00:00 | 2026-11-07T09:44:37.151903+00:00 | 552.374559 | 5016 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T09:35:24.778251+00:00 | 2026-11-07T09:35:25.561122+00:00 | 0.782874 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T09:35:24.777570+00:00 | 2026-11-07T09:35:30.770616+00:00 | 5.993055 | 376 Python cases; 100% coverage; exit 0 |

The rename-neutral production delta is 210 nonempty added/removed lines across two logical modules:
88 in the public adapter and 122 in the relocated settlement module, within the sprint budget.
The other 202 production modules and all 715 compile-fail fixtures retain baseline bytes. All four
private observation declarations and shared capability declarations retain their bytes. Changed
text retains UTF-8 and LF. No executor, injected row, fake executable or production test branch is
introduced. The obsolete empty main Colima source directory is absent from the evidence path set;
all its implementation is covered by the private directory and public facade file. The phase
remains Active with complete owned static joins, its remaining implementation and composed live
gate owed.

#### Remaining Work

None.

### Sprint 16.31c: Shared Colima ownership and invocation identity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Identity.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportColimaIdentity.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Give the production adapter and private static input builder the same pure owner, record and
invocation binding algebra without duplicating the ownership protocol in the suite.

#### Deliverables

- One private identity module owns owner-token UTF-8 hex encoding, origin-record naming, acquisition
  call digests, invocation digests and namespace/toolchain owner binding.
- The public adapter projects its sealed prepared call, gate and retained backend into that algebra.
  Canonical bytes, domain tags, field order, separator, four owner-binding digests and root-disk argv
  remain unchanged. The public export list remains unchanged.
- Known-answer values and independent field/order sensitivity checks pin the actual pure functions.
  Exact private exports, actual production consumers and a named hidden-package failure pin the boundary.

#### Validation

The existing owner-token, origin-record, acquisition, invocation and bound-owner
encodings have one declaration home in the private Backend.Identity module. The public adapter
projects the actual plan, prepared wall, gate and retained backend into those pure functions.
Owner-token and UTF-8 hex declarations retain their complete baseline bytes. Domain tags,
NUL framing, decimal gate fields, argv order, the 128-bit origin filename and four bound-owner
digest groups are unchanged. Shared SHA-256 uses the same canonical UTF-8 digest primitive.
The complete public export list is byte-identical to the baseline.

ColimaSpec's `private Colima identity algebra` group pins five independent known-answer vectors:
canonical UTF-8 owner-token hex, origin filename, acquisition digest, invocation digest and
bound owner. The Unicode project input encodes as c3b8, not a locale replacement byte. Independent
changes to every owner-token field, each bound namespace/fingerprint input, every acquisition
input and argument order, and every invocation gate field produce distinct identities. These
cases apply actual pure functions to values; no fixture executor stands in for their subject.

Its case `the prepared adapter projects into one private identity algebra` pins actual private
ownership and exports, absence of duplicate owner/hex/record serializers, actual prepared wall
and gate projections and the sole domain-tag declaration home. ImportColimaIdentity.hs fails
for the complete private-package diagnostic. Fixture registration and live-definition inventories
pass. Canonical budgeting and ownership documentation state the same private protocol boundary.

All thirteen targeted checks and all 855 focused budget, ownership, Colima, effect, authority/export,
documentation, portability, production-scanning and fixture-inventory checks pass. Both workspaces
build with tests enabled on Linux and native Windows. Windows supplies compilation-only evidence;
native runtime acceptance remains owed by the host-portability phase. Native fixture result
retention and complete owned static joins remain separate sprint scopes.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under
WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are static checks,
not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T10:04:07.374709+00:00 | 2026-11-07T10:14:11.887163+00:00 | 604.513054 | 5027 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T10:04:07.374778+00:00 | 2026-11-07T10:13:39.120599+00:00 | 571.746393 | 5027 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T10:04:07.374746+00:00 | 2026-11-07T10:04:08.200782+00:00 | 0.826038 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T10:04:07.374775+00:00 | 2026-11-07T10:04:13.330047+00:00 | 5.955278 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 181 nonempty added/removed lines across two modules: 103 in the public
adapter and 78 in the new private identity module, within the sprint budget. The other 203
production modules and all 715 existing compile-fail fixtures retain baseline bytes. One new
private-import fixture raises that inventory to 716. Changed text retains UTF-8 and LF. No executor,
injected row, fake executable or production test branch is introduced. The phase remains Active
with native fixture result retention, its remaining implementation and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.31d: Native fixture resolution retains its actual result [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/unrepresentable_state.md`, `documents/engineering/testing.md`

#### Objective

Retain the native fixture pipeline's existing opaque resolver result for static owned joins while
all descriptive views remain pure projections of the same real observation.

#### Deliverables

- The existing executeNativeResolverFixtureWithSettlement retains its actual TrustedResolverResult
  together with the original execution capsule. Native walking and settlement remain one pipeline;
  it creates no additional resolver, fake executable, execution callback or production override.
- The existing settlementView becomes available inside the private testing facade. Existing native
  fixture cases project the same descriptive results from the retained opaque result.
- Real ready/missing/refused fixture cases and complete private import boundaries remain checked.
  A host whose native fixture backend is Unsupported reports that actual result; no ready authority
  is manufactured for that host.

#### Validation

The existing private native fixture entry retains its actual opaque TrustedResolverResult
beside the execution capsule. Its native walk, protocol rendering, bootstrap identity selection
and shared settlement remain the same pipeline. The existing settlementView is exported only
inside the private testing facade, and its complete implementation retains baseline bytes.
Existing descriptive consumers project the same real result through a test-local wrapper.

ColimaSpec's two native fixture resolution cases exercise actual ready and missing-Colima results.
They retain the observed toolchain paths and fingerprint or actual Brew/Python evidence, and compare
pure descriptive projections of those same results. CoverageManifest declares both cases against
the POSIX native fixture capability. The alternative branch calls the actual unsupported backend
and checks its protocol and result; it creates no ready toolchain. Native Windows compilation
passes, while execution on that host remains owed by host-portability acceptance.

The source/export case pins the actual retained-result signature, native walk, rendering and
settlement, plus all three dispositions of the unchanged pure projection. ImportColimaResolverTesting.hs
remains a complete hidden-package refusal. Registration and live-definition inventories pass.
No additional resolver producer, fake executable, execution callback, production override or public
API is introduced. The complete owned static joins remain a separate sprint scope.

All seven targeted checks and all 859 focused budget, ownership, Colima, effect, authority/export,
documentation, portability, production-scanning and fixture-inventory checks pass. Both workspaces
build with tests enabled on Linux and native Windows. Windows evidence is compilation only.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under
WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are static checks,
not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T10:29:04.121637+00:00 | 2026-11-07T10:39:24.603705+00:00 | 620.482409 | 5031 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T10:29:14.283367+00:00 | 2026-11-07T10:39:02.535957+00:00 | 588.252913 | 5031 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T10:29:24.494151+00:00 | 2026-11-07T10:29:30.420317+00:00 | 5.926164 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T10:29:30.752875+00:00 | 2026-11-07T10:29:39.430082+00:00 | 8.677209 | 376 Python cases; 100% coverage; exit 0 |

The production delta is eleven nonempty added/removed lines in one private module, within the
sprint budget. The other 204 production modules and all 716 compile-fail fixtures retain baseline
bytes. Changed text retains UTF-8 and LF. The phase remains Active with its remaining implementation
and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.31e: Static provider-start and wall settlement joins [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Settlement/Internal.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Settle the generic provider start and provider wall inseparably from one exact successful backend invocation.

#### Deliverables

- The private owning bridge is the sole inspector of native applied/exact settlement observations.
  It produces the corresponding private provider-start and wall facts. The public adapter's unexported
  continuation consumes its projection capability to join the exact prepared journal pair to the
  provider-neutral permit mint and provider-start completion.
- `settleColimaWallCall` checks the owned observation's state root, namespace key, record path, Docker config,
  bound owner, and invocation digest (which carries the gate's operation, session, attempt, and journal
  version) against the prepared call before producing authority.
- Applied maps to generic provider `Created`; exact replay maps to `Repaired`; both preserve the original
  observed provider generation and return its exact managed `Running` handle and receipt.
- `LiveColimaWall` is produced only after both wall and provider-start settlement succeed and retains their
  change views plus all backend identity needed by live and cleanup.
- Foreign, conflict, unsupported, failed, cross-call, or replay-mismatched results cannot settle either side.

#### Validation

ColimaSpec's ten `native fixture backed owned settlement` cases apply the actual public
settleColimaWallCall to private descriptive owned observations carrying the actual native fixture's
opaque ready toolchain. withPreparedTestCallForGateAndEnvelope uses the real plan, admitted budget,
reservation, observed provider handle and protected-store gate; shared private naming and identity
functions derive the binding inputs. It adds no resolver producer, executor or production test branch.

The applied case produces wall epoch 73, a Created wall and Created provider. The exact case produces
the same wall epoch, an unchanged wall and Repaired provider. The actual private settlement producer
and generic provider-start completion retain observed provider generation 17 in both cases and
validate its matching receipt. The source case `the owned join retains the generic managed handle
and matching receipt` pins the adapter's direct forwarding of that same handle and receipt into the
opaque live wall; it introduces no public observation accessor.

Each session, attempt and physical journal-version case obtains a real alternative protected-store
gate and asserts that only that coordinate differs. The alternative result settles against its own
prepared call, then refuses the original call with the exact outside-plan/fence-namespace Failure.
Independent state-root, namespace-key, record-path, isolated Docker-config and bound-owner changes
produce that same refusal. The three `static unowned settlement` cases preserve Conflict, Failure
and Unsupported without requiring a ready native fixture.

CoverageManifest declares all ten fixture-backed cases against the POSIX native walker capability.
Its alternative branch checks the actual native unsupported result and creates no ready authority.
This is static settlement evidence, not execution of the public Apple toolchain chain.

Compile-fail cases ImportColimaSettlementInternal.hs, ImportColimaObservation.hs,
ImportProviderStartInternal.hs, ForgePreparedProviderStart.hs, CoercePreparedProviderStartRoles.hs,
ForgeColimaAuthorities.hs, CoerceColimaAuthorityRoles.hs, ForgeProviderWallSettlementPermit.hs,
RawObservationProviderWallSettlement.hs and CoerceProviderWallSettlementPermitRoles.hs pass for
their registered reasons. Registration and live-definition inventories pass. All 27 targeted cases and all 874 focused budget,
ownership, Colima, effect, authority/export, documentation, portability, production-scanning and
fixture-inventory checks pass. Both workspaces build with tests enabled on Linux and native Windows.
Windows supplies compilation evidence only; its runtime acceptance remains owed.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under
WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are static checks,
not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T10:42:58.943542+00:00 | 2026-11-07T10:52:40.767991+00:00 | 581.824715 | 5046 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T10:42:58.943739+00:00 | 2026-11-07T10:52:06.857562+00:00 | 547.914078 | 5046 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T10:42:58.943701+00:00 | 2026-11-07T10:42:59.707210+00:00 | 0.763512 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T10:42:58.943743+00:00 | 2026-11-07T10:43:04.593026+00:00 | 5.649289 | 376 Python cases; 100% coverage; exit 0 |

There is no production Haskell delta. All 205 production modules and all 716 compile-fail fixtures
retain baseline bytes, and changed text retains UTF-8 and LF. The phase remains Active with its
remaining implementation and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.32: Settled live Colima Docker route [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Report.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/engineering/ensure_reconcilers.md`

#### Objective

Make the settled live wall the sole route to Docker in the exact Colima namespace.

#### Deliverables

- `runLiveColimaDocker` consumes only the opaque LiveColimaWall and its arguments. Its descriptive
  ColimaDockerRun retains a complete CapturedRun and an optional post-call revalidation failure.
- The private owning driver is absent from public imports; its route admission checks the exact
  Managed stage, owner, lineage and acquisition invocation through one total pure function.
- Docker always names its exact colima-profile context in the retained isolated Docker config;
  routedDockerCommand refuses arguments that override the route.
- The driver revalidates the protected-store entry, machine binding, Docker context, complete
  manifest and running profile around the command. An unavailable command, including a native
  timeout, is ColimaMutationCommandUnavailable and has no captured run. The route writes no stage.
- A command that completes retains its actual exit and both streams even when the driver's
  post-call standing check fails. That failure accompanies the run instead of erasing it.
- The public wrapper revalidates its toolchain before and after the driver. A pure result join
  preserves driver refusal as not-run, and keeps either or both later failures beside a completed
  capture. A nonzero exit remains a completed run.
- Public constructors expose descriptive results only; the live wall stays opaque and no alternate
  raw Docker execution route is public.

#### Validation

ColimaSpec's thirteen `pure managed Docker route` cases apply the actual route admission,
command classification and completed-result join to values. The exact Managed record admits;
individual owner, lineage and invocation mismatches refuse; every other real stage, including
Released, refuses with the exact Managed-lineage fault. The actual native timeout text classifies
as ColimaMutationCommandUnavailable with no capture. Completed success and nonzero exits retain
both streams through the same classifier.

The result cases distinguish a driver refusal from a completed command. Driver refusal remains
Left for either toolchain check result. A completed command retains its complete CapturedRun
when ownership standing, toolchain identity, or both later checks fail. A valid completed run
has no post-call failure. These are pure decision checks; they claim no stand-in Docker execution.

The source case pins the actual owning driver's pure-policy calls, route admission before the
routed command, absence of stage writes and duplicate record identity decisions, and retention
of capture beside a failed post-call standing check. It also pins the sealed wrapper's pre/post
toolchain revalidation, owning-driver call and pure result join. The sole native acceptance
consumer compiles against ColimaDockerRun and requires no post-call failure.

The owning driver remains private. ImportColimaOwnership.hs, ForgeColimaAuthorities.hs and
CoerceColimaAuthorityRoles.hs retain their registered refusal reasons; exact public/private export
pins, registration and live-definition inventories pass. The only new named type is descriptive
ColimaDockerRun, which grants no live or cleanup authority. No resolver producer, injected
executor or production test branch is introduced.

All nineteen targeted checks and all 887 focused budget, ownership, Colima, effect, authority/export,
documentation, portability, production-scanning and fixture-inventory checks pass. Both workspaces
build with tests enabled on Linux and native Windows. Windows supplies compilation evidence only;
its runtime acceptance remains owed.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under
WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are static checks,
not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T10:56:41.160188+00:00 | 2026-11-07T11:06:26.976520+00:00 | 585.816565 | 5059 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T10:56:41.159967+00:00 | 2026-11-07T11:05:54.943210+00:00 | 553.783462 | 5059 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T10:56:41.159967+00:00 | 2026-11-07T10:56:41.933798+00:00 | 0.773830 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T10:56:41.160523+00:00 | 2026-11-07T10:56:46.829102+00:00 | 5.668583 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 59 nonempty added/removed lines across three modules: 27 in the owning
driver, 21 in its descriptive report module and eleven in the public adapter. This is within
the sprint budget. The other 202 production modules and all 716 compile-fail fixtures retain
baseline bytes, and changed text retains UTF-8 and LF. The phase remains Active with its remaining
implementation and composed live gate owed.

#### Remaining Work

None.

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

### Sprint 16.34: Exact Colima cleanup authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
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

ColimaSpec's native fixture-backed case `the exact live wall introduces cleanup authority`
settles the actual public prepared call over the retained native fixture ready toolchain, then
calls the actual withColimaCleanupAuthority eliminator on the resulting opaque live wall. It
returns the continuation result under the same scoped wall rather than constructing authority
from a raw observation. CoverageManifest declares eleven native fixture-backed owned-settlement
cases and verifies their actual branch completions in the full suite. The other branch checks
actual native unsupported resolution without manufacturing a ready result or live wall.

The four pure `private cleanup lineage admission` cases apply the actual shared private policy
to a real codec-produced Managed record. The exact owner/lineage/acquisition invocation admits;
each independent mismatch returns the exact managed-stage-belongs-to-another-lineage fault.
The source case `cleanup authority retains the exact live ownership package` pins the complete
profile, owned backend, epoch, managed Running handle, matching receipt and reservation fence
retained by the eliminator. It also pins the actual private driver's first refusal branch before
replay or mutation, absence of a duplicate local lineage predicate, and the shared comparison
used by both cleanup and Docker admission. These are pure policy and
source-flow checks; they do not claim to execute a stand-in delete command or a public Apple run.

ImportColimaOwnership.hs, ForgeColimaAuthorities.hs, CoerceColimaAuthorityRoles.hs and
CrossPlanColimaConsumer.hs retain their registered refusal reasons. The private export pin,
public owning-driver absence guard, registration and live-definition inventories pass. The
cleanup authority remains opaque and nominal, with no public raw driver route.

All 24 targeted checks and all 893 focused budget, ownership, Colima, effect, authority/export,
documentation, portability, production-scanning and fixture-inventory checks pass. Both workspaces
build with tests enabled on Linux and native Windows. Windows supplies compilation evidence only;
its runtime acceptance remains owed. No execution override or additional resolver producer exists.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under
WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are static checks,
not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T11:10:09.845690+00:00 | 2026-11-07T11:19:54.334611+00:00 | 584.489097 | 5065 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T11:10:09.845275+00:00 | 2026-11-07T11:19:19.872829+00:00 | 550.027716 | 5065 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T11:10:09.845503+00:00 | 2026-11-07T11:10:10.629360+00:00 | 0.783859 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T11:10:09.845580+00:00 | 2026-11-07T11:10:15.665950+00:00 | 5.820374 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 23 nonempty added/removed lines in the private owning driver,
within the sprint budget. The other 204 production modules and all 716 compile-fail fixtures
retain baseline bytes. The public adapter is byte-identical to the baseline. Changed text
retains UTF-8 and LF. The phase remains Active with its remaining implementation and composed
live gate owed.

#### Remaining Work

None.

### Sprint 16.35: Journal-prepared Colima cleanup call [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Identity.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
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

ColimaSpec's two native fixture-backed cleanup preparation cases settle the actual public
prepared wall, obtain cleanup authority through its real eliminator, and call public
prepareColimaCleanupCall under a real teardown gate. The retained fence succeeds; a different
fence returns the complete cleanup-gate Conflict. CoverageManifest declares thirteen native
fixture-backed owned-settlement cases and the full suite verifies their actual branch completions.
The alternative branch checks actual native unsupported resolution without a fabricated toolchain.

The `stable cleanup invocation identity` group pins the independent SHA-256 known-answer vector
bd8c1eb157f3bdb87e749a5f7da051ea1792df12273de1915a571b92146857ec over the cleanup domain, call,
plan, operation and decimal fence with NUL framing. Every stable coordinate changes the digest.
Actual protected-store gates independently change only session, attempt or physical journal
version and retain the same release identity. The source case pins the actual adapter's stable
projection into the private identity algebra and absence of retry-coordinate serialization.
The shared private function takes only the stable coordinates; there is no second serializer.

The complete prepareColimaCleanupCall declaration and body retain baseline bytes. It still seals
the current exact gate in the prepared managed transition and refuses a different fence before
preparation. Public exports are unchanged. Stable backend release identity does not weaken
current journal preparation or supply deletion authority from descriptive values.

ColimaAcquireCallAsCleanupGate.hs, WrongColimaCleanupPhase.hs, ForgeColimaAuthorities.hs,
CoerceColimaAuthorityRoles.hs and ImportColimaIdentity.hs retain their registered refusal reasons.
Private export pins, registration and live-definition inventories pass. All 25 targeted checks
and all 899 focused budget, ownership, Colima, effect, authority/export, documentation, portability,
production-scanning and fixture-inventory checks pass. Both workspaces build with tests enabled
on Linux and native Windows. Windows supplies compilation evidence only; runtime acceptance remains
owed. The static cases execute no stand-in delete command or public Apple execution chain.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under
WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are static checks,
not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T11:23:48.214652+00:00 | 2026-11-07T11:33:34.598514+00:00 | 586.383976 | 5071 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T11:23:48.214700+00:00 | 2026-11-07T11:33:04.331090+00:00 | 556.116501 | 5071 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T11:23:48.214699+00:00 | 2026-11-07T11:23:49.007760+00:00 | 0.793062 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T11:23:48.217464+00:00 | 2026-11-07T11:23:54.064526+00:00 | 5.847061 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 36 nonempty added/removed lines across two modules: thirteen in the
private identity algebra and 23 in the public adapter, within the sprint budget. The other
203 production modules and all 716 compile-fail fixtures retain baseline bytes. Changed text
retains UTF-8 and LF. No additional resolver producer, executor or production test branch is
introduced. The phase remains Active with its remaining implementation and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.36: Closed Colima cleanup retry admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`, `documents/architecture/ownership_invariant.md`

#### Objective

Select cleanup begin, retry or completed replay from one private closed durable-stage decision.

#### Deliverables

- ColimaCleanupResume is a private descriptive sum for Managed begin, Releasing resume and Released
  replay. Its pure admission function consumes the actual stage record and requested cleanup invocation.
- Releasing and Released admit only their durably committed cleanup invocation; other stages refuse
  this admission boundary. No decision constructor grants mutation or deletion authority.
- The owning driver checks the exact owner, lineage and acquisition invocation first, then consumes
  this decision before context admission or command work inside the same protected-store entry.
- A completed replay enters its existing conditional absence path rather than profile deletion.
  Managed refresh and Releasing continuation retain the existing manifest and bound-identity checks.
- The public cleanup authority and the private owning-driver import boundary stay unchanged.

#### Validation

ColimaSpec's seven `private cleanup resume admission` cases apply the actual classifier
to codec-produced durable stage records. Managed selects begin; the committed cleanup invocation
selects Releasing continuation or Released replay. A different invocation refuses either committed
stage with the exact non-resumable ownership fault. The remaining stages, including ContextReleased,
refuse this admission boundary. Conditional profile and namespace completion are separate sprint
scopes and remain owed.

The source case `the real cleanup admits its retry before context or deletion work` pins the
actual driver's lineage-first and retry-before-context ordering, explicit Released replay and
pure total signature. The existing refresh-before-freeze guard ties the classifier's Managed
mapping to the actual driver's refresh branch and retains manifest-before-stage publication.
The closed private sum is descriptive, not a deletion receipt. The actual
entry retains the same protected-store exclusion, manifest checks, machine/disk bindings and
release operations downstream; no interpreter or execution override is added.

ImportColimaOwnership.hs, ForgeColimaAuthorities.hs and CoerceColimaAuthorityRoles.hs retain their
registered refusal reasons. The owning-driver privacy and exact export pins, registration and
live-definition inventories pass. Public exports and all other production modules are unchanged.
These pure and source-flow checks claim no stand-in delete execution or public Apple run.

All fourteen targeted checks and all 906 focused budget, ownership, Colima, effect, authority/export,
documentation, portability, production-scanning and fixture-inventory checks pass. Both workspaces
build with tests enabled on Linux and native Windows. Windows supplies compilation evidence only;
its runtime acceptance remains owed.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under
WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are static checks,
not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T11:41:24.791918+00:00 | 2026-11-07T11:51:18.299354+00:00 | 593.507493 | 5078 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T11:41:24.791851+00:00 | 2026-11-07T11:50:47.387989+00:00 | 562.596190 | 5078 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T11:41:24.791903+00:00 | 2026-11-07T11:41:25.562711+00:00 | 0.770809 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T11:41:24.791910+00:00 | 2026-11-07T11:41:30.453384+00:00 | 5.661468 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 51 nonempty added/removed lines in one private owning-driver module,
within the sprint budget. The other 204 production modules and all 716 compile-fail fixtures
retain baseline bytes. Changed text retains UTF-8 and LF. The phase remains Active with its
remaining implementation and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.36a: Conditional Colima profile release decisions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`, `documents/architecture/ownership_invariant.md`

#### Objective

Classify the exact profile identity, bounded delete result and absence readback before forgetting origins.

#### Deliverables

- The exact listed profile, admitted wall, machine identity and data-disk binding precede deletion.
- The cleanup invocation is durably recorded before the bounded delete command. Failed, unavailable
  or uncertain deletion retains the release stage and origins until fresh observations authorize progress.
- Strict profile-absence and kernel data-disk observations precede origin release. A changed identity,
  duplicated listing, malformed or stderr-bearing report cannot authorize deletion or forgetting.
- A matching committed release can continue from genuine already-absent observations without
  deleting a replacement or requiring an unowned profile to reappear.
- The actual private driver consumes the pure decisions under its existing ownership entry.

#### Validation

ColimaSpec's fifteen `private conditional profile release` cases apply the actual pure
profile, machine-binding, delete-completion, absence and frozen-manifest decisions to values.
They cover exact wall/runtime, changed wall or runtime, duplicate listing, uncommitted absence,
committed absence, exact machine binding, machine/epoch drift, missing or different bindings,
failed/unavailable/completed delete, retained profile and unrelated profile names.

Frozen-manifest cases retain the committed manifest while admitting only unchanged remainders.
Added entries, replaced identities, a non-Releasing stage and a different retained digest refuse.
The actual driver retains exact full-manifest standing for Managed and validates original home
and Docker-config root identities before accepting frozen Releasing remainders.

The source case `the actual cleanup consumes profile decisions and the shared absence recovery`
pins the real driver delegation, root checks, kernel disk observation, retained record versions
and shared resumeReportedRemoval boundary. The already-absent branch rechecks strict profile
absence, the exact committed stage/version and invocation, kernel disk absence and valid retained
bindings before record cleanup. It accepts already-forgotten records without issuing a second
delete, and reaches the existing conditional namespace settlement only after both origins are gone.

OwnershipSpec's `an interrupted reported removal cleans its record only over fresh absence`
executes the actual protected-store/bound-record primitive and refuses both formerly bound and
replacement present identities. OwnershipPosixSpec's manifest cases exercise the actual native
walker in temporary directories. Source guards connect this driver to those existing primitives;
these checks claim no stand-in provider deletion or public Apple execution chain.

The existing refresh/order guards now follow the actual profile and machine classifier homes,
while retaining freeze-before-delete and manifest-before-stage checks. Frozen metadata replacement
is pinned to its complete OwnershipOccupied diagnostic; its bytes, retained manifest and no-command
assertions remain intact. The existing described-command transaction remains coherent but is not
counted as real provider execution evidence.

ImportColimaOwnership.hs, ForgeColimaAuthorities.hs and CoerceColimaAuthorityRoles.hs retain their
registered refusal reasons. Owning-driver privacy, exact private export pins, registration and
live-definition inventories pass. All 37 targeted checks and all 921 focused budget, ownership,
Colima, effect, authority/export, documentation, portability, production-scanning and fixture-inventory
checks pass. Both workspaces build with tests enabled on Linux and native Windows. Windows supplies
compilation evidence only; its runtime acceptance remains owed.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The gate host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under
WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies Haskell real-kernel test temporaries. These are static checks,
not crash-durability or live provider acceptance.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T12:01:41.525829+00:00 | 2026-11-07T12:11:24.650668+00:00 | 583.124901 | 5093 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T12:01:41.525633+00:00 | 2026-11-07T12:10:53.787919+00:00 | 552.262340 | 5093 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T12:01:41.525634+00:00 | 2026-11-07T12:01:42.274325+00:00 | 0.748692 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T12:01:41.525588+00:00 | 2026-11-07T12:01:47.380289+00:00 | 5.854697 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 163 nonempty added/removed lines in one private owning-driver module,
within the sprint budget. The other 204 production modules and all 716 compile-fail fixtures
retain baseline bytes. Public exports are unchanged. Changed text retains UTF-8 and LF. No new
executor, resolver producer or production testing branch exists. The phase remains Active with
conditional context/namespace completion, its remaining implementation and composed live gate owed.

#### Remaining Work

None.

### Sprint 16.36b: Conditional Colima directory removal recovery [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`, `core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`documents/architecture/durable_state.md`, `documents/architecture/ownership_invariant.md`

#### Objective

Finish a removed directory's retained record through the one shared kernel-removal recovery boundary.

#### Deliverables

- The shared resumeOwnedRemoval consumes a retained Bound token, actual row and live protected entry.
  It checks release and durable-record capabilities before kernel work and refuses reported or
  found-state records rather than treating them as created kernel objects.
- Fresh kernel absence reaches parent synchronization and only then the existing forget continuation.
  A present identity, including the former identity, is refused and is never removed by recovery.
- Colima directory readers and release use one pure absent-origin, identity-bound directory policy.
  A removed bound directory delegates to the shared producer and forgets only its observed version.
- An absent unrecorded directory is an idempotent no-op. An unrecorded present directory or a
  replacement preserves the objects and any retained record.
- The native family declares the actual row's release/record support; an unavailable row reports
  its real declared refusal. No execution override or production test branch exists.

#### Validation

Four native directory-release cases use actual protected entries, retained origin records and
kernel temporary directories. They cover removal interrupted before origin settlement, an absent
unrecorded directory, an unrecorded present directory and a foreign replacement. Removed created
directories settle their retained records; unrecorded or replaced present objects remain intact.
The native family declares its actual selected row and genuine unsupported answer.

Two directory-policy cases check the actual absent-origin bound-directory classifier and source
connections to the sole shared kernel recovery producer. OwnershipSpec exercises actual retained
reported and found-state records and proves their refusal without forgetting. The existing lifetime
cases now include kernel removal recovery: revoked and foreign-thread entries refuse before effects.
The classifier inventory includes both new release/record clause checks.

The shared resumeOwnedRemoval producer observes fresh kernel absence, syncs the parent and only
then invokes the retained-record settlement. It refuses reported objects, found-state origins and
any present identity, including the formerly bound identity; it never removes an object again.
The Colima consumer reenters its actual stored bound directory and forgets only at its stored version.
Ordinary reobservation and release keep their existing behavior.

ImportColimaOwnership.hs, ForgeColimaAuthorities.hs and CoerceColimaAuthorityRoles.hs retain their
registered refusal reasons. Private owning-driver exports, the additive shared recovery export,
registration and live-definition inventories pass. All 15 targeted checks and all 929 focused checks
pass. Both workspaces build with tests enabled on Linux and native Windows. Windows supplies
compilation evidence only; native runtime acceptance remains owed.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2,
Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies real-kernel temporaries. This is static/kernel validation, not crash
durability, public Apple execution or live provider deletion evidence.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T12:32:52.678326+00:00 | 2026-11-07T12:42:49.298514+00:00 | 596.620244 | 5101 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T12:32:52.678423+00:00 | 2026-11-07T12:42:17.344428+00:00 | 564.666061 | 5101 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T12:32:52.678362+00:00 | 2026-11-07T12:32:56.761812+00:00 | 4.083454 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T12:32:52.678422+00:00 | 2026-11-07T12:33:01.900012+00:00 | 9.221591 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 104 nonempty added/removed lines in two modules, within the sprint budget.
The other 203 production modules and all 716 compile-fail fixtures retain baseline bytes. The shared
ownership API adds its kernel removal recovery counterpart; the public Colima deletion route remains
opaque. Changed text retains UTF-8 and LF. No executor, resolver producer or production testing branch
is added. The phase remains Active with context/namespace completion, remaining implementation and
its composed live gate owed.

#### Remaining Work

None.

### Sprint 16.36c: Context removal decisions and Docker standing preflight [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`, `documents/architecture/ownership_invariant.md`

#### Objective

Admit retained Docker standing before namespace effects, and keep failed context removal unsettled.

#### Deliverables

- The actual Docker driver performs read-only stored-stage and lineage admission before parent
  validation, directory acquisition or commands. Missing, Released, releasing and mismatched stages
  preserve existing records and cannot recreate a context directory or origin.
- Managed admission continues through the existing actual directory, manifest and profile checks;
  completed Docker captures retain their post-call standing result.
- Context removal consumes the shared pure delete-completion decision before strict absence
  readback. Failure returns before any ContextReleased transition or context ownership removal.
- Actual temporary protected-store cases and pure/source cases hold these boundaries without a
  stand-in executor or production testing branch. Private exports remain explicitly pinned.

#### Validation

ColimaSpec's five `native Docker standing preflight` cases exercise actual protected entries
and durable stage records. They cover exact Managed admission, Released refusal, Releasing and
ContextReleased refusal, every owner/lineage/acquisition-invocation mismatch and an absent stage.
Each compares actual stored records before and after and checks that no context directory or
origin appears. The production read-only preflight reads the stage and consumes the existing
pure lineage decision; it has no namespace acquisition or command effect.

Three `private context release decisions` cases apply the shared delete-completion classifier
to unavailable, failed and successful context removal values, and pin the actual driver's control
flow. A failed removal returns before readback or ContextReleased. Successful completion reaches
strict context absence; existing retained binding and fingerprint checks remain before removal.
The Docker source case pins stored admission before parent validation and context acquisition.

The existing pure managed Docker route cases retain completed captures and post-call ownership
and toolchain results. Actual Docker standing checks retain directory, manifest and machine-binding
validation after stage admission. These checks use pure decisions, real protected-store/kernel
operations and source connections; they claim no simulated or public Apple command execution.

ImportColimaOwnership.hs, ForgeColimaAuthorities.hs and CoerceColimaAuthorityRoles.hs retain their
registered refusal reasons. Private exports, owning-driver privacy, registration and live-definition
inventories pass. All 28 targeted and all 937 focused checks pass. Both workspaces build with tests
enabled on Linux and native Windows. Windows supplies compilation evidence only; native runtime
acceptance remains owed.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2,
Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies real-kernel temporaries. This is static/kernel validation, not crash
durability or live provider deletion evidence.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T12:46:44.654250+00:00 | 2026-11-07T12:56:36.975663+00:00 | 592.321472 | 5109 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T12:46:44.654289+00:00 | 2026-11-07T12:56:02.254923+00:00 | 557.600689 | 5109 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T12:46:44.654199+00:00 | 2026-11-07T12:46:45.412315+00:00 | 0.758114 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T12:46:44.654286+00:00 | 2026-11-07T12:46:50.372553+00:00 | 5.718268 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 72 nonempty added/removed lines in one private owning-driver module,
within the sprint budget. The other 204 production modules and all 716 compile-fail fixtures retain
baseline bytes. Public exports are unchanged. Changed text retains UTF-8 and LF. No executor,
resolver producer or production testing branch is added. The phase remains Active with conditional
context/namespace recovery, remaining implementation and its composed live gate owed.

#### Remaining Work

None.

### Sprint 16.36d: Conditional Colima ContextReleased retry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`, `documents/architecture/ownership_invariant.md`

#### Objective

Resume the committed context namespace settlement without reissuing provider removal.

#### Deliverables

- The closed cleanup retry decision admits ContextReleased only for the committed cleanup invocation.
  Other invocations refuse before context or namespace effects.
- Fresh completion and admitted retry use one kernel-only helper with the actual protected entry,
  exact held stage/version, retained manifest evidence and unchanged parent bindings.
- The helper removes only unchanged retained context entries and the bound created directory.
  Fresh absence recovers a retained origin through shared kernel removal recovery; completed absence
  is idempotent. Replacements, added entries or changed evidence preserve objects and records.
- Only successful context settlement reaches the existing conditional Released transition. Neither
  the helper nor this retry recreates directories or executes a provider command.
- The real native manifest/release family declares its row and actual unsupported answer. Public
  deletion authority and private export pins remain intact.

#### Validation

ColimaSpec's eight `native context namespace recovery` cases exercise actual protected entries,
retained stage/manifest/origin versions and kernel temporary directories. They cover retained
metadata removal, a directory removed before origin settlement, already-settled absence, a replaced
root, an added entry, replaced metadata, a changed held stage and a changed retained manifest.
Successful context settlement forgets only its observed bound origin; stage and manifest bytes
and versions remain retained for the driver's next durable transition. Refusals preserve the
objects and origin. The family declares its actual native manifest/release row and verifies a
genuine unavailable-row refusal where that row cannot execute.

Two `private cleanup resume admission` cases admit the committed ContextReleased invocation and
refuse another. The existing earlier-stage case retains refusal for every acquisition stage.
The `private context namespace retry` source case connects both fresh and resumed settlement to
releaseColimaContextNamespace before advancing Released. The helper checks the actual held stage
and version, retained manifest evidence, parent bindings, actual namespace remainders and bound
directory. Fresh absence delegates to the shared kernel recovery. No provider command is reissued.

The shared namespace remainder walker retains its actual bound root, immutable manifest admission,
deepest-first entry removal and native identity checks. Pure/profile, context completion, ownership,
entry-lifetime, privacy and export guards remain intact. All 29 targeted and all 949 focused checks
pass. Both workspaces build with tests enabled on Linux and native Windows. Windows supplies
compilation evidence only; native runtime acceptance remains owed.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2,
Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies real-kernel temporaries. This is static/kernel validation, not crash
durability, simulated deletion or public Apple execution evidence.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T13:05:12.032458+00:00 | 2026-11-07T13:15:06.644141+00:00 | 594.611682 | 5121 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T13:05:12.032482+00:00 | 2026-11-07T13:14:32.703809+00:00 | 560.671329 | 5121 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T13:05:12.032482+00:00 | 2026-11-07T13:05:12.806434+00:00 | 0.773952 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T13:05:12.037656+00:00 | 2026-11-07T13:05:17.686735+00:00 | 5.649077 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 178 nonempty added/removed lines in one private owning-driver module,
within the sprint budget, including the namespace walker's move to its shared private home.
The other 204 production modules and all 716 compile-fail fixtures retain baseline bytes. Public
exports are unchanged. Changed text retains UTF-8 and LF. No executor, resolver producer or
production testing branch is added. The phase remains Active with Released namespace/parent-origin
recovery, remaining implementation and its composed live gate owed.

#### Remaining Work

None.

### Sprint 16.36e: Conditional Colima Released namespace settlement [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/durable_state.md`, `documents/architecture/ownership_invariant.md`

#### Objective

Finish or resume Released namespace and parent-origin settlement from retained identities.

#### Deliverables

- The committed cleanup invocation reaches one kernel-only finisher before writing Released
  and verifies complete vacancy on exact replay. The actual held stage/version, strict context/report-origin absence and frozen
  manifest evidence precede remaining-root admission.
- Every remaining home, cache and temporary root retains its original created-directory binding.
  Only unchanged retained manifest remainders authorize removal, including tracked scaffolding and
  cache/temporary data. New or replaced state remains intact.
- Temporary, cache and home origins settle child-first, including removed-object origin recovery.
  Only then is the retained manifest forgotten at its version. Missing manifest evidence authorizes
  no deletion; actual complete vacancy alone permits completed replay.
- Parent origins release only over empty unchanged owned parents. Removed parents recover through
  the shared absence/sync producer. Shared nonempty or foreign/replaced parents remain intact.
- Fresh completion and exact replay return Right (); the durable Released record remains retained.
  Public deletion stays opaque and journal-prepared. Native families declare actual row/refusal paths.

#### Validation

ColimaSpec's sixteen `native Released namespace recovery` cases use actual prepared namespaces,
protected stage/manifest/origin records and kernel temporary objects. They cover retained cache,
temporary data and scaffolding; interrupted temporary, child and home origin settlement; roots
already settled with a retained manifest; completed replay; replaced home/cache/metadata; added
entries; a changed held stage; a missing manifest; and removed/shared/replaced namespace parents.
They hold actual retained versions, bytes, directory identities and foreign contents. Every native
or genuine unsupported branch is declared and counted by the actual manifest/release row family.

Two `private Released namespace protocol` cases apply the actual committed-manifest decision and
pin the fresh/replay kernel helper and the actual parent recovery producer. The helper admits the
exact held Released stage/version, checks context and reported-origin absence, retains committed
manifest evidence and reobserves every remaining root before deletion. Its native manifest walker
admits only unchanged retained remainders, including cache/temp data and tracked scaffolding.
Temporary, cache and home roots settle child-first; only then is the observed manifest version
forgotten. Missing evidence admits only actual complete vacancy and no remaining-root deletion.

Fresh completion and exact replay consume the same helper and stage-table decisions; replay first
requires complete vacancy. An already
removed bound parent uses shared fresh-absence/sync recovery; empty unchanged owned parents release,
while shared nonempty or replaced parents retain their objects and origins. The retained Released
stage remains available for exact completed replay. No raw scaffold removal or second provider
command is used in this kernel settlement.

All 35 targeted and all 968 focused checks pass, including existing pure/profile/context retry,
ownership/entry-lifetime, private export, authority, registration and live-definition checks. Both
workspaces build with tests enabled on Linux and native Windows. Windows supplies compilation
evidence only; native runtime acceptance remains owed.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2,
Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies real-kernel temporaries. These checks claim no crash-durability,
simulated deletion or public Apple execution evidence.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T13:19:27.537678+00:00 | 2026-11-07T13:29:28.985217+00:00 | 601.447541 | 5140 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T13:19:27.537645+00:00 | 2026-11-07T13:28:53.807148+00:00 | 566.269498 | 5140 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T13:19:27.537724+00:00 | 2026-11-07T13:19:28.324746+00:00 | 0.787023 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T13:19:27.537708+00:00 | 2026-11-07T13:19:33.339458+00:00 | 5.801750 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 164 nonempty added/removed lines in one private owning-driver module,
within the sprint budget. The other 204 production modules and all 716 compile-fail fixtures retain
baseline bytes. Public exports are unchanged. Changed text retains UTF-8 and LF. No executor,
resolver producer or production testing branch is added. The phase remains Active with remaining
implementation and its composed live gate owed.

#### Remaining Work

None.

### Sprint 16.37: Exact Colima cleanup execution and phase completion [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Report.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/WrongColimaCleanupPhase.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Adopt the private conditional cleanup result and complete exactly the retained prepared transition.

#### Deliverables

- runColimaCleanup consumes only the opaque prepared cleanup call and freshly resolves its retained
  closed tool/namespace route; callers supply no executor, environment, handle, receipt or backend answer.
- Cleanup discovery requires existing Colima. The pure install-policy decision maps actual trusted
  missing-tool evidence to a Failure with ReprobeBeforeRetry; only acquisition may select installation.
  A live Docker route revalidates its existing retained toolchain without discovery or installation.
- The adapter requires the freshly resolved route to match the retained wall, builds the complete
  private request and revalidates the toolchain after the backend returns.
- Driver success, including exact Released replay, completes the retained prepared Running-to-Destroyed
  transition at the original managed generation. The public result pairs that sealed PhaseAdvance
  with any post-call standing diagnostic; a later failure does not withhold committed completion.
- Driver refusal completes nothing and retains its own typed error, regardless of post-call standing.
  The pure completion classifier makes these choices before the actual typed completion producer.
- Public deletion and phase authority stay opaque. The private driver remains inaccessible through
  the public library, and the wrong-phase fixture matches the diagnostic-bearing result shape while
  still rejecting Running where successful cleanup yields Destroyed.

#### Validation

ColimaSpec's four pure `exact cleanup completion` decision cases cover all driver-success/refusal
and post-call-success/refusal combinations. A committed release retains its completion and any later
standing diagnostic; a failed release retains its own error and completes nothing. The unsupported
discovery case preserves its typed refusal under either installation policy. The source case pins
actual cleanup policy, exact retained route, driver call, post-call revalidation, pure completion
and original-generation completePreparedPhaseTransition delegation. A live Docker route revalidates
its retained toolchain and has no installation/discovery path.

Two `native resolver install policy` cases consume actual opaque ready and missing results from the
native fixture walker. Both policies retain the actual ready route. Only acquisition chooses the
retained Brew installation branch; cleanup maps genuine trusted missing evidence to the exact
Failure with ReprobeBeforeRetry. The family declares actual native support and verifies the real
unavailable-row answer elsewhere. These cases classify real resolver evidence; they do not execute
an installed stand-in Colima or Brew command.

WrongColimaCleanupPhase.hs now expects the diagnostic-bearing result shape and still fails for its
registered Destroyed/Running mismatch. ImportColimaOwnership.hs, ForgeColimaAuthorities.hs and
CoerceColimaAuthorityRoles.hs retain their named refusals. All 16 targeted and all 977 focused cases
pass, including private exports, owning-driver privacy, authority, registration and live-definition
inventories. Both workspaces build with tests enabled on Linux and native Windows. Windows supplies
compilation evidence only; native runtime acceptance remains owed.

The public cleanup route remains opaque. Its opt-in Apple consumer now checks the retained
post-call diagnostic beside completion. No static case claims to execute runColimaCleanup; public
Apple cleanup confirmation remains in the HOSTBOOTSTRAP_COLIMA_LIVE=1 acceptance lane.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2,
Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies real-kernel temporaries. These checks claim no crash-durability or
public Apple execution evidence.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T13:35:06.826378+00:00 | 2026-11-07T13:44:52.279022+00:00 | 585.452640 | 5149 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T13:35:06.826426+00:00 | 2026-11-07T13:44:18.439162+00:00 | 551.612735 | 5149 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T13:35:06.826428+00:00 | 2026-11-07T13:35:07.608823+00:00 | 0.782399 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T13:35:06.828087+00:00 | 2026-11-07T13:35:12.554844+00:00 | 5.726758 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 69 nonempty added/removed lines across the main adapter and its private
report/classification module, within the sprint budget. The other 203 production modules and 715
compile-fail fixtures retain baseline bytes; only the cleanup wrong-phase fixture adopts the new
result shape. Public export names are unchanged; successful cleanup now returns its sealed advance
beside an optional standing diagnostic. Changed text retains UTF-8 and LF. No executor, resolver
producer or production testing branch is added. The phase remains Active with remaining
implementation and its composed live gate owed.

#### Remaining Work

None.

### Sprint 16.38: Bounded cluster command interpretation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Report.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterCommandSpec.hs`, `core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Run every described owned-cluster/backend command under one finite policy and the shared grouped runner.

#### Deliverables

- One total command policy gives Kind/nvkind creation 660 seconds, beyond the rendered ten-minute
  wait; Helm receives 600 seconds and an explicit five-minute Kubernetes wait receives 360 seconds.
  Other commands receive 60 seconds. Every row bounds output to 4 MiB per stream and termination
  grace to two seconds.
- The interpreter uses resolveLaunch and the described stdin, captures the actual working directory
  and environment, and delegates process ownership to runBoundedGroupedWithInput. It creates no
  parallel spawn or process-group implementation and accepts no injected command executor.
- One pure bounded-result classifier preserves completed captures, including failure exits, and
  refuses timeout, output overflow and failed execution with named diagnostics. Listing/status
  classification never turns those failures into absence.
- Ownership.interpret and every backend command, including read-only status, adopt that interpreter.
  Existing described arguments, typed ownership decisions and public authority boundaries remain intact.
- Pure policy/fault cases and source checks connect actual callers to the existing real-kernel
  runner cases. Native timeout, escalation, backpressure and child reaping count as runner evidence;
  no stand-in cluster driver is counted as execution evidence.

#### Validation

ClusterCommandSpec's eleven `bounded cluster command policy` cases apply the actual command
factories and total bounds/result decisions. Both creation drivers retain a 660-second wall beyond
their rendered --wait 10m. Listing, inspection, update, deletion and API queries retain a 60-second
wall; Helm receives 600 seconds and a five-minute Kubernetes wait receives 360 seconds. Every row
holds a 4 MiB per-stream output ceiling and two-second termination grace. Another tool's
creation-shaped vector gets no creation allowance.

Completed commands retain their exit and both full streams, including nonzero exit. The actual
listing classifier still rejects failure exits. Timeout becomes the named ClusterCommandUnrun
report and status probe failure; output overflow and execution failure produce no successful report.
The source case pins resolveLaunch, described stdin, actual namespace capture, pure bounds and
the sole runBoundedGroupedWithInput delegation, plus Ownership.interpret and every backend command.
The backend reachability guard requires the actual bounded producer. No domain boundary assembles
or signals its own child process.

EffectSpec's actual kernel cases `the wall terminates the child and reaps its pid`, `closing the
streams does not grant a second wall budget`, `escalation kills a SIGTERM-ignoring leader and
grandchild`, cancellation, unread-input and duplex backpressure run through the shared grouped
runner. Their declared native capability/refusal paths remain counted. Source connections bind the
cluster policy to that actual runner; no stand-in Kind command or injected timeout executor is
claimed as cluster execution evidence. Existing scripted-cluster regressions remain coherent but
are not live provider proof.

All 16 targeted and all 1091 focused checks pass, including cluster backend/ownership/report,
described commands, effects, ownership, authority/export, documentation, portability and source
inventories. Both workspaces build with tests enabled on Linux and native Windows. Windows supplies
compilation evidence only; native runtime acceptance remains owed.

All four host-static commands pass on one frozen 1189-file source snapshot, verified in both trees
before and after each command. The host is hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2,
Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.
Bounded 3 GiB tmpfs supplies real-kernel temporaries. These are static/kernel checks, not crash
durability or the independent live cluster gate.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-07T14:01:51.370422+00:00 | 2026-11-07T14:12:54.516832+00:00 | 663.146408 | 5160 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T14:01:51.370754+00:00 | 2026-11-07T14:12:09.583321+00:00 | 618.212566 | 5160 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T14:01:51.370197+00:00 | 2026-11-07T14:01:52.229838+00:00 | 0.859641 | Ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T14:01:51.370582+00:00 | 2026-11-07T14:01:57.222336+00:00 | 5.851756 | 376 Python cases; 100% coverage; exit 0 |

The production delta is 67 nonempty added/removed lines across exactly three cluster modules,
within the sprint budget. The other 202 production modules and all 716 compile-fail fixtures retain
baseline bytes. Export pins include the two bounded ownership helpers and the pure report classifier;
public authority constructors remain sealed. Changed text retains UTF-8 and LF. No injected executor,
backend producer or production testing branch is added. The plan places bounded interpretation
before its independent owned cluster-gate consumer and keeps genuine read-only status verification
separate. The phase remains Active with remaining implementation and its composed live gate owed.

#### Remaining Work

None.

### Sprint 16.38a: Independent Linux cluster gate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/app/Main.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`, `core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Expose the independent bounded cluster acceptance case through the binary's fixed test command.

#### Deliverables

- `hostbootstrap test run cluster-live` owns one isolated Harness plan and resolves Docker, Kind, kubectl and Helm before resource creation.
- The plan prepares creation, readiness, cordoning, and exact reverse cleanup through the shared cluster
  backend (`HostBootstrap.Cluster.Backend` over `HostBootstrap.Cluster.Ownership`), with bounded process
  and polling policies, private kubeconfig publication, and retained conditional reverse.
- The assertion observes the Kubernetes client/server versions and runtime-selected loopback publications.
  It supplies no host port number and proves both exact relay containers absent after release.
- The exact reverse proves labelled-node absence and re-reads the durable sentinel outside cluster state.
- `EffectSpec` requires the repository's non-ignored source tree to contain no shell, PowerShell, batch,
  or command script. The operator reaches the gate through the same five-verb command tree as other work.

#### Validation

On 2026-11-07 the native x86_64 `hostbootstrap-linux-d` WSL2 machine runs the bare core binary's
`test run cluster-live` from `.build/cluster-live-16-38a-verified`. Run `run-3eb9ea49a539` reports
`1/1 passed` and exits 0 in 168.443448 seconds (15:33:30.514684 to 15:36:18.947994 UTC).
The actual Direct provider resolves the writable canonical root and registry image, publishes its
running dependency, and is freshly re-probed before the owned cluster preparation. Kind creates
`hostbootstrap-test-run-3eb9ea49a539` from the pinned v1.36.1 image. The applied cordon precedes
fresh API/node readiness. The assertion reads kubectl v1.37.0 and server v1.36.1 through the private
kubeconfig, creates two real relay containers with runtime-selected loopback ports, proves their
ports differ and both containers are absent after release, then reverses the recorded cluster
identities and re-reads the exact durable sentinel. No test binary substitutes for any provider.

The host runs Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, Docker 29.9.3, Kind 0.32.0,
Helm 4.3.1, GHC 9.12.4 and Cabal 3.16.1.0. Its native tool downloads match official SHA-256 values.
The node image is `kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5`.
The canonical config carries a finite five-minute kubeadm API bootstrap timeout within Kind's
ten-minute readiness wait and the 660-second process bound. The shared runner delivers stdin EOF;
the host-tools phase's real EOF-reader cases and declared gate establish that prerequisite before this run.

Thirty targeted CLI, source and document cases pass, including actual public CLI initialization with
default/explicit resources, refusal of zero CPU/malformed memory, the owned backend route and the exact
dry-run output. The production change is 188 non-empty diff lines in the one Bare module. Both
workspaces build on Linux and Windows; Windows results are compilation only. The full static commands
below pass on all final production bytes, including the shared runner fix. Only the two host-tools
closure metadata files change between that frozen static source and the live source, and all 22
document-validator cases pass on those closure bytes before this live run.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T15:21:54.127284+00:00 | 2026-11-07T15:32:24.526437+00:00 | 630.437394 | 5166 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T15:21:54.127323+00:00 | 2026-11-07T15:31:47.901251+00:00 | 593.809963 | 5166 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T15:21:54.127222+00:00 | 2026-11-07T15:21:54.925839+00:00 | 0.798680 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T15:21:54.127328+00:00 | 2026-11-07T15:21:59.875159+00:00 | 5.748305 | 376 Python cases; 100% coverage; exit 0 |

The static commands and live run each verify all 1189 files against their frozen manifest before and
after execution in both workspaces. Live artifact: `D:/CodexScratch/hostbootstrap-test-temp/hostbootstrap-16-38a-final-owned-live-jstv_ia3/result.json`.
The static artifacts are the four `hostbootstrap-3-7-request-eof-final-*` directories recorded by the
host-tools phase. Final Docker readback names no remaining containers. Earlier failed/interrupted
trial artifacts establish no acceptance; their retained Harness recovery debt belongs to the test-harness
phase's explicit cancellation and recovery work. Phase closure still requires every owing sprint and
the phase's own complete composed gate.

#### Remaining Work

None.

### Sprint 16.38b: One cluster lifecycle execution route [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/test/LifecycleSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/engineering/composition_patterns.md`, `documents/engineering/resource_budgeting.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Keep the owned backend as the only cluster creation and exact deletion execution route.

#### Deliverables

- The pure lifecycle plan, teardown partition and owned package constructors remain available.
- Unused execution drivers and their scripted cases are absent from the lifecycle module.
- Source and export guards require the owned consumer and reject dead execution entry points.

#### Validation

On 2026-11-07, native x86_64 `hostbootstrap-linux-d` (Ubuntu 24.04.5 on WSL2 Linux
6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4, Cabal 3.16.1.0) passes all 286 selected lifecycle,
cluster/backend, export-inventory and document checks. The lifecycle package defines no creation,
health/recreate, chart, cleanup or status execution route and imports no tool runner. A source case
requires the shared planning definitions and refuses every removed execution entry or orphan helper.
Pure plan resolution, topology, NVIDIA decisions, node-budget projection and teardown partition remain.
The public export inventory contains only the retained API. Twelve cases for removed compatibility
functions disappear with those functions; one source guard pins the actual final boundary. All 716
compile-failure fixtures retain their registered identities and reasons.

The change is 376 non-empty production diff lines, all in Lifecycle. Both workspaces build on Linux
and native Windows; Windows evidence establishes compilation only. The full commands below pass on
one frozen source; every leg verifies all 1189 files before and after execution in both workspaces.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T15:50:19.561971+00:00 | 2026-11-07T16:01:11.493149+00:00 | 651.956671 | 5155 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T15:50:19.557649+00:00 | 2026-11-07T16:00:29.847923+00:00 | 610.314401 | 5155 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T15:50:19.561305+00:00 | 2026-11-07T15:50:20.470408+00:00 | 0.909140 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T15:50:19.561952+00:00 | 2026-11-07T15:50:25.472683+00:00 | 5.910989 | 376 Python cases; 100% coverage; exit 0 |

The dated artifacts are `hostbootstrap-16-38b-legacy-drivers-cases-79rwdahk` and the four
`hostbootstrap-16-38b-legacy-drivers-final-*` directories under `D:/CodexScratch/hostbootstrap-test-temp/`.
The independent gate uses the owned route established in Sprint 16.38a. This sprint removes unused
execution code and claims static validation; the phase still owes its complete composed live gate
once every remaining sprint is complete.

#### Remaining Work

None.

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

### Sprint 16.40: The read-only cluster status is a decision [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/ClusterCommandSpec.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Observe cluster status through the shared bounded interpreter without changing owned state.

#### Deliverables

- Read-only status asks the driver's own listing through the shared bounded interpreter and applies
  the total classifyClusterStatus decision over the shared classifyClusterListing answer.
- A present or absent cluster is a valid observation. Unavailable, failed, noisy, malformed,
  duplicated or nonportable reports refuse; timeout never becomes absence.
- Actual status observations before and after owned reconcile/release leave container mutations and
  protected records unchanged. No new origin, record or ownership permission is produced by status.
- The independent owned cluster-live case supplies genuine Linux execution and protected-record
  comparisons. Pure classifications and source checks hold refusal and non-mutation boundaries
  without a stand-in driver or injected executor.

#### Validation

On 2026-11-07, the native x86_64 `hostbootstrap-linux-d` WSL2 machine runs the bare core binary's
`test run cluster-live` from `.build/cluster-live-16-40`. Run `run-40f8e59f90a7` reports `1/1 passed`
and exits 0 in 182.792324 seconds (16:14:39.244004 to 16:17:42.031798 UTC). The actual driver status
observations are absent before creation, present after readiness, present before reverse, and absent
after release. Around every call, the gate compares real protected-store identity/record bytes and
record-directory presence plus each actual labelled node container's immutable identity, name,
state, HostConfig and published ports. Every comparison is equal. No snapshots or private credential
bytes are printed. The run also verifies the actual applied cordon and readiness, two concurrent
runtime-selected loopback publications and their absence, conditional cluster release, labelled-node
absence and durable-sentinel survival.

The prepared status entry retains its exact backend-binding validation; the retained entry uses only
the retained name projection. Both delegate to one bounded listing and the total report classifier.
The source case refuses ownership/store mutation entry points and unbounded interpreters in that
path. Existing pure status cases retain all report failures as probe failures. All 142 selected
backend, source/export and document cases pass; no provider executable substitutes for the live tools.

The host runs Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, Docker 29.9.3, Kind 0.32.0,
kubectl 1.37.0, server 1.36.1, Helm 4.3.1, GHC 9.12.4 and Cabal 3.16.1.0. The production change is
75 non-empty diff lines across Backend (12) and Bare (63). Both workspaces build on Linux and native
Windows; Windows evidence establishes compilation only. The full commands below verify one frozen 1189-file manifest before and after execution in both
workspaces. The passing live source differs only in the source-guard test that follows the new shared
status helper; every production byte is identical. The final command suite includes that delegation guard.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T16:35:20.856496+00:00 | 2026-11-07T16:46:21.677358+00:00 | 660.833353 | 5156 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T16:35:20.856485+00:00 | 2026-11-07T16:45:51.495525+00:00 | 630.650957 | 5156 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T16:35:20.856604+00:00 | 2026-11-07T16:35:21.675964+00:00 | 0.819378 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T16:35:20.856641+00:00 | 2026-11-07T16:35:26.829630+00:00 | 5.973103 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-40-read-only-status-delegation-cases-pt502aka`,
`hostbootstrap-16-40-read-only-status-live-ztx1_wns` and the four
`hostbootstrap-16-40-read-only-status-verified-final-*` directories under `D:/CodexScratch/hostbootstrap-test-temp/`.
The phase still owes its complete composed gate after every remaining sprint is complete.

#### Remaining Work

None.

### Sprint 16.41: The described cluster commands [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Command.hs`,
`core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Report.hs`,
`core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterCommandSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`,
`core/hostbootstrap-core/test/ClusterReportSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Every cluster effect as a value in the one closed effect vocabulary.

#### Objective boundary

This sprint renders argument vectors and connects process-outcome classification for diagnostic-bearing
mutations and kubeconfig reads. The remaining strict report grammar is Sprint 16.42's; where
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

On 2026-11-07, the 259 selected command, report, backend, ownership, portability, export/source and documentation
cases pass on the native x86_64 `hostbootstrap-linux-d` WSL2 machine. The pure cases pin diagnostic-bearing
Kind vectors without quiet mode, both dotted-name examples, mutation success with progress on both streams,
missing-child and nonzero-exit refusals, and successful kubeconfig readback with diagnostic chatter while
retaining strict body validation. Existing protocol-fixture cases remain compatible with the exact vectors
and quiet-mode suppression; they establish no actual provider execution evidence.

An independent real-runtime check obtains its Docker and Kind argument vectors by applying the production
renderers through a Haskell consumer. It creates two stopped Docker containers named
`hostbootstrap-16-41-24485e63f93e.v1-control-plane` and
`hostbootstrap-16-41-24485e63f93e-v1-control-plane`, verifies their labels and immutable identities, and asks
Docker both queries. The production escaped filter returns only the dotted-name container; the unescaped
filter returns both. Cleanup removes both exact identities, including their own anonymous volumes, then
verifies the labelled set is absent. The production kubeconfig-read vector against the nonexistent Kind
cluster exits 1 and preserves Kind's own first error line. This gate exits 0 in 4.743111 seconds, from
16:54:57.743407 to 16:55:02.486451 UTC. It does not claim a protected-ownership reconciliation run.

The host runs Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, Docker 29.9.3, Kind 0.32.0,
GHC 9.12.4 and Cabal 3.16.1.0. The change is 69 non-empty production diff lines across Command (24),
Report (36) and Ownership (9). Both workspaces build on Linux and native Windows; the Windows evidence
establishes compilation only. All four commands below verify the same frozen 1189-file manifest before
and after their runs in both source trees. The live source differs only in the fixture decoder spelling;
every production byte matches the final full-suite source.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T17:08:45.462547+00:00 | 2026-11-07T17:19:26.528715+00:00 | 641.073733 | 5160 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T17:08:45.462436+00:00 | 2026-11-07T17:18:52.524632+00:00 | 607.069359 | 5160 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T17:08:45.462545+00:00 | 2026-11-07T17:08:46.294994+00:00 | 0.832461 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T17:08:45.462431+00:00 | 2026-11-07T17:08:51.390835+00:00 | 5.928471 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-41-cluster-vectors-regex-token-cases-d04_ojv5`,
`hostbootstrap-16-41-cluster-vectors-real-runtime-verified-2sdj0d13`, and the four
`hostbootstrap-16-41-cluster-vectors-verified-final-*` directories under `D:/CodexScratch/hostbootstrap-test-temp/`.
The phase still owes its complete composed gate after every remaining sprint is complete.

#### Remaining Work

None.

### Sprint 16.42: Strict cluster report framing and node sets [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Report.hs`,
`core/hostbootstrap-core/test/ClusterReportSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Every report body is admitted by its exact grammar, and a node set has no significant ordering.
Readiness classification and its diagnostic pipeline are the separate contracts of Sprints 16.42a
and 16.42b; the split holds each change within three production modules.

#### Deliverables

- Listing and identity classifiers share exact line framing: ASCII only, one final newline, no carriage
  return or empty row, and a finite line bound. Empty output remains an empty listing.
- Node-list documents are ASCII and within the shared document ceiling before low-byte packing and JSON
  decoding. A malformed document is a refusal, while a well-formed different node set is unexpected.
- Node names are unique and within the declared alphabet. Their sorted set is compared with the declared
  set, so node-report order never decides readiness.
- Framing cases apply the shared classifier directly and assert its exact refusal rather than relying
  on another grammar to reject the same bytes.

#### Validation

On 2026-11-07, the 263 selected report, command, backend, ownership, portability, source/export and
documentation cases pass on the native x86_64 `hostbootstrap-linux-d` WSL2 machine. The shared line
classifier itself returns the exact carriage-return, non-ASCII and empty-row refusals. Node-list value
cases reject non-ASCII label bytes and a wide character that low-byte packing could turn into a quote,
and reject a document beyond the shared 1 MiB ceiling before decoding. A Ready list in lexicographic
worker-name order matches a declaration in numeric worker order. Duplicate names and a different node
set retain their distinct refusals/outcomes. These are direct applications of the actual total functions;
no provider substitute establishes the report contract.

The production change is eight non-empty diff lines in Report. Both workspaces build on Linux and native
Windows; Windows evidence establishes compilation only. The host runs Ubuntu 24.04.5,
Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0. All four commands below verify
one frozen 1189-file manifest before and after execution in both source trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T17:22:45.551800+00:00 | 2026-11-07T17:33:32.447725+00:00 | 646.902200 | 5164 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T17:22:45.551715+00:00 | 2026-11-07T17:32:59.894240+00:00 | 614.348482 | 5164 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T17:22:45.551799+00:00 | 2026-11-07T17:22:46.355614+00:00 | 0.803824 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T17:22:45.551745+00:00 | 2026-11-07T17:22:51.520235+00:00 | 5.968549 | 376 Python cases; 100% coverage; exit 0 |

Artifacts are the selected-case result and the four `hostbootstrap-16-42-report-grammar-final-*`
directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The phase still owes its complete composed
gate after every remaining sprint is complete.

#### Remaining Work

None.

### Sprint 16.42a: API readiness process outcomes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Report.hs`,
`core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterReportSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

An API server answering not-ready differs from a kubectl process that never launched. The direct
ownership result retains the API diagnostic; the strong result's forwarding contract is Sprint 16.42b's.

#### Deliverables

- `classifyApiReadiness` returns a typed refusal for an unlaunched command and readiness only from a
  successful quiet process outcome. A failed exit or noisy success is not-ready carrying the bounded first
  diagnostic line.
- The ownership observer maps a command refusal to its report fault and carries the diagnostic in its
  API-unready outcome. The strong backend retains the distinction between a failed probe and not-ready.
- The module Haddocks and direct value cases describe and hold these outcomes exactly.

#### Validation

On 2026-11-07, the 265 selected report, command, backend, ownership, portability, source/export and
documentation cases pass on the native x86_64 `hostbootstrap-linux-d` WSL2 machine. Direct classifier
applications establish the quiet successful Ready value, an unlaunched kubectl's exact
`ClusterCommandUnrun` refusal, the Unauthorized first line from a nonzero exit, the warning first line
from a noisy success, an explicit absent-diagnostic message, and truncation to one 512-character line.
The ownership probe exhaustively maps the typed refusal to its report fault, retains the diagnostic in
its API-unready result, and the strong backend maps the report fault to probe failure. Existing protocol
fixtures remain compatible; they establish no actual provider execution evidence. Forwarding the
API-unready diagnostic through the strong readiness view remains Sprint 16.42b's contract.

The production change is 35 non-empty diff lines across Report (26), Ownership (7) and Backend (2).
Both workspaces build on Linux and native Windows; Windows evidence establishes compilation only.
The host runs Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0.
All four commands below verify one frozen 1189-file manifest before and after execution in both source
trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T17:37:21.969073+00:00 | 2026-11-07T17:48:12.835808+00:00 | 650.872131 | 5166 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T17:37:21.969074+00:00 | 2026-11-07T17:47:38.118193+00:00 | 616.154232 | 5166 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T17:37:21.968176+00:00 | 2026-11-07T17:37:22.747649+00:00 | 0.779476 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T17:37:21.969036+00:00 | 2026-11-07T17:37:28.134030+00:00 | 6.165054 | 376 Python cases; 100% coverage; exit 0 |

Artifacts are the selected-case result and the four `hostbootstrap-16-42a-api-readiness-final-*`
directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The phase still owes its complete composed
gate after every remaining sprint is complete.

#### Remaining Work

None.

### Sprint 16.42b: Readiness diagnostics reach the bounded poll [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Observation/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

A bounded readiness poll that exhausts its allowance names the API server's actual refusal while its
settlement still compares the exact managed container identity.

#### Deliverables

- The private observation distinguishes API-unready with its identity and diagnostic from node-set
  unready and same-named replacement observations. A diagnostic mints no readiness evidence.
- The strong backend forwards the direct ownership diagnostic. Settlement preserves the exact identity
  conflict and returns a retryable not-ready refusal containing the diagnostic.
- The non-authorizing readiness view carries a descriptive not-ready message to the existing bare and
  demo polling consumers. A runtime dependency refusal retains that message too.

#### Validation

On 2026-11-07, the 268 selected report, command, backend, ownership, portability, refusal, source/export
and documentation cases pass on the native x86_64 `hostbootstrap-linux-d` WSL2 machine. Direct applications
of `clusterApiNotReadyRefusal` retain the exact Unauthorized diagnostic and managed identity with a
fresh-probe retry disposition; a different identity returns the exact replacement conflict and resource
key. The function returns only `ReconcileError`, never a readiness witness.

The source case pins the actual backend's diagnostic-bearing private observation, the descriptive view's
message projection, settlement's pure refusal and managed-key/identity inputs, and dependency refusal
forwarding. The bare and demo polls consume that existing descriptive view. The private observation
remains behind the hidden-module compile-fail boundary; the full suite checks all 716 registered fixtures
and 205 production modules. Existing protocol fixtures remain compatible and establish no actual provider
execution evidence. This sprint's evidence is for the total refusal decisions, source chain, type boundary
and host static gate; the phase still owes its final real cluster gate.

The production change is 46 non-empty diff lines across Observation/Internal (1), Reconcile (41) and
Backend (4). Both workspaces build on Linux and native Windows; Windows evidence establishes compilation
only. The host runs Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0.
All four commands below verify one frozen 1189-file manifest before and after execution in both source
trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T17:53:18.107160+00:00 | 2026-11-07T18:03:50.450040+00:00 | 632.347462 | 5169 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T17:53:18.107327+00:00 | 2026-11-07T18:03:14.796897+00:00 | 596.693907 | 5169 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T17:53:18.107385+00:00 | 2026-11-07T17:53:18.925055+00:00 | 0.817678 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T17:53:18.107384+00:00 | 2026-11-07T17:53:23.968006+00:00 | 5.860669 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-42b-readiness-diagnostic-cases-guvkyqwc` and the four
`hostbootstrap-16-42b-readiness-diagnostic-final-*` directories under `D:/CodexScratch/hostbootstrap-test-temp/`.
The phase still owes its complete composed gate after every remaining sprint is complete.

#### Remaining Work

None.

### Sprint 16.43: The cluster resumption decisions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Resume.hs`,
`core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterResumeSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/engineering/cluster_lifecycle.md`

#### Objective

Where a cluster transaction stands, as a total function of the expected generation claim and three observations.

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

On 2026-11-07, all 300 selected resumption, report, command, backend, ownership, portability, refusal,
source/export and documentation cases pass on the native x86_64 `hostbootstrap-linux-d` WSL2 machine.
Direct applications of the total decisions reject another generation's bound and unbound records for
both a cluster and a node, even at the same container identity. The direct origin-record preflight accepts
this generation and refuses the other without inventing a runtime observation. Every conflict, including
the generation refusal, renders nonempty. Existing prior-object, wrong-kind, absence and replacement
cases retain their classifications.

The source guard checks actual normal/binding/re-entry claim arguments, stored-claim retained cleanup,
and the all-record retirement preflight. The retirement path validates every existing record's kind,
claim and absent origin before forgetting the first; retained cleanup carries the stored digest itself,
including through node checks and release, and never re-hashes it as a new owner string. No-record
cleanup still observes the real namespace before reporting already released. Existing protocol fixtures
remain compatible and establish no actual provider execution evidence. The separate actual-cluster
negative assertions are Sprint 16.43a's scope. The resumption Haddock states the residual adoption window
for an unbound record that outlives its interrupted create.

The production change is 170 non-empty diff lines across Resume (58) and Ownership (112).
Both workspaces build on Linux and native Windows; Windows evidence establishes compilation only.
The host runs Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0.
All four commands below verify one frozen 1189-file manifest before and after execution in both source
trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T18:18:48.022954+00:00 | 2026-11-07T18:29:41.070631+00:00 | 653.051792 | 5175 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T18:18:48.022873+00:00 | 2026-11-07T18:29:04.237290+00:00 | 616.218301 | 5175 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T18:18:48.022960+00:00 | 2026-11-07T18:18:48.792000+00:00 | 0.769046 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T18:18:48.022576+00:00 | 2026-11-07T18:18:53.710349+00:00 | 5.687805 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-43-claim-generation-cases-vb64kqt8` and the four
`hostbootstrap-16-43-claim-generation-final-*` directories under `D:/CodexScratch/hostbootstrap-test-temp/`.
The phase still owes its complete composed gate after every remaining sprint is complete.

#### Remaining Work

None.

### Sprint 16.43a: Actual cluster generation refusal [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

The independent owned live gate confirms a generation refusal against its actual cluster, separately from
the pure standing decisions. The split keeps the real-runtime assertion within the sprint size limit.

#### Deliverables

- After the actual cluster is Ready, the gate asks the ownership transaction to reconcile the same exact
  name and node with a deliberately different generation owner, and requires the named claim conflict.
- The assertion compares real protected-record bytes and actual immutable node-container state before and
  after the refusal. Neither a provider stand-in nor an injected executor participates.
- An independent real-absence/protected-store assertion publishes a matching unbound root and a worker
  from another generation, then requires record retirement to refuse before changing either record.
- The ordinary retained reverse still releases the original cluster and preserves the durable sentinel.

#### Validation

On 2026-11-07, the native x86_64 `hostbootstrap-linux-d` WSL2 machine runs the bare binary's
`test run cluster-live` from `.build/cluster-live-16-43a`. The actual already-Ready cluster is reconciled
under a deliberately different generation owner, using its retained name, nodes, state directory and
private credential path. The result is the named generation conflict. Exact protected-store identity and
record bytes plus actual immutable container identity, name, state, HostConfig and ports are unchanged
around the attempt. No snapshot or credential bytes are printed.

The second assertion uses an independent name, observes the actual Kind cluster and Docker node/worker
absent, and publishes a matching unbound root record plus another generation's worker record through the canonical record tape over real
protected CAS in a private temporary store. Actual record retirement returns the named generation conflict;
both records remain present with exactly the same bytes and versions. No provider resource is created for
that assertion. The normal original cluster still undergoes actual cordoning, readiness, concurrent
runtime-selected loopback publications and their absence, retained reverse, labelled-node absence and
durable-sentinel survival. Four read-only status observations also preserve the record/container snapshots.
The suite metadata already initialized beside the binary is reused unchanged; the run starts in a fresh
working directory. No provider executable or injected executor substitutes for any of these subjects.

Run `run-4a789e67b983` reports `1/1 passed` and exits 0 in 157.536167 seconds, from
2026-11-07T19:08:44.199544+00:00 to 2026-11-07T19:11:21.734924+00:00 UTC.

All 302 selected source, resumption, report, command, backend, ownership, portability, refusal and
documentation cases pass. The source case pins the actual suite's two assertion calls, protected entries,
transaction calls and both real snapshots. The production change is 131 non-empty diff lines in Bare.
Both workspaces build on Linux and native Windows; Windows evidence establishes compilation only.
The host runs Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, Docker 29.9.3, Kind 0.32.0,
kubectl 1.37.0, server 1.36.1, Helm 4.3.1, GHC 9.12.4 and Cabal 3.16.1.0. All four commands below
and the actual live run verify one frozen 1189-file manifest before and after execution in both source
trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T18:56:41.018549+00:00 | 2026-11-07T19:07:35.063322+00:00 | 654.048176 | 5176 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T18:56:41.018020+00:00 | 2026-11-07T19:07:00.150149+00:00 | 619.135357 | 5176 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T18:56:41.018077+00:00 | 2026-11-07T18:56:41.802110+00:00 | 0.784037 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T18:56:41.018074+00:00 | 2026-11-07T18:56:46.839762+00:00 | 5.821720 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-43a-claim-live-tape-cases-adp76jlm`, `hostbootstrap-16-43a-claim-live-actual-uscngw2k` and the
four `hostbootstrap-16-43a-claim-live-verified-final-*` directories under `D:/CodexScratch/hostbootstrap-test-temp/`.
The phase still owes its complete composed gate after every remaining sprint is complete.

#### Remaining Work

None.

### Sprint 16.44: Worker binding and interrupted reconciliation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Every declared worker binds before the control plane, and an interrupted worker binding resumes under
the exact stored generation claim.

#### Deliverables

- `bindNodeRecords` binds workers first and the control plane last as the cluster commit point.
- `bindOneNodeForClaim` applies the total `nodeStanding` decision to the actual record and runtime
  observation. A matching published, unbound origin binds its observed identity; an already-bound identity
  remains unchanged; missing records, foreign claims and replacements remain refusals.
- `requireOwnedWorkers` reports `ClusterRecovered` when it binds an interrupted worker and
  `ClusterAlreadyOwned` when every worker was already bound. `ownedClusterNodesForClaim` uses the same
  claim-preserving worker recovery for retained transactions while requiring the root already bound.
- The source guard holds the worker-first order and the exact claim through both recovery routes.
  Existing total standing and report decisions retain their refusal cases. Actual two-node creation,
  reconciliation, repeat entry and release run against Docker, Kind and the protected store.

#### Validation

On 2026-11-07, the actual x86_64 `hostbootstrap-linux-d` WSL2 machine runs two independent two-node Kind
clusters. For each, the client observes the actual cluster and both nodes absent and publishes both
unbound origin records through the canonical tape in a real protected store before actual Kind creation.
It binds the control-plane record to the actual observed container identity and leaves the worker
unbound. These are ordinary production record operations over actual objects; no executable substitutes
for a provider, no executor is injected and no production crash point is added.

The reconciliation run reports `ClusterRecovered`, binds the actual worker, preserves the root's exact
record bytes and version, and preserves both actual container identities. Its repeat reports
`ClusterAlreadyOwned`. The independent release run starts from the bound-root/unbound-worker standing
and completes release through the same claim-preserving recovery. Both runs report `ClusterReleased`,
observe both actual nodes absent and list no remaining protected records. Each creates its own cluster
once. No credential bytes are printed.

The `reconcile` run exits 0 in 232.126199 seconds, from
2026-11-07T19:21:38.297551+00:00 to 2026-11-07T19:25:30.422635+00:00 UTC.

The `release` run exits 0 in 244.536256 seconds, from
2026-11-07T19:26:05.985209+00:00 to 2026-11-07T19:30:10.520291+00:00 UTC.

The external Haskell client compiles with `-Wall -Werror` against the in-tree core and its internal
record library. Its source SHA-256 is
`618957a78b29fb9be54ed086e056e4ec9142d1f4b251d3fefc665aa490f89e0a`;
the native binary is `7ba0fa485b6b21caa1ad66293a6ed60751f87b0f06712252d68dbffdd63b893e`.
The client and Kind configuration are retained outside the repository under
`/home/hostbootstrap/.cache/hostbootstrap-16-44-live/`; the Windows source copy is under
`D:/CodexScratch/hostbootstrap-test-temp/`. Actual machine and boot identities match the live cluster
gate host. Docker is 29.9.3, Kind 0.32.0 and the cached node image is Kubernetes 1.36.1.

All 303 selected cases pass, including the pure standing/refusal cases, claim-preserving wiring,
portability and documentation checks. A separately observed 40-case ownership fixture family also
passes; its authored tool answers establish fixture compatibility only. The production change is 49
non-empty diff lines in one module. Both workspaces build on Linux and native Windows; Windows evidence
establishes compilation only. All commands below and both actual live runs verify one frozen 1189-file
manifest before and after execution in both source trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T19:36:57.044638+00:00 | 2026-11-07T19:46:47.895023+00:00 | 590.853163 | 5177 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T19:36:57.044638+00:00 | 2026-11-07T19:46:45.519320+00:00 | 588.477452 | 5177 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T19:22:01.509267+00:00 | 2026-11-07T19:22:02.515049+00:00 | 1.005783 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T19:22:01.681186+00:00 | 2026-11-07T19:22:09.880621+00:00 | 8.199469 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: the `hostbootstrap-16-44-worker-binding-*` result directories under
`D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate remains owed.

#### Remaining Work

None.

### Sprint 16.44a: The private cluster transaction boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportClusterOwnership.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Only the internal backend, bare live gate and internal test component can construct the owned cluster
or invoke its clause-holding transactions. The existing public command, report, standing, cordon and
interpreter modules retain their public module identities through reexports.

#### Deliverables

- The Cabal-private `cluster-ownership-internal` library compiles the ownership transaction and its
  strict dependency closure once. Main and the core test component depend on that unit. Main does not
  expose or reexport `HostBootstrap.Cluster.Ownership`.
- Main reexports `HostBootstrap.Cluster.Command`, `HostBootstrap.Cluster.Report`,
  `HostBootstrap.Cluster.Resume`, `HostBootstrap.Cluster.Cordon`,
  `HostBootstrap.Cluster.Cordon.Foundation` and `HostBootstrap.Effect.Interpreter`.
- `ImportClusterOwnership.hs` imports the transaction module and attempts `releaseOwnedCluster` from
  the public consumer unit. Its registered expectation pins the complete hidden-package diagnostic.
- The private ownership export pin is checked against the actual module; the source guard also checks
  private visibility and the retained public reexports. The public inventory omits the private module.
- Seven modules have one physical source each under `internal/cluster-ownership/`; no production body
  changes and no copied test implementation accompany the moves. Existing source guards and governed
  implementation citations name those current homes. This phase's evidence coverage includes the unit.

#### Validation

On 2026-11-07, all 272 selected cases pass on the native x86_64 `hostbootstrap-linux-d` WSL2 gate host.
The downstream compile-fail fixture refuses for its named hidden-package reason. Both fixture inventory
checks pass, as do the public sealed-export inventory, private export pin, six public reexports, shared
computation-home guards, every declared owner reaching the canonical record tape, retained cluster
node-claim re-entry, described bounded cluster commands, Cordon, Effect, portability and documentation
checks. No test-only production interface is introduced.

Both workspaces build warning-clean on Linux and native Windows. The final test guard is rebuilt in all
four workspaces; Windows evidence establishes compilation only. Each of the seven relocated files has
exactly the SHA-256 of its previous physical source in the preceding frozen manifest. Production body
diff is zero, with relocations accounted separately. The host uses Ubuntu 24.04.5,
Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0.

All four commands below verify the same frozen 1190-file manifest before and after execution in both
source trees. The core suites use the established `/hbt` temporary root.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T20:10:48.322719+00:00 | 2026-11-07T20:21:16.658601+00:00 | 628.338714 | 5179 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T20:10:48.322756+00:00 | 2026-11-07T20:20:44.425197+00:00 | 596.105133 | 5179 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T20:10:48.322794+00:00 | 2026-11-07T20:10:49.106705+00:00 | 0.783915 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T20:10:48.322792+00:00 | 2026-11-07T20:10:54.071654+00:00 | 5.748889 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-44a-cluster-private-scanner-cases-y5mqd2zp`, the four
`hostbootstrap-16-44a-cluster-private-scanner-*-build-*` directories and four
`hostbootstrap-16-44a-cluster-private-verified-final-*` result directories under
`D:/CodexScratch/hostbootstrap-test-temp/`. The phase still owes its complete composed static/live gate.

#### Remaining Work

None.

### Sprint 16.44b: Honest cluster fixture scope and exact decision assertions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/FakeCluster.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Cluster fixture coverage states what it establishes, each modeled tool has its own executable role,
and ownership assertions name exact values and credential bytes.

#### Deliverables

- `prepareFixtureExecutables` gives each temporary fixture distinct `kind`, `nvkind`, `docker`,
  `kubectl` and `helm` executable copies, with the host executable suffix and permissions preserved.
  All three fixture configuration tables and recorded-exposure callers select those named paths.
- `runFakeClusterClient` checks the executable's actual base name against its modeled vector family
  before dispatch. A Docker vector sent to the kubectl-named executable returns the named fixture
  wrong-tool refusal without changing the fixture mutation sequence; unknown vectors still refuse.
- The fixture header and all cluster/provider-model comments state that these answers are authored
  compatibility models. Their processes supply no provider execution evidence under section NN.
  Pure classifications, actual kernel operations and the actual cluster-live gate establish their
  respective subjects.
- The one renderer case checks one value of all seven `ClusterOwnershipFault` constructors, with
  exact delegation for store, report, standing and clause faults and exact credential/config/budget
  prefixes and payloads.
- The present-node assertion compares the exact planted identity. All three published-credential
  assertions read raw `ByteString` bytes and compare with the exact authored fixture bytes. An unclaimed
  cluster asserts `ClusterUnderNoRecord`, no records, no credential readback and no model mutation.

#### Validation

On 2026-11-07, all 237 selected checks pass on the native x86_64 `hostbootstrap-linux-d` WSL2 host.
The selection includes the complete ownership, backend, reconcile, workload and exposure-relay
families, the exact renderer/identity/credential/foreign-standing assertions, source-home guards,
fixture registration/import probes, portability and documentation checks. The new wrong-tool case
also passes independently as `1/1`: its Docker vector reaches the kubectl-named fixture executable,
the exact wrong-tool reason returns, and the fixture mutation sequence remains unchanged.

The renderer checks are direct applications of the actual pure renderer. The named-executable cases
validate the fixture itself and compatibility with its authored answers; they make no new claim about
real Docker, Kind, kubectl or Helm. The phase's actual provider confirmation remains its composed
cluster-live gate. No production Haskell body, production execution interface or dependency changes.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The same frozen 1190-file manifest is verified before and after every command in both source
trees. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and
Cabal 3.16.1.0; static-suite temporary roots use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T20:34:15.956520+00:00 | 2026-11-07T20:45:40.434438+00:00 | 684.480926 | 5180 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T20:34:15.956602+00:00 | 2026-11-07T20:45:07.209683+00:00 | 651.255947 | 5180 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T20:34:15.956599+00:00 | 2026-11-07T20:34:16.728190+00:00 | 0.771596 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T20:34:15.956553+00:00 | 2026-11-07T20:34:21.671414+00:00 | 5.714889 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-44b-cluster-fixture-cases-s0_5q3bz`, `hostbootstrap-16-44b-cluster-fixture-wrong-tool-28t3_6x0` and
the `hostbootstrap-16-44b-cluster-fixture-*-build-*` and `hostbootstrap-16-44b-cluster-fixture-final-*` result
directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.44c: Durable cluster credentials on every owned entry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected/Publication.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportProtectedPublication.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Credential publication establishes data and namespace durability before reconcile binds any node,
and an already-owned entry refreshes its exact Kind credential before continuing.

#### Deliverables

- The private `HostBootstrap.Protected.Publication` module owns the existing platform file-sync,
  atomic rename and parent-sync implementations. Protected records and cluster credentials share these
  exact bodies. Windows retains write-through replacement and long-path normalization; POSIX retains
  same-directory rename and parent sync; Darwin retains its stronger device-cache flush.
- `atomicPublishKubeconfig` completes and closes a private sibling, syncs it, atomically replaces the
  destination and syncs the namespace through the shared primitives. The temporary cleanup covers every
  failed requested operation. The caller binds no new identity after publication refuses.
- An already-owned reconcile obtains and republishes the actual current Kind credential before worker
  re-entry. Missing or differing credentials are restored, and even an identical visible file undergoes
  the full durability protocol rather than being treated as proof that a previous flush succeeded.
- Source guards hold the complete protected-store publisher and shared platform bodies, plus the
  credential operation order and already-owned refresh. `ImportProtectedPublication.hs` pins the named
  hidden-package refusal for a public consumer of these private primitives.
- The introducing protected-store sprint states the one shared publication home. The credential
  fixture case checks exact bytes and no additional model create; its authored tool answers remain
  fixture compatibility evidence. Actual behavior is confirmed against Kind and the real filesystem.

#### Validation

On 2026-11-07, the actual native x86_64 `hostbootstrap-linux-d` WSL2 host creates the single-node Kind
cluster `hostbootstrap-16-44c-credential` through `reconcileOwnedCluster`, with the pinned 1.36.1 node
image and actual local Docker socket. Its record store and credential destination are on native ext4
under `/home/hostbootstrap/.cache/hostbootstrap-16-44c-live/run`; staging uses `/hbt`.

The initial published credential equals actual Kind readback bytes and grants no group or other file
access. Removing the file and then separately replacing its contents both recover as
`ClusterAlreadyOwned`, restoring exact private bytes while preserving the actual control-plane identity
and the bound record's exact bytes and version. Replacing the destination with an actual directory makes
the real rename refuse with `ClusterOwnershipKubeconfig`; identity and record/version remain unchanged,
and no sibling publication temporary remains. Removing that test-owned empty directory permits the next
entry to publish successfully. Final release observes the actual Kind cluster and Docker node absent and
lists no remaining protected records. No credential bytes are printed, no provider is substituted and no
production execution override or crash point is introduced.

The actual run exits 0 in 175.074668 seconds, from
2026-11-07T21:03:12.578505+00:00 to 2026-11-07T21:06:07.652406+00:00 UTC.

The external Haskell client compiles with `-Wall -Werror` against the actual in-tree units.
Its source SHA-256 is `e823670ecc306c683b397d7a6b3660e8d7fd9249400777f08d3d91051924b9be`;
the native binary is `122c0fbaae1feb4fab1461fcec7a55b3c51fe3eaf3748ba117a7d2b07dd728cd`.
Preparation verifies those inputs, the fresh run root, UID 1000, machine identity and the retained boot.
The client and configuration remain outside the repository under the native live directory and
`D:/CodexScratch/hostbootstrap-test-temp/`.

All 163 selected checks pass, including actual protected-store operations, the complete shared platform
source guard, credential ordering, private import refusal, exact credential fixture, public export
inventory, shared computation homes, fixture probes, portability and documentation. The source guards
hold the requested platform operations; the live case confirms actual byte readback, failure handling,
permissions and cleanup. The production delta is 229 non-empty lines across exactly three modules,
including the extraction; the shared platform bodies are byte-identical to their previous home.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation only.
All commands below and the actual live run verify the same frozen 1192-file manifest before and after
execution in both source trees. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2,
GHC 9.12.4 and Cabal 3.16.1.0; static-suite temporary roots use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T21:02:42.071915+00:00 | 2026-11-07T21:14:12.688754+00:00 | 690.619873 | 5183 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T21:02:42.071995+00:00 | 2026-11-07T21:13:36.823566+00:00 | 654.754452 | 5183 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T21:02:42.073222+00:00 | 2026-11-07T21:02:42.915499+00:00 | 0.842281 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T21:02:42.071916+00:00 | 2026-11-07T21:02:48.012122+00:00 | 5.940232 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-44c-credential-publication-cases-x_12i6dn`, `hostbootstrap-16-44c-credential-publication-live-actual-3_b15nbw`,
`hostbootstrap-16-44c-credential-publication-live-prepared-qhetvnw5` and the
`hostbootstrap-16-44c-credential-publication-*-build-*` / `hostbootstrap-16-44c-credential-publication-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.
The complete composed phase gate remains owed after the remaining sprints.

#### Remaining Work

None.

### Sprint 16.44d: Refused creation retires only observed-absent origins [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Resume.hs`,
`core/hostbootstrap-core/test/ClusterResumeSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

A refused creating command leaves no future adoption claim when its namespace is authoritatively absent.

#### Deliverables

- `refusedCreateOriginsMayRetire` is the total decision over actual listing and control-plane-origin
  values. Only the absent/absent pair permits retiring unbound origins.
- Every refused create/staging path re-observes both authorities in the same protected session and
  preserves origins when anything stands or either observation fails. Known absence reaches the shared
  generation-claim preflight and compare-and-delete operations before the original create fault returns.
  A failed retirement surfaces its durable-store fault.
- Four direct value cases cover every observation pair; a source guard holds actual re-observation and
  the same session/key/claim through retirement. Existing model compatibility verifies the exact create
  refusal, empty record set and later `ClusterUnderNoRecord` without claiming provider execution evidence.
- The actual live case refuses an invalid Kind config, confirms both unbound origins retired, then
  creates the same name under an independent protected owner. The first store must refuse that foreign
  cluster without changing its identity or the independent owner's records. That owner releases it.

#### Validation

On 2026-11-07, all 303 selected checks pass on the native x86_64 `hostbootstrap-linux-d` WSL2 host.
Four direct applications cover every authoritative listing/control-plane observation pair. The source
guard pins both create/staging refusal paths to actual re-observation and the same protected session,
key and generation claim through the shared retirement protocol. Exact fixture compatibility verifies
the original create fault, empty records and subsequent `ClusterUnderNoRecord`; all affected ownership,
resumption, backend, reconcile, workload and exposure-relay families pass, as do public export pins,
source-home guards, fixture probes, portability and documentation checks. Authored fixture answers
remain compatibility evidence only.

The actual live client observes the Kind cluster and both declared node names absent and publishes two
unbound origins through the canonical tape in a real protected store. Actual Kind refuses a correctly
hashed but invalid config. Reconciliation returns the create report fault and retires both origins;
the store is empty and the cluster and both nodes are actually absent.

A second protected store then creates the same actual cluster name under its independent generation
claim, using the pinned 1.36.1 single-node config. Reconciliation from the first store returns exactly
`ClusterUnderNoRecord`. Its store remains empty and publishes no credential. The independent owner's
actual node identity, exact bound record bytes/version and private credential bytes remain unchanged.
That owner's normal release transaction removes the actual cluster and node and forgets its own records;
both stores are empty at completion. No provider executable, executor or observation is substituted and
no credential bytes are printed.

The actual run exits 0 in 130.855636 seconds, from
2026-11-07T21:24:08.566980+00:00 to 2026-11-07T21:26:19.422044+00:00 UTC.

The external Haskell client compiles with `-Wall -Werror` against the in-tree units.
Its source SHA-256 is `1558df5be12f0a18f4037decd53b0f2cd9aa1c23752f36e234f0aea5dcaa29a9`;
the native binary is `90eb6c58d3f2b019ad9c84d9dc7ddd799471e101ac43aa4e97bbfaa21eada455`.
Preparation verifies the inputs, fresh run directory, UID 1000, machine and retained boot identities.
The client and config remain outside the repository under
`/home/hostbootstrap/.cache/hostbootstrap-16-44d-live/` and `D:/CodexScratch/hostbootstrap-test-temp/`.

The production change is 33 non-empty diff lines across two modules. Both workspaces build warning-clean
on Linux and native Windows; Windows establishes compilation only. All commands below and the actual
live run verify the same frozen 1192-file manifest before and after execution in both source trees.
The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0.
Static-suite temporaries use `/hbt`; the actual two stores and credentials use native ext4.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T21:23:42.245327+00:00 | 2026-11-07T21:34:58.132089+00:00 | 675.889737 | 5189 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T21:23:42.245695+00:00 | 2026-11-07T21:34:23.233273+00:00 | 640.990398 | 5189 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T21:23:42.245242+00:00 | 2026-11-07T21:23:43.041833+00:00 | 0.796590 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T21:23:42.247936+00:00 | 2026-11-07T21:23:47.921111+00:00 | 5.673199 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-44d-refused-create-cases-zm4bnbeo`, `hostbootstrap-16-44d-refused-create-live-actual-aet1_8_3`,
`hostbootstrap-16-44d-refused-create-live-prepared-cjuo8n3u` and the
`hostbootstrap-16-44d-refused-create-*-build-*` / `hostbootstrap-16-44d-refused-create-final-*` result directories
under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate remains owed.

#### Remaining Work

None.

### Sprint 16.45: Resumable identity-bound cluster cleanup [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`, `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Resume.hs`,
`core/hostbootstrap-core/test/ClusterResumeSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Forward and retained cleanup finish from durable node identities after a partial delete.

#### Deliverables

- Shared release decisions admit absent bound nodes and preserve every claim and replacement refusal.
- Both release routes re-observe every declared node under the same held protected entry.
- Cleanup forgets workers before its root record, and resumes without a second delete after actual absence.
- Unbound origins and orphan worker metadata retire only over authoritative absence.

#### Validation

On 2026-11-07, all 318 selected checks pass on the native x86_64 `hostbootstrap-linux-d` WSL2 host.
`ClusterResumeSpec` applies the real total release decisions directly: deleted bound control planes
under both listing values, a surviving bound container under an absent listing, replacement refusal
under both listing values, the exact stored generation, an absent bound worker, an absent unbound origin,
a present unclaimed node and an unbound listing disagreement. The ordinary forward classifications
remain independently checked.

`ClusterBackendSpec`'s "release resumes only through actual node observations and the shared removal
primitive" pins actual observation, durable read and generation propagation, the surviving-node identity
comparison, the canonical `resumeReportedRemoval` cleanup and worker-first origin retirement.
"cluster standings and record retirement retain the exact expected generation claim" follows both
forward and retained entry points through their shared driver and the all-record retirement preflight.

`ClusterOwnershipSpec`'s supplementary authored-model compatibility cases assert exact outcomes for:
"release resumes a delete whose client reported failure", "retained release resumes after all bound
nodes disappear", "all absent nodes retire an interrupted worker binding too", "a vanished worker does
not prevent deleting its remaining control plane", "a vanished control plane releases through a
surviving bound worker" and "orphan worker metadata retires before a new claim creates". They check
exact mutation sequences, empty protected records and fresh creation where declared. These use real
protected storage but authored runtime answers and establish no provider execution under § NN.
Actual Kind/Docker confirmation belongs to Sprint 16.45a.

The affected ownership, resumption, backend, reconcile, workload and relay families pass alongside the
export pins, fixture probes, portability, source-home and documentation checks. All four workspace
builds are warning-clean on Linux and native Windows; Windows establishes compilation only.
The production change is 229 non-empty diff lines across two modules. The full static gate verifies
the same frozen 1192-file manifest before and after each command in both source trees. The host uses
Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0; suite temporaries
use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T21:49:42.178124+00:00 | 2026-11-07T22:01:12.260456+00:00 | 690.085368 | 5204 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T21:49:42.177997+00:00 | 2026-11-07T22:00:34.405925+00:00 | 652.230794 | 5204 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T21:49:42.177998+00:00 | 2026-11-07T21:49:42.997898+00:00 | 0.819903 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T21:49:42.191352+00:00 | 2026-11-07T21:49:48.027297+00:00 | 5.835967 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-45-release-resume-verified-cases-1qnbx1ga` and the
`hostbootstrap-16-45-release-resume-all-nodes-*-build-*` / `hostbootstrap-16-45-release-resume-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.45a: Actual cluster cleanup resumption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`, `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Resume.hs`,
`core/hostbootstrap-core/test/ClusterResumeSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Actual Kind and Docker observations confirm cleanup from persisted bound identities.

#### Deliverables

- An external consumer builds against the in-tree units and creates actual clusters through ownership transactions.
- Actual provider deletion leaves exact protected records for the ordinary release transaction to finish.
- Forward and retained release preserve replacements and complete record cleanup over actual absence.

#### Validation

On 2026-11-07 the actual native x86_64 `hostbootstrap-linux-d` WSL2 confirmation exits 0.
The external Haskell consumer builds with `-Wall -Werror` against the in-tree units. The first actual
two-node Kind cluster is created through normal reconciliation in one real protected entry. Actual
Kind deletion removes both containers and leaves the exact root and worker records, including their
versions, unchanged. Forward release returns `ClusterReleased` and retires both records over actual
absence. A repeated release returns `ClusterAlreadyReleased`, and normal reconcile creates afresh.

The second actual cluster supplies fresh bound identities. The consumer verifies and removes its own
control plane by its raw immutable Docker ID and observes absence before creating a real diagnostic
replacement at the same name. Retained release, supplied with a different lexical forward owner input,
returns exactly `NodeReplaced` with the original and replacement identities. The replacement's full
Docker inspect bytes, the actual worker identity and both exact bound records and versions are unchanged.

After exact-ID disposal of the consumer's own diagnostic replacement, ordinary retained release uses
the stored generation claim and actual surviving worker to finish deletion. It returns `ClusterReleased`;
Kind reports no cluster, Docker reports neither declared node, and the protected store contains no
records. No provider executable, executor or observation is substituted and no credential bytes are printed.
A separate actual retained-recovery run also reaches the same replacement refusal and complete cleanup
through this consumer and the retained API, leaving its protected store empty.

The full actual run takes 286.717608 seconds, from
2026-11-07T22:09:20.557154+00:00 to 2026-11-07T22:14:07.273532+00:00 UTC.
The additional actual retained recovery takes 10.369225 seconds.

The source SHA-256 is `f0e149ccc9ec9eed588ab2c49a7cd2f582257ede114acfb99e82320dc6e601c2`;
the native binary is `afd0b332a54dc50f1ab487cbb41e2c329a4dad572f45e4411985b181fc42b27a`.
The two-node config is `3d47c85542f66000aa11db15d846213da7e93bb62a4aa8ec2464d2b6237bd0f2`
and pins `kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5`,
with the five-minute kubeadm API timeout. Preparation checks a fresh root, UID 1000, the retained machine
and boot identities and all input hashes. The consumer remains outside the repository under
`/home/hostbootstrap/.cache/hostbootstrap-16-45a-live-corrected/` and
`D:/CodexScratch/hostbootstrap-test-temp/`.

The live run verifies the frozen 1192-file manifest before and after execution in both source trees.
There is no production or test source change in this confirmation sprint. Sprint 16.45's complete
5204-core / 167-demo / 376-Python, 100%-coverage static gate applies to these exact source bytes;
its closure changes only the two plan metadata files, which pass all 22 documentation checks.
Confirmation closure validates its final metadata through `DocValidatorSpec`. The complete composed phase
gate remains owed.

Artifacts: `hostbootstrap-16-45a-cleanup-live-verified-actual-zuo57peb`, `hostbootstrap-16-45a-cleanup-live-diagnostic-recovery-piamh1yg`,
`hostbootstrap-16-45a-cleanup-live-corrected-compile-or7skhiv` and
`hostbootstrap-16-45a-cleanup-live-corrected-inputs-vy6dhlx9` under
`D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.45b: Retained release classifications and refusals [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`, `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Resume.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`,
`core/hostbootstrap-core/test/ClusterResumeSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Retained cleanup classifies a surviving bound object and malformed or unclaimed origins exactly.

#### Deliverables

- A successful delete whose bound objects remain answers `ClusterStillPresent` and retains exact records.
- Backend retry classification distinguishes a needed re-probe from a permanent refusal.
- Retained release rejects unbound, malformed, absent and replaced origins without removal.

#### Validation

On 2026-11-07, all eight selected direct checks pass on the native x86_64 `hostbootstrap-linux-d` WSL2
host. `ClusterResumeSpec`'s "node removal completion" group applies the real total classifier to absent
unbound and bound nodes, a surviving bound identity, a replacement and an unclaimed present identity.
Only actual absence permits record retirement; the same bound identity requires a re-probe and both
replacement cases preserve their exact typed refusals.

`ClusterBackendSpec`'s "a retained plan with no nodes refuses before storage or provider access" applies
the real backend to the empty plan and verifies the exact `DoNotRetry` failure and absent state directory.
"an absent actual ownership record refuses before resolving any provider tool" opens a real temporary
protected store, observes actual record absence and verifies the exact named `DoNotRetry` failure and
empty store. Neither case configures any provider executable. The source guard "retained release checks
actual record presence and shares node completion classification" follows the actual protected read,
retained delegation and shared total completion function.

The full gate also passes `ClusterOwnershipSpec`'s supplementary authored-model compatibility cases:
"a successful modeled delete with surviving nodes retains exact records", "retained release refuses a
created but unbound origin exactly", "retained release refuses a non-reported record before any delete"
and "retained release preserves a replacement and exact bound record versions". They verify complete
faults and outcomes, exact protected bytes and versions, node/listing preservation and mutation sequences.
`ClusterBackendSpec`'s "retained cleanup re-probes a successful modeled delete whose node remains" verifies
the complete `ReprobeBeforeRetry` failure and unchanged records/nodes; "retained backend refuses a
replacement and preserves exact records" compares the complete identity-bearing cause, recovery
disposition, exact record snapshots and remaining replacement. Authored tool answers establish fixture
compatibility only under § NN; actual replacement and partial-delete behavior is Sprint 16.45a's real
Kind/Docker confirmation.

All affected ownership, resumption, backend, reconcile, workload and relay cases pass in the full gate,
as do the export pins, source-home guards, fixture probes, portability and documentation checks. Both
workspaces build warning-clean on Linux and native Windows; Windows establishes compilation only.
The production change is 30 non-empty diff lines across three modules. Every command below verifies
the same frozen 1192-file manifest before and after execution in both source trees. The host uses
Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0; suite temporaries
use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T22:24:00.012560+00:00 | 2026-11-07T22:35:51.903985+00:00 | 711.894500 | 5218 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T22:24:00.012558+00:00 | 2026-11-07T22:35:00.571448+00:00 | 660.561735 | 5218 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T22:24:00.017271+00:00 | 2026-11-07T22:24:00.826101+00:00 | 0.808834 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T22:24:00.027537+00:00 | 2026-11-07T22:24:05.793295+00:00 | 5.765781 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-45b-retained-refusals-direct-7di9yupm` and the
`hostbootstrap-16-45b-retained-refusals-verified-*-build-*` / `hostbootstrap-16-45b-retained-refusals-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.45c: Exact readiness and cordon refusals [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Readiness and cordon assert exact re-entry and replacement decisions with checked setup outcomes.

#### Deliverables

- Readiness and cordon preserve the exact named re-entry refusal.
- Setup and replacement assertions name their complete outcomes.
- A refused release preserves the exact root and worker record set.

#### Validation

On 2026-11-07 all 124 selected ownership, resumption and documentation checks pass on the native x86_64
`hostbootstrap-linux-d` WSL2 host. `ClusterOwnershipSpec` checks fourteen successful creation setups
before their next operation; deliberate create refusals carry their exact original reports. The repeated
release case also verifies its first release completed.

The readiness case "a cluster the driver no longer names cannot be re-entered" compares the complete
`OwnershipProbeFailed` re-entry operation and description. The new sibling "cordon refuses an unlisted
cluster before any update" compares the same complete refusal, unchanged protected bytes and versions,
and the exact create-only mutation sequence.

"a node replaced while the probe ran is a conflict rather than a readiness" and "a node replaced while
the wall was applied is a conflict" compare the complete `NodeReplaced` outcome with both exact fixture
identities. The replaced-worker, unclaimed-cordon and unbound-release cases likewise name their precise
refusals. "a replacement that took a node's name is left standing" compares exactly the cluster and
worker key set, the complete protected image and root record version, the exact identity-bearing
refusal and the replacement fixture object.

Authored runtime answers establish supplementary compatibility only under § NN. `ClusterResumeSpec`
directly applies the real standing and release classifications to values; actual replacement preservation
and retained cleanup is Sprint 16.45a's real Kind/Docker confirmation. No production or test execution
seam is added. This sprint changes no production source; the sole changed test module and governed
documentation remain within the recorded 1192-file manifest. All four commands below verify the same
frozen bytes before and after execution in both source trees.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation only.
The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0;
suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T22:38:42.139818+00:00 | 2026-11-07T22:50:15.627981+00:00 | 693.491158 | 5219 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T22:38:42.140387+00:00 | 2026-11-07T22:49:54.743825+00:00 | 672.606348 | 5219 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T22:38:42.140362+00:00 | 2026-11-07T22:38:42.931611+00:00 | 0.791254 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T22:38:42.140383+00:00 | 2026-11-07T22:38:47.970580+00:00 | 5.830223 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-45c-exact-owned-refusals-cases-lz39e_1p` and the
`hostbootstrap-16-45c-exact-owned-refusals-*-build-*` / `hostbootstrap-16-45c-exact-owned-refusals-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.46: Declared cluster tools and backend admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterCommandSpec.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

One driver declaration governs every described cluster tool and backend admission.

#### Deliverables

- Canonical command values enumerate the renderer families and their exact tool targets.
- Kind admission requires Kind, Docker, Kubectl and Helm; nvkind also requires Nvkind.
- Discovery derives its declaration from the shared command inventory.
- A physical-source guard checks inline backend tools against both driver declarations.

#### Validation

On 2026-11-07 all 86 selected command, admission, export, source-home and documentation checks pass
on the native x86_64 `hostbootstrap-linux-d` WSL2 host. `ClusterCommandSpec` applies the actual command
renderers and canonical per-driver catalog to values. Every representative command's actual target
matches its declared tool; its frame, standard input, non-empty vector and bounded command policy
remain checked. `clusterCommandTools` is derived from that same catalog, and each driver's admission
row is its exact catalog footprint plus Helm.

"each driver declares its complete ownership API and chart tools" pins `[Kind, Docker, Kubectl, Helm]`
and `[Kind, Nvkind, Docker, Kubectl, Helm]` and checks both directions of command/declaration membership.
`ClusterBackendSpec`'s "nvkind discovery requires both nvkind creation and Kind ownership tools" admits
the complete configured set, then verifies each missing client returns its exact `Unsupported` detail
with no backend value. These are admission decisions over the actual typed configuration; no provider
execution is claimed.

"physical cluster command sites stay inside their driver tool declarations" scans the actual public
and private direct `HostBootstrap.Cluster.*` modules through the shared lexer. It pins Backend, Command
and Ownership participation, checks every literal command site against the applicable declarations,
and follows production discovery's use of `clusterDriverTools`. Constructed source controls check
comments, literal strings, qualified invocation and an undeclared target. The direct-module predicate
also explicitly excludes `HostBootstrap.Cluster.Cordon.Foundation`: nested host-capacity foundations
use their own platform probe declarations, including df and sysctl, rather than the driver row.

The full gate passes all affected ownership, backend, reconcile, workload and relay cases, the exact
public export pins, source-home guard, fixture registration/probes, portability and documentation checks.
Authored runtime answers remain supplementary compatibility only under § NN. Existing actual Kind/Docker
confirmation is recorded in Sprint 16.45a; this sprint introduces no execution override or new provider
path. The production change is 48 non-empty diff lines across two modules.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation only.
The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0.
Every command below verifies the same frozen 1192-file manifest before and after execution in both
source trees. Static-suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T23:04:53.420511+00:00 | 2026-11-07T23:16:29.316126+00:00 | 695.898673 | 5221 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T23:04:53.420511+00:00 | 2026-11-07T23:15:52.126686+00:00 | 658.709069 | 5221 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T23:04:53.420486+00:00 | 2026-11-07T23:04:54.193042+00:00 | 0.772556 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T23:04:53.428517+00:00 | 2026-11-07T23:04:59.212143+00:00 | 5.783649 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-46-cluster-declared-tools-direct-1yf6rg1f` and the
`hostbootstrap-16-46-cluster-declared-tools-row-*-build-*` / `hostbootstrap-16-46-cluster-declared-tools-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.46a: Bounded cluster ownership addresses [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Every declared node address is valid before backend storage can open.

#### Deliverables

- Target construction derives root and worker record keys through the canonical address constructors.
- An over-bound key is a typed permanent refusal before any record or state directory is created.

#### Validation

On 2026-11-07 all 33 selected boundary, retained-release and documentation checks pass on the native
x86_64 `hostbootstrap-linux-d` WSL2 host. `ClusterOwnershipSpec`'s "canonical worker addresses accept
200 bytes and refuse 201" applies the actual key constructors and pins the exact `ProtectedInvalid`
refusal. "a long standard worker address is refused at 221 encoded bytes" checks the valid 107-byte
root key and complete 221-byte worker refusal for a 99-character lowercase cluster name. These are
pure applications of the canonical encoding and bounds, with no provider stand-in.

`ClusterBackendSpec`'s "an oversized nvkind worker address refuses before state storage opens" resolves
an actual ordinary nvkind plan under a real canonical temporary root, checks its exact control-plane
and worker names, and calls the real retained API with no provider executable configured. It returns
the complete `FailureDetail` for `validate cluster spec`, the exact 221-byte key reason and `DoNotRetry`.
Its state directory does not exist afterward. The existing no-node and absent-record preflight cases
also pass unchanged, with their distinct complete refusals.

"forward and retained cluster targets validate canonical worker keys before storage" pins the root,
worker and exposure-key constructors in the existing forward target, and retained release's adoption
of that same constructor before its sole storage open. The projected retained kubeconfig coordinate
is preserved. No record codec or address bound is duplicated.

The focused run also passes supplementary authored-model compatibility for ordinary retained deletion,
Harness run-scoped deletion, accepted deletion with a surviving node, refused deletion, and replacement
preservation. The full gate rechecks all other ownership, backend, reconcile, workload and relay cases,
export pins, source-home guards, fixture registration/probes, portability and documentation checks.
Authored runtime answers remain compatibility only under § NN; the new boundary and actual filesystem
cases configure no such executable.

The production change is 50 non-empty diff lines in one module, adopting the shared target constructor
at the retained call site. Both workspaces build warning-clean on Linux and native Windows; Windows
establishes compilation only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2,
GHC 9.12.4 and Cabal 3.16.1.0. Every command below verifies the same frozen 1192-file manifest before
and after execution in both source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T23:23:18.718877+00:00 | 2026-11-07T23:34:46.575752+00:00 | 687.859763 | 5225 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T23:23:18.718844+00:00 | 2026-11-07T23:34:07.912846+00:00 | 649.196726 | 5225 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T23:23:18.718873+00:00 | 2026-11-07T23:23:19.521447+00:00 | 0.802579 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T23:23:18.725910+00:00 | 2026-11-07T23:23:24.426281+00:00 | 5.700392 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-46a-bounded-cluster-addresses-cases-e3kec4jk` and the
`hostbootstrap-16-46a-bounded-cluster-addresses-*-build-*` / `hostbootstrap-16-46a-bounded-cluster-addresses-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.46b: One protected reconciliation entry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Already-owned reconciliation and its running check share the same protected entry.

#### Deliverables

- The single transaction continuation observes ownership and container running state under one session.
- The source guard pins exactly one transaction entry and the exact carried generation.

#### Validation

On 2026-11-07 all 27 selected checks pass on the native x86_64
`hostbootstrap-linux-d` WSL2 host. The source guard "reconciliation and its running check share one
exact protected entry" pins exactly one `withClusterTransaction` in `runClusterReconcileCall`, with
`Owned.reconcileOwnedCluster` and `Owned.ownedClusterRunning` receiving the same configuration,
protected session, key and owned descriptor. Foreign observation also stays inside that continuation.
The actual protected-store entry primitive supplies session exclusion; the source guard verifies its
composition at this call site.

The healthy repeat, stopped owned containers and foreign cluster cases pass as supplementary authored
model compatibility. The complete gate also rechecks all reconciliation observations, ownership
refusals, export pins, physical computation homes, compile-fail fixtures and documentation. Authored
client answers provide compatibility only under § NN, not actual provider execution evidence.

The production change is 38 non-empty diff lines in one module. Both workspaces build warning-clean
on Linux and native Windows; Windows establishes compilation only. The host uses Ubuntu 24.04.5,
Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0. Each command below verifies the
same frozen 1192-file manifest before and after execution in both source trees; suite temporaries
use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-07T23:38:43.528012+00:00 | 2026-11-07T23:50:14.590153+00:00 | 691.065181 | 5226 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-07T23:38:43.527948+00:00 | 2026-11-07T23:49:43.171221+00:00 | 659.646178 | 5226 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-07T23:38:43.528667+00:00 | 2026-11-07T23:38:44.397857+00:00 | 0.869194 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-07T23:38:43.527919+00:00 | 2026-11-07T23:38:49.280694+00:00 | 5.752797 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-46b-single-cluster-entry-cases-el4ly4x0` and the
`hostbootstrap-16-46b-single-cluster-entry-*-build-*` / `hostbootstrap-16-46b-single-cluster-entry-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.46c: Readiness carries the observed identity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

A readiness result identifies the actual control plane the transaction re-observes.

#### Deliverables

- Private ownership readiness returns its observed identity with the classified outcome.
- The backend stamps that actual identity and settles replacement without advancing readiness authority.
- A fresh record and new identity between cordon and readiness is an exact not-ready result.

#### Validation

On 2026-11-08, 25 selected checks pass on the native x86_64 `hostbootstrap-linux-d` WSL2 host.
The recreated-record compatibility case establishes an initial readiness version of 1, releases the
first record, creates a new record with a different control-plane identity, and observes the old
cordon return `ClusterReadinessResultNotReady` naming that identity. A fresh cordon then observes
version 2, demonstrating the stale result did not advance the counter. Its authored client replies
establish compatibility, not actual provider execution evidence under § NN.

The source guard pins the post-probe control-plane identity to the classified outcome and checks that
an identity mismatch returns not-ready before the version guard. The complete gate exercises the
private ownership outcomes and the broader reconciliation and documentation suite. The production
change is 21 non-empty diff lines in two modules; both workspaces build warning-clean on Linux and
native Windows, with Windows establishing compilation only. The host uses Ubuntu 24.04.5, Linux
6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0. Each command below verifies the
same frozen 1192-file manifest before and after execution in both source trees; temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T00:13:46.452410+00:00 | 2026-11-08T00:25:34.964049+00:00 | 708.543871 | 5228 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T00:13:46.453027+00:00 | 2026-11-08T00:24:50.604489+00:00 | 664.181682 | 5228 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T00:13:46.452536+00:00 | 2026-11-08T00:13:47.225856+00:00 | 0.773357 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T00:13:46.453028+00:00 | 2026-11-08T00:13:52.317163+00:00 | 5.864402 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-46c-observed-readiness-fixed-cases-uf4kmsk3` and the
`hostbootstrap-16-46c-observed-readiness-*-build-*` / `hostbootstrap-16-46c-observed-readiness-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.46d: Exact backend discovery and join assertions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Backend tests identify their precise scope and preserve complete conflict evidence.

#### Deliverables

- Contradictory listings and unhealthy owned clusters retain exact mutation and record evidence.
- Discovery and join case names agree with the tools and nodes they actually exercise.
- Lexer-based imports and exact capability fields pin the private backend boundary.

#### Validation

On 2026-11-08, 29 selected checks pass on the native x86_64 `hostbootstrap-linux-d` WSL2 host.
The contradictory-listing case checks the exact reported cause, empty recorded create paths and empty
protected records; the stopped-owned-cluster case checks the conflict and the exact mutation history
and retained listing. These use authored client replies as supplementary compatibility, not provider
execution evidence under § NN. The discovery and join names describe their actual scope.

The source guard uses the comment-stripping import reader for the cluster command and ownership modules,
and checks the complete hidden capability constructor field types. The test-only change introduces no
production Haskell. Both workspaces build warning-clean on Linux and native Windows; Windows establishes
compilation only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and
Cabal 3.16.1.0. Each command below verifies the same frozen 1192-file manifest before and after execution
in both source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T00:29:52.188335+00:00 | 2026-11-08T00:41:24.623187+00:00 | 692.458666 | 5228 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T00:29:52.188383+00:00 | 2026-11-08T00:40:55.191898+00:00 | 663.026320 | 5228 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T00:29:52.188389+00:00 | 2026-11-08T00:29:53.000942+00:00 | 0.812581 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T00:29:52.198863+00:00 | 2026-11-08T00:29:58.201443+00:00 | 6.002786 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-46d-exact-backend-final-cases-ds0nrtnx` and the
`hostbootstrap-16-46d-exact-backend-*-build-*` / `hostbootstrap-16-46d-exact-backend-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.47: The direct-Colima ownership driver [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Colima stage records preserve an owner exactly through their byte encoding.

#### Deliverables

- Stage record producers and parsers admit printable ASCII owners only.
- Invalid owners refuse, and admitted owners round-trip exactly.

#### Validation

On 2026-11-08, the native x86_64 `hostbootstrap-linux-d` WSL2 host passed all 328 focused
Colima and documentation cases. The stage-record constructor rejects U+0100, U+00E9 and spaces;
the byte parser rejects encoded U+00E9 and spaces; a valid owner round-trips unchanged. Both paths
check the same printable ASCII range before a record can be rendered with the byte codec.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command below verifies the same frozen 1192-file manifest before and after execution
in both source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T00:47:43.573033+00:00 | 2026-11-08T00:59:28.132359+00:00 | 704.577992 | 5228 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T00:47:43.573070+00:00 | 2026-11-08T00:58:40.833148+00:00 | 657.277495 | 5228 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T00:47:43.573077+00:00 | 2026-11-08T00:47:44.364918+00:00 | 0.791862 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T00:47:43.591205+00:00 | 2026-11-08T00:47:49.486752+00:00 | 5.895699 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-47-colima-owner-final-cases-2l015gbv` and the
`hostbootstrap-16-47-colima-owner-*-build-*` / `hostbootstrap-16-47-colima-owner-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.47a: Post-delete Colima cleanup resumption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Post-delete Colima cleanup resumption.

#### Deliverables

- Implement and validate the exact behavior below.

#### Validation

On 2026-11-08, 328 focused Colima and documentation cases pass on the native x86_64
`hostbootstrap-linux-d` WSL2 host. The cleanup fixture interrupts the post-delete listing, checks the
retained `ColimaReleasing` stage, and retries the same invocation to `ColimaReleased` with no second
delete. A second fixture starts from `ColimaContextReleased`, invokes the cleanup driver, and reaches
`ColimaReleased` without executing a command. The fixture uses the real protected store and host
filesystem; authored command responses establish compatibility only under § NN, not provider
execution evidence. The actual Colima substrate remains covered by the phase's acceptance gate.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command below verifies the same frozen 1192-file manifest before and after execution
in both source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T01:05:29.230044+00:00 | 2026-11-08T01:17:07.143521+00:00 | 697.927991 | 5228 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T01:05:29.228810+00:00 | 2026-11-08T01:16:25.969231+00:00 | 656.754081 | 5228 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T01:05:29.232145+00:00 | 2026-11-08T01:05:30.032858+00:00 | 0.800730 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T01:05:29.239433+00:00 | 2026-11-08T01:05:35.001717+00:00 | 5.762405 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-47a-colima-resume-final-cases-_g5l4yh_` and the
`hostbootstrap-16-47a-colima-resume-*-build-*` / `hostbootstrap-16-47a-colima-resume-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.47b: Publish Colima release after namespace cleanup [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Publish Colima release after namespace cleanup.

#### Deliverables

- Implement and validate the exact behavior below.

#### Validation

On 2026-11-08, 328 focused Colima and documentation cases pass on the native x86_64
`hostbootstrap-linux-d` WSL2 host. A nonempty scaffold refuses while the retained stage remains
`ColimaContextReleased` and the home, cache, temporary and manifest records remain; after the added
entry is removed, the same cleanup invocation completes. A second scenario starts after namespace
and manifest removal but before the terminal stage write and completes without a command. A terminal
replay with a newly occupied home refuses. The fixture uses the real protected store and filesystem;
authored command answers provide compatibility only under § NN, not provider execution evidence.

The stage table now requires namespace absence for `ColimaReleased`; a source guard checks that the
namespace finisher runs before that transition. Both workspaces build warning-clean on Linux and native
Windows; Windows establishes compilation only. The host uses Ubuntu 24.04.5, Linux
6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0. Each command below verifies the
same frozen 1192-file manifest before and after execution in both source trees; suite temporaries use
`/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T01:27:24.993087+00:00 | 2026-11-08T01:39:13.698888+00:00 | 708.717161 | 5228 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T01:27:24.993087+00:00 | 2026-11-08T01:38:31.271063+00:00 | 666.288751 | 5228 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T01:27:24.994294+00:00 | 2026-11-08T01:27:25.810790+00:00 | 0.816506 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T01:27:25.000897+00:00 | 2026-11-08T01:27:31.089055+00:00 | 6.088260 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-47b-colima-release-order-final-cases-c67v95lv` and the
`hostbootstrap-16-47b-colima-release-order-*-build-*` / `hostbootstrap-16-47b-colima-release-order-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.47c: Resume bound Colima creation records [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Resume bound Colima creation records.

#### Deliverables

- Implement and validate the exact behavior below.

#### Validation

On 2026-11-08, 328 focused Colima and documentation checks pass on the native x86_64
`hostbootstrap-linux-d` WSL2 host. The fixture first binds the reported profile and disk, refuses an
acquisition while the retained manifest differs, then retries the same invocation after restoring the
manifest and reaches Managed without another start. Rebinding the same identity succeeds; a changed
machine observation and a different binding refuse. An existing profile without a bound claimed origin
still refuses as outcome unknown. The fixture uses real protected records and filesystem identities;
authored command responses provide compatibility only under § NN, not actual Colima execution.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command below verifies the same frozen 1192-file manifest before and after execution
in both source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T01:48:47.079704+00:00 | 2026-11-08T02:00:16.057285+00:00 | 688.986247 | 5228 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T01:48:47.079529+00:00 | 2026-11-08T01:59:47.739143+00:00 | 660.667944 | 5228 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T01:48:47.080361+00:00 | 2026-11-08T01:48:47.883321+00:00 | 0.802974 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T01:48:47.094416+00:00 | 2026-11-08T01:48:53.236224+00:00 | 6.141891 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-47c-colima-bound-recovery-final-cases-jnpr2d2x` and the
`hostbootstrap-16-47c-colima-bound-recovery-*-build-*` / `hostbootstrap-16-47c-colima-bound-recovery-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.47d: Resume unbound Colima directory origins [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Resume unbound Colima directory origins.

#### Deliverables

- Implement and validate the exact behavior below.

#### Validation

On 2026-11-08, 328 focused Colima and documentation checks pass on the native x86_64
`hostbootstrap-linux-d` WSL2 host. A missing parent causes directory creation to fail with an unbound
origin retained; after the parent is created, the same preparation reaches `ColimaPrepared`. A present
target is refused with its directory and exact origin record preserved. A stale unbound present-origin
record over an absent target is forgotten at its protected version and a new directory is acquired.
These cases use the actual protected store, host filesystem and ownership primitives.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command below verifies the same frozen 1192-file manifest before and after execution
in both source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T02:06:15.941644+00:00 | 2026-11-08T02:17:46.031115+00:00 | 690.096904 | 5228 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T02:06:15.942061+00:00 | 2026-11-08T02:17:17.576136+00:00 | 661.641220 | 5228 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T02:06:15.945489+00:00 | 2026-11-08T02:06:16.886534+00:00 | 0.941064 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T02:06:15.951881+00:00 | 2026-11-08T02:06:22.445231+00:00 | 6.493422 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-47d-colima-unbound-origin-final-cases-bq8e56ql` and the
`hostbootstrap-16-47d-colima-unbound-origin-*-build-*` / `hostbootstrap-16-47d-colima-unbound-origin-final-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.47e: Re-enter Colima context for live Docker [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Re-enter Colima context for live Docker.

#### Deliverables

- Implement and validate the exact behavior below.

#### Validation

On 2026-11-08, 328 focused Colima and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. With a real protected store and filesystem, a Managed route
with a missing context binding refuses without creating a directory or record or running a command.
A Released stage likewise refuses before invoking the interpreter or recreating the context. The
interpreter is a fixture; public Apple execution remains acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1192-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T02:23:13.931424+00:00 | 2026-11-08T02:35:04.477548+00:00 | 710.552884 | 5228 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T02:23:13.931424+00:00 | 2026-11-08T02:34:19.523452+00:00 | 665.598379 | 5228 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T02:22:41.836663+00:00 | 2026-11-08T02:22:42.690383+00:00 | 0.853726 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T02:22:41.836664+00:00 | 2026-11-08T02:22:47.751759+00:00 | 5.915152 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-47e-focused-jx9hpao7` and the
`hostbootstrap-16-47e-pass-*-build-*` / `hostbootstrap-16-47e-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.47f: Re-enter Colima context and verify disk at settlement [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Re-enter Colima context and verify disk at settlement.

#### Deliverables

- Implement and validate the exact behavior below.

#### Validation

On 2026-11-08, 328 focused Colima and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. With a real protected store and filesystem, settlement from Prepared
with a deleted context record refuses without recreating its directory or record. A disk identity
that differs from the binding is refused, with the stage and version retained as Prepared. These
cases use actual protected records and filesystem identities; public Apple execution remains
acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1192-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T02:39:03.072307+00:00 | 2026-11-08T02:50:52.713936+00:00 | 709.647828 | 5228 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T02:39:03.072307+00:00 | 2026-11-08T02:50:19.118854+00:00 | 676.052464 | 5228 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T02:37:39.756009+00:00 | 2026-11-08T02:37:40.543781+00:00 | 0.787775 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T02:37:39.761754+00:00 | 2026-11-08T02:37:45.657159+00:00 | 5.895458 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-47f-focused-6p08dfsa` and the
`hostbootstrap-16-47f-*-build-*` / `hostbootstrap-16-47f-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.47g: Seal Colima stage evidence [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Seal Colima stage evidence.

#### Deliverables

- Implement and validate the exact behavior below.

#### Validation

On 2026-11-08, 329 focused Colima and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. The source guard checks the actual private stage module's
export list and positional declarations: managed evidence is abstract and neither stage records nor
managed evidence expose record-update labels. Existing stage and codec cases continue to pass.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1192-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T02:54:39.900737+00:00 | 2026-11-08T03:06:28.153485+00:00 | 708.258529 | 5229 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T02:54:39.900737+00:00 | 2026-11-08T03:05:53.152798+00:00 | 673.257570 | 5229 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T02:53:24.104736+00:00 | 2026-11-08T02:53:24.925230+00:00 | 0.820498 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T02:53:24.104735+00:00 | 2026-11-08T02:53:29.690564+00:00 | 5.585872 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-47g-focused-nbj3zfc3` and the
`hostbootstrap-16-47g-*-build-*` / `hostbootstrap-16-47g-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.47h: Document Colima command bounds [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Stage.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/applied_cordon.md`

#### Objective

Document Colima command bounds.

#### Deliverables

- Implement and validate the exact behavior below.

#### Validation

On 2026-11-08, 329 focused Colima and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. Inspection of `colimaBounds` confirms it passes the caller's
wall timeout through unchanged and specifies the 16 MiB transcript ceiling and six-second grace;
the Haddock and engineering documentation now describe those actual bounds. Existing bounded-run
and Colima cases pass.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1192-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T03:09:18.321890+00:00 | 2026-11-08T03:21:22.745849+00:00 | 724.429547 | 5229 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T03:09:18.321890+00:00 | 2026-11-08T03:20:37.414390+00:00 | 679.097754 | 5229 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T03:07:55.287927+00:00 | 2026-11-08T03:07:56.190161+00:00 | 0.902236 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T03:07:55.287927+00:00 | 2026-11-08T03:08:01.094129+00:00 | 5.806246 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-47h-focused-e7n4lt3u` and the
`hostbootstrap-16-47h-*-build-*` / `hostbootstrap-16-47h-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.48: The live cluster gate as a harness case [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/app/Main.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`,
`core/hostbootstrap-core/internal/bare-runtime/HostBootstrap/CLI/Bare/Runtime.hs`
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

#### Validation

On 2026-11-08, 131 focused cluster-backend, value, source-boundary and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. The output and mapping value cases and source guard pass. The
actual private relay transaction runs through the bounded command interpreter and fixture Docker client;
when UserInterrupt arrives after modeled relay creation, creation workers stop and both names are absent.
The fixture's responses model Docker and are not live provider evidence. The previous live confirmation
is historical; a new one is owed in Sprint 16.48b.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1193-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T03:52:13.198274+00:00 | 2026-11-08T04:05:03.448468+00:00 | 770.255587 | 5232 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T03:52:13.198275+00:00 | 2026-11-08T04:04:27.489572+00:00 | 734.296442 | 5232 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T03:50:14.950381+00:00 | 2026-11-08T03:50:15.755690+00:00 | 0.805313 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T03:50:14.968888+00:00 | 2026-11-08T03:50:20.864600+00:00 | 5.895751 | 376 Python cases; 100% coverage; exit 0 |

**2026-08-21 — passed.** On Linux 7.0.0-28-generic x86_64 with Docker 29.7.1, Kind 0.32.0,
kubectl 1.36.4, and Kubernetes 1.36.1, the bare binary's `test run cluster-live` exited 0 in 30
seconds. Its generative `run-53dce11d81dc3` plan created and cordoned
`hostbootstrap-test-run-53dce11d81dc3`, reached node readiness, returned the client/server version and
non-empty node observation, deleted the cluster through that same closed-over plan, proved no matching
labelled node container remained, and re-read the exact sentinel under
`.test_data/run-53dce11d81dc3`. The harness then released its own data generation. The client binary was
downloaded from the official Kubernetes distribution and matched its published SHA-256 before the run;
the temporary gate directory and generated test config were removed afterward.

Closing this sprint requires the value and interruption cases in Remaining Work and the host static gate.
The fresh live confirmation follows in Sprint 16.48b.


Artifacts: `hostbootstrap-16-48-corrected-focused-avwi785z` and the
`hostbootstrap-16-48-corrected-*-build-*` / `hostbootstrap-16-48-corrected-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.48a: Carry Harness codec authority to bare assertions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Harness.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/architecture/dhall_generation.md`

#### Objective

Carry the actual generated Harness scope and its codec into bare assertions.

#### Deliverables

- Decode the sibling project config through its installed, scope-bound Harness codec. Carry the
  actual authority from the lifecycle; do not reconstruct it from untrusted names or paths.

#### Validation

On 2026-11-08, 121 focused Harness, source-boundary and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. The scoped suite receives a real fixture-held Harness authority
and retained config bytes, refuses a changed case registry, and refuses an unscoped lifecycle before
forward execution. The bare source guard checks scoped codec decoding. The public export inventory
also passes (27 cases). Live Docker/Kind confirmation is owed in Sprint 16.48b.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1193-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T04:24:26.187222+00:00 | 2026-11-08T04:37:19.018712+00:00 | 772.836678 | 5236 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T04:27:13.191543+00:00 | 2026-11-08T04:39:25.492312+00:00 | 732.305673 | 5236 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T04:24:26.187229+00:00 | 2026-11-08T04:24:27.172051+00:00 | 0.984828 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T04:24:26.194813+00:00 | 2026-11-08T04:24:32.533612+00:00 | 6.338837 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-48a-cases2-focused-o0thdest`, `hostbootstrap-16-48a-export-check-4kock1e0`, and the
`hostbootstrap-16-48a-final-*-build-*` / `hostbootstrap-16-48a-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.48aa: Exercise bare plan and kubectl arguments [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Provide a private test seam for the actual bare plan and its Kubernetes argument builder.

#### Deliverables

- Expose `bareStepPlan`, `bareInit`, and `bareKubectlArguments` to the test suite without adding a public API.
- Verify no Harness run gives `Left EmptyStepPlan`; both observation vectors begin with `--kubeconfig`
  and the exact `clusterKubeconfigPath` of the plan.

#### Validation

On 2026-11-08, 23 focused bare-value and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. A test-only home module includes the exact production bare
module without exposing it publicly. The actual `bareInit` and `bareStepPlan` reject a config lacking
a Harness run with `EmptyStepPlan`; the actual `bareKubectlArguments` returns each complete
observation vector with the exact plan-owned kubeconfig path.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T04:44:48.958899+00:00 | 2026-11-08T04:58:56.591691+00:00 | 847.638382 | 5237 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T04:45:10.293522+00:00 | 2026-11-08T04:58:40.531562+00:00 | 810.243385 | 5237 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T04:43:53.921987+00:00 | 2026-11-08T04:43:54.978639+00:00 | 1.056660 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T04:43:53.919795+00:00 | 2026-11-08T04:44:00.975018+00:00 | 7.055270 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-48aa-final-focused-605z8u9b` and the
`hostbootstrap-16-48aa-final-*-build-*` / `hostbootstrap-16-48aa-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.48b: Confirm the bare cluster gate on linux-cpu [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`, `documents/engineering/testing.md`

#### Objective

Confirm the completed bare cluster gate against a disposable live linux-cpu host.

#### Deliverables

- Run `hostbootstrap test run cluster-live` after the preceding changes and record its cluster readiness,
  read-only observation, cleanup, and durable-root evidence.

#### Validation

On 2026-11-08 the declared phase checks passed in order on x86_64 Ubuntu 24.04.5 WSL2
(`hostbootstrap-linux-d`, Linux 6.18.54.1-microsoft-standard-WSL2):

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all --ghc-options=-Werror` from `core/` | 2026-11-08T05:04:16.514703+00:00 | 2026-11-08T05:16:46.699013+00:00 | 750.189 | 5237 core cases; exit 0 |
| `hostbootstrap test run cluster-live` after isolated `test init` | 2026-11-08T05:17:07.140221+00:00 | 2026-11-08T05:19:52.765880+00:00 | 165.627 | 1/1 passed; exit 0 |

The host used Docker 29.9.3, Kind 0.32.0, kubectl 1.37.0, Kubernetes 1.36.1, Helm 4.3.1,
GHC 9.12.4 and Cabal 3.16.1.0. The run created `hostbootstrap-test-run-6babc15a5f49`, observed
its ready node and Kubernetes version using the plan's kubeconfig, exercised the exposure containers,
and passed the reverse assertion including byte-identical durable-sentinel readback. Separate Docker
queries found no cluster-labelled node or exposure containers afterward; `kind get clusters` reported
none. An earlier isolated live run also passed and left no matching containers.

Both legs verified the same 1194-file source manifest before and after. Artifacts: `hostbootstrap-16-48b-phase-core-lliutzns`, `hostbootstrap-16-48b-live-ordered-60c33brh`, and `hostbootstrap-16-48b-live-qoml89bh` under
`D:/CodexScratch/hostbootstrap-test-temp/`. This is sprint evidence; the complete phase gate must be
rerun at phase closure after its remaining work.

#### Remaining Work

None.

### Sprint 16.49: The enumeration names what the binary drives [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Remove the unused Python path from the Colima ownership description.

#### Deliverables

- Delete the never-read `ownershipPythonPath` field and its assignments without altering the retained
  Colima ownership description. Keep the previously completed HostTool narrowing and exact pin.

#### Validation

On 2026-11-08, 329 focused Colima and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. The unused Python path field and its assignments are absent
from the Colima ownership description; the remaining identity and ownership fields are unchanged.
The resolver and protocol still observe Python and are explicitly scheduled for Sprints 16.49a-c.
`documents/architecture/build_and_run_model.md` was reviewed; this internal field removal does not
change its current behavior description.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T05:25:29.570546+00:00 | 2026-11-08T05:37:36.540302+00:00 | 726.974480 | 5237 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T05:25:29.570544+00:00 | 2026-11-08T05:36:56.192181+00:00 | 686.626097 | 5237 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T05:23:47.457526+00:00 | 2026-11-08T05:23:48.340696+00:00 | 0.883172 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T05:23:47.456972+00:00 | 2026-11-08T05:23:53.349970+00:00 | 5.893034 | 376 Python cases; 100% coverage; exit 0 |

On 2026-08-21, `cabal build all --ghc-options=-Werror` and
`cabal build hostbootstrap-core-test --ghc-options=-Werror` passed on x86_64 Linux with GHC 9.12.4 and
Cabal 3.16.1.0. The focused exact-membership, cluster-backend, and provider-backend gate passed all 65
cases in 2.91 seconds. Fixture `HostConfig` values contain only the tools their tested production route
actually resolves.


Artifacts: `hostbootstrap-16-49-focused-p3jcxvaf` and the
`hostbootstrap-16-49-*-build-*` / `hostbootstrap-16-49-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.49a: Remove Python from Colima authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Authority.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Remove Python from retained Colima toolchain authority and its fingerprint while keeping the current wire
and native resolver buildable for the ordered migration.

#### Deliverables

- Remove the bootstrap-Python validation and retained identity; ensure settlement and revalidation do not
  derive authority or fingerprint from that interpreter. Keep old wire observations descriptive until the
  following migration changes the producer.

#### Validation

On 2026-11-08, 329 focused Colima and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. The protected Colima and Brew authorities retain only their
actual command and helper identities. A fixture changes the transitional wire's Python identity and
confirms settlement and the v2 toolchain fingerprint remain the same. The legacy native resolver
still probes Python; Sprints 16.49b-c remove that wire and probe. The fingerprint version changes, so
old retained fingerprints do not compare equal; public Apple execution remains acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T05:43:47.715918+00:00 | 2026-11-08T05:56:02.016969+00:00 | 734.305824 | 5237 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T05:44:26.427645+00:00 | 2026-11-08T05:55:53.608400+00:00 | 687.185220 | 5237 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T05:43:47.715890+00:00 | 2026-11-08T05:43:48.606018+00:00 | 0.890132 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T05:43:47.715919+00:00 | 2026-11-08T05:43:53.570313+00:00 | 5.854432 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-49a-focused-yps40cuy` and the
`hostbootstrap-16-49a-final-*-build-*` / `hostbootstrap-16-49a-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.49b: Introduce the Python-free resolver wire [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Protocol.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Introduce a Python-free resolver wire and consume it without manufacturing an interpreter identity.

#### Deliverables

- Add and validate Python-free READY and missing-Colima reports alongside the legacy native producer.
- Settle new reports through the same authority policy and expose descriptive fixture views.

#### Validation

On 2026-11-08, 330 focused Colima and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. Python-free READY and missing-Colima reports parse and settle
to the same command and helper identities as the corresponding legacy reports; a zero executable
identity is refused. These are fixture wire values, not live Apple observations. Native discovery
still emits the legacy report and is switched in Sprint 16.49ba.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T06:02:20.565589+00:00 | 2026-11-08T06:14:29.020517+00:00 | 728.459661 | 5238 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T06:02:41.490525+00:00 | 2026-11-08T06:14:06.579783+00:00 | 685.093710 | 5238 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T06:01:35.183647+00:00 | 2026-11-08T06:01:36.036182+00:00 | 0.852541 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T06:01:35.183646+00:00 | 2026-11-08T06:01:41.033033+00:00 | 5.849425 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-49b-focused-8ic0i4hf` and the
`hostbootstrap-16-49b-final-*-build-*` / `hostbootstrap-16-49b-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.49ba: Switch native Colima discovery to the new wire [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Native.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Make native discovery produce only Python-free reports and refuse legacy settlement.

#### Deliverables

- Remove native Python probing and emit the new reports. Reject legacy reports at settlement.
- Verify a fixture with no Python executable resolves READY without changing its fingerprint.

#### Validation

On 2026-11-08, 331 focused Colima and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. The native resolver fixture produces the Python-free report,
remains ready after its Python executable is removed, and retains the same fingerprint. Settlement
refuses valid legacy interpreter-bearing reports. These are native filesystem fixture observations and
wire decisions; actual Apple execution remains acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T06:20:53.435804+00:00 | 2026-11-08T06:32:52.886387+00:00 | 719.455258 | 5239 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T06:21:28.140784+00:00 | 2026-11-08T06:32:56.081787+00:00 | 687.945470 | 5239 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T06:20:53.435851+00:00 | 2026-11-08T06:20:54.313644+00:00 | 0.877798 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T06:20:53.435764+00:00 | 2026-11-08T06:20:59.645142+00:00 | 6.209416 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-49ba-focused-bmy5ho5z` and the
`hostbootstrap-16-49ba-final-*-build-*` / `hostbootstrap-16-49ba-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.49c: Remove obsolete Python resolver protocol [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Protocol.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Resolver/Testing.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Delete the remaining obsolete Python wire and fixture shapes and pin their absence.

#### Deliverables

- Remove the Python candidate, protocol layout field, fixture path and obsolete wire cases. A fixture
  without `usr/bin/python3` resolves READY, and the trusted wire has no Python field.
- Source guards cover the direct-Colima backend and adapter. `Ensure/GuestBootstrap.hs` intentionally
  retains its unrelated guest `python3-venv` package, so an assertion over every Ensure module would
  incorrectly forbid that legitimate package.

#### Validation

On 2026-11-08, 332 focused Colima and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. Native resolver fixtures resolve without a Python executable,
retain stable fingerprints, and refuse the removed interpreter-bearing wire. A source guard covers
the direct Colima backend and adapter. Actual Apple execution remains acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T06:40:37.040850+00:00 | 2026-11-08T06:52:27.382367+00:00 | 710.346131 | 5240 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T06:40:37.041011+00:00 | 2026-11-08T06:51:37.601047+00:00 | 660.564326 | 5240 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T06:40:37.048227+00:00 | 2026-11-08T06:40:37.871518+00:00 | 0.823299 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T06:40:37.049003+00:00 | 2026-11-08T06:40:42.876487+00:00 | 5.827523 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-49c-focused-ihvxj23t` and the
`hostbootstrap-16-49c-final-*-build-*` / `hostbootstrap-16-49c-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

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
run is evidence for creation, readiness, and deletion only; the cordon on this route is Sprint 16.38a's owed
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

The consumer owns canonical cluster configuration; core retains and validates that exact choice.

#### Deliverables

- A resolved plan names no implicit project template for either driver.
- The consumer renders the bytes and binds their digest, state path and declared topology through
  `withPlanOwnedClusterConfig` before the prepared backend consumes them.
- The closed creation vocabulary passes the staged choice as Kind's `--config` or nvkind's
  `--config-template`; it derives no project filename from the driver.
- Pure plan and described-command cases pin the absence of an implicit template and the exact supplied path.

#### Validation

Lifecycle plan cases require `clusterConfigFile` to be `Nothing` for both resolved drivers. The
closed command cases retain the explicitly supplied config path under the selected driver's exact
flag, and the owned backend validates and stages the canonical bytes before creation. The consumer's
artifact selection remains a consumer decision.

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

### Sprint 16.54: One prepared-gate commitment [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`, `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`, `core/hostbootstrap-core/test/BudgetSpec.hs`, `core/hostbootstrap-core/test/ClusterReconcileSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/PrepareFixture.hs`
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

On 2026-11-08, 358 focused budget, cluster, provider, and documentation cases pass on the
x86_64 `hostbootstrap-linux-d` WSL2 host. The golden commitment pins the domain, framing, and
fields; distinct non-ASCII plan values remain distinct. The cluster, running-provider, and
provider-share registrations expose their actual package journal coordinates to the tests, which
compare each with its prepared gate's commitment. The fixture stores Unicode gate values under
hashed record keys without imposing an unrelated record-name constraint.

The canonical construction is the length-framed SHA-256 digest over UTF-8. The replaced colon join
was ambiguous and the earlier Char8 encoding truncated characters. No durable state depends on the
replaced commitment: these packages are invocation-scoped authenticated handoff transport, not
protected-store records; the dependency wire golden uses placeholders rather than real commitments.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T07:02:08.426375+00:00 | 2026-11-08T07:13:50.621747+00:00 | 702.199937 | 5242 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T07:02:08.426179+00:00 | 2026-11-08T07:13:02.771449+00:00 | 654.349520 | 5242 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T07:02:08.426179+00:00 | 2026-11-08T07:02:09.232930+00:00 | 0.806754 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T07:02:08.441793+00:00 | 2026-11-08T07:02:14.282600+00:00 | 5.840840 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-54-gate-focused-3rrpic3x` and the
`hostbootstrap-16-54-unicode-*-build-*` / `hostbootstrap-16-54-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.55: The resolved cluster plan retains one state directory [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

A resolved cluster plan retains exactly one derived-state directory, with no empty-list case or
partial path extraction. Its pure teardown partition preserves the durable root.

#### Deliverables

- The field is one directory rather than a list, and its name says so.
- The `error` disappears because the empty case has no term.
- The teardown partition and retained backend projection read it directly.
- The ledger row is removed in the same change.
- `teardown` refuses a removal set that equals `dataPath` or contains an ancestor of it. Run-key
  construction and consumer migration continue in the following split sprints.

#### Validation

On 2026-11-08, 200 focused lifecycle and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. The teardown partition returns refusal for a durable root or
ancestor and for empty, mixed absolute/relative, or parent-segment paths. Filesystem aliases remain
subject to the ownership backend; this is a pure lexical guard. Run-key construction continues in
the following split sprints. Earlier validation on 2026-09-12 recorded 154 lifecycle cases and
150 demo cases for the single derived-state directory representation.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T07:19:39.686179+00:00 | 2026-11-08T07:31:00.411806+00:00 | 680.730051 | 5244 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T07:19:39.686181+00:00 | 2026-11-08T07:30:35.293899+00:00 | 655.611981 | 5244 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T07:19:39.686146+00:00 | 2026-11-08T07:19:40.452642+00:00 | 0.766498 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T07:19:39.699246+00:00 | 2026-11-08T07:19:45.431621+00:00 | 5.732410 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-55-focused-jtzc8zv6` and the
`hostbootstrap-16-55-linuxcore-build-*`, `hostbootstrap-16-55-linuxdemo-*`, `hostbootstrap-16-55-windows*-*`, and `hostbootstrap-16-55-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.55a: Introduce validated Harness profile construction [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Provide a validating constructor and a pattern-free run-key accessor before migrating consumers.

#### Deliverables

- Add `mkTestCaseProfile` and an accessor; share ASCII run-key validation with `profileFromPlanName`.
- Test refusal of empty, unsafe, non-ASCII, and overlong keys and admission of `run-42`.

#### Validation

On 2026-11-08, 539 focused lifecycle, authority, and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. `mkTestCaseProfile` and plan-name parsing share the same
bounded ASCII run-key admission, and `clusterProfileRunKey` projects admitted keys. Empty,
path-bearing, non-ASCII, and overlong keys are refused; `run-42` is admitted. The prior constructor
remains exposed only for the staged consumer migration in the next sprint.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T07:49:01.406579+00:00 | 2026-11-08T08:00:37.857059+00:00 | 696.455007 | 5245 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T07:49:01.406538+00:00 | 2026-11-08T08:00:07.235342+00:00 | 665.833128 | 5245 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T07:49:01.406580+00:00 | 2026-11-08T07:49:02.345809+00:00 | 0.939235 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T07:49:01.407690+00:00 | 2026-11-08T07:49:07.333682+00:00 | 5.926029 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-55a-rerun-gate-focused-ebc539cj` and the
`hostbootstrap-16-55a-rerun-{linuxcore,linuxdemo,windowscore,windowsdemo}-*`, and `hostbootstrap-16-55a-rerun-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.55b: Adopt validated profiles in the bare CLI [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Route the bare CLI through validated Harness profile construction.

#### Deliverables

- Refuse invalid run keys before building a live cluster plan or reading a retained one.
- Exercise valid and invalid profile paths through the bare CLI test seam.

#### Validation

On 2026-11-08, the bare CLI plan case passes on the x86_64 `hostbootstrap-linux-d` WSL2 host:
empty, path-bearing, overlong and non-ASCII run names are refused, and `run-42` is admitted.
The CLI validates the profile both before plan construction and when reading retained config.
The focused authority and documentation suites also pass 361 cases. The former unchecked profile
constructor remains available for the demo migration and will be sealed in Sprint 16.55c.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T08:05:28.027271+00:00 | 2026-11-08T08:16:58.769410+00:00 | 690.746624 | 5245 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T08:05:28.037492+00:00 | 2026-11-08T08:16:19.908968+00:00 | 651.875710 | 5245 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T08:05:28.039076+00:00 | 2026-11-08T08:05:28.840428+00:00 | 0.801352 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T08:05:28.040689+00:00 | 2026-11-08T08:05:33.888123+00:00 | 5.847472 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-55b-focused-rs3gjd2l` and the
`hostbootstrap-16-55b-{linuxcore-build,linuxdemo,windowscore,windowsdemo}-*`, and `hostbootstrap-16-55b-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.55ba: Refine demo Harness run keys [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Config.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Make demo Harness run keys validated values while preserving their Dhall representation.

#### Deliverables

- Refine decoded and programmatically constructed run keys through `mkTestCaseProfile`.
- Project the retained valid cluster profile without a partial conversion.
- Reject invalid keys at config decoding and exercise the public smart constructor.

#### Validation

On 2026-11-08, all 168 demo cases pass on the x86_64 `hostbootstrap-linux-d` WSL2 host.
Demo Harness run keys are refined through the core's constructor during Dhall decoding and
programmatic assembly; invalid names are refused and a valid Harness configuration round-trips
through its unchanged text representation. The value retains its validated profile for total
projection. Demo command constructor matches remain for the following sprint.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T08:22:01.720985+00:00 | 2026-11-08T08:33:43.691624+00:00 | 701.975200 | 5245 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T08:22:01.720999+00:00 | 2026-11-08T08:32:41.076465+00:00 | 639.359621 | 5245 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T08:22:01.721133+00:00 | 2026-11-08T08:22:02.516976+00:00 | 0.795850 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T08:22:01.720939+00:00 | 2026-11-08T08:22:07.498046+00:00 | 5.777140 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-55ba-demo-focused-o5erhvc9` and the
`hostbootstrap-16-55ba-{linuxcore,linuxdemo-build,windowscore,windowsdemo}-*`, and `hostbootstrap-16-55ba-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.55bb: Adopt profile accessors in demo commands [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Remove demo command dependencies on the unchecked profile constructor.

#### Deliverables

- Replace profile constructor matches with the pattern-free accessor.

#### Validation

On 2026-11-08, all 168 demo cases pass on the x86_64 `hostbootstrap-linux-d` WSL2 host.
Demo commands now use `clusterProfileRunKey` for scope labels and Harness-only branches; existing
routing, teardown, and profile cases remain green. The unchecked constructor is sealed in the
following sprint.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T08:36:50.238880+00:00 | 2026-11-08T08:48:23.761940+00:00 | 693.527569 | 5245 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T08:36:50.238876+00:00 | 2026-11-08T08:47:32.104407+00:00 | 641.869700 | 5245 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T08:36:50.239090+00:00 | 2026-11-08T08:36:51.023540+00:00 | 0.784458 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T08:36:50.245761+00:00 | 2026-11-08T08:36:57.153814+00:00 | 6.908101 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-55bb-demo-focused-863usi7g` and the
`hostbootstrap-16-55bb-{linuxcore,linuxdemo-build,windowscore,windowsdemo}-*`, and `hostbootstrap-16-55bb-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.55c: Seal Harness profile construction [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`

#### Objective

Make invalid Harness run keys unrepresentable through the public cluster profile API.

#### Deliverables

- Hide the `TestCase` constructor and update remaining test consumers to use the validated API.
- Pin the public boundary and verify teardown cannot be given a path forged through a run key.

#### Validation

On 2026-11-08, 540 lifecycle, authority, and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. `TestCase` is private, the export inventory pins the public
boundary, and a source-boundary case checks it cannot be exported accidentally. Production and
fixture consumers construct Harness profiles through validated run keys; the teardown tests refuse
paths that can reach the durable root.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T08:54:23.200966+00:00 | 2026-11-08T09:06:01.367576+00:00 | 698.171079 | 5246 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T08:54:23.200662+00:00 | 2026-11-08T09:05:17.983264+00:00 | 654.786797 | 5246 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T08:54:23.200436+00:00 | 2026-11-08T08:54:23.983575+00:00 | 0.783143 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T08:54:23.205145+00:00 | 2026-11-08T08:54:29.190504+00:00 | 5.985396 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-55c-focused-0iut5saa` and the
`hostbootstrap-16-55c-{linuxcore-build,linuxdemo,windowscore,windowsdemo}-*`, and `hostbootstrap-16-55c-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

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

### Sprint 16.57: Admit only safe routed Docker commands [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Routing.hs`, `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

Apply route restrictions where Docker parses global options, and distinguish forbidden subcommands.

#### Deliverables

- Refuse empty arguments, leading flags, and the `context`, `login`, `logout`, and `buildx` subcommands with appropriate diagnostics.
- Admit flags and values after an allowed subcommand; verify the accepted and refused argument tables.

#### Validation

On 2026-11-08, 333 focused Colima and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. Routed Docker admission rejects missing commands, leading
global options, and forbidden subcommands with distinct diagnostics; flags after allowed
subcommands remain intact. Actual Apple execution remains acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T09:10:56.854206+00:00 | 2026-11-08T09:22:46.103754+00:00 | 709.260890 | 5247 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T09:10:56.856568+00:00 | 2026-11-08T09:22:03.712895+00:00 | 666.866466 | 5247 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T09:10:56.867242+00:00 | 2026-11-08T09:10:57.654935+00:00 | 0.787698 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T09:10:56.856482+00:00 | 2026-11-08T09:11:02.863805+00:00 | 6.007358 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-57-focused-grlkq65z` and the
`hostbootstrap-16-57-{linuxcore-build,linuxdemo,windowscore,windowsdemo}-*`, and `hostbootstrap-16-57-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.57a: Preserve shipped command argument bytes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

Preserve executable and argument bytes through the supervised shipped-command frame.

#### Deliverables

- Replace low-byte truncation and Latin-1 decoding with exact encoding and raw-byte spawning; refuse unencodable arguments.
- Round-trip non-ASCII arguments through the frame and a real supervised child.

#### Validation

On 2026-11-08, 335 focused Colima and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. A real supervised child receives non-ASCII UTF-8 arguments
unchanged under the closed C locale; invalid scalar and NUL arguments refuse. Timeout,
cancellation, descendant cleanup, and hard parent-death cases also pass. Descriptor inheritance
uses a close-on-exec sweep with checked errors; actual Apple execution remains acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T09:34:54.574011+00:00 | 2026-11-08T09:46:23.659800+00:00 | 689.105359 | 5249 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T09:34:54.573965+00:00 | 2026-11-08T09:45:59.611740+00:00 | 665.056658 | 5249 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T09:34:54.574408+00:00 | 2026-11-08T09:34:55.406914+00:00 | 0.832531 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T09:34:54.574019+00:00 | 2026-11-08T09:35:00.392446+00:00 | 5.818592 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-57a-final2-focused-ssruhep8` and the
`hostbootstrap-16-57a-final2-{linuxcore-build,linuxdemo,windowscore,windowsdemo}-*`, and `hostbootstrap-16-57a-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.57b: Derive the direct-Colima command tool set [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

Remove the unused independently restated command-tool list.

#### Deliverables

- Delete `colimaCommandTools`, correct the module description, and derive the test tool set from described commands.

#### Validation

On 2026-11-08, 674 focused Colima, authority, and documentation cases pass on the x86_64
`hostbootstrap-linux-d` WSL2 host. The obsolete tool list is removed; the test derives the target
set directly from the described commands, and the private export pin reflects the removal.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1194-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T09:51:12.375834+00:00 | 2026-11-08T10:02:39.460467+00:00 | 687.096330 | 5250 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T09:51:12.375868+00:00 | 2026-11-08T10:01:56.801208+00:00 | 644.436336 | 5250 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T09:51:12.375865+00:00 | 2026-11-08T09:51:13.159394+00:00 | 0.783553 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T09:51:12.381227+00:00 | 2026-11-08T09:51:18.198261+00:00 | 5.817198 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-57b-focused-8nseg0c1` and the
`hostbootstrap-16-57b-{linuxcore-build,linuxdemo,windowscore,windowsdemo}-*`, and `hostbootstrap-16-57b-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.57c: Type validated Colima profiles [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Command.hs`, `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Require a validated Colima profile for commands that address a profile.

#### Deliverables

- Introduce a private-constructor `ColimaProfile` through the ownership validator and adopt it for profile commands.

#### Validation

On 2026-11-08, 676 focused Colima, authority, compile-fail, and documentation cases pass on
the x86_64 `hostbootstrap-linux-d` WSL2 host. Ownership keys retain a validated opaque
`ColimaProfile`, and profile-targeting command builders require it. Invalid names refuse; the
public constructor-forging fixture fails with the pinned diagnostic. Apple execution remains
acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1195-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T10:11:44.307486+00:00 | 2026-11-08T10:23:13.615189+00:00 | 689.319076 | 5252 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T10:11:44.307434+00:00 | 2026-11-08T10:22:35.739539+00:00 | 651.442850 | 5252 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T10:11:44.307443+00:00 | 2026-11-08T10:11:45.105515+00:00 | 0.798087 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T10:11:44.319453+00:00 | 2026-11-08T10:11:50.112598+00:00 | 5.793241 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-57c-final-focused-n6dccpoq` and the
`hostbootstrap-16-57c-final-{linuxcore-build,linuxdemo,windowscore,windowsdemo}-*`, and `hostbootstrap-16-57c-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.57ca: Type Docker context command arguments [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Command.hs`, `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Derive Docker context command arguments only from admitted Colima profiles.

#### Deliverables

- Introduce opaque `DockerContextName`, derived from `ColimaProfile`, and adopt it for context and routed-Docker commands.
- Pin the public constructor boundary and command argument behavior.

#### Validation

On 2026-11-08, 676 focused Colima, authority, compile-fail, and documentation cases pass on
the x86_64 `hostbootstrap-linux-d` WSL2 host. Command builders require an opaque `DockerContextName` derived from a validated
`ColimaProfile`. Invalid profile names refuse; the public context-constructor-forging fixture fails
with the pinned diagnostic. Apple execution remains
acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1196-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T10:31:17.999338+00:00 | 2026-11-08T10:42:49.653983+00:00 | 691.662596 | 5253 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T10:31:17.999340+00:00 | 2026-11-08T10:42:20.516458+00:00 | 662.524738 | 5253 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T10:31:03.344926+00:00 | 2026-11-08T10:31:04.081386+00:00 | 0.736465 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T10:31:03.344925+00:00 | 2026-11-08T10:31:08.629648+00:00 | 5.284778 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-57ca-focused-2lkw_s7a` and the
`hostbootstrap-16-57ca-{linuxcore,linuxdemo,windowscore,windowsdemo}-build-*`, and `hostbootstrap-16-57ca-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.57caa: Centralize Docker context projections [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Command.hs`, `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Use the derived context identity for admission and the settled public wall projection.

#### Deliverables

- Route context listing decisions and the live wall's context through the typed derivation, leaving its spelling in one command-layer home.

#### Validation

On 2026-11-08, 675 focused Colima, authority, compile-fail, and documentation cases pass on
the x86_64 `hostbootstrap-linux-d` WSL2 host. Context admission and removal decisions consume validated profiles, and the settled wall retains
the derived `DockerContextName`. The actual wall projection and Docker arguments agree on its
name; the command layer is the single home for the context spelling. Apple execution remains
acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1196-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T10:49:16.503405+00:00 | 2026-11-08T11:00:54.408553+00:00 | 697.913046 | 5253 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T10:49:16.503381+00:00 | 2026-11-08T11:00:06.472077+00:00 | 649.976149 | 5253 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T10:49:16.503402+00:00 | 2026-11-08T10:49:17.276901+00:00 | 0.773509 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T10:49:16.506971+00:00 | 2026-11-08T10:49:22.386342+00:00 | 5.879439 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-57caa-final-focused-89s5bp72` and the
`hostbootstrap-16-57caa-guard-{linuxcore,linuxdemo,windowscore,windowsdemo}-build-*`, and `hostbootstrap-16-57caa-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.57cb: Type Colima start arguments [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Command.hs`, `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Make the Colima start prefix a typed command invariant.

#### Deliverables

- Require a start-argument value that fixes `start --profile <p>` and update its callers.

#### Validation

On 2026-11-08, 677 focused Colima, authority, compile-fail, and documentation cases pass on
the x86_64 `hostbootstrap-linux-d` WSL2 host. The opaque `ColimaStartArguments` fixes the start command profile, rejects later profile flags,
and is checked against the owned profile before entering the transaction. Focused cases exercise
mismatch refusal, argument override refusal, and the hidden-constructor compile-fail fixture. Apple execution remains
acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1197-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T11:07:02.422050+00:00 | 2026-11-08T11:18:33.339018+00:00 | 690.923321 | 5255 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T11:07:02.422054+00:00 | 2026-11-08T11:17:46.757687+00:00 | 644.341561 | 5255 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T11:06:14.755686+00:00 | 2026-11-08T11:06:15.544646+00:00 | 0.788963 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T11:06:14.755686+00:00 | 2026-11-08T11:06:20.351398+00:00 | 5.595758 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-57cb-focused-nykz8rar` and the
`hostbootstrap-16-57cb-{linuxcore-build,linuxdemo,windowscore,windowsdemo}-*`, and `hostbootstrap-16-57cb-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.58: The direct-Colima suite asserts what its cases name [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/Run.hs`, `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Report.hs`, `core/hostbootstrap-core/test/ColimaSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`
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

On 2026-11-08, 499 focused Colima, effect, cluster, and documentation cases pass on
the x86_64 `hostbootstrap-linux-d` WSL2 host. The direct-Colima cases cover classifier refusals, every stage pair, digest sensitivity, exact
command targets, failed-start records, and non-vacuous parent-death and opt-in live behavior. The
coverage manifest records 31 native-only cases and a separate live lane. Absolute Lima disk paths
containing parent traversal are refused. Cancellation now terminates the subprocess group before
waiting on pipe readers; Windows cross-drive fixtures recognize the explicit anchor refusal. Apple execution remains
acceptance work.

Both workspaces build warning-clean on Linux; the core workspace builds and tests natively on Windows. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Linux commands verify the same frozen 1197-file manifest before and after execution in both
source trees; the native Windows command verifies the Windows tree. Linux suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T12:25:14.555881+00:00 | 2026-11-08T12:37:38.749389+00:00 | 744.199383 | 5260 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T12:25:14.555881+00:00 | 2026-11-08T12:36:48.523405+00:00 | 693.973004 | 5260 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T12:23:31.938792+00:00 | 2026-11-08T12:23:33.602978+00:00 | 1.664196 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T12:23:31.938785+00:00 | 2026-11-08T12:23:38.618897+00:00 | 6.680166 | 376 Python cases; 100% coverage; exit 0 |
| `cabal test all` from `core/` on native Windows | 2026-11-08T12:23:31.923595+00:00 | 2026-11-08T13:01:17.894940+00:00 | 2265.989018 | 5260 core cases; 31 native Colima refusals; exit 0 |

Artifacts: `hostbootstrap-16-58-fix-linux-focused-wuqe359_` and the
`hostbootstrap-16-58-fix-{linux,windows}-build-*` and `hostbootstrap-16-58-fixed-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.59: The storage wall settles only through a package-private permit [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`, `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget/Internal.hs`, `core/hostbootstrap-core/test/BudgetSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Make `AppliedStorageWall` evidence depend on a package-private settlement permit joined to the exact
prepared storage call, journal gate, and live provider wall. The storage proof retains that wall's
epoch rather than inventing one.

#### Deliverables

- Mint an opaque `StorageWallSettlementPermit` in the private budget internal module and require it
  alongside the live provider wall during settlement; hide raw observation constructors.
- Reject mismatched fences and settle refusal, failure, and uncertain observations without producing
  storage authority. Pin the public constructor boundary with a compile-fail case.

#### Validation

On 2026-11-08, 425 focused Colima, authority, compile-fail, and documentation cases pass on
the x86_64 `hostbootstrap-linux-d` WSL2 host. The private storage permit joins the exact prepared call, journal lineage, and live provider wall.
The applied proof retains the live wall epoch. The private harness checks successful settlement,
ceiling and epoch drift, gate and fence mismatches, and that non-success observations cannot invoke
the consumer. `RawStorageWallObservation.hs` pins the public constructor boundary. Apple execution remains
acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1198-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T13:15:29.190963+00:00 | 2026-11-08T13:26:55.320063+00:00 | 686.134380 | 5261 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T13:15:29.191005+00:00 | 2026-11-08T13:26:26.134309+00:00 | 656.948362 | 5261 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T13:15:29.191002+00:00 | 2026-11-08T13:15:35.414737+00:00 | 6.223783 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T13:15:29.191205+00:00 | 2026-11-08T13:15:40.529957+00:00 | 11.338840 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-59-fence-focused-olg6d8hq` and the
`hostbootstrap-16-59-{fence-build,final-linuxdemo-build,final-windowscore-build,final-windowsdemo-build}-*`, and `hostbootstrap-16-59-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.59a: Share storage launch renderers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`, `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Cordon/Foundation.hs`, `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`, `core/hostbootstrap-core/test/BudgetSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`, `documents/architecture/unrepresentable_state.md`

#### Objective

Use the storage tokens emitted by the production Lima, Incus, and WSL2 launch renderers in the
prepared storage-wall call.

#### Deliverables

- Share the production sizing renderers, including a WSL2 VHD-size renderer used by both provider
  launch and storage-wall preparation, and compare their actual tokens in `BudgetSpec`.

#### Validation

On 2026-11-08, 482 focused budget, substrate, WSL, authority, and documentation cases pass on
the x86_64 `hostbootstrap-linux-d` WSL2 host. Storage-wall preparation now obtains Lima and Incus storage tokens from their production sizing
renderers, and WSL2 preparation and installation share one exact VHD-size renderer. Budget cases
compare each prepared token with its launch renderer. The covered provider change expired phase 15
evidence; its complete static and live Incus gate passed again before this sprint continued. Apple execution remains
acceptance work.

Both workspaces build warning-clean on Linux and native Windows; Windows establishes compilation
only. The host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal
3.16.1.0. Each command verifies the same frozen 1198-file manifest before and after execution in both
source trees; suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T14:01:42.624660+00:00 | 2026-11-08T14:12:05.855541+00:00 | 623.235680 | 5261 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T14:01:42.624692+00:00 | 2026-11-08T14:12:24.377414+00:00 | 641.757662 | 5261 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T14:01:42.624553+00:00 | 2026-11-08T14:01:43.409546+00:00 | 0.784997 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T14:01:42.624688+00:00 | 2026-11-08T14:01:48.429954+00:00 | 5.805314 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: `hostbootstrap-16-59a-resumed-focused-26lhsckb` and the
`hostbootstrap-16-59a-final-windows{core,demo}-build-*`, and `hostbootstrap-16-59a-gate-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.60: The ownership manifest is validated, byte-exact, and host-neutral [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Manifest.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
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
- Raw paths and host-neutral POSIX path validation are supplied by Sprint 16.21b. The validated
  entry and prefix producers preserve that byte vocabulary.
- A host-independent pure suite covers the vocabulary on every gate host, and the Windows row's
  `OwnershipUnsupported` answer is asserted once.

#### Validation

On 2026-11-08, the manifest suite passes on the x86_64 Linux WSL2 host and native Windows.
The pure cases exercise malformed grammar, producer refusals, all five entry kinds, raw-byte
round trips, digest sensitivity, and prefix validation. The Windows suite asserts its explicit
unsupported result. The registered private-package compile-fail fixture confirms record update
cannot bypass validation. Focused runs pass 687 Linux cases and 17 Windows cases.

Both workspaces build warning-clean on Linux and Windows. The Linux host uses Ubuntu 24.04.5,
Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4 and Cabal 3.16.1.0. Linux commands verify
the same frozen 1200-file manifest before and after execution in both source trees; the native
Windows command verifies the Windows tree. Linux suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T14:23:54.285736+00:00 | 2026-11-08T14:35:48.077292+00:00 | 713.796917 | 5267 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T14:23:54.285738+00:00 | 2026-11-08T14:35:04.385751+00:00 | 670.105047 | 5267 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T14:23:54.296713+00:00 | 2026-11-08T14:23:55.144353+00:00 | 0.847645 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T14:23:54.302314+00:00 | 2026-11-08T14:24:00.365397+00:00 | 6.063129 | 376 Python cases; 100% coverage; exit 0 |
| `cabal test all` from `core/` on native Windows | 2026-11-08T14:23:54.286317+00:00 | 2026-11-08T15:02:04.005666+00:00 | 2289.736573 | 5267 core cases; exit 0 |

Artifacts: the `hostbootstrap-16-60-*` result directories under
`D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate remains owed.

#### Remaining Work

None.

### Sprint 16.61: The WSL idle-timeout Haddocks state what the timeout bounds [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Cordon/Foundation.hs`
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

On 2026-11-08, both WSL sizing Haddocks and the WSL engineering guide state that
the six-hour timeout bounds idle gaps, cite the observed 4 h 3 min Windows gate,
and make no claim that it limits the total run. The sizing Haddock is attached
to its sizing function.

The Linux host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2,
GHC 9.12.4 and Cabal 3.16.1.0. Linux commands verify the frozen 1200-file
manifest in both source trees before and after execution; Python commands verify
the Windows tree. Linux suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T15:03:16.874530+00:00 | 2026-11-08T15:15:30.146433+00:00 | 733.277546 | 5267 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T15:03:16.874534+00:00 | 2026-11-08T15:15:33.230366+00:00 | 736.361503 | 5267 core and 168 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T15:03:16.941097+00:00 | 2026-11-08T15:03:21.950245+00:00 | 5.009183 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T15:03:16.874867+00:00 | 2026-11-08T15:03:28.584531+00:00 | 11.709753 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: the `hostbootstrap-16-61-*` result directories under
`D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate remains owed.

#### Remaining Work

None.

### Sprint 16.62: The direct Linux GPU host answers its budget with a typed decision [Done]

**Status**: Done
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

On 2026-11-08, the provider plan retains the requested envelope and reports CPU, memory and
storage as unsupported walls for the direct host. The demo reservation reports that its outer
build and project container run uncapped. Focused runs passed 109 core and 83 demo cases.
The covered provider change expired phase 15 evidence; its complete static and live Incus
gate passed again, its cleanup was verified, and its digest was refreshed before this sprint closed.

The Linux host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4
and Cabal 3.16.1.0. Linux commands verified the frozen 1200-file manifest in both source
trees; the Python commands verified the Windows tree. Linux suite temporaries used `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T16:38:55.761683+00:00 | 2026-11-08T16:49:56.556852+00:00 | 660.800154 | 5267 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T16:38:55.761681+00:00 | 2026-11-08T16:49:54.175749+00:00 | 658.419033 | 5267 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T16:24:20.759751+00:00 | 2026-11-08T16:24:22.368016+00:00 | 1.608273 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T16:24:20.759841+00:00 | 2026-11-08T16:24:30.693389+00:00 | 9.933624 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-62-*` and `hostbootstrap-15-50c-*` result
directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.63: The Colima reconciler hashes through Digest [Done]

**Status**: Done
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

On 2026-11-08, the unchanged Colima suite passes with the canonical byte-oriented
SHA-256 function used for ownership lineage and cleanup digests. The local Text
hash helper and the separate direct hash implementation are gone.

The Linux host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2,
GHC 9.12.4 and Cabal 3.16.1.0. Linux commands verify the frozen 1200-file
manifest in both source trees before and after execution; Python commands verify
the Windows tree. Linux suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all --ghc-options=-Werror` from `core/` | 2026-11-08T17:20:49.716663+00:00 | 2026-11-08T17:33:10.313139+00:00 | 740.602176 | 5267 core cases; exit 0 |
| `cabal test all` from `core/` | 2026-11-08T17:33:17.063346+00:00 | 2026-11-08T17:45:02.253542+00:00 | 705.195620 | 5267 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T17:21:09.915424+00:00 | 2026-11-08T17:32:24.818044+00:00 | 674.907814 | 5267 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T17:21:09.915488+00:00 | 2026-11-08T17:21:11.628558+00:00 | 1.713082 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T17:21:09.915480+00:00 | 2026-11-08T17:21:17.728665+00:00 | 7.813243 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: the `hostbootstrap-16-63-*` result directories under
`D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate remains owed.

#### Remaining Work

None.

### Sprint 16.64: Place dependency-probe representation in a private leaf [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Dependency/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

The dependency-probe representation belongs to the package-private lifecycle dependency leaf,
with the public reconciler preserving its current interface while consumers migrate.

#### Deliverables

- The private leaf owns the nominal, error-polymorphic probe representation and its constructor.
- The public reconciler's existing probe type and wrapper delegate to that representation, retaining
  behavior and compatibility until the later backend-evidence and readiness-kind work closes.

#### Validation

On 2026-11-08, the private lifecycle dependency leaf owns the nominal, error-polymorphic
probe representation. The reconciler delegates its existing API to that representation;
backend-evidence producers and readiness-kind checks remain in the following work.
Both workspaces build, and 176 focused reconciliation, dependency, and documentation
cases pass.

The Linux host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2,
GHC 9.12.4 and Cabal 3.16.1.0. Linux commands verify the frozen 1200-file
manifest in both source trees before and after execution; Python commands verify
the Windows tree. Linux suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T18:08:03.103271+00:00 | 2026-11-08T18:21:01.988436+00:00 | 778.891005 | 5267 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T18:08:03.103270+00:00 | 2026-11-08T18:20:21.597780+00:00 | 738.500049 | 5267 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T18:08:03.110460+00:00 | 2026-11-08T18:08:04.948855+00:00 | 1.838410 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T18:08:03.115886+00:00 | 2026-11-08T18:08:11.397593+00:00 | 8.281771 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: the `hostbootstrap-16-64-*` result directories under
`D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate remains owed.

#### Remaining Work

None.

### Sprint 16.64a: Cluster dependencies use backend-owned probe producers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Cluster preparation obtains provider and share dependency probes from their opaque backend-owned
dependency objects, which retain the exact fresh reprobe.

#### Deliverables

- The private provider dependency bridge produces probes from its running-provider and share objects.
- Cluster preparation uses those producers while preserving its current readiness behavior.

#### Validation

On 2026-11-08, 323 focused cluster, provider, and documentation cases passed.
Cluster preparation obtains its running-provider and share probes from the corresponding
backend-owned dependency objects. Both workspaces build. The covered provider change
expired phase 15 evidence; its complete static and live Incus gate passed again, its
cleanup was verified, and its covered-path digest was refreshed.

The Linux host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2,
GHC 9.12.4 and Cabal 3.16.1.0. Linux commands verified the frozen 1200-file manifest
in both source trees; Python commands verified the Windows tree. Linux suite temporaries
used `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T18:26:07.975340+00:00 | 2026-11-08T18:38:05.669128+00:00 | 717.706634 | 5267 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T18:26:07.975359+00:00 | 2026-11-08T18:37:38.630666+00:00 | 690.667670 | 5267 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T18:26:07.975289+00:00 | 2026-11-08T18:26:11.663052+00:00 | 3.687829 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T18:26:07.975258+00:00 | 2026-11-08T18:26:18.513918+00:00 | 10.538847 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-64a-*` and `hostbootstrap-15-50d-*` result
directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.64b: Running-provider callbacks carry an opaque probe [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

A fresh running-provider callback receives the probe minted by the provider backend, so its
consumer does not wrap or replace the backend's raw reprobe action.

#### Deliverables

- The public fresh-running-provider callback receives an opaque dependency probe made by the
  provider adapter. The raw action stays behind the adapter's private helper.
- The demo passes that probe directly into provider-share preparation.

#### Validation

On 2026-11-08, 289 focused provider and documentation cases and 83 demo command cases
passed. The fresh running-provider callback supplies an opaque probe minted from its
backend-owned fresh observation; demo share preparation consumes that probe directly. Both workspaces build. The covered provider change
expired phase 15 evidence; its complete static and live Incus gate passed again, its
cleanup was verified, and its covered-path digest was refreshed.

The Linux host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2,
GHC 9.12.4 and Cabal 3.16.1.0. Linux commands verified the frozen 1200-file manifest
in both source trees; Python commands verified the Windows tree. Linux suite temporaries
used `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T18:57:47.581141+00:00 | 2026-11-08T19:10:19.173184+00:00 | 751.601233 | 5267 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T18:57:47.580964+00:00 | 2026-11-08T19:09:36.817472+00:00 | 709.245177 | 5267 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T18:57:47.580748+00:00 | 2026-11-08T18:57:49.348438+00:00 | 1.767719 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T18:57:47.586522+00:00 | 2026-11-08T18:57:54.861822+00:00 | 7.275407 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-64b-*` and `hostbootstrap-15-50e-*` result
directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.64c: Backend probes retain their readiness kind [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/readiness/HostBootstrap/Readiness/Kernel.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

The private backend probe retains the closed readiness kind its typed key names, so later
dependency preparation can compare that kind with the plan's required edge.

#### Deliverables

- Every backend probe key maps to a distinct readiness-kind value.
- A probe retains and projects the kind of the key used to mint it.

#### Validation

On 2026-11-08, the private readiness kernel retains a closed term-level kind on
each backend probe. The mapping covers all eight backend keys and distinguishes
cluster API readiness from GPU plugin readiness. Both workspaces build, and 58
focused readiness and documentation cases pass.

The Linux host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2,
GHC 9.12.4 and Cabal 3.16.1.0. Linux commands verify the frozen 1200-file
manifest in both source trees before and after execution; Python commands verify
the Windows tree. Linux suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T19:29:23.669357+00:00 | 2026-11-08T19:42:39.165643+00:00 | 795.504454 | 5269 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T19:29:23.669192+00:00 | 2026-11-08T19:42:09.607556+00:00 | 765.946242 | 5269 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T19:29:23.669068+00:00 | 2026-11-08T19:29:25.537449+00:00 | 1.868404 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T19:29:23.669359+00:00 | 2026-11-08T19:29:31.822546+00:00 | 8.153290 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: the `hostbootstrap-16-64c-*` result directories under
`D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate remains owed.

#### Remaining Work

None.

### Sprint 16.64d: Dependency probes retain backend readiness kind [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Dependency probes produced from backend probes retain the readiness kind fixed by their typed
backend key, preparing that kind for the plan-edge comparison.

#### Deliverables

- The private probe representation retains an optional generic kind without importing readiness
  or reconciliation into the dependency leaf.
- `planDependencyProbe` supplies the exact backend probe's retained readiness kind.
- The existing raw compatibility wrapper remains explicitly untagged until its removal in the
  remaining backend-evidence migration.

#### Validation

On 2026-11-08, dependency probes produced by backend probes retain the readiness
kind fixed by their typed backend key. The private compatibility bridge remains
untagged and is tracked for removal. Both workspaces build; 60 focused readiness,
boundary and documentation cases and 12 private dependency cases pass.

The Linux host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2,
GHC 9.12.4 and Cabal 3.16.1.0. Linux commands verify the frozen 1200-file
manifest in both source trees before and after execution; Python commands verify
the Windows tree. Linux suite temporaries use `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T19:49:51.359535+00:00 | 2026-11-08T20:02:47.940812+00:00 | 776.588887 | 5270 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T19:49:51.359450+00:00 | 2026-11-08T20:02:14.086219+00:00 | 742.734044 | 5270 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T19:49:51.359481+00:00 | 2026-11-08T19:49:53.109596+00:00 | 1.750135 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T19:49:51.359537+00:00 | 2026-11-08T19:49:58.660247+00:00 | 7.300782 | 376 Python cases; 100% coverage; exit 0 |

Artifacts: the `hostbootstrap-16-64d-*` result directories under
`D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate remains owed.

#### Remaining Work

None.

### Sprint 16.64e: Provider and cluster probes carry readiness kinds [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Backend-owned provider, share, and cluster dependency producers retain the readiness kind their
fresh observation establishes.

#### Deliverables

- Running-provider probes carry provider-responding readiness; provider-share probes carry
  durable-share readiness; cluster probes carry cluster-API readiness.
- The fresh running-provider callback returns the same provider-responding kind.

#### Validation

On 2026-11-08, 359 focused cluster, provider, readiness and documentation cases passed.
The running-provider, durable-share and cluster producers tag their probes with provider
responding, durable share and cluster API readiness kinds respectively. Both workspaces build. The covered provider change
expired phase 15 evidence; its complete static and live Incus gate passed again, its
cleanup was verified, and its covered-path digest was refreshed.

The Linux host uses Ubuntu 24.04.5, Linux 6.18.54.1-microsoft-standard-WSL2,
GHC 9.12.4 and Cabal 3.16.1.0. Linux commands verified the frozen 1200-file manifest
in both source trees; Python commands verified the Windows tree. Linux suite temporaries
used `/hbt`.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T20:08:22.795871+00:00 | 2026-11-08T20:20:30.052757+00:00 | 727.263207 | 5270 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T20:08:22.795950+00:00 | 2026-11-08T20:20:04.767173+00:00 | 701.977332 | 5270 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T20:08:22.795912+00:00 | 2026-11-08T20:08:24.682684+00:00 | 1.886790 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T20:08:22.795945+00:00 | 2026-11-08T20:08:30.433606+00:00 | 7.637727 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-64e-*` and `hostbootstrap-15-50f-*` result
directories under `D:/CodexScratch/hostbootstrap-test-temp/`. The complete composed phase gate
remains owed.

#### Remaining Work

None.

### Sprint 16.64f: Observe an owned Incus share without mutation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Reobserve a share and its owned parent without attaching, repairing, or changing either object.

#### Deliverables

- Check the exact owned share record and device under the protected entry, and recheck the parent identity.
- Refuse absent, unbound, foreign, or replaced observations without mutation.

#### Validation

On 2026-11-08, 361 focused provider, authority and documentation cases passed. The new case
checks absence, the exact bound share, and parent replacement during device read without changing
provider state or records. Both Linux workspaces build with tests enabled. The provider change
expired Phase 15 evidence; its complete static and live Incus gate passed, cleanup was verified,
and the covered-path digest was refreshed. The WSL2 host used Ubuntu 24.04.5, GHC 9.12.4 and
Cabal 3.16.1.0; Linux runs checked identical 1200-file source manifests in both trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T20:43:34.066299+00:00 | 2026-11-08T20:56:07.240381+00:00 | 753.180257 | 5271 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T20:43:34.066323+00:00 | 2026-11-08T20:55:23.442159+00:00 | 709.381653 | 5271 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T20:43:34.066319+00:00 | 2026-11-08T20:43:37.041665+00:00 | 2.975370 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T20:43:34.075491+00:00 | 2026-11-08T20:43:42.657343+00:00 | 8.581922 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-64f-*` and `hostbootstrap-15-50g-*` result
directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64g: Reobserve retained Incus shares without repairing them [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Use the read-only owned-share observation for the retained Incus dependency service.

#### Deliverables

- Reprobe the exact owned Incus share without attaching or repairing it; refuse absence or replacement.
- Preserve the other provider routes and the existing guest-side mount check.

#### Validation

On 2026-11-08, 361 focused provider, authority and documentation cases passed. The retained
share case checks repeated valid observations and removal of the device; the missing device is
refused without attachment, other provider mutation, or record change. Both Linux workspaces build.
The covered provider change expired Phase 15 evidence; its complete static and live Incus gate
passed, cleanup was verified, and the covered-path digest was refreshed. The WSL2 host used Ubuntu
24.04.5, GHC 9.12.4 and Cabal 3.16.1.0; Linux runs checked the same 1200-file manifest in both trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T21:13:52.308999+00:00 | 2026-11-08T21:26:31.845600+00:00 | 759.542682 | 5271 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T21:13:52.308946+00:00 | 2026-11-08T21:25:44.639144+00:00 | 712.335899 | 5271 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T21:13:52.308975+00:00 | 2026-11-08T21:13:54.006656+00:00 | 1.697697 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T21:13:52.308993+00:00 | 2026-11-08T21:13:58.975939+00:00 | 6.667001 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-64g-*` and `hostbootstrap-15-50h-*` result
directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64h: Check readiness kinds on projected edges [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Record the readiness kind required by the synthetic chart and guest-alias edges and refuse a differently
tagged probe before it runs. Untagged compatibility probes and general graph edges remain for later work.

#### Deliverables

- Preserve exact edge order and public key projection while carrying the required readiness kind.
- Reject a tagged GPU readiness probe on a chart's cluster API edge before any action or probe executes.

#### Validation

On 2026-11-08, 175 focused reconciliation and documentation cases passed. A real GPU-plugin
backend probe is refused on a chart cluster-API edge before it runs; existing chart and alias
preparation cases pass. Both Linux workspaces build. The WSL2 host used Ubuntu 24.04.5,
GHC 9.12.4 and Cabal 3.16.1.0; Linux runs checked the same 1200-file manifest in both trees.
General graph edges and untagged probes remain owned by Sprints 16.64i and 16.64j respectively.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T21:48:28.344630+00:00 | 2026-11-08T22:01:33.847766+00:00 | 785.509416 | 5272 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T21:48:28.344662+00:00 | 2026-11-08T22:00:33.405278+00:00 | 725.066418 | 5272 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T21:48:28.344650+00:00 | 2026-11-08T21:48:30.177281+00:00 | 1.832646 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T21:48:28.347013+00:00 | 2026-11-08T21:48:34.979753+00:00 | 6.632802 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-64h-*` result directories under
`D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64i: Assign readiness kinds to plan resource edges [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Derive each resource-bearing plan edge's required readiness kind from the plan kernel's closed resource
family relation. Tagged mismatches are refused before the probe runs.

#### Deliverables

- Map the six plan resource families to their baseline provider, share, Docker, object-store, registry and
  cluster readiness kinds using the plan kernel's own family keys.
- Apply those kinds to node and project graph descriptors while preserving their ordered key projection.
- Keep untagged compatibility probes open for removal in the following sprint.

#### Validation

On 2026-11-08, 176 focused reconciliation and documentation cases passed. A real provider-network
probe cannot satisfy the provider-responding edge and is refused before it runs. The six baseline
resource-family kinds are derived using the plan kernel's canonical family keys. Both Linux
workspaces build. The WSL2 host used Ubuntu 24.04.5, GHC 9.12.4 and Cabal 3.16.1.0; Linux runs
checked the same 1200-file manifest in both trees. Untagged compatibility probes remain open in
Sprint 16.64l.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T22:08:55.127715+00:00 | 2026-11-08T22:21:14.484690+00:00 | 739.362887 | 5273 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T22:08:55.127796+00:00 | 2026-11-08T22:20:32.639188+00:00 | 697.516967 | 5273 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T22:08:55.127772+00:00 | 2026-11-08T22:08:56.894788+00:00 | 1.767030 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T22:08:55.127749+00:00 | 2026-11-08T22:09:01.713889+00:00 | 6.586193 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-64i-*` result directories under
`D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64j: Retain the exact settled share declaration [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Retain the prepared share call digest in the managed share so a later dependency cannot substitute a
second declaration with the same plan resource key and generation.

#### Deliverables

- The share settlement records the exact prepared call digest alongside the managed handle and receipt.
- Existing share projections, carry and alias operations preserve the retained digest.

#### Validation

On 2026-11-08, 403 focused provider settlement, alias, authority and documentation cases passed.
The managed share retains the exact prepared call digest, including through the existing alias and
carry paths. Both Linux workspaces build. The covered provider change expired Phase 15 evidence;
its complete static and live Incus gate passed, cleanup was verified, and its digest refreshed.
The WSL2 host used Ubuntu 24.04.5, GHC 9.12.4 and Cabal 3.16.1.0; Linux runs checked the same
1200-file manifest in both trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T22:32:56.208978+00:00 | 2026-11-08T22:45:30.922012+00:00 | 754.719073 | 5273 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T22:32:56.208092+00:00 | 2026-11-08T22:44:35.035544+00:00 | 698.833041 | 5273 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T22:32:56.208887+00:00 | 2026-11-08T22:32:57.901041+00:00 | 1.692173 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T22:32:56.217136+00:00 | 2026-11-08T22:33:02.598829+00:00 | 6.381741 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-64j-declaration-*` and `hostbootstrap-15-50i-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64k: Mint a local provider share dependency [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Mint an opaque share dependency from the exact settled provider share and its strong backend, with the
read-only fresh reprobe retained inside it. The owner-serviced runtime route consumes the same capability.

#### Deliverables

- Check backend origin, ownership receipt, prepared share key and generation before minting a dependency.
- Retain the backend's exact fresh reprobe, and use it in the registered share service.
- Preserve the existing guest mount check until alias preparation consumes the new capability.

#### Validation

On 2026-11-08, 361 focused provider, authority and documentation cases passed. The producer accepts
the exact settled declaration, refuses a different prepared declaration for the same share, and the
retained runtime service refuses a missing share without mutation. Both Linux workspaces build. The
covered provider change expired Phase 15 evidence; its complete static and live Incus gate passed,
cleanup was verified, and its digest refreshed. The WSL2 host used Ubuntu 24.04.5, GHC 9.12.4 and
Cabal 3.16.1.0; Linux runs checked the same 1200-file manifest in both trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T23:03:26.194769+00:00 | 2026-11-08T23:15:57.828012+00:00 | 751.639106 | 5273 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T23:03:26.194488+00:00 | 2026-11-08T23:15:24.373059+00:00 | 718.184169 | 5273 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T23:03:26.194767+00:00 | 2026-11-08T23:03:27.901696+00:00 | 1.706942 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T23:03:26.202318+00:00 | 2026-11-08T23:03:32.662306+00:00 | 6.460038 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-64k-*` and `hostbootstrap-15-50j-*` result
directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64l: Reobserve the Incus guest share mount [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Extend the backend-owned Incus share reprobe to verify that the exact guest target remains a writable
virtiofs mount while the same owned instance and share device remain bound.

#### Deliverables

- Reobserve the owned device, query guest mount type and writability through the owned instance, and
  reobserve the device under the same protected entry without attaching or repairing it.
- Refuse missing or wrong mount reports and retain the demo's bidirectional host/guest identity check.

#### Validation

On 2026-11-08 UTC, 599 focused provider, authority and documentation cases passed. The retained
share service accepts an owned writable virtiofs mount and refuses a wrong mount or missing device
without changing the provider or record. The native WSL2 Incus fixture invokes the actual retained
share probe and passed both independently and in the complete phase gate. A first live fixture run
refused its incorrectly named runtime route; the owned VM was absent, the verified intent root was
removed, and the corrected route passed. The covered provider change expired Phase 15 evidence;
its complete static and live gate passed across 2026-11-08 and 2026-11-09 UTC, cleanup was verified,
and its digest refreshed. Both Linux workspaces build, and Linux runs verified the same 1200-file
manifest in both trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-08T23:42:20.955291+00:00 | 2026-11-08T23:53:37.367271+00:00 | 676.417256 | 5273 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-08T23:42:20.955242+00:00 | 2026-11-08T23:53:43.169505+00:00 | 682.219583 | 5273 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-08T23:42:20.955288+00:00 | 2026-11-08T23:42:22.623646+00:00 | 1.668372 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-08T23:42:20.955216+00:00 | 2026-11-08T23:42:27.759639+00:00 | 6.804472 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-64l-*` and `hostbootstrap-15-50k-*` result
directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64m: Retain the local share identity in its dependency [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Retain the exact local managed share inside its opaque dependency so the alias consumer can compare its
backend origin and settled declaration, not only a generic key and generation.

#### Deliverables

- The backend producer retains the exact managed share and its owned fresh reprobe.
- Carried share dependencies preserve their existing recovery behavior.

#### Validation

On 2026-11-09 UTC, 57 focused provider registration, cluster reconciliation and documentation cases
passed. The local constructor retains the exact managed share; the producer's changed-declaration
refusal and the carried recovery route remain covered. Both Linux workspaces build. The covered
provider change expired Phase 15 evidence; its complete static and live Incus gate passed, cleanup
was verified, and its digest refreshed. Linux runs checked the same 1200-file manifest in both trees.

| Command | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` from `core/` | 2026-11-09T00:13:22.713997+00:00 | 2026-11-09T00:25:57.073572+00:00 | 754.365603 | 5273 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-09T00:13:22.714003+00:00 | 2026-11-09T00:25:09.417954+00:00 | 706.709602 | 5273 core and 169 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-09T00:13:22.714518+00:00 | 2026-11-09T00:13:24.572685+00:00 | 1.858181 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-09T00:13:22.730626+00:00 | 2026-11-09T00:13:30.004155+00:00 | 7.273588 | 376 Python cases; 100% coverage; exit 0 |

Artifacts use the `hostbootstrap-16-64m-*` and `hostbootstrap-15-50l-*` result
directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64n: Prepare guest aliases from opaque share dependencies [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Make the node alias route consume the backend-minted share dependency rather than a caller-supplied IO
callback, while retaining the demo's bidirectional host/guest share identity observation.

#### Deliverables

- Verify the dependency's managed identity and use its fresh durable-share probe at alias preparation.
- The demo obtains the dependency from its exact settled share and retains its bidirectional check.
- Existing refusing node routes remain effect-free and cannot take an arbitrary caller probe.

#### Validation

On 2026-11-09 UTC, both workspaces built and the focused alias, compile-fail, and documentation
cases passed (29 cases). The alias cases exercise the real backend-minted dependency, including
refusal of a carried dependency before guest or gate effects; the compile-fail case rejects a raw callback.
The full static gate passed against the same frozen 1,201-file snapshot: `cabal test all` from `core/`
(5,275 cases), `cabal test all` from `demo/` (169 demo and 5,275 core cases),
`poetry run python -m hostbootstrap.check_code`, and `poetry run python -m hostbootstrap.test_all`
(376 cases, 100% coverage). The Phase 15 gate also passed its full core suite and the real Incus/Direct
live provider exercise on WSL2 Linux x86_64 with KVM API 12. Post-run inspection found no remaining
instances or provider-live roots. The result artifacts are under `D:/CodexScratch/hostbootstrap-test-temp/`
with prefixes `hostbootstrap-16-64n-final2-focus-` and `hostbootstrap-15-50m-`.

#### Remaining Work

None.

### Sprint 16.64o: Reserve the dependency probe readiness index [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Give the package-private dependency probe a nominal readiness index while preserving the existing public
compatibility surface, so the remaining producer and snapshot migration can be split into buildable steps.

#### Deliverables

- The internal probe carries a nominal readiness index distinct from its runtime kind term.
- The current public alias fixes that index to a compatibility marker until the typed migration lands.
- Existing tagged and compatibility probes retain their behavior.

#### Validation

On 2026-11-09 UTC, `cabal build all` passed in both `core/` and `demo/`. The complete host static gate
passed on the frozen 1,201-file snapshot: `cabal test all` in `core/` (5,275 cases), `cabal test all`
in `demo/` (169 demo and 5,275 core cases), `poetry run python -m hostbootstrap.check_code`, and
`poetry run python -m hostbootstrap.test_all` (376 cases, 100% coverage). The internal probe tests
exercised both tagged and compatibility observations. Result artifacts use the `hostbootstrap-16-64o-`
prefix under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64p: Preserve readiness indices in dependency snapshots [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Preserve a backend probe's readiness type through the plan probe and snapshot, while retaining the
compatibility bridge until its remaining callers are migrated.

#### Deliverables

- A readiness-indexed dependency probe retains the backend probe's dependency index.
- Snapshot entries and chart preparation accept an indexed probe without erasing its type at the producer.
- Existing compatibility callers and wrong-kind runtime refusal continue to work.

#### Validation

On 2026-11-09 UTC, `cabal build all` passed in both `core/` and `demo/`. The complete host static gate
passed on the frozen 1,201-file snapshot: `cabal test all` in `core/` (5,275 cases), `cabal test all`
in `demo/` (169 demo and 5,275 core cases), `poetry run python -m hostbootstrap.check_code`, and
`poetry run python -m hostbootstrap.test_all` (376 cases, 100% coverage). The suite includes the
wrong-kind chart refusal and backend readiness cases. Result artifacts use the `hostbootstrap-16-64p-`
prefix under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64q: Index the cluster readiness producer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/internal/readiness/HostBootstrap/Readiness/Kernel.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Make a cluster readiness dependency carry its `ClusterApiReady` index through the typed snapshot path.

#### Deliverables

- `clusterReadinessProbe` returns a probe indexed by `ClusterApiReady` while retaining its fresh
  cluster API re-observation and runtime readiness kind.
- The cluster workload route continues to accept and prepare the indexed probe.

#### Validation

On 2026-11-09 UTC, `cabal build all hostbootstrap-core-test` in `core/` and `cabal build all` in
`demo/` passed. The compiled core test binary ran the cluster reconciliation, cluster workload,
authority, and documentation validator groups: 404 cases passed on the frozen 1,201-file snapshot.
The first build exposed a missing marker export; the final builds and focused run above include its fix.
Result artifacts use the `hostbootstrap-16-64q-final-` prefix under
`D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64r: Expose backend readiness marker types [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/readiness/HostBootstrap/Readiness/Kernel.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Make the closed backend readiness marker types nameable by consumers of indexed dependency probes.

#### Deliverables

- All marker types paired with the closed `BackendProbeKey` constructors are exported by the kernel and
  public readiness module without exporting their constructors.
- The sealed export inventory reflects the intended public surface.

#### Validation

On 2026-11-09 UTC, `cabal build all hostbootstrap-core-test` in `core/` and `cabal build all` in
`demo/` passed. The compiled core test binary ran the readiness, authority, and documentation validator
groups: 396 cases passed on the frozen 1,201-file snapshot. Result artifacts use the
`hostbootstrap-16-64r-` prefix under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64s: Index provider dependency producers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Carry the provider responding and durable share readiness indices from the backend-minted dependency
producers through provider and alias preparation.

#### Deliverables

- Running-provider and provider-share dependency probes retain their corresponding readiness index.
- The fresh running-provider handle exposes its responding-indexed probe; provider and alias preparation
  accept indexed probes without dropping the existing compatibility bridge.

#### Validation

On 2026-11-09 UTC, both workspaces built and 367 provider, alias, cluster, and documentation cases
passed. A full core run then found that `ObservedReadyGuestAlias.hs` still expected the old type name;
the fixture continued to reject the unsealed value, and its diagnostic expectation was updated. The
corrected fixture and documentation validator passed (23 cases). The complete Phase 15 gate then passed:
`cabal test all` (5,275 cases) and the live Incus/Direct run (5,275 cases and provider-live PASS) on the
corrected 1,201-file snapshot, followed by a clean resource inspection. Artifacts use the
`hostbootstrap-16-64s-` and `hostbootstrap-15-50n-` prefixes under
`D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64t: Move adversarial probe fixtures behind the package boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`, `core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Keep tests that deliberately supply arbitrary probe behavior able to exercise refusal and freshness cases
without depending on the soon-to-be-removed public wrapper.

#### Deliverables

- Test-only callers use the matching private implementation unit under a test-only module alias.
- Public production modules do not gain a new raw probe constructor.

#### Validation

On 2026-11-09 UTC, `cabal build all hostbootstrap-core-test` in `core/` and `cabal build all` in
`demo/` passed. The compiled core test binary ran the reconciliation, provider, and documentation
validator groups: 416 cases passed on the frozen 1,201-file snapshot. Result artifacts use the
`hostbootstrap-16-64t-` prefix under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64u: Use backend probes in the live provider fixture [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/provider-live/ProviderLiveAliasFixture.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Replace the live fixture's retained constant probes with fresh backend-minted provider and share probes.

#### Deliverables

- Backend exports typed probe projections over its opaque running-provider and share dependencies.
- The live Incus and Direct routes prepare their shares using a running-provider reprobe, and the Incus
  alias uses the settled share's fresh backend reprobe.

#### Validation

On 2026-11-09 UTC, both workspaces and the live fixture built. A focused live Incus/Direct run passed
using the backend-minted probes, and 600 provider, authority, and documentation cases passed. The first
full core run identified an outdated handoff mixin guard from Sprint 16.64t; its expectation was updated
for the explicit private test alias, and that guard plus documentation validation passed (23 cases).
The complete Phase 15 gate then passed `cabal test all` (5,275 cases) and the live Incus/Direct run
(5,275 cases and provider-live PASS) on the corrected 1,201-file snapshot. Post-run inspection found no
instances or provider-live roots. Result artifacts use the `hostbootstrap-16-64u-` and
`hostbootstrap-15-50o-` prefixes under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64v: Seal the public probe boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ImportRawDependencyProbe.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Prevent public callers from wrapping arbitrary IO as a dependency probe after migrating all production and
live-fixture callers to backend-minted evidence.

#### Deliverables

- `HostBootstrap.Reconcile` does not export or define the raw `dependencyProbe` wrapper.
- A compile-fail fixture verifies the missing public export; the sealed export inventory reflects it.

#### Validation

On 2026-11-09 UTC, `cabal build all hostbootstrap-core-test hostbootstrap-provider-live-linux-cpu` in
`core/` and `cabal build all` in `demo/` passed. The compiled core test binary ran compile-fail,
authority, and documentation validation: 360 cases passed on the frozen 1,202-file snapshot. The new
fixture verifies that `HostBootstrap.Reconcile` does not export `dependencyProbe`. The first focused run
caught a sprint-title wording violation; the recorded passing run includes its correction. Result artifacts
use the `hostbootstrap-16-64v-` prefix under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64w: Refuse untagged dependency probes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`, `core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Require every readiness-bearing operation edge to receive a probe tagged with the matching backend kind.

#### Deliverables

- Traversal refuses an untagged probe before running it when an edge requires a readiness kind.
- Adversarial private test probes name the kind required by their fixture, and a refusal case verifies that
  untagged probes cannot prepare an operation.

#### Validation

On 2026-11-09 UTC, `cabal build all hostbootstrap-core-test` in `core/` and `cabal build all` in
`demo/` passed. The compiled core test binary ran reconciliation, provider, and documentation groups:
417 cases passed on the corrected 1,202-file snapshot, including untagged and wrong-kind refusal cases.
The first core build exposed a test fixture return-type ambiguity; the recorded passing build includes its
fix. Result artifacts use the `hostbootstrap-16-64w-` prefix under
`D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64x: Make the public probe type readiness-indexed [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Make the public `DependencyProbe` type name retain the readiness index while keeping the temporary
indexed alias for producer migration.

#### Deliverables

- `DependencyProbe` takes a nominal readiness index and `IndexedDependencyProbe` aliases that type.
- Existing producer and snapshot consumers remain buildable during the remaining migration.

#### Validation

On 2026-11-09 UTC, `cabal build all hostbootstrap-core-test` in `core/` and `cabal build all` in
`demo/` passed. The compiled core test binary ran reconciliation, compile-fail, authority, and
documentation groups: 515 cases passed on the frozen 1,202-file snapshot. The existing compile-fail
fixtures were adapted to the indexed public type. Result artifacts use the `hostbootstrap-16-64x-`
prefix under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64y: Use the indexed public type for plan and cluster probes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Use the final `DependencyProbe` type name for plan, snapshot, chart, and cluster producers, retaining
the temporary alias only for the remaining provider migration.

#### Deliverables

- Plan and cluster producers and snapshot entry points use the readiness-indexed public type directly.
- A compile-fail fixture demonstrates that one readiness index cannot be coerced into another.

#### Validation

On 2026-11-09 UTC, `cabal build all hostbootstrap-core-test` in `core/` and `cabal build all` in
`demo/` passed. The compiled core test binary ran compile-fail, readiness, cluster, authority, and
documentation groups: 440 cases passed on the frozen 1,203-file snapshot. The new fixture asserts the
specific `ClusterApiReady` versus `GpuPluginReady` coercion refusal. Result artifacts use the
`hostbootstrap-16-64y-` prefix under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64z: Use the indexed public type for provider probes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/provider-live/ProviderLiveAliasFixture.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Use the final readiness-indexed `DependencyProbe` type for provider and durable-share producers and
consumers, including the live fixture.

#### Deliverables

- Provider, share, and alias signatures use the final public type name and retain readiness indices.
- The live provider fixture continues to exercise fresh backend probes.

#### Validation

On 2026-11-09 UTC, both workspaces and the live fixture built, and 291 provider, compile-fail, and
documentation cases passed. The complete Phase 15 gate passed `cabal test all` (5,278 cases) and the
live Incus/Direct run (5,278 cases and provider-live PASS) on the frozen 1,203-file snapshot. Post-run
inspection found no instances or provider-live roots. Result artifacts use the `hostbootstrap-16-64z-`
and `hostbootstrap-15-50p-` prefixes under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.64aa: Dependency probes are minted from backend evidence and carry their readiness kind [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`
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

On 2026-11-09 UTC, both workspaces built and 515 focused reconciliation, compile-fail, authority,
and documentation cases passed. The full static gate passed on the frozen 1,203-file snapshot:
`cabal test all` in `core/` (5,278 cases), `cabal test all` in `demo/` (169 demo and 5,278 core cases),
`poetry run python -m hostbootstrap.check_code`, and `poetry run python -m hostbootstrap.test_all`
(376 cases, 100% coverage). The compile-fail suite includes the missing raw wrapper and nominal readiness
coercion checks; the reconciliation suite includes the GPU-versus-cluster and untagged refusals. Result
artifacts use the `hostbootstrap-16-64aa-` prefix under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.65: Refuse kernel release of reported objects [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`, `core/hostbootstrap-core/test/OwnershipShippedSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

Prevent a kernel-owned removal from deleting an object whose record says another authority owns it.

#### Deliverables

- `releaseOwnedObject` refuses `ReportedObject` with `OwnershipMalformed` before any removal or forget.
- A symbolic-link record survives `ShipGiveBackObject` and can be released through its own reported route.

#### Validation

On 2026-11-09 UTC, `cabal build all hostbootstrap-core-test` in `core/` and `cabal build all` in
`demo/` passed. The compiled core test binary ran ownership, shipped ownership, and documentation
groups: 201 cases passed on the frozen 1,203-file snapshot. The new tests verify that a reported
record reaches neither the removal primitive nor the forget continuation and that a symbolic link
survives kernel give-back before its reported give-back succeeds. Result artifacts use the
`hostbootstrap-16-65-` prefix under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.65a: Introduce the reported-claim recording path [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Share clause-2 recording between kernel and reported faces and introduce a claim-only path that existing
owners can adopt in bounded, buildable steps.

#### Deliverables

- A private `recordOrigin` implements the shared clause; kernel recording uses it after capability checks.
- `recordReportedClaim` records only `ReportedObject claim`; the existing compatibility entry remains
  until all callers are migrated.

#### Validation

On 2026-11-09 UTC, both workspaces built. The compiled core test binary ran ownership, shipped ownership,
and documentation groups: 202 cases passed on the corrected 1,203-file snapshot. The new claim-only
case checks the reported kind; the lifetime test also exercises the new entry after session expiration.
The first focused runs exposed a shared-path source guard and its action count, both updated to cover the
new entry. Result artifacts use the `hostbootstrap-16-65a-` prefix under
`D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.65b: Migrate cluster and Colima reported claims [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Route cluster and Colima reported records through the claim-only entry without changing their claims.

#### Deliverables

- Cluster and Colima callers supply their existing owner claims directly.
- Existing ownership and lifecycle behavior remains unchanged.

#### Validation

On 2026-11-09 UTC, `cabal build all hostbootstrap-core-test` in `core/` and `cabal build all` in
`demo/` passed. The compiled core test binary ran cluster, Colima, ownership, and documentation groups:
628 cases passed on the frozen 1,203-file snapshot. Result artifacts use the `hostbootstrap-16-65b-`
prefix under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.65c: Migrate shipped and provider reported claims [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Route shipped symbolic-link and provider reported records through the claim-only entry while retaining
their exact existing claims.

#### Deliverables

- Shipped and provider owners pass their existing claims directly to the claim-only recorder.
- Existing ownership and provider lifecycle behavior remains unchanged.

#### Validation

On 2026-11-09 UTC, both workspaces and the live fixture built, and 780 ownership, provider, authority,
and documentation cases passed. The complete Phase 15 gate passed `cabal test all` (5,281 cases) and
the live Incus/Direct run (5,281 cases and provider-live PASS) on the frozen 1,203-file snapshot.
Post-run inspection found no instances or provider-live roots. The sealed export inventory was updated to
include the temporary claim-only entry. Result artifacts use the `hostbootstrap-16-65c-` and
`hostbootstrap-15-50q-` prefixes under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.65d: Restrict the reported-origin entry to claims [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/GuestVm.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

Make `recordReportedOrigin` accept only an owner claim, with a temporary claim-only alias for callers
still migrating to the final name. The guest VM owner is an additional production caller discovered in the
tree and must migrate before the signature changes.

#### Deliverables

- `recordReportedOrigin` records only `ReportedObject claim` through the shared private clause.
- The guest VM owner and reported-face tests pass existing claims; the temporary alias remains claim-only.

#### Validation

On 2026-11-09 UTC, both workspaces and the live fixture built, and 780 focused ownership, provider,
authority, and documentation cases passed. The initial full core run found that the new compile-fail
expectation omitted the qualified claim type; the corrected fixture and documentation checks passed
(23 cases). The complete Phase 15 gate then passed `cabal test all` (5,282 cases) and the live
Incus/Direct run (5,282 cases and provider-live PASS) on the corrected 1,204-file snapshot. Post-run
inspection found no instances or provider-live roots. Result artifacts use the `hostbootstrap-16-65d-`
and `hostbootstrap-15-50r-` prefixes under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.65e: Adopt the final reported-origin name in local owners [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`
**Substrates**: linux-cpu
**Docs to update**: None.

#### Objective

Use the final claim-only `recordReportedOrigin` name in the cluster, Colima, and shipped owners.

#### Deliverables

- These owners retain the same claims and use the final recorder directly.
- Provider owners continue to use the equivalent temporary claim-only alias until the next sprint.

#### Validation

On 2026-11-09 UTC, `cabal build all hostbootstrap-core-test` in `core/` and `cabal build all` in
`demo/` passed. The compiled core test binary ran cluster, Colima, shipped ownership, and documentation
groups: 612 cases passed on the frozen 1,204-file snapshot. Result artifacts use the `hostbootstrap-16-65e-`
prefix under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.65f: The reported face records only a reported object [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/GuestVm.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
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

On 2026-11-09 UTC, both workspaces and the provider-live fixture built; 781 focused ownership,
provider, authority, compile-fail, and documentation cases passed. `cabal test all --ghc-options=-Werror`
from `core/` passed all 5,282 cases on the final 1,204-file snapshot, including the explicit shared-clause
guard. The complete Phase 15 core and live Incus/Direct gate passed on the preceding snapshot, whose only
subsequent change strengthens that test assertion; post-run inspection found no instances or provider-live
roots. Result artifacts use the `hostbootstrap-16-65f-` and `hostbootstrap-15-50s-` prefixes under
`D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.66: The Colima report classifiers check every name they return [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Report.hs`,
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

On 2026-11-09 UTC, both workspaces built and 670 Colima, authority, and documentation cases passed.
`cabal test all` from `core/` passed all 5,282 cases on the frozen 1,204-file snapshot. The classifier
cases cover empty, whitespace-containing, and overlong Docker context names, and the raw Colima JSONL
case uses `classifyColimaListing`. Result artifacts use the `hostbootstrap-16-66-` prefix under
`D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.67: Refresh the composed cluster phase gate [Done]

**Status**: Done
**Implementation**: none; this sprint reruns the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh phase 16 evidence after the completed lifecycle, readiness, ownership, and classifier changes.

#### Deliverables

- Run the declared core test and live Kind cluster gate together on a linux-cpu host.
- Record the gate environment, outcome, cleanup, and covered-path digest.

#### Validation

On 2026-11-09 UTC, the composed gate ran on Ubuntu 24.04.5 x86_64 under WSL2 with Linux
6.18.54.1-microsoft-standard-WSL2, Docker 29.9.3, Kind 0.32.0, kubectl 1.37.0, Kubernetes 1.36.1,
Helm 4.3.1, GHC 9.12.4, and Cabal 3.16.1.0. Starting at 2026-11-09T07:25:31.671073+00:00 and ending at
2026-11-09T07:39:43.917999+00:00, it completed in 852.254 seconds with exit 0. `cabal test all`
from `core/` passed 5,282 cases; the bare core binary's `hostbootstrap test run cluster-live` passed its
linux-cpu case. The run created `hostbootstrap-test-run-34a0ecafc976`, observed its cluster read-only,
refused mismatched generations without mutation, and verified node-container absence and the durable
sentinel after teardown. A separate post-run inspection confirmed the labelled node and both exposure
containers absent. The canonical covered-path digest is `015be233a1ca7be5595fb932e0e1c8b7aeab308803f997930aeed628824d8549`. Result artifacts use the
`hostbootstrap-16-composed-gate-`, `hostbootstrap-16-gate-cleanup-`, and `hostbootstrap-16-gate-digest-`
prefixes under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 16.68: Re-run the composed cluster phase gate after covered-path expiry [Done]

**Status**: Done
**Implementation**: none; this sprint reruns the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Restore the completion evidence that Sprint 17.10's edit of `hostbootstrap-core.cabal`, a path in this phase's
`**Evidence covers**` set, expired. This is evidence expiry under § C, not a design-error reopening.

#### Deliverables

- Run the declared core test and live Kind cluster gate together on a linux-cpu host.
- Re-record the gate environment, outcome, cleanup, and covered-path digest, and set the phase `Done`.

#### Validation

On 2026-11-10 UTC the composed gate ran on Ubuntu 24.04.5 x86_64 under WSL2 (the `hostbootstrap-linux-d` distribution)
with Linux 6.18.54.1-microsoft-standard-WSL2, Docker 29.9.3, Kind 0.32.0, kubectl v1.36.3 (client) against a
Kubernetes v1.36.1 server, Helm 4.3.1, GHC 9.12.4, and Cabal 3.16.1.0. The static half, `cabal test all` from `core/`,
passed 5,336 of 5,336 in 6,787 seconds (after the first run's 5,334 of 5,336 was traced to the
`RecoveryInterruptionSpec` five-second sentinel bound on this virtualized host, which now waits up to a minute). The
live half, the bare core binary's `hostbootstrap test run cluster-live`, ran from 2026-11-10T09:06:57-05:00 to
09:09:51-05:00: it created a fresh Harness-owned Kind cluster, observed it read-only (`ClusterStatusPresent`, records
and containers unchanged), deleted it through the retained plan, observed it absent (`ClusterStatusAbsent`), and
reported `1/1 passed`; `kind get clusters` then listed none. Two earlier live attempts are not counted: the first
passed `cluster-live` but its teardown could not verify because the binary had no installed handoff identity (the
direct `cabal build` skipped the `--hostbootstrap-install-identity` step the bootstrapper runs after every build) and
leaked one run-scoped cluster, which was deleted; the second found no Docker daemon because the distribution had idled
down. Docker was started as root for the run inside this dedicated distribution only and stopped afterwards. The
canonical covered-path digest is recorded in the `**Gate evidence**` row.

#### Remaining Work

None.

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

None.

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
