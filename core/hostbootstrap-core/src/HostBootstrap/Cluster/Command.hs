{- | Every cluster effect this project performs, as a described command.

§ KK admits one closed effect vocabulary and one interpreter for it, and this
module is where the cluster's operations enter that vocabulary. Each function
returns a 'HostCommand' value: the tool the frame table names, the exact
argument vector, the stdio disposition, and the frame whose process reads it.
None of them can run anything, which is the property that makes an argument
vector comparable by application rather than only observable by launching it.

The pairing with "HostBootstrap.Cluster.Report" is the whole design. This module
says what to ask; that one says what an answer means. A driver composes the two
and holds its clauses through the seam ("HostBootstrap.Ownership.Primitive"), so
no step of a cluster transaction is a program written in another language and
parsed back.

__Objective boundary.__ Three tools answer here and they answer about different
things. @kind@ owns the cluster as a named object; the container runtime owns the
node containers the cluster is realized as, and is what clause 3's identity comes
from, because a cluster name is reusable and a container identifier is not; and
@kubectl@ owns the Kubernetes API's own view, which is a readiness question
rather than an ownership one. Keeping the three in one place is what makes it
checkable that a mutation is only ever asked of the first two.

The kubeconfig a @kubectl@ question needs travels on standard input rather than
in @argv@, so a credential for a live control plane never appears in a process
listing.
-}
module HostBootstrap.Cluster.Command (
    -- * Asking the cluster driver
    listClustersCommand,
    readKubeconfigCommand,
    createClusterCommand,
    deleteClusterCommand,

    -- * Asking the container runtime
    listNodeContainerCommand,
    readNodeContainerIdCommand,
    readNodeContainerRunningCommand,
    updateNodeContainerCommand,

    -- * Asking the Kubernetes API
    readApiReadyzCommand,
    listApiNodesCommand,

    -- * What the cluster drives
    clusterCommandTools,
)
where

import HostBootstrap.Effect.Vocabulary (HostCommand, hostCommand, withCommandStdin)
import HostBootstrap.HostTool (HostTool (Docker, Kind, Kubectl))

-- ---------------------------------------------------------------------------
-- What the cluster drives

{- | Every tool a cluster transaction reaches, declared once.

§ K makes the host-tool set closed and § LL makes a driver a __row__ of one
table rather than a module that resolves whatever it happens to need. The tools
a cluster drives are therefore named here, beside the questions they answer and
beside the frame whose process asks them, so a driver and the row that holds its
clauses are declared in one place.

The declaration is exact in both directions: a tool named by a command below and
missing here would be one this boundary drives without declaring, and a tool
named here that no command reaches would be an entry the enumeration carries for
nobody.
-}
clusterCommandTools :: [HostTool]
clusterCommandTools = [Kind, Docker, Kubectl]

-- ---------------------------------------------------------------------------
-- The cluster driver

{- | Ask the driver which clusters it names.

The whole listing rather than a membership question about one name, because a
driver that names the same cluster twice is contradicting itself and a
membership answer cannot say so. The driver's global quiet flag keeps its
authoritative empty listing on standard output without the informational
@No kind clusters found.@ diagnostic it otherwise writes to standard error.
-}
listClustersCommand :: HostCommand
listClustersCommand = kindCommand ["get", "clusters"]

-- | Ask the driver for one cluster's kubeconfig.
readKubeconfigCommand :: String -> HostCommand
readKubeconfigCommand clusterName =
    kindCommand ["get", "kubeconfig", "--name", clusterName]

{- | Create the cluster, writing its initial kubeconfig into one private staging file.

The caller opens the staging file on the local filesystem before this command
and removes it after the child exits. The authoritative durable credential is a
fresh exact readback published by the ownership transaction after creation, so
Kind never takes its client-side lock on a host-provider mount. A declared
configuration is optional because a cluster with no declared topology is a
legitimate single-node one, and an empty @--config@ would name a file that does
not exist rather than mean "none". The bounded wait keeps a successful create
from racing the separate fresh API and node-readiness observation that follows
it.
-}
createClusterCommand ::
    -- | the cluster's own name
    String ->
    -- | the declared configuration snapshot, where the plan declares one
    Maybe FilePath ->
    -- | the private local staging file this run has opened for Kind
    FilePath ->
    HostCommand
createClusterCommand clusterName config kubeconfig =
    kindCommand
        ( ["create", "cluster", "--name", clusterName]
            <> maybe [] (\path -> ["--config", path]) config
            <> ["--kubeconfig", kubeconfig, "--wait", "10m"]
        )

{- | Remove the cluster the driver names.

Addressed by name, which is all the driver admits. What keeps this from removing
somebody else's cluster is not the argument vector: it is clause 4, which
re-observes the node containers' identities under the durable record before this
command is issued at all.
-}
deleteClusterCommand :: String -> HostCommand
deleteClusterCommand clusterName =
    kindCommand ["delete", "cluster", "--name", clusterName]

{- | Keep Kind's progress chatter off the report vocabulary's error stream.

Every successful answer is classified strictly, including mutations whose
standard output is otherwise ignored. Kind writes ordinary progress to standard
error by default, so its own global quiet flag is part of every typed Kind
command rather than an exception in each report classifier.
-}
kindCommand :: [String] -> HostCommand
kindCommand arguments = hostCommand Kind ("--quiet" : arguments)

-- ---------------------------------------------------------------------------
-- The container runtime

{- | Ask the runtime for the container standing at one node's exact name.

Anchored on both ends, because a substring filter matches every node whose name
merely contains this one — and the answer to "which container is this node"
would then depend on what else happens to exist. Untruncated, because a
shortened identifier is a prefix rather than an identity.
-}
listNodeContainerCommand :: String -> HostCommand
listNodeContainerCommand nodeName =
    hostCommand
        Docker
        [ "container"
        , "ls"
        , "--all"
        , "--quiet"
        , "--no-trunc"
        , "--filter"
        , "name=^/" <> nodeName <> "$"
        ]

{- | Ask the runtime for one container's own identifier.

Taken against the identifier a listing just produced, so the answer either
confirms it or shows that the name moved between the two questions.
-}
readNodeContainerIdCommand :: String -> HostCommand
readNodeContainerIdCommand container =
    hostCommand Docker ["inspect", "-f", "{{.Id}}", container]

-- | Ask the runtime whether one container is running.
readNodeContainerRunningCommand :: String -> HostCommand
readNodeContainerRunningCommand container =
    hostCommand Docker ["inspect", "-f", "{{.State.Running}}", container]

{- | Apply one cordon's declared limits to one node container.

The container is addressed by the identity the durable record bound, never by
the node's name: the name is what a replacement inherits and the identity is what
it cannot.
-}
updateNodeContainerCommand ::
    -- | the limit flags the cordon declares
    [String] ->
    -- | the bound container identity
    String ->
    HostCommand
updateNodeContainerCommand limits container =
    hostCommand Docker (["update"] <> limits <> [container])

-- ---------------------------------------------------------------------------
-- The Kubernetes API

{- | Ask the API server whether it reports itself ready.

The kubeconfig is handed over standard input and named as @\/dev\/stdin@, so the
credential is neither written to a path this transaction would then own nor
visible in a process listing.
-}
readApiReadyzCommand :: String -> HostCommand
readApiReadyzCommand kubeconfig =
    withCommandStdin
        kubeconfig
        (hostCommand Kubectl ["--kubeconfig=/dev/stdin", "get", "--raw=/readyz"])

{- | Ask the API server for every node it knows, in full.

JSON rather than a column selection, because the readiness decision is over the
node's conditions and a formatted column would put the classification in the
question instead of in the total function that answers it.
-}
listApiNodesCommand :: String -> HostCommand
listApiNodesCommand kubeconfig =
    withCommandStdin
        kubeconfig
        (hostCommand Kubectl ["--kubeconfig=/dev/stdin", "get", "nodes", "-o", "json"])
