# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# The real-consumer compatibility smoke for a newly built or freshly published base tag.
#
# Phase 23 runs this consumer once against the fresh local image ID before
# publication and once against the exact pulled digest. It asks the one question
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
# It is deliberately NOT the demo's Dockerfile. That one authenticates a
# separately selected builder and consumes a signed one-use build grant minted by
# the project binary's build coordinator, so driving it would require the Python
# bootstrapper to mint build authority — a second authority surface the
# architecture exists to prevent. The demo's own authenticated build is exercised
# by the worked-demo phase, through the coordinator that owns it.
#
# Build with:
#   docker build -f docker/compatibility-smoke.Dockerfile --build-arg BASE_IMAGE=<reference> .

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# The toolchain the base exists to carry, and the warm store derived projects
# build against. Each is a distinct failure: a missing compiler, a compiler the
# store was not built for, and an absent or unreadable store are different
# publication faults, so they are not collapsed into one command.
RUN set -eu; \
    ghc --version; \
    cabal --version; \
    test -d "${CABAL_DIR:?CABAL_DIR is not set in the published base}"; \
    test -d /opt/basecontainer/haskell-deps; \
    echo "compatibility smoke: toolchain and warm store present"

# The container code-check is the only place the formatter and the linter run,
# and the code-check doctrine treats their presence as part of what the base
# guarantees. An image that carries neither would fail every derived project's
# check-code at build time rather than here, so they are started here.
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
      '    , text' \
      > /tmp/compatibility-smoke/hostbootstrap-compatibility-smoke.cabal; \
    printf '%s\n' \
      'module ConsumerProbe (probe) where' \
      '' \
      'probe :: Int' \
      'probe = 0' \
      > /tmp/compatibility-smoke/src/ConsumerProbe.hs; \
    cd /tmp/compatibility-smoke; \
    cabal build --dry-run all; \
    echo "compatibility smoke: a derived consumer resolves a complete build plan"
