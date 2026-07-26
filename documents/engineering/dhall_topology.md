# Dhall Topology

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [schema](schema.md), [resource_budgeting](resource_budgeting.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [binary_context_config](../architecture/binary_context_config.md)

> **Purpose**: Define how the topology frames in a binary's sibling `<project>.dhall` drive the recursive
> `project` chain — frames are parameters and a witness contract, never the chain shape — and how each
> project binary checks its declared frame before acting, while opaque authority remains an open target.

## TL;DR

- The plan shape is **code**: ordered step fragments are finalized into an opaque validated `StepPlan`,
  owned by the project binary and interpreted recursively by `project up`. It is not in any `.dhall`.
- `.dhall` carries **parameters + context + witness**, never the shape. The sibling `<project>.dhall`
  parameterizes the chain (budgets, ports, replicas, optional structural flags) and declares the
  topology frame the binary occupies.
- The `topologyFrames` list (frames plus parent references) is the **map of the recursive descent**:
  each frame is one segment of the `project up` chain, and the same data names where every binary copy
  sits in that descent.
- Each binary copy checks the selected ancestry and every supplied runtime witness. Checked mismatches
  fail fast, but an omitted required witness, duplicate/cyclic/disconnected graph, or inconsistent
  `parentChain` is not comprehensively rejected. The fields are still constructible data, not opaque
  authority; Phase 15.9 closes both validation and widening/forgery gaps.
- Children never reach back to read the parent's host file, but current child configs are not
  least-privilege projections: they adjust descriptive context while retaining the full demo project
  record and parent resource envelope. Projection/delivery is split across composite bootstrap,
  `psFrameContext`/handoff, and workload deployment actions; the named `context-init` action is only an
  announcer/frame anchor. The target plan gives that operation one owner and emits a role-specific type.
- [composition_methodology](../architecture/composition_methodology.md) is the canonical home of the
  chain / recursive-interpreter / fractal-bootstrap model; this document defers to it and describes only
  the Dhall side.

## The Chain Is Code; The Dhall Is Parameters

The recursive forward ordering is an opaque validated Haskell `StepPlan`; the sibling
`<project>.dhall` does not encode that plan. Current frame-context and teardown callbacks are separate
checked single-assignment contributions,
while the target opaque `ProjectPlan scope specDigest planId configId cfg` derives them from the same validated
representation (see
[composition_methodology](../architecture/composition_methodology.md)). The Dhall supplies three things
and nothing more:

| Concern | What it carries | Used for |
|---|---|---|
| **Parameters** | project/user settings: Dockerfile path, resource budget, ports, HA replicas, feature flags, and any optional structural flag (e.g. skip the VM and go straight to Docker) | inputs to `chain cfg`, so the chain stays a pure function of root params |
| **Context** | the topology frame the binary occupies: `topologyFrames`, `currentFrame`, and declared command/capability/resource context | naming the binary's segment of the recursive descent |
| **Witness** | locally checkable runtime witnesses for the current frame | proving the process is actually in the frame it claims |

Because optional structural variation is a root-`.dhall` flag rather than a different file shape, the
chain remains a pure function of root parameters. The `.dhall` never becomes a second representation of
the chain.

## Topology Frames Drive The Recursive Chain

The local config carries a declared picture of the composed topology. Current validation consumes only
the selected ancestry rather than proving the declaration is one complete valid graph. The common shape
is:

```text
topology.frames       provider-backed nodes such as host, Lima/Incus VM, Docker container, cluster, pod
topology.currentFrame the frame this process claims to occupy
context               the declared command/capability/resource context for that current frame
witnesses             local checks that prove the process is actually in that frame
```

The `topologyFrames` list — frames plus `topologyParentId` references — is the map of the recursive
descent. Each frame is one segment of the `project up` chain: `project up` interprets the current
frame's steps, then hands off `pb project up` into the next frame, where the child copy reads its own
sibling `<project>.dhall` and continues. The frame list is open-ended, so a project represents
`host -> VM -> container -> kind cluster -> pod` or any other provider-backed descent without the core
library learning every provider in advance. The core checks the common frame graph and command gate;
higher layers add provider payloads and witness checks.

This is the data behind the file-reading part of the read-only `context` command: `context inspect`
renders the global lift composition — `topologyFrames` / `parentChain` — with the current frame
highlighted, and `context show` decodes a selected project-local config. The other routes are static:
`path` prints the canonical filename, `schema` prints the separate in-scope `ConfigArtifact` registry,
and `render` prints static artifact examples. The validated-codec project-local `cfg` shape belongs to
`service schema`, not `context schema`.

## Each Binary Checks Its Frame

The frame list says where the descent goes; witnesses describe local placement evidence. Before side
effects, current code finds the first matching `currentFrame`, follows and resolves that ancestry, checks
the requested command declarations, and verifies each supplied witness. A false supplied witness fails
fast. It does not require a kind/provider-specific set, so omission can pass; nor does it reject every
duplicate, cycle, disconnected frame, `parentChain` mismatch, or illegal child/provider/role relation.

The target promotes the draft through a total graph validator with unique IDs, one root, connected
acyclic edges, terminating traversal, exact parent-chain agreement, one reachable current frame, and
legal child relations. A closed required-witness function derives the exact set for each placement;
missing, duplicate, irrelevant, contradictory, or false evidence cannot produce the opaque validated
context.

This per-frame fail-fast catches known placement mismatches during recursive handoff. It is not yet an
unforgeable authority boundary: context/capability constructors and widening paths remain public enough
for a caller to represent a declaration the trusted projection would not mint. A baked image-build config
is not intended to authorize VM-scoped workflows on whatever Docker daemon happens to be reachable; the
target makes that impossible through opaque narrowed capabilities.

- **WRONG**: bake `/usr/local/bin/<project>.dhall` with VM-project-container authority and then rely on
  `docker run <image> project up` to work from any host. This is wrong because it silently makes the
  current Docker daemon authoritative and can create a kind cluster outside the VM the topology intended.
- **RIGHT**: bake only an image-build config for Dockerfile-time gates. Use the lifecycle's trusted
  projection/delivery seam to stream a child config in-place into the exact frame it launches, and have
  the child verify its witnesses before dispatch. Today that trusted seam is split as described below;
  the target seals it as one plan operation.

## Generated Child Configs

When `project up` crosses a frame boundary, the current demo obtains the next local config through
different seams. The composite `build-pb` action derives/streams the VM config;
`psFrameContext` derives the container payload and the handoff streams it in-place over `stdin`; service
and daemon deployment actions render ConfigMaps. The `context-init` action itself prints only an
announcement. VM/container children write the payload at their own sibling path before dispatch, with no
config bind-mount.

Current projection narrows descriptive context and allowed commands for a named child frame and includes
the supplied local witnesses, but it is not a least-privilege parameter projection. The demo reuses its
full `ProjectConfig` at service/daemon leaves, retaining host Dockerfile/deploy knobs and the parent's full
raw resource envelope. The locally calculated cluster slice is not carried into those child configs.
Children do not reach back to read the parent's host file, but their copied payload is still overbroad.

The target role-specific projection contains only the service role, its exact plan/frame resource slice,
and the service settings it needs. Phase 15.9 makes authority/witness narrowing opaque; Phase 9.10 owns
the resource slice; Phase 19.8 removes host-only fields from leaf parameter types. Negative tests prove a
service leaf cannot contain Docker-build, VM-orchestration, or host deploy inputs. See
[config_generation](config_generation.md) for the current split seams and target unified operation.

- **WRONG**: make a service pod read the host's `<project>.dhall` directly so it can see fields such as
  replica count or image tag. This is wrong because it leaks host-level authority and couples a child to
  a parent file path.
- **TARGET**: the parent validates one immutable config snapshot, and its trusted projection/delivery
  operation generates a role-specific service `<project>.dhall` before the service starts.

## The Configuration Set

| Config | Shape | Produced by | Read by |
|------|-------|-------------|---------|
| Local runtime `<project>.dhall` | Project parameters plus the current topology frame (context + witness) | Written by `project init` (host root); for children, produced by the current bootstrap/frame-context/deployment seam or target unified plan operation; edited by the user only for host-level settings | The project binary before normal command dispatch |
| Generated child `<project>.dhall` | Current: full project record with an adjusted child context; target: role-specific parameters plus validated child frame/resource/witness proof | Current demo: composite VM bootstrap, `psFrameContext`/handoff, or workload deployment; target: one plan-authorized projection/delivery operation | The child binary copy |
| Rich project/deploy Dhall | Runtime/deploy records composed from the reusable vocabulary | The project binary | The project binary |
| Project test Dhall | One project-owned test value containing resource/variant inputs; compiled Haskell currently owns case identities | `test init` | The project binary / test harness |

The host-root and child configs share one **canonical location**: the executable's sibling
`<project>.dhall` (`siblingProjectConfigPath` — e.g. `.build/<project>.dhall` beside the host binary). The
host root is written and read at that one path, and each descent mints its child at the same sibling rule in
its own frame. The values a config carries are the project's own: core owns no defaults. Current
`psAssemble` is the sole default-bearing project-config assembler for Production init and Harness
variants; `test init` follows the separate `psTestInit` path because it creates `tcfg`. Demo service
projection still contains fallback values that later finalized role projection must remove. The
on-disk config is a complete value the project (not core) defines.

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
helpers, and command gating through the sibling `<project>.dhall`. The context description is topology-aware:
runtime configs carry provider-backed `topologyFrames`, a `currentFrame`, and locally checked supplied
witnesses. The binary checks selected ancestry and supplied evidence before command side effects, but
whole-graph and required-witness completeness remain Phase 15.9 work. These fields are descriptive and
not yet opaque authority. The core command surface is
`context`/`project`/`test`/`service`/`check-code`, and the demo drives its lifecycle through the recursive
`project` chain — `demoChainFor :: Substrate -> ProjectConfig -> [Step]` in
`demo/src/HostBootstrapDemo/Commands.hs` — interpreted by `project up`. The demo also contributes its
`web` and `accelerator` service variants and its VM/provider IO as chain steps — the surface is fixed, so
it adds no verbs.

The model this document describes is the recursive project plan: opaque `StepPlan`
interpreted by `project up`, with `project init` writing the root config, the current split seams
producing child configs, and `context` providing read-only introspection. A single `project up` on Incus/Linux
stands up the live persistent stack — a cordoned kind cluster, the in-cluster registry, the
project image pushed to that registry, and the web chart pod serving `localhost:30080` — and
`project down` / `project destroy` tear it back down. The topology data and per-frame fail-fast above
are the substrate the chain interpreter builds on. `test run all`
**drives the same `project up`** under a test-written config (one `project up` per distinct test config),
asserts the live stack, and tears it down — it reuses the chain rather than standing up a separate per-case
cluster. Child configs are generated from passed parameters, some **forwarded from the parent** context's
`<project>.dhall`. See
[composition_methodology](../architecture/composition_methodology.md) for the model and
`DEVELOPMENT_PLAN/` for phase status.

## See also

- [composition_methodology](../architecture/composition_methodology.md) — canonical home of the chain,
  the recursive `project up` interpreter, and the fractal-bootstrap model.
- [config_generation](config_generation.md) — current child-projection/delivery seams and the target
  unified operation.
- [binary_context_config](../architecture/binary_context_config.md) — how a binary decides whether a
  command belongs in its frame.
- [schema](schema.md) — the typed `<project>.dhall` schema, including the topology-frame records.
