# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# The idiomatic hostbootstrap-demo project container — the reference shape every
# derived project copies (see documents/engineering/derived_dockerfile.md). It
# inherits the warm-store base, authenticates a separate builder, builds and installs the project binary
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
ARG ACTIVATION_VERIFICATION_KEY_HEX

WORKDIR /workspace
# The demo is L0-direct: it needs hostbootstrap-core's source (the in-repo
# cabal.project references ../core/hostbootstrap-core).
COPY core/hostbootstrap-core /workspace/core/hostbootstrap-core
COPY demo /workspace/demo

WORKDIR /workspace/demo
# The coordinator-selected builder is an integrity-bound named build context;
# it is not confidential and can exceed BuildKit's 500 KiB secret limit.  The
# canonical image-build config remains a secret. The builder is installed at
# a distinct libexec path before
# any source-generated binary can authorize the gate, and the signed channel
# binds their exact bytes. The final runtime entrypoint path is deliberately
# absent until the source-built binary is materialized in the final layer.
COPY --from=hostbootstrap-builder hostbootstrap-demo /usr/local/libexec/hostbootstrap-demo
RUN --mount=type=secret,id=hostbootstrap-build-config,required=true \
    chmod 0755 /usr/local/libexec/hostbootstrap-demo \
    && install -m 0644 /run/secrets/hostbootstrap-build-config /usr/local/libexec/hostbootstrap-demo.dhall \
    && install -m 0644 /run/secrets/hostbootstrap-build-config /usr/local/bin/hostbootstrap-demo.dhall \
    && test "${#HANDOFF_VERIFICATION_KEY_HEX}" -eq 64 \
    && test "${#ACTIVATION_VERIFICATION_KEY_HEX}" -eq 64 \
    && python3 -c "import binascii,sys; open('/usr/local/libexec/hostbootstrap-demo.handoff.pub','wb').write(binascii.unhexlify(sys.argv[1]))" "${HANDOFF_VERIFICATION_KEY_HEX}" \
    && python3 -c "import binascii,sys; open('/usr/local/libexec/hostbootstrap-demo.activation.pub','wb').write(binascii.unhexlify(sys.argv[1]))" "${ACTIVATION_VERIFICATION_KEY_HEX}" \
    && install -m 0644 /usr/local/libexec/hostbootstrap-demo.handoff.pub /usr/local/bin/hostbootstrap-demo.handoff.pub \
    && install -m 0644 /usr/local/libexec/hostbootstrap-demo.activation.pub /usr/local/bin/hostbootstrap-demo.activation.pub \
    && chmod 0644 /usr/local/libexec/hostbootstrap-demo.handoff.pub /usr/local/libexec/hostbootstrap-demo.activation.pub

# The mandatory code-check quality gate accepts only the signed, one-RUN secret
# presentation. No channel or verification key is persisted in the image.
RUN --mount=type=secret,id=hostbootstrap-build-channel,required=true \
    --mount=type=secret,id=hostbootstrap-build-verification,required=true \
    --mount=type=secret,id=hostbootstrap-build-coordinator,required=true \
    /usr/local/libexec/hostbootstrap-demo check-code

# Build the source-produced binary only after the independently selected
# builder has authenticated and passed the warning-clean gate.
RUN cabal build -j1 --enable-tests --enable-benchmarks all --ghc-options=-Werror \
    && built_binary="$(cabal list-bin --enable-tests --enable-benchmarks exe:hostbootstrap-demo)" \
    && test -s "${built_binary}"

# The web build: compile the Halogen SPA from the bridge-generated PureScript
# types and bundle it. The bridge codegen is re-homed into the build-image chain
# step (it runs before this image build and stages the generated sources into the
# context), so there is no `web bridge` verb — the command surface is fixed
# (development_plan_standards § P).
RUN cd web \
    && spago build \
    && esbuild --bundle --minify --outfile=public/app.js src/index.js

# The authenticated builder is already a source-built, digest-bound executable.
# Keep the in-image Cabal product as a checked build result, materialize the
# authenticated bytes at the ordinary runtime path in the final layer, and
# remove the build-only authority. BuildKit can otherwise export a large
# directly copied or linked executable as an empty snapshot even though an
# in-layer test -s succeeds.
RUN built_binary="$(cabal list-bin --enable-tests --enable-benchmarks exe:hostbootstrap-demo)" \
    && test -s "${built_binary}" \
    && dd if=/usr/local/libexec/hostbootstrap-demo of=/usr/local/bin/hostbootstrap-demo bs=4M status=none \
    && dd if=/usr/local/libexec/hostbootstrap-demo.dhall of=/usr/local/bin/hostbootstrap-demo.dhall status=none \
    && dd if=/usr/local/libexec/hostbootstrap-demo.handoff.pub of=/usr/local/bin/hostbootstrap-demo.handoff.pub status=none \
    && dd if=/usr/local/libexec/hostbootstrap-demo.activation.pub of=/usr/local/bin/hostbootstrap-demo.activation.pub status=none \
    && dd if=web/public/app.js of=web/public/app.runtime.js status=none \
    && rm web/public/app.js \
    && mv web/public/app.runtime.js web/public/app.js \
    && chmod 0755 /usr/local/bin/hostbootstrap-demo \
    && chmod 0644 /usr/local/bin/hostbootstrap-demo.dhall \
        /usr/local/bin/hostbootstrap-demo.handoff.pub \
        /usr/local/bin/hostbootstrap-demo.activation.pub \
        web/public/app.js \
    && rm /usr/local/libexec/hostbootstrap-demo \
    && rm /usr/local/libexec/hostbootstrap-demo.dhall \
    && rm /usr/local/libexec/hostbootstrap-demo.handoff.pub \
    && rm /usr/local/libexec/hostbootstrap-demo.activation.pub \
    && test -s /usr/local/bin/hostbootstrap-demo \
    && test -s /usr/local/bin/hostbootstrap-demo.dhall \
    && test "$(stat -c %s /usr/local/bin/hostbootstrap-demo.handoff.pub)" -eq 32 \
    && test "$(stat -c %s /usr/local/bin/hostbootstrap-demo.activation.pub)" -eq 32 \
    && test -s web/public/app.js

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/hostbootstrap-demo"]
