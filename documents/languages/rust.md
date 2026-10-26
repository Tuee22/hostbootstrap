# Rust

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md)

> **Purpose**: Document the Rust toolchain the base image ships.

This page documents what the base image ships for Rust.

The base image installs Rustup's rolling stable toolchain:

```
RUSTUP_TOOLCHAIN=stable
```

with `llvm-tools-preview` and `rustfmt` components, on top of Rustup's minimal profile. The minimal
profile carries no `clippy`, so `cargo clippy` is unavailable until a project adds that component.

`RUSTUP_TOOLCHAIN` is set image-wide, and Rustup ranks that variable above a project's
`rust-toolchain.toml`, so inside the container a project's toolchain pin is ignored. A project that needs
its pin honoured unsets `RUSTUP_TOOLCHAIN` for its build.

Caches:

* `CARGO_HOME=/opt/cache/cargo`
* `CARGO_TARGET_DIR=/opt/build/rust/target`
* `CARGO_HTTP_TIMEOUT=120`
* `CARGO_NET_RETRY=5`

LLVM LLD and BOLT (from the apt LLVM family, see [cpp.md](cpp.md)) are
available for optimised Rust builds when projects opt in.
