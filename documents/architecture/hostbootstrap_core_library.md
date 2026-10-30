# hostbootstrap-core Library

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](composition_methodology.md), [binary_context_config](binary_context_config.md), [generic_project_model](generic_project_model.md), [library_hierarchy](library_hierarchy.md), [authoring_project_binaries](../engineering/authoring_project_binaries.md), [build_and_run_model](build_and_run_model.md), [ensure_reconcilers](../engineering/ensure_reconcilers.md), [dhall_topology](../engineering/dhall_topology.md)

> **Purpose**: Describe the `hostbootstrap-core` Haskell library — its opaque `StepPlan` authoring
> algebra, exact `ProjectPlan` interpreter, and the extension contract a project binary uses to build on
> top of it.

## TL;DR

- `hostbootstrap-core` owns the reusable host-management primitives and the current-frame substrate of the
  recursive interpreter:
  host-tool resolution, substrate detection, `ensure` reconcilers, cluster-lifecycle semantics, and the
  binary-context validation that gates execution. A consumer still owns project/provider actions such as
  the demo's VM setup, image build, and direct-host preparation, and contributes them as steps.
- The core surface a project extends is the **`Step` algebra**. Core ships host-management step kinds
  (deploy-vm, ensure-X, copy-source, build-pb, build-image, context-init, deploy-kind, deploy-chart,
  expose-port, and named post-handoff hooks); a project contributes its own step kinds (for the demo, deploy-object-store, deploy-registry,
  push-image, and accelerator-daemon placement)
  into the same ordered validated `StepPlan`. That value is the authoring and validation input admitted
  into one `ProjectPlan scope specDigest planId configId cfg`; host and workload steps interleave freely.
- A project's public forward description is the exact admitted `ProjectPlan`. `renderChain` consumes its
  complete non-empty `forward` projection. The root-Up interpreter keeps root-only execution on the
  direct Chain path and selects the rooted coordinator when the admitted catalog has descendants. The root
  process alone owns one
  `ProtectedStore`, the global
  lease/snapshot/acquisition, a recursively projected `RootedPlanCatalog`, and per-frame journals.
  `ValidatedLifecycleContext` is store-bearing root-coordinator parent-plan evidence and never crosses the
  process boundary. A child is a
  long-lived storeless `FrameExecutor`: it exact-compares root-signed prepared node evidence, performs the
  local effect, and returns an observation for root settlement. The coordinator opens catalog sessions
  root-first, and Chain delegates each declared descent through an exact catalog-selected process route.
  Nested children derive only their immediate child and relay through a keyless link. Raw Chain remains the
  lower current-frame substrate rather than a parallel durable command-entry route.
- The surfaced core command tree is exactly five user-facing verbs: `project`, `test`, `service`,
  `context`, and `check-code`. `ensure` is a reconciler library a project may call from a step action;
  core also exports an `ensureStep` constructor. The current demo invokes `runEnsure` inside larger
  provider/build actions instead of representing each reconcile call as an independent `ensure-*` row.
- `HostBootstrap.Identity.Install` owns root identity installation. `provisionInstalledIdentity` installs or
  validates five sibling files of the executable: the handoff signing seed `.handoff.key` and its public half
  `.handoff.pub`, the distinct build signing seed `.build.key`, and the distinct activation signing seed
  `.activation.key` and its public half `.activation.pub`. Each file is published with no-replace semantics,
  so the set is completed idempotently by a re-run rather than written atomically as a whole. Valid
  identities are retained across rebuilds, a missing public half is repaired only from its retained seed, and
  a public half without its seed, malformed material, or a mismatched pair is refused. Two callers reach it:
  the Python bootstrapper's `--hostbootstrap-install-identity` entry after it installs a newly built binary,
  and a default-role `project init` whose output resolves to the executable's sibling config, whether it
  writes that file or keeps it under `--if-missing`. Child-role init,
  `service init`, and arbitrary output paths do not reach it. Effectful `project up` runs the read-only
  `validateInstalledIdentity` over all five files before opening durable command authority, so an
  incomplete set is refused there.
- **A small closed set of argument vectors is classified before the parser.** `runCLI` recognizes five
  core-owned internal entries (identity installation, the cluster exposure relay, the Colima command
  transaction, the authenticated lifecycle child, and the frame child) before `optparse-applicative` sees the
  arguments; none is in the command tree or in `--help`. Those five are the closed set
  [development_plan_standards.md § P](../../DEVELOPMENT_PLAN/development_plan_standards.md) admits, and a
  project adds no pre-parser entry of its own. The demo's `main` still intercepts one marker before it calls
  `runHostBootstrapCLI`, a departure the
  [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) deletes. The complete inventory and
  what each entry carries are in [Entries before the parser](#entries-before-the-parser).
- The [authenticated-handoff
  phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md) owns the closed
  `RootedLifecycleRequest`/`RootedLifecycleResponse` v1 vocabulary and canonical recovery package. The
  neutral request and exact nine-/eleven-field response codecs live in Cabal-hidden `Handoff.Rooted`, whose
  importer set is allow-listed by a source guard in `HandoffSpec`. The `HostBootstrap.Handoff` facade exports
  the abstract response and renderer, the fixed-domain live-broker signer, and the installed-key CPS verifier
  `withVerifiedRootedLifecycleResponse`, which `Command.Child` and `Handoff.Process.Route` call at runtime. A
  root-signed response is authority: a child runs local plan work only on a verified root-signed `Prepared`
  grant (see the `Command.Child` row below). Transport carries exact singleton bytes through
  the bounded sealed requester envelope, checks intermediate path suffixes and complete root equality, and
  invokes the installed-key verifier only at the originating typed operation. The
  [recursive-lifecycle-command
  phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) consumes them. Recovery's rooted binding
  commits separately to the complete package payload and its child-config field; no adapter-only digest is
  relabelled as configuration, and the lower carrier composes no package of its own.
  The recursive catalog alone constructs the package, admits its complete configuration/digest, and routes the
  exact Offer through the keyless relay to the already-installed root signer. Each frame's installed
  recursive-handoff runtime is what names which arm it holds: the root arm is derived from the admitted root
  environment and a live broker's own public half and requires a route with no authenticated current frame,
  while the nested arm is derived from an authenticated parent edge, requires the relayed route to name that
  edge's child frame, and is handed out only beside the keyless link. The runtime retains no key, store,
  broker, channel, catalog, session, or route, so it can say who a frame is without letting it sign.
  The request codec extends only
  hidden `Handoff.Rooted`; Protocol's singleton outer field and bytes remain frozen. Four-field `OpenFrame`
  carries only a nonce and obtains its ancestry solely from the sealed external relay envelope. That envelope
  obeys the same one-to-256-component, 4,096-byte-per-component grammar as the inner post-open path.
  Exact nine-field signed `Opened` discloses the root-admitted canonical path plus root-issued session/stage/next ordinal but
  contains no digest of itself; only after the complete response is signed and read back does its derived
  digest become the first predecessor for the next request. Post-open nine-/ten-field requests echo those
  coordinates and must match both envelope and session path. Every exact eleven-field response echoes the
  request path/session/nonce, supplies successor stage/ordinal, and belongs to the request's closed response
  family. `Prepared` carries node/dependencies/operation-gate/projected-gates packages; `FrameComplete` carries
  one canonical lifecycle report; `ReceiptRecorded` repeats its predecessor digest; rooted `Refused` is
  post-open only. Root signatures authenticate responses; those coordinates protect the cooperating sealed
  interpreter, not identity against a malicious launching parent. Only the root signs catalog-selected
  prepared grants and settles returned observations.
- The canonical home of this model is [composition_methodology](composition_methodology.md); this doc
  describes the library surface that realizes it and defers there for the model itself.

## Current Status

The core surface is the fixed **`project` command and current-frame interpreter substrate**. It merges the `context`
read-only command, `project init|up|down|destroy`, the `test init|run` split, `service init|schema|run`,
and `check-code` into a
composable `optparse-applicative` value. The demo's deploy is the first-class
`demoChainFor :: Substrate -> CanonicalProjectRoot scope rootId -> ProjectConfig scope -> [Step]` fragment (in
`demo/src/HostBootstrapDemo/Commands.hs`), partially applied to the detected `Substrate` and accepted through
`addSteps`, so its steps derive their paths from the admitted canonical root. It is validated as the authored graph
from which exact project-plan admission derives `forward` and `DerivedTopology`; the demo also
contributes its `web` and `accelerator` service variants and its VM/provider IO as chain steps — the
surface is fixed, so it adds no verbs. The binary-context gate and
the project-local `<project>.dhall` schema decoder/encoder back the interpreter.

The public `HostBootstrap.Chain` surface is exact-plan-only, but it is a lower substrate rather than a
command-entry authority. Production dispatch retains or reconstructs one admitted plan across rendering
and snapshot persistence/binding, then joins it to one `ValidatedLifecycleContext`; the hidden fixed
root-Up entry derives and retains the journal, Execute cursor, and one-use command authority before
supplying them to Chain. Its reverse verbs use the matching plan/current-frame projection. Harness
dispatch retains one Harness-indexed plan inside the generated-config ownership bracket, admits that
plan's exact lifecycle context, and uses the same hidden root-Up entry for its forward action while
retaining its exact reverse action for engine-owned cleanup. The project's five-field `TestSuite` supplies
only the safety precondition, assertion-environment opener, case matrix, per-case assertion, and
post-reverse absence assertion; it owns no lifecycle callback or subprocess route. The reverse action is
projection-only rather than command authority.

The implemented root-only lifecycle substrate includes a private verb-tagged reverse intent protocol, exact
same-verb resume and fresh-source admission, a liveness-held snapshot facade, and a sealed Down/Destroy root
entry. It also includes durable Prepared/Bound reverse descent state, strict adapter re-rendering, recoverable
one-use edge opening and token repair, canonical completion reports and observations, sealed semantic completion,
root-resident parent acknowledgement, keyless request/response routing, finalized child projection, and the
opaque inert `PlannedForwardHandoff`. These pieces retain their exact plan, frame, verb, broker, binding, and
record-version relations. Forward and reverse children share the storeless rooted executor. The sealed
root reverse entry also owns the sole exact cluster-cleanup seam: a plan-derived `DeleteCluster` local work
item can run only behind a `PreparedGate` naming that plan and operation, and the closed Down/Destroy term
selects the effect without a caller flag. The shared recursive reverse command consumes that seam.

Cluster backend discovery is package-indexed rather than caller-selected. It consumes the opaque
`PlanOwnedClusterConfig`, selects exactly its Kind or nvkind branch, and mints a Cabal-hidden strong capability
only when the selected creation driver and Docker, Kubectl, and Helm are present in typed `HostConfig`;
discovery probes nothing. The capability retains that `HostConfig`, the exact driver, canonical config bytes
and digest, ownership identity, plan-owned kubeconfig path, and a readiness-version counter. It retains no
per-tool executable identity and no store: each cluster transaction opens the protected store in its state
directory when it enters. Reconcile and reprobe validate those retained terms against the prepared operation before effects;
Kind cannot fall through to nvkind, nvkind cannot fall through to Kind, and callers cannot inject executable
paths or argument vectors. The protected store holds the ownership clauses, as specified by the
[cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).

`Handoff.Completion` owns sealed semantic completion. `Handoff.TerminalReport` renders canonical reports
from the exact terminal origin supplied by the root coordinator. Protocol, Receiver, and Relay stay Cabal-private. Receiver additionally carries the
dedicated child entry that takes its protocol descriptors before any callback can: it duplicates the original
standard input and output into private handles, builds the binary channel from those, and for the callback's
whole life points global standard input at the null device and global standard output at standard error. One
bracket flushes, redirects, restores, and closes on every path including cancellation, the entry accepts no
channel and no handle, and the duplication policy is the module's only one, with no ambient heuristic,
alternate descriptor, or exported testing seam. The lower relay framing validates
exact request/response correspondence and cooperating-route ancestry; only the root arm may enter durable
prepare or adoption. Root-owned receipt confirmation orders Published → signed `FrameComplete` →
`ReceiptConfirm` → Received → signed `ReceiptRecorded`. A nested process receives no receipt writer or
`ProtectedStore`. An open-attachment failure remains Protocol's existing outer `Refused`; it is never encoded
as a rooted post-open refusal.

The finalized project boundary installs exactly one child projector, validates projected configuration through
the finalized codec, and exposes neither projector bytes nor a caller-polymorphic result. The exact
`PlannedForwardHandoff` joins that projection to admitted topology, constructs the target plan and
`PlanDigestBinding`, retains a sanitized process route and inert binding input, and grants no process, channel,
journal, cursor, store, or effect authority. The rooted catalog shares its immediate-target projection
kernel and dispatches through the catalog-admitted `CatalogForwardHandoff` package, as specified by the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).

The implemented forward runtime keeps `ValidatedLifecycleContext` and its retained store in the root process,
constructs one recursive `RootedPlanCatalog`, opens every catalog-selected `RootedFrameSession` root-first,
and signs
`PreparedNodeGrant` only after durable Unknown publication. Long-lived children are storeless
`FrameExecutor` values that exact-compare each signed grant against their independently rebuilt target plan
and return bounded observations for root settlement. Its nonterminal loop durably prepares and settles nodes,
advances exact session ordinals, dispatches only an admitted requester path, and delegates nested descent
without lending signing or store authority. Reverse launch has the corresponding private composition
seam: canonical package decoding remains in `Teardown.Internal`, witness-only nominal route selection remains
in `Handoff.Process.Route`, and `Handoff.Process` owns the derived child for exactly the authenticated edge.
The prepared reverse frame service retains its exact Offer and forest, consumes root-owned pre-descent work
internally, signs grants only for child-local work, imports only an exact completed deeper descent, and admits
Close and receipt only after canonical semantic completion rejoins the durable Bound row. The same coordinator ultimately owns successful reverse
terminalization and rearm, the child-first public reverse driver, and failed-Up unwind.
The root command authority retained by `ReverseDescent` remains indexed by the root frame; its separately
indexed `DescentWork` may name any exact parent/child edge in that root plan. Catalog selection and topology
validation bind those coordinates without manufacturing per-child command authority.
The public Production reverse verbs interpret no plan beside this owner. Their single command
call site obtains a sealed target entry from `LifecycleEntry`, and the shared driver recursively prepares each
catalog edge, installs its restricted reverse broker link, launches the derived process route, and waits for
verified `SubtreeSettled` before continuing. Successful root settlement can reach Mode terminalization only
through the producer-supplied closure that retains the exact target lease and verifies all sessions closed for
the retained plan digest.
`StepPlan` remains available to author and validate a graph; it is not the public Chain execution boundary.
Nested lifecycle entry uses authenticated child admission and proof-complete recursive traversal, while exact
`down`/`destroy` authorization belongs to
[the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).

Development ownership follows that boundary: the
[step-algebra-and-project-plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
owns the exact plan/current-frame/Chain and Production current-frame foundation, while authenticated
recursive child entry and traversal remain with the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md). The
[test-harness-and-run-ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)
supplies exact generative Harness run evidence to the generic authenticated-scope producer, adopts that
Harness producer call site, and owns the Harness command consumer and assertion engine.

The lift surface is layered below that plan boundary. The
[Dhall-configuration-and-generic-project-model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)
owns pure `HostBootstrap.Lift.Context`; the
[ensure-reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md) owns the generic resolved-tool
`HostBootstrap.Lift`; and the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns provider lifecycle realizations that consume and reexport the lower target records/renderers. Registry
policy is additive above generic Lift, never an import of generic Lift itself.

On Incus/Linux, `project up` constructs the persistent stack: a cordoned kind cluster, registry, pushed
project image, and service workloads. `project down` and `project destroy` traverse the same plan's
child-first reverse forest and apply each node's exact managed cleanup policy. The demo calls config-free
reconcilers inside provider/build actions; it does not expose every `runEnsure` call as a separate chain row.

The direct `linux-gpu` path is also represented by the same core surfaces, not a second orchestrator.
Its two-frame demo chain runs the metal resource preflight plus `Ensure.Docker`/`Ensure.Cuda`, builds the
CUDA project image, and hands off with `--gpus=all`. The demo's `containerPlan` selects
`NvkindDriver`; core executes that supplied plan, creates the explicit control-plane + GPU-worker
topology, splits and applies the one
cluster envelope across both node containers, probes allocatable GPU before any Helm or `kubectl`
mutation, installs NVIDIA device-plugin `0.19.3` only when that probe is not already positive, and gates
on positive `nvidia.com/gpu` before the project deploys its GPU-requesting daemon pod. These surfaces have
static coverage. Native and virtualized hardware evidence, current gate status, and test totals belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

The Windows surface splits by responsibility: the `windows-cpu`/`windows-gpu` substrates and
`Ensure.CudaWin` describe the host build stack, while `HostBootstrap.Wsl2` and `Ensure.Wsl2` implement
the Windows provider path. Current hardware evidence and closure remain in the development plan. See
[wsl2](../engineering/wsl2.md) and [ensure_reconcilers](../engineering/ensure_reconcilers.md).

Current generic model: under
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md) the extension
contract is the generic `ProjectSpec cfg tcfg`, parameterized over a project's config family
`cfg :: Type -> Type` (its `<project>.dhall`) and test-config type `tcfg` (its
`<project>.test.dhall`). Core then owns no fixed config type and **no default values**.
`ProjectCfg cfg` exposes only read-only `cfgContext` and installs identity-generative Production and
authority-closed Harness mapped `ProjectCodec`s; it exposes no raw context updater. Canonical
render/hash/strict re-decode yields scope-correct root-local `ValidatedConfig` identity. The surfaced
command tree (`project`, `test`, `service`, `context`, `check-code`) is core-owned and fixed. One
restricted `psAssemble` is the default-bearing project-config path for Production init and exact-run
Harness variants; `psTestInit` separately builds `tcfg`. An opaque typed service registry is jointly
finalized with the full codec under one digest, and demo role projection consumes only explicit
assembled Web/Accelerator fields with no fallback values. See the
[generic_project_model.md](generic_project_model.md) design,
[Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md), and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

These gaps between the tree and the contract this page states are open:

- `project up --dry-run` is meant to render the admitted plan without acting. It enters the same Production
  path as an effectful `up`: it opens the protected authority store, acquires or retains Production mode
  through `withProductionRoot` (recording an unbound lease, and refusing while a Harness run holds the
  mode), or recovers a bound Production snapshot, before it renders. It skips only the installed-identity
  check and the lifecycle-context and execution stages. The
  [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) owes
  a dry-run path that takes no mode, lease, or snapshot authority.
- The demo's `main` intercepts `--hostbootstrap-direct-cluster-release-v1` before it calls
  `runHostBootstrapCLI` (see [Entries before the parser](#entries-before-the-parser)). That is a per-project
  pre-parser entry, which
  [development_plan_standards.md § P](../../DEVELOPMENT_PLAN/development_plan_standards.md) forbids. The
  [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owes its deletion and the release of the
  Direct cluster through the authenticated reverse child.
- `HostBootstrap.Chain` also exports `runChainFromFrame` (with `runChainFromFrameWithDescent` and the
  `handoffDispatch` renderer), which no command calls and which launches `<self> project up` by argument
  vector through `liftSubcommandWithStdin` at a descent instead of handing it to the rooted coordinator. The
  [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) owes
  its deletion.
- The hidden handoff owners (`HostBootstrap.Handoff.Protocol`, `HostBootstrap.Handoff.Receiver`,
  `HostBootstrap.Handoff.Relay`, `HostBootstrap.Handoff.Internal`) are main-library `other-modules`, so the
  test suite reaches them only through source guards and compile-fail fixtures. The
  [authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
  owes a test-only route that lets their refusals be exercised by value while consumer imports stay
  refused, and the kill-on-close Job Object Windows row of `HostBootstrap.Effect.ChildGroup`.

## Module Surface

The library namespace is `HostBootstrap.*`. The set below is indicative of the surface consumers depend
on; the canonical inventory is tracked in
[`../../DEVELOPMENT_PLAN/system-components.md`](../../DEVELOPMENT_PLAN/system-components.md). A module is
importable by a downstream package unless its row says **Cabal-hidden** (listed in the main library's
`other-modules`) or names a private Cabal sublibrary; the Cabal file is authoritative for visibility.

| Module | Responsibility |
|--------|----------------|
| `HostBootstrap.HostTool` | Closed enumeration and absolute-path resolver for managed external tools (including `Nvkind`/`NvidiaSmi` and Windows `Winget`/`Nvcc`/`Wsl`). Prepared provider and cluster routes resolve their clients alone and hold their clauses through protected-store entries; the removed Python/flock/lockf locking front end is not part of either backend. The guest-alias route's own front ends are the guest's, reached through one absolute host-provider command. Managed host effects consume resolved tools; guest command names are interpreted in their declared guest frame. |
| `HostBootstrap.Detached` | The sealed host-invocation *shape* boundary (§ HH) for a child that outlives its launcher. `DetachedLaunch` hides its constructor and every field accessor; the stdio disposition, descriptor inheritance, session, and console detachment are fixed inside the module. `withDetachedChild` is a rank-2 bracket over the launch, total on acquire, that retains the child's own output for the launcher to quote (§ CC). |
| `HostBootstrap.HostConfig` | Typed host configuration containing detected substrate and resolved tool paths. `HostCapacity` is discovered separately by provider-neutral `HostBootstrap.Cluster.Cordon.Foundation` for budgeting. |
| `HostBootstrap.Substrate` | Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`, `windows-cpu`, `windows-gpu`) and host-applicability predicates. |
| `HostBootstrap.Ensure` | The `Reconciler` value type and `runEnsure` runner. It is not exposed as a command; the current demo calls it from composite step actions, while `HostBootstrap.Step.ensureStep` is available for projects that model a reconcile call as its own row. |
| `HostBootstrap.Ensure.*` | Nine context-free dependency reconcilers live in `allReconcilers`; `Ensure.Colima` is instead an implemented exact plan-owned adapter. It consumes the matching plan/provider/topology/budget/fit/partition plus journal-derived reservation/start, derives one 128-bit isolated-home/global-lock authority and socket-safe local profile, and accepts no compatibility lifecycle plan, caller profile/root, raw envelope, executor, or host config. The canonical start fixes side-effecting defaults and binds CPU/memory plus a 20-GiB root and `total-20`-GiB data disk. Its Cabal-private backend contains the fixed Apple resolver, bounded runner/supervisor, descriptor-relative filesystem/context/namespace/origin programs, and opaque settlement bridge. The private `Resolver.Install` kernel orders retained-Brew revalidation, bounded fixed invocation, and a complete fresh resolver pass. `Resolver.Testing` adds descriptive views plus a bracketed thread-local fixture execution seam: it is unavailable to downstream clients, every public-adapter discovery/revalidation still runs strict resolver parsing and settlement, and it exports no trusted-toolchain or backend-result constructor. Self-bound origin states, machine/context and complete artifact identities gate provider-start/wall settlement, live Docker, and independently journaled conditional `colima delete --force --data` cleanup. A prepared-but-present outcome, foreign/replaced identity, or partial foreign stage mints no authority. The [cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) owns these exact library adapters. `Ensure.Wsl2` owns prerequisite diagnostics, normalization, virtualization classification, and `bcdedit` rendering without importing the WSL2 lifecycle realization. Other probe strengths and platform install coverage still vary: Docker installs only on Linux and delegates/refuses on Apple/Windows, and Homebrew can only verify the pre-binary minimum. `Ensure.Cuda` owns the signed NVIDIA apt bootstrap, default-runtime/CDI/volume-injection configuration, and the exact nvkind Docker smoke. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| `HostBootstrap.Step` | Opaque `Step`/`StepKind`, disjoint typed core/project identities, explicit reverse policies, namespaced operation keys, plan-authored chart and standalone service-activation declarations, and opaque `StepPlan`. Smart constructors are public; raw constructors are not. `mkStepPlan` rejects empty/duplicate/conflicting plans, noncontiguous `A/B/A` returns, and a post-handoff suffix that does not unwind deepest participating frame first while preserving every valid list's exact order. Activation admission additionally requires one non-empty role/effect declaration per authoring step and a frame unique across both declaration families; its canonical commitment carries no runtime measurement or signing authority. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.ProjectPlan` | Pure public facade for one generative admitted plan. It exposes opaque `PlannedStep` forward order, `DerivedTopology`, stable snapshot, exact resource/edge projections, and reverse policy/callback projections while keeping construction in the trusted admission layer. |
| `HostBootstrap.Plan.Resource` | **Cabal-private `plan-resource-internal`.** The single positional `PlannedResource` representation and seven resource-family tags, depending only on `base` and `text`. All five identity indices are nominal. `Lifecycle.Plan` retains validated-graph minting and readers; public facades and the private readiness kernel share the same opaque identity. |
| `HostBootstrap.Readiness.Kernel` | **Cabal-private `readiness-internal`.** Generic-config `Probe`, closed backend keys and observation payloads, and the private probe factory and observer. It depends only on `base` and the shared plan-resource unit. The six identity indices are nominal; configuration and payload parameters are representational. It defines no configuration representation or polling loop. |
| `HostBootstrap.Readiness` | Opaque validated polling and total probe results. Its public seven-parameter `Probe` synonym specializes the private kernel's eight-parameter type to `HostConfig`; polling, version validation, and `Ready` integration stay here. Closed backend keys require an exact planned resource; probe injection is private. The public `dependencyProbe` wrapper remains a separate gap in `Reconcile`. `ObservedReady` is non-authorizing evidence for local convenience helpers. See [readiness](readiness.md). |
| `HostBootstrap.Reconcile` | Final-codec/step-plan lifecycle identity; opaque planned resources/edges, reconcile/adoption outcomes, prepared operation pairs, phase-indexed handles, and legal persisted journal transitions. The result/handle foundation belongs to the [canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md). Its consumers are the protected-store journal in `HostBootstrap.Lifecycle.Transaction`, `HostBootstrap.Chain`, and the live adapters `HostBootstrap.Cluster.Reconcile`, `HostBootstrap.Substrate.Provider.Reconcile`, and `Ensure.Colima`. |
| `HostBootstrap.Chain` | Exact public current-frame substrate. Root-local execution consumes matching Execute authority/cursor evidence and rereads the acquisition/cursor row inside protected transitions. At a process boundary Chain does not lend those values: `DerivedTopology` feeds root catalog construction and a storeless frame executor runs only root-granted nodes. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Config.Schema` | Owner for project-local `<project>.dhall` schema surfaces, sibling lookup, canonical root admission, canonical render/hash/re-decode verification, child projections, and service/daemon snapshot metadata. `withSiblingValidatedProjectConfigContext` binds service selection and execution to one verified snapshot. Core owns no defaults. The named `context-init` action is still only an announcer; VM/container/service delivery remains split across lifecycle actions. See [dhall_topology](../engineering/dhall_topology.md). |
| `HostBootstrap.Config.Fields` | Opaque common framework view, full-vs-role and Production-vs-Harness discriminators, `RoleCodec`, structural `RuntimeRoleWire`, `ValidatedServiceRequest`, and `RoleParams`. Role wires include mandatory framework validation plus only the selected service fields. |
| `HostBootstrap.Context` | Binary-context substrate inside `<project>.dhall`: discover the sibling path, render topology frames, validate the whole graph, selected ancestry, and the placement-complete required/exact witness set, and gate the chain per frame on handoff. Duplicate identifiers, missing parents, cycles, disconnected frames, and incomplete or extraneous witnesses refuse validation. Read-only introspection backs the `context` command. See [binary_context_config](binary_context_config.md). |
| `HostBootstrap.Lifecycle.Context` | Opaque five-index `ValidatedLifecycleContext` joining one canonical root, the coordinator's already-open exact protected store, an admitted root or nested parent plan, current/project frame, and validated binary context. Admission rechecks project/binary identity, root/store identity and path, topology, placement, and the exact runtime-witness set. The value is root-process-resident and never a child-process input; rank-2 `RootedPlanCatalog` selection structurally binds each target plan/config/current frame without a second evidence type or store authority. |
| `HostBootstrap.ProjectRoot` | Rank-2 canonical project-root admission with private `CanonicalProjectRoot scope rootId` / `CanonicalHostPath scope rootId` constructors. Admission retains the surrounding config/lifecycle `scope` and mints only `rootId`; the sibling gate therefore cannot yield an independently scoped root. Relative roots use the config-owned project-home anchor; missing, wrong-kind, escaping, and redirected roots fail before the callback. |
| `HostBootstrap.Authority` | Safe lower-authority facade: closed verbs/phases, executable-path-verified rank-2 installed identity, exact-store OS-principal evidence, and opaque broker epoch, root, root-scope, and command-authority inspection. The verb-generic reservation gate is root-only; no child command-authority or store opener is part of the recursive process boundary. |
| `HostBootstrap.Lifecycle.RootedPlan` | **Cabal-hidden.** Root-only recursive catalog construction, persistence/readback, root-first continuation folding, and rank-2 structural selection of exact planned or recovery edges. It introduces only `RootedPlanCatalog`; no second catalog-entry or frame-evidence type is exposed. |
| `HostBootstrap.Lifecycle.Rooted` | **Cabal-hidden.** Root-only frame-session coordinator. It opens and advances `RootedFrameSession`, prepares `PreparedNodeGrant`, owns exact node/operation-key selection and per-frame journal transitions, and settles replay while retaining the invocation's sole protected store. The prepared reverse service couples one exact Offer and child forest to that session; terminal receipt confirmation remains gated on semantic completion. |
| `HostBootstrap.Lifecycle.FrameExecutor` | **Cabal-hidden.** Long-lived storeless child interpreter. Its seven indices are nominal and five are minted by the opening, so one frame's executor is not another's. One helper turns signed bytes into a response through the installed key and the exact request they answer, so no branch reads a coordinate off unverified bytes: opening admits only `Opened`; the closed post-open selector admits `NextNode`, `SettleNode`, `DescendResult`, `CloseFrame`, and `ReceiptConfirm`; advancing admits every post-open response family but `Opened` and requires a strictly greater ordinal; and execution admits only `Prepared` and reads its four nested packages out of that response rather than beside it. It exact-compares the authorized node, its ordered dependencies, and its projections against its own reconstructed frame plan, requires every gate package to name that plan, frame, and session, then reifies the same durable gate through a hidden allow-listed mint, performs the local effect, and returns one bounded observation. It exposes no store, raw record key, snapshot, cursor, signer, session opener, settlement, or operation-set selection. |
| `HostBootstrap.Command.Child` | **Cabal-hidden.** Fixed `--hostbootstrap-lifecycle-child` entry (see [Entries before the parser](#entries-before-the-parser)) for Production and Harness forward and reverse frames. It loads the independently installed `<executable>.handoff.pub` and takes the isolated Receiver channel. Forward admission authenticates the canonical config wire; reverse admission independently decodes and re-renders the recovery package's child config, reconstructs and digest-binds the exact local plan, and admits only the byte-identical Down/Destroy adapter through `HostBootstrap.Teardown.Executor.Internal`. Both arms open one long-lived `FrameExecutor`. Root-signed `Prepared` responses alone run local plan work; observations return through `SettleNode`, and a reverse `Descend` advances only from canonical observations that replay to its exact child projection. Terminal reporting follows `CloseFrame` plus `ReceiptConfirm`, returning only the root-signed `FrameComplete` report after `ReceiptRecorded`. It imports no protected store, signing key, root broker, durable mutation, or process launcher. |
| `HostBootstrap.Authority.Kernel` | **Cabal-private `authority-internal`.** Representation and protected-transition kernel for fresh project/store-bound broker epochs, closed exact-scope root minting, and canonical one-use command reservation. It shares the one definition of the scope indices with the main library. An import guard allow-lists package consumers and keeps configuration/plan validation above this layer. |
| `HostBootstrap.Authority.Testing` | **Cabal-private `authority-internal`.** The package suite's narrow fixture access to the private authority kernels. It is absent from the main library's exports and re-exports; downstream consumers cannot import it. |
| `HostBootstrap.Protected` | Versioned durable record store with OS-released exclusive entry, store identity, exact-version compare-and-swap/delete, atomic publish, injective record-name encoding, and an effective create/remove probe for the exact records directory. |
| `HostBootstrap.Cluster.Cordon.Foundation` | Implemented exposed lower boundary. The [canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md) owns opaque canonical-unit `ResourceBudget`, exact quantity parsing/refusal, provider-neutral capacity reads/verification, exact-budget sizing renderers, and storage-wall policy. Its guarded imports stay within host configuration/tools/substrates, the effect vocabulary/interpreter, and the private native Windows capacity kernel. Per-dimension source types reject a memory source in a CPU slot. Whole-GiB providers reject inexact hard ceilings rather than rounding upward. See [resource_budgeting](../engineering/resource_budgeting.md). |
| `HostBootstrap.Cluster.Cordon` | Implemented configuration-facing facade owned by the [Dhall-configuration-and-generic-project-model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md). It reexports the foundation and adapts `Config.Vocab.Resources`/`ResourceEnvelope`, preflight wrappers, and descriptive pure `fitsBudget`; it owns no plan-indexed workload/fit/partition/slice proof. Its exact dependency direction is mechanically guarded. |
| `HostBootstrap.Cluster.Budget` | Closed provider keys plus opaque plan-indexed validated/effective budgets, workload fit, and constructive partitions/slices remain pure. The only public provider-wall reservation producer consumes the exact plan/provider resource, wall, partition, and durable `PreparedGate`, deriving its session/fence/attempt/journal lineage from that gate. Raw wall observations stay descriptive: an unexposed provider-specific bridge first validates its closed backend result, then package-hidden `HostBootstrap.Cluster.Budget.Internal` can mint the nominal settlement permit from only that owning observation and the matching prepared operation/preconditions. Public settlement consumes the permit rather than a caller observation. The same hidden path completes the opaque journal-bound provider start to its exact generic Running handle/receipt without substituting provider-specific machine identity for resource generation. WSL success returns its lease inseparably; uncertain acquisition returns no authority. The [cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) closes this boundary with direct Colima's descriptor-held `flock(2)` acquisition and identity-conditional cleanup. The Apple demo uses Lima, and the [Apple Silicon acceptance phase](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md) exercises the direct-Colima adapter through a separate native lane. |
| `HostBootstrap.Cluster.Lifecycle` | The [cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)'s opaque nominal `PlanOwnedCluster` joins one admitted plan to its matching cluster/provider resources, topology, plan-derived Production or generative Harness profile/root/config presence, and exact budget slice. `HostBootstrap.Cluster.Reconcile` additionally requires an opaque backend-minted Running-provider dependency, binds config bytes and budget into preparation, retains backend container identity separately from journal generation, and gates readiness behind identity-checked cordon. Cabal-hidden `HostBootstrap.Cluster.Workload` then binds the planned chart to fresh cluster readiness, canonical values, its optional exact activation-revision basename, and its durable gate; activation signing remains root-owned and the installed revision remains runtime input rather than deployment-controller authority. `Cluster.Backend` alone renders Helm/Kubectl forward and Helm absence-checked reverse calls, both settling through existing generic reconciliation results. See [cluster_lifecycle](../engineering/cluster_lifecycle.md). |
| `HostBootstrap.Cluster.Backend` | Public production discovery resolves the selected Kind/nvkind driver plus Docker, Kubectl, and Helm through typed `HostConfig`/`HostTool`, exposing only an opaque strong backend and exact-indexed calls. The executor, injected-test constructor, raw result constructors, relay implementation, and durable protocol live behind Cabal-private/hidden modules. Tools resolve once through `HostConfig`; the backend retains that configuration and no per-tool executable identity or store, and each transaction opens the clause-holding protected store in its state directory. The closed backend contract fixes the child environment/cwd/PATH and watchdog, self-binds cluster records and exact config/kube snapshots, retains every node container ID, and conditions cordon/readiness/cleanup on those identities. Exposure preparation consumes only service/target semantics and an exact applied cordon; reconciliation creates an identity-labelled relay with Docker's atomic loopback-only host-port selection, persists the exact mapping, and mints opaque `ResolvedExposure` values only after exact identity and mapping inspection. Exposure release precedes cluster cleanup and refuses replacement, wildcard, missing, added, or changed mappings. |
| `HostBootstrap.Lift.Context` | Implemented public boundary owned by the [Dhall-configuration-and-generic-project-model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md): Incus/Lima/WSL2 target records, container/config delivery, and same-root `canonicalHostMount`. The [ensure-reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md) supplies opaque `VMStack` and `LiftContext`: the VM builders extend the open stack, `vmContext` closes it without a container, and `inContainer` closes it with one terminal container. Ordinary `liftLayers`, `liftVMStack` and terminal readers expose the retained structure without record update; the Lift facade reexports the same abstract types and API. Target/container/config records remain public descriptive values. One renderer per VM provider consumes `VMPlacement` for both ordinary and lifecycle leaves, carrying optional workdir, non-interactivity and elevation. Lima and WSL include sudo only when elevated; ordinary Lima enables it to retain `sudo -H`, while Incus already executes as root. Every WSL crossing uses `--exec` followed by the supplied command vector. The authenticated lifecycle authority channel remains distinct. The module resolves no tool and performs no effect. |
| `HostBootstrap.Lift` | The generic self-reference fold and effect dispatch is implemented over `Lift.Context`; the [ensure-reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md) owns its effect seam, adversarial quoting, and import-guard coverage. Lift reexports selected pure vocabulary, resolves only the outer host tool, and imports no provider realization or Registry module. Ordinary container config delivery is staged create/copy/start work: supplied stdin becomes a ustar projection for `docker cp`, then attached start retains the image entry point. The public stdin execution signatures are unchanged; the single-command eliminator refuses staged delivery. Known-ID failure cleanup follows the remove/retain policy and preserves the primary result. The exact Chain derives each frame boundary's context from `DerivedTopology` and hands off `pb project up` through this lower seam. Reachability/blob leaf helpers are later additive network/registry extensions rather than part of this generic contract. See [composition_methodology](composition_methodology.md#the-recursive-project-up-interpreter) for the protocol, cleanup limits and static validation boundary. |
| `HostBootstrap.Substrate.Provider` | Implemented boundary. `SubstrateProvider` is abstract and selected from a closed Incus/Lima/WSL2/Direct kind; narrow projections expose descriptive identity, Lift context, and pure plans without exposing construction or record update. Discovery executes provider-owned closed requests against raw outcomes, bounds retry, and mints a generative backend-indexed capability only from the exact opaque managed Running provider. `Provider.Reconcile` exposes opaque nominal managed provider/share authorities and exact prepared provision/ready/share/stop/delete calls. Its fresh CPS opener rebinds carried evidence to the exact planned provider identity and keeps the backend/provider indices lexical through dependent share and alias work. The Incus realization holds the four ownership clauses over VM/share mutation and bound guest execution, through the seam's reported face: every effect is a described command run by the one interpreter, every answer a total classification, and the transaction's standing a total function of the durable record, that observation, and the claim the instance carries. Direct is only a plan-local admission and identity share, with structured stop/delete/guest/alias refusals and no physical-host ownership. `Provider.Alias` consumes the matching managed provider/share authority and ships a closed symbolic-link transaction to the installed guest binary. The far-side ownership row uses the shared protected store and origin codec for no-replace publication, interruption recovery, exact kernel-identity binding, and conditional release; provider discovery retains no guest `flock`, `stat`, or Python front end. The demo's exact copy-source action completes `reconcileNodeGuestAlias` before releasing either lexical handle, and its reverse releases the alias before provider deletion. The [host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) owns this boundary, its native Linux/x86_64 KVM/Incus gate, and its remaining provider, alias, shipped-row, and guest-VM work; the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns demo call-site adoption. |
| `HostBootstrap.Incus` / `HostBootstrap.Lima` / `HostBootstrap.Wsl2` | Provider lifecycle probes and argv builders consume and reexport their target records and inner renderers from `Lift.Context`, leaving lifecycle-specific create/start/copy/stop/delete behavior in the provider modules. The [host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) owns that boundary, and the Apple Silicon and Windows acceptance phases own the native Lima and WSL2 confirmations. `Ensure.Wsl2` owns prerequisite diagnostics; `HostBootstrap.Wsl2` only compatibility-reexports those lower definitions. See [Incus](../engineering/incus.md), [Lima](../engineering/lima.md), and [WSL2](../engineering/wsl2.md). |
| `HostBootstrap.Registry` | Registry credential discovery/forwarding exists. The [composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md) owns the registry-aware `liftSubcommandWithAuth` consumer here so Registry imports generic Lift and its quoting helper while Lift imports no Registry policy. Credentials are forwarded only at the stdin effect boundary and remain absent from argv. See [registry_credentials](../engineering/registry_credentials.md). |
| `HostBootstrap.Harness` | The standardized assertion engine. Its five-field existential `TestSuite` contains the safety precondition, assertion-environment opener, case matrix, per-case assertion, and post-reverse absence assertion—no bring-up or teardown callback. For each variant the command-owned `ConfigVariant` supplies an opaque lifecycle over one exact Harness plan; the engine runs forward, assertions, reverse, and the absence check in that order and reports lifecycle/cleanup failures separately. Terminal close requires the reverse action's settled-destroy `ProjectClosureEvidence`; callback success alone is not close authority. See [harness_workflow](harness_workflow.md). |
| `HostBootstrap.Harness.Lifecycle.Internal` | Constructor and eliminators for the opaque `HarnessLifecycle`. It lives in the private `harness-lifecycle-internal` Cabal component, which the main library and its own test suite may depend on but downstream packages cannot. Command constructs the runtime value from one exact Harness plan; engine tests use the same private component rather than exposing a public constructor. |
| `HostBootstrap.Command.LifecycleEntry` | Cabal-hidden owner of root Up, Down, and Destroy entries. Each nominal package joins the exact root authority, verb, plan, root lifecycle context, acquisition journal, cursor, command reservation, and rooted catalog. Root admission reserves the command only after the exact evidence joins; retained reverse terminalization validates complete subtree and session settlement. Children cannot inhabit this sum: `Command.Child` drives the storeless frame executor through signed rooted grants and terminal receipts. No public constructor or authority projection exists. |
| `HostBootstrap.Command` | The **fixed** core command tree (`coreCommands`): `project init|up|down|destroy`, `test init|run`, `service init|schema|run`, `context`, and `check-code`. Both Production and typed Harness `up` paths validate one exact lifecycle context before snapshot persistence and immediately pass the hidden lifecycle entry to its fixed interpreter; an Execute reservation is one-use and a Teardown retry performs no second effect or reservation. `project down|destroy` are two verb-indexed projections of the one plan: core Kind cleanup runs only when the current frame owns `deploy-kind`, every other node runs the reverse its own step declared, and per-node outcomes are structured with failures aggregated after every independent node has run. No per-project verbs. |
| `HostBootstrap.CLI` | Opaque identity-parametric `ProjectSpec cfg tcfg`, unfinished `ProjectSpecBuilder`, checked additive operations (step fragments rank-2 in one shared root/config scope), `finalizeProjectSpec`, and the two entrypoints. Finalization validates suite/case/artifact/input/service contributions; dispatch verifies and retains the executable identity before selecting codecs or commands, and per-config plan projection validates the exact non-empty `StepPlan` before interpretation. One restricted identity-polymorphic `psAssemble` supplies Production/Harness configs and `psTestInit` supplies `tcfg`. |
| `HostBootstrap.Config.Class` | The single typeclass coupling core to a project's config family: `ProjectCfg` (read-only `cfgContext` plus the codec), `TestCfg`, `InitArgs`, `ExistingOutputPolicy`, `AssemblyRequest`, `ConfigAssembly`, and the `ProjectCodec` family. Core names no concrete config record; project defaults live only in the project's assembler. |
| `HostBootstrap.Identity.Install` | `provisionInstalledIdentity` installs or validates the five sibling identity files with per-file no-replace publication, and `validateInstalledIdentity` checks the complete set read-only. See the TL;DR and [Entries before the parser](#entries-before-the-parser). |
| `HostBootstrap.Handoff.Transaction` | Both ends of one frame crossing: `classifyFrameChild` and `runFrameChildEntry` on the far side, `withFrameChildTransaction` on the near side. It carries one opaque transaction and one opaque outcome and interprets neither. See [The frame-child entry](#the-frame-child-entry). |
| `HostBootstrap.Teardown` | The verb-indexed reverse projection `TeardownPlan` and its child-first teardown forest. `openTeardownForest` is the sole initial producer of a forest; only a completed forest reaches `verifySubtreeSettled`, and only a root-frame destroy subtree reaches `verifyDestroySettled`. It owns `SubtreeSettled` and `DescentWork`. |
| `HostBootstrap.Service` / `HostBootstrap.Service.Program` | `Service` holds opaque typed service definitions, the `ServiceRegistry` jointly finalized with the role codecs, and activation-revision installation and verification behind `runInstalledServiceProgram`. `Service.Program` holds the closed, effect-indexed `ServiceProgram` a handler returns; its only eliminator demands the signed effect authorization. |
| `HostBootstrap.DocValidator` | The mechanical documentation validator run through the code-check. See [documentation_standards](../documentation_standards.md). |

## Host-Tool Resolution And Substrate Ownership

External tools resolve through the closed `HostTool` enumeration to absolute paths; the
[HostTool module](../../core/hostbootstrap-core/src/HostBootstrap/HostTool.hs) owns the boundary.
`AbsExe` hides its constructor, `mkAbsExe` rejects non-absolute paths, and `absExePath` is an ordinary
accessor that cannot be used in a record update. Managed host effects consume this representation. A
described guest command is resolved in the frame that interprets it; the guest is reached through its
resolved host provider.

`buildHostConfig` measures each tool once and retains its path with the detected substrate.
`resolveInstalled` returns a configured path unchanged, even when the file is no longer present; it
calls `discover` again only when the configuration has no entry, such as after an `ensure` step installs
a missing tool. An unresolved required tool is reported as `UnresolvedTool`, naming the tool before an
invocation is attempted.

A described HTTP command, `hostCommand Curl args`, resolves through the measured `HostConfig`; an
unconfigured `Curl` returns the standard `curl not found on this host` refusal before launch.

At the local frame, Lift keeps raw commands separate from self-reference and lifecycle binaries.
`foldLeafCommand` returns `Either String HostCommand`: an exact registered command name becomes a
`ToolTarget`, while an unregistered name or an absolute raw executable is refused before launch.
Only the local self-reference or lifecycle leaf becomes a `SelfTarget`. Crossed commands still resolve
their outer provider tool; the nested frame interprets its own command names.

On POSIX hosts, `Ghc` and `Ghcup` discovery tries `PATH` before the ghcup install directory:
`$GHCUP_INSTALL_BASE_PREFIX/.ghcup/bin` when configured, otherwise `$HOME/.ghcup/bin`. This allows the
config-free GHC reconciler's refresh to find the recommended default compiler it installs.

Discovery prefers the stable POSIX CUDA symlink before versioned toolkit roots.
`newestToolkitVersions` orders dotted numeric versions across CUDA and MSVC layouts, so `12.10` sorts
ahead of `12.9`. Windows system-tool candidates come from `SystemRoot` plus `System32`, with search-path
fallback; CUDA, LLVM, Visual Studio, and `vswhere` candidates come from `ProgramFiles` and
`ProgramFiles(x86)`. Non-Windows discovery answers `Nothing` for `Wsl` and `Bcdedit`. The two Windows
resolution cases remain in the suite on every gate host and record either the system-folder result or
that refusal.

Resolution is only one of the two axes. § K fixes *which* executable an invocation names; the *shape* of
the invocation — stdio disposition, descriptor inheritance, session, environment, and working directory
— is a separate boundary under
[§ HH](../../DEVELOPMENT_PLAN/development_plan_standards.md), owned by `HostBootstrap.Detached`. A child
that outlives its launcher is where the two axes come apart, and it is the case the boundary is built
for: no module outside it assembles a `CreateProcess` for such a child, the disposition is not a
parameter, and `withDetachedChild` owns the launch rather than the child's lifetime. The seal binds
cooperating code in this repository: the hidden constructors exclude construction through the module, but
they do not bind a caller that depends on `process` directly, so keeping the boundary sealed is a
drift-guard obligation rather than a property the type system maintains on its own. See
[unrepresentable_state](unrepresentable_state.md) for the method and the boundary's own gate.

Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`, `windows-cpu`, `windows-gpu`) is owned by `HostBootstrap.Substrate`;
its classification core is pure (`classify`, `parseDockerArch`) with a thin IO wrapper for the platform
reads and the NVIDIA probe. The pre-binary host floor belongs to the Python bootstrapper, which asserts it
before the binary exists; after the binary exists, every prerequisite with an install plan is an `ensure`
reconciler dispatched on the classified substrate. See [prerequisites](../engineering/prerequisites.md).

## The Step Algebra And The Project Chain

The core surface a project extends is the `Step` algebra, not a set of noun verbs. A `Step` is a typed,
composable unit the recursive interpreter runs and reports. `hostbootstrap-core` ships the
**host-management step kinds**:

- `deploy-vm` — provision the platform VM (Lima on Apple Silicon, Incus on native Linux, WSL2 on Windows);
- `ensure-X` — a constructor for a reconciler-shaped row (`ensure-ghc`, `ensure-docker`, …); the
  current demo instead calls `runEnsure` inside composite actions;
- `copy-source` — stage project source into the frame;
- `build-pb` — build/install the project binary in the frame (parent-orchestrated, since the child `pb`
  does not exist yet);
- `build-image` — build the project container image;
- `context-init` — a frame-anchor kind intended to own child projection and delivery; its current demo
  action body only announces, though for the container boundary it is the node that declares the descent
  carrying the payload, while the VM projection stays inside the composite bootstrap action;
- `deploy-kind` / `deploy-chart` — cluster and Helm-release lifecycle leaves;
- `expose-port` — settle and verify the exact runtime-owned local exposure for an in-cluster service;
- `post-handoff-<name>` — a named hook built with `postHandoffStep` that runs in an already-declared frame
  after the descent below it completes. Post-handoff steps form a final suffix of the plan, ordered from
  the deepest participating frame back toward the root, and cannot declare a descent.

A project contributes its **own** step kinds (for the demo: `deploy-object-store`, `deploy-registry`,
`push-image`, and accelerator-daemon placement) into the same ordered plan. Host steps and workload steps
interleave freely; `addSteps` appends checked contributions before finalization. This is the
workload-extension seam.

A project's authored forward graph is an opaque `StepPlan`. Its source fragments are pure functions of
project parameters. Structural variation (for example, skipping the VM frame and going straight to a
container) is a branch inside the fragment, not a configuration flag: the demo's `demoChainFor` selects its
root chain from the detected `Substrate` (the direct GPU-container chain on `linux-gpu`, a VM-backed chain
elsewhere) and, in a nested frame, from the provider retained in the validated binary-context topology.
`mkStepPlan` requires every frame that has a successor to declare exactly one descent (`MissingFrameDescent`,
`DuplicateFrameDescent`) and the innermost frame to declare none (`DescentFromInnermostFrame`). It also
rejects empty/duplicate/conflicting plans, non-contiguous frame returns, post-handoff suffixes outside
deepest-to-root unwind order, duplicate or dead reverse declarations, misplaced projected operations, and
invalid provider-resource declarations; `StepPlanError` is the complete list. Every accepted source order is
preserved exactly. Raw `Step`, identity, and plan constructors are hidden.

Trusted admission binds that validated graph to the exact scope, specification, canonical root,
configuration, and fresh `planId`. The public `ProjectPlan` is therefore the executable representation:
its `forward` projection is a `NonEmpty (PlannedStep ...)`, and its `DerivedTopology` is the matching frame
graph. `renderChain` renders the complete admitted `forward` order. The effectful
`runChainFromFrameWithDescentFailure`, the interpreter the hidden `Command.LifecycleEntry` drives, delegates
the frame's one admitted descent to a caller-supplied callback and, on failure, returns the operations whose
durable Prepared gates it published. It accepts no raw `StepPlan`, frame name, or second topology; its `CommandAuthority` and `LifecycleCursor`
share the exact plan, frame, broker generation, `VerbUp`, and `ExecutePhase` indices. It checks their
retained frame/verb/phase terms, the supplied store, and the cursor's retained acquisition
project/store/broker origin against the authority. It then selects the current frame's non-empty nodes and
uses the authority's broker epoch and invocation identity for the operation session. Every node descriptor,
prepared call, and carried resource remains under the same plan indices. The backend-facing
`StepObservation` is plan-independent; `runPlannedStep` immediately wraps it as nominal
`PlannedStepObservation scope planId configId`, and Chain uses only that plan/config-indexed value for
success, detail, and terminal settlement.
Every protected entry rereads the exact acquisition source and current cursor row while holding that
entry, so advancing the retained Execute row to Teardown makes later Chain transitions refuse.

The exact Chain is the **current-frame substrate** of the recursive/fractal interpreter. It asks
`DerivedTopology` whether a descent follows the authorized current-frame segment, and Production hands an
admitted descent to the rooted coordinator rather than treating `HostBootstrap.Lift` as authority. The
recursive-lifecycle-command phase supplies authenticated recursive child authorization and proof-complete
traversal above this substrate; see
[the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).
Managed effects publish their exact unknown and settlement records under the root-owned journal.
Recovery reopens the same plan and operation lineage; uncertain outcomes remain recoverable rather than
being guessed as success. Convenience non-authorizing IO actions do not claim the same idempotence proof.
Every descent is the same fractal pattern
— provision the frame, build/install the `pb` in it, hand off `pb project up` — and the Python
bootstrapper is the metal-frame instance of that exact pattern (see
[python_haskell_boundary](python_haskell_boundary.md)). The model itself, including teardown's
recurse-in-then-stop-on-ascent shape and the `.data`-preserved invariant, is owned by
[composition_methodology](composition_methodology.md); this doc defers there rather than re-deriving it.

## Command-Tree Extension Contract

[`HostBootstrap.CLI`](../../core/hostbootstrap-core/src/HostBootstrap/CLI.hs) exposes the core command tree
as a composable `optparse-applicative` value and a generic project entrypoint. The module's export list and
signatures are authoritative; the operations are:

| Operation | Role |
|---|---|
| `projectSpec` | Starts an unfinished `ProjectSpecBuilder cfg tcfg` from the `TestSuite`, the project `check-code` action, the `ConfigArtifact` delta, the test-config `CodecWitness`, the `InitArgs`-to-`tcfg` test initializer, and the rank-2 restricted config assembler. |
| `addSteps` | Appends one step fragment that receives the admitted `CanonicalProjectRoot` and the scoped config. Required at least once. |
| `addForwardChildPlan` | Installs the project's forward-child projector: from a config, the parent and child frame identifiers, and the `LiftContext`, it returns the child's config path, projected config, and `StepPlan`. Required **exactly once**. |
| `addArtifacts`, `addAssemblyInputs`, `addServices` | Append schema artifacts, the read-only input allowlist of the assembler, and typed service registries. |
| `finalizeProjectSpec` | Validates the builder into an opaque `ProjectSpec cfg tcfg` or returns a `ProjectSpecError`. |
| `runHostBootstrapCLI` | Runs a finalized spec under `ProjectCfg cfg` and `TestCfg tcfg` constraints. |
| `runBareHostBootstrapCLI` | Runs the bare core binary's private specification. |

`TestCfg tcfg` supplies the pure project-owned projection from the executable `[CaseId]` registry and
decoded `tcfg` into an opaque validated `TestMatrix (TestVariant tcfg)`. The config callback therefore
assembles one already-validated draft; it cannot return an empty list or invent/duplicate raw labels.

- `progName` is the project/config name used in help and diagnostics. Before dispatch it must equal the
  normalized actual executable basename (with a Windows `.exe` removed), or the process exits before
  config/lifecycle work. The admitted rank-2 `InstalledProjectIdentity projectId` is then retained through
  Production codec/service/assembler/command construction and every Harness run; the static spec cannot
  choose `projectId`.
- `projectSpec` starts the unfinished builder from the `TestSuite`, project `check-code` action,
  `ConfigArtifact` delta, and project-owned
  init/test-config builders. `addSteps`, `addArtifacts`, `addAssemblyInputs`, and `addServices` append
  without erasure, while `addForwardChildPlan` installs the one child projector, and an `addSteps` fragment receives the admitted canonical-root authority so its
  steps — including the descent each frame declares with `Step.descendsVia` — derive project-relative
  paths from it, and each acquiring step declares the effect that releases it with `Step.reversedBy`.
  Service definitions inseparably bind identity, typed
  projection, role codec, and handler; no separate selector exists.
  The bare core binary uses a separate
  entrypoint (`runBareHostBootstrapCLI`).
- `finalizeProjectSpec` validates the static contributions and refuses an empty test suite, duplicate
  case identifiers, artifacts that shadow core artifacts or repeat, duplicate assembly inputs, a missing
  step contribution (`MissingStepPlan`), a missing or repeated forward-child projector
  (`MissingForwardChildPlan`, `DuplicateForwardChildPlan`), and conflicting service registries.
  Per-config plan projection validates exact non-empty topology and typed identities before an
  interpreter is returned. `runHostBootstrapCLI` accepts only that opaque finalized value, applies
  executable-name validation, checks the [entries before the parser](#entries-before-the-parser), merges
  the spec with the core command tree, and runs the parser.
- Configuration reaches a command by one of three routes. `project up|down|destroy` and `check-code` load
  and admit the sibling `<project>.dhall` once, gated by the command class its binary-context role permits,
  and refuse observed mismatches between the process and the frame the config declares; `context inspect`
  decodes the sibling and `context show [FILE]` the selected file read-only, with no class gate. A lifecycle
  child reads no sibling: its configuration arrives on the authenticated config wire of the
  `--hostbootstrap-lifecycle-child` entry. `service run` reads no full config: it verifies its
  platform-installed activation revision and decodes only the narrowed role wire. `test run` reads the
  sibling `<project>.test.dhall`, and each Harness variant generates its own sibling config.
- The plan, lease, frame, cursor, and complete-context gates are enforced on every effectful lifecycle
  path: the hidden `Command.LifecycleEntry` joins them before any root effect, and
  `runChainFromFrameWithDescentFailure` rereads the acquisition and cursor rows inside each protected
  transition.

A project binary contributes a chain value plus extension streams, never its own verbs. Its `Main.hs`
attaches the chain (interleaving core and project step kinds) to the spec and hands it to the entrypoint:

```haskell
import HostBootstrap.CLI
  ( addForwardChildPlan, addServices, addSteps, finalizeProjectSpec, projectSpec
  , runHostBootstrapCLI )
import HostBootstrap.Substrate (detect)
import HostBootstrapDemo.Commands
  (demoArtifacts, demoChainFor, demoCheckCode, demoForwardChildPlan, demoServices, demoTestSuite)
import HostBootstrapDemo.Config (demoAssemble, demoTestInit, testConfigCodec)
import System.Exit (die)

main :: IO ()
main = do
  -- Detect the host substrate once so the root chain selects its frame shape.
  substrate <- detect >>= either die pure
  let builder =
        addForwardChildPlan demoForwardChildPlan
          ( addSteps (demoChainFor substrate)
              ( addServices demoServices
                  (projectSpec demoTestSuite demoCheckCode demoArtifacts testConfigCodec demoTestInit demoAssemble)
              )
          )
  spec <- either (die . show) pure (finalizeProjectSpec builder)
  runHostBootstrapCLI "hostbootstrap-demo" spec
```

This is the core of [`demo/app/Main.hs`](../../demo/app/Main.hs). The shipped file additionally line-buffers
its output, wraps the ordinary command in `withForwardedRegistryAuth`, and intercepts the demo's own
pre-parser entry (see [Entries before the parser](#entries-before-the-parser)).

The bare `hostbootstrap` binary uses the dedicated bare entrypoint:

```haskell
main :: IO ()
main = runBareHostBootstrapCLI "hostbootstrap"
```

This guarantees the **parser tree and command names** are shared, not that bare and project behavior is
identical. `runBareHostBootstrapCLI` uses the private specification in `HostBootstrap.CLI.Bare`: an empty
service registry, no project artifacts, a `check-code` that only prints that the bare binary has no project
checks, and a forward-child projector that refuses. Its Production plan is empty, so a bare `project up`
refuses at plan admission (`EmptyStepPlan`). Its Harness plan is one `deploy-kind` step whose declared
reverse is `clusterDelete`, exercised by the single compiled `cluster-live` case: a bare `test run all`
creates a run-scoped Kind cluster, asserts on it, and deletes it, so it needs Docker, Kind, and Kubectl and
changes host state. A project binary supplies an opaque finalized `ProjectSpec`; its plan, test seams, typed
services, schema artifacts, and cleanup make those same routes useful. Exact plan, resource, and lifecycle joins
validate those contributed relationships before effects.

Both entrypoints end a refused `project init` assembly through `die`: the original refusal is printed to
standard error and the process exits with status 1 before config publication. The bare path does not turn
that `Either` refusal into an `IOError`. [CLISpec](../../core/hostbootstrap-core/test/CLISpec.hs) checks the
bare entrypoint under real arguments with an incompatible added role and verifies that no output is
published.

### Surfaced commands

This table is the canonical inventory of verbs and flags. `project down` and `project destroy` take no
flags, the only global option is `--help`, and a bare invocation prints the help text.

| Command | Behavior |
|---|---|
| `context inspect\|show\|schema\|render\|path` | Read-only introspection: `path`, `schema`, and `render [--artifact NAME]` are static and config-free, and `path` prints the canonical filename `<project>.dhall` rather than a path; `inspect` reads the executable's sibling `.dhall`, while `show [FILE]` reads the selected file, whose default `<project>.dhall` resolves against the current directory. |
| `project init` | Config-free initializer. Its no-flag default writes the root host-orchestrator config to the executable's sibling `<project>.dhall` and leaves an omitted `--source-root DIR` to the project assembler; a relative root resolves against the config's anchor directory. The shared `InitArgs` parser accepts `--output FILE` (`-o`), `--role ROLE` (default `host-orchestrator`), repeatable `--also-role ROLE`, `--source-root DIR`, `--dockerfile PATH`, `--cpu N`, `--memory TEXT`, `--storage TEXT`, and `--ha-replicas N`, interpreted by `psAssemble (ProductionAssembly args)`; core supplies no default for any omitted value. Role additions are checked by `roleAdditionAllowed`/`addRole`. `--force` and `--if-missing` are mutually exclusive spellings of one `ExistingOutputPolicy`: `--force` overwrites, `--if-missing` leaves an existing output untouched, giving both fails to parse, and with neither an existing output is refused. Root identity provisioning (see the TL;DR) follows the existing-output decision and depends only on the parsed `--role` equalling the default `host-orchestrator` and the output resolving to the executable's sibling `<project>.dhall`, not on a write: `--if-missing` over an existing sibling still installs or validates the identity, while the refusal with neither flag exits before it. |
| `project up` | Resolve and interpret the exact root plan; the operator entry refuses a non-root frame. `--dry-run` renders the admitted plan with `renderChain` and skips the installed-identity check and execution, but it takes Production mode authority first (see [Current Status](#current-status)). Both the fresh and the recovered root entry hold a finalized specification at the exact index their plan retains — the recovered one is relabelled by the digest-proven join rather than re-finalized — and each refuses before any lifecycle effect if that specification is not the bound plan snapshot's. Effectful Production admits root-only, store-bearing `ValidatedLifecycleContext`; a Cabal-hidden root-Up entry owns the one store, lease/snapshot/acquisition, and root cursor, then constructs the recursive catalog. Nested processes enter only as `FrameExecutor`s over closed rooted requests/responses. The root prepares exact keys, signs grants, settles returned observations, and records receipt confirmation. Convenience IO actions report completion only; prepared managed adapters provide exact idempotence and ownership observations. |
| `project down` | Retain or reconstruct one exact Production plan and drive its `StopFrame` reverse projection child-first through authenticated nested entries, preserving durable roots/provider frames and deleting an owned Kind cluster because Kind has no stopped state. The pure projection is not exact command authority; the rooted coordinator supplies exact descent authority and receipt-bound settlement. See [durable_state](durable_state.md). |
| `project destroy` | Retain or reconstruct one exact Production plan and drive its `DeleteFrame` reverse projection child-first through authenticated child-to-parent interpretation, exact teardown authorization, and receipt-bound ownership. Host `.data` is carried outside provider disks. Harness restart-spanning cases use the same reverse driver internally, require settled destroy, rotate to a protected fresh invocation, rebind the exact snapshot, and forward again without exposing lifecycle IO to assertions. |
| `test init [--replace]` | Needs **no** pre-existing `<project>.dhall`; writes `<project>.test.dhall` from the project's test initializer. An existing `<project>.test.dhall` is refused unless `--replace` is given, which overwrites it. In the demo it contains resource overrides plus declarative variant names/messages; compiled Haskell still owns case bodies and lifecycle-free assertions. |
| `test run <case-id>\|all` | Needs `<project>.test.dhall`; `all` runs the compiled matrix and a case id selects one compiled case. Each variant is assembled as `cfg (Harness projectId runId)` under fresh authority and its matching codec, owns its generated sibling config and project-suffixed protected store, admits one exact Harness `ProjectPlan` and root lifecycle context, and enters its forward action only through the hidden fixed root-Up `LifecycleEntry`. It then runs assertion-only cases and interprets the retained exact reverse projection. An `AssertAcrossRestart` case places its two assertion phases around an engine-owned settled destroy, fresh same-run invocation generation, exact snapshot rebind, and second forward. Settled destroy evidence is required before terminal Harness close. |
| `service init\|schema\|run` | Run a long-running role. `init` takes the same flags as `project init` with default role `cluster-service`, and never installs root identity. `schema` prints the full schema plus distinct Production/Harness role-wire families (including structured empty families). `run` takes no arguments and does not open the sibling full config: it reads absolute platform-installed revision/key/store coordinates from `HOSTBOOTSTRAP_SERVICE_ACTIVATION`, `HOSTBOOTSTRAP_ACTIVATION_KEY`, and `HOSTBOOTSTRAP_AUTHORITY_STORE`, hashes its own executable and the installed role/private bytes, verifies the signed activation and concrete pod-restart or host-invocation identity, decodes only the narrowed role wire, consumes or exactly reopens the one-use request-indexed role plan, authorizes its declared effect row, and interprets its closed `ServiceProgram` inside Serve with Ready's exact handles. No `service down`. |
| `check-code` | Loads and admits the sibling `<project>.dhall` under the check-code command class, then runs the project's fail-fast code-check action. In an image-build container frame it first verifies the signed build invocation delivered through the build secrets and authorizes the check against it. |

`project up` and `test run` consume the same plan/step representation, not a separate Harness selector.
Production and each separately scoped Harness variant first admit their exact root lifecycle context, then
the hidden fixed root-Up entry derives their journal/cursor/command authority and invokes the lower
current-frame Chain; neither command constructs or projects those values directly. Production refuses
nested entry. Harness retains the matching reverse projection around assertions rather than shelling
`project up`. The lifecycle-entry constructor, producer, and retained evidence are private, so assertions
cannot replace either action or turn a descriptive config into lifecycle authority.
`project up` interprets the plan to stand up the persistent deploy stack and ends at a live webservice
(`service run`) at the exact runtime-resolved loopback endpoint; its typed request already
contains the assembled `message`, so the handler does not reopen config. `test run all` directly runs the
corresponding Harness-scoped current-frame forward plan once per config variant (the demo runs
two), asserts the live stack (the SPA `#message` polymorphic over the active `EXPECTED_MESSAGE`), using
the exact Harness profile. The durable case uses the engine-owned same-run destroy/up transition; see
[harness workflow](harness_workflow.md).

### Entries before the parser

`runCLI` in `HostBootstrap.CLI` reads the argument vector once and tests it against the entries below, in
this order, before `optparse-applicative` runs. Only an argument vector that matches none of them reaches the
parser. Each entry is absent from `--help` because none is in the command tree. The same `runCLI` serves
`runHostBootstrapCLI` and `runBareHostBootstrapCLI`, so every binary carries all six core entries.

| Argument vector | Owner | Launched by | What the vector carries | Action |
|---|---|---|---|---|
| exactly `--hostbootstrap-install-identity` (`installedIdentityEntryArguments`) | `HostBootstrap.Identity.Install` | the Python bootstrapper, after it installs a newly built binary | nothing | `provisionInstalledIdentity` for the running executable's path |
| `__hostbootstrap-exposure-relay-v1` followed by one or more groups of service, listen port, target host, and target port (`runExposureRelayEntry`) | Cabal-hidden `HostBootstrap.Cluster.Exposure.Internal` | `HostBootstrap.Cluster.Backend`, as the command of the identity-labelled relay container on the `kind` network | caller-selected relay targets, validated for distinct services and listen ports; a malformed vector refuses instead of falling through to the parser | runs the TCP relay |
| `--hostbootstrap-working-directory-entry` followed by directory, executable, and arguments (`workingDirectoryEntryArguments`) | `HostBootstrap.Effect.Run` | the bounded runner on macOS, relaunching the current executable | absolute working directory and executable plus the exact argument vector; the runner supplies the complete environment | changes directory and execs the executable without an intermediate shell; malformed entry exits 126; refused on Windows |
| exactly `__hostbootstrap-colima-command-transaction-v1` (`shippedCommandEntryArguments`) | private `colima-backend-internal` sublibrary, `HostBootstrap.Ensure.Colima.Backend.Runner` | the binary itself, relaunched by the Colima backend's bounded runner | nothing on the vector; the absolute executable and its arguments arrive encoded on standard input | runs that one command in its own process group until the launcher's standard input closes; refuses on Windows |
| exactly `--hostbootstrap-lifecycle-child` (`lifecycleChildArguments`) | `HostBootstrap.Command.Child` | the rooted lifecycle process route, for one authenticated forward or reverse descent | nothing; project, scope, verb, plan, frame, and every coordinate arrive through the authenticated Offer or a root-signed response | the storeless `FrameExecutor` described in the `Command.Child` row |
| exactly `--hostbootstrap-frame-child` (`classifyFrameChild`) | `HostBootstrap.Handoff.Transaction` | the lift fold, for one frame-crossing transaction | nothing | answers one opaque transaction; see [The frame-child entry](#the-frame-child-entry) |

These six are the closed set
[development_plan_standards.md § P](../../DEVELOPMENT_PLAN/development_plan_standards.md) admits; a seventh
entry is a change to § P, not to a module. A project adds no pre-parser entry: an argument vector a
project's own `main` intercepts before it calls `runHostBootstrapCLI` is a per-project verb under § P, and
core neither sees nor bounds it. The demo departs from that once: `demo/app/Main.hs` routes exactly
`--hostbootstrap-direct-cluster-release-v1 PROFILE` to `runDirectClusterReleaseChild`, which the Direct
lane's own declared cluster reverse launches inside the project image to release a retained direct (nvkind)
cluster for the closed `production` or `harness:<run>` profile, and it refuses the marker with any other
argument count. The [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) deletes this entry
and releases the Direct cluster through the authenticated reverse child instead; see
[Current Status](#current-status).

Every core entry matches the whole argument vector or nothing and opens no route to a `ProjectSpec`
extension stream. The identity, lifecycle-child, and frame-child entries carry nothing on the vector: no
coordinates, no path, no authority, and no caller-selected action. The exposure relay and the Colima command
transaction carry caller-selected work (relay targets, a command to run), and § P admits both because their
launcher confines that work. Only `HostBootstrap.Cluster.Backend` writes the relay targets, as the relay
container's command, and only the Colima backend's bounded runner writes the command onto the transaction's
standard input. Both owners are Cabal-hidden or private-sublibrary modules that no project imports, so no
project and no operator selects that work.

### The frame-child entry

The command surface is fixed and closed, and it is also not the only way a process of this binary can
be started. A recursive lifecycle crosses into a VM or a container by launching *this binary* over
there, and the process that arrives has no environment, no descriptor it can name, and no coordinate
telling it which frame it woke up in — it has an argument vector and two streams.

So `runCLI` reads that argument vector once, before the parser, and (after the other core entries in
[Entries before the parser](#entries-before-the-parser)) hands it to the total pure classifier
`classifyFrameChild`. The classifier answers whether this process is the far side of a frame crossing, and what
it returns carries nothing: no path, no authority, no caller-selected action, and no route to a
project's extension streams. A frame child is a frame child regardless of which spec built the binary,
so `runBareHostBootstrapCLI` and `runHostBootstrapCLI` reach the entry by the same route.

The marker is the whole argument vector or it is nothing — a marker with anything before or after it,
a different spelling, or a different case is an ordinary invocation. It is absent from `--help` because
it is not in the command tree at all, and a process launched with it refuses unless its standard input
and output are the protocol channel, which outside a crossing they are not. It is therefore not a
hidden command: nothing an operator can usefully type reaches it.

What travels across the crossing is one opaque transaction out and one opaque outcome back, framed by
the same magic, version, tag, and request identity as every other message on the handoff channel. The
near side folds the lift context to the invocation that crosses the frames, launches the child into its
own process group with the protocol on private pipes and diagnostics inherited, sends one transaction,
reads one answer, and then ends the group — on a returned outcome, a refusal, a protocol failure, an
exception, or asynchronous cancellation alike. Ending the group rather than the process is what makes a
shell or provider the child launched go away with it. The platform rows live in the private
`HostBootstrap.Effect.ChildGroup` (the `effect-internal` sublibrary), shared with `HostBootstrap.Handoff.Process`,
so `HostBootstrap.Handoff.Transaction` carries no platform conditional. On POSIX hosts the row signals the
child's process group, waits a grace, then kills the group. The Windows row terminates only the launched
process; the target row is a kill-on-close Job Object that ends the whole tree (see
[Current Status](#current-status)).

The bytes are interpreted by whichever phase owns the object the transaction concerns, never by the
transport. A frame that has no interpreter installed answers a refusal rather than falling silent, so
the near side learns that the far side declined instead of inferring it from a closed pipe.

## Consumption

The in-repository demo consumes `hostbootstrap-core` as a sibling local package. A remote consumer uses
a `source-repository-package` and must supply a full immutable commit in its `tag` field; the governed
template in [derived project standards](../engineering/derived_project_standards.md) makes that pin
explicit. The rolling base image warms a best-effort Cabal store; matching artifacts are reused
opportunistically and ordinary cache misses may resolve/download/build compatible dependencies.
See [base_image](../engineering/base_image.md) and [warm_store](../engineering/warm_store.md).
