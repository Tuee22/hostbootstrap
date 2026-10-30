{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

module EnsureSpec (tests) where

import Control.Exception (AsyncException (UserInterrupt), bracket, finally, throwIO, try)
import qualified Data.ByteString as ByteString
import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TextIO
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import HostBootstrap.Command (allReconcilers)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Ensure (
    FramePlan (InstallHere),
    InstallStep (..),
    Reconciler (..),
    StepOutcome (..),
    appliesTo,
    classifyStepOutcome,
    decide,
    environmentNonRootUser,
    frameTable,
    grantSocketAccess,
    installAndVerifyWith,
    invokingNonRootUser,
    linuxGpuRow,
    linuxRow,
    reconcilerInstallSteps,
    reportedGpu,
    requirement,
    runReconciler,
    withInvokingGroupMemberWith,
    withProbeDir,
 )
import qualified HostBootstrap.Ensure.AppleMetal as AppleMetal
import qualified HostBootstrap.Ensure.Cuda as Cuda
import qualified HostBootstrap.Ensure.CudaWin as CudaWin
import qualified HostBootstrap.Ensure.Docker as Docker
import qualified HostBootstrap.Ensure.Ghc as Ghc
import qualified HostBootstrap.Ensure.Homebrew as Homebrew
import qualified HostBootstrap.Ensure.Incus as EIncus
import qualified HostBootstrap.Ensure.Lima as Lima
import qualified HostBootstrap.Ensure.Wsl2 as Wsl2
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (AbsExe, HostTool (..), ghcupBinCandidates, mkAbsExe)
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..), nvidiaDeviceMarker)
import PlatformPath (hostFixturePath)
import SourceGuard (
    haskellDefinitionNames,
    haskellDefinitionTokens,
    haskellTokens,
    importsModule,
    libraryModulePath,
    readPackageDescription,
    withPackageSourceIn,
 )
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, doesPathExist, getCurrentDirectory, getTemporaryDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, takeDirectory, takeFileName, (</>))
import System.IO (SeekMode (AbsoluteSeek), hClose, hFlush, hSeek, hSetNewlineMode, stderr, stdout, universalNewlineMode)
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
#ifndef mingw32_HOST_OS
import System.Posix.User (getEffectiveUserID, getUserEntryForID, userName)
#endif
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

apple, cpu, gpu, winCpu, winGpu :: Substrate
apple = Substrate AppleSilicon Arm64
cpu = Substrate LinuxCpu Amd64
gpu = Substrate LinuxGpu Amd64
winCpu = Substrate WindowsCpu Amd64
winGpu = Substrate WindowsGpu Amd64

findR :: String -> Reconciler
findR name = case filter ((== name) . reconcilerName) allReconcilers of
    (r : _) -> r
    [] -> error ("no reconciler named " ++ name)

tests :: TestTree
tests =
    testGroup
        "EnsureSpec"
        [ testGroup "applicability matrix" applicabilityCases
        , testGroup "the frame table a reconciler is a row over" frameTableCases
        , testGroup "decide" decideCases
        , testGroup "runReconciler" runCases
        , testGroup "install-step outcome classifier" stepOutcomeCases
        , testGroup "install-and-verify driver" installDriverCases
        , testGroup "invoking user and socket grants" groupMemberCases
        , testGroup "probe scratch directories" probeDirectoryCases
        , testGroup "install plans" installPlanCases
        , testGroup "Incus provider capability probe" incusProbeCases
        , testGroup "Incus observed convergence" incusConvergenceCases
        , testGroup "CUDA nvkind runtime probe" cudaProbeCases
        , testGroup "NVIDIA repository preparation" repositoryCases
        , testGroup "Docker group and socket verification" dockerGroupCases
        , testGroup "WSL platform status" wslStatusCases
        , testGroup "WSL prerequisite decisions" wslActionCases
        , testGroup "WSL2 prerequisite boundary" wslPrerequisiteCases
        ]

applicabilityCases :: [TestTree]
applicabilityCases =
    [ testCase "the nine context-free reconcilers are present (project Colima requires a prepared budget)" $
        map reconcilerName allReconcilers
            @?= ["docker", "apple-metal", "cuda", "cudawin", "homebrew", "ghc", "lima", "incus", "wsl2"]
    , testCase "docker applies to every substrate" $
        map (appliesTo (findR "docker")) [apple, cpu, gpu, winCpu, winGpu] @?= [True, True, True, True, True]
    , testCase "incus applies to apple AND linux (the first cross-substrate reconciler)" $
        map (appliesTo (findR "incus")) [apple, cpu, gpu, winCpu, winGpu] @?= [True, True, True, False, False]
    , testCase "apple-metal applies to apple-silicon only" $
        map (appliesTo (findR "apple-metal")) [apple, cpu, gpu, winCpu, winGpu] @?= [True, False, False, False, False]
    , testCase "cuda applies to linux-gpu only" $
        map (appliesTo (findR "cuda")) [apple, cpu, gpu, winCpu, winGpu] @?= [False, False, True, False, False]
    , testCase "cudawin applies to windows-gpu only" $
        map (appliesTo (findR "cudawin")) [apple, cpu, gpu, winCpu, winGpu] @?= [False, False, False, False, True]
    , testCase "homebrew applies to apple-silicon only" $
        map (appliesTo (findR "homebrew")) [apple, cpu, gpu] @?= [True, False, False]
    , testCase "ghc applies to apple-silicon only" $
        map (appliesTo (findR "ghc")) [apple, cpu, gpu] @?= [True, False, False]
    , testCase "lima applies to apple-silicon only" $
        map (appliesTo (findR "lima")) [apple, cpu, gpu] @?= [True, False, False]
    , testCase "wsl2 applies to Windows only" $
        map (appliesTo (findR "wsl2")) [apple, cpu, gpu, winCpu, winGpu] @?= [False, False, False, True, True]
    ]

{- | § LL: applicability, the diagnostic's requirement, and the install plan are
three views of one table rather than three fields that can disagree. These cases
assert the agreement itself, on every reconciler and every host — which is the
thing a per-module @case@ over the substrate tag could never state.
-}
frameTableCases :: [TestTree]
frameTableCases =
    [ testCase "an applicable host has a plan, and an inapplicable one has the diagnostic" $
        sequence_
            [ case (appliesTo r sub, reconcilerInstallSteps r sub) of
                (True, Left err) ->
                    assertBool
                        (reconcilerName r ++ " applies to this host but refuses a plan: " ++ err)
                        (not ("not applicable" `isInfixOf` err))
                (False, Left err) ->
                    err @?= renderDiagnostic r sub
                (False, Right steps) ->
                    assertBool
                        (reconcilerName r ++ " has no row here but produced " ++ show (length steps) ++ " step(s)")
                        False
                (True, Right _) -> pure ()
            | r <- allReconcilers
            , sub <- [apple, cpu, gpu, winCpu, winGpu]
            ]
    , testCase "the requirement a diagnostic quotes is the rows' own rendering" $
        map (\name -> (name, requirement (findR name))) (map reconcilerName allReconcilers)
            @?= [ ("docker", "all substrates")
                , ("apple-metal", "apple-silicon")
                , ("cuda", "linux-gpu")
                , ("cudawin", "windows-gpu")
                , ("homebrew", "apple-silicon")
                , ("ghc", "apple-silicon")
                , ("lima", "apple-silicon")
                , ("incus", "apple-silicon or linux")
                , ("wsl2", "windows")
                ]
    , testCase "an accelerator row is selected ahead of its frame's general row" $ do
        let generalSteps = [InstallStep Sudo ["apt-get", "install", "-y", "docker.io"]]
            gpuSteps = [InstallStep Sudo ["apt-get", "install", "-y", "nvidia-container-toolkit"]]
            fixture =
                Reconciler
                    { reconcilerName = "row-order-fixture"
                    , reconcilerSummary = "select a Linux frame row"
                    , reconcilerFrames = frameTable [linuxRow (InstallHere generalSteps), linuxGpuRow (InstallHere gpuSteps)]
                    , reconcile = const (pure ())
                    }
        reconcilerInstallSteps fixture gpu @?= Right gpuSteps
        reconcilerInstallSteps fixture cpu @?= Right generalSteps
        requirement fixture @?= "linux-gpu or linux"
    , testCase "a frame another frame owns is an absent row, not a second refusal" $ do
        -- incus is the linux and apple host provider; the WSL2 frame owns the
        -- Windows one. Saying so twice is how two answers to one question start
        -- to differ, so Windows is simply not a row.
        appliesTo (findR "incus") winCpu @?= False
        case reconcilerInstallSteps (findR "incus") winCpu of
            Left err -> err @?= renderDiagnostic (findR "incus") winCpu
            Right steps ->
                assertBool ("incus has no Windows plan: " ++ show steps) False
    ]
  where
    renderDiagnostic r sub = case decide r sub of
        Left err -> err
        Right _ -> "<applicable>"

decideCases :: [TestTree]
decideCases =
    [ testCase "decide is Left with a one-line diagnostic on the wrong host" $
        case decide (findR "homebrew") cpu of
            Left msg ->
                assertBool ("diagnostic mentions host + requirement: " ++ msg) $
                    "ensure homebrew" `isInfixOf` msg
                        && "linux-cpu" `isInfixOf` msg
                        && "apple-silicon" `isInfixOf` msg
            Right _ -> assertBool "expected Left for homebrew on linux-cpu" False
    , testCase "accelerator reconcilers reject the wrong host before side effects" $ do
        case decide AppleMetal.reconciler cpu of
            Left msg -> do
                assertBool "apple-metal diagnostic names the reconciler" ("ensure apple-metal" `isInfixOf` msg)
                assertBool "apple-metal diagnostic names the required substrate" ("apple-silicon" `isInfixOf` msg)
            Right _ -> assertBool "expected apple-metal to reject linux-cpu" False
        case decide CudaWin.reconciler winCpu of
            Left msg -> do
                assertBool "cudawin diagnostic names the reconciler" ("ensure cudawin" `isInfixOf` msg)
                assertBool "cudawin diagnostic names the required substrate" ("windows-gpu" `isInfixOf` msg)
            Right _ -> assertBool "expected cudawin to reject windows-cpu" False
    ]

runCases :: [TestTree]
runCases =
    [ testCase "wrong host: exits non-zero WITHOUT performing the action" $ do
        ref <- newIORef False
        let r = (findR "homebrew"){reconcile = \_ -> writeIORef ref True}
            cfg = HostConfig{hcSubstrate = cpu, hcToolPaths = Map.empty}
        result <- try (runReconciler r cfg) :: IO (Either ExitCode ())
        ran <- readIORef ref
        result @?= Left (ExitFailure 1)
        ran @?= False
    , testCase "right host: performs the reconcile action" $ do
        ref <- newIORef False
        let r = (findR "homebrew"){reconcile = \_ -> writeIORef ref True}
            cfg = HostConfig{hcSubstrate = apple, hcToolPaths = Map.empty}
        runReconciler r cfg
        ran <- readIORef ref
        ran @?= True
    ]

stepOutcomeCases :: [TestTree]
stepOutcomeCases =
    [ testCase "an ordinary successful step continues" $
        classifyStepOutcome Brew ["install", "demo"] (Right (ExitSuccess, "installed", ""))
            @?= StepContinue
    , testCase "an ordinary failed step retains the command, exit, and stderr" $
        classifyStepOutcome Sudo ["apt-get", "install", "-y", "demo"] (Right (ExitFailure 7, "progress", "permission denied"))
            @?= StepFailed "install step `sudo apt-get install -y demo` failed (exit 7) permission denied"
    , testCase "a runner refusal retains its exact text" $
        classifyStepOutcome Brew ["install", "demo"] (Left "resolved command is unavailable")
            @?= StepFailed "resolved command is unavailable"
    , testCase "winget's existing-package install failure is already installed" $
        classifyStepOutcome Winget ["install", "--id", "Microsoft.WSL"] (Right (ExitFailure 1, "Found an existing package already installed", ""))
            @?= StepAlreadyInstalled
    , testCase "winget's unavailable-upgrade install failure is already installed" $
        classifyStepOutcome Winget ["install", "--id", "Microsoft.WSL"] (Right (ExitFailure 2, "", "No available upgrade found"))
            @?= StepAlreadyInstalled
    , testCase "a successful winget install continues even when it reports an existing package" $
        classifyStepOutcome Winget ["install", "--id", "Microsoft.WSL"] (Right (ExitSuccess, "Found an existing package already installed", ""))
            @?= StepContinue
    , testCase "other winget install failures remain failures" $
        classifyStepOutcome Winget ["install", "--id", "Microsoft.WSL"] (Right (ExitFailure 3, "package searched", "source is unavailable"))
            @?= StepFailed "install step `winget install --id Microsoft.WSL` failed (exit 3) source is unavailable"
    , testCase "winget already-installed text does not soften a non-install command" $
        classifyStepOutcome Winget ["upgrade", "demo"] (Right (ExitFailure 4, "", "No available upgrade found"))
            @?= StepFailed "install step `winget upgrade demo` failed (exit 4) No available upgrade found"
    , testCase "successful WSL output recognizes a UTF-16-padded reboot request" $
        classifyStepOutcome Wsl ["--install", "--no-distribution"]
            (Right (ExitSuccess, utf16ish "Changes will not be effective until the system is rebooted", ""))
            @?= StepRebootRequired
    , testCase "failed WSL stderr recognizes a UTF-16-padded reboot request" $
        classifyStepOutcome Wsl ["--install", "--no-distribution"]
            (Right (ExitFailure 5, "", utf16ish "Changes will not be effective until the system is rebooted"))
            @?= StepRebootRequired
    , testCase "WSL restart text is case-insensitive after UTF-16 normalization" $
        classifyStepOutcome Wsl ["--status"] (Right (ExitSuccess, utf16ish "A system RESTART is required", ""))
            @?= StepRebootRequired
    , testCase "WSL install's special negative exit requests a reboot without text" $
        classifyStepOutcome Wsl ["--install", "--no-distribution"] (Right (ExitFailure (-1), "", ""))
            @?= StepRebootRequired
    , testCase "the same WSL negative exit on another command remains a failure" $
        classifyStepOutcome Wsl ["--status"] (Right (ExitFailure (-1), "", ""))
            @?= StepFailed "install step `wsl --status` failed (exit -1) "
    , testCase "successful Brew reboot text continues without a WSL reboot outcome" $
        classifyStepOutcome Brew ["install", "demo"]
            (Right (ExitSuccess, "Changes will not be effective until the system is rebooted", ""))
            @?= StepContinue
    , testCase "failed Brew reboot text retains the ordinary failure" $
        classifyStepOutcome Brew ["install", "demo"] (Right (ExitFailure 6, "", "restart required"))
            @?= StepFailed "install step `brew install demo` failed (exit 6) restart required"
    ]

data InstallDriverEvent
    = Probed Substrate Bool
    | RanStep Substrate HostTool [String]
    | Refreshed Substrate
    deriving (Eq, Show)

installDriverCases :: [TestTree]
installDriverCases =
    [ testCase "present dependency is a verified no-op" $ do
        events <- newIORef []
        let note event = modifyIORef' events (++ [event])
            probe cfg = note (Probed (hcSubstrate cfg) True) >> pure True
            runner cfg tool args = note (RanStep (hcSubstrate cfg) tool args) >> pure (Right (ExitSuccess, "", ""))
            refresh cfg = note (Refreshed (hcSubstrate cfg)) >> pure cfg
            plan _ = error "present dependency must not evaluate its install plan"
        installAndVerifyWith runner refresh "test" probe plan cpuConfig
        readIORef events >>= (@?= [Probed cpu True])
    , testCase "absent dependency runs every step, verifies, then a second invocation is a no-op" $ do
        installed <- newIORef False
        events <- newIORef []
        let note event = modifyIORef' events (++ [event])
            probe cfg = do
                present <- readIORef installed
                note (Probed (hcSubstrate cfg) present)
                pure present
            runner cfg tool args = do
                note (RanStep (hcSubstrate cfg) tool args)
                if tool == Ghcup
                    then writeIORef installed True
                    else pure ()
                pure (Right (ExitSuccess, "", ""))
            refresh cfg = note (Refreshed (hcSubstrate cfg)) >> pure cfg{hcSubstrate = gpu}
            steps = [InstallStep Brew ["install", "demo"], InstallStep Ghcup ["install", "demo"]]
        installAndVerifyWith runner refresh "test" probe (const (Right steps)) cpuConfig
        installAndVerifyWith runner refresh "test" probe (const (Right steps)) cpuConfig
        readIORef events
            >>= ( @?=
                    [ Probed cpu False
                    , RanStep cpu Brew ["install", "demo"]
                    , Refreshed cpu
                    , RanStep gpu Ghcup ["install", "demo"]
                    , Refreshed gpu
                    , Probed gpu True
                    , Probed cpu True
                    ]
                )
    , testCase "winget already-installed failure refreshes before a successful re-probe" $ do
        refreshed <- newIORef False
        events <- newIORef []
        let note event = modifyIORef' events (++ [event])
            probe cfg = do
                present <- readIORef refreshed
                note (Probed (hcSubstrate cfg) present)
                pure present
            runner cfg tool args = do
                note (RanStep (hcSubstrate cfg) tool args)
                pure (Right (ExitFailure 1, "Found an existing package already installed", ""))
            refresh cfg = do
                note (Refreshed (hcSubstrate cfg))
                writeIORef refreshed True
                pure cfg{hcSubstrate = winGpu}
            installArgs = ["install", "--id", "Microsoft.WSL"]
            initialConfig = HostConfig{hcSubstrate = winCpu, hcToolPaths = Map.empty}
        installAndVerifyWith runner refresh "test" probe (const (Right [InstallStep Winget installArgs])) initialConfig
        readIORef events
            >>= (@?= [Probed winCpu False, RanStep winCpu Winget installArgs, Refreshed winCpu, Probed winGpu True])
    , testCase "post-install verification failure exits after the final probe" $ do
        events <- newIORef []
        let note event = modifyIORef' events (++ [event])
            probe cfg = note (Probed (hcSubstrate cfg) False) >> pure False
            runner cfg tool args = note (RanStep (hcSubstrate cfg) tool args) >> pure (Right (ExitSuccess, "", ""))
            refresh cfg = note (Refreshed (hcSubstrate cfg)) >> pure cfg
            steps = [InstallStep Brew ["install", "demo"]]
        result <- try (installAndVerifyWith runner refresh "test" probe (const (Right steps)) cpuConfig) :: IO (Either ExitCode ())
        result @?= Left (ExitFailure 1)
        readIORef events
            >>= (@?= [Probed cpu False, RanStep cpu Brew ["install", "demo"], Refreshed cpu, Probed cpu False])
    , testCase "plan refusal exits before any install or refresh effect" $ do
        events <- newIORef []
        let note event = modifyIORef' events (++ [event])
            probe cfg = note (Probed (hcSubstrate cfg) False) >> pure False
            runner cfg tool args = note (RanStep (hcSubstrate cfg) tool args) >> pure (Right (ExitSuccess, "", ""))
            refresh cfg = note (Refreshed (hcSubstrate cfg)) >> pure cfg
        result <- try (installAndVerifyWith runner refresh "test" probe (const (Left "unsupported host")) cpuConfig) :: IO (Either ExitCode ())
        result @?= Left (ExitFailure 1)
        readIORef events >>= (@?= [Probed cpu False])
    , testCase "failed install step exits without refresh or post-install verification" $ do
        events <- newIORef []
        let note event = modifyIORef' events (++ [event])
            probe cfg = note (Probed (hcSubstrate cfg) False) >> pure False
            runner cfg tool args = note (RanStep (hcSubstrate cfg) tool args) >> pure (Right (ExitFailure 7, "", "step failed"))
            refresh cfg = note (Refreshed (hcSubstrate cfg)) >> pure cfg
            steps = [InstallStep Brew ["install", "demo"]]
        result <- try (installAndVerifyWith runner refresh "test" probe (const (Right steps)) cpuConfig) :: IO (Either ExitCode ())
        result @?= Left (ExitFailure 1)
        readIORef events >>= (@?= [Probed cpu False, RanStep cpu Brew ["install", "demo"]])
    , testCase "a WSL install reboot stops before refresh, default-version setting, or verification" $ do
        events <- newIORef []
        let note event = modifyIORef' events (++ [event])
            probe cfg = note (Probed (hcSubstrate cfg) False) >> pure False
            runner cfg tool args = note (RanStep (hcSubstrate cfg) tool args) >> pure (Right (ExitFailure (-1), "", ""))
            refresh cfg = note (Refreshed (hcSubstrate cfg)) >> pure cfg
            steps = [InstallStep Wsl ["--install", "--no-distribution"], InstallStep Wsl ["--set-default-version", "2"]]
            initialConfig = HostConfig{hcSubstrate = winCpu, hcToolPaths = Map.empty}
        captured <- captureEnsureExit (installAndVerifyWith runner refresh "wsl2" probe (const (Right steps)) initialConfig)
        captured
            @?= ( Left (ExitFailure 1)
                , "ensure wsl2: installing (2 step(s))\n"
                , "ensure wsl2: host reboot required after WSL2 install; reboot and retry\n"
                )
        readIORef events >>= (@?= [Probed winCpu False, RanStep winCpu Wsl ["--install", "--no-distribution"]])
    ]

data GroupMemberEvent
    = LookedUpEffectiveUser
    | RanPrivileged [String]
    | EnteredSocketGrant String
    deriving (Eq, Show)

groupMemberCases :: [TestTree]
groupMemberCases =
    [ testCase "the environment user bypasses euid lookup and grants each daemon's real socket ACL after usermod" $
        mapM_
            ( \(label, groupName, socket, user, progress, groupArguments, aclArguments) -> do
                (captured, events) <-
                    recordGroupWorkflowFor label groupName socket [("SUDO_USER", user), ("USER", "root")] Nothing (const (Right (ExitSuccess, "", "")))
                captured @?= (Right (), progress, "")
                events
                    @?= [ RanPrivileged groupArguments
                        , EnteredSocketGrant user
                        , RanPrivileged aclArguments
                        ]
            )
            [ ( "ensure docker"
              , "docker"
              , "/var/run/docker.sock"
              , "matt"
              , "ensure docker: ensuring matt belongs to docker\n"
              , ["usermod", "-aG", "docker", "matt"]
              , ["setfacl", "-m", "u:matt:rw", "/var/run/docker.sock"]
              )
            , ( "ensure incus"
              , "incus-admin"
              , "/var/lib/incus/unix.socket"
              , "alex"
              , "ensure incus: ensuring alex belongs to incus-admin\n"
              , ["usermod", "-aG", "incus-admin", "alex"]
              , ["setfacl", "-m", "u:alex:rw", "/var/lib/incus/unix.socket"]
              )
            ]
    , testCase "a root-only environment invokes the euid fallback before granting membership" $ do
        (captured, events) <- recordGroupWorkflow [("USER", "root")] (Just "matt") (const (Right (ExitSuccess, "", "")))
        captured @?= (Right (), "ensure docker: ensuring matt belongs to docker\n", "")
        events
            @?= [ LookedUpEffectiveUser
                , RanPrivileged ["usermod", "-aG", "docker", "matt"]
                , EnteredSocketGrant "matt"
                , RanPrivileged ["setfacl", "-m", "u:matt:rw", "/var/run/docker.sock"]
                ]
    , testCase "a missing invoking user reports the exact skip without privileged work or a callback" $ do
        (captured, events) <- recordGroupWorkflow [("USER", "root")] Nothing (const (Right (ExitSuccess, "", "")))
        captured @?= (Right (), "ensure docker: no non-root invoking user detected for docker membership (skipping)\n", "")
        events @?= [LookedUpEffectiveUser]
    , testCase "a nonzero usermod exit names the label, step, and code without granting an ACL" $ do
        (captured, events) <- recordGroupWorkflow [("USER", "matt")] Nothing (const (Right (ExitFailure 7, "", "usermod denied")))
        captured
            @?= ( Left (ExitFailure 1)
                , "ensure docker: ensuring matt belongs to docker\n"
                , "ensure docker: could not add matt to docker (exit 7) usermod denied\n"
                )
        events @?= [RanPrivileged ["usermod", "-aG", "docker", "matt"]]
    , testCase "a usermod runner refusal retains its label and reason without granting an ACL" $ do
        (captured, events) <- recordGroupWorkflow [("USER", "matt")] Nothing (const (Left "sudo transport is unavailable"))
        captured
            @?= ( Left (ExitFailure 1)
                , "ensure docker: ensuring matt belongs to docker\n"
                , "ensure docker: sudo transport is unavailable\n"
                )
        events @?= [RanPrivileged ["usermod", "-aG", "docker", "matt"]]
    , testCase "a socket ACL failure uses the same checked-step diagnostic" $ do
        let runner arguments = case arguments of
                "setfacl" : _ -> Right (ExitFailure 8, "", "ACL denied")
                _ -> Right (ExitSuccess, "", "")
        (captured, events) <- recordGroupWorkflow [("USER", "matt")] Nothing runner
        captured
            @?= ( Left (ExitFailure 1)
                , "ensure docker: ensuring matt belongs to docker\n"
                , "ensure docker: could not grant matt immediate access to /var/run/docker.sock (exit 8) ACL denied\n"
                )
        events
            @?= [ RanPrivileged ["usermod", "-aG", "docker", "matt"]
                , EnteredSocketGrant "matt"
                , RanPrivileged ["setfacl", "-m", "u:matt:rw", "/var/run/docker.sock"]
                ]
    , testCase "the native euid fallback agrees with the effective user's passwd entry" $ do
        expected <- nativeEffectiveUser
        invokingNonRootUser [("USER", "root")] >>= (@?= expected)
    ]

recordGroupWorkflow ::
    [(String, String)] ->
    Maybe String ->
    ([String] -> Either String (ExitCode, String, String)) ->
    IO ((Either ExitCode (), String, String), [GroupMemberEvent])
recordGroupWorkflow = recordGroupWorkflowFor "ensure docker" "docker" "/var/run/docker.sock"

recordGroupWorkflowFor ::
    String ->
    String ->
    FilePath ->
    [(String, String)] ->
    Maybe String ->
    ([String] -> Either String (ExitCode, String, String)) ->
    IO ((Either ExitCode (), String, String), [GroupMemberEvent])
recordGroupWorkflowFor label groupName socket environment selected respond = do
    events <- newIORef []
    let note event = modifyIORef' events (++ [event])
        lookupUser = note LookedUpEffectiveUser >> pure selected
        runner arguments = note (RanPrivileged arguments) >> pure (respond arguments)
        grant checkedStep user = do
            note (EnteredSocketGrant user)
            grantSocketAccess checkedStep socket user
    captured <-
        captureEnsureExit $
            withInvokingGroupMemberWith environment lookupUser runner label groupName grant
    observed <- readIORef events
    pure (captured, observed)

captureEnsureExit :: IO () -> IO (Either ExitCode (), String, String)
captureEnsureExit action =
    withSystemTempFile "hostbootstrap-ensure-stdout" $ \_ output ->
        withSystemTempFile "hostbootstrap-ensure-stderr" $ \_ errors -> do
            hFlush stdout
            hFlush stderr
            result <-
                bracket
                    (hDuplicate stdout)
                    (\saved -> hFlush stdout `finally` (hDuplicateTo saved stdout `finally` hClose saved))
                    ( \_ ->
                        bracket
                            (hDuplicate stderr)
                            (\saved -> hFlush stderr `finally` (hDuplicateTo saved stderr `finally` hClose saved))
                            (\_ -> hDuplicateTo output stdout >> hDuplicateTo errors stderr >> try action)
                    )
            hSeek output AbsoluteSeek 0
            hSeek errors AbsoluteSeek 0
            hSetNewlineMode output universalNewlineMode
            hSetNewlineMode errors universalNewlineMode
            out <- TextIO.hGetContents output
            err <- TextIO.hGetContents errors
            pure (result, Text.unpack out, Text.unpack err)

nativeEffectiveUser :: IO (Maybe String)
#ifdef mingw32_HOST_OS
nativeEffectiveUser = pure Nothing
#else
nativeEffectiveUser = do
    effective <- getEffectiveUserID
    if effective == 0
        then pure Nothing
        else do
            entry <- try (userName <$> getUserEntryForID effective) :: IO (Either IOError String)
            pure (either (const Nothing) Just entry)
#endif

probeDirectoryCases :: [TestTree]
probeDirectoryCases =
    [ testCase "a successful probe uses a real file and removes its directory" $
        withOwnedProbePrefix $ \prefix -> do
            observed <- newIORef Nothing
            let payload = ByteString.pack [0, 255, 13, 10, 128]
            result <- withProbeDir prefix $ \directory -> do
                let marker = directory </> "probe.bin"
                ByteString.writeFile marker payload
                actual <- ByteString.readFile marker
                writeIORef observed (Just (directory, actual))
                pure True
            result @?= True
            (directory, actual) <- requireProbeObservation "successful probe" observed
            actual @?= payload
            doesPathExist directory >>= (@?= False)
    , testCase "an IOError is a failed probe and still removes its directory" $
        withOwnedProbePrefix $ \prefix -> do
            observed <- newIORef Nothing
            result <- withProbeDir prefix $ \directory -> do
                ByteString.writeFile (directory </> "probe.bin") (ByteString.pack [1, 2, 3])
                writeIORef observed (Just directory)
                ioError (userError "probe fixture IOError")
            result @?= False
            directory <- requireProbeObservation "IOError probe" observed
            doesPathExist directory >>= (@?= False)
    , testCase "UserInterrupt escapes a probe after its directory is removed" $
        withOwnedProbePrefix $ \prefix -> do
            observed <- newIORef Nothing
            result <-
                try
                    ( withProbeDir prefix $ \directory -> do
                        ByteString.writeFile (directory </> "probe.bin") (ByteString.pack [1, 2, 3])
                        writeIORef observed (Just directory)
                        throwIO UserInterrupt
                    ) ::
                    IO (Either AsyncException Bool)
            result @?= Left UserInterrupt
            directory <- requireProbeObservation "interrupted probe" observed
            doesPathExist directory >>= (@?= False)
    , testCase "nested probes with the same prefix keep distinct live directories" $
        withOwnedProbePrefix $ \prefix -> do
            outerObserved <- newIORef Nothing
            innerObserved <- newIORef Nothing
            liveObserved <- newIORef Nothing
            let payload = ByteString.pack [0, 255, 13, 10, 128]
            result <- withProbeDir prefix $ \outer -> do
                let marker = outer </> "outer.bin"
                ByteString.writeFile marker payload
                writeIORef outerObserved (Just outer)
                innerResult <- withProbeDir prefix $ \inner -> do
                    ByteString.writeFile (inner </> "inner.bin") (ByteString.pack [4, 5, 6])
                    writeIORef innerObserved (Just inner)
                    pure True
                innerPath <- readIORef innerObserved
                innerAbsent <- maybe (pure False) (fmap not . doesPathExist) innerPath
                outerAlive <- doesDirectoryExist outer
                sentinelPresent <- doesFileExist marker
                bytes <- if sentinelPresent then ByteString.readFile marker else pure ByteString.empty
                writeIORef liveObserved (Just (innerResult, innerAbsent, outerAlive, bytes))
                pure True
            outer <- requireProbeObservation "outer nested probe" outerObserved
            inner <- requireProbeObservation "inner nested probe" innerObserved
            assertBool "nested probes reused one directory" (outer /= inner)
            result @?= True
            live <- requireProbeObservation "state after inner cleanup" liveObserved
            live @?= (True, True, True, payload)
            doesPathExist outer >>= (@?= False)
            doesPathExist inner >>= (@?= False)
    ]

-- A fresh owned basename and a checked-absent temp/name target keep even a
-- fixed-name implementation from deleting an operator's temporary bytes.
withOwnedProbePrefix :: (FilePath -> IO result) -> IO result
withOwnedProbePrefix use =
    withSystemTempDirectory "hostbootstrap-probe-owner" $ \owner -> do
        let prefix = takeFileName owner <> "-probe"
        assertBool "probe prefix contains a path separator" (all (`notElem` "/\\") prefix)
        temporary <- getTemporaryDirectory
        doesPathExist (temporary </> prefix) >>= (@?= False)
        use prefix

requireProbeObservation :: String -> IORef (Maybe value) -> IO value
requireProbeObservation label observed =
    readIORef observed >>= maybe (assertFailure (label <> " callback was not observed")) pure

cpuConfig :: HostConfig
cpuConfig = HostConfig{hcSubstrate = cpu, hcToolPaths = Map.empty}

{- | The pure, substrate-branched install planners (install-and-verify, § L):
Homebrew formulae on apple-silicon; apt/ghcup/container-toolkit on linux. The
driver's control flow is covered above through its injectable effects; these
assert each reconciler's pure plan.
-}
installPlanCases :: [TestTree]
installPlanCases =
    [ testCase "lima: brew install lima on apple" $
        Lima.installSteps apple @?= Right [InstallStep Brew ["install", "lima"]]
    , testCase "wsl2: winget WSL, platform enablement, and WSL2 default on Windows" $ do
        Wsl2.installSteps winCpu
            @?= Right
                [ InstallStep Winget ["install", "--id", "Microsoft.WSL", "--exact", "--accept-package-agreements", "--accept-source-agreements"]
                , InstallStep Wsl ["--install", "--no-distribution"]
                , InstallStep Wsl ["--set-default-version", "2"]
                ]
        assertBool "wsl2 Left on linux-cpu" (isLeft (Wsl2.installSteps cpu))
    , testCase "ghcup discovery uses its explicit install-base prefix ahead of HOME" $
        ghcupBinCandidates [("GHCUP_INSTALL_BASE_PREFIX", "/opt/toolchains"), ("HOME", "/home/operator")]
            @?= ["/opt/toolchains/.ghcup/bin"]
    , testCase "ghcup discovery defaults to the HOME installation directory" $
        ghcupBinCandidates [("HOME", "/home/operator")]
            @?= ["/home/operator/.ghcup/bin"]
    , testCase "ghcup discovery has no candidate without an installation root" $
        ghcupBinCandidates [] @?= []
    , testCase "ghc: brew ghcup then install and select the recommended GHC on apple" $
        Ghc.installSteps apple
            @?= Right [InstallStep Brew ["install", "ghcup"], InstallStep Ghcup ["install", "ghc", "--set", "recommended"]]
    , testCase "homebrew: an absent host minimum names the operator's install instruction" $
        Homebrew.installSteps apple
            @?= Left "Homebrew is the host toolchain root; the Python bootstrapper asserts it as a host minimum. Install from https://brew.sh and retry."
    , testCase "docker: apt install on linux, delegate Apple and Windows host providers" $ do
        let linux =
                Right
                    [ InstallStep Sudo ["apt-get", "update"]
                    , InstallStep Sudo ["apt-get", "install", "-y", "docker.io", "docker-buildx", "acl"]
                    , InstallStep Sudo ["systemctl", "enable", "--now", "docker"]
                    ]
        Docker.installSteps cpu @?= linux
        Docker.installSteps gpu @?= linux
        Docker.installSteps apple
            @?= Left "on Apple silicon Docker is provided by the prepared per-project Colima provider wall"
        Docker.installSteps winCpu
            @?= Left "docker is reconciled by the Windows WSL2 host-provider path, not `ensure docker`"
        Docker.installSteps winGpu
            @?= Left "docker is reconciled by the Windows WSL2 host-provider path, not `ensure docker`"
    , testCase "the group grant prefers the invoking sudo user and skips root" $ do
        -- One case, because there is now one implementation. The Docker and Incus
        -- grants each carried an identical copy of this lookup and only Incus grew
        -- the euid fallback beside it, so a host whose service runner omits the
        -- login-user environment silently skipped the docker grant while
        -- performing the incus one. Two identical test blocks could not see that:
        -- they tested the halves that agreed.
        environmentNonRootUser [("SUDO_USER", "matt"), ("USER", "root")] @?= Just "matt"
        environmentNonRootUser [("SUDO_USER", "root"), ("LOGNAME", "matt"), ("USER", "root")]
            @?= Just "matt"
        environmentNonRootUser [("SUDO_USER", "root"), ("USER", "root")] @?= Nothing
        environmentNonRootUser [("USER", "")] @?= Nothing
        -- The IO path both grants now share keeps environment identity first, so
        -- @sudo@ still grants the original operator rather than the effective
        -- passwd entry. The euid fallback beneath it is POSIX-only and is reached
        -- only when the environment names nobody.
        invokingNonRootUser [("SUDO_USER", "matt"), ("USER", "root")]
            >>= (@?= Just "matt")
    , testCase "cuda: container toolkit on linux-gpu, Left elsewhere" $ do
        Cuda.repositoryToolSteps
            @?= [ InstallStep Sudo ["apt-get", "update"]
                , InstallStep Sudo ["apt-get", "install", "-y", "--no-install-recommends", "curl", "gnupg2"]
                ]
        Cuda.installSteps gpu
            @?= Right
                [ InstallStep Sudo ["apt-get", "update"]
                , InstallStep Sudo ["apt-get", "install", "-y", "nvidia-container-toolkit"]
                , InstallStep Sudo ["nvidia-ctk", "runtime", "configure", "--runtime=docker", "--set-as-default", "--cdi.enabled"]
                , InstallStep Sudo ["nvidia-ctk", "config", "--set", "accept-nvidia-visible-devices-as-volume-mounts=true", "--in-place"]
                , InstallStep Sudo ["systemctl", "restart", "docker"]
                ]
        assertBool "cuda Left on linux-cpu" (isLeft (Cuda.installSteps cpu))
    , testCase "apple-metal: no package-manager plan; Xcode CLT supplies the stack" $ do
        assertBool "apple-metal reports its CLT remediation on apple-silicon" $
            case AppleMetal.installSteps apple of
                Left msg -> "Xcode Command Line Tools" `isInfixOf` msg
                Right _ -> False
        assertBool "apple-metal Left on linux-cpu" (isLeft (AppleMetal.installSteps cpu))
    , testCase "apple-metal: pure SDK and Swift/Metal probe builders" $ do
        AppleMetal.macosSdkArgs @?= ["--sdk", "macosx", "--show-sdk-path"]
        AppleMetal.systemProfilerMetalArgs @?= ["SPDisplaysDataType"]
        AppleMetal.swiftMetalCompileArgs "/SDK" "/tmp/MetalProbe.swift" "/tmp/metal-probe"
            @?= ["-O", "-sdk", "/SDK", "/tmp/MetalProbe.swift", "-o", "/tmp/metal-probe", "-framework", "Metal"]
        assertBool "probe source creates a Metal device" $
            "MTLCreateSystemDefaultDevice" `isInfixOf` AppleMetal.swiftMetalProbeSource
    , testCase "cudawin: winget installs CUDA Toolkit, MSVC workload, and LLVM on windows-gpu only" $ do
        CudaWin.installSteps winGpu
            @?= Right
                [ InstallStep
                    Winget
                    [ "install"
                    , "--id"
                    , "Nvidia.CUDA"
                    , "--exact"
                    , "--silent"
                    , "--disable-interactivity"
                    , "--accept-package-agreements"
                    , "--accept-source-agreements"
                    ]
                , InstallStep
                    Winget
                    [ "install"
                    , "--id"
                    , "Microsoft.VisualStudio.2022.BuildTools"
                    , "--exact"
                    , "--silent"
                    , "--disable-interactivity"
                    , "--accept-package-agreements"
                    , "--accept-source-agreements"
                    , "--override"
                    , "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
                    ]
                , InstallStep
                    Winget
                    [ "install"
                    , "--id"
                    , "LLVM.LLVM"
                    , "--exact"
                    , "--silent"
                    , "--disable-interactivity"
                    , "--accept-package-agreements"
                    , "--accept-source-agreements"
                    ]
                ]
        assertBool "cudawin Left on windows-cpu" (isLeft (CudaWin.installSteps winCpu))
    , testCase "cudawin: pure probe builders select clang, VS Build Tools, and nvcc -ccbin" $ do
        CudaWin.clangVersionArgs @?= ["--version"]
        CudaWin.vswhereVCToolsArgs
            @?= [ "-latest"
                , "-products"
                , "*"
                , "-requires"
                , "Microsoft.VisualStudio.Workload.VCTools"
                , "-property"
                , "installationPath"
                ]
        CudaWin.cudaSmokeCompileArgs "C:\\VS\\VC\\bin" "C:\\tmp\\cuda_smoke.cu" "C:\\tmp\\cuda_smoke.exe"
            @?= ["-ccbin", "C:\\VS\\VC\\bin", "C:\\tmp\\cuda_smoke.cu", "-o", "C:\\tmp\\cuda_smoke.exe"]
        assertBool "smoke source has a CUDA kernel" $
            "__global__ void hostbootstrap_probe_kernel" `isInfixOf` CudaWin.cudaSmokeSource
    , testCase "incus: Colima-backed provider on apple, native daemon on linux" $ do
        EIncus.installSteps apple
            @?= Right
                [ InstallStep Brew ["install", "incus"]
                , InstallStep Brew ["install", "colima"]
                , InstallStep Colima ["start", EIncus.appleIncusProfile, "--runtime", "incus"]
                ]
        let linux =
                Right
                    [ InstallStep Sudo ["apt-get", "install", "-y", "incus", "acl"]
                    ]
        EIncus.installSteps cpu @?= linux
        EIncus.installSteps gpu @?= linux
    ]

incusProbeCases :: [TestTree]
incusProbeCases =
    [ testCase "a configured missing client cannot run the capability callback" $ do
        callbacks <- newIORef (0 :: Int)
        let cfg = HostConfig{hcSubstrate = cpu, hcToolPaths = Map.empty}
        result <- EIncus.withIncusProviderCapability cfg (\_ -> modifyIORef' callbacks (+ 1))
        -- A callback returns a pure result, which here is an IO action. Execute
        -- any admitted result before observing the counter, so accidental
        -- admission cannot hide behind an unevaluated callback action.
        observed <- traverse id result
        observed @?= Left "Incus provider is not usable: IncusClientMissing"
        readIORef callbacks >>= (@?= 0)
    , testCase "daemon absence, permissions, and transport failure remain distinct" $ do
        EIncus.classifyIncusProviderStatus True (failed "connect: no such file") ok ok
            @?= EIncus.IncusDaemonAbsent "exit 1: connect: no such file"
        EIncus.classifyIncusProviderStatus True (failed "permission denied") ok ok
            @?= EIncus.IncusPermissionDenied "exit 1: permission denied"
        EIncus.classifyIncusProviderStatus True (Left "transport closed") ok ok
            @?= EIncus.IncusDaemonUnreachable "transport closed"
    , testCase "VM capability and image-source egress are required after daemon reachability" $ do
        EIncus.classifyIncusProviderStatus True ok (failed "qemu missing") ok
            @?= EIncus.IncusVMIncapable "exit 1: qemu missing"
        EIncus.classifyIncusProviderStatus True ok ok (failed "remote unreachable")
            @?= EIncus.IncusNoEgress "exit 1: remote unreachable"
    , testCase "daemon permission failure takes precedence over VM and egress failures" $ do
        let status = EIncus.classifyIncusProviderStatus True (failed "permission denied") (failed "qemu") (failed "x")
        status @?= EIncus.IncusPermissionDenied "exit 1: permission denied"
        EIncus.incusProviderStatusResult status
            @?= Left "Incus provider is not usable: IncusPermissionDenied \"exit 1: permission denied\""
    , testCase "VM-capability failure takes precedence over egress failure" $ do
        let status = EIncus.classifyIncusProviderStatus True ok (failed "qemu") (failed "x")
        status @?= EIncus.IncusVMIncapable "exit 1: qemu"
        EIncus.incusProviderStatusResult status
            @?= Left "Incus provider is not usable: IncusVMIncapable \"exit 1: qemu\""
    , testCase "the complete classifier row passes the descriptive status check" $ do
        let status = EIncus.classifyIncusProviderStatus True ok ok ok
        EIncus.incusProviderStatusResult status @?= Right ()
    , testCase "capability admission observes its configuration before checking status and minting" $ do
        -- DEVELOPMENT_PLAN/rationale.md: "Incus capability admission performs its own observation".
        source <- readIncusSource
        gate <- either assertFailure pure (haskellDefinitionTokens "withIncusProviderCapability" source)
        gate
            @?= haskellTokens
                ( unlines
                    [ "withIncusProviderCapability cfg consume = do"
                    , "    status <- probeIncusProviderStatus cfg"
                    , "    pure $ do"
                    , "        incusProviderStatusResult status"
                    , "        pure (consume IncusProviderCapability)"
                    ]
                )
        caller <- either assertFailure pure (haskellDefinitionTokens "verifyUsableProvider" source)
        caller
            @?= haskellTokens
                ( unlines
                    [ "verifyUsableProvider cfg = do"
                    , "    admitted <- withIncusProviderCapability cfg (const ())"
                    , "    case admitted of"
                    , "        Right () -> putStrLn \"ensure incus: daemon, VM capability, and image-source egress ready\""
                    , "        Left err -> die (\"ensure incus: \" ++ err)"
                    ]
                )
    , testCase "virtiofsd candidates retain Incus's literal search order" $ do
        -- A host with QEMU and OVMF but no virtiofsd launches VMs and then fails
        -- every durable-share attach, so "usable" (§ L) has to include it. The
        -- candidate list is Incus's own search order.
        EIncus.virtiofsdCandidatePaths
            @?= [ "/usr/libexec/virtiofsd"
                , "/usr/lib/qemu/virtiofsd"
                , "/usr/lib/virtiofsd"
                ]
    , testCase "Incus capability, forwarding, and module loading use no interpreter programs" $
        -- DEVELOPMENT_PLAN/rationale.md: "Incus convergence observes gaps before executing argv".
        withPackageSourceIn [] $ \packageRoot _ -> do
            description <- readPackageDescription
            path <- libraryModulePath packageRoot description "HostBootstrap.Ensure.Incus"
            source <- readFile path
            definitions <- either assertFailure pure (haskellDefinitionNames source)
            assertBool "the shell capability probe is still defined" $
                "linuxVmCapabilityProbeScript" `notElem` definitions
            mapM_
                (\program -> assertBool ("Incus still invokes " ++ program) (show program `notElem` haskellTokens source))
                ["sh", "bash"]
    ]
        <> [ testCase ("the descriptive eliminator refuses " ++ label) $
                EIncus.incusProviderStatusResult status @?= Left reason
           | (label, status, reason) <-
                [ ( "a missing client"
                  , EIncus.classifyIncusProviderStatus False ok ok ok
                  , "Incus provider is not usable: IncusClientMissing"
                  )
                , ( "an absent daemon"
                  , EIncus.classifyIncusProviderStatus True (failed "connect: no such file") ok ok
                  , "Incus provider is not usable: IncusDaemonAbsent \"exit 1: connect: no such file\""
                  )
                , ( "denied daemon access"
                  , EIncus.classifyIncusProviderStatus True (failed "permission denied") ok ok
                  , "Incus provider is not usable: IncusPermissionDenied \"exit 1: permission denied\""
                  )
                , ( "an unreachable daemon"
                  , EIncus.classifyIncusProviderStatus True (Left "transport closed") ok ok
                  , "Incus provider is not usable: IncusDaemonUnreachable \"transport closed\""
                  )
                , ( "missing VM capability"
                  , EIncus.classifyIncusProviderStatus True ok (failed "qemu missing") ok
                  , "Incus provider is not usable: IncusVMIncapable \"exit 1: qemu missing\""
                  )
                , ( "missing image-source egress"
                  , EIncus.classifyIncusProviderStatus True ok ok (failed "remote unreachable")
                  , "Incus provider is not usable: IncusNoEgress \"exit 1: remote unreachable\""
                  )
                ]
           ]
  where
    ok = Right (ExitSuccess, "", "")
    failed reason = Right (ExitFailure 1, "", reason)

incusConvergenceCases :: [TestTree]
incusConvergenceCases =
    [ testCase ("complete VM probes and packages follow " ++ show arch) $ do
        EIncus.linuxVmPackages arch @?= packages
        EIncus.linuxVmCapabilityProbes arch Nothing
            @?= ( qemu
                , firmware
                , [ ["test", "-x", "/usr/libexec/virtiofsd"]
                  , ["test", "-x", "/usr/lib/qemu/virtiofsd"]
                  , ["test", "-x", "/usr/lib/virtiofsd"]
                  ]
                )
    | (arch, packages, qemu, firmware) <-
        [ ( Amd64
          , ["qemu-system-x86", "ovmf", "virtiofsd", "acl"]
          , ["test", "-x", "/usr/bin/qemu-system-x86_64"]
          , [ ["test", "-f", "/usr/share/OVMF/OVMF_CODE.fd"]
            , ["test", "-f", "/usr/share/OVMF/OVMF_CODE_4M.fd"]
            ]
          )
        , ( Arm64
          , ["qemu-system-arm", "qemu-efi-aarch64", "virtiofsd", "acl"]
          , ["test", "-x", "/usr/bin/qemu-system-aarch64"]
          , [["test", "-f", "/usr/share/AAVMF/AAVMF_CODE.fd"]]
          )
        ]
    ]
        <> [ testCase ("convergence on " ++ show arch ++ " with " ++ label) $ do
                executable <- resolvedIncusFixture
                EIncus.linuxIncusConvergence arch (EIncus.LinuxIncusObservation executable vmReady daemonReady) @?= expected
           | (arch, vmPackages) <-
                [ (Amd64, ["qemu-system-x86", "ovmf", "virtiofsd", "acl"])
                , (Arm64, ["qemu-system-arm", "qemu-efi-aarch64", "virtiofsd", "acl"])
                ]
           , (label, vmReady, daemonReady, expected) <-
                [ ("a fully usable provider", True, True, [])
                , ( "only a VM-capability gap"
                  , False
                  , True
                  , [ InstallStep Sudo (["apt-get", "install", "-y"] ++ vmPackages)
                    , InstallStep Sudo ["systemctl", "restart", "incus"]
                    ]
                  )
                , ( "only a root-daemon gap"
                  , True
                  , False
                  , [ InstallStep Sudo [incusFixturePath, "admin", "init", "--minimal"]
                    , InstallStep Sudo ["systemctl", "restart", "incus"]
                    ]
                  )
                , ( "both gaps and one final restart"
                  , False
                  , False
                  , [ InstallStep Sudo (["apt-get", "install", "-y"] ++ vmPackages)
                    , InstallStep Sudo [incusFixturePath, "admin", "init", "--minimal"]
                    , InstallStep Sudo ["systemctl", "restart", "incus"]
                    ]
                  )
                ]
           ]
        <> [ testCase "the root-daemon probe preserves the resolved absolute executable" $ do
                executable <- resolvedIncusFixture
                EIncus.linuxIncusDaemonProbeArgs executable
                    @?= [incusFixturePath, "list", "--format", "csv", "-c", "n"]
           , testCase "a configured stale virtiofsd path remains an executable probe" $
                withSystemTempDirectory "hostbootstrap-incus-stale-virtiofsd" $ \directory -> do
                    let stalePath = directory </> "missing-virtiofsd"
                    doesPathExist stalePath >>= (@?= False)
                    stale <- either assertFailure pure (mkAbsExe stalePath)
                    let (_, _, alternatives) = EIncus.linuxVmCapabilityProbes Amd64 (Just stale)
                    alternatives
                        @?= [ ["test", "-x", "/usr/libexec/virtiofsd"]
                            , ["test", "-x", "/usr/lib/qemu/virtiofsd"]
                            , ["test", "-x", "/usr/lib/virtiofsd"]
                            , ["test", "-x", stalePath]
                            ]
                    -- These are result-combination controls, not privileged IO:
                    -- merely holding the configured path is no successful test-x.
                    EIncus.linuxVmCapabilitySatisfied True [True] [False, False, False, False] @?= False
                    EIncus.linuxVmCapabilitySatisfied True [True] [False, False, False, True] @?= True
           , testCase "forwarding vectors check the chain and each direction before insertion" $
                EIncus.incusBridgeForwardingArgs
                    @?= ( ["iptables", "-nL", "DOCKER-USER"]
                        , [ ( ["iptables", "-C", "DOCKER-USER", "-i", "incusbr0", "-j", "ACCEPT"]
                            , ["iptables", "-I", "DOCKER-USER", "-i", "incusbr0", "-j", "ACCEPT"]
                            )
                          , ( ["iptables", "-C", "DOCKER-USER", "-o", "incusbr0", "-j", "ACCEPT"]
                            , ["iptables", "-I", "DOCKER-USER", "-o", "incusbr0", "-j", "ACCEPT"]
                            )
                          ]
                        )
           , testCase "KVM module attempts retain Intel then AMD then generic order" $
                EIncus.kvmModuleLoadArgs
                    @?= [ ["modprobe", "kvm_intel"]
                        , ["modprobe", "kvm_amd"]
                        , ["modprobe", "kvm"]
                        ]
           ]
        <> [ testCase ("VM-capability combination " ++ label) $
                EIncus.linuxVmCapabilitySatisfied qemu firmware virtiofs @?= expected
           | (label, qemu, firmware, virtiofs, expected) <-
                [ ("requires executable QEMU", False, [True], [True], False)
                , ("requires a firmware alternative", True, [False, False], [True], False)
                , ("requires executable virtiofsd", True, [True], [False, False, False], False)
                , ("accepts a later firmware alternative", True, [False, True], [True], True)
                , ("accepts a later virtiofsd alternative", True, [True], [False, True], True)
                , ("refuses an empty firmware group", True, [], [True], False)
                , ("refuses an empty virtiofsd group", True, [True], [], False)
                ]
           ]
        <> incusFlowCases

incusFlowCases :: [TestTree]
incusFlowCases =
    [ testCase "Linux observations drive the only convergence plan and refresh every installed tool" $ do
        -- DEVELOPMENT_PLAN/rationale.md: "Incus convergence observes gaps before executing argv".
        source <- readIncusSource
        body <- either assertFailure pure (haskellDefinitionTokens "reconcileLinuxIncus" source)
        body
            @?= haskellTokens
                ( unlines
                    [ "reconcileLinuxIncus cfg = do"
                    , "    installAndVerify \"incus client\" (\\candidate -> pure (toolPresent candidate Incus)) installSteps cfg"
                    , "    refreshed <- buildHostConfig (hcSubstrate cfg)"
                    , "    executable <-"
                    , "        maybe"
                    , "            (die \"ensure incus: client disappeared before daemon initialization\")"
                    , "            pure"
                    , "            (resolveMaybe refreshed Incus)"
                    , "    capability <- probeLinuxVmCapability refreshed"
                    , "    daemon <- runTool refreshed Sudo (linuxIncusDaemonProbeArgs executable)"
                    , "    let observation = LinuxIncusObservation executable (probeSucceeded capability) (probeSucceeded daemon)"
                    , "        steps = linuxIncusConvergence (substrateArch (hcSubstrate refreshed)) observation"
                    , "    converged <- runLinuxConvergence refreshed steps"
                    , "    ensureKvmAccess converged"
                    , "    ensureIncusAdminGroup converged"
                    , "    ensureBridgeForwarding converged"
                    , "    verifyUsableProvider converged"
                    ]
                )
        -- The existing unique-definition reader intentionally refuses a
        -- multi-equation binding. Pin both complete executor equations, with
        -- their signature and following declaration, through the same lexer.
        assertBool "convergence does not refresh between the actual planned steps" $
            haskellTokens
                ( unlines
                    [ "runLinuxConvergence :: HostConfig -> [InstallStep] -> IO HostConfig"
                    , "runLinuxConvergence cfg [] = pure cfg"
                    , "runLinuxConvergence cfg (InstallStep tool arguments : remaining) = do"
                    , "    runRequired cfg tool arguments"
                    , "    refreshed <- buildHostConfig (hcSubstrate cfg)"
                    , "    runLinuxConvergence refreshed remaining"
                    , "verifyUsableProvider :: HostConfig -> IO ()"
                    ]
                )
                `isInfixOf` haskellTokens source
    , testCase "VM capability executes every grouped probe before combining its actual results" $ do
        -- DEVELOPMENT_PLAN/rationale.md: "Incus convergence observes gaps before executing argv".
        source <- readIncusSource
        body <- either assertFailure pure (haskellDefinitionTokens "probeLinuxVmCapability" source)
        body
            @?= haskellTokens
                ( unlines
                    [ "probeLinuxVmCapability cfg = do"
                    , "    let (qemuArgs, firmwareArgs, virtiofsdArgs) ="
                    , "            linuxVmCapabilityProbes (substrateArch (hcSubstrate cfg)) (resolveMaybe cfg Virtiofsd)"
                    , "    qemu <- runTool cfg Sudo qemuArgs"
                    , "    firmware <- mapM (runTool cfg Sudo) firmwareArgs"
                    , "    virtiofsd <- mapM (runTool cfg Sudo) virtiofsdArgs"
                    , "    let qemuReady = probeSucceeded qemu"
                    , "        firmwareReady = map probeSucceeded firmware"
                    , "        virtiofsdReady = map probeSucceeded virtiofsd"
                    , "        missing ="
                    , "            [ name"
                    , "            | (name, ready) <- [(\"QEMU executable\", qemuReady), (\"firmware image\", or firmwareReady), (\"virtiofsd executable\", or virtiofsdReady)]"
                    , "            , not ready"
                    , "            ]"
                    , "    pure $"
                    , "        if linuxVmCapabilitySatisfied qemuReady firmwareReady virtiofsdReady"
                    , "            then Right (ExitSuccess, \"\", \"\")"
                    , "            else Left (\"missing Linux VM capability: \" ++ intercalate \", \" missing)"
                    ]
                )
    , testCase "forwarding skips a missing chain and inserts only after its rule check fails" $ do
        -- DEVELOPMENT_PLAN/rationale.md: "Incus convergence observes gaps before executing argv".
        source <- readIncusSource
        body <- either assertFailure pure (haskellDefinitionTokens "ensureBridgeForwarding" source)
        body
            @?= haskellTokens
                ( unlines
                    [ "ensureBridgeForwarding cfg = do"
                    , "    let (chainArgs, rules) = incusBridgeForwardingArgs"
                    , "    chain <- runTool cfg Sudo chainArgs"
                    , "    case chain of"
                    , "        Right (ExitSuccess, _, _) -> mapM_ ensureRule rules"
                    , "        Right _ -> pure ()"
                    , "        Left err -> die (\"ensure incus: \" ++ err)"
                    , "  where"
                    , "    ensureRule (checkArgs, insertArgs) = do"
                    , "        checked <- runTool cfg Sudo checkArgs"
                    , "        case checked of"
                    , "            Right (ExitSuccess, _, _) -> pure ()"
                    , "            Right _ -> runRequired cfg Sudo insertArgs"
                    , "            Left err -> die (\"ensure incus: \" ++ err)"
                    ]
                )
    , testCase "KVM rechecks the device after each module attempt and stops when it exists" $ do
        -- DEVELOPMENT_PLAN/rationale.md: "Incus convergence observes gaps before executing argv".
        source <- readIncusSource
        body <- either assertFailure pure (haskellDefinitionTokens "ensureKvmAccess" source)
        body
            @?= haskellTokens
                ( unlines
                    [ "ensureKvmAccess cfg = do"
                    , "    status <- kvmDeviceStatus"
                    , "    case status of"
                    , "        KvmOk -> putStrLn \"ensure kvm: /dev/kvm read-write (no-op)\""
                    , "        KvmAbsent -> do"
                    , "            putStrLn \"ensure kvm: /dev/kvm absent; loading the kvm kernel module\""
                    , "            loadUntilPresent kvmModuleLoadArgs"
                    , "        KvmUnwritable -> grantKvmReadWrite cfg"
                    , "  where"
                    , "    loadUntilPresent [] = die kvmFirmwareResidue"
                    , "    loadUntilPresent (arguments : remaining) = do"
                    , "        _ <- runTool cfg Sudo arguments"
                    , "        afterModprobe <- kvmDeviceStatus"
                    , "        case afterModprobe of"
                    , "            KvmAbsent -> loadUntilPresent remaining"
                    , "            _ -> grantKvmReadWrite cfg"
                    ]
                )
    ]

readIncusSource :: IO String
readIncusSource =
    withPackageSourceIn [] $ \packageRoot _ -> do
        description <- readPackageDescription
        path <- libraryModulePath packageRoot description "HostBootstrap.Ensure.Incus"
        readFile path

incusFixturePath :: FilePath
incusFixturePath = hostFixturePath "/configured/bin/incus"

resolvedIncusFixture :: IO AbsExe
resolvedIncusFixture = either assertFailure pure (mkAbsExe incusFixturePath)

cudaProbeCases :: [TestTree]
cudaProbeCases =
    [ testCase "one predicate answers whether a listing reported a device" $ do
        -- The host driver listing, the nvkind runtime smoke, and the cluster's
        -- own probe all ask this; they read the same marker by construction.
        reportedGpu (Right (ExitSuccess, "GPU 0: NVIDIA RTX 3090\n", "")) @?= True
        reportedGpu (Right (ExitSuccess, "", "")) @?= False
        reportedGpu (Right (ExitFailure 9, "", "driver communication failed")) @?= False
        reportedGpu (Left "nvidia-smi could not be run") @?= False
        reportedGpu (Right (ExitSuccess, nvidiaDeviceMarker, "")) @?= True
    , testCase "uses the official nvkind volume-mount injection smoke" $
        Cuda.nvkindRuntimeProbeArgs
            @?= [ "run"
                , "--rm"
                , "-v"
                , "/dev/null:/var/run/nvidia-container-devices/all"
                , "ubuntu:20.04"
                , "nvidia-smi"
                , "-L"
                ]
    ]

repositoryCases :: [TestTree]
repositoryCases =
    [ testCase ("signed repository list " ++ label) $
        fmap Text.unpack (Cuda.signedByListText (Text.pack input)) @?= expected
    | (label, input, expected) <-
        [ ( "rewrites NVIDIA's active line and preserves its experimental comment"
          , nvidiaActiveLine ++ "\n" ++ nvidiaCommentLine ++ "\n"
          , Right (nvidiaSignedLine ++ "\n" ++ nvidiaCommentLine ++ "\n")
          )
        , ( "rewrites every active entry while preserving indentation, comments, and blanks"
          , "# café\n\n  " ++ nvidiaActiveLine ++ "\n\tdeb https://nvidia.github.io/libnvidia-container/experimental/deb/$(ARCH) /\n\n"
          , Right ("# café\n\n  " ++ nvidiaSignedLine ++ "\n\tdeb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/experimental/deb/$(ARCH) /\n\n")
          )
        , ("preserves the absence of a final newline", nvidiaActiveLine, Right nvidiaSignedLine)
        , ("refuses empty content", "", Left "NVIDIA repository list has no supported deb https:// entry")
        , ("refuses HTML", "<!doctype html><html>error</html>\n", Left "NVIDIA repository list has an unsupported active line")
        , ("refuses comment-only content", nvidiaCommentLine ++ "\n\n", Left "NVIDIA repository list has no supported deb https:// entry")
        , ("refuses an embedded deb substring", "<html>" ++ nvidiaActiveLine ++ "</html>\n", Left "NVIDIA repository list has an unsupported active line")
        , ("refuses an unsupported active HTTP entry", "deb http://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /\n", Left "NVIDIA repository list has an unsupported active line")
        , ("refuses unsupported active options", "deb [arch=amd64] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /\n", Left "NVIDIA repository list has an unsupported active line")
        , ("refuses an active entry for a different host", "deb https://example.com/stable/deb/$(ARCH) /\n", Left "NVIDIA repository list has an unsupported active line")
        , ("refuses an unsupported row after a valid entry", nvidiaActiveLine ++ "\ndeb-src https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /\n", Left "NVIDIA repository list has an unsupported active line")
        ]
    ]
        <> [ testCase "repository vectors name the actual scratch inputs and fixed destinations" $ do
                let scratch = hostFixturePath "/owned/nvidia-repository"
                Cuda.repositoryFetchSteps scratch @?= expectedRepositoryFetchSteps scratch
                Cuda.repositoryPublishSteps scratch @?= expectedRepositoryPublishSteps scratch
           , testCase "both downloads and strict UTF-8 rewrite precede publication and scratch cleanup" $ do
                fixture <- newRepositoryFixture (Downloaded repositoryKeyBytes) (Downloaded repositoryListBytes) successfulRepositoryCommand
                Cuda.setupRepositoryWith (repositoryRunner fixture) >>= (@?= Right ())
                scratch <- repositoryScratch fixture
                repositoryCommands fixture
                    >>= (@?= repositoryStepCommands (expectedRepositoryFetchSteps scratch ++ expectedRepositoryPublishSteps scratch))
                repositoryPublicationBytes fixture
                    >>= (@?= [("gpg", repositoryKeyBytes), ("install", signedRepositoryListBytes)])
                assertRepositoryCleaned fixture
           , testCase "a download IOException refuses and cleans scratch before publication" $ do
                fixture <- newRepositoryFixture DownloadIOException (Downloaded repositoryListBytes) successfulRepositoryCommand
                result <- Cuda.setupRepositoryWith (repositoryRunner fixture)
                assertRepositoryFailure (RefusesWith "NVIDIA repository IO failure: " "fixture download IO failure") result
                repositoryCommands fixture >>= (\commands -> length commands @?= 1)
                repositoryPublicationBytes fixture >>= (@?= [])
                assertRepositoryCleaned fixture
           , testCase "a download UserInterrupt propagates after scratch cleanup" $ do
                fixture <- newRepositoryFixture InterruptedDownload (Downloaded repositoryListBytes) successfulRepositoryCommand
                result <- try (Cuda.setupRepositoryWith (repositoryRunner fixture)) :: IO (Either AsyncException (Either String ()))
                result @?= Left UserInterrupt
                repositoryCommands fixture >>= (\commands -> length commands @?= 1)
                repositoryPublicationBytes fixture >>= (@?= [])
                assertRepositoryCleaned fixture
           , testCase "a failed gpg publication stops before installing the list and cleans scratch" $ do
                let publication program
                        | program == "gpg" = Left "gpg publication refused"
                        | otherwise = successfulRepositoryCommand program
                fixture <- newRepositoryFixture (Downloaded repositoryKeyBytes) (Downloaded repositoryListBytes) publication
                Cuda.setupRepositoryWith (repositoryRunner fixture) >>= (@?= Left "gpg publication refused")
                scratch <- repositoryScratch fixture
                repositoryCommands fixture
                    >>= (@?= repositoryStepCommands (expectedRepositoryFetchSteps scratch ++ take 1 (expectedRepositoryPublishSteps scratch)))
                repositoryPublicationBytes fixture >>= (@?= [("gpg", repositoryKeyBytes)])
                assertRepositoryCleaned fixture
           , testCase "a failed list publication reports failure and cleans scratch without claiming rollback" $ do
                let publication program
                        | program == "install" = Right (ExitFailure 9, "", "list publication denied")
                        | otherwise = successfulRepositoryCommand program
                fixture <- newRepositoryFixture (Downloaded repositoryKeyBytes) (Downloaded repositoryListBytes) publication
                result <- Cuda.setupRepositoryWith (repositoryRunner fixture)
                assertRepositoryFailure (RefusesWith "NVIDIA repository command failed (exit 9): sudo install " "list publication denied") result
                scratch <- repositoryScratch fixture
                repositoryCommands fixture
                    >>= (@?= repositoryStepCommands (expectedRepositoryFetchSteps scratch ++ expectedRepositoryPublishSteps scratch))
                repositoryPublicationBytes fixture
                    >>= (@?= [("gpg", repositoryKeyBytes), ("install", signedRepositoryListBytes)])
                assertRepositoryCleaned fixture
           ]
        <> [ testCase ("repository refusal before publication: " ++ label) $ do
                fixture <- newRepositoryFixture key list successfulRepositoryCommand
                result <- Cuda.setupRepositoryWith (repositoryRunner fixture)
                assertRepositoryFailure expected result
                scratch <- repositoryScratch fixture
                repositoryCommands fixture
                    >>= (@?= take fetchCount (repositoryStepCommands (expectedRepositoryFetchSteps scratch)))
                repositoryPublicationBytes fixture >>= (@?= [])
                assertRepositoryCleaned fixture
           | (label, key, list, fetchCount, expected) <-
                [ ("key runner refusal", RefusedDownload "key fetch refused", Downloaded repositoryListBytes, 1, RefusesExactly "key fetch refused")
                , ("key nonzero exit", FailedDownload 7 "key HTTP failure", Downloaded repositoryListBytes, 1, RefusesWith "NVIDIA repository command failed (exit 7): curl " "key HTTP failure")
                , ("list runner refusal", Downloaded repositoryKeyBytes, RefusedDownload "list fetch refused", 2, RefusesExactly "list fetch refused")
                , ("list nonzero exit", Downloaded repositoryKeyBytes, FailedDownload 8 "list HTTP failure", 2, RefusesWith "NVIDIA repository command failed (exit 8): curl " "list HTTP failure")
                , ("missing key file", MissingDownload, Downloaded repositoryListBytes, 2, RefusesWith "NVIDIA repository IO failure: " "nvidia-container-toolkit.key")
                , ("missing list file", Downloaded repositoryKeyBytes, MissingDownload, 2, RefusesWith "NVIDIA repository IO failure: " "nvidia-container-toolkit.list")
                , ("empty key file", Downloaded ByteString.empty, Downloaded repositoryListBytes, 2, RefusesExactly "NVIDIA repository key is empty")
                , ("empty list file", Downloaded repositoryKeyBytes, Downloaded ByteString.empty, 2, RefusesExactly "NVIDIA repository list is empty")
                , ("invalid list UTF-8", Downloaded repositoryKeyBytes, Downloaded (ByteString.pack [255]), 2, RefusesExactly "NVIDIA repository list is not UTF-8")
                , ("HTML list body", Downloaded repositoryKeyBytes, Downloaded (utf8Bytes "<!doctype html><html>error</html>\n"), 2, RefusesExactly "NVIDIA repository list has an unsupported active line")
                , ("comment-only list body", Downloaded repositoryKeyBytes, Downloaded (utf8Bytes (nvidiaCommentLine ++ "\n")), 2, RefusesExactly "NVIDIA repository list has no supported deb https:// entry")
                , ("blank list body", Downloaded repositoryKeyBytes, Downloaded (utf8Bytes " \n\t\n"), 2, RefusesExactly "NVIDIA repository list has no supported deb https:// entry")
                , ("embedded deb text", Downloaded repositoryKeyBytes, Downloaded (utf8Bytes ("<html>" ++ nvidiaActiveLine ++ "</html>\n")), 2, RefusesExactly "NVIDIA repository list has an unsupported active line")
                , ("unsupported active list syntax", Downloaded repositoryKeyBytes, Downloaded (utf8Bytes "deb http://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /\n"), 2, RefusesExactly "NVIDIA repository list has an unsupported active line")
                ]
           ]

        <> repositoryFlowCases

repositoryFlowCases :: [TestTree]
repositoryFlowCases =
    [ testCase "CUDA verifies its no-op before tool preparation, repository publication, and the runtime tail" $ do
        -- DEVELOPMENT_PLAN/rationale.md: "NVIDIA repository publication follows validated fetches".
        source <- readCudaSource
        reconciler <- either assertFailure pure (haskellDefinitionTokens "reconciler" source)
        assertBool "CUDA does not use the guarded production flow" $
            ["reconcile", "=", "reconcileCuda"] `isInfixOf` reconciler
        flow <- either assertFailure pure (haskellDefinitionTokens "reconcileCuda" source)
        flow
            @?= haskellTokens
                ( unlines
                    [ "reconcileCuda cfg = do"
                    , "    if not (toolPresent cfg NvidiaSmi)"
                    , "        then die \"ensure cuda: nvidia-smi not found; install the NVIDIA driver, then re-run.\""
                    , "        else do"
                    , "            driver <- runTool cfg NvidiaSmi [\"-L\"]"
                    , "            if not (reportedGpu driver)"
                    , "                then die \"ensure cuda: nvidia-smi did not report a GPU; repair the NVIDIA driver, then re-run.\""
                    , "                else do"
                    , "                    ready <- satisfied cfg"
                    , "                    if ready"
                    , "                        then putStrLn \"ensure cuda: present (no-op)\""
                    , "                        else case installSteps (hcSubstrate cfg) of"
                    , "                            Left err -> die (\"ensure cuda: \" ++ err)"
                    , "                            Right _ -> do"
                    , "                                installAndVerify \"cuda repository tools\" repositoryToolsPresent (const (Right repositoryToolSteps)) cfg"
                    , "                                refreshed <- buildHostConfig (hcSubstrate cfg)"
                    , "                                repository <- setupRepositoryWith (runTool refreshed)"
                    , "                                case repository of"
                    , "                                    Left err -> die (\"ensure cuda: \" ++ err)"
                    , "                                    Right () -> installAndVerify \"cuda\" satisfied installSteps refreshed"
                    ]
                )
        tools <- either assertFailure pure (haskellDefinitionTokens "repositoryToolsPresent" source)
        tools
            @?= haskellTokens
                ( unlines
                    [ "repositoryToolsPresent cfg"
                    , "    | not (toolPresent cfg Curl) = pure False"
                    , "    | otherwise = do"
                    , "        result <- runTool cfg Sudo [\"gpg\", \"--version\"]"
                    , "        pure $ case result of"
                    , "            Right (ExitSuccess, _, _) -> True"
                    , "            _ -> False"
                    ]
                )
        smoke <- either assertFailure pure (haskellDefinitionTokens "satisfied" source)
        smoke
            @?= haskellTokens
                ( unlines
                    [ "satisfied cfg = do"
                    , "    smi <- runTool cfg NvidiaSmi [\"-L\"]"
                    , "    case smi of"
                    , "        result | reportedGpu result -> do"
                    , "            smoke <- runTool cfg Docker nvkindRuntimeProbeArgs"
                    , "            pure (reportedGpu smoke)"
                    , "        _ -> pure False"
                    ]
                )
    , testCase "CUDA repository preparation has no shell helper or interpreter step" $ do
        -- DEVELOPMENT_PLAN/rationale.md: "NVIDIA repository publication follows validated fetches".
        source <- readCudaSource
        definitions <- either assertFailure pure (haskellDefinitionNames source)
        assertBool "the repository shell program is still defined" ("repositorySetupScript" `notElem` definitions)
        mapM_
            (\program -> assertBool ("CUDA still invokes " ++ program) (show program `notElem` haskellTokens source))
            ["/bin/sh", "sh", "bash"]
    ]

readCudaSource :: IO String
readCudaSource =
    withPackageSourceIn [] $ \packageRoot _ -> do
        description <- readPackageDescription
        path <- libraryModulePath packageRoot description "HostBootstrap.Ensure.Cuda"
        readFile path

data RepositoryDownload
    = Downloaded ByteString.ByteString
    | RefusedDownload String
    | FailedDownload Int String
    | MissingDownload
    | DownloadIOException
    | InterruptedDownload

data RepositoryFailure = RefusesExactly String | RefusesWith String String

data RepositoryFixture = RepositoryFixture
    { repositoryRunner :: HostTool -> [String] -> IO (Either String (ExitCode, String, String))
    , repositoryCommands :: IO [(HostTool, [String])]
    , repositoryScratch :: IO FilePath
    , repositoryPublicationBytes :: IO [(String, ByteString.ByteString)]
    }

newRepositoryFixture ::
    RepositoryDownload ->
    RepositoryDownload ->
    (String -> Either String (ExitCode, String, String)) ->
    IO RepositoryFixture
newRepositoryFixture key list publication = do
    commands <- newIORef []
    scratch <- newIORef Nothing
    published <- newIORef []
    let scratchPath = readIORef scratch >>= maybe (assertFailure "repository runner never observed an owned scratch path") pure
        recordScratch path expectedName = do
            let directory = takeDirectory path
            assertBool "repository output is not absolute" (isAbsolute path)
            takeFileName path @?= expectedName
            assertBool "repository output is not in the owned template" ("hostbootstrap-cuda-repository" `isPrefixOf` takeFileName directory)
            doesDirectoryExist directory >>= (@?= True)
            canonicalDirectory <- canonicalizePath directory
            temporary <- getTemporaryDirectory >>= canonicalizePath
            takeDirectory canonicalDirectory @?= temporary
            known <- readIORef scratch
            case known of
                Nothing -> writeIORef scratch (Just directory)
                Just previous -> directory @?= previous
        download path reply = case reply of
            Downloaded bytes -> ByteString.writeFile path bytes >> pure (Right (ExitSuccess, "", ""))
            RefusedDownload reason -> pure (Left reason)
            FailedDownload code reason -> pure (Right (ExitFailure code, "", reason))
            MissingDownload -> pure (Right (ExitSuccess, "", ""))
            DownloadIOException -> throwIO (userError "fixture download IO failure")
            InterruptedDownload -> throwIO UserInterrupt
        run tool arguments = do
            modifyIORef' commands (++ [(tool, arguments)])
            case (tool, arguments) of
                (Curl, ["-fsSL", "-o", path, "https://nvidia.github.io/libnvidia-container/gpgkey"]) -> do
                    recordScratch path "nvidia-container-toolkit.key"
                    download path key
                (Curl, ["-fsSL", "-o", path, "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"]) -> do
                    recordScratch path "nvidia-container-toolkit.list"
                    download path list
                (Sudo, ["gpg", "--dearmor", "--yes", "-o", "/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg", keyPath]) -> do
                    directory <- scratchPath
                    keyPath @?= directory </> "nvidia-container-toolkit.key"
                    bytes <- ByteString.readFile keyPath
                    modifyIORef' published (++ [("gpg", bytes)])
                    pure (publication "gpg")
                (Sudo, ["install", "-m", "0644", listPath, "/etc/apt/sources.list.d/nvidia-container-toolkit.list"]) -> do
                    directory <- scratchPath
                    listPath @?= directory </> "nvidia-container-toolkit.signed.list"
                    bytes <- ByteString.readFile listPath
                    modifyIORef' published (++ [("install", bytes)])
                    pure (publication "install")
                _ -> assertFailure ("unexpected repository command: " ++ show (tool, arguments))
    pure (RepositoryFixture run (readIORef commands) scratchPath (readIORef published))

assertRepositoryCleaned :: RepositoryFixture -> IO ()
assertRepositoryCleaned fixture = do
    scratch <- repositoryScratch fixture
    mapM_
        (\path -> doesPathExist path >>= (@?= False))
        [ scratch
        , scratch </> "nvidia-container-toolkit.key"
        , scratch </> "nvidia-container-toolkit.list"
        , scratch </> "nvidia-container-toolkit.signed.list"
        ]

assertRepositoryFailure :: RepositoryFailure -> Either String () -> IO ()
assertRepositoryFailure (RefusesExactly reason) result = result @?= Left reason
assertRepositoryFailure (RefusesWith prefix detail) result = case result of
    Left reason -> do
        assertBool ("missing refusal prefix: " ++ show reason) (prefix `isPrefixOf` reason)
        assertBool ("missing refusal detail: " ++ show reason) (detail `isInfixOf` reason)
    Right () -> assertFailure "repository preparation unexpectedly succeeded"

expectedRepositoryFetchSteps :: FilePath -> [InstallStep]
expectedRepositoryFetchSteps scratch =
    [ InstallStep Curl ["-fsSL", "-o", scratch </> "nvidia-container-toolkit.key", "https://nvidia.github.io/libnvidia-container/gpgkey"]
    , InstallStep Curl ["-fsSL", "-o", scratch </> "nvidia-container-toolkit.list", "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"]
    ]

expectedRepositoryPublishSteps :: FilePath -> [InstallStep]
expectedRepositoryPublishSteps scratch =
    [ InstallStep Sudo ["gpg", "--dearmor", "--yes", "-o", "/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg", scratch </> "nvidia-container-toolkit.key"]
    , InstallStep Sudo ["install", "-m", "0644", scratch </> "nvidia-container-toolkit.signed.list", "/etc/apt/sources.list.d/nvidia-container-toolkit.list"]
    ]

repositoryStepCommands :: [InstallStep] -> [(HostTool, [String])]
repositoryStepCommands steps = [(tool, arguments) | InstallStep tool arguments <- steps]

successfulRepositoryCommand :: String -> Either String (ExitCode, String, String)
successfulRepositoryCommand _ = Right (ExitSuccess, "", "")

repositoryKeyBytes, repositoryListBytes, signedRepositoryListBytes :: ByteString.ByteString
repositoryKeyBytes = ByteString.pack [0, 255, 13, 10, 128]
repositoryListBytes = utf8Bytes ("# café\n" ++ nvidiaActiveLine ++ "\n" ++ nvidiaCommentLine ++ "\n")
signedRepositoryListBytes = utf8Bytes ("# café\n" ++ nvidiaSignedLine ++ "\n" ++ nvidiaCommentLine ++ "\n")

nvidiaActiveLine, nvidiaSignedLine, nvidiaCommentLine :: String
nvidiaActiveLine = "deb https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /"
nvidiaSignedLine = "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /"
nvidiaCommentLine = "#deb https://nvidia.github.io/libnvidia-container/experimental/deb/$(ARCH) /"

utf8Bytes :: String -> ByteString.ByteString
utf8Bytes = TextEncoding.encodeUtf8 . Text.pack

data DockerGroupEvent
    = RequestedDockerGroups [String]
    | ObservedDockerSocketGroup
    deriving (Eq, Show)

dockerGroupCases :: [TestTree]
dockerGroupCases =
    [ testCase label $ do
        events <- newIORef []
        let note event = modifyIORef' events (++ [event])
            runner arguments = note (RequestedDockerGroups arguments) >> pure groups
            observeSocket = note ObservedDockerSocketGroup >> pure socket
        Docker.verifyDockerGroupWith runner observeSocket "matt" >>= (@?= expected)
        readIORef events
            >>= (@?= [RequestedDockerGroups ["id", "-nG", "matt"]] ++ [ObservedDockerSocketGroup | inspectSocket])
    | (label, groups, socket, expected, inspectSocket) <-
        [ ( "exact group tokens separated by whitespace grant observed socket access"
          , Right (ExitSuccess, "matt\tdocker\nwheel ", "")
          , Right ("docker", True)
          , Right ()
          , True
          )
        , ( "membership in a custom actual socket group is accepted"
          , Right (ExitSuccess, "matt container-runtime\n", "")
          , Right ("container-runtime", True)
          , Right ()
          , True
          )
        , ( "docker membership alone cannot grant access to a different owning group"
          , Right (ExitSuccess, "matt docker\n", "")
          , Right ("container-runtime", True)
          , Left "matt is not a member of Docker socket group container-runtime"
          , True
          )
        , ( "group-name prefixes and substrings do not establish membership"
          , Right (ExitSuccess, "matt docker-root dockerish\n", "")
          , Right ("docker", True)
          , Left "matt is not a member of Docker socket group docker"
          , True
          )
        , ( "group membership preserves case"
          , Right (ExitSuccess, "matt Docker\n", "")
          , Right ("docker", True)
          , Left "matt is not a member of Docker socket group docker"
          , True
          )
        , ( "empty successful id output cannot establish membership"
          , Right (ExitSuccess, "", "")
          , Right ("docker", True)
          , Left "matt is not a member of Docker socket group docker"
          , True
          )
        , ( "membership does not replace the socket group-write bit"
          , Right (ExitSuccess, "matt container-runtime\n", "")
          , Right ("container-runtime", False)
          , Left "Docker socket is not writable by owning group container-runtime"
          , True
          )
        , ( "a group runner refusal skips socket observation"
          , Left "id runner unavailable"
          , Right ("docker", True)
          , Left "could not read groups for matt: id runner unavailable"
          , False
          )
        , ( "a nonzero id exit skips metadata despite convincing stdout"
          , Right (ExitFailure 7, "matt docker\n", "id denied")
          , Right ("docker", True)
          , Left "could not read groups for matt (exit 7) id denied"
          , False
          )
        , ( "a socket metadata refusal is retained after group observation"
          , Right (ExitSuccess, "matt docker\n", "")
          , Left "socket metadata unavailable"
          , Left "socket metadata unavailable"
          , True
          )
        ]
    ]
        <> [ testCase "a socket observation IOException becomes an explicit refusal" $ do
                events <- newIORef []
                let runner arguments = do
                        modifyIORef' events (++ [RequestedDockerGroups arguments])
                        pure (Right (ExitSuccess, "matt docker\n", ""))
                    observeSocket = do
                        modifyIORef' events (++ [ObservedDockerSocketGroup])
                        throwIO (userError "fixture socket IO failure")
                result <- Docker.verifyDockerGroupWith runner observeSocket "matt"
                case result of
                    Left reason -> do
                        assertBool "socket IOException lost its refusal prefix" ("could not verify Docker group access: " `isPrefixOf` reason)
                        assertBool "socket IOException lost its reason" ("fixture socket IO failure" `isInfixOf` reason)
                    Right () -> assertFailure "socket IOException was reported as verified access"
                readIORef events >>= (@?= [RequestedDockerGroups ["id", "-nG", "matt"], ObservedDockerSocketGroup])
           , testCase "a group runner UserInterrupt propagates before socket observation" $ do
                events <- newIORef []
                let runner arguments = do
                        modifyIORef' events (++ [RequestedDockerGroups arguments])
                        throwIO UserInterrupt
                    observeSocket = modifyIORef' events (++ [ObservedDockerSocketGroup]) >> pure (Right ("docker", True))
                result <- try (Docker.verifyDockerGroupWith runner observeSocket "matt") :: IO (Either AsyncException (Either String ()))
                result @?= Left UserInterrupt
                readIORef events >>= (@?= [RequestedDockerGroups ["id", "-nG", "matt"]])
           ]
        <> dockerGroupFlowCases

dockerGroupFlowCases :: [TestTree]
dockerGroupFlowCases =
    [ testCase "production permission refusal precedes the actual direct-info and ACL flow" $ do
        -- DEVELOPMENT_PLAN/rationale.md: "Docker future-login checks observe group and socket permissions".
        source <- readDockerSource
        group <- either assertFailure pure (haskellDefinitionTokens "ensureDockerGroup" source)
        group
            @?= haskellTokens
                "ensureDockerGroup cfg = withInvokingGroupMember cfg dockerLabel \"docker\" (verifyDockerGroup cfg)"
        verified <- either assertFailure pure (haskellDefinitionTokens "verifyDockerGroup" source)
        verified
            @?= haskellTokens
                ( unlines
                    [ "verifyDockerGroup cfg checkedStep user = do"
                    , "    verified <- verifyDockerGroupWith (runTool cfg Sudo) readDockerSocketGroup user"
                    , "    case verified of"
                    , "        Left err -> die (dockerLabel ++ \": \" ++ err)"
                    , "        Right () -> ensureCurrentSessionSocketAccess cfg checkedStep user"
                    ]
                )
        access <- either assertFailure pure (haskellDefinitionTokens "ensureCurrentSessionSocketAccess" source)
        access
            @?= haskellTokens
                ( unlines
                    [ "ensureCurrentSessionSocketAccess cfg checkedStep user = do"
                    , "    direct <- dockerInfo cfg"
                    , "    if direct"
                    , "        then reportDockerAccessVerified"
                    , "        else do"
                    , "            ensureAclTool checkedStep"
                    , "            grantSocketAccess checkedStep dockerSocketPath user"
                    , "            reportDockerAccessVerified"
                    ]
                )
        direct <- either assertFailure pure (haskellDefinitionTokens "dockerInfo" source)
        direct
            @?= haskellTokens
                ( unlines
                    [ "dockerInfo cfg = do"
                    , "    result <- runTool cfg Docker [\"info\"]"
                    , "    pure $ case result of"
                    , "        Right (ExitSuccess, _, _) -> True"
                    , "        _ -> False"
                    ]
                )
        acl <- either assertFailure pure (haskellDefinitionTokens "ensureAclTool" source)
        acl
            @?= haskellTokens
                ( unlines
                    [ "ensureAclTool checkedStep ="
                    , "    checkedStep"
                    , "        \"install acl for immediate docker socket access\""
                    , "        [\"env\", \"DEBIAN_FRONTEND=noninteractive\", \"apt-get\", \"install\", \"-y\", \"acl\"]"
                    ]
                )
    , testCase "native socket metadata supplies its real owning group and group-write bit" $ do
        -- DEVELOPMENT_PLAN/rationale.md: "Docker future-login checks observe group and socket permissions".
        source <- readDockerSource
        socket <- either assertFailure pure (haskellDefinitionTokens "dockerSocketPath" source)
        socket @?= haskellTokens "dockerSocketPath = \"/var/run/docker.sock\""
        -- Both platform bindings remain in the physical source. Match their
        -- complete conditional declaration through the lexer; neither is an
        -- observation fabricated by the portable fixtures above.
        assertBool "native socket metadata no longer maps actual POSIX permissions or refuses on Windows" $
            haskellTokens
                ( unlines
                    [ "readDockerSocketGroup :: IO (Either String (String, Bool))"
                    , "#ifdef mingw32_HOST_OS"
                    , "readDockerSocketGroup ="
                    , "    pure (Left \"Docker socket group inspection is unavailable on native Windows\")"
                    , "#else"
                    , "readDockerSocketGroup = do"
                    , "    observed <- tryIOError $ do"
                    , "        status <- getFileStatus dockerSocketPath"
                    , "        owner <- getGroupEntryForID (fileGroup status)"
                    , "        pure (groupName owner, intersectFileModes (fileMode status) groupWriteMode /= 0)"
                    , "    pure (either (Left . (\"could not inspect Docker socket permissions: \" ++) . displayException) Right observed)"
                    , "#endif"
                    , "ensureCurrentSessionSocketAccess :: HostConfig -> (String -> [String] -> IO ()) -> String -> IO ()"
                    ]
                )
                `isInfixOf` haskellTokens source
    , testCase "Docker group verification has no sg or shell interpreter argv" $ do
        -- DEVELOPMENT_PLAN/rationale.md: "Docker future-login checks observe group and socket permissions".
        source <- readDockerSource
        mapM_
            (\program -> assertBool ("Docker still invokes " ++ program) (show program `notElem` haskellTokens source))
            ["sg", "sh", "/bin/sh", "bash", "-c"]
    ]

readDockerSource :: IO String
readDockerSource =
    withPackageSourceIn [] $ \packageRoot _ -> do
        description <- readPackageDescription
        path <- libraryModulePath packageRoot description "HostBootstrap.Ensure.Docker"
        readFile path

wslStatusCases :: [TestTree]
wslStatusCases =
    [ testCase label $ Wsl2.classifyWslStatus result @?= expected
    | (label, result, expected) <-
        [ ( "ordinary status success establishes platform readiness"
          , Right (ExitSuccess, "Default Distribution: Ubuntu-24.04\nDefault Version: 2", "")
          , Wsl2.WslPlatformReady
          )
        , ( "virtualization-disabled text overrides status success"
          , Right (ExitSuccess, "Virtualization is not enabled", "")
          , Wsl2.WslVirtualizationUnavailable
          )
        , ( "a nonzero NUL-padded no-distribution report establishes platform readiness"
          , Right (ExitFailure 1, utf16ish "Windows Subsystem for Linux has no installed distributions.", "")
          , Wsl2.WslPlatformReady
          )
        , ( "a nonzero virtualization-disabled report requires virtualization"
          , Right (ExitFailure 1, "Virtualization is not enabled", "")
          , Wsl2.WslVirtualizationUnavailable
          )
        , ( "an unrelated status failure means the platform is absent"
          , Right (ExitFailure 5, "The requested operation failed", "Access is denied")
          , Wsl2.WslPlatformAbsent
          )
        , ( "a status runner refusal means the platform is absent"
          , Left "wsl.exe could not be launched"
          , Wsl2.WslPlatformAbsent
          )
        , ( "virtualization diagnostics override a no-distribution report on success"
          , Right (ExitSuccess, "Windows Subsystem for Linux has no installed distributions.", "Virtualization is not enabled")
          , Wsl2.WslVirtualizationUnavailable
          )
        , ( "virtualization diagnostics override a no-distribution report on failure"
          , Right (ExitFailure 1, "WSL2 is unable to start", "Windows Subsystem for Linux has no installed distributions.")
          , Wsl2.WslVirtualizationUnavailable
          )
        , ( "uppercase NUL-padded virtualization diagnostics on stderr override success"
          , Right (ExitSuccess, "Default Version: 2", utf16ish "VIRTUALIZATION IS NOT ENABLED")
          , Wsl2.WslVirtualizationUnavailable
          )
        , ( "uppercase NUL-padded unable-to-start diagnostics on stderr override success"
          , Right (ExitSuccess, "", utf16ish "WSL2 IS UNABLE TO START")
          , Wsl2.WslVirtualizationUnavailable
          )
        , ( "uppercase NUL-padded no-distribution stderr establishes readiness after failure"
          , Right (ExitFailure 42, "", utf16ish "WINDOWS SUBSYSTEM FOR LINUX HAS NO INSTALLED DISTRIBUTIONS.")
          , Wsl2.WslPlatformReady
          )
        , ( "a no-distribution report is also ready on status success"
          , Right (ExitSuccess, "Windows Subsystem for Linux has no installed distributions.", "")
          , Wsl2.WslPlatformReady
          )
        , ( "default version one does not make the installed platform absent"
          , Right (ExitSuccess, "Default Version: 1", "")
          , Wsl2.WslPlatformReady
          )
        , ( "empty successful status output still establishes platform readiness"
          , Right (ExitSuccess, "", "")
          , Wsl2.WslPlatformReady
          )
        ]
    ]
        <> [ testCase "readiness observes one status result and has no online fallback" $
                -- DEVELOPMENT_PLAN/rationale.md: "WSL readiness comes from platform status".
                withPackageSourceIn [] $ \packageRoot _ -> do
                    description <- readPackageDescription
                    path <- libraryModulePath packageRoot description "HostBootstrap.Ensure.Wsl2"
                    source <- readFile path
                    body <- either assertFailure pure (haskellDefinitionTokens "wsl2Ready" source)
                    body
                        @?= haskellTokens
                            ( unlines
                                [ "wsl2Ready cfg = do"
                                , "    result <- runTool cfg Wsl [\"--status\"]"
                                , "    pure (classifyWslStatus result == WslPlatformReady)"
                                ]
                            )
                    length (filter (== "runTool") body) @?= 1
                    definitions <- either assertFailure pure (haskellDefinitionNames source)
                    assertBool "the online readiness helper is still defined" $
                        "wsl2OnlineListReady" `notElem` definitions
                    assertBool "the WSL online catalogue is still queried" $
                        show "--online" `notElem` haskellTokens source
           ]

wslActionCases :: [TestTree]
wslActionCases =
    [ testCase label $ Wsl2.wslNextAction status hypervisor firmware @?= expected
    | (label, status, hypervisor, firmware, expected) <-
        [ ( "ready without hypervisor or firmware support sets default version two"
          , Wsl2.WslPlatformReady
          , False
          , False
          , Wsl2.WslSetDefaultVersion (InstallStep Wsl ["--set-default-version", "2"])
          )
        , ( "ready with firmware support alone sets default version two"
          , Wsl2.WslPlatformReady
          , False
          , True
          , Wsl2.WslSetDefaultVersion (InstallStep Wsl ["--set-default-version", "2"])
          )
        , ( "ready with a hypervisor alone sets default version two"
          , Wsl2.WslPlatformReady
          , True
          , False
          , Wsl2.WslSetDefaultVersion (InstallStep Wsl ["--set-default-version", "2"])
          )
        , ( "ready with both machine facts sets default version two"
          , Wsl2.WslPlatformReady
          , True
          , True
          , Wsl2.WslSetDefaultVersion (InstallStep Wsl ["--set-default-version", "2"])
          )
        , ( "an absent platform without either machine fact requires firmware attention"
          , Wsl2.WslPlatformAbsent
          , False
          , False
          , Wsl2.WslFirmwareUnavailable
          )
        , ( "an absent platform with firmware support alone installs"
          , Wsl2.WslPlatformAbsent
          , False
          , True
          , Wsl2.WslInstallPlatform
          )
        , ( "an absent platform with a hypervisor installs despite unavailable firmware"
          , Wsl2.WslPlatformAbsent
          , True
          , False
          , Wsl2.WslInstallPlatform
          )
        , ( "an absent platform with both machine facts installs"
          , Wsl2.WslPlatformAbsent
          , True
          , True
          , Wsl2.WslInstallPlatform
          )
        , ( "unavailable virtualization without either machine fact requires firmware attention"
          , Wsl2.WslVirtualizationUnavailable
          , False
          , False
          , Wsl2.WslFirmwareUnavailable
          )
        , ( "unavailable virtualization with firmware support alone enables hypervisor launch"
          , Wsl2.WslVirtualizationUnavailable
          , False
          , True
          , Wsl2.WslEnableHypervisorLaunch
          )
        , ( "unavailable virtualization with a hypervisor installs despite unavailable firmware"
          , Wsl2.WslVirtualizationUnavailable
          , True
          , False
          , Wsl2.WslInstallPlatform
          )
        , ( "unavailable virtualization with both machine facts installs"
          , Wsl2.WslVirtualizationUnavailable
          , True
          , True
          , Wsl2.WslInstallPlatform
          )
        ]
    ]
        <> [ testCase "default-version convergence consumes the action payload after ready or completed installation" $
                -- DEVELOPMENT_PLAN/rationale.md: "WSL prerequisites use native machine observations".
                withPackageSourceIn [] $ \packageRoot _ -> do
                    description <- readPackageDescription
                    path <- libraryModulePath packageRoot description "HostBootstrap.Ensure.Wsl2"
                    source <- readFile path
                    body <- either assertFailure pure (haskellDefinitionTokens "reconcileWsl2" source)
                    assertBool "the selected action is not passed to the production interpreter" $
                        haskellTokens "runAction cfg action where" `isInfixOf` body
                    assertBool "the ready action does not execute its own tool and argv payload" $
                        haskellTokens
                            ( unlines
                                [ "runAction currentHostConfig (WslSetDefaultVersion (InstallStep tool args)) = do"
                                , "    result <- runTool currentHostConfig tool args"
                                , "    case classifyStepOutcome tool args result of"
                                , "        StepContinue -> reportReady"
                                , "        StepAlreadyInstalled -> reportReady"
                                , "        StepRebootRequired ->"
                                , "            die \"ensure wsl2: host reboot required after WSL2 install; reboot and retry\""
                                , "        StepFailed reason -> die (\"ensure wsl2: \" ++ reason)"
                                , "runAction currentHostConfig WslInstallPlatform = do"
                                ]
                            )
                            `isInfixOf` body
                    assertBool "completed installation does not refresh before the same default-version action" $
                        haskellTokens
                            ( unlines
                                [ "runAction currentHostConfig WslInstallPlatform = do"
                                , "    installAndVerify \"wsl2\" wsl2Ready installSteps currentHostConfig"
                                , "    refreshed <- buildHostConfig (hcSubstrate currentHostConfig)"
                                , "    runAction refreshed (WslSetDefaultVersion defaultVersionStep)"
                                , "runAction currentHostConfig WslEnableHypervisorLaunch = setHypervisorLaunch currentHostConfig"
                                ]
                            )
                            `isInfixOf` body
           ]

wslPrerequisiteCases :: [TestTree]
wslPrerequisiteCases =
    [ testCase "diagnostic classifiers and hypervisor argv live with ensure" $ do
        Wsl2.wslReportsVirtualizationDisabled
            (ExitSuccess, "WSL2 is unable to start since virtualization is not enabled", "")
            @?= True
        Wsl2.wslReportsVirtualizationDisabled
            (ExitSuccess, utf16ish "WSL2 is unable to start since virtualization is not enabled", "")
            @?= True
        Wsl2.wslReportsNoInstalledDistributions
            (ExitFailure 1, "Windows Subsystem for Linux has no installed distributions.", "")
            @?= True
        Wsl2.normalizeWslText (utf16ish "Ubuntu-24.04") @?= "ubuntu-24.04"
        Wsl2.bcdeditHypervisorLaunchArgs
            @?= ["/set", "hypervisorlaunchtype", "auto"]
    , testCase "virtualization-disabled classification ignores ordinary and unrelated WSL text" $
        map Wsl2.wslReportsVirtualizationDisabled
            [ (ExitSuccess, ordinaryStatus, "")
            , (ExitSuccess, utf16ish ordinaryStatus, "")
            , (ExitSuccess, "", "")
            , (ExitSuccess, "Windows Subsystem for Linux has no installed distributions.", "")
            ]
            @?= [False, False, False, False]
    , testCase "no-distribution classification ignores ordinary and unrelated WSL text" $
        map Wsl2.wslReportsNoInstalledDistributions
            [ (ExitSuccess, ordinaryStatus, "")
            , (ExitSuccess, utf16ish ordinaryStatus, "")
            , (ExitSuccess, "", "")
            , (ExitSuccess, "WSL2 is unable to start since virtualization is not enabled", "")
            ]
            @?= [False, False, False, False]
    , testCase "Ensure.Wsl2 does not import the later provider realization" $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (fail ("could not locate repository root from " ++ cwd)) pure
        source <- readFile (root </> "core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs")
        assertBool
            "Ensure.Wsl2 imported HostBootstrap.Wsl2"
            (not (importsModule "HostBootstrap.Wsl2" source))
    , testCase "WSL prerequisite observations have no PowerShell interpreter helpers" $
        -- DEVELOPMENT_PLAN/rationale.md: "WSL prerequisites use native machine observations".
        withPackageSourceIn [] $ \packageRoot _ -> do
            description <- readPackageDescription
            path <- libraryModulePath packageRoot description "HostBootstrap.Ensure.Wsl2"
            source <- readFile path
            definitions <- either assertFailure pure (haskellDefinitionNames source)
            mapM_
                (\name -> assertBool ("PowerShell helper is still defined: " ++ name) (name `notElem` definitions))
                ["powerShellBoolArgs", "parsePowerShellBool", "runPowerShellBool"]
            let tokens = haskellTokens source
            assertBool "the WSL reconciler still selects PowerShell" ("PowerShell" `notElem` tokens)
            assertBool "the WSL reconciler still sends -Command text" (show "-Command" `notElem` tokens)
    , testCase "dependency import scanner catches decorated multiline imports and ignores lexical controls" $ do
        let sample =
                unlines
                    [ "-- import HostBootstrap.Commented"
                    , "{- outer {- import HostBootstrap.Nested -} import HostBootstrap.BlockCommented -}"
                    , "import {-# SOURCE #-}"
                    , "  safe"
                    , "  qualified"
                    , "  \"hostbootstrap-core\""
                    , "  HostBootstrap.Wsl2"
                    , "literal = \"import HostBootstrap.StringLiteral\""
                    ]
        assertBool "decorated multiline provider import was missed" (importsModule "HostBootstrap.Wsl2" sample)
        mapM_
            (\ignored -> assertBool ("lexical control was treated as an import: " ++ ignored) (not (importsModule ignored sample)))
            [ "HostBootstrap.Commented"
            , "HostBootstrap.Nested"
            , "HostBootstrap.BlockCommented"
            , "HostBootstrap.StringLiteral"
            ]
    ]
  where
    ordinaryStatus = "Default Distribution: Ubuntu-24.04\nDefault Version: 2"

utf16ish :: String -> String
utf16ish = concatMap (\character -> [character, '\0'])
