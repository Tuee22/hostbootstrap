{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}

-- | The @ensure incus@ reconciler: the host-provider tool, applicable on
-- **both** apple-silicon and linux (the first cross-substrate reconciler).
--
-- Install-and-verify (see @development_plan_standards.md § L, § U@):
-- on apple-silicon, @brew install incus@ + @brew install colima@ and
-- @colima start incus --runtime incus@, because macOS ships only the client and
-- the daemon must run inside Colima's Linux VM; on ubuntu-24.04,
-- @apt-get install incus@ + @sudo incus admin init --minimal@, plus the linux
-- invoking user in @incus-admin@ so the user can reach the daemon socket. A
-- verified no-op when the provider is usable; the permission step is still
-- reconciled on linux. The pure 'installSteps' planner is unit-tested.
module HostBootstrap.Ensure.Incus
  ( reconciler,
    installSteps,
    appleIncusProfile,
    IncusProviderStatus (..),
    IncusProviderCapability,
    classifyIncusProviderStatus,
    virtiofsdCandidatePaths,
    linuxVmCapabilityProbeScript,
    withIncusProviderCapability,
    probeIncusProviderStatus,
    targetIncusAdminUser,
    ensureKvmAccess,
  )
where

import Data.Char (toLower)
import Data.List (find, intercalate, isInfixOf)
import Data.Maybe (mapMaybe)
import HostBootstrap.Ensure
  ( FramePlan (InstallHere),
    InstallStep (..),
    Reconciler (..),
    appleRow,
    frameTable,
    installAndVerify,
    linuxRow,
    reconcilerInstallSteps,
    runTool,
    toolPresent,
  )
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig, resolveMaybe)
import HostBootstrap.HostTool (HostTool (Brew, Colima, Incus, Sudo), absExePath)
import HostBootstrap.Substrate (Substrate, isAppleSilicon, isLinux)
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

-- | Total provider-capability observation. Package presence is intentionally
-- not a ready state.
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

withIncusProviderCapability ::
  IncusProviderStatus ->
  (forall capabilityId. IncusProviderCapability capabilityId -> result) ->
  Either String result
withIncusProviderCapability IncusProviderReady consume =
  Right (consume IncusProviderCapability)
withIncusProviderCapability status _ =
  Left ("Incus provider is not usable: " ++ show status)

{- | Where Incus looks for @virtiofsd@, in its own search order. Pure so the
list is pinned by a test rather than restated at a call site.
-}
virtiofsdCandidatePaths :: [FilePath]
virtiofsdCandidatePaths =
  [ "/usr/libexec/virtiofsd",
    "/usr/lib/qemu/virtiofsd",
    "/usr/lib/virtiofsd"
  ]

{- | The Linux VM-capability probe: the QEMU binary, an OVMF firmware image, and
a @virtiofsd@ Incus can actually exec.

The @virtiofsd@ conjunct is what makes this probe answer the question § L asks —
whether the provider is *usable* — rather than merely whether a binary is
installed. A host with QEMU and OVMF but no @virtiofsd@ can launch a VM and then
fail every durable-share attach, so reporting it ready is the exact "installed
but not usable" claim the doctrine forbids.
-}
linuxVmCapabilityProbeScript :: String
linuxVmCapabilityProbeScript =
  intercalate
    " && "
    [ "test -x /usr/bin/qemu-system-x86_64",
      "(test -f /usr/share/OVMF/OVMF_CODE.fd || test -f /usr/share/OVMF/OVMF_CODE_4M.fd)",
      "(" ++ intercalate " || " (map candidate virtiofsdCandidatePaths ++ [onPath]) ++ ")"
    ]
  where
    candidate path = "test -x " ++ path
    onPath = "command -v virtiofsd >/dev/null 2>&1"

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
    { reconcilerName = "incus",
      reconcilerSummary =
        "Ensure the incus host-provider is usable "
          ++ "(Colima on apple-silicon, native daemon on linux)",
      -- The first reconciler with two rows. On apple-silicon a dedicated
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
                  [ InstallStep Brew ["install", "incus"],
                    InstallStep Brew ["install", "colima"],
                    InstallStep Colima ["start", appleIncusProfile, "--runtime", "incus"]
                  ]
              ),
            linuxRow
              ( InstallHere
                  [ InstallStep Sudo ["apt-get", "install", "-y", "incus", "acl"],
                    InstallStep Sudo ["incus", "admin", "init", "--minimal"]
                  ]
              )
          ],
      reconcile = reconcileIncus
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
  ensureKvmAccess refreshed
  -- @virtiofsd@ is not optional and is not pulled in by @incus@ or
  -- @qemu-system-x86@. Incus needs it to share a host directory into a *VM*,
  -- which is exactly the § DD Incus @ShareReconcile@ (a disk device attached
  -- post-create). Without it a hot-plugged share fails with
  -- @Failed to start device "...": Virtiofsd isn't running@ -- observed on a
  -- pristine Ubuntu 24.04 host, where every other part of this convergence
  -- reported ready.
  runRequired
    refreshed
    Sudo
    ["apt-get", "install", "-y", "qemu-system-x86", "ovmf", "virtiofsd", "acl"]
  ensureLinuxDaemon refreshed
  runRequired refreshed Sudo ["systemctl", "restart", "incus"]
  ensureIncusAdminGroup refreshed
  ensureBridgeForwarding refreshed
  verifyUsableProvider refreshed

ensureLinuxDaemon :: HostConfig -> IO ()
ensureLinuxDaemon cfg =
  case resolveMaybe cfg Incus of
    Nothing -> die "ensure incus: client disappeared before daemon initialization"
    Just incusExe -> do
      let listArgs = [absExePath incusExe, "list", "--format", "csv", "-c", "n"]
      rootProbe <- runTool cfg Sudo listArgs
      case rootProbe of
        Right (ExitSuccess, _, _) -> pure ()
        _ -> do
          runRequired cfg Sudo [absExePath incusExe, "admin", "init", "--minimal"]
          runRequired cfg Sudo listArgs

verifyUsableProvider :: HostConfig -> IO ()
verifyUsableProvider cfg = do
  status <- probeIncusProviderStatus cfg
  case withIncusProviderCapability status (const ()) of
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
          else
            runTool cfg Sudo ["sh", "-c", linuxVmCapabilityProbeScript]
      egress <- runTool cfg Incus ["image", "info", "images:ubuntu/24.04"]
      pure
        ( classifyIncusProviderStatus
            True
            daemon
            capability
            egress
        )

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
ensureBridgeForwarding cfg =
  mapM_ ensureRule ["-i", "-o"]
  where
    ensureRule direction =
      runRequired
        cfg
        Sudo
        [ "bash",
          "-c",
          "iptables -nL DOCKER-USER >/dev/null 2>&1 || exit 0; "
            ++ "iptables -C DOCKER-USER "
            ++ direction
            ++ " incusbr0 -j ACCEPT 2>/dev/null "
            ++ "|| iptables -I DOCKER-USER "
            ++ direction
            ++ " incusbr0 -j ACCEPT"
        ]
installSteps :: Substrate -> Either String [InstallStep]
installSteps = reconcilerInstallSteps reconciler

ensureIncusAdminGroup :: HostConfig -> IO ()
ensureIncusAdminGroup cfg = do
  env <- getEnvironment
  case targetIncusAdminUser env of
    Nothing ->
      putStrLn "ensure incus: no non-root invoking user detected for incus-admin membership (skipping)"
    Just user -> do
      putStrLn ("ensure incus: ensuring " ++ user ++ " belongs to incus-admin")
      result <- runTool cfg Sudo ["usermod", "-aG", "incus-admin", user]
      case result of
        Right (ExitSuccess, _, _) ->
          ensureImmediateSocketAccess cfg user
        Right (ExitFailure n, _, errOut) ->
          die
            ( "ensure incus: could not add "
                ++ user
                ++ " to incus-admin (exit "
                ++ show n
                ++ ") "
                ++ errOut
            )
        Left err -> die ("ensure incus: " ++ err)

ensureImmediateSocketAccess :: HostConfig -> String -> IO ()
ensureImmediateSocketAccess cfg user = do
  result <-
    runTool
      cfg
      Sudo
      ["setfacl", "-m", "u:" ++ user ++ ":rw", "/var/lib/incus/unix.socket"]
  case result of
    Right (ExitSuccess, _, _) ->
      putStrLn "ensure incus: daemon socket access verified for the current invocation"
    Right (ExitFailure code, _, err) ->
      die
        ( "ensure incus: could not grant immediate daemon socket access (exit "
            ++ show code
            ++ "): "
            ++ err
        )
    Left err -> die ("ensure incus: " ++ err)

-- | Ensure the invoking user can open @/dev/kvm@, the nested-VM providers' gate.
-- Self-healing (see @development_plan_standards.md § L@), mirroring the @setfacl@
-- the VM bootstrap performs on the Docker socket: load the @kvm@ kernel module if
-- the node is absent, and grant the user @rw@ via @setfacl@ if it is present but
-- unwritable. Fails fast only on the irreducible residue — no @/dev/kvm@ after
-- @modprobe@ (firmware virtualization disabled), or still unwritable after
-- @setfacl@. A usable device is a verified no-op. Linux-only; the caller gates on
-- the substrate.
ensureKvmAccess :: HostConfig -> IO ()
ensureKvmAccess cfg = do
  status <- kvmDeviceStatus
  case status of
    KvmOk -> putStrLn "ensure kvm: /dev/kvm read-write (no-op)"
    KvmAbsent -> do
      putStrLn "ensure kvm: /dev/kvm absent; loading the kvm kernel module"
      _ <-
        runTool
          cfg
          Sudo
          ["sh", "-c", "modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || modprobe kvm 2>/dev/null || true"]
      afterModprobe <- kvmDeviceStatus
      case afterModprobe of
        KvmAbsent -> die kvmFirmwareResidue
        _ -> grantKvmReadWrite cfg
    KvmUnwritable -> grantKvmReadWrite cfg

-- | Grant the invoking user @rw@ on @/dev/kvm@ via @setfacl@, then re-verify.
-- Root already has @rw@ (so a root euid never reaches an unwritable status and
-- 'targetIncusAdminUser' returning 'Nothing' just re-verifies).
grantKvmReadWrite :: HostConfig -> IO ()
grantKvmReadWrite cfg = do
  env <- getEnvironment
  case targetIncusAdminUser env of
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

-- | The login user whose future sessions should be allowed to talk to the incus
-- socket. Prefer @SUDO_USER@ so @sudo hostbootstrap ...@ grants the original
-- operator, then fall back to the non-sudo environment. Root itself needs no
-- group grant.
targetIncusAdminUser :: [(String, String)] -> Maybe String
targetIncusAdminUser env = find (/= "root") candidates
  where
    candidates =
      mapMaybe nonEmpty [lookup "SUDO_USER" env, lookup "LOGNAME" env, lookup "USER" env]
    nonEmpty (Just "") = Nothing
    nonEmpty value = value
