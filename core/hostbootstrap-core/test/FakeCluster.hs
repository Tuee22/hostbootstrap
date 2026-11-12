{-# LANGUAGE LambdaCase #-}

{- | Authored cluster-tool protocol models for fixture compatibility.

The child executable reads and writes this fixture's own files. Its Kind,
Docker, kubectl and Helm answers are authored here; running those answers in a
separate process does not make them provider execution evidence under section NN.
Pure production classifications, actual protected-store kernel operations and
the real Docker/Kind cluster-live gate establish their respective subjects.

Each modeled tool has its own executable name. A vector addressed to the wrong
tool is refused before fixture state changes, and unrecognized vectors remain
refusals. These checks validate this fixture's routing and modeled sequencing.
The fixture runs on every gate host; it makes no claim about that host's real
cluster tools.
-}
module FakeCluster (
    -- * Entering the role
    fakeClusterVariable,
    withFakeClusterClient,
    runFakeClusterClient,
    prepareFixtureExecutables,
    fixtureToolPath,

    -- * Declaring the fixture
    newClusterFixture,
    declareNodes,

    -- * What the tools hold
    ClusterNode (..),
    readClusters,
    writeClusters,
    readNodes,
    writeNodes,
    FakeRelay (..),
    readRelays,
    writeRelays,
    recordedClusterMutations,
    recordedKubeconfigPaths,
    recordedConfigFiles,
    fixtureKubeconfig,
    fixtureNodeIdentity,
    armReplacementAfter,
    armApiUnready,
    armHelmNoChanges,
    armHelmMalformed,
    armHelmCleanupMalformed,
    armRolloutRefusal,
    armCreateRefusal,
    armDeleteRefusal,
    armDeleteThenRefusal,
    armDeleteNoop,
    armUpdateRefusal,
    armUpdateStderr,
    armRelayRemovalRefusal,
    armRelayPullProgress,
    armRelayNullPorts,
    armRelayStoppedOnCreate,
    armBareRelayBlock,
    replacementIdentity,
    crashAfterCreatePath,
) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket_)
import Control.Monad (forM_, unless, when)
import qualified Data.ByteString as ByteString
import Data.List (isInfixOf, intercalate, isPrefixOf, isSuffixOf, stripPrefix)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import System.Directory (copyFile, copyPermissions, createDirectoryIfMissing, doesFileExist, listDirectory, removeFile)
import System.Environment (getExecutablePath, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.FilePath (takeBaseName, takeDirectory, takeExtension, takeFileName, (</>))
import System.IO (Handle, readFile', stderr, stdout)

-- ---------------------------------------------------------------------------
-- Entering the role

{- | The variable that tells a child of this suite it is a cluster client.

Named rather than positional because the argument vector is not this fixture's
to shape: it is exactly what the described command carries.
-}
fakeClusterVariable :: String
fakeClusterVariable = "HOSTBOOTSTRAP_FAKE_CLUSTER_ROOT"

-- | Hold the variable for exactly the span in which this suite is a cluster tool.
withFakeClusterClient :: FilePath -> IO result -> IO result
withFakeClusterClient root =
    bracket_ (setEnv fakeClusterVariable root) (unsetEnv fakeClusterVariable)

-- | Place distinct tool-named copies in this fixture's own temporary directory.
-- The returned template selects that directory and the host executable suffix.
prepareFixtureExecutables :: FilePath -> IO FilePath
prepareFixtureExecutables root = do
    executable <- getExecutablePath
    let directory = root </> "tool-bin"
        template = directory </> takeFileName executable
    createDirectoryIfMissing True directory
    forM_ ["kind", "nvkind", "docker", "kubectl", "helm"] $ \tool -> do
        let target = fixtureToolPath template tool
        present <- doesFileExist target
        unless present (copyFile executable target >> copyPermissions executable target)
    pure template

-- | The actual tool filename beside one fixture's executable template.
fixtureToolPath :: FilePath -> String -> FilePath
fixtureToolPath template tool = takeDirectory template </> (tool <> takeExtension template)

-- ---------------------------------------------------------------------------
-- Declaring the fixture

-- | One node container this fixture's runtime currently holds.
data ClusterNode = ClusterNode
    { nodeIdentity :: String
    , nodeRunning :: Bool
    , nodeLimits :: [String]
    }
    deriving (Eq, Read, Show)

data FakeRelay = FakeRelay
    { relayIdentity :: String
    , relayName :: String
    , relayLabels :: [(String, String)]
    , relayMappings :: [(Int, String, Int)]
    , relayRunning :: Bool
    , relayTargets :: [(String, Int, String, Int)]
    , relayNullPorts :: [Int]
    }
    deriving (Eq, Read, Show)

{- | Lay down one fixture root, empty of clusters and of history.

The declared node set is a fixture input rather than something derived from the
configuration path, because what a real driver reads out of a configuration
snapshot is a topology and a fixture that guessed at one from a filename would be
asserting about the guess.
-}
newClusterFixture :: FilePath -> [String] -> IO FilePath
newClusterFixture root nodes = do
    createDirectoryIfMissing True root
    writeFile (clusterMutationsPath root) ""
    writeFile (kubeconfigPathsPath root) ""
    writeFile (root </> "config-files") ""
    writeClusters root []
    writeNodes root []
    writeRelays root []
    writeFile (root </> "next-host-port") "41000"
    writeFile (root </> "next-relay-identity") "1"
    declareNodes root nodes
    pure root

-- | Declare which node containers one creation establishes.
declareNodes :: FilePath -> [String] -> IO ()
declareNodes root = writeFile (declaredNodesPath root) . show

declaredNodesPath :: FilePath -> FilePath
declaredNodesPath root = root </> "declared-nodes"

clustersPath :: FilePath -> FilePath
clustersPath root = root </> "clusters"

nodesPath :: FilePath -> FilePath
nodesPath root = root </> "nodes"

relaysPath :: FilePath -> FilePath
relaysPath root = root </> "relays"

clusterMutationsPath :: FilePath -> FilePath
clusterMutationsPath root = root </> "cluster-mutations"

{- | Arm the client to die after a create it has already performed.

The outcome-unknown window between a mutation and its report is the one a resumed
transaction exists for, and the only honest way to reach it is a client that
really did the thing and really did not say so.
-}
crashAfterCreatePath :: FilePath -> FilePath
crashAfterCreatePath root = root </> "crash-after-create"

{- | Arm the API server to refuse its own readiness endpoint once.

A control plane that has not come up is a legitimate answer rather than a fault,
and the only honest way to see the driver treat it as one is to have the server
really refuse.
-}
armApiUnready :: FilePath -> IO ()
armApiUnready root = writeFile (apiUnreadyPath root) "once\n"

armHelmNoChanges, armHelmMalformed, armHelmCleanupMalformed, armRolloutRefusal :: FilePath -> IO ()
armHelmNoChanges root = writeFile (root </> "helm-no-changes") "once\n"
armHelmMalformed root = writeFile (root </> "helm-malformed") "once\n"
armHelmCleanupMalformed root = writeFile (root </> "helm-cleanup-malformed") "once\n"
armRolloutRefusal root = writeFile (root </> "rollout-refusal") "once\n"

apiUnreadyPath :: FilePath -> FilePath
apiUnreadyPath root = root </> "api-unready"

{- | Arm the driver to refuse a create without performing it.

The standing in which clause 2 is durable and nothing else ever happened is not
reachable by writing durable state behind the driver's back -- it is what a real
refusal leaves -- so the fixture reaches it by having the driver really refuse.
-}
armCreateRefusal :: FilePath -> IO ()
armCreateRefusal root = writeFile (refuseCreatePath root) "once\n"

armDeleteRefusal :: FilePath -> IO ()
armDeleteRefusal root = writeFile (root </> "delete-refusal") "once\n"

armDeleteThenRefusal :: FilePath -> IO ()
armDeleteThenRefusal root = writeFile (root </> "delete-then-refusal") "once\n"

armDeleteNoop :: FilePath -> IO ()
armDeleteNoop root = writeFile (root </> "delete-noop") "once\n"

armUpdateRefusal, armUpdateStderr :: FilePath -> IO ()
armUpdateRefusal root = writeFile (root </> "update-refusal") "once\n"
armUpdateStderr root = writeFile (root </> "update-stderr") "once\n"

armRelayRemovalRefusal, armRelayPullProgress, armRelayNullPorts, armRelayStoppedOnCreate :: FilePath -> IO ()
armRelayRemovalRefusal root = writeFile (root </> "relay-removal-refusal") "once\n"
armRelayPullProgress root = writeFile (root </> "relay-pull-progress") "once\n"
armRelayNullPorts root = writeFile (root </> "relay-null-ports") "once\n"
armRelayStoppedOnCreate root = writeFile (root </> "relay-start-stopped") "once\n"

armBareRelayBlock :: FilePath -> IO ()
armBareRelayBlock root = writeFile (root </> "bare-relay-block") "armed\n"


consumeRelayArm :: FilePath -> String -> IO Bool
consumeRelayArm root name = do
    let path = root </> name
    armed <- doesFileExist path
    when armed (removeFile path)
    pure armed

refuseCreatePath :: FilePath -> FilePath
refuseCreatePath root = root </> "refuse-create"

{- | Arm the runtime to put a different container at a node's name after one verb.

A test process cannot reach the window between a command a driver issued and the
observation it takes afterwards, because the transaction holds the store's
exclusive entry throughout; the tool can, because it is the thing being asked.
The arming is one-shot, so a case names the exact command after which the name
stops being its own.
-}
armReplacementAfter :: FilePath -> String -> IO ()
armReplacementAfter root verb = writeFile (replaceAfterPath root verb) "once\n"

replaceAfterPath :: FilePath -> String -> FilePath
replaceAfterPath root verb = root </> ("replace-after-" <> verb)

-- | The identity a replacement carries, so a case compares against one value.
replacementIdentity :: String
replacementIdentity = replicate 63 'f' <> "1"

readClusters :: FilePath -> IO [String]
readClusters root = read <$> readFile' (clustersPath root)

writeClusters :: FilePath -> [String] -> IO ()
writeClusters root = writeFile (clustersPath root) . show

readNodes :: FilePath -> IO [(String, ClusterNode)]
readNodes root = read <$> readFile' (nodesPath root)

writeNodes :: FilePath -> [(String, ClusterNode)] -> IO ()
writeNodes root = writeFile (nodesPath root) . show

readRelays :: FilePath -> IO [FakeRelay]
readRelays root = do
    existing <- read <$> readFile' (relaysPath root)
    names <- filter (isPrefixOf "bare-relay-state-") <$> listDirectory root
    bare <- traverse (fmap read . readFile' . (root </>)) names
    pure (existing <> bare)

writeRelays :: FilePath -> [FakeRelay] -> IO ()
writeRelays root = writeFile (relaysPath root) . show

-- | The mutating verbs this fixture's tools performed, in order.
recordedClusterMutations :: FilePath -> IO [String]
recordedClusterMutations root = lines <$> readFile' (clusterMutationsPath root)

{- | Where every creation this fixture served was told to write its credential.

Recorded because a kubeconfig is the one thing a creating command writes outside
this fixture's own state, and a driver told to write it somewhere the transaction
does not already own would be leaking a live credential.
-}
recordedKubeconfigPaths :: FilePath -> IO [String]
recordedKubeconfigPaths root = lines <$> readFile' (kubeconfigPathsPath root)

-- | Actual config paths and bytes read by each creating client process.
recordedConfigFiles :: FilePath -> IO [(FilePath, ByteString.ByteString)]
recordedConfigFiles root = map read . lines <$> readFile' (root </> "config-files")

kubeconfigPathsPath :: FilePath -> FilePath
kubeconfigPathsPath root = root </> "kubeconfig-paths"

{- | The identifier this fixture's runtime mints for one node name.

Exposed so a case can predict the identity a binding will carry without reading
the fixture back, which is what makes "the identity bound is the one the runtime
answered" an equality rather than a shrug.
-}
fixtureNodeIdentity :: String -> String
fixtureNodeIdentity = nodeIdentity . freshNode

-- | The exact complete credential body the fake Kind client reports.
fixtureKubeconfig :: String -> String
fixtureKubeconfig name = "apiVersion: v1\nclusters: [" <> name <> "]\n"

-- ---------------------------------------------------------------------------
-- Serving one command

-- | Serve one cluster command, as a process the one interpreter launched.
runFakeClusterClient :: FilePath -> [String] -> IO ()
runFakeClusterClient root argv = do
    actual <- takeBaseName <$> getExecutablePath
    case fixtureToolFamily argv of
        Just expected | actual /= expected ->
            refuse ("fixture wrong tool: expected " <> expected <> ", got " <> actual)
        _ -> serveFakeClusterClient root argv

-- | Classification of this fixture's own supported vector families.
fixtureToolFamily :: [String] -> Maybe String
fixtureToolFamily ("--quiet" : arguments) = fixtureToolFamily arguments
fixtureToolFamily ("get" : _) = Just "kind"
fixtureToolFamily ("create" : "cluster" : _) = Just "kind"
fixtureToolFamily ("delete" : "cluster" : _) = Just "kind"
fixtureToolFamily ("cluster" : "create" : _) = Just "nvkind"
fixtureToolFamily ("--kubeconfig" : _ : command : _)
    | command `elem` ["upgrade", "uninstall", "status"] = Just "helm"
    | otherwise = Just "kubectl"
fixtureToolFamily (argument : _)
    | "--kubeconfig=" `isPrefixOf` argument = Just "kubectl"
    | argument `elem` ["container", "inspect", "update", "image", "pull"] = Just "docker"
fixtureToolFamily _ = Nothing

serveFakeClusterClient :: FilePath -> [String] -> IO ()
serveFakeClusterClient root ("--quiet" : arguments) =
    -- Fixture compatibility only; this supplies no provider execution evidence.
    bracket_ (setEnv "HOSTBOOTSTRAP_FAKE_CLUSTER_QUIET" "1") (unsetEnv "HOSTBOOTSTRAP_FAKE_CLUSTER_QUIET")
        (serveFakeClusterClient root arguments)
serveFakeClusterClient root argv = case argv of
    -- The cluster driver
    ["get", "clusters"] -> readClusters root >>= mapM_ emitLine
    ["get", "kubeconfig", "--name", name] -> do
        present <- readClusters root
        if name `elem` present
            then writeUtf8 stdout (fixtureKubeconfig name)
            else refuse ("no cluster named " <> name)
    ("create" : "cluster" : "--name" : name : rest) -> do
        present <- readClusters root
        recordKubeconfig root rest
        recordConfig root rest
        refusing <- doesFileExist (refuseCreatePath root)
        if refusing
            then do
                removeFile (refuseCreatePath root)
                refuse "the cluster client refused the create it was asked for"
            else
                if name `elem` present
                    then refuse ("a cluster named " <> name <> " already exists")
                    else do
                        declared <- readDeclaredNodes root
                        writeClusters root (name : present)
                        held <- readNodes root
                        writeNodes root ([(node, freshNode node) | node <- declared] <> held)
                        recordMutation root "create"
                        forM_ declared (replaceIfArmed root "create")
                        armed <- doesFileExist (crashAfterCreatePath root)
                        when armed $ do
                            removeFile (crashAfterCreatePath root)
                            refuse "the cluster client died after the create it performed"
    ["delete", "cluster", "--name", name] -> do
        refusing <- consumeRelayArm root "delete-refusal"
        when refusing (refuse "the cluster client refused the delete it was asked for")
        noOp <- consumeRelayArm root "delete-noop"
        if noOp
            then recordMutation root "delete"
            else do
                present <- readClusters root
                held <- readNodes root
                writeClusters root (filter (/= name) present)
                writeNodes root (filter (not . (nodePrefix name `isPrefixOf`) . fst) held)
                recordMutation root "delete"
                replaceIfArmed root "delete" (name <> "-control-plane")
                failedAfter <- consumeRelayArm root "delete-then-refusal"
                when failedAfter (refuse "the modeled delete completed before its client refused")
    -- The container runtime
    ["container", "ls", "--all", "--quiet", "--no-trunc", "--filter", filterArg] ->
        case stripAnchoredName filterArg of
            Just name -> do
                held <- readNodes root
                relays <- readRelays root
                case (lookup name held, [relay | relay <- relays, relayName relay == name]) of
                    (Just node, _) -> emitLine (nodeIdentity node)
                    (Nothing, [relay]) -> emitLine (relayIdentity relay)
                    (Nothing, []) -> pure ()
                    _ -> refuse "duplicate relay names"
                replaceIfArmed root "listing" name
            Nothing -> case stripPrefix "id=" filterArg of
                Just identity -> do
                    held <- readNodes root
                    relays <- readRelays root
                    mapM_ emitLine ([nodeIdentity node | (_, node) <- held, nodeIdentity node == identity] <> [relayIdentity relay | relay <- relays, relayIdentity relay == identity])
                Nothing -> refuse ("unrecognized container filter " <> filterArg)
    ["inspect", "--format", "{{.Image}}", name]
        | "-control-plane" `isSuffixOf` name -> emitLine "sha256:bare-fixture-image"
    ["container", "ls", "--all", "--quiet", "--filter", filterArg] ->
        case stripAnchoredName filterArg of
            Just name -> do
                present <- doesFileExist (root </> ("bare-relay-state-" <> name))
                when present (emitLine name)
            Nothing -> refuse "unrecognized bare relay name filter"
    ("container" : "run" : "--detach" : "--name" : name : "--publish" : "127.0.0.1::20000/tcp" : "--entrypoint" : "/bin/sleep" : _image : "infinity" : []) -> do
        let relay = FakeRelay (replicate 64 'a') name [] [(20000, "127.0.0.1", 43123)] True [] []
        writeFile (root </> ("bare-relay-state-" <> name)) (show relay)
        blocked <- doesFileExist (root </> "bare-relay-block")
        when blocked (threadDelay 120000000)
        emitLine (relayIdentity relay)
    ("container" : "run" : rest) -> createRelay root rest
    ["container", "rm", "--force", identity] -> do
        refusing <- consumeRelayArm root "relay-removal-refusal"
        when refusing (refuse "the runtime refused relay removal")
        let barePath = root </> ("bare-relay-state-" <> identity)
        barePresent <- doesFileExist barePath
        if barePresent
            then removeFile barePath >> emitLine identity
            else do
                relays <- readRelays root
                if any ((== identity) . relayIdentity) relays
                    then do
                        writeRelays root (filter ((/= identity) . relayIdentity) relays)
                        emitLine identity
                        recordMutation root "relay-delete"
                    else refuse ("no such relay " <> identity)
    ["inspect", "--format", template, identity]
        | "{{\"\\n\"}}" `isSuffixOf` template -> refuse "the relay format duplicates the runtime record terminator"
        | not ("{{.State.Running}}" `isInfixOf` template) -> refuse "relay inspection omits running state"
        | otherwise ->
            readRelays root >>= \relays -> case [relay | relay <- relays, relayIdentity relay == identity] of
                [relay] -> renderRelay relay
                [] -> refuse ("no such relay " <> identity)
                _ -> refuse "duplicate relay identities"
    ["inspect", "-f", "{{.Id}}", reference] ->
        nodeReferenced root reference >>= \case
            Nothing -> refuse ("no such container " <> reference)
            Just node -> emitLine (nodeIdentity node)
    ["inspect", "-f", "{{.State.Running}}", reference] ->
        nodeReferenced root reference >>= \case
            Nothing -> refuse ("no such container " <> reference)
            Just node -> emitLine (if nodeRunning node then "true" else "false")
    ("update" : rest)
        | not (null rest) -> do
            refusing <- consumeRelayArm root "update-refusal"
            when refusing (refuse "the cluster runtime refused the update")
            let identifier = last rest
                limits = init rest
            nodeNamed root identifier >>= \case
                Nothing -> refuse ("no such container " <> identifier)
                Just (name, node) -> do
                    held <- readNodes root
                    writeNodes
                        root
                        [ (key, if key == name then node{nodeLimits = limits} else current)
                        | (key, current) <- held
                        ]
                    recordMutation root "update"
                    replaceIfArmed root "update" name
                    noisy <- consumeRelayArm root "update-stderr"
                    when noisy (writeUtf8 stderr "the cluster runtime emitted update stderr\n")
    -- The API server
    ["--kubeconfig=/dev/stdin", "get", "--raw=/readyz"] -> do
        unready <- doesFileExist (apiUnreadyPath root)
        if unready
            then do
                removeFile (apiUnreadyPath root)
                refuse "the control plane is not ready yet"
            else writeUtf8 stdout "ok"
    ["--kubeconfig=/dev/stdin", "get", "nodes", "-o", "json"] -> do
        held <- readNodes root
        emitLine (nodeDocument [(name, nodeRunning node) | (name, node) <- held])
        case held of
            [] -> pure ()
            ((name, _) : _) -> replaceIfArmed root "nodes" name
    ["--kubeconfig", _kubeconfig, "upgrade", "--install", release, _artifact, "--namespace", _namespace, "--create-namespace=false", "--values", "-", "--set-string", _image, "--rollback-on-failure", "--wait"] -> do
        let noChanges = root </> "helm-no-changes"
            malformed = root </> "helm-malformed"
            installed = root </> ("helm-release-" <> release)
        ifM
            (doesFileExist noChanges)
            (removeFile noChanges >> emitLine "no changes")
            ( ifM
                (doesFileExist malformed)
                ( do
                    removeFile malformed
                    emitLine ("Release \"" <> release <> "\" does not exist. Installing it now.")
                    emitLine ("NAME: " <> release)
                    emitLine "STATUS: deployed"
                    emitLine "REVISION: 1"
                )
                ( do
                    alreadyInstalled <- doesFileExist installed
                    writeFile installed "installed\n"
                    if alreadyInstalled
                        then emitLine ("Release \"" <> release <> "\" has been upgraded")
                        else do
                            emitLine ("Release \"" <> release <> "\" does not exist. Installing it now.")
                            emitLine ("NAME: " <> release)
                            emitLine "LAST DEPLOYED: Thu Jan  1 00:00:00 1970"
                            emitLine "NAMESPACE: fixture"
                            emitLine "STATUS: deployed"
                            emitLine "REVISION: 1"
                            emitLine "DESCRIPTION: Install complete"
                )
            )
    ["--kubeconfig", _kubeconfig, "rollout", "status", "--namespace", _namespace, target, "--timeout=5m"]
        | "deployment/" `isPrefixOf` target -> do
            let refusal = root </> "rollout-refusal"
            ifM
                (doesFileExist refusal)
                (removeFile refusal >> refuse "deployment did not become ready")
                (emitLine "deployment successfully rolled out")
    ["--kubeconfig", _kubeconfig, "uninstall", release, "--namespace", _namespace, "--wait"] -> do
        let malformed = root </> "helm-cleanup-malformed"
            installed = root </> ("helm-release-" <> release)
        ifM
            (doesFileExist malformed)
            (removeFile malformed >> emitLine "unfamiliar uninstall success")
            ( do
                present <- doesFileExist installed
                if present
                    then removeFile installed >> emitLine ("release \"" <> release <> "\" uninstalled")
                    else refuse ("release " <> release <> " not found")
            )
    ["--kubeconfig", _kubeconfig, "status", release, "--namespace", _namespace] -> do
        present <- doesFileExist (root </> ("helm-release-" <> release))
        if present then emitLine "deployed" else refuse ("release " <> release <> " not found")
    _ -> refuse ("the cluster fixture does not recognize " <> show argv)

createRelay :: FilePath -> [String] -> IO ()
createRelay root arguments = case parseRelayRun arguments of
    Left reason -> refuse reason
    Right (name, labels, targets) -> do
        relays <- readRelays root
        if any ((== name) . relayName) relays
            then refuse ("a relay named " <> name <> " already exists")
            else do
                nextPort <- read <$> readFile' (root </> "next-host-port")
                identityIndex <- read <$> readFile' (root </> "next-relay-identity")
                nullPorts <- consumeRelayArm root "relay-null-ports"
                pullProgress <- consumeRelayArm root "relay-pull-progress"
                stopped <- consumeRelayArm root "relay-start-stopped"
                let identity = replicate 56 'e' <> padNumber (identityIndex :: Int)
                    listeners = [listener | (_, listener, _, _) <- targets]
                    mappings = [(listener, "127.0.0.1", nextPort + offset) | (offset, listener) <- zip [0 ..] listeners]
                    relay = FakeRelay identity name labels (if stopped then [] else mappings) (not stopped) targets (if nullPorts then [8080] else [])
                writeFile (root </> "next-host-port") (show (nextPort + length listeners))
                writeFile (root </> "next-relay-identity") (show (identityIndex + 1))
                writeRelays root (relay : relays)
                recordMutation root "relay-create"
                when pullProgress (writeUtf8 stderr "Pulling relay image\nDigest: fixture-image\n")
                emitLine identity
  where
    padNumber number = replicate (8 - length rendered) '0' <> rendered
      where
        rendered = show number

parseRelayRun :: [String] -> Either String (String, [(String, String)], [(String, Int, String, Int)])
parseRelayRun ("--detach" : "--quiet" : "--name" : name : rest) = flags False [] [] rest
  where
    flags network labels listeners ("--label" : assignment : remaining) = case break (== '=') assignment of
        (key, '=' : value) -> flags network ((key, value) : labels) listeners remaining
        _ -> Left "malformed relay label"
    flags False labels listeners ("--network" : "kind" : remaining) = flags True labels listeners remaining
    flags network labels listeners ("--publish" : mapping : remaining)
        | Just raw <- stripPrefix "127.0.0.1::" mapping
        , "/tcp" `isSuffixOf` raw = case reads (take (length raw - 4) raw) of
            [(listener, "")] | validPort listener -> flags network labels (listener : listeners) remaining
            _ -> Left "malformed relay publication"
    flags True labels listeners (_image : "__hostbootstrap-exposure-relay-v1" : relayArgs) = do
        targets <- relayTargetsFromArgs relayArgs
        if reverse listeners == [listener | (_, listener, _, _) <- targets]
            then Right (name, reverse labels, targets)
            else Left "relay arguments and publications differ"
    flags _ _ _ _ = Left "malformed relay run or missing kind network"

    relayTargetsFromArgs [] = Right []
    relayTargetsFromArgs (service : listener : host : port : remaining) = case (reads listener, reads port) of
        ([(parsedListener, "")], [(parsedPort, "")])
            | validPort parsedListener && validPort parsedPort && not (null service) && not (null host) ->
                ((service, parsedListener, host, parsedPort) :) <$> relayTargetsFromArgs remaining
        _ -> Left "malformed relay target"
    relayTargetsFromArgs _ = Left "malformed relay target tuple"
    validPort port = port > 0 && port < 65536
parseRelayRun _ = Left "malformed relay run prefix"

renderRelay :: FakeRelay -> IO ()
renderRelay relay = do
    emitLine (relayIdentity relay)
    emitLine ('/' : relayName relay)
    mapM_ (emitLine . labelValue) ["io.hostbootstrap.owner", "io.hostbootstrap.cluster", "io.hostbootstrap.generation", "io.hostbootstrap.operation", "io.hostbootstrap.spec"]
    emitLine (if relayRunning relay then "true" else "false")
    emitLine ("{" <> intercalate "," (published <> unpublished) <> "}")
  where
    labelValue key = maybe "<no value>" id (lookup key (relayLabels relay))
    mappings = if relayRunning relay then relayMappings relay else []
    published = [show (show listener <> "/tcp") <> ":[{\"HostIp\":" <> show address <> ",\"HostPort\":" <> show (show hostPort) <> "}]" | (listener, address, hostPort) <- mappings]
    unpublished = [show (show port <> "/tcp") <> ":null" | port <- relayNullPorts relay]

-- ---------------------------------------------------------------------------
-- What the fixture holds

-- | The node names one creation establishes, as the fixture declared them.
readDeclaredNodes :: FilePath -> IO [String]
readDeclaredNodes root = read <$> readFile' (declaredNodesPath root)

freshNode :: String -> ClusterNode
freshNode node =
    ClusterNode
        { nodeIdentity = take 64 (concatMap identityDigit node <> repeat '0')
        , nodeRunning = True
        , nodeLimits = []
        }

{- | One container identifier, derived from the node's name.

Sixty-four hex characters, as a runtime mints, and a function of the name so a
case can predict it without reading the fixture back.
-}
identityDigit :: Char -> String
identityDigit character =
    let code = fromEnum character `mod` 256
     in [hexDigit (code `div` 16), hexDigit (code `mod` 16)]

hexDigit :: Int -> Char
hexDigit value
    | value < 10 = toEnum (fromEnum '0' + value)
    | otherwise = toEnum (fromEnum 'a' + value - 10)

nodePrefix :: String -> String
nodePrefix name = name <> "-"

stripAnchoredName :: String -> Maybe String
stripAnchoredName value = case value of
    'n' : 'a' : 'm' : 'e' : '=' : '^' : '/' : rest
        | not (null rest)
        , last rest == '$' ->
            unquote (init rest)
    _ -> Nothing
  where
    unquote encoded = case stripPrefix "\\." encoded of
        Just rest -> ('.' :) <$> unquote rest
        Nothing -> case encoded of
            [] -> Just []
            character : rest
                | character `elem` ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" :: String) ->
                    (character :) <$> unquote rest
            _ -> Nothing

{- | The node one reference names, by its own name or by its identifier.

A runtime accepts either, and the driver deliberately uses the name: asking the
name again is what makes a container replaced between the listing and the
readback answer differently.
-}
nodeReferenced :: FilePath -> String -> IO (Maybe ClusterNode)
nodeReferenced root reference = do
    held <- readNodes root
    pure $ case lookup reference held of
        Just node -> Just node
        Nothing -> lookup reference [(nodeIdentity node, node) | (_, node) <- held]

nodeNamed :: FilePath -> String -> IO (Maybe (String, ClusterNode))
nodeNamed root identifier =
    lookup identifier . map (\(name, node) -> (nodeIdentity node, (name, node))) <$> readNodes root

nodeDocument :: [(String, Bool)] -> String
nodeDocument nodes = "{\"items\":[" <> commaSeparated (map item nodes) <> "]}"
  where
    item (name, ready) =
        "{\"metadata\":{\"name\":\""
            <> name
            <> "\"},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\""
            <> (if ready then "True" else "False")
            <> "\"}]}}"
    commaSeparated values = case values of
        [] -> ""
        (first : rest) -> foldl (\acc value -> acc <> "," <> value) first rest

recordMutation :: FilePath -> String -> IO ()
recordMutation root verb = appendFile (clusterMutationsPath root) (verb <> "\n")

{- | Note where a creating command was told to put its kubeconfig.

Recorded before the create is decided, because the argument vector is a fact
about what was asked regardless of whether the driver went on to accept it.
-}
recordKubeconfig :: FilePath -> [String] -> IO ()
recordKubeconfig root arguments = case arguments of
    ("--kubeconfig" : path : _) -> appendFile (kubeconfigPathsPath root) (path <> "\n")
    (_ : rest) -> recordKubeconfig root rest
    [] -> pure ()

recordConfig :: FilePath -> [String] -> IO ()
recordConfig root arguments = case arguments of
    ("--config" : path : _) -> do
        bytes <- ByteString.readFile path
        appendFile (root </> "config-files") (show (path, bytes) <> "\n")
    (_ : rest) -> recordConfig root rest
    [] -> pure ()

-- | Put a different container at one node's name, if this verb was armed for it.
replaceIfArmed :: FilePath -> String -> String -> IO ()
replaceIfArmed root verb name = do
    armed <- doesFileExist (replaceAfterPath root verb)
    when armed $ do
        removeFile (replaceAfterPath root verb)
        held <- readNodes root
        case lookup name held of
            Just node ->
                writeNodes
                    root
                    ((name, node{nodeIdentity = replacementIdentity}) : filter ((/= name) . fst) held)
            Nothing ->
                writeNodes
                    root
                    ( (name, ClusterNode replacementIdentity True [])
                        : held
                    )

refuse :: String -> IO ()
refuse reason = do
    quiet <- lookupEnv "HOSTBOOTSTRAP_FAKE_CLUSTER_QUIET"
    when (quiet /= Just "1") (writeUtf8 stderr (reason <> "\n"))
    exitWith (ExitFailure 1)

ifM :: (Monad monad) => monad Bool -> monad value -> monad value -> monad value
ifM condition whenTrue whenFalse = condition >>= \answer -> if answer then whenTrue else whenFalse

-- Protocol fixtures emit UTF-8 bytes with their declared LF terminators.
-- Text handles translate newlines on Windows and would change the wire.
writeUtf8 :: Handle -> String -> IO ()
writeUtf8 handle = ByteString.hPut handle . TextEncoding.encodeUtf8 . Text.pack

emitLine :: String -> IO ()
emitLine = writeUtf8 stdout . (<> "\n")
