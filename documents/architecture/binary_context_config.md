# Binary Context Configuration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [python_haskell_boundary](python_haskell_boundary.md), [composition_methodology](composition_methodology.md), [dhall_topology](../engineering/dhall_topology.md), [development plan](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md)

> **Purpose**: Define the "know your place" authority contract every project binary uses to reason
> explicitly about where it is running in a composed host/VM/container/cluster topology, and the
> read-only `context` command that introspects it.

## TL;DR

- The runtime config file is the executable's sibling `<project>.dhall`. It carries three things:
  **parameters** (the user-owned root settings), **context** (the binary's place in the topology), and
  **witness** (locally checkable facts that prove the process is in that place).
- The role lives inside the Dhall value, not in the filename. The binary has one default lookup rule.
- The recursive `project up` interpreter hands a subcommand off into the next frame; on each handoff the
  child verifies its own `.dhall` frame against the runtime, or **fails fast** (exit code 1) before any
  side effect.
- The `.dhall` describes parameters and context, never the lift chain shape — the chain is code. The model
  lives in [composition_methodology](composition_methodology.md); this doc defers to it.
- `context` is a **read-only** introspection/visualization command: it decodes the sibling `.dhall`,
  renders `topologyFrames`/`parentChain` with the current frame highlighted, and shows schema and witnesses.
  An internal **context-init step** of `project up` writes context files; no user verb does.

## The Contract

The project binary is not a blind command receiver. It is the local interpreter of one segment of a pure,
typed global composition. When the recursive interpreter lifts `project up` across a boundary, the callee
still has enough typed information to know which frame of the chain it is responsible for.

The canonical lookup path is:

```text
<directory containing executable>/<project>.dhall
```

| Context | Binary location | Config file location |
|---|---|---|
| Host binary | `./.build/<project>` | `./.build/<project>.dhall` |
| VM host-native binary | VM-local `./.build/<project>` or installed path | sibling `<project>.dhall` |
| Project container binary | `/usr/local/bin/<project>` | `/usr/local/bin/<project>.dhall` |
| Cluster service or daemon binary | container entrypoint path | sibling path mounted or materialized by the controller |

There are no alternate automatic filenames such as `<project>.host.dhall`: a role-encoding name would
require the binary to choose a role before reading the file that declares its role. An explicit
`--config FILE` may exist for inspection and testing, but normal dispatch defaults to the single sibling
path.

## The .dhall: Parameters, Context, And Witness

The sibling `<project>.dhall` carries three layers in one typed value:

| Layer | Owner | Purpose |
|---|---|---|
| **Parameters** | the user (root) | the root settings the chain is a pure function of — CPU, memory, storage, HA replicas, structural flags such as "skip VM, go straight to Docker" |
| **Context** | the parent frame's context-init step | this binary's place in the topology: identity, frames, current frame, capabilities, allowed command classes, resource envelope |
| **Witness** | the parent frame's context-init step | locally checkable facts (`runtimeWitnesses`) that let this binary prove it really is in the declared frame |

The `.dhall` never encodes the lift chain itself. The chain is `chain :: cfg -> [Step]` — a Haskell
value, the project's single representation (see [composition_methodology](composition_methodology.md)).
Structural variation (for example, skipping the VM frame to go straight to a Docker frame) is a parameter
flag on the **root** `.dhall`, so the chain stays a pure function of root parameters rather than a second
representation living in config.

### Context Shape

| Field family | Purpose |
|---|---|
| Project identity | project name, binary name, and source root |
| Execution topology | a list of provider-backed frames, their parent links, and the current frame id |
| Context kind | host orchestrator, VM orchestrator, VM project container, image-build container, cluster service, daemon, one-shot job, or test harness |
| Role name(s) | the roles this config authorizes — a single `<project>.dhall` may declare **more than one** (e.g. project *and* service); each command checks the capability it needs |
| Runtime witnesses | locally checkable facts proving the process is in the declared frame: provider profile, mounted socket, env value, config hash, or executable path |
| Local capabilities | tools and services this context may use: Docker socket, kind network, Kubernetes API, durable store |
| Allowed command classes | which command families are valid in this context |
| Resource envelope | the budget slice or cordon this context is inside |

Project-specific logic may extend the value with its own **Parameters-layer** fields, but it must never
make a child reach back to the parent's config or treat a missing config as implicit authority. The demo's
`message : Text` is exactly such a project-extended Parameters-layer field — a typed, mandatory field on
the demo's **own** config type (not a core slot, and in particular not a generic `extra : Map Text Text`)
that the `Web` service reads and renders. A context's relationship to the others lives in the
pure execution-topology frame graph (the compositional lifts), not implicitly in the command line; the
read-only `context` command renders that graph uniformly for **every** `<project>.dhall`, whatever roles it
declares.

A **multi-role** config (one `<project>.dhall` that is both a project authority and a `service` authority)
is generated by granting a primary role its additional roles: `project init --role host-orchestrator
--also-role service` (the repeatable `--also-role ROLE`) unions each added role's command classes and
capabilities into the one context (`HostBootstrap.Context.addRole`). The primary context kind and topology
frame are unchanged; only the authority is widened, so the same config passes both the `project up` and
`service run` gates — each command still checks the capability it needs.

## Topology Shape

The topology is pure Dhall data carried inside the same local config. It is intentionally data, not a
runtime callback. The reflected schema carries these fields on the context record:

```dhall
let ContextKind =
      < HostOrchestrator
      | VMOrchestrator
      | VMProjectContainer
      | ImageBuildContainer
      | ClusterService
      | Daemon
      | OneShotJob
      | TestHarness
      >

let ProviderKind =
      < HostProvider
      | IncusVMProvider
      | LimaVMProvider
      | DockerContainerProvider
      | KubernetesProvider
      | ExternalProvider
      >

let WitnessKind =
      < WitnessFileExists
      | WitnessUnixSocket
      | WitnessEnvEquals
      | WitnessExecutable
      >

let TopologyFrame =
      { topologyFrameId : Text
      , topologyParentId : Text
      , topologyProvider : ProviderKind
      , topologyKind : ContextKind
      , topologyRoleName : Text
      }

let RuntimeWitness =
      { witnessKind : WitnessKind
      , witnessName : Text
      , witnessValue : Text
      }

in  { context =
      { topologyFrames : List TopologyFrame
      , currentFrame : Text
      , runtimeWitnesses : List RuntimeWitness
      , capabilities : List Capability
      , allowedCommandClasses : List CommandClass
      , resourceEnvelope : { cpu : Natural, memory : Text, storage : Text }
      , ...
      }
    }
```

A list of frames plus parent references is open enough for arbitrary composition depth without a closed
recursive type. It can express:

```text
host binary -> Lima VM -> Docker project container -> kind cluster -> service pod
host binary -> Incus VM -> Docker project container -> Pulumi role -> EKS cluster -> workload pod
```

`hostbootstrap-core` owns the common invariants: `currentFrame` must exist, parent references must resolve,
the current frame must authorize the command class and required capabilities, the context-init step can
only mint a descendant the topology allows, and each declared witness must be locally checkable by the
binary or a provider-specific verifier. Higher layers extend `ProviderKind`, role payloads, and witness
constructors when they introduce new providers.

The practical consequence is that illegal state is unrepresentable at the config boundary. A workflow that
declares it is the VM project container must carry a VM parent frame and a Docker/container witness. If
someone runs `docker run <image> test run all` directly on the host with that VM-container config, the
process is missing the VM-ancestry witness and fails before creating a kind cluster.

## Per-Frame Fail-Fast On Handoff

The recursive interpreter descends frame by frame: each frame runs its chain steps, then hands off
`<project> project up` into the next frame (see [composition_methodology](composition_methodology.md) for
the fractal-bootstrap pattern). The binary-context gate is the precondition on each handoff.

Every non-introspection command starts by loading the sibling config and fails fast with exit code 1 when:

- `<project>.dhall` is absent;
- the Dhall does not decode against the binary's config/context schema;
- the config names a different project or binary;
- the requested command is not valid for the current frame's context kind or role;
- the context does not declare the capabilities the requested command requires;
- required local runtime witnesses cannot be verified.

So when the parent hands off into a child frame, the child's first act is to prove — against its own
`.dhall` and the local runtime — that it is in the frame it was minted for. A frame that cannot witness its
declared place refuses the handoff loudly, and the lifting parent sees a non-zero exit. The same `project`
command tree exists in each frame, but each copy refuses work that does not belong to its place.

## The `context` Command: Read-Only Introspection

`context` is a **read-only** command. It mutates nothing and creates no files. Its subcommands —
`inspect`, `path`, `show`, `schema`, and `render` — are the single introspection surface:

- decode the sibling `<project>.dhall` and pretty-print parameters, context, and witnesses;
- render the global lift composition (`topologyFrames`/`parentChain`) with the **current frame
  highlighted**, so an operator can see where this binary sits and what its ancestry is;
- print the in-scope typed schema and the static artifact examples from the registry.

Because `context` only reads, it is one of the few entrypoints that runs without an existing, gate-passing
sibling config (alongside help/version). It never projects authority into a child frame.

### Context creation is an internal step, not a verb

An internal **context-init step** of `project up` mints context files, at the boundary where the
next binary becomes meaningful. The context-init step is a core step kind in the chain (see the Step
algebra in [hostbootstrap_core_library](hostbootstrap_core_library.md)):

1. Python derives `<project>` from the Cabal file, builds `./.build/<project>`, and execs the requested
   command. It writes no Dhall and does **not** initialize config; it is the metal-frame instance of the
   fractal bootstrap.
2. `project init` writes the **root** `<project>.dhall` (host orchestrator, no parent) carrying the
   user-owned parameters. It runs only on a fresh host-level binary with no sibling `.dhall`. Because
   Python never creates config, a normal command run before `project init` finds no sibling config and
   **fails fast** (exit 1) per the gate above — the binary owns its Dhall.
3. During `project up`, a context-init step in a host or VM frame **generates** the **child** frame's
   `<project>.dhall` from passed parameters — some supplied at the frame and some **forwarded from the
   parent context's `<project>.dhall`** — before handing off into it. A child config is a parameterized
   projection of its parent, never a hand-authored copy; it names the child frame and includes the
   witnesses the child can verify locally.
4. The project Dockerfile bakes a narrow `image-build-container` config at `/usr/local/bin/<project>.dhall`
   so build-time commands (`check-code`, static code generation, web asset compilation) run during the
   image build. Runtime parents mount a narrower runtime config at the same path when launching a container
   for `test run all`, service, or daemon work.
5. A service or daemon receives a role-specific config from the controller or launcher that owns identity
   and durable placement. For stateful Kubernetes services that is usually a `StatefulSet`.

## Docker Defaults And Service Overrides

The Docker image carries a safe default `ImageBuildContainer` config so build-time commands can run during
the Dockerfile. That baked config is narrow: build/code-quality and context-init authority only.

A lifted runtime workflow must not gain authority merely because the image has a baked default file. The
parent VM or host frame's context-init step mounts or materializes a runtime child `<project>.dhall` at the
canonical path before launching the container; that runtime config declares the frame and witnesses its
ancestry. A direct host invocation without that runtime context fails fast instead of silently creating a
kind cluster on the wrong Docker daemon.

A long-running service follows the same rule and is the common case: the chart's `deploy-chart` step deploys
a pod whose entrypoint is **`service run`**, and the pod's service-role `<project>.dhall` arrives as a
**ConfigMap that overrides the image's baked container config** at the canonical path. The config declares a
service role and a valid service variant; `service run` fails fast otherwise (§ AA). The same image
therefore serves image-build, ad-hoc runtime, and service contexts while each container instance reads
exactly one local file.

The test harness obeys the same authority rules without a distinct lifted "TestHarness" path: `test run`
runs the **real `project up`** under a harness-generated root config, so its assertions execute in the
normal host/VM/container frames the chain mints. A suite may declare **more than one config variant**; the
harness stands each up, asserts, and tears it down in turn (the demo runs `message = "Hello, world!"` then
`message = "Hello, Universe!"`, with the `message` flowing `<project>.dhall` → chart `ConfigMap` → the
`Web` service → the SPA `#message`, and the Playwright e2e-tabs assertion polymorphic over the exported
`EXPECTED_MESSAGE`). Two preconditions protect production before any test runs — the harness refuses if the
executable-sibling `<project>.dhall` (`siblingProjectConfigPath`, i.e. `.build/<project>.dhall`) already
exists (it would overwrite a real config) or if a production cluster is running (it would touch production
state) — and it deletes only the generated config and `.test_data` it created this run.

## Config Snapshot And Daemons

For short-lived commands the config is read once at startup and treated as immutable for that invocation;
on-disk changes affect future invocations only.

For daemons and services the default is the same: read once, validate, log the config path and hash, and
run under that snapshot until restart or an explicit reconcile. Live reload is optional project work and
must never live-reload authority fields — project identity, context kind, parent chain, capabilities, or
allowed command classes.

Daemon startup logs should make the active authority obvious: project, binary, context kind, role name,
config path, config hash, source root, and resource envelope, plus any version/build metadata. Logs go to
stdout/stderr by default so systemd, Docker, Kubernetes, or incus can collect and rotate them.

## Demo Contexts

The worked demo descends through four frames, each reading its own `<project>.dhall`:

| Context | Role |
|---|---|
| Host | metal-side orchestrator: select the VM provider, size and launch the VM, tear it down behind the guard |
| VM | fresh Linux host: Lima on Apple Silicon, Incus on native Linux; re-establish the host-native binary and build the project container |
| Container on the VM | lifted workload: interpret the container-frame chain steps (`deploy-kind` → `deploy-harbor` → `push-image` → `deploy-chart` → `expose-port`) that stand up the persistent stack |
| Cluster service | chart-launched webservice pod: serve only the service role |

The same `project` command tree exists in each copy of the binary. Each copy reads a different local
`<project>.dhall` and therefore accepts a different subset of commands; `context` visualizes which frame a
given copy occupies.

## Secrets Are Never In The Context

The context is generated, mounted, copied between frames, and read for inspection (`context`), so it must
carry no secret. Docker Hub credentials in particular are **never** a context field: they are an
effect-only runtime capability forwarded ephemerally down the lift (piped on `stdin` / a forwarded
environment name), never represented in Dhall and never persisted. See
[registry credentials](../engineering/registry_credentials.md).

## Current Status

[Phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md) governs the binary-context gate.
Python does not create runtime config. The built binary owns ungated default generation, schema/help,
validation, child-config projection, and the normal command gate that reads the context authority embedded
in the local config. The gate checks project/binary identity, context kind, command class,
capabilities, execution topology, current frame, parent/ancestor relationships, and local runtime
witnesses, and a command fails before side effects when the process is not actually in the frame its Dhall
declares. Dockerfiles bake the narrow `image-build-container` role; runtime containers receive
parent-generated `vm-project-container` configs mounted over the baked file.

The model described above is real-run-validated end-to-end on real hardware:

- The recursive `project up` interpreter interprets the `[Step]` chain across the 3-frame fractal descent.
  Context creation is the internal context-init step kind, and `project init` writes the root config.
- The read-only `context` command is the single introspection surface: `context inspect`, `context path`,
  `context show`, `context schema`, and `context render`.
- The `.dhall` is the explicit parameters + context + witness value of a root the chain is a pure function
  of, with structural variation expressed as a root parameter flag.

A single `project up` on Incus/Linux stands up the live persistent stack — a cordoned kind cluster, the full
production Harbor, the project image pushed to the in-cluster registry, and the web chart pod serving
`localhost:30080` with HTTP 200 — and `project down` / `project destroy` tear it down with host `.data`
preserved. The phase records live in `DEVELOPMENT_PLAN/`, which owns implementation status; this document
describes the authority contract.

## See Also

- [composition_methodology](composition_methodology.md) — the canonical home of the chain-is-the-project
  model, the recursive interpreter, and fractal bootstrap that this doc defers to.
- [hostbootstrap_core_library](hostbootstrap_core_library.md) — the Step algebra and the `project`/`context`
  command tree.
- [registry_credentials](../engineering/registry_credentials.md) — why Docker Hub credentials are
  forwarded ephemerally and never placed in the context Dhall.
- [python_haskell_boundary](python_haskell_boundary.md) — Python as the metal-frame instance of the
  fractal bootstrap.
- [dhall_topology](../engineering/dhall_topology.md) — where the binary context fields fit in the Dhall
  configuration model.
