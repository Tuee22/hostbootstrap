# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# The real-consumer compatibility smoke for a newly built or freshly published base tag.
#
# The base-image-and-warm-store phase runs this consumer once against the fresh
# local image ID before publication and once against the exact pulled digest. It
# asks the one question
# the smoke exists to answer: is this image usable by a project that builds FROM it?
#
# It asks that question of a package the base has never seen. Resolving
# /opt/basecontainer/haskell-deps — the warm store's own package set — is close
# to tautological: it re-resolves the very description whose resolution produced
# the store, so it would succeed on an image no derived project could use. The
# consumer written below is a separate package with its own name, version and
# dependency list, and it names the dependency shape a real derived project has
# rather than the store's.
#
# It is deliberately NOT the demo's Dockerfile. That one needs the
# `hostbootstrap-builder` named build context, the `hostbootstrap-build-config`
# secret, and a `check-code` step whose one RUN presents the
# `hostbootstrap-build-channel`, `hostbootstrap-build-verification` and
# `hostbootstrap-build-coordinator` secrets. Driving it would require the Python
# bootstrapper to mint build authority, a second authority surface the
# architecture exists to prevent. The demo's own authenticated build is exercised
# by the worked-demo phase, through the coordinator that owns it.
#
# Build with:
#   docker build -f docker/compatibility-smoke.Dockerfile --build-arg BASE_IMAGE=<reference> .

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# The compiler and the package tool the base exists to carry.
RUN set -eu; \
    ghc --version; \
    cabal --version; \
    echo "compatibility smoke: the toolchain starts"

# The same toolchain is reachable by an arbitrary non-root uid, as a container leg
# that runs as the host's uid needs it to be.
RUN set -eu; \
    setpriv --reuid=65534 --regid=65534 --clear-groups -- ghc --numeric-version; \
    setpriv --reuid=65534 --regid=65534 --clear-groups -- cabal --numeric-version; \
    echo "compatibility smoke: the toolchain starts as a non-root uid"

# The warm store: $CABAL_DIR is set, a store directory keyed to this image's own
# compiler exists, and at least one package is registered in it. A store keyed
# to another compiler fails here.
RUN set -eu; \
    test -d "${CABAL_DIR:?CABAL_DIR is not set in the published base}"; \
    set -- "${CABAL_DIR}/store/ghc-$(ghc --numeric-version)-"*; \
    test -d "$1"; \
    set -- "$1"/package.db/*.conf; \
    test -f "$1"; \
    echo "compatibility smoke: the warm store matches the compiler and holds packages"

# The code-check doctrine treats the presence of the formatter and the linter as
# part of what the base guarantees. They also run in the host source gate
# (`_style_gates` in hostbootstrap/cli.py), in the base build's sample check and
# in every derived project's container check-code, so an image without them
# would fail those places rather than here; they are started here.
RUN set -eu; \
    fourmolu --version; \
    hlint --version; \
    echo "compatibility smoke: the style tools the base guarantees both start"

# A derived project resolves a complete build plan on this image. Resolution
# alone is the check: a full build would measure the store's contents rather
# than its usability, and would put a multi-minute compile inside a publication
# gate. The plan is allowed to reuse store artifacts where they match and to
# resolve normally where they do not — that is the warm store's stated contract,
# an opportunistic cache rather than a lock, so a plan that names downloads is a
# pass and a plan that cannot be produced at all is the failure this catches.
RUN set -eu; \
    mkdir -p /tmp/compatibility-smoke/src; \
    printf '%s\n' \
      'cabal-version: 2.4' \
      'name: hostbootstrap-compatibility-smoke' \
      'version: 0.1.0.0' \
      'build-type: Simple' \
      '' \
      'library' \
      '  default-language: Haskell2010' \
      '  hs-source-dirs: src' \
      '  exposed-modules: ConsumerProbe' \
      '  build-depends:' \
      '      base' \
      '    , bytestring' \
      '    , containers' \
      '    , dhall' \
      '    , filepath' \
      '    , optparse-applicative' \
      '    , split' \
      '    , text' \
      > /tmp/compatibility-smoke/hostbootstrap-compatibility-smoke.cabal; \
    printf '%s\n' \
      'module ConsumerProbe (probe) where' \
      '' \
      'probe :: Int' \
      'probe = 0' \
      > /tmp/compatibility-smoke/src/ConsumerProbe.hs; \
    printf '%s\n' \
      'packages: .' \
      'optimization: 2' \
      > /tmp/compatibility-smoke/cabal.project; \
    cd /tmp/compatibility-smoke; \
    cabal build --dry-run all; \
    echo "compatibility smoke: a derived consumer resolves a complete build plan"
