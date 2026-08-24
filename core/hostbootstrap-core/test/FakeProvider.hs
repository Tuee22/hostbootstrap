{-# LANGUAGE LambdaCase #-}

{- | A provider client this suite's fixtures drive, as a real process.

§ KK admits one effect vocabulary and one interpreter for it, and § NN admits
evidence only from applying total functions to values or from real processes
doing real work.  Together they close off the shape a provider fixture used to
take: there is no runner to inject, so a suite that wants a provider to have
answered a particular way has to supply a program the interpreter can launch.

The program it supplies is __this suite's own executable__.  A wrapper script
would be the obvious alternative and is not usable: the one interpreter launches
a described command with its exact argument vector, and the guest vectors this
project crosses with carry whole programs — text with quotes and newlines that
no batch file or shell wrapper forwards unchanged.  What tells the child which
role it is playing is therefore the environment its launcher was holding, and
'withFakeProviderClient' holds that variable for exactly the span of a fixture.

Everything the client answers from is durable, because the client is a second
process: a lifecycle state a launch established has to still be there when the
next command asks about it, and a fixture that kept it in the parent would be
asserting about its own memory rather than about what a provider reported.

The argument vectors below are exactly the ones
"HostBootstrap.Substrate.Provider.Command" renders, the ones
"HostBootstrap.Substrate.Provider" probes a substrate with, and the one the
lift's fold places at an in-VM leaf.  A vector this module does not recognize is
a refusal rather than a silent success, so a driver that starts asking for
something new fails a fixture instead of passing through it.
-}
module FakeProvider (
    -- * Entering the role
    fakeProviderVariable,
    withFakeProviderClient,
    GuestHandler,
    runFakeProviderClient,

    -- * Declaring the fixture
    ProviderBehaviour (..),
    newProviderFixture,

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
    armReplacementAfter,
    replacementIdentity,
    recordedGuestInvocations,
    recordedProviderMutations,
) where

import Control.Exception (bracket_)
import Control.Monad (when)
import Data.List (isPrefixOf)
import HostBootstrap.Substrate.Provider (RawProviderOutcome (..))
import HostBootstrap.Substrate.Provider.Command (
    providerIdentityConfigKey,
    providerOwnerConfigKey,
 )
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Environment (setEnv, unsetEnv)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStr, hPutStrLn, readFile', stderr)

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
withFakeProviderClient root =
    bracket_ (setEnv fakeProviderVariable root) (unsetEnv fakeProviderVariable)

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

Three, because three are what a provider contract distinguishes: a client that
answers, one whose provisioning egress cannot resolve an image, and one whose
daemon has stopped answering.
-}
data ProviderBehaviour
    = ProviderAnswers
    | ProviderEgressUnavailable
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
    writeFile (providerMutationsPath root) ""
    writeInstances root []
    writeFile (providerDescriptorPath root) (unlines [role, show behaviour])
    pure root

providerFixtureRoot :: FilePath -> FilePath
providerFixtureRoot = id

providerDescriptorPath :: FilePath -> FilePath
providerDescriptorPath root = root </> "provider-descriptor"

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

recordedGuestInvocations :: FilePath -> IO [[String]]
recordedGuestInvocations root = map read . lines <$> readFile' (guestInvocationsPath root)

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
    descriptor <- lines <$> readFile' (providerDescriptorPath root)
    case descriptor of
        (role : behaviour : _) -> serveProviderCommand guest root role (read behaviour) argv
        _ -> refuseProviderCommand "the provider fixture descriptor is unreadable"

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
    ["list", "--format", "csv", "-c", "n"] ->
        whileAnswering root behaviour (mapM_ (putStrLn . fst))
    ["list", name, "--format", "csv", "-c", "ns"] ->
        whileAnswering root behaviour $ \instances ->
            case lookup name instances of
                Nothing -> pure ()
                Just held -> putStrLn (name <> "," <> instanceRunState held)
    ["list", name, "--format", "csv", "-c", "s"] ->
        whileAnswering root behaviour $ \instances ->
            case lookup name instances of
                Nothing -> pure ()
                Just held -> putStrLn (instanceRunState held)
    ["config", "get", name, key] ->
        instanceNamed root name >>= \case
            Nothing -> refuseProviderCommand ("Failed to fetch instance " <> show name <> ": Instance not found")
            Just held
                | key == providerIdentityConfigKey -> putStrLn (instanceIdentity held)
                | key == providerOwnerConfigKey -> putStrLn (instanceOwnerClaim held)
                | otherwise -> pure ()
    ("--quiet" : "launch" : _image : name : options) -> do
        instances <- readInstances root
        writeInstances root ((name, launchedInstance name options) : filter ((/= name) . fst) instances)
        recordMutation root "launch"
        armed <- doesFileExist (crashAfterLaunchPath root)
        when armed $ do
            removeFile (crashAfterLaunchPath root)
            refuseProviderCommand "the provider client died after the launch it performed"
    ["start", name] -> do
        alterInstance root name (\held -> held{instanceRunState = "RUNNING"})
        recordMutation root "start"
        replaceIfArmed root "start" name
    ["stop", name] -> do
        alterInstance root name (\held -> held{instanceRunState = "STOPPED"})
        recordMutation root "stop"
        replaceIfArmed root "stop" name
    ["restart", name, "--force"] -> do
        alterInstance root name (\held -> held{instanceRunState = "RUNNING"})
        recordMutation root "restart"
        replaceIfArmed root "restart" name
    ["delete", name, "--force"] -> do
        instances <- readInstances root
        writeInstances root (filter ((/= name) . fst) instances)
        recordMutation root "delete"
        replaceIfArmed root "delete" name
    ["image", "info", _image]
        | behaviour == ProviderEgressUnavailable -> refuseProviderCommand "not found"
        | otherwise -> pure ()
    ["config", "device", "list", name] -> do
        held <- instanceNamed root name
        mapM_ putStrLn (maybe [] (map fst . instanceDevices) held)
    ["config", "device", "get", name, device, key] -> do
        held <- instanceNamed root name
        case held >>= lookup device . instanceDevices >>= lookup key of
            Nothing -> pure ()
            Just value -> putStrLn value
    ("config" : "device" : "add" : name : device : "disk" : settings) -> do
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
    ("exec" : name : "--" : inner) -> do
        appendFile (guestInvocationsPath root) (show inner <> "\n")
        answered <- guest root name role inner
        emitGuestAnswer answered
    _ -> refuseProviderCommand ("unsupported provider command " <> show argv)

{- | Answer a listing only while the provider's own daemon is answering.

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
launchedInstance :: String -> [String] -> ProviderInstance
launchedInstance name options =
    ProviderInstance
        { instanceRunState = "RUNNING"
        , instanceIdentity = "instance-" <> name
        , instanceOwnerClaim = launchedClaim options
        , instanceDevices = []
        , instanceDaemonAnswers = True
        }

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

{- | Put a different instance at the name, if this verb was armed for it.

Total over the two states the name can be in: an instance that is still there
takes the replacement identity, and a name the command just emptied gets a
running replacement, because "somebody else recreated it" is the same hazard
either way.
-}
replaceIfArmed :: FilePath -> String -> String -> IO ()
replaceIfArmed root verb name = do
    armed <- doesFileExist (replaceAfterPath root verb)
    when armed $ do
        removeFile (replaceAfterPath root verb)
        instances <- readInstances root
        case lookup name instances of
            Just held ->
                writeInstances
                    root
                    ( (name, held{instanceIdentity = replacementIdentity})
                        : filter ((/= name) . fst) instances
                    )
            Nothing ->
                writeInstances
                    root
                    ( ( name
                      , ProviderInstance
                            { instanceRunState = "RUNNING"
                            , instanceIdentity = replacementIdentity
                            , instanceOwnerClaim = ""
                            , instanceDevices = []
                            , instanceDaemonAnswers = True
                            }
                      )
                        : instances
                    )

{- | Answer as the guest did, on the streams the provider client answers on.

@incus exec@ reports the guest's own exit status and streams, so this client does
too; a refusal that never reached a guest is the client's own failure and is
reported as one.
-}
emitGuestAnswer :: RawProviderOutcome -> IO ()
emitGuestAnswer (RawProviderExit code out err) = do
    putStr out
    hPutStr stderr err
    exitWith code
emitGuestAnswer (RawProviderFailure reason) = refuseProviderCommand reason

refuseProviderCommand :: String -> IO ()
refuseProviderCommand reason = do
    hPutStrLn stderr reason
    exitWith (ExitFailure 1)
