# Derived Dockerfile

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [derived project standards](derived_project_standards.md), [code check doctrine](code_check_doctrine.md), [binary context](../architecture/binary_context_config.md), [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md), [Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)

> **Purpose**: Define the idiomatic derived-project Dockerfile shape — the in-Dockerfile `check-code` gate, the `purescript-bridge` → `spago` → `esbuild` web build, and the build-stage ordering — using the worked `hostbootstrap-demo` container as the reference.

## TL;DR

- A derived project's container is built **by the project binary**, not by the
  Python bootstrapper: the binary is the builder (see
  [build and run model](../architecture/build_and_run_model.md)).
- The reference container is `FROM ${BASE_IMAGE}` → copy the project and its ordinary
  `cabal.project` → build the project binary (opportunistically reusing the warm store) →
  create the image-build sibling
  `<project>.dhall` → `RUN <project> check-code` → web build (`spago build` → `esbuild`
  over the bridge-generated sources the build-image step's `writeBridge` invocation
  staged into the context) → verify the in-image Cabal product → expose the
  digest-bound authenticated builder into the runtime bin path → tini ENTRYPOINT.
- The in-Dockerfile `check-code` step is a **build-time gate**: an image with
  style or lint violations cannot be produced. See
  [code check doctrine](code_check_doctrine.md).
- `demo/docker/Dockerfile` is the worked example and the reference shape derived
  projects copy.

## The reference shape

The derived Dockerfile (the worked example is `demo/docker/Dockerfile`) inherits the warm-store base
image, copies both the in-repo core source and demo source, uses the same Cabal project as the host build,
builds the project binary (reusing the warm store), writes the image-build sibling
`<project>.dhall`, runs the code-check gate, then builds the web bundle, with tini as PID 1. At runtime the
launch handoff overrides the image entry point with `sh`, streams a freshly minted config on standard
input, writes it in-place over the baked image-build file, and then executes `<project> project up`.
There is no runtime config bind-mount. Its generalized skeleton is:

```dockerfile
# check=skip=InvalidDefaultArgInFrom

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace
COPY core/hostbootstrap-core /workspace/core/hostbootstrap-core
COPY <project> /workspace/<project>
WORKDIR /workspace/<project>

# 1. Install the coordinator-selected authenticated builder at a path distinct
#    from the runtime entrypoint. Install the coordinator-supplied image-build
#    config beside it through a BuildKit secret; do not mint config here.
COPY --from=hostbootstrap-builder <project> /usr/local/libexec/<project>
RUN --mount=type=secret,id=hostbootstrap-build-config,required=true \
    install -m 0644 /run/secrets/hostbootstrap-build-config \
        /usr/local/libexec/<project>.dhall

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
    && chmod 0755 /usr/local/bin/<project> \
    && rm /usr/local/libexec/<project> \
    && rm /usr/local/libexec/<project>.dhall \
    && test -s /usr/local/bin/<project> \
    && test -s /usr/local/bin/<project>.dhall

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/<project>"]
```

The source build uses the same warning-clean Cabal configuration as the
project-defined gate. A later invocation must not reconfigure the same build
tree with different GHC options and then trust only its exit status. Both the
selected build product and exported entrypoint are required to be non-empty.
The source-built, digest-bound authenticated builder under `/usr/local/libexec`
is the byte authority for the runtime artifact. The final layer copies those
bytes with `dd` into a new regular `/usr/local/bin/<project>` file and removes
the build-only libexec authority. The same final materialization rule applies to
the runtime config, public keys, and generated web bundle. After export, the
coordinator starts a probe container and checks those artifacts again, including
the exact 32-byte key sizes, before reporting the image complete. Thus the image does not depend on
BuildKit snapshotting either the in-container linked Cabal product or a direct
large-file copy from the named context.

## Parser directive

The first line is the `# check=skip=InvalidDefaultArgInFrom` parser directive. It
suppresses the BuildKit warning for the `ARG BASE_IMAGE` / `FROM ${BASE_IMAGE}`
pattern: the base image tag is supplied at build time by the project binary rather
than defaulted in the Dockerfile, which is the intended shape, so the warning is
skipped rather than worked around. Derived projects copy this directive verbatim.

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
demo runs `fourmolu`, `hlint`, and `cabal build --ghc-options=-Werror` through
`hostbootstrap-demo check-code`. Because it is a `RUN` step, a non-zero
exit fails the image build: the image cannot exist with style or lint violations.
This is the derived-project half of the rule in
[code check doctrine](code_check_doctrine.md). The gate runs **before** the web
build so a failing check stops the build early.

## The web build

The web build follows the gate, in three ordered steps:

1. `writeBridge` — generate the PureScript types from the `warp`/`wai` webservice's API types via
   `purescript-bridge`. This is **not** a `web bridge` verb (the command surface is fixed): it is the
   build-image chain step's `writeBridge` invocation, which runs before the image build and stages the
   generated sources into the build context. The demo's `BudgetView` Haskell type feeds both JSON and the
   generated PureScript — and carries the `message` field — so the front-end types cannot drift from the
   API. See [purescript](../languages/purescript.md).
2. `spago build` — compile the Halogen SPA (Overview / Budget / Status tabs)
   against the generated types.
3. `esbuild --bundle --minify` — bundle the compiled output into the served
   `public/app.js`.

The Playwright e2e suite is not part of the image build. It runs in the `test run all` harness's
`e2e-tabs` case, from the already-built project image on the VM host network against that case's exact
runtime-resolved web exposure. Because the project image inherits the base image's global Playwright install
and browser cache, the harness runs the e2e from that baked install: it does not pull a separate
`mcr.microsoft.com/playwright:*` image and does not run `npm install` or `npx` at test time. See
[playwright](../languages/playwright.md) and the [demo runbook](../operations/demo_runbook.md).

## Build-stage ordering

The ordering is load-bearing and every derived project preserves it:

| Order | Step | Why it is here |
|---|---|---|
| 1 | `FROM ${BASE_IMAGE}` + `COPY` | Inherit the warm-store base; bring the source in. |
| 2 | Named-context builder at `/usr/local/libexec` + secret config | Authenticate with coordinator-selected bytes while keeping the runtime path absent. |
| 3 | Authenticated libexec `check-code` | Fail fast on violations before the source and web builds. |
| 4 | Warning-clean source build | Reuse matching cache artifacts, allow normal online misses, and select a non-empty Cabal product. |
| 5 | `spago build` → `esbuild` over the `writeBridge`-staged sources | Compile and bundle the generated PureScript types. |
| 6 | Final runtime materialization + exported-image probe | Rewrite binary, config, keys, and web output in the final layer; remove build-only authority; then verify the exported image. |
| 7 | tini ENTRYPOINT | tini is PID 1 for correct signal handling. |

## Current Status

The worked demo Dockerfile follows the current authenticated ordering and consumes a fresh ephemeral
`BuildInvocationAuthority`; it does not mint its own image-build config. The reusable protocol is implemented by the
[authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md);
the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns this reference Dockerfile's
command/channel adoption and live container evidence.

This is the reference shape; see [derived project standards](derived_project_standards.md)
for the broader rules every derived project follows.
