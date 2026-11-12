{-# LANGUAGE OverloadedStrings #-}

{- | Pure provider dispatch and planning contract.  Authority-bearing discovery
is exercised through the clause-holding backend in 'ProviderBackendSpec'; this
module locks the public opaque route's descriptive projections and effect plans.
-}
module ProviderSpec (tests) where

import Control.Monad (forM_)
import Data.List (isInfixOf, isPrefixOf, sort)
import HostBootstrap.Context (ResourceEnvelope (..))
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.HostTool (HostTool (Incus, Lima, Wsl))
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lift (
    ContainerLift (..),
    ContainerPlacement (DirectHostContainer, ProviderGuestContainer),
    LiftLayer (ViaContainer, ViaLimaVM, ViaVM, ViaWsl2VM),
    inLimaVM,
    inVM,
    inWsl2VM,
    localContext,
 )
import HostBootstrap.Readiness (ProbeResult (..), ProbeConflict (..), ProbeFailure (..))
import HostBootstrap.Lima (LimaVM (..))
import HostBootstrap.Lift.Context (emptyVMStack, vmContext)
import qualified HostBootstrap.Lima as Lima
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import HostBootstrap.Substrate.Provider
import qualified HostBootstrap.Substrate.Provider.Command as ProviderCommand
import HostBootstrap.Wsl2 (Wsl2VM (..))
import qualified HostBootstrap.Wsl2 as Wsl2
import qualified SourceGuard
import System.Exit (ExitCode (..))
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import System.IO (readFile')
import Text.Read (readMaybe)
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
        , testGroup "provider-live client boundary" providerLiveBoundaryCases
        , testGroup "the inherited durability statement" inheritedDurabilityCases
        , testGroup "one crossing renderer" crossingRendererCases
        ]

{- | Section LL and rationale.md's frame-table rationale require the absence
guard "one crossing renderer". Scan physical public and private trees, so an
undeclared module cannot hide a second consumer.
-}
crossingRendererCases :: [TestTree]
crossingRendererCases =
    [ testCase "the complete public and private trees have exactly the declared renderer owners" $
        SourceGuard.withPackageSourceIn ["src"] $ \packageRoot sourceRoot -> do
            public <- SourceGuard.readHaskellSources sourceRoot
            private <- SourceGuard.readHaskellSources (packageRoot </> "internal")
            let sources = [(SourceGuard.repoRelativePath packageRoot path, source) | (path, source) <- public <> private]
            crossingRendererViolations sources @?= []
    , testCase "the predicate admits its exact baseline and ignores comments and textual mentions" $ do
        crossingRendererViolations crossingRendererBaseline @?= []
        let other = unlines
                [ "module Other where"
                , "-- execVMArgs and \"exec\""
                , "{- shellVMArgs {- \"shell\" -} -}"
                , "mention = \"wslExecArgs\""
                , "ordinary = \"executable\""
                ]
        crossingRendererViolations (crossingRendererBaseline <> [("src/Other.hs", other)]) @?= []
    , testCase "a further qualified primitive consumer is refused for every renderer variant" $
        forM_ crossingRendererIdentifiers $ \identifier -> do
            let violations = crossingRendererViolations
                    (crossingRendererBaseline <> [("src/Other.hs", "value = Qualified." <> identifier)])
            assertBool ("the extra " <> identifier <> " consumer escaped the ownership set")
                (any ("src/Other.hs" `isInfixOf`) violations)
    , testCase "a further crossing literal is refused including escaped spellings" $
        forM_ ["\"exec\"", "\"shell\"", "\"e\\120ec\"", "\"s\\104ell\""] $ \literal -> do
            let violations = crossingRendererViolations
                    (crossingRendererBaseline <> [("src/Other.hs", "value = [" <> literal <> "]")])
            assertBool ("the extra literal escaped: " <> literal)
                (any ("src/Other.hs carries crossing literal " `isPrefixOf`) violations)
    ]

crossingRendererOwners :: [FilePath]
crossingRendererOwners =
    [ "internal/handoff-implementation/HostBootstrap/Lift/Context.hs"
    , "src/HostBootstrap/Lift.hs"
    , "src/HostBootstrap/Incus.hs"
    , "src/HostBootstrap/Lima.hs"
    , "src/HostBootstrap/Wsl2.hs"
    , "src/HostBootstrap/Substrate/Provider.hs"
    ]

crossingRendererIdentifiers :: [String]
crossingRendererIdentifiers =
    ["execVMArgs", "shellVMArgs", "wslExecArgs", "execVMArgsAt", "shellVMArgsAt", "wslExecArgsAt"]

crossingRendererBaseline :: [(FilePath, String)]
crossingRendererBaseline = [(path, "value = execVMArgs") | path <- crossingRendererOwners]

crossingRendererViolations :: [(FilePath, String)] -> [String]
crossingRendererViolations sources =
    ["crossing renderer owners differ: " <> show owners | owners /= sort crossingRendererOwners]
        <> [ path <> " carries crossing literal " <> show command
           | (path, tokens) <- scanned
           , path `notElem` literalOwners
           , token@('"' : _) <- tokens
           , Just command <- [readMaybe token :: Maybe String]
           , command `elem` ["exec", "shell"]
           ]
  where
    scanned = [(path, SourceGuard.haskellTokens source) | (path, source) <- sources]
    owners = sort [path | (path, tokens) <- scanned, any (`elem` crossingRendererIdentifiers) tokens]
    literalOwners =
        ["internal/handoff-implementation/HostBootstrap/Lift/Context.hs", "src/HostBootstrap/Lift.hs"]

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
        , ("Incus", "incus VM", \prefix name -> commandArguments <$> ProviderCommand.deleteInstanceCommand prefix name)
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
        providerLiftContext apple @?= vmContext (inLimaVM (LimaVM "demo-vm") emptyVMStack)
        providerKind linux @?= ProviderIncus
        providerLiftContext linux @?= vmContext (inVM (IncusVM "demo-vm" "images:ubuntu/24.04") emptyVMStack)
        providerKind windows @?= ProviderWsl2
        providerLiftContext windows @?= vmContext (inWsl2VM (Wsl2VM "demo-vm") emptyVMStack)
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

    ]

lifecycleCases :: [TestTree]
lifecycleCases =
    [ testCase "provision plans retain the exact provider argv" $ do
        fmap provisionEffects (planProviderProvision apple env (Just appleShare))
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
        planProviderProvision direct env (Just directShare)
            @?= Right
                ( ProviderProvisionPlan
                    [RunDirectHost RealizeDirectHost]
                    (DirectHostWallsUnsupported env [ProviderCpuWall, ProviderMemoryWall, ProviderStorageWall])
                )
        let otherEnvelope = ResourceEnvelope 3 "4GiB" "20GiB"
        fmap provisionWallDecision (planProviderProvision direct otherEnvelope Nothing)
            @?= Right (DirectHostWallsUnsupported otherEnvelope [ProviderCpuWall, ProviderMemoryWall, ProviderStorageWall])
    , testCase "Incus launch requires the prepared ownership route" $ do
        let refusal = Left (ProviderOperationFailure ProviderIncus ProviderProvision
                "Incus provisioning requires the prepared provision call")
        planProviderProvision linux env (Just linuxShare) @?= refusal
        planProviderProvision linux (ResourceEnvelope 0 "invalid" "invalid") Nothing @?= refusal
    , testCase "Incus lifecycle plans project the shared commands for each instance" $
        forM_ ["demo-vm", "demo-other"] $ \name -> do
            let row = selectProviderKind ProviderIncus (handles {vmhIncus = IncusVM name "images:ubuntu/24.04"})
                source = "/srv/shared data"
                share = plannedShare row source
            fmap rebootStartEffects (planProviderRebootReady row)
                @?= Right [RunHostCommand (ProviderCommand.startInstanceCommand name)]
            planProviderStop row env
                @?= Right [RunHostCommand (ProviderCommand.stopInstanceCommand name)]
            planProviderDelete row env
                @?= fmap (\command -> [RunHostCommand command])
                    (either (Left . ProviderOperationFailure ProviderIncus ProviderDelete) Right
                        (ProviderCommand.deleteInstanceCommand (vmhGuardPrefix handles) name))
            case hpsReconcile share of
                Nothing -> assertFailure "the Incus row lost its share reconciliation"
                Just reconcile -> do
                    let listing = ProviderCommand.listShareDevicesCommand name
                    commandTarget listing @?= ToolTarget Incus
                    srProbe reconcile @?= ExistsProbe Incus (commandArguments listing) LinesMember
                    srWhenMissing reconcile @?=
                        [RunHostCommand (ProviderCommand.attachShareDeviceCommand name (srMember reconcile) source source)]
    , testCase "WSL provision applies the global wall before install" $
        fmap provisionEffects (planProviderProvision windows env (Just windowsShare))
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
        planProviderRebootReady windows
            @?= Right
                RebootReadyPlan
                    { rebootStartEffects = []
                    , rebootCordonReconcile = Just
                        (ExistsProbe Wsl ["--list", "--running", "--quiet"] WslQuietMember, [hostToolEffect Wsl ["--shutdown"]])
                    , rebootWaitProbe = WaitProbe Wsl ["-d", "demo-vm", "--exec", "true"]
                    }
        planProviderRebootReady apple
            @?= Right
                RebootReadyPlan
                    { rebootStartEffects = [hostToolEffect Lima ["start", "demo-vm"]]
                    , rebootCordonReconcile = Nothing
                    , rebootWaitProbe = WaitProbe Lima ["shell", "demo-vm", "--", "sudo", "-H", "true"]
                    }
    , testCase "stop and guarded delete are explicit" $ do
        planProviderStop apple env @?= Right [hostToolEffect Lima ["stop", "demo-vm"]]
        planProviderStop linux env @?= Right [hostToolEffect Incus ["stop", "demo-vm", "--force"]]
        planProviderStop windows env
            @?= Right [ReleaseGlobalWslWall wallBody, hostToolEffect Wsl ["--shutdown"]]
        planProviderDelete apple env @?= Right [hostToolEffect Lima ["delete", "demo-vm", "--force"]]
        planProviderDelete linux env @?= Right [hostToolEffect Incus ["delete", "demo-vm", "--force"]]
        planProviderDelete windows env
            @?= Right [hostToolEffect Wsl ["--unregister", "demo-vm"], ReleaseGlobalWslWall wallBody, hostToolEffect Wsl ["--shutdown"]]
    , testCase "Direct stop and delete are structured refusals" $ do
        assertUnsupported ProviderStop (planProviderStop direct env)
        assertUnsupported ProviderDelete (planProviderDelete direct env)
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
                    , srMember = "hb-share-82a329e0f07a"
                    , srWhenMissing =
                        [ hostToolEffect
                            Incus
                            [ "config"
                            , "device"
                            , "add"
                            , "demo-vm"
                            , "hb-share-82a329e0f07a"
                            , "disk"
                            , "source=/srv/demo/.data"
                            , "path=/srv/demo/.data"
                            ]
                        ]
                    }
        shareReconcileEffects linuxShare "root\nhb-share-82a329e0f07a\neth0\n" @?= []
        let missing = [hostToolEffect Incus
                ["config", "device", "add", "demo-vm", "hb-share-82a329e0f07a", "disk",
                    "source=/srv/demo/.data", "path=/srv/demo/.data"]]
        shareReconcileEffects linuxShare "root\nhb-share-a017dbabc79b\neth0\n" @?= missing
        shareReconcileEffects linuxShare "root\neth0\n" @?= missing
        shareReconcileEffects linuxShare "root\nhb-share-82a329e0f07a-old\n" @?= missing
        fmap srMember (hpsReconcile (plannedShare linux "/srv/other/.data"))
            @?= Just "hb-share-a017dbabc79b"
    , testCase "WSL projects through DrvFs" $
        windowsShare @?= HostPathShare "C:\\repo\\demo\\.data" "/mnt/c/repo/demo/.data" Nothing
    ]

probeCases :: [TestTree]
probeCases =
    [ testCase "provider capabilities expose no independent guest executor" $
        SourceGuard.withPackageSourceIn ["src"] $ \_ sourceRoot -> do
            sources <- SourceGuard.readHaskellSources sourceRoot
            forM_ sources $ \(path, source) ->
                forM_
                    [ "ProviderGuestExecutor", "bindProviderGuestExecutor"
                    , "runProviderGuestExecutor", "providerCapabilityGuestExecutor"
                    ] $ \name ->
                        assertBool (path <> " names " <> name)
                            (SourceGuard.countHaskellIdentifier name source == 0)
    , testCase "unit probe classifier preserves each readiness and availability prefix" $ do
        forM_ ["not ready", "starting", "connection refused", "daemon is not running"] $ \prefix ->
            classifyProviderProbe (RawProviderExit (ExitFailure 9) "" (prefix <> " detail\n"))
                @?= NotReady (prefix <> " detail")
        forM_ ["not found", "unsupported", "no such file"] $ \prefix ->
            classifyProviderProbe (RawProviderExit (ExitFailure 9) (prefix <> " detail\n") "")
                @?= Unavailable (prefix <> " detail")
    , testCase "native Incus agent startup needs the exact exit and error" $ do
        let startup = "Error: VM agent isn't currently running"
        classifyProviderProbe (RawProviderExit (ExitFailure 255) "" (startup <> "\n"))
            @?= NotReady startup
        forM_
            [ (RawProviderExit (ExitFailure 254) "" startup,
                "exit 254: Error: VM agent isn't currently running")
            , (RawProviderExit (ExitFailure 255) "" "permission denied",
                "exit 255: permission denied")
            , (RawProviderExit (ExitFailure 255) "unexpected " startup,
                "exit 255: unexpected Error: VM agent isn't currently running")
            , (RawProviderExit (ExitFailure 255) startup "",
                "exit 255: Error: VM agent isn't currently running")
            , (RawProviderExit (ExitFailure 255) "" (startup <> " after a transport failure"),
                "exit 255: Error: VM agent isn't currently running after a transport failure")
            ] $ \(raw, cause) ->
                classifyProviderProbe raw @?= Failed (ProbeFailure "provider probe" cause)
    , testCase "unit probes use exit status and retain unclassified failure details" $ do
        classifyProviderProbe (RawProviderExit ExitSuccess "arbitrary\noutput\0" "ignored")
            @?= ProbeReady ()
        classifyProviderProbe (RawProviderExit (ExitFailure 7) "" "permission denied\n")
            @?= Failed (ProbeFailure "provider probe" "exit 7: permission denied")
    , testCase "provider conflict markers require one bounded token line" $ do
        let marker = "HB_PROVIDER_CONFLICT expected:1 observed/2 identity-mismatch"
            conflict = ProbeConflict "expected:1" "observed/2"
                "resolve the provider identity conflict before retrying (identity-mismatch)"
        providerConflictMarker marker @?= Just conflict
        classifyProviderProbe (RawProviderFailure marker) @?= ProbeConflicted conflict
        forM_
            [ marker <> "\nextra"
            , "HB_PROVIDER_CONFLICT expected observed bad!token"
            , "HB_PROVIDER_CONFLICT " <> replicate 241 'x' <> " observed reason"
            , marker <> " extra"
            ] $ \invalid -> do
                providerConflictMarker invalid @?= Nothing
                classifyProviderProbe (RawProviderFailure invalid)
                    @?= Failed (ProbeFailure "provider probe" invalid)
    , testCase "probe folds hide Direct/tool dispatch" $ do
        foldExistsProbe
            (Left "direct")
            (\tool args membership -> Right (tool, args, membership))
            (providerExistsProbe direct)
            @?= (Left "direct" :: Either String (HostTool, [String], Membership))
        foldWaitProbe
            (Left "direct")
            (\tool args -> Right (tool, args))
            (providerWaitProbe windows)
            @?= (Right (Wsl, ["-d", "demo-vm", "--exec", "true"]) :: Either String (HostTool, [String]))
    , testCase "closed providers expose exact probe descriptions" $ do
        providerExistsProbe apple @?= ExistsProbe Lima ["list", "-q"] LinesMember
        providerExistsProbe linux @?= ExistsProbe Incus ["list", "--format", "csv", "-c", "n"] LinesMember
        providerExistsProbe windows @?= ExistsProbe Wsl ["--list", "--quiet"] WslQuietMember
        providerExistsProbe direct @?= DirectHostExistsProbe
        providerWaitProbe direct @?= DirectHostReadyProbe
    , testCase "provider planning keeps aliases in the prepared route" $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (assertFailure "could not locate the provider source root") pure
        source <- readFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "Substrate" </> "Provider.hs")
        forM_
            [ "AliasNodeKind", "AliasState", "AliasFacts", "classifyAlias", "trimTrailingSlash"
            , "AliasAction", "planAliasEnsure", "AliasRemoval", "planAliasRemove", "planProviderAlias"
            ] $ \name -> SourceGuard.countHaskellIdentifier name source @?= 0

    ]

interpreterCases :: [TestTree]
interpreterCases =
    [ testCase "membership parsers are total" $ do
        membersOf LinesMember "demo-vm\nother\n" @?= ["demo-vm", "other"]
        membersOf WslQuietMember (concatMap (\c -> [c, '\0']) ("demo-vm\nother\n" :: String))
            @?= ["demo-vm", "other"]
    , testCase "file staging retains each transport" $ do
        stageFileEffects (LimaFileTransfer (LimaVM "demo-vm")) "src.tgz" "/tmp/x.tgz"
            @?= StagedFile [hostToolEffect Lima ["copy", "src.tgz", "demo-vm:/tmp/x.tgz"]] "/tmp/x.tgz" True
        stageFileEffects (IncusFileTransfer (IncusVM "demo-vm" "images:ubuntu/24.04")) "src.tgz" "/tmp/x.tgz"
            @?= StagedFile [hostToolEffect Incus ["file", "push", "src.tgz", "demo-vm/tmp/x.tgz"]] "/tmp/x.tgz" True
        stageFileEffects DirectHostTransfer "/srv/demo/src.tgz" "/tmp/x.tgz"
            @?= StagedFile [] "/srv/demo/src.tgz" False
    , testCase "VM shell and Windows mount folds are descriptive" $ do
        vmShellArgs (ViaWsl2VM (Wsl2VM "d")) ["true"]
            @?= Just (Wsl, ["-d", "d", "--exec", "true"])
        let command = ["printf", "%s", "two words; $HOME 'quoted' *.txt"]
            vmRows =
                [ ( ViaVM (IncusVM "incus-vm" "image")
                  , Incus
                  , ["exec", "incus-vm", "--", "printf", "%s", "two words; $HOME 'quoted' *.txt"]
                  )
                , ( ViaLimaVM (LimaVM "lima-vm")
                  , Lima
                  , ["shell", "lima-vm", "--", "sudo", "-H", "printf", "%s", "two words; $HOME 'quoted' *.txt"]
                  )
                , ( ViaWsl2VM (Wsl2VM "wsl-distro")
                  , Wsl
                  , ["-d", "wsl-distro", "--exec", "printf", "%s", "two words; $HOME 'quoted' *.txt"]
                  )
                ]
        forM_ vmRows $ \(layer, tool, arguments) -> do
            vmShellArgs layer command @?= Just (tool, arguments)
            vmShellArgs layer [] @?= Nothing
        forM_ [ProviderGuestContainer, DirectHostContainer] $ \placement -> do
            let container =
                    ContainerLift
                        { clImage = "fixture:image"
                        , clPlacement = placement
                        , clMounts = []
                        , clExtraArgs = []
                        , clRemoveAfter = True
                        , clConfigDelivery = Nothing
                        }
            vmShellArgs (ViaContainer container) command @?= Nothing
        windowsPathToWslMount "C:\\Users\\Matt\\f.tgz" @?= "/mnt/c/Users/Matt/f.tgz"
    ]

{- | The provider boundary's durability is the protected store's, mechanically.

The partial-write, partial-fsync, and partial-unlink windows a durable record can
be interrupted in belong to the store that publishes it, and the store's own
contract is the
[ownership-clauses-and-reservations phase](../../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md)'s.
This boundary inherits it by holding no durable byte of its own: it names no
mutating filesystem primitive, so there is no instruction point here at which a
second durability window could exist to patch (§ NN).

The scan includes the provider facade and its entire module subtree. Explicit
read-only imports admit the Direct observations; all other filesystem imports
refuse, including unlisted handle writers and unrestricted imports. Publications
must occur beyond their import lists, both in the driver and in the record tape.
-}
inheritedDurabilityCases :: [TestTree]
inheritedDurabilityCases =
    [ testCase "the provider driver publishes every durable byte through the protected store" $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        let packageRoot = root </> "core" </> "hostbootstrap-core"
            substrateRoot = packageRoot </> "src" </> "HostBootstrap" </> "Substrate"
            providerPath = substrateRoot </> "Provider.hs"
            driverRoot = substrateRoot </> "Provider"
        provider <- readFile' providerPath
        sources <- ((providerPath, provider) :) <$> SourceGuard.readHaskellSources driverRoot
        forM_ sources $ \(path, source) -> do
            let violations = providerDurabilityImportViolations source
            assertBool (path ++ " has filesystem imports outside the observation boundary: " ++ show violations)
                (null violations)
            forM_ ["compareAndSwapProtectedRecord", "compareAndDeleteProtectedRecord"] $ \publication ->
                assertBool
                    (path ++ " reaches " ++ publication ++ " beside the tape rather than through it")
                    (SourceGuard.countHaskellIdentifier publication source == 0)
        ownership <-
            maybe (assertFailure "the provider ownership driver is absent from the scanned tree") pure
                (lookup (driverRoot </> "Ownership.hs") sources)
        forM_ ["publishFreshRecord", "publishBoundRecord", "forgetRecord"] $ \publication ->
            assertBool
                ("the driver no longer applies " ++ publication)
                (publicationIsApplied "HostBootstrap.Ownership.Tape" publication ownership)
        tape <-
            readFile'
                ( packageRoot
                    </> "internal"
                    </> "ownership"
                    </> "HostBootstrap"
                    </> "Ownership"
                    </> "Tape.hs"
                )
        forM_ ["compareAndSwapProtectedRecord", "compareAndDeleteProtectedRecord"] $ \publication ->
            assertBool
                ("the shared tape no longer applies " ++ publication)
                (publicationIsApplied "HostBootstrap.Protected" publication tape)
    , testCase "the import guard refuses writes and unrestricted filesystem imports" $ do
        forM_
            [ ( "System.Directory"
              , [ "renameFile", "renameDirectory", "renamePath", "removeFile", "removeDirectory"
                , "removeDirectoryRecursive", "removePathForcibly", "createDirectory"
                , "createDirectoryIfMissing", "copyFile", "copyFileWithMetadata", "copyPermissions"
                , "setPermissions", "setAccessTime", "setModificationTime", "createFileLink"
                , "createDirectoryLink", "removeDirectoryLink"
                ]
              )
            , ( "System.IO"
              , [ "writeFile", "appendFile", "openFile", "openBinaryFile", "withFile"
                , "withBinaryFile", "hFlush", "hClose", "hPutChar", "hPutStr", "hPutStrLn"
                , "hPutBuf", "hPutBufNonBlocking", "hSetFileSize", "openTempFile"
                , "openBinaryTempFile", "openTempFileWithDefaultPermissions"
                , "openBinaryTempFileWithDefaultPermissions"
                ]
              )
            ] $ \(moduleName, names) ->
                forM_ names $ \name ->
                    assertBool (moduleName ++ "." ++ name ++ " escapes the import guard")
                        (not (null (providerDurabilityImportViolations
                            ("import qualified " ++ moduleName ++ " as Files (" ++ name ++ ")"))))
        forM_
            [ "import System.Directory"
            , "import System.IO"
            , "import System.IO hiding (writeFile)"
            , "import System.IO (readFile)\nimport qualified System.IO as Other (hPutBuf)"
            ] $ \source ->
                assertBool ("an unrestricted or duplicate import escapes: " ++ source)
                    (not (null (providerDurabilityImportViolations source)))
        providerDurabilityImportViolations
            "import System.Directory (Permissions (readable, searchable, writable), getPermissions, doesDirectoryExist, pathIsSymbolicLink, canonicalizePath)"
            @?= []
        providerDurabilityImportViolations "import System.IO (readFile, readFile')" @?= []
        providerDurabilityImportViolations "-- import System.IO (writeFile)\nvalue = \"import System.Directory\"" @?= []
    , testCase "a publication import alone does not prove the publication is applied" $
        forM_
            [ ("HostBootstrap.Ownership.Tape", "publishFreshRecord")
            , ("HostBootstrap.Ownership.Tape", "publishBoundRecord")
            , ("HostBootstrap.Ownership.Tape", "forgetRecord")
            , ("HostBootstrap.Protected", "compareAndSwapProtectedRecord")
            , ("HostBootstrap.Protected", "compareAndDeleteProtectedRecord")
            ] $ \(moduleName, publication) -> do
                let imported = "import " ++ moduleName ++ " (" ++ publication ++ ")\n"
                publicationIsApplied moduleName publication imported @?= False
                publicationIsApplied moduleName publication
                    (imported ++ "-- " ++ publication ++ "\nvalue = " ++ show publication) @?= False
                publicationIsApplied moduleName publication
                    (imported ++ "value = " ++ publication ++ " tape key record") @?= True
    ]

-- | Only explicit, read-only filesystem imports belong to a provider decision.
-- Everything outside this small observation vocabulary belongs below the tape.
providerDurabilityImportViolations :: String -> [String]
providerDurabilityImportViolations source =
    concatMap check
        [ ( "System.Directory"
          , [ "Permissions", "readable", "searchable", "writable", "getPermissions"
            , "doesDirectoryExist", "pathIsSymbolicLink", "canonicalizePath"
            ]
          )
        , ("System.IO", ["readFile", "readFile'"])
        ]
  where
    check (moduleName, admitted)
        | not (SourceGuard.importsModule moduleName source) = []
        | otherwise = case SourceGuard.moduleImportTokens moduleName source of
            Nothing -> [moduleName ++ " requires one explicit read-only import list"]
            Just tokens ->
                [moduleName ++ "." ++ token | token <- tokens, token `notElem` (["(", ")", ","] ++ admitted)]

-- | The identifier must occur beyond its one explicit import-list occurrence.
publicationIsApplied :: String -> String -> String -> Bool
publicationIsApplied moduleName publication source =
    case SourceGuard.moduleImportTokens moduleName source of
        Nothing -> False
        Just tokens ->
            let imported = length (filter (== publication) tokens)
             in imported == 1 && SourceGuard.countHaskellIdentifier publication source > imported

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
