# Derived Dockerfile

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [derived project standards](derived_project_standards.md), [code check doctrine](code_check_doctrine.md), [development plan](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md)

> **Purpose**: Define the idiomatic derived-project Dockerfile shape — the in-Dockerfile `check-code` gate, the `purescript-bridge` → `spago` → `esbuild` web build, and the build-stage ordering — using the worked `hostbootstrap-demo` container as the reference.

## TL;DR

- A derived project's container is built **by the project binary**, not by the
  Python bootstrapper (see
  [build and run model](../architecture/build_and_run_model.md) is referenced from
  the runbook; here the binary is the builder).
- The idiomatic container is `FROM ${BASE_IMAGE}` → build + install the project
  binary (reusing the warm store) → `RUN <project> check-code` → web build
  (`<project> web bridge` →
  `spago build` → `esbuild`) → tini ENTRYPOINT.
- The in-Dockerfile `check-code` step is a **build-time gate**: an image with
  style or lint violations cannot be produced. See
  [code check doctrine](code_check_doctrine.md).
- `demo/docker/Dockerfile` is the worked example and the reference shape derived
  projects copy.

## The reference shape

The idiomatic derived Dockerfile (the worked example is `demo/docker/Dockerfile`)
inherits the warm-store base image, builds and installs the project binary
(reusing the warm store), runs the code-check gate, then builds the web bundle,
with tini as PID 1. Its skeleton:

```dockerfile
# check=skip=InvalidDefaultArgInFrom

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace/<project>
COPY . /workspace/<project>

# 1. Build/install the project binary (reusing the layered warm store).
RUN cabal build --enable-tests --enable-benchmarks all \
    && install -m 0755 "$(cabal list-bin ... exe:<project>)" /usr/local/bin/<project>

# 2. The mandatory code-check gate.
RUN <project> check-code

# 3. The web build.
RUN <project> web bridge \
    && cd web \
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

After the binary is installed, the Dockerfile runs `RUN <project> check-code`. This
is the inherited core `check-code` verb whose body is project-defined; the demo
runs it as `hostbootstrap-demo check-code`. Because it is a `RUN` step, a non-zero
exit fails the image build: the image cannot exist with style or lint violations.
This is the derived-project half of the rule in
[code check doctrine](code_check_doctrine.md). The gate runs **before** the web
build so a failing check stops the build early.

## The web build

The web build follows the gate, in three ordered steps:

1. `<project> web bridge` — generate the PureScript types from the servant API via
   `purescript-bridge`. The demo's `DemoApi` Haskell types feed both JSON and the
   generated PureScript, so the front-end types cannot drift from the API. See
   [purescript](../languages/purescript.md).
2. `spago build` — compile the Halogen SPA (Overview / Budget / Status tabs)
   against the generated types.
3. `esbuild --bundle --minify` — bundle the compiled output into the served
   `public/app.js`.

The Playwright e2e suite is not part of the image build; it runs from the container
against the incus-host `baseURL` during a demo run. See
[playwright](../languages/playwright.md) and the
[demo runbook](../operations/demo_runbook.md).

## Build-stage ordering

The ordering is load-bearing and every derived project preserves it:

| Order | Step | Why it is here |
|---|---|---|
| 1 | `FROM ${BASE_IMAGE}` + `COPY` | Inherit the warm-store base; bring the source in. |
| 2 | Build + install the binary | The web build and the gate both need the installed binary. |
| 3 | `RUN <project> check-code` | Fail fast on violations before the more expensive web build. |
| 4 | `web bridge` → `spago build` → `esbuild` | Types must exist before `spago`; the bundle is the last artifact. |
| 5 | tini ENTRYPOINT | tini is PID 1 for correct signal handling. |

This is the reference shape; see [derived project standards](derived_project_standards.md)
for the broader rules every derived project follows.
