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
is a total function of the expected claim and three observations
("HostBootstrap.Cluster.Resume"), and /what a clause is/ belongs to the one seam ("HostBootstrap.Ownership.Primitive"). What is
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

Origin records use the protected store's compare-and-swap. Private credential
bytes use the same canonical file sync, atomic platform rename and parent sync
primitives, before reconcile binds any node identity. An already-owned reconcile
refreshes that exact credential before continuing. Record partial-write,
partial-fsync and partial-unlink windows belong to the store's own contract — the
[ownership-clauses-and-reservations phase](../../../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md)'s.
The credential publication retains private temporary-file permissions and propagates every failed flush.
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
    clusterCommandBounds,
    interpretClusterCommand,
)
where

import Control.Exception (IOException, bracket, finally, mask, onException, try)
import Control.Monad (when)
import Crypto.Hash (Digest, SHA256, hash)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Command (
    ClusterDriver (..),
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
import HostBootstrap.Cluster.Cordon (ResourceBudget, clusterNodeBudgetShare, kindNodeCordonLimits)
import HostBootstrap.Cluster.Report (
    ApiReadiness (ApiNotReady, ApiReady),
    ClusterPresence (ClusterAbsent, ClusterPresent),
    ClusterReportFault,
    ContainerRunState (ContainerNotRunning, ContainerRunning),
    NodeReadiness (NodesNotReady, NodesReady, NodesUnexpected),
    classifyApiNodes,
    classifyApiReadiness,
    classifyClusterListing,
    classifyClusterCommandRun,
    classifyClusterReport,
    classifyContainerRunState,
    classifyKubeconfig,
    classifyNodeContainer,
    classifyNodeContainerIdentity,
    classifyClusterMutationReport,
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
    ClusterStandingConflict (NodeReplaced, ClusterUnderNoRecord),
    clusterStanding,
    clusterReleaseStanding,
    nodeReleaseStanding,
    nodeRemovalComplete,
    clusterStandingConflictMessage,
    nodeStanding,
    validateClusterOriginRecord,
    refusedCreateOriginsMayRetire,
 )
import HostBootstrap.Effect.Interpreter (resolveLaunch)
import HostBootstrap.Effect.Run (CapturedRun, RunBounds (..), RunNamespace (RunNamespace), runBoundedGroupedWithInput)
import HostBootstrap.Effect.Vocabulary (HostCommand (..), EffectTarget (ToolTarget), EffectStdio (effectStdin))
import HostBootstrap.HostTool (HostTool (Kind, Nvkind, Helm, Kubectl))
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Ownership.Clause (Bound, Recorded)
import HostBootstrap.Ownership.Object (
    ConflictReport (ConflictReport, conflictExpected, conflictObserved, conflictSubject),
    ObjectIdentity,
    OriginRecord,
    ObjectKind (ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OwnerClaim,
    OwnershipFault (
        OwnershipConflict,
        OwnershipMalformed,
        OwnershipOccupied,
        OwnershipProbeFailed
    ),
    mkOwnerClaim,
    originRecordKind,
    originRecordOrigin,
    originRecordBinding,
    ownershipFaultMessage,
 )
import HostBootstrap.Ownership.Primitive (
    bindReportedIdentity,
    enterReportedObject,
    reenterStoredReportedObject,
    recordReportedOrigin,
    resumeReportedRemoval,
    reobserveReportedIdentity,
 )
import HostBootstrap.Ownership.Tape (
    OwnershipCarrier (fromClauseFault, fromStoreFault),
    RecordSubject (RecordSubject, subjectBinding, subjectRecord),
    RecordTape,
    carryClause,
    carryClauseFault,
    forgetRecord,
    publishBoundRecord,
    publishFreshRecord,
    readRecordUnder,
    readStoredRecordUnder,
    storedOriginRecord,
    recordTape,
 )
import HostBootstrap.Protected.Publication (syncPublishedFile, renamePublishedFile, syncPublishedParent)
import HostBootstrap.Protected (
    ProtectedError,
    ProtectedSession,
    RecordKey,
    mkRecordKey,
    mkRecordSegment,
    protectedErrorMessage,
    recordKeyText,
    recordTupleSeparator,
 )
import System.Environment (getEnvironment)
import System.Directory (getCurrentDirectory, doesFileExist, getTemporaryDirectory, removeDirectory, removeFile)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (IOMode (WriteMode), hClose, hFlush, openBinaryTempFile, withBinaryFile)
import System.IO.Temp (createTempDirectory)

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
    , ownedClusterConfig :: Maybe (ByteString.ByteString, Text)
    -- ^ the prepared configuration bytes and their exact SHA-256, where declared
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
ownedClusterRecordKey owned =
    mkRecordSegment ("cluster:" <> Text.pack (ownedClusterName owned)) >>= mkRecordKey

{- | The protected-store key one node's own durable record lives under.

Prefixed by the cluster's key, so every record a cluster owns is discoverable
from the cluster's own name and a node record can never be mistaken for a
cluster's.
-}
ownedNodeRecordKey :: OwnedCluster -> String -> Either ProtectedError RecordKey
ownedNodeRecordKey owned node = do
    cluster <- ownedClusterRecordKey owned
    component <- mkRecordSegment ("node:" <> Text.pack node)
    mkRecordKey (recordKeyText cluster <> recordTupleSeparator <> component)

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
      ClusterApiUnready Text
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

Each names what stopped the transaction: the protected store, a tool's report,
the ownership standing, a clause, configuration staging, credential publication, or the resource budget.
A driver above this module maps them onto its own vocabulary through the one
renderer, so no reason is described twice.
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
    | -- | the staged configuration disagrees with its prepared digest
      ClusterOwnershipConfig Text
    | -- | the canonical budget cannot be expressed by the runtime
      ClusterOwnershipBudget Text
    deriving (Eq, Show)

-- | One rendering, so no caller writes a second description of a refusal.
clusterOwnershipFaultMessage :: ClusterOwnershipFault -> Text
clusterOwnershipFaultMessage fault = case fault of
    ClusterOwnershipStore inner -> protectedErrorMessage inner
    ClusterOwnershipReport inner -> clusterReportFaultMessage inner
    ClusterOwnershipStanding inner -> clusterStandingConflictMessage inner
    ClusterOwnershipClause inner -> ownershipFaultMessage inner
    ClusterOwnershipKubeconfig inner -> "cluster kubeconfig: " <> inner
    ClusterOwnershipConfig inner -> "cluster config: " <> inner
    ClusterOwnershipBudget inner -> "cluster budget: " <> inner

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
ownedClusterStanding cfg session key owned =
    ownedClusterStandingForClaim (ownedClusterClaim owned) cfg session key owned

ownedClusterStandingForClaim ::
    OwnerClaim ->
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterStanding)
ownedClusterStandingForClaim = ownedClusterStandingUsing clusterStanding

ownedClusterStandingUsing ::
    (OwnerClaim -> Maybe OriginRecord -> ClusterPresence -> Origin -> Either ClusterStandingConflict ClusterStanding) ->
    OwnerClaim -> HostConfig -> ProtectedSession session -> RecordKey -> OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterStanding)
ownedClusterStandingUsing decide expected cfg session key owned = do
    presence <- observeOwnedClusterPresence cfg owned
    case presence of
        Left fault -> pure (Left fault)
        Right listed -> do
            observed <- observeOwnedNode cfg (ownedClusterControlPlane owned)
            case observed of
                Left fault -> pure (Left fault)
                Right origin -> do
                    stored <- readRecordUnder (clusterTape session) key
                    pure $ case stored of
                        Left fault -> Left fault
                        Right record -> case decide expected record listed origin of
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
    ClusterDriver ->
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReconcileOutcome)
reconcileOwnedCluster driver cfg session key owned = do
    entered <- ownedClusterStanding cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right (ClusterOwned identity) -> do
            published <- publishOwnedClusterKubeconfig cfg owned
            case published of
                Left fault -> pure (Left fault)
                Right () -> requireOwnedWorkers cfg session owned identity
        Right (ClusterCreatedUnbound _) -> publishThenBind ClusterRecovered
        Right ClusterNothingDone -> publishThenCreate
        Right ClusterOriginRecorded -> publishThenCreate
  where
    publishThenCreate = do
        published <- publishEveryRecord cfg session key owned
        case published of
            Left fault -> pure (Left fault)
            Right () -> createThenBind driver cfg session key owned
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
publishEveryRecord _cfg session key owned =
    case traverse address (ownedClusterNodeNames owned) of
        Left failure -> pure (Left (ClusterOwnershipStore failure))
        Right addresses -> go addresses
  where
    address node = (,) node <$> nodeRecordKey owned key node
    go [] = pure (Right ())
    go ((node, nodeKey) : rest) = do
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
    ClusterDriver ->
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReconcileOutcome)
createThenBind driver cfg session key owned = do
    created <- runCreateCommand driver cfg owned
    case created of
        Left fault -> Left <$> settleRefusedCreate cfg session key owned fault
        Right captured -> case classifyClusterMutationReport captured of
            Left fault -> Left <$> settleRefusedCreate cfg session key owned (ClusterOwnershipReport fault)
            Right () -> do
                published <- publishOwnedClusterKubeconfig cfg owned
                case published of
                    Left fault -> pure (Left fault)
                    Right () -> do
                        bound <- bindNodeRecords cfg session key owned
                        pure (fmap ClusterCreated bound)

-- | Retire only origins whose post-refusal namespace is freshly absent.
-- Observation uncertainty preserves the origins and original fault. A failed
-- retirement reports its own durable-store fault rather than hiding it.
settleRefusedCreate ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    ClusterOwnershipFault ->
    IO ClusterOwnershipFault
settleRefusedCreate cfg session key owned original = do
    presence <- observeOwnedClusterPresence cfg owned
    controlPlane <- observeOwnedNode cfg (ownedClusterControlPlane owned)
    case (presence, controlPlane) of
        (Right listed, Right origin)
            | refusedCreateOriginsMayRetire listed origin -> do
                retired <- forgetEveryRecordForClaim (ownedClusterClaim owned) session key owned
                pure (either id (const original) retired)
        _ -> pure original

{- | Give the creating command private local configuration and credential files.

The path is selected by the host runtime rather than derived from durable state,
so a host-provider mount is never asked to implement Kind's sidecar lock. The
file is opened before its name is handed to Kind, which prevents a competing
invocation from selecting the same staging object, and cleanup runs on every
reported or exceptional exit. Prepared config bytes are written beside it and
read back for SHA-256 verification before the command receives their private path.
-}
runCreateCommand ::
    ClusterDriver ->
    HostConfig ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault (Either String CapturedRun))
runCreateCommand driver cfg owned = do
    attempted <- tryIO $ do
        temporaryRoot <- getTemporaryDirectory
        bracket
            (createTempDirectory temporaryRoot ".hostbootstrap-kind")
            removeStaging
            $ \directory -> do
                let staging = directory </> (".hostbootstrap-kind-" <> ownedClusterName owned <> ".kubeconfig")
                    configPath = directory </> "config.yaml"
                withBinaryFile staging WriteMode (const (pure ()))
                configured <- case ownedClusterConfig owned of
                    Nothing -> pure (Right Nothing)
                    Just (bytes, expectedDigest) -> do
                        ByteString.writeFile configPath bytes
                        observed <- ByteString.readFile configPath
                        let observedDigest = Text.pack (show (hash observed :: Digest SHA256))
                        pure $
                            if observedDigest == expectedDigest
                                then Right (Just configPath)
                                else Left (ClusterOwnershipConfig "the staged configuration digest disagrees with the prepared bytes")
                case configured of
                    Left fault -> pure (Left fault)
                    Right stagedConfig -> Right <$> interpret cfg (createClusterCommand driver (ownedClusterName owned) stagedConfig staging)
    pure $ case attempted of
        Left failure -> Left (kubeconfigFileFault "stage the creating command's private files" failure)
        Right result -> result
  where
    removeStaging directory = do
        let credential = directory </> (".hostbootstrap-kind-" <> ownedClusterName owned <> ".kubeconfig")
        mapM_ removeIfPresent [credential, directory </> "config.yaml"]
        removeDirectory directory
    removeIfPresent path = do
        present <- doesFileExist path
        when present (removeFile path)

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

{- | Sync complete credential bytes in a private sibling, atomically replace
the destination and establish namespace durability through the canonical platform
publication primitives. Readers observe one complete credential.
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
    restore
        ( do
            syncPublishedFile temporary
            renamePublishedFile temporary destination
            syncPublishedParent destination
        ) `onException` removeTemporary

tryIO :: IO value -> IO (Either IOException value)
tryIO = try

kubeconfigFileFault :: Text -> IOException -> ClusterOwnershipFault
kubeconfigFileFault operation failure =
    ClusterOwnershipKubeconfig (operation <> " failed: " <> Text.pack (show failure))

{- | Bind clause 3 over every node, answering with the control plane's identity.

Workers bind first and the control plane binds last as the cluster commit point.
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
bindNodeRecords cfg session key owned = go (ownedClusterWorkers owned <> [ownedClusterControlPlane owned]) Nothing
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
bindOneNode cfg session nodeKey owned node =
    fmap (fmap fst) $
        bindOneNodeForClaim (ownedClusterClaim owned) cfg session nodeKey owned node (createLostItsNode node)

-- | Resume only this exact generation's published origin; never adopt an absent record.
bindOneNodeForClaim ::
    OwnerClaim ->
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    String ->
    ClusterOwnershipFault ->
    IO (Either ClusterOwnershipFault (ObjectIdentity, Bool))
bindOneNodeForClaim expected cfg session nodeKey owned node unowned = do
    observed <- observeOwnedNode cfg node
    case observed of
        Left fault -> pure (Left fault)
        Right origin -> do
            stored <- readRecordUnder (clusterTape session) nodeKey
            case stored of
                Left fault -> pure (Left fault)
                Right record -> case nodeStanding expected record origin of
                    Left conflict -> pure (Left (ClusterOwnershipStanding conflict))
                    Right (ClusterOwned identity) -> pure (Right (identity, False))
                    Right (ClusterCreatedUnbound identity) ->
                        withRecordedNodeClaim session nodeKey owned node expected $ \recorded ->
                            bindIdentity session nodeKey recorded identity (identity, True)
                    Right ClusterNothingDone -> pure (Left unowned)
                    Right ClusterOriginRecorded -> pure (Left unowned)

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
    ObjectIdentity ->
    IO (Either ClusterOwnershipFault ClusterReconcileOutcome)
requireOwnedWorkers cfg session owned controlPlane = go False (ownedClusterWorkers owned)
  where
    go recovered [] = pure (Right (if recovered then ClusterRecovered controlPlane else ClusterAlreadyOwned controlPlane))
    go recovered (node : rest) = case ownedNodeRecordKey owned node of
        Left failure -> pure (Left (ClusterOwnershipStore failure))
        Right nodeKey -> do
            identity <- bindOneNodeForClaim (ownedClusterClaim owned) cfg session nodeKey owned node (createLostItsNode node)
            case identity of
                Left fault -> pure (Left fault)
                Right (_, boundNow) -> go (recovered || boundNow) rest

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
ownedClusterNodes cfg session key owned =
    ownedClusterNodesForClaim (ownedClusterClaim owned) cfg session key owned

ownedClusterNodesForClaim ::
    OwnerClaim ->
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault [(String, RecordKey, ObjectIdentity)])
ownedClusterNodesForClaim expected cfg session key owned = do
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
            identity <-
                if node == ownedClusterControlPlane owned
                    then requireOwnedNode expected cfg session nodeKey node (nodeNoLongerOwned node)
                    else fmap (fmap fst) (bindOneNodeForClaim expected cfg session nodeKey owned node (nodeNoLongerOwned node))
            case identity of
                Left fault -> pure (Left fault)
                Right bound -> go rest ((node, nodeKey, bound) : gathered)

{- | The identity one node stands under, or why this record does not own it.

Written once because three transactions ask exactly this question, and a standing
that is not 'ClusterOwned' means something different to each of them: the caller
supplies the refusal it owes and the decision itself stays one function.
-}
requireOwnedNode ::
    OwnerClaim ->
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    String ->
    -- | what a standing short of clause 3 means to this caller
    ClusterOwnershipFault ->
    IO (Either ClusterOwnershipFault ObjectIdentity)
requireOwnedNode expected cfg session nodeKey node unowned = do
    observed <- observeOwnedNode cfg node
    case observed of
        Left fault -> pure (Left fault)
        Right origin -> do
            stored <- readRecordUnder (clusterTape session) nodeKey
            pure $ case stored of
                Left fault -> Left fault
                Right record -> case nodeStanding expected record origin of
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
    IO (Either ClusterOwnershipFault (ObjectIdentity, ClusterReadinessOutcome))
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
        pure $ do
            nodes <- after
            case [identity | (node, _, identity) <- nodes, node == ownedClusterControlPlane owned] of
                [identity] -> Right (identity, outcome)
                _ -> Left (nodeNoLongerOwned (ownedClusterControlPlane owned))

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
        Left fault -> pure (Left (ClusterOwnershipReport fault))
        Right (ApiNotReady diagnostic) -> pure (Right (ClusterApiUnready diagnostic))
        Right ApiReady -> do
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

The one cluster envelope is divided by its declared node count using the shared
budget calculation. Each node receives the renderer's limits for that share,
so the aggregate cap stays within the envelope.
-}
cordonOwnedCluster ::
    HostConfig ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    ResourceBudget ->
    IO (Either ClusterOwnershipFault [String])
cordonOwnedCluster cfg session key owned budget =
    case clusterNodeBudgetShare (length (ownedClusterNodeNames owned)) budget >>= kindNodeCordonLimits of
        Left refusal -> pure (Left (ClusterOwnershipBudget (Text.pack refusal)))
        Right limits -> do
            entered <- ownedClusterNodes cfg session key owned
            case entered of
                Left fault -> pure (Left fault)
                Right standing -> do
                    applied <- applyEach limits standing
                    case applied of
                        Left fault -> pure (Left fault)
                        Right () -> do
                            after <- ownedClusterNodes cfg session key owned
                            pure (fmap (const [node | (node, _, _) <- standing]) after)
  where
    applyEach _limits [] = pure (Right ())
    applyEach limits ((_, _, identity) : rest) = do
        updated <- interpret cfg (updateNodeContainerCommand limits (containerReference identity))
        case classifyClusterReport clusterReportLineBound updated of
            Left fault -> pure (Left (ClusterOwnershipReport fault))
            Right _ -> applyEach limits rest

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
releaseOwnedCluster cfg session key owned =
    releaseClusterForClaim (ownedClusterClaim owned) cfg session key owned

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
    retained <- retainedClaim session key
    case retained of
        Left fault -> pure (Left fault)
        Right held -> releaseWithClaim (maybe (ownedClusterClaim owned) id held)
  where
    releaseWithClaim claim = releaseClusterForClaim claim cfg session key owned

-- | Forward and retained release share every observation and conditional act.
releaseClusterForClaim ::
    OwnerClaim -> HostConfig -> ProtectedSession session -> RecordKey -> OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReleaseOutcome)
releaseClusterForClaim claim cfg session key owned = do
    entered <- ownedClusterStandingUsing clusterReleaseStanding claim cfg session key owned
    case entered of
        Left fault -> pure (Left fault)
        Right ClusterNothingDone -> releaseUnboundOrigins claim cfg session key owned
        Right ClusterOriginRecorded -> releaseUnboundOrigins claim cfg session key owned
        Right (ClusterCreatedUnbound _) -> pure (Left (releaseBeforeBinding owned))
        Right (ClusterOwned identity) -> do
            standing <- releaseClusterNodes claim cfg session key owned
            case standing of
                Left fault -> pure (Left fault)
                Right nodes ->
                    withBoundNodeClaim session key (ownedClusterControlPlane owned) claim identity $
                        \bound -> removeOwnedCluster claim cfg session key owned nodes bound

-- | Read every node under the held claim, including absent bound nodes.
-- A worker left unbound by interrupted creation uses ordinary identity binding.
releaseClusterNodes ::
    OwnerClaim -> HostConfig -> ProtectedSession session -> RecordKey -> OwnedCluster ->
    IO (Either ClusterOwnershipFault [(String, RecordKey, Maybe ObjectIdentity)])
releaseClusterNodes claim cfg session key owned = go (ownedClusterNodeNames owned) []
  where
    go [] held = pure (Right (reverse held))
    go (node : rest) held = case nodeRecordKey owned key node of
        Left fault -> pure (Left (ClusterOwnershipStore fault))
        Right nodeKey -> do
            observed <- observeOwnedNode cfg node
            stored <- readRecordUnder (clusterTape session) nodeKey
            case (observed, stored) of
                (Left fault, _) -> pure (Left fault)
                (_, Left fault) -> pure (Left fault)
                (Right origin, Right record) -> case nodeReleaseStanding claim record origin of
                    Left conflict -> pure (Left (ClusterOwnershipStanding conflict))
                    Right (ClusterOwned identity) -> go rest ((node, nodeKey, Just identity) : held)
                    Right (ClusterCreatedUnbound _) -> do
                        bound <- bindOneNodeForClaim claim cfg session nodeKey owned node (nodeNoLongerOwned node)
                        case bound of
                            Left fault -> pure (Left fault)
                            Right (identity, _) -> go rest ((node, nodeKey, Just identity) : held)
                    Right _ -> go rest ((node, nodeKey, Nothing) : held)

-- | Unbound and orphan origins retire only after every declared node is absent.
releaseUnboundOrigins ::
    OwnerClaim -> HostConfig -> ProtectedSession session -> RecordKey -> OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReleaseOutcome)
releaseUnboundOrigins claim cfg session key owned = absent (ownedClusterNodeNames owned)
  where
    absent [] = forgetEveryRecordForClaim claim session key owned
    absent (node : rest) = do
        observed <- observeOwnedNode cfg node
        case observed of
            Left fault -> pure (Left fault)
            Right OriginAbsent -> absent rest
            Right (OriginPresent _) -> pure (Left (ClusterOwnershipStanding ClusterUnderNoRecord))

retainedClaim ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either ClusterOwnershipFault (Maybe OwnerClaim))
retainedClaim session key = do
    record <- readRecordUnder (clusterTape session) key
    pure $ case record of
        Left fault -> Left fault
        Right Nothing -> Right Nothing
        Right (Just held) -> case originRecordKind held of
            ReportedObject claim -> Right (Just claim)
            -- A record of another kind is not this owner's: only a reported
            -- object carries the claim a retained cluster is released against.
            _ ->
                Left
                    ( ClusterOwnershipClause
                        ( OwnershipMalformed
                            "the retained cluster ownership record carries no owner claim"
                        )
                    )

{- | Remove the cluster, then forget exactly the records whose objects are gone.

The cluster's own record is forgotten last and through the seam, because it is
the control plane's: the token that authorizes forgetting it is the one clause 4
minted from the re-observation, and the answer that releases it is the runtime's
own absence /after/ the removal rather than before it.
-}
removeOwnedCluster ::
    OwnerClaim -> HostConfig -> ProtectedSession session -> RecordKey -> OwnedCluster ->
    [(String, RecordKey, Maybe ObjectIdentity)] -> Bound session object ->
    IO (Either ClusterOwnershipFault ClusterReleaseOutcome)
removeOwnedCluster claim cfg session key owned nodes bound = do
    removed <- removeRemaining nodes
    case removed of
        Left fault -> pure (Left fault)
        Right () -> do
            gone <- everyNodeGone cfg nodes
            case gone of
                Left fault -> pure (Left fault)
                Right False -> pure (Right ClusterStillPresent)
                Right True -> finishOwnedRelease session key nodes bound
  where
    -- A surviving bound node supplies the actual clause-4 re-observation.
    -- An all-absent cluster needs only durable record cleanup, not another delete.
    removeRemaining [] = pure (Right ())
    removeRemaining ((node, nodeKey, expected) : rest) = do
        observed <- observeOwnedNode cfg node
        case observed of
            Left fault -> pure (Left fault)
            Right OriginAbsent -> removeRemaining rest
            Right origin@(OriginPresent standing) -> case expected of
                Nothing -> pure (Left (ClusterOwnershipStanding ClusterUnderNoRecord))
                Just identity | standing /= identity -> pure (Left (replacedUnderRelease identity standing))
                Just identity ->
                    withBoundNodeClaim session nodeKey node claim identity $ \witness ->
                        case reobserveReportedIdentity witness origin of
                            Left fault -> pure (Left (ClusterOwnershipClause fault))
                            Right _ -> do
                                report <- interpret cfg (deleteClusterCommand (ownedClusterName owned))
                                pure $ case classifyClusterMutationReport report of
                                    Left fault -> Left (ClusterOwnershipReport fault)
                                    Right _ -> Right ()

-- | Retire worker records first so partial cleanup retains the root binding.
finishOwnedRelease ::
    ProtectedSession session -> RecordKey -> [(String, RecordKey, Maybe ObjectIdentity)] ->
    Bound session object -> IO (Either ClusterOwnershipFault ClusterReleaseOutcome)
finishOwnedRelease session key nodes bound = do
    forgotten <- forgetNodeRecords session [nodeKey | (_, nodeKey, _) <- nodes, nodeKey /= key]
    case forgotten of
        Left fault -> pure (Left fault)
        Right () -> do
            released <- resumeReportedRemoval bound OriginAbsent
                (const (forgetRecord (clusterTape session) key))
            pure (fmap (const ClusterReleased) (carryClauseFault released))

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
    [(String, RecordKey, Maybe ObjectIdentity)] ->
    IO (Either ClusterOwnershipFault Bool)
everyNodeGone _cfg [] = pure (Right True)
everyNodeGone cfg ((node, _, expected) : rest) = do
    observed <- observeOwnedNode cfg node
    case observed of
        Left fault -> pure (Left fault)
        Right origin -> case nodeRemovalComplete expected origin of
            Left conflict -> pure (Left (ClusterOwnershipStanding conflict))
            Right removed -> do
                remaining <- everyNodeGone cfg rest
                pure (fmap (removed &&) remaining)
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
                    claim
                    (publishFreshRecord (clusterTape session) key)
            traverse continue recorded
    pure (carryClause outcome)

{- | Re-mint clause 3's token over a record that already carries the binding.

Read the bound record back inside the held entry and require this node's exact
claim, absent origin and identity. Reported re-entry projects that existing
record into clause 3's token without replaying publication or changing its
version. The caller never adopts a different claim or binding.
-}
withBoundNodeClaim ::
    ProtectedSession session ->
    RecordKey ->
    String ->
    OwnerClaim ->
    ObjectIdentity ->
    ( forall object.
      Bound session object ->
      IO (Either ClusterOwnershipFault result)
    ) ->
    IO (Either ClusterOwnershipFault result)
withBoundNodeClaim session key node claim identity continue = do
    stored <- readStoredRecordUnder (clusterTape session) key
    case stored of
        Left fault -> pure (Left fault)
        Right Nothing ->
            pure
                (Left (ClusterOwnershipClause
                    (OwnershipProbeFailed "re-enter the cluster origin record"
                        "the origin record vanished inside the exclusive entry")))
        Right (Just held)
            | originRecordKind (storedOriginRecord held) == ReportedObject claim
            , originRecordOrigin (storedOriginRecord held) == OriginAbsent
            , originRecordBinding (storedOriginRecord held) == Just identity -> do
                outcome <-
                    reenterStoredReportedObject session node held
                        (\token -> Right <$> continue token)
                pure (carryClause outcome)
            | otherwise ->
                pure
                    (Left (ClusterOwnershipClause
                        (OwnershipOccupied
                            "the stored cluster origin record does not match this node claim and bound identity")))

{- | Forget every record this cluster published, workers before the root.

Reached only from a standing where clause 2 is the last clause held: there is no
object to re-observe, so forgetting the records is the whole of the release.
-}
forgetEveryRecordForClaim ::
    OwnerClaim ->
    ProtectedSession session ->
    RecordKey ->
    OwnedCluster ->
    IO (Either ClusterOwnershipFault ClusterReleaseOutcome)
forgetEveryRecordForClaim expected session key owned =
    case traverse (nodeRecordKey owned key) (ownedClusterWorkers owned <> [ownedClusterControlPlane owned]) of
        Left failure -> pure (Left (ClusterOwnershipStore failure))
        Right keys -> do
            checked <- checkClaims keys
            case checked of
                Left fault -> pure (Left fault)
                Right () -> do
                    forgotten <- forgetNodeRecords session keys
                    pure (fmap (const ClusterAlreadyReleased) forgotten)
  where
    checkClaims [] = pure (Right ())
    checkClaims (recordKey : rest) = do
        stored <- readRecordUnder (clusterTape session) recordKey
        case stored of
            Left fault -> pure (Left fault)
            Right Nothing -> checkClaims rest
            Right (Just record) -> case validateClusterOriginRecord expected record of
                Left conflict -> pure (Left (ClusterOwnershipStanding conflict))
                Right () -> checkClaims rest

-- | Forget a list of records, stopping at the first the store refuses.
forgetNodeRecords ::
    ProtectedSession session ->
    [RecordKey] ->
    IO (Either ClusterOwnershipFault ())
forgetNodeRecords _session [] = pure (Right ())
forgetNodeRecords session (key : rest) = do
    forgotten <- forgetRecord (clusterTape session) key
    case carryClauseFault forgotten of
        Left fault -> pure (Left fault)
        Right () -> forgetNodeRecords session rest

{- | Forget one durable record, whatever version the store currently holds.

A record that is already gone is not an error: the transaction's own goal is that
nothing of it remains, and a re-entry that finds the key free has reached it.
-}

-- | Bind clause 3's identity and answer with the outcome that describes it.
bindIdentity ::
    ProtectedSession session ->
    RecordKey ->
    Recorded session object ->
    ObjectIdentity ->
    outcome ->
    IO (Either ClusterOwnershipFault outcome)
bindIdentity session key recorded identity outcome = do
    bound <- bindReportedIdentity recorded identity (publishBoundRecord (clusterTape session) key)
    pure (fmap (const outcome) (carryClauseFault bound))

{- | What this owner calls its records, for the tape's refusals.

The only thing the cluster supplies to the shared store adapter; publishing,
binding, forgetting and reading a record back is the same act every owner behind
the seam performs.
-}
clusterSubject :: RecordSubject
clusterSubject =
    RecordSubject
        { subjectRecord = "the cluster origin record"
        , subjectBinding = "bind the cluster node identity"
        }

clusterTape :: ProtectedSession session -> RecordTape session
clusterTape session = recordTape session clusterSubject

instance OwnershipCarrier ClusterOwnershipFault where
    fromClauseFault = ClusterOwnershipClause
    fromStoreFault = ClusterOwnershipStore

-- | Finite command policy, including waits rendered by the owned vocabulary.
clusterCommandBounds :: HostCommand -> RunBounds
clusterCommandBounds command = RunBounds
    { boundWallMicros = seconds * 1000000
    , boundOutputBytes = 4 * 1024 * 1024
    , boundTerminationGraceMicros = 2000000
    }
  where
    arguments = commandArguments command
    seconds = case (commandTarget command, dropWhile (== "--quiet") arguments) of
        (ToolTarget Kind, "create" : "cluster" : _) -> 660
        (ToolTarget Nvkind, "cluster" : "create" : _) -> 660
        (ToolTarget Helm, _) -> 600
        (ToolTarget Kubectl, _) | "--timeout=5m" `elem` arguments -> 360
        _ -> 60

-- | Resolve once and retain the described stdin through the shared grouped runner.
interpretClusterCommand :: HostConfig -> HostCommand -> IO (Either String CapturedRun)
interpretClusterCommand cfg command = case resolveLaunch cfg command of
    Left refusal -> pure (Left refusal)
    Right (executable, arguments) -> do
        namespace <- try ((,) <$> getCurrentDirectory <*> getEnvironment) :: IO (Either IOException (FilePath, [(String, String)]))
        case namespace of
            Left fault -> pure (Left ("cannot resolve cluster run namespace: " <> show fault))
            Right (directory, environment) -> do
                outcome <- runBoundedGroupedWithInput (clusterCommandBounds command) (RunNamespace directory environment)
                    executable arguments (TextEncoding.encodeUtf8 (Text.pack (effectStdin (commandStdio command))))
                pure (classifyClusterCommandRun outcome)

interpret :: HostConfig -> HostCommand -> IO (Either String CapturedRun)
interpret = interpretClusterCommand
