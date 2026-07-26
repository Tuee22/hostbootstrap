# Cluster tooling

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [go.md](go.md)

> **Purpose**: Document the Kubernetes/cluster CLIs the base image ships and the demo's current
> NodePort exposure.

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

## Demo NodePorts

The demo does **not** currently enforce one loopback-only boundary for all services.
`demo/kind.yaml` and `demo/kind-in-cluster.yaml` bind the public web (`30080`),
registry (`30500`), and MinIO (`30900`) mappings to `0.0.0.0`. They can therefore be reachable on the VM
or host interfaces allowed by the provider/network/firewall. Only the host-daemon accelerator ingress
(`30081`) is bound to `127.0.0.1`, and local binding is placement rather than authentication.

The `hostbootstrap-demo` consumer instantiates this pattern: its `deploy-minio`
chain step stands up an in-cluster MinIO (S3) store that backs the registry, and its
container-frame binary creates the registry bucket with `mc` through `localhost:30900` from that frame.
`push-image` similarly uses `localhost:30500`, but those client addresses do not change the listeners'
`0.0.0.0` bindings. The registry is anonymous HTTP, and the demo's MinIO root/S3 values are fixed source
constants rendered into a Kubernetes Secret. Treat these endpoints as development-demo services, not an
authenticated or loopback-confined production boundary. See
[in_cluster_registry.md](../engineering/in_cluster_registry.md).
