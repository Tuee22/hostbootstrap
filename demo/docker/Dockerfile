# check=skip=InvalidDefaultArgInFrom
#
# The idiomatic hostbootstrap-demo project container — the reference shape every
# derived project copies (see documents/engineering/derived_dockerfile.md). It
# inherits the warm-store base, installs the host-native-built binary, runs the
# in-Dockerfile `check-code` quality gate, then builds the web bundle
# (purescript-bridge -> spago -> esbuild). tini is PID 1.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace/hostbootstrap-demo

COPY . /workspace/hostbootstrap-demo

# The project binary is built host-native by `hostbootstrap up` and installed
# here; the container build reuses the warm store via the layered core.freeze.
RUN cabal build --enable-tests --enable-benchmarks all \
    && install -m 0755 "$(cabal list-bin --enable-tests --enable-benchmarks exe:hostbootstrap-demo)" /usr/local/bin/hostbootstrap-demo

# The mandatory code-check quality gate: the image cannot exist with violations.
RUN hostbootstrap-demo check-code

# The web build: generate PureScript types from the servant API, then bundle.
RUN hostbootstrap-demo web bridge \
    && cd web \
    && spago build \
    && esbuild --bundle --minify --outfile=public/app.js src/index.js

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/hostbootstrap-demo"]
