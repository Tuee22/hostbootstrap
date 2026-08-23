# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# The idiomatic hostbootstrap-demo project container — the reference shape every
# derived project copies (see documents/engineering/derived_dockerfile.md). It
# inherits the warm-store base, builds and installs the project binary
# (opportunistically reusing matching inherited artifacts), creates the project-local container
# config, runs the in-Dockerfile `check-code` quality gate, then builds the web
# bundle (purescript-bridge -> spago -> esbuild). tini is PID 1.
#
# Build context is the REPO ROOT (so the L0-direct demo can reach
# hostbootstrap-core's source); build with:
#   docker build -f demo/docker/Dockerfile --build-arg BASE_IMAGE=<tag> .

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# The verification key is public but is provisioned independently of source,
# config, and the signed handoff envelope.  Build #3 supplies the exact public
# half installed beside the root binary.
ARG HANDOFF_VERIFICATION_KEY_HEX

WORKDIR /workspace
# The demo is L0-direct: it needs hostbootstrap-core's source (the in-repo
# cabal.project references ../core/hostbootstrap-core).
COPY core/hostbootstrap-core /workspace/core/hostbootstrap-core
COPY demo /workspace/demo

WORKDIR /workspace/demo
# The coordinator-selected builder is an integrity-bound named build context;
# it is not confidential and can exceed BuildKit's 500 KiB secret limit.  The
# canonical image-build config remains a secret.  Both are installed before
# any source-generated binary can authorize the gate, and the signed channel
# binds their exact bytes.
COPY --from=hostbootstrap-builder hostbootstrap-demo /usr/local/bin/hostbootstrap-demo
RUN --mount=type=secret,id=hostbootstrap-build-config,required=true \
    chmod 0755 /usr/local/bin/hostbootstrap-demo \
    && install -m 0644 /run/secrets/hostbootstrap-build-config /usr/local/bin/hostbootstrap-demo.dhall \
    && test "${#HANDOFF_VERIFICATION_KEY_HEX}" -eq 64 \
    && python3 -c "import binascii,sys; open('/usr/local/bin/hostbootstrap-demo.handoff.pub','wb').write(binascii.unhexlify(sys.argv[1]))" "${HANDOFF_VERIFICATION_KEY_HEX}" \
    && chmod 0644 /usr/local/bin/hostbootstrap-demo.handoff.pub

# The mandatory code-check quality gate accepts only the signed, one-RUN secret
# presentation. No channel or verification key is persisted in the image.
RUN --mount=type=secret,id=hostbootstrap-build-channel,required=true \
    --mount=type=secret,id=hostbootstrap-build-verification,required=true \
    --mount=type=secret,id=hostbootstrap-build-coordinator,required=true \
    hostbootstrap-demo check-code

# Build and install the source-produced binary only after the independently
# selected builder has authenticated and passed the warning-clean gate.
RUN cabal build --enable-tests --enable-benchmarks all \
    && install -m 0755 "$(cabal list-bin --enable-tests --enable-benchmarks exe:hostbootstrap-demo)" /usr/local/bin/hostbootstrap-demo

# The web build: compile the Halogen SPA from the bridge-generated PureScript
# types and bundle it. The bridge codegen is re-homed into the build-image chain
# step (it runs before this image build and stages the generated sources into the
# context), so there is no `web bridge` verb — the command surface is fixed
# (development_plan_standards § P).
RUN cd web \
    && spago build \
    && esbuild --bundle --minify --outfile=public/app.js src/index.js

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/hostbootstrap-demo"]
