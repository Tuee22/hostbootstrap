# Cluster tooling

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [go.md](go.md)

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
| `nvkind` | latest Go module release (built in-place; see [go.md](go.md)) |

The rolling base workflow discovers releases and architecture-specific URLs at build time over HTTPS.
There is no committed version replay manifest.

## Demo exposure

The demo's fixed Kubernetes NodePort numbers (registry `30500`, web `30080`, S3 store `30900`, and on the
Kind lanes accelerator `30081`) are cluster-internal routing targets only; they do not select a port in the
provider or host namespace. The demo's Kind and nvkind configs contain no host-side mappings, and
`ClusterConfigSpec` and `CommandsSpec` fail if either rendering carries an `extraPortMappings` or `hostPort`
entry. Host-side reachability comes from a relay the cluster backend creates after the cluster is Ready, on
the cluster's container network, with loopback ports Docker assigns; clients consume the endpoint the backend
reads back from that exact relay. [network_reachability.md](../architecture/network_reachability.md) is the
canonical home for the relay's ownership, its port binding, and endpoint resolution.

These NodePort numbers are not defaults to copy or move into Dhall. The registry remains anonymous HTTP, and
the demo's S3 root credentials remain fixed
source constants rendered into a Kubernetes Secret. Treat every resolved endpoint as a development-demo
service, not an authenticated production boundary. See
[in_cluster_registry.md](../engineering/in_cluster_registry.md).
