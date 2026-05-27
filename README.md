# basecontainer

Shared Ubuntu 24.04 base images for multi-language development, CI, and
release builds.

The image is intentionally a dependency and toolchain layer. Downstream
repositories should still own their application source, generated artifacts,
runtime configuration, charts, and project-specific package installation.

## Scope

This README is the working contract for a reusable Dockerfile and build script.
It defines a base toolchain layer for Haskell, Python, Node.js, PureScript,
Playwright, C/C++, Rust, cluster tooling, image tooling, and optional CUDA
workloads.

## Image Contract

Use one `Dockerfile` with a parameterized upstream base:

```dockerfile
# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}
```

The same Dockerfile builds these published image families:

| Image family | Platform | Upstream base | Purpose |
|---|---:|---|---|
| `cpu-ubuntu24.04` | `linux/amd64`, `linux/arm64` | `ubuntu:24.04` | General project build, lint, test, cluster tooling, browser tests, C++ and Rust backends |
| `cuda-ubuntu24.04` | `linux/amd64`, `linux/arm64` | CUDA devel + cuDNN Ubuntu 24.04 base | CUDA compile, link, and runtime validation path |

Do not publish architecture-specific CUDA image families unless the upstream
CUDA base diverges by architecture and requires separate handling.

Fresh builds should resolve current upstream tool versions by default. Keep only
compatibility anchors fixed in repository files: Ubuntu 24.04, the required GHC
and Cabal versions, and the published image tag names. Do not hard-code upstream
release hashes or point releases for tools that can be resolved from apt,
language package managers, or upstream stable/latest metadata during the Docker
build. Published release metadata should record the resolved versions and base
image digests after the build.

## Toolchain Requirements

| Capability area | Requirements included in this base |
|---|---|
| Haskell | GHC 9.14.1, Cabal 3.16.1.0, warmed Cabal store, Fourmolu, HLint, Dhall libraries, protobuf-related Haskell libraries, PostgreSQL client headers |
| Python | Ubuntu 24.04 default Python, `python` alias, pip/setuptools/wheel bootstrap, Poetry as the only global Python package, protobuf compiler support for generated Python packages |
| Node and frontend | Latest upstream Node.js for the target architecture, npm, PureScript, Spago, esbuild, TypeScript, purs-tidy, Playwright with chromium/firefox/webkit |
| Cluster and image tooling | Docker CLI, buildx, compose, latest kind, stable kubectl, latest Helm, latest nvkind, skopeo, MinIO `mc`, latest AWS CLI v2, latest Pulumi CLI, `dig`, OpenSSH client |
| Native builds | CMake, Make, GCC/G++, C++17 and C++23 support, binutils, gdb, mimalloc, GCC PGO tooling, newest Ubuntu 24.04 LLVM BOLT/LLD package family available to apt |
| Rust | Latest stable Rust through rustup, rustfmt, LLVM LLD/BOLT support for optimized Rust build paths |
| Optional CUDA | Latest multi-platform CUDA devel + cuDNN Ubuntu 24.04 upstream image selected by the build script, nvcc, cuBLAS development/runtime libraries, cuDNN development/runtime libraries |

Host-only resources still remain host-only: the image can include CLIs and
headers, but it cannot provide the host Docker daemon, host NVIDIA driver,
kernel modules, or a real systemd-managed RKE2 host unless a downstream workflow
explicitly runs it in a privileged environment.

## Installation Doctrine

When a tool needs a natural command name in the image, prefer installation
methods in this order:

1. Use the distribution, vendor, or language package manager's normal installer.
2. Add the installed binary directory to `PATH`, and set tool-specific
   environment variables such as `LLVM_CONFIG` when needed.
3. Use a stable symlink only when a dynamically resolved versioned prefix needs a
   stable path for Docker `ENV`. Prefer one prefix symlink over per-binary
   symlinks.
4. Copy binaries only as a last resort when there is no viable installer, PATH,
   or symlink approach. Do not create redundant copies of binaries already
   installed elsewhere in the image.

Single-file CLI downloads installed with `install -m 0755` into `/usr/local/bin`
are acceptable when that is the vendor's normal installation shape. Dockerfile
`COPY` for repository support files is also fine; the rule is about avoiding
redundant installed binary copies.

## Downstream Development Model

Basecontainer is only the published image. Downstream projects should keep their
own Dockerfiles, Compose files, package manifests, and native tool
configuration.

When a project bind-mounts source for hot rebuilds, use `/workspace` as the
source root:

```text
/workspace    source tree bind-mounted from the host
/opt/build    generated build artifacts inside the container
/opt/cache    package-manager caches inside the container
```

The source bind mount is for hot rebuilds only. Compilers, package managers,
test runners, browser tools, and code generators should not write generated
state into `/workspace`. This avoids root-owned host artifacts such as
`dist-newstyle/`, `node_modules/`, `.venv/`, `target/`, `build/`, `dist/`,
`.spago/`, `playwright-report/`, `.mypy_cache/`, `.ruff_cache/`,
`__pycache__/`, `.tox/`, `.nox/`, `coverage/`, and dependency lock files.

Do not bind-mount `/opt/build` or `/opt/cache` back to the host. Those paths are
container-local working state. Rebuilds should happen inside the container, and
generated artifacts do not need a second persistence path on the host. Source
changes, Dockerfile changes, and project configuration changes are already
persisted through the project repository itself.

Native tool config files should enforce the `/opt/build` and `/opt/cache` paths
where the tool supports that. When a tool cannot configure artifact paths, run
that tool from a project-owned working directory under `/opt/build` and copy
source inputs from `/workspace`. Do not use symlinks for build worktrees: a tool
that writes through a symlink can still leak artifacts into the bind-mounted
source tree. The default developer command should stay simple, for example
`cabal build`, `poetry build`, `npm run build`,
`spago build`, `npm test`, `cargo build`, `cmake --build --preset
container-debug`, or `make`.

The base image should create these directories and set cache defaults:

```dockerfile
RUN mkdir -p /workspace /opt/build /opt/cache

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
    BOLT_RT_INSTR_LIB=/opt/llvm/lib/libbolt_rt_instr.a

ENV PATH=/opt/llvm/bin:/opt/pulumi:/root/.ghcup/bin:/opt/cache/cabal/bin:/root/.cabal/bin:/root/.cargo/bin:/opt/build/node/global/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
```

The examples below are instructions for project-owned config files, not files
provided by basecontainer. A good validation check is to run a clean build and
then verify that the source tree still has no generated directories.

Treat dependency lock files as generated build artifacts. They should be created
inside `/opt/build` when a tool insists on writing one, and they should not be
committed to downstream repositories.

Projects that run an outer container to manage Kind or other Docker-backed
clusters should forward the host Docker socket. If that outer container owns
runtime cluster data, bind-mount the project `.data/` directory to the host so
that data survives container replacement. Projects that only compile and test
code do not need Docker socket forwarding.

### Haskell Builds

Haskell projects should pin Cabal's build directory outside the source mount.
Put the build directory in the checked-in `cabal.project`, not in ad hoc command
arguments:

```cabal
-- cabal.project
packages: .
with-compiler: ghc-9.14.1
builddir: /opt/build/haskell/dist-newstyle
```

The ordinary commands are then safe:

```bash
cabal update
cabal build all
cabal test all
cabal run exe:my-app
```

`CABAL_DIR=/opt/cache/cabal` keeps Cabal's package state out of `/workspace`.
Do not let `dist-newstyle/` appear in the source tree. If a project uses
`cabal.project.local` for developer-only options, it should not override
`builddir`.

### Python Builds

Python projects should keep installed packages, wheels, test caches, type-check
caches, bytecode caches, and lint caches outside the bind mount.

Recommended `poetry.toml`:

```toml
[virtualenvs]
create = false
in-project = false
```

With `virtualenvs.create = false`, `poetry install` installs into the active
container Python environment. This is intentional for basecontainer workflows:
the container is disposable, and project dependencies should be container-wide
inside that container rather than written into a project `.venv/` or
`/opt/build` virtualenv.

Recommended `pyproject.toml` cache settings:

```toml
[tool.mypy]
cache_dir = "/opt/build/python/mypy-cache"

[tool.ruff]
cache-dir = "/opt/build/python/ruff-cache"

[tool.pytest.ini_options]
cache_dir = "/opt/build/python/pytest-cache"

[tool.coverage.run]
data_file = "/opt/build/python/.coverage"
```

Poetry does not have a project config key that changes the default package
artifact directory for `poetry build`; by default it writes `dist/` under the
current working directory. For package builds, run Poetry from a build worktree
under `/opt/build` so the ordinary command is safe:

```bash
mkdir -p /opt/build/python/app
cd /opt/build/python/app
cp /workspace/pyproject.toml pyproject.toml
[ -f /workspace/poetry.toml ] && cp /workspace/poetry.toml poetry.toml
cp -a /workspace/src src
[ -f /workspace/README.md ] && cp /workspace/README.md README.md
poetry install
poetry build
poetry run pytest
```

This writes installed dependencies into the container Python environment and
writes bytecode caches, pytest caches, type-check caches, and package artifacts
under `/opt/build` or `/opt/cache`. If a project has package data outside
`src/`, copy that input into the build worktree too.

If a project uses tox, keep its work directory out of the source tree:

```ini
# tox.ini
[tox]
work_dir = /opt/build/python/tox
```

If a project uses nox, keep its environment directory out of the source tree:

```python
# noxfile.py
import nox

nox.options.envdir = "/opt/build/python/nox"
```

The only Python package installed globally by the base image is Poetry. Project
dependencies remain owned by the downstream `pyproject.toml`.

### Node And npm Builds

npm writes `node_modules` under the package working directory. To keep
`node_modules` out of `/workspace`, run npm from a build sandbox under
`/opt/build/node/<package>` and copy source inputs from `/workspace`. The
ordinary commands should be run from that sandbox:

Use npm scripts for project commands. Do not use `npx` in downstream build,
test, lint, or Playwright workflows.

A project-owned install step can create a sandbox like:

```bash
mkdir -p /opt/build/node/app
cp /workspace/package.json /opt/build/node/app/package.json
[ -f /workspace/.npmrc ] && cp /workspace/.npmrc /opt/build/node/app/.npmrc
[ -f /workspace/tsconfig.json ] && cp /workspace/tsconfig.json /opt/build/node/app/tsconfig.json
[ -f /workspace/vite.config.ts ] && cp /workspace/vite.config.ts /opt/build/node/app/vite.config.ts
cp -a /workspace/src /opt/build/node/app/src
[ -d /workspace/scripts ] && cp -a /workspace/scripts /opt/build/node/app/scripts
[ -d /workspace/public ] && cp -a /workspace/public /opt/build/node/app/public
cd /opt/build/node/app
npm install
npm run build
npm test
```

If the package lives under `web/` or `frontend/`, use that subdirectory as the
source:

```bash
mkdir -p /opt/build/node/web
cp /workspace/web/package.json /opt/build/node/web/package.json
cp -a /workspace/web/src /opt/build/node/web/src
```

Recommended `.npmrc`:

```ini
cache=/opt/cache/npm
prefix=/opt/build/node/global
update-notifier=false
fund=false
audit=false
package-lock=true
```

`package-lock.json` is allowed to be created in the `/opt/build` sandbox, but it
should not exist under `/workspace` or be version controlled.

Project build tools should also be configured so `npm run build` does not emit
into `/workspace`. Example `vite.config.ts`:

```ts
import { defineConfig } from "vite";

export default defineConfig({
  cacheDir: "/opt/cache/node/vite",
  build: {
    outDir: "/opt/build/node/app/dist",
    emptyOutDir: true,
  },
});
```

Example `tsconfig.json`:

```json
{
  "compilerOptions": {
    "outDir": "/opt/build/node/app/tsc",
    "tsBuildInfoFile": "/opt/build/node/app/tsconfig.tsbuildinfo"
  }
}
```

### PureScript And Spago Builds

PureScript and Spago write `output/`, dependency state, and bundle outputs under
the current working directory unless directed otherwise. Run Spago from a
build worktree under `/opt/build/purescript/<package>` so the ordinary commands
are safe:

```bash
mkdir -p /opt/build/purescript/app
cd /opt/build/purescript/app
[ -f /workspace/spago.yaml ] && cp /workspace/spago.yaml spago.yaml
[ -f /workspace/package.json ] && cp /workspace/package.json package.json
cp -a /workspace/src src
[ -d /workspace/test ] && cp -a /workspace/test test
spago build
spago test
```

If a project still uses legacy `spago.dhall` and `packages.dhall`, copy those
files into the build worktree instead of `spago.yaml`. Do not produce
source-tree `output/`, `test-output/`, `.spago/`, or `spago.lock`. Treat
`spago.lock` as a generated build artifact.

### Playwright Builds

The base image installs browser binaries at `PLAYWRIGHT_BROWSERS_PATH`, outside
the source tree. Downstream projects should configure test output and HTML
reports outside `/workspace`.

Recommended `playwright.config.ts` or `playwright.config.js`:

```ts
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "/workspace/tests",
  outputDir: "/opt/build/playwright/test-results",
  reporter: [
    ["list"],
    ["html", { outputFolder: "/opt/build/playwright/report", open: "never" }],
  ],
  snapshotPathTemplate:
    "/opt/build/playwright/snapshots/{testFilePath}/{arg}{ext}",
});
```

The ordinary command is then:

```bash
npm test
```

Projects that intentionally maintain golden screenshots or snapshots in source
should use a separate, explicit update workflow. Normal test runs should not
write reports, traces, videos, screenshots, or snapshot updates into
`/workspace`.

### Rust Builds

Rust projects should keep Cargo registry state, compiled artifacts, and
`Cargo.lock` out of the bind mount. Run Cargo from a build worktree under
`/opt/build/rust/<package>` so the ordinary commands are safe:

```bash
mkdir -p /opt/build/rust/app
cd /opt/build/rust/app
cp /workspace/Cargo.toml Cargo.toml
[ -d /workspace/.cargo ] && cp -a /workspace/.cargo .cargo
cp -a /workspace/src src
cargo build
cargo test
cargo build --release
```

`Cargo.lock` may be generated in the `/opt/build` worktree, but it should not
exist under `/workspace` or be version controlled.

Recommended `.cargo/config.toml`:

```toml
[build]
target-dir = "/opt/build/rust/target"
```

`CARGO_HOME=/opt/cache/cargo` keeps registry and git state out of `/workspace`.
`CARGO_TARGET_DIR=/opt/build/rust/target` is set as an environment fallback for
tools that do not read `.cargo/config.toml`. This prevents `target/` from
appearing under `/workspace`.

### C And C++ Builds

CMake projects should use checked-in presets that put binary directories and
install output under `/opt/build`. Example `CMakePresets.json`:

```json
{
  "version": 6,
  "configurePresets": [
    {
      "name": "container-debug",
      "generator": "Ninja",
      "binaryDir": "/opt/build/cmake/${sourceDirName}/debug",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Debug",
        "CMAKE_INSTALL_PREFIX": "/opt/build/install"
      }
    }
  ],
  "buildPresets": [
    {
      "name": "container-debug",
      "configurePreset": "container-debug"
    }
  ],
  "testPresets": [
    {
      "name": "container-debug",
      "configurePreset": "container-debug",
      "output": {
        "outputOnFailure": true
      }
    }
  ],
  "installPresets": [
    {
      "name": "container-debug",
      "configurePreset": "container-debug"
    }
  ]
}
```

The ordinary CMake commands are then safe:

```bash
cmake --preset container-debug
cmake --build --preset container-debug
ctest --preset container-debug
cmake --install --preset container-debug
```

Make-based projects should route every output through `BUILD_DIR`. Example
Makefile:

```make
BASECONTAINER_BUILD_ROOT ?= /opt/build
BUILD_DIR ?= $(BASECONTAINER_BUILD_ROOT)/make/$(notdir $(CURDIR))
INSTALL_PREFIX ?= $(BASECONTAINER_BUILD_ROOT)/install
PGO_DIR ?= $(BUILD_DIR)/pgo-profile
BOLT_DIR ?= $(BUILD_DIR)/bolt-profile

CXX ?= g++
CXXFLAGS ?= -std=c++23 -O3 -fPIC

all: $(BUILD_DIR)/app

$(BUILD_DIR)/app: src/main.cc
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $< -o $@

test: all
	$(BUILD_DIR)/app --self-test

install: all
	mkdir -p $(INSTALL_PREFIX)/bin
	cp $(BUILD_DIR)/app $(INSTALL_PREFIX)/bin/app

clean:
	rm -rf $(BUILD_DIR)
```

The ordinary Make commands are then safe:

```bash
make
make test
make install
```

Targets must write objects, libraries, binaries, PGO profiles, and BOLT profiles
under `$(BUILD_DIR)`, never under a source-tree `build/` directory.

### CUDA Builds

CUDA projects should follow the same CMake or Make rule: configure the native
build tool so `nvcc` outputs and generated CUDA objects land under `/opt/build`.
Example `CMakePresets.json` entry for a CUDA build:

```json
{
  "version": 6,
  "configurePresets": [
    {
      "name": "cuda-release",
      "generator": "Ninja",
      "binaryDir": "/opt/build/cmake/${sourceDirName}/cuda-release",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Release",
        "CMAKE_CUDA_ARCHITECTURES": "native",
        "CMAKE_INSTALL_PREFIX": "/opt/build/install"
      }
    }
  ],
  "buildPresets": [
    {
      "name": "cuda-release",
      "configurePreset": "cuda-release"
    }
  ]
}
```

The ordinary commands are then safe:

```bash
cmake --preset cuda-release
cmake --build --preset cuda-release
```

### Git Ignore Guardrails

Downstream `.gitignore` files should still ignore common generated paths as a
last line of defense. These entries are not the primary control; the native
tool config above should keep artifacts out of the source tree before
`.gitignore` matters.

```gitignore
dist-newstyle/
.cabal-sandbox/
.venv/
node_modules/
dist/
output/
test-output/
.spago/
playwright-report/
test-results/
target/
build/
.mypy_cache/
.ruff_cache/
.pytest_cache/
.coverage
__pycache__/
*.pyc
*.lock
Cargo.lock
poetry.lock
package-lock.json
npm-shrinkwrap.json
yarn.lock
pnpm-lock.yaml
spago.lock
cabal.project.freeze
.tox/
.nox/
htmlcov/
coverage/
.nyc_output/
.vite/
.turbo/
.next/
.svelte-kit/
.parcel-cache/
*.tsbuildinfo
```

After a container build or hot rebuild, this check should return no output:

```bash
find /workspace \
  \( -name dist-newstyle -o -name node_modules -o -name .venv \
  -o -name target -o -name build -o -name dist -o -name output \
  -o -name test-output -o -name .spago -o -name playwright-report \
  -o -name test-results -o -name .mypy_cache -o -name .ruff_cache \
  -o -name .pytest_cache -o -name __pycache__ -o -name .tox \
  -o -name .nox -o -name coverage -o -name .nyc_output \
  -o -name .vite -o -name .turbo -o -name .next \
  -o -name .svelte-kit -o -name .parcel-cache -o -name '*.lock' \
  -o -name Cargo.lock -o -name poetry.lock -o -name package-lock.json \
  -o -name npm-shrinkwrap.json -o -name yarn.lock \
  -o -name pnpm-lock.yaml -o -name spago.lock \
  -o -name cabal.project.freeze \) \
  -prune -print
```

## Core Apt Packages

The base apt layer should use Ubuntu 24.04 package names and let apt resolve the
target architecture. Avoid explicit architecture conditionals unless a binary
download has no architecture-neutral installer.

Baseline packages use unversioned apt names except for LLVM/BOLT. Ubuntu's
unversioned `bolt` package is not LLVM BOLT, so the Dockerfile should discover
the highest available LLVM package family and install the matching versioned
packages:

```bash
llvm_major="$(apt-cache search --names-only '^llvm-[0-9]+$' \
  | awk '{print $1}' \
  | sed -nE 's/^llvm-([0-9]+)$/\1/p' \
  | sort -n \
  | tail -1)"
```

Baseline package set:

```text
build-essential
binutils
bolt-${llvm_major}
ca-certificates
cmake
curl
dnsutils
docker-buildx
docker-compose-v2
docker.io
file
g++
gcc
gdb
git
gnupg
iproute2
iptables
jq
less
libdnnl-dev
libffi-dev
libgmp-dev
libmimalloc-dev
libncurses-dev
libnuma-dev
libpq-dev
libssl-dev
libtinfo-dev
lld-${llvm_major}
llvm-${llvm_major}
llvm-${llvm_major}-dev
make
ninja-build
openssh-client
perl
pkg-config
protobuf-compiler
python3
python3-dev
python-is-python3
python3-pip
python3-venv
skopeo
sudo
tini
unzip
wget
xz-utils
zlib1g-dev
```

Do not install or support Clang as a C++ compiler. The supported C++ compiler is
GCC/G++. LLVM packages are included only for BOLT, LLD, `llvm-config`, and
related post-link/profile tooling.

Ubuntu installs unversioned LLVM command names inside the versioned LLVM prefix,
for example `/usr/lib/llvm-${llvm_major}/bin/llvm-config`. Because
`llvm_major` is discovered during the Docker build, expose one stable prefix
symlink and put that prefix on `PATH`. Do not copy individual LLVM binaries:

```bash
llvm_major="$(dpkg-query -W -f='${Package}\n' 'llvm-[0-9]*' \
  | sed -nE 's/^llvm-([0-9]+)$/\1/p' \
  | sort -n \
  | tail -1)"
ln -s "/usr/lib/llvm-${llvm_major}" /opt/llvm
```

Then set:

```text
PATH=/opt/llvm/bin:${PATH}
LLVM_CONFIG=/opt/llvm/bin/llvm-config
LIBRARY_PATH=/opt/llvm/lib
BOLT_RT_INSTR_LIB=/opt/llvm/lib/libbolt_rt_instr.a
```

## Haskell

Install only one compiler and one Cabal:

```text
GHC_VERSION=9.14.1
CABAL_VERSION=3.16.1.0
```

Both must be installed through `ghcup`. Do not add a separate formatter/checker
GHC. Existing project Dockerfiles have used a second GHC for style tooling; this
base intentionally does not. If `fourmolu` or `hlint` need patches to build
with GHC 9.14.1, carry those patches in this base repository and build the
patched packages with GHC 9.14.1.

Expected PATH:

```text
/opt/llvm/bin:/opt/pulumi:/root/.ghcup/bin:/opt/cache/cabal/bin:/root/.cabal/bin:/root/.cargo/bin:/opt/build/node/global/bin:/usr/local/bin
```

Install style and support tools into stable locations:

```bash
cabal update
cabal install \
  --ignore-project \
  --allow-newer=all \
  --installdir /usr/local/bin \
  --install-method=copy \
  --overwrite-policy=always \
  fourmolu \
  hlint
```

### Prebuilt Haskell Store

The base should warm the Cabal store with the union of downstream Haskell
libraries. This reduces rebuild time and gives us a place to carry patched
packages when Hackage bounds lag GHC 9.14.1.

Planned support layout:

```text
support/haskell-deps/
  cabal.project
  basecontainer-haskell-deps.cabal
  patches/
```

`basecontainer-haskell-deps.cabal` should expose a tiny library or executable
whose `build-depends` is the shared dependency set this base is expected to
prebuild, including:

```text
QuickCheck
aeson
aeson-pretty
ansi-terminal
async
base16-bytestring
base64-bytestring
brick
case-insensitive
cborg
cborg-json
co-log
co-log-core
containers
cookie
criterion
cryptohash-sha1
cryptohash-sha256
cryptonite
dhall
directory
filepath
flat
fsnotify
hedgehog
hedis
hspec
http-client
http-client-tls
http-types
lens-family
lens-family-core
memory
mtl
network
optparse-applicative
path
path-io
postgresql-simple
prettyprinter
prettyprinter-ansi-terminal
process
proto-lens
proto-lens-runtime
proto-lens-setup
purescript-bridge
safe-exceptions
scientific
serialise
stm
tasty
tasty-golden
tasty-hedgehog
tasty-hunit
tasty-quickcheck
temporary
text
time
transformers
typed-process
unix
uuid
vector
vty
wai
wai-websockets
warp
websockets
wuss
yaml
```

The support `cabal.project` should mirror the downstream `allow-newer` pressure
needed by GHC 9.14.1. When bounds or releases are not usable from Hackage, prefer
one of these in order:

1. A checked-in patch under `support/haskell-deps/patches/`.
2. A checked-in local package under `support/haskell-deps/vendor/`.
3. A `source-repository-package` only when there is no reasonable patch or
   vendored-package alternative; document why external source is unavoidable.

The Dockerfile warm-up step should be:

```bash
cd /opt/basecontainer/haskell-deps
cabal update
cabal build all --only-dependencies
cabal build all
```

Do not copy any downstream application source into this base image to warm the
store.

## Python

Use Ubuntu 24.04's default Python. Provide both `python3` and `python` with the
Ubuntu package intended for that purpose:

```bash
apt-get install -y --no-install-recommends python-is-python3
```

After apt Python dependencies are installed, run the required bootstrap command:

```bash
python -m pip install --upgrade pip setuptools wheel poetry
```

For Ubuntu 24.04 image builds, set `PIP_BREAK_SYSTEM_PACKAGES=1` before that
command unless the implementation uses a dedicated bootstrap venv. The only
globally installed Python package should be Poetry. Downstream projects own
their Python dependencies through their own `pyproject.toml` and Poetry
configuration.

## Node, PureScript, And Playwright

Install the latest upstream Node.js release for the target architecture during
the Docker build. Use the bundled npm as the standard package manager for
downstream frontend, PureScript, Playwright, and Pulumi workflows. Do not expose
or recommend `npx`; project commands should be npm scripts.

Global npm tools expected in the base:

```bash
npm install -g \
  @playwright/test \
  esbuild \
  playwright \
  purescript \
  purs-tidy \
  spago \
  typescript
```

Install browser dependencies and all three Playwright browser families:

```bash
playwright install --with-deps chromium firefox webkit
```

Playwright names the Chrome-family bundled browser `chromium`. If a downstream
test specifically requires branded Google Chrome rather than the bundled
Chromium browser, add `playwright install chrome` in that downstream image or in
this base once the requirement is confirmed.

## Cluster And Registry Tooling

The base should include:

```text
docker
docker buildx
docker compose
kind
kubectl
helm
nvkind
skopeo
mc
aws
pulumi
protoc
```

Use architecture-neutral installers where they exist. For tools that require
binary downloads, keep the architecture mapping limited to that download block:

```bash
arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64) tool_arch=amd64; aws_arch=x86_64 ;;
  arm64) tool_arch=arm64; aws_arch=aarch64 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac
```

For archive-based CLI distributions that contain several related executables,
extract the archive into a stable tool directory and add that directory to
`PATH`. For example, install Pulumi under `/opt/pulumi` and include
`/opt/pulumi` in `PATH`; do not copy each Pulumi executable into
`/usr/local/bin`.

The image should contain Docker CLI tools, not a Docker daemon. Downstream
Compose files can mount `/var/run/docker.sock` and, when registry access is
needed, the host Docker config.

## C++, GCC, And Rust

The native build stack must support:

- C++17 for the legacy backend.
- C++23 for imperative and functional backends.
- GCC/G++ from Ubuntu 24.04.
- GNU binutils and gdb.
- GCC profile-guided optimization workflows.
- The newest Ubuntu 24.04 LLVM BOLT package family available to apt.
- Matching LLD for Rust optimized link paths that require it.
- `libmimalloc-dev`.
- Latest stable Rust installed with rustup.
- `rustfmt` and `llvm-tools-preview`.

Clang is not a supported compiler in this base. C++ builds should use `gcc` and
`g++`; LLVM is present for BOLT and related binary/profile tools only.

Expected environment:

```text
CC=gcc
CXX=g++
LLVM_CONFIG=/usr/local/bin/llvm-config
RUSTUP_TOOLCHAIN=stable
CARGO_HTTP_TIMEOUT=120
CARGO_NET_RETRY=5
```

Rust install:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --default-toolchain stable
rustup component add --toolchain stable llvm-tools-preview rustfmt
```

## CUDA Image

The CUDA image is built for both `linux/amd64` and `linux/arm64`.

Use the same Dockerfile, but pass a CUDA-enabled Ubuntu 24.04 base image as
`BASE_IMAGE`. The CUDA base must include or allow installation of:

```text
Latest CUDA toolkit in an Ubuntu 24.04 devel image
nvcc
cuBLAS dev/runtime libraries
cuDNN dev/runtime libraries
```

A CUDA devel + cuDNN upstream image is preferred so the Dockerfile does not need
separate CUDA repository setup. The build script should resolve the newest
Docker Hub tag matching `nvidia/cuda:*cudnn-devel-ubuntu24.04` that has both
`linux/amd64` and `linux/arm64` manifests when `CUDA_BASE_IMAGE` is not set. If
apt installation is still required, keep it behind a CUDA-flavor build argument,
not an architecture branch.

Do not put CUDA stubs on `LD_LIBRARY_PATH`. Runtime driver libraries are injected
by the NVIDIA Container Toolkit on a GPU host. Keep only runtime libraries in the
dynamic linker path:

```bash
printf '/usr/local/cuda/lib64\n' > /etc/ld.so.conf.d/cuda.conf
ldconfig
```

The image can compile and link CUDA code. It does not provide the host NVIDIA
driver or GPU device access.

## Third-Party CLI Helpers

The base should include shared CLI helpers that are broadly useful across
project build and cluster workflows:

- MinIO client `mc`.

Do not include application/runtime helpers such as `llama-server` or `pgadmin4`
in this base image. Downstream projects that need those should install them in
their own runtime images. Resolve shared CLI helper versions during the Docker
build from stable/latest upstream metadata where available, and record the
resolved versions in release metadata.

## Build Script

The repository contains a single script:

```text
scripts/build-and-push.sh
```

It should build and push CPU amd64/arm64 plus CUDA amd64/arm64 simultaneously,
using the host Docker Hub login. The script should default the Docker Hub
namespace to the logged-in Docker username and allow explicit override through
`DOCKERHUB_USERNAME`.

The script resolves the latest CUDA devel + cuDNN Ubuntu 24.04 base image with
`curl`, `jq`, and `docker buildx imagetools` unless `CUDA_BASE_IMAGE` is set
explicitly. Shape:

```bash
#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-basecontainer}"
CPU_BASE_IMAGE="${CPU_BASE_IMAGE:-ubuntu:24.04}"
BUILDER_NAME="${BUILDER_NAME:-basecontainer-builder}"
BUILDX_PROGRESS="${BUILDX_PROGRESS:-plain}"

resolve_latest_cuda_base_image() {
  candidates="$(
    curl -fsSL 'https://hub.docker.com/v2/repositories/nvidia/cuda/tags?page_size=100&name=cudnn-devel-ubuntu24.04' \
      | jq -r '
          [
            .results[].name
            | select(test("^[0-9]+[.][0-9]+[.][0-9]+-cudnn-devel-ubuntu24[.]04$"))
          ]
          | sort_by(split("-")[0] | split(".") | map(tonumber))
          | reverse
          | .[]
        '
  )"

  while IFS= read -r tag; do
    image="nvidia/cuda:${tag}"
    if docker buildx imagetools inspect --raw "${image}" \
      | jq -e '
          ([.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64")] | length > 0)
          and
          ([.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "arm64")] | length > 0)
        ' >/dev/null; then
      printf '%s\n' "${image}"
      return
    fi
  done <<< "${candidates}"

  echo "Unable to resolve a CUDA cuDNN devel Ubuntu 24.04 tag with amd64 and arm64 manifests." >&2
  exit 1
}

CUDA_BASE_IMAGE="${CUDA_BASE_IMAGE:-$(resolve_latest_cuda_base_image)}"

logged_in_user="$(
  docker info 2>/dev/null \
    | awk -F': ' '/Username:/ {print $2; exit}'
)"
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-$logged_in_user}"

if [ -z "${DOCKERHUB_USERNAME}" ]; then
  echo "Docker Hub username not found. Run docker login or set DOCKERHUB_USERNAME." >&2
  exit 1
fi

IMAGE_REPO="docker.io/${DOCKERHUB_USERNAME}/${IMAGE_NAME}"

docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1 \
  || docker buildx create --name "${BUILDER_NAME}" --use
docker buildx use "${BUILDER_NAME}"

build_cpu_image() {
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg BASE_IMAGE="${CPU_BASE_IMAGE}" \
    --build-arg IMAGE_FLAVOR=cpu \
    --progress "${BUILDX_PROGRESS}" \
    --provenance=true \
    --sbom=true \
    --tag "${IMAGE_REPO}:cpu-ubuntu24.04" \
    --tag "${IMAGE_REPO}:ubuntu24.04" \
    --push \
    .
}

build_cuda_image() {
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg BASE_IMAGE="${CUDA_BASE_IMAGE}" \
    --build-arg IMAGE_FLAVOR=cuda \
    --progress "${BUILDX_PROGRESS}" \
    --provenance=true \
    --sbom=true \
    --tag "${IMAGE_REPO}:cuda-ubuntu24.04" \
    --tag "${IMAGE_REPO}:cuda" \
    --push \
    .
}

run_labeled() {
  label="$1"
  shift
  "$@" 2>&1 | awk -v label="${label}" '{ print "[" label "] " $0; fflush(); }'
}

run_labeled cpu build_cpu_image &
cpu_pid="$!"
run_labeled cuda build_cuda_image &
cuda_pid="$!"

set +e
wait "${cpu_pid}"
cpu_status="$?"
wait "${cuda_pid}"
cuda_status="$?"
set -e

if [ "${cpu_status}" -ne 0 ] || [ "${cuda_status}" -ne 0 ]; then
  echo "Build failure: cpu=${cpu_status}, cuda=${cuda_status}" >&2
  exit 1
fi
```

The script should not manage Docker Hub credentials directly. It should rely on
the host Docker credential store created by `docker login`.

## Verification Checklist

For every published CPU image:

```bash
ghc --numeric-version
cabal --numeric-version
fourmolu --version
hlint --version
python --version
poetry --version
node --version
npm --version
playwright --version
rustc --version
cargo --version
llvm-config --version
llvm-bolt --version
llvm-profdata --version
llvm-objcopy --version
ld.lld --version
kubectl version --client=true
helm version --short
kind version
docker --version
docker buildx version
docker compose version
aws --version
pulumi version
protoc --version
skopeo --version
mc --version
```

For CUDA images:

```bash
nvcc --version
ldconfig -p | grep libcublas
ldconfig -p | grep libcudnn
```

For downstream smoke validation, rebuild representative Haskell, Python,
Node.js, PureScript, Playwright, C/C++, Rust, cluster-tooling, and CUDA workloads
that consume the published base image on both target platforms where hardware is
available.

## Downstream Use

Downstream Dockerfiles should consume the published base instead of rebuilding
toolchains locally when Docker Hub is available. Keep the base image as a
replaceable build argument so local and fallback builds can use the same
Dockerfile. This `COPY` pattern is for release or CI image builds where the
source tree is intentionally baked into an application image:

```dockerfile
# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=docker.io/YOUR_DOCKERHUB_USER/basecontainer:cpu-ubuntu24.04
FROM ${BASE_IMAGE} AS base

FROM base
WORKDIR /workspace
COPY . .
```

### Docker Hub Fallbacks

When Docker Hub is unavailable, or a downstream project intentionally wants to
build the base dependencies itself, prefer one of these approaches instead of
copying basecontainer Dockerfile instructions into the downstream Dockerfile.

Build from a checked-out basecontainer repository:

```bash
git clone https://github.com/Tuee22/basecontainer.git ../basecontainer
docker buildx build --load --tag basecontainer:local ../basecontainer
docker buildx build \
  --build-arg BASE_IMAGE=basecontainer:local \
  --tag app:local \
  .
```

Build directly from GitHub without keeping a local checkout:

```bash
docker buildx build \
  --load \
  --tag basecontainer:local \
  https://github.com/Tuee22/basecontainer.git#main

docker buildx build \
  --build-arg BASE_IMAGE=basecontainer:local \
  --tag app:local \
  .
```

`--load` is for a single local platform. For multi-platform fallback builds, push
the locally built base image to an accessible internal registry and pass that
registry tag as `BASE_IMAGE`.

For a single build graph that builds basecontainer and the downstream image
together, use Buildx Bake with a `target:` context. This is the closest
idiomatic equivalent to inlining the basecontainer Dockerfile, without
duplicating it.

Downstream Dockerfile:

```dockerfile
# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=docker.io/YOUR_DOCKERHUB_USER/basecontainer:cpu-ubuntu24.04
FROM ${BASE_IMAGE} AS base

FROM base
WORKDIR /workspace
COPY . .
```

`docker-bake.hcl` using a local checkout:

```hcl
variable "BASECONTAINER_CONTEXT" {
  default = "../basecontainer"
}

target "basecontainer" {
  context = BASECONTAINER_CONTEXT
  dockerfile = "Dockerfile"
}

target "app" {
  context = "."
  dockerfile = "Dockerfile"
  args = {
    BASE_IMAGE = "basecontainer"
  }
  contexts = {
    basecontainer = "target:basecontainer"
  }
  tags = ["app:local"]
}
```

Build with the local checkout:

```bash
docker buildx bake app
```

Build the same graph with basecontainer read directly from GitHub:

```bash
docker buildx bake app \
  --set basecontainer.context=https://github.com/Tuee22/basecontainer.git#main
```

For CUDA fallback builds, use the same patterns but pass a CUDA-capable base and
CUDA flavor to the basecontainer build. `--load` can load only one platform into
the local Docker image store, so set `CUDA_PLATFORM` to the platform you need
locally:

```bash
CUDA_PLATFORM="${CUDA_PLATFORM:-linux/amd64}"

docker buildx build \
  --load \
  --platform "${CUDA_PLATFORM}" \
  --build-arg BASE_IMAGE="${CUDA_BASE_IMAGE}" \
  --build-arg IMAGE_FLAVOR=cuda \
  --tag basecontainer:cuda-local \
  ../basecontainer

docker buildx build \
  --build-arg BASE_IMAGE=basecontainer:cuda-local \
  --tag app:cuda-local \
  .
```

For multi-platform CUDA fallback builds, push the base image to an accessible
internal registry and pass that registry tag as `BASE_IMAGE`. Set
`CUDA_BASE_IMAGE` to a CUDA devel + cuDNN Ubuntu 24.04 image with the target
platform manifest. The published basecontainer build script resolves the latest
matching Docker Hub tag with both `linux/amd64` and `linux/arm64` manifests when
`CUDA_BASE_IMAGE` is not set.

For local development and hot rebuilds, projects may bind-mount the source tree
at `/workspace`. Keep `/opt/build` and `/opt/cache` inside the container, and
make each language's checked-in config route build artifacts away from the
source tree.

CUDA downstream builds should select:

```text
docker.io/YOUR_DOCKERHUB_USER/basecontainer:cuda-ubuntu24.04
```

Downstream projects should keep their normal application build, tests, generated
files, Poetry installs, npm installs, Cabal project settings, and chart pulls in
their own Dockerfiles or command surfaces. This base exists to make those steps
fast and consistent, not to absorb downstream application ownership.
