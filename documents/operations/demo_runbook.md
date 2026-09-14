# hostbootstrap-demo Runbook

**Status**: Authoritative source
**Supersedes**: the fully validated, recursively torn-down, test-scoped demo narrative
**Referenced by**: [documents index](../README.md), [testing](../engineering/testing.md), [binary context](../architecture/binary_context_config.md), [WSL2](../engineering/wsl2.md)

> **Purpose**: Give operators an honest guide to the demo's current command surface, lift chain,
> durable path, harness behavior, and validation limitations.

## TL;DR

- `hostbootstrap-demo` is a project binary that depends on `hostbootstrap-core` and contributes one
  substrate-selected
  `demoChainFor :: Substrate -> CanonicalProjectRoot scope rootId -> ProjectConfig scope -> [Step]`,
  installed through `addSteps`. There is no base-image LABEL/ENTRYPOINT
  integration mode.
- `project up` executes the exact recursive Chain, while `project down`/`destroy` execute the retained
  plan's child-first reverse projection. The **target** recursively authenticates each child invocation; the operator sequence remains
  root-only, with no nested form to type. The authenticated-handoff phase supplies the child-plan authority
  substrate, while the
  [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) owns
  Production descent, child acquisition integration, and recursive forward/reverse traversal.
- At a chart reverse node, the shared command projects the exact chart from the retained plan, reads only its
  plan/frame/resource-keyed ownership record, verifies those coordinates, and derives Helm cleanup identity
  from that chart. Missing records are foreign, mismatches fail before mutation, and released tombstones retry
  as an already-converged result.
- Before chart apply, the demo measures the exact image and in-image binary, builds the narrowed Production
  role manifest, relays it to the root-only activation signer, installs the signed immutable revision under the
  durable data root, and gives Helm only that revision basename. The pod verifies the revision with the
  independently installed public key before selecting or acquiring its closed service program.
- The chain includes MinIO before the registry and places the accelerator daemon after the workload.
- Before lifecycle adapters consume that chain, the pure exact-slice projection classifies its typed operations
  into provider, cluster, workload, service, and assertion roles. VM and Direct plans retain distinct provider
  prefixes but both require one immediate provider-to-cluster edge and cluster-local workload suffix. The
  projection refuses unknown identities, missing or duplicate singleton roles, wrong-frame workloads, broken
  dependency prefixes, or a config whose canonical digest differs from the admitted plan.
- On the `linux-cpu` Incus lane, the VM deployment action now receives its exact `StepExecution`. Before
  share attachment, cluster work, or descent, it resolves only that node's plan-owned provider resource,
  prepares and settles provision, prepares and settles a live Ready probe, records the settled provider
  identity, and registers the invocation-local pending provider dependency package. A failed, foreign, or
  provisional path registers no package. The worked-demo acceptance exercises this path through fresh Incus
  guests and terminal retained-record deletion.
- The Direct Linux GPU lane applies the same exact producer discipline to its current-metal-frame provider
  reservation without inventing a VM. After Docker discovery and before CUDA, image construction, cluster
  work, or descent, the build action settles the plan-owned Direct reservation and verifies the canonical
  project root plus the configured base-image egress probe. Only its managed Ready result records the
  `reserved` reverse identity and registers the Direct invocation-local dependency package. Direct reverse
  remains journal terminalization only; this does not claim a physical host-provider release.
- The VM chain now has an explicit `copy-source` node between provider settlement and VM descent. On Incus it
  freshly opens the invocation-local provider dependency, resolves only its own durable-share resource, and
  keeps both provider and managed share handles inside one continuation while attaching the canonical host
  durable root at the provider-selected absolute guest target. Mount validation and exact guest-alias
  reconciliation finish before the continuation returns. No share handle is carried into the later descent node, and the
  Direct chain declares no copy-source action.
- Host `.data` is carried through the stable `/var/tmp/hostbootstrap-demo-data` Linux alias into
  kind/nvkind and the pod. The durable-readback case writes before and reads after an engine-owned fresh
  same-run lifecycle generation.
- `test run <case-id>|all` selects compiled cases. Each variant is admitted under an exact Harness plan and
  owns `.test_data/<runId>`. The long gate
  still creates real provider, Docker, and cluster state, so use a disposable host with no production demo
  state.

## Current Status

The host-native binary, frame handoff, provider folds, project-image build, kind/nvkind lifecycle, MinIO
and registry deployment, chart, web/accelerator services, and compiled harness cases exist. Static tests
cover many pure builders and failure paths. Current native-hardware closure, exact test totals, and dated
evidence belong only in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

Both VM-backed and Direct project-image builds pull and resolve the published base to a repository digest,
measure a clean Docker context and the selected builder, and sign a fresh `hostbootstrap/build/v1` binding with
the separately provisioned `<executable>.build.key`. After every stable binary copy, the Python builder invokes
one exact private entry in that binary; Haskell installs or validates the handoff secret/public pair, distinct
build secret, and distinct activation secret/public pair without creating config. Existing valid material is
retained, missing public halves are reconstructed only from their retained secret, and orphaned, malformed, or
mismatched material refuses. Python never reads or creates key bytes. Build authority, its public key, coordinator identity,
and image-build config are transient BuildKit secrets; the measured builder is supplied through the read-only
`hostbootstrap-builder` named build context. The Dockerfile runs authenticated, no-cache
`check-code` before compiling the final binary. The final Cabal invocation keeps the same `-Werror`
configuration as that gate and refuses an empty selected executable. After the web build, the Dockerfile
copies the source-built, digest-bound authenticated builder bytes from its build-only libexec path into a new
regular bin-path runtime file, final-materializes the config, both public keys, and web bundle, removes the
build-only authority, and refuses empty runtime artifacts. The coordinator repeats those checks against an
exported probe container before it reports build #3 complete.
Runtime therefore does not depend on BuildKit snapshotting either the in-container linked Cabal product or a
direct large-file named-context copy. The
Dockerfile does not mint an image-build config from its own arguments.

Cluster creation has one closed backend selected by the plan-owned cluster package. A Kind plan requires the
resolved Kind, Docker, Kubectl, and Helm identities; an nvkind plan requires nvkind instead of Kind and never
falls back to it. Discovery mints no backend when a required tool is absent, and later operations refuse a
changed driver, config bytes/digest, or ownership identity before mutation. Operators therefore repair the
declared host-tool installation or regenerate the exact admitted plan; substituting a similarly named binary
or editing the rendered cluster config in place is not a recovery path.

Automatic local exposure is runtime-owned. Host-port numbers are absent from Dhall and canonical Kind/nvkind
config. After cluster readiness, an identity-bound relay built from the exact derived project image joins the
cluster network, Docker atomically selects and binds its loopback publications, and authenticated inspection
produces the opaque service endpoints carried to fixed successors. Every application-facing local client
selects its semantic service only inside that lexical resolved-endpoint continuation. Reverse authenticates
and removes the exact relay before cluster deletion, retaining the exposure record on any mismatch.

The `deploy-kind`/nvkind node now consumes the authenticated provider package carried into its child frame.
It fresh-probes that exact parent-owned generation, derives its cluster package from the node's opaque admitted
execution projection, writes the canonical config, reconciles ownership, applies the budget cordon, verifies
fresh readiness, settles the runtime exposure, and publishes only the pending cluster dependency package for
fixed successors. A refusal
at any stage leaves no readiness/package to consume. After correcting the reported provider, tool, ownership,
or config mismatch, run `project down` or `project destroy` to advance the consumed failed-Up invocation through
its exact reverse path before starting a fresh `project up`.

The VM placement witness under `/run/hostbootstrap` is recreated after the
provider share transaction settles. This ordering matters on Incus because
attaching the exact virtiofs device stops and starts the VM, clearing `/run`;
the child context never relies on the earlier bootstrap-time witness.

Operator-significant boundaries are:

- a callback-free non-core reverse node is foreign-retained; it is never reported as released without a
  resource-specific callback;
- Direct provider reverse terminalizes its journal reservation and reports physical host stop/delete as
  `Unsupported`;
- bare Linux has no runtime storage quota or image-GC wall;
- terminal hardware acceptance follows each substrate's declared gate; current completion and dated
  evidence are recorded in the [development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Build and Config

The Python entry point builds the sole Cabal executable host-native into `.build/<executable>` and hands
off its arguments. It discovers exactly one top-level Cabal file, runs `cabal update`, and is not an
offline path. See [Python/Haskell boundary](../architecture/python_haskell_boundary.md).

The demo host build and later Linux image build both use `demo/cabal.project`. It contains no
base-owned absolute import; the container inherits the warm store opportunistically and may compile
cache misses. Published-base pull behavior is documented in
[build and run model](../architecture/build_and_run_model.md).

Initialize the executable-sibling root config with:

```text
hostbootstrap-demo project init
```

Normal commands load that sibling `hostbootstrap-demo.dhall`. Current child configs adjust context but
retain the full demo project record and raw parent envelope; they are not least-privilege parameter
types. Their ownership is also split: the composite pristine-bootstrap derives/streams the VM config,
the descent the `context-init` step declares carries the container payload that the handoff streams, and
the chart transaction renders the service ConfigMap while the daemon action renders its own ConfigMap. The
context-init step's action body only announces the
container handoff and anchors the frame. VM/container payloads are written at the child's executable-sibling path before
dispatch; there is no config bind-mount. The target plan owns projection/delivery as one operation and
emits a role-specific payload.

## Inspect Before Mutating

The read-only context surface is:

```text
hostbootstrap-demo context inspect
hostbootstrap-demo context path
hostbootstrap-demo context show [FILE]
hostbootstrap-demo context schema
hostbootstrap-demo context render [--artifact NAME]
```

Use `project up --dry-run` to render the selected step chain without applying it.

## Bring-up Chain

VM-backed lanes descend host → provider VM → project container. Their exact plan authors the provider at the
descended VM frame. Native Linux GPU authors a distinct Direct reservation provider at the metal frame and uses a direct
host → GPU-enabled project-container path and nvkind. The provider abstraction is
`SubstrateProvider`/`LiftLayer`, with no parallel target dispatcher.

The workload segment is ordered:

```text
deploy-kind or nvkind
  -> deploy-minio
  -> deploy-registry
  -> push-image
  -> deploy-chart
  -> expose-port
  -> accelerator-daemon placement
```

Before backend selection, the command projects the singular cluster operation from the admitted plan and
renders canonical config bytes. VM-backed lanes select Kind and preserve their provider-visible writable
durable target. The Direct Linux GPU lane selects nvkind, adds its GPU worker, and contains no VM/share/alias
fiction. The target renderer carries only these semantic exposure intents:

The cluster action accepts neither a selected executable nor a cluster name. VM/container lanes open the
carried `core:deploy-vm` provider through `runtime://provider/demo-vm-readiness`; Direct opens its admitted
`core:deploy-vm` host reservation through `runtime://provider/demo-direct-readiness`, independently of its
preceding `core:build-image` action. Both then follow the same
reconcile → ownership carry → cordon → fresh readiness → runtime exposure → cluster-package registration
sequence. On Direct Linux GPU, fresh node readiness is followed by the Docker NVIDIA-runtime smoke, pinned
exact `nvidia` RuntimeClass observation, device-plugin reconciliation, DaemonSet readiness, and a positive
`nvidia.com/gpu` allocatable observation before runtime exposure and package registration. The later
accelerator Deployment selects that RuntimeClass and requests one `nvidia.com/gpu`; acceptance must observe
that request on a Running pod rather than infer GPU placement from a successful rollout alone.
The following `deploy-chart` node carries an exact stable chart declaration. It opens that acknowledged
cluster package, performs a nonce-bound fresh readiness probe, and sends canonical values to the
producer-owned Helm/Kubectl service. The chart owns the service ConfigMap, image identity, Deployment rollout,
release, and namespace as one transaction; no separate `kubectl apply` or compatibility chart mutator runs.
Helm is invoked with `--rollback-on-failure` and an explicit `--wait`; a successful command that writes a
warning to standard error is refused rather than silently classified as a settled chart. Helm 4 first-install
output must also carry the matching release name, deployed status, revision 1, and `Install complete`
description; a zero exit alone is not accepted.
Immediately before preparation, the child computes the exact image/binary measurements and narrowed role wire,
then relays the canonical activation-signing request. The root signs only an exact admitted-plan plus a
chart- or step-declared service/effect placement. The chart-owned web service and separately applied accelerator
daemon therefore use distinct plan-authored activation frames under the same policy. The child adopts each grant
into the immutable revision store, and the prepared workload retains only its exact lowercase digest basename.

The Deployment mounts the selected revision read-only from the shared durable root and mounts the separate
authority store at its fixed runtime coordinate. A dedicated service account has only pod `get`; the container
uses it to read its own real restart count, combines that with its downward-API pod UID, and then executes
`service run`. A missing/malformed revision, key, instance identity, role wire, measurement, or effect grant
refuses before the service program acquires a listener.

| Driver | Runtime-exposed services |
|---|---|
| Kind | registry, web, accelerator ingress, MinIO |
| nvkind | registry, web, MinIO |

Stable Kubernetes Service/NodePort targets remain cluster-internal. They are not copied into host publication.
After cluster readiness, Docker assigns a distinct host port to every relay listener while binding it to
`127.0.0.1`; hostbootstrap inspects the exact relay identity and passes those resolved endpoints to the
registry push, web probes, MinIO setup, accelerator ingress, and harness assertions. Duplicate services,
wildcard inspection, missing/additional mappings, wrong targets, identity replacement, digest mismatch, or
noncanonical input refuses. No operator chooses a port and no retry loop scans candidates.

The Apple/Windows host-resident daemon starts after the deployment child frame has exited, so it does not use
that child's invocation-local cluster package. It crosses the selected VM provider frame with the closed
read-only exposure request; the guest opens the durable exposure record, re-observes the exact relay identity
and complete mapping set in its Docker engine, and returns only the accelerator loopback port. A missing,
pending, replaced, or changed relay fails the host-daemon step before process launch.

The root coordinator installs its admitted activation signing service into the root Chain carrier before that
descent. The same carrier survives the child close, so the host daemon's post-handoff step can submit its exact
manifest and receive a signed activation grant without retaining a child service or moving the root signing
key. Exposure observation and activation signing are therefore separate fresh checks: one returns only a
loopback port, and the other returns only a signed grant.

MinIO creates the S3 backing and bucket before the registry. The accelerator daemon is in-cluster for
Linux CPU/GPU and host-native after private ingress for Apple Silicon/Windows GPU. An in-cluster daemon mounts
the same revision and authority directories as the web workload, reads its own pod UID and exact daemon-container
restart count, and invokes `service run`. A host daemon instead measures the copied executable, installs its
verification key and revision beside durable state, and receives a fresh invocation nonce for that process.

Run:

```text
hostbootstrap-demo project up
```

Most reconcilers currently return `IO ()`; “reconcile-to-running” is an operational intention, not a
typed report of created/adopted/repaired/unchanged state.

## Durable Data

The current data path is:

```text
<project-root>/.data
  -> provider-specific share/mount
  -> provider guest /var/tmp/hostbootstrap-demo-data
  -> kind/nvkind node /var/lib/hostbootstrap-demo-data
  -> pod /var/lib/hostbootstrap-demo-data/web
```

`/var/tmp/hostbootstrap-demo-data` is a provider-guest Docker-visible projection, not the canonical
store. WSL2, Incus, and Lima use it after carrying the canonical host root into their guest. Direct
Linux instead binds the canonical absolute host `.data` path; the guest alias remains a
provider-local projection for VM-backed lanes only.

On Incus, child descent waits until the declared guest target is itself a writable `virtiofs`
mountpoint. A same-named writable directory in the guest filesystem is not accepted as share
readiness, so Docker cannot retain that underlying directory while the device mount arrives. The
share ownership transaction force-restarts a newly attached Incus VM before it binds the share,
then rechecks the instance identity and Running state. This is the activation boundary for the disk
device, not a readiness-loop workaround; an exact bound retry does not restart again.

Cluster teardown omits the configured data path from its removal set. The `durable-readback` harness case
declares `AssertAcrossRestart`: its `BeforeRestart` callback writes and reads the marker, the Harness engine
performs a settled reverse, rotates to a fresh protected invocation, rebinds the exact retained plan, and
forwards again, then its `AfterRestart` callback reads the same bytes. Project-owned assertion code receives
only the phase and has no lifecycle authority. See
[durable state](../architecture/durable_state.md).

## Down and Destroy

```text
hostbootstrap-demo project down
hostbootstrap-demo project destroy
```

Each verb is a projection of the same validated plan: cluster cleanup runs only in an owning current
frame, and every other node runs the reverse effect its own step declared. The command authenticates chart
cleanup against the exact plan/frame/resource ownership record and runs it before cluster cleanup; provider,
share, alias, and service callbacks remain authorized by their exact projected local-work nodes. Cleanup
aggregates failures and retains unsettled work for an exact retry instead of treating a partial reverse as
terminal closure.

Down retains the provider's durable share, guest alias, and exact alias ownership row. Destroy can therefore
restart the guest and reach the same durable cluster store before releasing the alias and deleting the VM.
The host `.data` root and marker survive both verbs.

On Apple and Linux, `project down` returns the provider VM's CPU and memory to the host. On Windows it
first restores the journalled `.wslconfig` origin, including an absent origin, and then invokes the
global `wsl --shutdown`. That ordering makes the next cold boot read the restored configuration; the
shutdown stops every distro and releases the shared utility VM's memory balloon. The earlier Windows
gate proves this wall-release observable, not the current full recursive-teardown and durable-readback
hardware acceptance.

The managed six-hour idle timeouts are a backstop only when a run is interrupted before teardown. In
that case an operator can run `wsl --shutdown` manually, after accounting for its disclosed effect on
every WSL distro. See [wsl2](../engineering/wsl2.md) § Wall release.

The provider disk may be removed by `destroy`; the canonical host durable root is shared from outside
that disk and is not intentionally included in cluster removal. Same-run reattachment/readback is a required
worked-demo acceptance assertion on every lane.

On Direct Linux GPU, reverse first releases any recorded host exposure, then starts the project image with the
Docker socket and only the exact profile data bind. Its fixed internal retained-release entry authenticates the
recorded nvkind node identities, deletes and proves them absent, and releases those records. The parent proves
the declared nodes absent again before Harness permission restoration and removal; Production data permissions
are never normalized by this route.

## Demo Harness

Initialize and run:

```text
hostbootstrap-demo test init
hostbootstrap-demo test run <case-id>
hostbootstrap-demo test run all
```

The compiled case ids are `pristine-bootstrap`, `web-build`, `e2e-tabs`,
`registry-persistence`, and `durable-readback`. They are Haskell code, not dynamically defined by
`<project>.test.dhall`. The demo test file decodes as:

```haskell
data TestConfig = TestConfig
  { testResources :: Resources
  , testVariants :: [TestVariantConfig]
  }
```

Case selection uses opaque compiled `CaseId`s and a validated total `TestMatrix`; `all` is only a parser
selector. `testVariants` declares the two stable message variants, and `demoTestMatrix` projects every
compiled case across them before the run acquires anything. The command retains one exact Harness plan and
drives the common recursive forward and reverse interpreters. Four cases use `AssertOnce`.
`durable-readback` uses `AssertAcrossRestart`, so its before/after callbacks merge into one report row while
the engine alone owns settled teardown, protected generation rotation, exact snapshot rebind, and the second
forward. Two variants still produce exactly ten report rows.

The command is admitted only at the rooted Harness entry. Its independent Harness authority cannot admit a
Production plan, and each owned run root is `.test_data/<runId>`.
Existing-config and production-cluster preconditions reduce collision risk; the long gate still belongs on
a disposable host because it creates real host infrastructure.

The case intentions are:

| Case id | Assertion scope |
|---|---|
| `pristine-bootstrap` | provider/bootstrap/build path |
| `web-build` | image check-code and web artifact path |
| `e2e-tabs` | SPA/API/accelerator behavior |
| `registry-persistence` | registry data across registry-pod recreation |
| `durable-readback` | web POST → GET of the exact marker through the plan-owned `.test_data/<runId>` durable root across engine-owned same-run destroy/recreate |

Those case assertions do not replace the recursive end-state audit, receipt-bound ownership checks, or
native-substrate acceptance gates.

### Linux/CPU pristine acceptance

This is the baseline lane every other one is measured against, and it is the one the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) closes on. Run it only from a
disposable demo state with no `.build`, `.hostbootstrap`, generated `hostbootstrap-demo.dhall`, or
`.test_data`, on a host the substrate classifier calls `linux-cpu` — a Linux host reporting neither
`/proc/driver/nvidia/version` nor `/dev/nvidiactl`. A workstation with a visible accelerator classifies
as `linux-gpu` and takes the Direct chain instead, so on one of those the `linux-cpu` gate host is a
guest VM of its own. That guest needs nested virtualization, because this lane creates a provider VM.

The phase's gate is the Production sequence followed by the complete matrix. From the repository root:

```text
poetry run hostbootstrap run --project-root demo project init
poetry run hostbootstrap run --project-root demo project up
poetry run hostbootstrap run --project-root demo project down
poetry run hostbootstrap run --project-root demo project destroy
rm demo/.build/hostbootstrap-demo.dhall
poetry run hostbootstrap run --project-root demo test init
poetry run hostbootstrap run --project-root demo test run all
```

Two refusals in that sequence are the design working rather than faults to route around. `project up`
without a preceding `project init` refuses, because it has no sibling config to admit. And the harness
refuses every case with `a production config already exists … refusing to overwrite it` while the
generated Production config is still on disk — that file is the operator's, written by `project init`
and not removed by `project destroy`, which tears down state rather than the operator's configuration.
Removing it is the pristine precondition this section already states, and it is why the `rm` above sits
between the two halves.

This lane takes the Incus VM path. `project up` provisions the guest at the declared budget, attaches
the durable share, builds the project binary host-native *inside* the guest, pulls the published CPU
base and builds the derived image there, then descends into that image for the cluster, registry,
workload, and web service. Budget hours rather than minutes for a cold host: the guest's own GHC and
dependency closure are built from nothing before the image build begins. The matrix then performs four
pristine generations, one per fresh guest. Success is exactly `10/10 passed`.

After success, audit the end state: no provider VM remains, no kind cluster and no
hostbootstrap-named container survive, `.build/hostbootstrap-demo.dhall` is gone while the
operator-owned `.build/hostbootstrap-demo.test.dhall` remains, and `.test_data` exists and is empty. The
dated host, versions, run IDs, durations, and image digests belong in
[the worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

### Apple Silicon pristine acceptance

Run the Apple acceptance only from a disposable demo state with no `.build`, `.hostbootstrap`, generated
`hostbootstrap-demo.dhall`, `.test_data`, or Lima instance. Preserve tracked sources and any unrelated ambient
Colima profile. From the repository root:

```text
poetry run hostbootstrap run --project-root demo test init
poetry run hostbootstrap run --project-root demo test run all
```

The complete matrix performs four fresh Lima bring-ups and four terminal destroys. Allow at least two hours
for the matrix, plus the initial cold host-native build; the acceptance phase records measured durations.
Every bring-up installs/builds inside a pristine guest, pulls the published base, and
runs the image's `check-code`/export verification before workloads start. Success is exactly `10/10 passed`.

After success, verify both run leases encode `closed`; no project mode, generated-config, or data-root record
remains; `.build/hostbootstrap-demo.dhall` is gone while `.build/hostbootstrap-demo.test.dhall` remains;
`.test_data` exists and is empty; no accelerator daemon is live; and `limactl list` reports no demo instance.
The shared Docker context and any pre-existing Colima `default` profile are ambient state and must remain
unchanged. The dated host, versions, run IDs, duration, image digests, and audit belong in
[Apple Silicon substrate acceptance](../../DEVELOPMENT_PLAN/phase-25-apple-silicon-substrate.md).

### Linux/NVIDIA pristine acceptance

Run the NVIDIA acceptance only from a disposable demo state with no `.build`, `.hostbootstrap`, generated
`hostbootstrap-demo.dhall`, or `.test_data`. Preserve tracked sources and any unrelated ambient Docker or
Incus workload. The substrate classifier reads `/proc/driver/nvidia/version` and `/dev/nvidiactl`, so a host
with no NVIDIA markers classifies as `linux-cpu` and runs a different lane. From the repository root:

```text
poetry run hostbootstrap run --project-root demo test init
poetry run hostbootstrap run --project-root demo test run all
```

This lane takes the Direct host-provider path, so the four bring-ups create no VM: each builds the project
image, descends into it, and creates an nvkind cluster in a frame the metal host cannot see directly. Allow
about an hour for the matrix, plus the initial cold host-native build. Every bring-up pulls the published
CUDA base, runs the image's `check-code`/export verification, and reconciles the pinned NVIDIA device plugin
before the accelerator workload is released. Success is exactly `10/10 passed`.

Accelerator placement must be **observed, not inferred**: confirm a Running accelerator pod selecting
RuntimeClass `nvidia` with request and limit `nvidia.com/gpu: 1` on a worker advertising positive allocatable
GPU. A successful rollout alone does not establish the device request.

After success, verify both run leases encode `closed` and both profiles `available`; no project mode,
generated-config, or data-root record remains; `.build/hostbootstrap-demo.dhall` is gone while
`.build/hostbootstrap-demo.test.dhall` remains; `.test_data` exists and is empty; no hostbootstrap-named
container survives; and `incus list` reports no instance. Any unrelated ambient container or GPU process is
ambient state and must remain untouched, so the audit is "no container of this run" rather than "no
container".

Before leaving the machine, also record the complete host static gate on it. A Linux/NVIDIA host is an
x86_64 Linux gate host, and the coverage matrix visits a hardware set once, so that cell is collected on
this visit rather than by convening the machine again. The dated host, versions, run IDs, duration, image
digests, and audit belong in
[NVIDIA GPU substrate acceptance](../../DEVELOPMENT_PLAN/phase-26-nvidia-gpu-substrate.md); the gate-host
row belongs in
[host-portability acceptance](../../DEVELOPMENT_PLAN/phase-28-host-portability-acceptance.md).

### Windows pristine acceptance

Run the Windows acceptance only from a disposable demo state with no `.build`, `.hostbootstrap`, generated
`hostbootstrap-demo.dhall`, `.test_data`, or installed `hostbootstrap-demo-vm` distribution. Record the
`.wslconfig` origin's bytes first; the wall audit at the end compares against them, and an absent origin is
itself a valid origin to restore. From the repository root:

```text
poetry run hostbootstrap run --project-root demo test init
poetry run hostbootstrap run --project-root demo test run all
```

Launch the second command through [durable Windows runs](../engineering/durable_windows_runs.md) rather
than directly, because the matrix outlives any agent-driven shell. The complete matrix performs four fresh
WSL2 guest installations and four terminal destroys, taking the per-user global wall at four successive
fences. Each bring-up warns before applying the wall ceiling, because doing so runs a global cross-distro
`wsl --shutdown`. Allow at least three hours on a four-core-class host, plus the initial cold host-native
build. Success is exactly `10/10 passed`.

After success, verify both run leases encode `closed` and both profiles `available`; no project mode,
generated-config, or data-root record remains; `.build/hostbootstrap-demo.dhall` is gone while
`.build/hostbootstrap-demo.test.dhall` remains; `.test_data` exists and is empty; `wsl -l -v` reports no
installed distribution; no accelerator daemon is live; and `.wslconfig` holds its exact origin bytes with
no active wall record. An idle utility VM left by post-run observation is settled with `wsl --shutdown`,
which is safe once no distribution remains. The dated host, versions, run IDs, duration, image digests, and
audit belong in
[Windows and WSL2 substrate acceptance](../../DEVELOPMENT_PLAN/phase-27-windows-and-wsl2-substrate.md).

## Safe Operating Guidance

- Do not run the long harness on a machine carrying production demo state.
- Treat every runtime-resolved web, registry, MinIO, and accelerator endpoint as a development-only listener.
  The target relay binds only `127.0.0.1`; do not publish it on a wildcard address, persist its selected port in
  Dhall, or construct a localhost URL independently. The registry is still anonymous HTTP, and MinIO uses
  fixed source credentials rendered into a Kubernetes Secret.
- Treat a wrong or occupied durable alias as a conflict; do not delete it by pathname alone.
- Do not point a derived build at a locally rebuilt base. Pull the published tag; the host-native lane
  requires its repository digest and refuses an image with no registry digest.
- On Windows, follow [durable Windows runs](../engineering/durable_windows_runs.md) for the long gate.
- Follow explicit recovery guidance when a command emits it. Structured recovery dispositions are target
  behavior, not universal today; do not manually unregister/delete a provider unless you have separately
  established ownership.

## Related

- [harness workflow](../architecture/harness_workflow.md) — exact Harness plan, profile, and run-root ownership.
- [lifecycle state model](../architecture/lifecycle_state_model.md) — typed transition and ownership
  contract.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — current kind/nvkind operations.
- [accelerator daemon](../engineering/accelerator_daemon.md) — service placement and substrate live gates.
