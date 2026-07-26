# syntax=docker/dockerfile:1.7
#
# Rolling, native-architecture hostbootstrap base. Current compatible upstream
# versions/URLs are resolved by hostbootstrap/base_image.py for each build.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG IMAGE_FLAVOR
ARG TARGETARCH
ARG LLVM_MAJOR
ARG HASKELL_STYLE_TOOLS_DIR
ARG GO_VERSION
ARG GO_DOWNLOAD_URL
ARG NODE_VERSION
ARG NODE_DOWNLOAD_URL
ARG PURESCRIPT_VERSION
ARG PURESCRIPT_DOWNLOAD_URL
ARG KIND_VERSION
ARG KIND_DOWNLOAD_URL
ARG KUBECTL_VERSION
ARG KUBECTL_DOWNLOAD_URL
ARG HELM_VERSION
ARG HELM_DOWNLOAD_URL
ARG PULUMI_VERSION
ARG PULUMI_DOWNLOAD_URL
ARG GHCUP_DOWNLOAD_URL
ARG MC_DOWNLOAD_URL
ARG AWS_DOWNLOAD_URL
ARG CABAL_BUILD_JOBS=1
ARG GHC_RTS_OPTS=

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    rm -f /etc/apt/sources.list.d/cuda-*.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        bolt-${LLVM_MAJOR} \
        ca-certificates \
        clang-${LLVM_MAJOR} \
        cmake \
        curl \
        dnsutils \
        docker-compose-v2 \
        docker.io \
        file \
        g++ \
        gcc \
        gdb \
        git \
        gnupg \
        iproute2 \
        iptables \
        jq \
        less \
        libclang-rt-${LLVM_MAJOR}-dev \
        libdnnl-dev \
        libffi-dev \
        libgmp-dev \
        libmimalloc-dev \
        libncurses-dev \
        libnuma-dev \
        libpq-dev \
        libssl-dev \
        libtinfo-dev \
        lld-${LLVM_MAJOR} \
        llvm-${LLVM_MAJOR} \
        llvm-${LLVM_MAJOR}-dev \
        make \
        ninja-build \
        openssh-client \
        perl \
        pkg-config \
        protobuf-compiler \
        python3 \
        python3-dev \
        python-is-python3 \
        python3-pip \
        python3-venv \
        skopeo \
        sudo \
        tini \
        unzip \
        wget \
        xz-utils \
        zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    mkdir -p /workspace /opt/build /opt/cache /opt/cache/go/bin /opt/cache/go/build /opt/cache/go/mod /usr/local/lib; \
    ln -s "/usr/lib/llvm-${LLVM_MAJOR}" /opt/llvm; \
    test -f /opt/llvm/lib/libbolt_rt_instr.a; \
    ln -sf /opt/llvm/lib/libbolt_rt_instr.a /usr/local/lib/libbolt_rt_instr.a

ENV BASECONTAINER_SOURCE_ROOT=/workspace \
    BASECONTAINER_BUILD_ROOT=/opt/build \
    BASECONTAINER_CACHE_ROOT=/opt/cache \
    CABAL_DIR=/opt/cache/cabal \
    PIP_CACHE_DIR=/opt/cache/python/pip \
    POETRY_CACHE_DIR=/opt/cache/python/pypoetry \
    POETRY_VIRTUALENVS_CREATE=false \
    POETRY_VIRTUALENVS_IN_PROJECT=false \
    PYTHONPYCACHEPREFIX=/opt/build/python/pycache \
    NPM_CONFIG_CACHE=/opt/cache/npm \
    NPM_CONFIG_PREFIX=/opt/build/node/global \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    CARGO_HOME=/opt/cache/cargo \
    CARGO_TARGET_DIR=/opt/build/rust/target \
    GOROOT=/opt/go \
    GOPATH=/opt/cache/go \
    GOCACHE=/opt/cache/go/build \
    GOMODCACHE=/opt/cache/go/mod \
    GOTOOLCHAIN=local \
    LLVM_CONFIG=/opt/llvm/bin/llvm-config \
    LIBRARY_PATH=/opt/llvm/lib \
    BOLT_RT_INSTR_LIB=/opt/llvm/lib/libbolt_rt_instr.a \
    HASKELL_STYLE_TOOLS_DIR=${HASKELL_STYLE_TOOLS_DIR} \
    CC=clang-${LLVM_MAJOR} \
    CXX=clang++-${LLVM_MAJOR} \
    RUSTUP_TOOLCHAIN=stable \
    CARGO_HTTP_TIMEOUT=120 \
    CARGO_NET_RETRY=5 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

ENV PATH=/opt/llvm/bin:/opt/pulumi:/opt/go/bin:/opt/cache/go/bin:/root/.ghcup/bin:/opt/cache/cabal/bin:${HASKELL_STYLE_TOOLS_DIR}:/root/.cabal/bin:/opt/cache/cargo/bin:/opt/build/node/global/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN set -eux; \
    tmpdir="$(mktemp -d)"; \
    curl -fsSL "${GO_DOWNLOAD_URL}" -o "${tmpdir}/go.tar.gz"; \
    rm -rf /opt/go; \
    tar -xzf "${tmpdir}/go.tar.gz" -C /opt; \
    rm -rf "${tmpdir}"; \
    /opt/go/bin/go version | grep -F "go${GO_VERSION}"

RUN set -eux; \
    CGO_ENABLED=1 /opt/go/bin/go install "github.com/NVIDIA/nvkind/cmd/nvkind@latest"; \
    install -m 0755 /opt/cache/go/bin/nvkind /usr/local/bin/nvkind; \
    /usr/local/bin/nvkind --help >/dev/null

RUN set -eux; \
    export PIP_BREAK_SYSTEM_PACKAGES=1; \
    python -m pip install --ignore-installed --upgrade pip setuptools wheel poetry; \
    python -m pip --version; \
    poetry --version

RUN set -eux; \
    tmpdir="$(mktemp -d)"; \
    curl -fsSL "${NODE_DOWNLOAD_URL}" -o "${tmpdir}/node.tar.xz"; \
    tar -xJf "${tmpdir}/node.tar.xz" -C /usr/local --strip-components=1; \
    rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack; \
    printf '%s\n' \
      '#!/bin/sh' \
      'exec /usr/local/bin/node /usr/local/lib/node_modules/npm/bin/npm-cli.js "$@"' \
      > /usr/local/bin/npm; \
    chmod 0755 /usr/local/bin/npm; \
    rm -rf "${tmpdir}"; \
    node --version | grep -Fx "${NODE_VERSION}"; \
    NPM_CONFIG_PREFIX=/usr/local npm install -g npm; \
    npm --version

RUN set -eux; \
    tmpdir="$(mktemp -d)"; \
    curl -fsSL "${PURESCRIPT_DOWNLOAD_URL}" -o "${tmpdir}/purescript.tar.gz"; \
    tar -xzf "${tmpdir}/purescript.tar.gz" -C "${tmpdir}"; \
    install -m 0755 "${tmpdir}/purescript/purs" /usr/local/bin/purs; \
    rm -rf "${tmpdir}"; \
    purs --version | grep -Fx "${PURESCRIPT_VERSION#v}"

RUN set -eux; \
    npm install -g @playwright/test esbuild playwright purs-tidy spago typescript; \
    playwright install --with-deps chromium firefox webkit; \
    rm -rf /root/.npm

RUN set -eux; \
    tmpdir="$(mktemp -d)"; \
    curl -fsSL "${GHCUP_DOWNLOAD_URL}" -o "${tmpdir}/ghcup"; \
    install -m 0755 "${tmpdir}/ghcup" /usr/local/bin/ghcup; \
    curl -fsSL "${KIND_DOWNLOAD_URL}" -o "${tmpdir}/kind"; \
    install -m 0755 "${tmpdir}/kind" /usr/local/bin/kind; \
    kind version | grep -F "${KIND_VERSION}"; \
    curl -fsSL "${KUBECTL_DOWNLOAD_URL}" -o "${tmpdir}/kubectl"; \
    install -m 0755 "${tmpdir}/kubectl" /usr/local/bin/kubectl; \
    kubectl version --client | grep -F "${KUBECTL_VERSION}"; \
    curl -fsSL "${HELM_DOWNLOAD_URL}" -o "${tmpdir}/helm.tgz"; \
    tar -xzf "${tmpdir}/helm.tgz" -C "${tmpdir}"; \
    install -m 0755 "${tmpdir}/linux-${TARGETARCH}/helm" /usr/local/bin/helm; \
    helm version --short | grep -F "${HELM_VERSION}"; \
    curl -fsSL "${MC_DOWNLOAD_URL}" -o "${tmpdir}/mc"; \
    install -m 0755 "${tmpdir}/mc" /usr/local/bin/mc; \
    mc --version; \
    curl -fsSL "${AWS_DOWNLOAD_URL}" -o "${tmpdir}/awscliv2.zip"; \
    unzip -q "${tmpdir}/awscliv2.zip" -d "${tmpdir}"; \
    "${tmpdir}/aws/install" --install-dir /opt/aws-cli --bin-dir /usr/local/bin; \
    aws --version; \
    curl -fsSL "${PULUMI_DOWNLOAD_URL}" -o "${tmpdir}/pulumi.tgz"; \
    tar -xzf "${tmpdir}/pulumi.tgz" -C /opt; \
    pulumi version | grep -Fx "${PULUMI_VERSION}"; \
    rm -rf "${tmpdir}"

RUN set -eux; \
    ghcup install ghc recommended; \
    ghcup set ghc recommended; \
    ghcup install cabal recommended; \
    ghcup set cabal recommended; \
    ghc --numeric-version; \
    cabal --numeric-version

RUN set -eux; \
    mkdir -p "${HASKELL_STYLE_TOOLS_DIR}"; \
    cabal update; \
    cabal install \
        --ignore-project \
        --installdir "${HASKELL_STYLE_TOOLS_DIR}" \
        --install-method=copy \
        --overwrite-policy=always \
        fourmolu \
        hlint; \
    ln -sf "${HASKELL_STYLE_TOOLS_DIR}/fourmolu" /usr/local/bin/fourmolu; \
    ln -sf "${HASKELL_STYLE_TOOLS_DIR}/hlint" /usr/local/bin/hlint

RUN set -eux; \
    tmpdir="$(mktemp -d)"; \
    curl -fsSL https://sh.rustup.rs -o "${tmpdir}/rustup-init.sh"; \
    sh "${tmpdir}/rustup-init.sh" -y --profile minimal --default-toolchain stable; \
    rm -rf "${tmpdir}"; \
    rustup component add llvm-tools-preview rustfmt; \
    rustc --version; \
    rustfmt --version

COPY core/warm-deps/ /opt/basecontainer/haskell-deps/

# Populate one best-effort store. Consumers use their normal cabal.project and
# may resolve/download/compile any missing or incompatible dependency.
RUN set -eux; \
    export GHCRTS="${GHC_RTS_OPTS}"; \
    cd /opt/basecontainer/haskell-deps; \
    cabal update; \
    cabal build all --only-dependencies -j${CABAL_BUILD_JOBS}; \
    cabal build all -j${CABAL_BUILD_JOBS}

RUN set -eux; \
    fourmolu --version; \
    hlint --version; \
    cd /opt/basecontainer/haskell-deps; \
    fourmolu --mode check core/app daemon/app; \
    hlint core/app daemon/app

# One Dockerfile serves CPU and CUDA parents. This filesystem-only check is the
# documented conditional exception and requires no host GPU.
RUN set -eux; \
    if [ -d /usr/local/cuda/lib64 ]; then \
      printf '/usr/local/cuda/lib64\n' > /etc/ld.so.conf.d/cuda.conf; \
      ldconfig; \
    fi

WORKDIR /workspace
