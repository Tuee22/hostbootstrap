{-# LANGUAGE ScopedTypeVariables #-}

module EnsureSpec (tests) where

import Control.Exception (try)
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import HostBootstrap.Command (allReconcilers)
import HostBootstrap.Ensure
    ( InstallStep (..)
    , Reconciler (..)
    , appliesTo
    , decide
    , installAndVerifyWith
    , reconcilerInstallSteps
    , requirement
    , runReconciler
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
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (..))
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import SourceGuard (importsModule)
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

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
        , testGroup "install-and-verify driver" installDriverCases
        , testGroup "install plans" installPlanCases
        , testGroup "Incus provider capability probe" incusProbeCases
        , testGroup "CUDA nvkind runtime probe" cudaProbeCases
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
        -- cuda has only a linux-gpu row, so the plain linux host has no row at
        -- all: the accelerator is a requirement of the row, not a second frame.
        appliesTo (findR "cuda") cpu @?= False
        appliesTo (findR "cuda") gpu @?= True
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
            >>= ( @?= [ Probed cpu False
                       , RanStep cpu Brew ["install", "demo"]
                       , Refreshed cpu
                       , RanStep gpu Ghcup ["install", "demo"]
                       , Refreshed gpu
                       , Probed gpu True
                       , Probed cpu True
                       ]
                )
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
    ]

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
        Wsl2.powerShellBoolArgs "(Get-ComputerInfo -Property HyperVisorPresent).HyperVisorPresent"
            @?= ["-NoProfile", "-Command", "(Get-ComputerInfo -Property HyperVisorPresent).HyperVisorPresent"]
        assertBool "wsl2 Left on linux-cpu" (isLeft (Wsl2.installSteps cpu))
    , testCase "ghc: brew ghcup then ghcup install ghc on apple" $
        Ghc.installSteps apple
            @?= Right [InstallStep Brew ["install", "ghcup"], InstallStep Ghcup ["install", "ghc"]]
    , testCase "homebrew: no resolved-tool plan (toolchain root)" $
        assertBool "homebrew Left on apple" (isLeft (Homebrew.installSteps apple))
    , testCase "docker: apt install on linux, defer to colima on apple" $ do
        let linux = Right [InstallStep Sudo ["apt-get", "install", "-y", "docker.io", "acl"], InstallStep Sudo ["systemctl", "enable", "--now", "docker"]]
        Docker.installSteps cpu @?= linux
        Docker.installSteps gpu @?= linux
        assertBool "docker Left on apple" (isLeft (Docker.installSteps apple))
    , testCase "docker: linux socket user prefers the invoking sudo user and skips root" $ do
        Docker.targetDockerUser [("SUDO_USER", "matt"), ("USER", "root")] @?= Just "matt"
        Docker.targetDockerUser [("SUDO_USER", "root"), ("LOGNAME", "matt"), ("USER", "root")]
            @?= Just "matt"
        Docker.targetDockerUser [("SUDO_USER", "root"), ("USER", "root")] @?= Nothing
        Docker.targetDockerUser [("USER", "")] @?= Nothing
    , testCase "cuda: container toolkit on linux-gpu, Left elsewhere" $ do
        Cuda.installSteps gpu
            @?= Right
                [ InstallStep Sudo ["apt-get", "update"]
                , InstallStep Sudo ["apt-get", "install", "-y", "--no-install-recommends", "curl", "gnupg2"]
                , InstallStep Sudo ["/bin/sh", "-c", Cuda.repositorySetupScript]
                , InstallStep Sudo ["apt-get", "update"]
                , InstallStep Sudo ["apt-get", "install", "-y", "nvidia-container-toolkit"]
                , InstallStep Sudo ["nvidia-ctk", "runtime", "configure", "--runtime=docker", "--set-as-default", "--cdi.enabled"]
                , InstallStep Sudo ["nvidia-ctk", "config", "--set", "accept-nvidia-visible-devices-as-volume-mounts=true", "--in-place"]
                , InstallStep Sudo ["systemctl", "restart", "docker"]
                ]
        assertBool "cuda configures NVIDIA's signed stable apt repository" $
            all
                (`isInfixOf` Cuda.repositorySetupScript)
                [ "https://nvidia.github.io/libnvidia-container/gpgkey"
                , "/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
                , "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"
                , "signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
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
                    , InstallStep Sudo ["incus", "admin", "init", "--minimal"]
                    ]
        EIncus.installSteps cpu @?= linux
        EIncus.installSteps gpu @?= linux
    , testCase "incus: linux admin user prefers the invoking sudo user and skips root" $ do
        EIncus.targetIncusAdminUser [("SUDO_USER", "matt"), ("USER", "root")] @?= Just "matt"
        EIncus.targetIncusAdminUser [("SUDO_USER", "root"), ("LOGNAME", "matt"), ("USER", "root")]
            @?= Just "matt"
        EIncus.targetIncusAdminUser [("SUDO_USER", "root"), ("USER", "root")] @?= Nothing
        EIncus.targetIncusAdminUser [("USER", "")] @?= Nothing
    ]

incusProbeCases :: [TestTree]
incusProbeCases =
    [ testCase "package presence alone does not mint provider capability" $ do
        EIncus.classifyIncusProviderStatus False ok ok ok @?= EIncus.IncusClientMissing
        assertBool
            "missing client cannot mint capability"
            (isLeft (EIncus.withIncusProviderCapability EIncus.IncusClientMissing (const ())))
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
    , testCase "only the complete ready row mints the opaque capability" $ do
        let status = EIncus.classifyIncusProviderStatus True ok ok ok
        status @?= EIncus.IncusProviderReady
        EIncus.withIncusProviderCapability status (const "ready") @?= Right "ready"
    , testCase "the VM-capability probe requires a virtiofsd Incus can exec" $ do
        -- A host with QEMU and OVMF but no virtiofsd launches VMs and then fails
        -- every durable-share attach, so "usable" (§ L) has to include it. The
        -- candidate list is Incus's own search order.
        EIncus.virtiofsdCandidatePaths
            @?= [ "/usr/libexec/virtiofsd"
                , "/usr/lib/qemu/virtiofsd"
                , "/usr/lib/virtiofsd"
                ]
        let script = EIncus.linuxVmCapabilityProbeScript
        mapM_
            (\needle -> assertBool ("probe checks " ++ needle ++ ": " ++ script) (needle `isInfixOf` script))
            ( [ "test -x /usr/bin/qemu-system-x86_64"
              , "/usr/share/OVMF/OVMF_CODE.fd"
              , "command -v virtiofsd"
              ]
                ++ map ("test -x " ++) EIncus.virtiofsdCandidatePaths
            )
        -- The three conjuncts are joined with && so a missing one fails the probe
        -- rather than being reported ready.
        length (filter (== "&&") (words script)) @?= 2
    ]
  where
    ok = Right (ExitSuccess, "", "")
    failed reason = Right (ExitFailure 1, "", reason)

cudaProbeCases :: [TestTree]
cudaProbeCases =
    [ testCase "requires a successful host GPU listing before runtime reconciliation" $ do
        Cuda.nvidiaDriverProbeReady (Right (ExitSuccess, "GPU 0: NVIDIA RTX 3090\n", "")) @?= True
        Cuda.nvidiaDriverProbeReady (Right (ExitSuccess, "", "")) @?= False
        Cuda.nvidiaDriverProbeReady (Right (ExitFailure 9, "", "driver communication failed")) @?= False
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
    , testCase "accepts a visible GPU and rejects empty/failed probes" $ do
        Cuda.nvkindRuntimeProbeReady (Right (ExitSuccess, "GPU 0: NVIDIA RTX 3090\n", "")) @?= True
        Cuda.nvkindRuntimeProbeReady (Right (ExitSuccess, "", "")) @?= False
        Cuda.nvkindRuntimeProbeReady (Right (ExitFailure 1, "", "runtime misconfigured")) @?= False
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
    , testCase "Ensure.Wsl2 does not import the later provider realization" $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (fail ("could not locate repository root from " ++ cwd)) pure
        source <- readFile (root </> "core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs")
        assertBool
            "Ensure.Wsl2 imported HostBootstrap.Wsl2"
            (not (importsModule "HostBootstrap.Wsl2" source))
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

utf16ish :: String -> String
utf16ish = concatMap (\character -> [character, '\0'])
