# Rust

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [cpp.md](cpp.md)

> **Purpose**: Document the Rust toolchain the base image ships.

This page documents what the base image ships for Rust.

The base image installs the pinned Rust toolchain via `rustup`:

```
RUSTUP_TOOLCHAIN=1.95.0
```

with `llvm-tools-preview` and `rustfmt` components. Caches:

* `CARGO_HOME=/opt/cache/cargo`
* `CARGO_TARGET_DIR=/opt/build/rust/target`
* `CARGO_HTTP_TIMEOUT=120`
* `CARGO_NET_RETRY=5`

LLVM LLD and BOLT (from the apt LLVM family, see [cpp.md](cpp.md)) are
available for optimised Rust builds when projects opt in.
