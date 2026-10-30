{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}

{- | The @ensure incus@ reconciler: the host-provider tool, applicable on
**both** apple-silicon and linux (the first cross-substrate reconciler).

Install-and-verify (see @development_plan_standards.md § L, § U@):
on apple-silicon, @brew install incus@ + @brew install colima@ and
@colima start incus --runtime incus@, because macOS ships only the client and
the daemon must run inside Colima's Linux VM. On Linux, install a missing client
and observe architecture-specific VM support and the root daemon before
selecting packages, initialization, or a restart. The invoking user's
@incus-admin@ membership and socket access remain reconciled separately. A
usable observation requires no VM-package install or daemon restart. The pure
plans and argument vectors are unit-tested.
-}
module HostBootstrap.Ensure.Incus (
    reconciler,
    installSteps,
    appleIncusProfile,
    IncusProviderStatus (
        IncusClientMissing,
        IncusDaemonAbsent,
        IncusPermissionDenied,
        IncusDaemonUnreachable,
        IncusVMIncapable,
        IncusNoEgress
    ),
    IncusProviderCapability,
    classifyIncusProviderStatus,
    incusProviderStatusResult,
    virtiofsdCandidatePaths,
    LinuxIncusObservation (..),
    linuxVmPackages,
    linuxVmCapabilityProbes,
    linuxVmCapabilitySatisfied,
    linuxIncusDaemonProbeArgs,
    linuxIncusConvergence,
    incusBridgeForwardingArgs,
    kvmModuleLoadArgs,
    withIncusProviderCapability,
    probeIncusProviderStatus,
    ensureKvmAccess,
)
where

import Data.Char (toLower)
import Data.List (intercalate, isInfixOf)
import HostBootstrap.Ensure (
    FramePlan (InstallHere),
    InstallStep (..),
    Reconciler (..),
    appleRow,
    frameTable,
    grantSocketAccess,
    installAndVerify,
    invokingNonRootUser,
    linuxRow,
    reconcilerInstallSteps,
    runTool,
    toolPresent,
    withInvokingGroupMember,
 )
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig, resolveMaybe)
import HostBootstrap.HostTool (AbsExe, HostTool (Brew, Colima, Incus, Sudo, Virtiofsd), absExePath)
import HostBootstrap.Substrate (Arch (Amd64, Arm64), Substrate, isAppleSilicon, isLinux, substrateArch)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), die)
#ifndef mingw32_HOST_OS
import System.Directory (doesPathExist)
import System.Posix.Files (fileAccess)
#endif

data KvmStatus = KvmOk | KvmAbsent | KvmUnwritable
    deriving (Eq, Show)

kvmDeviceStatus :: IO KvmStatus
#ifdef mingw32_HOST_OS
kvmDeviceStatus = pure KvmAbsent
#else
kvmDeviceStatus = do
  present <- doesPathExist "/dev/kvm"
  if not present
    then pure KvmAbsent
    else do
      readWrite <- fileAccess "/dev/kvm" True True False
      pure (if readWrite then KvmOk else KvmUnwritable)
#endif

appleIncusProfile :: String
appleIncusProfile = "incus"

{- | Total provider-capability observation. Package presence is intentionally
not a ready state.
-}
data IncusProviderStatus
    = IncusClientMissing
    | IncusDaemonAbsent String
    | IncusPermissionDenied String
    | IncusDaemonUnreachable String
    | IncusVMIncapable String
    | IncusNoEgress String
    | IncusProviderReady
    deriving (Eq, Show)

-- | Opaque capability minted only from the complete ready observation.
data IncusProviderCapability capabilityId = IncusProviderCapability

{- | Observe the configured provider before admitting its opaque capability.
The pure continuation supplies a result; admission does not execute an IO action
that the continuation returns. Descriptive statuses cannot mint the capability.
-}
withIncusProviderCapability ::
    HostConfig ->
    (forall capabilityId. IncusProviderCapability capabilityId -> result) ->
    IO (Either String result)
withIncusProviderCapability cfg consume = do
    status <- probeIncusProviderStatus cfg
    pure $ do
        incusProviderStatusResult status
        pure (consume IncusProviderCapability)

{- | Read a descriptive readiness result. A caller-built classification remains
data; only 'withIncusProviderCapability' performs capability admission.
-}
incusProviderStatusResult :: IncusProviderStatus -> Either String ()
incusProviderStatusResult IncusProviderReady = Right ()
incusProviderStatusResult status = Left ("Incus provider is not usable: " ++ show status)

{- | Where Incus looks for @virtiofsd@, in its own search order. Pure so the
list is pinned by a test rather than restated at a call site.
-}
virtiofsdCandidatePaths :: [FilePath]
virtiofsdCandidatePaths =
    [ "/usr/libexec/virtiofsd"
    , "/usr/lib/qemu/virtiofsd"
    , "/usr/lib/virtiofsd"
    ]

{- | The resolved Incus executable, observed VM capability, and root-daemon
responsiveness used by Linux convergence. This is descriptive input, not a
provider capability.
-}
data LinuxIncusObservation = LinuxIncusObservation AbsExe Bool Bool
    deriving (Eq, Show)

-- | VM support packages for the host architecture, including share and ACL tools.
linuxVmPackages :: Arch -> [String]
linuxVmPackages Amd64 = ["qemu-system-x86", "ovmf", "virtiofsd", "acl"]
linuxVmPackages Arm64 = ["qemu-system-arm", "qemu-efi-aarch64", "virtiofsd", "acl"]

{- | Sudo argument vectors for QEMU, alternative firmware images, and alternative
virtiofsd executables. A configured virtiofsd path is still tested for execution;
its presence in the configuration alone establishes no capability.
-}
linuxVmCapabilityProbes :: Arch -> Maybe AbsExe -> ([String], [[String]], [[String]])
linuxVmCapabilityProbes architecture resolvedVirtiofsd =
    ( ["test", "-x", qemu]
    , [["test", "-f", image] | image <- firmware]
    , [["test", "-x", path] | path <- virtiofsdCandidatePaths ++ [absExePath exe | Just exe <- [resolvedVirtiofsd]]]
    )
  where
    (qemu, firmware) = case architecture of
        Amd64 -> ("/usr/bin/qemu-system-x86_64", ["/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_CODE_4M.fd"])
        Arm64 -> ("/usr/bin/qemu-system-aarch64", ["/usr/share/AAVMF/AAVMF_CODE.fd"])

-- | QEMU and one successful result from each alternative group are required.
linuxVmCapabilitySatisfied :: Bool -> [Bool] -> [Bool] -> Bool
linuxVmCapabilitySatisfied qemu firmware virtiofsd = qemu && or firmware && or virtiofsd

-- | The root daemon probe uses the exact Incus executable retained by the plan.
linuxIncusDaemonProbeArgs :: AbsExe -> [String]
linuxIncusDaemonProbeArgs executable = [absExePath executable, "list", "--format", "csv", "-c", "n"]

-- | Repair only observed gaps, restarting once when either repair ran.
linuxIncusConvergence :: Arch -> LinuxIncusObservation -> [InstallStep]
linuxIncusConvergence architecture (LinuxIncusObservation executable vmReady daemonReady) =
    [InstallStep Sudo (["apt-get", "install", "-y"] ++ linuxVmPackages architecture) | not vmReady]
        ++ [InstallStep Sudo [absExePath executable, "admin", "init", "--minimal"] | not daemonReady]
        ++ [InstallStep Sudo ["systemctl", "restart", "incus"] | not vmReady || not daemonReady]

-- | The shared chain observation and each direction's check/insert vectors.
incusBridgeForwardingArgs :: ([String], [([String], [String])])
incusBridgeForwardingArgs =
    ( ["iptables", "-nL", "DOCKER-USER"]
    , [(rule "-C" direction, rule "-I" direction) | direction <- ["-i", "-o"]]
    )
  where
    rule operation direction = ["iptables", operation, "DOCKER-USER", direction, "incusbr0", "-j", "ACCEPT"]

-- | Try each module until the KVM device exists, regardless of a command's exit.
kvmModuleLoadArgs :: [[String]]
kvmModuleLoadArgs = [["modprobe", "kvm_intel"], ["modprobe", "kvm_amd"], ["modprobe", "kvm"]]

classifyIncusProviderStatus ::
    Bool ->
    Either String (ExitCode, String, String) ->
    Either String (ExitCode, String, String) ->
    Either String (ExitCode, String, String) ->
    IncusProviderStatus
classifyIncusProviderStatus clientPresent daemon capability egress
    | not clientPresent = IncusClientMissing
    | otherwise =
        case classifyDaemon daemon of
            Just status -> status
            Nothing ->
                case failureText capability of
                    Just reason -> IncusVMIncapable reason
                    Nothing ->
                        case failureText egress of
                            Just reason -> IncusNoEgress reason
                            Nothing -> IncusProviderReady
  where
    classifyDaemon result =
        case failureText result of
            Nothing -> Nothing
            Just reason
                | permissionMarker reason -> Just (IncusPermissionDenied reason)
                | absentMarker reason -> Just (IncusDaemonAbsent reason)
                | otherwise -> Just (IncusDaemonUnreachable reason)
    permissionMarker reason =
        any (`isInfixOf` lower reason) ["permission denied", "not authorized", "access denied"]
    absentMarker reason =
        any (`isInfixOf` lower reason) ["no such file", "daemon is not running", "connection refused"]
    lower = map toLower

failureText :: Either String (ExitCode, String, String) -> Maybe String
failureText result =
    case result of
        Left err -> Just err
        Right (ExitSuccess, _, _) -> Nothing
        Right (ExitFailure code, out, err) ->
            Just ("exit " ++ show code ++ ": " ++ firstLine (out ++ err))
  where
    firstLine = takeWhile (`notElem` ("\r\n" :: String))

reconciler :: Reconciler
reconciler =
    Reconciler
        { reconcilerName = "incus"
        , reconcilerSummary =
            "Ensure the incus host-provider is usable "
                ++ "(Colima on apple-silicon, native daemon on linux)"
        , -- The first reconciler with two rows. On apple-silicon a dedicated
          -- @incus@ Colima profile runs Incus as its runtime, so it coexists with
          -- the default Docker profile; on linux the native daemon is installed and
          -- initialized. Homebrew formula installs are intentionally expressed as
          -- @brew install@ steps, because Homebrew treats an already installed
          -- formula as a successful no-op — the idempotent path this wants.
          --
          -- Windows is an absent row rather than a refusal: the WSL2 frame owns the
          -- Windows host provider, and saying so twice is how two answers to one
          -- question start to differ.
          reconcilerFrames =
            frameTable
                [ appleRow
                    ( InstallHere
                        [ InstallStep Brew ["install", "incus"]
                        , InstallStep Brew ["install", "colima"]
                        , InstallStep Colima ["start", appleIncusProfile, "--runtime", "incus"]
                        ]
                    )
                , linuxRow
                    ( InstallHere
                        [ InstallStep Sudo ["apt-get", "install", "-y", "incus", "acl"]
                        ]
                    )
                ]
        , reconcile = reconcileIncus
        }

reconcileIncus :: HostConfig -> IO ()
reconcileIncus cfg = do
    if isLinux (hcSubstrate cfg)
        then reconcileLinuxIncus cfg
        else do
            installAndVerify "incus" appleSatisfied installSteps cfg
            refreshed <- buildHostConfig (hcSubstrate cfg)
            verifyUsableProvider refreshed

appleSatisfied :: HostConfig -> IO Bool
appleSatisfied cfg
    | not (toolPresent cfg Incus && toolPresent cfg Colima) = pure False
    | otherwise = do
        profile <- runTool cfg Colima ["status", appleIncusProfile]
        case profile of
            Right (ExitSuccess, _, _) -> incusReachable
            _ -> pure False
  where
    incusReachable = do
        listed <- runTool cfg Incus ["list"]
        pure $ case listed of
            Right (ExitSuccess, _, _) -> True
            _ -> False

reconcileLinuxIncus :: HostConfig -> IO ()
reconcileLinuxIncus cfg = do
    installAndVerify "incus client" (\candidate -> pure (toolPresent candidate Incus)) installSteps cfg
    refreshed <- buildHostConfig (hcSubstrate cfg)
    executable <-
        maybe
            (die "ensure incus: client disappeared before daemon initialization")
            pure
            (resolveMaybe refreshed Incus)
    capability <- probeLinuxVmCapability refreshed
    daemon <- runTool refreshed Sudo (linuxIncusDaemonProbeArgs executable)
    let observation = LinuxIncusObservation executable (probeSucceeded capability) (probeSucceeded daemon)
        steps = linuxIncusConvergence (substrateArch (hcSubstrate refreshed)) observation
    converged <- runLinuxConvergence refreshed steps
    ensureKvmAccess converged
    ensureIncusAdminGroup converged
    ensureBridgeForwarding converged
    verifyUsableProvider converged

runLinuxConvergence :: HostConfig -> [InstallStep] -> IO HostConfig
runLinuxConvergence cfg [] = pure cfg
runLinuxConvergence cfg (InstallStep tool arguments : remaining) = do
    runRequired cfg tool arguments
    refreshed <- buildHostConfig (hcSubstrate cfg)
    runLinuxConvergence refreshed remaining

verifyUsableProvider :: HostConfig -> IO ()
verifyUsableProvider cfg = do
    admitted <- withIncusProviderCapability cfg (const ())
    case admitted of
        Right () -> putStrLn "ensure incus: daemon, VM capability, and image-source egress ready"
        Left err -> die ("ensure incus: " ++ err)

probeIncusProviderStatus :: HostConfig -> IO IncusProviderStatus
probeIncusProviderStatus cfg
    | not (toolPresent cfg Incus) =
        pure IncusClientMissing
    | otherwise = do
        daemon <- runTool cfg Incus ["list", "--format", "csv", "-c", "n"]
        capability <-
            if isAppleSilicon (hcSubstrate cfg)
                then runTool cfg Colima ["status", appleIncusProfile]
                else probeLinuxVmCapability cfg
        egress <- runTool cfg Incus ["image", "info", "images:ubuntu/24.04"]
        pure
            ( classifyIncusProviderStatus
                True
                daemon
                capability
                egress
            )

probeLinuxVmCapability :: HostConfig -> IO (Either String (ExitCode, String, String))
probeLinuxVmCapability cfg = do
    let (qemuArgs, firmwareArgs, virtiofsdArgs) =
            linuxVmCapabilityProbes (substrateArch (hcSubstrate cfg)) (resolveMaybe cfg Virtiofsd)
    qemu <- runTool cfg Sudo qemuArgs
    firmware <- mapM (runTool cfg Sudo) firmwareArgs
    virtiofsd <- mapM (runTool cfg Sudo) virtiofsdArgs
    let qemuReady = probeSucceeded qemu
        firmwareReady = map probeSucceeded firmware
        virtiofsdReady = map probeSucceeded virtiofsd
        missing =
            [ name
            | (name, ready) <- [("QEMU executable", qemuReady), ("firmware image", or firmwareReady), ("virtiofsd executable", or virtiofsdReady)]
            , not ready
            ]
    pure $
        if linuxVmCapabilitySatisfied qemuReady firmwareReady virtiofsdReady
            then Right (ExitSuccess, "", "")
            else Left ("missing Linux VM capability: " ++ intercalate ", " missing)

probeSucceeded :: Either String (ExitCode, String, String) -> Bool
probeSucceeded (Right (ExitSuccess, _, _)) = True
probeSucceeded _ = False

runRequired :: HostConfig -> HostTool -> [String] -> IO ()
runRequired cfg tool args = do
    result <- runTool cfg tool args
    case result of
        Right (ExitSuccess, _, _) -> pure ()
        Right (ExitFailure code, _, err) ->
            die
                ( "ensure incus: "
                    ++ show tool
                    ++ " failed (exit "
                    ++ show code
                    ++ "): "
                    ++ err
                )
        Left err -> die ("ensure incus: " ++ err)

ensureBridgeForwarding :: HostConfig -> IO ()
ensureBridgeForwarding cfg = do
    let (chainArgs, rules) = incusBridgeForwardingArgs
    chain <- runTool cfg Sudo chainArgs
    case chain of
        Right (ExitSuccess, _, _) -> mapM_ ensureRule rules
        Right _ -> pure ()
        Left err -> die ("ensure incus: " ++ err)
  where
    ensureRule (checkArgs, insertArgs) = do
        checked <- runTool cfg Sudo checkArgs
        case checked of
            Right (ExitSuccess, _, _) -> pure ()
            Right _ -> runRequired cfg Sudo insertArgs
            Left err -> die ("ensure incus: " ++ err)
installSteps :: Substrate -> Either String [InstallStep]
installSteps = reconcilerInstallSteps reconciler

ensureIncusAdminGroup :: HostConfig -> IO ()
ensureIncusAdminGroup cfg =
    withInvokingGroupMember cfg incusLabel "incus-admin" $ \checkedStep user -> do
        grantSocketAccess checkedStep incusSocketPath user
        putStrLn (incusLabel ++ ": daemon socket access verified for the current invocation")

-- | The reconciler's name in every message it prints or dies with.
incusLabel :: String
incusLabel = "ensure incus"

-- | The daemon socket an invocation needs open before its group login exists.
incusSocketPath :: FilePath
incusSocketPath = "/var/lib/incus/unix.socket"

{- | Ensure the invoking user can open @/dev/kvm@, the nested-VM providers' gate.
Self-healing (see @development_plan_standards.md § L@), mirroring the @setfacl@
the VM bootstrap performs on the Docker socket: load the @kvm@ kernel module if
the node is absent, and grant the user @rw@ via @setfacl@ if it is present but
unwritable. Fails fast only on the irreducible residue — no @/dev/kvm@ after
@modprobe@ (firmware virtualization disabled), or still unwritable after
@setfacl@. A usable device is a verified no-op. Linux-only; the caller gates on
the substrate.
-}
ensureKvmAccess :: HostConfig -> IO ()
ensureKvmAccess cfg = do
    status <- kvmDeviceStatus
    case status of
        KvmOk -> putStrLn "ensure kvm: /dev/kvm read-write (no-op)"
        KvmAbsent -> do
            putStrLn "ensure kvm: /dev/kvm absent; loading the kvm kernel module"
            loadUntilPresent kvmModuleLoadArgs
        KvmUnwritable -> grantKvmReadWrite cfg
  where
    loadUntilPresent [] = die kvmFirmwareResidue
    loadUntilPresent (arguments : remaining) = do
        _ <- runTool cfg Sudo arguments
        afterModprobe <- kvmDeviceStatus
        case afterModprobe of
            KvmAbsent -> loadUntilPresent remaining
            _ -> grantKvmReadWrite cfg

{- | Grant the invoking user @rw@ on @/dev/kvm@ via @setfacl@, then re-verify.
Root already has @rw@ (so a root euid never reaches an unwritable status and
'invokingNonRootUser' returning 'Nothing' just re-verifies).
-}
grantKvmReadWrite :: HostConfig -> IO ()
grantKvmReadWrite cfg = do
    env <- getEnvironment
    selectedUser <- invokingNonRootUser env
    case selectedUser of
        Nothing -> verifyKvmReadWrite
        Just user -> do
            putStrLn ("ensure kvm: granting " ++ user ++ " rw on /dev/kvm via setfacl")
            result <- runTool cfg Sudo ["setfacl", "-m", "u:" ++ user ++ ":rw", "/dev/kvm"]
            case result of
                Right (ExitSuccess, _, _) -> verifyKvmReadWrite
                Right (ExitFailure n, _, errOut) ->
                    die ("ensure kvm: setfacl on /dev/kvm failed (exit " ++ show n ++ ") " ++ errOut)
                Left err -> die ("ensure kvm: " ++ err)

verifyKvmReadWrite :: IO ()
verifyKvmReadWrite = do
    status <- kvmDeviceStatus
    case status of
        KvmOk -> putStrLn "ensure kvm: /dev/kvm read-write"
        _ -> die kvmUnwritableResidue

kvmFirmwareResidue :: String
kvmFirmwareResidue =
    "ensure kvm: /dev/kvm not found after loading the kvm module; enable hardware "
        ++ "virtualization (Intel VT-x / AMD-V) in firmware and retry."

kvmUnwritableResidue :: String
kvmUnwritableResidue =
    "ensure kvm: /dev/kvm still not read/write after setfacl; grant rw on /dev/kvm and retry."
