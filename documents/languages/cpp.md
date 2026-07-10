# C / C++ / LLVM

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [cuda.md](cuda.md), [rust.md](rust.md)

> **Purpose**: Document the C/C++/LLVM toolchain the base image ships.

This page documents what the base image ships for C/C++/LLVM.

The base image ships the standard Ubuntu C/C++ toolchain (`build-essential`,
`gcc`, `g++`, `binutils`, `gdb`, `cmake`, `ninja-build`, `pkg-config`) plus
the **latest available LLVM family** on Ubuntu 24.04 — currently LLVM 19.

LLVM is symlinked at `/opt/llvm` for stable paths:

* `LLVM_CONFIG=/opt/llvm/bin/llvm-config`
* `LIBRARY_PATH=/opt/llvm/lib`
* `BOLT_RT_INSTR_LIB=/opt/llvm/lib/libbolt_rt_instr.a`
* `CC=clang-N`
* `CXX=clang++-N`
* `PATH=/opt/llvm/bin:…`

`bolt-N`, `clang-N`, `libclang-rt-N-dev`, `lld-N`, `llvm-N`, and
`llvm-N-dev` are all present. `/usr/local/lib/libbolt_rt_instr.a` is a
compatibility symlink to the BOLT runtime archive under `/opt/llvm/lib`.
Mimalloc is preinstalled (`libmimalloc-dev`) for projects that want a faster
allocator.

The LLVM major version is passed as `LLVM_MAJOR` from the host CLI; the
Dockerfile contains no apt-cache probing.

## Accelerator Daemon CPU Lane

The `linux-cpu` accelerator daemon lane runs in Kubernetes from the CPU
hostbootstrap base image and JIT-builds its generated add worker with the
base-provided `clang++`. The deterministic C++ worker template and build argv are
implemented in `HostBootstrapDemo.Accelerator`; live pod build/run is still an
integration gate. It does not run `ensure` inside the pod; missing `clang++` is a
base-image contract failure. The integration test for this lane must build the
worker in the pod and drive the demo UI add request through the CBOR WebSocket
daemon path. See
[accelerator_daemon](../engineering/accelerator_daemon.md).
