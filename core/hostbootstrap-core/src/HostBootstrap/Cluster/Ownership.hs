{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The four ownership clauses, held over a cluster and its node containers.

@development_plan_standards.md § EE@ says a resource this project mutates is
owned under four clauses, and § LL says a driver is a __row__ of one frame table
rather than a module of parallel logic. This module is where the two meet for a
Kind cluster: clause 1 is the protected store's exclusive entry, clause 2 that
store's compare-and-swap, clause 3 the container identity the runtime itself
answers with, and clause 4 the conditional release the later transactions hold
over the same records.

Nothing here is written in another language. /What to ask/ is a described command
("HostBootstrap.Cluster.Command"), /what an answer means/ is a total
classification ("HostBootstrap.Cluster.Report"), /where the transaction stands/
is a total function of three values ("HostBootstrap.Cluster.Resume"), and /what a
clause is/ belongs to the one seam ("HostBootstrap.Ownership.Primitive"). What is
left for this module is the order those compose in.

__Every node is an owned object.__ A cluster is a name the driver knows and a set
of containers the runtime knows, and clause 3 can bind exactly one identity per
record — so the cluster's own record binds the control-plane container and each
other node carries its own record beside it, exactly as a share is an object
inside a provider instance. That is what lets a later cordon address a node by
the identity this run bound rather than by the name a replacement inherits.

__Every record is published before the creating command.__ One
@kind create cluster@ brings every node container into existence at once, so
there is no per-node moment at which a record could be written first. All of them
are therefore published — over an explicit absence — before the create runs, and
bound afterwards from what the runtime reports. A run that dies between the two
leaves records and no containers, which is a standing the next entry re-enters
rather than a mystery, because clause 2's publication is idempotent.

Whether a record survives that crash at all is __not__ a question this module
answers. Every durable byte it publishes is the protected store's
compare-and-swap, so the partial-write, partial-fsync, and partial-unlink windows
belong to the store's own contract — the
[ownership-clauses-and-reservations phase](../../../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md)'s.
This boundary inherits that contract by holding no durable byte of its own.
-}
module HostBootstrap.Cluster.Ownership (
    -- * The cluster a transaction owns
    OwnedCluster (..),
    ownedClusterClaim,
    ownedClusterRecordKey,
    ownedNodeRecordKey,
    ownedClusterNodeNames,

    -- * What a transaction did
    ClusterReconcileOutcome (..),
    ClusterReadinessOutcome (..),
    ClusterReleaseOutcome (..),

    -- * Why a transaction could not proceed
    ClusterOwnershipFault (..),
    clusterOwnershipFaultMessage,

    -- * What the authorities are currently reporting
    observeOwnedNode,
    observeOwnedClusterPresence,
    ownedClusterStanding,
    ownedClusterNodes,
    ownedClusterRunning,

    -- * The transactions
    reconcileOwnedCluster,
    observeOwnedClusterReadiness,
    cordonOwnedCluster,
    releaseOwnedCluster,
    releaseRetainedOwnedCluster,
)
where

import Control.Exception (IOException, finally, mask, onException, try)
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Command (
    createClusterCommand,
    deleteClusterCommand,
    listApiNodesCommand,
    listClustersCommand,
    listNodeContainerCommand,
    readApiReadyzCommand,
    readKubeconfigCommand,
    readNodeContainerIdCommand,
    readNodeContainerRunningCommand,
    updateNodeContainerCommand,
 )
import HostBootstrap.Cluster.Cordon (ResourceBudget, kindNodeCordonLimits)
import HostBootstrap.Cluster.Report (
    ApiReadiness (ApiNotReady, ApiReady),
    ClusterPresence (ClusterAbsent, ClusterPresent),
    ClusterReportFault,
    ContainerRunState (ContainerNotRunning, ContainerRunning),
    NodeReadiness (NodesNotReady, NodesReady, NodesUnexpected),
    classifyApiNodes,
    classifyApiReadiness,
    classifyClusterListing,
    classifyClusterReport,
    classifyContainerRunState,
    classifyKubeconfig,
    classifyNodeContainer,
    classifyNodeContainerIdentity,
    clusterReportFaultMessage,
    clusterReportLineBound,
    containerReference,
 )
import HostBootstrap.Cluster.Resume (
    ClusterStanding (
        ClusterCreatedUnbound,
        ClusterNothingDone,
        ClusterOriginRecorded,
        ClusterOwned
    ),
    ClusterStandingConflict (NodeReplaced),
    clusterStanding,
    clusterStandingConflictMessage,
    nodeStanding,
 )
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun)
import HostBootstrap.Effect.Vocabulary (HostCommand)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Ownership.Clause (Bound, Recorded, Releasable)
import HostBootstrap.Ownership.Object (
    ConflictReport (ConflictReport, conflictExpected, conflictObserved, conflictSubject),
    ObjectIdentity,
    ObjectKind (ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OriginRecord,
    OwnerClaim,
    OwnershipFault (
        OwnershipConflict,
        OwnershipMalformed,
        OwnershipProbeFailed
    ),
    mkOwnerClaim,
    originRecordKind,
    originRecordOrigin,
    ownershipFaultMessage,
    parseOriginRecord,
    renderOriginRecord,
 )
import HostBootstrap.Ownership.Primitive (
    bindReportedIdentity,
    enterReportedObject,
    recordReportedOrigin,
    releaseReportedObject,
    reobserveReportedIdentity,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    RecordKey,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    protectedErrorMessage,
    readProtectedRecord,
 )
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile, renameFile)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (hClose, hFlush, openBinaryTempFile)

-- ---------------------------------------------------------------------------
-- What is owned

{- | Everything a transaction needs to know about the cluster it owns.

No handle: a transaction reads its own records, asks the two authorities its own
questions, and decides from those, so nothing is carried in from a previous call
and kept correct.

The owner is this run's durable binding, and the claim is minted from it. That is
what makes a claim fresh in the only sense that matters: two attempts at one
generation derive the same claim and are the same transaction, while a new
generation derives a different one and owns a different cluster.
-}
data OwnedCluster = OwnedCluster
    { ownedClusterName :: String
    -- ^ the cluster's own name, which is also its record's key
    , ownedClusterControlPlane :: String
    -- ^ the node whose container carries the cluster's own identity
    , ownedClusterWorkers :: [String]
    -- ^ every other declared node, each an owned object of its own
    , ownedClusterConfig :: Maybe FilePath
    -- ^ the declared configuration snapshot, where the plan declares one
    , ownedClusterKubeconfig :: FilePath
    -- ^ the durable path where this run atomically publishes the exact credential
    , ownedClusterOwner :: Text
    -- ^ this run's durable owner binding
    }
    deriving (Eq, Show)

{- | Every declared node, control plane first.

One ordering, so a transaction that publishes records and a transaction that
re-observes them walk the same list in the same order and a diagnostic naming
"the first node that disagreed" means the same thing in both.
-}
ownedClusterNodeNames :: OwnedCluster -> [String]
ownedClusterNodeNames owned = ownedClusterControlPlane owned : ownedClusterWorkers owned

{- | The claim this run stamps on its records.

Derived rather than drawn from a generator, so a resumed entry mints exactly the
claim the entry that published the record did and recognizes its own records.
-}
ownedClusterClaim :: OwnedCluster -> OwnerClaim
ownedClusterClaim = mkOwnerClaim . TextEncoding.encodeUtf8 . ownedClusterOwner

{- | The protected-store key the cluster's own durable record lives under.

The cluster name, because that is what the plan declares and what the driver
answers about.
-}
ownedClusterRecordKey :: OwnedCluster -> Either ProtectedError RecordKey
ownedClusterRecordKey = mkRecordKey . Text.pack . ownedClusterName

{- | The protected-store key one node's own durable record lives under.

Prefixed by the cluster's key, so every record a cluster owns is discoverable
from the cluster's own name and a node record can never be mistaken for a
cluster's.
-}
ownedNodeRecordKey :: OwnedCluster -> String -> Either ProtectedError RecordKey
ownedNodeRecordKey owned node =
    mkRecordKey (Text.pack (ownedClusterName owned <> "." <> node))

{- | The key one declared node's record lives under, control plane included.

The control plane's record /is/ the cluster's, because clause 3 binds exactly one
identity per record and the cluster's own identity is that container's. Written
once here so no transaction can come to disagree with another about which key a
node's record is under.
-}
nodeRecordKey ::
    OwnedCluster ->
    -- | the cluster's own key, which the control plane shares
    RecordKey ->
    String ->
    Either ProtectedError RecordKey
nodeRecordKey owned key node
    | node == ownedClusterControlPlane owned = Right key
    | otherwise = ownedNodeRecordKey owned node

-- ---------------------------------------------------------------------------
-- What a transaction did

{- | What reconciling established, and how far it had to go.

Three end states reached by different histories, and an operator reading a run
wants to know which: a first creation, a resumed entry whose cluster already
existed under this record, and an entry that found all three clauses held.
-}
data ClusterReconcileOutcome
    = -- | this entry created the cluster and bound its containers
      ClusterCreated ObjectIdentity
    | -- | a previous entry created it under this record; this one bound it
      ClusterRecovered ObjectIdentity
    | -- | clauses 1 through 3 were already held over this cluster
      ClusterAlreadyOwned ObjectIdentity
    deriving (Eq, Show)

{- | What the readiness probe found, once the clauses were re-entered.

Four answers and no fault among them, because each is a true statement about a
live control plane rather than a tool failing to answer. A cluster whose API
server has not come up, whose nodes have not joined, and whose node set is not
the one the plan declares are three different things an operator waiting on a
bring-up needs to be able to tell apart.
-}
data ClusterReadinessOutcome
    = -- | the API server answers and every declared node reports itself Ready
      ClusterReady
    | -- | the control plane does not report itself ready yet
      ClusterApiUnready
    | -- | the API server answers and at least one declared node is not Ready
      ClusterNodesUnready
    | -- | the API server names a node set the plan does not declare
      ClusterNodesUndeclared
    deriving (Eq, Show)

{- | What releasing observed.

'ClusterStillPresent' is not a failure to remove: it is the runtime still naming
this run's own container after a delete the driver accepted, which leaves every
record exactly where it was so the next entry re-enters the same transaction.
-}
data ClusterReleaseOutcome
    = -- | the cluster and every record of it are gone, and this entry did it
      ClusterReleased
    | -- | there was nothing to remove, and any record of it is now forgotten
      ClusterAlreadyReleased
    | -- | the runtime still names a node this record binds, so nothing was forgotten
      ClusterStillPresent
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Why a transaction could not proceed

{- | The closed set of reasons a transaction stopped short of an outcome.

Four, and each names a different authority: the protected store, the answering
tool's own report, the standing three values decide, and the seam that mints the
clause tokens. A driver above this module maps them onto its own vocabulary
through the one renderer, so no reason is described twice.
-}
data ClusterOwnershipFault
    = -- | the protected store could not be read or written
      ClusterOwnershipStore ProtectedError
    | -- | a tool's answer is not one this vocabulary admits
      ClusterOwnershipReport ClusterReportFault
    | -- | the facts do not describe a transaction this run may continue
      ClusterOwnershipStanding ClusterStandingConflict
    | -- | a clause could not be held
      ClusterOwnershipClause OwnershipFault
    | -- | the credential could not be staged or atomically published
      ClusterOwnershipKubeconfig Text
    deriving (Eq, Show)

-- | One rendering, so no caller writes a second description of a refusal.
clusterOwnershipFaultMessage :: ClusterOwnershipFault -> Text
clusterOwnershipFaultMessage fault = case fault of
    ClusterOwnershipStore inner -> protectedErrorMessage inner
    ClusterOwnershipReport inner -> clusterReportFaultMessage inner
    ClusterOwnershipStanding inner -> clusterStandingConflictMessage inner
    ClusterOwnershipClause inner -> ownershipFaultMessage inner
    ClusterOwnershipKubeconfig inner -> "cluster kubeconfig: " <> inner

-- ---------------------------------------------------------------------------
-- What the authorities are currently reporting

{- | What the runtime says stands at one node's name.

Two questions rather than one, and __both addressed by the node's name__: the
listing produces the identifier standing there and the inspection asks the name
again for its own identifier. Addressing the second question by the identifier
the first produced would confirm only that the identifier still resolves; asking
the name is what makes a container replaced between the two answer differently,
which is a conflict rather than an identity.
-}
observeOwnedNode ::
    HostConfig ->
    String ->
    IO (Either ClusterOwnershipFault Origin)
observeOwnedNode cfg node = do
    listed <- classifyNodeContainer <$> interpret cfg (listNodeContainerCommand node)
    case listed of
        Left fault -> pure (Left (ClusterOwnershipReport fault))
        Right Nothing -> pure (Right OriginAbsent)
        Right (Just candidate) -> do
            readback <-
                classifyNodeContainerIdentity
                    <$> interpret cfg (readNodeContainerIdCommand node)
            pure $ case readback of
                Left fault -> Left (ClusterOwnershipReport fault)
                Right observed
                    | observed == candidate -> Right (OriginPresent observed)
                    | otherwise -> Left (nodeMovedUnderReadback candidate observed)

-- | What the driver says about the cluster's name.
observeOwnedClusterPresence ::
    HostConfig ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterPresence)
observeOwnedClusterPresence cfg owned = do
    listed <- classifyClusterListing (ownedClusterName owned) <$> interpret cfg listClustersCommand
    pure (either (Left . ClusterOwnershipReport) Right listed)

{- | Where the cluster transaction stands, from the record and both authorities.

One decision, taken in one place, so reconcile and every later transaction cannot
come to disagree about what an unbound record beside a present cluster means.
-}
ownedClusterStanding ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterStanding)
ownedClusterStanding cfg session key owned = do
    presence <- observeOwnedClusterPresence cfg owned
    case presence of
        Left fault -> pure (Left fault)
        Right listed -> do
            observed <- observeOwnedNode cfg (ownedClusterControlPlane owned)
            case observed of
                Left fault -> pure (Left fault)
                Right origin -> do
                    stored <- readRecordUnder session key
                    pure $ case stored of
                        Left fault -> Left fault
                        Right record -> case clusterStanding record listed origin of
                            Left conflict -> Left (ClusterOwnershipStanding conflict)
                            Right standing -> Right standing

-- ---------------------------------------------------------------------------
-- Reconciling

{- | Hold clauses 1 through 3 over the cluster, creating it if it is not there.

The caller supplies the exclusive entry, because clause 1 is the store's and one
entry covers a whole transaction. Everything after it is this module's, in the
only order the tokens admit: observe, decide where the transaction stands,
publish every record, create, re-observe, bind every record.
-}
reconcileOwnedCluster ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReconcileOutcome)
reconcileOwnedCluster cfg session key owned = do
    entered <- ownedClusterStanding cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right (ClusterOwned identity) ->
            requireOwnedWorkers cfg session owned (ClusterAlreadyOwned identity)
        Right (ClusterCreatedUnbound _) -> publishThenBind ClusterRecovered
        Right ClusterNothingDone -> publishThenCreate
        Right ClusterOriginRecorded -> publishThenCreate
  where
    publishThenCreate = do
        published <- publishEveryRecord cfg session key owned
        case published of
            Left fault -> pure (Left fault)
            Right () -> createThenBind cfg session key owned
    publishThenBind outcome = do
        published <- publishOwnedClusterKubeconfig cfg owned
        case published of
            Left fault -> pure (Left fault)
            Right () -> fmap outcome <$> bindNodeRecords cfg session key owned

{- | Publish clause 2 over every record this cluster owns, before any mutation.

Each in its own short-lived entry rather than in one nest of them, because the
publication is idempotent: what the token asserts is that this record is durable,
and re-entering to bind it later re-asserts exactly the same fact.
-}
publishEveryRecord ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ())
publishEveryRecord _cfg session key owned = go (ownedClusterNodeNames owned)
  where
    go [] = pure (Right ())
    go (node : rest) = case nodeRecordKey owned key node of
        Left failure -> pure (Left (ClusterOwnershipStore failure))
        Right nodeKey -> do
            published <-
                withRecordedNode session nodeKey owned node (\_recorded -> pure (Right ()))
            case published of
                Left fault -> pure (Left fault)
                Right () -> go rest

{- | Create the cluster, then bind what the runtime reports for every node.

The create is one described command through the one interpreter, so the interval
between the published records and the bound identities is an ordinary
outcome-unknown window rather than an instruction inside a program written in
another language.
-}
createThenBind ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReconcileOutcome)
createThenBind cfg session key owned = do
    created <- runCreateCommand cfg owned
    case created of
        Left fault -> pure (Left fault)
        Right captured -> case classifyClusterReport clusterReportLineBound captured of
            Left fault -> pure (Left (ClusterOwnershipReport fault))
            Right _ -> do
                published <- publishOwnedClusterKubeconfig cfg owned
                case published of
                    Left fault -> pure (Left fault)
                    Right () -> do
                        bound <- bindNodeRecords cfg session key owned
                        pure (fmap ClusterCreated bound)

{- | Give Kind a unique private local file for only the duration of creation.

The path is selected by the host runtime rather than derived from durable state,
so a host-provider mount is never asked to implement Kind's sidecar lock. The
file is opened before its name is handed to Kind, which prevents a competing
invocation from selecting the same staging object, and cleanup runs on every
reported or exceptional exit.
-}
runCreateCommand ::
    HostConfig ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault (Either String CapturedRun))
runCreateCommand cfg owned = do
    attempted <- tryIO $ mask $ \restore -> do
        temporaryRoot <- getTemporaryDirectory
        let template = ".hostbootstrap-kind-" <> ownedClusterName owned <> ".kubeconfig"
        (staging, handle) <- openBinaryTempFile temporaryRoot template
        let removeStaging = do
                present <- doesFileExist staging
                when present (removeFile staging)
        hClose handle `onException` removeStaging
        restore
            ( interpret
                cfg
                ( createClusterCommand
                    (ownedClusterName owned)
                    (ownedClusterConfig owned)
                    staging
                )
            )
            `finally` removeStaging
    pure $ case attempted of
        Left failure -> Left (kubeconfigFileFault "stage the creating command's private credential" failure)
        Right result -> Right result

{- | Read the exact live credential and atomically replace the durable copy.

The readback is authoritative even after an outcome-unknown create: it asks Kind
for the cluster that now stands rather than trusting bytes left by the creating
client. Publication precedes every binding, so a durable ownership row can never
say the nodes are bound while its credential is absent or partial.
-}
publishOwnedClusterKubeconfig ::
    HostConfig ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ())
publishOwnedClusterKubeconfig cfg owned = do
    credential <- classifyKubeconfig <$> interpret cfg (readKubeconfigCommand (ownedClusterName owned))
    case credential of
        Left fault -> pure (Left (ClusterOwnershipReport fault))
        Right kubeconfig -> do
            published <- atomicPublishKubeconfig (ownedClusterKubeconfig owned) kubeconfig
            pure $ case published of
                Left failure -> Left (kubeconfigFileFault "publish the exact durable credential" failure)
                Right () -> Right ()

{- | Flush complete credential bytes to a private sibling and rename them over
the destination, so readers observe either the previous complete credential or
the new complete credential.
-}
atomicPublishKubeconfig :: FilePath -> String -> IO (Either IOException ())
atomicPublishKubeconfig destination kubeconfig = tryIO $ mask $ \restore -> do
    let directory = takeDirectory destination
        template = "." <> takeFileName destination <> ".publish"
    (temporary, handle) <- openBinaryTempFile directory template
    let removeTemporary = do
            present <- doesFileExist temporary
            when present (removeFile temporary)
        closeAndRemove = hClose handle `finally` removeTemporary
    restore (ByteStringChar8.hPutStr handle (ByteStringChar8.pack kubeconfig) >> hFlush handle)
        `onException` closeAndRemove
    hClose handle `onException` removeTemporary
    restore (renameFile temporary destination) `onException` removeTemporary

tryIO :: IO value -> IO (Either IOException value)
tryIO = try

kubeconfigFileFault :: Text -> IOException -> ClusterOwnershipFault
kubeconfigFileFault operation failure =
    ClusterOwnershipKubeconfig (operation <> " failed: " <> Text.pack (show failure))

{- | Bind clause 3 over every node, answering with the control plane's identity.

The control plane's is the cluster's own, which is why it is the one returned: a
caller holding a cluster handle holds one identity, and it is the one a later
transaction re-observes to decide whether this is still its cluster.
-}
bindNodeRecords ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ObjectIdentity)
bindNodeRecords cfg session key owned = go (ownedClusterNodeNames owned) Nothing
  where
    go [] Nothing = pure (Left (createLostItsControlPlane owned))
    go [] (Just identity) = pure (Right identity)
    go (node : rest) carried = case nodeRecordKey owned key node of
        Left failure -> pure (Left (ClusterOwnershipStore failure))
        Right nodeKey -> do
            bound <- bindOneNode cfg session nodeKey owned node
            case bound of
                Left fault -> pure (Left fault)
                Right identity
                    | node == ownedClusterControlPlane owned -> go rest (Just identity)
                    | otherwise -> go rest carried

bindOneNode ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    String ->
    IO (Either ClusterOwnershipFault ObjectIdentity)
bindOneNode cfg session nodeKey owned node = do
    observed <- observeOwnedNode cfg node
    case observed of
        Left fault -> pure (Left fault)
        Right origin -> do
            stored <- readRecordUnder session nodeKey
            case stored of
                Left fault -> pure (Left fault)
                Right record -> case nodeStanding record origin of
                    Left conflict -> pure (Left (ClusterOwnershipStanding conflict))
                    Right (ClusterOwned identity) -> pure (Right identity)
                    Right (ClusterCreatedUnbound identity) ->
                        withRecordedNode session nodeKey owned node $ \recorded ->
                            bindIdentity session nodeKey recorded identity identity
                    Right ClusterNothingDone -> pure (Left (createLostItsNode node))
                    Right ClusterOriginRecorded -> pure (Left (createLostItsNode node))

{- | Every worker this cluster declares is bound under its own record.

Asked even on the already-owned path, because the cluster's own identity says
nothing about the other nodes: a worker replaced out of band leaves a control
plane that still answers with the identity this run bound, and a transaction that
stopped at that answer would go on to cordon somebody else's container.
-}
requireOwnedWorkers ::
    HostConfig ->
    ProtectedSession session ->
    OwnedCluster ->
    ClusterReconcileOutcome ->
    IO (Either ClusterOwnershipFault ClusterReconcileOutcome)
requireOwnedWorkers cfg session owned outcome = go (ownedClusterWorkers owned)
  where
    go [] = pure (Right outcome)
    go (node : rest) = case ownedNodeRecordKey owned node of
        Left failure -> pure (Left (ClusterOwnershipStore failure))
        Right nodeKey -> do
            identity <- requireOwnedNode cfg session nodeKey node (createLostItsNode node)
            case identity of
                Left fault -> pure (Left fault)
                Right _ -> go rest

-- ---------------------------------------------------------------------------
-- Re-entering what this record already owns

{- | Every declared node, with the identity its own durable record binds.

The one step each later transaction re-enters from. It asks the driver whether
the cluster is still named and then asks the runtime about every declared node
under that node's own record, so a node replaced out of band is a conflict here
rather than something a readiness answer or an applied wall would go on to
describe.

Answering with the keys as well as the identities is deliberate: a transaction
that goes on to forget records has to forget exactly the ones it re-observed, and
deriving them a second time would be a second answer to which key a node's record
is under.
-}
ownedClusterNodes ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault [(String, RecordKey, ObjectIdentity)])
ownedClusterNodes cfg session key owned = do
    presence <- observeOwnedClusterPresence cfg owned
    case presence of
        Left fault -> pure (Left fault)
        Right ClusterAbsent -> pure (Left (clusterNoLongerNamed owned))
        Right ClusterPresent -> go (ownedClusterNodeNames owned) []
  where
    go [] gathered = pure (Right (reverse gathered))
    go (node : rest) gathered = case nodeRecordKey owned key node of
        Left failure -> pure (Left (ClusterOwnershipStore failure))
        Right nodeKey -> do
            identity <- requireOwnedNode cfg session nodeKey node (nodeNoLongerOwned node)
            case identity of
                Left fault -> pure (Left fault)
                Right bound -> go rest ((node, nodeKey, bound) : gathered)

{- | The identity one node stands under, or why this record does not own it.

Written once because three transactions ask exactly this question, and a standing
that is not 'ClusterOwned' means something different to each of them: the caller
supplies the refusal it owes and the decision itself stays one function.
-}
requireOwnedNode ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    String ->
    -- | what a standing short of clause 3 means to this caller
    ClusterOwnershipFault ->
    IO (Either ClusterOwnershipFault ObjectIdentity)
requireOwnedNode cfg session nodeKey node unowned = do
    observed <- observeOwnedNode cfg node
    case observed of
        Left fault -> pure (Left fault)
        Right origin -> do
            stored <- readRecordUnder session nodeKey
            pure $ case stored of
                Left fault -> Left fault
                Right record -> case nodeStanding record origin of
                    Left conflict -> Left (ClusterOwnershipStanding conflict)
                    Right (ClusterOwned identity) -> Right identity
                    Right _ -> Left unowned

{- | Whether every node this record owns reports itself running.

Health and readiness are different questions asked of different authorities.
Readiness asks the API server whether the cluster works; this asks the container
runtime whether the objects clause 3 bound are still up. An owned cluster whose
containers are stopped is a conflict an operator resolves rather than something
to recreate, so the answer is a value rather than a repair.
-}
ownedClusterRunning ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault Bool)
ownedClusterRunning cfg session key owned = do
    entered <- ownedClusterNodes cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right nodes -> go nodes
  where
    go [] = pure (Right True)
    go ((_, _, identity) : rest) = do
        reported <-
            classifyContainerRunState
                <$> interpret cfg (readNodeContainerRunningCommand (containerReference identity))
        case reported of
            Left fault -> pure (Left (ClusterOwnershipReport fault))
            Right ContainerNotRunning -> pure (Right False)
            Right ContainerRunning -> go rest

-- ---------------------------------------------------------------------------
-- Readiness

{- | Ask the live control plane whether this run's own cluster is ready.

Read-only, and re-entered from the durable record on __both__ sides of the probe.
The credential is the one the driver hands back for this cluster now rather than
the file the creating command wrote, because a kubeconfig on disk is a fact about
the past; it travels to the API server on standard input, so it is never in an
argument vector.

A node replaced while the probe ran is a conflict rather than a readiness. That
is not an extra comparison: the standing taken after the probe reads the same
durable records, so a runtime now naming a different container at a bound node
refuses there exactly as it would refuse anywhere else.
-}
observeOwnedClusterReadiness ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReadinessOutcome)
observeOwnedClusterReadiness cfg session key owned = do
    entered <- ownedClusterNodes cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right _ -> do
            credential <-
                classifyKubeconfig <$> interpret cfg (readKubeconfigCommand (ownedClusterName owned))
            case credential of
                Left fault -> pure (Left (ClusterOwnershipReport fault))
                Right kubeconfig -> do
                    answered <- probeReadiness cfg owned kubeconfig
                    case answered of
                        Left fault -> pure (Left fault)
                        Right outcome -> settle outcome
  where
    settle outcome = do
        after <- ownedClusterNodes cfg session key owned
        pure (fmap (const outcome) after)

{- | What the API server says, as one value.

Its own step because the two questions are ordered: a node list read from a
control plane that has not reported itself ready would be a snapshot of a cluster
still assembling itself, and 'NodesUnexpected' would then mean "not yet" rather
than "not this cluster".
-}
probeReadiness ::
    HostConfig ->
    OwnedCluster ->
    String ->
    IO (Either ClusterOwnershipFault ClusterReadinessOutcome)
probeReadiness cfg owned kubeconfig = do
    ready <- classifyApiReadiness <$> interpret cfg (readApiReadyzCommand kubeconfig)
    case ready of
        ApiNotReady -> pure (Right ClusterApiUnready)
        ApiReady -> do
            listed <-
                classifyApiNodes (ownedClusterNodeNames owned)
                    <$> interpret cfg (listApiNodesCommand kubeconfig)
            pure $ case listed of
                Left fault -> Left (ClusterOwnershipReport fault)
                Right NodesReady -> Right ClusterReady
                Right NodesNotReady -> Right ClusterNodesUnready
                Right NodesUnexpected -> Right ClusterNodesUndeclared

-- ---------------------------------------------------------------------------
-- Cordoning

{- | Apply the declared wall to every node this record owns.

Each application addresses the __container identity the durable record bound__,
never the node's name: the name is what a replacement inherits and the identity
is what it cannot, so a wall can only ever land on a container this run made.

The nodes are re-observed on both sides, because an applied wall is a mutation:
one taken against a standing nobody rechecked would cap whatever now stands at
the name, and one whose result nobody rechecked would report a wall over a
container that was replaced while it was being applied.

The wall itself is the one budget renderer's value, so what a cluster budget caps
is stated once and this driver only decides where it lands.
-}
cordonOwnedCluster ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    ResourceBudget ->
    IO (Either ClusterOwnershipFault [String])
cordonOwnedCluster cfg session key owned budget = do
    entered <- ownedClusterNodes cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right standing -> do
            applied <- applyEach standing
            case applied of
                Left fault -> pure (Left fault)
                Right () -> do
                    after <- ownedClusterNodes cfg session key owned
                    pure (fmap (const [node | (node, _, _) <- standing]) after)
  where
    limits = kindNodeCordonLimits budget

    applyEach [] = pure (Right ())
    applyEach ((_, _, identity) : rest) = do
        updated <- interpret cfg (updateNodeContainerCommand limits (containerReference identity))
        case classifyClusterReport clusterReportLineBound updated of
            Left fault -> pure (Left (ClusterOwnershipReport fault))
            Right _ -> applyEach rest

-- ---------------------------------------------------------------------------
-- Releasing

{- | Release the cluster and every record of it (clause 4).

The order is clause 4's and is the only one the tokens admit: every node is
re-observed as the identity this run bound /before/ the destructive command, the
command runs once, and a record is forgotten only over a reported absence.

A same-named replacement is left standing. Clause 4 compares the identity rather
than the name, so a container that took a node's name while the cluster was being
removed is somebody else's: it is reported, nothing is removed a second time, and
no record is forgotten over it.

Two standings short of ownership are releases rather than refusals. Nothing at
all is nothing to do, and a record published over a cluster that was never
created is forgotten without a command being issued, because there is no object
to re-observe and clause 2 is the only clause that was ever held.
-}
releaseOwnedCluster ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReleaseOutcome)
releaseOwnedCluster cfg session key owned = do
    entered <- ownedClusterStanding cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right ClusterNothingDone -> pure (Right ClusterAlreadyReleased)
        Right ClusterOriginRecorded -> forgetEveryRecord session key owned
        Right (ClusterCreatedUnbound _) -> pure (Left (releaseBeforeBinding owned))
        Right (ClusterOwned identity) -> do
            standing <- ownedClusterNodes cfg session key owned
            case standing of
                Left fault -> pure (Left fault)
                Right nodes ->
                    withBoundNode session key owned (ownedClusterControlPlane owned) identity $
                        \bound -> case reobserveReportedIdentity bound (OriginPresent identity) of
                            Left fault -> pure (Left (ClusterOwnershipClause fault))
                            Right releasable ->
                                removeOwnedCluster cfg session key owned nodes releasable

{- | Release a cluster from the claim retained in its exact durable record.

Recursive reverse interpretation no longer holds the forward action's lexical
owner input.  It does retain the protected record that clause 2/3 published, so
this entry derives the claim from those bytes and re-mints the same bound token
before conditional deletion.  A malformed or non-cluster record refuses; a
same-named replacement remains protected by the ordinary standing checks.
-}
releaseRetainedOwnedCluster ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReleaseOutcome)
releaseRetainedOwnedCluster cfg session key owned = do
    entered <- ownedClusterStanding cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right ClusterNothingDone -> pure (Right ClusterAlreadyReleased)
        Right ClusterOriginRecorded -> forgetEveryRecord session key owned
        Right (ClusterCreatedUnbound _) -> pure (Left (releaseBeforeBinding owned))
        Right (ClusterOwned identity) -> do
            retained <- retainedClaim session key
            case retained of
                Left fault -> pure (Left fault)
                Right claim -> do
                    standing <- ownedClusterNodes cfg session key owned
                    case standing of
                        Left fault -> pure (Left fault)
                        Right nodes ->
                            withBoundNodeClaim session key owned (ownedClusterControlPlane owned) claim identity $
                                \bound -> case reobserveReportedIdentity bound (OriginPresent identity) of
                                    Left fault -> pure (Left (ClusterOwnershipClause fault))
                                    Right releasable ->
                                        removeOwnedCluster cfg session key owned nodes releasable

retainedClaim ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either ClusterOwnershipFault OwnerClaim)
retainedClaim session key = do
    record <- readRecordUnder session key
    pure $ case record of
        Left fault -> Left fault
        Right Nothing -> Left (ClusterOwnershipClause (OwnershipProbeFailed "read the retained cluster claim" "the cluster ownership record is absent"))
        Right (Just held) -> case originRecordKind held of
            ReportedObject claim -> Right claim
            _ -> Left (ClusterOwnershipClause foreignRecord)

{- | Remove the cluster, then forget exactly the records whose objects are gone.

The cluster's own record is forgotten last and through the seam, because it is
the control plane's: the token that authorizes forgetting it is the one clause 4
minted from the re-observation, and the answer that releases it is the runtime's
own absence /after/ the removal rather than before it.
-}
removeOwnedCluster ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    [(String, RecordKey, ObjectIdentity)] ->
    Releasable session object ->
    IO (Either ClusterOwnershipFault ClusterReleaseOutcome)
removeOwnedCluster cfg session key owned nodes releasable = do
    removed <- interpret cfg (deleteClusterCommand (ownedClusterName owned))
    case classifyClusterReport clusterReportLineBound removed of
        Left fault -> pure (Left (ClusterOwnershipReport fault))
        Right _ -> do
            gone <- everyNodeGone cfg nodes
            case gone of
                Left fault -> pure (Left fault)
                Right False -> pure (Right ClusterStillPresent)
                Right True -> do
                    forgotten <-
                        forgetNodeRecords
                            session
                            [nodeKey | (_, nodeKey, _) <- nodes, nodeKey /= key]
                    case forgotten of
                        Left fault -> pure (Left fault)
                        Right () -> do
                            released <-
                                releaseReportedObject
                                    releasable
                                    OriginAbsent
                                    (const (forgetRecord session key))
                            pure (fmap (const ClusterReleased) (collapseFault released))

{- | Whether the runtime still names any node this record bound.

Three answers folded into two, because only one of them is a decision this
transaction may take. A node that is gone and a node still standing under the
identity this run bound are both facts about this record's own object, and the
second simply means the removal has not taken effect. A /different/ container at
the name is not this record's object at all, so it is a refusal that leaves
everything exactly as it was found.
-}
everyNodeGone ::
    HostConfig ->
    [(String, RecordKey, ObjectIdentity)] ->
    IO (Either ClusterOwnershipFault Bool)
everyNodeGone _cfg [] = pure (Right True)
everyNodeGone cfg ((node, _, identity) : rest) = do
    observed <- observeOwnedNode cfg node
    case observed of
        Left fault -> pure (Left fault)
        Right OriginAbsent -> everyNodeGone cfg rest
        Right (OriginPresent standing)
            | standing == identity -> do
                remaining <- everyNodeGone cfg rest
                pure (fmap (const False) remaining)
            | otherwise -> pure (Left (replacedUnderRelease identity standing))

-- ---------------------------------------------------------------------------
-- The refusals this module owns

nodeMovedUnderReadback :: ObjectIdentity -> ObjectIdentity -> ClusterOwnershipFault
nodeMovedUnderReadback expected observed =
    ClusterOwnershipClause
        ( OwnershipConflict
            ConflictReport
                { conflictSubject = "the container a node's name was listed under"
                , conflictExpected = OriginPresent expected
                , conflictObserved = OriginPresent observed
                }
        )

createLostItsControlPlane :: OwnedCluster -> ClusterOwnershipFault
createLostItsControlPlane owned =
    ClusterOwnershipClause
        ( OwnershipProbeFailed
            "bind the cluster's own identity"
            ( "the cluster "
                <> Text.pack (ownedClusterName owned)
                <> " declares no control-plane node to carry it"
            )
        )

clusterNoLongerNamed :: OwnedCluster -> ClusterOwnershipFault
clusterNoLongerNamed owned =
    ClusterOwnershipClause
        ( OwnershipProbeFailed
            "re-enter the owned cluster"
            ( "the driver names no cluster "
                <> Text.pack (ownedClusterName owned)
                <> ", so this record's clauses cannot be re-entered"
            )
        )

nodeNoLongerOwned :: String -> ClusterOwnershipFault
nodeNoLongerOwned node =
    ClusterOwnershipClause
        ( OwnershipProbeFailed
            "re-enter the owned cluster node"
            ( "the node "
                <> Text.pack node
                <> " is not bound to a container under this record"
            )
        )

releaseBeforeBinding :: OwnedCluster -> ClusterOwnershipFault
releaseBeforeBinding owned =
    ClusterOwnershipClause
        ( OwnershipProbeFailed
            "release the owned cluster"
            ( "the cluster "
                <> Text.pack (ownedClusterName owned)
                <> " was created and never bound, so no identity authorizes removing it"
            )
        )

{- | The refusal a container that took a node's name during the removal earns.

Clause 4 compares the identity, not the name, so an object standing where this
run's node was is somebody else's: it is reported and left exactly as it was
found, and no record is forgotten over it.
-}
replacedUnderRelease :: ObjectIdentity -> ObjectIdentity -> ClusterOwnershipFault
replacedUnderRelease expected observed =
    ClusterOwnershipStanding (NodeReplaced expected observed)

createLostItsNode :: String -> ClusterOwnershipFault
createLostItsNode node =
    ClusterOwnershipClause
        ( OwnershipProbeFailed
            "bind the cluster node identity"
            ( "the runtime reports no container named "
                <> Text.pack node
                <> " after the creation the driver accepted"
            )
        )

-- ---------------------------------------------------------------------------
-- The shared steps

{- | Hold clause 2 over one node's record and continue under its token.

The origin recorded is an absence on every branch that reaches here, and that is
a fact rather than a simplification: anything standing under no record of this
project's is refused by the standing before this point.
-}
withRecordedNode ::
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    String ->
    ( forall object.
      Recorded session object ->
      IO (Either ClusterOwnershipFault result)
    ) ->
    IO (Either ClusterOwnershipFault result)
withRecordedNode session key owned node continue = do
    withRecordedNodeClaim session key owned node (ownedClusterClaim owned) continue

withRecordedNodeClaim ::
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    String ->
    OwnerClaim ->
    ( forall object.
      Recorded session object ->
      IO (Either ClusterOwnershipFault result)
    ) ->
    IO (Either ClusterOwnershipFault result)
withRecordedNodeClaim session key _owned node claim continue = do
    outcome <-
        enterReportedObject session node OriginAbsent $ \entered -> do
            recorded <-
                recordReportedOrigin
                    entered
                    (ReportedObject claim)
                    (publishFreshRecord session key)
            traverse continue recorded
    pure (collapseClause outcome)

{- | Re-mint clause 3's token over a record that already carries the binding.

Clause 4 is reachable from a later entry, and the token it needs is the one
clause 3 minted -- which this process does not have, because the entry that bound
the identity has ended. Re-entering republishes nothing: the record already says
exactly this, so the publication is the idempotent no-op it was designed to be,
and what the re-entry produces is the evidence the release order requires.
-}
withBoundNode ::
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    String ->
    ObjectIdentity ->
    ( forall object.
      Bound session object ->
      IO (Either ClusterOwnershipFault result)
    ) ->
    IO (Either ClusterOwnershipFault result)
withBoundNode session key owned node identity continue =
    withBoundNodeClaim session key owned node (ownedClusterClaim owned) identity continue

withBoundNodeClaim ::
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    String ->
    OwnerClaim ->
    ObjectIdentity ->
    ( forall object.
      Bound session object ->
      IO (Either ClusterOwnershipFault result)
    ) ->
    IO (Either ClusterOwnershipFault result)
withBoundNodeClaim session key owned node claim identity continue =
    withRecordedNodeClaim session key owned node claim $ \recorded -> do
        bound <- bindReportedIdentity recorded identity (publishBoundRecord session key)
        case collapseFault bound of
            Left fault -> pure (Left fault)
            Right token -> continue token

{- | Forget every record this cluster published, in declared order.

Reached only from a standing where clause 2 is the last clause held: there is no
object to re-observe, so forgetting the records is the whole of the release.
-}
forgetEveryRecord ::
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReleaseOutcome)
forgetEveryRecord session key owned =
    case traverse (nodeRecordKey owned key) (ownedClusterNodeNames owned) of
        Left failure -> pure (Left (ClusterOwnershipStore failure))
        Right keys -> do
            forgotten <- forgetNodeRecords session keys
            pure (fmap (const ClusterAlreadyReleased) forgotten)

-- | Forget a list of records, stopping at the first the store refuses.
forgetNodeRecords ::
    ProtectedSession session ->
    [RecordKey] ->
    IO (Either ClusterOwnershipFault ())
forgetNodeRecords _session [] = pure (Right ())
forgetNodeRecords session (key : rest) = do
    forgotten <- forgetRecord session key
    case collapseFault forgotten of
        Left fault -> pure (Left fault)
        Right () -> forgetNodeRecords session rest

{- | Forget one durable record, whatever version the store currently holds.

A record that is already gone is not an error: the transaction's own goal is that
nothing of it remains, and a re-entry that finds the key free has reached it.
-}
forgetRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either OwnershipFault ())
forgetRecord session key = do
    current <- readProtectedRecord session key
    case current of
        Left failure -> pure (Left (storeFault "read the cluster origin record" failure))
        Right Nothing -> pure (Right ())
        Right (Just stored) -> do
            forgotten <-
                compareAndDeleteProtectedRecord
                    session
                    key
                    (ExpectVersion (protectedRecordVersion stored))
            pure
                ( either
                    (Left . storeFault "forget the cluster origin record")
                    (const (Right ()))
                    forgotten
                )

-- | Bind clause 3's identity and answer with the outcome that describes it.
bindIdentity ::
    ProtectedSession session ->
    RecordKey ->
    Recorded session object ->
    ObjectIdentity ->
    outcome ->
    IO (Either ClusterOwnershipFault outcome)
bindIdentity session key recorded identity outcome = do
    bound <- bindReportedIdentity recorded identity (publishBoundRecord session key)
    pure (fmap (const outcome) (collapseFault bound))

{- | Publish clause 2's record, or accept the one this transaction already wrote.

Idempotent on purpose. A resumed entry has to mint its token honestly: a first
attempt is the compare-and-swap from absent, and a resumed one checks that what is
already there is this transaction's own record. "This transaction's own" is the
kind and the origin, not the bytes, because a re-entry over a record a previous
entry already /bound/ finds clause 3's identity there as well — the same thing
plus one more fact this same transaction established.
-}
publishFreshRecord ::
    ProtectedSession session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
publishFreshRecord session key record = do
    existing <- readProtectedRecord session key
    case existing of
        Left failure -> pure (Left (storeFault "read the cluster origin record" failure))
        Right Nothing -> do
            written <- compareAndSwapProtectedRecord session key ExpectAbsent bytes
            pure
                ( either
                    (Left . storeFault "publish the cluster origin record")
                    (const (Right ()))
                    written
                )
        Right (Just stored)
            | protectedRecordBytes stored == bytes -> pure (Right ())
            | otherwise -> pure (extendsThisRecord record (protectedRecordBytes stored))
  where
    bytes = renderOriginRecord record

extendsThisRecord :: OriginRecord -> ByteString -> Either OwnershipFault ()
extendsThisRecord record stored = case parseOriginRecord stored of
    Left _ -> Left foreignRecord
    Right held
        | originRecordKind held == originRecordKind record
        , originRecordOrigin held == originRecordOrigin record ->
            Right ()
        | otherwise -> Left foreignRecord

{- | Publish the bound record against the exact version the store now holds.

Read back inside the same exclusive entry rather than carried out of the
publication continuation, so the store stays the one place a record version
lives.
-}
publishBoundRecord ::
    ProtectedSession session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
publishBoundRecord session key record = do
    current <- readProtectedRecord session key
    case current of
        Left failure -> pure (Left (storeFault "read the cluster origin record" failure))
        Right Nothing ->
            pure
                ( Left
                    ( OwnershipProbeFailed
                        "bind the cluster node identity"
                        "the origin record vanished inside the exclusive entry"
                    )
                )
        Right (Just stored)
            | protectedRecordBytes stored == bytes -> pure (Right ())
            | otherwise -> do
                written <-
                    compareAndSwapProtectedRecord
                        session
                        key
                        (ExpectVersion (protectedRecordVersion stored))
                        bytes
                pure
                    ( either
                        (Left . storeFault "bind the cluster node identity")
                        (const (Right ()))
                        written
                    )
  where
    bytes = renderOriginRecord record

readRecordUnder ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either ClusterOwnershipFault (Maybe OriginRecord))
readRecordUnder session key = do
    stored <- readProtectedRecord session key
    pure $ case stored of
        Left failure -> Left (ClusterOwnershipStore failure)
        Right Nothing -> Right Nothing
        Right (Just record) ->
            case parseOriginRecord (protectedRecordBytes record) of
                Left fault -> Left (ClusterOwnershipClause fault)
                Right decoded -> Right (Just decoded)

foreignRecord :: OwnershipFault
foreignRecord =
    OwnershipMalformed
        "the durable record under this key is not the one this transaction publishes"

storeFault :: Text -> ProtectedError -> OwnershipFault
storeFault operation failure = OwnershipProbeFailed operation (protectedErrorMessage failure)

interpret :: HostConfig -> HostCommand -> IO (Either String CapturedRun)
interpret = interpretHostCommand

{- | Carry the seam's own fault into this module's sum, keeping an inner refusal.

The clause producers answer in @'OwnershipFault'@ and the continuations beneath
them answer in this module's richer sum, so the two nest. Collapsing them here —
once — is what keeps every caller from writing its own.
-}
collapseClause ::
    Either OwnershipFault (Either ClusterOwnershipFault result) ->
    Either ClusterOwnershipFault result
collapseClause (Left fault) = Left (ClusterOwnershipClause fault)
collapseClause (Right inner) = inner

collapseFault :: Either OwnershipFault value -> Either ClusterOwnershipFault value
collapseFault = either (Left . ClusterOwnershipClause) Right
