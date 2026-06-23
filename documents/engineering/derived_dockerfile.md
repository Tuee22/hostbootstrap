# Derived Dockerfile

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [derived project standards](derived_project_standards.md), [code check doctrine](code_check_doctrine.md), [binary context](../architecture/binary_context_config.md), [development plan](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md), [phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md)

> **Purpose**: Define the idiomatic derived-project Dockerfile shape — the in-Dockerfile `check-code` gate, the `purescript-bridge` → `spago` → `esbuild` web build, and the build-stage ordering — using the worked `hostbootstrap-demo` container as the reference.

## TL;DR

- A derived project's container is built **by the project binary**, not by the
  Python bootstrapper: the binary is the builder (see
  [build and run model](../architecture/build_and_run_model.md)).
- The reference container is `FROM ${BASE_IMAGE}` → build + install the project
  binary (reusing the warm store) → create the image-build sibling
  `<project>.dhall` → `RUN <project> check-code` → web build (`spago build` → `esbuild`
  over the bridge-generated sources the build-image step's `writeBridge` invocation
  staged into the context) → tini ENTRYPOINT.
- The in-Dockerfile `check-code` step is a **build-time gate**: an image with
  style or lint violations cannot be produced. See
  [code check doctrine](code_check_doctrine.md).
- `demo/docker/Dockerfile` is the worked example and the reference shape derived
  projects copy.

## The reference shape

The derived Dockerfile (the worked example is `demo/docker/Dockerfile`) inherits the warm-store base
image, builds and installs the project binary (reusing the warm store), writes the image-build sibling
`<project>.dhall`, runs the code-check gate, then builds the web bundle, with tini as PID 1. When the
container runs `project up` in the deploy stack, the parent frame's `context-init` step mounts a freshly
minted runtime `<project>.dhall` over the baked image-build file at the binary's sibling-config path. Its
skeleton:

```dockerfile
# check=skip=InvalidDefaultArgInFrom

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace/<project>
COPY . /workspace/<project>

# 1. Build/install the project binary (reusing the layered warm store).
RUN cabal build --enable-tests --enable-benchmarks all \
    && install -m 0755 "$(cabal list-bin ... exe:<project>)" /usr/local/bin/<project>

# 2. Create the image-build config next to /usr/local/bin/<project>.
RUN <project> project init --role image-build-container --output /usr/local/bin/<project>.dhall

# 3. The mandatory code-check gate.
RUN <project> check-code

# 4. The web build. The bridge codegen is re-homed into the build-image chain
#    step's `writeBridge` invocation, which runs BEFORE this image build and
#    stages the generated PureScript sources into the build context — there is no
#    `web bridge` verb. The Dockerfile only compiles and bundles them.
RUN cd web \
    && spago build \
    && esbuild --bundle --minify --outfile=public/app.js src/index.js

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/<project>"]
```

## Parser directive

The first line is the `# check=skip=InvalidDefaultArgInFrom` parser directive. It
suppresses the BuildKit warning for the `ARG BASE_IMAGE` / `FROM ${BASE_IMAGE}`
pattern: the base image tag is supplied at build time by the project binary rather
than defaulted in the Dockerfile, which is the intended shape, so the warning is
skipped rather than worked around. Derived projects copy this directive verbatim.

## The base inheritance

`FROM ${BASE_IMAGE}` inherits the warm-store base
([base image](base_image.md)). The container build reuses the warm Cabal store via
the layered `core.freeze` ([warm store](warm_store.md)), so the binary build in the
container is a cache hit against the same pins the host-native build used — the
demo's `purescript-bridge` dependency lives in that warm store's `core.freeze`.

## The `check-code` gate

After the binary is installed, the Dockerfile first runs the bootstrap-only config initialization
entrypoint, for example
`RUN <project> project init --role image-build-container --output /usr/local/bin/<project>.dhall`. That
Dhall file is stored next to the binary and tells subsequent image-build commands that they have
build-time authority only. The initialization entrypoint is the only command allowed to run before the
sibling config exists; normal commands fail fast without it. See
[binary context](../architecture/binary_context_config.md).

Then the Dockerfile runs `RUN <project> check-code`. This
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
`e2e-tabs` case, from the already-built project image on the kind network against that case's in-cluster
service via its NodePort. Because the project image inherits the base image's global Playwright install
and browser cache, the harness runs the e2e from that baked install: it does not pull a separate
`mcr.microsoft.com/playwright:*` image and does not run `npm install` or `npx` at test time. See
[playwright](../languages/playwright.md) and the [demo runbook](../operations/demo_runbook.md).

## Build-stage ordering

The ordering is load-bearing and every derived project preserves it:

| Order | Step | Why it is here |
|---|---|---|
| 1 | `FROM ${BASE_IMAGE}` + `COPY` | Inherit the warm-store base; bring the source in. |
| 2 | Build + install the binary | The web build and the gate both need the installed binary. |
| 3 | `RUN <project> project init --role image-build-container ...` | Store the image-build sibling config before any normal command dispatch. |
| 4 | `RUN <project> check-code` | Fail fast on violations before the more expensive web build. |
| 5 | `spago build` → `esbuild` over the `writeBridge`-staged sources | The build-image step's `writeBridge` invocation staged the PureScript types into the context before this build; `spago` compiles them and the bundle is the last artifact. |
| 6 | tini ENTRYPOINT | tini is PID 1 for correct signal handling. |

This is the reference shape; see [derived project standards](derived_project_standards.md)
for the broader rules every derived project follows.
