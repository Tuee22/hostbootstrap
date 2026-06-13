# Config Generation

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-8-dhall-generation-and-extension.md), [binary context](../architecture/binary_context_config.md)

> **Purpose**: Describe the `ConfigArtifact` registry, the `config schema` and `config render` verbs that emit and materialize it, and the render → decode → re-render round-trip guarantee.

## TL;DR

- `HostBootstrap.Dhall.Gen` defines `ConfigArtifact` — a named artifact carrying a reflected
  `schemaText` and a rendered `renderText` — built by `artifactOf @a name value`.
- `schemaText` is reflected from the Haskell type via the `ToDhall` encoder's `declared` field, so it
  equals the type the `FromDhall` decoder accepts and cannot drift; `renderText` is the `ToDhall`
  embedding of a concrete value.
- `coreArtifacts` is the L0 registry (`budget`, `podResources`, `kindNode`). `config schema` prints
  `schemaUnion` of the in-scope registry (guarded by a committed snapshot); `config render
  [--artifact NAME]` materializes the renders.
- `deployConfigText` renders a deploy config carrying `assert : C.fitsWithin budget pods === True`, so
  an over-budget deploy fails to type-check. In normal binary execution, the budget value comes from the
  active binary-context config rather than a normal-command read of `hostbootstrap.dhall`.
- A render → decode → re-render round-trip is byte-stable.

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

A project binary concatenates its own artifacts onto `coreArtifacts` — the schema-gen stream of the
four-stream extension contract (see [library_hierarchy](../architecture/library_hierarchy.md)). The
reflect-from-decoders versus hand-written-assert split is described in
[dhall_generation](../architecture/dhall_generation.md).

## `config schema`

`config schema` prints `schemaUnion` of the in-scope artifacts — the transitive union of the
registry's schemas, each labelled by name:

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

The output is guarded by a committed snapshot at
`core/hostbootstrap-core/test/golden/config_schema.dhall`. A decoder-type change that is not
re-snapshotted fails the golden diff, so the printed schema and the committed contract stay in
lock-step.

## `config render`

`config render [--artifact NAME]` materializes the registry's renders. With no flag it renders every
in-scope artifact; `--artifact NAME` filters to the named one. Each render is the `renderText` of the
artifact — the `ToDhall` embedding of its canonical value.

The rich deploy tier is rendered by `deployConfigText coreImport budget pods`, which composes a budget
and a concurrent pod set into a config carrying the budget assertion. The budget is seeded from the
static bootstrap input, then carried by `project-binary-context-config.dhall` in normal binary execution:

```dhall
let C = <coreImport>
let budget = { cpu = 4, memory = 8, storage = 20 }
let pods = [ … ]
in  { budget = budget
    , pods = pods
    , _fitsBudget = assert : C.fitsWithin budget pods === True
    }
```

`coreImport` is the Dhall import text for `Core.dhall` — an absolute path in tests, a bundled path in
a deployed binary. Because the assertion is part of the rendered config, Dhall checks it at evaluation
time:

- **WRONG**: render a deploy config and rely on a separate runtime check to reject over-budget pod
  sets. This is wrong because nothing stops the over-budget config from being evaluated and consumed
  before that check runs — the budget is not enforced at the config's own boundary.
- **RIGHT**: embed `assert : C.fitsWithin budget pods === True` in the rendered config, so an
  over-budget pod set makes the config itself fail to type-check at Dhall evaluation and never
  produces a value. See [resource_budgeting](resource_budgeting.md) for the budget the assertion
  guards.

## The Round-Trip Guarantee

Because `schemaText` is reflected from the same type the decoder accepts and `renderText` is that
type's `ToDhall` embedding, a generated config round-trips byte-stably: render a value, decode it back
through `FromDhall`, and re-render the decoded value, and the two render texts are byte-identical. A
test proves this. The round-trip is the practical guarantee that the generated tier is a faithful
projection of the binary's types — the render and the schema both flow from one source, so there is no
seam where they can disagree. The standards-level statement of the model lives in
[derived_project_standards](derived_project_standards.md) and
[development_plan_standards § P, Q, T, X](../../DEVELOPMENT_PLAN/development_plan_standards.md); the
Dhall tier topology is in [dhall_topology](dhall_topology.md), and the runtime context authority is in
[binary_context_config](../architecture/binary_context_config.md).
