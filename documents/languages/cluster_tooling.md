# Cluster tooling

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [go.md](go.md)

> **Purpose**: Document the Kubernetes/cluster CLIs the base image ships and the loopback-NodePort
> boundary.

This page documents what the base image ships for cluster tooling.

The base image carries the CLIs every project needs to drive a local Kind
cluster + Harbor registry:

| CLI | Source |
|---|---|
| `docker`, `docker compose` | apt (`docker.io`, `docker-compose-v2`) |
| `kind` | latest GitHub release |
| `kubectl` | `dl.k8s.io/release/stable.txt` |
| `helm` | latest GitHub release |
| `skopeo` | apt |
| `mc` (MinIO client) | `dl.min.io` |
| `aws` (v2) | `awscli.amazonaws.com` |
| `pulumi` | latest GitHub release |
| `nvkind` | `github.com/NVIDIA/nvkind` (built in-place; see [go.md](go.md)) |

The `kind`, `kubectl`, `helm`, and `pulumi` versions are resolved on the host by
`hostbootstrap/base_image.py` and passed as `--build-arg` to the Dockerfile;
`docker` and `skopeo` come from apt, `mc` and `aws` from versionless upstream
URLs, and `nvkind` is built from `@latest` in-image.

## Loopback NodePorts

A project's in-cluster services (e.g. MinIO, Pulsar) are reachable from the
host binary at `./.build/<project>` **only over loopback NodePorts
(`127.0.0.0/8`)**. This is a deliberate security boundary: cluster services must
never be reachable off-host.
