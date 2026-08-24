{-# LANGUAGE LambdaCase #-}

{- | A cluster driver, container runtime, and API server this suite drives, as
one real process.

§ KK admits one effect vocabulary and one interpreter for it, and § NN admits
evidence only from applying total functions to values or from real processes
doing real work. There is therefore no runner to inject: a suite that wants the
driver to have answered a particular way supplies a program the interpreter can
launch, and that program is __this suite's own executable__.

One program serves all three tools, because the argument vector says which one it
is being asked as. That is not a shortcut — it is the same property the described
commands are built on: a vector that could be read as belonging to two tools
would be a vector the driver could send to the wrong one.

Everything it answers from is durable, because the client is a second process: a
cluster a create established has to still be there when the next command asks
about it, and a fixture that kept it in the parent would be asserting about its
own memory rather than about what a tool reported.

A vector this module does not recognize is a refusal rather than a silent
success, so a driver that starts asking for something new fails a fixture instead
of passing through it.
-}
module FakeCluster (
    -- * Entering the role
    fakeClusterVariable,
    withFakeClusterClient,
    runFakeClusterClient,

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
    fixtureNodeIdentity,
    armReplacementAfter,
    armApiUnready,
    armHelmNoChanges,
    armHelmMalformed,
    armHelmCleanupMalformed,
    armRolloutRefusal,
    armCreateRefusal,
    replacementIdentity,
    crashAfterCreatePath,
) where

import Control.Exception (bracket_)
import Control.Monad (forM_, when)
import Data.List (intercalate, isPrefixOf, isSuffixOf, stripPrefix)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Environment (setEnv, unsetEnv)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, readFile', stderr)

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
    writeClusters root []
    writeNodes root []
    writeRelays root []
    writeFile (root </> "next-host-port") "41000"
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
readRelays root = read <$> readFile' (relaysPath root)

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

kubeconfigPathsPath :: FilePath -> FilePath
kubeconfigPathsPath root = root </> "kubeconfig-paths"

{- | The identifier this fixture's runtime mints for one node name.

Exposed so a case can predict the identity a binding will carry without reading
the fixture back, which is what makes "the identity bound is the one the runtime
answered" an equality rather than a shrug.
-}
fixtureNodeIdentity :: String -> String
fixtureNodeIdentity = nodeIdentity . freshNode

-- ---------------------------------------------------------------------------
-- Serving one command

-- | Serve one cluster command, as a process the one interpreter launched.
runFakeClusterClient :: FilePath -> [String] -> IO ()
runFakeClusterClient root argv = case argv of
    -- The cluster driver
    ["--quiet", "get", "clusters"] -> readClusters root >>= mapM_ putStrLn
    ["--quiet", "get", "kubeconfig", "--name", name] -> do
        present <- readClusters root
        if name `elem` present
            then putStrLn ("apiVersion: v1\nclusters: [" <> name <> "]")
            else refuse ("no cluster named " <> name)
    ("--quiet" : "create" : "cluster" : "--name" : name : rest) -> do
        present <- readClusters root
        recordKubeconfig root rest
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
    ["--quiet", "delete", "cluster", "--name", name] -> do
        present <- readClusters root
        held <- readNodes root
        writeClusters root (filter (/= name) present)
        writeNodes root (filter (not . (nodePrefix name `isPrefixOf`) . fst) held)
        recordMutation root "delete"
        replaceIfArmed root "delete" (name <> "-control-plane")
    -- The container runtime
    ["container", "ls", "--all", "--quiet", "--no-trunc", "--filter", filterArg] ->
        case stripAnchoredName filterArg of
            Just name -> do
                held <- readNodes root
                relays <- readRelays root
                case (lookup name held, [relay | relay <- relays, relayName relay == name]) of
                    (Just node, _) -> putStrLn (nodeIdentity node)
                    (Nothing, [relay]) -> putStrLn (relayIdentity relay)
                    (Nothing, []) -> pure ()
                    _ -> refuse "duplicate relay names"
                replaceIfArmed root "listing" name
            Nothing -> case stripPrefix "id=" filterArg of
                Just identity -> do
                    held <- readNodes root
                    relays <- readRelays root
                    mapM_ putStrLn ([nodeIdentity node | (_, node) <- held, nodeIdentity node == identity] <> [relayIdentity relay | relay <- relays, relayIdentity relay == identity])
                Nothing -> refuse ("unrecognized container filter " <> filterArg)
    ("container" : "run" : rest) -> createRelay root rest
    ["container", "rm", "--force", identity] -> do
        relays <- readRelays root
        if any ((== identity) . relayIdentity) relays
            then do
                writeRelays root (filter ((/= identity) . relayIdentity) relays)
                putStrLn identity
                recordMutation root "relay-delete"
            else refuse ("no such relay " <> identity)
    ["inspect", "--format", template, identity]
        | "{{\"\\n\"}}" `isSuffixOf` template -> refuse "the relay format duplicates the runtime record terminator"
        | otherwise ->
            readRelays root >>= \relays -> case [relay | relay <- relays, relayIdentity relay == identity] of
                [relay] -> renderRelay relay
                [] -> refuse ("no such relay " <> identity)
                _ -> refuse "duplicate relay identities"
    ["inspect", "-f", "{{.Id}}", reference] ->
        nodeReferenced root reference >>= \case
            Nothing -> refuse ("no such container " <> reference)
            Just node -> putStrLn (nodeIdentity node)
    ["inspect", "-f", "{{.State.Running}}", reference] ->
        nodeReferenced root reference >>= \case
            Nothing -> refuse ("no such container " <> reference)
            Just node -> putStrLn (if nodeRunning node then "true" else "false")
    ("update" : rest)
        | not (null rest) -> do
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
    -- The API server
    ["--kubeconfig=/dev/stdin", "get", "--raw=/readyz"] -> do
        unready <- doesFileExist (apiUnreadyPath root)
        if unready
            then do
                removeFile (apiUnreadyPath root)
                refuse "the control plane is not ready yet"
            else putStr "ok"
    ["--kubeconfig=/dev/stdin", "get", "nodes", "-o", "json"] -> do
        held <- readNodes root
        putStrLn (nodeDocument [(name, nodeRunning node) | (name, node) <- held])
        case held of
            [] -> pure ()
            ((name, _) : _) -> replaceIfArmed root "nodes" name
    ["--kubeconfig", _kubeconfig, "upgrade", "--install", release, _artifact, "--namespace", _namespace, "--create-namespace=false", "--values", "-", "--set-string", _image, "--rollback-on-failure", "--wait"] -> do
        let noChanges = root </> "helm-no-changes"
            malformed = root </> "helm-malformed"
            installed = root </> ("helm-release-" <> release)
        ifM
            (doesFileExist noChanges)
            (removeFile noChanges >> putStrLn "no changes")
            ( ifM
                (doesFileExist malformed)
                ( do
                    removeFile malformed
                    putStrLn ("Release \"" <> release <> "\" does not exist. Installing it now.")
                    putStrLn ("NAME: " <> release)
                    putStrLn "STATUS: deployed"
                    putStrLn "REVISION: 1"
                )
                ( do
                    alreadyInstalled <- doesFileExist installed
                    writeFile installed "installed\n"
                    if alreadyInstalled
                        then putStrLn ("Release \"" <> release <> "\" has been upgraded")
                        else do
                            putStrLn ("Release \"" <> release <> "\" does not exist. Installing it now.")
                            putStrLn ("NAME: " <> release)
                            putStrLn "LAST DEPLOYED: Thu Jan  1 00:00:00 1970"
                            putStrLn "NAMESPACE: fixture"
                            putStrLn "STATUS: deployed"
                            putStrLn "REVISION: 1"
                            putStrLn "DESCRIPTION: Install complete"
                )
            )
    ["--kubeconfig", _kubeconfig, "rollout", "status", "--namespace", _namespace, target, "--timeout=5m"]
        | "deployment/" `isPrefixOf` target -> do
            let refusal = root </> "rollout-refusal"
            ifM
                (doesFileExist refusal)
                (removeFile refusal >> refuse "deployment did not become ready")
                (putStrLn "deployment successfully rolled out")
    ["--kubeconfig", _kubeconfig, "uninstall", release, "--namespace", _namespace, "--wait"] -> do
        let malformed = root </> "helm-cleanup-malformed"
            installed = root </> ("helm-release-" <> release)
        ifM
            (doesFileExist malformed)
            (removeFile malformed >> putStrLn "unfamiliar uninstall success")
            ( do
                present <- doesFileExist installed
                if present
                    then removeFile installed >> putStrLn ("release \"" <> release <> "\" uninstalled")
                    else refuse ("release " <> release <> " not found")
            )
    ["--kubeconfig", _kubeconfig, "status", release, "--namespace", _namespace] -> do
        present <- doesFileExist (root </> ("helm-release-" <> release))
        if present then putStrLn "deployed" else refuse ("release " <> release <> " not found")
    _ -> refuse ("the cluster fixture does not recognize " <> show argv)

createRelay :: FilePath -> [String] -> IO ()
createRelay root arguments = case parseRelayRun arguments of
    Left reason -> refuse reason
    Right (name, labels, listeners) -> do
        relays <- readRelays root
        if any ((== name) . relayName) relays
            then refuse ("a relay named " <> name <> " already exists")
            else do
                nextPort <- read <$> readFile' (root </> "next-host-port")
                let identity = replicate 56 'e' <> padNumber (length relays + 1)
                    mappings = [(listener, "127.0.0.1", nextPort + offset) | (offset, listener) <- zip [0 ..] listeners]
                writeFile (root </> "next-host-port") (show (nextPort + length listeners))
                writeRelays root (FakeRelay identity name labels mappings : relays)
                recordMutation root "relay-create"
                putStrLn identity
  where
    padNumber number = replicate (8 - length rendered) '0' <> rendered
      where
        rendered = show number

parseRelayRun :: [String] -> Either String (String, [(String, String)], [Int])
parseRelayRun ("--detach" : "--name" : name : rest) = flags [] [] rest
  where
    flags labels listeners ("--label" : assignment : remaining) = case break (== '=') assignment of
        (key, '=' : value) -> flags ((key, value) : labels) listeners remaining
        _ -> Left "malformed relay label"
    flags labels listeners ("--network" : "kind" : remaining) = flags labels listeners remaining
    flags labels listeners ("--publish" : mapping : remaining) = case reads (takeWhile (/= '/') (drop (length ("127.0.0.1::" :: String)) mapping)) of
        [(listener, "")] | "127.0.0.1::" `isPrefixOf` mapping -> flags labels (listener : listeners) remaining
        _ -> Left "malformed relay publication"
    flags labels listeners (_image : "__hostbootstrap-exposure-relay-v1" : relayArgs) = do
        declared <- relayListeners relayArgs
        if reverse listeners == declared
            then Right (name, reverse labels, declared)
            else Left "relay arguments and publications differ"
    flags _ _ _ = Left "malformed relay run"

    relayListeners [] = Right []
    relayListeners (_service : listener : _target : _port : remaining) = case reads listener of
        [(parsed, "")] -> (parsed :) <$> relayListeners remaining
        _ -> Left "malformed relay listener"
    relayListeners _ = Left "malformed relay target tuple"
parseRelayRun _ = Left "malformed relay run prefix"

renderRelay :: FakeRelay -> IO ()
renderRelay relay = do
    putStrLn (relayIdentity relay)
    putStrLn ('/' : relayName relay)
    mapM_ (putStrLn . labelValue) ["io.hostbootstrap.owner", "io.hostbootstrap.cluster", "io.hostbootstrap.generation", "io.hostbootstrap.operation", "io.hostbootstrap.spec"]
    putStrLn
        ( "{"
            <> intercalate "," [show (show listener <> "/tcp") <> ":[{\"HostIp\":" <> show address <> ",\"HostPort\":" <> show (show hostPort) <> "}]" | (listener, address, hostPort) <- relayMappings relay]
            <> "}"
        )
  where
    labelValue key = maybe "<no value>" id (lookup key (relayLabels relay))

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
            Just (init rest)
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
    hPutStrLn stderr reason
    exitWith (ExitFailure 1)

ifM :: (Monad monad) => monad Bool -> monad value -> monad value -> monad value
ifM condition whenTrue whenFalse = condition >>= \answer -> if answer then whenTrue else whenFalse
