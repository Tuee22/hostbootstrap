# Static-Base hostbootstrap.dhall schema

**Status**: Authoritative source
**Supersedes**: the three-execution-model / substrate-keyed / lifecycle `hostbootstrap.dhall` schema (Container/HostBinary/HostDaemon, Cluster/NoCluster, Mounts, force-target)
**Referenced by**: [../README.md](../README.md), [prerequisites.md](prerequisites.md), [base_image.md](base_image.md), [derived_project_standards.md](derived_project_standards.md), [dhall_topology.md](dhall_topology.md)

> **Purpose**: Define the single static-base `hostbootstrap.dhall` the thin Python bootstrapper reads,
> and explain why runtime project-binary context and rich/test Dhall are separate generated artifacts.

## TL;DR

- The repository-root `hostbootstrap.dhall` is **static-base and identical in shape across projects**:
  it carries a `project` name, a `dockerfile` path, and a `resources` budget (`cpu`, `memory`,
  `storage`).
- It is the one configuration the Python bootstrapper reads. Normal project-binary commands read
  sibling `project-binary-context-config.dhall` files instead.
- The rich project-level Dhall (runtime roles plus cluster-bootstrap instructions) and the per-case
  test-harness Dhall are **artifacts emitted by the project binary**, which also emits the schema
  they validate against.
- `HostBootstrap.Config.Schema` remains as the in-process static-base decoder for bootstrap support and
  the explicit `config show FILE` inspection path; normal command dispatch uses the sibling context.

## Top-Level Shape

```dhall
{ project = "app"
, dockerfile = "docker/app.Dockerfile"
, resources = { cpu = 4, memory = "8GiB", storage = "20GiB" }
}
```

The bootstrapper injects the `package.dhall` schema as `H`, so a project may instead write the typed
form `H.config { project = "app", dockerfile = "docker/app.Dockerfile", resources = { cpu = 4, memory
= "8GiB", storage = "20GiB" } }` (lowercase `config`, applied as a function — not `H.Config::{…}`).

| field | type | required | meaning |
|---|---|---|---|
| `project` | `Text` | yes | project (and project-binary) name; the binary is `./.build/<project>` and `/usr/local/bin/<project>` inside the container |
| `dockerfile` | `Text` | yes | project Dockerfile, relative to the project root; declares `ARG BASE_IMAGE`, `FROM ${BASE_IMAGE}`, and the project `ENTRYPOINT` |
| `resources` | `Resources` | yes | the per-project resource budget copied into the generated binary-context config |

### Resources

```dhall
{ cpu = 4, memory = "8GiB", storage = "20GiB" }
```

| field | type | meaning |
|---|---|---|
| `cpu` | `Natural` | whole CPU cores the project may consume |
| `memory` | `Text` | memory budget (binary quantity, e.g. `8GiB` (Gi/GiB both accepted)) |
| `storage` | `Text` | storage budget (e.g. `20GiB`) |

`resources` is consumed first by the Python bootstrapper, which writes the host-level
`project-binary-context-config.dhall`. Project binaries consume the budget through their sibling context
config, not by re-reading `hostbootstrap.dhall`. See [resource_budgeting.md](resource_budgeting.md) for
the budgeting and cordoning contract.

## Why The Schema Is Minimal

The static-base schema deliberately carries **no** substrate, execution-model, lifecycle, mount, role,
or command-allowance information. Substrate (`apple-silicon`, `linux-cpu`, `linux-gpu`) is detected
at runtime by `hostbootstrap-core`; the binary's local role is declared in
`project-binary-context-config.dhall`, not here. There is no `--force-target`, no
`Cluster`/`NoCluster` lifecycle tag, and no `Container`/`HostBinary`/`HostDaemon` model. Every project
builds its container as the code-check gate and always materializes a host binary at `./.build/<project>`
(see [base_image.md](base_image.md) and [derived_project_standards.md](derived_project_standards.md)).

> **WRONG** — declaring a substrate matrix or an execution model in the static-base file
>
> ```dhall
> H.config
>   { project = "app"
>   , substrates =
>     [ H.entry H.Substrate.LinuxGpu (H.cluster (H.Model.Container ...)) ]
>   }
> ```
>
> This is the removed substrate-keyed schema. The Python bootstrapper does not select an execution
> model, so a substrate/lifecycle/model matrix has nothing to read it. Substrate is detected, not
> declared.
>
> **RIGHT** — one static-base value
>
> ```dhall
> { project = "app"
> , dockerfile = "docker/app.Dockerfile"
> , resources = { cpu = 4, memory = "8GiB", storage = "20GiB" }
> }
> ```
>
> The bootstrapper injects the `package.dhall` schema as `H`, so a project may instead write the
> typed form `H.config { project = "app", dockerfile = "docker/app.Dockerfile", resources = { cpu =
> 4, memory = "8GiB", storage = "20GiB" } }` (lowercase `config`, applied as a function — not
> `H.Config::{…}`).

## Runtime Context And Rich/Test Dhall Are Separate

Configuration is typed Dhall with separate bootstrap and runtime concerns; only the first item lives in
this file:

1. **Static-Base `hostbootstrap.dhall`** (this document) — `project`, `dockerfile`, `resources` — read
   by the Python bootstrapper, identical in shape across every project.
2. **Binary context `project-binary-context-config.dhall`** — created during bootstrap or at a nested
   boundary and read by the binary before normal command dispatch.
3. **Rich project-level Dhall** — runtime roles plus cluster-bootstrap instructions — read by the
   project binary. The project binary emits both the schema and the configuration.
4. **Per-case test-harness Dhall** — generated by the project binary, one value per test case.

The runtime tiers are artifacts the project binary produces or receives
(`--create-container-config`, `<project> context create ...`, `<project> config schema`,
`<project> config render`, and the binary's test entrypoint). See
[dhall_topology.md](dhall_topology.md) and
[binary_context_config](../architecture/binary_context_config.md) for the full topology.

## Parsing

The normal path decodes the static-base file in the Python bootstrapper only.
`HostBootstrap.Config.Schema` reads `project`, `dockerfile`, and `resources` into a typed `StaticBase`
value for bootstrap support and exposes it as `hostbootstrap config show <file>`. Normal command
dispatch reads the sibling binary-context file instead. The rich and test tiers are decoded by the
project binary against the schema it emits.

## See also

- [prerequisites.md](prerequisites.md) — the fail-fast host minimums the Python layer asserts before
  reading this file
- [resource_budgeting.md](resource_budgeting.md) — how `resources` is verified and cordoned
- [dhall_topology.md](dhall_topology.md) — the Dhall topology across bootstrap, context, rich, and test
  configs
- [binary_context_config](../architecture/binary_context_config.md) — the per-binary runtime context
  contract
- [derived_project_standards.md](derived_project_standards.md) — the project Dockerfile and binary
  this file points at
