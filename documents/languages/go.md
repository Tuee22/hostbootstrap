# Go

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [cluster_tooling.md](cluster_tooling.md)

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

The GOTOOLCHAIN=local setting means the `go` command only ever uses the toolchain installed at `/opt/go` and never
downloads another one. A module whose `go.mod` `go` or `toolchain` line requires a newer Go than the image
carries fails to build instead of triggering a toolchain download.

## nvkind

The base image builds `nvkind` natively in the final image, in a **single
stage** with `CGO_ENABLED=1`. The base default `CC=clang-N` is used for cgo;
gcc is still installed for projects that opt into it explicitly. There is no
multi-stage cross-compile path for `nvkind`; it is built natively in the final
image.

The layer runs `go install` for the `nvkind` module's latest release, which writes the binary to
`/opt/cache/go/bin/nvkind`, then copies it to `/usr/local/bin/nvkind`. Both copies stay in the image.
`/opt/cache/go/bin` precedes `/usr/local/bin` on `PATH`, so a bare `nvkind` runs the
`/opt/cache/go/bin` copy; replacing only `/usr/local/bin/nvkind` does not change what `PATH` resolves. This
selection is rolling cache/tooling input, not a public source-version contract.

The base image is built only for the host's native architecture, so this `nvkind` build never
cross-compiles. That is a property of the base build only; it places no limit on a project's own
cross-compilation through the GOOS and GOARCH variables.
