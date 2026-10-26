# C / C++ / LLVM

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [rust.md](rust.md)

> **Purpose**: Document the C/C++/LLVM toolchain the base image ships.

This page documents what the base image ships for C/C++/LLVM.

The base image ships the standard Ubuntu C/C++ toolchain (`build-essential`,
`gcc`, `g++`, `binutils`, `gdb`, `cmake`, `ninja-build`, `pkg-config`) plus
the LLVM 19 family, all from the Ubuntu 24.04 archive as the parent image's apt sources serve it at build
time. No archive snapshot is pinned, so a rebuild can pick up newer package patch versions.

LLVM is symlinked at `/opt/llvm` for stable paths:

* `LLVM_CONFIG=/opt/llvm/bin/llvm-config`
* `LIBRARY_PATH=/opt/llvm/lib`
* `BOLT_RT_INSTR_LIB=/opt/llvm/lib/libbolt_rt_instr.a`
* `CC=clang-N`
* `CXX=clang++-N`
* `PATH=/opt/llvm/bin:…`

`N` is the fixed LLVM major. Because `/opt/llvm/bin` leads `PATH`, the unversioned `clang` and `clang++`
resolve to that major's binaries.

`bolt-N`, `clang-N`, `libclang-rt-N-dev`, `lld-N`, `llvm-N`, and
`llvm-N-dev` are all present. `/usr/local/lib/libbolt_rt_instr.a` is a
compatibility symlink to the BOLT runtime archive under `/opt/llvm/lib`.
Mimalloc is preinstalled (`libmimalloc-dev`) for projects that want a faster
allocator.

The image also carries these Ubuntu development packages for native builds: `libdnnl-dev`, `libffi-dev`,
`libgmp-dev`, `libncurses-dev`, `libnuma-dev`, `libpq-dev`, `libssl-dev`, `libtinfo-dev`, `zlib1g-dev`,
`python3-dev`, and `protobuf-compiler`.

The LLVM major is a fixed constant, `LLVM_MAJOR` (`19`), in
[`hostbootstrap/base_image.py`](../../hostbootstrap/base_image.py), passed to the Dockerfile as a build
argument. It does not roll and no command-line flag selects it; the Dockerfile contains no apt-cache
probing. [base_image.md](../engineering/base_image.md#rolling-input-policy) lists it among the selections
that do not roll.

## Accelerator Daemon CPU Lane

The `linux-cpu` accelerator daemon lane runs in Kubernetes from the CPU
hostbootstrap base image and JIT-builds its generated add worker with the
base-provided `clang++`. The deterministic C++ worker template and build argv are
implemented in `HostBootstrapDemo.Accelerator`. It does not run `ensure` inside the pod; missing `clang++` is a
base-image contract failure. The Linux CPU integration case builds the worker in the pod and drives the demo
UI add request through the CBOR WebSocket daemon path; see
[accelerator_daemon](../engineering/accelerator_daemon.md#tests). Its dated live evidence is recorded in
[the worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).
