# Build and Release

**Status**: Authoritative source
**Supersedes**: immutable-input and synthetic offline base validation
**Referenced by**: [documents index](../README.md), [base image](base_image.md),
[warm store](warm_store.md), [derived Dockerfile](derived_dockerfile.md)

> **Purpose**: Define the native rolling-base publish workflow and its real-consumer compatibility
> smoke, and the authority protocol for a derived image's attesting build gate.

## Workflow

Agents and maintainers publish one native architecture at a time:

```sh
poetry run hostbootstrap base build-and-push --arch amd64
```

Run the arm64 form on a native arm64 host and Docker engine. `--flavor` narrows to CPU or CUDA;
otherwise both flavors are selected and build concurrently unless `--sequential` is supplied.

The workflow runs these steps once, for all selected flavors together:

1. queries the Docker engine's architecture and refuses unless the requested, host, and engine
   architectures agree, before any source gate or image build;
2. runs the complete [source preflight](#source-preflight);
3. on Linux, measures host CPU and memory, refuses below the supported floor, and sizes a per-build budget
   (see [the host-sized budget](base_image.md#host-sized-warm-store-budget)); off Linux it measures nothing;
4. discovers current compatible upstream versions and URLs for every selected flavor, so a discovery
   failure for either flavor stops the command before any image build.

Then, for each selected flavor, it:

5. cold-builds the rolling tag with plain native `docker build`;
6. resolves the freshly built local image ID and, with the classic builder needed for daemon-local ID
   resolution, cold-builds the compatibility consumer against that immutable local ID, refusing before
   registry mutation if the consumer's build plan cannot be resolved on the new base;
7. pushes the rolling tag;
8. pulls that published tag so a same-named local image cannot mask registry state;
9. resolves the pulled repository digest as an identifier for this workflow;
10. cold-builds `docker/compatibility-smoke.Dockerfile` against that exact digest.

Buildx, emulation, and multi-architecture manifest lists are outside this workflow.

## Source preflight

Before any build or push:

```text
Python code check
Python tests (hostbootstrap.test_all; the coverage threshold is not checked here)
Haskell formatter over the formatter roots of both Cabal projects (core provider-live excluded)
Haskell linter over the library and consumer sources
core Cabal build/test with -Werror
demo Cabal build/test with -Werror
```

The style legs run before the Cabal legs, so a style regression fails in seconds rather than after a
full build, and each names the root it read. The roots, the modules the formatter cannot read, and the
core `provider-live` suite root that neither leg reads are canonical in
[where the style tools run](code_check_doctrine.md#where-the-style-tools-run). Both legs read the
committed [`fourmolu.yaml`](../../fourmolu.yaml) and [`.hlint.yaml`](../../.hlint.yaml), which fix the
tools' configurable options and so remove option drift. They do not fix the tools: `fourmolu` and
`hlint` are unpinned, and a tool upgrade that changes formatting or adds a default hint can still change
the verdict with no repository change; see
[code-check doctrine](code_check_doctrine.md#the-committed-style-contract).

Any failure stops before registry mutation. The in-image Fourmolu/HLint sample check verifies the
rolling tools themselves and does not replace source preflight.

## Authenticated derived-image gates

`HostBootstrap.Build` defines the authority protocol for a derived image's attesting gate. A separately
provisioned, long-lived Build signing identity is distinct from the handoff project key and the runtime
Activation key. One active coordinator bracket signs a canonical binding containing the installed project
identity, finalized spec and Production-config digests, build identifier, measured source-context digest,
coordinator-binary identity, exact builder-binary identity, and image-build frame. The intended build-engine
consumer delivers that binding and signature through a mounted secret/session file; an absent channel is an
explicit refusal and never falls back to the descriptive image-build config.

Inside the build, the reusable verifier uses an independently installed public key, independently supplied
project/spec/config/coordinator identities, and fresh measurements of the caller-supplied source-root and
builder paths. It authenticates those selected bytes but does not intrinsically establish that the paths name
the build engine's actual context and the running executable. Successful verification invokes a rank-2
continuation with the matching opaque `ImageBuildFrame` and `BuildInvocationAuthority`; callers do not choose
or retain their phantom identities. Each returned authority can authorize `CheckCodePhase` and `BuildPhase` at
most once each, and
those phase authorities cannot authorize lifecycle commands. A second verification of the same signed file
would create separate in-memory phase state; this protocol layer therefore does not claim global channel
consumption. Build grants authenticate the length-framed binding
under the dedicated `hostbootstrap/build/v1` domain. The verification key is provisioned before a coordinator
opens; it is not exported from the active coordinator or accepted from the channel. The coordinator's public
signing operation holds its live-state lock through signature construction, and an escaped coordinator refuses
after the bracket closes.

This protocol is distinct from an ordinary developer invocation of `check-code`, which remains
sibling-config-gated and non-attesting. The demo's VM and Direct builders create a clean measured context,
resolve the rolling base to its freshly pulled repository digest, measure the selected coordinator and builder,
and sign a fresh binding. Channel, Build public key, coordinator identity, and canonical image-build config
reach Docker only as BuildKit secrets. The selected builder reaches the Dockerfile through the read-only
`hostbootstrap-builder` named build context, avoiding BuildKit's secret-size limit without weakening its measured
binding. The build disables layer-cache reuse, and VM transient authority files and builder context are removed
after the attempt. Inside the image, `check-code` derives `/workspace/demo` and its own
executable path, verifies the grant, and consumes `CheckCodePhase` before the project hook. Only afterward does
the Dockerfile compile and install the source-produced binary. A baked config alone remains non-authoritative.

The coordinator requires the distinct provisioned `<executable>.build.key`; the handoff key is not accepted as
a substitute. Each of these refuses explicitly:

- a missing or malformed Build key or channel;
- changed source, config, or builder bytes;
- a foreign project or coordinator;
- a repeated use of a phase authority.

## Rolling selection and evidence

The published tag is the consumer discovery reference and intentionally moves. The source tree contains
no base-input lock. Rebuilding the same revision can select newer compatible parents, toolchains, and
packages.

A digest is still useful to identify the exact artifact just pulled and to bind the subsequent smoke
against a registry result rather than a stale local tag. That use does not make the digest a permanent
consumer pin and does not turn dynamic inputs into reproducibility evidence.

The compatibility smoke is a synthesized derived consumer: a package with its own name, version,
dependency list and source, and no `cabal.project`. It needs only the selected base reference and none of
the demo's separate authenticated build authority. It checks that the toolchain, the warm-store project
directory, and the style tools are present, then runs `cabal build --dry-run all` on the consumer, which
passes when Cabal resolves a complete build plan; the plan may list builds and downloads. Every
dependency the consumer names is already in the store's closure, so the step shows only that such a
consumer's plan resolves on the publication, not that one reaching past the store does. It compiles and links nothing, so it does
not prove that dependencies compile or link against the store and the pinned compiler, that the warm store
is complete, or that the build is offline. See [base image](base_image.md#republishing) for what each step
checks.

## Local inspection versus publication

`hostbootstrap base build` may build a local image for inspection. Derived validation of the published
source of truth follows a `build-and-push`, explicit pull, and real-consumer smoke.
Do not silently substitute a same-named local base.

Publishing mutates Docker Hub, and agents perform it as required: the rebuild → republish → pull rule is
standing authority, described under [publication authority](base_image.md#publication-authority). A change
that leaves the base inputs untouched does not call for a publication.

## Evidence and partial failure

Output records selected versions, architecture/flavor, pushed tag, pulled digest, source-gate results,
and compatibility-smoke result. These identify what happened in that run; no committed replay manifest
is produced.

Each flavor is pushed after its build and local-ID smoke succeed. There is no multi-tag transaction, and
the two modes fail differently:

- **Sequential** (`--sequential`, or a single `--flavor`): flavors run one at a time and the command stops
  at the first failure, so later flavors are neither built nor pushed.
- **Concurrent** (both flavors, the default): both flavors run to completion, then the command raises the
  first failure in flavor order (CPU before CUDA). A failure in the other flavor appears only in that
  flavor's line-prefixed output.

A flavor whose whole sequence completed prints one `[<flavor>] published and validated <digest>` line. A
flavor that failed after its push prints no such line; whether its rolling tag changed is visible only in
its prefixed `docker push` output. If one flavor fails, read both and report which rolling tags changed and
which compatibility smokes completed; do not describe the whole set as atomic.

## Validation

Unit seams cover:

- architecture mismatch before mutation;
- dynamic resolver output feeding build arguments;
- source-gate failure before Docker build/push;
- build → local consumer smoke → push → pull → digest identification → published consumer smoke ordering;
- the smoke's use of the dedicated real-consumer Dockerfile, whose only build argument is the base
  reference and which mounts no secret and no named build context.

Live publication evidence — the dated run, the published tag, its resolved digest, and both smoke
results — belongs in the owning development-plan sprint, which for the rolling base tags is the
[base-image-publication-and-opportunistic-warm-store phase](../../DEVELOPMENT_PLAN/phase-23-base-image-and-warm-store.md).
This page states only the ordering the sequence must hold.
