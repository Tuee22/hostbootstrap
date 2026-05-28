# syntax=docker/dockerfile:1.7
ARG GO_BUILDER_IMAGE=golang:latest
ARG HASKELL_TOOLS_BASE_IMAGE=ubuntu:24.04
ARG BASE_IMAGE=ubuntu:24.04
ARG HASKELL_TOOLS_GHC_VERSION=9.12.4
ARG HASKELL_TOOLS_CABAL_VERSION=3.16.1.0

FROM --platform=$BUILDPLATFORM ${GO_BUILDER_IMAGE} AS nvkind-builder

ARG TARGETARCH
ARG BUILDARCH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) goarch=amd64; cc=gcc ;; \
      arm64) goarch=arm64; cc=gcc ;; \
      *) echo "unsupported target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    apt_packages="ca-certificates gcc libc6-dev"; \
    if [ "${TARGETARCH}" != "${BUILDARCH}" ]; then \
      case "${TARGETARCH}" in \
        amd64) apt_packages="ca-certificates gcc-x86-64-linux-gnu libc6-dev-amd64-cross"; cc=x86_64-linux-gnu-gcc ;; \
        arm64) apt_packages="ca-certificates gcc-aarch64-linux-gnu libc6-dev-arm64-cross"; cc=aarch64-linux-gnu-gcc ;; \
      esac; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends ${apt_packages}; \
    rm -rf /var/lib/apt/lists/*; \
    GOOS=linux GOARCH="${goarch}" CGO_ENABLED=1 CC="${cc}" \
      go install github.com/NVIDIA/nvkind/cmd/nvkind@latest; \
    mkdir -p /out; \
    if [ -x "/go/bin/nvkind" ]; then \
      install -m 0755 /go/bin/nvkind /out/nvkind; \
    else \
      install -m 0755 "/go/bin/linux_${goarch}/nvkind" /out/nvkind; \
    fi

FROM ${HASKELL_TOOLS_BASE_IMAGE} AS haskell-tools-builder

ARG HASKELL_TOOLS_GHC_VERSION
ARG HASKELL_TOOLS_CABAL_VERSION

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        gcc \
        g++ \
        libffi-dev \
        libgmp-dev \
        libncurses-dev \
        libtinfo-dev \
        make \
        pkg-config \
        xz-utils \
        zlib1g-dev \
    ; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) ghcup_arch=x86_64 ;; \
      arm64) ghcup_arch=aarch64 ;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://downloads.haskell.org/~ghcup/${ghcup_arch}-linux-ghcup" -o /usr/local/bin/ghcup; \
    chmod 0755 /usr/local/bin/ghcup

ENV PATH=/root/.ghcup/bin:/root/.cabal/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN ghcup install ghc "${HASKELL_TOOLS_GHC_VERSION}" \
    && ghcup set ghc "${HASKELL_TOOLS_GHC_VERSION}" \
    && ghcup install cabal "${HASKELL_TOOLS_CABAL_VERSION}" \
    && ghcup set cabal "${HASKELL_TOOLS_CABAL_VERSION}"

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN mkdir -p /out \
    && cabal update \
    && cabal install \
        --jobs=1 \
        --ignore-project \
        --installdir /out \
        --install-method=copy \
        --overwrite-policy=always \
        fourmolu \
        hlint

FROM ${BASE_IMAGE}

ARG IMAGE_FLAVOR=cpu
ARG GHC_VERSION=9.14.1
ARG CABAL_VERSION=3.16.1.0
ARG RUST_TOOLCHAIN=stable

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    apt-get update; \
    llvm_major="$(apt-cache search --names-only '^llvm-[0-9]+$' \
        | awk '{print $1}' \
        | sed -nE 's/^llvm-([0-9]+)$/\1/p' \
        | sort -n \
        | tail -1)"; \
    test -n "${llvm_major}"; \
    apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        "bolt-${llvm_major}" \
        ca-certificates \
        cmake \
        curl \
        dnsutils \
        docker-buildx \
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
        libdnnl-dev \
        libffi-dev \
        libgmp-dev \
        libmimalloc-dev \
        libncurses-dev \
        libnuma-dev \
        libpq-dev \
        libssl-dev \
        libtinfo-dev \
        "lld-${llvm_major}" \
        "llvm-${llvm_major}" \
        "llvm-${llvm_major}-dev" \
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
        zlib1g-dev \
    ; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    mkdir -p /workspace /opt/build /opt/cache; \
    llvm_major="$(dpkg-query -W -f='${Package}\n' 'llvm-[0-9]*' \
        | sed -nE 's/^llvm-([0-9]+)$/\1/p' \
        | sort -n \
        | tail -1)"; \
    test -n "${llvm_major}"; \
    ln -s "/usr/lib/llvm-${llvm_major}" /opt/llvm

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
    LLVM_CONFIG=/opt/llvm/bin/llvm-config \
    LIBRARY_PATH=/opt/llvm/lib \
    BOLT_RT_INSTR_LIB=/opt/llvm/lib/libbolt_rt_instr.a \
    CC=gcc \
    CXX=g++ \
    RUSTUP_TOOLCHAIN=${RUST_TOOLCHAIN} \
    CARGO_HTTP_TIMEOUT=120 \
    CARGO_NET_RETRY=5 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

ENV PATH=/opt/llvm/bin:/opt/pulumi:/root/.ghcup/bin:/opt/cache/cabal/bin:/root/.cabal/bin:/root/.cargo/bin:/opt/build/node/global/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=nvkind-builder /out/nvkind /usr/local/bin/nvkind

RUN export PIP_BREAK_SYSTEM_PACKAGES=1 \
    && python -m pip install --ignore-installed --upgrade pip setuptools wheel poetry

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) node_arch=x64 ;; \
      arm64) node_arch=arm64 ;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    node_version="$(curl -fsSL https://nodejs.org/dist/index.json \
        | jq -r --arg platform "linux-${node_arch}" \
          '[.[] | select((.files // []) | index($platform))][0].version')"; \
    test -n "${node_version}"; \
    test "${node_version}" != "null"; \
    tmpdir="$(mktemp -d)"; \
    curl -fsSL "https://nodejs.org/dist/${node_version}/node-${node_version}-linux-${node_arch}.tar.xz" \
        -o "${tmpdir}/node.tar.xz"; \
    tar -xJf "${tmpdir}/node.tar.xz" -C /usr/local --strip-components=1; \
    rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack; \
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'exec /usr/local/bin/node /usr/local/lib/node_modules/npm/bin/npm-cli.js "$@"' \
      > /usr/local/bin/npm; \
    chmod 0755 /usr/local/bin/npm; \
    rm -rf "${tmpdir}"

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) purescript_asset=linux64.tar.gz ;; \
      arm64) purescript_asset=linux-arm64.tar.gz ;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    purescript_version="$(curl -fsSL https://api.github.com/repos/purescript/purescript/releases/latest | jq -r '.tag_name')"; \
    test -n "${purescript_version}"; \
    test "${purescript_version}" != "null"; \
    tmpdir="$(mktemp -d)"; \
    curl -fsSL "https://github.com/purescript/purescript/releases/download/${purescript_version}/${purescript_asset}" \
        -o "${tmpdir}/purescript.tar.gz"; \
    tar -xzf "${tmpdir}/purescript.tar.gz" -C "${tmpdir}"; \
    install -m 0755 "${tmpdir}/purescript/purs" /usr/local/bin/purs; \
    rm -rf "${tmpdir}"

RUN npm install -g \
        @playwright/test \
        esbuild \
        playwright \
        purs-tidy \
        spago \
        typescript \
    && playwright install --with-deps chromium firefox webkit \
    && rm -rf /root/.npm

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) ghcup_arch=x86_64; tool_arch=amd64; aws_arch=x86_64; pulumi_arch=x64 ;; \
      arm64) ghcup_arch=aarch64; tool_arch=arm64; aws_arch=aarch64; pulumi_arch=arm64 ;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://downloads.haskell.org/~ghcup/${ghcup_arch}-linux-ghcup" -o /usr/local/bin/ghcup; \
    chmod 0755 /usr/local/bin/ghcup; \
    tmpdir="$(mktemp -d)"; \
    kind_version="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r '.tag_name')"; \
    kubectl_version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"; \
    helm_version="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')"; \
    pulumi_version="$(curl -fsSL https://api.github.com/repos/pulumi/pulumi/releases/latest | jq -r '.tag_name')"; \
    curl -fsSL "https://kind.sigs.k8s.io/dl/${kind_version}/kind-linux-${tool_arch}" -o "${tmpdir}/kind"; \
    install -m 0755 "${tmpdir}/kind" /usr/local/bin/kind; \
    curl -fsSL "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${tool_arch}/kubectl" -o "${tmpdir}/kubectl"; \
    install -m 0755 "${tmpdir}/kubectl" /usr/local/bin/kubectl; \
    curl -fsSL "https://get.helm.sh/helm-${helm_version}-linux-${tool_arch}.tar.gz" -o "${tmpdir}/helm.tgz"; \
    tar -xzf "${tmpdir}/helm.tgz" -C "${tmpdir}"; \
    install -m 0755 "${tmpdir}/linux-${tool_arch}/helm" /usr/local/bin/helm; \
    curl -fsSL "https://dl.min.io/client/mc/release/linux-${tool_arch}/mc" -o "${tmpdir}/mc"; \
    install -m 0755 "${tmpdir}/mc" /usr/local/bin/mc; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o "${tmpdir}/awscliv2.zip"; \
    unzip -q "${tmpdir}/awscliv2.zip" -d "${tmpdir}"; \
    "${tmpdir}/aws/install" --install-dir /opt/aws-cli --bin-dir /usr/local/bin; \
    curl -fsSL "https://get.pulumi.com/releases/sdk/pulumi-${pulumi_version}-linux-${pulumi_arch}.tar.gz" -o "${tmpdir}/pulumi.tgz"; \
    tar -xzf "${tmpdir}/pulumi.tgz" -C /opt; \
    test -x /opt/pulumi/pulumi; \
    rm -rf "${tmpdir}"

RUN ghcup install ghc "${GHC_VERSION}" \
    && ghcup set ghc "${GHC_VERSION}" \
    && ghcup install cabal "${CABAL_VERSION}" \
    && ghcup set cabal "${CABAL_VERSION}"

COPY --from=haskell-tools-builder /out/fourmolu /usr/local/bin/fourmolu
COPY --from=haskell-tools-builder /out/hlint /usr/local/bin/hlint

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain "${RUSTUP_TOOLCHAIN}" \
    && rustup component add --toolchain "${RUSTUP_TOOLCHAIN}" llvm-tools-preview rustfmt

COPY support/haskell-deps/ /opt/basecontainer/haskell-deps/

RUN cd /opt/basecontainer/haskell-deps \
    && cabal update \
    && cabal build --jobs=1 all --only-dependencies \
    && cabal build --jobs=1 all

RUN if [ "${IMAGE_FLAVOR}" = "cuda" ] && [ -d /usr/local/cuda/lib64 ]; then \
      printf '/usr/local/cuda/lib64\n' > /etc/ld.so.conf.d/cuda.conf; \
      ldconfig; \
    fi

WORKDIR /workspace
