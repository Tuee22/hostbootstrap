# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=ubuntu:24.04
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

RUN export PIP_BREAK_SYSTEM_PACKAGES=1 \
    && python -m pip install --upgrade pip setuptools wheel poetry

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

RUN npm install -g \
        @playwright/test \
        esbuild \
        playwright \
        purescript \
        purs-tidy \
        spago \
        typescript \
    && playwright install --with-deps chromium firefox webkit \
    && rm -rf /root/.npm

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) ghcup_arch=x86_64; go_arch=amd64; tool_arch=amd64; aws_arch=x86_64; pulumi_arch=x64 ;; \
      arm64) ghcup_arch=aarch64; go_arch=arm64; tool_arch=arm64; aws_arch=aarch64; pulumi_arch=arm64 ;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://downloads.haskell.org/~ghcup/${ghcup_arch}-linux-ghcup" -o /usr/local/bin/ghcup; \
    chmod 0755 /usr/local/bin/ghcup; \
    tmpdir="$(mktemp -d)"; \
    kind_version="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r '.tag_name')"; \
    kubectl_version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"; \
    helm_version="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')"; \
    pulumi_version="$(curl -fsSL https://api.github.com/repos/pulumi/pulumi/releases/latest | jq -r '.tag_name')"; \
    go_version="$(curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r '[.[] | select(.stable == true)][0].version')"; \
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
    curl -fsSL "https://go.dev/dl/${go_version}.linux-${go_arch}.tar.gz" -o "${tmpdir}/go.tgz"; \
    tar -C /usr/local -xzf "${tmpdir}/go.tgz"; \
    PATH="/usr/local/go/bin:${PATH}" GOBIN=/usr/local/bin go install github.com/NVIDIA/nvkind/cmd/nvkind@latest; \
    rm -rf "${tmpdir}" /usr/local/go /root/go

RUN ghcup install ghc "${GHC_VERSION}" \
    && ghcup set ghc "${GHC_VERSION}" \
    && ghcup install cabal "${CABAL_VERSION}" \
    && ghcup set cabal "${CABAL_VERSION}"

RUN cabal update \
    && cabal install \
        --ignore-project \
        --allow-newer=all \
        --installdir /usr/local/bin \
        --install-method=copy \
        --overwrite-policy=always \
        fourmolu \
        hlint

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain "${RUSTUP_TOOLCHAIN}" \
    && rustup component add --toolchain "${RUSTUP_TOOLCHAIN}" llvm-tools-preview rustfmt

COPY support/haskell-deps/ /opt/basecontainer/haskell-deps/

RUN cd /opt/basecontainer/haskell-deps \
    && cabal update \
    && cabal build all --only-dependencies \
    && cabal build all

RUN if [ "${IMAGE_FLAVOR}" = "cuda" ] && [ -d /usr/local/cuda/lib64 ]; then \
      printf '/usr/local/cuda/lib64\n' > /etc/ld.so.conf.d/cuda.conf; \
      ldconfig; \
    fi

WORKDIR /workspace
