# Config Generation

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md), [binary context](../architecture/binary_context_config.md)

> **Purpose**: Describe the `ConfigArtifact` registry and the render → decode → re-render round-trip,
> the root `<project>.dhall` written by `project init`, and the child `.dhall` minted by the
> context-init step inside `project up` — the parameters/context/witness the chain consumes, never the
> chain shape.

## TL;DR

- The chain `chain :: cfg -> [Step]` is **code** — it is the project's identity and the single
  representation of the lift sequence. The `.dhall` is **parameters + context + witness**, never the
  chain shape. The canonical home of that model is
  [composition_methodology](../architecture/composition_methodology.md); this doc defers to it and
  covers only how the config text is generated.
- `HostBootstrap.Dhall.Gen` defines `ConfigArtifact` — a named artifact carrying a reflected
  `schemaText` and a rendered `renderText` — built by `artifactOf @a name value`. `schemaText` is
  reflected from the Haskell type via the `ToDhall` encoder's `declared` field, so it equals the type
  the `FromDhall` decoder accepts and cannot drift; `renderText` is the `ToDhall` embedding of a concrete
  value.
- `coreArtifacts` is the L0 registry (`budget`, `podResources`, `kindNode`). A project supplies its
  artifact delta through `ProjectSpec`; the read-only `context` command renders the in-scope registry's
  schemas and static example renders; the reflected project-local `ProjectConfig` schema is printed by
  `service schema`, not `context`.
- `project init` writes the **root** `<project>.dhall` — the host-orchestrator config with no parent
  frame, carrying resource budget and deploy knobs. The **context-init step** inside `project up` mints
  each **child** `<project>.dhall` for the next frame just before the chain hands off into it: it narrows
  the parent config to the child frame and appends that frame's topology and witnesses.
- `deployConfigText` renders a config carrying `assert : C.fitsWithin budget pods === True`, so an
  over-budget config fails to type-check. A render → decode → re-render round-trip is byte-stable.

## The `ConfigArtifact` Registry

`HostBootstrap.Dhall.Gen` is the generation substrate. A `ConfigArtifact` is a named pair of a
reflected schema and a rendered value:

```haskell
data ConfigArtifact = ConfigArtifact
  { artifactName :: Text
  , schemaText   :: Text
  , renderText   :: Text
  }
```

`artifactOf @a name value` builds one:

- `schemaText` is `reflectedSchema @a` — `Dhall.Core.pretty (declared (Dhall.inject :: Encoder a))`.
  Because `declared` is the exact Dhall type the matching `FromDhall` decoder accepts, the schema is
  definitionally the decoder's accepted type and cannot drift from it.
- `renderText` is `renderValue value` — the `ToDhall` embedding of a concrete canonical value.

`coreArtifacts` is the L0 registry:

| Artifact | Type reflected | Sample value |
|----------|----------------|--------------|
| `budget` | `HostBootstrap.Config.Vocab.Budget` | `Budget 4 8 20` |
| `podResources` | `HostBootstrap.Config.Vocab.PodResources` | `PodResources 1 1 1 1 2` |
| `kindNode` | `HostBootstrap.Config.Vocab.KindNode` | `KindNode 4 8 20` |

A project binary supplies its own artifacts in `ProjectSpec`; `HostBootstrap.Command` concatenates them
onto `coreArtifacts` for the inherited inspection surface — the schema-gen stream of the extension
contract (the command surface itself is fixed and is not a stream; see
[library_hierarchy](../architecture/library_hierarchy.md)). The
reflect-from-decoders versus hand-written-assert split is described in
[dhall_generation](../architecture/dhall_generation.md).

## `project init`: The Root `<project>.dhall`

`project init` is the fail-fast bootstrap for the **root** config. It succeeds only for a fresh
host-level binary with no sibling `<project>.dhall`, and writes the host-orchestrator config — the one
frame with no parent:

```sh
<project> project init --cpu 6 --memory 10 --storage 80 --ha-replicas 1
```

The values it writes are NOT core defaults: `project init` calls the project-owned `psInit` to render a
fully-populated config, then layers any flag overrides on top. The flags are optional precisely because
`psInit` already supplies every field — core ships no default config values, so the no-flag invocation
renders the project's own defaults (for the demo, `6/10/80`, `haReplicas = 1`, `docker/Dockerfile`,
`message = "Hello, world!"`). The shared builder lives in one place; see *The Shared Value-Free Builder*
below.

The written config shape carries the Dockerfile path, the editable resource budget, the deploy
knobs, any project-extended field (the demo's `message`), and the root context authority (a single
host-orchestrator frame). The rendered Dhall hoists the
repeated `ContextKind`/`ProviderKind`/`WitnessKind`/`Capability`/`CommandClass` unions into top-level
`let` bindings (`HostBootstrap.Dhall.Hoist`) so the file stays compact and standalone — no imports,
decodable in-process. Optional structural variation (for example, skip the VM and descend straight to
Docker) is a flag on this project config, so `chain cfg` stays a pure function of the project parameters.

The root config is the user's editable surface. The chain reads it once at the top frame; every deeper
frame's config is **derived**, not hand-edited.

## The Shared Value-Free Builder

A single pure builder under `psInit` — `demoInit` (= `demoInitWithMessage demoDefaultMessage`), which
delegates to the value-taking `projectConfigForRole` assembler — is the only place
default config values live. Three callers share it: `project init` (renders the root config, then layers
flag overrides), `test init` (writes the thin `test.dhall` override), and the test harness (generates each
run's `<project>.dhall` via the project-owned `psTestConfig`, which reuses `psInit`). The harness builds
its config **functionally**, by calling that builder in-process — it never shells out to `<project>
project init`. Sharing one builder is what keeps the production config and every test run rendered from the
same defaults (DRY), with no second source of truth.

The on-disk config is normally **absent** after a build: nothing creates it as a side effect of building
the binary, and Python does not initialize or trigger config creation. A normal command fails fast (exit 1)
when its sibling `<project>.dhall` is missing; the config exists only after an explicit `project init` or
after the harness generates one for a run. There is no auto-init backstop.

## The Context-Init Step: Minting Child `<project>.dhall`

Descending into a nested frame requires a child config that proves the binary's new position. That child
`.dhall` is minted by a **context-init step** the chain runs inside `project up`, just before it hands
off `pb project up` into the next frame (the VM, then the project container). The minted projection is
delivered **in-place**: it is streamed into the child frame over the lift's `stdin` channel, and the
descending binary writes it to its own sibling `<project>.dhall` before dispatch — only the narrowed
projection crosses (never the parent's full config), on `stdin` only, with no host-side config file and no
config bind-mount for the VM/container frames (the Kubernetes service pod keeps its ConfigMap override,
§ AA). The same pure generation
code that `project init` uses projects the child from the parent:

- it keeps the project settings the child needs;
- it carries the parent's resource envelope and deploy knobs;
- it appends the child frame to `topologyFrames`, sets `currentFrame` to it, and records the witnesses
  that prove the frame locally;
- it narrows capabilities and allowed command classes so a container/service config cannot represent
  host-only authority.

The descending binary reads its sibling child `.dhall` before dispatch and verifies it is in the frame
that config describes, or fails fast — the per-frame handoff check (see
[binary_context_config](../architecture/binary_context_config.md) and
[dhall_topology](dhall_topology.md)).

- **WRONG**: a parent mints a child config for a frame that is not in the topology, or a child binary
  trusts the config without witnessing its frame. This is wrong because the child could then run
  host-only authority in a container, defeating the per-frame fail-fast that keeps the lift honest.
- **RIGHT**: the context-init step mints a child only for a frame already in `topologyFrames`, and the
  descending binary refuses to act before its local witnesses prove that `currentFrame`. See
  [composition_methodology § Context-Aware Topology](../architecture/composition_methodology.md).

## `context`: Read-Only Inspection

`context` is read-only. It introspects the sibling `<project>.dhall`, renders the global lift
composition (`topologyFrames`/`parentChain`) with the current frame highlighted, and prints the in-scope
registry. It mutates nothing — minting child configs is the context-init step's job inside `project up`,
not a user verb.

The registry surface `context schema` prints is the transitive union of the in-scope artifacts' schemas
(`coreArtifacts ++ project artifacts`), each labelled by name — the reflected project-local
`ProjectConfig` schema is printed by `service schema`, not `context schema`:

```text
-- budget
{ cpu : Natural, memory : Natural, storage : Natural }

-- podResources
{ replicas : Natural
, cpuRequest : Natural
, cpuLimit : Natural
, memoryRequest : Natural
, memoryLimit : Natural
}

-- kindNode
{ cpus : Natural, memory : Natural, storage : Natural }
```

The L0 portion of that schema is guarded by a committed snapshot at
`core/hostbootstrap-core/test/golden/config_schema.dhall`. A decoder-type change that is not
re-snapshotted fails the golden diff, so the printed schema and the committed contract stay in lock-step.
The static example renders `context` materializes are each the `renderText` of an artifact — the
`ToDhall` embedding of its canonical value.

## The Budget Assertion

The rich deploy tier is rendered by `deployConfigText coreImport budget pods`, which composes a budget
and a concurrent pod set into a config carrying the budget assertion. The context-init step seeds the
budget from the root `<project>.dhall`, then carries it through each generated child projection:

```dhall
let C = <coreImport>
let budget = { cpu = 4, memory = 8, storage = 20 }
let pods = [ … ]
in  { budget = budget
    , pods = pods
    , _fitsBudget = assert : C.fitsWithin budget pods === True
    }
```

`coreImport` is the Dhall import text for `Core.dhall` — an absolute path in tests, a bundled path in a
deployed binary. Because the assertion is part of the rendered config, Dhall checks it at evaluation
time:

- **WRONG**: render a deploy config and rely on a separate runtime check to reject over-budget pod sets.
  This is wrong because nothing stops the over-budget config from being evaluated and consumed before
  that check runs — the budget is not enforced at the config's own boundary.
- **RIGHT**: embed `assert : C.fitsWithin budget pods === True` in the rendered config, so an
  over-budget pod set makes the config itself fail to type-check at Dhall evaluation and never produces a
  value. See [resource_budgeting](resource_budgeting.md) for the budget the assertion guards.

## The Round-Trip Guarantee

Because `schemaText` is reflected from the same type the decoder accepts and `renderText` is that type's
`ToDhall` embedding, a generated config round-trips byte-stably: render a value, decode it back through
`FromDhall`, and re-render the decoded value, and the two render texts are byte-identical. A test proves
this. The round-trip is the practical guarantee that the generated tier is a faithful projection of the
binary's types — the render and the schema both flow from one source, so there is no seam where they can
disagree. The standards-level statement of the model lives in
[derived_project_standards](derived_project_standards.md) and
[development_plan_standards § P, Q, T, X](../../DEVELOPMENT_PLAN/development_plan_standards.md); the
Dhall tier topology is in [dhall_topology](dhall_topology.md), and the runtime context authority is in
[binary_context_config](../architecture/binary_context_config.md).

## Current Status

The generation substrate is implemented and exercised: the `ConfigArtifact` registry,
`reflectedSchema`, `deployConfigText` with the budget assertion, the parent-to-child projection helpers,
the union hoisting, the committed schema snapshot, and the round-trip test all run through the canonical
code-check.

The surface that drives them is the recursive lifecycle command: `project init` writes only the root
host-orchestrator config, failing fast on an existing sibling `<project>.dhall`; the parent-to-child
projection runs as the **context-init step** the chain executes inside the recursive `project up`
interpreter, minting each child `<project>.dhall` just before the chain hands off into the next frame
(the VM, then the project container); and `context schema`/`context render` are the ungated read-only
inspection verbs under the `context` command. Child-config **delivery** was refined from
build-then-copy/mount to **in-place streaming** over the lift's `stdin` channel (landed 2026-07-02 — see
[binary_context_config](../architecture/binary_context_config.md) and
[Phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md) Sprint 15.7); minting is unchanged. The topology-aware gate checks the per-frame witnesses on
every descent. The recursive `project up` interpreter and the `[Step]` chain that calls the context-init
step are real-run-validated end-to-end: a single `project up` on Incus/Linux stands up the live
persistent stack and `project down` / `project destroy` tear it back down (see the development plan
[phase 8](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md)).
