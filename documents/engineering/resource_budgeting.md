# Resource Budgeting

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [schema](schema.md), [cluster_lifecycle](cluster_lifecycle.md), [applied_cordon](applied_cordon.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [build_and_run_model](../architecture/build_and_run_model.md), [binary_context_config](../architecture/binary_context_config.md)

> **Purpose**: Define the per-project resource budget read from the static-base `hostbootstrap.dhall`,
> copied into each binary-context config, and how that budget is enforced as a ceiling cordoned per
> substrate.

## TL;DR

- The static-base `resources` field is the one ceiling: one declared `cpu` / `memory` / `storage`
  number per project. The Python bootstrapper reads it from `hostbootstrap.dhall` and writes it into the
  host-level `project-binary-context-config.dhall`; nested contexts carry the relevant slice forward.
- The project binary verifies the active context has the spare budget available before proceeding, then
  applies the cordon — a dedicated per-project Colima/incus VM, a kind-node cap, or a container cap.
- The ceiling is enforced by three rings (compile, bring-up, runtime). The applied detail lives in
  [applied_cordon](applied_cordon.md).
- Normal binary commands do not re-read `hostbootstrap.dhall`; they consume the budget from their
  sibling binary-context config.

## The Budget Field

The resource budget is a `resources` record in the static-base schema described in [schema](schema.md):

```dhall
{ project    = "app"
, dockerfile = "docker/app.Dockerfile"
, resources  = { cpu = 4, memory = "8GiB", storage = "20GiB" }
}
```

- `cpu` — whole cores reserved for the project's substrate.
- `memory` — memory ceiling for the project's substrate.
- `storage` — disk budget for the project's substrate (image layers, cluster data, build outputs).

The Python bootstrapper reads this field because it is the only component that can bridge the static
bootstrap input into the first runtime context before any binary exists. It writes the host-level
`project-binary-context-config.dhall` next to `./.build/<project>`. From there, each project binary passes
the appropriate envelope to nested contexts before crossing a VM, container, daemon, or cluster-service
boundary. The Python bootstrapper does not size the Colima/incus VM — it builds no sizing argv at all,
and consumes the Haskell-emitted argv verbatim. See
[python_haskell_boundary](../architecture/python_haskell_boundary.md) and
[binary_context_config](../architecture/binary_context_config.md).

## The One Ceiling

The declared `resources` number is a hard ceiling, not advice. One canonical quantity parser
(`parseQuantity` in `HostBootstrap.Cluster.Cordon`) decodes the declared quantities, so the one number
means the same thing at every spinup and in every generated config. A project's workload cannot exceed
its declared share because the ceiling is held by three independent rings of defense:

- **Compile ring** — the generated deploy config carries a Dhall-time `assert` that the budget fits the
  pods, so an over-budget config fails to type-check.
- **Bring-up ring** — the pure `verifyBudget` runs as a fail-fast preflight (budget versus resolved
  spare host capacity), and `fitsBudget` proves the concurrent pod set fits before bring-up.
- **Runtime ring** — the applied VM / kind-node / `docker run` caps on the live substrate.

The applied mechanics of all three rings, the canonical parser, and the per-substrate storage cordon
are documented in [applied_cordon](applied_cordon.md).

## Verify-Spare-Resources

Before cordoning, the project binary checks that the active context's declared envelope can be satisfied
locally. If the host cannot satisfy `cpu` / `memory` / `storage`, it fails fast with a one-line diagnostic
naming the shortfall and exits non-zero rather than over-committing the host.

`verifyBudget` is the pure core of this check; `preflightBudget resources hostCapacity` derives the
budget and runs `verifyBudget` against resolved spare host capacity. `resolveHostCapacity` reads CPU
cores and `MemAvailable` from `/proc` on Linux and returns a permissive default off Linux, where the
Colima VM wall is the real cordon. The preflight runs inside `clusterUp` before any substrate is
touched. See [applied_cordon](applied_cordon.md) for the bring-up ring and
[cluster_lifecycle](cluster_lifecycle.md) for where it runs.

## Cordoning per Substrate

The budget is enforced — cordoned — so a project's workload cannot exceed its declared share. The cordon
is applied by the project binary in the context where the workload is about to run, not by the Python
bootstrapper.

| Substrate | Cordoning mechanism |
|-----------|---------------------|
| `apple-silicon` | A dedicated per-project Colima VM sized to `cpu` / `memory` / `storage`. The VM boundary is the cordon: the project's Docker workload runs inside its own sized VM, isolated from the host and from other projects' VMs. The VM is sized by the project binary's `ensure docker` step, not by the Python bootstrapper. |
| `linux-cpu` / `linux-gpu` | A kind-node cap applied during cluster bring-up: `docker update --cpus --memory --memory-swap` on the control-plane container, capping the cluster's consumption to the declared budget. |

On Apple the cordon is the per-project Colima VM, sized by the project binary before the build; on
Linux it is the kind-node cap applied during cluster bring-up, after `kind create` and before Helm,
fail-closed. Storage is cordoned per substrate (Colima `--disk` on Apple, an incus `root,size` for an
incus VM, a quota'd hostPath plus image GC on bare Linux). The cluster-side enforcement is part of the
lifecycle semantics in [cluster_lifecycle](cluster_lifecycle.md); the full applied detail — the argv,
the storage drop from the `docker update` flags, and the self-limiting `--memory-swap == --memory` — is
in [applied_cordon](applied_cordon.md).
