# Go

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [cluster_tooling.md](cluster_tooling.md)

> **Purpose**: Document the Go toolchain the base image ships and the in-place `nvkind` build.

This page documents what the base image ships for Go.

Go is first-class in the base image. The latest stable Go toolchain is
installed at `/opt/go` (resolved via `https://go.dev/dl/?mode=json`). The
image sets the conventional environment variables alongside the other
languages':

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

```Dockerfile
RUN CGO_ENABLED=1 /opt/go/bin/go install github.com/NVIDIA/nvkind/cmd/nvkind@latest \
 && install -m 0755 /opt/cache/go/bin/nvkind /usr/local/bin/nvkind
```

A build can only ever produce the host-native arch — there is no cross-arch
build for Go, which keeps this stage simple.
