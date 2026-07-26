# Go

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [cluster_tooling.md](cluster_tooling.md)

> **Purpose**: Document the Go toolchain the base image ships and the in-place `nvkind` build.

This page documents what the base image ships for Go.

Go is first-class in the base image. The rolling workflow resolves the latest stable upstream release
for the native architecture and installs it at `/opt/go`. The image sets the
conventional environment variables alongside the other languages':

```
GOROOT=/opt/go
GOPATH=/opt/cache/go
GOCACHE=/opt/cache/go/build
GOMODCACHE=/opt/cache/go/mod
GOTOOLCHAIN=local
PATH=…/opt/go/bin:/opt/cache/go/bin:…
```

## nvkind

The base image builds `nvkind` natively in the final image, in a **single
stage** with `CGO_ENABLED=1`. The base default `CC=clang-N` is used for cgo;
gcc is still installed for projects that opt into it explicitly. There is no
multi-stage cross-compile path for `nvkind`; it is built natively in the final
image.

The layer installs the current compatible `nvkind` module release and places the native binary at
`/usr/local/bin/nvkind`. This selection is rolling cache/tooling input, not a public source-version
contract.

A build can only ever produce the host-native arch — there is no cross-arch
build for Go, which keeps this stage simple.
