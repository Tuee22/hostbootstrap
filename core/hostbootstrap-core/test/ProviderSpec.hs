{-# LANGUAGE OverloadedStrings #-}

{- | Pure provider dispatch and planning contract.  Authority-bearing discovery
is exercised through the clause-holding backend in 'ProviderAliasSpec'; this
module locks the public opaque route's descriptive projections and effect plans.
-}
module ProviderSpec (tests) where

import Control.Monad (forM_)
import Data.List (isInfixOf, isPrefixOf)
import HostBootstrap.Context (ResourceEnvelope (..))
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.HostTool (HostTool (Incus, Lima, Wsl))
import HostBootstrap.Incus (IncusVM (..))
import qualified HostBootstrap.Incus as Incus
import HostBootstrap.Lift (LiftLayer (ViaWsl2VM), inLimaVM, inVM, inWsl2VM, localContext)
import HostBootstrap.Lima (LimaVM (..))
import qualified HostBootstrap.Lima as Lima
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import HostBootstrap.Substrate.Provider
import HostBootstrap.Wsl2 (Wsl2VM (..))
import qualified HostBootstrap.Wsl2 as Wsl2
import qualified SourceGuard
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

handles :: VMHandles
handles =
    VMHandles
        { vmhIncus = IncusVM "demo-vm" "images:ubuntu/24.04"
        , vmhLima = LimaVM "demo-vm"
        , vmhWsl2 = Wsl2VM "demo-vm"
        , vmhGuardPrefix = "demo"
        }

unguardedHandles :: VMHandles
unguardedHandles = handles{vmhWsl2 = Wsl2VM "someone-elses-distro"}

env :: ResourceEnvelope
env = ResourceEnvelope{cpu = 6, memory = "10GiB", storage = "80GiB"}

sel :: Substrate -> SubstrateProvider
sel substrate =
    either
        (error . ("selectSubstrateProvider failed: " ++))
        id
        (selectSubstrateProvider substrate handles)

apple, linux, windows, direct :: SubstrateProvider
apple = sel (Substrate AppleSilicon Arm64)
linux = sel (Substrate LinuxCpu Amd64)
windows = sel (Substrate WindowsCpu Amd64)
direct = sel (Substrate LinuxGpu Amd64)

plannedShare :: SubstrateProvider -> FilePath -> HostPathShare
plannedShare provider source =
    either (error . show) id (planProviderShare provider source)

appleShare, linuxShare, windowsShare, directShare :: HostPathShare
appleShare = plannedShare apple "/Users/me/demo/.data"
linuxShare = plannedShare linux "/srv/demo/.data"
windowsShare = plannedShare windows "C:\\repo\\demo\\.data"
directShare = plannedShare direct "/srv/demo/.data"

tests :: TestTree
tests =
    testGroup
        "ProviderSpec"
        [ testGroup "closed dispatch" dispatchCases
        , testGroup "the one guarded destructive delete" guardedDeleteCases
        , testGroup "pure lifecycle plans" lifecycleCases
        , testGroup "host-path shares" shareCases
        , testGroup "probe descriptions" probeCases
        , testGroup "pure interpreters" interpreterCases
        , testGroup "guest alias state machine" aliasCases
        , testGroup "provider-live client boundary" providerLiveBoundaryCases
        ]

{- | § LL: every frame's destructive delete is one computation, so these cases
ask the same questions of all three rows at once. That is the point — three
copies each passed a test that only asked whether a differently-prefixed name
refused, and none of them was ever asked what an empty guard prefix does.
-}
guardedDeleteCases :: [TestTree]
guardedDeleteCases =
    [ testCase "an admitted name reaches the row's own argv" $
        map (\row -> rowDelete row "hostbootstrap-demo-" "hostbootstrap-demo-vm") rows
            @?= [ Right ["delete", "hostbootstrap-demo-vm", "--force"]
                , Right ["delete", "hostbootstrap-demo-vm", "--force"]
                , Right ["--unregister", "hostbootstrap-demo-vm"]
                ]
    , testCase "a name outside the guard refuses in the frame's own noun" $
        sequence_
            [ case rowDelete row "hostbootstrap-demo-" "personal-ubuntu" of
                Right argv -> assertBool (rowLabel row ++ " deleted an unguarded name: " ++ show argv) False
                Left message -> do
                    assertBool
                        (rowLabel row ++ " names what it refused: " ++ message)
                        ("personal-ubuntu" `isInfixOf` message)
                    assertBool
                        (rowLabel row ++ " names its own frame: " ++ message)
                        (rowNoun row `isInfixOf` message)
            | row <- rows
            ]
    , testCase "an empty guard prefix refuses, because it admits every name" $
        sequence_
            [ case rowDelete row "" "hostbootstrap-demo-vm" of
                Right argv ->
                    assertBool
                        (rowLabel row ++ " deleted under a vacuous guard: " ++ show argv)
                        False
                Left message ->
                    assertBool
                        (rowLabel row ++ " says why the guard is vacuous: " ++ message)
                        ("admits every name" `isInfixOf` message)
            | row <- rows
            ]
    , testCase "an empty name refuses before the prefix is compared" $
        sequence_
            [ case rowDelete row "hostbootstrap-demo-" "" of
                Right argv ->
                    assertBool (rowLabel row ++ " rendered a nameless delete: " ++ show argv) False
                Left message ->
                    assertBool
                        (rowLabel row ++ " says the frame has no name: " ++ message)
                        ("no name" `isInfixOf` message)
            | row <- rows
            ]
    ]
  where
    rows =
        [ ("Lima", "Lima VM", \prefix name -> Lima.deleteVMArgs prefix (LimaVM name))
        , ("Incus", "incus VM", \prefix name -> Incus.destroyVMArgs prefix (IncusVM name "images:ubuntu/24.04"))
        , ("WSL2", "WSL2 distro", Wsl2.wslUnregisterArgs)
        ]
    rowLabel (label, _, _) = label
    rowNoun (_, noun, _) = noun
    rowDelete (_, _, delete) = delete

dispatchCases :: [TestTree]
dispatchCases =
    [ testCase "descriptive accessors project each closed provider" $ do
        providerVmId apple @?= "demo-vm"
        providerKind apple @?= ProviderLima
        providerLiftContext apple @?= inLimaVM (LimaVM "demo-vm") localContext
        providerKind linux @?= ProviderIncus
        providerLiftContext linux @?= inVM (IncusVM "demo-vm" "images:ubuntu/24.04") localContext
        providerKind windows @?= ProviderWsl2
        providerLiftContext windows @?= inWsl2VM (Wsl2VM "demo-vm") localContext
        providerVmId direct @?= "local-host"
        providerKind direct @?= ProviderDirectHost
        providerLiftContext direct @?= localContext
    , testCase "kind dispatch is total, including Direct" $ do
        let kinds = [ProviderIncus, ProviderLima, ProviderWsl2, ProviderDirectHost]
        map (providerKind . (`selectProviderKind` handles)) kinds @?= kinds
        map
            providerKindForSubstrate
            [ Substrate AppleSilicon Arm64
            , Substrate LinuxCpu Amd64
            , Substrate LinuxGpu Amd64
            , Substrate WindowsCpu Amd64
            , Substrate WindowsGpu Amd64
            ]
            @?= [ProviderLima, ProviderIncus, ProviderDirectHost, ProviderWsl2, ProviderWsl2]
    , testCase "lifecycle kinds project totally into topology kinds" $
        map providerTopologyKind [ProviderIncus, ProviderLima, ProviderWsl2, ProviderDirectHost]
            @?= [Context.IncusVMProvider, Context.LimaVMProvider, Context.Wsl2VMProvider, Context.HostProvider]
    , testCase "discovery reports are structurally guest or Direct" $ do
        let ready = ProviderObservedReady ()
            guest =
                GuestProviderDiscovery
                    ready
                    ready
                    ready
                    (ProviderObservedNotReady "endpoint warming")
                    (ProviderObservedReady (GuestFlock "/usr/bin/flock"))
                    (ProviderObservedReady (GuestGnuStat "/usr/bin/stat"))
                    (ProviderObservedReady (GuestPython3 "/usr/bin/python3"))
            local = DirectProviderDiscovery ready (ProviderObservedUnavailable "offline")
        ProviderGuestDiscovery guest @?= ProviderGuestDiscovery guest
        ProviderDirectDiscovery local @?= ProviderDirectDiscovery local
    ]

lifecycleCases :: [TestTree]
lifecycleCases =
    [ testCase "provision plans retain the exact provider argv" $ do
        planProviderProvision apple env (Just appleShare)
            @?= Right
                [ hostToolEffect
                    Lima
                    [ "start"
                    , "-y"
                    , "--timeout"
                    , "15m"
                    , "--name=demo-vm"
                    , "--containerd"
                    , "none"
                    , "--cpus"
                    , "6"
                    , "--memory"
                    , "10"
                    , "--disk"
                    , "80"
                    , "--vm-type"
                    , "vz"
                    , "--mount-only"
                    , "/Users/me/demo/.data:w"
                    , "template:ubuntu-24.04"
                    ]
                ]
        planProviderProvision linux env (Just linuxShare)
            @?= Right
                [ hostToolEffect
                    Incus
                    [ "launch"
                    , "images:ubuntu/24.04"
                    , "demo-vm"
                    , "--vm"
                    , "-c"
                    , "limits.cpu=6"
                    , "-c"
                    , "limits.memory=10GiB"
                    , "-d"
                    , "root,size=80GiB"
                    ]
                ]
        planProviderProvision direct env (Just directShare)
            @?= Right [RunDirectHost RealizeDirectHost]
    , testCase "WSL provision applies the global wall before install" $
        planProviderProvision windows env (Just windowsShare)
            @?= Right
                [ ApplyGlobalWslWall wallBody
                , hostToolEffect Wsl ["--shutdown"]
                , hostToolEffect
                    Wsl
                    ["--install", "-d", "Ubuntu-24.04", "--name", "demo-vm", "--no-launch", "--vhd-size", "80GB"]
                ]
    , testCase "reboot-to-ready has one result shape" $ do
        planProviderRebootReady linux
            @?= Right
                RebootReadyPlan
                    { rebootStartEffects = [hostToolEffect Incus ["start", "demo-vm"]]
                    , rebootCordonReconcile = Nothing
                    , rebootWaitProbe = WaitProbe Incus ["exec", "demo-vm", "--", "true"]
                    }
        planProviderRebootReady direct
            @?= Right
                RebootReadyPlan
                    { rebootStartEffects = [RunDirectHost ReconcileDirectHostReady]
                    , rebootCordonReconcile = Nothing
                    , rebootWaitProbe = DirectHostReadyProbe
                    }
    , testCase "stop and guarded delete are explicit" $ do
        planProviderStop apple env @?= Right [hostToolEffect Lima ["stop", "demo-vm"]]
        planProviderStop linux env @?= Right [hostToolEffect Incus ["stop", "demo-vm"]]
        planProviderStop windows env
            @?= Right [ReleaseGlobalWslWall wallBody, hostToolEffect Wsl ["--shutdown"]]
        planProviderDelete apple env @?= Right [hostToolEffect Lima ["delete", "demo-vm", "--force"]]
        planProviderDelete linux env @?= Right [hostToolEffect Incus ["delete", "demo-vm", "--force"]]
        planProviderDelete windows env
            @?= Right [hostToolEffect Wsl ["--unregister", "demo-vm"], ReleaseGlobalWslWall wallBody]
    , testCase "Direct stop/delete and Direct guest alias are structured refusals" $ do
        assertUnsupported ProviderStop (planProviderStop direct env)
        assertUnsupported ProviderDelete (planProviderDelete direct env)
        assertUnsupported ProviderAlias (planProviderAlias direct "/alias" "/target" AliasAbsent)
    , testCase "a guarded delete cannot target a foreign namespace" $
        case selectSubstrateProvider (Substrate WindowsCpu Amd64) unguardedHandles of
            Left failure -> assertBool ("expected provider selection, got " ++ failure) False
            Right provider ->
                case planProviderDelete provider env of
                    Left ProviderOperationFailure{providerErrorOperation = ProviderDelete} -> pure ()
                    other -> assertBool ("expected guarded ProviderOperationFailure, got " ++ show other) False
    ]
  where
    wallBody =
        [ "[general]"
        , "instanceIdleTimeout=21600000"
        , "[wsl2]"
        , "processors=6"
        , "memory=10GB"
        , "swap=10GB"
        , "vmIdleTimeout=21600000"
        ]
    assertUnsupported operation result =
        case result of
            Left ProviderUnsupported{providerErrorKind = ProviderDirectHost, providerErrorOperation = observed} ->
                observed @?= operation
            other -> assertBool ("expected Direct ProviderUnsupported, got " ++ show other) False

shareCases :: [TestTree]
shareCases =
    [ testCase "Lima and Direct preserve the canonical path" $ do
        appleShare @?= HostPathShare "/Users/me/demo/.data" "/Users/me/demo/.data" Nothing
        directShare @?= HostPathShare "/srv/demo/.data" "/srv/demo/.data" Nothing
    , testCase "Incus plans one idempotent disk device" $ do
        hpsReconcile linuxShare
            @?= Just
                ShareReconcile
                    { srProbe = ExistsProbe Incus ["config", "device", "list", "demo-vm"] LinesMember
                    , srMember = "durable-data"
                    , srWhenMissing =
                        [ hostToolEffect
                            Incus
                            [ "config"
                            , "device"
                            , "add"
                            , "demo-vm"
                            , "durable-data"
                            , "disk"
                            , "source=/srv/demo/.data"
                            , "path=/srv/demo/.data"
                            ]
                        ]
                    }
        shareReconcileEffects linuxShare "root\ndurable-data\neth0\n" @?= []
    , testCase "WSL projects through DrvFs" $
        windowsShare @?= HostPathShare "C:\\repo\\demo\\.data" "/mnt/c/repo/demo/.data" Nothing
    ]

probeCases :: [TestTree]
probeCases =
    [ testCase "probe folds hide Direct/tool dispatch" $ do
        foldExistsProbe
            (Left "direct")
            (\tool args membership -> Right (tool, args, membership))
            (providerExistsProbe direct)
            @?= (Left "direct" :: Either String (HostTool, [String], Membership))
        foldWaitProbe
            (Left "direct")
            (\tool args -> Right (tool, args))
            (providerWaitProbe windows)
            @?= (Right (Wsl, ["-d", "demo-vm", "--", "true"]) :: Either String (HostTool, [String]))
    , testCase "closed providers expose exact probe descriptions" $ do
        providerExistsProbe apple @?= ExistsProbe Lima ["list", "-q"] LinesMember
        providerExistsProbe linux @?= ExistsProbe Incus ["list", "--format", "csv", "-c", "n"] LinesMember
        providerExistsProbe windows @?= ExistsProbe Wsl ["--list", "--quiet"] WslQuietMember
        providerExistsProbe direct @?= DirectHostExistsProbe
        providerWaitProbe direct @?= DirectHostReadyProbe
    ]

interpreterCases :: [TestTree]
interpreterCases =
    [ testCase "membership parsers are total" $ do
        membersOf LinesMember "demo-vm\nother\n" @?= ["demo-vm", "other"]
        membersOf WslRunningMember "NAME STATE VERSION\n* demo-vm Running 2\nother Stopped 2\n"
            @?= ["demo-vm"]
    , testCase "file staging retains each transport" $ do
        stageFileEffects (LimaFileTransfer (LimaVM "demo-vm")) "src.tgz" "/tmp/x.tgz"
            @?= StagedFile [hostToolEffect Lima ["copy", "src.tgz", "demo-vm:/tmp/x.tgz"]] "/tmp/x.tgz" True
        stageFileEffects (IncusFileTransfer (IncusVM "demo-vm" "images:ubuntu/24.04")) "src.tgz" "/tmp/x.tgz"
            @?= StagedFile [hostToolEffect Incus ["file", "push", "src.tgz", "demo-vm/tmp/x.tgz"]] "/tmp/x.tgz" True
        stageFileEffects DirectHostTransfer "/srv/demo/src.tgz" "/tmp/x.tgz"
            @?= StagedFile [] "/srv/demo/src.tgz" False
    , testCase "VM shell and Windows mount folds are descriptive" $ do
        vmShellArgs (ViaWsl2VM (Wsl2VM "d")) ["true"]
            @?= Just (Wsl, ["-d", "d", "--", "true"])
        windowsPathToWslMount "C:\\Users\\Matt\\f.tgz" @?= "/mnt/c/Users/Matt/f.tgz"
    ]

aliasCases :: [TestTree]
aliasCases =
    [ testCase "alias classification and ensure are total" $ do
        classifyAlias target (AliasFacts Nothing False) @?= AliasAbsent
        classifyAlias target (AliasFacts (Just target) True) @?= AliasLinkedCorrectly
        planAliasEnsure alias target AliasAbsent @?= Right AliasCreateLink
        planAliasEnsure alias target AliasLinkedCorrectly @?= Right AliasLeaveLinked
    , testCase "foreign aliases are refused rather than overwritten" $ do
        assertLeftHas "points to" (planAliasEnsure alias target (AliasLinkedElsewhere "/elsewhere"))
        assertLeftHas "refusing to remove" (planAliasRemove alias target (AliasLinkedElsewhere "/elsewhere"))
    , testCase "owned alias removal is explicit" $
        planAliasRemove alias target AliasLinkedCorrectly @?= Right AliasUnlink
    ]
  where
    target = "/var/tmp/hostbootstrap-demo-data-actual"
    alias = "/var/tmp/hostbootstrap-demo-data"
    assertLeftHas needle result = case result of
        Left message -> assertBool ("expected " ++ show needle ++ " in " ++ message) (needle `isInfixOf` message)
        Right value -> assertBool ("expected Left, got " ++ show value) False

providerLiveBoundaryCases :: [TestTree]
providerLiveBoundaryCases =
    [ testCase "the live client uses only opaque prepared provider routes" $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        let liveRoot = root </> "core" </> "hostbootstrap-core" </> "provider-live"
            liveFiles =
                [ "ProviderLiveMain.hs"
                , "ProviderLiveConfig.hs"
                , "ProviderLiveRunner.hs"
                , "ProviderLiveAliasFixture.hs"
                ]
            rawPlannerIdentifiers =
                [ "planProviderProvision"
                , "planProviderRebootReady"
                , "planProviderStop"
                , "planProviderDelete"
                , "planProviderShare"
                , "planProviderAlias"
                ]
            independentGuestIdentifiers =
                [ "GuestExec"
                , "ProviderGuestExecutor"
                , "bindProviderGuestExecutor"
                , "runProviderGuestExecutor"
                ]
            opaqueConstructorImports =
                [ ["SubstrateProvider", "(", "..", ")"]
                , ["ManagedProviderHandle", "(", "..", ")"]
                , ["ManagedProviderShareHandle", "(", "..", ")"]
                , ["ProviderCapability", "(", "..", ")"]
                ]
        sources <-
            traverse
                ( \name -> do
                    source <- readFile (liveRoot </> name)
                    pure (name, source)
                )
                liveFiles
        forM_ sources $ \(name, source) -> do
            assertBool
                (name ++ " imports the private provider executor boundary")
                (not (SourceGuard.importsModule "HostBootstrap.Substrate.Provider.Internal" source))
            forM_ (rawPlannerIdentifiers ++ independentGuestIdentifiers) $ \identifier ->
                assertBool
                    (name ++ " contains forbidden provider-live identifier " ++ identifier)
                    (SourceGuard.countHaskellIdentifier identifier source == 0)
            forM_ opaqueConstructorImports $ \tokens ->
                assertBool
                    (name ++ " requests an opaque constructor: " ++ unwords tokens)
                    (SourceGuard.countHaskellTokenSequence tokens source == 0)
        aliasSource <-
            maybe
                (assertFailure "ProviderLiveAliasFixture.hs was not loaded")
                pure
                (lookup "ProviderLiveAliasFixture.hs" sources)
        let directSlice = sourceSlice "exerciseDirect ::" "exerciseIncus ::" aliasSource
        assertBool "could not isolate the provider-live Direct route" (not (null directSlice))
        SourceGuard.countHaskellIdentifier "stopProvider" directSlice @?= 1
        SourceGuard.countHaskellTokenSequence ["Right", "_", "->", "fixtureFailure"] directSlice @?= 1
        forM_
            [ "deleteProvider"
            , "withPreparedProviderDelete"
            , "runProviderDeleteCall"
            , "planProviderDelete"
            ]
            (\identifier -> SourceGuard.countHaskellIdentifier identifier directSlice @?= 0)
    ]

sourceSlice :: String -> String -> String -> String
sourceSlice start end =
    unlines
        . takeWhile (not . isPrefixOf end)
        . dropWhile (not . isPrefixOf start)
        . lines
