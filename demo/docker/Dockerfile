# check=skip=InvalidDefaultArgInFrom
#
# The idiomatic hostbootstrap-demo project container — the reference shape every
# derived project copies (see documents/engineering/derived_dockerfile.md). It
# inherits the warm-store base, builds and installs the project binary (reusing
# the warm store via the imported freeze), creates the container binary-context
# config, runs the in-Dockerfile `check-code` quality gate, then builds the web
# bundle (purescript-bridge -> spago -> esbuild). tini is PID 1.
#
# Build context is the REPO ROOT (so the L0-direct demo can reach
# hostbootstrap-core's source); build with:
#   docker build -f demo/docker/Dockerfile --build-arg BASE_IMAGE=<tag> .

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace
# The demo is L0-direct: it needs hostbootstrap-core's source (the in-repo
# cabal.project references ../core/hostbootstrap-core).
COPY core/hostbootstrap-core /workspace/core/hostbootstrap-core
COPY demo /workspace/demo

WORKDIR /workspace/demo
# Swap in the container cabal.project (imports the warm-store freeze) so only the
# project's own modules compile; the dependency closure is reused.
RUN cp docker/container.cabal.project cabal.project

# Build and install the project binary, reusing the base image's warm store.
RUN cabal build --enable-tests --enable-benchmarks all \
    && install -m 0755 "$(cabal list-bin --enable-tests --enable-benchmarks exe:hostbootstrap-demo)" /usr/local/bin/hostbootstrap-demo

# The bootstrap-only context hook is the one command allowed to run before the
# sibling project-binary-context-config.dhall exists.
RUN hostbootstrap-demo --create-container-config /usr/local/bin/project-binary-context-config.dhall

# The mandatory code-check quality gate: the image cannot exist with violations.
RUN hostbootstrap-demo check-code

# The web build: generate PureScript types from the API, compile the Halogen SPA,
# then bundle it.
RUN hostbootstrap-demo web bridge \
    && cd web \
    && spago build \
    && esbuild --bundle --minify --outfile=public/app.js src/index.js

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/hostbootstrap-demo"]
