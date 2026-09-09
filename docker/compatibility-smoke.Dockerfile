# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# The real-consumer compatibility smoke for a freshly published base tag.
#
# Phase 23's gate ends "publish rolling tag -> pull -> real-consumer
# compatibility smoke", and this is that consumer. It asks the one question the
# smoke exists to answer: is the image that was just published usable by a
# project that builds FROM it?
#
# It is deliberately NOT the demo's Dockerfile. That one authenticates a
# separately selected builder and consumes a signed one-use build grant minted by
# the project binary's build coordinator, so driving it would require the Python
# bootstrapper to mint build authority — a second authority surface the
# architecture exists to prevent. The demo's own authenticated build is exercised
# by the worked-demo phase, through the coordinator that owns it.
#
# Build with:
#   docker build -f docker/compatibility-smoke.Dockerfile --build-arg BASE_IMAGE=<digest> .

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

# A derived project resolves and builds against the inherited store without
# network access to a package index it did not publish. Resolution alone is the
# check: a full build would measure the store's contents rather than its
# usability, and would put a multi-minute compile inside a publication gate.
WORKDIR /opt/basecontainer/haskell-deps
RUN set -eu; \
    cabal build --dry-run all; \
    echo "compatibility smoke: the inherited store resolves for a derived build"
