{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The IO backend that produces cluster observations while holding the four
Locked-Origin Identity Ownership clauses, plus the loopback-bound exposure
operation the cluster's published ports must consume.

This is the cluster peer of "HostBootstrap.Substrate.Provider.Alias": the
classification and receipt gating live in "HostBootstrap.Cluster.Reconcile", and
this module supplies only the effects that feed it.  The command runner is
injected as a 'ClusterExec', so the same protocol runs against a real
filesystem and a real driver binary under test.

Clause realization (see
@documents/architecture/ownership_invariant.md@):

* clause 1 — @flock -x@ on a lock file beside the cluster's state directory,
  held across the whole observe/create/settle bracket and released by the kernel
  if the holder dies;
* clause 2 — a durable origin record written before the first mutation, naming
  the exact prior state (absent, or a present cluster's identity);
* clause 3 — identity is the control-plane node container's immutable ID, not
  the cluster name.  A cluster deleted and recreated out of band therefore
  presents a different identity;
* clause 4 — deletion re-observes that identity under the same lock and refuses
  a replacement, leaving it intact.

A host that lacks a required tool is 'Unsupported' and mints no receipt.
-}
module HostBootstrap.Cluster.Backend (
    -- * The cluster the backend owns
    ClusterSpec,
    mkClusterSpec,
    clusterSpecName,
    clusterSpecStateDirectory,
    clusterSpecConfigPath,

    -- * The injected command runner
    ClusterExec (..),
    ClusterCommandResult (..),

    -- * The clause-holding backend
    StrongClusterBackend,
    discoverStrongClusterBackend,
    runClusterReconcileCall,
    runClusterCleanupCall,

    -- * Loopback-bound exposure
    LoopbackExposure,
    mkLoopbackExposure,
    loopbackExposureListenAddress,
    loopbackExposureHostPort,
    loopbackExposureNodePort,
    PreparedLoopbackExposure,
    withPreparedLoopbackExposure,
    preparedLoopbackExposureMapping,
    ObservedPortBinding (..),
    settleLoopbackExposure,
)
where

import Data.Bits (xor)
import Data.Char (isDigit)
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Cluster.Reconcile (
    ClusterCleanupObservation (..),
    ClusterObservation (..),
    PreparedClusterCleanup,
    PreparedClusterReconcile,
    preparedClusterCleanupHandle,
    preparedClusterReconcileHandle,
 )
import HostBootstrap.Reconcile (
    ClusterResource,
    ConflictDetail (..),
    FailureDetail (..),
    PlannedResource,
    ReconcileError (..),
    RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry),
    UnsupportedDetail (..),
    plannedResourceKey,
    resourceHandleGeneration,
    resourceHandleKey,
 )

-- The cluster the backend owns -----------------------------------------------

{- | The exact cluster this backend may act on: its driver-visible name, the
directory that holds its lock and origin record, and the driver config the
create call consumes. No caller-supplied identity beyond these reaches the
backend.
-}
data ClusterSpec = ClusterSpec FilePath FilePath FilePath
    deriving (Eq, Show)

mkClusterSpec ::
    -- | cluster name
    String ->
    -- | absolute state directory holding the lock and origin record
    FilePath ->
    -- | absolute driver config path
    FilePath ->
    Either ReconcileError ClusterSpec
mkClusterSpec name stateDirectory configPath
    | null name = invalid "cluster name must not be empty"
    | any (`elem` (" \t\n'\"" :: String)) name =
        invalid "cluster name must not contain whitespace or quotes"
    | not (absolutePath stateDirectory) =
        invalid "cluster state directory must be an absolute path"
    | not (absolutePath configPath) =
        invalid "cluster driver config must be an absolute path"
    | '\0' `elem` name || '\0' `elem` stateDirectory || '\0' `elem` configPath =
        invalid "cluster identifiers must not contain NUL"
    | otherwise = Right (ClusterSpec name stateDirectory configPath)
  where
    invalid reason =
        Left (Failure (FailureDetail "validate cluster spec" reason DoNotRetry))

absolutePath :: FilePath -> Bool
absolutePath ('/' : _) = True
absolutePath _ = False

clusterSpecName :: ClusterSpec -> String
clusterSpecName (ClusterSpec name _ _) = name

clusterSpecStateDirectory :: ClusterSpec -> FilePath
clusterSpecStateDirectory (ClusterSpec _ stateDirectory _) = stateDirectory

clusterSpecConfigPath :: ClusterSpec -> FilePath
clusterSpecConfigPath (ClusterSpec _ _ configPath) = configPath

-- The injected command runner ------------------------------------------------

{- | How the backend reaches the host. Production supplies the resolved absolute
tool (§ K); a test supplies a local runner over a fake driver, so the clauses
run against a real filesystem.
-}
newtype ClusterExec = ClusterExec
    {runClusterCommand :: [String] -> IO ClusterCommandResult}

data ClusterCommandResult = ClusterCommandResult
    { clusterCommandOk :: Bool
    , clusterCommandStdout :: String
    , clusterCommandStderr :: String
    }
    deriving (Eq, Show)

{- | Capability for a backend that holds the four clauses for a cluster. Its
constructor is private: only 'discoverStrongClusterBackend' mints it, and only
after verifying the host exposes the ownership tools plus the driver.
-}
data StrongClusterBackend = StrongClusterBackend ClusterExec FilePath FilePath

{- | Probe for @flock@, @sh@, @grep@, the cluster driver, and the container
runtime that reports node identity. A host missing one is 'Unsupported' and
mints no capability, so the caller cannot mistake "cannot own" for "owned".
-}
discoverStrongClusterBackend ::
    ClusterExec ->
    -- | absolute cluster-driver executable (@kind@ / @nvkind@)
    FilePath ->
    -- | absolute container-runtime executable used for node identity
    FilePath ->
    IO (Either ReconcileError StrongClusterBackend)
discoverStrongClusterBackend exec driver runtime
    | not (absolutePath driver) || not (absolutePath runtime) =
        pure
            ( Left
                ( Failure
                    ( FailureDetail
                        "discover cluster ownership backend"
                        "the cluster driver and container runtime must be resolved absolute paths"
                        DoNotRetry
                    )
                )
            )
    | otherwise = do
        result <- runClusterCommand exec ["sh", "-c", ownershipToolProbe driver runtime]
        pure $
            if clusterCommandOk result
                then Right (StrongClusterBackend exec driver runtime)
                else
                    Left
                        ( Unsupported
                            ( UnsupportedDetail
                                "reconcile cluster"
                                "the host lacks a cluster ownership tool (flock, grep, the cluster driver, or the container runtime)"
                            )
                        )

{- | A single compound probe with no nested command substitution, so it survives
the same quoting paths the guest-alias probe does.
-}
ownershipToolProbe :: FilePath -> FilePath -> String
ownershipToolProbe driver runtime =
    intercalate
        " && "
        ( [ "command -v " <> tool <> " >/dev/null 2>&1"
          | tool <- ["flock", "grep"]
          ]
            <> ["test -x " <> quoteShell driver, "test -x " <> quoteShell runtime]
        )

-- The clause-holding reconcile/cleanup calls ---------------------------------

{- | Observe the cluster under an exclusive @flock@ and, when it is absent,
create it. The reported change echoes the plan-assigned generation the prepared
operation must confirm; the control-plane node container's immutable ID is the
clause-3 binding and is journalled in the origin record (clause 2) so
conditional deletion can compare against it (clause 4).
-}
runClusterReconcileCall ::
    StrongClusterBackend ->
    ClusterSpec ->
    PreparedClusterReconcile scope planId clusterId operationKey callDigest attempt journalVersion ->
    IO ClusterObservation
runClusterReconcileCall
    (StrongClusterBackend exec driver runtime)
    spec
    prepared = do
        result <-
            runClusterCommand
                exec
                (flockWrapped spec driver runtime clusterReconcileScript)
        pure
            ( parseReconcileReport
                (resourceHandleGeneration (preparedClusterReconcileHandle prepared))
                result
            )

{- | Delete the cluster under the same exclusive lock, but only while its
control-plane identity still matches the one the origin record bound. A
replacement is reported as such and left intact.
-}
runClusterCleanupCall ::
    StrongClusterBackend ->
    ClusterSpec ->
    PreparedClusterCleanup scope planId clusterId phase ->
    IO (Either ReconcileError ClusterCleanupObservation)
runClusterCleanupCall
    (StrongClusterBackend exec driver runtime)
    spec
    prepared = do
        result <-
            runClusterCommand
                exec
                (flockWrapped spec driver runtime clusterCleanupScript)
        pure
            ( parseCleanupReport
                (resourceHandleKey (preparedClusterCleanupHandle prepared))
                result
            )

{- | Wrap a script in @flock -x \<lock\> sh -c \<script\> _ name record driver
runtime config@ so the exclusive lock spans the whole bracket (clause 1). The
lock file sits in the cluster's state directory and is auto-created by @flock@.
-}
flockWrapped :: ClusterSpec -> FilePath -> FilePath -> String -> [String]
flockWrapped spec driver runtime script =
    [ "flock"
    , "-x"
    , clusterLockPath spec
    , "sh"
    , "-c"
    , script
    , "hb-cluster"
    , clusterSpecName spec
    , clusterRecordPath spec
    , driver
    , runtime
    , clusterSpecConfigPath spec
    ]

clusterLockPath :: ClusterSpec -> FilePath
clusterLockPath spec =
    clusterSpecStateDirectory spec <> "/" <> clusterSpecName spec <> ".cluster.lock"

clusterRecordPath :: ClusterSpec -> FilePath
clusterRecordPath spec =
    clusterSpecStateDirectory spec <> "/" <> clusterSpecName spec <> ".cluster.origin"

{- | Positional args: @$1@ name, @$2@ record, @$3@ driver, @$4@ runtime,
@$5@ config.

The control-plane container ID is the identity: it is assigned by the runtime,
never reused, and changes when the cluster is recreated — so a same-named
cluster someone else rebuilt cannot pass as ours.
-}
clusterReconcileScript :: String
clusterReconcileScript =
    unlines
        [ "name=\"$1\"; rec=\"$2\"; driver=\"$3\"; runtime=\"$4\"; config=\"$5\""
        , "node=\"$name-control-plane\""
        , -- clause 2: record the exact origin before the first mutation.
          "if [ ! -e \"$rec\" ]; then"
        , "  if \"$driver\" get clusters 2>/dev/null | grep -qx \"$name\"; then"
        , "    printf 'origin present %s\\n' \"$(\"$runtime\" inspect -f '{{.Id}}' \"$node\" 2>/dev/null)\" > \"$rec\""
        , "  else"
        , "    printf 'origin absent\\n' > \"$rec\""
        , "  fi"
        , "fi"
        , -- observe (clause 3: bind to the node container ID, never the name).
          "if \"$driver\" get clusters 2>/dev/null | grep -qx \"$name\"; then"
        , "  id=$(\"$runtime\" inspect -f '{{.Id}}' \"$node\" 2>/dev/null)"
        , "  if [ -z \"$id\" ]; then printf 'UNHEALTHY missing-control-plane\\n'; exit 0; fi"
        , "  state=$(\"$runtime\" inspect -f '{{.State.Running}}' \"$node\" 2>/dev/null)"
        , "  if [ \"$state\" = true ]; then printf 'HEALTHY %s\\n' \"$id\""
        , "  else printf 'UNHEALTHY %s\\n' \"$id\"; fi"
        , "elif \"$driver\" create cluster --name \"$name\" --config \"$config\" >/dev/null 2>&1; then"
        , "  id=$(\"$runtime\" inspect -f '{{.Id}}' \"$node\" 2>/dev/null)"
        , "  if [ -z \"$id\" ]; then printf 'PROBEFAILED created-without-control-plane\\n'; exit 0; fi"
        , "  printf 'managed %s\\n' \"$id\" >> \"$rec\""
        , "  printf 'CREATED %s\\n' \"$id\""
        , "else"
        , "  printf 'PROBEFAILED create-failed\\n'"
        , "fi"
        ]

{- | Positional args as above. Deletion is conditional on the identity recorded
when the cluster was created; a different control-plane ID is reported as a
replacement and nothing is deleted.
-}
clusterCleanupScript :: String
clusterCleanupScript =
    unlines
        [ "name=\"$1\"; rec=\"$2\"; driver=\"$3\"; runtime=\"$4\""
        , "node=\"$name-control-plane\""
        , "managed=''"
        , "if [ -f \"$rec\" ]; then managed=$(grep '^managed ' \"$rec\" | tail -n 1 | cut -d' ' -f2); fi"
        , "if ! \"$driver\" get clusters 2>/dev/null | grep -qx \"$name\"; then"
        , "  rm -f \"$rec\"; printf 'REMOVED\\n'; exit 0"
        , "fi"
        , "cur=$(\"$runtime\" inspect -f '{{.Id}}' \"$node\" 2>/dev/null)"
        , "if [ -n \"$managed\" ] && [ \"$cur\" = \"$managed\" ]; then"
        , "  if \"$driver\" delete cluster --name \"$name\" >/dev/null 2>&1; then"
        , "    rm -f \"$rec\"; printf 'REMOVED\\n'"
        , "  else printf 'DELETEFAILED\\n'; fi"
        , "else"
        , "  printf 'REPLACED %s\\n' \"$cur\""
        , "fi"
        ]

parseReconcileReport :: Word64 -> ClusterCommandResult -> ClusterObservation
parseReconcileReport generation result
    | not (clusterCommandOk result) =
        ClusterProbeFailed
            ( "the exclusive-entry cluster command failed: "
                <> firstLineText (clusterCommandStderr result)
            )
    | otherwise = case words (firstLine (clusterCommandStdout result)) of
        ("CREATED" : _) -> ClusterCreated generation
        ("HEALTHY" : identity : _) -> ClusterHealthy (identityGeneration identity)
        ("UNHEALTHY" : identity : _) -> ClusterUnhealthy (identityGeneration identity)
        ("PROBEFAILED" : rest) ->
            ClusterProbeFailed
                ( "the cluster driver could not produce an owned cluster: "
                    <> Text.pack (unwords rest)
                )
        _ ->
            ClusterProbeFailed
                ( "unparseable backend report: "
                    <> firstLineText (clusterCommandStdout result)
                )

parseCleanupReport ::
    Text ->
    ClusterCommandResult ->
    Either ReconcileError ClusterCleanupObservation
parseCleanupReport key result
    | not (clusterCommandOk result) =
        Left
            ( Failure
                ( FailureDetail
                    "clean up cluster"
                    ( "the exclusive-entry cluster command failed: "
                        <> firstLineText (clusterCommandStderr result)
                    )
                    ReprobeBeforeRetry
                )
            )
    | otherwise = case words (firstLine (clusterCommandStdout result)) of
        ("REMOVED" : _) -> Right ClusterCleanupRemoved
        ("REPLACED" : identity : _) ->
            Right (ClusterCleanupReplaced (identityGeneration identity))
        ("REPLACED" : _) -> Right (ClusterCleanupReplaced 1)
        ("DELETEFAILED" : _) ->
            Left
                ( Failure
                    ( FailureDetail
                        "clean up cluster"
                        ("the cluster driver refused to delete " <> key)
                        ReprobeBeforeRetry
                    )
                )
        _ ->
            Left
                ( Failure
                    ( FailureDetail
                        "clean up cluster"
                        ( "unparseable backend report: "
                            <> firstLineText (clusterCommandStdout result)
                        )
                        DoNotRetry
                    )
                )

{- | Fold a container ID to a strictly positive generation, so an observed
identity can be compared against the plan-assigned one.
-}
identityGeneration :: String -> Word64
identityGeneration = max 1 . foldl step 1469598103934665603
  where
    step acc c = (acc `xor` fromIntegral (fromEnum c)) * 1099511628211

firstLine :: String -> String
firstLine value = case lines value of
    (l : _) -> l
    [] -> ""

firstLineText :: String -> Text
firstLineText = Text.pack . firstLine

quoteShell :: String -> String
quoteShell value = "'" <> concatMap escape value <> "'"
  where
    escape '\'' = "'\\''"
    escape c = [c]

-- Loopback-bound exposure -----------------------------------------------------

{- | A published cluster port. There is deliberately no way to supply a listen
address: the mapping is always loopback, so a wildcard exposure of a
project-local service is unrepresentable rather than merely discouraged.
-}
data LoopbackExposure = LoopbackExposure Int Int
    deriving (Eq, Show)

mkLoopbackExposure ::
    -- | host port
    Int ->
    -- | node port inside the cluster
    Int ->
    Either ReconcileError LoopbackExposure
mkLoopbackExposure hostPort nodePort
    | not (validPort hostPort) =
        invalid ("host port out of range: " <> Text.pack (show hostPort))
    | not (validPort nodePort) =
        invalid ("node port out of range: " <> Text.pack (show nodePort))
    | otherwise = Right (LoopbackExposure hostPort nodePort)
  where
    validPort port = port > 0 && port < 65536
    invalid reason =
        Left (Failure (FailureDetail "validate cluster exposure" reason DoNotRetry))

-- | Always @127.0.0.1@. This is the whole point of the type.
loopbackExposureListenAddress :: LoopbackExposure -> String
loopbackExposureListenAddress _ = "127.0.0.1"

loopbackExposureHostPort :: LoopbackExposure -> Int
loopbackExposureHostPort (LoopbackExposure hostPort _) = hostPort

loopbackExposureNodePort :: LoopbackExposure -> Int
loopbackExposureNodePort (LoopbackExposure _ nodePort) = nodePort

{- | An exposure bound to one planned cluster resource. The renderer that emits
the driver's port mapping consumes this, so it cannot publish a port for a
cluster that is not in the plan.
-}
data PreparedLoopbackExposure scope planId clusterId clusterFrame
    = PreparedLoopbackExposure Text LoopbackExposure

withPreparedLoopbackExposure ::
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    LoopbackExposure ->
    (PreparedLoopbackExposure scope planId clusterId clusterFrame -> result) ->
    Either ReconcileError result
withPreparedLoopbackExposure planned exposure consume =
    Right (consume (PreparedLoopbackExposure (plannedResourceKey planned) exposure))

-- | The exact mapping to render: listen address, host port, node port.
preparedLoopbackExposureMapping ::
    PreparedLoopbackExposure scope planId clusterId clusterFrame ->
    (String, Int, Int)
preparedLoopbackExposureMapping (PreparedLoopbackExposure _ exposure) =
    ( loopbackExposureListenAddress exposure
    , loopbackExposureHostPort exposure
    , loopbackExposureNodePort exposure
    )

{- | What the runtime reports the published port is actually bound to. A
wildcard address is the failure this operation exists to catch: it silently
exposes a project-local service to the network.
-}
data ObservedPortBinding = ObservedPortBinding
    { observedBindAddress :: String
    , observedBindPort :: String
    }
    deriving (Eq, Show)

{- | Confirm that the live binding is the exact loopback mapping that was
prepared. A wildcard or foreign address is a structured 'Conflict', never a
warning, and an unparseable port is a 'Failure' rather than an assumed match.
-}
settleLoopbackExposure ::
    PreparedLoopbackExposure scope planId clusterId clusterFrame ->
    ObservedPortBinding ->
    Either ReconcileError ()
settleLoopbackExposure
    (PreparedLoopbackExposure key exposure)
    observed
        | not (all isDigit port) || null port =
            Left
                ( Failure
                    ( FailureDetail
                        "verify cluster exposure"
                        ("unparseable published port: " <> Text.pack port)
                        ReprobeBeforeRetry
                    )
                )
        | address /= loopbackExposureListenAddress exposure
            || read port /= loopbackExposureHostPort exposure =
            Left
                ( Conflict
                    ( ConflictDetail
                        key
                        ( Text.pack
                            ( loopbackExposureListenAddress exposure
                                <> ":"
                                <> show (loopbackExposureHostPort exposure)
                            )
                        )
                        (Text.pack (address <> ":" <> port))
                        "the cluster port is not bound to the prepared loopback address; refusing to treat a wider binding as the declared exposure"
                    )
                )
        | otherwise = Right ()
      where
        address = observedBindAddress observed
        port = observedBindPort observed
