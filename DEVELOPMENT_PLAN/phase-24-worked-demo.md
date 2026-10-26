# Phase 24 — The worked demo

**Status**: Active
**Depends on**: Phase 16 (provider, cluster, and guest lifecycle foundations), Phase 17 (proof-complete
recursive lifecycle command), Phase 22 (service-runtime activation and `service run` semantics), Phase 23
(base image publication and the opportunistic warm store)
**Substrates**: linux-cpu
**Gate**: `cabal build all` and `cabal test hostbootstrap-demo-test` from `demo/`, the
core host-static gate from `core/`, plus live
`hostbootstrap run -- project up`, `hostbootstrap run -- project down`,
`hostbootstrap run -- project destroy`, and `hostbootstrap run -- test run all` reporting `10/10 passed`
inside the universal `linux-cpu` realization on any supported outer host
**Gate kind**: deferred
**Gate evidence**: 2026-10-20 ; `MacBookPro`, native arm64 macOS 26.6.2 (build 25G83),
Apple M1 Max, 64 GiB memory, GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.3.2, Python 3.14.3,
live universal `linux-cpu` realized through native VZ/aarch64 Lima 2.1.2 guests ;
`cabal build all` and `cabal test all` from `core/`,
`cabal build all -j1`, `cabal test all`, and
`cabal test hostbootstrap-demo-test --test-show-details=direct --test-options=--hide-successes`
from `demo/`, `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root,
plus repository Python-bootstrapper
`poetry run hostbootstrap run --project-root demo project init`,
`poetry run hostbootstrap run --project-root demo project up`,
`poetry run hostbootstrap run --project-root demo project down`,
`poetry run hostbootstrap run --project-root demo project destroy`,
`poetry run hostbootstrap run --project-root demo test init`, and
`poetry run hostbootstrap run --project-root demo test run all`
reporting `10/10 passed`, followed by terminal ownership,
Production-data preservation, ambient-state, and covered-source audits ;
pass ; covers 0b27634921cf2e486ef70fcefcc27943206f30197760b685a60ec81d247f80e7
**Evidence covers**: `.dockerignore` `.hlint.yaml` `core/cabal.project` `core/hostbootstrap-core/app` `core/hostbootstrap-core/dhall` `core/hostbootstrap-core/hostbootstrap-core.cabal` `core/hostbootstrap-core/internal` `core/hostbootstrap-core/provider-live` `core/hostbootstrap-core/src` `core/hostbootstrap-core/test` `demo/app` `demo/cabal.project` `demo/chart` `demo/docker` `demo/hostbootstrap-demo.cabal` `demo/kind.yaml` `demo/nvkind-in-cluster.yaml` `demo/playwright/package.json` `demo/playwright/playwright.config.ts` `demo/playwright/tests` `demo/src` `demo/test` `demo/web/spago.yaml` `demo/web/src/Main.purs` `demo/web/src/index.js` `fourmolu.yaml` `hostbootstrap` `pyproject.toml` `tests`

> **Purpose**: Be the real consumer that proves the library composes — a complete application with its own
> plan, config vocabulary, test component, and service variants.

## Phase Objective

Everything below this phase is a library. This phase is the consumer that exercises it end to end: a
scope-polymorphic plan instantiated separately for production and for each harness run, a web application with
a real cluster, an in-cluster registry backed by object storage, an accelerator daemon, and a five-case test
matrix generated from decoded configuration.

It is also where the universal-realization contract becomes live: the host-native binary must establish
native Linux, Lima/Colima, or WSL2 as appropriate and re-enter this same project in `linux-cpu`; a native
macOS or Windows execution of the commands is not equivalent. The derived-image quality gate lives here: the
demo's build #3 runs `fourmolu` and `hlint` through its in-container `check-code`, the one place a derived
project runs them. They are not a leg of the host static gate; the repository source gate (`base build` and
`base build-and-push`) also runs both on the maintainer's host — see [rationale.md](rationale.md) and
[code_check_doctrine.md](../documents/engineering/code_check_doctrine.md). Sprints 24.30 and 24.41 are the worked-demo Production and
Harness live confirmations of the host-static recursive lifecycle command completed by Phase 17.

## Sprints

### Sprint 24.1: The demo plan and config vocabulary [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Config.hs`,
`demo/test/CommandsSpec.hs`, `demo/test/ConfigSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

One scope-polymorphic plan the demo instantiates per scope.

#### Deliverables

- The demo declares its own config vocabulary and step fragments, finalized into one `StepPlan`; it adds no
  verb of its own.
- The plan is scope-polymorphic and is instantiated separately for `Production` and for each harness run, so a
  test run's cluster and data root derive from its run identity while host ports are selected only by the
  runtime-owned exposure operation.
- The demo's chain runs on the core interpreter; there is no demo-local deploy interpreter.
- The pulled rolling base is consumed `FROM` the published tag, and the in-Dockerfile `check-code` stage runs
  the container gate.
- The decoded config, finalized plan, and generated test vocabulary remain one coherent demo-owned assembly;
  no hidden environment or command-line term changes its topology.
- Production and Harness Dhall contain stable application/Service ports only. There is no field, default,
  derived run hash, or numeric convention for a provider-/host-local port; service identity and internal target
  are the complete exposure intent available before effects.
- The refined config values (`Quantity`, `HaReplicas`, `Port`, `TimeoutSeconds`, `Resources`) are reachable
  only through their smart producers: `Config.hs` exports read-only getter functions, never record field labels,
  so record update cannot bypass `mkQuantity`, `mkHaReplicas`, `mkPort`, `mkTimeoutSeconds`, or `mkResources`.
- The chain selector refuses an invalid retained topology or an unsupported nested route as a typed plan
  refusal, never a lazy `error`.

#### Validation

`CommandsSpec` covers the plan shape, both scope instantiations, and the config vocabulary. `ConfigSpec` and a
source guard prove generated/example Dhall has no host-port field and no Haskell default or run-derived host
number feeds plan construction. The container gate runs on every image build. Dated evidence, 2026-08-23:
Production and Harness config/plan projection retains only the four semantic service/internal-target
declarations, and the complete demo gate passed 142/142 under `--ghc-options=-Werror`.

Closure requires these cases in `cabal test hostbootstrap-demo-test` from `demo/`, then the demo host-static gate:
the compile-fail fixture and the `ConfigSpec` and `CommandsSpec` cases named under Remaining Work.

#### Remaining Work

- `Config.hs`: stop exporting the record fields `quantityText`, `haReplicasNat`, `portNat`,
  `timeoutSecondsNat`, `cpu`, `memory`, and `storage`; export plain getter functions of the same meaning
  instead, and update callers. The demo suite has no compile-fail harness: add `demo/test/compile-fail/` with a
  fixture whose body is `p {portNat = 0}` for an imported `Port`, and a `ConfigSpec` case that compiles it the
  way core's `CompileFailSpec` compiles its fixtures and asserts the compile fails naming `portNat`.
- `ConfigSpec` "a malformed config fails with a typed error": catch the concrete Dhall type-error exception
  rather than `SomeException`, and assert its rendered text names `resources`. Change `assertDecodeFails` to
  catch `Dhall.ExtractErrors` only and to take the expected refinement text, asserting the message contains the
  `mkPort`, `mkTimeoutSeconds`, `mkHaReplicas`, or `mkQuantity` refusal for each row; add positive decodes for
  `WebServiceConfig` and `AcceleratorServiceConfig` to that group.
- `ConfigSpec` "renderProjectConfigSummary surfaces identity and budget": assert the summary contains
  `project: hostbootstrap-demo` and `resources: cpu=6 memory=10GiB storage=80GiB`.
- `Commands.hs` `demoChainFor`: return `Either String [Step]` and lift its two failure arms (invalid retained
  topology; nested frame with no supported provider route) into the plan-construction error channel, as
  `demoForwardChildPlan` does. Add `CommandsSpec` cases expecting each `Left` message.
- `Config.hs` Haddocks: replace `demoTestConfig` with `demoAssemble` (module header and `demoInit`); rewrite
  `demoAssemble`'s Haddock to say it builds one config per declared `HarnessAssembly` variant draft, carrying
  that draft's message and identified by `variantName`; remove the "selectable suites" claim from `TestConfig`
  and the default `test.dhall` Haddocks (the type holds `testResources` and `testVariants`); and move the
  orphaned `ProjectConfig` and `defaultTestConfig` Haddock blocks onto their declarations.

### Sprint 24.2: The application, registry, and accelerator daemon [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Web/`, `demo/src/HostBootstrapDemo/Container.hs`,
`demo/src/HostBootstrapDemo/Accelerator/`, `demo/chart/`, `demo/web/`
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/engineering/accelerator_daemon.md`

#### Objective

A real application with real dependencies.

#### Deliverables

- A web service and single-page application, served through the cluster, with an idiomatic Dockerfile.
- A single-binary in-cluster registry backed by object storage, with a finalized registry plan that renders
  redirect configuration as output and requires a settled route before an image push.
- An accelerator daemon reached over a private listener with a CBOR round trip, placed per substrate: in-cluster
  behind a service address on Linux, host-native through its exact runtime-resolved loopback exposure on Apple
  and Windows.
- The daemon's readiness is observed rather than slept for, and its launch uses the sealed invocation-shape
  boundary so a pre-readiness failure writes its cause somewhere readable.
- The application, registry, and accelerator variants expose only their finalized service interfaces; demo
  orchestration does not acquire lifecycle authority from an application callback.
- `Accelerator.Protocol` is a strict, deterministic CBOR decoder for bytes from the WebSocket peer: trailing
  bytes, an unknown message type, a missing or wrong-typed field, a duplicate map key, invalid UTF-8, an
  indefinite length, and truncated input each refuse with their own reason. A map value is dispatched on its
  CBOR major type, so a malformed text value reports the text fault, never `expected CBOR double`.
- `Accelerator.Daemon` refuses a malformed endpoint at startup, holding its port as the core
  `HostBootstrap.Network` `Port`; bounds connect and handshake by a deadline raced against the shutdown file;
  reports an undecodable or non-request frame as a protocol error distinct from a clean disconnect; and lets
  asynchronous exceptions, including the per-request `timeout`, propagate through worker-session teardown.

#### Validation

`CommandsSpec` proves the provider-/host-local adopters (`deployObjectStoreAction`, `deployRegistryAction`,
`pushImageAction`, `exposeAction`, and the host accelerator's `withHostAcceleratorExposure`) open only the
resolved exposure for their semantic service and construct no fixed local endpoint. The test-case clients in
`demoAssert` address the fixed cluster-internal NodePorts (`30080`, `30500`) from inside the cluster frame and
are not resolved-exposure clients. The live `10/10` matrix exercises those clients after the later exposure
adopter closes. Dated evidence, 2026-08-23: the focused `CommandsSpec` source and value checks passed 58/58 and
the complete demo gate passed 142/142 under `--ghc-options=-Werror`.

Closure requires these `AcceleratorRuntimeSpec` cases to exist and pass in `cabal test hostbootstrap-demo-test`
from `demo/`: the protocol negative table, the endpoint refusal table, the readiness-marker table, the
daemon-loop branch cases, the supervisor exhaustion and start-failure cases, the teardown-timeout case, and the
worker-seam cases named under Remaining Work; then the demo host-static gate.

#### Remaining Work

- `Accelerator/Protocol.hs`: replace `parseValue`'s `(<|>)` backtracking with a dispatch on the next byte's
  major type (major 3 is text, `0xfb` is a double, anything else refuses naming the byte), and make
  `messageFromFields` refuse a map whose key list contains a duplicate. Add a table-driven negative group to
  `AcceleratorRuntimeSpec`: an encoded request plus one extra byte (`trailing bytes after accelerator CBOR
  message`), type `bogus` (`unknown accelerator message type`), a map without `requestId` (`missing accelerator
  CBOR field: requestId`), `requestId` encoded as a double (`accelerator CBOR field is not text`), `left`
  encoded as text (`accelerator CBOR field is not a double`), a map header with additional info 31, a truncated
  message, a text value holding bytes `0xC3 0x28` (`invalid UTF-8 text`), and a map with two `requestId`
  entries. Add round trips whose text field is 24 bytes and 256 bytes long to reach the one- and two-byte
  length encodings.
- `Accelerator/Daemon.hs`: replace the `SomeException` catches in `closeSessionQuiet`, `stopProcessSession`,
  and `terminateQuiet` with `trySynchronous`. Add a case whose first attempt fails fast while the worker stays
  alive and whose stop blocks past a one-second request deadline; assert the daemon emits
  `DaemonRequestTimedOut` and starts no unbounded retry.
- `Accelerator/Daemon.hs`: parse the endpoint port as decimal digits only and admit it through
  `HostBootstrap.Network.mkPort`; make `endpointPort` a `Port` and stop exporting the `WebSocketEndpoint`
  constructor. Add refusal cases for `ws://:30081/x` (empty host), `ws://h:abc/x`, `ws://h:1:2/x`, `ws://h:0/x`,
  `ws://h:-1/x`, `ws://h:70000/x`, and `ws://h:0x7531/x`.
- `Accelerator/Daemon.hs`: make `receiveWebSocketRequest` return a distinct malformed-frame outcome carrying the
  decode error (or the unexpected message type) and emit it as a protocol-error event instead of
  `DaemonDisconnected`. Bound `connectWebSocket`'s wait on `resultVar` by a deadline raced against the
  transport's shutdown check, killing the client thread when either fires. Add loop cases for each: a frame of
  garbage bytes yields the protocol-error event, and a connect that never completes ends with `DaemonStopping`
  once the shutdown check turns true.
- `AcceleratorRuntimeSpec` loop branches: a transport whose first `connectDaemon` returns `Left` (expect
  `DaemonConnectFailed` then reconnect); a connection whose `receiveRequest` returns `Nothing` before shutdown;
  a supervisor that sleeps past `requestTimeoutMicros` (expect `DaemonRequestTimedOut` and an
  `AcceleratorFailure` response sent); and a supervisor returning `Left` (expect `DaemonRequestFailed` and the
  failure response). Assert the exact event sequence in each.
- `AcceleratorRuntimeSpec` readiness: assert the marker file is removed after `DaemonConnectFailed "x"` and after
  `DaemonStopping`, and that `updateDaemonReadiness Nothing` is a no-op.
- `AcceleratorRuntimeSpec` supervision: a session whose `sessionAdd` always returns `Left` (expect `accelerator
  worker failed after one restart:` and balanced stop counters), and a `startSession` that returns `Left` and
  one that throws `IOException` (expect the start error text).
- Worker seams: delete the uncalled export `runWorkerProcess`. Test `startWorkerSession` against a spec rooted
  in an empty temporary directory (expect the missing-executable refusal) and against a tiny script worker that
  prints a non-numeric line (expect `accelerator worker returned non-numeric output`).
- `Accelerator.hs`: export `WorkerSpec` abstractly (no `(..)`), with read-only accessor functions in place of
  record fields, so `workerSpec` is the only producer and no caller can record-update `workerSourceText` under
  another source's `workerArtifactHash` and hash-addressed path. Add an `AcceleratorSpec` case asserting
  `workerSpec root backend` yields a hash that equals `stableSourceHash` of its own source text and a binary
  path under a directory named by that hash.

### Sprint 24.3: The five-case test matrix from decoded config [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Config.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/ConfigSpec.hs`, `demo/test/CommandsSpec.hs`,
`demo/playwright/playwright.config.ts`, `demo/playwright/package.json`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Generate the matrix from configuration, not from Haskell source.

#### Deliverables

- Five compiled cases: `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`, and
  `durable-readback`; two config variants; ten report-card rows.
- `durable-readback` writes through the web service and reads the same bytes back from the plan-owned durable
  root without receiving or invoking a lifecycle callback.
- `TestConfig` carries a declared `testVariants` set, and `demoTestMatrix` projects the run matrix out of it, so
  adding, renaming, or removing a variant is an edit to the generated `<project>.test.dhall` rather than to a
  Haskell module. `test init` writes the two the demo ships with.
- Each declared name is validated into a `VariantId` while the matrix is being built — before the run acquires
  anything. An empty set is the core's own `EmptyVariantRegistry`, duplicates are its `DuplicateVariantIds`,
  and a malformed name is `InvalidVariantDeclaration`.
- The demo's `TestSuite` supplies the safety probe, assertion environment, typed case matrix, per-case
  assertions, and post-reverse absence assertion. It receives no lifecycle callback; the harness engine owns
  and retains the exact Harness plan.
- `registry-persistence` fails when the registry restart itself fails, and passes only after a registry pod
  with a new UID serves `tags/list` again. Every case's reachability probe reports a deterministic lift or
  container failure as a failure carrying its cause, not as an unreachable service after the full poll budget.
- `pristine-bootstrap` stages the source tarball inside a fresh per-run temporary directory and treats any
  nonzero `tar` exit as fatal, since host `tar` is bsdtar on Windows and macOS.
- The Playwright config names its actual target: the chart's web Service at the Kind node's NodePort 30080,
  with `BASE_URL`, `EXPECTED_MESSAGE` (required), and `EXPECTED_ACCELERATOR_BACKEND` set by the harness.

#### Validation

`ConfigSpec` covers the projection directly: the matrix's variants are the declared ones, a third variant
appears from a config edit alone, each variant carries its own served message, every case runs under every
declared variant, and each of the empty, malformed, and duplicate declarations is refused before the run.
`CommandsSpec` covers the immediate stack assertions and the lifecycle-free declarative write/read shape.
Dated evidence, 2026-08-22: the decoded two-variant registry expanded the five compiled cases into ten report
rows and the complete demo suite passed 138/138 with `--ghc-options=-Werror`.

Closure requires the `CommandsSpec` and `ConfigSpec` cases named under Remaining Work to exist and pass in
`cabal test hostbootstrap-demo-test` from `demo/`, then the demo host-static gate; the live `10/10` matrix
exercises the rewritten assertions on the next acceptance run.

#### Remaining Work

- `Commands.hs` `assertRegistrySurvivesRestart`: keep the restart result; return `Fail` carrying the captured
  output on `Left` or `ExitFailure`, and record the registry pod UID before the restart and require a different
  UID after the rollout before re-probing `tags/list`. Factor the decision into a pure exported classifier over
  (restart result, UID before, UID after, tags reachable) and add a `CommandsSpec` table: restart failure gives
  `Fail` with the output, an unchanged UID gives `Fail`, a changed UID with tags reachable gives `Pass`.
- `Commands.hs` `assertRegistrySurvivesRestart` Haddock: replace "Runs last in the case matrix" with the real
  order (`durable-readback` runs after it on the same stack, which is safe because the case waits for the new
  registry rollout before returning).
- `Commands.hs` `waitClusterServiceReachable`: classify a `Left` from `liftLeaf` and a `docker run` exit of 125,
  126, or 127 as `Failed`, and return the rendered `PollError` instead of a `Bool` so `assertReachable` and
  `resolveAcceleratorE2E` put the cause in their `Fail` message. Expose the classifier as a pure function and add
  `CommandsSpec` rows: curl exit 7 is `NotReady`; exits 125, 126, 127 and a `Left` are `Failed`.
- `Commands.hs` `stageSource`: treat every nonzero `tar` exit as fatal, and write the tarball inside a fresh
  `withSystemTempDirectory` rather than the fixed `<tmp>/hostbootstrap-src.tgz` shared by concurrent runs.
  Rewrite the cleanup comment to name that location and drop the repo-root `.hostbootstrap-src.tgz` claim. Add a
  `CommandsSpec` case over the pure tar-exit decision: `ExitFailure 1` with a written tarball is fatal.
- `demo/playwright/playwright.config.ts`: replace the `demo web serve` / incus-host comment with the chart web
  Service at the Kind node's NodePort 30080 and the three harness-set variables. `demo/playwright/package.json`:
  drop the never-installed `@playwright/test` 1.60.0 devDependency, or describe it as advisory because the
  harness runs the base image's global Playwright.
- `ConfigSpec`: replace `testMatrixCaseIds matrix @?= demoCaseIds` with an assertion that the production
  `demoCases` ids (imported from `HostBootstrapDemo.Commands`) equal the operator-facing literal list, so adding,
  removing, or renaming a compiled case fails the suite; correct the comment beside `demoCaseIds` to say so.

### Sprint 24.4: Plan-owned profile/root and service-target projection [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `demo/src/HostBootstrapDemo/Container.hs`, `demo/test/CommandsSpec.hs`,
`demo/test/ConfigSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrapDemo.Config`,
`HostBootstrapDemo.Container` (3; cap 3)
**Sprint budget**: no new named contract and no lifecycle call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Project both demo scopes' profile/root terms alongside their exact project plan and close the published-artifact
provenance boundary without adopting lifecycle consumers in this projection-only sprint.

#### Deliverables

- Production and Harness command assembly retain one exact `ProjectPlan`; `RunProfile` remains descriptive
  configuration and never becomes independent lifecycle authority. The Production codec admits only
  `ProductionRun` and the Harness codec admits only `HarnessRun` named by its `harnessRunName` authority; the run
  name is a validated single-path-segment newtype, so `runDurableHostPath` is total.
- One digest-checked demo projection (`canonicalDemoConfigProjection`) re-renders the config, compares its digest
  with the retained one, and returns resources, replica count, the public and accelerator ports, the semantic
  service targets, and canonical durable host root. Production projects preserved `.data`; Harness projects
  `.test_data/<run>` under its run bracket. The semantic cluster-internal service targets it returns
  (`registry` 30500, `web` 30080, `object-store` 30900, `accelerator` 30081) are fixed demo constants, not
  config fields; the digest check gates the config-derived members only, and the chart values and the
  in-cluster test-case clients restate the same NodePorts.
- The guest mount source and `PreserveOnReverse` resource derive from the same canonical durable-root projection;
  this sprint exposes the joined terms but does not adopt later lifecycle call sites.
- Every derived build passes `--pull`; the host-native lane resolves the published base tag to a repository
  digest and builds `FROM` that within-run reference without writing it to config or the repository. Only a
  RepoDigest whose repository equals the tag's own repository can pin the reference: an image with no such
  RepoDigest is the stale-local case and refuses, and two distinct matching digests refuse as ambiguous.
- This sprint exposes assembly/provenance inputs for later packages only. Provider, cluster, chart, and teardown
  consumers remain owned by their numbered adoption sprints and receive no premature plan-owned claim here.

#### Validation

`CommandsSpec` and `ConfigSpec` cover both scope projections, durable-root identity, Harness isolation,
`--pull`, the `pinnedBaseReference` join and its malformed-digest refusal, and the `baseDigestArgs` inspection
argv. The demo host-static gate must pass. The named-module and 400-line budgets are checked before
implementation; overflow is split into a new sprint rather than expanding this one. Sprint 24.30 owns live
confirmation. Dated evidence, 2026-08-23: the digest-checked projection, both scope projections, base-digest
pinning, and absence guards passed in the complete 142-case demo gate under `--ghc-options=-Werror`.

Closure requires the `CommandsSpec` RepoDigest-selection table and the `ConfigSpec` codec, assembly, and
digest cases named under Remaining Work to exist and pass in `cabal test hostbootstrap-demo-test` from `demo/`,
followed by the demo host-static gate.

#### Remaining Work

- `Container.hs`: add a pure `publishedReferenceFromInspect :: String -> String -> Either String String` (tag,
  `docker image inspect` RepoDigests stdout) that parses each line into repository and digest, normalises both
  repositories (`docker.io/` and `library/` prefixes), keeps only entries whose repository equals
  `repositoryOf tag`, refuses when none match (the stale-local message) and when two distinct digests match,
  and joins the survivor through `pinnedBaseReference`. `resolvePublishedBase` and `resolvePublishedBaseInVM`
  (`Commands.hs`) both call it instead of taking the first line or the first `@sha256:` line. Add `CommandsSpec`
  cases: empty output, whitespace-only output, one matching line, a foreign-repository line sorted before the
  matching one (the matching digest wins), only a foreign repository (refused), two distinct matching digests
  (refused), and a non-`sha256` digest (refused).
- `Container.hs`: delete the uncalled `buildProjectContainer` export and point the module Haddock at the real
  build seam (`dockerBuildArgsWithVerificationKey` and `runAuthenticatedDirectImageBuild` in `Commands.hs`).
- `Config.hs`: `withHarnessProjectCodec` stops discarding its authority. The Production codec refuses any
  `runProfile` other than `ProductionRun`; the Harness codec refuses any other than `HarnessRun` whose name equals
  `harnessRunName authority`. Replace `HarnessRun Text` with `HarnessRun RunName`, a private-constructor newtype
  whose `FromDhall` instance (through `refiningDecoder`) refuses an empty name, `.`, `..`, and any name holding
  `/` or `\`. `runDurableHostPath` then returns its path without `error` (or returns `Either` if a refusal arm
  remains). Add `ConfigSpec` cases: each codec refuses the other scope's profile; `RunName` refuses `""`, `..`,
  `a/b`, and `a\b`; `demoAssemble` under `HarnessAssembly` yields `runProfile == HarnessRun name`,
  `clusterProfileOf == TestCase name`, and the test resources, while `ProductionAssembly` keeps `ProductionRun`.
- `ConfigSpec` digest projection case: derive the expected retained digest from the core path
  (`renderScopedProjectConfigBytes` for the demo codec, or the digest `withValidatedConfig` returns) rather than
  from `renderProjectConfig`, so drift between the core-admitted bytes and the demo renderer fails the case.

### Sprint 24.5: Authored provider resources and exact direct-parent join [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Lifecycle.Plan`,
`HostBootstrapDemo.Commands` (3; cap 3)
**Sprint budget**: one new named type, `ProviderResourceDeclaration`, and no call-site adoption; at most 400
production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/engineering/resource_budgeting.md`, `documents/operations/demo_runbook.md`

#### Objective

Let plans author provider resources at their actual target frames, then prove each cluster has exactly one
immediate provider parent.

#### Deliverables

- `HostBootstrap.Step` adds the sole named type `ProviderResourceDeclaration` and a closed declaration
  extension whose target is only the current frame or its unique immediate child; callers supply neither raw
  frame text nor a resource key.
- `Lifecycle.Plan` validates, retains, and hashes the declaration and resolves the `ProviderResource` frame
  from it: the current frame, or the unique immediate child. The closed provider family keys its resource as
  `core:deploy-vm` (`plannedKindKey ProviderResourceKind`). A `core:deploy-vm` step with no declaration
  resolves its provider at its own executing frame; this is the compatibility rule the undeclared core
  fixtures rely on, and both demo topologies declare explicitly.
- Validation refuses duplicates, a child target without exactly one declared descent, an absent topology
  target, and any declaration inconsistent with the node's exact resource prefix.
- The demo's pure projection enumerates only plan-admitted declarations, resolves each cluster frame's unique
  immediate parent, and joins it to exactly one provider at that frame; zero, duplicate, ancestor, sibling, or
  wrong-frame candidates fail before backend work.
- VM topology declares the provider at the VM target frame (`providerResourceAtImmediateChild`), while Direct
  topology declares its host reservation at the current metal frame (`providerResourceAtCurrentFrame`) on the
  same `core:deploy-vm` operation. The Direct and VM provider resources share that operation key; the backend
  origin, package route, and carried adapter identity distinguish them, and the Direct graph creates no VM
  resource.
- On WSL2 the provider storage preflight reserves the swap file beside the distribution disk:
  `withWsl2SwapStorage` returns the budget with storage increased by the memory size in whole GiB, rounded up.
- One rule places a provider resource on every route. `resourceFrame` decides its frame and admission (one
  `ProviderResourceDeclaration`, or the undeclared `core:deploy-vm` compatibility rule).
  `validateGraphResource` checks a provider-kind resource against that frame, not the authoring step's frame.
  `forwardKernel`'s dependency view, which feeds `withNodeResourceOfKind` and `withPlannedStepResourceOfKind`,
  carries the same frame and admission. One provider key under one `planId` therefore has one frame whichever
  route mints it.

#### Validation

`ProjectPlanSpec` covers current-frame and child-frame projection, `StepSpec` covers the
`DuplicateProviderResourceDeclaration` and `ProviderResourceChildWithoutUniqueDescent` refusals, the
compile-fail fixtures cover hidden construction, and `CommandsSpec` covers stable identity, VM and Direct
success, and every ambiguous or mismatched join. The core and demo host-static gates must pass.
The named-type/module/line budgets are checked before implementation; any second type, adoption, fourth module,
or over-400 estimate is split into another sprint.

Dated evidence, 2026-08-22: the core gate passed 2,387/2,387 and the demo gate passed 126/126 plus its nested
core 2,387/2,387, all with `--ghc-options=-Werror`. Closure requires the `CommandsSpec` swap-storage cases and
the `ProjectPlanSpec` provider-frame cases named under Remaining Work to exist and pass in
`cabal test hostbootstrap-demo-test` from `demo/` and `cabal test all` from `core/`, then both host-static
gates.

#### Remaining Work

- `Commands.hs`: export `withWsl2SwapStorage`. Add `CommandsSpec` cases: `demoDefaultResources` (10GiB memory,
  80GiB storage) yields storage `90GiB` with CPU and memory unchanged; a budget whose memory quantity is not a
  whole number of GiB (in any unit `mkQuantity` admits) rounds the added swap up to the next whole GiB.
- `Lifecycle/Plan.hs` `validateGraphResource`: take the resource kind and, for a provider kind, compare
  `plannedResourceFrameKernel` with `resourceFrame graph ProviderResourceKind step` instead of
  `frameId (stepFrame step)`. Today `withProjectPlannedEdgeKernel` and
  `withProjectProviderGuestAliasProjectionKernel` refuse a provider that the same plan minted at its immediate
  child frame with `PlanResourceBindingMismatch "resource frame"`, so `withPlanOwnedCluster` cannot edge the VM
  provider. Test: in `ProjectPlanSpec`, take a plan whose `core:deploy-vm` step at frame `host` declares
  `providerResourceAtImmediateChild` with the single child `guest`. Assert that `withPlannedResourceOfKind`
  yields frame `guest`, and that `withPlannedEdge plan share provider` and
  `withProviderGuestAliasProjection plan provider share` both return `Right`.
- `Lifecycle/Plan.hs` `forwardKernel` and the node route: build each provider dependency's view entry with the
  `resourceFrame` rule (child frame for an immediate-child declaration), and have `withNodeResourceOfKind`
  admit a `ProviderResourceKind` key by that step's declaration rather than by the literal `core:deploy-vm`
  comparison. Test: in `ProjectPlanSpec`, the node route (`withNodeResourceOfKind` on the dependent cluster
  node's execution) and the plan route return the same key and the same frame (`guest`) for the
  immediate-child provider above. A `projectStep "direct-provider"` carrying `declaresProviderResource`
  resolves through both routes with equal frames, rather than giving `PlanResourceKindMismatch` on the node
  route.

### Sprint 24.6: Neutral exact-plan execution package [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Lifecycle.Execution.Internal`, `HostBootstrap.Lifecycle.Plan`,
`HostBootstrap.Reconcile` (3; cap 3)
**Sprint budget**: one new named type, `PlanExecutionPackage`, and no call-site adoption; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/generic_project_model.md`

#### Objective

Seed step execution with neutral canonical plan metadata without introducing an Execution-to-Plan import cycle.

#### Deliverables

- Cabal-private `PlanExecutionPackage` is owned by `Lifecycle.Execution.Internal` and contains only nominal plan,
  scope, frame, operation, resource-prefix, retained config-digest, and already-canonical metadata needed by an
  executing step; it does not contain `ProjectPlan` or a backend witness.
- `Lifecycle.Plan` owns the fixed projection that inspects the exact admitted `ProjectPlan` and emits only
  canonical neutral terms. `Reconcile.stepExecutionFor` is the sole package constructor joining those terms
  through the hidden constructor; `Lifecycle.Execution.Internal` never imports Plan or `ProjectPlan`.
- Demo action configuration is available only as canonical plan metadata emitted through its finalized codec;
  a typed consumer must re-render and match the retained digest before using projected fields.
- The package is carried by a dedicated hidden execution slot, not `CarriedResource`, and cannot be forged,
  replaced, decoded from public bytes, or reconstructed from independently supplied config.
- Forward step projections retain the same nominal package identity and exact resource prefix. A package for
  another plan, scope, or config cannot be constructed: `stepExecutionFor` has no runtime refusal path and builds
  every field, generation included, from the one `PlannedStep` whose nominal scope, `planId`, and `configId`
  indices match the `ProjectPlan`. Teardown receives no `StepExecution` package, so this sprint makes no
  reverse-consumption claim.

#### Validation

`ReconcileSpec` and compile-fail fixtures cover sole production, digest agreement, forward retention, hidden
construction, and an import-cycle guard; the nominal-role inventory and the compile-fail fixture prove that a
mismatched scope, plan, or config index does not type-check. The core host-static gate must pass. The sole-type,
module, and 400-line budgets are checked before implementation; overflow is split before work starts.

#### Remaining Work

None. Completed 2026-08-22. The nominal Cabal-private `PlanExecutionPackage`, dedicated `StepExecution` slot,
plan-owned neutral-term projection, sole reconciler producer, config-digest continuity, forward-prefix
retention, hidden-construction fixture, nominal-role inventory, and import-cycle/source-owner guards are
implemented. Together with Sprint 24.6a, the complete core host-static gate passed 2,389/2,389 under `-Werror`.

### Sprint 24.6a: Plan-indexed recursive frame carrier [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.FrameExecutor`, `HostBootstrap.Command.Child` (2; cap 3)
**Sprint budget**: no new named type; at most 200 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Retain the admitted plan index across the storeless recursive frame executor so its local step can consume the
sole plan-produced execution package without weakening either nominal boundary.

#### Deliverables

- The forward frame opener receives the interpretation's plan-indexed resource carrier and fixes the executor's
  root-plan index to that same admitted plan; the existing generative compatibility opener remains for reverse.
- Recursive child execution retains the exact `PlannedStep` and calls only `Reconcile.stepExecutionFor`; it no
  longer constructs an execution descriptor or package from received text.
- Signed plan/frame/node/gate checks still occur before the action, and the plan-indexed carrier remains hidden.

#### Validation

Focused recursive-frame/source-shape tests plus the complete core host-static gate. Check the two-module,
zero-type, and 200-line budgets before marking Done.

#### Remaining Work

None. Completed 2026-08-22. The plan-indexed opener, retained exact `PlannedStep`, and sole
`Reconcile.stepExecutionFor` child route are implemented. The focused executor boundary, constructor
compile-fail, and governed-document tests passed; the complete core host-static gate passed 2,389/2,389 under
`-Werror`.

### Sprint 24.7: Workload partition and exact plan slices [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `demo/test/CommandsSpec.hs`, `demo/test/ConfigSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrapDemo.Config` (2; cap 3)
**Sprint budget**: no new named contract and no lifecycle call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/operations/demo_runbook.md`

#### Objective

Derive the demo's provider, cluster, and workload partitions and their exact frame-local slices from the
admitted plan package.

#### Deliverables

- The live cluster action (`deployKindAction`) takes its exact slice from its admitted `StepExecution`: the
  cluster slice is the execution's own config digest and frame, and the action refuses before backend work
  when `core:deploy-vm` (and, off the Direct lane, `core:copy-source`) is absent from the node's admitted
  dependency keys.
- The demo keeps no whole-plan role partition of its own: each action reads only its admitted
  `StepExecution`, and no uncalled slice projection stands beside the live path.
- Canonical demo config is re-rendered through the finalized codec and digest-matched against the execution's
  retained digest (`canonicalDemoConfigProjection`) before any config-derived resource, replica, port, or
  durable-root field is used. The cluster-internal service targets returned beside them are fixed demo
  constants that the digest does not cover.
- A digest mismatch refuses during pure projection, before budget admission or backend effects.

#### Validation

`ConfigSpec` covers the digest-matched projection and its mismatch refusal; `CommandsSpec` covers the cluster
action's provider, reconcile, cordon, readiness, and package order. Dated evidence, 2026-08-22: the full demo
gate passed 128/128 together with the nested core gate at 2,389/2,389. Closure requires the deletion below, the
`CommandsSpec` dependency-key refusal cases named under Remaining Work, and the demo host-static gate.

#### Remaining Work

- `Commands.hs`: delete `demoExactPlanSlices`, `demoExactRenderedClusterConfig` (exports at lines 98-99,
  definitions near 855-930), and `demoClosedOperationPartition` and `demoProviderClusterJoin`, whose only
  caller is `demoExactPlanSlices`, with their exports. They have no production caller: the uncalled renderer
  passes the child-visible durable root as the nvkind Docker-host source and its service-slice check rejects the
  WindowsCpu `demoVmBackedStack` chain. Delete the `CommandsSpec` case "cluster config is derived only from the
  exact plan slices", which only reads their source text.
- `Commands.hs` `deployKindAction`: factor the dependency-key admission (provider key always; share key unless
  Direct) into a pure exported function over the execution's dependency keys and the Direct flag, and add
  `CommandsSpec` rows: VM keys without `core:copy-source` refuse with "the exact provider share is absent", any
  keys without `core:deploy-vm` refuse with "the exact provider is absent", and the Direct lane admits without
  the share key.

### Sprint 24.8: Domain-separated runtime dependency package [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Lifecycle.Dependency.Internal`,
`HostBootstrap.Lifecycle.Execution.Internal` (2; cap 3; Cabal metadata is not a production module)
**Sprint budget**: one new named type, `RuntimeDependencyPackage`, and no call-site adoption; at most 400
production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/binary_context_config.md`

#### Objective

Carry domain-separated canonical recovery commitments and a package-private fresh-probe route without creating
a Dependency/Reconcile/Execution import cycle or smuggling runtime authority through a generic carrier.

#### Deliverables

- Cabal-private `RuntimeDependencyPackage scope planId` is the sole named type. Its closed domain distinguishes
  provider and cluster recovery, and its canonical fields bind plan, scope, resource, frame, backend origin,
  generation, journal/receipt commitments, route, and expiry.
- The package may retain only a package-private bounded client route, never a backend or fresh-probe closure,
  and never retains or serializes
  `ManagedProviderHandle`, `ManagedProviderShareHandle`, `RunningProviderDependency`, `ClusterReadiness`, any
  generic managed handle, or receipt authority.
- A separate invocation-owned opaque live-service registry may hold a closure capturing the strong backend and
  managed handle/readiness source after its `StepAction`; the canonical package registry holds commitments and
  bounded client routes only. Both registries are private tuple fields, not additional named types.
- `Lifecycle.Execution.Internal` holds both interpretation-wide registries once per invocation and shares them
  across every `StepRuntime`, independent of per-step state and `CarriedResource`. Neither lower module imports
  Provider, Cluster, Reconcile, or ProjectPlan types, so the DAG stays acyclic.
- Package construction, domain opening, closure replacement, and public decoding remain hidden. Wrong domain,
  nominal identity, commitment, route, generation, or lifetime is rejected before a probe is attempted.
- The coordinate checks have one implementation: `openPackage` calls `openCoordinates` and adds only its
  journal and receipt checks. The live-service registry binds a route to exactly one registered package:
  installing a service under a route already held by another registered package refuses rather than evicting
  that package's closure.

#### Validation

`LifecycleDependencySpec`, compile-fail fixtures, and an import-cycle guard cover hidden construction, exact
commitments, domain separation, dedicated carriage, and the absence of every forbidden witness type. The core
host-static gate must pass. The sole-type/module/line budgets are checked before implementation; overflow is
split rather than weakening the boundary.

Closure requires the behavioural registry and opener cases and the strengthened guards named under Remaining
Work to exist and pass under `cabal test all` from `core/`, followed by the core host-static gate.

Dated evidence, 2026-08-22: focused package/domain/registry tests and the hidden-module compile-fail fixture passed;
the governed-document validator and `-Werror` build passed; and the full core host-static gate passed all
2,394 tests. The implementation adds one named type across two production modules and 241 significant
production lines, within the declared budgets.

#### Remaining Work

- `Lifecycle/Execution/Internal.hs` `replaceStepRuntimeDependencyService`: it filters the live table by
  `runtimeDependencyPackageRoute` alone, so a second registered package with the same route evicts the first
  package's closure. A later `invokeStepRuntimeDependencyService` for the first package then fails with
  `runtime dependency live commitment mismatch`. Refuse with
  `runtime dependency live route is bound to another package` when the route is held under a different
  commitment, and replace only an entry with the same commitment. State the one-route-one-package rule in the
  Haddock.
- `LifecycleDependencySpec` (or a `ClusterReconcileSpec` fixture that reaches the hidden module): behavioural
  cases replacing the source guard "packages, services" / `if package `notElem` canonical then pure (Left`.
  Each case asserts the exact `Left` text:
  - `replaceStepRuntimeDependencyService` on an unregistered package gives
    `runtime dependency live service has no exact canonical package`;
  - `invokeStepRuntimeDependencyService` on an unregistered package gives
    `runtime dependency probe has no exact canonical package`, and the service closure never runs (an `IORef`
    counter stays 0);
  - a registered package with no installed service gives `runtime dependency live service is absent`;
  - two registered packages under one route: the second install refuses with the route-binding refusal above,
    and the first package's invoke still reaches its own closure.
- `Lifecycle/Dependency/Internal.hs` `openPackage`: call `openCoordinates` for the domain, plan, scope,
  resource, frame, origin, generation, route, and expiry checks, then add the journal and receipt checks,
  instead of restating them. Update the `LifecycleDependencySpec` "one implementation" guard to name all
  three openers and assert that `openPackage`'s body references `openCoordinates`.
- `LifecycleDependencySpec` acyclicity and forbidden-witness guards:
  - Take the import set from `SourceGuard.haskellImports` (as `IncusSpec` does) and assert it is disjoint
    from the forbidden module list, so a qualified import is caught.
  - Before checking the forbidden tokens, assert that each declaration slice (`data RuntimeDependencyPackage`,
    `providerDependencyPackageFields ::`) is non-empty and contains its expected constructor or field name.
- `LifecycleDependencySpec` cluster-coordinates case: add a provider package opened through
  `withClusterRuntimeDependencyCoordinates`, and a cluster package opened through
  `withProviderRuntimeDependencyCoordinates`, each asserting `runtime dependency domain mismatch`, the
  refusal of `openCoordinates`.

### Sprint 24.9: Provider-domain package producer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Dependency.Internal`,
`HostBootstrap.Substrate.Provider.Backend` (2; cap 3)
**Sprint budget**: no new named contract and no consumer call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Register an invocation-only pending provider commitment and live service after exact action-local
provision-to-ready settlement; fixed-node `Chain` sequencing alone prevents a successor/descent from running
until the producer gate has been acknowledged.

#### Deliverables

- `Substrate.Provider.Backend` can register a pending provider-domain package only inside the action-local
  settled running-provider bracket. `StepAction` returns before `Chain.acknowledgeOutcome` durably commits the
  row, so package registration never claims that the journal is already committed.
- Canonical commitments bind the plan/resource/frame/backend origin, backend generation, producer operation and
  gate, action-local ready observation, package route, and bracket expiry; a key/generation/version tuple alone
  is insufficient. Provider Ready has no separate durable journal row.
- The backend registers a bounded fresh-reprobe closure under that commitment in the invocation-owned opaque
  live-service registry. The closure captures the strong backend and managed provider handle; neither enters
  the canonical package registry or generic execution carrier.
- The package-private bounded client route addresses only that service and commitment; it cannot expose a raw
  probe, backend command, closure, handle, journal writer, or caller-selected resource identity.
- The provider opener admits any node whose own resources or dependency prefix contain the provider key
  (`withNodeResourceOfKind`); it holds no executing-node or acknowledged-gate check. That the successor/descent
  opens the package only after `Chain` has acknowledged the producer gate is a property of `Chain`'s fixed node
  order alone. Retry converges on the exact package, a changed package or stale generation refuses, expiry
  refuses, and every fresh lifecycle invocation starts with empty registries. No separate journal-promotion API
  is introduced.

#### Validation

`ProviderBackendSpec` (`providerRuntimePackageCase`) and `LifecycleDependencySpec` cover pending registration,
opening, exact-retry convergence, changed-package and stale-generation refusal, nonce replay, expiry, and a
source-shape assertion that the package contains no handle; the package case opens within the producer's own
action and requires success, which is the documented consequence of sequencing-only ordering. The core host-static gate must pass. Module and 400-line budgets are checked before work;
any new type or adoption is split out.

Completed 2026-08-22: the focused provider backend gate passed 24/24, the existing package/domain suite and
hidden-import fixture cover exact opening and expiry boundaries, the governed-document validator passed as
part of the full gate, and the full core host-static gate passed all 2,395 tests under `-Werror`. No named
contract or consumer call site was added; the producer adds 113 significant production lines in its one
changed production module, within the two-module and 400-line caps.

#### Remaining Work

None. Exact settled Ready authority now publishes one pending provider package whose distinct hashes bind the
complete still-pending producer gate and action-local Ready call/observation. The paired service captures the
strong backend and managed handle only in the invocation-local live registry and accepts one fixed reprobe
request. Exact retries converge, canonical drift refuses, invalid gates fail before registration, and a new
carrier begins without either registry. `Chain` remains the sole owner of the later durable acknowledgment;
this producer introduces no promotion or consumer path.

### Sprint 24.9a: Exact carried ownership evidence [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Execution.Internal`, `HostBootstrap.Reconcile` (2; cap 3)
**Sprint budget**: no new named contract and no call-site adoption; at most 300 production Haskell lines.
Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Let a fixed typed successor recover the exact generic handle/ownership-receipt pair carried from authenticated
ownership evidence, without decoding a witness from stable bytes or adding provider knowledge to the neutral
execution carrier.

#### Deliverables

- The existing `CarriedResource` keeps the already-validated ownership operation independently from its optional
  local settlement bytes; no receipt, managed handle, provider witness, or new named type enters the carrier.
- Authenticated child seeding transfers exact package resource/generation/operation evidence without attaching
  the parent frame's settlement, so the child can rebind ownership but cannot publish foreign settlement bytes.
- `Reconcile` alone can open one exact plan-admitted carried resource as a fresh lexical generic managed handle
  and matching `OwnershipReceipt`, binding key, generation, observation version, and ownership operation.
- Missing ownership evidence, a resource outside the node's exact dependency prefix, or an empty ownership
  operation refuses before the continuation. `pushCarriedResource` keeps at most one entry per key, so
  duplicate carriage cannot arise.
- Existing reporting and Chain publication APIs retain their prior shapes; stable bytes remain the canonical
  durable artifact and the added tuple field is invocation-local only.

#### Validation

`ReconcileSpec` (`assertExactResourceCarrier`) covers exact lexical opening, the foreign-key `Conflict`
(`outside:resource`), and the fresh-carrier `Failure`. Closure requires the two cases named under Remaining
Work to exist and pass in `ReconcileSpec`, then the existing Chain and resource-record suites and the full core
host-static gate. The no-type/two-module/300-line budgets are checked before implementation.

Dated evidence, 2026-08-22: the focused reconciliation gate passed 66/66, including exact receipt
revalidation, foreign-key refusal, and fresh-carrier refusal; the full core host-static gate passed all 2,395
tests under `-Werror`, including Chain, resource-record, and governed-document validation. No named type or
call-site was added, and the two-module implementation remains well below the 300-line cap.

#### Remaining Work

- Add a `ReconcileSpec` case that pushes `mintCarriedResource key 5 7` (no ownership operation) for a key in the
  node's prefix and asserts `withCarriedManagedResourceReceipt` returns `Left (Failure _)` whose detail begins
  `the carried managed resource has no ownership settlement`. Import `mintCarriedResource` from
  `HostBootstrap.Lifecycle.Execution.Internal` alongside the existing carrier helpers.
- Add a `ReconcileSpec` case that pushes `mintTransferredCarriedResource key 5 7 ""` and asserts `Left (Failure
  _)` whose detail begins `the carried ownership operation is empty`.

### Sprint 24.10: Fresh provider dependency recovery [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Dependency.Internal`,
`HostBootstrap.Substrate.Provider.Backend`, `HostBootstrap.Substrate.Provider.Reconcile` (3; cap 3)
**Sprint budget**: no new named contract and no project call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Open an exact provider package into a fresh lexical running dependency only after backend reprobe and ownership
evidence agree.

#### Deliverables

- The hidden provider-domain opener serves the fixed successor/descent after acknowledged producer sequencing;
  `withProviderRuntimeDependencyCoordinates` verifies plan, scope, resource, frame, backend origin, generation,
  route, and live expiry. The producer's journal and action-local ready commitments stay sealed in the package
  and are bound only through the package commitment that selects the live service; the opener does not compare
  them against anything the successor holds. The carried variant
  (`withCarriedProviderRuntimeDependencyCoordinates`) also leaves plan and origin to the authenticated carrier.
  The opener depends only on that sequencing and invents no provider-ready rows.
- It invokes the package-private fresh probe; the live provider service rechecks its still-owned handle against
  the real backend and returns only a sealed observation bound to the request nonce and commitment.
- `Substrate.Provider.Reconcile` combines that observation with the exact journaled ownership evidence and
  reconstructs a
  fresh `ManagedProviderHandle` and `RunningProviderDependency` only inside a lexical continuation.
- Neither successful canonical decoding nor successful backend reachability alone is enough. Missing provision
  or ready ownership, replay, wrong nonce, changed origin/generation, closed lifetime, or a mismatched resource
  refuses without yielding a dependency.
- The recovered witnesses cannot enter `RuntimeDependencyPackage`, `PlanExecutionPackage`, `CarriedResource`,
  stable bytes, config, environment, argv, or a return value that outlives the continuation.

#### Validation

`ProviderBackendSpec` (`providerRuntimePackageCase`) covers fresh success, same-nonce replay, and expiry
through `withFreshRunningProviderDependency`; `LifecycleDependencySpec` covers the pure coordinate opener; the
`EscapeFreshRunningProviderDependency` compile-fail fixture rejects escaping the witnesses. Closure requires the
`ProviderBackendSpec` refusal cases named under Remaining Work to exist and pass, then the core host-static
gate.

`openCarriedCoordinates` checks domain, scope, resource, frame, generation, route, and the exclusive expiry,
but `LifecycleDependencySpec` reaches only one provider-share success and one domain mismatch (a provider
package opened through the provider-share domain); the provider-domain carried opener has no case, so
dropping the expiry or generation `require` would let a child frame adopt an expired or superseded parent
provider package with the gate green. Closure also requires a `LifecycleDependencySpec` case, beside "every
commitment and the exclusive expiry are checked before opening", for each of
`withCarriedProviderRuntimeDependencyCoordinates` (over the provider package) and
`withCarriedProviderShareRuntimeDependencyCoordinates` (over the provider-share package): the matching
coordinates open and return the package's origin and route; and a wrong scope, resource, frame, generation
(`8` for `7`), and route, and `now` equal to the package's expiry, each return `Left` with exactly
`"runtime dependency scope mismatch"`, `"runtime dependency resource mismatch"`,
`"runtime dependency frame mismatch"`, `"runtime dependency generation mismatch"`,
`"runtime dependency route mismatch"`, and `"runtime dependency package is expired"`. All run under
`cabal test all` from `core/`. The module and 400-line budgets are checked first; any type or consumer adoption is split out.

Dated evidence, 2026-08-22: the focused provider backend gate passed 24/24; package/protocol-focused coverage
passed 26/26; the lexical non-escape compile-fail fixture passed; and the full core host-static gate passed all
2,396 tests under `-Werror`, including governed-document validation. No named contract or project call site was
added, and the three-module implementation remains below the 400-line cap.

#### Remaining Work

- Add `ProviderBackendSpec` refusal cases for `withFreshRunningProviderHandle` beside
  `providerRuntimePackageCase`, each asserting no continuation runs: (a) a fresh carrier with no registered
  package (`Failure` whose detail begins `the exact provider package is absent`); (b) a registered package whose
  live probe reports a generation other than the carried handle's (`Conflict` naming `fresh generation=`);
  (c) a registered package with no carried settlement for the provider key (`Failure` from
  `withCarriedManagedResourceReceipt`, `no settled managed resource has been carried`); and (d) a route other
  than the registered one (the coordinate refusal from `withProviderRuntimeDependencyCoordinates`). A key
  outside the node's prefix has no registered package, so case (a) covers it.
- Add child-side `ProviderBackendSpec` cases for `withFreshCarriedRunningProviderDependency`, which no test
  calls. (a) With a registered provider package and a carried settlement for its key, recovery runs the
  continuation once with the planned provider. (b) With a fresh carrier, it returns `Failure` whose detail
  begins `the exact provider package is absent; admitted dependency keys: <none>`, and the continuation does
  not run. (c) Registering a second, different package under the same key refuses at
  `registerStepRuntimeDependencyPackage` with `runtime dependency key already names another canonical
  package`. That registration refusal is what keeps the recovery's
  `the provider package registry contains duplicate resource keys` branch unreachable. Add the matching (b)
  case for `withFreshCarriedProviderShareDependency`, expecting `the exact provider share package is absent`.
  The carried variant's fresh-generation `Conflict` case is owed
  by phase 15's rebound-phase sprint.
- Add the two carried-opener mismatch and expiry tables named under Validation to `LifecycleDependencySpec`,
  one for `withCarriedProviderRuntimeDependencyCoordinates` and one for
  `withCarriedProviderShareRuntimeDependencyCoordinates`.

### Sprint 24.10a: Exact Lima provider backend realization [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Production modules**: `HostBootstrap.Substrate.Provider`,
`HostBootstrap.Substrate.Provider.Internal`, `HostBootstrap.Substrate.Provider.Backend` (3; cap 3)
**Sprint budget**: no new named contract and no project call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Realize the Apple host's closed Lima provider row through the same prepared provider backend vocabulary used
by exact resource settlement.

#### Deliverables

- Construction admits only an Apple-silicon `HostConfig`, the closed Lima provider value, a resolved Lima
  executable, one exact resource envelope, and absolute writable host/guest share paths.
- Semantic and realization fingerprints bind the VM identity, budget, share endpoints, and resolved tool; a
  changed term cannot reopen a package under another backend origin.
- Provisioning executes only the Lima row's closed launch effects, with exact absence/presence observations
  before and after mutation; readiness uses the row's bounded guest probe.
- A provider-bound Lima route admits only that VM and runs host-tool, guest, and provisioning-egress probes
  through the one host-command interpreter.
- Share observation requires the backend-retained host/guest endpoints and a live writable guest directory;
  it mints no independent mount mutation because Lima declares the share at VM creation.
- Forward stop/delete stay `Unsupported`; step-declared reverse remains the sole destructive Lima route.

#### Validation

`ProviderBackendSpec` covers host/provider/tool admission and exact budget/share fingerprint changes; provider
route suites cover the closed binding. The focused provider-backend group and complete core host-static gate
must pass under `--ghc-options=-Werror`. The zero-type/three-module/400-line budgets are checked before Done.

#### Remaining Work

None. Completed 2026-08-26 on aarch64 macOS: the focused provider-backend group passed 29/29, including Lima
admission and exact fingerprint changes, and the complete core host-static gate passed 2,462/2,462 under
`-Werror` in 433.14 seconds. The three-module implementation adds no named type or project call site and stays
below 400 production lines.

### Sprint 24.11: VM provider provision-to-ready adoption [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: one VM provider call-site adoption and no new named contract; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Adopt the exact VM provider resource through provision, ready settlement, and provider-package production.

#### Deliverables

- The VM topology consumes only the Sprint 24.5 provider declaration resolved at the VM target frame and the
  matching plan execution package/slice; no operation-name fallback or caller-built key is accepted.
- One demo call site selects the closed Incus or Lima strong backend, then prepares, runs, journals, and
  settles the provider reconciler under the exact budget and lifecycle bracket before any cluster or descent
  work begins.
- Action-local ready settlement proves the observed backend identity/generation and uses Sprint 24.9 to register
  an invocation-only pending provider package/service. Only the fixed later node reached after `Chain`
  acknowledges the producer gate may open it; failure, retry, or fresh invocation clears it.
- The package, not a managed/running witness, is installed in the interpretation-wide dependency registry for
  subsequent descent; failed or provisional runs install nothing and retain no package.
- This forward adopter writes the exact settled provider journal identity needed by Sprint 24.27's separate
  teardown/command adoption; it does not claim that a `TeardownAction` can consume `PlanExecutionPackage`.

#### Validation

`CommandsSpec` holds source guards over the one adopter (`runExactVmProvider`): stage ordering from prepared
gate through provider registration, the fixed route, both backend branches, and the absence of an
operation-name fallback; it does not run the adopter. Failure unwind and the provision/ready mismatch matrix
(foreign provider, replacement settlement) are owned by the lower provider suites
(`ProviderReconcileSpec`, `ProviderBackendSpec`). The demo host-static gate must pass. The one-adoption/module/line budgets are checked before implementation;
overflow is split before this call site lands.

The one adopter in `HostBootstrapDemo.Commands` receives the interpreter-supplied exact `StepExecution`,
selects the Incus or Lima strong backend without changing the lifecycle call shape, resolves only the
plan-owned provider resource at that execution's opaque operation key, and orders backend discovery,
provision call/settlement, managed Ready call/settlement, carried reverse identity, and pending dependency
package registration. Foreign, failed, and provisional branches return before registration; share,
cluster, and descent remain later in the action/chain. `CommandsSpec` pins both backend branches to this one
adopter and its fixed route, ordering, and no-fallback resource lookup. On 2026-08-26 the focused 61-case
`CommandsSpec` group passed under `--ghc-options=-Werror`.

#### Remaining Work

None. Completed 2026-08-26 on aarch64 macOS: `CommandsSpec` passed 61/61, the complete demo gate passed
145/145, and both the canonical and demo-linked core gates passed 2,462/2,462 under `-Werror`. Python quality
checks and all 231 Python tests also passed.

### Sprint 24.12: Direct provider reservation-to-ready adoption [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: one Direct provider call-site adoption and no new named contract; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Adopt the Direct lane's explicit current-frame provider reservation without pretending it is a VM deployment.

#### Deliverables

- The Direct topology consumes its own plan-declared `core:deploy-vm` provider reservation at the current
  metal frame and the matching exact direct-parent join; that shared provider operation denotes a Direct host
  reservation here and creates no VM resource.
- One demo call site prepares, runs, journals, and settles the Direct provider backend under its exact budget
  and lifecycle bracket before cluster work.
- Action-local ready settlement records Direct backend origin, generation, expected reservation outcome, and
  observation receipt, then registers the invocation-only pending package/service through Sprint 24.9; only the
  fixed later node reached after `Chain` acknowledges the producer gate may open it.
- The package enters only the interpretation-wide dependency registry. No raw host probe, pre-existing socket, generic
  resource key, or caller-supplied readiness boolean substitutes for the settled reservation.
- This forward adopter writes the exact settled Direct reservation journal identity for Sprint 24.27. Direct
  reverse can terminalize only that journal reservation; physical stop/delete are `Unsupported`, and neither
  this sprint nor teardown may claim or fabricate backend release.

#### Validation

`CommandsSpec` covers exact Direct success, absence of VM operations, package production, failure unwind, the
journal identity/static reverse-input projection required by Sprint 24.27, and mismatch refusals; it does not
claim physical reverse release. The demo host-static gate must pass. The one-adoption/module/line budgets are
checked before implementation; overflow is split before this call site lands.

Dated evidence, 2026-08-22: the Direct Linux GPU provider action receives its exact interpreter-supplied
`StepExecution`. Its adopter in `HostBootstrapDemo.Commands` resolves only the current-frame
plan-owned provider resource at that execution's opaque operation key, admits the canonical project root and
configured base-image egress through `mkDirectHostBackendSpec`, and orders reservation provision, managed
Ready, carried reverse identity (`carryCreatedRunningProviderSettlement`, which records phase `running` with
adapter `demo-direct-provider-v1`), and pending Direct package registration.
The separate following `core:build-image` action consumes that reservation before it performs CUDA and
project-image construction; nvkind work and descent remain later. Direct
foreign/failure/provisional paths return before package registration, and the implementation adds no VM
resource, physical reverse claim, or named contract. The one-adoption, one-module, and 400-line budgets hold.
`CommandsSpec` pins the exact current-frame callsite, full ordering, pre-CUDA placement, fixed Direct route,
and absence of operation-name fallback; its existing topology test proves the Direct plan has a current-frame
provider declaration and no VM provider resource, while lower backend suites retain root/egress/mismatch and
failure matrices. The canonical demo host-static gate passed all 130 demo tests and its linked core gate passed
all 2,396 core tests under `-Werror`. Live Direct acceptance remains Sprint 24.30.

#### Remaining Work

None.

### Sprint 24.13: Copy-source managed-share adoption [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: one copy-source share call-site adoption and no new named contract; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Insert the real writable durable copy-source share between the VM provider and container descent, with its
managed handle kept lexical for the immediately nested guest-alias action.

#### Deliverables

- VM/container topology includes the exact plan-declared `copySourceStep` between the settled VM provider and
  child descent; Direct topology has no share or alias step.
- One demo call site opens the fresh provider dependency through the selected Incus or Lima strong backend,
  prepares the exact copy-source resource, reconciles its share, journals ownership, and settles the backend
  observation before descent.
- The writable source is the canonical host durable root and its unchanged absolute guest target is the
  admitted selected-edge target; image, arguments, remove policy, socket, target, read-only flag, and config
  remain unchanged.
- The `ManagedProviderShareHandle` value exists only inside this call site's lexical continuation; no handle
  value enters `CarriedResource`, either execution package, or plan/config bytes. After alias success the
  action carries the share's `provisioned` ownership settlement (`carryProviderShareSettlement`, adapter
  `demo-provider-share-v1`) and registers a `provider-share` runtime-dependency package
  (`registerProviderShareDependencyPackage`), so the share's key, generation, and receipt reach the child frame
  as Sprint 24.31 designs, where a fresh nonce-bound reprobe rebinds them.
- The continuation remains open around Sprint 24.14's alias reconciliation inside this same copy-source action,
  then settles and closes before returning to `Chain` for selected container descent; failure unwinds the share
  and yields no reusable handle or receipt authority.

#### Validation

`CommandsSpec` case `copy-source keeps the exact writable share lexical before VM descent` covers exact stage
ordering, source/target identity, route preservation, Direct-lane absence, and source-shape/non-escape guards
by source offsets and plan topology; no case exercises a failure unwind. The demo host-static gate must pass.
The one-adoption/module/line budgets are checked before implementation; overflow is split rather than moving a
handle across a node.

The VM topology contains one exact `copy-source` node after `deploy-vm` and before the VM descent; Direct
contains none. The shared Incus/Lima action freshly opens the producer's package-bound Running provider,
resolves only its own `DurableShareResource`, prepares with the fresh backend reprobe, reconciles and settles
the exact share, and keeps the managed provider/share handles lexical through mount validation and the nested
alias action. Incus may attach and restart; Lima proves the writable create-time mount retained by its exact
backend. Failure, foreign settlement, replay, and package mismatch return before the continuation can complete;
the handle value stays lexical, and only the settlement and `provider-share` package cross to the child.
Dated evidence, 2026-08-26 on aarch64 macOS: the shared Incus/Lima lexical adopter passed the 61-case focused
`CommandsSpec`, complete 145-case demo gate, and both 2,462-case core gates under `-Werror`.

Closure requires two `CommandsSpec` cases to exist and pass in `cabal test hostbootstrap-demo-test` from
`demo/`, followed by the demo host-static gate: the case `copy-source keeps the exact writable share lexical
before VM descent` with its source slice bounded to the `runExactVmShare` body and the single-carriage
assertions named under Remaining Work, and a new case `dependencyLifetime adds the 1024-version lease or
refuses overflow` holding the rows `dependencyLifetime 0 == Right 1024`,
`dependencyLifetime (maxBound - 1024) == Right maxBound`, and
`dependencyLifetime (maxBound - 1023) == Left "dependency lifetime overflows"`.

#### Remaining Work

- `demo/test/CommandsSpec.hs`, case `copy-source keeps the exact writable share lexical before VM descent`:
  bound `adopterSource` to the `runExactVmShare` body by taking the slice that starts at `runExactVmShare ::`
  up to the next top-level signature `runExactVmProvider ::` (the slice today runs to the end of
  `Commands.hs`). Its assertion `not ("carryManagedResource" isInfixOf adopterSource)` is weak rather than
  vacuous: it cannot catch carriage through the wrapper `carryProviderShareSettlement`, which itself calls
  `carryManagedResourceSettlement`; keep it on the bounded slice. The ordering of
  `carryProviderShareSettlement execution managedShare "demo-provider-share-v1"` after `reconcileNodeGuestAlias`
  is already in `exactCallsite`. Add only: `carryProviderShareSettlement` occurs exactly once in the bounded
  slice, and after that occurrence the slice contains `registerProviderShareDependencyPackage` followed by the
  literal `"runtime://provider-share/demo-vm-share-readiness"`.
- `demo/src/HostBootstrapDemo/Commands.hs`: add and export
  `dependencyLifetime :: Word64 -> Either String Word64`, returning `Right (now + 1024)` when
  `now <= maxBound - 1024` and `Left "dependency lifetime overflows"` otherwise. Use it at all four
  dependency-package registration sites, each prefixing its own failure noun to the `Left` text and failing
  before any registration effect: `deployKindAction` (`cluster reconcile: `, replacing its
  `when (... > maxBound - 1024)` guard and the unchecked `now + 1024` it passes to
  `registerClusterRuntimeDependencyPackage`), `runExactVmProvider` (`VM provider reconcile: `) and
  `runExactDirectProvider` (`Direct provider reconcile: `), each replacing its `when` guard and its
  `preparedGateJournalVersion gate + 1024` argument, and `runExactVmShare`
  (`copy-source reconcile: `, through its local `failLifecycle`, replacing the unchecked `now + 1024` it passes
  to `registerProviderShareDependencyPackage`). Add the `CommandsSpec` case
  `dependencyLifetime adds the 1024-version lease or refuses overflow` with the three rows named under
  Validation.

### Sprint 24.14: Lexically nested guest-alias adoption [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: one guest-alias call-site adoption and no new named contract; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/operations/demo_runbook.md`

#### Objective

Reconcile the VM guest alias while the exact provider and share handles are simultaneously live in the one
copy-source action.

#### Deliverables

- The sole demo alias call is inserted inside Sprint 24.13's managed-share continuation, so the freshly opened
  provider handle and exact share handle coexist lexically in the same action.
- `reconcileNodeGuestAlias` receives the exact plan-declared provider, share, alias, and target identity; it
  cannot reconstruct either handle from `CarriedResource`, a receipt, or a later execution node.
- Alias settlement completes inside the share continuation before that action returns; only then may `Chain`
  continue to selected container descent. No managed share handle remains open across the later descent node.
- Direct topology proves the alias action absent, and VM topology refuses missing share settlement, wrong
  provider origin, wrong durable source/target, replay, or a closed provider/share bracket.
- The existing partial alias/projector work remains mutable and does not make this sprint Done; no compatibility
  export, demo-local handle constructor, or cross-node handle carrier is permitted.

#### Validation

`CommandsSpec` covers lexical nesting, ordering, the settled journal transition/static reverse input required by
Sprint 24.27, Direct absence, mismatch refusal, and non-escape source guards; reverse adoption itself remains
24.27. The demo host-static gate must pass. The one-adoption/module/line budgets are checked before the call-site
work is completed; overflow is split without separating share from alias.

On 2026-08-22 `copy-source` began declaring its exact `core:copy-source/guest-alias` projection and the Incus
managed-share continuation replaced the compatibility `mintDurableAlias` call with the lower exact alias
reconciler. Fresh recovery now rebinds erased carrier evidence to the exact planned provider identity before
opening its rank-2 backend/provider continuation; that planned provider, its managed Running handle, the exact
planned/managed share pair, stable alias path, unchanged provider-selected target, and live mount probe enter
`reconcileNodeGuestAlias` together. Provider-bound capability discovery and strong-alias narrowing occur inside
the share settlement continuation, and alias settlement completes before it returns to `Chain`; neither handle
can reach the descent node or a carrier. Direct declares neither copy-source nor the alias projection. This adds
no named contract and remains one call-site adoption in one demo production module under 400 lines.
`CommandsSpec` pins the projection, target, lexical nesting, exact reconciler route, Direct absence, and removal
of the compatibility mutator; the lower alias suite retains the complete origin/source/target/replay/closed-
bracket mismatch matrix. The demo gate passed all 132 tests and the complete core host-static gate passed all
2,396 tests under `-Werror`.

#### Remaining Work

None.

### Sprint 24.15: Canonical provider-package wire vocabulary [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`
**Production modules**: `HostBootstrap.Handoff`, `HostBootstrap.Handoff.Protocol`,
`HostBootstrap.Lifecycle.Dependency.Internal` (3; cap 3)
**Sprint budget**: no new named contract and no call-site adoption; at most 400 production Haskell lines. Split
before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Define the canonical provider-package commitment and reprobe request/response bytes carried by the existing
authenticated handoff protocol, without encoding a closure or runtime witness.

#### Deliverables

- Closed protocol tags encode the provider domain, exact canonical package commitments, bounded request nonce,
  observation result, refusal reason, and expiry; unknown tags and noncanonical encodings fail closed.
- Wire bytes never encode a closure, backend command, `ManagedProviderHandle`, `ManagedProviderShareHandle`,
  `RunningProviderDependency`, `ClusterReadiness`, journal writer, receipt authority, or reusable secret.
- No live-service closure ever enters the package or encoder. A receiver can construct only the hidden bounded
  client route supplied by Sprints 24.17–24.18 after authenticated admission, never deserialize executable code.
- Request and response bytes bind the Handoff route, plan, scope, resource, frame, backend origin, generation,
  journal/ready commitments, request nonce, and Process invocation lifetime.
- Canonical round trips preserve exactly the committed fields; wrong domain, duplicate fields, trailing bytes,
  oversized input, changed binding, replayed nonce, or expired lifetime is an explicit protocol refusal.

#### Validation

`HandoffSpec` and `LifecycleDependencySpec` cover canonical golden bytes, round trips, all malformed or
forbidden cases, and a source guard excluding witness serialization. The core host-static gate must pass. The
module and 400-line budgets are checked before implementation; any new type or adoption is split out.

Closure requires the refusal cases named under Remaining Work to exist and pass under `cabal test all` from
`core/`, each asserting its exact refusal text, followed by the core host-static gate.

On 2026-08-22 the provider-package codec gained its closed provider/cluster domain decoder, exact twelve-field
canonical re-render check, 64-KiB package bound, and 128-KiB request/response bound. The authenticated handoff
vocabulary gained the three closed singleton-field tags and a raw-byte facade for package, request, success,
and explicit-refusal frames; it deliberately adds neither a state-machine adoption nor a named contract.
`LifecycleDependencySpec` passed all 6 focused tests covering exact golden bytes, round trips, malformed and
noncanonical fields, changed commitments, replay, empty refusal, oversize, and the forbidden-witness source
guard. `HandoffSpec` passed all 108 tests including facade framing, duplicate fields, changed nonce, and the
closed-tag source guard. The three production modules remained within the 400-line sprint budget (56
significant lines in `HostBootstrap.Handoff`, 15 in `HostBootstrap.Handoff.Protocol`, and the bounded codec
addition in `HostBootstrap.Lifecycle.Dependency.Internal`), with no call-site adoption. The complete core
host-static gate passed all 2,399 tests under `-Werror` on `linux-cpu`.

#### Remaining Work

- `LifecycleDependencySpec` bundle decoder (`runtimeDependencyPackagesFromBundleWire`) cases:
  - an empty package list (`runtime dependency package bundle is empty`);
  - 17 packages (`runtime dependency package bundle has too many packages`);
  - a `hostbootstrap/runtime-dependency-bundle/v2` domain (`runtime dependency package bundle domain mismatch`);
  - a non-canonical inner length (`runtime dependency package bundle is not canonical`);
  - a well-formed wire over 512 KiB (`runtime dependency package bundle exceeds its canonical bound`).
  Add the encoder's empty, too-many, and size refusals for `runtimeDependencyPackageBundleWire`.
- `LifecycleDependencySpec` package decoder (`runtimeDependencyPackageFromWire`) cases:
  - version `hostbootstrap/runtime-dependency/v2` (`runtime dependency package version mismatch`);
  - domain `other` (`runtime dependency package domain is unknown`);
  - from `parseWireFields`, a missing `:` delimiter, a truncated frame, and invalid UTF-8.
- `LifecycleDependencySpec` oversized-frame cases: the package case (`64 * 1024 + 1` bytes of `x`) and the
  chart-request case (`256 * 1024 + 1` bytes of `x`) are refused by `parseWireFields` whether or not the bound
  exists. Build each input as a well-formed, canonically length-prefixed frame just past its bound. Assert
  that the message contains `exceeds its canonical bound` instead of accepting any `Left`.
- `HandoffSpec`: zero-field and two-field inputs to `providerDependencyPackageFromFields`,
  `providerDependencyPackagesFromFields`, `providerDependencyProbeRequestFromFields`,
  `providerDependencyProbeResponseFromFields`, and `withAuthenticatedProviderDependencyProbeRequest`, each
  asserting its `... field count differs` refusal.

### Sprint 24.16: Caller-free provider reprobe service kernel [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Production modules**: `HostBootstrap.Handoff`, `HostBootstrap.Handoff.Protocol`,
`HostBootstrap.Handoff.Relay` (3; cap 3)
**Sprint budget**: no new named contract and no call-site adoption; at most 400 production Haskell lines. Split
before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Define the caller-free provider reprobe service kernel for the root or parent that owns the real provider
backend; installation in the Process bracket belongs to Sprint 24.17.

#### Deliverables

- A caller-free kernel accepts an already-authenticated bounded request plus a lexical live provider probe and
  returns a canonical response; this sprint installs no service and imports no future `Handoff.Process`.
- Each request is authenticated against the exact admitted handoff binding, route, invocation generation,
  package commitment, request nonce, and the journaled provision-plus-ready evidence before backend access.
- The owning root/parent performs the real backend probe locally through `probeRunningProvider`, which
  observes the Direct, Incus, and guest-VM backends (the guest-VM row serves both Lima and WSL2); a child is
  never asked to discover host tools or treat channel reachability as provider readiness.
- A response is canonical, nonce-bound, origin/generation-bound, single-request evidence only. It conveys no
  handle, reusable probe authority, HMAC key, journal writer, or capability that survives the duplex bracket.
- Wrong route, commitment, ownership evidence, generation, nonce, backend identity, replay, timeout, or closed
  provider produces an authenticated refusal and no fresh dependency.

#### Validation

`HandoffSpec` and `RecursiveLifecycleSpec` use real local duplex fixtures and fake backend observations to cover live
success, all binding/lifetime/refusal cases, and non-export of backend authority. The core host-static gate must
pass. The one-adoption/module/line budgets are checked before implementation; overflow is split. Closure
requires the capacity and package-domain cases named under Remaining Work to exist and pass under
`cabal test all` from `core/`, followed by the core host-static gate.

On 2026-08-22 the caller-free kernel began opening every provider package coordinate and its exclusive
lifetime before backend access, atomically consuming one of at most 64 bracket-local nonces, and bounding the
lexical observation to 100 milliseconds. Exact-generation observations produce canonical success fields; replay,
capacity exhaustion, timeout, provider closure/refusal, and generation change produce canonical nonce-bound
refusals, while malformed or mismatched requests never reach the probe. The continuation receives only a
byte-field handler and the kernel installs no Process endpoint, exports no backend authority, adds no named
contract, and adopts no call site. `HandoffSpec` passed all 109 tests, including success, route mismatch,
single-use replay, closure, changed generation, timeout, and sealed ownership; `RecursiveLifecycleSpec` passed
all 6 real-process/local-kernel cases with a fake exact-generation observation. The implementation touched the
three declared production modules and added 62 significant facade lines plus a small Relay alias, remaining
well below 400 production lines. The complete core host-static gate passed all 2,401 tests under `-Werror` on
`linux-cpu` in 157.01 seconds.

#### Remaining Work

- `HandoffSpec` (beside the kernel cases near line 330-383): drive `withProviderDependencyReprobeKernel` with 65
  distinct nonces and assert that the 65th answers `provider dependency probe request limit was reached`
  without calling the probe (an `IORef` counter stays at 64).
- `HandoffSpec`: pass a `provider-share` package to the provider-only endpoint
  (`withAuthenticatedProviderDependencyProbeRequest` through `requireProviderPackage`) and assert
  `provider dependency package domain mismatch`. Pass a `cluster` package where
  `requireCarriedProviderDependencyPackage` applies and assert
  `carried provider dependency package domain mismatch`.

### Sprint 24.17: Keyless multi-hop reprobe relay and child client [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Production modules**: `HostBootstrap.Handoff.Relay`, `HostBootstrap.Handoff.Receiver`,
`HostBootstrap.Handoff.Process` (3; cap 3)
**Sprint budget**: one Process-owned service installation and no new named contract; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Relay exact reprobe frames across nested live Process duplexes without distributing root authentication keys or
allowing an intermediate frame to reinterpret them.

#### Deliverables

- The production carrier path (`withCarriedProviderDependencyFromCarrierKernel`, through
  `withCarriedProviderDependencyForwardLifecycleChildProcess`) is the one internal installation: it places every
  registered `provider` and `provider-share` service behind a bracket-scoped duplex endpoint inside the live
  `Handoff.Process` exchange, and closing either bracket irreversibly closes service and clients. Each request
  through that endpoint holds Sprint 24.16's kernel bounds: at most 64 bracket-local nonces, a probe deadline
  at the owning endpoint, and a canonical nonce-bound refusal (`renderRuntimeDependencyProbeRefusal`) for
  replay, capacity, timeout, and probe failure.
- An intermediate parent validates only its immediate transport framing and relays the exact canonical payload
  bytes toward the owning root/parent and back; it receives no root key, handle, or authority to mint a result.
  It waits for the upstream answer without a timeout of its own, as `relayRootedLifecycle` does, so no framed
  read on the parent channel is interrupted part way. The time bound is the owning endpoint's.
- The child-side hidden client binds each fresh nonce to the admitted immediate-edge route and invocation
  lifetime, accepts exactly one matching authenticated response, and exposes only package-private probe output.
  A parent refusal carrying the edge's request identity reaches the caller as `ReceiverRefusedByParent` with
  the parent's code and detail.
- The child client (`withProviderDependencyClientKernel`) is open only while its edge is live: it shares one
  per-edge liveness flag with `sendReport`, so a call after the terminal report is delivered, or a second
  call while one is in flight on the same edge, refuses without sending a frame. The endpoint installer
  (`withProviderDependencyReprobeEndpointKernel`) fixes its continuation's result to `Either Text ()`, so the
  installed `BrokerLink` cannot be returned out of the Process exchange that owns it.
- Relay depth, frame size, deadline, outstanding request count, and response count are bounded; cross-route
  substitution, reflection, duplicate response, late response, truncation, or unknown tag fails closed.
- No alternate socket, environment variable, argv term, config field, durable file, generic carrier, or
  caller-supplied executable can become a reprobe channel or long-lived authority.

#### Validation

`HandoffSpec` and `RecursiveLifecycleSpec` cover one-hop and multi-hop success, keylessness, bounds, close
races, replay/reflection/substitution refusal, and absence of alternate channels. Closure requires the
behavioural production-path, edge-liveness, and compile-fail cases named under Remaining Work to exist and pass
in `HandoffSpec`, `RecursiveLifecycleSpec`, and `CompileFailSpec` under `cabal test all` from `core/`, then the
core host-static gate. The module and 400-line budgets are checked before implementation; any new type or adoption
is split.

The production child descent (`Command/Child.hs`, `Command/LifecycleEntry.hs`) installs the endpoint through
`withCarriedProviderDependencyFromCarrierKernel`, whose endpoint calls the registered Sprint 24.9 service
(`invokeStepRuntimeDependencyService`) directly; that service carries an unbounded replay list, no probe
deadline, and unframed text refusals. `withProviderDependencyForwardLifecycleChildProcess`, which nests the
caller-free kernel, has no caller, and the `HandoffSpec` substring guard ("Process does not own the provider
service installation") passes over that uncalled function.

Dated evidence, 2026-08-22: a record-narrowed `BrokerLink` endpoint sits inside the existing forward
child-process exchange, and root links refuse without that lexical installation. An admitted child's hidden
receiver client uses only its retained channel
and request identity, permits one outstanding request, consumes at most 64 nonces, and accepts exactly the
closed matching response before the package codec verifies commitment, nonce, and outcome. Each intermediate
link forwards the exact field list through its authenticated parent channel, with a one-second upstream
deadline; it receives no endpoint authority or result constructor. The implementation adds no named contract,
socket, environment/config/argv/file route, generic carrier, or call-site adoption and stays within the three
declared modules and 400-line budget. `HandoffSpec` passed all 110 cases, including the live kernel matrix and
static one-hop/multi-hop route, keylessness, endpoint lifetime, bounds, and alternate-channel ownership; the
existing 6-case `RecursiveLifecycleSpec` retained its real two-boundary topology and exact fake observation
fixture. The complete core host-static gate passed all 2,402 tests under `-Werror` on `linux-cpu` in 155.88
seconds.

#### Remaining Work

- `Handoff/Process.hs`: make the endpoint built by `withCarriedProviderDependencyForwardLifecycleChildProcess`
  apply the 24.16 kernel bounds around each retained service call: decode the request nonce, refuse a replayed
  nonce and the 65th distinct nonce, run the service under the kernel's probe deadline, and answer every
  refusal through `renderRuntimeDependencyProbeRefusal` for the matched package. Reuse the kernel's bound
  constants from `HostBootstrap.Handoff` rather than restating them.
- `Handoff/Process.hs`: delete the uncalled `withProviderDependencyForwardLifecycleChildProcess` and its export.
  `Handoff/Relay.hs`: delete the uncalled `withProviderDependencyReprobeServiceKernel`, an alias of
  `Handoff.withProviderDependencyReprobeKernel`, and its export. Remove both names from `HandoffSpec`'s frozen
  export lists.
- `Handoff/Relay.hs` `relayProviderDependency`: delete the `timeout providerRelayMicros` around the framed
  `await` (and `providerRelayMicros`). On expiry, that timeout can interrupt `readProtocolMessage` part way and
  leave a partly consumed frame on the parent channel, and it sends no refusal upstream. Test: a `HandoffSpec`
  two-hop case whose owning endpoint answers after 1.2 seconds delivers that answer to the grandchild, and a
  second request on the same parent channel then succeeds. This shows the channel stays in frame.
- `Handoff/Receiver.hs` provider-dependency client: in both receive arms (the package announcement and the
  probe response), map a `RefusedTag` message carrying the edge's request identity to `refusalFrom message`
  before the tag-mismatch check, rather than to `ReceiverMalformedMessage RefusedTag 2`. Test: a
  `RecursiveLifecycleSpec` (or `HandoffSpec` duplex) case where the parent answers a probe with `refuse`
  asserts `ReceiverRefusedByParent` carrying the parent's code and detail.
- `HandoffSpec` carrier-level endpoint cases for `withCarriedProviderDependencyForwardLifecycleChildProcess`.
  Each case asserts the endpoint's exact refusal text and that no service ran:
  - with one registered provider package, a request wire naming it succeeds, and one naming an unregistered
    package refuses;
  - with two registered provider packages, a request whose fields match both refuses as ambiguous;
  - a request whose fields changed after validation refuses.
- `HandoffSpec`: replace the substring guard "Process does not own the provider service installation" and the
  export-list entry with behavioural cases over the production endpoint, using a registered service: a probe
  that sleeps past the deadline yields the canonical `provider dependency probe timed out` refusal; 65 distinct
  nonces yield `provider dependency probe request limit was reached` on the 65th; a repeated nonce yields the
  canonical replay refusal; and a probe returning `Left` yields a canonical nonce-bound refusal, not raw text.
- `Handoff/Receiver.hs` `withProviderDependencyClientKernel`: gate it on a per-edge liveness and in-flight flag
  that `sendReport` closes once the terminal report is delivered; a closed or busy edge returns a
  `ReceiverError` without calling `channelSend`. Tests in `RecursiveLifecycleSpec` (or a `HandoffSpec` duplex):
  a call after `sendReport` and a nested call inside the client's own continuation each return the refusal, and
  the parent's recorded inbound frames show no `ProviderDependencyPackageTag` for either.
- `Handoff/Relay.hs` `withProviderDependencyReprobeEndpointKernel`: change the continuation's type from
  `BrokerLink scope brokerGeneration -> IO result` to `BrokerLink scope brokerGeneration -> IO (Either Text ())`,
  the type both `Handoff/Process.hs` callers already use, and keep the Haddock's no-escape claim. Add a
  compile-fail fixture under `core/hostbootstrap-core/test/compile-fail/`, registered in `CompileFailSpec`,
  that passes `pure` as the continuation and must fail to type-check.

### Sprint 24.18: Authenticated child package admission [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`, `core/hostbootstrap-core/test/ChainSpec.hs`
**Production modules**: `HostBootstrap.Handoff.Process`, `HostBootstrap.Command.Child`,
`HostBootstrap.Chain` (3; cap 3)
**Sprint budget**: one authenticated child-descent call-site adoption and no new named contract; at most 400
production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Admit and seed the canonical provider package only after authenticated child descent; fresh parent-serviced
provider opening remains inside Sprint 24.23's cluster action.

#### Deliverables

- One child-descent call site accepts provider-package bytes only after Phase 17 authenticates the child plan,
  canonical config, immediate selected topology edge, `HandoffBindingInput`, invocation, and live Process route.
- Admission decodes each canonical package, requires the provider or provider-share domain, and before the frame
  executor opens checks its plan commitment against the parent plan digest and its frame against the parent
  frame that the edge's `VerifiedHandoff` binds, its scope against the edge's authenticated root scope, and its
  resource against the dependency keys of the admitted child plan's local nodes. Only then does it install the
  package with the Sprint 24.17 hidden client into the interpretation-wide registry shared by all child
  `StepRuntime`s; no running witness is seeded.
- This adoption stops after canonical package admission and client attachment. It never calls the provider
  opener or produces a `RunningProviderDependency`; Sprint 24.23 owns that fresh lexical refinement.
- The child cannot select a host executable, backend command, probe route, or SelfRef, and no Managed/Running/
  Readiness witness, key, or raw channel enters plan bytes, config, environment, argv, or a carrier.
- Wrong ancestry edge, child-local plan/config digest, package commitment, binding, nonce, generation, replay,
  timeout, or closed duplex refuses before cluster preparation and unwinds the descent bracket.

#### Validation

The sprint closes when these behavioural cases exist and pass in the core host-static gate:

- `RecursiveLifecycleSpec` drives `withProviderDependencyClientKernel` over a real two-process duplex and asserts
  `ReceiverDeclined` for a second request while one is outstanding, a replayed `(package, nonce)` pair, a request
  past `providerClientRequestLimit`, and a package not in the admitted set, plus `ReceiverWrongEdge` for a
  response or package announcement carrying another request identity and `ReceiverProtocolFailure` for a closed
  duplex.
- `RecursiveLifecycleSpec` sends a provider package whose plan commitment, frame, scope, or resource differs from
  the authenticated edge and child plan, and a cluster-domain package, and asserts that each child descent refuses
  before the frame executor runs any local node.
- `ChainSpec` keeps its package-only seed/no-witness source guard; a source guard is not counted as refusal
  coverage.

The one-adoption/module/line budgets are checked before implementation; any overflow is split.

On 2026-08-22 the one forward-child descent adoption queried the already authenticated edge for its
parent-selected provider package on every child descent, whatever the local plan's dependencies. The query
carries no candidate package; Relay returns the Process endpoint's exact canonical package or explicit
absence. A present provider-domain package is registered in the child's invocation-wide `ResourceCarrier`,
and the hidden nonce client is attached in its distinct live-service registry before the frame executor opens.
Every local `StepRuntime` shares that carrier, and deeper descents forward the same canonical package and fixed
service. Admission performs no probe and names no `RunningProviderDependency`, managed provider/share handle,
or cluster-readiness witness. `ChainSpec` passed all 44 cases including the package-only seed/no-witness source
proof, `HandoffSpec` passed all 110 bounded transport cases, and `RecursiveLifecycleSpec` passed all 6 real
two-process-boundary cases including explicit package absence. The three declared production modules remained
within the no-new-contract and 400-line sprint budget, and the child owner remained below its pre-existing
two-split 800-significant-line ceiling. The complete core host-static gate passed all 2,403 tests under
`-Werror` on `linux-cpu` in 160.83 seconds.

#### Remaining Work

- `Command/Child.hs` `openFrame` (with `seedProviderDependencyCarrierKernel` in `Handoff/Process.hs`): before
  `opened` runs `withOpenedFrameExecutorForPlanKernel`, refuse each admitted package whose plan commitment is not
  the parent plan digest bound by `receivedEdgeHandoff edge`, whose frame is not that handoff's parent frame,
  whose scope is not `receivedEdgeAuthenticatedRootScope edge`, or whose resource is not a dependency key of a
  local node of the admitted child plan. Return `ReceiverDeclined` with a message naming the mismatched field.
  Test: the `RecursiveLifecycleSpec` mismatched-package cases listed in Validation.
- `RecursiveLifecycleSpec`: add the `withProviderDependencyClientKernel` refusal cases listed in Validation,
  each asserting the exact `ReceiverError` constructor and message.
- `HandoffSpec` (or `RecursiveLifecycleSpec`): seed `seedProviderDependencyCarrierKernel` with a `cluster`-domain
  package and assert its non-provider domain refusal, with no carried ownership transferred into the child
  carrier (`readCarriedResources` is empty). Seed a `provider` package and assert that its resource,
  generation, and operation are carried with no settlement bytes.

### Sprint 24.19: Exact rendered cluster config and exposure intent [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/ClusterConfig.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/test/ClusterConfigSpec.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.ClusterConfig`, `HostBootstrapDemo.Config`,
`HostBootstrapDemo.Commands` (3; cap 3)
**Sprint budget**: no new named contract and no lifecycle call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`,
`documents/operations/demo_runbook.md`

#### Objective

Render exact canonical Kind/nvkind configuration and semantic exposure intent from digest-matched plan
metadata before any cluster backend is selected.

#### Deliverables

- The pure demo renderer `renderExactClusterConfig` consumes Sprint 24.7's exact cluster slice, the finalized
  config projection, and one declared Docker-visible host data path, verifies the retained config digest, and
  emits canonical bytes plus their digest and deterministic state/config paths. The host data path is the fixed
  `durableDockerHostPath` on the VM lane. On the Direct lane the cluster action reads it from Docker's inspection
  of the project container's durable mount (`discoverDirectDockerHostDataPath`), so Direct bytes depend on that
  observation as well as on plan metadata.
- The closed driver value selects only Kind or nvkind rendering; driver-specific node, mount, accelerator,
  network, and kubeconfig fields are total and unknown driver text is unrepresentable.
- The projection declares a closed set of service identities, protocols, and stable cluster-internal targets.
  Canonical Kind/nvkind bytes contain no host-side port number or `extraPortMappings`; host publication is a
  later owned runtime result rather than configuration.
- The VM/container render preserves the selected writable durable target and cluster topology, while Direct
  rendering contains no VM/share/alias fiction; both retain the same exact cluster resource identity.
- Canonical output is a fixed-order rendering. `requireCanonicalPath` refuses a durable target or Docker-visible
  path that is relative, not `Posix.normalise`-canonical, or contains a `..`, `.`, or empty segment;
  `verifyExactClusterConfig` refuses noncanonical or extended bytes; digest or slice disagreement refuses.
  Symlink and file-identity checks are intentionally deferred to the later IO backend under its lock.

#### Validation

`ClusterConfigSpec` covers Kind/nvkind golden output, both topologies, exact semantic targets, absence of
host-port rendering, digest agreement, slice refusal, and noncanonical-byte refusal; `CommandsSpec` pins the
committed configs' absence of `extraPortMappings:` and `hostPort:`. A source guard rejects numeric host-port
policy in Dhall, Haskell, generated Kind/nvkind YAML, and chart/test client fixtures. The sprint closes when the
`ClusterConfigSpec` path-label and intent-target cases in Remaining Work exist and the demo host-static gate
passes. The module/400-line
budgets are checked before implementation; any type, adoption, fourth module, or overflow is split.

On 2026-08-23 `ClusterConfigSpec` covered both golden renderings and the complete demo gate passed 142/142
under `--ghc-options=-Werror`.

#### Remaining Work

- `demo/src/HostBootstrapDemo/ClusterConfig.hs` `requireCanonicalPath`: take the path's role label
  (`cluster durable target` for the child-frame durable root, `Docker-host data path` for the Docker-visible
  mount source) and put the label and the offending path in every refusal, so a bad Docker-host source is not
  reported as a bad durable root.
- `demo/test/ClusterConfigSpec.hs` "digest, slice, and paths fail closed": add cases for
  `renderExactClusterConfig` with a Docker-visible path of `/srv/demo/../.data`, `/srv/./demo`, and
  `/srv//demo`, each asserting the exact `Left` text: `demo cluster config: Docker-host data path ...` naming the
  path and its reason (not absolute, not lexical-canonical, escapes lexically), beside the existing
  relative-path case; add one durable-target case asserting the `cluster durable target` label.
- `ClusterConfig.hs`: build the exposure intents' relay target from the plan-owned base the node mappings come
  from (`planOwnedClusterName base ++ "-control-plane"`), not from `resolvePlanWithDriver` over the config's own
  project and profile; `renderExactClusterConfig` takes that cluster name from `withExactPlanOwnedClusterConfig`.
  Add a `ClusterConfigSpec` case asserting every intent's target equals the control-plane node mapping of the
  wrapper it is bound in, for a Production and a Harness base.

### Sprint 24.20: Plan-owned cluster driver/config package [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`demo/src/HostBootstrapDemo/ClusterConfig.hs`, `core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`demo/test/ClusterConfigSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Cluster.Lifecycle`, `HostBootstrap.Cluster.Reconcile`,
`HostBootstrapDemo.ClusterConfig` (3; cap 3)
**Sprint budget**: one new named type, `PlanOwnedClusterConfig`, and no call-site adoption; at most 400
production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/generic_project_model.md`

#### Objective

Bind the exact closed driver, canonical rendered config, exposure intents, and plan-owned cluster package into the one
input accepted by cluster preparation.

#### Deliverables

- Opaque `PlanOwnedClusterConfig` is the sole named type and binds the exact existing `PlanOwnedCluster`, closed
  Kind/nvkind driver, canonical bytes/digest, config/state paths, semantic exposure intents, node mappings, and workload slice.
- `withPlanOwnedCluster` first constructs the existing base `PlanOwnedCluster` from the planned provider
  resource and admitted provider→cluster edge (`withExecutionOwnedCluster` on the action side), without runtime
  dependency or config recursion; the base join refuses a provider that is not an exact dependency of the
  cluster node and a budget slice of another cluster resource. The binder `withPlanOwnedClusterConfig`, exported
  from `HostBootstrap.Cluster.Lifecycle`, then produces the wrapper. Core cannot render a project's config, so
  the binder checks structure rather than canonical-render equality: non-empty bytes of at most 1 MiB whose
  SHA-256 equals the supplied digest, state and config paths equal to the driver-derived paths under the
  plan-owned durable root, no `hostPort:` or `extraPortMappings:`, a non-empty duplicate-free intent set, node
  mappings equal to the closed driver's node suffixes, and a non-empty duplicate-free workload slice. The demo's
  only producer, `withExactPlanOwnedClusterConfig`, renders through Sprint 24.19's `renderExactClusterConfig`
  under the same driver it binds, so the canonical-render and driver/config match is the consumer wrapper's.
  Runtime dependency is consumed only when preparing the reconcile.
- Cluster preparation hardcodes no `Kind` driver and resolves no driver independently; it consumes the completed
  wrapper and exposes no raw path, driver text, or alternate config argument.
- `PreparedClusterReconcile` retains that exact package so every reconcile, cordon, readiness, and cleanup
  operation observes one driver, bytes digest, path set, mapping set, and ownership identity.
- Each binder or base-join refusal above returns `ClusterPackageMismatch` before backend discovery or mutation.

#### Validation

`ClusterReconcileSpec` covers exact retention of driver, bytes, intents, mappings, and workload slice, the
plan-derived config digest, and a Harness plan's isolated config; `ClusterConfigSpec` covers the demo render;
compile-fail fixtures cover sole construction. The source-text case "the config binder is closed over both
drivers and every independent mismatch" pins message presence only and is not refusal coverage. The sprint
closes when the behavioural binder cases in Remaining Work exist and the core and demo host-static gates pass.
The sole-type/module/line budgets are checked before implementation; overflow is split.

On 2026-08-23 the complete core gate passed 2,428/2,428 and the demo gate passed 142/142 under
`--ghc-options=-Werror`.

#### Remaining Work

- `core/hostbootstrap-core/test/ClusterReconcileSpec.hs`: add one behavioural case per binder refusal that calls
  `withPlanOwnedClusterConfig` on the fixture's base package with exactly one input changed and asserts
  `Left (ClusterPackageMismatch msg)` with the exact message: a digest that differs from the bytes, a state path
  and a config path off the driver-derived location, bytes containing `hostPort:`, bytes containing
  `extraPortMappings:`, an empty intent set, two intents for one service, Kind node mappings bound under
  `NvkindDriver`, and an empty or duplicated workload slice. Add a positive case binding the same base under both
  `KindDriver` and `NvkindDriver` with each driver's mappings.
- `demo/test/ClusterConfigSpec.hs`: add a case asserting `withExactPlanOwnedClusterConfig` yields a wrapper whose
  `planOwnedClusterConfigBytes` equal `renderExactClusterConfig`'s bytes for the same driver, for Kind and nvkind,
  and whose node mappings are exactly `[control-plane -> <cluster>-control-plane]` for Kind and
  `[control-plane -> <cluster>-control-plane, worker -> <cluster>-worker]` for nvkind.

### Sprint 24.21: Closed Kind/nvkind cluster and exposure backend [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Cluster.Backend`, `HostBootstrap.Cluster.Backend.Internal` (2; cap 3)
**Sprint budget**: no new named contract and no project call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/operations/demo_runbook.md`

#### Objective

Resolve the plan-owned Kind or nvkind driver into one closed backend that retains every exact host tool and
config term needed for reconcile, runtime-owned relay exposure, cordon, readiness, and cleanup.

#### Deliverables

- Backend discovery consumes only `PlanOwnedClusterConfig` and resolves exactly the closed Kind or nvkind
  branch; caller-selected driver names, executables, paths, and argument lists are absent.
- `discoverStrongClusterBackend` probes nothing. Tools are resolved once into the typed `HostConfig` (§ K), and
  discovery admits the backend only when the branch's creation driver and Docker, Kubectl, and Helm all resolve
  there; a missing tool is `Unsupported` and mints no capability. The hidden `StrongClusterBackend` retains that
  `HostConfig`, the closed driver, the canonical config bytes and digest, the ownership identity, the
  plan-owned kubeconfig path, and a readiness-version counter. It retains no per-tool executable identity and no
  store: the writable state directory and the Phase 16 clause-holding protected store are established when each
  transaction enters it. Flock, Python, and supervisor identities are absent; Phase 16 owns no such locking
  front end or interpreter and this sprint does not create one.
- Every subprocess invocation is generated internally from the retained branch and exact package; nvkind never
  falls back to Kind and a Kind backend refuses an nvkind package before any command.
- Existing reconcile, applied-cordon, readiness, and cleanup calls accept only the resolved closed backend and
  retain their lock, fresh-observation, generation, and exact-identity guarantees.
- After cluster readiness, the backend realizes Sprint 24.19's service intents through the generic
  cluster-lifecycle exposure operation. The exact derived project image supplies the hidden relay process;
  Docker joins it to the cluster network and atomically publishes each relay listener on loopback with no
  host-side number. Exact inspection returns one resolved mapping per declared service and no others.

#### Validation

`ClusterBackendSpec` and compile-fail fixtures cover both branches, `HostConfig` tool admission ("a configuration
missing one cluster tool mints no capability", "a configuration carrying all three is admitted with no probe"),
exact invocations, replacement/mismatch refusal, no fallback, and all lifecycle operations. The core host-static gate must pass.
The module and 400-line budgets are checked before implementation; any new type or adoption is split.

#### Remaining Work

None. Completed 2026-08-23. The closed backend creates one identity-labelled immutable-image relay on the Kind
network, lets Docker select loopback ports, exact-inspects every declared mapping, and conditionally releases
only the recorded identity. Focused exposure tests passed 11/11, all 519 compile-fail boundaries passed, and
the complete core gate passed 2,428/2,428 under `--ghc-options=-Werror`.

### Sprint 24.22: Cluster-domain readiness and exposure recovery [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Cluster.Backend`, `HostBootstrap.Cluster.Reconcile`,
`HostBootstrap.Lifecycle.Dependency.Internal` (3; cap 3)
**Sprint budget**: no new named contract and no project call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Produce and later open a cluster-domain runtime package so successors receive freshly reprobed lexical
`ClusterReadiness` and exact resolved exposures, never carried witnesses or reconstructed ports.

#### Deliverables

- Only exact action-local reconcile settlement followed by applied cordon and ready settlement may register a
  pending cluster-domain package; its commitments bind the plan-owned cluster config, driver/backend origin,
  generation, expected ownership/cordon/ready outcomes, route, and expiry without claiming a committed row.
  `registerClusterRuntimeDependencyPackage` refuses a producer gate for another plan before it runs any
  exposure call, so a refused registration starts no relay and writes no exposure record.
- The cluster service's probe and exposure response renderers apply the bounds their verifiers enforce, so the
  service never sends wire that every client rejects.
- `Cluster.Backend` registers the bounded fresh-readiness closure in an invocation-owned opaque live-service
  registry separate from the canonical package registry. The closure captures the strong backend/readiness
  source; no `ClusterReadiness` witness is stored in either registry.
- The hidden cluster-domain opener (`withFreshClusterRuntimeDependency`) is available only to the fixed successor
  node after `Chain` acknowledges the producer gate. Through `withClusterRuntimeDependencySuccessor` it checks the
  successor-visible coordinates: cluster domain, plan digest, scope, resource key, frame, the carried handle's
  generation, route, and expiry. The backend origin is read from the package itself, and the journal and ready
  commitments are not compared by the opener; all three stay bound by the package commitment that selects the
  separate live service. It then executes a fresh backend readiness observation and passes the verified probe
  response to the recovered-readiness producer `withRecoveredClusterReadiness`, which Sprint 16.10 places in the
  hidden `HostBootstrap.Cluster.Observation.Internal` and makes re-probe on every reprobe. That producer
  reconstructs `ClusterReadiness` only inside a lexical continuation; the opener introduces no separate
  reconcile/cordon/ready durable rows or journal-promotion API.
- Canonical package presence or action-local ready settlement alone is insufficient. A wrong domain or
  coordinate, a changed carried cluster generation, an absent or duplicate package, replay, stale probe, or
  failed readiness yields no witness. A config or driver mismatch is detected only through the package
  commitment and the live service it selects, not by a separate opener comparison.
- The package, wire, and canonical registry cannot contain or expose `ClusterReadiness`, an applied-cordon capability, managed
  backend handle, raw probe, journal writer, reusable receipt, or a value escaping the lexical continuation.
- The package commits each semantic service to its resolved-exposure identity. Its opener re-inspects the exact
  relay and mappings before exposing endpoints lexically; a port number without matching relay/cluster
  generation and ownership operation carries no authority.

#### Validation

`ClusterBackendSpec`, `LifecycleDependencySpec`, and compile-fail fixtures cover exact production, fresh open,
every mismatch/staleness case, non-escape, and absence of forbidden witnesses. The core host-static gate must
pass. The module and 400-line budgets are checked first; any new type or adoption is split. Closure requires
the gate-ordering, successor-exposure, exposure-request, and render-bound cases named under Remaining Work to
exist and pass under `cabal test all` from `core/`, followed by the core host-static gate.

Dated evidence, 2026-08-23: the cluster package commits its exact resolved service set and the live opener
freshly re-inspects it before yielding readiness and opaque exposures lexically; nonce replay, changed mapping,
wildcard, malformed response, and cross-service attempts refuse through the direct backend exposure calls in
`ClusterBackendSpec`. All 519 compile-fail boundaries and the complete 2,428-case core gate passed under
`--ghc-options=-Werror`.

#### Remaining Work

- `Cluster/Backend.hs` `registerClusterRuntimeDependencyPackage`: it runs `runClusterExposureCall` (which can
  start a relay container and publish the `<cluster>.exposure` record) before it checks
  `preparedGatePlan gate /= stepExecutionPlanDigest execution`. Move that check, and every other pure
  validation, before the first exposure call. Test: a `ClusterBackendSpec` case passes a `PreparedGate` recorded
  for another plan and asserts the `the producer gate names another plan` refusal. After it,
  `FakeCluster.readRelays root` is empty and the protected store holds no exposure record for the cluster.
- `ClusterWorkloadSpec` "successor recovery returns freshly inspected exact exposures": assert the exact host
  port `41000` and the relay identity read back with `FakeCluster.readRelays root`, not loopback shape alone.
  Add a case that rewrites the relay after package registration with `FakeCluster.writeRelays` (once with
  another relay identity, once with a changed mapping). Each asserts that `withFreshClusterRuntimeDependency`
  refuses and its continuation does not run. This shows the successor path re-inspects the relay rather than
  replaying the durable record.
- `LifecycleDependencySpec`: domain (`runtime dependency exposure request domain mismatch`) and commitment
  mismatch cases for `withRuntimeDependencyExposureRequest`, each asserting its exact refusal.
- `Lifecycle/Dependency/Internal.hs` renderers. `renderRuntimeDependencyProbeResponse` is total, so it renders
  generation 0, which `verifyRuntimeDependencyProbeOutcome` rejects as
  `runtime dependency probe generation is not canonical`. Make it return `Either Text ByteString`, refusing a
  non-canonical nonce and generation 0. Make `renderRuntimeDependencyExposureResponse` refuse a final wire over
  the 128 KiB `maximumProbeBytes` that `verifyRuntimeDependencyExposureResponse` enforces. In
  `Cluster/Backend.hs`, the cluster runtime service returns both refusals as its `Left`. Tests in
  `LifecycleDependencySpec`: generation 0 is refused at render time with its own reason, and so is an exposure
  set whose rendering exceeds 128 KiB.

### Sprint 24.23: Exact cluster reconcile, exposure, cordon, and readiness adoption [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: one cluster lifecycle call-site adoption and no new named contract; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Adopt one exact demo cluster call site from fresh provider recovery through reconcile, readiness, runtime-owned
exposure, applied cordon, and cluster-package production.

#### Deliverables

- The action-side plan projection attaches the already-validated exact Sprint 24.7 budget to the executing
  cluster resource under fresh partition indices and joins the cluster/provider resources using only the
  opaque `StepExecution`'s retained plan metadata; it never reconstructs a sibling `ProjectPlan`. The call
  site consumes that slice, Sprint 24.20 plan-owned cluster config, Sprint 24.21
  backend, and a provider package from the interpretation registry; it accepts no independent driver/config,
  provider handle, readiness flag, or cluster name.
- It is the sole child-side opener of the admitted provider package: before reindexing it authenticates the
  exact parent→child `PlanDigestBinding` and selected immediate topology edge; after fixed-node acknowledged
  sequencing it requests a parent-serviced fresh probe, refines a lexical `RunningProviderDependency`, then
  prepares and runs
  the exact cluster reconcile, journals
  ownership, settles the observed cluster, applies the exact cordon, and only then settles fresh readiness.
- Within that lexical readiness continuation it invokes Sprint 24.22's producer, registers the invocation-owned
  live readiness service separately, and stores only a pending cluster-domain package in the canonical
  registry. Only the fixed chart successor reached after `Chain` acknowledges the producer gate may open it;
  failure, retry, or a fresh invocation destroys both registries.
- Failure or replacement at any stage produces no readiness/package and unwinds only journal-proven owned work;
  wrong provider/cluster/frame/config/driver/budget/generation or out-of-order cordon is refused before use.
- Exposure settlement occurs only after exact cluster readiness and before cluster-package publication. The
  action supplies semantic targets, never candidate host ports; reverse removes the identity-bound relay before
  cluster deletion.
- Direct and VM/container lanes reach this same call-site shape through their distinct admitted provider routes;
  no compatibility export or hardcoded Kind is permitted. The Direct nvkind lane carries two demo-local steps
  that run typed `HostConfig` tools outside the core backend. Before rendering, `discoverDirectDockerHostDataPath`
  lists and inspects Docker containers to find the durable bind source. After ready settlement and before
  exposure, `ensureDirectNvidiaClusterRuntime` probes the Docker NVIDIA runtime and the `nvidia` RuntimeClass,
  installs the `nvdp` device-plugin Helm release, and polls allocatable GPUs. That release lives inside the owned
  cluster, has no journal row of its own, and is removed with the cluster by cluster deletion.

#### Validation

`CommandsSpec` plus the core cluster specs cover both lanes, action-side exact-plan/slice projection, exact
order (including `ensureDirectNvidiaClusterRuntime` between readiness and exposure on the Direct lane), package
carriage, failure unwind, and every mismatch. The core and demo host-static gates must pass. The one-adoption/module/line budgets are checked before
implementation; overflow is split before the call site lands.

#### Remaining Work

None. Completed 2026-08-23. The single VM/Direct adopter orders provider recovery, plan/config/backend binding,
reconcile, cordon, readiness, exposure settlement, and package publication. Both reverse routes recover and
remove the identity-bound relay before cluster deletion. `CommandsSpec` passed 58/58; the complete core and
demo gates passed 2,428/2,428 and 142/142 under `--ghc-options=-Werror`.

### Sprint 24.24: Planned chart/workload resource [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Lifecycle.Plan`,
`HostBootstrap.ProjectPlan` (3; cap 3)
**Sprint budget**: one new named type, `ChartWorkloadResource`, and no call-site adoption; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Represent the demo chart deployment as one exact plan-owned workload resource rather than a raw Helm mutation.

#### Deliverables

- Opaque `ChartWorkloadResource` is the sole named type and is projected only from a finalized chart/workload
  step at its exact cluster frame and operation key; callers cannot construct its resource key or frame.
- Its stable plan bytes bind chart artifact digest, release, namespace, canonical values digest, image identity,
  canonical workload/partition declaration key and digest, service role, cluster resource, and exact effects;
  they do not contain the later generative `PlannedWorkloadSet` or `BudgetPartition` values.
- Plan admission requires exactly one matching cluster parent and declared workload/partition identity, and
  refuses missing, duplicate, sibling, ancestor, wrong-frame, wrong-scope, or cross-plan resources before
  execution. Sprint 24.25 later matches the generative Sprint 24.7 outputs to those retained declarations.
- The resource's operation participates in the existing lifecycle session so `Chain` supplies its own exact
  `PreparedGate`; no demo code mints, stores, or accepts a gate independently.
- Reverse identity is derived from the same planned release/namespace/resource fields and cannot select another
  release, delete a shared namespace, or infer ownership from a live Helm listing.

#### Validation

`ProjectPlanSpec` and compile-fail fixtures cover stable bytes, exact parent/partition admission, gate ownership,
reverse identity, hidden construction, and every mismatch, including the zero-declaration chart step in Remaining
Work. The sprint closes when that case, the cross-frame and duplicate cluster-parent cases, the execution-terms
case, and the `CoerceChartWorkloadResourceRoles` fixture exist and pass and the core host-static gate passes. The sole-type/module/line
budgets are checked before implementation; overflow is split.

`ChartWorkloadResource` is abstract and generative, and its only projection reads an admitted
`core:deploy-chart` declaration. Admission refuses a declaration on a non-chart step, more than one declaration
on a step, an empty declaration field, and a chart declaration without exactly one prior same-frame
`core:deploy-kind` dependency. Stable plan format 5 binds the declaration and its cluster dependency; every
structural/recovery decoder consumes the same schema. The public reverse identity is derived from the admitted
release, namespace, and workload declaration key. Focused validation passed 92 indexed-plan tests and the
hidden-construction compile-fail fixture. On 2026-08-22 the complete core gate passed 2,413/2,413 in 163.08
seconds under `--ghc-options=-Werror`. The sprint introduced its one declared named type, used all three allowed
production modules, adopted no call site, and stayed below 400 added production Haskell lines.

#### Remaining Work

- `Lifecycle/Plan.hs` `validateChartWorkloadDeclarations`: the `[]` branch returns `Right ()` for every step, so a
  `core:deploy-chart` step with no declaration passes admission and fails only when the successor executes. Make
  the `[]` branch refuse when `stepIdentity step == CoreStepIdentity DeployChartId`, through the existing
  `binding "chart workload declaration count" "one" "0"` refusal. Test: a `ProjectPlanSpec` case admitting a
  plan whose `core:deploy-chart` step carries no chart workload declaration expects that `PlanError`; update any
  existing fixture that relied on the gap.
- `Lifecycle/Plan.hs` `projectPlanExecutionTermsKernel`: map only `PlanResourceKindMismatch` (a non-chart step)
  to `Nothing` and propagate any other `PlanError` from `withProjectChartWorkloadResourceKernel`, rather than
  `either (const Nothing) Just`. A chart projection failure then reports its own binding mismatch, not
  `PlanResourceOperationMissing` for an operation the plan holds. Once the zero-declaration refusal above
  holds at admission, no admitted plan reaches the propagated branch. Test: `ProjectPlanSpec` asserts that a
  non-chart node's execution terms carry no chart declaration, and that the admitted chart node's terms carry
  exactly its declaration.
- `ProjectPlanSpec` "one exact same-frame cluster parent": `chartWorkloadWithoutClusterPlan` has no deploy-kind
  step, so only the `[]` branch runs. Add a chart that depends on a `core:deploy-kind` step in another frame,
  expecting the `none` refusal (the same-frame filter), and a chart that depends on two same-frame
  `core:deploy-kind` steps, expecting the `duplicate` refusal.
- `test/compile-fail/CoerceChartWorkloadResourceRoles.hs`, registered in `CompileFailSpec` beside
  `CoercePlannedResourceRoles`: one `coerce` per index of `ChartWorkloadResource` (scope, planId, resourceId,
  frame), each expecting the `Couldn't match type ... arising from a use of 'coerce'` phrase, so deleting the
  `type role ChartWorkloadResource nominal ...` line fails the gate.

### Sprint 24.25a: Exact workload/partition declaration binding [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload/Binding.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/BudgetSpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Plan`, `HostBootstrap.Cluster.Budget`,
`HostBootstrap.Cluster.Workload.Binding` (3; cap 3)
**Sprint budget**: no new named contract and no call-site adoption; at most 400 production Haskell lines. Split
before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Give Sprint 24.25 a caller-free, canonical equality between the stable chart declaration and the generative
workload-set/partition outputs.

#### Deliverables

- The hidden plan kernel folds the exact chart declaration, stable plan digest, and same-frame cluster key only
  while the nominal `ChartWorkloadResource` is in scope; no facade exposes a constructor or caller-authored
  replacement record.
- `PlannedWorkloadSet` and `BudgetPartition` retain deterministic canonical identities derived from their exact
  ordered workloads, budgets, and slices. Empty text, delimiter ambiguity, reordering, resource substitution,
  or budget drift changes or refuses the identity.
- One equality fold joins the chart declaration key/digest to the exact generative workload set and partition;
  callers supply neither an expected key nor an expected digest, and a mismatch yields no continuation.
- Existing budget admission semantics and nominal indices remain unchanged, and no backend command is run.

#### Validation

`ProjectPlanSpec` and `BudgetSpec` cover deterministic identity, ordering and budget sensitivity, exact match,
all declaration substitutions, and absence of a caller-authored digest seam. The complete core host-static gate
must pass. The no-type/module/line budgets are checked before implementation. Closure requires the
delimiter-ambiguity case named under Remaining Work to exist and pass under `cabal test all` from `core/`.

Dated evidence: the chart resource retains its stable plan digest and same-frame cluster key behind a hidden
detail fold. `PlannedWorkloadSet` and `BudgetPartition` derive length-framed SHA-256 identities from exact ordered workload,
overhead, resource/frame, slice, and quantity fields; the workload key is hash-framed as well. The pure binding
fold compares all three identities and releases no continuation on substitution. Focused `BudgetSpec` passed
25/25 cases, including ordering, quantity, budget, and declaration drift. On 2026-08-22 the complete core gate
passed 2,416/2,416 in 165.67 seconds under `--ghc-options=-Werror`. The sprint added no named type or call-site
adoption, used all three allowed production modules, and stayed below 400 added production Haskell lines.

#### Remaining Work

- `BudgetSpec` "workload identity retains exact authoring order without delimiter ambiguity" compares `[a, b]`
  with `[b, a]` for workloads that differ only in replicas, which every concatenation separates. Add a
  boundary-shift pair that is identical under unframed concatenation and differs only in where a digit falls
  between two adjacent fields: replicas `1` with CPU `11`, against replicas `11` with CPU `1`, other fields
  equal. Assert different `plannedWorkloadSetDigest` values, so replacing the length framing in `Budget.hs`
  with plain concatenation fails the case.

### Sprint 24.25b: Chart dependency and journal preparation kernel [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`, `core/hostbootstrap-core/test/ReconcileSpec.hs`
**Production modules**: `HostBootstrap.Cluster.Reconcile`, `HostBootstrap.Reconcile` (2; cap 3)
**Sprint budget**: no new named contract and no call-site adoption; at most 400 production Haskell lines. Split
before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Seal the chart operation's exact ready-cluster dependency and durable prepare gate through the existing generic
reconciliation journal without exposing resource-handle construction.

#### Deliverables

- `ClusterReadiness` projects its retained managed cluster handle only through the public read-only cluster
  module; callers cannot construct or relabel readiness evidence.
- One chart-specialized generic reconciliation kernel derives the chart handle, operation descriptor, exact
  cluster dependency, call digest, observation version, and operation/precondition pair from the nominal chart
  resource, ready cluster handle/probe, and `PreparedGate`. The chart handle's generation does not move with the
  gate's fence epoch, so an unchanged committed chart settles unchanged after a fence rotation.
- The kernel rejects wrong cluster identity, empty call digest, stale/foreign gate, missing or duplicate
  dependency, failed readiness reprobe, and zero fence/version before yielding its generative continuation.
- No workload backend command, activation witness, or new result/type is introduced.

#### Validation

`ClusterReconcileSpec` and `ReconcileSpec` cover the exact ready dependency and every substitution/refusal.
The complete core host-static gate must pass. The no-type/module/line budgets are checked before implementation.
Closure requires the readiness-refusal case named under Remaining Work to match its exact refusal, and the
fence-rotation unchanged-settlement case to exist, both passing under `cabal test all` from `core/`.

Dated evidence, 2026-08-22: `ClusterReadiness` exposes only its read-only handle/probe projections, and the
generic chart preparation kernel derives and seals the exact cluster dependency, chart handle, operation
descriptor, call digest, gate, operation, and preconditions. Focused `ClusterReconcileSpec` and `ReconcileSpec`
coverage passed, including wrong-cluster, failed-readiness, and wrong-gate refusals; the complete core gate passed
2,421/2,421 after the forward workload slice was added. The guarantee that callers cannot construct readiness
evidence also depends on the recovered-readiness constructor `withRecoveredClusterReadiness` leaving the public
surface; Sprint 16.10 owns that change, and Sprint 24.25d closes on it.

#### Remaining Work

- `ReconcileSpec` `chartPreparationSummary` turns every projection, cluster-settlement, and node-count setup
  failure into `Left (Failure ...)`, the shape the "chart preparation refuses a failed readiness reprobe" case
  accepts. Make setup failures call `assertFailure` with their reason. Have the case assert the exact `Failure`
  that `withPreparedChartWorkloadOperation` returns for the fixture probe's
  `FailureDetail "readiness" "not ready" ReprobeBeforeRetry`, so a broken fixture cannot pass the refusal case.
- `Reconcile.hs` `withPreparedChartWorkloadOperation`: the observed chart handle takes its generation from
  `preparedGateFence gate`, and fence epochs only rotate upward, so after a fence rotation an unchanged,
  already committed chart compares its prior receipt's generation with the new fence and settles as a
  `Conflict`. Derive the chart generation from a source that does not move with the lease: the prior committed
  record's generation for this chart resource when one exists, and the first generation otherwise. Test: a
  `ReconcileSpec` case settles a chart under a gate at fence 1, then prepares the same unchanged chart, with the
  prior receipt present, under a gate at fence 2 whose backend reports it unchanged, and asserts the settlement
  is the unchanged `ChangeView` with no `Conflict` naming the receipt generation.

### Sprint 24.25: Prepared and settled chart/workload backend [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ClusterWorkloadSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Cluster.Workload`, `HostBootstrap.Cluster.Backend` (2; cap 3; Cabal
metadata is not a production module)
**Sprint budget**: one new named type, `PreparedChartWorkload`, and no call-site adoption; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Prepare, run, observe, journal, and settle the exact chart resource behind readiness evidence,
without adding a parallel result type.

#### Deliverables

- Cabal-hidden `PreparedChartWorkload` is the sole named type and retains the exact planned resource,
  `PreparedGate`, freshly opened lexical `ClusterReadiness`, successor execution descriptor,
  canonical values/image digests, and operation attempt/version.
- Its only preparer checks that readiness, resource, cluster identity, plan, scope, frame, gate, canonical values,
  and declared effects all match the stable plan before Helm or Kubernetes access. Runtime role activation is
  installed for the deployed service revision; it is not controller authority and is never made available to
  the deployment action.
- `Cluster.Backend` renders the one producer-owned Helm/Kubectl transaction internally from the registered
  cluster runtime service and exact package fields; callers provide no executable, raw arguments,
  release/namespace, values path, or readiness flag.
- The prepared value runs and settles inside its hidden eliminator, returning the existing generic
  `ReconcileResult`/`ChangeView`; replacement, stale readiness/activation/gate, digest drift, foreign release,
  partial apply, timeout, or unready workload refuses, and no second named result is introduced. A foreign
  release is an existing Helm release of the planned name and namespace that does not carry this chart
  resource's ownership identity; the backend refuses it before `helm upgrade --install` and never adopts it.
- Plan admission gives every chart declaration an activation frame, so the one public preparer is
  `withPreparedActivatedChartWorkload`, which requires a canonical activation revision. No public preparer
  deploys a chart without its root-signed revision.
- Reverse cleanup is the independently bounded no-new-type Sprint 24.25c immediately below.

#### Validation

`ClusterWorkloadSpec` and compile-fail fixtures cover sole forward preparation, exact apply rendering,
Changed settlement, journal/version binding, canonical-value drift, malformed success, readiness failure, and
no second result type. The sprint closes when the foreign-release, activation-revision, other-cluster, and exact
negative-refusal cases in Remaining Work exist and pass and the core host-static gate passes. The sole-type/module/line budgets are checked before implementation; reverse cleanup is
split because the combined implementation exceeds 400 lines.

On 2026-08-22 nine focused `ClusterWorkloadSpec` cases covered exact apply, drift and malformed-output refusals,
rollout failure, conservative no-op settlement, cleanup convergence, replay, and route substitution, and the
complete core gate passed 2,429/2,429 with `--ghc-options=-Werror`. Cabal-hidden `PreparedChartWorkload` is
produced only after exact declaration, freshly recovered cluster-readiness, values-digest, dependency, and
journal-gate checks; the producer-owned runtime service renders Helm upgrade/install through stdin followed by
the exact Kubectl deployment rollout.

#### Remaining Work

- `Cluster/Backend.hs` `serveClusterChartRequest`: it runs `helm upgrade --install` without checking who owns an
  existing release, so a same-named foreign release is upgraded and settled as `BackendRepaired`. Install with a
  Helm release label carrying the chart resource's ownership identity (`--labels`), and before the upgrade run a
  read-only Helm query for the planned release in the planned namespace. When the release exists without that
  exact label value, return a refusal response that the successor settles as a non-retryable `BackendFailed`
  naming the foreign release, and issue no `upgrade`. Tests in `ClusterWorkloadSpec`: a fake Helm reporting an
  existing release with no owner label, and one with another identity, each expect the refusal and record no
  `upgrade` invocation; a fake Helm reporting the release with this identity keeps the existing upgrade and
  conservative no-op settlement.
- `Cluster/Workload.hs` and `Cluster/Backend.hs`: `withPreparedChartWorkload` prepares with no activation
  revision and ignores the declaration's activation frame. `Cluster.Backend` re-exports it publicly, and only
  `ClusterWorkloadSpec` calls it. Remove it from both export lists and delete it. Make
  `withPreparedChartWorkloadInternal` take the revision as `Text`, not `Maybe Text`. Move the
  `ClusterWorkloadSpec` callers to `withPreparedActivatedChartWorkload` with a canonical 64-hex revision.
- `ClusterWorkloadSpec` activated-preparer refusals: `withPreparedActivatedChartWorkload` with `"../x"`, with a
  64-character uppercase hex value, and with a 63-character lowercase hex value. Each returns
  `Failure (FailureDetail "prepare chart workload" "activation revision is not a canonical SHA-256 basename"
  DoNotRetry)`, and the fake Helm records no command. A cluster resource other than the declaration's returns
  `chart declaration names another cluster resource`.
- `ClusterWorkloadSpec` negatives ("canonical values are checked before Helm is invoked", "an incomplete Helm 4
  install result is refused", "rollout refusal prevents a successful settlement", and "cleanup refuses an
  unrecognized successful uninstall") accept any `Left (Failure _)`, the constructor the fixture
  (`withChartWorkloadFixture`, `fixtureFailure`) also uses for its own plumbing failures. Match `failedOperation`
  and `failureCause` per refusal, for example `canonical values bytes differ from the admitted digest` in the
  values case. In the values case, also assert that the fake's `helm-release-<release>` marker under the
  fixture root is absent after the refusal.

### Sprint 24.25c: Journal-owned chart/workload reverse cleanup [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterWorkloadSpec.hs`
**Production modules**: `HostBootstrap.Cluster.Workload`, `HostBootstrap.Cluster.Backend` (2; cap 3)
**Sprint budget**: no new named type and no call-site adoption; at most 400 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Release the exact Helm workload owned by a settled forward chart resource without replaying forward preparation
or exposing command construction.

#### Deliverables

- One hidden eliminator consumes only the exact managed forward settlement and the planned release, namespace,
  and resource identity retained by the prepared package; it admits no caller-supplied executable or arguments.
- The backend renders Helm uninstall and authoritative absence observation internally under the retained backend.
- Removed and already-absent releases converge through existing reconciliation views. A foreign settlement
  (`withSettledChartWorkloadCleanup`), an unrecognized successful uninstall, a failed uninstall, a `helm status`
  that still reports the release after uninstall, and any other `helm status` failure refuse.
- Cleanup requires no `PreparedGate`, `ClusterReadiness`, activation witness, values bytes, or second result type.

#### Validation

`ClusterWorkloadSpec` covers exact uninstall rendering and absence convergence ("cleanup removes the exact
settled release and converges over absence") and malformed-success refusal ("cleanup refuses an unrecognized
successful uninstall"). The sprint closes when the refusal, release-marker, and verified-bundle cases in
Remaining Work exist and pass and the complete core host-static gate passes; the no-type/module/line budgets are checked before implementation.

On 2026-08-22 the complete core host-static gate passed 2,423/2,423 with `--ghc-options=-Werror`. The
no-new-type cleanup fold admits only a generic managed forward settlement for the exact nominal chart resource,
derives release and namespace from the stable declaration, and renders Helm uninstall and status internally. The
cleanup addition uses the same two production modules, adds no named type, and remains below 400 production
Haskell lines.

#### Remaining Work

- `ClusterWorkloadSpec`: add refusal cases for chart cleanup, each asserting `Left` with the exact
  `cleanup chart workload` or `prepare chart workload cleanup` message: a foreign `ReconcileResult` passed to
  `withSettledChartWorkloadCleanup` ("a foreign chart release cannot be cleaned up"); a fake Helm whose
  `uninstall` exits non-zero; a fake Helm whose `uninstall` succeeds but whose `status` exits 0 ("Helm still
  reports the release after uninstall"); and a `status` that fails with stderr other than `not found`.
- `ClusterWorkloadSpec` "cleanup removes the exact settled release and converges over absence" asserts only
  `Right ((), ())`. Assert that the fake's `helm-release-<release>` marker under the fixture root exists
  before the first cleanup and is gone after it. A cleanup that returns `Right ()` without issuing an uninstall
  then fails the case.
- `ClusterWorkloadSpec` teardown entry: `runVerifiedChartWorkloadCleanupCall` (the `Cluster/Backend.hs` call
  that Sprint 24.27's reverse command runs on a `VerifiedResourceRecordBundle`) is reached today only by
  source-text counts. Add a case that installs the fixture chart, builds a managed verified bundle for it, and
  runs the call twice. Assert that the fake Helm records exactly one `uninstall` of the planned release in the
  planned namespace, and that the second run converges over `not found`. Add a non-managed bundle case
  asserting `Right ()` with no Helm command recorded.

### Sprint 24.25d: Successor-local chart and readiness recovery [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Lifecycle.Plan`, `HostBootstrap.Lifecycle.Execution.Internal`,
`HostBootstrap.Lifecycle.Dependency.Internal`, `HostBootstrap.Reconcile`, `HostBootstrap.Cluster.Reconcile`,
`HostBootstrap.Cluster.Workload`, `HostBootstrap.Cluster.Backend` (7; above the § G cap of 3). This is a
recorded § G exception: the one successor-recovery path threads a single descriptor field, carrier rebind,
package opener, and readiness reconstruction through each owner's fixed entry, and no module gained a second
contract.
**Sprint budget**: no new named contract and no call-site adoption; at most 400 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Let the fixed chart successor recover its own exact stable chart declaration, acknowledged managed-cluster
handle, and one-use freshly serviced readiness observation without reconstructing the producer's backend package.

#### Deliverables

- The neutral execution descriptor retains the current node's chart declaration only when the admitted plan
  projected one; a rank-2 opener reconstructs the nominal chart resource for that exact node.
- The successor rebinds the acknowledged cluster settlement from the invocation carrier at its exact planned
  resource type and validates the canonical cluster package without accepting a caller-selected backend origin.
- The invocation-owned service performs the fresh backend probe and returns its nonce-bound observation version;
  `ClusterReadiness` is reconstructed lexically as a one-use dependency probe over the carried managed handle.
  The reconstruction function `withRecoveredClusterReadiness` is reachable only from `Cluster.Backend`'s opener:
  no exposed module of `hostbootstrap-core` exports it, so no caller can turn a managed cluster handle, or the
  handle `withClusterReadinessResourceHandle` projects from a consumed readiness, into fresh readiness.
- Missing declaration, unacknowledged cluster settlement, package substitution, duplicate service, replay,
  expiry, zero version, or a second readiness use refuses before chart effects.

#### Validation

`ReconcileSpec`, `ClusterBackendSpec`, `ClusterReconcileSpec`, and compile-fail fixtures cover exact projection,
fresh successor recovery, one-use behavior, every mismatch, and non-escape. The unexported-producer deliverable
rests on Sprint 16.10, which moves `withRecoveredClusterReadiness` into the hidden
`HostBootstrap.Cluster.Observation.Internal` and registers the `ImportRecoveredClusterReadiness.hs`
compile-fail fixture. The sprint closes when that fixture and the chart wire cases in Remaining Work exist and
pass and the complete core gate passes.

On 2026-08-22 focused coverage passed for exact execution, chart application, replay, and route substitution,
and the complete core gate passed 2,429/2,429 with `--ghc-options=-Werror`. The execution descriptor retains the
exact optional chart declaration, the successor rebinds only its acknowledged carried cluster settlement, and its
live service returns a nonce-bound fresh readiness version and owns the exact chart effect transaction.

#### Remaining Work

- `LifecycleDependencySpec` chart wire cases. `verifyRuntimeDependencyChartResponse` binds a chart outcome to
  the package commitment and the exact call digest, and is reached today only through `ClusterWorkloadSpec`'s
  install. Verify a response rendered by `renderRuntimeDependencyChartResponse` against:
  - another call digest;
  - another package;
  - the outcome `deleted`;
  - a non-canonically re-framed copy;
  - a 3-field wire;
  - a response domain other than `hostbootstrap/runtime-dependency-chart-response/v1`.
  Each asserts its exact refusal. Add domain (`runtime dependency chart request domain mismatch`) and commitment
  mismatch cases for `withRuntimeDependencyChartRequest`.

### Sprint 24.26: Readiness-gated activated chart/workload adoption [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/docker/Dockerfile`, `demo/chart/`, `demo/hostbootstrap-demo.cabal`, `demo/test/CommandsSpec.hs`,
`hostbootstrap/bootstrap.py`, `tests/test_bootstrap.py`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Identity/Install.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload.hs`
**Production modules**: one demo adopter, the thin Python builder, and twelve existing core boundary modules;
the activated adoption is split across the owners of identity installation, root-only signing, keyless relay,
child execution, service installation, and chart preparation rather than introducing a parallel facade.
**Sprint budget**: one activated chart/workload call-site adoption and no new named contract. The existing
boundary modules are changed only at their fixed entry/fold; no generic signer or activation carrier is added.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Run the demo service only from an exact root-signed immutable activation revision, through the planned,
readiness-gated chart transaction.

#### Deliverables

- The fixed chart successor opens Sprint 24.22's cluster-domain package only after acknowledged producer-node
  sequencing, fresh-reprobes the exact cluster, and keeps `ClusterReadiness` lexical for this one action.
- The action's own `PreparedGate` and Sprint 24.24's planned resource are joined with that readiness; missing or
  mismatched evidence refuses before backend work. The prepared workload retains only an exact lowercase
  activation-revision basename and the backend injects only that basename into Helm.
- One demo call site prepares, runs, observes, and settles Sprint 24.25's transaction, then returns its generic
  `ChangeView` through the existing `Chain` outcome/journal path.
- The demo defines both long-running roles as closed `ServiceProgram`s. Before Helm, it measures the exact image
  and in-image binary, decodes the Production role wire, finalizes the registry, builds the canonical manifest,
  and asks the invocation-local execution service to sign it. Nested frames relay those canonical bytes to the
  root; only the root activation key signs, and only when the plan digest plus exact planned service/effect row
  match.
- The returned signature is adopted through the existing activation installer under the durable data root.
  Docker receives only the independently installed public key. The chart mounts the immutable revision and
  authority store read-only/by exact path and obtains the real Kubernetes pod UID and container restart count.
  Its dedicated service account is bound to a namespaced Role granting only `get` on `pods`, with no `list`,
  `watch`, other verb, or ClusterRole. Deployment pod names are generated, so the grant is not narrowed to the
  pod's own name: the account can `get` any pod in the release namespace whose name it knows.
- After copying a stable project binary, the thin builder invokes one exact private Haskell entry which installs
  or validates the handoff, build, and activation identities. Python never reads, creates, or interprets key
  material, and this entry creates no project configuration.
- `deployChartAction` calls no `deployChart`, builds no `containerPlan`, and applies no caller-built ConfigMap;
  the chart renders its own ConfigMap from the `serviceConfig` value. The adopter takes its scope
  commitment from `clusterProfileOf projectCfg`, and `prepareDemoServiceActivationFor` derives the activation
  root as `profileDataPath (clusterProfileOf projectCfg) sourceRoot </> "activation" </> "revisions"`. No Phase 22
  sprint is redefined as owning this demo chart mutation.
- The web `Deployment` declares `strategy.type: Recreate`, so a rollout never runs two web pods, each with its
  own process-local accelerator hub, beside each other.

#### Validation

`CommandsSpec` covers readiness/gate/signing/install ordering, both demo lanes, exact chart assets, get-only pod
RBAC (no `list` or `watch`), real restart identity, plan projection, and absence of `deployChart`. Core
activation, relay, identity-install, lifecycle-dependency, and workload tests cover canonical signing, exact
policy, key separation, bounded protocol v2, basename validation, and refusal. `test_bootstrap` covers the
post-copy private entry without config initialization. Core, Python, and demo host-static gates must pass before
live acceptance. The sprint closes when the comment corrections in Remaining Work land, the `chartValues`
refusal, role-digest, and `Recreate`-strategy `CommandsSpec` cases exist and pass, and the demo host-static gate
passes.

On 2026-08-23 the complete core gate passed 2,442/2,442 under `-Werror`, the complete demo suite passed 142/142,
all 231 Python tests passed, and Ruff, Black, MyPy, and the changed-file Fourmolu check were clean. Sprint 24.30
retains the separate live activation evidence.

#### Remaining Work

- `demo/src/HostBootstrapDemo/Commands.hs` `deployChartAction` Haddock: state that the action installs the chart,
  whose own `templates/configmap.yaml` renders the service ConfigMap from the `serviceConfig` Helm value, and
  that the `configHash` pod-template annotation rolls the Deployment when that content changes. Remove "applied
  outside Helm" and "StatefulSet".
- `demo/chart/values.yaml`: replace "the separately applied ConfigMap" with the chart-rendered ConfigMap and the
  `configHash` rollout trigger. Replace the accelerator comment's "kind mapping is bound to 127.0.0.1" with: host
  daemons reach NodePort 30081 inside the cluster, and the host reaches it only through the runtime-allocated
  loopback relay. Mark `image.identity` as the only consumed image key (overridden by the planned image
  identity) and delete the unread `image.repository` and `image.tag`.
- `demo/chart/templates/service.yaml`: replace "local-only NodePort for Apple/Windows host daemons" with "NodePort,
  exposed to the host only through the loopback relay".
- `demo/chart/Chart.yaml` description: the plan's `core:deploy-chart` step installs the chart into the demo's
  Kind/nvkind cluster, and the web Service is a NodePort the in-network e2e reaches. Remove "per-case kind
  cluster" and "`cluster up`".
- `demo/chart/templates/deployment.yaml` container comment: state that `command` replaces the image ENTRYPOINT,
  so tini is not PID 1 in the pod and the demo binary is. Explain that the `kubectl get pod` wrapper reads the
  container restart count into `HOSTBOOTSTRAP_CONTAINER_RESTART_COUNT` for the service's restart identity, exits
  64 when the count is absent or non-numeric, and depends on the base-provided `kubectl` and the
  `runtime-rbac.yaml` Role. Make the same tini qualification in the `demo/docker/Dockerfile` header comment.
- `demo/hostbootstrap-demo.cabal` description: the demo extends `hostbootstrap-core` through
  `runHostBootstrapCLI` and the five extension streams (step fragments, Dhall vocabulary, the schema-gen
  `coreArtifacts ++ demoArtifacts` registry, test-harness `Seams`, and the service runtime seam) and adds no
  command to the fixed surface. The live in-VM / Kind / in-cluster registry / web / Playwright surface is driven by
  the fixed `project up` and `test run` commands. Remove "four-stream", "appended noun-first project verbs",
  "Harbor", and "the verbs".
- `Commands.hs` `chartValues`: replace the `error` on a `validatedWebServiceConfigForContext` `Left` with an
  `Either String ByteString` result propagated through `declaredChartStep` and `deployChartAction`, as
  `acceleratorHelmValuesForContext` already does. Add a `CommandsSpec` case whose config sets `publicPort` equal
  to `acceleratorPort` and asserts the typed `Left` (`Web publicPort and acceleratorPort must be distinct`).
- `CommandsSpec` "full and role codecs retain one jointly finalized specification digest": also assert
  `roleCodecSpecDigest roleCodec == projectCodecSpecDigest codec` for each role codec of the finalized
  registry. The changed-digest and changed-scope rejections assert the exact `Left` texts `role wire
  specification digest disagrees with its selected codec` and `role wire scope kind disagrees with its selected
  codec` rather than accepting any `Left`.
- `demo/chart/templates/deployment.yaml`: add `strategy: {type: Recreate}` to the web `Deployment` spec. The
  default `RollingUpdate` briefly runs the old and new web pods together, each with a separate process-local
  hub, which `haReplicas = 1` exists to prevent. Add a `CommandsSpec` case that reads the template and asserts
  the `Recreate` strategy.

### Sprint 24.27: Exact worked-demo reverse command adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrap.Command`, `HostBootstrap.Command.LifecycleEntry`,
`HostBootstrap.Cluster.Backend`, `HostBootstrap.Lifecycle.ResourceRecord`, `HostBootstrap.Reconcile`,
`HostBootstrap.Teardown` (6; cap 6)
**Sprint budget**: one reverse-command call-site adoption and no new named contract; at most 400 production
Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/operations/demo_runbook.md`

#### Objective

Adopt exact chart cleanup in the shared demo `down`/`destroy` command from retained teardown
plan/frame/journal authority, without pretending `TeardownAction` receives a forward `StepExecution` package.

#### Deliverables

- The one Production reverse-command entry consumes Phase 17's exact `TeardownPlan`, current frame, command
  intent, cursor, and reconstructed `ProjectPlan`; it never accepts or reconstructs `PlanExecutionPackage`.
- The exact `LocalWork` operation key projects only its plan-owned chart resource. Cleanup reads that resource's
  canonical protected record, verifies its plan digest, frame, and resource identity, and derives the Helm
  release and namespace only from the verified chart projection.
- Child-first forest order runs authenticated chart removal before the owning frame's cluster cleanup. Existing
  declared provider/share/alias reverses remain reachable only through their exact projected `LocalWork` node.
- Missing ownership is retained as foreign; malformed, stale, wrong-plan, wrong-frame, and wrong-resource records
  fail before Helm. A verified released tombstone converges without a second mutation.
- Both the Production driver and the Harness destroy driver use the same record-authenticated chart rule, while
  `down`/`destroy` continue to omit the canonical durable root from their removal sets.

#### Validation

`ProjectPlanSpec` and `CommandsSpec` cover retained-plan command entry, exact operation/record/chart stages,
absence of forward-package use, and the established child-first/down/destroy projections. Resource-record,
cluster-workload, teardown, and compile-fail suites cover mismatch refusal, idempotent cleanup, ordering, and
non-forgeability. Core and demo host-static gates must pass. The one-adoption/module/line budgets are checked.

Completed 2026-08-22: the focused core and demo source-shape gates passed; the full core host-static gate passed
2,429/2,429 and the complete demo suite passed 139/139 under `--ghc-options=-Werror`. The implementation adds
no named contract, keeps the single Production reverse-command entry, and remains below the 400-line budget.

#### Remaining Work

None. The sealed root reverse entry lends its reconstructed exact plan to each opaque local-work callback. A
chart node can therefore open only the record named by its plan digest, frame, and resource key; only a verified
owned record reaches Helm, and a verified released record is already converged. No forward execution package or
caller-selected chart identity enters reverse execution. The authenticated reverse child derives the exact
Production or `harness:<run-id>` lifecycle profile from its verified handoff binding, executes retained cluster
release in the child frame, and classifies a callback-free non-core node as foreign-retained rather than as a
successful release.

### Sprint 24.28: Exact demo forward-child projector [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/app/Main.hs`,
`demo/test/CommandsSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrapDemo.Commands`, `Main` (2; cap 3)
**Sprint budget**: one demo projector call-site adoption and no new named contract; at most 400 production
Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/composition_methodology.md`, `documents/architecture/generic_project_model.md`,
`documents/architecture/hostbootstrap_core_library.md`, `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Install the exact project-owned forward-child projector after every projected provider, cluster, chart,
guest, and reverse consumer is exact.

#### Deliverables

- `demoForwardChildPlan`, its chain-at-context/payload helpers, and `validateDirectParentLift` form the sole
  demo projector; `Main` installs it exactly once with `addForwardChildPlan`.
- The completed projector proves only the retained ancestry prefix and unique immediate parent→child edge, not
  whole child-plan/descent equality. VM/VM-container ancestry edges remain exact; child-local graphs may differ
  below the child.
- The selected Direct container edge alone may rebase one writable durable source to its unchanged absolute
  target (source=target in the child plan) while preserving image, arguments, remove, socket, target, read-only,
  placement, and config delivery. For `ViaContainer`, canonical payload equals `cdPayload`; root→VM has no ConfigDelivery.
- The exact package retains topology evidence, `LiftContext`/invocation route, canonical authenticated protocol
  payload, and `HandoffBindingInput`, never an actual `HandoffBinding`, independently selectable executable, or
  `SelfRef`; it derives a ConfigDelivery-stripped Process route and adds no `Cluster.Lifecycle` compatibility export.
- `Main`'s argv pre-parser for the Direct cluster release is not part of this projector; Sprint 24.71 deletes it.

#### Validation

`CommandsSpec`, `Main` source guards, and the core projector compile-fail fixtures cover Production/Harness
scopes, VM and Direct topologies, exact immediate-edge semantics, the sole Direct rebase, payload cases, hidden
package fields, and no compatibility export. The sprint closes when the lift-placement and projected-durable
cases in Remaining Work exist and the demo host-static gate passes. The one-adoption/module/line budgets are
checked.

Completed 2026-08-22: `Main` retains its expected projector-installation hash
`7956057055b30b02f534eaa147dbef0d01756445e0d56148ecc259bbb0a794cb`; the focused behavioral gate covers the
root→VM, VM→container, Direct, Harness, foreign-edge, and wrong-lift paths; and the complete demo suite passed
140/140 under `--ghc-options=-Werror`. The implementation adds no named contract and remains below 400
production Haskell lines.

The installed scope-polymorphic projector proves the retained ancestry prefix and unique immediate edge,
rebuilds the child-local graph from the narrowed config, admits only the exact Direct durable-source rebase,
and yields no binding, executable, `SelfRef`, or compatibility export.

#### Remaining Work

- `Commands.hs` `validateDirectParentLift`: add
  `requireForward (clPlacement container == clPlacement expected) "direct lift placement differs from the canonical child route"`,
  since placement alone decides whether the process route injects the direct-container witness. Add a
  `CommandsSpec` case passing the canonical direct lift with `clPlacement = ProviderGuestContainer` and
  asserting that exact `Left`.
- `Commands.hs` `DemoDurableBind`: give `ProjectedDurable`'s two fields distinct newtypes (a guest descriptor
  root that `guestProfileDataPath` expands into the mount target, and a child-visible durable source), so a
  transposition at the construction site in `demoForwardChildPlan` does not compile; add a `CommandsSpec` case
  asserting the projected mount's source and target for a descriptor root that differs from the source path.

### Sprint 24.29: Authenticated derived-image adoption [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/docker/Dockerfile`,
`core/hostbootstrap-core/test/CLISpec.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrap.Command`, `HostBootstrapDemo.Commands` (2 Haskell modules; cap 3;
`demo/docker/Dockerfile` is a build input)
**Sprint budget**: the VM and Direct image-build call-site adoption and no new named contract; at most 400
production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/operations/demo_runbook.md`

#### Objective

Build the demo image only through the authenticated project-owned build protocol after the exact plan/projector
and published-base provenance boundaries close.

#### Deliverables

- Both demo build lanes consume an authenticated clean source/build identity, a freshly resolved published-base
  repository digest, and the canonical Dockerfile/context projection. The Direct lane fixes its executable and
  context locally; the VM lane measures the installed guest builder and transfers authority secret files through the
  provider's typed file-transfer route.
- The existing build protocol binds project/spec/config, build nonce, source, coordinator, builder, and frame.
  Each build uses a fresh temporary channel and disables Docker layer-cache reuse. On the VM lane every guest
  secret file, the context archive, the extracted build context, and the builder context are removed on every
  exit path once the first secret is pushed, including a failure during secret push, context transfer, archive
  extraction, builder install, or the build itself. Each removal runs independently, so one failed `rm` does not
  skip the others.
- The binding's specification digest is the jointly finalized Production runtime codec that image
  `check-code` opens. A Harness lifecycle may request the build, but its separately labelled Harness plan codec
  is not substituted for the image entrypoint's specification.
- Every derived build retains `--pull`, uses the within-run repository digest resolved in Sprint 24.4, and runs
  the image's warning-clean `check-code`; a stale local base cannot satisfy the result.
- Image-build `check-code` accepts only the fixed BuildKit channel/verification/coordinator/config secret mounts
  and the selected builder supplied as the read-only `hostbootstrap-builder` named build context, canonically
  validates the sibling image config, measures `/workspace/demo` and the running installed builder,
  verifies the signed grant, and consumes its at-most-once `CheckCodePhase` authority before the project hook.
- No environment, argv, Dhall field, source file, or durable project file transports build authority. The
  Dockerfile installs the coordinator-selected, source-built builder from the named build context and the config
  from a secret, and authenticates the warning-clean gate. It then compiles the in-image Cabal product
  warning-clean and checks only that the product is non-empty (`test -s`), and materializes the digest-bound
  builder bytes, not the in-image product, as the export-stable runtime executable. Runtime provenance rests on
  the signed builder digest; the in-image build proves that the image's sources compile, not that the runtime
  bytes equal them.

#### Validation

`BuildAuthoritySpec` and `CommandsSpec` cover authenticated signing/verification, digest identity, at-most-once
phase use, `--pull`, `--no-cache`, published digest resolution, fixed secret delivery, warning-clean stage
ordering, malformed/cross-project/replacement refusal, and absence of Dockerfile config minting. The sprint
closes when the VM secret-cleanup cases in Remaining Work exist and the core and demo host-static gates pass.
The adoption/module/line budgets are checked.

Completed 2026-08-22: `BuildAuthoritySpec` passed 28/28, the focused demo BuildKit adopter passed, the full core
host-static gate passed 2,429/2,429, and the complete demo suite passed 141/141 under
`--ghc-options=-Werror`. No named contract was added; the two-module implementation plus Dockerfile remains
below 400 production Haskell lines.

Both derived-image lanes resolve and pull the published base, sign a fresh source/config/builder binding,
deliver authority material through transient BuildKit secrets and the measured builder through a read-only named
build context, and run authenticated `check-code` before compiling the in-image source build and exposing the
digest-bound authenticated builder as the runtime image binary. `CommandsSpec` also proves that both lifecycle
scopes bind image authority to the exact finalized Production runtime specification measured by that entrypoint.
Ordinary host developer `check-code` remains a config-gated local action.

#### Remaining Work

- `demo/src/HostBootstrapDemo/Commands.hs` `withAuthenticatedVmBuildSecrets`: the `finally` covers only
  `use guestBuildContext secretArgs`, so a failure in `traverse stageOne localFiles`, the context transfer, the
  `tar -xzf` extraction, or the builder install leaves the pushed secrets at their fixed guest `/tmp` paths, and
  the chained `>>` cleanup stops at the first failed `rm`. Open the cleanup bracket before the first `stageOne`,
  record each guest path as soon as its push completes, and run each cleanup command (each pushed secret, the
  context archive, the builder context, the extracted context) independently, collecting failures and
  re-raising after all have run.
- Factor the guest operations behind a record the function takes, for example push-file and run-in-guest
  actions, so `CommandsSpec` can drive it with a recording fake. Add cases that fail at the third secret push, at
  extraction, at builder install, and in the build, and assert that every already-pushed secret path appears in
  a later guest `rm`. Add a case where the first `rm` fails and assert that the remaining cleanup commands still
  run.

### Sprint 24.30: Production recursive-lifecycle acceptance [Done]

**Status**: Done
**Implementation**: no production change; evidence in this phase and
`documents/operations/demo_runbook.md`
**Production modules**: none (0; cap 3)
**Sprint budget**: no new named contract, no call-site adoption, and zero production Haskell lines; this is the
separate live-substrate confirmation of the preceding host-static changes.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/engineering/testing.md`, `documents/architecture/composition_methodology.md`

#### Objective

Confirm the proof-complete recursive lifecycle command through the real Production demo consumer.

#### Deliverables

- Acceptance starts only after Sprints 24.3–24.29 and the demo static gate are green; it introduces no fallback
  interpreter, authority injector, compatibility export, test-only lifecycle route, or production code.
- Fresh Production `project up` traverses every declared frame through Phase 17's root-coordinated storeless
  frame executor and reaches exact provider, cluster, workload, service readiness, and read-only endpoint
  assertions.
- One exact demo owner receives distinct runtime-assigned loopback ports for its registry, web, and S3 store
  listeners without candidate scanning, retry-on-collision, or operator configuration. On the Incus-backed
  `linux-cpu` realization `acceleratorPlacementForContext` selects `InClusterDaemon`, so no host-accelerator
  listener exists there; the host-accelerator listener belongs to the Apple Silicon and Windows/WSL2 acceptance
  runs. Every probe uses the endpoint resolved for its own exact service and generation. The lower
  cluster-lifecycle phase's live gate separately proves concurrent same-listener allocation in one Docker
  namespace.
- Production `project down` and root-only `project destroy` drive Sprint 24.27's shared child-first reverse
  route, remove only owned state, and preserve the canonical durable-root sentinel required by each command
  contract. This realization has no Direct lane; reporting Direct physical release as `Unsupported` belongs to the
  NVIDIA acceptance run.
- Dated evidence records host/OS/architecture, tool versions, published base and derived image identities,
  exact command results, and audited provider/cluster/workload/durable-root end state.

#### Validation

On fresh linux-cpu, pass `cabal build all` and
`cabal test hostbootstrap-demo-test --ghc-options=-Werror` from `demo/` and the core host-static gate from
`core/`; prove the live demo's distinct authenticated service endpoints; then run
`hostbootstrap run -- project up`, `hostbootstrap run -- project down`, and
`hostbootstrap run -- project destroy`. Record evidence only after every command exits as specified, owned
infrastructure is absent, and durable-root assertions pass. Phase 17
retains only its host-static process gate; Phase 19 retains its separately owned Harness/interruption gate.

#### Remaining Work

None. Completed 2026-08-24 on the disposable `hostbootstrap-phase24-cpu-host` gate host: Ubuntu 24.04.4 LTS,
Linux 6.8.0-138-generic x86_64, Incus 6.0.0, Docker 29.1.3, Python 3.12.3, GHC 9.12.4, Cabal 3.16.1.0, and
`hostbootstrap` 0.1.0. Fresh Production `project up`, `project down`, and root-only `project destroy` each
exited successfully; the sequence reached distinct runtime-assigned registry, web, and MinIO loopback
endpoints, retained the durable sentinel through both reverse verbs, and removed the owned provider after
Destroy. The separately owned lower cluster-lifecycle live gate supplies the concurrent same-listener
allocation proof.

### Sprint 24.31: The guest bootstrap and the guest alias driver [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/docker/Dockerfile`, `.dockerignore`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/GuestBootstrapSpec.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/operations/demo_runbook.md`

#### Objective

Establish the project binary inside a pristine guest through the one guest-bootstrap vocabulary, publish the
exact provider/share dependencies, and let the guest alias hold and release its four ownership clauses through
the shipped project binary.

#### Deliverables

- The pristine-guest bring-up consumes the closed guest bootstrap vocabulary the
  [ensure-reconcilers phase](phase-8-ensure-reconcilers.md) owns: five ordered, separately probeable steps,
  each an argument vector, ending with the binary installed where the lift expects it.
- Because the step is probe-first, a re-run of a partially bootstrapped guest completes the steps that are
  outstanding instead of repeating the ones that are not.
- Linux Docker readiness includes the separately packaged Buildx plugin. Authenticated build #3 consumes one
  coordinator-created, `.hostbootstrap`-free core-plus-demo archive: the bytes hashed locally are the exact bytes
  transferred to and built inside the guest, and the builder digest has one canonical unprefixed form.
- With the binary established there, the guest alias holds its four clauses through the ownership seam,
  over the shipped row addressed at that frame — so the alias's identity is still read by the kernel that
  owns the object, and it is read by this binary.
- The reverse adapter consumes `RetainResource` on Down without releasing the alias or its ownership row;
  Destroy consumes `ReleaseResource` and gives back the exact link after child teardown.
- The shipped row stages the symbolic link and binds that exact device/inode identity in the durable record
  before atomic no-replace publication. Linux publishes a second name with `link(2)`; Darwin moves the same
  bound inode with `renamex_np(RENAME_EXCL)`, because APFS does not admit a hard link to a symbolic link.
  Both the bound-staging and bound-published interruption windows resume without adopting a pathname.
- The alias's durable record uses the shared record vocabulary, so a record written in a guest is readable
  by the host frame that owns the share.
- This is the sprint in which a frame crossing carries an ownership transaction for the first time, so it
  is where that row earns its live confirmation.
- The copy-source action runs only after the guest binary build, retains the VM descent, publishes the exact
  Provisioned share member and its closed runtime commitment after alias success, and forwards provider plus
  provider-share commitments as one bounded canonical bundle. The child rebinds each exact receipt through a
  distinct nonce-bound live service before cluster preconditions.
- Incus share readiness requires the declared guest target itself to be a writable `virtiofs` mountpoint before
  alias publication or child descent; a writable directory in the guest's underlying source tree is not share
  readiness and cannot race Docker's bind-source resolution. The owned share transaction activates a newly
  attached VM disk through one identity-checked restart before it binds and publishes that share.
- The VM provider publishes Running from its actual absent acquisition predecessor. The alias operation key is
  the full provider/share relation declared by the plan, and forward ordering remains bootstrap → shipped alias
  → provider/share dependency publication → child entry.
- Lifecycle routes place Lima's `--workdir` flag before the instance operand, matching Lima 2.x's command
  grammar instead of forwarding that flag to the guest shell. Harness reverse restores access only on
  non-symlink descendants of its exact virtiofs run share; it never attempts to chmod the Lima mountpoint.

#### Validation

`GuestBootstrapSpec`, `ProviderAliasSpec`, `OwnershipShippedSpec`, provider-dependency tests, and
`CommandsSpec` cover the five-step probe-first plan, Buildx readiness, deterministic build bytes, exact
provider/share bundle, full alias relation, ordering, settlement, retry, replacement-safe release, and shipped
POSIX ownership behavior. The complete core and demo host-static gates must pass. The live confirmation starts
from the retained pristine-guest state, creates the alias, completes child cluster descent, proves the alias
survives provider stop/restart, and releases it while the durable share remains intact.

On 2026-08-26, macOS arm64 passed the complete warning-clean core gate at 2,474/2,474 in 357.86 seconds,
`cabal build all` from `demo/`, and the complete warning-clean demo gate at 145/145.

#### Remaining Work

None. On 2026-09-09, the current core and demo gates pass, and the fresh Windows/WSL Production
Up/Down/Destroy sequence passes. After Down and a cold restart, the alias retains device/inode
`2096:217048`, the exact target, and the exact ownership-record hash. Destroy releases the alias row
and removes the provider while preserving the host marker. Sprint 24.42 records the commands,
timings, image digest, and terminal audit.

Dated evidence on 2026-08-26 on macOS 26.5 arm64 with Lima 2.1.2, GHC 9.12.4, Cabal 3.16.1.0, and
`hostbootstrap` 0.1.0. The fresh Apple/Lima Harness run bootstrapped the project binary and Docker 29.1.3 in
each of four pristine guests, published the guest alias, completed child cluster descent, survived the
engine-owned same-run Destroy/recreate boundary for both variants, and released the provider on terminal
Destroy. Run `run-3ed8c816cf5d0` (`hello-world`) and run `run-3efa98a88f190` (`hello-universe`) contributed
five passing assertions each to the exact `10/10 passed` report. The terminal audit found no Lima instance,
generated sibling config, Harness durable root, or live accelerator ownership state; the operator test config,
project authority store, and build caches remained.

The earlier live evidence for the Incus path also remains part of this sprint's gate: on 2026-08-24, a fresh
Ubuntu 24.04 linux-cpu/x86_64 Incus run bootstrapped the project binary
inside a pristine guest, attached the exact host `.data` root as writable `virtiofs`, and completed cluster
descent. Before and after an explicit provider stop/start, `/var/tmp/hostbootstrap-demo-data` resolved to the
same owned host root, a write marker remained readable, and both installed activation-revision digests were
unchanged. Root-only `project destroy` then deleted the provider while preserving that durable root and marker.

### Sprint 24.32: Chart-declared service activation frame [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Lifecycle.Plan`,
`HostBootstrapDemo.Commands` (3; cap 3)
**Sprint budget**: no new named type and no lifecycle call-site adoption; at most 400 production Haskell
lines. The existing chart declaration gains one exact canonical field.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/operations/demo_runbook.md`

#### Objective

Make the derived service-runtime frame part of the exact plan-authored chart workload rather than asking a
later signer to infer it from the chart execution frame or mounted configuration bytes.

#### Deliverables

- `declaresChartWorkloadResource` retains the exact derived service activation frame beside workload identity,
  role, and effects; empty frames refuse during plan validation.
- `ChartWorkloadResource` and the neutral execution package carry that field without exposing a constructor or
  manufacturing it at reconciliation time.
- The canonical plan format hashes the activation frame, and the strict structural reader admits the
  corresponding ten-field chart record.
- The demo derives the declared frame through the same `renderServiceConfigForContext` projection used to
  render the mounted service wire and Helm values.

#### Validation

`ProjectPlanSpec` proves exact projection and that changing only the activation frame changes canonical bytes;
`CommandsSpec` proves the demo declaration consumes the same derived frame. Run the warning-clean core build,
focused plan gate, complete demo gate, and Sprint 24.30 live acceptance.

#### Remaining Work

None. Completed 2026-08-23. The warning-clean core build, focused `ProjectPlanSpec`, container
`fourmolu`/`hlint`, focused `CommandsSpec` 58/58, complete demo 142/142 gate, and repeated aggregate core gate
at 2,446/2,446 pass. The fresh linux-cpu run retained the exact declared activation frame through rooted
authorization and created its immutable activation revision before Helm entered the workload transaction.

### Sprint 24.33: Exact rooted activation-placement authorization [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`
**Production modules**: `HostBootstrap.Command.LifecycleEntry` (1; cap 3)
**Sprint budget**: no new named type and one activation-signing call-site correction; at most 200 production
Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/operations/demo_runbook.md`

#### Objective

Authorize activation only from an exact chart declaration in the admitted root or child-plan catalog, using
the service-runtime frame that declaration owns.

#### Deliverables

- The root derives one closed `(activation frame, plan digest, service, permitted effects)` placement from each
  admitted chart resource in the root plan and recursively admitted child plans.
- Signing requires the manifest frame to select exactly one placement and then requires exact plan digest,
  service, and filtered service-effect equality before the existing activation policy and broker can run.
- A lifecycle-plan frame without a chart-declared activation placement is not authority, and duplicate
  activation frames refuse rather than selecting one.

#### Validation

A `ChainSpec` source-shape case pins the code fragments of catalog-wide derivation and the manifest comparison;
it is not refusal coverage. The sprint closes when the behavioural placement cases in Remaining Work exist and
pass in the warning-clean core host-static gate.

On 2026-08-23 the warning-clean build, focused Chain gate at 46/46, and repeated aggregate core gate at
2,446/2,446 passed. In the fresh linux-cpu run the root accepted the chart-declared service frame, published its
signed immutable activation revision, and invoked Helm; no lifecycle frame or mounted config bytes supplied
signing authority.

#### Remaining Work

- `Command/LifecycleEntry.hs`: lift the placement selection out of the local `signActivation` into a pure
  function over the admitted placement list and the manifest, for example
  `selectActivationPlacement :: [(Text, Text, Text, [Text])] -> ActivationManifest -> Either ActivationError ()`.
  Lift the root-plus-catalog derivation of `admittedActivationPlacements` likewise, export both through the
  module's test-visible surface, and have `signActivation` call them before the policy and broker.
- `ChainSpec`: add behavioural cases asserting `ActivationManifestInvalid` with the exact message for a manifest
  frame with no placement ("absent from the admitted rooted plan catalog"), a frame placed twice
  ("duplicated"), a wrong plan digest ("differs from its admitted frame plan"), and a wrong service or wrong
  filtered effects ("service/effect placement is absent"), plus `Right ()` for the exact placement. Add a
  derivation case where the root plan and an admitted child plan declare the same activation frame, and assert
  the duplicate refusal.

### Sprint 24.34: Docker-host durable-root projection [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/ClusterConfig.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/ClusterConfigSpec.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.ClusterConfig`, `HostBootstrapDemo.Commands` (2; cap 3)
**Sprint budget**: no new named type and one cluster-config call-site adoption; at most 200 production Haskell
lines. The existing owned guest alias becomes the canonical Docker-daemon mount source.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/operations/demo_runbook.md`

#### Objective

Render the Kind node's durable bind from the path interpreted by the Docker daemon rather than from the
project container's in-frame durable path.

#### Deliverables

- The exact cluster config keeps its state and config artifacts under the plan-owned in-frame durable root.
- Kind `extraMounts.hostPath` uses the existing owned Docker-host alias, whose target is the provider-shared
  durable root, while `containerPath` remains `/var/lib/hostbootstrap-demo-data`. On the Direct nvkind lane the
  source is the Docker-reported bind source of the project container's profile data destination
  (`discoverDirectDockerHostDataPath`), validated by `directDurableMountSource`.
- `renderYaml` emits the Docker-visible path as a YAML scalar that Kind parses back to exactly that path, for
  every path `requireCanonicalPath` admits.
- The rendered Kind and nvkind bytes agree with the checked-in topology templates and do not expose a child
  container path to the sibling Docker daemon.
- The Direct durable-bind discovery tolerates an unrelated container that exits between Docker's listing and
  its inspection, so such an exit does not abort `project up` or the Direct teardown. It selects the mount in
  Haskell from Docker's JSON mount list, so a non-ASCII destination path matches.
- The activation revision and service-authority directories created through the project-container mount are
  therefore visible inside the Kind node before Helm admits a workload that requires them.

#### Validation

`ClusterConfigSpec` pins the distinct in-frame state paths and Docker-host mount source. Closure requires these
cases to exist and pass in `cabal test hostbootstrap-demo-test`, then the complete demo gate:

- `ClusterConfigSpec`: Kind and nvkind rendered with a Docker-visible path containing ` #`, `: `, `'`, and `"`
  either produce bytes whose `hostPath` value decodes to exactly that path (the golden text names the quoted
  form) or are refused with a `Docker-host data path` message (the role label Sprint 24.19 owes), matching the
  chosen remedy below.
- `ClusterConfigSpec`: the YAML body of `demo/kind.yaml` and `demo/nvkind-in-cluster.yaml` (the lines after the
  leading `#` comment block) equals `renderExactClusterConfig`'s bytes for `KindDriver` and `NvkindDriver` with
  `durableDockerHostPath`.
- `CommandsSpec`: the pure Direct mount selection over a container listing and per-container inspect results
  skips a container whose inspect reports `No such object`, still refuses a malformed listing, and still
  refuses an absent or duplicated destination.

Dated evidence, 2026-08-24: the fresh Incus-backed Production run mounted the owned guest alias as the Kind
node's Docker-host source; the node saw the immutable web and accelerator activation revisions plus the shared
service-authority directory before both deployments reached `1/1 Running`. The alias remained the same writable
`virtiofs` projection across an explicit provider stop/start.

#### Remaining Work

- `demo/src/HostBootstrapDemo/ClusterConfig.hs` `renderYaml`: emit both `hostPath` values from the
  Docker-visible path as YAML double-quoted scalars with `\` and `"` escaped (or refuse, in
  `requireCanonicalPath`, any path holding `#`, `:`, a quote, a control character, or leading/trailing
  whitespace with a `Docker-host data path` refusal). Add the `ClusterConfigSpec` quoting case above.
- `demo/test/ClusterConfigSpec.hs`: add the template byte-agreement case above, so the checked-in YAML cannot
  drift from the Haskell renderer.
- `demo/src/HostBootstrapDemo/Commands.hs` `discoverDirectDockerHostDataPathAt`: treat an inspect failure whose
  stderr reports `No such object` as a departed container and skip it, keeping every other inspect failure
  fatal; factor the listing-plus-inspect selection into a pure exported function and add the `CommandsSpec`
  case above.
- `Commands.hs` `discoverDirectDockerHostDataPathAt`: stop embedding the destination in the Go template with
  Haskell `show` (which writes `é` as `\233`, an octal escape to Go, and inserts `\&`, which Go rejects). Inspect
  with `{{json .Mounts}}`, decode the mount list in Haskell, and select the entry whose `Destination` equals the
  profile data path. Add a `CommandsSpec` case to the pure selection: a mount list whose destination is
  `/home/josé/hostbootstrap/.data` selects its source.

### Sprint 24.35: Helm 4 rollback and result contract [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`, `core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterWorkloadSpec.hs`
**Production modules**: `HostBootstrap.Cluster.Backend` (1; cap 3)
**Sprint budget**: no new named contract and one backend command correction; at most 100 production Haskell
lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/operations/demo_runbook.md`

#### Objective

Invoke Helm's supported rollback-on-failure contract without a deprecation warning, and classify Helm 4's
first-install status record without weakening the exact captured-command boundary.

#### Deliverables

- The chart reconcile command requests `--rollback-on-failure` and retains its explicit `--wait` readiness
  boundary.
- Successful Helm and Kubectl calls remain required to return an empty stderr stream; the backend does not
  weaken exact command-result classification to hide warnings.
- A first install is accepted only when Helm 4's exact install announcement is accompanied by the matching
  release name, deployed status, revision 1, and `Install complete` description. The prior supported install
  phrase remains admitted, while an incomplete status record is refused.
- The fake backend accepts only the supported command vector, so a return to the deprecated flag breaks the
  focused static gate, and it emits Helm 4's status shape so classifier drift breaks the workload gate.
- The live linux-cpu acceptance records Helm's version and reaches the Ready workload without a command warning.

#### Validation

`ClusterWorkloadSpec`, through `FakeCluster`'s single accepted `upgrade --install ... --rollback-on-failure
--wait` vector, covers the exact chart reconcile vector, the Helm 4 first-install record, and refusal of an
incomplete record (`an incomplete Helm 4 install result is refused`); `ClusterBackendSpec` carries no Helm case.
Closure additionally requires a `ClusterWorkloadSpec` case in which `FakeCluster` answers a first install with
the prior `Release "<release>" has been installed` phrase and the chart reconcile reports a first install.
Run the warning-clean core build, focused backend gates, and complete core gate.

Dated evidence, 2026-08-23: the warning-clean core build, focused `ClusterBackendSpec` 32/32 and
`ClusterWorkloadSpec` 10/10 gates, complete core 2,446/2,446 gate, and governed-doc 2/2 gate pass. A fresh
linux-cpu run using Helm 4.2.3 settled the first-install status record without stderr and reached a 1/1 Ready
`hostbootstrap-demo-web` pod.

#### Remaining Work

- `core/hostbootstrap-core/test/FakeCluster.hs`: add an arm, selected by a fixture marker file beside the
  existing `rollout-refusal` marker, that answers the first `upgrade --install` with only
  `Release "<release>" has been installed`. `core/hostbootstrap-core/test/ClusterWorkloadSpec.hs`: add a case
  that sets the marker and asserts the chart reconcile succeeds as a first install, so `classifyHelm`'s
  `installed` branch in `HostBootstrap.Cluster.Backend` is exercised.

### Sprint 24.36: Plan-authored standalone service activation placements [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Lifecycle.Plan`,
`HostBootstrap.Command.LifecycleEntry` (3; cap 3)
**Sprint budget**: no new named type and one standalone declaration field; at most 240 production Haskell
lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Let any exact plan step declare one service activation placement without pretending that every service is a
Helm-owned chart workload.

#### Deliverables

- `declaresServiceActivation` retains one exact activation frame, role, and non-empty unique effect row on an
  ordinary opaque `Step`; it does not retain runtime measurements or signing authority.
- Canonical plan format version 7 hashes a structurally exact standalone-activation list for every step.
- Admission rejects empty fields, duplicate effects, more than one standalone declaration per step, and an
  activation frame reused by either a chart or another standalone declaration.
- The rooted signing catalog derives placements from chart and standalone declarations in admitted root and
  child plans, then preserves the existing exact frame, plan-digest, role, and effect comparison.

#### Validation

`ProjectPlanSpec` proves canonical sensitivity (`service activation placements are exact canonical plan
declarations`) and chart-versus-standalone collision refusal (`service activation frames are unique across
chart and standalone declarations`). Closure requires one `ProjectPlanSpec` case per remaining admission
refusal of `validateServiceActivationDeclarations`, each asserting the exact `withProjectPlan` result, then the
warning-clean core build and complete core host-static gate.

Dated evidence, 2026-08-23: the warning-clean core build, focused three-case canonical/version/collision gate,
complete core 2,448/2,448 gate, and governed documentation gate pass.

#### Remaining Work

- `core/hostbootstrap-core/test/ProjectPlanSpec.hs`: using `serviceActivationPlan` and `draftsFor`, add cases
  asserting `Left (PlanResourceBindingMismatch field expected observed)` for: an empty frame
  (`"service activation frame" "non-empty" "empty"`); an empty role (`"service activation role" "non-empty"
  "empty"`); effects `[]`, `["a", "a"]`, and `[""]` (`"service activation effects" "a non-empty unique set"
  "empty or duplicate"`); one step carrying two `declaresServiceActivation` calls (`"service activation
  declaration count" "at most one per step" "2"`); and two standalone steps declaring the same frame
  (`"service activation frame" "unique" "duplicate"`).

### Sprint 24.36a: Far-frame recorded exposure observation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterShippedSpec.hs`, `core/hostbootstrap-core/test/Spec.hs`
**Production modules**: `HostBootstrap.Cluster.Backend`, `HostBootstrap.Cluster.Shipped`,
`HostBootstrap.CLI` (3; cap 3)
**Sprint budget**: one opaque exposure-observation result and one read-only frame transaction; at most 400
production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Re-observe one recorded cluster service exposure inside the exact provider frame that owns its Docker engine,
without carrying a child-frame runtime witness into its parent.

#### Deliverables

- `HostBootstrap.Cluster.Backend` opens the protected exposure row for the exact cluster, refuses absent,
  pending, malformed, conflicting, or duplicate service facts, and re-observes the recorded relay's exact
  identity and loopback port mapping before returning the requested host port. The observation creates
  nothing: a state directory without `store.identity` is reported as `the exact exposure record is absent`
  before any store is opened.
- `HostBootstrap.Cluster.Shipped` defines one bounded, closed, read-only request and response vocabulary for
  that observation. The request admits only an absolute POSIX state path, a valid cluster name, and one
  bounded service name; the response contains no Docker handle, ownership witness, or credential. The crossing
  is the unauthenticated frame-child transaction of `HostBootstrap.Handoff.Transaction`: the payload carries
  no authority, so the vocabulary admits observations only.
- The near-side function crosses only through `withFrameChildTransaction` and one already-derived lift
  context; its capability-restricted wrapper projects that context from the exact `ProviderCapability`.
  Providers whose lifecycle owns the route directly, including WSL2, supply the plan-selected provider lift.
  The far-side interpreter derives its host configuration locally and performs the backend observation there.
- The frame-child dispatcher distinguishes this request by its closed prefix and otherwise delegates to the
  shipped ownership interpreter, preserving one child entry surface. The CLI and the test driver run that one
  dispatcher, so the crossing case exercises the production code.
- Focused tests cover canonical round trips, malformed and oversized refusals, wrong-identity and wrong-port
  rejection, exact service selection, interpreter fall-through, and child-process observation.

#### Validation

Run the warning-clean focused `ClusterBackendSpec` and `ClusterShippedSpec` gates, then the complete
warning-clean core host-static gate and governed-documentation gate. Closure requires the cases named under
Remaining Work to exist and pass on every gate host, Windows included, under `cabal test all` from `core/`.

Dated evidence, 2026-08-26: `ClusterBackendSpec` passed 37/37, `ClusterShippedSpec` passed 8/8, the
public-consumer bind boundaries passed 2/2, the complete warning-clean core gate passed 2,474/2,474 in 430.34
seconds on macOS arm64, and the governed-documentation gate passed 2/2.

#### Remaining Work

- `ClusterShippedSpec` "only a canonical bounded port is a response" decodes only the unprefixed `"41000"`,
  which fails `stripPrefix` before the port bound or the canonical re-encoding is checked. Using the module's
  response prefix (export the response encoder if it is hidden):
  - `decodeShippedClusterExposureResponse (prefix <> "41000") == Right 41000`;
  - `Left "the shipped cluster exposure response carries an invalid host port"` for `prefix <> "0"`,
    `prefix <> "65536"`, `prefix <> "041000"`, and `prefix <> "41000\n"`;
  - `Left "the bytes are not a shipped cluster exposure response"` for a foreign prefix.
  Add a positive `observeShippedClusterExposureAt` case over a recorded `FakeCluster` exposure through a local
  frame child, asserting the exact recorded host port.
- `ClusterShippedSpec` observation cases: on `mingw32`, `withAbsentRequest` substitutes
  `/var/tmp/hostbootstrap-cluster-exposure-absent`, which the far side's native `isAbsolute` refuses. Both cases
  accept `not absolute`, the crossing case on every host. Give the far interpreter a state directory that is
  absolute on the running host and admitted by the request validation. Then assert the exact
  `the exact exposure record is absent` text on every host, and drop both `not absolute` alternatives. Where a
  host admits no such path, the crossing case is a declared row that host lacks, not an accepted refusal.
- `Cluster/Backend.hs` `observeRecordedClusterExposure`: before `openProtectedStore` (which creates `records/`,
  writes a fresh `store.identity`, and opens `store.lock` read-write), return
  `the exact exposure record is absent` when `<state>/store.identity` does not exist. Make the Haddock and
  `Cluster/Shipped.hs`'s "Read-only observation" say that the observation creates nothing and takes the
  existing store's lock. Test: a `ClusterBackendSpec` case observes a non-existent state directory, asserts the
  absent refusal, and asserts that the directory still does not exist afterwards.
- `Cluster/Shipped.hs` module Haddock: replace "the authenticated frame transaction already owned by
  `HostBootstrap.Handoff.Transaction`" with the unauthenticated frame-child transaction it is. Its framing is
  the whole admission check, and this payload carries no authority. State that only observational requests
  belong in this vocabulary.

### Sprint 24.37: Accelerator service-activation adoption [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: no new named contract and one additional activation call-site adoption; at most 300
production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/accelerator_daemon.md`,
`documents/operations/demo_runbook.md`

#### Objective

Launch every accelerator placement through the same signed `service run` activation and concrete instance
boundary as the chart-owned web service.

#### Deliverables

- Linux accelerator steps declare their exact daemon activation placement and install a root-signed immutable
  revision for the measured in-cluster image and binary before applying the Deployment.
- The accelerator Deployment mounts the durable activation-revision and service-authority directories and
  supplies their fixed runtime coordinates.
- The pod obtains its own UID through a downward-API `fieldRef` on `metadata.uid` and its exact container
  restart count through the chart-owned runtime service account (`kubectl get pod`) before invoking
  `service run`; neither value is caller-authored configuration.
- Host-resident Apple and Windows accelerator steps declare the same placement, measure the copied daemon
  executable, install its verification key and activation revision beside durable state, and mint a fresh
  invocation nonce for each detached process.
- Before root descent, the rooted coordinator installs its already-admitted activation signer into the exact
  root Chain carrier. Child frames retain their relayed signer, while the same root carrier survives child close
  and supplies only signed grants to post-handoff activation; no signing key crosses a frame or enters plan
  bytes.
- After the deployment child frame closes, the Apple host-resident accelerator step reopens the exact owned
  provider and obtains its capability; the WSL2 route uses its plan-selected provider lift. Both use the
  far-frame observation transaction to recover the accelerator relay's freshly identity-checked loopback port,
  and neither expects the child's cluster runtime package to survive.
- Generated-manifest and chain gates fix the activation declarations, mounts, coordinates, and instance-qualified
  launch shapes.
- The WSL2 exposure probe and the installed activation-key read convert only synchronous failures into a named
  refusal; an asynchronous exception (a user interrupt, a cancelling thread, or `System.Timeout`'s timeout)
  propagates unchanged.

#### Validation

Run focused `CommandsSpec` and `ChainSpec`, the complete demo gate, warning-clean demo build, formatter and
linter checks, and the complete core gate. The worked-demo live acceptance confirms the linux-cpu call site
through a Ready daemon and successful terminal `project up`; hardware acceptance phases confirm the
host-resident and GPU call sites. Closure requires the `CommandsSpec` cases named under Remaining Work, then the
demo host-static gate.

Dated evidence, 2026-08-26: far-frame relay observation is adopted for the Apple and Windows host-resident
daemon launch. `CommandsSpec` fixes the Apple fresh-provider/capability route, the WSL2 plan-selected lift
route, and port-only endpoint consumption and passed 61/61. `ChainSpec` passed 48/48 with the exact root-carrier
signer binding, the complete warning-clean core gate passed 2,474/2,474 in 357.86 seconds, and the complete
warning-clean demo build and 145/145 gate passed on macOS arm64. Each of the four live pristine-image builds
passed the image's in-container `check-code`; the Apple/Lima Harness gate reported `10/10 passed`, and all four
post-handoff host daemons reached Ready through the root-signed activation carrier and far-frame exposure.
The published base digest was
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`; the four derived-image digests were
`sha256:c5558991213ee0e6e5aba5f161a3ad4d1d4356582e3d7347f6da87ad6a7d61ec`,
`sha256:fa0f37a5b15a874f018ac72e1a707e16e220ebb2c6bccf24c334760eebf1dde2`,
`sha256:3968f151dc0b59c135afc795d0d1dc99c02c3195a7ec2077a2116b1cdc7d0b66`, and
`sha256:024a9bfaec30e47c81e8cf4f49ce1d2a34c9b1631d3a8f0b6e777c34c2f5c212`.

#### Remaining Work

- `Commands.hs`, `ProviderWsl2` arm of the host accelerator's exposure recovery: replace the
  `try ... :: IO (Either SomeException ...)` around `observeShippedClusterExposureAt` with a catch that rethrows
  `SomeAsyncException` (or catches `IOException` only). Factor the conversion into one exported helper and add a
  `CommandsSpec` case: an action throwing `userError` yields the probe-failure `Left`, and an action throwing
  `UserInterrupt` rethrows it.
- `Commands.hs` `installedActivationVerificationKeyHex`: read `<exe>.activation.pub` through `try @IOException`
  (or the core's typed key-loading API, as `installedProjectVerificationKeyHex` does through
  `installedVerificationKey`) so only file errors become the key-file refusal; cover it with the same helper's
  `CommandsSpec` case.

### Sprint 24.38: Declarative same-run durable readback [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: no new named contract and one assertion-policy adoption; at most 120 production Haskell
lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Prove durable state by reading it after an engine-owned settled destroy and fresh invocation of the same
Harness run, without giving project assertion code lifecycle authority.

#### Deliverables

- `durable-readback` declares `AssertAcrossRestart`; the other four cases run only before restart.
- `BeforeRestart` writes the marker through the live Docker/cluster route and verifies the exact
  run-profile durable root in the assertion frame.
- The assertion environment derives the exact profile from the admitted canonical project root and
  retains its provider projection for marker readback and diagnostics in that frame.
- The Harness engine owns intermediate destroy, fresh broker generation, exact snapshot/plan rebind, and the
  second forward; the assertion callback receives only `AfterRestart`.
- `AfterRestart` reads the same marker through the recreated workload and exact durable root, retaining one report row.
- Both configured variants therefore retain exactly five rows and the complete matrix remains exactly 10 rows.

#### Validation

The command-level core fixture proves real protected generation rotation and exact plan rebind; `HarnessSpec`
proves one-row phase merging; `CommandsSpec` fixes the demo policy and phase-specific operations. The live
linux-cpu Harness run must report 10/10 after performing both same-run generations.

On 2026-10-16, the native Linux/NVIDIA matrix reports `8/10 passed`: both variants' durable
readback rows read the absent VM-only alias, while their exact host and node roots contain the marker.
The correction derives the profile root from the admitted generated config, projects it through the
selected provider, and retains the resulting path in the assertion environment for both phases.
`CommandsSpec` adds two behavioral cases for Direct/Lima/Incus, both Windows lanes, Production,
distinct Harness runs, drive separators, and roots containing spaces. All 77 focused cases pass,
as do Fourmolu 0.19.0.1 and HLint 3.10 on both changed files.
The source adoption remains within one production module and the sprint's 120-line budget.

The complete corrected-tree host static gate passes on `matt-caledon-desktop`, native x86_64
Ubuntu 24.04.5 LTS, Linux 7.0.0-38-generic, GHC 9.12.4, Cabal 3.16.1.0, Poetry 1.8.2,
and Python 3.12.3. From `core/`, `cabal build all` and plain `cabal test all` pass, including
2,552/2,552 cases in 231.98 seconds. From `demo/`, `cabal build all` passes in 22.12 seconds;
plain `cabal test all` passes 161/161 demo cases in 2.23 seconds and 2,552/2,552 core cases in
235.92 seconds (240.35 seconds for the workspace command). The exact unfiltered
`cabal test hostbootstrap-demo-test` passes 161/161 in 1.37 seconds (3.72 seconds for the command).
Both provider-live components return their declared no-request `Unsupported` result. The repository
Python code check passes, and `poetry run python -m hostbootstrap.test_all` passes 251/251 in
2.04 seconds. Both edited files retain LF, and `git diff --check` passes. Before/after measurements
over the 29 roots and 862 files agree at
`2270a6319a8e5bc12c64b9edf057f031f79ba673af2677a9cfcf001b3551d11b`.

#### Remaining Work

None. The complete live `linux-cpu` confirmation is owned by Sprint 24.50.

### Sprint 24.39: Non-empty derived-image executable [Active]

**Status**: Active
**Implementation**: `demo/docker/Dockerfile`, `demo/test/CommandsSpec.hs`
**Production modules**: none; the Dockerfile is the one build call-site adoption
**Sprint budget**: no new named contract; one Dockerfile build/runtime-artifact correction.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/derived_dockerfile.md`,
`documents/engineering/derived_project_standards.md`, `documents/operations/demo_runbook.md`

#### Objective

Make successful derived-image construction prove both the in-image source build and the exported runtime
entrypoint, without depending on BuildKit to snapshot the in-container linked Cabal product.

#### Deliverables

- The final source build uses the same `--ghc-options=-Werror` configuration as the authenticated code-check
  gate that precedes it, so one Docker build tree is not reconfigured under conflicting GHC option sets.
- The Dockerfile binds the exact `cabal list-bin` result and requires the in-image source build to be non-empty.
- The source-built, digest-bound authenticated builder occupies a build-only libexec path. After the web build,
  the Dockerfile copies its bytes with `dd` into a new regular `/usr/local/bin/hostbootstrap-demo` file, removes
  the build-only authority, final-materializes the config, public keys, and web bundle, and requires every
  runtime-critical artifact to be non-empty. The coordinator repeats those checks against the exported image.
- The post-bootstrap `copy-source` continuation re-mints the ephemeral VM-provider witness only after the exact
  share and guest alias have settled, because Incus virtiofs attachment stop/starts the guest and clears `/run`.
- The reference derived-project documentation carries the same warning-clean, final-materialized authenticated
  runtime artifact, config/key/web materialization, and exported-image probe shape.
- The Dockerfile's own comments state that shape in body order: install the coordinator-selected builder and
  the secret-supplied config, run authenticated `check-code`, run the warning-clean Cabal build (checked, not
  shipped), build the web bundle, then materialize the builder bytes, config, public keys, and bundle in the
  final layer. They state that only the build coordinator builds the image, because it supplies the
  `hostbootstrap-builder` named context, the four BuildKit secrets, and the two 64-hex key arguments.

#### Validation

`CommandsSpec` case `the Direct derived build uses only the authenticated BuildKit channel` fixes the
Dockerfile stage order, the final warning-clean build, web build, runtime artifact materialization, and the
exported-image probe. Its coordinator slice runs from `runAuthenticatedDirectImageBuild ::` to
`copyBuildTree ::`, which also spans `withAuthenticatedVmBuildSecrets` and `resolvePublishedBaseInVM`, and its
`".hostbootstrap"`, `resolvePublishedBaseInVM cfg provider mAuth`, and `verifyVmProjectImage cfg provider`
needles match whole-file text outside the subject, so those Direct-coordinator and exclusion claims are owed.
Closure requires these cases in `cabal test hostbootstrap-demo-test`, then the complete demo gate:

- a value-level case on a pure exported Direct `docker build` argv function asserting it contains
  `--secret id=hostbootstrap-build-channel,...` and `--build-context hostbootstrap-builder=...`;
- `ignoredBuildEntry ".hostbootstrap" @?= True` (and the same for each other excluded entry), with
  `ignoredBuildEntry` exported;
- the VM call-site needles bound to the pristine-bootstrap VM function body and written so they cannot match a
  definition line (for example `pinnedBase <- resolvePublishedBaseInVM`).

Dated evidence, 2026-08-24: a fresh Production build pulled base digest
`sha256:6254553581475f9f54bd2538d4d5a7ba8528732dabb7c437609014ff56a6aead`, produced derived manifest
`sha256:f5939eb9716a610fbc6e2010392911c2d8eb59df63f6d008bb39e6d0d2730e5b`, and exported a non-empty
80,028,904-byte `/usr/local/bin/hostbootstrap-demo`. The final config (2,579 bytes), both public keys
(32 bytes each), and web bundle (102,333 bytes) were also non-empty before authenticated handoff and the
complete workload sequence succeeded.

#### Remaining Work

- `demo/docker/Dockerfile` header (lines 4-13): rewrite in body order as the Deliverables state, and replace the
  `docker build -f demo/docker/Dockerfile --build-arg BASE_IMAGE=<tag> .` line with the statement that only the
  build coordinator (build #3) builds this image, linking
  `documents/engineering/derived_dockerfile.md#the-check-code-gate`.
- `demo/docker/Dockerfile` lines 18-20 and 57-58: name both public keys (`HANDOFF_VERIFICATION_KEY_HEX`,
  `ACTIVATION_VERIFICATION_KEY_HEX`) installed beside `/usr/local/bin/hostbootstrap-demo` and shipped
  intentionally, and say the signed build channel and the `hostbootstrap-build-verification` secret are mounted
  for the one `check-code` RUN and not persisted.
- `demo/src/HostBootstrapDemo/Commands.hs`: factor the Direct build's `docker build` argv out of
  `runAuthenticatedDirectImageBuild` into a pure exported function and export `ignoredBuildEntry`;
  `demo/test/CommandsSpec.hs`: add the value-level cases above and bound the coordinator slice at
  `withAuthenticatedVmBuildSecrets ::`.
- `demo/test/CommandsSpec.hs`: relabel the post-share witness-ordering assertion, which requires
  `runExactVmShare` to precede `mintVmProviderWitness` but reads "copy-source does not re-mint the ephemeral
  provider witness after the share settles", to "copy-source re-mints the ephemeral provider witness only after
  the share settles".

### Sprint 24.40: Authenticated reverse-child cluster release [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child/Reverse.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Executor/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Production modules**: `HostBootstrap.Command.Child`, `HostBootstrap.Command.Child.Reverse`,
`HostBootstrap.Teardown.Executor.Internal` (3; cap 3)
**Sprint budget**: no new named contract and one authenticated reverse-child call-site adoption; at most 120
production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`,
`documents/operations/demo_runbook.md`

#### Objective

Make callback-free reverse work execute its core-owned retained cluster action in the authenticated child frame
and preserve exact Production/Harness profile identity.

#### Deliverables

- The storeless executor delegates callback-free work to one caller-owned core reverse action instead of
  manufacturing a released observation.
- The authenticated child derives `production` or `harness:<run-id>` only from the verified handoff scope and
  uses that exact admitted profile to derive retained cluster ownership.
- `DeleteCluster` releases the exact recorded exposure before the retained cluster; a failed release remains a
  failed teardown observation.
- A callback-free non-core node is terminally foreign-retained because the current frame acquired nothing it can
  release.
- A child frame's core-managed `DeleteCluster` reaches Phase 16's `releaseRetainedCluster` only through
  `runCoreManagedReverse`, and only under the root-signed `Prepared` grant for that operation:
  `runCoreManagedReverse` is reached only from the `Prepared` branch of `runStorelessReversePreparedKernel`.
- The reverse action is a Cabal-private module within the sprint's 120-line budget; no root store, broker,
  signing key, lifecycle authority, or caller-selected cluster identity enters it.

#### Validation

`HandoffSpec` fixes callback delegation, exact profile derivation, exposure-before-cluster order, non-core
classification, and private-module ownership. Its size guards bound the whole lower executor and child reverse
modules at 400 significant lines each, not the sprint's 120-line increment; `Command/Child/Reverse.hs` is 62
lines. `ProjectPlanSpec` fixes the third sealed
reverse-cursor use and preserves the existing child owner's two-sprint attribution. The focused gates and the
complete warning-clean core gate must pass. These are source-text and module-list guards: every
`RecursiveLifecycleSpec` step declares `reversedBy`, so `runCoreManagedReverse` never runs in a test. Closure
requires the behavioural fixture named under Remaining Work to exist and pass under `cabal test all` from
`core/`.

Dated evidence, 2026-08-24: the complete core host-static gate passed 2,457/2,457 under `-Werror`; the reverse
child source guard proves the private action is the only core callback, and the live Sprint 24.41 run confirms
its retained-cluster release in four fresh child generations.

#### Remaining Work

- `RecursiveLifecycleSpec`: add a POSIX-row fixture variant whose container frame holds a callback-free
  core-managed `core:deploy-kind` node backed by `FakeCluster` (with a recorded exposure relay) and a callback-free
  `core:deploy-chart` node. Drive a nested destroy through the authenticated reverse child and assert:
  - `Command/Child/Reverse.hs` `runCoreManagedReverse` resolves the plan's profile and releases the recorded
    exposure before the retained cluster (the fake's command log shows the relay removal before the cluster
    deletion);
  - with the fake armed to fail the exposure release, the node's observation is `TeardownFailed`, the cluster is
    not deleted, and the root does not mint `SubtreeSettled`;
  - the chart node's observation is `TeardownForeignRetained`.
- `HandoffSpec` source guard: in `Command/Child.hs`, `runCoreManagedReverse` is handed only to `driveReverse`,
  and `driveReverse` passes it to `runStorelessReversePreparedKernel` only inside its `Right ("prepared", _)`
  response branch; no module under `src/` other than `Command/Child/Reverse.hs` and `Command/Child.hs` names
  `runCoreManagedReverse`.

### Sprint 24.41: Harness recursive-lifecycle acceptance [Done]

**Status**: Done
**Implementation**: no production change; the dated evidence is in this sprint's scope note below
**Production modules**: none (0; cap 3)
**Sprint budget**: no new named contract, no call-site adoption, and zero production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`,
`documents/operations/demo_runbook.md`

#### Objective

Confirm the complete two-variant recursive Harness matrix after every worked-demo capability is present.

#### Deliverables

- Each variant performs pristine recursive Up, all five assertions, settled child-first Destroy, a protected
  fresh same-run generation, recursive Up, durable readback, and terminal close.
- Every pristine generation pulls the published rolling base by repository digest and builds its derived image
  without Docker layer-cache reuse.
- The report is exactly ten rows and the terminal audit finds no provider VM, cluster, workload, generated run
  config, or Harness durable root; the operator-owned test config remains.
- Dated evidence records the gate host, toolchain, duration, run IDs, base digest, and all derived image digests.

#### Validation

Run `hostbootstrap run -- test run all` on a fresh disposable linux-cpu host and require exactly `10/10 passed`.
Then audit the provider and filesystem end state and repeat the core, demo, and Python host-static gates.

#### Remaining Work

None. Completed 2026-08-24 on the disposable `hostbootstrap-phase24-cpu-host` gate host: Ubuntu 24.04.4 LTS,
Linux 6.8.0-138-generic x86_64, Incus 6.0.0, Docker 29.1.3, Python 3.12.3, GHC 9.12.4, Cabal 3.16.1.0, and
`hostbootstrap` 0.1.0. The fresh Harness command completed in 105m12.680s and reported exactly `10/10 passed`.
Both `hello-world` (`run-6d81c1594f58`) and `hello-universe` (`run-7059dc5c98eb`) performed write → settled
Destroy → fresh Up → read within one run.

Every one of the four pristine generations pulled published base digest
`sha256:6254553581475f9f54bd2538d4d5a7ba8528732dabb7c437609014ff56a6aead`; their derived image digests were
`sha256:d2c003d48ca746e60d9ca96fb20422dca2b65184e09c33f8660c1c81e3df238e`,
`sha256:c3d185248323121a63b937ae2122020b469eecf824e225035d49bcbe1719d98f`,
`sha256:72a2064bc698e59832dd0f5f4792323d36dc4b5e3fbecf8539dd3b161cdfe7b0`, and
`sha256:c274ee1ecb7898acccc74eb7e5ab8b89432eaf9e6b126379c9722ed735dac615`. The terminal audit found no
`hostbootstrap-demo-vm`, no Harness `.test_data`, and no generated `hostbootstrap-demo.dhall`; the
operator-owned `hostbootstrap-demo.test.dhall` remained. The post-run gates passed core 2,457/2,457, demo
145/145, Python 231/231, and Python coverage 1,331/1,331 statements.

### Sprint 24.42: The live demo matrix run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated live demo lifecycle and matrix run inside the universal linux-cpu realization.

The claim this sprint makes is about the universal floor, whichever outer host realizes it. Where that
host is Windows, the additional Windows-only wall, ownership, and accelerator behavior the same run
exercises is owned by the
[Windows and WSL2 substrate phase](phase-28-windows-and-wsl2-substrate.md), not asserted here.

#### Deliverables

- one dated run of `hostbootstrap run -- project up`, `project down`, `project destroy`, and
  `test run all` reporting `10/10 passed`, naming its host.

#### Validation

The gate host is native x86_64 Windows 11 Home 10.0.26200 with an AMD Ryzen 7 5700G, 15.87 GiB of
host memory, and an NVIDIA GeForce RTX 3090 on driver 616.64. Its toolchain is GHC 9.12.4,
Cabal 3.16.1.0, Poetry 2.4.1, repository-venv Python 3.14.7, Docker CLI 29.6.1, and WSL 2.7.10.0 on
kernel 6.18.33.2-2. The universal `linux-cpu` realization is the WSL2 Linux guest the provider owns.

The current-source static preflight passes on that host. From `core/`,
`cabal test all --ghc-options=-Werror` passes 2,500/2,500 in 329.88 seconds, and the provider-live
component reports its declared no-request `Unsupported` outcome. From `demo/`,
`cabal build all --ghc-options=-Werror` is warning-clean and
`cabal test hostbootstrap-demo-test --ghc-options=-Werror` passes 149/149 in 5.40 seconds. From the
repository root, `poetry run python -m hostbootstrap.check_code` passes and
`poetry run python -m hostbootstrap.test_all` passes 235/235. The 46-file covered source measures
`bead951148f4b26e04c53272877c55c4f80539619efd081335bdeea7367846dd`.

The fresh Production sequence runs through the repository Python bootstrapper against that same
covered source. The generated config declares 6 CPUs, 10 GiB memory, and 80 GiB storage and measures
SHA-256 `5ec0092759c6818db0879c97399f5f33f345062781adf06d5e8214378fbb0a22`. The three canonical
commands are `poetry run hostbootstrap run --project-root demo project up`, `project down`, and
`project destroy`; each uses the harness-owned durable Windows launcher.

| Command | Result | Duration |
|---------|--------|----------|
| Up | exit 0 | 3,542.59 s |
| Down | exit 0 | 33.30 s |
| Destroy | exit 0 | 12.61 s |

Up builds the native project inside a fresh Ubuntu 24.04.4 WSL guest, pulls published CPU/amd64 base
digest `sha256:e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5`, and builds derived
image `sha256:866175c5db3841f4019f19e82e7d183be57e6f3f3f556950dcc2eda9fc835122`. The in-image quality
gate and the exported runtime, config, key, and web checks pass. The kind control plane and the exact
exposure relay run; web, MinIO, and registry pods are Ready and their health endpoints return HTTP 200.
The budget endpoint reports 6/10/80 and `Hello, world!`, the durable endpoint reads the preserved
marker, and the Windows accelerator returns 5 for 2 + 3 with backend `windows-gpu` and artifact hash
`fc76cd884d2539b8`. Down stops the daemon and utility VM and restores the original wall bytes; an
explicit cold guest restart observes the same alias device/inode, target, ownership record, and durable
marker. Destroy removes the distribution, Production mode, and alias ownership row, closes the lease at
epoch 8, and leaves the reverse intent terminal at version 6.

The complete Harness matrix then runs against the same covered source. The harness `test init` entry
writes `.build/hostbootstrap-demo.test.dhall`, which declares the same 6/10/80 resources and the two
stable variants and measures SHA-256
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`. The repository Python
bootstrapper's complete-matrix entry, launched through the harness-owned durable Windows launcher,
starts at 2026-09-11 01:28:44 UTC, exits 0 at 04:26:15 UTC after 10,651 seconds (2 hours 57 minutes
31 seconds), and reports exactly `10/10 passed`. Both `hello-world` (`run-7a1188be2e68`) and
`hello-universe` (`run-7eeb3f4ea634`) pass pristine bootstrap, web build, end-to-end tabs, registry
persistence, and durable readback; each durable-readback case crosses settled destruction and fresh
same-run cluster recreation before reading its retained bytes.

The matrix performs four pristine generations, one per fresh WSL2 guest, at global wall fences 23, 24,
25, and 26. Every generation installs a fresh Ubuntu 24.04 distribution, pulls published CPU/amd64 base
digest `sha256:e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5` without Docker
layer-cache reuse, and builds its own derived image:

| Variant | Generation | Derived image digest |
|---------|------------|----------------------|
| `hello-world` | 1 | `sha256:8997e96ad7e45b71d888b1d51b80227c6e79540cac96ebb4a474cfcac851032d` |
| `hello-world` | 2 | `sha256:de2d2bcfa28c033d6f0d46339021cb6e7181a04f82ca153f9a2ca55b79648a8b` |
| `hello-universe` | 1 | `sha256:0c872c258e4cc260e87219bcb0fb00b163e5bfc6218956087d9c5f1414da685a` |
| `hello-universe` | 2 | `sha256:9e388ac4f0c17d23393824b6db4886bde36f300f3914a76cd706305e9e3f33d8` |

The terminal audit finds both leases `closed`, at epochs 4 and 8, and both profiles `available`. No
project mode, generated-config, or data-root record remains. The generated
`.build/hostbootstrap-demo.dhall` is gone while the operator-owned
`.build/hostbootstrap-demo.test.dhall` remains at its exact hash; `.test_data` exists and is empty and
neither run data directory survives. No WSL distribution is installed, the utility VM is stopped, and no
demo daemon or detached matrix process runs. The global wall is released and `.wslconfig` holds its exact
original SHA-256 `2986099d4e292abed1bacbf7b7cb514188bad4304f930800803a85470ee4e694`. The terminal 46-file
source measurement still matches the in-run
`bead951148f4b26e04c53272877c55c4f80539619efd081335bdeea7367846dd`.

#### Remaining Work

None. The dated run above is complete: the Production sequence, the `10/10` matrix, the terminal
ownership audit, and the matching source measurement.

### Sprint 24.43: The demo's daemon claims are protected-store entries [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/architecture/ownership_invariant.md`

#### Objective

Hold the host accelerator daemon's lifecycle operation and ownership claim as protected-store entries, so a
hard kill of `project up` at any point, including between the ownership claim and the pid write, leaves state
the next run resolves without an operator deleting records by hand.

#### Deliverables

- The lifecycle operation is `withProtectedEntry` over a store in the daemon's own directory: an OS-released
  exclusive lock spanning the whole bracket, so a dead holder of the operation is released by the kernel.
- The ownership claim outlives the process, so it is a compare-and-swapped protected record written under that
  operation entry (`claimHostAcceleratorDaemon`), with `ExpectAbsent` refusing a second live holder and
  `hostAcceleratorDaemonOwned` answering the pid/ownership consistency check.
- One function taking the suffix (`hostAcceleratorDaemonPath`) replaces per-file path accessors.
- A stale claim from a killed predecessor is resolved by the next run: an owner record with no pid file, or an
  empty one, left by a hard kill between the claim and the pid write, is released when no process with the
  daemon's identity runs, and the POSIX pid file is written atomically (temporary file plus rename).
- The stop sequence is a pure decision over (pid file present, owner present, pid, graceful exit, identity
  still ours) interpreted by a thin IO shell: it never signals a PID whose identity probe does not match, and
  preserves the pid file when the process survives a forced stop.
- The Windows launch, stop, and identity-probe PowerShell text quotes through the core `powerShellQuoteArg`;
  the demo carries no quoter of its own, and the Windows launch's argument list is rendered from
  `hostAcceleratorDaemonArgs`, the argv the identity matcher reads.

#### Validation

The host static gate. Closure requires these cases in `cabal test hostbootstrap-demo-test`, then the complete
demo gate:

- a `CommandsSpec` decision table over the pure stop decision: pid absent and owner absent gives no action;
  owner present and pid absent with no matching process gives release; owner present with an empty pid file
  gives release when no matching process runs; a dead or reused PID (identity `Right False`) gives remove-pid
  without signal; a survivor of the forced stop gives refuse-and-preserve-pid; pid present with no owner
  gives refuse;
- a `CommandsSpec` Windows identity row with a matching command line and a different `ExecutablePath`
  (`C:\other\impostor.exe`) expecting `False`, and a row with only one output line expecting `False`;
- a `CommandsSpec` case that the Windows launch script carries every element of `hostAcceleratorDaemonArgs`
  quoted by `powerShellQuoteArg`;
- an `EffectSpec` source guard that fails on any top-level PowerShell quoter definition outside the core quote
  module, under any name, with `powerShellQuote` listed in `retiredQuoterSpellings`.

The behavioural kill-and-restart confirmation belongs to the acceptance phase that declares the hardware: the
daemon runs only on Apple Silicon and Windows/GPU, so no `linux-cpu` gate reaches it. On Apple Silicon it is
[Phase 26](phase-26-apple-silicon-substrate.md) Sprint 26.8, which kills the daemon and its launcher at two
points; the window between `claimHostAcceleratorDaemon` and the pid-file write cannot be hit from outside the
process, so it stays covered by this sprint's `CommandsSpec` decision table. Dated evidence: the
protected operation and claim records landed with `CommandsSpec` pinning their construction, and the demo suite
passed 151/151.

#### Remaining Work

- `demo/src/HostBootstrapDemo/Commands.hs` `stopHostAcceleratorDaemonUnlocked`: when the owner record is
  present and the pid file is absent or empty, release the owner record instead of dying with
  `pid and lifecycle ownership disagree`, after confirming no process matches the daemon identity; write the
  POSIX pid file to a temporary file and rename it. Factor the decision into a pure exported function and add
  the decision table above.
- `demo/test/CommandsSpec.hs`: add the two Windows identity rows above for `hostDaemonIdentityMatches`.
- `demo/src/HostBootstrapDemo/Commands.hs`: delete the private `powerShellQuote` and use `powerShellQuoteArg`
  from `HostBootstrap.Effect` in `hostAcceleratorDaemonPowerShellScript`; widen the `EffectSpec` quoter guard
  as stated above, and add `powerShellQuote` to `EffectSpec`'s `retiredQuoterSpellings` so the deleted name
  cannot return.
- `hostAcceleratorDaemonPowerShellScript`: build `-ArgumentList @(...)` from `hostAcceleratorDaemonArgs` through
  `powerShellQuoteArg` instead of the literal `@('service', 'run')`, so the Windows launch and
  `hostDaemonIdentityMatches` read the same argv; correct its Haddock's "four daemon-specific environment
  overrides" to "the daemon environment overrides" (the caller passes eight). Add a `CommandsSpec` case asserting
  the rendered script contains each element of `hostAcceleratorDaemonArgs` quoted by `powerShellQuoteArg`.

### Sprint 24.44: The demo's cluster configuration and tool paths are its own [Active]

**Status**: Active
**Implementation**: `demo/kind.yaml`, `demo/nvkind-in-cluster.yaml`, `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/test/CommandsSpec.hs`, `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/derived_project_standards.md`

#### Objective

The selector branches once per cluster template that differs, and each checked-in template names the Haskell
renderer as the authority for its bytes. The base image's style-tool location stays a constant the Python
bootstrapper owns and passes as a build argument. The demo's code-check resolves `fourmolu`, `hlint`, and
`cabal` through the closed core `HostTool` resolver and invokes each by the absolute path it admits, on a host
as in the image, so no ambient `PATH` lookup of its own stands outside the § K boundary.

#### Deliverables

- The selector branches once per configuration that differs, or the configurations are made to differ for the reason the branch claims.
- The drift guard that counts mount lines in those files is updated with them.
- The style-tool location reaches the demo through the configuration seam rather than as a literal.
- The demo's code-check resolves its tools on a host as well as in the image through `HostTool.discover`: the
  enumeration names `Fourmolu`, `Hlint`, and `Cabal`, the external tools the check drives, and
  `HostBootstrapDemo.Commands` calls no `findExecutable`. A tool the resolver does not admit refuses by name
  before any check runs. Its Haddock claims no version pin the base image does not hold.
- Each checked-in template's header names the Haskell renderer (`HostBootstrapDemo.ClusterConfig.renderYaml`)
  as the authority for the bytes the plan-owned path applies, calls the file a reference copy that
  Sprint 24.34's byte-agreement case holds equal, and scopes its lanes exactly: `kind.yaml` serves the Kind
  lanes (Linux CPU in-cluster and the Apple/Windows host-resident accelerator); the Linux GPU lane uses
  `nvkind-in-cluster.yaml`.

#### Validation

The host static gate, plus this phase's demo suite. The tree holds `kind.yaml` and `nvkind-in-cluster.yaml`;
the selector branches twice, once per template that differs, and the selector case asserts that the
in-cluster and host-resident contexts choose the same template. `HASKELL_STYLE_TOOLS_DIR` stays owned by the
Python bootstrapper, which passes it as a build argument and the base image puts on `PATH`. Dated evidence:
the demo suite passed 151/151.

Closure also requires: `HostToolSpec` cases that `toolCommandName` of `Fourmolu`, `Hlint`, and `Cabal` is
`fourmolu`, `hlint`, and `cabal`, and that the enumeration's membership pin lists them; a `CommandsSpec` case
over a pure resolution step showing that an unresolved tool refuses with `check-code: <tool> is not available`
before any check runs; and a scoped `CommandsSpec` guard that `demoCheckCode` and its helpers name no
`findExecutable`. All pass under `cabal test all` from `core/` and `cabal test hostbootstrap-demo-test` from
`demo/`, followed by both host-static gates.

#### Remaining Work

- `demo/kind.yaml` and `demo/nvkind-in-cluster.yaml` headers: replace "there is no second copy of this file"
  and "in-cluster and host-resident accelerator lanes alike" with the authority and lane statement in the
  Deliverables. The byte-agreement test is owed by Sprint 24.34.
- `demo/src/HostBootstrapDemo/Commands.hs` `demoCheckCode` Haddock: replace "the formatter/linter/toolchain
  pinned in the base image" with the tools resolved by name on `PATH`, which in the image are whatever versions
  the base image's unpinned `cabal install fourmolu hlint` and `ghcup set cabal recommended` selected when it
  was built, so a republished base can change the check's verdict on unchanged source.
- `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`: add `Fourmolu`, `Hlint`, and `Cabal` to `HostTool`
  with their `toolCommandName`s, and update the membership pin in `HostToolSpec`.
  `demo/src/HostBootstrapDemo/Commands.hs`: replace `resolveCheckTool`'s `findExecutable` with
  `HostTool.discover` and invoke each check through the admitted `AbsExe`; factor the three lookups into a pure
  step over their `Maybe AbsExe` results that refuses an absent tool by name. Add the `HostToolSpec` and
  `CommandsSpec` cases named under Validation.

### Sprint 24.45: The worked-demo gate against the current tree [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Record the complete worked-demo gate against the current covered tree. The host realizes the universal
`linux-cpu` baseline through its supported provider; a Direct Linux GPU run exercises a different lane.

#### Deliverables

- The declared gate runs in full: both demo Cabal legs, the core host-static gate, and the live
  `project up`, `project down`, `project destroy` and `test run all` legs.
- A gate-evidence row records the gate host, the commands as run, and the case total.
- The covers digest is re-measured over this phase's own paths and recorded.

#### Validation

The phase's own gate. It brings up real provider, Docker and cluster state on the host that runs it.

The gate ran in full on 2026-09-14 inside a `linux-cpu` guest VM on an NVIDIA Linux host, described below.
Its recorded source digest precedes the lifecycle short-close correction; the 2026-09-17 run on
`matt-junction` recorded at the end of this section covers the corrected tree.

The `linux-cpu` gate host is a guest VM, because this machine reports `/dev/nvidiactl` and
`/proc/driver/nvidia/version` and therefore realizes `linux-gpu` on metal. The guest was created with no
provider installed, so the chain's own `ensure` step installed Incus inside it — which is what exposed
the two repairs this run also confirms.

The Production sequence:

| Command | Result | Duration |
|---------|--------|----------|
| `project init` | exit 0 | 1,012.69 s |
| `project up` | exit 0 | 2,527.69 s |
| `project down` | exit 0 | 18.56 s |
| `project destroy` | exit 0 | 31.88 s |

`project init` writes the sibling config, which measures SHA-256
`b949ceb3c943ec9b04206b4cbdd2fcf8d2a80da03236745450556c60ae2dcae1`; its duration is the cold host-native
build of the project binary inside the guest, not the command's own work. Up provisions the Incus guest,
builds the binary there, pulls published CPU/amd64 base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, and builds derived image
`sha256:37c013915c0999fa055fcdf055ef649cbb309f2c7462869d398947363ad4ebab` before descending into it for
the cluster, registry, workload and web service. Down stops the guest through its retained ownership
record. Destroy then reports
`project destroy: starting hostbootstrap-demo-vm so its retained children can be reached`, unwinds every
retained child through the frame it reopened, and deletes the guest — the observable the reachability
repair exists to produce, and the exact point at which the same sequence failed before it.

The complete Harness matrix then ran against the same covered source, from 18:34:50Z to 21:14:25Z:
exit 0 after 9,574.61 seconds (2 hours 39 minutes 35 seconds), reporting exactly `10/10 passed`. Both
`hello-world` (`run-3546b7b4d7f`) and `hello-universe` (`run-7bade736622`) passed pristine bootstrap, web
build, end-to-end tabs, registry persistence, and durable readback; each durable-readback case crossed a
settled destruction and a fresh same-run recreation before reading its retained bytes. The four pristine
generations each built their own derived image:

| Variant | Generation | Derived image digest |
|---------|------------|----------------------|
| `hello-world` | 1 | `sha256:34e7966ebf4e6a47d0ca4d414b1e72cce3eba586160e74ac911542c973963e1f` |
| `hello-world` | 2 | `sha256:cd97972a87414af4b26234083e5b368b4c948d8239afb3866042e6c4d0a2c042` |
| `hello-universe` | 1 | `sha256:14f6bdab08eba4ac8085b689ce46ccd897f2d897f02218afd272b58c4f8ebca2` |
| `hello-universe` | 2 | `sha256:7118d37280fb8ff373c21201bea52c545d77ee11d936919b89f586f43c841eaf` |

The terminal audit is clean: `incus list` reports no instance, the generated
`.build/hostbootstrap-demo.dhall` is gone while the operator-owned
`.build/hostbootstrap-demo.test.dhall` remains at
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`, and `.test_data` exists and is empty.
`kind` and `docker` are absent from the gate host's own `PATH`, which is correct for this lane: both live
inside the guest the run created and deleted.

On 2026-09-16, the complete native Windows static gate passes against the short-close correction:
`cabal build all` and `cabal test all` from `core/` (2,543/2,543), `cabal build all`,
`cabal test hostbootstrap-demo-test` (151/151), and `cabal test all` from `demo/`
(151/151 plus 2,543/2,543 core cases), plus the repository Python code check and 251/251
Python tests. The host and command options are recorded in Sprint 17.57. The post-closure documentation
validator passes 11/11 in 6.19 seconds. Production initialization through the repository Python
bootstrapper and harness-owned durable Windows launcher succeeds at 20:33:23 UTC in 27.64 seconds.
Its generated Production config measures SHA-256
`5ec0092759c6818db0879c97399f5f33f345062781adf06d5e8214378fbb0a22` and declares 6 CPUs,
10 GiB memory, and 80 GiB storage. The independently provisioned Linux host also passes every static
gate leg, as recorded in Sprint 29.5, and is removed before Production bring-up begins.
The same durable launcher runs the repository Python bootstrapper's complete Production sequence:

| Command | Result | Duration |
|---------|--------|----------|
| `project up` | exit 0 | 2,618.06 s |
| `project down` | exit 0 | 15.38 s |
| `project destroy` | exit 0 | 9.82 s |

Up runs from 20:39:44 UTC to 21:23:22 UTC. It creates a fresh WSL2 guest at wall fence 31, pulls
published CPU/amd64 base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, and builds image
`sha256:11755765a487337268d3fa68d63fc48711672570b96f2c531507bddda6e4a3ef`.
The image quality gate, web build, exported-runtime verification, unmodified Kind import, registry
push, and web exposure pass. The hidden native Windows accelerator daemon becomes ready at a
loopback-only endpoint. Down restores the original wall before stopping the guest; destroy removes
the stopped guest and exits at 21:23:47 UTC.

The terminal Production lease is `closed` at epoch 11 and no project mode remains. The daemon and WSL
distribution are absent, no active wall record remains, and the original `.wslconfig` hash is restored.
The operator test config retains its exact hash. Production durable data remains, as `destroy` intends.
The runbook's disposable Production-config removal is performed only after its original hash is checked;
the idle WSL utility VM is then shut down before the complete Harness matrix begins.
The complete matrix starts at 21:26:26 UTC with `hello-world` run `run-6e2eb13b6da4`, wall fence 32.
It exits 1 at 22:08:19 UTC after 2,512.69 seconds with `0/12 passed`: an invalid tar header during
Kind image extraction causes failed bring-up, and the corrected close check preserves the unresolved
run instead of releasing its mode. Sprint 28.5 records the image, layer, retained lease, and wall audit.

The final session-journal and canonical-resource corrections pass the complete Windows static gate,
recorded in Sprint 29.5: core 2,547/2,547, demo 151/151 plus 2,547/2,547 core cases, Python code
checks, and 251/251 Python cases. The independent x86_64 Linux gate also passes: 2,552 core cases,
151 demo cases, both Python legs, and the complete demo workspace. The focused demo gate passes
all 151 cases on both platforms. The 46 covered
files now measure `281a2cd1e6247562ae90d3edb1738daa0b498b6c9072c6a382b296ab31e63f5c`.
The normal harness recovery retry at 23:01:51 UTC closes the abandoned session but retains its
unsettled canonical provider/share ownership and Harness mode. It exits 1 with `0/10 passed`, all
refused, after 26.52 seconds. That retained mode also excludes a fresh Production cycle. No complete
current-source live gate is claimed; the previous Production pass predates these corrections.

On 2026-09-17 UTC, the native Linux visit validates the settled working tree on `matt-junction`
and its existing `hb-linux-cpu` gate VM. All 976 tracked working-tree files are copied and verified
byte-for-byte before the live gate. The native host passes `cabal build all` from `core/` and `demo/`,
the focused demo suite (151/151), and the complete host static gate after the real-kernel replacement
fixture corrections in phases 14 and 19: core `cabal test all` passes 2,552/2,552 in 176.58 seconds;
the demo workspace passes 2,552/2,552 core cases in 175.82 seconds plus 151/151 demo cases in
0.69 seconds; the repository Python code check and 251/251 Python tests in 1.65 seconds pass.
The VM reports `substrate: linux-cpu (amd64)` and begins with an empty nested provider inventory
and test-data root. Repository Python-bootstrapper `project init` succeeds.

Production `project up` passes, observed complete by 01:28:28 UTC. It pulls CPU/amd64 base
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, builds image
`sha256:2eb9674f9485106b38afdc36b75f1d987fa2d8e349e2b758f4e94930796dca30`, passes the image quality
gate, web build, exported-runtime verification, unmodified Kind import, and registry push, and reaches
Running web and accelerator pods. `project down` exits 0 in 9.454 seconds. `project destroy` restarts
the stopped guest to reach its retained children, exits 0 in 34.250 seconds, and leaves the nested
Incus inventory empty. The Production lease is `closed` at generation 14, project mode is absent,
and Production durable data is retained. The generated Production config measures
`b949ceb3c943ec9b04206b4cbdd2fcf8d2a80da03236745450556c60ae2dcae1`; the operator test config
retains `8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
The disposable Production config is removed only after that check. `test init` refuses to overwrite
the existing operator test config, which is retained unchanged.

The complete `test run all` starts at 01:30:37 UTC and exits 0 with `test report: 10/10 passed`
in 9,408.679 seconds (2 hours 36 minutes 48.679 seconds). Both variants pass `pristine-bootstrap`,
`web-build`, `e2e-tabs`, `registry-persistence`, and `durable-readback`, including destruction and
same-run recreation before durable readback. Each of the four generations passes exported-runtime
verification and the unmodified Kind import:

| Variant and run | Generation | Derived image digest |
|-----------------|------------|----------------------|
| `hello-world`, `run-270210cc9b7` | 1 | `sha256:414335c49d125bbb5417719240dfe482ec326fa707dd642cf192f205e4eda755` |
| `hello-world`, `run-270210cc9b7` | 2 | `sha256:cfb80494a89ac1c564ac0841c460d2c485e88eb6bfac9229282a8f4b6083faa5` |
| `hello-universe`, `run-6bd796f49d0` | 1 | `sha256:5260f0334c222cdc3640e8d98b2fd52bc125d74f43ae3a1e5181d157c41a3797` |
| `hello-universe`, `run-6bd796f49d0` | 2 | `sha256:53fd80771c56155ef65d1df98849d88c9bc31aa566aeb745e79a6cbb490cdb59` |

The terminal audit at 04:10:38 UTC finds no nested Incus instance, both current Harness leases
`closed` at generations 18 and 22, both profiles `available`, and no mode, generated-config ownership,
or data-root ownership record. The generated config is absent, `.test_data` is empty, and the operator
test config retains its exact hash. The 46 covered files remeasure to that dated run's original digest.
The current-source baseline gate is complete; the preserved Windows run remains owned by phase 28.
The post-closure `DocValidatorSpec` check passes 11/11 in 2.66 seconds.

#### Remaining Work

None.

### Sprint 24.46: The consumer's provider opens on every lane it stops [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: the reachability and stop branches of an action this consumer already receives; at most
120 production Haskell lines and no new type.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

The recursive lifecycle command's reachability step asks the provider reverse to reopen an existing
managed frame so retained children can settle. A reverse opens only a provider the run reached and
retained; a provider that was never created admits no guest descent, guest cleanup, or provisioning.

#### Deliverables

- The Incus branch opens through the retained ownership record, with no caller-supplied generation or
  owner, exactly as its stop and delete peers do.
- The Lima/WSL2 branch admits a present instance of the managed name (`substrateExists` finds `providerVmId`
  in the provider's list output; unlike the Incus branch it consults no retained ownership record) before using
  the plan's reboot-ready effects and the forward path's readiness probe; an absent instance never reaches a
  start effect.
- On WSL2 the reachability branch re-acquires the global wall from `planProviderProvision`'s wall effects and
  runs `applyReconcileCordon` before starting the distribution, exactly as `runVmUp`'s existing-instance path
  does, so a destroy descent after `project down` runs inside the project's cordon.
- The non-Incus stop branch observes its outcome: after the stop effects it probes the running state and
  returns `TeardownFailed` when the frame still runs, rather than reporting `TeardownReleased` unobserved.
- A failed forward before provider creation performs no guest descent or guest cleanup, and the Harness lease
  and mode of that run reach a terminal state.
- Neither branch can reach the stop effect while answering a reachability step.

#### Validation

The worked demo's own live gate on the Incus lane, where the observable is `project destroy` reporting
that it started the provider and then settling every retained child. Every recorded Incus-lane run
(2026-09-14, 2026-09-17, 2026-09-30) predates the 2026-10-20 admission probe that now runs before the
Incus branch, so the Incus-lane confirmation of the current tree is owed. The Lima and WSL2 branches are
confirmed by the [Apple Silicon](phase-26-apple-silicon-substrate.md) and
[Windows and WSL2](phase-28-windows-and-wsl2-substrate.md) acceptances, each on its own hardware; this
phase does not claim them.

**2026-10-17 — absent-provider refusal exposes open work.** The standalone native Apple
matrix refuses its unchanged 80-GiB storage budget against 29 GiB free before forward provider
creation. Reverse then starts an absent `hostbootstrap-demo-vm`, provisioning a default
4-CPU/4-GiB/100-GiB guest rather than reopening retained work. Guest child admission and alias
cleanup fail because that guest has no installed project binary or durable alias. The matrix
reports `0/12 passed`, with unresolved teardown and mode closure. The gate-created guest is
stopped and deleted after its ownership and lack of project state are independently established;
the bound Harness lease and mode are preserved. Sprint 26.7 records the exact failed run.

No dated entry records a selected `test run` between that attempt and the 2026-10-20 visit, or how the
retained `run-3096b80fd8548` lease, its Harness mode, and its consumed profile leave the protected store: the
2026-10-20 visit (Sprint 24.50) begins with `.hostbootstrap` absent. This phase therefore claims no
confirmation that a later run recovers a capacity-refused, Bound Harness lease and its mode; the live
refusal-before-creation run under Remaining Work is the confirmation it owes.

**2026-10-20 — admission and native validation pass.** Reachability probes provider
existence before either provider branch. The pure admission decision returns `TeardownFailed` for
an absent frame, keeping unobserved children outstanding without provisioning or entering a guest.
`CommandsSpec` covers both decision values and guards their call-site order; `TeardownSpec` applies
the real forest transition to the failed reachability observation and verifies retained child work
with no guest descent.

On `MacBookPro`, native arm64 macOS 26.6.2, GHC 9.12.4 and Cabal 3.16.1.0,
`cabal build all` from `core/` and `cabal build all -j1` from `demo/` pass. Plain
`cabal test all` passes in both workspaces: 2,553/2,553 core cases in 553.83 seconds from
`core/`, then 2,553/2,553 in 552.81 seconds plus 164/164 demo cases in 6.25 seconds from
`demo/`. The separately declared `cabal test hostbootstrap-demo-test --test-show-details=direct
--test-options=--hide-successes` passes 164/164 in 5.86 seconds. Both provider-live components
report their declared not-requested `Unsupported` result. Repository-root
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
pass; the final Python runner reports 251/251 in 2.45 seconds. Fourmolu 0.19.0.1 and 0.21
and HLint 3.10 accept all three changed Haskell files.

The additional native negative probe uses `cabal repl exe:hostbootstrap-demo
--repl-options=-ignore-dot-ghci` from `demo/`, real substrate detection and `buildHostConfig`,
and the normal Production-default `projectConfigForRole`. Calling
`demoProviderReverse pc cfg ReachFrame` returns the exact absent-frame `TeardownFailed`;
the equality assertion passes and GHCi exits 0 at 16:35 UTC. Independent snapshots at
16:34:47 and 16:35:36 UTC, with a half-second Lima/state monitor between them, observe
no VM and unchanged absence of `.build`, `.hostbootstrap`, `.data`, `.test_data`, identities,
and daemon state. This proves the actual absent-Lima callback without allocating a failed
Harness lease; it does not claim full capacity-refusal recovery or a traced guest-command count.

Closure requires, beyond the cases above: a `CommandsSpec` case over a pure WSL2 reachability plan asserting
the wall effects and `applyReconcileCordon` precede the reboot-start effects, matching `runVmUp`'s
existing-instance order; a `CommandsSpec` case over a pure stop-outcome decision returning `TeardownFailed`
when the post-stop running probe still observes the frame and `TeardownReleased` only when it does not; the
`CommandsSpec` existence-probe decision rows under Remaining Work; the complete demo gate; and the two live
runs below, each recorded here with its host, date, and terminal state.

#### Remaining Work

- `demo/src/HostBootstrapDemo/Commands.hs` `demoProviderReverse`, `ReachFrame` non-Incus branch: on WSL2,
  run `wallEffectsOnly` of `planProviderProvision` and `applyReconcileCordon` before `rebootStartEffects`
  (factor one helper shared with `runVmUp`'s existing-instance path); add the ordering case above.
- `demoProviderReverse`, stop branch: after `runEffectsBestEffort` of `planProviderStop`, probe the running
  state (WSL2's running-member probe; `limactl list` status on Lima) and return `TeardownFailed` naming the
  frame when it still runs; add the stop-outcome case above.
- `Commands.hs` `substrateExists`: a non-zero `wsl --list --quiet` exit is fatal (`provider existence probe
  failed`). On a fresh Windows host with WSL enabled but no distribution installed, `wsl.exe` exits non-zero
  reporting that there are no installed distributions, so `project up` dies before it can install the managed
  distribution. Factor the `(exit, stdout, stderr)` to member-list decision into a pure exported function. It
  maps a non-zero exit for which `wslReportsNoInstalledDistributions` holds to the empty member list (absent),
  and keeps every other non-zero exit a refusal. Test: `CommandsSpec` rows for exit 0 with the managed name
  (present), a non-zero exit carrying the no-distributions diagnostic (absent), and another non-zero exit
  (refused).
- Live, Incus lane on a native `linux-cpu` host: run Production `project up`, `project down`, and
  `project destroy` on the current tree and record `project destroy` starting the provider through its
  retained record and settling every retained child.
- Live: run a Harness case that refuses before provider creation (an oversized storage budget) end to end and
  record that no provider is provisioned, no guest command runs, and the terminal Harness lease and mode state;
  a lease or mode left unresolved after the absent-frame `TeardownFailed` is a defect of this sprint.

### Sprint 24.47: Revalidate the worked demo after shared guest setup changes [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Config.hs`,
`demo/docker/wsl2-daemon.json`, `demo/test/` — the shared guest setup, the WSL2 Docker daemon configuration,
and S3 store image changed during live revalidation
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

The WSL-only Docker image-store choice and the portable S3 store deployment
change paths covered by this deferred phase. The earlier live worked-demo gate
no longer proves the resulting tree. Re-run this phase's complete declared gate
on a supported outer host before advancing the later acceptance phases.

#### Deliverables

- The static core and demo legs of this phase's gate pass against the changed tree.
- Production up, down, and destroy plus the full Harness matrix pass in the
  universal `linux-cpu` realization.
- The terminal ownership audit and this phase's covered-source digest are recorded.

#### Validation

The changed tree passes `cabal build all` from `demo/`, `cabal build all` and
`cabal test all` from `core/` (2,547 tests), and the demo's
`hostbootstrap-demo-test` (151 tests). The repository Python code check and
test suite also pass (251 tests). The live phase gate and covered-source
digest remain pending. The first fresh Windows/WSL2 `project up` run reached
Docker after a guest-native Haskell build and reported `overlay2` before its
published-base pull. That exact published digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`
pulled successfully. The project image then failed `check-code` because
Fourmolu required a different guarded-case layout in the new WSL driver check.
The source was formatted exactly as suggested and the published base image's
Fourmolu check passed against the host worktree. `project down` could not
reverse the failed up because build #3 had not produced `hostbootstrap-demo:local`.
The uniquely identified production guest and its protected state were archived
and reset; the live gate must be rerun on the formatted source.
After the formatting edit, `cabal build all` and `cabal test all` pass from
`core/` (2,547 tests), `cabal build all` and `cabal test all -j1` pass from
`demo/` (151 demo tests and 2,547 core tests), and the repository Python
code check and all 251 Python tests pass. This re-establishes the static
portion of the gate; the live legs remain pending.
The fresh production `project up` on Windows/WSL2 wall fence 41 exits 0:
the published CPU/amd64 base digest is pulled under `overlay2`, build #3
verifies its exported runtime and web bundle, Kind imports the project image,
the local registry push completes, and the host accelerator daemon reports
ready. `project down` also exits 0, releases the WSL2 wall, restores the
original `.wslconfig`, and stops the guest. `project destroy` exits 0 and
unregisters that guest. The post-production audit finds no active wall,
no WSL registrations or hostbootstrap processes, no active protected mode,
and `.wslconfig` at its original SHA-256. The full Harness matrix remains
pending.
The first matrix invocation refuses `0/10` before guest creation because the
generated production `.build/hostbootstrap-demo.dhall` from `project init`
still occupies the Harness output path. After confirming no active project
process or WSL registration, that generated config is archived outside the
repository at `C:\Users\Matt\AppData\Local\Temp\hb-recovery-archive-20260923\production-config-fence41.dhall`
with matching SHA-256; the operator test config remains present. The matrix
must be rerun with that output path free.
The rerun starts against the unchanged formatted source. Both fresh
`hello-world` generations reach assertions, then destroy their guest and
release the wall; the second leaves the harness ready to open
`hello-universe` under fence 44. This is partial progress, not the complete
`10/10` gate result.
The matrix then exits 1 with `5/12 passed`: all five `hello-world` checks
pass, but the first `hello-universe` guest's Docker 29.1.3 classic `overlay2`
pull of the published base fails after downloading every layer with
`layers from manifest don't match image configuration`. Its assertions are
broken and reverse teardown leaves protected ownership. A diagnostic retry
of the same `docker pull` in that retained guest succeeds at the exact
published digest. The error is in Docker's intermittent pull/unpack path;
this result does not close the phase.
Two further cold pulls of that digest pass after limiting the retained WSL2
guest to one concurrent layer download. The WSL2 daemon config now carries
that setting, and published-base pulls in WSL2 guests have a three-attempt
bound. The changed Haskell source compiles with `-Werror` and passes Fourmolu;
the complete static gate then passes on this tree: `cabal build all` and
`cabal test all -j1` from `demo/` (151 demo and 2,547 core tests),
`cabal build all` and `cabal test all` from `core/` (2,547 tests), the
repository Python code check, and all 251 Python tests. The failed guest's
274 protected-state files and wall record are archived outside the repository,
the wall restores to its original `.wslconfig` hash, and its uniquely
identified WSL registration is removed. The live gate remains owed.
The next fresh production `project up` reaches Docker `overlay2` at WSL wall
fence 45. Its first serialized published-base pull still fails with
`layers from manifest don't match image configuration`; the new bounded
retry reports the pull failure accurately and its second attempt succeeds
at digest `sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`.
The run proceeds to build #3; its terminal result and the matrix remain owed.
Production `project up` then exits 0. Build #3 verifies the exported runtime,
config, public keys, and web bundle; Kind imports the derived image and the
host daemon reaches ready. `project down` and `project destroy` also exit 0.
The audit finds no WSL registration, active wall, protected mode, or
hostbootstrap process, and `.wslconfig` matches its original SHA-256
`2986099D4E292ABED1BACBF7B7CB514188BAD4304F930800803A85470EE4E694`.
The generated production config is archived outside the repository with its
hash intact so the full Harness matrix can use the output path. That matrix
remains the open live leg.
The full matrix's first fresh `hello-world` guest (fence 46) pulls the
published digest on its first attempt, completes build #3 and assertions,
then destroys the guest and releases the wall. Its second fresh guest
(fence 47) reaches `overlay2`; its first published-base pull again fails
with the layer/configuration mismatch, while the bounded second attempt
succeeds at the same digest and proceeds to build #3. The matrix terminal
report exits 1 with `4/12 passed`. The second guest completes build #3 and
starts same-run restart, but `kind load docker-image hostbootstrap-demo:local`
exits 1 inside `project:push-image`. The parent reports a terminal callback
failure after acknowledgement; the retained lifecycle child record exposes
the actual Kind command refusal. Kind's detailed stderr is absent from the
record, so the lower-level import failure is unproven. Failed-Up unwind leaves
the child chain open; teardown and mode close cannot settle its protected
records, and `hello-universe` is refused. The failed guest was unregistered
and the wall restored; 240 protected-state files were archived outside the
repository after verifying the run identity. The WSL-only Kind image load
now has three bounded attempts and emits captured output on stderr for each
failed attempt. This source change compiles with `-Werror`; the full gate is
owed again.
The WSL-only Kind retry passes Fourmolu 0.19.0.1 with the repository style
contract, `cabal build all` from `demo/`, and `cabal test all -j1` from
`demo/` (151 demo tests and 2,547 core tests). The repository Python code
check and all 251 Python tests also pass. The separate core gate and fresh
live legs are in progress. The separate `cabal test all` from `core/` then
exits 0, including the core test suite and the expected skipped native
provider-live lane. The fresh production `project up` has acquired WSL wall
fence 48; its terminal result is pending.
The fence-48 production run exits 1 before Docker: GHCup's pinned GHC 9.12.4
installation exits 1 while `gmake install` copies libraries. Its generated
`make.log` and `ghcup.log` stop during installation without a reported make
error; the guest reports 68 GiB free disk and 9.2 GiB available memory, and
the kernel log contains no OOM kill. Subsequent Hyper-V Worker Admin event
inspection identifies a guest-reported CPU Machine Check Exception and
`Kernel panic - not syncing: Fatal local machine check` at 07:07 local time.
This explains the abruptly stopped installer. The physical or virtualization
fault beneath the reported machine check is not identified. This run never
exercises the new Kind import code and cannot serve
as live gate evidence. Its guest and protected records require the approved
reset before another pristine run.
The approved reset archives the fence-48 wall record, 22 protected-state
files, and the generated production config outside the repository; the wall
restore returns `Right ()`, the verified sole WSL GUID is unregistered, and
`.wslconfig` matches its original SHA-256. A new production attempt is
launched on the unchanged source.
That fence-49 production attempt also exits during GHCup installation, before
Docker. Its extracted GHC profiling archive is 595,591,168 bytes, whereas
the matching member in GHCup's digest-verified download is 617,432,916
bytes; `ranlib` on the extracted archive reproduces `State.p_o: file
truncated`, while the complete tar member passes `ranlib`. Hyper-V Worker
Admin records further guest-reported CPU Machine Check Exceptions and fatal
local machine-check panics at 07:18, 07:20, and 07:25 local time, including
during a direct diagnostic extraction. The run cannot validate the code;
further pristine WSL gates on this host need a stable host/virtualization
environment. The approved operator reset archived the fence-49 wall record,
22 protected-state files, and generated production config outside the
repository. Wall restoration returned `Right ()`, the verified sole guest GUID
`{9c5cb108-819c-4992-85bb-83a7e81090ff}` was unregistered, zero WSL
registrations remain, and `.wslconfig` retains its original SHA-256
`2986099d4e292abed1bacbf7b7cb514188bad4304f930800803a85470ee4e694`.
All four Hyper-V fatal events carry the same machine-check status word
`b200000080060001`; the Windows System log has no WHEA-Logger event in the
same two-day window. The host runs WSL 2.7.10.0, kernel 6.18.33.2-2, and
Windows build 26200.9457. A [Microsoft WSL issue](https://github.com/microsoft/WSL/issues/41649)
reports the same guest status word on another host across later WSL and kernel
versions; it does not establish this machine's underlying cause or a fix.
The previously used `matt-junction` Linux host is reachable but rejects the
available SSH identity with `Permission denied (publickey)`, so its `hb-linux-cpu`
guest cannot be used for the owed gate from this workspace.

The four saved panic dumps and matching Windows Resource-Exhaustion-Detector
events show a concrete host condition at each crash: system commit was
63.62–63.76 GiB against a 63.87 GiB limit. The Windows `psmux` client
`tmux.exe` (PID 11040) accounted for 44.24–45.77 GiB, while `vmmemWSL`
accounted for 7.49–8.63 GiB. The page file is automatically managed; its
limit had grown during the earlier runs. The dumps also contain an earlier
WSLg `Xwayland`/`dxgkrnl` warning. Commit exhaustion is established, but the
mechanism that reports it as a guest machine check is not proved.

A controlled fence-50 Production retry starts through the durable WMI launcher
outside the `psmux` process tree, with ten-second Windows commit and `psmux`
samples. The current Codex process itself runs in an attached `psmux` pane,
so that client cannot be restarted during this session. `project init`
passes. Fresh `project up` installs GHC 9.12.4, builds and installs the guest
binary, pulls base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`,
and reaches Docker build #3. No new guest machine-check or Windows
resource-exhaustion event appears. The attempt is deliberately interrupted
while the image's `check-code` runs: commit reached 23.008 GiB against a
23.347 GiB limit, and `psmux` private commit had grown from 0.07 to 1.67
GiB. Thus it establishes progress beyond the earlier GHC failure, not a
passing Production gate or an isolated no-`psmux` result. Normal `project down`
cannot enter the unfinished image, and `project destroy` refuses the
remaining reverse state. The run's 35 protected files, generated config,
and wall record are archived outside the repository. Wall restoration
returns `Right ()`; verified sole guest GUID
`{41d9da26-9ecd-412f-9c64-9183a67a1d6d}` is unregistered; zero WSL
registrations remain; and `.wslconfig` retains its original SHA-256 above.
The same attached `psmux` client continues growing after the WSL guest is
unregistered, reaching 2.13 GiB while system commit is 12.94 GiB of a
22.34 GiB limit. Its growth is independent of this live WSL guest.

After the operator resets `tmux`, a fresh fence-51 Production `project init`
passes and `project up` starts through the detached WMI launcher. The new
`tmux` client still hosts Codex and grows during the run. Guest GHC installation
and project-binary compilation pass; Docker starts with the WSL-only `overlay2`
store, pulls the published CPU/amd64 base at the digest above, and enters
image build #3. There is no new Hyper-V machine-check event or Windows
resource-exhaustion event. At the build's end, however, Cabal reports that
building `test:hostbootstrap-core-test` segfaulted. Guest `dmesg` records
`ghc_worker` signal 11 and a general protection fault in
`libHSghc-9.12.4-5301-ghc9.12.4.so`. The last sampled Windows commit is
18.011 GiB of 19.745 GiB, with the new `tmux` client at 1.935 GiB; guest
memory after failure has 9.1 GiB available and no OOM kill is recorded. This
attempt therefore fails at a compiler crash without reproducing the earlier
WSL kernel panic. The cause of that compiler crash remains unproven, and the
Production gate has not passed. `project down` cannot enter the unfinished
image; `project destroy` refuses `ModeReverseRootInProgress`. The 22
protected-state files, generated config, and wall record are archived outside
the repository under `failed-production-post-tmux-reset-fence51` with matching
counts and SHA-256 hashes. The core wall restore removes the active record;
the verified sole guest GUID `{fdafab47-5988-4be8-9038-4724a34ea5c0}` is
unregistered. Zero WSL registrations remain and `.wslconfig` retains its
original SHA-256 above. After recording this failure, `cabal test all -j1`
from `core/` passes all 2,547 core tests, including `DocValidatorSpec`; the
native provider-live lane takes its declared skip. `git diff --check` passes.

With the attached `psmux` client detached, the next fresh Production
`project init` passes and `project up` proceeds through guest GHC installation,
the project-binary build, the published CPU/amd64 base pull at digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`,
and the in-image `check-code` step that had segfaulted at fence 51. Windows
commit remains about 16.4 GiB of 19.745 GiB during the image build, with no
new machine-check or resource-exhaustion event. The run then exits 1 during
Kind rollout. The live pod is in `ImagePullBackOff`: Quay returns HTTP 401 for
the demo's `quay.io/minio/minio:latest` image. Direct pulls of a pinned MinIO
release from Quay and Docker Hub also fail. The parent reports a terminal
callback acknowledgement failure, but the pod event identifies the immediate
deployment failure. This run does not establish that `psmux` caused the earlier
GHC crash or WSL machine checks. Normal `project down` and `project destroy`
both exit 0; the audit finds zero WSL registrations, no active wall, and the
original `.wslconfig` SHA-256. The 99 generated protected-state records and
production config are archived outside the repository under
`failed-production-detached-client-20260924`, leaving their worktree paths free
for another run. The unavailable image dependency requires a portable S3 store;
the full live gate remains owed.
After recording this attempt, `cabal test all -j1` from `core/` exits 0,
including `DocValidatorSpec`; `git diff --check` also passes.
The demo now renders a versioned VersityGW POSIX-backed S3 Deployment in place
of the unavailable MinIO image. `docker manifest inspect` confirms that
`ghcr.io/versity/versitygw:v1.7.0` publishes linux/amd64 and linux/arm64
manifests. `cabal build all` from `demo/` passes with `-Werror`. The full
static and live gates must run against this new tree.
On 2026-09-24, the first Production run with that store passes `project init`,
`project up`, `project down`, and `project destroy` on native Windows/WSL2.
The guest pulls published CPU/amd64 base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`,
passes the in-image code check and export verification, and brings up
VersityGW `v1.7.0` and the registry as Ready Kind Deployments. The 16.3 GB
project image loads into Kind and pushes through the S3-backed registry;
the pushed manifest digest is
`sha256:81366613bb1b80ecd325e304cca4a3511a3a03643d06012d1ec3be9fdf00ccf5`.
The web endpoint and hidden Windows host daemon reach readiness. With no
attached `psmux` client, sampled Windows commit remains below 16.8 GiB of a
19.745 GiB limit during the build. Teardown releases the WSL wall, restores
the original `.wslconfig` SHA-256, and unregisters the sole guest. The 108
generated protected-state files and production config (SHA-256
`5EC0092759C6818DB0879C97399F5F33F345062781ADF06D5E8214378FBB0A22`)
are archived outside the repository under `production-versity-20260924` to
leave the Harness output path free. The complete matrix remains owed.
The complete Windows host static gate then passes against this source tree:
`cabal build all` and `cabal test all` from `demo/` (151 demo and 2,547
core tests), `cabal build all` and `cabal test all` from `core/` (2,547 tests,
including `DocValidatorSpec`), the repository Python code check, and all 251
Python tests. `git diff --check` passes. The full live matrix remains owed.
The fresh full Windows/WSL2 matrix started on 2026-09-24 and exited 1 on
2026-09-25 with `4/12 passed`. Its first `hello-world` generation (wall fence
54) built and deployed the image and passed the initial assertions. The
same-run restart for `durable-readback` created a second fresh guest (fence
55); that guest pulled the exact published CPU/amd64 base digest, completed
both project builds, and verified the exported runtime, config, keys, and web
bundle. Its `kind load docker-image` first failed while extracting layer
`sha256:593011a328f7a4180421214f7ebcaf88b70debf94326a0e3b0700c708f32daea`
because the node content store could not find that digest. Both bounded
retries then failed at `docker save` with `file integrity checksum failed for
"usr/lib/x86_64-linux-gnu/libclang-19.so.19"`. Thus the retained local Docker
image could not be exported; repeating Kind import of that same image did not
repair it. The lower-level cause of the fresh guest's local image corruption
is unproven. Failed-Up unwind left the child chain and protected effect record
unsettled, so teardown and mode close reported leaks and `hello-universe` was
refused. The guest was already destroyed, the global wall released, and the
original `.wslconfig` restored. With no WSL registration or hostbootstrap
process remaining, all 137 protected-state files were archived intact outside
the repository under `failed-versity-matrix-fence55-20260925.hostbootstrap`;
`wsl --shutdown` cleared the lingering utility VM. The final audit finds no
WSL registration, hostbootstrap process, active wall, generated run config, or
protected mode, and the `.wslconfig` SHA-256 is again
`2986099D4E292ABED1BACBF7B7CB514188BAD4304F930800803A85470EE4E694`.
The complete live gate remains owed.

The WSL2 bootstrap now checks the derived image with `docker save` redirected
to `/dev/null` before Kind or the registry exists. This reads every archived layer,
including base files that the runtime smoke test does not execute. On the
observed file-integrity-checksum class, it first refuses to clear an occupied
Docker daemon, then removes the guest's unused images and builder cache,
re-pulls the published base with digest verification, and
rebuilds. The repair is bounded to three builds in a project-owned WSL2
guest; other export failures retain their diagnostic and fail. This is a
recovery for the observed local image corruption, not a claim that its
lower-level cause has been identified. The revised source passes the native
Windows static gate: `cabal build all` and `cabal test all` in both `demo/`
and `core/` (151 demo, 2,547 core, and the native provider-live skip),
the Python code check and all 251 Python tests, Fourmolu 0.19.0.1 on the
changed module, and HLint 3.10 with no hints. A fresh Production run and the
complete live matrix remain owed on this changed tree.

The first fresh Production `project up` on the checksum-recovery change
stopped before Kind because its preflight used `docker save -o /dev/null`.
Docker refuses that character device as an output file. In the retained guest,
`docker save hostbootstrap-demo:local > /dev/null` completed successfully,
proving this attempt's image was exportable. The preflight now uses that
redirection, and `cabal build all` in `demo/` passes. Normal `project down`
released the WSL wall and restored the original `.wslconfig`, but `project
destroy` stopped because the guest's durable alias path was a directory where
its ownership record expected a symbolic link. Recovery and the full live gate
remain owed.
The sole WSL registration matched the demo guest and GUID
`{b11e094b-84b6-4aab-8dc8-8e68e22b87b6}`; 84 protected-state files,
both generated configs, and the generated keys were archived intact outside
the repository under `failed-integrity-preflight-20260925`. The approved
operator reset unregistered that guest and shut WSL down. The terminal audit
shows no registered distribution, and `.wslconfig` still hashes to
`2986099D4E292ABED1BACBF7B7CB514188BAD4304F930800803A85470EE4E694`.

The next fresh Windows/WSL2 Production sequence on the corrected preflight
passed `project init`, `project up`, `project down`, and `project destroy`.
The guest pulled the published CPU/amd64 base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`;
`docker save` over the entire derived image and the exported-runtime probe
both passed. Kind's first import failed with a missing containerd content
digest `sha256:9f522cd6153474e0565bf0d2dd54e8b52ab08c80d6b1a64487f523fe3a866fc6`.
The declared retry recovered: the image loaded, the in-cluster push returned
manifest digest
`sha256:449768998ad08b5bd2db741d9719adc3bcdc15bf62ff54f2405dd22b74efd19d`,
and the web service and host daemon reached readiness. `project down`
released wall fence 57 and restored the original `.wslconfig`; `project
destroy` unregistered the sole guest. The host has no WSL registration or
hostbootstrap-demo process, and `.wslconfig` again hashes to
`2986099D4E292ABED1BACBF7B7CB514188BAD4304F930800803A85470EE4E694`.
The 108 protected-state files, generated Production config (SHA-256
`5EC0092759C6818DB0879C97399F5F33F345062781ADF06D5E8214378FBB0A22`),
and generated keys were archived intact outside the repository under
`production-integrity-redir-20260925` to leave the Harness output path
pristine. The full Harness matrix remains owed.
The complete Windows/WSL2 Harness matrix was launched durably at
2026-09-24 23:20 EDT under `phase24-integrity-redir-matrix-20260925`.
Its first `hello-world` generation is `run-1a4ccab22128` and acquired wall
fence 58. The Python host checks on this tree pass (`ruff`, Black, mypy,
251 tests), as do `cabal build all` in `core/`,
`cabal test hostbootstrap-demo-test` in `demo/` (151 tests), and
`git diff --check`. `cabal test all` in `core/` also exits 0, including
the core suite and native provider-live refusal. The matrix outcome remains
pending.
The matrix's first guest at fence 58 pulled the expected published base,
passed the full derived-image archive check, loaded and pushed the image
(manifest `sha256:f87877ead41b6002af4776b1677d2484c027a3a21e23ce379a3b1b6e7a37fe23`),
and reached web and daemon readiness. The Harness opened `hello-world`
assertions, destroyed that guest, restored the WSL wall, and began its
same-run restart at fence 59. The complete matrix result is still pending.
After the README frontier update, `cabal test all` from `demo/` passed again:
151 demo tests and the 2,547-case core suite, including `DocValidatorSpec`.
The second matrix guest at wall fence 59 passed the WSL2 project-image archive
and exported-runtime checks. Its first Kind image import reported missing
containerd content digest
`sha256:9f58ca9c5ce6715bba03208cd6974205b75a52ec2485e10a402153262859a28a`;
the declared retry recovered. The web service and host daemon reached readiness,
the Harness opened the restarted `hello-world` assertions, and normal destroy
released the wall. The same matrix then began its third fresh guest at fence 60
for `hello-universe`; the complete result remains pending.

On 2026-09-30 UTC the native x86_64 Linux visit to `matt-junction` (Ubuntu 24.04.5 LTS, Linux
7.0.0-31-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1) runs this phase's complete
gate against the covered source the Windows visit left, which measures
`04d0e9d3f27226ba03e1546b3bc6ea9b631dd2443e18f64e965bcf4037184d8e`. The host static legs pass on
`matt-junction`: from `core/`, `cabal build all` and `cabal test all` (2,552/2,552 in 216.68 seconds);
from `demo/`, `cabal build all`, `cabal test hostbootstrap-demo-test` (151/151), and `cabal test all -j1`
(151/151 demo cases in 0.83 seconds and 2,552/2,552 core cases in 204.28 seconds); and from the repository root,
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
(251/251 in 1.55 seconds). Both Cabal workspaces run the provider-live component to its declared
no-request refusal. Fourmolu 0.19.0.1 and HLint 3.10 report no change and no hint over `demo/src` and
`demo/app`, the scope of the image's own `check-code`. The live legs run in the existing `hb-linux-cpu`
guest from a pristine demo state: the 2026-09-17 tree and its `.build`, `.hostbootstrap`, `.data`, and
`.test_data` are archived outside the repository, the nested provider inventory is empty, and the guest's
tree measures the same covered digest as the host's. The guest reaches its package mirrors only after
non-persistent `DOCKER-USER` accept rules on `matt-junction` let `incusbr0` traffic past Docker's
`FORWARD DROP` policy; that host firewall state is outside the repository and the gate. The guest runs Ubuntu 24.04.5 LTS on Linux 6.8.0-139-generic with
16 vCPU and 32 GiB, Incus 6.0.0, GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.4.3, and Python 3.12.3, and
`doctor` reports `substrate: linux-cpu (amd64)`.

The repository Python bootstrapper's Production sequence passes in that guest:

| Command | Result | Duration |
|---------|--------|----------|
| `project init` | exit 0 | 1,123.17 s |
| `project up` | exit 0 | 2,539.68 s |
| `project down` | exit 0 | 22.69 s |
| `project destroy` | exit 0 | 35.09 s |

`project init`'s duration is the cold host-native build of the project binary inside the guest; the
sibling config it writes measures `b949ceb3c943ec9b04206b4cbdd2fcf8d2a80da03236745450556c60ae2dcae1`.
Up provisions the nested Incus guest, builds the binary there, pulls published CPU/amd64 base
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, and verifies the derived
image's exported runtime, config, public keys, and web bundle before descending into it. The VersityGW
store reports ready at `object-store.default.svc:9000` with its `registry` bucket, the registry rolls out
behind a runtime-assigned loopback exposure, the image loads into Kind and pushes as manifest
`sha256:a6dfd7e7403ab260f2babe1521168e9b9fc98d74ab6b27f508da58679ff13c50`, the web service answers at its
resolved endpoint, and the in-cluster accelerator daemon rolls out. Down stops the guest through its
retained ownership record; destroy starts it so its retained children can be reached, then deletes it
through that record. The Production audit finds an empty nested provider inventory, the Production lease
`closed`, its reverse root terminal, and no mode record; Production durable data remains, as `destroy`
intends. The
generated Production config is archived outside the repository with its hash intact, and `test init`
writes the operator test config at `8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.

The complete `test run all` starts at 05:04:02 UTC and exits 0 with `test report: 10/10 passed` in
10,976.15 seconds (3 hours 2 minutes 56 seconds). Both `hello-world` (`run-59b4fb85ecb`) and
`hello-universe` (`run-a52709f83c4`) pass `pristine-bootstrap`, `web-build`, `e2e-tabs`,
`registry-persistence`, and `durable-readback`, the last across a settled destruction and a fresh
same-run recreation. Each of the four pristine generations pulls the published CPU/amd64 base digest
above, verifies the derived image's exported runtime, config, public keys, and web bundle, brings up the
VersityGW store with its `registry` bucket, loads the image into Kind and pushes it through the
S3-backed registry, and deletes its guest through the retained ownership record:

| Variant and run | Generation | Pushed manifest digest |
|-----------------|------------|------------------------|
| `hello-world`, `run-59b4fb85ecb` | 1 | `sha256:eca2b198af87aae1480557c87bc227d07f3d45305ed4f9ffa9e52da27bbf3c39` |
| `hello-world`, `run-59b4fb85ecb` | 2 | `sha256:4ef4cfdac1a76cef29d8b76f50ec3634485bb74cd39512feea463afdbab151a3` |
| `hello-universe`, `run-a52709f83c4` | 1 | `sha256:4623b1b7fc253d00b566139b7b614b5044a43ad819c0ed8975b30c23149d51b9` |
| `hello-universe`, `run-a52709f83c4` | 2 | `sha256:b059c25f9ef369335c7659fbaeac593b4f0ea4857dbf67322b7f81007e66dcde` |

The terminal audit at 08:06:58 UTC finds no nested Incus instance, both Harness leases `closed` at
generations 7 and 11, both profiles `available` at generations 6 and 10, and no mode, generated-config
ownership, or data-root ownership record. The generated config is absent, `.test_data` exists and is
empty, the operator test config retains its exact hash, and no project process remains. The 47 covered
files remeasure to that dated run's original digest on both the gate host and `matt-junction`. The current-source
baseline gate is complete.

#### Remaining Work

None.

### Sprint 24.48: Teardown verifies the current protected ownership stores [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Make the Harness's terminal ownership assertion inspect the protected daemon claims and WSL wall
receipt used by the current lifecycle, so obsolete paths cannot admit a false clean teardown.

#### Deliverables

- The daemon assertion takes the current protected operation entry and refuses a retained owner or PID.
- The Windows assertion inspects the current protected global-wall active record.
- Regression cases exercise retained current records, a held operation, and released ownership.

#### Validation

On 2026-10-15, the correction passes the complete native Windows host static gate. The audit finds
`verifyHarnessTeardown` checking removed daemon owner/operation directories and `global-wall.record`
instead of the current daemon `.claims` and per-user `global-wall` protected stores. The assertion
now observes the daemon's existing owner record and the production wall-location API under their
protected entries. Windows profile selection uses `USERPROFILE`, matching the wall backend.

The retained fence-61 wall is settled through `restoreCurrentUserGlobalWall`, invoked through
`cabal exec -- ghci` with the demo's exact owner, specification, reservation, receipt, and managed
body. This typed recovery restores the original file identity and hash, clears the active wall and
retained origin pathname, and preserves the monotonic fence. Eight observer regressions exercise
retained current records, held entries, PID-only residue, released records, never-used stores, and
failed store opens. Fourmolu 0.19.0.1 and HLint 3.10 pass over both edited files;
`git diff --check` passes.

The first demo workspace attempt exits 1 because two new specs treat the compare-and-swap result
as a record rather than the record version it returns. Both specs now pass that version directly
to `ExpectVersion`. Its passing 2,547-case core component in 404.83 seconds does not establish a
passing composed gate; the final complete workspace pass below includes the corrected specs.

The final native gate passes all declared legs:

- From `core/`, `cabal build all` passes warning-clean, followed by
  `cabal test all --test-options=--hide-successes` at 2,547/2,547 in 403.76 seconds after resolution
  of the newer compatible dependency graph. The initial core run also passes 2,547/2,547 in
  535.81 seconds, including `DocValidatorSpec`.
- From `demo/`, `cabal build all --builddir=.build/host-static` passes warning-clean, and
  `cabal test all --builddir=.build/host-static --test-options=--hide-successes` exits 0 with
  159/159 demo cases in 5.60 seconds and 2,547/2,547 core cases in 384.59 seconds. The isolated
  build directory keeps this gate separate from the concurrent bootstrapper's executable build.
- Both Cabal workspaces pass the provider-live component's declared no-request refusal.
- From the repository root, `poetry run python -m hostbootstrap.check_code` passes, and
  `poetry run python -m hostbootstrap.test_all` passes 251/251 in 11.29 seconds.

No production source changes follow the final passing gate.

#### Remaining Work

None.

### Sprint 24.49: Validate the corrected teardown in the complete worked demo [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/engineering/wsl2.md`,
`documents/architecture/durable_state.md`, `documents/operations/demo_runbook.md`

#### Objective

Run the phase's complete declared gate after correcting its terminal ownership assertions.

#### Deliverables

- Production up, down, and destroy pass through the supported Windows/WSL2 baseline realization.
- The complete Harness matrix passes with a terminal ownership and wall audit.
- Gate evidence records the actual commands and the remeasured covered-source digest.

#### Validation

Completed on 2026-10-16 UTC after the 2026-10-15 Windows visit: the corrected tree passes the
complete native Windows and x86_64 Linux static gates, the supported Windows/WSL2 Production
`init`/`up`/`down`/`destroy` sequence, and the complete Harness matrix at `10/10 passed` with exit 0.
Both the Production and final Harness ownership/wall audits pass.

The phase's 29 roots cover 862 authored files: the full live gate's compiled core/consumer components,
package/project and bootstrap metadata, chart/browser/SPA and style/build-context inputs, plus the
static gate's source, tests, schemas, and inspected cluster fixtures. They measure
`25747980e634fb9c9e40bb61d7d28a1479c784607f30fb93a37dd7c70691db19`.
The post-gate measurement on 2026-10-16 is identical; source and authored fixture bytes remain
unchanged throughout the live runs. The earlier 47-file
subset measurement `cbafd88a0d75bfa414560f90c2a7fb4265db1fbf835ac1d29a3ee56ff4d564f1` retains
its narrower provenance.

The final Windows static gate passes core build and 2,547/2,547 core cases in 403.76 seconds;
the isolated demo build and full workspace pass 159/159 demo cases in 5.60 seconds and 2,547/2,547
core cases in 384.59 seconds. Python code checks and 251/251 tests in 11.29 seconds pass.
Sprint 24.48 records the exact commands and the corrected first spec compilation failure.
The first closure documentation check refuses a row that records the complete workspace test but
omits the separately named `cabal test hostbootstrap-demo-test` leg. That exact target is rerun with
`--builddir=.build/host-static --test-show-details=direct --test-options=--hide-successes` and passes
159/159 in 5.55 seconds; the evidence row now records both actual commands.
The closure `DocValidatorSpec` rerun passes 11/11 in 5.43 seconds, checking status harmony,
complete gate-command evidence, and the current covered-source digest.
The complete Linux gate in the Production guest exits 0 at 21:41:23 UTC after 1,214.41 seconds:
core build and 2,552/2,552 cases in 327.64 seconds; the complete demo workspace at 159/159 in
2.08 seconds plus 2,552/2,552 core cases in 326.72 seconds; Python code checks and 251/251 tests
in 3.31 seconds. Both workspaces on both hosts report the provider-live component's declared
no-request result. The 857-file portability subset matches between Windows and Linux before and
after the gate; Sprint 29.5 records its digest, commands, and cache configuration.

All live commands use this checkout's repository Python bootstrapper,
`poetry run hostbootstrap run --project-root demo`, on `DESKTOP-R6BTBVS`.
`project init` exits 0 at 20:30 UTC and writes the Production sibling config with SHA-256
`5ec0092759c6818db0879c97399f5f33f345062781adf06d5e8214378fbb0a22`.
The source-built executable retains SHA-256
`b0a46ea3e9090221811bc925e0e280c365b34845032210d763f2868e90d1458f`;
the operator test config retains SHA-256
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.

Production `project up` starts at 20:31 UTC through the harness-owned WMI durable launcher, label
`phase24-production-up-20261015`, and exits 0 at 21:19:07 UTC after approximately 47 minutes 42 seconds.
It acquires wall fence 62 and creates `hostbootstrap-demo-vm`, Ubuntu 24.04.5 LTS on kernel
6.18.33.2-microsoft-standard-WSL2. Observed allocation is six CPUs, 10,184,824 kB memory, and an
83,955,703,808-byte formatted filesystem from the declared 80 GiB VHD; the managed wall sets
six processors, 10 GB memory, 10 GB swap, and both 21,600,000 ms idle timeouts.
Docker uses `overlay2` and pulls published CPU/amd64 base
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`.
The derived image is `sha256:b6c94394b6d0efc4ee9e21e5733275f15be2262be6d4e158837c6127a1a0225f`.
Its code checks, archive integrity, and exported runtime/config/public-key/web-bundle verification
pass; Kind imports it and all three application deployments become ready. Requests through the
runtime-assigned relay prove CUDA arithmetic and Float32 rounding. Sprint 28.5 records the native
Windows worker and loopback placement observations.

Production `project down`, durable label `phase24-production-down-20261015`, exits 0 at 21:44:23 UTC
and restores the wall before stopping the guest. `project destroy` exits 0 at 21:45:10 UTC and
unregisters that exact guest. The verified Production sibling config is removed through the
runbook's operator step before Harness admission.
The 21:46 UTC audit finds the Production lease closed (record version 5, epoch 3), its consumed
profile retained, no ephemeral mode/config/data-root records, no daemon PID/current protected owner
or native worker, and no WSL registration. The wall is inactive at fence 62 and the original
`.wslconfig` hash and Windows file ID are restored. The operator test config is unchanged,
`.test_data` is empty, and Production `.data` is preserved. Governed durable-state, WSL2, and runbook
prose reflects the managed-alias and restore-before-shutdown contracts; focused documentation
checks pass on Windows and Linux.

The complete `poetry run hostbootstrap run --project-root demo test run all` matrix starts at
2026-10-15 21:46:23.514 UTC through WMI durable label `phase24-matrix-20261015`, PID 31600.
Both `hello-world` generations belong to `run-6b565ce5808`:

- Fence 63 publishes image `sha256:cb897da5442f89b4d45d9ac028e6bf265a4414cfa66f01aebdf51e6b8759eff1`,
  first observed through its verified public web activation manifest at 22:32:48.056 UTC.
- Its engine-owned reconstruction at fence 64 publishes
  `sha256:0bf2239bf5dbe15736c82cd75ed5fc94f6fc35d54c0789dc9403b984bd659294`,
  first observed at 23:19:31.672 UTC.

After world teardown restores the wall, `hello-universe` starts as `run-bcec61e1608` at fence 65,
with WSL GUID `{b7955e79-55ea-46e9-9e16-9700c92cd8ea}` observed at 23:20:14.528 UTC.
Both universe generations complete, with the final recreation at fence 66. The matrix exits 0 at
2026-10-16 00:53:07.207 UTC after 11,203.69 seconds (3 hours 6 minutes 43.69 seconds), reporting
`10/10 passed`: pristine bootstrap, web build, end-to-end tabs, registry persistence, and durable
readback all pass for both variants. Sprint 28.5 holds all four exact image IDs, guest identities,
verified public manifests, and actual published-base pulls.

The final read-only audit passes at 00:55:51 UTC. Both Harness leases are Closed at record version 6
(epochs 7 and 11); their retained Available profiles are record version 3, epochs 6 and 10, with
forward lease version 4. The final destroy invocation advances the lease generation, and terminal
close advances its version again; Sprint 28.5 records the audit helper's corrected comparison.
There are no ephemeral mode/config/data-root records, generated project config, daemon PID/current
protected owner, native worker, or WSL registration. `.test_data` is empty, Production `.data` is
preserved, and the operator test config hash is unchanged. The wall is inactive at fence 66, with
original SHA-256 `2986099d4e292abed1bacbf7b7cb514188bad4304f930800803a85470ee4e694`
and Windows file ID `0x00000000000000000061000000023bde` restored. After wall restoration and
an empty WSL inventory, the supported `wsl.exe --shutdown` exits 0; host process observation confirms
the empty utility VM is stopped.
The Harness itself proves protected-entry release through the corrected production observer; the
external audit does not claim an independent entry-lock probe.

The preceding baseline pass retains its original narrower scope: `demo/src` `demo/app` `demo/test` `demo/docker` `core/hostbootstrap-core/src/HostBootstrap/Lifecycle` `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan`.
Its dated evidence and original digest remain unchanged:

- 2026-09-30 ; `hb-linux-cpu`, an Ubuntu 24.04.5 LTS guest, Linux 6.8.0-139-generic
  x86_64, 16 vCPU and 32 GiB, reused with an empty nested provider inventory under Incus 6.0.0 on `matt-junction`
  (x86_64 Ubuntu 24.04.5 LTS, Linux 7.0.0-31-generic) with nested virtualization, running GHC 9.12.4,
  Cabal 3.16.1.0, Poetry 2.4.3 and Python 3.12.3, where `doctor` reports `substrate: linux-cpu (amd64)` ;
  repository Python bootstrapper `poetry run hostbootstrap run --project-root demo project init`,
  `poetry run hostbootstrap run --project-root demo project up`,
  `poetry run hostbootstrap run --project-root demo project down`,
  `poetry run hostbootstrap run --project-root demo project destroy`,
  `poetry run hostbootstrap run --project-root demo test init`, then
  `poetry run hostbootstrap run --project-root demo test run all` from a pristine demo state, with
  `cabal build all`, `cabal test hostbootstrap-demo-test`, and `cabal test all -j1` from `demo/` and
  `cabal build all` and `cabal test all` from `core/` plus
  `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
  on the x86_64 Linux gate host `matt-junction` ; pass ;
  covers 04d0e9d3f27226ba03e1546b3bc6ea9b631dd2443e18f64e965bcf4037184d8e

The exact 2026-10-16 gate-evidence row is retained for the source that run exercised.
The later formatter update does not restamp this result:

- 2026-10-16 ; `DESKTOP-R6BTBVS`, native x86_64 Windows 11 Home 10.0.26300.9457,
AMD Ryzen 7 5700G, 63.87 GiB, RTX 3090, GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.4.1, Python 3.14.7,
with Ubuntu 24.04.5 LTS/WSL2 6.18.33.2, 6 CPUs, 10 GiB memory and 80 GiB VHD ;
`cabal build all` and `cabal test all --test-options=--hide-successes` from `core/`,
`cabal build all --builddir=.build/host-static` and
`cabal test all --builddir=.build/host-static --test-options=--hide-successes` and
`cabal test hostbootstrap-demo-test --builddir=.build/host-static --test-show-details=direct --test-options=--hide-successes`
from `demo/`,
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
from the root, plus repository-bootstrapper `poetry run hostbootstrap run --project-root demo project init`,
`poetry run hostbootstrap run --project-root demo project up`,
`poetry run hostbootstrap run --project-root demo project down`,
`poetry run hostbootstrap run --project-root demo project destroy`,
`poetry run hostbootstrap run --project-root demo test init`, and
`poetry run hostbootstrap run --project-root demo test run all` (`10/10 passed`, exit 0),
followed by the terminal ownership/WSL wall audit ; pass ;
covers 25747980e634fb9c9e40bb61d7d28a1479c784607f30fb93a37dd7c70691db19

#### Remaining Work

None.

### Sprint 24.49a: Meet the compatible Haskell formatter contract [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/languages/haskell.md`, `documents/engineering/testing.md`

#### Objective

Let the base-publication source preflight pass the compatible formatter without changing runtime
behavior. This sprint owns three production source modules and their affected specs.

#### Deliverables

- Apply Fourmolu 0.19.0.1 import ordering and indentation to the affected core source and specs.
- Express the demo chart values through local `valueLines`, preserving the exact generated text and
  satisfying both Fourmolu 0.19.0.1 and 0.21.
- Validate the source-only change with the host static gate; Sprint 24.50 separately owns live confirmation.

#### Validation

On 2026-10-16, the canonical publication preflight passes all formatter roots with Fourmolu 0.19.0.1
and all linter roots with HLint 3.10; the demo source/app roots also pass Fourmolu 0.21. The native
macOS core build and complete demo workspace build/test pass, including 159/159 demo cases in
5.51 seconds and its core component. After the source edits settle,
`cabal test all --test-show-details=direct --test-options=--hide-successes` from `core/` exits 0 with
2,552/2,552 in 453.84 seconds plus the provider-live component's declared no-request result.
`poetry run python -m hostbootstrap.check_code` passes, and
`poetry run python -m hostbootstrap.test_all` passes 251/251 in 1.89 seconds. The existing governed
Haskell style and testing pages describe this policy accurately and need no contract change.

#### Remaining Work

None.

### Sprint 24.49b: Scope extension pragmas to the branches that use them [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Row.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/languages/haskell.md`, `documents/engineering/testing.md`

#### Objective

Keep the Windows refusal branches' required language extensions while allowing the POSIX lint
preflight to reject unused pragmas. This sprint owns two production source modules.

#### Deliverables

- Guard `EmptyCase` in the POSIX ownership module with the existing Windows CPP condition, retaining
  the extension required by its Windows empty cases.
- Guard `OverloadedStrings` in the ownership-row selector with the Windows condition that uses it.
- Validate the source-only change with the host static gate; native Windows confirmation remains
  owned by Phases 28 and 29, and Sprint 24.50 separately owns the live worked-demo confirmation.

#### Validation

On 2026-10-16, both modules pass focused Fourmolu 0.19.0.1 and HLint 3.10 checks. The finalized
pragmas compile in the native macOS core build and complete demo workspace build/test; its core
component and 159/159 demo cases pass. The subsequent native
`cabal test all --test-show-details=direct --test-options=--hide-successes` from `core/` exits 0 with
2,552/2,552 in 453.84 seconds plus the provider-live component's declared no-request result.
Both Python host-static commands pass, with 251/251 tests in 1.89 seconds. The same current source
also passes the complete arm64 Linux static gate recorded in Phase 29. These are POSIX-host
confirmations; the reopened Windows acceptance retains its own required native run. The governed
style and testing contracts remain accurate.

#### Remaining Work

None.

### Sprint 24.50: Revalidate the worked demo against the complete authored source [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Re-establish this phase's complete gate after the formatter and conditional-pragma work owned by
Sprints 24.49a and 24.49b, the assertion-frame durable-root adoption owned by Sprint 24.38,
and the absent-provider reverse admission owned by Sprint 24.46.

#### Deliverables

- The complete host static gate, core build, demo build, and focused demo suite pass against the complete authored tree.
- Production init, up, down, and destroy pass through a supported universal `linux-cpu` realization,
  followed by the complete Harness matrix reporting `10/10 passed`.
- Terminal ownership, Production-data preservation, and ambient-state restoration are audited, and
  dated gate evidence records every declared leg and a fresh measurement over this phase's evidence paths.

#### Validation

**2026-10-20 — complete phase gate passes.** Sprint 24.46 records the complete native
host static gate and actual absent-Lima callback probe. That static run records no source digest of its own;
the covers digest below is the 16:36 UTC pre-initialization measurement and the post-matrix re-measurement,
so the plan ties the static legs to those bytes by date and host only. Before Production initialization, the
29-root, 862-file source scope measures
`0b27634921cf2e486ef70fcefcc27943206f30197760b685a60ec81d247f80e7`.
All four demo generated-state roots are absent, as are installed identities and Lima instances.
The fresh 16:36 UTC ambient baseline contains the running Colima `default` profile
(9 CPUs, 32 GiB memory, 512 GiB disk), Docker context `colima`, and 38 Docker containers,
including the separately owned arm64 Linux static-gate container. Unrelated workloads are
preserved against this pre-live baseline. The explicit CPU/arm64 rolling-base pull resolves
`sha256:c5bedce2f8cc9bcdc82d46eedfda9bb10bbb2837b64d59258a777a18988590cf`, and Phase 23's
input digest remains unchanged. Repository Python-bootstrapper
`poetry run hostbootstrap run --project-root demo project init` starts at 16:36:29 UTC;
its cold local store resolves against Hackage index state `2026-10-20T12:40:44Z`.
Initialization exits 0 at 17:02:09 UTC after 1,540.15 seconds. The installed binary measures
`60ff3279b02f88ccce2e43e21a66270973528460946780fae49646d0bab682fe`, and the generated
Production config measures `6d5fdb277fbf7a775689f22686c987c5efa923a4611ce7b418d9b4ec9ca06990`.
The five installed identity artifacts are regular, single-link, 32-byte mode-0600 files;
their hashes and file metadata are retained for subsequent comparison. At this checkpoint,
test config, `.hostbootstrap`, `.data`, `.test_data`, and Lima instances are absent.

Production `project up` runs from 17:03:15 to 17:36:29 UTC and exits 0 in
1,994.18 seconds. The native VZ/aarch64 Lima guest has the declared 6 CPUs, 10 GiB memory,
and 80 GiB disk; its machine identity is `a23a05228b31446f83194b64d7573d33`.
Its staged source independently matches the pre-gate Phase 24 scope and the Apple live scope
`ecf6b4522ebbd983f3f702fe6b95e14c7d1c3843811b7fb0c781b3a5a094d0e7`.
The container quality gate and exported-runtime/configuration/public-key/web-bundle verification
pass, producing derived image
`sha256:57c4024a5140c161fcea49f7f3eaf4bd2f4da357749f21b6a03321de229adc76`.
The command reports web readiness at `http://127.0.0.1:32769/` and host-daemon readiness at
`ws://127.0.0.1:32771/api/accelerator/daemon`, PID 8118. An independent observation finds all
12 pods Running and Ready and the daemon reparented to native host PID 1. The independent
17:42:09 UTC application probes pass: the authenticated web exposure returns HTTP 200;
`/api/budget` confirms the declared budget fits; accelerator addition of 1.5 and 2.25 returns
3.75 with backend `apple-metal` and artifact fingerprint `a2d3bf4f0f5612bb`. The daemon launches
a native arm64 Mach-O worker. Marker POST and GET both return `hostbootstrap-destroy-up-v1`,
and the canonical `.data/web/marker` has SHA-256
`05932ad6080575c3081d3870d02780bd1e2750c039f2e4cee37a69de1eeb1c21`.
Binary, Production config, and all five identity artifacts exactly match the post-init metadata
and hashes.

Canonical `project down` exits 0 at 17:47:05 UTC in 285.56 seconds, including a stale-index
refresh to `2026-10-20T17:20:44Z` and its affected dependency rebuild. This rebuild legitimately
replaces the installed executable bytes with SHA-256
`dfbc5f5b798c54f32d3f46a55b91cd2c9d1146d06035fec711dad3649401ced2`;
its inode and size remain the same, and all five identity artifacts and the Production config
retain their complete post-init hashes and metadata. The provider is observed Stopped with
the same directory identity and declared budget. Canonical `project destroy` starts at
17:47:50 UTC to reopen the retained frame for terminal child release.

`project destroy` exits 0 at 17:48:04 UTC in 14.04 seconds. The independent observer sees
the original provider directory inode 480937611 transition Stopped → Running → absent;
the command explicitly starts the stopped frame before releasing its retained children.
The 17:48:26 UTC terminal audit passes: the actual Production lease is Closed at version 5,
epoch 3; its profile remains Consumed at version 2, epoch 1; the project journal is Closed
at version 2; the reverse root is Terminal Destroy at version 6; and the coordinator is Idle
at version 45, sequence 22. No mode, config/data-root ownership, provider directory,
daemon claim/witness, or project process remains. The complete retained `.data` tree has
40 entries (15 directories and 25 regular files), 10,535 file bytes, no symlinks, and
descriptor-relative no-follow fingerprint
`85f63dc8237b2d735ad25ca14596d11b30097554d7b52b26be64194120374441`.
The marker retains its content and inode 480945445. This complete tree and the terminal
record hashes are the preservation baseline for the Harness leg.

Only the verified generated Production sibling config is removed. Canonical `test init`
exits 0 at 17:48:57 UTC in 2.32 seconds and writes the 236-byte operator test config,
SHA-256 `8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
The installed executable and all five identity artifacts match the post-Production snapshot.
The source scopes still match their pre-gate measurements; Lima is empty, and ambient
Colima/Docker inventories and configuration hashes match the pre-live baseline. The matrix
starts at 17:49:19 UTC with 652.25 GiB free, against its declared 6-CPU/10-GiB/80-GiB budget.
The matrix result and terminal preservation audits are recorded after the per-generation checkpoints.

The first Harness generation is observed at 17:49:33 UTC for `hello-world`, run
`run-3f91a394f28d8`: fresh machine identity `4b75e581ad5b42e1ac4cff747f75f799`,
provider directory inode 480962371, and the declared 6-CPU/10-GiB/80-GiB budget.
Its physical run root matches the protected data-root ownership, and both staged source
scopes match the host at 17:49:44 UTC. It starts with no project binary, images, or containers.
Its guest-native build is complete by 18:05:38 UTC, with 152 core and 11 demo object files.
The explicit base pull returns the published CPU/arm64 digest, and the derived image passes
the container quality gate and exported runtime/config/public-key/web-bundle verification
by 18:16:39 UTC. The independently observed image is
`sha256:5f26dabda263e1eb38e8c8041ea2ee244fb0522bd0b9943b59d9960f262093c1`.
The first native daemon is Ready by 18:21:43 UTC and its Metal worker is observed at
18:21:48 UTC. The engine then performs the same-run destroy/recreate. The independent
18:23:18–31 UTC gap audit observes the exact marker under run-root inode 480962139,
marker inode 480981023, with the expected bytes and SHA-256
`05932ad6080575c3081d3870d02780bd1e2750c039f2e4cee37a69de1eeb1c21`.
Its identity/content survive the first provider's removal and the replacement's startup,
before that fresh guest has an application. Marker permissions change from 0644 to 0666
during declared re-preparation; the run root remains 0700. The first daemon and worker
are absent by 18:23:25 UTC. Generation 2 has fresh provider directory inode 480981109
and machine identity `236d0aaf2f374bbfa09751e6d352f572`; it is up and staging the same
run's source/config by 18:26:22 UTC.
Both staged source scopes match again. Generation 2 completes its guest-native build by
18:41:49 UTC, pulls the same published base, and passes the container quality gate and
exported-runtime/config/public-key/web-bundle verification by 18:54:50 UTC. Its independently
observed derived image is
`sha256:4cf11e4f0b16002c2d2996a0b87e376585f397d17145becce289ad22c025cfb7`.
Its application redeploys for the same-run after-restart assertions.
At 18:52:04 UTC an independent mid-matrix audit confirms the entire Production `.data`
fingerprint and metadata remain unchanged, as do its terminal lease/profile/reverse-root/
journal/coordinator record hashes. The installed binary, all five identity artifacts, and
operator test config also match their preservation snapshots. This mid-matrix checkpoint is
not the matrix's final audit, which is recorded after generation 4.

Generation 2 reaches host-daemon readiness at 18:59:36 UTC, opens the same-run
after-restart assertions, and completes terminal destroy before the next variant begins.
At 19:01:00 UTC the first actual Harness lease is Closed at version 6, epoch 7; its profile
is Available at version 3, epoch 6. Its generated-config/data-root ownership and physical
run root are absent. Persisted Harness project journal rows remain Open with Idle
coordinators, separately from the final Closed lease; no journal-closure claim is made.
Generation 3 is observed at 18:59:57 UTC for `hello-universe`, run
`run-3fcf16c002e28`: fresh machine identity `cf251fd0173744d79d28e0d1d4c557d3`,
provider directory inode 481001533, declared 6-CPU/10-GiB/80-GiB budget, and exact owned
data-root inode 481001489/mode 0700. Both staged-source scopes match at 19:00:07 UTC.
This guest starts with no project binary, images, or containers; its cold bootstrap is
complete by 19:15:19 UTC, with 152 core and 11 demo object files. Its explicit base pull
returns the same published CPU/arm64 digest, and its derived image passes the container
quality gate and exported-runtime/config/public-key/web-bundle verification by 19:27:41 UTC.
The independently observed image is
`sha256:0a5838e804c9ef9b5dfd335fabbdeeb186f58d984fddcdc3fab5fe4b97d1eedc`.
Current-visit guest provenance is observed at 19:15:31 UTC: Ubuntu 24.04.4 LTS,
aarch64 Linux 6.8.0-117-generic, GHC 9.12.4, Cabal 3.16.1.0, and Python 3.12.3.

Generation 3 reaches native host-daemon readiness at 19:32:13 UTC, with its Metal worker
observed at 19:32:17 UTC and all 12 pods Ready. During the second engine-owned same-run
destroy/recreate, the 19:33:49–19:34:00 UTC gap audit captures the exact marker at inode
481020405 and the expected bytes/SHA-256. These survive the old provider's removal and
the replacement's Stopped → Running transition before the fresh application exists.
Marker permissions change from 0644 to 0666; run-root inode 481001489 remains 0700.
The old daemon and worker are absent by 19:33:56 UTC. Generation 4 is observed at
19:34:11 UTC: fresh machine identity `77b0cf6eec8c4ae1be74f528cd20dc00`, provider
directory inode 481020640, and the declared 6-CPU/10-GiB/80-GiB budget. It retains the
exact same second-run root, lease/profile epoch 10, and matching staged source scopes
at 19:34:21 UTC. It executes the final cold rebuild and after-restart assertions.
Generation 4 completes its native build by 19:50:00 UTC, pulls the same published base,
and passes the container quality gate and exported-runtime/config/public-key/web-bundle
verification by 20:02:05 UTC. Its independently observed Linux/arm64 derived image is
`sha256:1faf1813adbe5ea66a55b6a1874f92916ae4ffdbf7e068a0f3721b4750cb6cc5`.
The retained marker still has inode 481020405 and the expected 27-byte content/hash before
the final application assertions.

The complete matrix exits 0 at 20:07:19.964 UTC in 8,280.90 seconds, reporting **10/10 passed**.
Both variants pass `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`,
and `durable-readback`, including both same-run assertion phases. All four fresh native
providers and their source/image identities are independently observed:

| Generation | Variant / run | Guest machine identity | Derived image SHA-256 |
|---|---|---|---|
| 1 | hello-world / `run-3f91a394f28d8` | `4b75e581ad5b42e1ac4cff747f75f799` | `5f26dabda263e1eb38e8c8041ea2ee244fb0522bd0b9943b59d9960f262093c1` |
| 2 | hello-world / `run-3f91a394f28d8` | `236d0aaf2f374bbfa09751e6d352f572` | `4cf11e4f0b16002c2d2996a0b87e376585f397d17145becce289ad22c025cfb7` |
| 3 | hello-universe / `run-3fcf16c002e28` | `cf251fd0173744d79d28e0d1d4c557d3` | `0a5838e804c9ef9b5dfd335fabbdeeb186f58d984fddcdc3fab5fe4b97d1eedc` |
| 4 | hello-universe / `run-3fcf16c002e28` | `77b0cf6eec8c4ae1be74f528cd20dc00` | `1faf1813adbe5ea66a55b6a1874f92916ae4ffdbf7e068a0f3721b4750cb6cc5` |

The final host daemon is Ready at 20:07:10 UTC. The independent terminal audit passes at
20:07:38 UTC: all three actual leases are Closed (Production version 5/epoch 3;
Harness version 6/epochs 7 and 11). Production's profile remains Consumed at version 2,
epoch 1; Harness profiles are Available at version 3, epochs 6 and 10. Production's
Closed journal/reverse-root and all retained terminal record hashes match the post-destroy
baseline. Both Harness journals persist as Open at version 1; all three coordinators are
Idle (Production sequence 22, Harness sequence 41 each). No project mode, config/data-root
ownership, generated sibling config, Lima VM/directory, daemon claim/witness, or native
owned process remains; `.test_data` exists and is empty.

The entire Production `.data` tree exactly retains its 40-entry, 10,535-byte fingerprint
`85f63dc8237b2d735ad25ca14596d11b30097554d7b52b26be64194120374441` and metadata.
The post-Production executable `dfbc5f5b798c54f32d3f46a55b91cd2c9d1146d06035fec711dad3649401ced2`,
all five identity artifacts, and operator test config retain their exact metadata and hashes.
The native post-matrix source measurement still matches all pre-gate scopes, including Phase 24's
29 roots/862 files at `0b27634921cf2e486ef70fcefcc27943206f30197760b685a60ec81d247f80e7`.
Ambient Colima profile/budget/configuration, Docker context, all 38 pre-live container identities,
all 11 image entries, and credential-configuration hashes are unchanged; Docker image listing
order differs, with no image-set change. All three owned observers stop with exit 0 at
20:08:08 UTC, and their exact PIDs are absent. The separately owned Linux static-gate
container is retained through final documentation validation, then removed at 20:19:05 UTC;
Phase 29 records its 11/11 Linux documentation check and unchanged ambient-state audit.
The native closing `DocValidatorSpec` command passes 11/11 in 3.56 seconds at
20:14:47 UTC (301.80 seconds including the refreshed dependency/project/test build),
before the next phase's separate live Colima gate starts.

**Earlier gate runs, retained as provenance.** The two runs below precede the 2026-10-20 run above and are
not the phase's covering evidence: the x86_64 run covers `2270a6319a8e…` and the Apple run covers
`82fe6ef5ab04…`, while the header row covers `0b27634921cf…`. Their narratives record what each run
observed on its own date.

The preceding x86_64 gate row retains its original commands and provenance:

- 2026-10-17 ; `hostbootstrap-cpu-gate-20261016`, x86_64 Ubuntu
24.04.5 LTS, Linux 6.8.0-147-generic, GHC 9.12.4, Cabal 3.16.1.0,
Poetry 2.5.1, Python 3.12.3, complete gate executed 2026-10-16–17 UTC ;
`cabal build all` and `cabal test all` from `core/`,
`cabal build all`, `cabal test all`, and `cabal test hostbootstrap-demo-test`
from `demo/`, `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root,
plus repository Python-bootstrapper
`poetry run hostbootstrap run --project-root demo project init`,
`poetry run hostbootstrap run --project-root demo project up`,
`poetry run hostbootstrap run --project-root demo project down`,
`poetry run hostbootstrap run --project-root demo project destroy`,
`poetry run hostbootstrap run --project-root demo test init`, and
`poetry run hostbootstrap run --project-root demo test run all`
reporting `10/10 passed`, followed by terminal ownership,
Production-data preservation, ambient-state, and covered-source audits ;
pass ; covers 2270a6319a8e5bc12c64b9edf057f031f79ba673af2677a9cfcf001b3551d11b

The preceding native Apple run retains its actual commands and source provenance:

-  2026-10-16 ; `MacBookPro`, native arm64 macOS 26.6.2 (build 25G83),
Apple M1 Max, 64 GiB memory, Lima 2.1.2, Colima 0.10.3, GHC 9.12.4, Cabal 3.16.1.0,
Fourmolu 0.19.0.1, HLint 3.10, Python 3.14.3, Poetry 2.3.2 ;
`cabal build all` and `cabal test all --test-show-details=direct --test-options=--hide-successes`
from `core/`, `cabal build all --ghc-options=-Werror`, `cabal test all --ghc-options=-Werror`,
and `cabal test hostbootstrap-demo-test --test-show-details=direct --test-options=--hide-successes`
from `demo/`, `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root, plus repository
Python-bootstrapper `poetry run hostbootstrap run --project-root demo project init`,
`poetry run hostbootstrap run --project-root demo project up`,
`poetry run hostbootstrap run --project-root demo project down`,
`poetry run hostbootstrap run --project-root demo project destroy`,
`poetry run hostbootstrap run --project-root demo test init`, and
`poetry run hostbootstrap run --project-root demo test run all` reporting `10/10 passed`
through the native Lima/aarch64 universal `linux-cpu` realization, followed by terminal ownership,
Production-data preservation, ambient-state, and source-digest audits ; pass ;
covers 82fe6ef5ab04aee2488bf374f13f178cac1f0f8df0c170ee802aea243adfb042

On 2026-10-16 the complete declared gate passed on `MacBookPro`, native arm64 macOS 26.6.2
(build 25G83), Apple M1 Max, 64 GiB memory, with the toolchain and commands in the preceding
preserved dated row.
The phase was reopened before the covered source edits; Sprint 24.49 retains its preceding Windows
pass, original source scope, and digest. That Apple run's 29-root, 862-file scope measures
`82fe6ef5ab04aee2488bf374f13f178cac1f0f8df0c170ee802aea243adfb042` before and after the live run.

The compatible publication preflight passes every Fourmolu 0.19.0.1 and HLint 3.10 root; focused
checks also pass both finalized Windows-only pragma guards. The demo source/app roots additionally
pass Fourmolu 0.21. The core build and full demo workspace build/test pass, including 159/159 demo
cases in 5.51 seconds and its core component. The separately declared demo test target passes
159/159 in 5.45 seconds. A final native `cabal test all` refresh against the settled source exits 0
with 2,552/2,552 in 453.84 seconds and the provider-live component's declared no-request
`Unsupported` result. Both Python host-static commands pass; the final runner passes 251/251 in
1.89 seconds. A separate coverage run passes 251/251 in 1.65 seconds with 100% over 1,413 statements.
`poetry run hostbootstrap doctor` reports `apple-silicon (arm64)` and passes its prerequisites.

The canonical CPU/arm64 base publication exits 0 at 15:14 UTC after source preflight, native build,
local-image consumer smoke, publication, explicit pull, and published-image consumer smoke.
Phase 23 records the dated publication. Production and all four Harness guests explicitly pull
`docker.io/tuee22/hostbootstrap@sha256:c5bedce2f8cc9bcdc82d46eedfda9bb10bbb2837b64d59258a777a18988590cf`.
The derived-image bootstrap verifies the exported runtime, configuration, public keys, and web bundle
before descent. The observed Lima guest is Ubuntu 24.04.4 LTS, aarch64 Linux 6.8.0-117-generic,
with Cabal 3.16.1.0; the native `vz` realization carries 6 CPUs, 10 GiB memory, and 80 GiB disk.
No architecture emulation or nested virtualization is used.

Production init exits 0 at 14:59 UTC. Its installed executable measures
`68c15238abe4700e7a270c1e4d5b424ee5ba3d2efd4fb0ffe6f5283460ee5abf` and its generated config
`6d5fdb277fbf7a775689f22686c987c5efa923a4611ce7b418d9b4ec9ca06990`.
Production up runs approximately 15:15–15:48 UTC and exits 0 with the web service and host daemon
Ready; the exposed web root independently returns HTTP 200. Its guest machine identity is
`b9fe9529e3fe44499db3586fab5ea88a`, and its derived image is
`sha256:d7b5986a56cbf99bc8b098ebefebe514070e0f458300e669b37168253d68d60b`.
Down exits 0 at 15:48 UTC. Destroy exits 0 at 15:49 UTC after restarting the stopped VM to release
retained children and deleting it. The read-only audit observes Production lease Closed epoch 3/
version 5, profile Consumed epoch 1/version 2, reverse-root Terminal Destroy version 6, and journal
Closed at transaction sequence 22/version 2. An initial audit-decoder assertion is resolved by
unwrapping the journal's nested transaction envelope; no stored state or source changes.

After verifying the generated Production config's regular-file identity and exact digest, only that
sibling config is removed through the prescribed operator step. Test init exits 0 and writes the
operator test config, measuring `8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
The complete matrix runs approximately 15:51–17:59 UTC (about 129 minutes), exits 0, and reports
`10/10 passed`. Each variant passes `pristine-bootstrap`, `web-build`, `e2e-tabs`,
`registry-persistence`, and `durable-readback`. The engine performs four fresh Lima bring-ups and
four terminal destroys, including one same-run recreation per variant. A separate read-only observer
captures these identities before automatic teardown and exits 0:

| Generation | Variant / run | Guest machine identity | Derived image SHA-256 |
|---|---|---|---|
| 1 | hello-world / `run-2b855a179ead0` | `90d244c12ff24ff496ad9419957f8b9f` | `183b4a3cf451d60c2b8e40be2ccd182c97e057e1ffdc1089740ffa9d5a36e03b` |
| 2 | hello-world / `run-2b855a179ead0` | `34a3b8414d6b4ab29821357252960c62` | `84ffdb54b49064ce44acc6f2e3a9361b3cdf441c9e3300ec4109d94939a4c1b8` |
| 3 | hello-universe / `run-2bbd549fc29c0` | `8d94d8f28325443ea634cc02b36dc305` | `ec32ccc193e55ca8f8a28308a3dc3a84c78eaf345b24523098c8a5006fbc798c` |
| 4 | hello-universe / `run-2bbd549fc29c0` | `f0b143a362b8495c8a40ad431fde4408` | `bb88b4bfbcfce681ff1df55d9f5e7eabcda5e493e7bfc75975070d19d9487767` |

The 18:00 UTC read-only terminal audit passes without discrepancies. Both Harness leases are
Closed at version 6, epochs 7 and 11; profiles are Available at version 3, epochs 6 and 10,
with forward lease version 4. Production closure records remain exactly unchanged. No ephemeral
mode/config/data-root ownership record, live demo daemon/worker, daemon protected owner, or
PID/ready/shutdown/output witness remains. Lima is empty, the generated Production sibling config
is absent, the operator test config is unchanged, and `.test_data` exists and is empty.

The complete retained Production `.data` tree matches its post-Production fingerprint exactly:
`4b1bb49a369f2ce3680822979fdbe2c1994b9a5e29763e6ab95fd11a5d0504b8`, 39 entries
(15 directories and 24 regular files), 10,508 file bytes, no symlinks, and unchanged root device
16777230/inode 470616174/mode 0755. Descriptor-relative no-follow streaming verifies the full tree.
The installed binary bytes/identity and all five 32-byte mode-0600 identity-file metadata remain
unchanged. The ambient Docker context, Colima profile listings/configuration hashes, and Docker
credential hash match the visit's initial snapshot. Unrelated workloads are left in place; their
container IDs are not claimed stable during concurrent external work. The separate Phase 29 static
container remains temporarily for final documentation validation and its own cleanup.

The runbook now states the combined pristine-visit Production-to-Harness sequence and the separate
native direct-Colima leg. No runtime contract changes. The unchanged-source Apple matrix also supplies
Phase 26's matrix leg; that phase separately owns Metal/direct-Colima acceptance and its 845-file digest.

On 2026-10-16–17 UTC, the then-current source passed the complete static gate, Production
lifecycle, and full Harness matrix on the independent x86_64 CPU gate host
`hostbootstrap-cpu-gate-20261016`, UUID `6c040aea-0554-4f14-ab67-30c27bbd18a1`,
provisioned through Incus on `matt-caledon-desktop`. The gate host runs Ubuntu 24.04.5 LTS,
Linux 6.8.0-147-generic, with 8 CPUs, 24 GiB memory, and a 250 GiB sparse root disk.
Nested AMD virtualization is enabled; the KVM API and VM-creation ioctl pass, NVIDIA markers
are absent, and the repository bootstrapper's `doctor` reports `linux-cpu (amd64)`.
Its own Incus project starts empty. The pre-existing stopped metal VM is preserved.

The corrected working-tree source and real checkout metadata are copied into `/root/hostbootstrap`
without build state, caches, installed identities, or credentials. GHC 9.12.4, Cabal 3.16.1.0,
Poetry 2.5.1, and Python 3.12.3 drive the run. Independent initial metal and guest measurements
agree on the 29-root, 862-file scope:
`2270a6319a8e5bc12c64b9edf057f031f79ba673af2677a9cfcf001b3551d11b`.
The complete static gate starts at 2026-10-16 20:09:04 UTC after the pristine-state audit.
Its actual command results are:

- From `core/`, `cabal build all` passes its cold build in 1,085.23 seconds, and
  `cabal test all` passes 2,552/2,552 in 191.17 seconds (354.15 seconds including the test build).
- From `demo/`, `cabal build all` passes in 15.32 seconds,
  `cabal test hostbootstrap-demo-test` passes 161/161 in 1.82 seconds, and canonical
  `cabal test all` exits 0 in 353.16 seconds, including 2,552/2,552 core cases in 201.73 seconds.
- From the repository root, `poetry run python -m hostbootstrap.check_code` passes, and
  `poetry run python -m hostbootstrap.test_all` passes 251/251 in 2.30 seconds.

Both provider-live components report their declared no-request disposition; these are not live
provider acceptance results. The demo static leg starts at 20:33:41 UTC after the Production
bootstrap releases its Cabal build tree. The external
`/root/.config/hostbootstrap-phase24/cabal.config` preserves baseline settings and selects only
the existing `/root/hostbootstrap/demo/.build/cabal-store`, avoiding another cold dependency
build without changing source or solver inputs.

All live commands use this checkout's repository Python bootstrapper,
`poetry run hostbootstrap run --project-root demo`. Production `project init` exits 0 in
1,308.36 seconds. `project up` starts at 2026-10-16 20:32:56 UTC and exits 0 in 3,325.49 seconds.
Its native inner Incus provider has 6 CPUs, 10 GiB memory, 80 GiB storage, and UUID
`8e09d5e3-10ba-4745-ae9e-31972e25f3d1`. The generated config and installed binary hashes,
and all five 32-byte, mode-0600 identity-file metadata, are captured without reading key bytes.
Production and all four Harness generations anonymously pull the published CPU/amd64 base,
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, matching
Phase 23's published evidence. Base inputs remain unchanged. Production's container quality gate
and exported-runtime verification pass at 21:18:37 UTC, producing derived image
`sha256:37d4f8220e4fdf9ada80d8d8a0f3b5d8a142775bdfbd5f3a960bebbf9ad8a6b4`.

The independent 21:28:37 UTC application check verifies the 182-byte HTML, 102,333-byte bundle,
fitting 6-CPU/10-GiB/80-GiB budget, and actual accelerator result `3.75` on the `linux-cpu`
artifact `1cde4043891ef815`. Marker POST and GET both return `hostbootstrap-destroy-up-v1`;
the canonical outer `.data/web/marker` holds the same 27 bytes, SHA256
`05932ad6080575c3081d3870d02780bd1e2750c039f2e4cee37a69de1eeb1c21`.
Canonical `project down` exits 0 in 40.97 seconds and `project destroy` in 40.50 seconds.
The 21:31:21 UTC Production audit finds the inner provider absent, the actual lease Closed at
version 5, epoch 3, its profile Consumed at version 2, epoch 1, and no mode/config/data-root
ownership or host-daemon/process witness. The journal is Closed at version 2, transaction 19;
the reverse-root record is Terminal Destroy at version 6, target 3. Its retained admission
successor is Bound at version 4, epoch 3, distinct from the actual final Closed lease.
The binary and all five identity-file metadata remain unchanged. The retained `.data` tree has
44 entries (17 directories and 27 regular files), 10,514 file bytes, and streaming no-follow
fingerprint `917683fa25ef40887e5e54844e01841ba88812ed515b17c03917c1252ead65d0`.
The marker retains its bytes, hash, inode, mode, and owner through both reversals.

After verifying and removing only the generated Production sibling config, canonical `test init`
exits 0 in 3.51 seconds. The 236-byte regular operator test config measures
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
The complete canonical `test run all` starts at 2026-10-16 21:31:59 UTC, exits 0 at approximately
2026-10-17 01:08 UTC after 12,968.49 seconds, and reports `10/10 passed`. Both variants pass
`pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`, and `durable-readback`.
Each variant retains its exact run/config across its engine-owned destroy/recreate and completes
both assertion phases. All four fresh providers are independently observed; each passes its native
bootstrap, container quality gate, and exported-runtime verification:

| Generation | Variant / run | Provider UUID | Guest machine identity | Derived image SHA-256 |
|---|---|---|---|---|
| 1 | hello-world / `run-5d21ca81fe0` | `6c76d09d-36db-4626-bd25-0c0c8829c179` | `6c76d09d36db4626bd250c0c8829c179` | `f95b9fb48cefe7711021b20ae1c5cf99c12ceef028fcd822ba3ae3b8db76c2be` |
| 2 | hello-world / `run-5d21ca81fe0` | `9dcf0c20-b3d1-4b8d-87ed-14e496d58832` | `9dcf0c20b3d14b8d87ed14e496d58832` | `b6102824d379204179e1a46f0522ae135c3f497959d7b89aefa23364494f091f` |
| 3 | hello-universe / `run-bb655a33e1c` | `5b2686ce-396c-4634-bc07-0a3441682758` | `5b2686ce396c4634bc070a3441682758` | `7d4f288c6153cfe531b88942fb28d14e0f0d39799690f11a5bf8148ab0c440a2` |
| 4 | hello-universe / `run-bb655a33e1c` | `a1add52f-8114-438c-b8d7-e94771625ff8` | `a1add52f8114438cb8d7e94771625ff8` | `f804ef08f15598c148f6dc181846e1ea6ee6dc358216e9ee923298522bbedaa4` |

The generation-2 provider is created at 2026-10-16 22:25:52 UTC. At 22:27:18 UTC,
before its application build, descriptor-relative no-follow traversal independently reads the
exact outer `.test_data/run-5d21ca81fe0/web/marker`: the expected 27 regular-file bytes and SHA256
`05932ad6080575c3081d3870d02780bd1e2750c039f2e4cee37a69de1eeb1c21`, device 2050/inode
2813235, mode 0666, uid/gid 0, and one link. Identity/content metadata is stable through the read;
read-atime is excluded. The bytes remain present after the first provider's destruction and before
the recreated application can write. Generation 2 reaches actual web readiness at 23:19:45 UTC
and CPU-daemon readiness at 23:19:51 UTC, then completes after-restart assertions and terminal destroy.

Generation 3 is created at 2026-10-16 23:20:04 UTC, and generation 4 at 2026-10-17 00:13:59 UTC.
At 00:14:02 UTC, before the recreated application can start, the exact outer
`.test_data/run-bb655a33e1c/web/marker` independently holds the same expected bytes and SHA256.
Descriptor-relative no-follow traversal confirms a regular file, device 2050/inode 2813235,
mode 0666, uid/gid 0, one link, and stable content/identity metadata through the read.
The four derived images are independently observed at 2026-10-16 22:15:46 and 23:10:14 UTC,
and 2026-10-17 00:03:47 and 00:58:10 UTC, respectively.

Generation 4 reaches web readiness at 2026-10-17 01:07:53.326 UTC and CPU-daemon readiness
at 01:07:58.274 UTC, with `DaemonConnected` and the `linux-cpu` artifact `1cde4043891ef815`.
Its after-restart assertions and terminal destroy complete before the final matrix report.

The independent terminal audit passes at 2026-10-17 01:08:55.705694 UTC. The two actual Harness
leases are Closed at version 6, epochs 7 and 11; their profiles are Available at version 3,
epochs 6 and 10, with forward lease version 4. No project mode, generated-config ownership,
data-root ownership, generated sibling config, provider VM, daemon directory/owner/witness,
or live project process remains. `.test_data` exists and is empty. The operator test config's
content and metadata remain unchanged, with its original SHA256
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
Both retained Harness project journals are Open at version 1, transaction 1, as the declared
source semantics permit: `finalizeHarnessClose` closes the actual run lease and then releases
the exact mode epoch. These journal rows are recorded separately from the final Closed leases.

The complete retained Production `.data` tree exactly matches its post-Production no-follow
fingerprint `917683fa25ef40887e5e54844e01841ba88812ed515b17c03917c1252ead65d0`:
44 entries, 17 directories, 27 regular files, and 10,514 file bytes. The Production lease
Closed at version 5, epoch 3, profile Consumed at version 2, epoch 1, journal Closed at
version 2, transaction 19, and reverse-root Terminal Destroy at version 6, target 3 retain
their exact recorded byte hashes. The installed binary retains its file identity and SHA256
`d3a1b5fc390411f7771d9e74da0be3ebab9159b3ce7371f6069c630056c4bdeb`;
all five 32-byte, mode-0600 identity-file metadata remain unchanged.

The final metal and guest measurements agree over all 29 roots and 862 files at
`2270a6319a8e5bc12c64b9edf057f031f79ba673af2677a9cfcf001b3551d11b`, matching the
pre-gate source. The 01:09:22 UTC native ambient-state audit passes: the pre-existing stopped
Incus VM is unchanged, Docker reports no containers, no compute GPU process remains, and the
same Xorg PID 1734 and GNOME PID 1886 remain.

After the final seven-file documentation sync, the closure `DocValidatorSpec` check passes
11/11 natively in 3.66 seconds and 11/11 on the gate host in 3.89 seconds. All five guest
phase covers digests still match after that sync. The independent observers stop cleanly at
01:10:25 UTC, with an empty inner provider inventory.

At 01:11:38 UTC, the separately owned development gate host is deleted after re-verifying its
exact UUID. The 01:11:55 UTC cleanup audit confirms that exactly its two IP-scoped forwarding
rules are removed and `DOCKER-USER` has no remaining rule. The only metal Incus instance is the
pre-existing stopped `hostbootstrap-demo-vm`, unchanged at UUID
`a62c4700-1bd7-45a1-9497-4b165a60ee91`. Docker and GPU-compute inventories remain empty,
the same Xorg/GNOME PIDs remain, and the original metal GHC 9.14.1 default is restored.
The post-cleanup 29-root, 862-file source measurement still matches
`2270a6319a8e5bc12c64b9edf057f031f79ba673af2677a9cfcf001b3551d11b`.

#### Remaining Work

None.

### Sprint 24.51: The web ingress, HTTP routes, and service ports hold their stated refusals [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Web/Server.hs`, `demo/src/HostBootstrapDemo/Web/Api.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `demo/test/WebServerSpec.hs`, `demo/test/ConfigSpec.hs`,
`demo/web/src/Main.purs`, `demo/playwright/tests/demo.spec.ts`
**Production modules**: `HostBootstrapDemo.Web.Server`, `HostBootstrapDemo.Web.Api`, `HostBootstrapDemo.Config`
(3; cap 3)
**Sprint budget**: no new named contract beyond the two port-role newtypes; at most 400 production Haskell lines.
Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/accelerator_daemon.md`, `documents/engineering/derived_dockerfile.md`

#### Objective

The web service's daemon ingress and HTTP routes refuse every input their contract names, under behavioural
test. The two listener ports are distinct role types over the core `HostBootstrap.Network` `Port`.

#### Deliverables

- `acceleratorDaemonServer` rejects any upgrade carrying an `Origin` header and any path other than
  `/api/accelerator/daemon`.
- `responseFromDaemon` and `dispatchToPeer` turn a mis-correlated response, an undecodable frame, an echoed
  request, a daemon failure, a disconnect while waiting, and a dispatch timeout into 503s.
- `registerPeer` replaces a prior daemon; `clearPeerIfCurrent` clears the hub only for the current peer.
- `parseAcceleratorAddRequest` decodes `requestId` as UTF-8 (`decodeUtf8'`) and refuses invalid UTF-8. It refuses
  NaN, infinite, and overflowing `left`/`right` with `acceleratorBadRequest`, and `/api/accelerator/add` answers
  400 for missing or non-numeric parameters.
- `WebServiceConfig` holds `PublicPort` and `AcceleratorPort` newtypes over the core `HostBootstrap.Network`
  `Port`. The demo `Port`/`mkPort` and `validateServiceType`'s `validPort` range branches are gone, so swapping
  the two listeners is a type error and the only remaining role-parameter refusal is the distinctness check.
- `Web.Api`'s Haddock says `budgetView` is a fixed illustrative mirror (`demoBudget = Budget 6 10 80`) computed
  by the compatibility `fitsBudget`, not the bring-up cordon's verdict.
- The SPA comment, the Playwright test name, and the docs name four tabs: Overview / Budget / Status /
  Accelerator.

#### Validation

The `WebServerSpec` and `ConfigSpec` cases under Remaining Work exist and pass in
`cabal test hostbootstrap-demo-test` from `demo/`, followed by the demo host-static gate.

#### Remaining Work

- `WebServerSpec`: run `WS.runClientWith` with header (`Origin`, `http://evil.test`) against
  `acceleratorIngressApp`; assert the handshake is rejected and `acceleratorDaemonConnected` stays False. Add a
  second case connecting to `/other` and asserting the same.
- `WebServerSpec`: add fake daemons that reply with (a) a result for another requestId, (b) raw garbage bytes,
  (c) an `AcceleratorRequest`, and (d) an `AcceleratorFailure`; assert the status and the `failureMessage` reason
  for each. Add one daemon that closes before replying and assert 503 with the peer cleared.
- `WebServerSpec`: connect daemon A, then daemon B; assert A's socket closes, `acceleratorDaemonConnected` stays
  True, and B answers a dispatch.
- `Server.hs`: decode `requestId` with `decodeUtf8'` and refuse invalid UTF-8; after `readMaybe`, refuse
  `isNaN`/`isInfinite`. Add `WebServerSpec` requests to `/api/accelerator/add` with `left` missing (400),
  `left=abc` (400), `left=NaN` (400), `left=1e39` (400), `requestId=%C3%A9` (echoed as `é`), and valid values
  with no daemon (503).
- `Config.hs`/`Server.hs`: replace the demo `Port`/`mkPort` with `PublicPort` and `AcceleratorPort` newtypes over
  `HostBootstrap.Network.Port`, decoded through the demo's `refiningDecoder` over the core `mkPort`. Delete
  `validPort` and the range branches from `validateServiceType`. Make `runLinkedListeners` take the two role
  types. Add `ConfigSpec` cases refusing ports 0 and 65536 at decode and admitting 1 and 65535.
- `ConfigSpec` "role parameters validate ports and request timeout before dispatch": rename it to what it
  reaches, assert the exact `Left "Web publicPort and acceleratorPort must be distinct"`, and add the
  `mkTimeoutSeconds 1` boundary.
- `Api.hs`: rewrite the module and `budgetView` Haddocks to state that the fixed budget and the compatibility
  `fitsBudget` are an illustrative mirror, not the cordon's admission.
- `demo/web/src/Main.purs` (line 22) and `demo/playwright/tests/demo.spec.ts` (line 21): say four tabs,
  Overview / Budget / Status / Accelerator.

### Sprint 24.52: The demo's guest probes and case assertions carry no interpreter text [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: no new named contract; at most 400 production Haskell lines. Split by call-site group
(case assertions; VM readiness and share probes) if the estimate exceeds the cap.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Every probe the demo runs in a guest or cluster frame for readiness or for a case assertion is a described
argument vector run through the one interpreter, or a lifted typed binary operation, with every comparison done
in Haskell. Under the plan standards' interpreter-text rule, the only irreducible interpreter residue is the
core guest-bootstrap module. Sprint 24.53 owns the image-build, image-verification, and published-base pull
paths, Sprint 24.78 the Windows host-daemon lifecycle, and Sprint 24.79 the whole-module absence guard and the
core PowerShell quoter's deletion.

#### Deliverables

- The case assertions run their probes as direct argument vectors through `liftLeaf`, with no
  `RawCmd "bash" ["-lc", ...]`: `assertE2EInVM` (Playwright through `docker run --workdir ... playwright test`,
  Commands.hs near 3863-3874), `assertRegistrySurvivesRestart` (near 3937-3948), and `assertDurableReadback`
  (near 3974-4020).
- The durable-share identity probe (near 4277-4299, which crosses `wsl -d <distro> -- bash -lc` on Windows)
  runs single-command typed leaves and compares device, inode, and target in Haskell.
- The VM readiness and share probes take an argv through the provider guest route rather than a `bash -lc`
  script: `awaitDurableShareMounted`, `captureInVMStdout`, `waitVMNetwork`, `waitDockerReady`,
  `runInDemoVMStdin`, `streamVMConfig`, and the `runInDemoVM` callers that pass shell text.
- `demoGuestShellArgs` is replaced by an argv-taking guest route for these callers.
- The pristine-bootstrap install-Docker step is a pure function of `ProviderKind` returning its command list.
  Only `ProviderWsl2` installs `demo/docker/wsl2-daemon.json` as `/etc/docker/daemon.json` and then requires
  `docker info --format {{.Driver}}` to report `overlay2`. Every other provider keeps
  `systemctl enable --now docker`. The overlay2 verdict is a pure function of the probe output.

#### Validation

`CommandsSpec` argv-shape cases for each rewritten call site, and the install-Docker and overlay2 cases, exist and
pass in `cabal test hostbootstrap-demo-test` from `demo/`, followed by the demo host-static gate. The live `10/10` matrix confirms
the assertions on the next acceptance run.

#### Remaining Work

- Rewrite the assertion probes (`assertE2EInVM`, `assertRegistrySurvivesRestart`, `assertDurableReadback`) as
  argument vectors, each built by a pure exported function of its inputs (and of `AssertionPhase` for durable
  readback); add `CommandsSpec` cases pinning each argv, including that the `BeforeRestart` argv POSTs the
  marker and the `AfterRestart` argv reads the same marker.
- Rewrite the durable-share identity probe as single-command leaves (one `stat`-style leaf per observed
  coordinate) with the comparison in Haskell; add a `CommandsSpec` case over the pure comparison.
- Rewrite the guest probes and stdin/stdout helpers (`awaitDurableShareMounted`, `captureInVMStdout`,
  `waitVMNetwork`, `waitDockerReady`, `runInDemoVMStdin`, `streamVMConfig`, and shell-text `runInDemoVM`
  callers) to take argv through the provider guest route; add a `CommandsSpec` case per helper pinning the argv
  it hands the route.
- Extract the install-Docker `guestStep` command list into the pure `ProviderKind` function above, and the
  overlay2 check into a pure verdict over the `docker info --format {{.Driver}}` output. `CommandsSpec`
  cases:
  - for `ProviderWsl2`, the list installs `wsl2-daemon.json` as `/etc/docker/daemon.json`, restarts Docker,
    and is followed by the overlay2 probe;
  - for `ProviderIncus` and `ProviderLima`, the list contains no `daemon.json` install and contains
    `systemctl enable --now docker`;
  - the verdict admits `overlay2` and refuses any other driver with the `is not overlay2` message.

### Sprint 24.53: The demo's image builds and published-base pull carry no interpreter text [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: no new named contract; at most 400 production Haskell lines. Split by call-site group
(image build and verification; published-base resolution) if the estimate exceeds the cap.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/engineering/registry_credentials.md`

#### Objective

The demo's build #3, image verification, image-archive probe, and published-base pull carry no shell text.
Credential forwarding is not this sprint's: Sprint 21.10 of the
[composition and network phase](phase-21-composition-and-network-algebra.md) deletes `dockerAuthStdinWrapper`
from `HostBootstrap.Registry` and moves `buildProjectImage` and `resolvePublishedBaseInVM` onto the binary's
typed forwarding operation, which reads the opaque `registryConfigPayload` on stdin and exposes it as
`HOSTBOOTSTRAP_REGISTRY_AUTH` to its Docker child only. No `docker login` runs, so no credential is written to the
guest's persistent `~/.docker/config.json`. This sprint removes the `bash -lc`, `/bin/sh -ec`, `cd ... &&`, and
`>/dev/null` text that remains at these call sites after Sprint 21.10. Each Docker invocation becomes one
argument vector. The vector goes to that typed operation when a `RegistryAuth` is present, and to Sprint 24.52's
argv-taking provider guest route when the pull is anonymous.

#### Deliverables

- Build #3 is one argv built by the pure exported `projectImageBuildArgv :: FilePath -> [String] -> [String]`
  from the guest build context and `dockerBuildArgsWithVerificationKey`'s arguments. The `-f` Dockerfile path and
  the positional context are rooted at the guest build context, so no `cd` precedes it. `runBuildImageReporting`
  takes that argv instead of a script and keeps its captured-output-on-failure reporting.
- The published-base pull is the argv `["docker", "pull", tag]` from the pure exported `publishedBasePullArgv`.
  `resolvePublishedBaseInVM`'s retry loop and its `RepoDigests` digest pin are unchanged.
- Image verification runs no entrypoint override. Both `verifyVmProjectImage` and `verifyDirectProjectImage` run
  `docker run --rm --entrypoint stat <image> --format=%s\t%n <path>...`, an argv from the pure exported
  `exportedProjectImageStatArgv`, over the five paths `exportedProjectImageProbe` names today. The pure
  exported `exportedProjectImageVerdict :: String -> Either String ()` requires each path to be present and
  non-empty, and the two `.pub` keys to be exactly 32 bytes. Each refusal names the failing path. The `--help`
  check is the argv `docker run --rm <image> --help`, with its stdout discarded in Haskell rather than by
  redirection.
- `probeVmProjectImageArchive` runs `docker save --output /var/tmp/hostbootstrap-demo-image-probe.tar <image>`
  and then `rm -f` on that path, both as argv through the guest route, with no `> /dev/null`.
  `exportedProjectImageProbe` is deleted.

#### Validation

The sprint closes when these cases exist and pass in `cabal test hostbootstrap-demo-test` from `demo/`,
followed by the demo host-static gate:

- `projectImageBuildArgv` returns an exact golden argv for a fixture context. The argv has no `cd`, `&&`, or
  `bash` element, its `-f` operand and last element are both under the fixture context, and `--no-cache` and the
  secret arguments sit before the context.
- `publishedBasePullArgv`, `exportedProjectImageStatArgv`, and the archive-probe argv each return an exact
  golden argv.
- For a `RegistryAuth` fixture built with `dockerHubAuthFromConfig`, the build and pull argv handed to Sprint
  21.10's typed forwarding operation contains no element equal to or containing that fixture's
  `registryConfigPayload`. The payload reaches the operation only as its stdin input.
- `exportedProjectImageVerdict` admits a fixture `stat` output with five non-empty paths and two 32-byte keys.
  It refuses a missing path, a zero-length binary, and a 31-byte key, each by name.

The live `10/10` matrix confirms the build paths on the next acceptance run.

#### Remaining Work

- `Commands.hs`: add `projectImageBuildArgv` and drop the `cd ... &&` `buildImageScript`. Make
  `runBuildImageReporting` take the argv and pass it to Sprint 21.10's typed forwarding operation when
  `buildProjectImage` holds a `RegistryAuth`, or to the Sprint 24.52 guest argv route otherwise. Add the golden
  and no-credential `CommandsSpec` cases above.
- `Commands.hs`: add `publishedBasePullArgv` and drop the `bash -lc` pull script from `resolvePublishedBaseInVM`.
  Use the same routing as the build. Add its golden case and its no-credential case.
- `Commands.hs`: replace the `/bin/sh -ec` `exportedProjectImageProbe` in `verifyVmProjectImage` and
  `verifyDirectProjectImage` with `exportedProjectImageStatArgv` plus `exportedProjectImageVerdict`, and the
  `--help ... >/dev/null` text with an argv whose output Haskell discards. Add the golden and verdict cases.
- `Commands.hs`: rewrite `probeVmProjectImageArchive` as the `docker save --output` and `rm -f` argv pair, with
  no `bash -lc` or redirection. Add its golden case.

### Sprint 24.54: The demo registry path is plan-derived, scoped, and tested [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Config.hs`,
`demo/test/CommandsSpec.hs`, `core/hostbootstrap-core/src/HostBootstrap/RegistryPlan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrapDemo.Config` (2; cap 3)
**Sprint budget**: no new named contract; at most 300 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Every registry and object-store address and NodePort the demo renders comes from one source. Store credentials
reach only the `mc` invocation that needs them. Push diagnostics address the plan-owned cluster. The blob-route
canary and the pure push and blob-route classifiers are tested as their Haddocks say.

#### Deliverables

- `registryConfigYaml` renders its S3 store address through core's `renderStorageStoreEndpoint` (Sprint 21.2),
  so `regionendpoint` is `endpointAuthority (registryPlanStore plan)`. `objectStoreClusterEndpoint` is a
  projection of `registryPlanStore` of the demo registry plan, and the duplicate
  `"object-store.default.svc:9000"` literal is deleted. Its Haddock ("a projection of the plan's store
  endpoint, never assembled separately") is then true.
- The semantic exposure targets in `Config.hs` (`("registry", 30500)`, `("object-store", 30900)`) and the
  registry and object-store Services read `registryNodePort` and `objectStoreNodePort` from one shared
  definition, so the Haddock's "the Service and semantic exposure intent both derive from it" holds.
- `ensureRegistryBucket` passes `MC_HOST_local` only to the `mc mb` run through a per-command environment
  overlay, with no process-wide `setEnv`; if the interpreter has no overlay, the setting is bracketed with
  `unsetEnv` in `finally`.
- `dumpPushDiagnostics` takes the cluster kubeconfig (`demoClusterKubeconfigPath`) from `pushImageAction` and
  builds every argv with `kubectlWith kubeconfig`; otherwise the `TEMP DIAGNOSTIC` block is deleted.
- `isTransientPushError` is exported and tested; `parseBlobRouteAnswer` is tested; `pushImageBlob`'s Haddock
  describes the policy-bounded poll and its `PollTimeout` rendering, with no final `runOrDie`.
- The canary blob is the one-byte blob `"a"`: `canaryBlobDigest`'s Haddock says so, and a test pins
  `canaryBlobDigest == sha256(canaryBlobPayload)`.
- `awaitBlobRoute` reads the HTTP status line of the `-D -` headers in its open and patch steps and treats 5xx
  as `NotReady`; a commit failure restarts from a fresh session rather than re-PUTting a consumed session URL,
  and the digest query joins with `?` or `&` according to whether the `Location` already carries a query.
- The readiness comments at Commands.hs near 1877-1896, 1980-1982, 2069-2073, and 2287-2288 call `ObservedReady`
  tags non-authorizing observations and drop the "type error" claims. Sprint 24.70 moves the image build and push
  steps onto plan-indexed `Ready`.

#### Validation

Cases required in `CommandsSpec`:

- `isTransientPushError` returns True for each marker and False for `unauthorized` and `denied`.
- `parseBlobRouteAnswer` on a `demoRegistryPlan` with a fixed exposure: `"200 "` gives no redirect,
  `"307 http://minio:9000/x"` gives a redirect with the store's scope, and `""` and `"abc"` are refused.
- The rendered registry config's `regionendpoint` equals the plan store authority, its storage lines equal
  `renderStorageStoreEndpoint` of the plan, and `objectStoreClusterEndpoint` equals
  `endpointAuthority (registryPlanStore plan)` for the demo registry plan.
- `canaryBlobDigest` equals `"sha256:"` followed by the hex SHA-256 of `canaryBlobPayload`, computed with the hash
  already in the demo's dependency closure.
- The pure upload-step classifier: a `500` status line is `NotReady`, a `202` with a `Location` is ready, and
  the digest joiner yields `?digest=` for a query-free `Location` and `&digest=` otherwise.
- The semantic exposure targets carry `registryNodePort` and `objectStoreNodePort`.

Then the demo host-static gate.

#### Remaining Work

- Implement each deliverable above with its case. Delete the duplicate endpoint literal, the duplicate NodePort
  literals in `Config.hs`'s semantic target list, the process-wide `setEnv`, and the unscoped kubectl
  diagnostics.

### Sprint 24.55: The accelerator runtime suites fail on the regressions they name [Planned]

**Status**: Planned
**Implementation**: `demo/test/AcceleratorRuntimeSpec.hs`, `demo/test/AcceleratorSpec.hs`,
`demo/src/HostBootstrapDemo/Accelerator.hs`
**Production modules**: none, unless a test seam requires an export (at most 40 lines)
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Each accelerator protocol, correlation, worker, and source case fails when the behaviour its name promises
regresses.

#### Deliverables

- The Float32 case decodes hand-built CBOR bytes carrying the double `16777217.0` and asserts the decoded
  `Float` is `16777216`; the supervisor case named `supervisor arithmetic has Float32 rounding semantics` is
  renamed to the pass-through of the worker value it checks, and the Float32 property rests on the real worker
  case.
- The correlation cases accept a matching-id `AcceleratorFailed` response, reject a mismatched-id
  `AcceleratorSucceeded` response, and assert the `request-id mismatch: expected req-1, got req-2` text.
- The `production WebSocket transport consumes its shutdown check` case, which only reads back the field it was
  given, is deleted; the live transport case in `WebServerSpec` covers the production path.
- The real worker build-and-run case fails when `detect` returns `Left`; for a missing lane or toolchain it
  reports a named `Unsupported` outcome, never a silent pass (testing.md: no case is skipped).
- The real worker case builds into a fresh `withSystemTempDirectory`, so `buildWorkerAtomically` runs every time.
- Every `runDaemonClientLoop` case is wrapped in `System.Timeout.timeout` and fails on expiry.
- `AcceleratorSpec` asserts the `CUDA_CHECK` failing branch (`if (status != cudaSuccess)` followed by
  `return 5;`).
- `AcceleratorSpec` pins a golden `stableSourceHash` and asserts that the C++, CUDA, and Swift source hashes are
  pairwise distinct.

#### Validation

The cases above exist and pass in `cabal test hostbootstrap-demo-test` from `demo/`, then the demo host-static
gate.

#### Remaining Work

- Implement each deliverable above as stated (findings F1557, F1564, F1566, F1567, F1555, F1556, F1560, F1561,
  F1558).

### Sprint 24.56: The web server suite fails on the regressions it names [Planned]

**Status**: Planned
**Implementation**: `demo/test/WebServerSpec.hs`, `demo/test/Spec.hs`,
`demo/src/HostBootstrapDemo/Web/Server.hs`
**Production modules**: none, unless a test seam requires an event-counter export (at most 40 lines)
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Each web-server case fails, with a message naming the defect, when the behaviour its name promises regresses,
and no regression can hang the suite instead of failing it.

#### Deliverables

- The idle-past-timeout case counts `DaemonConnected` events: exactly one, and no `DaemonDisconnected`, across
  the idle window, with a nonzero reconnect delay longer than the window.
- The linked-listener bind-failure case asserts `isAlreadyInUseError`, and that a connect to the public
  listener's port is refused after return.
- The busy-path dispatch is wrapped in `timeout 5000000` and fails with "busy request queued on the peer lock"
  on expiry.
- The public-listener refusal case asserts `acceleratorDaemonConnected hub == False` after the attempt and
  matches a rejected handshake carrying status 404, not any exception.
- The fake daemons run under `forkFinally` into an `MVar` that the main thread asserts holds `Right ()`, so a
  protocol defect fails with its own message rather than as `503 /= 200`.
- The threaded-RTS contract is asserted at runtime with `rtsSupportsBoundThreads` (and `getNumCapabilities`)
  beside the cabal-stanza text check.

#### Validation

The cases above exist and pass in `cabal test hostbootstrap-demo-test` from `demo/`, then the demo host-static
gate.

#### Remaining Work

- Implement each deliverable above as stated (findings F1585, F1587, F1595, F1593, F1594, F1596).

### Sprint 24.57: Demo command tests bound their subject [Planned]

**Status**: Planned
**Implementation**: `demo/test/CommandsSpec.hs`, `demo/test/Spec.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: pure extractions only; at most 150 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/languages/haskell.md`

#### Objective

`CommandsSpec` ordering, route, and readiness claims hold for the function they name, not for text elsewhere in
`Commands.hs`, and each case name states what the case exercises.

#### Deliverables

- A test helper slices exactly one top-level declaration, ending at the next top-level signature, and matches
  whole identifiers.
- `the cluster action adopts exact provider, reconcile, cordon, readiness, and package order` slices only
  `deployKindAction`; its route choice is a pure function of the context, asserted for a Direct and a VM context.
- The stage-order cases near CommandsSpec 242 and 343 are bounded to their subject declarations.
- The per-provider share readiness command (`shareReadinessCommand`) and the Harness permission-restore argv are
  pure functions asserted per provider, replacing the whole-file fragment checks near CommandsSpec 545-573.
- The durable-readback source guard near CommandsSpec 895 is replaced by assertions on the per-phase probe that
  Sprint 24.52 makes a pure function of `AssertionPhase`.
- `validated direct context keeps nvkind even if the inner host detects CPU` is renamed to `validated direct
  context selects nvkind; ordinary container selects kind`, since `containerPlan` takes no detection input.
- Source-text guards remain only for "this legacy identifier is absent" and are scoped to declarations.
- The demo suite's `main` (`demo/test/Spec.hs`) sets `setLocaleEncoding utf8` before any case runs, as the core
  suite does, so the source reads in `CommandsSpec` decode the same bytes on a non-UTF-8 code page and the demo
  leg of the host static gate holds the § JJ portability rule.

#### Validation

Each rewritten case fails under the mutations recorded in findings F1568, F1569, and F1570, for example
`providerRoute` set to the VM route in the Direct branch, `registerRunningProviderDependencyPackage` deleted from
`runExactVmProvider`, and `findmnt` moved off the `ProviderIncus` arm. A demo case asserts that
`textEncodingName <$> getLocaleEncoding` is `UTF-8` inside the suite. Then the demo host-static gate.

#### Remaining Work

- Implement the helper and each rewritten case above (findings F1571, F1568, F1569, F1570, F1584, F1572).
- `demo/test/Spec.hs`: call `setLocaleEncoding utf8` (from `GHC.IO.Encoding`) at the start of `main`, and add
  the locale-encoding case above.

### Sprint 24.58: Demo command refusal tests assert the named refusal [Planned]

**Status**: Planned
**Implementation**: `demo/test/CommandsSpec.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: pure extractions and one typed teardown refusal; at most 150 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Every `CommandsSpec` refusal case asserts the specific refusal its name claims, so an earlier unrelated refusal
cannot satisfy it.

#### Deliverables

- The forward-child and parent-join refusals near CommandsSpec 728-766 assert the specific `Left` message (or its
  prefix) of `demoForwardChildPlan` and `demoDirectParentJoin`, and a new case passes `directLift` (or a perturbed
  container lift) for `vm-orchestrator-1 -> vm-project-container-2` and expects the "lift differs" refusal.
- The forbidden host-port field list near CommandsSpec 787 lists each field once; the duplicate `"hostPort ::"`
  becomes `"hostPorts ::"` or is removed.
- `validateAcceleratorReplicaCount 0` is refused, and both refusals' messages contain `haReplicas=`.
- The pid-prefix case catches `IOException`, asserts `"invalid pid file"` in its text, and removes its temp file
  in `finally`.
- The image-build grant case asserts the spec-digest field of a `BuildBinding` built by a pure exported
  constructor against an independent fixture digest, rather than recomputing `demoImageBuildSpecDigest`.
- `verifyHarnessHostArtifacts` raises a typed refusal (or the helper captures stderr), and
  `assertHostTeardownRefused` takes the expected reason, distinguishing "Lifecycle operation remains active",
  "ownership remains", "PID remains", and "cannot inspect".
- The demo's harness safety check reaches core's `testSafetyPreconditions` through its own production probe:
  `demoTestSafety` delegates to an exported `demoTestSafetyWith :: HostConfig -> FilePath -> IO (Either String ())`.
  A `CommandsSpec` case uses a fixture `HostConfig` whose Docker tool is a fake that lists the managed
  control-plane container. There `productionClusterRunning` answers True, and the case asserts
  `Left "a production cluster is already running; refusing to touch production state"`. With no such
  container, the case asserts `Right ()`.

#### Validation

The rewritten cases exist and pass in `cabal test hostbootstrap-demo-test` from `demo/`, then the demo
host-static gate.

#### Remaining Work

- Implement each deliverable above as stated (findings F1573, F1574, F1582, F1581, F1583, F1580).
- Extract `demoTestSafetyWith` from `demoTestSafety` and add the two harness-safety `CommandsSpec` cases above.
  Core's own `True`/`False` cases for `testSafetyPreconditions` are owed in `HarnessSpec` by phase 19.

### Sprint 24.59: Runtime-dependency packages are minted for the plan they bind [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Lifecycle.Dependency.Internal`,
`HostBootstrap.Lifecycle.Execution.Internal`, `HostBootstrap.Substrate.Provider.Backend`,
`HostBootstrap.Cluster.Backend` (4; above the § G cap of 3). This is a recorded § G exception: the
signature change threads one witness through the two fixed producer call sites, each a one-argument change,
and no module gains a second contract.
**Sprint budget**: one new named contract, `PlanBinding`, and no call-site adoption beyond the three producer
calls; at most 200 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

`RuntimeDependencyPackage scope planId` declares nominal roles for `scope` and `planId`, but every producer is
polymorphic in both. The plan and scope that bind a package are plain `Text` fields that nothing ties to the
indices. This sprint makes the indices a guarantee: a package is minted only from a witness of the plan it
binds.

#### Deliverables

- `Lifecycle.Dependency.Internal` defines `PlanBinding scope planId`, carrying the plan digest and scope
  commitment text, with nominal roles. Its constructor is used only by `Lifecycle.Execution.Internal`, which
  mints it from a `StepExecution scope planId`.
- `mkProviderRuntimeDependencyPackage`, `mkProviderShareRuntimeDependencyPackage`, and
  `mkClusterRuntimeDependencyPackage` take a `PlanBinding scope planId` in place of the plan and scope `Text`
  arguments, and return a package at those indices.
- The producers in `Substrate.Provider.Backend` and `Cluster.Backend` pass the binding minted from their own
  execution. `Cluster.Backend`'s runtime comparison of the producer gate with the execution's plan digest
  remains: it checks the gate, not the package.

#### Validation

Under `cabal test all` from `core/`:

- a compile-fail fixture `test/compile-fail/RegisterForeignPlanPackage.hs`, registered in `CompileFailSpec`, that
  mints a package from one plan's execution and registers it in another plan's `StepRuntime`, rejected with a
  `Couldn't match type` phrase naming `planId`;
- a compile-fail fixture `test/compile-fail/ForgePlanBinding.hs` that constructs `PlanBinding` outside
  `Lifecycle.Execution.Internal`;
- a `LifecycleDependencySpec` case asserting that a minted package's plan and scope fields equal the
  execution's.

Then the core host-static gate.

#### Remaining Work

- Add `PlanBinding` and its `Lifecycle.Execution.Internal` producer, change the three package producers and
  their two call-site modules, and add the two fixtures and the field case above.
- Add a source guard: no module other than `Lifecycle.Execution.Internal` imports the `PlanBinding`
  constructor.

### Sprint 24.60: Carried runtime-dependency packages are rebound before use [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Dependency.Internal`, `HostBootstrap.Handoff`,
`HostBootstrap.Handoff.Process` (3; cap 3)
**Sprint budget**: one new named contract, `CarriedRuntimeDependencyPackage`, and no call-site adoption; at most
300 production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/binary_context_config.md`

#### Objective

A package decoded from wire bytes carries no plan witness, yet `runtimeDependencyPackageFromWire` and
`runtimeDependencyPackagesFromBundleWire` return it at caller-chosen indices. `Handoff` instantiates them at
`RuntimeDependencyPackage () ()`. This sprint makes a decoded package unindexed until the receiving frame
rebinds it against its own plan.

#### Deliverables

- The two wire decoders return `CarriedRuntimeDependencyPackage`, which has no `scope` or `planId` index and no
  opener of its own.
- `rebindCarriedRuntimeDependencyPackage :: PlanBinding scope planId -> CarriedRuntimeDependencyPackage ->
  Either Text (RuntimeDependencyPackage scope planId)` is the only way to an indexed package. It refuses when the
  package's plan or scope text differs from the binding.
- `Handoff`'s field decoders and `Handoff.Process`'s carrier seeding (`seedProviderDependencyCarrierKernel`)
  hold carried packages and rebind them with the child frame's `PlanBinding` before registration.

#### Validation

Under `cabal test all` from `core/`: `LifecycleDependencySpec` cases rebinding a decoded package under its own
binding (`Right`) and under a binding for another plan digest or scope (each `Left` with its field named).
`HandoffSpec` keeps its round trips over the carried type. A compile-fail fixture
`test/compile-fail/OpenCarriedPackage.hs` passes a `CarriedRuntimeDependencyPackage` to
`withProviderRuntimeDependencyCoordinates` and is rejected. Then the core host-static gate.

#### Remaining Work

- Add `CarriedRuntimeDependencyPackage` and `rebindCarriedRuntimeDependencyPackage`, move the two decoders and
  their `Handoff`/`Handoff.Process` callers onto them, and add the cases and the fixture above.

### Sprint 24.61: Chart workload and service activation declarations carry role types [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/StepSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Lifecycle.Plan`, `HostBootstrapDemo.Commands`
(3; cap 3)
**Sprint budget**: one new named contract, the `ChartWorkloadDeclaration` record with its role newtypes, and
one demo call-site adoption; at most 300 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

`declaresChartWorkloadResource` takes nine positional `Text` coordinates and stores an anonymous 10-tuple.
`declaresServiceActivation` takes the activation frame and service role as two bare `Text`s. Admission checks
only that each field is non-empty, so a swapped release and namespace, or a swapped activation frame and
service role, validates and is sealed into the canonical plan. § HH makes each role a type.

#### Deliverables

- `HostBootstrap.Step` defines one newtype per role: `ChartArtifactDigest`, `ChartRelease`, `ChartNamespace`,
  `ChartValuesDigest`, `ImageIdentity`, `WorkloadKey`, `WorkloadDigest`, `ActivationFrame`, and `ServiceRole`.
  It reuses any newtype the tree already defines for the same role.
- `ChartWorkloadDeclaration` is a named record of those types plus the effect list. Its constructor is private
  and its smart producer refuses an empty field. `declaresChartWorkloadResource` takes the record, and
  `stepChartWorkloadResourceDeclarations` returns records, not tuples.
- `declaresServiceActivation` takes `ActivationFrame` and `ServiceRole`.
- `Lifecycle.Plan` validates and encodes the record. The canonical plan bytes are unchanged, so no plan format
  version moves. The demo's `declaredChartStep` builds the record.

#### Validation

Under `cabal test all` from `core/` and `cabal test hostbootstrap-demo-test` from `demo/`:

- a compile-fail fixture `test/compile-fail/SwapChartDeclarationRoles.hs`, registered in `CompileFailSpec`,
  that passes a `ChartNamespace` where `ChartRelease` is expected and is rejected with `Couldn't match type`;
- a `ProjectPlanSpec` golden case that the canonical plan bytes of the existing chart fixture are unchanged;
- `StepSpec` refusal cases for an empty field through the smart producer.

Then the core and demo host-static gates.

#### Remaining Work

- Add the role newtypes, the record, and its producer. Change the two declaration functions, the plan
  validation and encoding, and `declaredChartStep`. Add the fixture and the cases above.

### Sprint 24.62: The prepared chart workload carries role types to the wire [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/test/ClusterWorkloadSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Cluster.Workload`, `HostBootstrap.Cluster.Backend`,
`HostBootstrap.Lifecycle.Dependency.Internal` (3; cap 3)
**Sprint budget**: no new named contract; at most 300 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Sealed `PreparedChartWorkload` retains artifact, release, namespace, values digest, image, workload key, role,
cluster key, and call digest as bare `Text`. Its mint and its eliminator `withPreparedChartWorkloadParts` pass
them positionally, and so do the `Cluster.Backend` consumer and `runtimeDependencyChartRequest`. A swap at any
of these stages compiles. The call digest also agrees with the swap, so no check catches it.

#### Deliverables

- `PreparedChartWorkload` holds the Sprint 24.61 role types for those coordinates, plus `ClusterKey` and
  `ChartCallDigest` newtypes.
- `withPreparedChartWorkloadParts` yields a record of those types rather than a positional lambda.
- `runtimeDependencyChartRequest` and the `Cluster.Backend` Helm transaction take the record. They unwrap a
  role only where it becomes a `helm` argument.

#### Validation

Under `cabal test all` from `core/`: a compile-fail fixture `test/compile-fail/SwapPreparedChartRoles.hs` that
passes the namespace field where the release is expected in the chart request is rejected, and the existing
`ClusterWorkloadSpec` install and cleanup cases pass unchanged. Then the core host-static gate.

#### Remaining Work

- Retype `PreparedChartWorkload`, its eliminator, the chart request renderer, and the backend consumer; add the
  fixture.

### Sprint 24.63: The execution package and carried resource carry role types [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Lifecycle.Execution.Internal`, `HostBootstrap.Reconcile`,
`HostBootstrap.Lifecycle.Plan` (3; cap 3)
**Sprint budget**: no new named contract; at most 300 production Haskell lines. If `HostBootstrap.Chain`'s
`mintSettledCarriedResource` call site needs more than an argument wrap, split it into its own sprint.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

`PlanExecutionPackage` and `mintPlanExecutionPackage` take five positional `Text`s: spec digest, plan digest,
config digest, node identity, and profile. `CarriedResource` and `mintSettledCarriedResource` take key,
generation, and version as `Text Word64 Word64`, and frame and operation as two adjacent `Text`s.
`executionNodeChartWorkload` is an 11-tuple. Transposing any pair compiles and binds execution authority or
carried ownership to the wrong coordinate.

#### Deliverables

- Role newtypes for the spec, plan, and config digests, the resource generation, the observation version, the
  frame, and the operation key replace those positional arguments and fields. Any role type the tree already
  defines is reused.
- `executionNodeChartWorkload` holds the Sprint 24.61 `ChartWorkloadDeclaration` record plus the cluster key,
  not an 11-tuple.

#### Validation

Under `cabal test all` from `core/`: a compile-fail fixture `test/compile-fail/SwapCarriedGenerationVersion.hs`
that passes an observation version where the generation is expected to `mintSettledCarriedResource` is rejected.
The existing `ReconcileSpec` carrier and package cases pass. Then the core host-static gate.

#### Remaining Work

- Introduce the role newtypes, retype the package, carrier, and chart field and their producers and consumers,
  and add the fixture.

### Sprint 24.64: The chart preparer requires the workload and partition binding [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload/Binding.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/BudgetSpec.hs`,
`core/hostbootstrap-core/test/ClusterWorkloadSpec.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrap.Cluster.Workload.Binding`, `HostBootstrap.Cluster.Workload`,
`HostBootstrapDemo.Commands` (3; cap 3)
**Sprint budget**: one new named contract, the `ChartWorkloadBinding` witness, and one demo call-site adoption;
at most 300 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/engineering/resource_budgeting.md`

#### Objective

Sprints 24.24 and 24.25a give the chart declaration a workload key and digest and a caller-free equality with
the generative `PlannedWorkloadSet` and `BudgetPartition`. Only `BudgetSpec` calls
`withMatchingChartWorkloadDeclaration`, `withPlannedWorkloadSet`, and `withBudgetPartition`. The production
preparer discards the declared workload digest, so a chart deploys whether or not its declaration matches any
planned workload. This sprint makes the binding a precondition of preparation.

#### Deliverables

- `withMatchingChartWorkloadDeclaration` yields an opaque `ChartWorkloadBinding scope planId chartId` witness on
  a match instead of bare `Text` fields.
- `withPreparedActivatedChartWorkload` requires that witness for its chart resource, so preparation cannot run
  without a matched workload set and partition.
- The demo's chart action derives its `PlannedWorkloadSet` and `BudgetPartition` from its admitted plan and the
  cordon's verified fit, and obtains the witness before preparation. `declaredChartStep` declares the key and
  digest those derivations produce (bare-hex SHA-256), not an fnv64 key and a `sha256:`-prefixed digest.

#### Validation

Under `cabal test all` from `core/` and `cabal test hostbootstrap-demo-test` from `demo/`:

- `BudgetSpec` asserts the witness is produced for the exact declaration and refused, with no continuation,
  for a drifted key or digest;
- `ClusterWorkloadSpec` prepares only with the witness;
- a compile-fail fixture `test/compile-fail/PrepareChartWithoutBinding.hs` that calls the preparer without
  the witness is rejected;
- `CommandsSpec` asserts that the demo's declared key and digest equal those derived from its configured
  workloads.

Then the core and demo host-static gates.

#### Remaining Work

- Add the witness, require it in the preparer, adopt it in the demo's chart action and declaration, and add the
  cases and the fixture above.

### Sprint 24.65: The demo's service handlers run on acquired listeners and the role durable path [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Web/Server.hs`,
`demo/src/HostBootstrapDemo/Accelerator/Daemon.hs`, `demo/test/WebServerSpec.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrapDemo.Web.Server`,
`HostBootstrapDemo.Accelerator.Daemon` (3; cap 3)
**Sprint budget**: no new named contract; at most 400 production Haskell lines. Split the accelerator role into
its own sprint if the estimate exceeds the cap.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/accelerator_daemon.md`, `documents/operations/demo_runbook.md`

#### Objective

The demo sets `type ListenApp DemoServicePayloads = IO ()` and its backend runs that IO unchecked
(`backendServe = fmap Right . mapM_ snd`). The declared listener is never acquired
(`serviceAcquireResource = const (pure Acquired)`). The web application binds both ports from config and
creates its durable root at the literal `/var/lib/hostbootstrap-demo-data/web`. The accelerator application
reads `HOSTBOOTSTRAP_ACCELERATOR_READY_FILE` and `HOSTBOOTSTRAP_ACCELERATOR_SHUTDOWN_FILE` and runs `detect`.
The declared effect rows therefore bound nothing in the only real consumer. This sprint narrows the demo onto
what the engine acquires. Sprint 24.51's `PublicPort` and `AcceleratorPort` role types come first.

#### Deliverables

- `ListenApp DemoServicePayloads` is a function of the listener socket that the service resource backend
  acquired for that resource. `serviceAcquireResource` binds the role's declared listeners, and `backendServe`
  hands each application the socket acquired under its resource name.
- `serveWebWithConfig` and `runLinkedListeners` serve on the given sockets and bind no port of their own.
- The web role's durable root is a `DurablePath` minted by `serviceDurablePath` under the role's durable root.
  `serveWebWithConfig` neither creates nor checks a directory, and the marker route reads and writes only
  children of that path.
- The accelerator role takes its readiness file, shutdown file, and substrate from its decoded role fields. It
  calls neither `lookupEnv` nor `detect`.
- The accelerator role's effect row is what it does: it binds no listener and dials the web service's
  accelerator ingress, so `demoServices`, `declaredInClusterAcceleratorStep`, and `declaredHostAcceleratorStep`
  declare `network-connect` and `process` in place of `network-listen` and `process`, and the role requests no
  `listener` resource.

#### Validation

Under `cabal test hostbootstrap-demo-test` from `demo/`:

- a `WebServerSpec` case binds an ephemeral socket, hands it to the web application, and gets `200` for `/` on
  that socket;
- a `WebServerSpec` case runs the marker route against a temporary `DurablePath` root and finds the marker under
  it;
- a `CommandsSpec` case with a counting fake resource backend asserts that `backendServe` runs each application
  once with the socket acquired for its resource name;
- a `CommandsSpec` case decodes accelerator role fields carrying the readiness and shutdown paths;
- a `CommandsSpec` case asserts that the accelerator's service definition and both accelerator activation
  declarations carry `network-connect` and `process`, no `network-listen`, and no `listener` resource request.

Then the demo host-static gate, and the live `10/10` matrix on the next acceptance run.

#### Remaining Work

- Retype `ListenApp`, acquire the listeners in the resource backend, move the web listeners and durable root
  onto the acquired socket and `DurablePath`, move the accelerator's environment and detection inputs into its
  role fields, and add the cases above.
- `Commands.hs`: declare the accelerator role as `WithEffect NetworkConnectName (WithEffect ProcessSpawnName
  NoEffects)` with no `listener` resource in `demoServices`, and as `[NetworkConnect, ProcessSpawn]` in
  `declaredInClusterAcceleratorStep` and `declaredHostAcceleratorStep`; correct the "binds a private listener"
  comment; add the effect-row case above.

### Sprint 24.66: The demo workspace carries the core build memory bound [Planned]

**Status**: Planned
**Implementation**: `demo/cabal.project`, `demo/test/CommandsSpec.hs`
**Production modules**: none
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cabal_layout.md`

#### Objective

`core/cabal.project` pins `jobs: 1` and `package * ghc-options: +RTS -M6144M -xr18432M -RTS`, on the stated
ground that the build configuration is the only place that bound can live. `demo/cabal.project` also compiles
`hostbootstrap-core` from local source, and it is a leg of the host static gate, but it carries neither
setting. A demo build therefore runs with Cabal's default parallel jobs and unbounded GHC heaps.

#### Deliverables

- `demo/cabal.project` carries the same `jobs: 1` and `package *` `ghc-options` RTS bound as
  `core/cabal.project`, with a comment pointing at the core rationale.

#### Validation

A demo test reads both `cabal.project` files and asserts that their `jobs:` line and their `package *`
`ghc-options` line are equal. It passes under `cabal test hostbootstrap-demo-test` from `demo/`, followed by
the demo host-static gate.

#### Remaining Work

- Add the two settings to `demo/cabal.project` and the equality case to the demo suite.

### Sprint 24.67: The demo cluster slice comes from the plan-indexed budget partition [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`, `demo/test/CommandsSpec.hs`,
`core/hostbootstrap-core/test/BudgetSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrap.Cluster.Budget` (2; cap 3)
**Sprint budget**: no new named contract and one demo call-site adoption; at most 300 production Haskell lines.
Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`, `documents/engineering/cluster_lifecycle.md`,
`documents/engineering/schema.md`

#### Objective

Development-plan standards § O fixes the budget chain: a plan-indexed `ValidatedBudget`, the provider's
`EffectiveBudget`, a `PlannedWorkloadSet` whose fit is verified, and a `BudgetPartition` that mints exact
frame-local slices before any wall or reconcile effect. The core suites exercise every kernel, but the demo's
cluster step (`deployKindAction`) mints its `ResourceSlice` with `withActionResourceSlice` from the planned
cluster and its config's cluster resources, so no production path runs the chain. This sprint puts the demo's
cluster slice behind it. Sprint 24.64's chart binding derives the same workload set and partition first.

#### Deliverables

- The demo's cluster step mints `ValidatedBudget` with `withValidatedBudget` from the exact plan its execution
  package was produced from and the config's resource envelope, admits the provider budget with
  `admitProviderBudget`, verifies the planned workloads with `verifyPlannedWorkloadFit`, and partitions with
  `withBudgetPartition`, sharing the `PlannedWorkloadSet` and `BudgetPartition` derivation Sprint 24.64 gives
  the chart action.
- `deployKindAction` takes its `ResourceSlice` from `withResourceSliceFor` over that partition. A workload set
  that does not fit, or a partition with no or duplicate slices for the planned cluster, refuses before any
  provider, cordon, or cluster effect.
- `withActionResourceSlice` has no caller and is deleted from `HostBootstrap.Cluster.Budget`.

#### Validation

Under `cabal test hostbootstrap-demo-test` from `demo/` and `cabal test all` from `core/`:

- a `CommandsSpec` case over the pure budget-admission step for the demo default resources yields a cluster
  slice whose CPU, memory, and storage equal the partition's cluster share;
- a `CommandsSpec` case whose planned workloads exceed the budget returns the `verifyPlannedWorkloadFit`
  `BudgetError` naming the exceeded resource, and the step runs no provider or cluster effect;
- a scoped `CommandsSpec` guard that `deployKindAction` names no `withActionResourceSlice`, and `BudgetSpec`
  passes with `withActionResourceSlice` deleted.

Then the core and demo host-static gates, and the live `10/10` matrix on the next acceptance run.

#### Remaining Work

- `Commands.hs` `deployKindAction`: replace `withActionResourceSlice plannedCluster sliceBudget` with the
  validated, admitted, fit-verified partition and `withResourceSliceFor plannedCluster`; factor the admission
  into a pure exported step and add the `CommandsSpec` cases above.
- `Cluster/Budget.hs`: delete `withActionResourceSlice` and its export once the demo no longer calls it, and
  move any `BudgetSpec` case that names it onto `withResourceSliceFor`.

### Sprint 24.68: The demo's WSL global wall settles through the provider wall reservation [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Windows.hs`, `demo/test/CommandsSpec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallWindowsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrap.Cluster.Budget`,
`HostBootstrap.Wsl2.GlobalWall.Windows` (3; cap 3)
**Sprint budget**: no new named contract and one demo call-site adoption; at most 400 production Haskell lines.
Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`, `documents/engineering/resource_budgeting.md`

#### Objective

The demo applies and restores the WSL2 global wall by calling `applyCurrentUserGlobalWall` and
`restoreCurrentUserGlobalWall` of `HostBootstrap.Wsl2.GlobalWall.Windows` directly. The typed chain that
§ O and the WSL2 resource-wall contract name (`withProviderWallReservation`, the settlement permit,
`settleProviderWallCall`, and the `ProviderWallAuthority` and `WslGlobalWallLease` it yields) has no WSL
production caller. This sprint routes the demo's wall through that chain, over the partition Sprint 24.67
derives.

#### Deliverables

- The demo's WSL2 wall acquisition reserves the wall with `withProviderWallReservation` from the exact plan,
  provider resource, provider wall spec, partition, and prepared gate, and applies it only through
  `settleProviderWallCall`, whose `LiveWslProviderWall` carries the `ProviderWallAuthority` and
  `WslGlobalWallLease`.
- The wall release consumes that lease; the demo calls neither `applyCurrentUserGlobalWall` nor
  `restoreCurrentUserGlobalWall` directly.
- A reservation for another plan, provider, or partition refuses before the `.wslconfig` file is touched.

#### Validation

Under `cabal test hostbootstrap-demo-test` from `demo/` and `cabal test all` from `core/`: a `CommandsSpec`
scoped guard that `HostBootstrapDemo.Commands` names neither `applyCurrentUserGlobalWall` nor
`restoreCurrentUserGlobalWall`; a `WslGlobalWallWindowsSpec` case driving the reservation-to-settlement path
over a temporary wall location, asserting the applied record carries the reservation's fence; and a case where
a mismatched reservation returns the settlement refusal and leaves the location's bytes unchanged. Then both
host-static gates. The live wall on Windows is confirmed by the Windows and WSL2 acceptance on its own hardware.

#### Remaining Work

- `Commands.hs` (near 4432 and 4456): replace the direct `applyCurrentUserGlobalWall` and
  `restoreCurrentUserGlobalWall` calls with the reservation, settlement permit, and `settleProviderWallCall`
  path, and release through the resulting lease; add the guard above.
- `Wsl2/GlobalWall/Windows.hs` and `Cluster/Budget.hs`: expose the wall apply and restore to the settlement
  path only, and add the two `WslGlobalWallWindowsSpec` cases above.

### Sprint 24.69: Demo cluster consumers take profile, cluster, and durable paths from the exact plan [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Config.hs`,
`demo/src/HostBootstrapDemo/ClusterConfig.hs`, `demo/test/CommandsSpec.hs`, `demo/test/ClusterConfigSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrapDemo.Config`,
`HostBootstrapDemo.ClusterConfig` (3; cap 3)
**Sprint budget**: no new named contract; at most 400 production Haskell lines. Split by consumer group
(forward cluster consumers; teardown and mount consumers) if the estimate exceeds the cap.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`, `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/harness_workflow.md`, `documents/architecture/build_and_run_model.md`

#### Objective

Every cluster name, path, and profile a demo consumer uses is a projection of the exact `ProjectPlan` the
command retained, so no independent argument can disagree with it. Today `containerPlan` takes a
`ClusterProfile` its call sites compute as `clusterProfileOf` of the config, together with the context's
source root; `deployKindAction`, the chart, mount, and teardown consumers reread `RunProfile`/`ClusterProfile`
and the filesystem root the same way; and the guest alias, Kind-node, and pod durable paths
(`/var/tmp/hostbootstrap-demo-data`, `/var/lib/hostbootstrap-demo-data`) are fixed demo constants.

#### Deliverables

- One plan projection returns the cluster profile, cluster plan, canonical host durable root, guest alias
  target, and in-node durable path for the executing scope; `containerPlan` takes that projection, not a
  `ClusterProfile` argument.
- `deployKindAction`, the chart activation root, the Direct cluster plan, the durable-share mount, and the
  teardown consumers read the profile and paths from that projection; no consumer calls `clusterProfileOf`.
- The guest alias path, the Kind `extraMounts` `containerPath`, and the chart's durable `hostPath` values are
  rendered from the projection's in-node path, so changing it changes every rendering together.
- A projection requested for a scope other than the retained plan's refuses before any effect.

#### Validation

Under `cabal test hostbootstrap-demo-test` from `demo/`: `CommandsSpec` cases that the projection for a
Production plan and for a Harness plan yields the expected profile, cluster name, and durable paths, and that
`containerPlan` of the projection names the same cluster as the plan; a `ClusterConfigSpec` case that the
rendered `containerPath` equals the projection's in-node path; and a scoped guard that no consumer outside the
projection calls `clusterProfileOf`. Then the demo host-static gate and the live `10/10` matrix on the next
acceptance run.

#### Remaining Work

- Add the plan projection and change `containerPlan` to take it; move every `clusterProfileOf` call site in
  `Commands.hs` onto it, then make `clusterProfileOf` private to the projection.
- Render the guest alias, Kind `containerPath`, and chart durable paths from the projection's in-node path
  instead of the `durableDockerHostPath` and `/var/lib/hostbootstrap-demo-data` literals.
- Add the `CommandsSpec` and `ClusterConfigSpec` cases above.

### Sprint 24.70: The demo's image build and push consume plan-indexed readiness [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: no new named contract; at most 400 production Haskell lines. Split by step (image build;
push) if the estimate exceeds the cap.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Development-plan standards § CC mint `Ready` only through the polling transition over a plan-registered
probe. The demo sequences its in-VM project-image build (`buildProjectImage`) and image push behind
non-authorizing `ObservedReady DockerDaemon` and `ObservedReady RegistryServing`. This sprint moves those two
steps onto plan-indexed readiness. The guest alias is outside this sprint: `runExactVmShare` already runs the
durable-share mount probe (`awaitDurableShareMounted`) as the share probe `reconcileNodeGuestAlias` consumes,
and the WSL2-only compatibility alias step (`reconcileShippedDurableAlias`) is deleted, not retyped, by
[the Windows and WSL2 acceptance phase](phase-28-windows-and-wsl2-substrate.md).

#### Deliverables

- The Docker-daemon and registry-serving probes are registered in each step's plan dependency snapshot
  (`planDependencyProbe`), and their readiness is minted by `awaitPlanReady` or `awaitPlanReadyWith`.
- `buildProjectImage` and the image push require the plan-indexed `Ready` witness, so neither can run against
  an observation made for another plan or step.
- The demo-local `DockerDaemon` and `RegistryServing` tags serve only those plan probes, and no
  `ObservedReady` value gates either step.

#### Validation

Under `cabal test hostbootstrap-demo-test` from `demo/`: `CommandsSpec` cases that each of the two steps'
probes is registered in its plan dependency snapshot, and a scoped guard that `buildProjectImage` and the push
step take no `ObservedReady` argument. Then the demo host-static gate and
the live `10/10` matrix on the next acceptance run.

#### Remaining Work

- Register the two probes through `planDependencyProbe`, mint their readiness through `awaitPlanReady`, and
  retype `buildProjectImage` and the push step to take the plan-indexed witness; add the cases above.

### Sprint 24.71: The Direct lane releases its cluster through the authenticated reverse child [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/app/Main.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `Main` (2; cap 3)
**Sprint budget**: no new named contract; at most 200 production Haskell lines, most of them deletions.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/engineering/authoring_project_binaries.md`, `documents/operations/demo_runbook.md`

#### Objective

Development-plan standards § P: a project adds no command, and the one internal marker a binary recognizes
before its parser is core's; a second is a per-project verb. The demo's `main` intercepts
`--hostbootstrap-direct-cluster-release-v1 PROFILE` before `runHostBootstrapCLI` and routes it to
`runDirectClusterReleaseChild`, because the Direct lane's `deploy-kind` node declares its own reverse
(`demoDirectClusterReverseAt`) that re-enters the project image with that marker. The authenticated reverse
child already releases a callback-free core-managed cluster in its own frame (Sprint 24.40). This sprint makes
the Direct lane use it and deletes the demo's entry.

#### Deliverables

- The Direct lane's `deploy-kind` node declares no reverse of its own, so `project down`, `project destroy`,
  and the Harness reverse release its exposure and retained nvkind cluster through `runCoreManagedReverse` in
  the authenticated Direct container frame.
- The Direct Harness data-root permission restoration runs as a reverse step inside that frame after the
  cluster release.
- `Main` passes every argv to `runHostBootstrapCLI`; `runDirectClusterReleaseChild`,
  `demoDirectClusterReverseAt`, `directClusterReleaseArgs`, and `clusterProfileArgument` are deleted.

#### Validation

Under `cabal test hostbootstrap-demo-test` from `demo/`: a `CommandsSpec` case that the Direct `deploy-kind`
step declares no `reversedBy`, a scoped guard that `demo/` names no `--hostbootstrap-direct-cluster-release-v1`,
and the updated pinned `Main` installation hash. Then the demo host-static gate. The live Direct reverse is
confirmed on the Direct lane's own hardware by the NVIDIA acceptance.

#### Remaining Work

- `Commands.hs`: drop the Direct `deploy-kind` node's `reversedBy`, move the Harness permission restoration
  into a Direct-frame reverse step, and delete `demoDirectClusterReverseAt`, `directClusterReleaseArgs`,
  `clusterProfileArgument`, and `runDirectClusterReleaseChild` with their exports.
- `demo/app/Main.hs`: delete the marker match and its refusal arm, and update the pinned installation hash.
- Add the `CommandsSpec` cases above.

### Sprint 24.72: The demo's registry proof observes the registry it names [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: no new named contract; at most 300 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`,
`documents/engineering/in_cluster_registry.md`

#### Objective

The demo's blob-route observation records runtime facts only in its status and in whether a `Location` was
issued: `parseBlobRouteAnswer` copies the service, port, runtime identity, and revision from the plan and
assigns any `Location` the store's scope by assumption. The live gate never pulls the pushed image back through
the resolved registry exposure, before or after a registry pod restart, and has no repeated-push case. This
sprint makes the observation and the persistence proof observe the registry they name. Sprint 24.52's argv
rewrite of `assertRegistrySurvivesRestart` comes first.

#### Deliverables

- `parseBlobRouteAnswer` takes the service, port, and runtime identity from the resolved exposure the probe
  dialled, not from the plan, and derives a redirect's scope from the observed `Location` authority, refusing
  a `Location` whose authority is not `endpointAuthority (registryPlanStore plan)`.
- The registry-persistence case pulls the pushed image by digest through the resolved registry exposure before
  and after the registry pod restart and compares the pulled digest with the pushed one.
- A repeated push of the same image settles without a new upload and leaves one tag pointing at the same
  digest.

#### Validation

Under `cabal test hostbootstrap-demo-test` from `demo/`: `CommandsSpec` cases that `parseBlobRouteAnswer`
refuses a `Location` with a foreign authority, admits one at the store authority with the store's scope, and
copies identity from the given exposure; and argv cases for the pull-by-digest assertion before and after the
restart. Then the demo host-static gate, and the live `10/10` matrix on the next acceptance run showing the
pulled digests equal to the pushed one.

#### Remaining Work

- Rewrite `parseBlobRouteAnswer` to take the dialled exposure and to observe the redirect scope from the
  `Location` authority; add its cases.
- Extend `assertRegistrySurvivesRestart` with a pull by digest through the resolved exposure on both sides of
  the restart, and add a repeated-push case to the persistence assertion; add their argv cases.

### Sprint 24.73: The demo's leaf service and daemon configs carry the leaf's own slice [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Config.hs`,
`demo/test/ConfigSpec.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrapDemo.Config` (2; cap 3)
**Sprint budget**: no new named contract; at most 200 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/dhall_topology.md`, `documents/engineering/config_generation.md`

#### Objective

The leaf `<project>.dhall` the demo delivers to a service pod (the chart's `serviceConfig` value) and to the
accelerator daemon (`acceleratorDaemonManifest`) is the full demo `ProjectConfig` with an adjusted context: it
carries the parent's raw resource envelope, host Dockerfile, and deploy section, and not the cluster slice the
plan computed for that leaf. `service run` authority does not depend on that file, because it decodes only the
narrowed role wire. This sprint makes the delivered leaf carry its own slice and states, in the one projection
that builds it, which parent fields a leaf keeps.

#### Deliverables

- `projectConfigForServiceContext` and the daemon projection set the leaf's `resources` to the slice Sprint
  24.67's partition gives that leaf, not the parent's envelope.
- That projection is the one place that decides which parent fields a leaf keeps; its Haddock lists them and
  states that `service run` authority comes only from the narrowed role wire.

#### Validation

Under `cabal test hostbootstrap-demo-test` from `demo/`: a `ConfigSpec` case that the rendered service and
daemon leaf configs carry the partition's slice for their leaf, extending "child projections preserve project
settings and narrow authority"; and a `CommandsSpec` case that the chart's `serviceConfig` value and the
daemon manifest carry those rendered bytes. Then the demo host-static gate.

#### Remaining Work

- Set the leaf `resources` from the partition slice in both projections, write the projection Haddock, and add
  the two cases above.

### Sprint 24.74: Installed signing seeds are pair-checked, durable, and owner-only [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Identity/Install.hs`,
`core/hostbootstrap-core/test/IdentityInstallSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

`HostBootstrap.Identity.Install` is the private installation entry Sprint 24.26 has the thin builder invoke
after copying a stable project binary; it installs or validates the handoff, build, and activation identities.
`validateInstalledIdentity` is the identity gate before every non-dry-run `project up`. Its key-pair refusals
stop an operator from running with a public half that does not belong to the retained secret. The handoff,
build, and activation seeds are readable by the owner alone on every host, survive a crash once published, and a
publication that fails reports its own cause; a retained seed with wider access is refused rather than kept.

#### Deliverables

- `validateInstalledIdentity` refuses: a handoff pair mismatch ("installed handoff key pair does not match at
  <path>.handoff.pub"); an activation pair mismatch; and an unreadable or malformed `.handoff.key`,
  `.handoff.pub`, `.activation.key`, or `.activation.pub`. It writes nothing.
- `provisionInstalledIdentity` refuses a malformed retained `.build.key` and a malformed retained
  `.activation.key` with "invalid installed key at <path>".
- `publishNoReplace` catches only synchronous `IOException`s from `linkNoReplace`, so an asynchronous exception
  (`UserInterrupt`, `ThreadKilled`) aborts the install. When the link fails and the destination is still absent,
  `ensureSecret`, `ensurePublic`, and `ensureActivationPublic` return a `Left` carrying the link error rather
  than a later "failed to read ... does not exist".
- The temporary is fsynced before it is linked and its directory is fsynced after (`FlushFileBuffers` on
  Windows), so a crash cannot leave a published, empty or truncated key.
- On POSIX, each new secret is published with mode 0600, set explicitly rather than inherited from the temporary
  file's default. On Windows, each new secret receives an explicit protected owner-only DACL with no inherited
  entries.
- The secret loaders refuse a retained seed whose POSIX mode grants any group or other bit
  (`mode .&. 0o077 /= 0`), or whose Windows DACL grants access to any principal other than the owner, SYSTEM,
  and Administrators.

#### Validation

The host static gate (`cabal test all` from `core/`) on every host. `IdentityInstallSpec` gains these cases.
After provisioning, `validateInstalledIdentity` is called directly with `.handoff.pub` overwritten by another
valid key, then with `.activation.pub` overwritten the same way, and each case asserts its exact mismatch
message. Each of the four handoff/activation files is truncated and then deleted, with the exact message
asserted each time. "read-only validation refuses a missing build identity" also asserts that `.build.key` is
still absent afterwards, and "refuses a mismatched retained handoff pair" uses the needle "handoff key pair does
not match". A malformed `.build.key` and a malformed `.activation.key` are presented to
`provisionInstalledIdentity`. A case drives the publication path with a link step that throws an
`IOException` (the link action is a parameter of the module-internal publisher, supplied by the test through
the module's test export) and asserts the `Left` carries that error's text and the destination is absent. On
POSIX, `fileMode .&. 0o077 == 0` is asserted for all three secrets after provisioning, and a retained seed
chmod-ed to 0644 is refused. On Windows, the provisioned secrets' DACL is asserted owner-only, and a retained
seed whose DACL grants Authenticated Users read is refused.

#### Remaining Work

- Narrow `publishNoReplace`'s catch to `IOException` and surface the link error from the three `ensure*`
  helpers; fsync the temporary and its directory around the link.
- Implement the explicit POSIX mode and Windows DACL on publication, plus the retained-seed permission refusal
  in the loaders.
- Add the direct `validateInstalledIdentity` mismatch, unreadable/malformed, and no-write cases, the tightened
  handoff-mismatch needle, the malformed build/activation seed cases, the link-failure case, and the permission
  cases above.

### Sprint 24.75: Harness scope spellings are one projection pair [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child/Reverse.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Production modules**: `HostBootstrap.Handoff`, `HostBootstrap.Command.Child.Reverse`,
`HostBootstrap.Teardown.Internal` (3; cap 3)
**Sprint budget**: two pure functions replacing two private ones and no new behaviour; at most 60 production
Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`

#### Objective

The signed handoff spelling of a lifecycle scope (`Production`, `Harness <run>`) and the stable mode spelling
(`production`, `harness:<run>`) convert through one exposed, unit-tested pair, so the reverse child and the
recovery binding check cannot drift apart.

#### Deliverables

- `HostBootstrap.Handoff` exports `stableScopeFromHandoffScope :: Text -> Either Text Text`, mapping
  `Production` to `production` and `Harness <run>` with a non-empty run to `harness:<run>`, and refusing any
  other text with "reverse child: the authenticated handoff carries an unknown lifecycle scope".
- It exports `handoffScopeFromStableScope :: Text -> Text`, the inverse on those two shapes, returning any
  other text unchanged.
- `recoveryProfileName` in `HostBootstrap.Command.Child.Reverse` is `stableScopeFromHandoffScope` over the
  binding's `handoffScope`, and the "the recovery offer scope differs" check in `validateOffer` in
  `HostBootstrap.Teardown.Internal` compares through `handoffScopeFromStableScope`; neither module keeps its
  own spelling arms.

#### Validation

The `HandoffSpec` cases named in Remaining Work exist and pass, the existing `TeardownSpec` and `HandoffSpec`
source guards are retargeted to the shared names, and `cabal test all` from `core/` passes.

#### Remaining Work

- Add the pair to `HostBootstrap.Handoff`, delete the local arms of `recoveryProfileName` and the
  `recoveryHandoffScope` helper, and retarget the `TeardownSpec` guard that matches
  `handoffScope binding == recoveryHandoffScope` and the `HandoffSpec` guard that names
  `recoveryProfileName binding` to the new call sites. Tests in `HandoffSpec`:
  `stableScopeFromHandoffScope "Production" @?= Right "production"`;
  `stableScopeFromHandoffScope "Harness run-1" @?= Right "harness:run-1"`; `"Harness "` and `"Staging x"` each
  return `Left "reverse child: the authenticated handoff carries an unknown lifecycle scope"`;
  `handoffScopeFromStableScope "harness:run-1" @?= "Harness run-1"`; and for both valid handoff spellings,
  `handoffScopeFromStableScope <$> stableScopeFromHandoffScope s @?= Right s`.

### Sprint 24.76: The accelerator ingress is published only on a lane that runs a daemon [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Config.hs`, `demo/src/HostBootstrapDemo/ClusterConfig.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/ClusterConfigSpec.hs`, `demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/accelerator_daemon.md`, `documents/operations/demo_runbook.md`

#### Objective

`acceleratorPlacementForContext` in `Config.hs` derives the accelerator placement from the binary context
alone and returns `HostResidentDaemon` for every context that is neither the explicit Linux GPU container nor
beneath an Incus VM. A `windows-cpu` WSL2 context therefore selects `HostResidentDaemon` although its chain
carries no accelerator step and `acceleratorBackendForSubstrate` refuses the substrate: `exposureIntents` in
`ClusterConfig.hs` keeps the `accelerator` intent for `(KindDriver, HostResidentDaemon)`, the chart values
render the host-daemon `NodePort` accelerator Service, and the relay publishes a loopback accelerator listener
that nothing serves. This sprint makes the placement follow the lane, so a lane without an accelerator daemon
publishes no accelerator ingress.

#### Deliverables

- `acceleratorPlacementForContext` takes the lane's `Substrate` with the context and returns
  `Maybe AcceleratorDaemonPlacement`: `Nothing` exactly when `acceleratorBackendForSubstrate` refuses the
  substrate (`windows-cpu`), and otherwise `Just` the placement the context selects.
- `exposureIntents` keeps the `accelerator` intent only for `KindDriver` with `Just HostResidentDaemon`;
  `renderExactClusterConfig` and `verifyExactClusterConfig` receive the placement rather than recomputing it.
- `acceleratorHelmValuesForContext` and the rendered chart values give a lane with no daemon a `ClusterIP`
  accelerator Service with no `nodePort`, so no host-reachable accelerator port exists on that lane.
- The placement call sites in `Commands.hs` take the substrate from the resolved host configuration
  (`hcSubstrate`); none recomputes the placement from the context alone.

#### Validation

The sprint closes when these cases exist and pass under `cabal test hostbootstrap-demo-test` from `demo/`,
with the demo host-static gate:

- `ClusterConfigSpec`: a `windows-cpu` Kind render carries no `accelerator` exposure intent, an Apple Silicon
  and a `windows-gpu` Kind render each carry it, and the Incus `linux-cpu` render carries none.
- `CommandsSpec`: the `windows-cpu` chart values set `service.accelerator.type` to `ClusterIP` and carry no
  `service.accelerator.nodePort`, while the `windows-gpu` values keep `NodePort` 30081; the existing
  "windows-cpu has no accelerator worker or host-daemon hook" case still passes.

#### Remaining Work

- Change `acceleratorPlacementForContext` in `Config.hs` to take the `Substrate` and return
  `Maybe AcceleratorDaemonPlacement`, thread the placement through `exposureIntents`,
  `renderExactClusterConfig`, and `verifyExactClusterConfig` in `ClusterConfig.hs` and through the chart-value
  call sites in `Commands.hs`, and add the `ClusterConfigSpec` and `CommandsSpec` cases named in Validation.

### Sprint 24.77: The retained cluster release takes the retained-cluster projection [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child/Reverse.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`
**Production modules**: `HostBootstrap.Cluster.Backend`, `HostBootstrap.Command`,
`HostBootstrap.Command.Child.Reverse` (3; cap 3)
**Sprint budget**: no new named contract; at most 60 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`, `documents/architecture/durable_state.md`

#### Objective

`releaseRetainedCluster :: HostConfig -> ClusterPlan -> IO (Either ReconcileError ())` in `Cluster/Backend.hs`
receives the whole `ClusterPlan`, including its `dataPath` durable root, although the cluster lifecycle phase
gives its body a retained-cluster projection that carries only the cluster name, the declared node names, the
state directory, and the kubeconfig path. This sprint narrows the exported signature to that projection, so no
cluster release receives a durable root. Its callers are `releaseRetainedClusterLifecycle` in `Command.hs` and
`runCoreManagedReverse` in `Command/Child/Reverse.hs`; it follows Sprint 24.71, which deletes the demo's own
caller, `runDirectClusterReleaseChild`.

#### Deliverables

- `releaseRetainedCluster` takes the typed `HostConfig` and the retained-cluster projection from
  `Cluster/Lifecycle.hs`, and nothing else: no `ClusterPlan` and no durable root.
- `releaseRetainedClusterLifecycle` in `Command.hs` and `runCoreManagedReverse` in `Command/Child/Reverse.hs`
  build the projection from their `ClusterPlan` at the call site.

#### Validation

The sprint closes when the existing `ClusterBackendSpec` retained-reverse and relay-first cases pass against
the projection signature, a `ClusterBackendSpec` source guard asserts that `releaseRetainedCluster`'s signature
in `Cluster/Backend.hs` names no `ClusterPlan`, and `cabal test all` passes from `core/` and from `demo/`.

#### Remaining Work

- Change `releaseRetainedCluster` in `Cluster/Backend.hs` to take the retained-cluster projection, build it
  from the `ClusterPlan` in `releaseRetainedClusterLifecycle` in `Command.hs` and in `runCoreManagedReverse`
  in `Command/Child/Reverse.hs`, rewrite the `ClusterBackendSpec` retained-reverse calls over it, and add the
  signature source guard named in Validation.

### Sprint 24.78: The Windows host daemon runs through the sealed detached launch [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Detached.hs`,
`core/hostbootstrap-core/test/DetachedSpec.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrap.Detached`, `HostBootstrapDemo.Commands` (2; cap 3)
**Sprint budget**: one new named contract (the Windows branch of the sealed detached launch, with pid-addressed
identity and termination); at most 400 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/accelerator_daemon.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

The Windows host accelerator daemon is launched, probed, and stopped with no PowerShell text. Today it runs
through `hostAcceleratorDaemonPowerShellScript` (a hidden `Start-Process` script), a `Stop-Process` expression,
and a `Get-CimInstance` script. The reason is that `process` honours `close_fds` on Windows only when all three
streams are inherited, so `withDetachedChild` cannot launch a Windows child that drops the launcher's captured
`project up` pipe. This sprint gives `HostBootstrap.Detached` a Windows branch that uses the platform binding the
interpreter-text rule asks for. With that branch, the Windows lane takes the same sealed launch as the POSIX lane,
and the identity probe and forced stop are typed operations of the same module.

#### Deliverables

- On Windows, `withDetachedChild` spawns through `CreateProcessW`. Its `STARTUPINFOEXW` carries a
  `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` that names only the null-device standard input and the sink handle, with
  `bInheritHandles = TRUE` and the flags `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP |
  CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT`. The command line comes from `process`'s own
  `System.Process.Internals.translate` over the executable and arguments, so no quoter is added. The returned
  handle is wrapped by `System.Process.Internals.mkProcessHandle`, so `detachedChildPid`,
  `awaitDetachedChild`, and `terminateDetachedChild` serve both platforms. The POSIX branch is unchanged.
- `HostBootstrap.Detached` exports `DetachedProcessIdentity` (`dpiExecutable :: FilePath`,
  `dpiCommandLine :: String`) and `detachedProcessIdentity :: Int -> IO (Either String (Maybe
  DetachedProcessIdentity))`. On Windows the probe calls `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`,
  `GetExitCodeProcess`, `QueryFullProcessImageNameW`, and `NtQueryInformationProcess` with
  `ProcessCommandLineInformation`. A pid that `OpenProcess` refuses with `ERROR_INVALID_PARAMETER`, or a process
  whose exit code is not `STILL_ACTIVE`, yields `Right Nothing`.
- `HostBootstrap.Detached` exports `terminateDetachedPid :: Int -> IO (Either String ())`. On Windows it calls
  `OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE)` and `TerminateProcess`, then waits at most 5 seconds with
  `WaitForSingleObject`. A pid with no running process yields `Right ()`. On POSIX both new operations return a
  `Left` naming the platform, and the demo's POSIX lane keeps its `Ps` and `Kill` argument vectors.
- The module Haddock and `detachedProcess`'s Haddock state the Windows branch and the pid-addressed identity
  and termination, and name no separate Windows host-daemon launch.
- The demo's Windows lane launches with `hostAcceleratorDaemonLaunch` and `withDetachedChild`, as the POSIX lane
  does. Its output therefore reaches the retained sink that `finishTracked` quotes, and Haskell writes its pid
  file through the POSIX lane's path. `startWindowsHostAcceleratorDaemon`, `hostAcceleratorDaemonPowerShellScript`
  and its export, and the demo's `powerShellQuoteArg` import do not exist.
- On Windows the stop calls `terminateDetachedPid`, and `hostDaemonProcessRunning` calls
  `detachedProcessIdentity`. `hostDaemonIdentityMatches` splits into a POSIX matcher over the `ps` output and
  `hostDaemonIdentityMatchesWindows :: FilePath -> DetachedProcessIdentity -> Bool`. The Windows matcher compares
  the normalised, case-insensitive executable path, and the command line through the existing four-spelling rule
  over `hostAcceleratorDaemonArgs`. `Commands.hs` does not import the `PowerShell` `HostTool` constructor.

#### Validation

The sprint closes when these cases exist and pass under `cabal test all` from `core/` and
`cabal test hostbootstrap-demo-test` from `demo/`, on the linux-cpu host-static gate and on the native
Windows host-static gate, which runs the Windows branch:

- `DetachedSpec` "a detached child inherits no launcher handle". The test opens a pipe whose write end is
  inheritable (on Windows a `SECURITY_ATTRIBUTES` with `bInheritHandle = TRUE`, on POSIX an fd without
  `FD_CLOEXEC`) and launches the linger child. After the test closes its own write end, the read end reaches
  EOF within 5 seconds while the child's sink keeps growing.
- `DetachedSpec` "a detached child's identity names its executable and arguments, and a terminated pid has
  none". On Windows, `detachedProcessIdentity` of the linger child's pid is `Right (Just i)`. Its
  `dpiExecutable` equals the launch executable under case-insensitive normalisation, and its `dpiCommandLine`
  contains every launch argument. After `terminateDetachedPid` returns `Right ()`, the probe returns
  `Right Nothing`. On POSIX both operations return `Left`.
- `CommandsSpec` "host daemon teardown requires executable identity before a forced stop" splits by platform.
  Its Windows rows, rewritten over `DetachedProcessIdentity` for `hostDaemonIdentityMatchesWindows`, are:
  matching executable and command line in both the upper-case and the per-argument-quoted spellings gives
  `True`; a `project up` command line gives `False`; `notepad.exe` gives `False`; the impostor executable
  `C:\other\impostor.exe` with a matching command line gives `False`.

The Windows acceptance phase confirms the live launch, readiness, and stop on its own hardware.

#### Remaining Work

- `Detached.hs`: add the Windows `CreateProcessW` branch of `withDetachedChild` with the handle list above.
  Add `DetachedProcessIdentity`, `detachedProcessIdentity`, and `terminateDetachedPid`, and rewrite the two
  Haddocks. Add the two `DetachedSpec` cases above.
- `Commands.hs`: route the Windows lane through `hostAcceleratorDaemonLaunch` and `withDetachedChild`. Replace the
  `Stop-Process` and `Get-CimInstance` calls with `terminateDetachedPid` and `detachedProcessIdentity`, and split
  `hostDaemonIdentityMatches` as above. Delete `startWindowsHostAcceleratorDaemon`,
  `hostAcceleratorDaemonPowerShellScript` and its export (the `Commands.hs` export list and the `CommandsSpec`
  import), the `PowerShell` import, and the `powerShellQuoteArg` import.
- `CommandsSpec.hs`: delete "the Windows host daemon launches hidden and tracks its pid" and the case Sprint 24.43
  adds that the Windows launch script carries each element of `hostAcceleratorDaemonArgs` quoted by
  `powerShellQuoteArg`. Rewrite the Windows identity rows (including the two Sprint 24.43 adds) over
  `DetachedProcessIdentity`. A one-line-output row cannot be represented and is dropped.

### Sprint 24.79: The demo module hands no interpreter an argument vector, and core carries no PowerShell quoter [Planned]

**Status**: Planned
**Implementation**: `demo/test/CommandsSpec.hs`,
`core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/Quote.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Effect.hs`, `core/hostbootstrap-core/test/EffectSpec.hs`
**Production modules**: `HostBootstrap.Effect`, `HostBootstrap.Effect.Quote` (2; cap 3)
**Sprint budget**: no new named contract; deletions only in production Haskell.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

This sprint closes after Sprints 24.52, 24.53, and 24.78 have rewritten every interpreter call site in
`HostBootstrapDemo.Commands`, and after Sprint 3.8 removes `HostBootstrap.Effect.Interpreter`'s PowerShell
reframing of `wsl.exe`. It lands the whole-module guard that keeps interpreter argument vectors out of the demo
module, and it deletes the core PowerShell quoter, which by then has no consumer.

The guard reads `src/HostBootstrapDemo/Commands.hs` with comments removed and splits it into Haskell lexemes,
each string literal one token (the rule core's `SourceGuard.haskellTokens` applies, through Prelude `lex`). It
fails on two kinds of token:

- a string literal whose whole content is one of `bash`, `/bin/bash`, `sh`, `/bin/sh`, `-lc`, `-ec`,
  `-Command`, `-EncodedCommand`, `powershell`, `powershell.exe`, or `pwsh`;
- the identifier `PowerShell` or `demoGuestShellArgs`.

Because matching is whole-token, an interpreter word inside a larger literal does not match. That scoping is
deliberate. `acceleratorDaemonManifest`'s `command: ["/bin/sh", "-c"]` line and its `kubectl get pod`
restart-count `args` are lines of a Kubernetes manifest literal, which the project container's own `/bin/sh` runs.
They mirror the container `command` in `demo/chart/templates/deployment.yaml`, through which Sprint 24.37 reads
the restart count. They are not an argument vector the demo hands the runner, the lift, or a guest route, and
this guard does not cover them. The guard's claim is limited to argument vectors.

#### Deliverables

- `CommandsSpec` carries the pure predicate `interpreterArgvTokens :: String -> [String]`, which returns the
  matched tokens of the rule above, and a whole-file case requiring `interpreterArgvTokens` of `Commands.hs` to be
  `[]`.
- `powerShellQuoteArg` is deleted from `HostBootstrap.Effect.Quote` (its definition and export), and from
  `HostBootstrap.Effect`'s re-export (Effect.hs export list) and import (the `HostBootstrap.Effect.Quote`
  import line).
- `EffectSpec` lists `powerShellQuoteArg` in `retiredQuoterSpellings`. The case "the PowerShell quoter has
  exactly one definition site" and the per-character `powerShellQuoteArg` cases that Sprint 3.6 adds are deleted.
  The PowerShell-quoter guard that Sprint 24.43 widens drops its `Quote.hs` exemption.

#### Validation

The sprint closes when these cases exist and pass in `cabal test hostbootstrap-demo-test` from `demo/` and
`cabal test all` from `core/`, followed by the host-static gate:

- `interpreterArgvTokens` reports `bash` and `-lc` for the fixture `RawCmd "bash" ["-lc", "x"]`, and reports
  `PowerShell` and `-Command` for `runTool cfg PowerShell ["-NoProfile", "-Command", "Stop-Process"]`.
- `interpreterArgvTokens` reports nothing for the manifest fixture
  `"          command: [\"/bin/sh\", \"-c\"]"` or for the comment `-- RawCmd "bash" ["-lc", "x"]`.
- The whole-file case over `Commands.hs` reports nothing.
- `EffectSpec` "no module carries a quoter of its own" passes with `powerShellQuoteArg` in
  `retiredQuoterSpellings`, and "the PowerShell quoter has exactly one definition site" does not exist.

#### Remaining Work

- `CommandsSpec.hs`: add `interpreterArgvTokens`, its four fixture cases, and the whole-file case above.
- `Quote.hs` and `Effect.hs`: delete `powerShellQuoteArg`, its export, its re-export, and its import.
- `EffectSpec.hs`: delete "the PowerShell quoter has exactly one definition site" and the per-character
  `powerShellQuoteArg` cases Sprint 3.6 adds. Add `powerShellQuoteArg` to `retiredQuoterSpellings`, and drop the
  `Quote.hs` exemption from the PowerShell-quoter guard.

## Remaining Work

- Sprint 24.1: export getters instead of the refined config record fields (with a compile-fail fixture), typed
  `demoChainFor` refusals, exact ConfigSpec exception and summary assertions, and the `Config.hs` Haddock fixes.
- Sprint 24.2: strict accelerator CBOR decoder and daemon endpoint/teardown/connect/protocol-error fixes with
  `AcceleratorRuntimeSpec` coverage, plus an abstract `WorkerSpec` export.
- Sprint 24.3: registry-restart outcome, typed reachability failures, per-run tar staging, Playwright target text,
  and case ids tied to `demoCases`.
- Sprint 24.4: RepoDigest selection by repository in `Container.hs`, deleting `buildProjectContainer`,
  scope-checked run profiles with a validated run name, and a core-derived digest projection test.
- Sprint 24.5: export and test `withWsl2SwapStorage`, and place a provider resource by one `resourceFrame` rule
  on the graph, edge, alias, and node routes.
- Sprint 24.7: delete the uncalled whole-plan slice projection and test the cluster action's dependency-key
  admission.
- Sprint 24.8: route-unique live services, behavioural registry refusal cases, `openPackage` over
  `openCoordinates`, and import-set and cross-domain opener guards.
- Sprint 24.9a: `ReconcileSpec` no-ownership and empty-operation refusal cases.
- Sprint 24.10: `ProviderBackendSpec` fresh-recovery refusal cases, child-side carried-recovery cases, and `LifecycleDependencySpec` mismatch and expiry tables for both carried coordinate openers.
- Sprint 24.13: bound the share-carriage guard to `runExactVmShare` with single-carriage assertions, and route all
  four dependency-package lifetimes through one checked `dependencyLifetime`.
- Sprint 24.15: bundle, package, field-count, and well-formed oversized-frame refusal cases.
- Sprint 24.16: probe request-limit and package-domain refusal cases.
- Sprint 24.17: route the production carried reprobe endpoint through the 24.16 bounds, delete the uncalled
  `withProviderDependencyForwardLifecycleChildProcess` and `withProviderDependencyReprobeServiceKernel`, a relay
  hop with no frame-splitting timeout, parent refusals reported as refusals, a per-edge liveness gate on the
  provider-dependency client, an `Either Text ()` endpoint continuation, and carrier endpoint cases.
- Sprint 24.18: admission commitment checks, client refusal fixtures, and the non-provider seeding case.
- Sprint 24.19: path-escape refusal tests with role-labelled messages, and exposure-intent targets from the
  plan-owned base.
- Sprint 24.20: behavioural binder refusal tests and node-mapping assertions.
- Sprint 24.22: refuse a foreign producer gate before any exposure effect, exact successor-exposure assertions
  with relay-rewrite refusals, exposure-request opener cases, and response renderers bounded like their
  verifiers.
- Sprint 24.24: zero-declaration chart refusal, kind-mismatch-only execution terms, cluster-parent cases, and the
  `ChartWorkloadResource` role fixture.
- Sprint 24.25a: a boundary-shift workload-identity case.
- Sprint 24.25b: an exact readiness-refusal assertion over a setup that cannot fail silently, and a chart
  generation that does not move with the gate fence.
- Sprint 24.25: foreign Helm release refusal, deletion of the public non-activated preparer, activation-revision
  and other-cluster refusals, and exact chart negative assertions.
- Sprint 24.25c: cleanup refusal tests, release-marker assertions, and the verified-bundle teardown cases.
- Sprint 24.25d: chart wire verifier and chart-request opener refusal cases.
- Sprint 24.26: chart, Cabal, and Haddock comment corrections, a typed `chartValues` refusal, exact role-codec
  digest assertions, and a `Recreate` web Deployment strategy.
- Sprint 24.28: the direct-lift placement check and typed `ProjectedDurable` fields.
- Sprint 24.29: VM build secret cleanup on every exit path.
- Sprint 24.33: behavioural activation-placement refusal tests.
- Sprint 24.34: quoted or refused YAML `hostPath`, template byte agreement, and a Direct mount discovery that
  tolerates a departed container and selects non-ASCII destinations in Haskell.
- Sprint 24.35: a `FakeCluster` arm and `ClusterWorkloadSpec` case for the prior Helm install phrase.
- Sprint 24.36: exact `PlanResourceBindingMismatch` cases for each standalone-activation admission refusal.
- Sprint 24.36a: response-decode and positive observation cases, host-portable absent-record cases, a
  non-creating observation, and an accurate crossing Haddock.
- Sprint 24.37: synchronous-only exception handling in the WSL2 exposure probe and the activation-key read.
- Sprint 24.39: Dockerfile header and key comments, a pure Direct build argv and exported `ignoredBuildEntry`
  with value cases, bounded coordinator slices, and the witness-ordering label.
- Sprint 24.40: a behavioural reverse-child fixture for `runCoreManagedReverse` order, failure, and foreign
  retention, and a `HandoffSpec` guard that it runs only under the `Prepared` grant.
- Sprint 24.43: release an owner record left without a pid, atomic pid writes, a tested pure stop decision, the
  impostor identity rows, the core PowerShell quoter, and a Windows argv rendered from
  `hostAcceleratorDaemonArgs`.
- Sprint 24.44: template headers that name `renderYaml` as the authority, a `demoCheckCode` Haddock that
  claims no tool pin, and check-code tools resolved through `HostTool.discover`.
- Sprint 24.46: WSL2 reachability inside the wall and cordon, an observed stop outcome, a no-distribution WSL
  existence probe that reports absence, and the live Incus-lane and refusal-before-creation runs.
- Sprint 24.51: web ingress and HTTP route refusals under test, and role-typed listener ports over the core
  `Port`.
- Sprint 24.52: argv-only case assertions and guest probes, and a tested WSL-only Docker daemon setup.
- Sprint 24.53: argv-only build #3, image verification, archive probe, and published-base pull, routed through
  the composition phase's typed credential-forwarding operation when authenticated.
- Sprint 24.54: a plan-derived, credential-scoped, and tested registry path with a single NodePort source, a
  store endpoint rendered by the core plan, and a tested canary.
- Sprint 24.55: accelerator runtime suites that fail on the regressions they name.
- Sprint 24.56: a web server suite that fails, never hangs, on the regressions it names.
- Sprint 24.57: `CommandsSpec` cases bounded to their subject declarations, and a UTF-8 locale encoding fixed
  in `demo/test/Spec.hs`.
- Sprint 24.58: `CommandsSpec` refusal cases that assert the named refusal, including the demo's harness safety
  refusal through its production probe.
- Sprint 24.59: runtime-dependency packages minted only from a `PlanBinding` of the plan they bind.
- Sprint 24.60: decoded packages held as `CarriedRuntimeDependencyPackage` until rebound against the receiving
  plan.
- Sprint 24.61: role-typed chart workload and service activation declarations.
- Sprint 24.62: role-typed prepared chart workload and chart request.
- Sprint 24.63: role-typed execution package, carried resource, and execution chart field.
- Sprint 24.64: a `ChartWorkloadBinding` witness required by the chart preparer and adopted by the demo.
- Sprint 24.65: demo service handlers on acquired listeners and the role `DurablePath`, with no ambient
  environment or detection in the accelerator role, and a `network-connect` accelerator effect row.
- Sprint 24.66: the core build memory bound in `demo/cabal.project`.
- Sprint 24.67: the demo cluster slice from the validated, fit-verified budget partition, and
  `withActionResourceSlice` deleted.
- Sprint 24.68: the demo's WSL global wall applied and released through the provider wall reservation and
  settlement.
- Sprint 24.69: `containerPlan` and every cluster consumer fed by one exact plan projection, with the guest,
  Kind, and chart durable paths rendered from it.
- Sprint 24.70: the image build and push gated on plan-indexed readiness.
- Sprint 24.71: the Direct lane's cluster released through the authenticated reverse child, with the demo's
  pre-parser release entry deleted.
- Sprint 24.72: a blob-route observation that reads the registry it dialled, and pull-by-digest and repeated-push
  cases across a registry restart.
- Sprint 24.73: leaf service and daemon configs carrying the leaf's own partition slice.
- Sprint 24.74: pair-check, fsync, and owner-restrict the installed signing seeds, and surface link failures.
- Sprint 24.75: share one tested pair for the handoff and stable scope spellings.
- Sprint 24.76: publish the accelerator ingress only on a lane that runs an accelerator daemon, with no
  `windows-cpu` accelerator exposure intent or `NodePort`.
- Sprint 24.77: `releaseRetainedCluster` takes the retained-cluster projection, built at its `Command.hs` and
  `Command/Child/Reverse.hs` call sites.
- Sprint 24.78: the Windows host daemon launched, probed, and stopped through a Windows branch of
  `HostBootstrap.Detached`, with no PowerShell text in the demo.
- Sprint 24.79: the whole-module interpreter-argv guard over `Commands.hs`, scoped to argument vectors, and
  the core `powerShellQuoteArg` deleted.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/unrepresentable_state.md` — the surface this phase changes in it.
- `documents/architecture/ownership_invariant.md` — the surface this phase changes in it.
- `documents/architecture/hostbootstrap_core_library.md` — the surface this phase changes in it.
- `documents/architecture/harness_workflow.md` — the surface this phase changes in it.
- `documents/architecture/generic_project_model.md` — the surface this phase changes in it.
- `documents/architecture/binary_context_config.md` — the surface this phase changes in it.

- `documents/architecture/network_reachability.md` — runtime-owned loopback exposure and resolved endpoints.
- `documents/architecture/lifecycle_state_model.md` — the canonical/live dependency registries and fresh
  provider/cluster refinements.
- `documents/architecture/composition_methodology.md` — the exact provider, cluster, workload, reverse, and
  projector composition order.

**Engineering docs to create/update:**
- `documents/engineering/resource_budgeting.md` — the surface this phase changes in it.
- `documents/engineering/derived_project_standards.md` — the surface this phase changes in it.
- `documents/engineering/derived_dockerfile.md` — the surface this phase changes in it.
- `documents/engineering/cluster_lifecycle.md` — the surface this phase changes in it.

- `documents/engineering/testing.md` — what the long gate covers that the static suites cannot.
- `documents/engineering/accelerator_daemon.md` — the per-substrate placement.
- `documents/engineering/build_release.md` — published-base provenance and authenticated derived-image build.

**Cross-references to add:**

- `documents/operations/demo_runbook.md` — the operator sequence, duration envelope, exact `Unsupported` Direct
  reverse boundary, and disposable-host requirement.
