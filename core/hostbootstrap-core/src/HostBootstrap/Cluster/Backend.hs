{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The IO backend that produces cluster observations while holding the four
Locked-Origin Identity Ownership clauses, plus the loopback-bound exposure
operation the cluster's published ports must consume.

This is the cluster peer of "HostBootstrap.Substrate.Provider.Alias": the
classification and receipt gating live in "HostBootstrap.Cluster.Reconcile", and
this module supplies only the effects that feed it.  Production execution is a
closed private-component capability; only the package's test component can
inject an interpreter for the same protocol.

Clause realization (see
@documents/architecture/ownership_invariant.md@):

* clause 1 — one resolved util-linux @flock(1)@ acquires an exclusive
  @flock(2)@ on a no-follow-opened descriptor beside the cluster origin record.
  The descriptor remains open across the complete observe/mutate/settle
  protocol and the kernel releases it if the holder dies. A Linux @lockf(1)@
  commonly uses the distinct POSIX record-lock namespace, so it is deliberately
  not an admitted alternative;
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
    -- * The clause-holding backend
    StrongClusterBackend,
    discoverStrongClusterBackend,
    runClusterReconcileCall,
    runClusterCleanupCall,
    runClusterCordonCall,
    ClusterStatusObservation (..),
    runClusterStatusCall,
    classifyClusterStatus,
    runClusterReadinessCall,

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

import Data.Char (isAlphaNum, isAscii, isDigit)
import Data.List (nub)
import Control.Exception.Safe (tryAny)
import Data.IORef (IORef, atomicModifyIORef')
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import System.Directory (canonicalizePath)
import Text.Read (readMaybe)
import HostBootstrap.Cluster.Backend.Internal
    ( ClusterCommandResult (..)
    , ClusterExec (..)
    , StrongClusterBackend (..)
    , discoverResolvedStrongClusterBackend
    )
import HostBootstrap.Cluster.Reconcile (
    AppliedClusterCordon,
    PreparedClusterCleanup,
    PreparedClusterCordon,
    PreparedClusterReconcile,
    appliedClusterCordonHandle,
    appliedClusterCordonName,
    appliedClusterCordonNodeNames,
    appliedClusterCordonOwnershipIdentity,
    appliedClusterCordonStateDirectory,
    preparedCleanupClusterName,
    preparedCleanupOwnershipIdentity,
    preparedCleanupNodeNames,
    preparedCleanupStateDirectory,
    preparedClusterConfigDigest,
    preparedClusterConfigPath,
    preparedClusterCordonBudget,
    preparedClusterCordonHandle,
    preparedClusterCordonName,
    preparedClusterCordonNodeNames,
    preparedClusterCordonOwnershipIdentity,
    preparedClusterCordonStateDirectory,
    preparedClusterName,
    preparedClusterNodeNames,
    preparedClusterOwnershipIdentity,
    preparedClusterStateDirectory,
    preparedClusterCleanupHandle,
 )
import HostBootstrap.Cluster.Observation.Internal
    ( ClusterBackendBinding (..)
    , ClusterCleanupCallResult (..)
    , ClusterCleanupObservation (..)
    , ClusterCordonCallResult (..)
    , ClusterCordonObservation (..)
    , ClusterReadinessCallResult (..)
    , ClusterReadinessObservation (..)
    , ClusterReconcileCallResult (..)
    , ClusterReconcileObservation (..)
    , managedClusterBackendIdentity
    , managedClusterBackendBinding
    , clusterBackendBindingArguments
    )
import HostBootstrap.Cluster.Cordon.Foundation (kindNodeCordonArgsForBudget)
import HostBootstrap.HostConfig (buildHostConfig, resolveMaybe)
import HostBootstrap.HostTool (HostTool (Docker, Flock, Kind, Kubectl, Python3), absExePath, toolCommandName)
import HostBootstrap.Reconcile (
    ClusterResource,
    ConflictDetail (..),
    FailureDetail (..),
    PlannedResource,
    ReconcileError (..),
    RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry),
    UnsupportedDetail (..),
    plannedResourceKey,
 )
import qualified HostBootstrap.Substrate as Substrate

-- The cluster the backend owns -----------------------------------------------

{- | The exact cluster this backend may act on: its driver-visible name, the
directory that holds its lock and origin record, and the driver config the
create call consumes. No caller-supplied identity beyond these reaches the
backend.
-}
data ClusterSpec = ClusterSpec String FilePath (Maybe (FilePath, Text)) (Maybe Text)
    deriving (Eq, Show)

mkClusterSpecWithConfig ::
    String ->
    FilePath ->
    Maybe FilePath ->
    Maybe Text ->
    Maybe Text ->
    Either ReconcileError ClusterSpec
mkClusterSpecWithConfig name stateDirectory configPath configDigest owner
    | null name = invalid "cluster name must not be empty"
    | length name > 128 || any (not . safeNameCharacter) name =
        invalid "cluster name must contain only ASCII letters, digits, dot, underscore, or hyphen"
    | not (absolutePath stateDirectory) =
        invalid "cluster state directory must be an absolute path"
    | maybe False (not . absolutePath) configPath =
        invalid "cluster driver config must be an absolute path"
    | '\0' `elem` stateDirectory || maybe False ('\0' `elem`) configPath =
        invalid "cluster identifiers must not contain NUL"
    | maybe False invalidOwner owner =
        invalid "cluster ownership identity must be non-empty, bounded, and contain no NUL"
    | otherwise =
        case (configPath, configDigest) of
            (Nothing, Nothing) -> Right (ClusterSpec name stateDirectory Nothing owner)
            (Just path, Just digest)
                | validSha256 digest -> Right (ClusterSpec name stateDirectory (Just (path, digest)) owner)
                | otherwise -> invalid "cluster config digest must be a lowercase SHA-256 value"
            _ -> invalid "cluster config path and digest must be retained together"
  where
    invalid reason =
        Left (Failure (FailureDetail "validate cluster spec" reason DoNotRetry))
    safeNameCharacter character =
        character >= 'a' && character <= 'z'
            || character >= 'A' && character <= 'Z'
            || character >= '0' && character <= '9'
            || character `elem` ("._-" :: String)
    invalidOwner value = Text.null value || Text.length value > 2048 || Text.any (== '\0') value

validSha256 :: Text -> Bool
validSha256 digest =
    Text.length digest == 64
        && Text.all (\character -> isDigit character || character >= 'a' && character <= 'f') digest

absolutePath :: FilePath -> Bool
absolutePath ('/' : _) = True
absolutePath _ = False

clusterSpecName :: ClusterSpec -> String
clusterSpecName (ClusterSpec name _ _ _) = name

clusterSpecStateDirectory :: ClusterSpec -> FilePath
clusterSpecStateDirectory (ClusterSpec _ stateDirectory _ _) = stateDirectory

clusterSpecConfig :: ClusterSpec -> Maybe (FilePath, Text)
clusterSpecConfig (ClusterSpec _ _ config _) = config

clusterSpecOwner :: ClusterSpec -> Maybe Text
clusterSpecOwner (ClusterSpec _ _ _ owner) = owner

{- | Capability for a backend that holds the four clauses for a cluster. Its
constructor lives in a Cabal-private component. Production discovery resolves
the closed typed tool set through @HostConfig@ and admits only its canonical,
root-owned Linux provider-frame paths; the raw executor used by tests is not
visible to downstream packages.
-}
discoverStrongClusterBackend :: IO (Either ReconcileError StrongClusterBackend)
discoverStrongClusterBackend = do
    detected <- Substrate.detect
    case detected of
        Left reason -> pure (unsupported reason)
        Right substrate
            | not (Substrate.isLinux substrate) ->
                pure (unsupported "the exact cluster ownership backend is available only inside a Linux provider frame")
            | otherwise -> do
                hostConfig <- buildHostConfig substrate
                case traverse (resolvePath hostConfig) requiredClusterTools of
                    Left reason -> pure (unsupported reason)
                    Right resolved -> do
                        canonical <- tryAny (traverse canonicalizePath resolved)
                        case canonical of
                            Left failure -> pure (unsupported ("canonicalize resolved cluster tools: " ++ show failure))
                            Right [driver, runtime, kubectl, flock, python] -> do
                                discovered <- discoverResolvedStrongClusterBackend driver runtime kubectl flock python
                                pure (either unsupported Right discovered)
                            Right _ -> pure (unsupported "the closed cluster tool resolver returned the wrong arity")
  where
    unsupported reason =
        Left
            ( Unsupported
                (UnsupportedDetail "reconcile cluster" (Text.pack reason))
            )
    requiredClusterTools = [Kind, Docker, Kubectl, Flock, Python3]
    resolvePath hostConfig tool =
        case resolveMaybe hostConfig tool of
            Nothing -> Left ("required cluster tool was not resolved through HostConfig: " ++ toolCommandName tool)
            Just executable -> Right (absExePath executable)

-- The clause-holding reconcile/cleanup calls ---------------------------------

{- | Observe the cluster under an exclusive @flock@ and, when it is absent,
create it. The raw observation reports the control-plane node container's
immutable ID. Settlement retains that backend identity beside, rather than in
place of, the prepared journal generation; the origin record binds the same ID
so conditional deletion can compare against it (clauses 2–4).
-}
runClusterReconcileCall ::
    StrongClusterBackend ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO (ClusterReconcileCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion)
runClusterReconcileCall
    backend
    prepared =
        ClusterReconcileCallResult <$> case preparedReconcileSpec prepared of
            Left err -> pure (ClusterProbeFailed (Text.pack (show err)))
            Right spec ->
                let nodes = preparedClusterNodeNames prepared
                 in parseReconcileReport <$> runLockedCluster backend spec "reconcile" Nothing (show (length nodes) : nodes)

{- | Delete the cluster under the same exclusive lock, but only while its
control-plane identity still matches the one the origin record bound. A
replacement is reported as such and left intact.
-}
runClusterCleanupCall ::
    StrongClusterBackend ->
    PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    IO (ClusterCleanupCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase)
runClusterCleanupCall
    backend
    prepared =
        case preparedCleanupSpec prepared of
            Left err -> pure (ClusterCleanupCallResult (ClusterCleanupFailed err))
            Right spec -> do
                let binding = managedClusterBackendBinding (preparedClusterCleanupHandle prepared)
                    nodes = preparedCleanupNodeNames prepared
                result <- runLockedCluster backend spec "cleanup" (Just binding) (show (length nodes) : nodes)
                pure (ClusterCleanupCallResult (parseCleanupReport (Text.pack (preparedCleanupClusterName prepared)) result))

{- | Apply the exact admitted cluster slice only after ownership settlement has
minted cordon authority.  The runtime path retained by backend discovery is the
Docker-compatible node-container adapter; no caller supplies resource values or
node names here.
-}
runClusterCordonCall ::
    StrongClusterBackend ->
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    IO (ClusterCordonCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase)
runClusterCordonCall backend prepared =
    ClusterCordonCallResult <$> case
            traverse
                (\nodeName -> kindNodeCordonArgsForBudget nodeName (preparedClusterCordonBudget prepared))
                (preparedClusterCordonNodeNames prepared)
        of
            Left reason -> pure (ClusterCordonFailed (Text.pack reason))
            Right argSets ->
                case preparedCordonSpec prepared of
                    Left err -> pure (ClusterCordonFailed (Text.pack (show err)))
                    Right spec -> do
                        let binding = managedClusterBackendBinding (preparedClusterCordonHandle prepared)
                            flattened = show (length argSets) : concat argSets
                        parseCordonReport <$> runLockedCluster backend spec "cordon" (Just binding) flattened

preparedReconcileSpec ::
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    Either ReconcileError ClusterSpec
preparedReconcileSpec prepared =
    mkClusterSpecWithConfig
        (preparedClusterName prepared)
        (preparedClusterStateDirectory prepared)
        (preparedClusterConfigPath prepared)
        (preparedClusterConfigDigest prepared)
        (Just (preparedClusterOwnershipIdentity prepared))

preparedCordonSpec ::
    PreparedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Either ReconcileError ClusterSpec
preparedCordonSpec prepared =
    mkClusterSpecWithConfig
        (preparedClusterCordonName prepared)
        (preparedClusterCordonStateDirectory prepared)
        Nothing
        Nothing
        (Just (preparedClusterCordonOwnershipIdentity prepared))

preparedCleanupSpec ::
    PreparedClusterCleanup scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    Either ReconcileError ClusterSpec
preparedCleanupSpec prepared =
    mkClusterSpecWithConfig
        (preparedCleanupClusterName prepared)
        (preparedCleanupStateDirectory prepared)
        Nothing
        Nothing
        (Just (preparedCleanupOwnershipIdentity prepared))

-- | Read-only status returned by the exact plan-owned status path.
data ClusterStatusObservation
    = ClusterStatusPresent
    | ClusterStatusAbsent
    | ClusterStatusProbeFailed Text
    deriving (Eq, Show)

{- | Ask the cluster driver which clusters it names, and decide from the answer.

Read-only, and one bounded run of the driver's own listing rather than a program
shipped to an interpreter: the argument vector is this module's, the runner is
the driver's row of the one bounded-run table, and what the bytes mean is
'classifyClusterStatus' — a total function a suite reaches by application rather
than by arranging for a process to produce each shape (§ KK, § NN).
-}
runClusterStatusCall ::
    StrongClusterBackend ->
    PreparedClusterReconcile scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId operationKey callDigest attempt journalVersion ->
    IO ClusterStatusObservation
runClusterStatusCall (StrongClusterBackend exec driver _runtime _kubectl _flock _python _closedPath _readinessVersion) prepared = do
    result <- runClusterCommand exec [driver, "get", "clusters"]
    pure (classifyClusterStatus (preparedClusterName prepared) result)

{- | What the driver's listing says about one cluster, as a total function of it.

Narrow on purpose, because a listing is another program's output. A non-zero
exit, anything at all on standard error, a body that does not end in exactly one
newline, a carriage return, a byte outside ASCII, a name outside the portable
alphabet, and the same name listed twice are each the driver contradicting
itself, and each is a refusal rather than an absence. Telling "the driver says
this cluster is not here" apart from "the driver did not answer" is the whole
point: the first authorizes creation and the second must not.
-}
classifyClusterStatus :: String -> ClusterCommandResult -> ClusterStatusObservation
classifyClusterStatus name result
    | not (clusterCommandOk result) = refused "cluster-list"
    | not (null (clusterCommandStderr result)) = refused "cluster-list"
    | otherwise = case listedClusterNames (clusterCommandStdout result) of
        Left reason -> refused reason
        Right names
            | not (all safeClusterName names) -> refused "cluster-list-name"
            | length names /= length (nub names) -> refused "duplicate-cluster"
            | name `elem` names -> ClusterStatusPresent
            | otherwise -> ClusterStatusAbsent
  where
    refused reason = ClusterStatusProbeFailed (Text.pack reason)

{- | The names one well-framed listing carries.

Empty output is an empty listing rather than a malformed one, because a driver
that names nothing writes nothing.
-}
listedClusterNames :: String -> Either String [String]
listedClusterNames "" = Right []
listedClusterNames output
    | last output /= '\n' = Left "cluster-list-framing"
    | '\r' `elem` output = Left "cluster-list-framing"
    | not (all isAscii output) = Left "cluster-list-framing"
    | otherwise = Right (splitOnNewline (init output))

splitOnNewline :: String -> [String]
splitOnNewline value = case break (== '\n') value of
    (before, []) -> [before]
    (before, _ : rest) -> before : splitOnNewline rest

-- | The portable alphabet a cluster name this driver reports must stay inside.
safeClusterName :: String -> Bool
safeClusterName value =
    not (null value)
        && length value <= 128
        && all admissible value
  where
    admissible character =
        isAscii character
            && (isAlphaNum character || character `elem` ("._-" :: String))

-- | The readiness probe is read-only and retains plan identity only when its
-- raw observation is settled in 'HostBootstrap.Cluster.Reconcile'.
runClusterReadinessCall ::
    StrongClusterBackend ->
    AppliedClusterCordon scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase ->
    IO (ClusterReadinessCallResult scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId phase)
runClusterReadinessCall backend@(StrongClusterBackend _ _ _ _ _ _ _ readinessVersion) applied = runFresh
  where
    managed = appliedClusterCordonHandle applied
    expectedIdentity = managedClusterBackendIdentity managed
    binding = managedClusterBackendBinding managed
    runFresh = do
        observation <-
            case
                mkClusterSpecWithConfig
                    (appliedClusterCordonName applied)
                    (appliedClusterCordonStateDirectory applied)
                    Nothing
                    Nothing
                    (Just (appliedClusterCordonOwnershipIdentity applied))
                of
                Left err -> pure (ClusterReadinessProbeFailed (Text.pack (show err)))
                Right spec ->
                    let nodes = appliedClusterCordonNodeNames applied
                     in parseReadinessReport <$> runLockedCluster backend spec "readiness" (Just binding) (show (length nodes) : nodes)
        (version, versionedObservation) <- case observation of
            ClusterReady identity
                | identity == expectedIdentity -> do
                    advanced <- nextReadinessVersion readinessVersion
                    pure $ case advanced of
                        Right fresh -> (fresh, observation)
                        Left reason -> (0, ClusterReadinessProbeFailed reason)
            _ -> pure (0, observation)
        pure (ClusterReadinessCallResult version versionedObservation runFresh)

nextReadinessVersion :: IORef Word64 -> IO (Either Text Word64)
nextReadinessVersion counter =
    atomicModifyIORef' counter $ \current ->
        if current == maxBound
            then (current, Left "the readiness phase-observation version is exhausted")
            else
                let next = current + 1
                 in (next, Right next)

parseReadinessReport :: ClusterCommandResult -> ClusterReadinessObservation
parseReadinessReport result
    | not (clusterCommandOk result) =
        ClusterReadinessProbeFailed
            ("the read-only readiness command failed: " <> firstLineText (clusterCommandStderr result))
    | otherwise = case protocolWords result of
        Just ["READY", identity] -> ClusterReady (Text.pack identity)
        Just ["NOTREADY", identity] -> ClusterNotReady (Text.pack identity)
        Just ("FAILED" : rest) ->
            ClusterReadinessProbeFailed (Text.pack (unwords rest))
        _ ->
            ClusterReadinessProbeFailed
                ("unparseable readiness report: " <> firstLineText (clusterCommandStdout result))

{- | Run one complete backend operation in a single Python process. The process
opens the state directory, lock, origin record, and any config snapshot with
@O_NOFOLLOW@. It asks the resolved util-linux @flock@ to lock the inherited
descriptor; Linux flock locks belong to the shared open-file description, so
the lock remains held by this process after the small @flock@ child exits.

The canonical origin moves through @prepared@, @executing@, and @managed@.
Every record self-binds its own inode. Before the driver effect, @executing@
also binds the config snapshot inode/digest and private kubeconfig inode; a
fresh process can therefore recover or remove only those exact objects.
-}
runLockedCluster ::
    StrongClusterBackend -> ClusterSpec -> String -> Maybe ClusterBackendBinding -> [String] -> IO ClusterCommandResult
runLockedCluster
    (StrongClusterBackend exec driver runtime kubectl flock python closedPath _readinessVersion)
    spec
    operation
    expectedBinding
    extraArgs =
        runClusterCommand
            exec
            ( [ python
              , "-c"
              , clusterOwnershipProgram
              , flock
              , clusterSpecStateDirectory spec
              , clusterSpecName spec
              , operation
              , driver
              , runtime
              , kubectl
              , closedPath
              , maybe "" Text.unpack (clusterSpecOwner spec)
              , maybe "" fst (clusterSpecConfig spec)
              , maybe "" (Text.unpack . snd) (clusterSpecConfig spec)
              ]
                <> maybe (replicate 8 "") clusterBackendBindingArguments expectedBinding
                <> extraArgs
            )

clusterOwnershipProgram :: String
clusterOwnershipProgram =
    unlines
        [ "import hashlib,json,os,secrets,signal,stat,subprocess,sys"
        , "class ProtocolError(Exception): pass"
        , "def finish(value): print(value,flush=True); raise SystemExit(0)"
        , "def reject(stage): raise ProtocolError(stage)"
        , "active_process=None"
        , "def stop_active(signum,_frame):"
        , "    if active_process is not None:"
        , "        try: os.killpg(active_process.pid,signal.SIGKILL)"
        , "        except OSError: pass"
        , "    raise SystemExit(128+signum)"
        , "signal.signal(signal.SIGINT,stop_active); signal.signal(signal.SIGTERM,stop_active)"
        , "def write_all(fd,data):"
        , "    view=memoryview(data)"
        , "    while view:"
        , "        count=os.write(fd,view)"
        , "        if count <= 0: reject('short-write')"
        , "        view=view[count:]"
        , "def read_all(fd,limit):"
        , "    chunks=[]; total=0"
        , "    while True:"
        , "        chunk=os.read(fd,min(65536,limit+1-total))"
        , "        if not chunk: return b''.join(chunks)"
        , "        chunks.append(chunk); total += len(chunk)"
        , "        if total > limit: reject('file-too-large')"
        , "def safe_name(value): return bool(value) and len(value) <= 128 and all(ch.isascii() and (ch.isalnum() or ch in '._-') for ch in value)"
        , "def owned_directory(fd,stage):"
        , "    current=os.fstat(fd)"
        , "    if not stat.S_ISDIR(current.st_mode) or current.st_uid != os.geteuid() or current.st_mode & 0o022: reject(stage+'-foreign')"
        , "    return fd"
        , "def trusted_directory(fd,stage):"
        , "    current=os.fstat(fd)"
        , "    sticky_root=current.st_uid == 0 and bool(current.st_mode & stat.S_ISVTX)"
        , "    if not stat.S_ISDIR(current.st_mode) or current.st_uid not in (0,os.geteuid()) or (current.st_mode & 0o022 and not sticky_root): reject(stage+'-foreign')"
        , "    return fd"
        , "def open_or_create_directory(parent,name,stage):"
        , "    created=False"
        , "    try: os.mkdir(name,0o700,dir_fd=parent); created=True"
        , "    except FileExistsError: pass"
        , "    except OSError: reject(stage+'-create')"
        , "    if created:"
        , "        try: os.fsync(parent)"
        , "        except OSError: reject(stage+'-parent-sync')"
        , "    try: before=os.stat(name,dir_fd=parent,follow_symlinks=False)"
        , "    except OSError: reject(stage+'-observe')"
        , "    try: fd=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)"
        , "    except OSError: reject(stage+'-open')"
        , "    opened=os.fstat(fd)"
        , "    if (before.st_dev,before.st_ino) != (opened.st_dev,opened.st_ino): reject(stage+'-raced')"
        , "    owned_directory(fd,stage)"
        , "    if created:"
        , "        try: os.fsync(fd)"
        , "        except OSError: reject(stage+'-sync')"
        , "    return fd"
        , "def open_absolute_directory(path,stage):"
        , "    if not os.path.isabs(path) or os.path.normpath(path) != path: reject(stage+'-path')"
        , "    parts=[part for part in path.split(os.sep) if part]"
        , "    if any(part in ('.','..') for part in parts): reject(stage+'-path')"
        , "    try: current=os.open(os.sep,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)"
        , "    except OSError: reject(stage+'-open')"
        , "    trusted_directory(current,stage)"
        , "    for part in parts:"
        , "        try: before=os.stat(part,dir_fd=current,follow_symlinks=False)"
        , "        except OSError: reject(stage+'-observe')"
        , "        try: child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=current)"
        , "        except OSError: reject(stage+'-open')"
        , "        opened=os.fstat(child)"
        , "        if not stat.S_ISDIR(opened.st_mode) or (before.st_dev,before.st_ino) != (opened.st_dev,opened.st_ino): reject(stage+'-raced')"
        , "        trusted_directory(child,stage)"
        , "        os.close(current); current=child"
        , "    return current"
        , "def open_existing_directory(parent,name,stage):"
        , "    try: before=os.stat(name,dir_fd=parent,follow_symlinks=False)"
        , "    except OSError: reject(stage+'-observe')"
        , "    try: fd=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)"
        , "    except OSError: reject(stage+'-open')"
        , "    opened=os.fstat(fd)"
        , "    if (before.st_dev,before.st_ino) != (opened.st_dev,opened.st_ino): reject(stage+'-raced')"
        , "    return owned_directory(fd,stage)"
        , "def secure_state(path,allow_create):"
        , "    if not os.path.isabs(path): reject('state-not-absolute')"
        , "    if not hasattr(os,'O_NOFOLLOW'): reject('nofollow-unavailable')"
        , "    leaf=os.path.basename(path); state_parent=os.path.dirname(path); parent_name=os.path.basename(state_parent); root=os.path.dirname(state_parent)"
        , "    if not safe_name(leaf) or parent_name != '.cluster' or not root: reject('state-shape')"
        , "    root_fd=open_absolute_directory(root,'state-root')"
        , "    owned_directory(root_fd,'state-root')"
        , "    opener=open_or_create_directory if allow_create else open_existing_directory"
        , "    parent_fd=opener(root_fd,parent_name,'state-parent')"
        , "    return opener(parent_fd,leaf,'state')"
        , "def open_lock(directory,name,allow_create):"
        , "    flags=os.O_RDWR|os.O_NOFOLLOW|getattr(os,'O_NONBLOCK',0)|(os.O_CREAT if allow_create else 0)"
        , "    try: fd=os.open(name,flags,0o600,dir_fd=directory)"
        , "    except OSError: reject('lock-open')"
        , "    info=os.fstat(fd)"
        , "    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1: reject('lock-foreign')"
        , "    try: path_info=os.lstat(name,dir_fd=directory)"
        , "    except OSError: reject('lock-path')"
        , "    if file_identity(path_info) != file_identity(info): reject('lock-raced')"
        , "    return fd,file_identity(info)"
        , "def validate_lock(fd,expected_identity):"
        , "    info=os.fstat(fd)"
        , "    if file_identity(info) != expected_identity or not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1: reject('lock-raced')"
        , "    try: path_info=os.lstat(lock_name,dir_fd=directory)"
        , "    except OSError: reject('lock-path')"
        , "    if file_identity(path_info) != expected_identity: reject('lock-raced')"
        , "def validate_frame():"
        , "    validate_lock(lock,lock_identity)"
        , "    reopened=open_absolute_directory(state,'state-revalidate')"
        , "    try: reopened_identity=file_identity(os.fstat(reopened))"
        , "    finally: os.close(reopened)"
        , "    if reopened_identity != state_identity: reject('state-raced')"
        , "def command(args,input_value=None,timeout=30,extra_fds=()):"
        , "    global active_process"
        , "    inherited=tuple(dict.fromkeys((directory,lock)+tuple(extra_fds)))"
        , "    try: process=subprocess.Popen(args,stdin=subprocess.PIPE if input_value is not None else subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,pass_fds=inherited,env=child_environment,cwd='/',start_new_session=True); active_process=process"
        , "    except OSError: reject('command-exec')"
        , "    try: stdout,stderr=process.communicate(input_value,timeout=timeout)"
        , "    except subprocess.TimeoutExpired:"
        , "        try: os.killpg(process.pid,signal.SIGTERM)"
        , "        except OSError: pass"
        , "        try: process.wait(timeout=2)"
        , "        except subprocess.TimeoutExpired:"
        , "            try: os.killpg(process.pid,signal.SIGKILL)"
        , "            except OSError: pass"
        , "            try: process.wait(timeout=2)"
        , "            except subprocess.TimeoutExpired: active_process=None; reject('command-reap-timeout')"
        , "        active_process=None; reject('command-timeout')"
        , "    active_process=None"
        , "    return subprocess.CompletedProcess(args,process.returncode,stdout,stderr)"
        , "def sync_directory():"
        , "    try: os.fsync(directory)"
        , "    except OSError: reject('directory-sync')"
        , "def file_identity(info): return (info.st_dev,info.st_ino)"
        , "def validate_regular(info,stage,links=(1,)):"
        , "    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink not in links: reject(stage+'-foreign')"
        , "def open_relative_retained(path,limit,allow_missing=False,links=(1,)):"
        , "    try: fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|getattr(os,'O_NONBLOCK',0),dir_fd=directory)"
        , "    except FileNotFoundError:"
        , "        if allow_missing: return None"
        , "        reject('record-missing')"
        , "    except OSError: reject('record-open')"
        , "    info=os.fstat(fd); validate_regular(info,'record',links)"
        , "    try: path_info=os.lstat(path,dir_fd=directory)"
        , "    except OSError: reject('record-path')"
        , "    if file_identity(path_info) != file_identity(info): reject('record-raced')"
        , "    raw=read_all(fd,limit); after=os.fstat(fd); validate_regular(after,'record',links)"
        , "    if file_identity(after) != file_identity(info): reject('record-raced')"
        , "    return fd,raw,file_identity(info)"
        , "def read_relative(path,limit):"
        , "    retained=open_relative_retained(path,limit,True)"
        , "    if retained is None: return None"
        , "    fd,raw,_identity=retained; os.close(fd); return raw"
        , "def validate_retained(path,fd,expected_identity,expected_raw,limit=4096):"
        , "    info=os.fstat(fd); validate_regular(info,'record')"
        , "    if file_identity(info) != expected_identity: reject('record-raced')"
        , "    try: path_info=os.lstat(path,dir_fd=directory)"
        , "    except OSError: reject('record-path')"
        , "    if file_identity(path_info) != expected_identity: reject('record-raced')"
        , "    os.lseek(fd,0,os.SEEK_SET)"
        , "    if read_all(fd,limit) != expected_raw: reject('record-changed')"
        , "def canonical(data): return (json.dumps(data,sort_keys=True,separators=(',',':'))+'\\n').encode('utf-8')"
        , "def valid_kernel_identity(value): return isinstance(value,list) and len(value) == 2 and all(isinstance(part,int) and part >= 0 for part in value) and value[1] > 0"
        , "def validate_record(data,raw,observed_record_identity):"
        , "    if not isinstance(data,dict) or data.get('version') != 1 or data.get('origin') != 'absent': reject('record-format')"
        , "    if data.get('name') != name: reject('record-name')"
        , "    if not isinstance(data.get('owner'),str) or not data['owner']: reject('record-owner')"
        , "    nonce=data.get('nonce')"
        , "    if not isinstance(nonce,str) or len(nonce) != 64 or any(ch not in '0123456789abcdef' for ch in nonce): reject('record-nonce')"
        , "    config=data.get('config')"
        , "    if config is not None and (not isinstance(config,str) or len(config) != 64 or any(ch not in '0123456789abcdef' for ch in config)): reject('record-config')"
        , "    if not valid_kernel_identity(data.get('state_directory')) or not valid_kernel_identity(data.get('lock')): reject('record-kernel-binding')"
        , "    if tuple(data['state_directory']) != state_identity or tuple(data['lock']) != lock_identity: reject('record-kernel-mismatch')"
        , "    if not valid_kernel_identity(data.get('record_identity')) or tuple(data['record_identity']) != observed_record_identity: reject('record-self-identity')"
        , "    state=data.get('state')"
        , "    if state == 'prepared':"
        , "        if set(data) != {'version','name','owner','nonce','origin','config','state','state_directory','lock','record_identity'}: reject('record-format')"
        , "    elif state == 'executing':"
        , "        config_snapshot=data.get('config_snapshot'); kube_snapshot=data.get('kube_snapshot')"
        , "        if set(data) != {'version','name','owner','nonce','origin','config','state','state_directory','lock','record_identity','config_snapshot','kube_snapshot'}: reject('record-format')"
        , "        if config is None and config_snapshot is not None: reject('record-config-snapshot')"
        , "        if config is not None and (not isinstance(config_snapshot,dict) or set(config_snapshot) != {'name','identity','digest'} or config_snapshot.get('name') != record_name+'.config-'+config or not valid_kernel_identity(config_snapshot.get('identity')) or config_snapshot.get('digest') != config): reject('record-config-snapshot')"
        , "        if not isinstance(kube_snapshot,dict) or set(kube_snapshot) != {'name','identity'} or kube_snapshot.get('name') != record_name+'.kube-'+str(nonce) or not valid_kernel_identity(kube_snapshot.get('identity')): reject('record-kube-snapshot')"
        , "    elif state == 'managed':"
        , "        identity=data.get('identity'); nodes=data.get('nodes')"
        , "        if set(data) != {'version','name','owner','nonce','origin','config','state','state_directory','lock','record_identity','identity','nodes'} or not isinstance(identity,str) or not identity or any(ch.isspace() for ch in identity): reject('record-identity')"
        , "        if not isinstance(nodes,dict) or not nodes: reject('record-nodes')"
        , "        if any(not safe_name(key) or not isinstance(value,str) or not value or any(ch.isspace() for ch in value) for key,value in nodes.items()): reject('record-nodes')"
        , "        if nodes.get(node) != identity: reject('record-control-plane')"
        , "    else: reject('record-state')"
        , "    if canonical(data) != raw: reject('record-noncanonical')"
        , "    return data"
        , "def open_record_retained(allow_missing=False):"
        , "    retained=open_relative_retained(record_name,4096,allow_missing)"
        , "    if retained is None: return None"
        , "    fd,raw,opened_identity=retained"
        , "    try: data=json.loads(raw.decode('utf-8'))"
        , "    except Exception: reject('record-decode')"
        , "    return validate_record(data,raw,opened_identity),fd,opened_identity,raw"
        , "def binding_words(data,record_identity):"
        , "    return [data['identity'],str(data['state_directory'][0]),str(data['state_directory'][1]),str(data['lock'][0]),str(data['lock'][1]),str(record_identity[0]),str(record_identity[1]),data['nonce']]"
        , "def expected_binding():"
        , "    values=[expected,expected_state_device,expected_state_inode,expected_lock_device,expected_lock_inode,expected_record_device,expected_record_inode,expected_nonce]"
        , "    if all(not value for value in values): return None"
        , "    if any(not value for value in values): reject('expected-binding')"
        , "    try: parsed=[int(value) for value in values[1:7]]"
        , "    except ValueError: reject('expected-binding')"
        , "    if any(value < 0 for value in parsed) or parsed[1] == 0 or parsed[3] == 0 or parsed[5] == 0 or len(expected_nonce) != 64 or any(ch not in '0123456789abcdef' for ch in expected_nonce): reject('expected-binding')"
        , "    return expected,tuple(parsed[0:2]),tuple(parsed[2:4]),tuple(parsed[4:6]),expected_nonce"
        , "def read_record():"
        , "    retained=open_record_retained(True)"
        , "    if retained is None: return None"
        , "    data,fd,_identity,_raw=retained; os.close(fd); return data"
        , "def stage_bytes(raw,kind,limit=4096):"
        , "    digest=hashlib.sha256(raw).hexdigest(); stage=record_name+'.'+kind+'-'+digest"
        , "    try: fd=os.open(stage,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory)"
        , "    except OSError: reject('stage-create')"
        , "    try: write_all(fd,raw); os.fsync(fd); info=os.fstat(fd); validate_regular(info,'stage')"
        , "    except OSError: reject('stage-write')"
        , "    finally: os.close(fd)"
        , "    retained=open_relative_retained(stage,limit,False); observed,observed_raw,stage_identity=retained"
        , "    os.close(observed)"
        , "    if observed_raw != raw: reject('stage-readback')"
        , "    sync_directory()"
        , "    return stage,stage_identity"
        , "def stage_record(data):"
        , "    stage=record_name+'.transition-'+data['state']+'-'+data['nonce']"
        , "    try: fd=os.open(stage,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory)"
        , "    except OSError: reject('record-stage-create')"
        , "    info=os.fstat(fd); validate_regular(info,'record-stage'); stage_identity=file_identity(info)"
        , "    target=dict(data); target['record_identity']=list(stage_identity); raw=canonical(target)"
        , "    try: write_all(fd,raw); os.fsync(fd); os.lseek(fd,0,os.SEEK_SET); observed=read_all(fd,4096)"
        , "    except OSError: reject('record-stage-write')"
        , "    finally: os.close(fd)"
        , "    if observed != raw: reject('record-stage-readback')"
        , "    try: path_info=os.lstat(stage,dir_fd=directory)"
        , "    except OSError: reject('record-stage-path')"
        , "    if file_identity(path_info) != stage_identity: reject('record-stage-raced')"
        , "    sync_directory()"
        , "    return stage,stage_identity,target,raw"
        , "def unlink_exact(path,expected_identity):"
        , "    try: observed=os.lstat(path,dir_fd=directory)"
        , "    except OSError: reject('stage-path')"
        , "    if file_identity(observed) != expected_identity: reject('stage-raced')"
        , "    try: os.unlink(path,dir_fd=directory)"
        , "    except OSError: reject('stage-remove')"
        , "    sync_directory()"
        , "def publish_initial(data):"
        , "    stage,stage_identity,target,raw=stage_record(data)"
        , "    try: os.link(stage,record_name,src_dir_fd=directory,dst_dir_fd=directory,follow_symlinks=False)"
        , "    except FileExistsError: reject('record-raced')"
        , "    except OSError: reject('record-publish')"
        , "    sync_directory()"
        , "    try: published=os.lstat(record_name,dir_fd=directory)"
        , "    except OSError: reject('record-readback')"
        , "    if file_identity(published) != stage_identity: reject('record-raced')"
        , "    unlink_exact(stage,stage_identity)"
        , "    retained=open_record_retained(False); observed,fd,_identity,observed_raw=retained; os.close(fd)"
        , "    if observed != target or observed_raw != raw: reject('record-readback')"
        , "def replace_record(data,current_fd,current_identity,current_raw):"
        , "    validate_retained(record_name,current_fd,current_identity,current_raw)"
        , "    stage,_stage_identity,target,raw=stage_record(data)"
        , "    validate_retained(record_name,current_fd,current_identity,current_raw)"
        , "    try: os.replace(stage,record_name,src_dir_fd=directory,dst_dir_fd=directory)"
        , "    except OSError: reject('record-replace')"
        , "    sync_directory(); os.close(current_fd)"
        , "    retained=open_record_retained(False); observed,fd,new_identity,observed_raw=retained"
        , "    if observed != target or observed_raw != raw: reject('record-readback')"
        , "    return observed,fd,new_identity,observed_raw"
        , "def remove_record(current_fd,current_identity,current_raw):"
        , "    validate_retained(record_name,current_fd,current_identity,current_raw)"
        , "    try: os.unlink(record_name,dir_fd=directory)"
        , "    except OSError: reject('record-remove')"
        , "    sync_directory(); os.close(current_fd)"
        , "    if read_relative(record_name,4096) is not None: reject('record-remove-readback')"
        , "def cleanup_stages():"
        , "    transition_prefix=record_name+'.transition-'; config_prefix=record_name+'.config-'; kube_prefix=record_name+'.kube-'"
        , "    prefixes=(transition_prefix,config_prefix,kube_prefix)"
        , "    try: entries=sorted(os.listdir(directory),key=lambda entry:(0 if entry.startswith(transition_prefix) else 1,entry))"
        , "    except OSError: reject('state-list')"
        , "    for entry in entries:"
        , "        if not entry.startswith(prefixes): continue"
        , "        prefix=next((candidate for candidate in prefixes if entry.startswith(candidate)),None); suffix=entry[len(prefix):] if prefix else ''"
        , "        retained=open_relative_retained(entry,1048576,False,(1,2)); fd,raw,stage_identity=retained; info=os.fstat(fd)"
        , "        if prefix == transition_prefix:"
        , "            try: transition_state,transition_nonce=suffix.split('-',1)"
        , "            except ValueError: reject('stage-name')"
        , "            if transition_state not in ('prepared','executing','managed') or len(transition_nonce) != 64 or any(ch not in '0123456789abcdef' for ch in transition_nonce): reject('stage-name')"
        , "            try: stage_data=json.loads(raw.decode('utf-8'))"
        , "            except Exception: reject('stage-decode')"
        , "            stage_data=validate_record(stage_data,raw,stage_identity)"
        , "            if stage_data['owner'] != owner or stage_data['state'] != transition_state or stage_data['nonce'] != transition_nonce: reject('stage-binding')"
        , "            if info.st_nlink == 2:"
        , "                try: published=os.lstat(record_name,dir_fd=directory)"
        , "                except OSError: reject('stage-link-observe')"
        , "                if transition_state != 'prepared' or file_identity(published) != stage_identity: reject('stage-link')"
        , "                os.close(fd); unlink_exact(entry,stage_identity)"
        , "            elif info.st_nlink == 1:"
        , "                current_retained=open_record_retained(True)"
        , "                if current_retained is None: reject('stage-transition')"
        , "                current,current_fd,current_identity,current_raw=current_retained"
        , "                if (stage_data['name'],stage_data['nonce'],stage_data['owner'],stage_data['config'],stage_data['state_directory'],stage_data['lock']) != (current['name'],current['nonce'],current['owner'],current['config'],current['state_directory'],current['lock']): reject('stage-binding')"
        , "                allowed=(current['state'],stage_data['state']) in (('prepared','executing'),('executing','managed'))"
        , "                if not allowed: reject('stage-transition')"
        , "                if stage_data['state'] == 'executing': close_bound_snapshots(open_bound_snapshots(stage_data,False))"
        , "                if stage_data['state'] == 'managed': require_bound_snapshots_absent(current)"
        , "                validate_retained(record_name,current_fd,current_identity,current_raw)"
        , "                try: os.replace(entry,record_name,src_dir_fd=directory,dst_dir_fd=directory)"
        , "                except OSError: reject('stage-recover-replace')"
        , "                sync_directory(); os.close(current_fd); os.close(fd)"
        , "                recovered_record=open_record_retained(False); recovered_data,recovered_fd,_recovered_identity,recovered_raw=recovered_record; os.close(recovered_fd)"
        , "                if recovered_data != stage_data or recovered_raw != raw: reject('stage-recover-readback')"
        , "            else: reject('stage-links')"
        , "        elif prefix == config_prefix:"
        , "            if len(suffix) != 64 or any(ch not in '0123456789abcdef' for ch in suffix) or hashlib.sha256(raw).hexdigest() != suffix: reject('config-stage-digest')"
        , "            current=read_record(); binding=current.get('config_snapshot') if current is not None and current.get('state') == 'executing' else None"
        , "            if binding is None or binding['name'] != entry or tuple(binding['identity']) != stage_identity or binding['digest'] != suffix or info.st_nlink != 1: reject('config-stage-binding')"
        , "            os.close(fd)"
        , "        else:"
        , "            current=read_record()"
        , "            binding=current.get('kube_snapshot') if current is not None and current.get('state') == 'executing' else None"
        , "            if len(suffix) != 64 or any(ch not in '0123456789abcdef' for ch in suffix) or binding is None or binding['name'] != entry or tuple(binding['identity']) != stage_identity or info.st_nlink != 1: reject('kube-stage-binding')"
        , "            os.close(fd)"
        , "def refuse_stages():"
        , "    prefixes=(record_name+'.transition-',record_name+'.config-',record_name+'.kube-')"
        , "    try: entries=os.listdir(directory)"
        , "    except OSError: reject('state-list')"
        , "    if any(entry.startswith(prefixes) for entry in entries): reject('stage-present')"
        , "def list_cluster():"
        , "    raw=command([driver,'get','clusters'])"
        , "    names=strict_lines(raw,'cluster-list',True)"
        , "    if names.count(name) > 1: reject('duplicate-cluster')"
        , "    return name in names"
        , "def strict_lines(raw,stage,allow_empty=False):"
        , "    if raw.returncode != 0 or raw.stderr: reject(stage)"
        , "    if raw.stdout == '' and allow_empty: return []"
        , "    if not raw.stdout.endswith('\\n') or '\\r' in raw.stdout: reject(stage)"
        , "    values=raw.stdout[:-1].split('\\n')"
        , "    if not values or any(not value for value in values): reject(stage)"
        , "    return values"
        , "def one_line(raw,stage):"
        , "    values=strict_lines(raw,stage)"
        , "    if len(values) != 1 or not values[0] or len(values[0]) > 512 or any(ch.isspace() for ch in values[0]): reject(stage)"
        , "    return values[0]"
        , "def node_identity(node_name):"
        , "    listed=command([runtime,'container','ls','--all','--quiet','--no-trunc','--filter','name=^/'+node_name+'$'])"
        , "    candidates=strict_lines(listed,'identity-list',True)"
        , "    if len(candidates) > 1: reject('identity-duplicate')"
        , "    if not candidates: return None"
        , "    observed=one_line(command([runtime,'inspect','-f','{{.Id}}',candidates[0]]),'identity-observe')"
        , "    if observed != candidates[0]: reject('identity-raced')"
        , "    return observed"
        , "def identity():"
        , "    value=node_identity(node)"
        , "    if value is None: reject('identity-observe')"
        , "    return value"
        , "def running(container_identity):"
        , "    value=one_line(command([runtime,'inspect','-f','{{.State.Running}}',container_identity]),'running-observe')"
        , "    if value not in ('true','false'): reject('running-value')"
        , "    return value == 'true'"
        , "def current_identity():"
        , "    if not list_cluster(): return None"
        , "    return identity()"
        , "def declared_nodes():"
        , "    try: count=int(extra[0]); values=extra[1:]"
        , "    except Exception: reject('node-arguments')"
        , "    if count < 1 or len(values) != count or len(set(values)) != count or any(not safe_name(value) for value in values): reject('node-arguments')"
        , "    return values"
        , "def observe_nodes(names): return {node_name:node_identity(node_name) for node_name in names}"
        , "def replacement_token(expected_nodes,observed_nodes):"
        , "    for node_name in sorted(expected_nodes):"
        , "        if observed_nodes.get(node_name) != expected_nodes[node_name]:"
        , "            observed=observed_nodes.get(node_name) or 'absent'"
        , "            return observed if node_name == node else node_name+':'+observed"
        , "    return None"
        , "def require_record(expected_owner,expected_identity=None):"
        , "    retained=open_record_retained(False); data,fd,record_identity,record_raw=retained"
        , "    if expected_owner and data['owner'] != expected_owner: reject('foreign-origin')"
        , "    if data['state'] != 'managed': reject('outcome-unknown')"
        , "    binding=expected_binding()"
        , "    if binding is None: reject('expected-binding')"
        , "    binding_identity,binding_state,binding_lock,binding_record,binding_nonce=binding"
        , "    if expected_identity is not None and binding_identity != expected_identity: reject('expected-identity-mismatch')"
        , "    if data['identity'] != binding_identity or tuple(data['state_directory']) != binding_state or tuple(data['lock']) != binding_lock or record_identity != binding_record or data['nonce'] != binding_nonce: reject('record-identity-mismatch')"
        , "    return data,fd,record_identity,record_raw"
        , "def open_absolute_regular(path,stage):"
        , "    if not os.path.isabs(path) or os.path.normpath(path) != path: reject(stage+'-path')"
        , "    parent_path=os.path.dirname(path); leaf=os.path.basename(path)"
        , "    if not leaf or leaf in ('.','..'): reject(stage+'-path')"
        , "    parent=open_absolute_directory(parent_path,stage+'-parent')"
        , "    try: before=os.stat(leaf,dir_fd=parent,follow_symlinks=False)"
        , "    except OSError: reject(stage+'-observe')"
        , "    try: fd=os.open(leaf,os.O_RDONLY|os.O_NOFOLLOW|getattr(os,'O_NONBLOCK',0),dir_fd=parent)"
        , "    except OSError: reject(stage+'-open')"
        , "    finally: os.close(parent)"
        , "    info=os.fstat(fd)"
        , "    if file_identity(before) != file_identity(info): reject(stage+'-raced')"
        , "    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022 or info.st_nlink != 1: reject(stage+'-foreign')"
        , "    return fd"
        , "def config_bytes():"
        , "    if not config_path and not config_digest: return None"
        , "    if not config_path or len(config_digest) != 64 or any(ch not in '0123456789abcdef' for ch in config_digest): reject('config-binding')"
        , "    fd=open_absolute_regular(config_path,'config')"
        , "    try:"
        , "        raw=read_all(fd,1048576)"
        , "    finally: os.close(fd)"
        , "    if hashlib.sha256(raw).hexdigest() != config_digest: reject('config-drift')"
        , "    return raw"
        , "def snapshot_config(raw):"
        , "    if raw is None: return None,None,None,None"
        , "    stage,stage_identity=stage_bytes(raw,'config',1048576)"
        , "    retained=open_relative_retained(stage,1048576,False); fd,observed,retained_identity=retained"
        , "    if observed != raw or retained_identity != stage_identity: reject('config-snapshot-readback')"
        , "    return descriptor_path(fd),stage,stage_identity,fd"
        , "def descriptor_path(fd):"
        , "    prefix='/proc/self/fd' if os.path.isdir('/proc/self/fd') else '/dev/fd'"
        , "    path=prefix+'/'+str(fd)"
        , "    if not os.path.exists(path): reject('descriptor-path')"
        , "    return path"
        , "def snapshot_kubeconfig(data):"
        , "    stage=record_name+'.kube-'+data['nonce']"
        , "    try: fd=os.open(stage,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory)"
        , "    except OSError: reject('kube-stage-create')"
        , "    info=os.fstat(fd); validate_regular(info,'kube-stage'); os.fsync(fd); sync_directory()"
        , "    return descriptor_path(fd),stage,file_identity(info),fd"
        , "def open_bound_snapshot(binding,kind,limit,allow_missing):"
        , "    if binding is None: return None"
        , "    flags=(os.O_RDWR if kind == 'kube' else os.O_RDONLY)|os.O_NOFOLLOW|getattr(os,'O_NONBLOCK',0)"
        , "    try: fd=os.open(binding['name'],flags,dir_fd=directory)"
        , "    except FileNotFoundError:"
        , "        if allow_missing: return None"
        , "        reject(kind+'-snapshot-missing')"
        , "    except OSError: reject(kind+'-snapshot-open')"
        , "    info=os.fstat(fd); validate_regular(info,kind+'-snapshot'); observed_identity=file_identity(info)"
        , "    try: path_info=os.lstat(binding['name'],dir_fd=directory)"
        , "    except OSError: reject(kind+'-snapshot-path')"
        , "    if observed_identity != tuple(binding['identity']) or file_identity(path_info) != observed_identity: reject(kind+'-snapshot-identity')"
        , "    raw=read_all(fd,limit); after=os.fstat(fd); validate_regular(after,kind+'-snapshot')"
        , "    if file_identity(after) != observed_identity: reject(kind+'-snapshot-identity')"
        , "    if kind == 'config' and hashlib.sha256(raw).hexdigest() != binding['digest']: reject('config-snapshot-digest')"
        , "    os.lseek(fd,0,os.SEEK_SET)"
        , "    return descriptor_path(fd),binding['name'],observed_identity,fd,raw"
        , "def open_bound_snapshots(data,allow_missing):"
        , "    config_open=open_bound_snapshot(data.get('config_snapshot'),'config',1048576,allow_missing)"
        , "    kube_open=open_bound_snapshot(data['kube_snapshot'],'kube',1048576,allow_missing)"
        , "    return config_open,kube_open"
        , "def close_bound_snapshots(opened):"
        , "    for entry in opened:"
        , "        if entry is not None: os.close(entry[3])"
        , "def remove_bound_snapshot(binding,opened):"
        , "    if binding is None: return"
        , "    if opened is None: return"
        , "    _path,name,observed_identity,fd,_raw=opened"
        , "    info=os.fstat(fd); validate_regular(info,'snapshot')"
        , "    if file_identity(info) != observed_identity or observed_identity != tuple(binding['identity']): reject('snapshot-identity')"
        , "    try: path_info=os.lstat(name,dir_fd=directory)"
        , "    except OSError: reject('snapshot-path')"
        , "    if file_identity(path_info) != observed_identity: reject('snapshot-raced')"
        , "    if 'digest' in binding:"
        , "        os.lseek(fd,0,os.SEEK_SET)"
        , "        if hashlib.sha256(read_all(fd,1048576)).hexdigest() != binding['digest']: reject('config-snapshot-digest')"
        , "    os.close(fd); unlink_exact(name,observed_identity)"
        , "def remove_bound_snapshots(data,opened):"
        , "    config_open,kube_open=opened"
        , "    remove_bound_snapshot(data.get('config_snapshot'),config_open)"
        , "    remove_bound_snapshot(data['kube_snapshot'],kube_open)"
        , "def require_bound_snapshots_absent(data):"
        , "    for binding in (data.get('config_snapshot'),data.get('kube_snapshot')):"
        , "        if binding is None: continue"
        , "        try: os.lstat(binding['name'],dir_fd=directory)"
        , "        except FileNotFoundError: continue"
        , "        except OSError: reject('snapshot-observe')"
        , "        reject('managed-transition-snapshot-present')"
        , "def managed_data(data,observed,observed_nodes):"
        , "    managed=dict(data); managed['state']='managed'; managed['identity']=observed; managed['nodes']=observed_nodes"
        , "    managed.pop('config_snapshot',None); managed.pop('kube_snapshot',None)"
        , "    return managed"
        , "def reconcile():"
        , "    raw_config=config_bytes(); expected_config=config_digest or None; names=declared_nodes()"
        , "    retained=open_record_retained(True); data=retained[0] if retained is not None else None; present=list_cluster()"
        , "    if data is None and present:"
        , "        observed=identity(); finish('FOREIGN '+observed)"
        , "    if data is None:"
        , "        data={'version':1,'name':name,'owner':owner,'nonce':secrets.token_hex(32),'origin':'absent','config':expected_config,'state':'prepared','state_directory':list(state_identity),'lock':list(lock_identity)}"
        , "        publish_initial(data)"
        , "        retained=open_record_retained(False)"
        , "    data,record_fd,record_identity,record_raw=retained"
        , "    if data['owner'] != owner: reject('foreign-origin')"
        , "    if data['config'] != expected_config: reject('config-binding-mismatch')"
        , "    if data['state'] == 'managed':"
        , "        if not present: reject('owned-cluster-absent')"
        , "        if set(data['nodes']) != set(names): reject('record-node-set')"
        , "        observed_nodes=observe_nodes(names); replacement=replacement_token(data['nodes'],observed_nodes)"
        , "        if replacement is not None: finish('UNHEALTHY '+replacement)"
        , "        if running(data['identity']): finish('HEALTHY '+' '.join(binding_words(data,record_identity)))"
        , "        finish('UNHEALTHY '+data['identity'])"
        , "    if data['state'] == 'prepared' and present: reject('outcome-unknown')"
        , "    if data['state'] == 'prepared':"
        , "        snapshot,stage,stage_identity,snapshot_fd=snapshot_config(raw_config)"
        , "        kube_snapshot,kube_stage,kube_stage_identity,kube_fd=snapshot_kubeconfig(data)"
        , "        executing=dict(data); executing['state']='executing'"
        , "        executing['config_snapshot']=None if stage is None else {'name':stage,'identity':list(stage_identity),'digest':expected_config}"
        , "        executing['kube_snapshot']={'name':kube_stage,'identity':list(kube_stage_identity)}"
        , "        executing,record_fd,record_identity,record_raw=replace_record(executing,record_fd,record_identity,record_raw)"
        , "        opened=((snapshot,stage,stage_identity,snapshot_fd,raw_config) if stage is not None else None,(kube_snapshot,kube_stage,kube_stage_identity,kube_fd,b''))"
        , "        data=executing"
        , "    else: opened=open_bound_snapshots(data,present)"
        , "    if present:"
        , "        close_bound_snapshots(opened)"
        , "        observed_nodes=observe_nodes(names)"
        , "        if any(value is None for value in observed_nodes.values()): reject('recover-node-absent')"
        , "        observed=observed_nodes.get(node)"
        , "        if observed is None: reject('recover-control-plane-absent')"
        , "        remove_bound_snapshots(data,open_bound_snapshots(data,True))"
        , "        managed=managed_data(data,observed,observed_nodes)"
        , "        managed,record_fd,record_identity,record_raw=replace_record(managed,record_fd,record_identity,record_raw)"
        , "        if running(observed): finish('HEALTHY '+' '.join(binding_words(managed,record_identity)))"
        , "        finish('UNHEALTHY '+observed)"
        , "    snapshot_open,kube_open=opened"
        , "    if kube_open is None: reject('kube-snapshot-missing')"
        , "    snapshot=snapshot_open[0] if snapshot_open is not None else None; snapshot_fd=snapshot_open[3] if snapshot_open is not None else None"
        , "    kube_snapshot=kube_open[0]; kube_fd=kube_open[3]"
        , "    try: os.ftruncate(kube_fd,0); os.lseek(kube_fd,0,os.SEEK_SET); os.fsync(kube_fd)"
        , "    except OSError: reject('kube-snapshot-reset')"
        , "    args=[driver,'create','cluster','--name',name]"
        , "    if snapshot is not None: args += ['--config',snapshot]"
        , "    args += ['--kubeconfig',kube_snapshot]"
        , "    inherited=tuple(fd for fd in (snapshot_fd,kube_fd) if fd is not None)"
        , "    validate_frame(); validate_retained(record_name,record_fd,record_identity,record_raw)"
        , "    created=command(args,timeout=180,extra_fds=inherited)"
        , "    if created.returncode != 0: close_bound_snapshots(opened); reject('create')"
        , "    try: os.fsync(kube_fd); os.lseek(kube_fd,0,os.SEEK_SET); kube_bytes=read_all(kube_fd,1048576)"
        , "    except OSError: close_bound_snapshots(opened); reject('kubeconfig-readback')"
        , "    if not kube_bytes: close_bound_snapshots(opened); reject('kubeconfig-empty')"
        , "    if not list_cluster(): reject('create-settle-absent')"
        , "    observed_nodes=observe_nodes(names)"
        , "    if any(value is None for value in observed_nodes.values()): reject('create-settle-node-absent')"
        , "    observed=observed_nodes.get(node)"
        , "    if observed is None: reject('create-settle-control-plane-absent')"
        , "    remove_bound_snapshots(data,opened)"
        , "    managed=managed_data(data,observed,observed_nodes)"
        , "    managed,record_fd,record_identity,record_raw=replace_record(managed,record_fd,record_identity,record_raw)"
        , "    finish('CREATED '+' '.join(binding_words(managed,record_identity)))"
        , "def cordon():"
        , "    data,record_fd,record_identity,record_raw=require_record(owner,expected)"
        , "    try: count=int(extra[0]); values=extra[1:]"
        , "    except Exception: reject('cordon-arguments')"
        , "    if count < 1 or len(values) != count*8: reject('cordon-arguments')"
        , "    groups=[values[offset:offset+8] for offset in range(0,len(values),8)]"
        , "    names=[args[-1] for args in groups]"
        , "    if len(set(names)) != count or set(names) != set(data['nodes']): reject('cordon-node-set')"
        , "    observed_nodes=observe_nodes(names); replacement=replacement_token(data['nodes'],observed_nodes)"
        , "    if replacement is not None: finish('REPLACED '+replacement)"
        , "    validate_retained(record_name,record_fd,record_identity,record_raw)"
        , "    for args in groups:"
        , "        if args[0] != 'update': reject('cordon-arguments')"
        , "        validate_frame(); validate_retained(record_name,record_fd,record_identity,record_raw)"
        , "        applied=command([runtime]+args[:-1]+[data['nodes'][args[-1]]])"
        , "        if applied.returncode != 0: reject('cordon-apply')"
        , "    validate_retained(record_name,record_fd,record_identity,record_raw)"
        , "    validate_frame()"
        , "    after_nodes=observe_nodes(names); replacement=replacement_token(data['nodes'],after_nodes)"
        , "    if replacement is not None: finish('REPLACED '+replacement)"
        , "    finish('APPLIED')"
        , "def readiness():"
        , "    names=declared_nodes(); data,record_fd,record_identity,record_raw=require_record(owner,expected)"
        , "    if set(data['nodes']) != set(names): reject('readiness-node-binding')"
        , "    observed_nodes=observe_nodes(names); replacement=replacement_token(data['nodes'],observed_nodes)"
        , "    if replacement is not None: finish('NOTREADY '+replacement)"
        , "    if not running(data['identity']): finish('NOTREADY '+data['identity'])"
        , "    kube=command([driver,'get','kubeconfig','--name',name])"
        , "    if kube.returncode != 0 or kube.stderr or not kube.stdout.endswith('\\n') or '\\r' in kube.stdout: reject('kubeconfig')"
        , "    api=command([kubectl,'--kubeconfig=/dev/stdin','get','--raw=/readyz'],kube.stdout)"
        , "    if api.returncode != 0 or api.stderr: finish('NOTREADY '+data['identity'])"
        , "    nodes=command([kubectl,'--kubeconfig=/dev/stdin','get','nodes','-o','json'],kube.stdout)"
        , "    if nodes.returncode != 0 or nodes.stderr or not nodes.stdout.endswith('\\n') or '\\r' in nodes.stdout: reject('node-query')"
        , "    try: decoded=json.loads(nodes.stdout)"
        , "    except Exception: reject('node-decode')"
        , "    items=decoded.get('items') if isinstance(decoded,dict) else None"
        , "    if not isinstance(items,list) or any(not isinstance(item,dict) for item in items): reject('node-shape')"
        , "    kube_names=[item.get('metadata',{}).get('name') for item in items]"
        , "    if any(not isinstance(value,str) for value in kube_names) or len(kube_names) != len(set(kube_names)) or set(kube_names) != set(names): finish('NOTREADY '+data['identity'])"
        , "    ready=all(any(condition.get('type') == 'Ready' and condition.get('status') == 'True' for condition in item.get('status',{}).get('conditions',[]) if isinstance(condition,dict)) for item in items)"
        , "    validate_retained(record_name,record_fd,record_identity,record_raw)"
        , "    validate_frame()"
        , "    after_nodes=observe_nodes(names); replacement=replacement_token(data['nodes'],after_nodes)"
        , "    if replacement is not None: finish('NOTREADY '+replacement)"
        , "    finish(('READY ' if ready else 'NOTREADY ')+data['identity'])"
        , "def cleanup():"
        , "    names=declared_nodes(); retained=open_record_retained(True); data=retained[0] if retained is not None else None; present=list_cluster(); observed_nodes=observe_nodes(names)"
        , "    if data is None:"
        , "        visible=next((value for value in observed_nodes.values() if value is not None),None)"
        , "        if visible is not None: finish('REPLACED '+visible)"
        , "        if present: reject('cluster-present-without-node')"
        , "        finish('REMOVED')"
        , "    data,record_fd,record_identity,record_raw=retained"
        , "    if data['owner'] != owner: reject('foreign-origin')"
        , "    if data['state'] != 'managed': reject('outcome-unknown')"
        , "    if set(data['nodes']) != set(names): reject('cleanup-node-binding')"
        , "    binding=expected_binding()"
        , "    if binding is None: reject('expected-binding')"
        , "    binding_identity,binding_state,binding_lock,binding_record,binding_nonce=binding"
        , "    if data['identity'] != binding_identity or tuple(data['state_directory']) != binding_state or tuple(data['lock']) != binding_lock or record_identity != binding_record or data['nonce'] != binding_nonce: reject('record-identity-mismatch')"
        , "    replacements=[(node_name,value) for node_name,value in observed_nodes.items() if value is not None and value != data['nodes'][node_name]]"
        , "    if replacements: finish('REPLACED '+(replacements[0][1] if replacements[0][0] == node else replacements[0][0]+':'+replacements[0][1]))"
        , "    exact_present=[node_name for node_name,value in observed_nodes.items() if value == data['nodes'][node_name]]"
        , "    if not present:"
        , "        if exact_present: reject('owned-nodes-without-cluster')"
        , "        validate_frame(); remove_record(record_fd,record_identity,record_raw); finish('REMOVED')"
        , "    if len(exact_present) != len(names): reject('owned-node-absent')"
        , "    validate_retained(record_name,record_fd,record_identity,record_raw)"
        , "    validate_frame()"
        , "    deleted=command([driver,'delete','cluster','--name',name],timeout=180)"
        , "    if deleted.returncode != 0: reject('delete')"
        , "    after_present=list_cluster(); after_nodes=observe_nodes(names)"
        , "    replacements=[(node_name,value) for node_name,value in after_nodes.items() if value is not None and value != data['nodes'][node_name]]"
        , "    if replacements: finish('REPLACED '+(replacements[0][1] if replacements[0][0] == node else replacements[0][0]+':'+replacements[0][1]))"
        , "    if after_present or any(value == data['nodes'][node_name] for node_name,value in after_nodes.items()): reject('delete-settle-present')"
        , "    validate_frame()"
        , "    remove_record(record_fd,record_identity,record_raw); finish('REMOVED')"
        , "try:"
        , "    flock,state,name,operation,driver,runtime,kubectl,tool_path,owner,config_path,config_digest,expected,expected_state_device,expected_state_inode,expected_lock_device,expected_lock_inode,expected_record_device,expected_record_inode,expected_nonce,*extra=sys.argv[1:]"
        , "    if not safe_name(name): reject('cluster-name')"
        , "    if not tool_path or any(not os.path.isabs(part) for part in tool_path.split(os.pathsep)): reject('tool-path')"
        , "    child_environment={'PATH':tool_path,'HOME':'/nonexistent','XDG_CONFIG_HOME':'/nonexistent','TMPDIR':'/tmp','LANG':'C','LC_ALL':'C','DOCKER_HOST':'unix:///var/run/docker.sock','DOCKER_CONTEXT':'default','KIND_EXPERIMENTAL_PROVIDER':'docker'}"
        , "    operations={'reconcile':reconcile,'cordon':cordon,'readiness':readiness,'cleanup':cleanup}"
        , "    if operation not in operations: reject('operation')"
        , "    binding=expected_binding(); allow_create=operation == 'reconcile'"
        , "    if allow_create and binding is not None: reject('unexpected-binding')"
        , "    if not allow_create and binding is None: reject('expected-binding')"
        , "    directory=secure_state(state,allow_create); state_identity=file_identity(os.fstat(directory)); record_name=name+'.cluster.origin'; lock_name=name+'.cluster.lock'; node=name+'-control-plane'"
        , "    if binding is not None and state_identity != binding[1]: reject('state-identity-mismatch')"
        , "    lock,lock_identity=open_lock(directory,lock_name,allow_create)"
        , "    if binding is not None and lock_identity != binding[2]: reject('lock-identity-mismatch')"
        , "    try: acquired=subprocess.run([flock,'-w','30','-x',str(lock)],pass_fds=(lock,),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=35,env=child_environment,cwd='/')"
        , "    except subprocess.TimeoutExpired: reject('lock-timeout')"
        , "    except OSError: reject('lock-exec')"
        , "    if acquired.returncode != 0 or acquired.stdout or acquired.stderr: reject('lock-acquire')"
        , "    validate_frame()"
        , "    if allow_create: cleanup_stages()"
        , "    else: refuse_stages()"
        , "    operations[operation]()"
        , "except ProtocolError as failure: finish('FAILED '+str(failure))"
        , "except SystemExit: raise"
        , "except Exception: finish('FAILED internal')"
        ]

parseReconcileReport :: ClusterCommandResult -> ClusterReconcileObservation
parseReconcileReport result
    | not (clusterCommandOk result) =
        ClusterProbeFailed
            ( "the exclusive-entry cluster command failed: "
                <> firstLineText (clusterCommandStderr result)
            )
    | otherwise = case protocolWords result of
        Just ("CREATED" : binding) -> maybe (ClusterProbeFailed "invalid CREATED backend binding") ClusterCreated (parseBackendBinding binding)
        Just ("HEALTHY" : binding) -> maybe (ClusterProbeFailed "invalid HEALTHY backend binding") ClusterHealthy (parseBackendBinding binding)
        Just ["FOREIGN", identity] -> ClusterForeign (Text.pack identity)
        Just ["UNHEALTHY", identity] -> ClusterUnhealthy (Text.pack identity)
        Just ("FAILED" : rest) ->
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
    ClusterCleanupObservation
parseCleanupReport key result
    | not (clusterCommandOk result) =
        ClusterCleanupFailed
            ( Failure
                ( FailureDetail
                    "clean up cluster"
                    ( "the exclusive-entry cluster command failed: "
                        <> firstLineText (clusterCommandStderr result)
                    )
                    ReprobeBeforeRetry
                )
            )
    | otherwise = case protocolWords result of
        Just ["REMOVED"] -> ClusterCleanupRemoved
        Just ["REPLACED", identity] -> ClusterCleanupReplaced (Text.pack identity)
        Just ("FAILED" : rest) ->
            ClusterCleanupFailed
                ( Failure
                    ( FailureDetail
                        "clean up cluster"
                        ( "the locked cluster backend refused to delete "
                            <> key
                            <> ": "
                            <> Text.pack (unwords rest)
                        )
                        ReprobeBeforeRetry
                    )
                )
        _ ->
            ClusterCleanupFailed
                ( Failure
                    ( FailureDetail
                        "clean up cluster"
                        ( "unparseable backend report: "
                            <> firstLineText (clusterCommandStdout result)
                        )
                        DoNotRetry
                    )
                )

parseCordonReport :: ClusterCommandResult -> ClusterCordonObservation
parseCordonReport result
    | not (clusterCommandOk result) =
        ClusterCordonFailed
            ("the lock-held cordon command failed: " <> firstLineText (clusterCommandStderr result))
    | otherwise = case protocolWords result of
        Just ["APPLIED"] -> ClusterCordonApplied
        Just ["REPLACED", identity] -> ClusterCordonReplaced (Text.pack identity)
        Just ("FAILED" : rest) -> ClusterCordonFailed (Text.pack (unwords rest))
        _ ->
            ClusterCordonFailed
                ("unparseable lock-held cordon report: " <> firstLineText (clusterCommandStdout result))

protocolWords :: ClusterCommandResult -> Maybe [String]
protocolWords result
    | not (null (clusterCommandStderr result)) = Nothing
    | otherwise =
        case clusterCommandStdout result of
            [] -> Nothing
            output
                | last output /= '\n' || '\r' `elem` output -> Nothing
                | otherwise ->
                    case init output of
                        line | '\n' `notElem` line && not (null line) -> Just (words line)
                        _ -> Nothing

parseBackendBinding :: [String] -> Maybe ClusterBackendBinding
parseBackendBinding [identity, stateDevice, stateInode, lockDevice, lockInode, recordDevice, recordInode, nonce]
    | not (null identity)
        && not (any (`elem` (" \t\r\n" :: String)) identity)
        && length nonce == 64
        && all (\character -> character >= '0' && character <= '9' || character >= 'a' && character <= 'f') nonce =
        ClusterBackendBinding
            (Text.pack identity)
            <$> readMaybe stateDevice
            <*> readMaybe stateInode
            <*> readMaybe lockDevice
            <*> readMaybe lockInode
            <*> readMaybe recordDevice
            <*> readMaybe recordInode
            <*> pure (Text.pack nonce)
parseBackendBinding _ = Nothing

firstLine :: String -> String
firstLine value = case lines value of
    (l : _) -> l
    [] -> ""

firstLineText :: String -> Text
firstLineText = Text.pack . firstLine

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
