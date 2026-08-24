# Cluster tooling

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [go.md](go.md)

> **Purpose**: Document the Kubernetes/cluster CLIs the base image ships and the demo's runtime-owned
> exposure boundary.

This page documents what the base image ships for cluster tooling.

The base image carries the CLIs every project needs to drive a local Kind
cluster + in-cluster registry:

| CLI | Source |
|---|---|
| `docker`, `docker compose` | current Ubuntu 24.04 packages |
| `kind` | current upstream release |
| `kubectl` | current upstream stable release |
| `helm` | current upstream release |
| `skopeo` | current Ubuntu 24.04 package |
| `mc` (MinIO client) | current upstream release |
| `aws` (v2) | current upstream installer |
| `pulumi` | current upstream release |
| `nvkind` | current compatible Go module release (built in-place; see [go.md](go.md)) |

The rolling base workflow discovers releases and architecture-specific URLs at build time over HTTPS.
There is no committed version replay manifest.

## Demo exposure

Stable Kubernetes Service/NodePort values are cluster-internal routing targets. They do not select a port in
the provider/host namespace. The target Kind/nvkind config therefore contains no host-side mappings. After
cluster readiness, hostbootstrap starts an identity-owned relay on the exact cluster network and asks Docker
to publish its declared listeners on `127.0.0.1` without supplying host-port numbers. Docker chooses and binds
them atomically; exact inspection supplies the resolved registry, MinIO, web, and optional accelerator
endpoints to their clients.

The fixed source mappings currently present in demo YAML/Haskell are tracked in the
[legacy-deletion ledger](../../DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md). They are not defaults to copy
or move into Dhall. The registry remains anonymous HTTP, and the demo's MinIO root/S3 values remain fixed
source constants rendered into a Kubernetes Secret. Treat every resolved endpoint as a development-demo
service, not an authenticated production boundary. See
[in_cluster_registry.md](../engineering/in_cluster_registry.md).
