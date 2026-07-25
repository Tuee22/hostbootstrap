# Phase 18: Service runtime command

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-16-project-lifecycle-command.md](phase-16-project-lifecycle-command.md)

> **Purpose**: Add the third DSL-driven core command — `service` — that runs a project's long-running
> roles (the `HostDaemon`/service run-model) through a fixed `service init|schema|run` surface, a project-
> contributed service ADT and internal handler registry, leaf-frame fail-fast gating, and dynamically
> rendered ConfigMap-delivered service config.

## Phase Status

**Status**: Active

`service` is **new core scope** — there had never been a `service` command; the demo's long-running web
workload previously ran through the load-bearing `web serve` verb. The fixed command can dispatch a
project-supplied registry key; current core does not prove that arbitrary selector output corresponds to
a service ADT value or capability (development_plan_standards § AA).

The implementation is built and has dated static validation evidence:

- `HostBootstrap.Service` ships the possibly empty `ServiceRegistry` of internal handler keys and actions.
  `HostBootstrap.CLI` threads it through `ProjectSpec` with `withServices`, rejects duplicate keys, and
  independently carries the config-specific selector with `withServiceConfig` / `psServiceVariant`.
- `HostBootstrap.Command.serviceCommandGroup` surfaces the fixed `service init|schema|run` tree. There is
  no `service down` and no positional variant argument: `service run` gates as
  `Context.ServiceCommand`, asks the effective project config for its selected variant, and dispatches that
  internal key through the registry. The selector is an arbitrary function; the required capability list
  is empty, and core can dispatch a config type with no service field. Both demo handlers then reload the
  sibling config: the Web reload alone asks `validateContext` for `[DurableStore]`, while the accelerator
  reload again asks for no capability, so capability checks and config identity differ by handler and
  read.
- The demo owns the real Dhall service model:
  `ServiceType = < Web : WebServiceConfig | Accelerator : AcceleratorServiceConfig >`, stored as the
  mandatory `service : Optional ServiceType` project-config field. `Web` carries distinct public and
  accelerator ports; `Accelerator` carries its request timeout. `configuredServiceVariant` maps those
  payload-bearing constructors to the internal registry keys and validates their placement.
- `demo/src/HostBootstrapDemo/Commands.hs` renders each parent-derived service config and its ConfigMap
  manifest at deployment time. Helm receives the current frame, exact config-byte hash, and placement;
  the hash annotation rolls the pod whenever the mounted bytes change. There is no static chart ConfigMap.
- The web role binds linked public and private listeners: public HTTP uses its configured port (default
  8080) behind NodePort 30080;
  accelerator WebSocket traffic uses the configured distinct port (default 8081) through a cluster-only
  Service or a local-only NodePort 30081.
  Registration is unavailable on the public listener, and the private listener rejects browser-originated
  registration. A process-local accelerator hub requires exactly one web replica and preserves an active
  request when a concurrent request receives the single-flight 503 response. `Recreate` rollouts prevent
  temporary peer overlap, and daemon connection readiness is explicit for both pod and host placement.
- The accelerator daemon keeps a serialized, persistent newline-delimited worker session, restarts it once
  after a worker failure, and clears it on request timeout. Worker arithmetic is semantically `Float32`
  across Haskell, Swift, C++, and CUDA; CBOR float64 is only the transport carrier. CUDA failures surface
  as failures rather than fabricated results.

Historical live evidence remains valid for the behavior it exercised: on 2026-06-19 the then-current
three-argument web entrypoint (`service run web`) served HTTP 200 at `localhost:30080` on the 16 GiB
Apple-Silicon host ([phase-13](phase-13-hostbootstrap-demo.md)) while reading its ConfigMap-mounted config.
That evidence predates the current config-selected two-argument entrypoint and the accelerator matrix; it
is not a live validation claim for the current four-lane accelerator gate.

**Reopened 2026-07-09 for the accelerator daemon runtime.** The protocol, concrete socket path, dynamic
configuration, two-listener web boundary, and persistent real-worker supervision are implemented and
covered by static/local tests. The cross-substrate live gates below remain open, so the phase stays Active.

**Reopened 2026-07-24 for validated service selection and immutable dispatch.** `service schema` is
encoder-declared, not decoder-reflected. `service run` selects from one config decode, but the demo
handlers reload the sibling file; selector/config/registry agreement is convention rather than a typed
relation; service projection invents fallback values; and a missing service config incorrectly points to
root `project init`. Blocked Sprint 18.6 owns the repair with Sprints 14.6, 15.9, 17.4, and 19.8.

## Remaining Work

**Accelerator daemon live-runtime closure — open.** Static and local validation, including the browser
workflow specification and guarded real-worker cases, is implemented. Completion still requires:

- real socket integration through the in-cluster `ClusterIP` and host-daemon local-only `NodePort` paths;
- the browser Add workflow against those live deployments, proving the result and metadata came from the
  selected JIT-built worker rather than from the web process; and
- the three still-open native substrate/placement lanes: Apple Silicon host daemon, Linux CPU
  in-cluster daemon, and Linux GPU direct nvkind/in-cluster daemon. On each lane the harness runs four
  cases across two message variants, so the required result is `8/8`.

The Windows GPU host-daemon lane is closed by the dated 2026-07-23 Windows/WSL2 `8/8` run, which exercised
the host worker, CBOR WebSocket path, browser result, and backend/artifact metadata. Windows is not part of
this phase's remaining work.

**Validated service dispatch — blocked (Sprint 18.6).** Replace arbitrary string selection and
double-read handlers with a config/frame/registry-indexed existential `SelectedService` package, exact
service authority, one immutable config-derived role payload, and command-specific missing-config
recovery guidance. The handler receives only
`RoleParams specDigest configId secretDigest fields service` from an opaque config-bound request bundle
through a closed
`ServiceProgram`, not the full config or raw `IO`; the selected service also proves that the program's
exact effect row is authorized.

## Phase Objective

Provide a generic, fixed `service` command on the core tree so every project binary runs its long-running
roles uniformly: `service init` / `service schema` / `service run`. The target jointly derives an opaque
selected-service package from one child-locally verified mounted role wire/request (projected from one
parent validated config), compatible
leaf frame, exact runtime authority, and finalized project-owned typed registry. Only the matching
role-specific parameter payload reaches the handler. Deployment config is delivered by a dynamically rendered
ConfigMap that overrides the image's baked container `<project>.dhall`. There is no `service down`: the
leaf process may run in a Kubernetes pod or as a host daemon, and its enclosing controller or project
lifecycle owns teardown (§ Y).

For the accelerator reopening, extend that surface with a daemon variant that connects to the web service
instead of serving HTTP itself. The daemon is still a leaf role: it performs no cluster bring-up and no
project lifecycle work.

## Sprints

### Sprint 18.1: The `service init|schema|run` command surface [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs` (`serviceCommandGroup`), `core/hostbootstrap-core/src/HostBootstrap/Service.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Docs to update**: `documents/architecture/run_models.md`, `README.md`

#### Objective

Put `service` on the fixed core tree (`project` / `test` / `service` / `context` / `check-code`) so every
project binary inherits it.

#### Deliverables

- `service init` writes a service-configured `<project>.dhall` from passed parameters (forwarded from a
  parent where applicable, § X); `service schema` prints the `ToDhall` encoder-declared project config
  schema; `service run` invokes the registry key returned by the current selector. No `service down`.
- `service run` is a **leaf-frame runtime command, never an orchestrator**: it assumes it is already placed
  in its frame (a k8s pod or host daemon) and runs the role; it brings up no VM or cluster.

#### Validation

- The core CLI spec asserts `service` is present on every binary, selector/lookup failures return
  non-zero, and there is no `service down` subcommand. It does not prove every `cfg` has a service ADT or
  that a constant selector is related to config.

#### Remaining Work

None. `serviceCommandGroup` surfaces `service init|schema|run` (no `service down`); `service run` gates as
  `Context.ServiceCommand` and applies a leaf primary-kind check. `CLISpec` covers that refusal and
  encoder-declared `service schema`; it does not establish service-field/capability/selector relations.
  The 2026-06-19 demo run is historical live evidence for the
pre-selector web form of the command ([phase-13](phase-13-hostbootstrap-demo.md)); current live matrix
closure is tracked by Sprint 18.5.

### Sprint 18.2: The `ServiceType` ADT and service-handler registry [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`, `core/hostbootstrap-core/src/HostBootstrap/CLI.hs` (`withServices`, `withServiceConfig`), `core/hostbootstrap-core/test/CLISpec.hs`, `demo/src/HostBootstrapDemo/Config.hs`, `demo/app/Main.hs`
**Docs to update**: `documents/architecture/library_hierarchy.md`, `system-components.md`

#### Objective

Let a binary define **more than one** payload-bearing service type and have `service run` dispatch the
variant selected by its effective config.

#### Deliverables

- A project contributes a possibly empty internal handler **registry** through `withServices` and an
  arbitrary config-to-string selector through `withServiceConfig` / `psServiceVariant`. The demo selector
  validates its own Dhall ADT by convention; core does not enforce that relation. The registry itself is
  not the Dhall ADT.
- The demo's real model is
  `ServiceType = < Web : WebServiceConfig | Accelerator : AcceleratorServiceConfig >`. The Web payload
  carries `publicPort` and `acceleratorPort`; the Accelerator payload carries `requestTimeoutSeconds`.
  `ProjectConfig.service` is a mandatory field whose value is optional so non-service frames remain
  representable.
- The registry may be empty — the fixed surface is unchanged and `service run` fails fast when no service
  is selected or no handler matches the selected key, so not every project ships a service.

#### Validation

- The CLI and demo specs assert config-selected dispatch over multiple variants, no positional variant
  argument, an empty registry that still exposes `service` but fails fast, payload/placement validation,
  and an unknown selected key exiting non-zero.

#### Remaining Work

None in the historical registry/selector landing. The distinct registry and arbitrary selector seams,
the real payload-bearing demo ADT, duplicate-key rejection, demo placement validation, and string-key
dispatch are built. Sprint 18.5 owns live placement evidence; Sprint 18.6 owns making the relation
unforgeable.

### Sprint 18.3: Leaf-frame gating and ConfigMap-delivered config [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `demo/src/HostBootstrapDemo/Commands.hs`, `demo/chart/templates/deployment.yaml`
**Docs to update**: `documents/architecture/binary_context_config.md`, `documents/engineering/cluster_lifecycle.md`

#### Objective

Gate `service run` to a service-role frame and deliver its config the binary-context way.

#### Deliverables

- The demo `service run` path fails fast when its selector rejects the effective config or registry lookup,
  and core checks a `ClusterService`/`Daemon` primary kind. Core does not require a service field or
  service-specific capability; Sprint 18.6 owns that exact relation.
- `project up`'s `deploy-chart` step deploys the pod whose entrypoint is `service run`; the pod's config
  arrives as a **dynamically rendered ConfigMap overriding the image's baked container
  `<project>.dhall`** (§ X). The deployer hashes the exact mounted bytes into the pod template annotation.
  `project up` *deploys* the service; `service run` *is* the service.

#### Validation

- A non-service-role config is refused; manifest tests prove that the chart pod runs `service run`, reads
  the generated ConfigMap, and rolls when the exact config bytes change. The earlier web-only delivery
  path was exercised in the historical demo run.

#### Remaining Work

None for the historical demo delivery implementation. `service run` refuses a non-leaf primary kind and
the demo selector rejects its invalid placements; the deployer renders the current full-record
parent-derived service config and ConfigMap, applies it, and passes Helm only the current frame,
config-byte hash, and placement. The chart args are `service run` with no positional variant. The
2026-06-19 web run remains historical evidence for mounted-config behavior; current live closure belongs
to Sprint 18.5.

### Sprint 18.4: Demo web role on config-selected `service run` [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`demoServices`), `demo/app/Main.hs` (`withServices`), `demo/chart/templates/deployment.yaml`, `demo/docker/Dockerfile`
**Docs to update**: `documents/operations/demo_runbook.md`, `README.md`

#### Objective

Run the demo's long-running web workload through the generic command and select its payload-bearing `Web`
constructor from the effective project config.

#### Deliverables

- `web serve` → `service run`, with `withServiceConfig` selecting `Web` and `withServices` resolving the
  internal `web` handler key; `web bridge` → the build-image chain step. The demo chart pod's entrypoint is
  `service run`, and its generated config selects the Web payload.

#### Validation

- Static manifest/CLI tests cover the current config-selected path. Historical live evidence proves the
  migrated web handler served HTTP 200 on the NodePort before the selector replaced the positional key
  ([phase-13](phase-13-hostbootstrap-demo.md)).

#### Remaining Work

None. The `web` verb is removed; `runVmBootstrap` generates the PureScript bridge before image build;
`demo/app/Main.hs` installs both the handler registry and config selector; and the chart args are
`["service", "run"]`. The current path is statically validated. The 2026-06-19 HTTP 200 run is retained as
explicitly historical evidence, not as current matrix closure.

### Sprint 18.5: Accelerator daemon runtime over CBOR WebSocket [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `demo/src/HostBootstrapDemo/Web/Server.hs`,
`demo/src/HostBootstrapDemo/Accelerator/Protocol.hs`,
`demo/src/HostBootstrapDemo/Accelerator/Daemon.hs`, `demo/test/WebServerSpec.hs`,
`demo/test/AcceleratorRuntimeSpec.hs`
**Docs to update**: `documents/architecture/run_models.md`,
`documents/architecture/binary_context_config.md`, `documents/engineering/accelerator_daemon.md`

#### Objective

Add the accelerator daemon as a config-selected long-running service/daemon role that connects to the
web server's private listener over CBOR WebSocket and forwards add requests to a persistent JIT-built
worker session.

#### Deliverables

- A payload-bearing `Accelerator` config value projected to the daemon handler through the fixed service
  registry, with `requestTimeoutSeconds` supplied by config rather than a positional CLI argument.
- CBOR request/result/failure codecs with request-id correlation.
- Separate linked web listeners: public application HTTP and private accelerator registration, with
  distinct ports, Origin rejection on the private path, and no registration route on the public path.
- WebSocket client loop with reconnect, configured request timeout, graceful shutdown, and backend/artifact
  metadata in replies. Idle socket lifetime is independent of the per-request worker timeout.
- Serialized persistent worker sessions used after Phase 13's substrate-specific JIT build, with
  newline-delimited request/reply framing, one restart after worker failure, timeout cleanup, and
  end-to-end `Float32` arithmetic semantics.
- Gate config-selected `service run` to daemon/service contexts only.

#### Validation

- Unit tests for CBOR codec round trips, invalid payload rejection, request correlation, single-flight
  contention, listener isolation, worker-session reuse/restart/timeout, precision, and no in-process web
  fallback.
- Integration tests for in-cluster daemon connection by `ClusterIP` and host daemon connection by
  local-only `NodePort`.
- Browser e2e add test asserts the sum and daemon-returned backend/artifact metadata.

#### Remaining Work

The implementation has dated static/local validation evidence. The effective config selects
`Accelerator`; the existing `Context.ServiceCommand` gate rejects
project-lifecycle authority; the dynamic manifest supplies the placement-specific connection target and
timeout; and deterministic CBOR codecs preserve request IDs, metadata, and failures. The web process owns
a single-flight hub on its private listener but never computes the sum itself. Public and private ports are
separate, the private path rejects Origin-bearing clients, linked listener failures terminate the role,
and process-local hub state is guarded by an exact-one-replica invariant.

The daemon keeps one serialized worker process per session, communicates over newline-delimited standard
input/output, reuses a healthy worker, retries once after a worker crash or protocol failure, and clears
the worker on timeout or shutdown. The configured request timeout applies to worker requests, not idle
WebSocket connectivity. Haskell, Swift, C++, and CUDA workers implement `Float32` semantics; CBOR's
float64 value is only the protocol carrier, and CUDA/runtime errors are returned as failures. Static tests
cover precision, persistence, recovery, listener isolation, contention, generated manifests, and the
guarded real-worker/browser workflows.

Historical local-worker evidence is retained: on 2026-07-10 the guarded `AcceleratorRuntimeSpec` built
the CUDA worker on the RTX 3090 with `nvcc -ccbin <msvc>` and returned `Right 3.75` (the then-current gate
reported 46 demo tests). That proves the native worker path used in that run; it is not a live daemon
socket, lifecycle, or browser-matrix result.

The phase remains Active only for native Apple Silicon host-daemon and Linux CPU/GPU in-cluster real
socket/browser closure. The Windows GPU host-daemon lane closed on the dated 2026-07-23 `8/8` run; that
result does not stand in for any of the three remaining native lanes.

### Sprint 18.6: Typed selected-service package and immutable handler input [Blocked]

**Status**: Blocked
**Blocked by**: Sprints 14.6, 15.9, 17.4, and 19.8
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Fields.hs` (introduced by Sprint 19.8),
`demo/hostbootstrap-demo.cabal`,
`demo/app/Main.hs`,
`demo/src/HostBootstrapDemo/Config.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Web/Server.hs`,
`demo/src/HostBootstrapDemo/Accelerator/Daemon.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/ServiceSpec.hs` (new),
`demo/test/ConfigSpec.hs`,
`demo/test/WebServerSpec.hs`,
`demo/test/AcceleratorSpec.hs`,
`core/hostbootstrap-core/test/Spec.hs`
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/hostbootstrap_core_library.md`,
`documents/engineering/config_generation.md`, `documents/engineering/schema.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Make service selection a validated relation among one immutable verified role-wire snapshot, exact leaf placement,
runtime authority, and the finalized typed handler registry. A caller cannot separate or mismatch a
service identity, its role-specific parameters, and its handler, or execute a package under different
config bytes.

#### Deliverables

- Consume Phase 19.8's removal of raw `psServiceVariant :: cfg -> Either String String` from the finalized
  specification. Phase 19.8 jointly finalizes the hidden
  field schema, `specDigest`, full `ProjectCodec`, role-wire
  `RoleCodec scope specDigest fields`, and typed registry. The parent
  can render only `RuntimeRoleWire fields service`; it cannot serialize a request or parameters. At
  runtime, `withVerifiedRuntimeRoleWire` consumes the
  rollout-revision/workload-instance/spec/binary/config/secret/service/effect-bound
  `VerifiedRuntimeRoleActivation`, matching finalized runtime spec, internally verified scope-specific
  secret bundle, and actual mounted bytes, then
  produces `ValidatedServiceRequest specDigest configId secretDigest fields service` with a fresh
  child-local `configId`. Production wires contain pointers; Harness wires contain only typed secret
  handles and use a separate run-scoped private bundle. The Kubernetes Secret/private OS channel is the
  sole secret-bearing runtime payload; no cleartext fixture enters the non-secret ConfigMap, pod
  template, signed activation manifest, envelope view, log, or diagnostic. The request and its
  `RoleParams specDigest configId secretDigest fields service` are one opaque, inseparable bundle.
  Phase 19.8's schema builder assigns every field a closed `VisibleTo consumers` set covering framework
  validation, typed plan frames, Harness assembly, and `Service service`; only the exact role projection
  can cross the boundary and only the selected-service filter can construct handler parameters.
- Make admission and old-instance recovery explicit typed gates. `verifyRolePlanDraft` validates the
  non-empty role draft and signed `rolePlanDigest` before durable mutation.
  `withRoleLifecycleAdmission` is the only protected producer of
  `RoleLifecycleAdmission ... planId configId ... invocationId admissionKey admissionVersion`; it
  atomically reserves the first journal version and mints the rank-2 `planId`/`invocationId`.
  `admissionKey` is stable for the verified activation/request/draft and has only Reserved→Consumed
  phases. A lost reservation acknowledgment yields `RoleLifecycleAdmissionUnknown`; the same opener or
  `resumeRoleLifecycleAdmissionUnknown` rehydrates the stored identities, and concurrent tokens have one
  plan-construction CAS winner. Commit-before-cursor-delivery yields `RolePlanOpenUnknown`, whose sole
  resume gate rehydrates that exact consumed plan/invocation/cursor. The live instance's own Reserved or
  Consumed row is never predecessor recovery.
  `withRuntimeRolePlan` must linearly consume that exact admission and `VerifiedRolePlanDraft`, is fixed
  to its `planId`, and has no raw-draft validation failure after reservation.

  Before admitting a new instance, enumerate the complete predecessor set for a stable
  `RolePlacementKey`. Its `VerifiedOldRoleInstanceManifest` retains each member's full old
  plan/spec/binary/config/secret/role-plan/effect-ceiling, local
  plan/config/revision/instance/invocation/journal/resource lineage; never index old recovery by the new
  rollout's digests. A non-empty set yields only `RoleLifecycleRecoveryRequired`.
  `recoverRoleLifecycle` performs an exact-set fold, rejects missing/duplicate/extra/substituted members,
  and returns either full-new-lineage unknown state or one `SettledRoleLifecycleRecovery` containing
  same-new-lineage `RecoveredRoleInstanceSet` plus `RoleRecoveryClearance`.
  `resumeRoleLifecycleRecoveryUnknown` is the unknown's sole consumer and re-probes the same key into
  another exhaustive advance; neither branch can pair with another service/plan/config/effect lineage.
  Each member requires authoritative `VerifiedRoleInstanceNonLive`, revalidated
  by the final CAS. Non-exclusive live overlap remains legal and excluded from recovery; only
  authoritatively non-live incomplete/unclean members are settled. A live exclusive predecessor yields
  Busy/Conflict or liveness Unknown without recovery authority. An exclusive successor requires
  `ServiceLeaseTransferBarrier ... predecessorFenceSet newFence transferVersion` covering every old
  prepared/in-flight attempt through backend fencing or retained-lock settlement; no-exclusive
  predecessors require `VerifiedNoServiceLeaseTransfer` for the whole set.
  `resumeRoleLifecycleAdmission` consumes that settled package, atomically closes all recovered
  invocations, and reserves the new admission. Kill/lost-ack resumes the same stable key and can never
  expose a new plan, cursor, or lease early.
- Construct one internal existential
  `SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase
  fields`
  containing the matching
  `ServiceSelection scope specDigest planId configId secretDigest frame revision instanceId ServePhase
  service effects`,
  request/parameters, and closed `ServiceProgram`. Its constructor/projections do not let callers
  substitute one member independently. The package is never handed to an arbitrary callback: sole
  `selectAndRunService` jointly consumes the exact request, role plan/`RolePlanDigestBinding`, current
  Serve cursor/context, identity-indexed `ReadyServiceHandles`, retained receipt/lease package, inseparable
  activation/projection package, compatible `VerifiedServicePlacement`, and finalized runtime spec. It
  looks up the exact typed handler/effect row, proves that row through `EffectAuthorization`, requires an
  opaque `DurablePlacementAuthority` for `DurableStore`, and atomically transfers a private
  `ServiceCommandAuthority scope specDigest planId configId secretDigest frame revision instanceId
  ServePhase service effects` into the package before interpreting it under core-owned masking. A separable/raw
  `RuntimeActivationAuthority`, decoded context placement label, and generic lifecycle
  `CommandAuthority` are not service dispatch authority. An explicitly empty registry produces a typed
  selection failure and the same Drain transition.
- `ServiceProgram` is a closed capability-indexed program with no public `IO`/`MonadIO`, arbitrary
  filesystem, or config-read constructor. Core interprets only the finalized service's authorized
  network/durable-store/process effect row; a project adds an effect through the typed interpreter seam,
  never by embedding raw `IO`. The row is not mutation authority: each mutating
  store/process/backend constructor first becomes an opaque
  `SealedServiceEffectCall ... effect ... targetId operationKey callDigest` carrying the exact target and
  arguments; adapters accept no separate raw request. Private prepare consumes that call, the exact
  `ServiceEffectReady` session, and whole retained package. Success yields
  `PreparedServiceEffect ... targetId operationKey callDigest fence attempt journalVersion` carrying the
  call/package. Known prepare rejection yields only
  `ServiceEffectPrepareFailed effect targetId operationKey callDigest fence attempt`; uncertain journal
  commit yields only `ServiceEffectPrepareUnknown ...`. Both private failure branches return the successor
  session and whole retained package directly to Serve→Drain/recovery, and neither state can normally
  prepare.
  The backend consumes the prepared value and returns
  `ServiceEffectAdvance ... targetId operationKey callDigest ... fromJournalVersion nextJournalVersion
  nextEffectState`. Its private eliminator exposes `ServiceEffectOutcome nextEffectState` only with the sole successor service-journal
  session under the unchanged effect row/phase and the reconstituted whole retained receipt/lease
  package. Observed outcomes yield `ServiceEffectReady`; unknown yields
  `ServiceEffectUnknown effect targetId operationKey callDigest fence attempt`, which no normal prepare
  accepts until same-key/fence reprobe produces an observed resolution or indexed
  `VerifiedSameKeyRetry ... configId secretDigest ... service effects phase effect invocationId sessionId
  targetId operationKey callDigest fence previousAttempt nextAttempt unknownJournalVersion
  retryJournalVersion`. Private `resumeVerifiedSameKeyRetry` consumes that exact Unknown session, full
  proof, and package and feeds the Ready successor plus reconstructed sealed call only back into the same
  interpreter. Another target/call, config, secret bundle, row, phase, invocation, session, or journal
  version cannot cross-pair; there is no caller-selectable Unknown→Ready conversion. This includes
  crash-after-call-before-ack. The prepared
  value can be minted only from the exact prior session and live
  `ServiceGenerationLease ... fence` inseparably retained with receipts; the no-exclusive-effects branch
  exists only when the signed placement ceiling prohibits every exclusive/mutating effect and therefore
  cannot authorize mutation. Registry selection must prove its exact row is within that same ceiling.
- Pass only the packaged `RoleParams specDigest configId secretDigest fields service` to the handler. Remove sibling-file reloads
  from Web/accelerator handlers; file replacement after dispatch cannot change parameters, role, or
  authority within that invocation, and the full `ValidatedConfig ... cfg` never crosses the
  child-wire or handler boundary.
- Give service/daemon leaves role-specific parameter types projected without fallback literals.
  Configured Web ports and accelerator timeout originate in the sole project assembler; host
  Dockerfile/VM/deploy fields and the other role's optional payload cannot reach the selected handler.
- Require the precise service/runtime-activation authority and complete placement witness set, not an
  empty capability requirement plus a string selector. Derive required durable-store/network/process
  capabilities from the authorized `effects` row and verified placement, so a handler cannot request or
  execute an effect absent from its `ServiceSelection` proof. Network/process Serve operations can use
  only handles acquired and successfully probed by Sprint 14.6; no handler-visible late bind/spawn can
  race readiness. The accelerator's restartable worker uses a stable ready supervisor handle. Its one
  allowed restart is a core-owned journal-prepared transition whose successor child must pass readiness
  before another request is routed.
- Make execution a mandatory lifecycle advance. Selection rejection, handler completion or typed
  failure, catchable controller shutdown, and caught interruption all return only
  `RoleAdvance ... ServePhase DrainPhase ServiceDispatchResult`; its
  private eliminator yields the result together with the sole Drain cursor and retained resource/lease
  package. Drain consumes both, attempts every independent release even after one fails, and returns
  `RoleAdvance ... DrainPhase ExitPhase DrainResult` whose eliminator yields the aggregate outcome with
  the sole Exit cursor. The masked core-owned run-to-Exit operation is the only public runner; no bare
  `Either`, phase eliminator, or arbitrary callback can capture/drop receipts. Uncatchable process death
  is handled by the typed exact-set predecessor-manifest recovery transition over durable lifecycle
  admission/receipt/lease/journal state.
  Rolling non-exclusive revisions/instances may overlap; cross-instance replay fails, and the retained
  fenced `ServiceGenerationLease` prevents old exclusive/mutating operations after transfer. The
  successor lease is published only when `ServiceLeaseTransferBarrier` proves an atomic backend fence
  or retained-lock barrier has settled or authoritatively fenced every prepared/in-flight old attempt
  from every predecessor manifest member; a backend with neither primitive is `Unsupported`.
- Make missing-config diagnostics command-specific. `service run` points to the owning
  parent/controller projection, or to `service init` together with the authorized manifest/identity
  installer; it never implies that descriptive bytes alone grant activation. Project lifecycle points to
  `project init`; no generic hint recommends an initializer that still cannot satisfy the requested gate.

#### Validation

- Compile-fail fixtures reject a wrong service-parameter/handler pairing, parameters minted under
  another `configId`, an independently chosen field row, a payload containing a field whose `VisibleTo`
  set omits that service, a handler program whose effect row differs from its `ServiceSelection`, and raw
  handler invocation without the core-owned selection/run gate. Construction tests cover structured
  selection outcomes
  for absent requests, registry mismatch, wrong config ID, non-leaf frames, stale activation
  revisions/instance IDs, any non-Serve cursor, activation package without matching placement, effect rows outside the admitted
  placement, `DurableStore` without `DurablePlacementAuthority`, a consumed service invocation, and
  missing service capability. A duplicate invocation/CAS test proves one command identity starts at most
  one handler. Admission tests prove raw draft mismatch refuses before any durable reservation, only
  `withRoleLifecycleAdmission` produces the one-use admission, and `withRuntimeRolePlan` cannot run
  without consuming it or reuse it to mint a second `planId`/cursor. Selection failure before program
  start still yields the unique Drain cursor/receipt-and-lease package.
- Crash-recovery tests enumerate multiple heterogeneous old rollout records and reject missing,
  duplicate, extra, new-lineage-relabelled, or liveness-stale manifest members. A live non-exclusive
  predecessor remains outside recovery and may overlap; a live exclusive predecessor yields no recovery
  authority. Kill injection across exact-set recovery, fence/lock transfer, old Exit closure, new
  admission reservation, and acknowledgment resumes one stable key through
  `resumeRoleLifecycleRecoveryUnknown`. Cross-service/plan/config/effect substitution of an unknown or
  settled recovery package fails. The exclusive branch cannot mint
  `RoleRecoveryClearance` without a `ServiceLeaseTransferBarrier` covering every predecessor; the
  no-exclusive branch requires the complete-set proof. No new plan/cursor/lease exists before
  `resumeRoleLifecycleAdmission`.
- Service-journal race/fault tests reject a prepared effect from another invocation/session or prior
  journal version, effect row, phase, target, or call digest; prove an adapter receives the sealed request
  only inside its prepared value and can consume each value once; and
  expose every terminal outcome only with the fresh successor session plus the whole retained
  receipt/lease package. No eliminator exposes a bare lease. Compile-fail tests prove normal prepare
  accepts only `ServiceEffectReady`. Faults before prepared-value return yield indexed
  `ServiceEffectPrepareFailed`/`ServiceEffectPrepareUnknown` with the sole session/package and reach
  Drain/recovery without retry or resource loss. Kill-after-call-before-ack produces a target/call-indexed
  `ServiceEffectUnknown`; only exact full-lineage same-key/fence reprobe can resolve it or mint a
  `VerifiedSameKeyRetry`, and only the private joint resume eliminator accepts that proof with the
  matching Unknown session/package.
  Success-, failure-, shutdown-, interruption-, and empty-registry paths prove each yields Drain, which attempts all
  releases while aggregating failures, and no result can be observed without the successor cursor.
  Demo codec properties prove each decoded
  Web/Accelerator value yields its corresponding typed request and parameters; core does not claim to
  inspect an arbitrary function for semantic relatedness because that function is removed.
- API tests prove `ServiceProgram` exposes no raw `IO`/`MonadIO`/config-read escape hatch. A
  replacement-race test swaps the mounted role wire between child-local validation and handler
  execution; the selected handler observes only the role parameters packaged under the verified local
  config ID/digest, and neither handler program nor interpreter opens the config path or receives the
  full project config. Replace/rebind-between-readiness-and-Serve tests prove only the probed managed
  handles are usable. Restart-after-effect-call-before-ack tests prove stable-key/fence reprobe prevents
  blind duplication. Supervisor-restart tests prove the child replacement is journal-prepared and cannot
  route work until the successor child has a new readiness proof.
- Role-projection tests prove every configured port/timeout is preserved and no fallback source exists.
  The mounted wire contains exactly mandatory `FrameworkValidation` fields plus fields tagged for the
  selected `Service service`; `RoleParams` contains only the latter. Plan/build/deploy-only fields inhabit
  neither. Golden tests prove both filters independently. These tests also audit the demo's semantic
  consumer tags; core's generic guarantee is relative to the declared tags. Production/Harness fixtures
  prove no inline secret appears in role ConfigMaps, pod templates, signed activation manifests, logs, or
  `LocalContextView`; only the Kubernetes Secret/private OS channel contains fixture bytes;
  missing/extra/duplicate Harness secret entries and cross-run/cross-spec bundles refuse.
- CLI tests distinguish the current full-`cfg` encoder-declared `service schema` from the target
  `RoleCodec`-derived role-wire schema registry, and prove an empty registry's structured result plus
  command-specific missing-config guidance.

#### Remaining Work

Blocked until Phase 14.6 supplies the phase-indexed role lifecycle, Phase 15.9 supplies immutable
validated role-wire/runtime authority, Phase 17.4 supplies command-specific parser/guidance semantics,
and Phase 19.8 finalizes the service registry/projection relation. Then migrate the handlers and rerun
the service/daemon matrix.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/run_models.md` - the `HostDaemon`/service run-model reached via `service run`, the
  current arbitrary selector/handler registry and their target replacement by a codec-produced opaque
  request, finalized typed registry, and effect-authorized `SelectedService`.
- `documents/architecture/binary_context_config.md` - the service-role context and dynamically generated
  ConfigMap-overrides-baked-`<project>.dhall` delivery.

**Engineering docs to create/update:**
- `documents/engineering/cluster_lifecycle.md` - the chart pod entrypoint `service run`, exact-byte config
  hashing, and placement-specific service delivery.
- `documents/engineering/accelerator_daemon.md` - CBOR protocol seam, concrete WebSocket transport, and
  persistent worker supervision.

**Cross-references to add:**
- `README.md` CLI Surface lists `service`; `system-components.md` adds the `service` command and the
  service-handler registry; `00-overview.md` names phase-18 in the cross-phase narrative.
