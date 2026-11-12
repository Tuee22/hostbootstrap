{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | A stand-in client for the provider CLI vectors these fixtures consume.

The compiled test executable serves instance listings, configuration reads,
launch/start/stop/restart/delete, disk-device calls, image-info probes and
@exec <name> -- <argv>@. Its Docker role records argv and applies the exact
command policy its fixture declares. Unrecognized Incus vectors refuse. It does not implement
the lift's @exec <vm> --cwd / -T --@ leaf.

Durable files carry the stand-in's instances and received commands across
processes. This exercises the interpreter's subprocess protocol and the real
protected store; it does not establish Incus/KVM behavior. The provider-live
component owns that confirmation.
-}
module FakeProvider (
    -- * Entering the role
    fakeProviderVariable,
    withFakeProviderClient,
    GuestHandler,
    runFakeProviderClient,
    aliasGuest,
    localGuestAliasSupported,

    -- * Declaring the fixture
    ProviderBehaviour (..),
    newProviderFixture,
    newDockerFixture,
    newGuestVmFixture,
    requireGuestVmRecord,
    limaInstanceDirectory,
    setLimaConfigValue,
    replaceLimaDirectory,
    failLimaCreatePath,
    changeLimaClaimPath,
    replaceLimaParentPath,
    guestVmScriptPath,

    -- * What the provider holds
    ProviderInstance (..),
    readInstances,
    writeInstances,
    instanceNamed,
    alterInstance,

    -- * What the fixture observed
    providerFixtureRoot,
    guestInvocationsPath,
    providerMutationsPath,
    providerToolStatePath,
    crashAfterLaunchPath,
    crashAfterDeletePath,
    stopLeavesRunningPath,
    armReplacementAfter,
    replacementIdentity,
    recordedProviderCommands,
    providerCommandsPath,
    listingFailurePath,
    recordedProviderMutations,
) where

import Control.Exception (bracket)
import Control.Monad (when)
import Data.Aeson (Value (Object), eitherDecodeStrict', encode, object, withObject, (.:), (.=))
import qualified Data.Aeson.Types as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as AesonMap
import HostBootstrap.Cluster.Cordon.Foundation (budgetCpu, budgetMemoryBytes, budgetStorageBytes)
import HostBootstrap.Substrate.Provider.Report (providerSizingBudget, providerReportFaultMessage)
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.ByteString as ByteString
import Data.List (isPrefixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Handoff.Transaction (classifyFrameChild)
#ifndef mingw32_HOST_OS
import HostBootstrap.Ownership.Row (hostOwnershipSupported)
#endif
import HostBootstrap.Substrate.Provider (RawProviderOutcome (..))
import HostBootstrap.Substrate.Provider.Command (
    ProviderSizing (ProviderSizing),
    providerIdentityConfigKey,
    providerOwnerConfigKey,
 )
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist, removeFile, renameDirectory)
import System.Environment (getExecutablePath, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)
import System.FilePath ((</>))
import System.IO (Handle, readFile', stderr, stdout)
import System.Process (CreateProcess (std_in, std_out, std_err), StdStream (Inherit), proc, waitForProcess, withCreateProcess)

-- | Run the shipped guest argv as a real local child. Inherited protocol
-- pipes preserve the streaming exchange with the production crossing.
aliasGuest :: GuestHandler
aliasGuest _root _name _role ["true"] = pure (RawProviderExit ExitSuccess "" "")
aliasGuest _root _name _role ["findmnt", "-n", "-o", "FSTYPE", "--mountpoint", _] =
    pure (RawProviderExit ExitSuccess "virtiofs\n" "")
aliasGuest _root _name _role ["test", "-w", _] = pure (RawProviderExit ExitSuccess "" "")
aliasGuest _root _name _role (guestSelf : arguments)
    | guestSelf == "/usr/local/bin/hostbootstrap-demo"
    , Just _ <- classifyFrameChild arguments = do
        executable <- getExecutablePath
        code <-
            withCreateProcess
                ((proc executable arguments){std_in = Inherit, std_out = Inherit, std_err = Inherit})
                (\_ _ _ child -> waitForProcess child)
        pure (RawProviderExit code "" "")
aliasGuest _root _name _role arguments =
    pure (RawProviderFailure ("the alias guest fixture received an unknown vector: " <> show arguments))

localGuestAliasSupported :: Bool
#ifdef mingw32_HOST_OS
localGuestAliasSupported = False
#else
localGuestAliasSupported = hostOwnershipSupported
#endif

-- ---------------------------------------------------------------------------
-- Entering the role

{- | The variable that tells a child of this suite it is a provider client.

Named rather than positional because the argument vector is not this fixture's
to shape: it is exactly what the described command carries.
-}
fakeProviderVariable :: String
fakeProviderVariable = "HOSTBOOTSTRAP_FAKE_PROVIDER_ROOT"

-- | Hold the variable for exactly the span in which this suite is a provider.
withFakeProviderClient :: FilePath -> IO result -> IO result
withFakeProviderClient root action =
    bracket
        (lookupEnv fakeProviderVariable)
        (maybe (unsetEnv fakeProviderVariable) (setEnv fakeProviderVariable))
        (\_ -> setEnv fakeProviderVariable root >> action)

{- | What answers on the far side of a crossing into the instance.

Receives the fixture root, the instance the command crossed into, the fixture's
declared role, and the guest's own argument vector.  A handler may reach back
into the provider's durable state through 'alterInstance', because some contracts
are about the instance being replaced /while/ a guest command runs, and that is a
property of the object rather than of anything the guest printed.
-}
type GuestHandler = FilePath -> String -> String -> [String] -> IO RawProviderOutcome

-- ---------------------------------------------------------------------------
-- Declaring the fixture

{- | What this fixture's provider client is able to do at all.

The raw responses distinguish a client that answers, unavailable provisioning
egress, an unclassified provisioning egress failure, and an unavailable daemon.
-}
data ProviderBehaviour
    = ProviderAnswers
    | ProviderEgressUnavailable
    | ProviderEgressFailure
    | ProviderDaemonUnavailable
    deriving (Eq, Read, Show)

{- | Lay down one fixture root, empty of instances and of history.

Returns the root, so a caller names its own directory and this module names
everything inside it.
-}
newProviderFixture :: FilePath -> String -> ProviderBehaviour -> IO FilePath
newProviderFixture root role behaviour = do
    createDirectoryIfMissing True (providerToolStatePath root)
    writeFile (guestInvocationsPath root) ""
    writeFile (providerCommandsPath root) ""
    writeFile (providerMutationsPath root) ""
    writeInstances root []
    writeFile (instanceCounterPath root) "0\n"
    writeFile (providerDescriptorPath root) (unlines [role, show behaviour])
    pure root

{- | A Docker CLI stand-in that records its received argv.

'Nothing' admits every vector; an explicit vector refuses every other one.
The return value names the joined command/argument observations. The common
provider-command file also retains each actual argument vector with Show/Read.
-}
newDockerFixture :: FilePath -> Maybe [String] -> String -> Int -> IO FilePath
newDockerFixture root allowed report status = do
    _ <- newProviderFixture root "docker" ProviderAnswers
    writeFile (dockerAnswerPath root) (show (allowed, report, status))
    let recorded = root </> "docker-invocations"
    writeFile recorded ""
    pure recorded

dockerAnswerPath :: FilePath -> FilePath
dockerAnswerPath root = root </> "docker-answer"

serveDockerClient :: FilePath -> [String] -> IO ()
serveDockerClient root argv = do
    appendFile (root </> "docker-invocations") (unwords ("docker" : argv) <> "\n")
    (allowed, report, status) <- read <$> readFile' (dockerAnswerPath root) :: IO (Maybe [String], String, Int)
    if maybe True (== argv) allowed
        then emitGuestAnswer (RawProviderExit (if status == 0 then ExitSuccess else ExitFailure status) report "")
        else refuseProviderCommand "the Docker fixture received an unexpected argument vector"

{- | A compiled guest-VM CLI with an exact sequence of raw process answers.

The script contains argv, exit status and streams only. It has no reconciliation
or ownership vocabulary; an unexpected vector or an exhausted sequence refuses.
-}
newGuestVmFixture :: FilePath -> [([String], Int, String, String)] -> IO ()
newGuestVmFixture root answers = do
    _ <- newProviderFixture root "guest-vm" ProviderAnswers
    writeFile (guestVmScriptPath root) (show answers)

guestVmScriptPath :: FilePath -> FilePath
guestVmScriptPath root = root </> "guest-vm-answers"

-- | A real file-presence observation before the stand-in installer answers.
requireGuestVmRecord :: FilePath -> FilePath -> IO ()
requireGuestVmRecord root target = writeFile (root </> "guest-vm-required-record") target

serveGuestVmClient :: FilePath -> [String] -> IO ()
serveGuestVmClient root argv = do
    required <- doesFileExist (root </> "guest-vm-required-record")
    when required $ do
        target <- readFile' (root </> "guest-vm-required-record")
        present <- doesFileExist target
        when (not present) (refuseProviderCommand "the disk-cap record was absent before installer invocation")
    answers <- read <$> readFile' (guestVmScriptPath root) :: IO [([String], Int, String, String)]
    case answers of
        ((expected, status, out, err) : remaining)
            | argv == expected -> do
                writeFile (guestVmScriptPath root) (show remaining)
                emitGuestAnswer (RawProviderExit (if status == 0 then ExitSuccess else ExitFailure status) out err)
        _ -> refuseProviderCommand ("the guest-VM fixture received an unexpected argument vector: " <> show argv)

providerFixtureRoot :: FilePath -> FilePath
providerFixtureRoot = id

providerDescriptorPath :: FilePath -> FilePath
providerDescriptorPath root = root </> "provider-descriptor"

instanceCounterPath :: FilePath -> FilePath
instanceCounterPath root = root </> "instance-counter"

providerInstancesPath :: FilePath -> FilePath
providerInstancesPath root = root </> "provider-instances"

-- | The guest argument vectors this fixture's provider dispatched, in order.
guestInvocationsPath :: FilePath -> FilePath
guestInvocationsPath root = root </> "guest-invocations"

-- | The mutating verbs this fixture's provider performed, in order.
providerMutationsPath :: FilePath -> FilePath
providerMutationsPath root = root </> "provider-mutations"

-- | A directory a guest handler may keep its own durable state in.
providerToolStatePath :: FilePath -> FilePath
providerToolStatePath root = root </> "tool-state"

{- | Arm the client to die after a launch it has already performed.

The outcome-unknown window between a mutation and its report is the one a
resumed transaction exists for, and the only honest way to reach it is a client
that really did the thing and really did not say so.
-}
crashAfterLaunchPath :: FilePath -> FilePath
crashAfterLaunchPath root = root </> "crash-after-launch"

-- | Fail the client's response after its stand-in instance has been removed.
crashAfterDeletePath :: FilePath -> FilePath
crashAfterDeletePath root = root </> "crash-after-delete"

-- | A successful stop response whose following raw listing still says running.
stopLeavesRunningPath :: FilePath -> FilePath
stopLeavesRunningPath root = root </> "stop-leaves-running"

{- | Arm the provider to put a different instance at the name after one verb.

Some contracts are about an object being replaced /inside/ a transaction, in the
window between the command a driver issued and the observation it takes
afterwards.  A test process cannot reach that window from outside, because the
transaction holds the store's exclusive entry throughout; the provider can,
because it is the thing being asked.  The arming is one-shot, so a case names the
exact command after which the name stops being its own.
-}
armReplacementAfter :: FilePath -> String -> IO ()
armReplacementAfter root verb = writeFile (replaceAfterPath root verb) "once\n"

replaceAfterPath :: FilePath -> String -> FilePath
replaceAfterPath root verb = root </> ("replace-after-" <> verb)

{- | The identity a replacement carries.

One value, so a case asserting "the replacement was left untouched" compares
against the same thing the provider put there.
-}
replacementIdentity :: String
replacementIdentity = "instance-replacement"

-- | Every raw command the real client received, including probes.
providerCommandsPath :: FilePath -> FilePath
providerCommandsPath root = root </> "provider-commands"

recordedProviderCommands :: FilePath -> IO [[String]]
recordedProviderCommands root = map read . lines <$> readFile' (providerCommandsPath root)

-- | A fixture-supplied failure for the whole-daemon listing.
listingFailurePath :: FilePath -> FilePath
listingFailurePath root = providerToolStatePath root </> "listing-failure"

recordedProviderMutations :: FilePath -> IO [String]
recordedProviderMutations root = lines <$> readFile' (providerMutationsPath root)

-- ---------------------------------------------------------------------------
-- What the provider holds

{- | What this fixture's provider currently holds about one instance.

The claim is carried separately from the identity because they answer different
questions: the identity is what the provider itself minted, and the claim is
what the creating command wrote onto the object.  A fixture that conflated them
could not produce an instance no record claims.
-}
data ProviderInstance = ProviderInstance
    { instanceRunState :: String
    , instanceIdentity :: String
    , instanceOwnerClaim :: String
    , instanceDevices :: [(String, [(String, String)])]
    , instanceDaemonAnswers :: Bool
    , instanceConfig :: [(String, String)]
    }
    deriving (Eq, Read, Show)

readInstances :: FilePath -> IO [(String, ProviderInstance)]
readInstances root = read <$> readFile' (providerInstancesPath root)

writeInstances :: FilePath -> [(String, ProviderInstance)] -> IO ()
writeInstances root = writeFile (providerInstancesPath root) . show

instanceNamed :: FilePath -> String -> IO (Maybe ProviderInstance)
instanceNamed root name = lookup name <$> readInstances root

alterInstance :: FilePath -> String -> (ProviderInstance -> ProviderInstance) -> IO ()
alterInstance root name change = do
    instances <- readInstances root
    writeInstances root [(key, if key == name then change held else held) | (key, held) <- instances]

-- ---------------------------------------------------------------------------
-- Serving one command

-- | Serve one provider command, as a process the one interpreter launched.
runFakeProviderClient :: GuestHandler -> FilePath -> [String] -> IO ()
runFakeProviderClient guest root argv = do
    appendFile (providerCommandsPath root) (show argv <> "\n")
    descriptor <- lines <$> readFile' (providerDescriptorPath root)
    case descriptor of
        ("docker" : _) -> serveDockerClient root argv
        ("guest-vm" : _) -> serveGuestVmClient root argv
        ("lima" : _) -> serveLimaClient guest root argv
        (role : declared : _) ->
            let behaviour = read declared
             in whileAnswering root behaviour $ \_ ->
                    serveProviderCommand guest root role behaviour argv
        _ -> refuseProviderCommand "the provider fixture descriptor is unreadable"

-- This role writes ordinary Lima metadata and creates actual directories.
-- The production driver, not this process, obtains kernel directory identities.
limaInstanceDirectory :: FilePath -> String -> FilePath
limaInstanceDirectory root name = root </> "lima" </> name

limaConfigPath :: FilePath -> String -> FilePath
limaConfigPath root name = limaInstanceDirectory root name </> "creation.json"

failLimaCreatePath :: FilePath -> FilePath
failLimaCreatePath root = root </> "fail-lima-create"

changeLimaClaimPath :: FilePath -> FilePath
changeLimaClaimPath root = root </> "change-lima-claim"

replaceLimaParentPath :: FilePath -> FilePath
replaceLimaParentPath root = root </> "replace-lima-parent"

replaceLimaDirectory :: FilePath -> String -> IO ()
replaceLimaDirectory root name = do
    let directory = limaInstanceDirectory root name
    -- Retaining the old directory prevents inode recycling from hiding replacement.
    renameDirectory directory (directory <> ".replaced")
    createDirectory directory
    ByteString.readFile (directory <> ".replaced" </> "creation.json")
        >>= ByteString.writeFile (limaConfigPath root name)

readLimaConfig :: FilePath -> String -> IO Value
readLimaConfig root name = do
    raw <- ByteString.readFile (limaConfigPath root name)
    either refuseProviderCommand pure (eitherDecodeStrict' raw)

-- | Change ordinary native-shaped config while retaining unrelated limits/metadata.
setLimaConfigValue :: FilePath -> String -> String -> Value -> IO ()
setLimaConfigValue root name field value = do
    current <- readLimaConfig root name
    case current of
        Object settings -> LazyByteString.writeFile (limaConfigPath root name)
            (encode (Object (AesonMap.insert (AesonKey.fromString field) value settings)))
        _ -> refuseProviderCommand "the Lima fixture config is not an object"

serveLimaClient :: GuestHandler -> FilePath -> [String] -> IO ()
serveLimaClient guest root argv = do
    scripted <- doesFileExist (guestVmScriptPath root)
    when scripted $ do
        answers <- read <$> readFile' (guestVmScriptPath root) :: IO [([String], Int, String, String)]
        case answers of
            ((expected, status, out, err) : remaining) | argv == expected -> do
                writeFile (guestVmScriptPath root) (show remaining)
                emitGuestAnswer (RawProviderExit (if status == 0 then ExitSuccess else ExitFailure status) out err)
            _ -> pure ()
    serveLimaCommand guest root argv

serveLimaCommand :: GuestHandler -> FilePath -> [String] -> IO ()
serveLimaCommand guest root argv = case argv of
    ["--log-level=error", "--tty=false", "list", "--format", "json", name] -> do
        instanceNamed root name >>= \case
            Nothing -> pure ()
            Just held -> do
                config <- readLimaConfig root name
                sizing <- either refuseProviderCommand pure (Aeson.parseEither
                    (withObject "Lima fixture config" (\settings -> ProviderSizing
                        <$> settings .: "cpus" <*> settings .: "memory" <*> settings .: "disk")) config)
                budget <- either (refuseProviderCommand . Text.unpack . providerReportFaultMessage) pure
                    (providerSizingBudget sizing)
                LazyByteString.hPut stdout (encode (object
                    [ "name" .= name, "status" .= instanceRunState held
                    , "dir" .= limaInstanceDirectory root name
                    , "cpus" .= budgetCpu budget, "memory" .= budgetMemoryBytes budget
                    , "disk" .= budgetStorageBytes budget
                    , "config" .= config, "errors" .= ([] :: [String]) ]))
        change <- doesFileExist (changeLimaClaimPath root)
        when change $ do
            removeFile (changeLimaClaimPath root)
            setLimaConfigValue root name "env"
                (object ["HOSTBOOTSTRAP_OWNER" .= ("foreign-owner" :: String)])
    ["--log-level=error", "--tty=false", "create", "--name", name, "-"] -> do
        instances <- readInstances root
        when (any ((== name) . fst) instances) (refuseProviderCommand "Instance already exists")
        failed <- doesFileExist (failLimaCreatePath root)
        when failed (refuseProviderCommand "the Lima create failed before creating anything")
        config <- ByteString.getContents
        _ <- either refuseProviderCommand pure (eitherDecodeStrict' config :: Either String Value)
        createDirectoryIfMissing True (root </> "lima")
        createDirectory (limaInstanceDirectory root name)
        ByteString.writeFile (limaConfigPath root name) config
        writeInstances root ((name, ProviderInstance "Stopped" "" "" [] True []) : instances)
        recordMutation root "lima-create"
        crashed <- doesFileExist (crashAfterLaunchPath root)
        when crashed $ do
            removeFile (crashAfterLaunchPath root)
            refuseProviderCommand "the Lima client died after creating the instance"
    ["--log-level=error", "--tty=false", "start", "--timeout", "15m", name] ->
        withInstance root name $ \_ -> do
            alterInstance root name (\held -> held{instanceRunState = "Running"})
            recordMutation root "lima-start"
            replaceLimaIfArmed "start" name
    ("shell" : name : "--" : "sudo" : "-H" : inner) ->
        withInstance root name $ \held -> do
            when (instanceRunState held /= "Running") (refuseProviderCommand "Instance is not running")
            appendFile (guestInvocationsPath root) (show inner <> "\n")
            answer <- guest root name "lima" inner
            replaceLimaIfArmed "guest" name
            parent <- doesFileExist (replaceLimaParentPath root)
            when parent $ do
                target <- readFile' (replaceLimaParentPath root)
                removeFile (replaceLimaParentPath root)
                renameDirectory target (target <> ".replaced")
                createDirectory target
            emitGuestAnswer answer
    _ -> refuseProviderCommand ("unsupported Lima command " <> show argv)
  where
    replaceLimaIfArmed verb name = do
        armed <- doesFileExist (replaceAfterPath root verb)
        when armed $ do
            removeFile (replaceAfterPath root verb)
            replaceLimaDirectory root name

serveProviderCommand ::
    GuestHandler ->
    FilePath ->
    String ->
    ProviderBehaviour ->
    [String] ->
    IO ()
serveProviderCommand guest root role behaviour argv = case argv of
    -- The whole-daemon listing this project's substrate probe asks, which is how
    -- a provider that is not answering at all is told from one that answers and
    -- names nothing.
    ["list", "--format", "csv", "-c", "n"] -> do
        failed <- doesFileExist (listingFailurePath root)
        if failed
            then readFile' (listingFailurePath root) >>= refuseProviderCommand
            else whileAnswering root behaviour (mapM_ (emitLine . fst))
    ["list", name, "--format", "csv", "-c", "ns"] ->
        whileAnswering root behaviour $ \instances ->
            case lookup name instances of
                Nothing -> pure ()
                Just held -> emitLine (name <> "," <> instanceRunState held)
    ["config", "get", name, key] ->
        instanceNamed root name >>= \case
            Nothing -> refuseProviderCommand ("Failed to fetch instance " <> show name <> ": Instance not found")
            Just held
                | key == providerIdentityConfigKey -> emitLine (instanceIdentity held)
                | key == providerOwnerConfigKey -> emitLine (instanceOwnerClaim held)
                | otherwise -> do
                    maybe (pure ()) emitLine (lookup key (instanceConfig held))
                    when (key == "limits.memory") (replaceIfArmed root "sizing-read" name)
    ("--quiet" : "launch" : _image : name : options) -> do
        instances <- readInstances root
        case lookup name instances of
            Just _ -> refuseProviderCommand "Instance already exists"
            Nothing -> do
                next <- (+ 1) . read <$> readFile' (instanceCounterPath root) :: IO Integer
                writeFile (instanceCounterPath root) (show next)
                writeInstances root ((name, launchedInstance name next options) : instances)
                recordMutation root "launch"
                armed <- doesFileExist (crashAfterLaunchPath root)
                when armed $ do
                    removeFile (crashAfterLaunchPath root)
                    refuseProviderCommand "the provider client died after the launch it performed"
    ["start", name] ->
        withInstance root name $ \held ->
            if instanceRunState held == "RUNNING"
                then refuseProviderCommand "Instance is already running"
                else do
                    alterInstance root name (\current -> current{instanceRunState = "RUNNING"})
                    recordMutation root "start"
                    replaceIfArmed root "start" name
    ["stop", name, "--force"] ->
        withInstance root name $ \held ->
            if instanceRunState held == "STOPPED"
                then refuseProviderCommand "Instance is already stopped"
                else do
                    remainsRunning <- doesFileExist (stopLeavesRunningPath root)
                    when (not remainsRunning) $
                        alterInstance root name (\current -> current{instanceRunState = "STOPPED"})
                    recordMutation root "stop"
                    replaceIfArmed root "stop" name
    ["restart", name, "--force"] ->
        withInstance root name $ \_ -> do
            alterInstance root name (\held -> held{instanceRunState = "RUNNING"})
            recordMutation root "restart"
            replaceIfArmed root "restart" name
    ["delete", name, "--force"] ->
        withInstance root name $ \held -> do
            instances <- readInstances root
            writeInstances root (filter ((/= name) . fst) instances)
            recordMutation root "delete"
            replaceIfArmedFrom root "delete" name (Just held)
            armed <- doesFileExist (crashAfterDeletePath root)
            when armed $ do
                removeFile (crashAfterDeletePath root)
                refuseProviderCommand "the provider client died after the delete it performed"
    ["image", "info", _image]
        | behaviour == ProviderEgressUnavailable -> refuseProviderCommand "not found"
        | behaviour == ProviderEgressFailure -> refuseProviderCommand "permission denied"
        | otherwise -> pure ()
    ["config", "device", "list", name] ->
        withInstance root name $ \held ->
            mapM_ emitLine (map fst (instanceDevices held))
    ["config", "device", "get", name, device, key] ->
        withInstance root name $ \held -> do
            let value = if device == "root" && key == "size"
                    then lookup "root.size" (instanceConfig held)
                    else lookup device (instanceDevices held) >>= lookup key
            maybe (pure ()) emitLine value
            when (key == "path") (replaceIfArmed root "device-read" name)
    ("config" : "device" : "add" : name : device : "disk" : settings) ->
        withInstance root name $ \_ -> do
            alterInstance
                root
                name
                ( \held ->
                    held
                        { instanceDevices =
                            (device, ("type", "disk") : map deviceSetting settings)
                                : filter ((/= device) . fst) (instanceDevices held)
                        }
                )
            recordMutation root "device-add"
            replaceIfArmed root "device-add" name
    ("exec" : name : "--" : inner) ->
        withInstance root name $ \held ->
            if instanceRunState held /= "RUNNING"
                then refuseProviderCommand "Instance is not running"
                else do
                    appendFile (guestInvocationsPath root) (show inner <> "\n")
                    answered <- guest root name role inner
                    emitGuestAnswer answered
    _ -> refuseProviderCommand ("unsupported provider command " <> show argv)

-- | Absent instances refuse before a mutation or guest dispatch is recorded.
withInstance :: FilePath -> String -> (ProviderInstance -> IO ()) -> IO ()
withInstance root name continue =
    instanceNamed root name >>= \case
        Nothing -> refuseProviderCommand "Instance not found"
        Just held -> continue held

{- | Answer commands only while the stand-in daemon is answering.

A daemon that is not there refuses every listing rather than reporting an empty
one, because "the provider says nothing is here" and "there is no provider" are
the two answers a driver must not confuse.
-}
whileAnswering ::
    FilePath ->
    ProviderBehaviour ->
    ([(String, ProviderInstance)] -> IO ()) ->
    IO ()
whileAnswering root behaviour answer = do
    instances <- readInstances root
    if behaviour == ProviderDaemonUnavailable || any (not . instanceDaemonAnswers . snd) instances
        then refuseProviderCommand "provider transport failed"
        else answer instances

{- | The instance a launch establishes, under the claim the launch carried.

The claim rides on the creating command in production, so it rides on it here:
an instance this fixture created without one would let a driver bind an object no
record claims and call it its own.
-}
launchedInstance :: String -> Integer -> [String] -> ProviderInstance
launchedInstance name serial options =
    ProviderInstance
        { instanceRunState = "RUNNING"
        , instanceIdentity = "instance-" <> name <> "-" <> show serial
        , instanceOwnerClaim = launchedClaim options
        , instanceDevices = []
        , instanceDaemonAnswers = True
        , instanceConfig =
            [ ("limits.cpu", setting "limits.cpu=")
            , ("limits.memory", setting "limits.memory=")
            , ("root.size", setting "root,size=")
            ]
        }
  where
    setting prefix = case [drop (length prefix) value | value <- options, prefix `isPrefixOf` value] of
        value : _ -> value
        [] -> ""

launchedClaim :: [String] -> String
launchedClaim options =
    case [drop (length prefix) option | option <- options, prefix `isPrefixOf` option] of
        (claim : _) -> claim
        [] -> ""
  where
    prefix = providerOwnerConfigKey <> "="

deviceSetting :: String -> (String, String)
deviceSetting setting = case break (== '=') setting of
    (key, '=' : value) -> (key, value)
    (key, _) -> (key, "")

recordMutation :: FilePath -> String -> IO ()
recordMutation root verb = appendFile (providerMutationsPath root) (verb <> "\n")

{- | A one-shot replacement changes identity and preserves the other fields.

A deleted instance is supplied by the caller that observed it before removal.
This lets the post-delete case hold the claim and state equal while requiring
the driver to distinguish the replacement by identity alone.
-}
replaceIfArmed :: FilePath -> String -> String -> IO ()
replaceIfArmed root verb name =
    instanceNamed root name >>= replaceIfArmedFrom root verb name

replaceIfArmedFrom :: FilePath -> String -> String -> Maybe ProviderInstance -> IO ()
replaceIfArmedFrom root verb name prior = do
    armed <- doesFileExist (replaceAfterPath root verb)
    when armed $ do
        removeFile (replaceAfterPath root verb)
        instances <- readInstances root
        let retained = case lookup name instances of
                Just held -> Just held
                Nothing -> prior
        case retained of
            Nothing -> refuseProviderCommand "the replacement fixture has no prior instance fields"
            Just held ->
                writeInstances root
                    ((name, held{instanceIdentity = replacementIdentity}) : filter ((/= name) . fst) instances)

{- | Answer as the guest did, on the streams the provider client answers on.

@incus exec@ reports the guest's own exit status and streams, so this client does
too; a refusal that never reached a guest is the client's own failure and is
reported as one.
-}
emitGuestAnswer :: RawProviderOutcome -> IO ()
emitGuestAnswer (RawProviderExit code out err) = do
    writeUtf8 stdout out
    writeUtf8 stderr err
    exitWith code
emitGuestAnswer (RawProviderFailure reason) = refuseProviderCommand reason

refuseProviderCommand :: String -> IO value
refuseProviderCommand reason = do
    writeUtf8 stderr (reason <> "\n")
    exitWith (ExitFailure 1)

-- Protocol fixtures emit UTF-8 bytes with their declared LF terminators.
-- Text handles translate newlines on Windows and would change the wire.
writeUtf8 :: Handle -> String -> IO ()
writeUtf8 handle = ByteString.hPut handle . TextEncoding.encodeUtf8 . Text.pack

emitLine :: String -> IO ()
emitLine = writeUtf8 stdout . (<> "\n")
