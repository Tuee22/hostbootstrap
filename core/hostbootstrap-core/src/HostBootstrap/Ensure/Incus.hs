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
    targetIncusAdminUser,
    ensureKvmAccess,
  )
where

import Control.Monad (when)
import Data.List (find)
import Data.Maybe (mapMaybe)
import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    runTool,
    toolPresent,
  )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostPrereqs (KvmStatus (..), kvmDeviceStatus)
import HostBootstrap.HostTool (HostTool (Brew, Colima, Incus, Sudo))
import HostBootstrap.Substrate
  ( Substrate,
    SubstrateName (AppleSilicon, LinuxCpu, LinuxGpu, WindowsCpu, WindowsGpu),
    isAppleSilicon,
    isLinux,
    renderSubstrateName,
    substrateName,
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), die)

appleIncusProfile :: String
appleIncusProfile = "incus"

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "incus",
      reconcilerSummary =
        "Ensure the incus host-provider is usable "
          ++ "(Colima on apple-silicon, native daemon on linux)",
      -- The first reconciler applicable on BOTH apple-silicon and linux.
      appliesTo = \sub -> isAppleSilicon sub || isLinux sub,
      requirement = "apple-silicon or linux",
      reconcile = reconcileIncus
    }

reconcileIncus :: HostConfig -> IO ()
reconcileIncus cfg = do
  installAndVerify "incus" satisfied installSteps cfg
  when (isLinux (hcSubstrate cfg)) (ensureIncusAdminGroup cfg)

-- | Incus is satisfied when the client can reach a usable provider. On macOS
-- that means the named Colima Incus profile is running and @incus list@ can
-- reach the Colima-provided daemon. On linux the native daemon is installed and
-- initialized by the plan, so the resolved client is the satisfaction probe.
satisfied :: HostConfig -> IO Bool
satisfied cfg
  | isAppleSilicon (hcSubstrate cfg) = appleSatisfied cfg
  | otherwise = pure (toolPresent cfg Incus)

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

-- | The substrate-branched install plan. Homebrew formula installs are
-- intentionally expressed as @brew install@ steps; Homebrew treats an already
-- installed formula as a successful no-op, which is the idempotent path we want.
-- On apple-silicon, start a dedicated @incus@ Colima profile with Incus as the
-- runtime so it can coexist with the default Docker Colima profile. On linux,
-- @apt-get install -y incus@ then @sudo incus admin init --minimal@.
installSteps :: Substrate -> Either String [InstallStep]
installSteps sub = case substrateName sub of
  AppleSilicon ->
    Right
      [ InstallStep Brew ["install", "incus"],
        InstallStep Brew ["install", "colima"],
        InstallStep Colima ["start", appleIncusProfile, "--runtime", "incus"]
      ]
  LinuxCpu -> Right linuxSteps
  LinuxGpu -> Right linuxSteps
  WindowsCpu ->
    Left ("incus is not the Windows host-provider; use the WSL2 provider on " ++ renderSubstrateName WindowsCpu)
  WindowsGpu ->
    Left ("incus is not the Windows host-provider; use the WSL2 provider on " ++ renderSubstrateName WindowsGpu)
  where
    linuxSteps =
      [ InstallStep Sudo ["apt-get", "install", "-y", "incus"],
        InstallStep Sudo ["incus", "admin", "init", "--minimal"]
      ]

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
          putStrLn $
            "ensure incus: incus-admin group membership ensured; "
              ++ "start a new login shell if it was newly added"
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
