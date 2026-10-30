# Derived Dockerfile

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [derived project standards](derived_project_standards.md), [code check doctrine](code_check_doctrine.md), [warm store](warm_store.md), [build and release](build_release.md), [build and run model](../architecture/build_and_run_model.md), [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md)

> **Purpose**: Define the idiomatic derived-project Dockerfile shape — the in-Dockerfile `check-code` gate, the `purescript-bridge` → `spago` → `esbuild` web build, and the build-stage ordering — using the worked `hostbootstrap-demo` container as the reference.

## TL;DR

- A derived project's container is built **by the project binary**, not by the
  Python bootstrapper: the binary is the builder (see
  [build and run model](../architecture/build_and_run_model.md)).
- The reference container is `FROM ${BASE_IMAGE}` → copy the project sources, its ordinary
  `cabal.project`, and the committed style contract → install the coordinator-selected
  authenticated builder, the coordinator-supplied image-build config (a BuildKit secret), and the
  public verification keys under `/usr/local/libexec` → run
  `/usr/local/libexec/<project> check-code` with the build secrets mounted → warning-clean
  source build (opportunistically reusing the warm store) → web build (`spago build` → `esbuild`
  over the bridge-generated sources the build-image step's `writeBridge` invocation staged into
  the context) → final materialization of the runtime binary, config, keys, and web bundle →
  tini ENTRYPOINT.
- The Dockerfile never runs `project init`: the image-build config arrives from the coordinator
  through the `hostbootstrap-build-config` BuildKit secret, so the image cannot mint its own build
  authority.
- The in-Dockerfile `check-code` step is a **build-time gate**: an image with
  style or lint violations in the sources the project's `check-code` covers cannot be produced. See
  [code check doctrine](code_check_doctrine.md).
- `demo/docker/Dockerfile` is the worked example and the reference shape derived
  projects copy.

## The reference shape

The derived Dockerfile (the worked example is `demo/docker/Dockerfile`) inherits the warm-store base
image, copies both the in-repo core source and demo source plus the committed style contract
(`fourmolu.yaml`, `.hlint.yaml`), and uses the same Cabal project as the host build. It installs the
coordinator-selected authenticated builder, the coordinator-supplied image-build config, and the public
handoff and activation verification keys under `/usr/local/libexec`, runs the authenticated code-check
gate from there, builds the source project and the web bundle, and materializes every runtime artifact in
the final layer, with a tini `ENTRYPOINT` that is PID 1 whenever a launch keeps the image entry point;
[the runtime launch](#the-runtime-launch) describes each launch and which ones override it. Its generalized skeleton is (an L0-direct in-repository
consumer copies the core source as shown; a remote consumer takes `hostbootstrap-core` from its pinned
`source-repository-package` instead):

```dockerfile
# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Public halves of the coordinator's handoff and activation signing keys,
# provisioned independently of source, config, and the signed handoff envelope.
ARG HANDOFF_VERIFICATION_KEY_HEX
ARG ACTIVATION_VERIFICATION_KEY_HEX

WORKDIR /workspace
COPY core/hostbootstrap-core /workspace/core/hostbootstrap-core
COPY <project> /workspace/<project>
# The committed style contract, at the root both tools search upward to.
COPY fourmolu.yaml /workspace/fourmolu.yaml
COPY .hlint.yaml /workspace/.hlint.yaml
WORKDIR /workspace/<project>

# 1. Install the coordinator-selected authenticated builder at a path distinct
#    from the runtime entrypoint. Install the coordinator-supplied image-build
#    config beside it through a BuildKit secret; do not mint config here.
#    Decode the 32-byte public keys from their hex build arguments.
COPY --from=hostbootstrap-builder <project> /usr/local/libexec/<project>
RUN --mount=type=secret,id=hostbootstrap-build-config,required=true \
    chmod 0755 /usr/local/libexec/<project> \
    && install -m 0644 /run/secrets/hostbootstrap-build-config \
        /usr/local/libexec/<project>.dhall \
    && test "${#HANDOFF_VERIFICATION_KEY_HEX}" -eq 64 \
    && test "${#ACTIVATION_VERIFICATION_KEY_HEX}" -eq 64 \
    && python3 -c "import binascii,sys; open(sys.argv[2],'wb').write(binascii.unhexlify(sys.argv[1]))" \
        "${HANDOFF_VERIFICATION_KEY_HEX}" /usr/local/libexec/<project>.handoff.pub \
    && python3 -c "import binascii,sys; open(sys.argv[2],'wb').write(binascii.unhexlify(sys.argv[1]))" \
        "${ACTIVATION_VERIFICATION_KEY_HEX}" /usr/local/libexec/<project>.activation.pub

# 2. The mandatory authenticated code-check gate.
RUN --mount=type=secret,id=hostbootstrap-build-channel,required=true \
    --mount=type=secret,id=hostbootstrap-build-verification,required=true \
    --mount=type=secret,id=hostbootstrap-build-coordinator,required=true \
    /usr/local/libexec/<project> check-code

# 3. Build the source project under the same warning-clean configuration.
RUN cabal build --enable-tests --enable-benchmarks all --ghc-options=-Werror \
    && built_binary="$(cabal list-bin ... exe:<project>)" \
    && test -s "${built_binary}"

# 4. The web build. The bridge codegen is re-homed into the build-image chain
#    step's `writeBridge` invocation, which runs BEFORE this image build and
#    stages the generated PureScript sources into the build context — there is no
#    `web bridge` verb. The Dockerfile only compiles and bundles them.
RUN cd web \
    && spago build \
    && esbuild --bundle --minify --outfile=public/app.js src/index.js

# 5. Verify the in-image product, materialize every runtime-critical artifact
#    in the final layer, remove the build-only authority, and check the result.
RUN built_binary="$(cabal list-bin ... exe:<project>)" \
    && test -s "${built_binary}" \
    && dd if=/usr/local/libexec/<project> of=/usr/local/bin/<project> \
        bs=4M status=none \
    && dd if=/usr/local/libexec/<project>.dhall \
        of=/usr/local/bin/<project>.dhall status=none \
    && dd if=/usr/local/libexec/<project>.handoff.pub \
        of=/usr/local/bin/<project>.handoff.pub status=none \
    && dd if=/usr/local/libexec/<project>.activation.pub \
        of=/usr/local/bin/<project>.activation.pub status=none \
    && dd if=web/public/app.js of=web/public/app.runtime.js status=none \
    && rm web/public/app.js \
    && mv web/public/app.runtime.js web/public/app.js \
    && chmod 0755 /usr/local/bin/<project> \
    && chmod 0644 /usr/local/bin/<project>.dhall \
        /usr/local/bin/<project>.handoff.pub \
        /usr/local/bin/<project>.activation.pub \
        web/public/app.js \
    && rm /usr/local/libexec/<project> \
    && rm /usr/local/libexec/<project>.dhall \
    && rm /usr/local/libexec/<project>.handoff.pub \
    && rm /usr/local/libexec/<project>.activation.pub \
    && test -s /usr/local/bin/<project> \
    && test -s /usr/local/bin/<project>.dhall \
    && test "$(stat -c %s /usr/local/bin/<project>.handoff.pub)" -eq 32 \
    && test "$(stat -c %s /usr/local/bin/<project>.activation.pub)" -eq 32 \
    && test -s web/public/app.js

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/<project>"]
```

The worked demo's step 1 additionally installs the config and both public keys at their
`/usr/local/bin` runtime paths before the gate; step 5 rewrites them there in the final layer either way.
Only the runtime **binary** path stays absent until step 5.

The source build uses the same warning-clean Cabal configuration as the
project-defined gate. A later invocation must not reconfigure the same build
tree with different GHC options and then trust only its exit status. Both the
selected build product and exported entrypoint are required to be non-empty.
The source-built, digest-bound authenticated builder under `/usr/local/libexec`
is the byte authority for the runtime artifact: the Cabal product of step 3 is
checked non-empty and never copied into the runtime path. The final layer copies
the builder bytes with `dd` into a new regular `/usr/local/bin/<project>` file and removes
the build-only libexec authority. The same final materialization rule applies to
the runtime config, public keys, and generated web bundle. Thus the image does not depend on
BuildKit snapshotting either the in-container linked Cabal product or a direct
large-file copy from the named context.

Core does not probe an exported image. The worked demo's build-image step does: after export it starts a
probe container (`verifyVmProjectImage` on the VM-backed lanes, `verifyDirectProjectImage` on the direct
lane) and checks the runtime binary, config, both 32-byte keys, and the web bundle again before reporting
the image complete. A derived project supplies its own equivalent probe.

## Parser directive

The first two lines are parser directives. `# syntax=docker/dockerfile:1` selects the BuildKit Dockerfile
frontend that the `RUN --mount=type=secret` steps and the named `--from=hostbootstrap-builder` context
depend on. `# check=skip=InvalidDefaultArgInFrom` suppresses the BuildKit warning for the
`ARG BASE_IMAGE` / `FROM ${BASE_IMAGE}`
pattern: the base image tag is supplied at build time by the project binary rather
than defaulted in the Dockerfile, which is the intended shape, so the warning is
skipped rather than worked around. Derived projects copy both directives verbatim.

## The base inheritance

`FROM ${BASE_IMAGE}` inherits the warm-store base
([base image](base_image.md)). The container uses the ordinary host-compatible project file unchanged.
Cabal reuses matching inherited store artifacts and resolves/downloads/compiles cache misses normally;
there is no base-owned freeze import ([warm store](warm_store.md)).

The normal workflow pulls the published rolling tag before a compatibility build. A publisher may pass
the resulting digest to bind that one smoke to the pulled artifact; this is not a permanent consumer pin.
See [build and release](build_release.md).

## The `check-code` gate

The coordinator supplies an integrity-bound builder through the read-only `hostbootstrap-builder` named
context and a canonical image-build config through a transient BuildKit secret. The Dockerfile installs both
under `/usr/local/libexec` and never invokes `project init`; it cannot mint its own build authority or config.
See [binary context](../architecture/binary_context_config.md).

Then the Dockerfile runs `/usr/local/libexec/<project> check-code` with the fresh signed channel,
verification material, and coordinator identity mounted as required secrets. This
is the inherited core `check-code` verb whose body is supplied through the project's `ProjectSpec`; the
demo's `demoCheckCode` runs `fourmolu --mode check` and `hlint` over `app` and `src`, then the full
`cabal build -j1 --enable-tests --enable-benchmarks all --ghc-options=-Werror`. Because it is a `RUN`
step, a non-zero exit fails the image build: the image cannot exist with style or lint violations in the
sources the project's `check-code` covers (for the demo, `app/` and `src/`; its `test/` sources are
style-checked by the host source gate, not in the image). This is the derived-project half of the rule in
[code check doctrine](code_check_doctrine.md). The signing and verification protocol behind the builder,
channel, and coordinator secrets is canonical in
[build and release](build_release.md#authenticated-derived-image-gates).

The style legs fail fast, before any compilation. The gate's own type-correct leg is the full
warning-clean source build, so the source build that follows the gate (step 3 of the skeleton) reruns the
same configuration against the warm build tree. That step exists to assert a non-empty in-image Cabal
product under identical flags; its product never reaches the runtime path, which always receives the
authenticated builder's bytes. The gate runs **before** the web build, so a failing check stops the build
before any web compilation.

## The runtime launch

The image's tini `ENTRYPOINT` is the entry for every lifecycle launch. A parent frame reaches a container
child in one of two ways, both rendered from the same `LiftContext` layer (canonical statement:
[composition methodology](../architecture/composition_methodology.md#the-recursive-project-up-interpreter)):

| Route | Serves | Argument shape | Config source |
|---|---|---|---|
| `LifecycleProcessRoute` | the recursive lifecycle verbs (`project up`, `project down`, `project destroy`) | `docker run` with standard input attached, working directory `/`, the image's own entrypoint, then `--hostbootstrap-lifecycle-child`; the authenticated Offer carries the verb | the canonical child config inside the authenticated handoff; the route refuses `ConfigDelivery`, extra arguments, and an entrypoint override |
| ordinary lift fold | non-lifecycle subcommands | `docker run <image> <subcommand>`; with a declared `ConfigDelivery`, `docker create <image> <subcommand>`, `docker cp - <id>:<directory>`, then `docker start -a <id>`, with no entry-point override | the explicit supplied stdin becomes a single-entry ustar projection copied into the stopped container before start; the destination directory must exist |

Neither route bind-mounts a runtime config.

tini is PID 1 for launches that keep the image entry point. The lifecycle route and ordinary lift renderer
keep it; config delivery adds no override. The web chart pod replaces it with a container `command` of
`/bin/sh -c`, which then `exec`s `service run`. The `e2e-tabs` Playwright container, the reachability `curl` checks
(`--entrypoint sh` / `--entrypoint curl`), and the build-image step's exported-image probe
(`--entrypoint /bin/sh`) also replace it and run without tini.

Delivery's known-ID failure cleanup follows its remove/retain policy; a cleanup attempt is not proof of
container absence. The static Lift tests inspect commands and archive bytes, rather than live extraction
or PID 1 behavior. See the
[ordinary delivery contract](../architecture/composition_methodology.md#the-recursive-project-up-interpreter)
for failure propagation and cleanup limits.

## The web build

The web build follows the gate, in three ordered steps:

1. `writeBridge` — generate the PureScript types from the `warp`/`wai` webservice's API types via
   `purescript-bridge`. This is **not** a `web bridge` verb (the command surface is fixed): it is the
   build-image chain step's `writeBridge` invocation, which runs before the image build and stages the
   generated sources into the build context. The demo's `BudgetView` Haskell type feeds both JSON and the
   generated PureScript — and carries the `message` field — so the front-end types cannot drift from the
   API. See [purescript](../languages/purescript.md).
2. `spago build` — compile the Halogen SPA (Overview / Budget / Status / Accelerator tabs)
   against the generated types.
3. `esbuild --bundle --minify` — bundle the compiled output into the served
   `public/app.js`.

The Playwright e2e suite is not part of the image build. It runs in the `test run all` harness's
`e2e-tabs` case, from the already-built project image started as a one-off container joined to the Docker
`kind` network (`--network kind`), with `BASE_URL` set to the web Service's cluster-internal NodePort
(`http://<run-scoped control-plane node>:30080`). Because the project image inherits the base image's global Playwright install
and browser cache, the harness runs the e2e from that baked install: it does not pull a separate
`mcr.microsoft.com/playwright:*` image and does not run `npm install` or `npx` at test time. See
[playwright](../languages/playwright.md) and the [demo runbook](../operations/demo_runbook.md).

## Build-stage ordering

The ordering is load-bearing and every derived project preserves it:

| Order | Step | Why it is here |
|---|---|---|
| 1 | `FROM ${BASE_IMAGE}` + `COPY` | Inherit the warm-store base; bring the source and the style contract in. |
| 2 | Named-context builder at `/usr/local/libexec` + secret config + public keys | Authenticate with coordinator-selected bytes while keeping the runtime binary path absent. |
| 3 | Authenticated libexec `check-code` | Fail fast on style and lint violations, then run the gate's warning-clean type-correct build, before the web build. |
| 4 | Warning-clean source build | Assert a non-empty Cabal product under the gate's exact flags, reusing matching cache artifacts and allowing normal online misses. |
| 5 | `spago build` → `esbuild` over the `writeBridge`-staged sources | Compile and bundle the generated PureScript types. |
| 6 | Final runtime materialization | Rewrite binary, config, keys, and web output in the final layer; remove build-only authority; check sizes. The project's build step then probes the exported image (see [the reference shape](#the-reference-shape)). |
| 7 | tini ENTRYPOINT | tini is PID 1 for correct signal handling whenever a launch keeps the image entry point (see [the runtime launch](#the-runtime-launch)). |

## Current Status

The worked demo Dockerfile follows the current authenticated ordering and consumes a fresh ephemeral
`BuildInvocationAuthority`; it does not mint its own image-build config. The reusable protocol is implemented by the
[authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md);
the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns this reference Dockerfile's
command/channel adoption and live container evidence.

This is the reference shape; see [derived project standards](derived_project_standards.md)
for the broader rules every derived project follows.
