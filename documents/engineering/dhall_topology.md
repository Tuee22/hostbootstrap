# Dhall Topology

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [schema](schema.md), [resource_budgeting](resource_budgeting.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [binary_context_config](../architecture/binary_context_config.md)

> **Purpose**: Define how the topology frames in a binary's sibling `<project>.dhall` drive the recursive
> `project` chain — frames are parameters and a witness contract, never the chain shape — and how each
> project binary checks its declared frame before acting, while independent installed or authenticated evidence supplies authority.

## TL;DR

- The plan shape is **code**: ordered step fragments are finalized into an opaque validated `StepPlan`
  owned by the project binary. The current-frame Chain (see
  [composition_methodology](../architecture/composition_methodology.md)) interprets each frame's exact
  segment; recursive `project up` traverses authenticated child entries. The shape is not in any `.dhall`.
- `.dhall` carries **parameters + context + witness**, never the shape. The sibling `<project>.dhall`
  parameterizes the chain (budgets, ports, replicas, optional structural flags) and declares the
  topology frame the binary occupies. "Frame" on this page is the topology sense of the
  [glossary](../README.md#glossary).
- The `topologyFrames` list (frames plus parent references) is the **map of the recursive descent**:
  each frame is one segment of the `project up` chain, and the same data names where every binary copy
  sits in that descent.
- Each binary copy validates the complete topology graph, requires the exact closed witness set for its
  placement, and checks those witnesses against the runtime. Missing/extra/duplicate witnesses,
  duplicate/cyclic/disconnected graphs, and an inconsistent `parentChain` fail closed. The fields remain
  constructible descriptive data rather than command authority; effectful gates independently admit them.
- Children never reach back to read the parent's host file. Frame child configs adjust descriptive
  context while retaining the full demo project record and parent resource envelope. A service reads
  only the narrowed role wire sealed into its signed activation, although the demo still delivers the
  full-record service `<project>.dhall` beside it. Projection/delivery is split across composite
  bootstrap, the descent the `context-init` node declares plus the handoff, and workload deployment
  actions; that action's body is only an announcement.
- [composition_methodology](../architecture/composition_methodology.md) is the canonical home of the
  chain / recursive-interpreter / fractal-bootstrap model; this document defers to it and describes only
  the Dhall side.

## The Chain Is Code; The Dhall Is Parameters

The recursive forward ordering, each frame's declared descent, and each step's reverse effect are one
opaque validated Haskell `StepPlan`; the sibling `<project>.dhall` does not encode that plan. There is no
separate teardown callback: each acquiring step carries its own reverse effect (`reversedBy`), and exact
admission turns the plan into the opaque `ProjectPlan scope specDigest planId configId cfg` whose forward
and reverse projections come from that one representation (see
[composition_methodology](../architecture/composition_methodology.md)). The Dhall supplies three things
and nothing more:

| Concern | What it carries | Used for |
|---|---|---|
| **Parameters** | project/user settings: Dockerfile path, resource budget, ports, HA replicas, feature flags, and any optional structural flag (e.g. skip the VM and go straight to Docker) | inputs to the step fragments passed to `addSteps`, so the chain stays a pure function of root params |
| **Context** | the topology frame the binary occupies: `topologyFrames`, `currentFrame`, and declared command/capability/resource context | naming the binary's segment of the recursive descent |
| **Witness** | locally checkable runtime witnesses for the current frame | proving the process is actually in the frame it claims |

Because optional structural variation is a root-`.dhall` flag rather than a different file shape, the
chain remains a pure function of root parameters. The `.dhall` never becomes a second representation of
the chain.

## Topology Frames Drive The Recursive Chain

The local config carries a declared picture of the composed topology, and the binary validates that
declaration as one complete graph before any command is authorized (see
[Each Binary Checks Its Frame](#each-binary-checks-its-frame)). The common shape is:

```text
topology.frames       provider-backed nodes such as host, Lima/Incus VM, Docker container, cluster, pod
topology.currentFrame the frame this process claims to occupy
context               the declared command/capability/resource context for that current frame
witnesses             local checks that prove the process is actually in that frame
```

The `topologyFrames` list — frames plus `topologyParentId` references — is the map of the recursive
descent. Each frame is one segment of the `project up` chain: the root interprets its own frame's steps,
then launches the next frame's binary copy through the authenticated handoff route. The child verifies
the root-signed scope capsule against its independently installed identity, decodes and validates the
exact config bytes the authenticated Offer carries for its frame, checks that its local frame matches the
authenticated child frame, and only then executes the root-granted nodes of its segment. The protocol is
canonical in
[binary_context_config § Per-Frame Fail-Fast On Handoff](../architecture/binary_context_config.md#per-frame-fail-fast-on-handoff).
The frame list is open-ended, so a project represents
`host -> VM -> container -> kind cluster -> pod` or any other provider-backed descent without the core
library learning every provider in advance. The core checks the common frame graph and command gate;
higher layers add provider payloads and witness checks.

This is the data behind the file-reading part of the read-only `context` command: `context inspect`
renders the global lift composition — `topologyFrames` / `parentChain` — with the current frame
highlighted, and `context show` decodes a selected project-local config. The other routes are static:
`path` prints the canonical filename, `schema` prints the separate in-scope `ConfigArtifact` registry,
and `render` prints static artifact examples. The validated-codec project-local `cfg` shape belongs to
`service schema`, not `context schema`. The subcommands and their flags are canonical in
[hostbootstrap_core_library § Surfaced commands](../architecture/hostbootstrap_core_library.md#surfaced-commands).

## Each Binary Checks Its Frame

The frame list says where the descent goes; witnesses describe local placement evidence. Before any
command is authorized, `validateContext` in `HostBootstrap.Context` checks the decoded context in this
order:

1. The project and binary names match, and `currentFrame` names a declared frame of the context's kind.
2. `validateTopology` proves the frame list is one graph: non-empty unique frame identifiers, every
   non-root parent resolvable, exactly one root, no cycle (every traversal carries a visited set and
   terminates), every frame reachable from the root, each child kind legal under its parent's kind, each
   frame's provider legal for its kind, and a declared `parentChain` that agrees with the edges.
3. `checkWitnessSet` requires the exact closed witness set the placement derives: a witness duplicated
   by kind and name (including a contradictory pair) refuses with `ContextWitnessDuplicate`, and a
   missing or unexpected witness refuses with `ContextWitnessSetMismatch`.
4. The requested command class is both declared and admitted by the validated placement, and the
   required capabilities and ancestors are present.

`validateRuntimeContext` then verifies every member of the placement-derived witness set against the
real local environment, so a false witness fails fast. Missing, duplicate, irrelevant, contradictory, or
false evidence cannot produce a validated context.

Per-frame checks reject known placement and witness mismatches. Descriptive context remains data, not
authority: installed root, authenticated handoff, or verified activation evidence supplies the command's
capability, and its plan/frame join must agree with the decoded description. A baked image-build config
cannot authorize a VM-scoped lifecycle merely because a Docker daemon is reachable.

- **WRONG**: bake `/usr/local/bin/<project>.dhall` with VM-project-container authority and then rely on
  `docker run <image> project up` to work from any host. This is wrong because it silently makes the
  current Docker daemon authoritative and can create a kind cluster outside the VM the topology intended.
- **RIGHT**: bake only an image-build config for Dockerfile-time gates. Use the lifecycle's trusted
  projection/delivery seam to stream a child config in-place into the exact frame it launches, and have
  the child verify its witnesses before dispatch. That trusted seam is split across the plan nodes
  described below.

## Generated Child Configs

When `project up` crosses a frame boundary, the demo obtains the next local config through
different seams. The composite `build-pb` action derives/streams the VM config; the descent the
`context-init` step declares carries the container payload and the handoff streams it in-place over
`stdin`; service and daemon deployment actions render ConfigMaps. The `context-init` action body itself
prints only an announcement. VM/container children write the payload at their own sibling path before dispatch, with no
config bind-mount.

Frame projection narrows descriptive context and allowed commands for a named child frame and includes
the supplied local witnesses, but it is not a least-privilege parameter projection: a VM, container,
service, or daemon child config is the full demo `ProjectConfig` with an adjusted context, retaining the
host Dockerfile/deploy knobs and the parent's full raw resource envelope. The locally calculated cluster
slice is not carried into those child configs. Children do not reach back to read the parent's host file.

A service leaf receives two artifacts:

| Artifact | Contents | Delivered by | Read by |
|---|---|---|---|
| Narrowed role wire | the selected role's parameters in a sealed framework envelope, inside the signed digest-addressed activation revision | deployment, which projects the leaf config and installs the activation | `service run`, through `withDecodedServiceProgram`, which never receives the full project configuration |
| Full-record service `<project>.dhall` | the full demo project record with the leaf's service or daemon context | the web chart's ConfigMap (rendered from its `serviceConfig` value) or the accelerator daemon manifest's ConfigMap | not consulted by `service run` for the role it runs |

The role wire is the service's authority (see
[binary_context_config § Config Snapshot And Daemons](../architecture/binary_context_config.md#config-snapshot-and-daemons)).
The full-record file still carries the host Dockerfile, deploy, and resource inputs: the demo
`ConfigSpec` case "child projections preserve project settings and narrow authority" asserts that a
cluster-service child keeps the host `deploy` value, and no test asserts that a service leaf config
excludes Docker-build, VM-orchestration, or host deploy inputs. See
[config_generation](config_generation.md) for the projection seams and
[Current Status](#current-status) for the gap.

- **WRONG**: make a service pod read the host's `<project>.dhall` directly so it can see fields such as
  replica count or image tag. This is wrong because it leaks host-level authority and couples a child to
  a parent file path.
- **RIGHT**: the parent validates one immutable config snapshot, projects the leaf, and installs a signed
  activation whose narrowed role wire is the only configuration `service run` decodes.

## The Configuration Set

| Config | Shape | Produced by | Read by |
|------|-------|-------------|---------|
| Local runtime `<project>.dhall` | Project parameters plus the current topology frame (context + witness) | Written by `project init` (host root, default role `host-orchestrator`) or `service init` (default role `cluster-service`; it shares `project init`'s flags and `ExistingOutputPolicy` and never installs root identity); for children, produced by the bootstrap/plan-declared-descent/deployment seams; edited by the user only for host-level settings | The project binary before normal command dispatch |
| Generated child `<project>.dhall` | Full project record with an adjusted child context | Demo: composite VM bootstrap, the plan-declared descent plus handoff, or workload deployment (see [config_generation](config_generation.md)) | The child binary copy; a service reads its narrowed role wire instead |
| Narrowed role wire | The selected service role's parameters in a sealed framework envelope | Service deployment, inside the signed activation revision | `service run` |
| Rich project/deploy Dhall | Runtime/deploy records composed from the reusable vocabulary | The project binary | The project binary |
| Project test Dhall | One project-owned test value containing resource/variant inputs; compiled Haskell currently owns case identities | `test init` | The project binary / test harness |

The host-root and child configs share one **canonical location**: the executable's sibling
`<project>.dhall` (`siblingProjectConfigPath` — e.g. `.build/<project>.dhall` beside the host binary). The
host root is written and read at that one path, and each descent mints its child at the same sibling rule in
its own frame. The values a config carries are the project's own: core owns no defaults. Current
`psAssemble` is the sole default-bearing project-config assembler for Production init and Harness
variants; `test init` follows the separate `psTestInit` path because it creates `tcfg`. Demo child and
service projection copies the assembled web ports and accelerator timeout from the parent config and
supplies no fallback values. The on-disk config is a complete value the project (not core) defines.

## Rich And Test Dhall

The rich project/deploy Dhall and the project-owned test Dhall are artifacts the project binary emits,
along with their schemas. `hostbootstrap-core` owns the reusable vocabulary and the context spine;
project-specific rich schemas are generated by the project binary. Test Dhall belongs to the
`test` surface — `test init` writes `<project>.test.dhall`, and `test run <case-id>|all` consumes its
typed resource override while selecting compiled Haskell cases
(see [testing](testing.md)). This keeps a single canonical home per concern: in the project
config/lifecycle path Python owns only pre-binary build mechanics, the local `<project>.dhall` owns the
binary's current frame and parameters, and the rich and test artifacts are owned by the project binary.

## Current Status

The project binary owns default local config generation (via `project init`), pure child projection
helpers, and command gating through the sibling `<project>.dhall`. Runtime configs carry provider-backed
`topologyFrames`, a `currentFrame`, and locally checked witnesses. The binary validates the whole graph and
the exact required-witness set before command side effects. These fields are descriptive rather than
opaque authority. The demo's chain function is `demoChainFor` in
`demo/src/HostBootstrapDemo/Commands.hs`, contributed through `addSteps` and interpreted by `project up`;
the demo adds no verbs. Recursive `project up` crosses frames through the authenticated handoff, and
`project down` / `project destroy` reverse the same plan child-first. `test run all` retains one exact
Harness plan per config variant and wraps forward and reverse interpretation around assertions; it does
not shell `project up`.

One gap remains: every generated child `<project>.dhall`, including the service and daemon leaf files the
demo delivers by ConfigMap, is the full demo project record with an adjusted context rather than a
least-privilege projection, and the locally calculated cluster slice is not carried into it. A service's
authority does not depend on that file, because `service run` decodes only its narrowed role wire.
[The worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owes the delivered service and
daemon leaf `<project>.dhall` two things: carrying the leaf's own partition slice, and one projection that
states which parent fields a leaf keeps. See
[composition_methodology](../architecture/composition_methodology.md) for the model and the
[development-plan status table](../../DEVELOPMENT_PLAN/README.md) for phase status.

## Validation

`cabal test all` from `core/` runs `ContextSpec`, whose graph-validator cases refuse a cyclic parent
chain, a cycle below a real root, duplicate frame identifiers, two roots, an unreachable frame, an illegal
child kind, and a `parentChain` that disagrees with the edges; its witness cases prove that a placement's
required witness set is exact, that runtime validation verifies the derived set rather than the declared
one, and that a wrong-frame witness fails before dispatch. `cabal test all` from `demo/` runs the demo
`ConfigSpec` child-projection cases, including "child projections preserve project settings and narrow
authority" (frame and service children keep the parent's Dockerfile, deploy, resource, and service
settings while their context narrows) and "child projection rejects direct host-to-runtime-container
configs". The host static gate legs are canonical in
[development_plan_standards § JJ](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## See also

- [composition_methodology](../architecture/composition_methodology.md) — canonical home of the current-frame
  Chain, recursive `project up`, and fractal-bootstrap model.
- [config_generation](config_generation.md) — the child-projection/delivery seams.
- [binary_context_config](../architecture/binary_context_config.md) — how a binary decides whether a
  command belongs in its frame.
- [schema](schema.md) — the typed `<project>.dhall` schema, including the topology-frame records.
