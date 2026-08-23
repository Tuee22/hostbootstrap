# Build and Release

**Status**: Authoritative source
**Supersedes**: immutable-input and synthetic offline base validation
**Referenced by**: [documents index](../README.md), [base image](base_image.md),
[warm store](warm_store.md), [derived Dockerfile](derived_dockerfile.md)

> **Purpose**: Define the native rolling-base publish workflow and its real-consumer compatibility
> smoke.

## Workflow

Maintainers publish one native architecture at a time:

```sh
poetry run hostbootstrap base build-and-push --arch amd64
```

Run the arm64 form on a native arm64 host and Docker engine. The CLI rejects request/host/engine
architecture disagreement before source gates or Docker work. `--flavor` narrows to CPU or CUDA;
otherwise independent flavors may build concurrently unless `--sequential` is supplied.

For each selected flavor the workflow:

1. discovers current compatible upstream versions and URLs;
2. runs the complete Python/core/demo source preflight;
3. cold-builds the rolling tag with plain native `docker build`;
4. pushes the rolling tag;
5. pulls that published tag so a same-named local image cannot mask registry state;
6. resolves the pulled repository digest as an identifier for this workflow;
7. cold-builds the real `demo/docker/Dockerfile` with that pulled base as a compatibility smoke.

Buildx, emulation, and multi-architecture manifest lists are outside this workflow.

## Source preflight

Before any build or push:

```text
Python code check
Python tests and configured coverage threshold
core Cabal build/test with -Werror
demo Cabal build/test with -Werror
```

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
sibling-config-gated and non-attesting. The demo's VM and Direct builders now create a clean measured context,
resolve the rolling base to its freshly pulled repository digest, measure the selected coordinator and builder,
and sign a fresh binding. Channel, Build public key, coordinator identity, and canonical image-build config
reach Docker only as BuildKit secrets. The selected builder reaches the Dockerfile through the read-only
`hostbootstrap-builder` named build context, avoiding BuildKit's secret-size limit without weakening its measured
binding. The build disables layer-cache reuse, and VM transient authority files and builder context are removed
after the attempt. Inside the image, `check-code` derives `/workspace/demo` and its own
executable path, verifies the grant, and consumes `CheckCodePhase` before the project hook. Only afterward does
the Dockerfile compile and install the source-produced binary. A baked config alone remains non-authoritative.

The coordinator requires the distinct provisioned `<executable>.build.key`; the handoff key is not accepted as
a substitute. Missing or malformed Build keys/channels, changed source/config/builder bytes, a foreign project
or coordinator, and repeated phase use refuse explicitly.

## Rolling selection and evidence

The published tag is the consumer discovery reference and intentionally moves. The source tree contains
no base-input lock. Rebuilding the same revision can select newer compatible parents, toolchains, and
packages.

A digest is still useful to identify the exact artifact just pulled and to bind the subsequent smoke
against a registry result rather than a stale local tag. That use does not make the digest a permanent
consumer pin and does not turn dynamic inputs into reproducibility evidence.

The compatibility smoke uses the real demo project and its ordinary `cabal.project`. It may download and
compile cache misses. It proves that the publication can build the consumer, not that the store is
complete or the build is offline.

## Local inspection versus publication

`hostbootstrap base build` may build a local image for inspection. Derived validation of the published
source of truth follows an operator-authorized `build-and-push`, explicit pull, and real-consumer smoke.
Do not silently substitute a same-named local base.

Publishing mutates Docker Hub and requires explicit user authorization. A requested documentation/code
change alone does not authorize it.

## Evidence and partial failure

Output records selected versions, architecture/flavor, pushed tag, pulled digest, source-gate results,
and compatibility-smoke result. These identify what happened in that run; no committed replay manifest
is produced.

Each flavor is pushed after its build succeeds. There is no multi-tag transaction. If one flavor fails,
report which rolling tags changed and which compatibility smokes completed; do not describe the whole
set as atomic.

## Validation

Unit seams cover:

- architecture mismatch before mutation;
- dynamic resolver output feeding build arguments;
- source-gate failure before Docker build/push;
- build → push → pull → digest identification → real-demo smoke ordering;
- the smoke's use of the real Dockerfile and ordinary online consumer project.

Live publication evidence belongs in the owning development-plan sprint.
