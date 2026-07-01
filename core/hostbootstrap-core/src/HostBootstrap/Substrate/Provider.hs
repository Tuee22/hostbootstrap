{- | One pure lift into each host substrate.

The three metal substrates — Apple Silicon (Lima), native Linux (Incus), and
Windows (WSL2) — share one VM lifecycle: probe existence, launch sized to the
budget (cordon #1), reconcile-to-running, wait for readiness, stage files in,
and tear down (stop or guarded delete). Historically each substrate was
hand-branched at every one of those IO sites in the consumer binary; this
module collapses that to a single pure 'SubstrateProvider' value selected once
by 'selectSubstrateProvider' (the lifecycle peer of
'HostBootstrap.Cluster.Cordon.capacityReadPlan' and
'HostBootstrap.Lift.foldLeaf' — substrate knowledge as data, the IO a generic
interpreter).

Every per-substrate effect is expressed as pure data (a list of 'HostEffect'
and the probe/transfer records), so the whole surface is unit-testable without
running a host tool. The one place the substrates genuinely differ — Lima/Incus
launch with a single sized argv, whereas WSL2's only memory/CPU wall is the
/global/ @.wslconfig@ utility-VM ceiling that must be written and applied with
@wsl --shutdown@ before the distro boots — is captured by 'spLaunch' returning a
/list/ of effects: a 'WriteHostFile' for the WSL2 case, an empty file list for
the others. See @documents/engineering/applied_cordon.md@ and
@documents/engineering/wsl2.md@.
-}
module HostBootstrap.Substrate.Provider (
    -- * Pure effect vocabulary
    HostEffect (..),
    Membership (..),
    ExistsProbe (..),
    WaitProbe (..),
    FileTransfer (..),
    StagedFile (..),

    -- * The one pure lift per substrate
    VMHandles (..),
    SubstrateProvider (..),
    selectSubstrateProvider,

    -- * Pure interpreters over the provider's data
    membersOf,
    stageFileEffects,
    vmShellArgs,
    windowsPathToWslMount,
)
where

import Data.Char (isAsciiUpper)
import Data.List (isPrefixOf)
import HostBootstrap.Cluster.Cordon (
    ResourceBudget (..),
    budgetFromResources,
    gibibytes,
    incusSizingArgs,
    limaSizingArgs,
    wsl2SizingArgs,
 )
import HostBootstrap.Context (ProviderKind (..), ResourceEnvelope)
import HostBootstrap.HostTool (HostTool (Incus, Lima, Wsl))
import HostBootstrap.Incus (
    IncusVM (..),
    createVMArgs,
    destroyVMArgs,
    execVMArgs,
    pushFileArgs,
    startVMArgs,
    stopVMArgs,
 )
import HostBootstrap.Lift (LiftLayer (..))
import HostBootstrap.Lima (LimaVM (..))
import qualified HostBootstrap.Lima as Lima
import HostBootstrap.Substrate (Substrate, SubstrateName (..), substrateName)
import HostBootstrap.Wsl2 (Wsl2VM (..))
import qualified HostBootstrap.Wsl2 as Wsl2

{- | A single pure host-side effect the lifecycle interpreter runs. 'WriteHostFile'
and 'RestoreHostFile' exist for the WSL2 @.wslconfig@ wall (a /global/ user
file, so the write backs up any pre-existing copy and the restore puts it back);
'RunHostTool' is the resolved-tool invocation every substrate uses.
-}
data HostEffect
    = -- | write @content@ to @path@ on the host, preserving any existing file
      WriteHostFile FilePath String
    | -- | restore @path@ from its backup (or remove it if there was none)
      RestoreHostFile FilePath
    | -- | run a resolved host tool with these args
      RunHostTool HostTool [String]
    deriving (Eq, Show)

-- | How to read membership of a VM name out of an existence-probe's stdout.
data Membership
    = -- | the name is one of the output lines (@incus list@ / @limactl list@)
      LinesMember
    | -- | the name is a whitespace token of the NUL-stripped output (@wsl --list --quiet@)
      WslQuietMember
    deriving (Eq, Show)

{- | An idempotency probe: list with @tool args@, then test the VM id against the
parsed output by 'Membership'.
-}
data ExistsProbe = ExistsProbe HostTool [String] Membership
    deriving (Eq, Show)

{- | A readiness probe: @tool args@ that runs a trivial @true@ in the VM and
succeeds once the VM answers.
-}
data WaitProbe = WaitProbe HostTool [String]
    deriving (Eq, Show)

{- | How a host file reaches the guest: a tool push (Lima/Incus), or — for WSL2,
which has no host→guest copy tool — read in place through the @/mnt@ drive mount.
-}
data FileTransfer
    = IncusFileTransfer IncusVM
    | LimaFileTransfer LimaVM
    | Wsl2MountTransfer Wsl2VM
    deriving (Eq, Show)

{- | The result of planning one file transfer: the host effects to place the file,
the path the guest reads it from, and whether that path is a pushed temporary
(so the caller removes it after) or an in-place mount (so it does not).
-}
data StagedFile = StagedFile
    { sfHostEffects :: [HostEffect]
    , sfGuestPath :: FilePath
    , sfPushedTemp :: Bool
    }
    deriving (Eq, Show)

{- | The consumer-supplied handles the pure selection needs: the per-substrate VM
identities, the delete-guard prefix, and the resolved @.wslconfig@ path (an
environment lookup the consumer performs; unused off Windows).
-}
data VMHandles = VMHandles
    { vmhIncus :: IncusVM
    , vmhLima :: LimaVM
    , vmhWsl2 :: Wsl2VM
    , vmhGuardPrefix :: String
    , vmhWslConfigPath :: FilePath
    }
    deriving (Eq, Show)

{- | The one pure lift into a substrate. Every field is data except 'spLaunch',
which is a function only because the sized launch depends on the active
'ResourceEnvelope' (its 'Left' carries a budget-parse error). The teardown
'spDestroy' is 'Left' when the guard prefix refuses the VM name.
-}
data SubstrateProvider = SubstrateProvider
    { spVmId :: String
    , spProviderKind :: ProviderKind
    , spLiftLayer :: LiftLayer
    , spExists :: ExistsProbe
    , spLaunch :: ResourceEnvelope -> Either String [HostEffect]
    , spStartExisting :: [HostEffect]
    , spWait :: WaitProbe
    , spTransfer :: FileTransfer
    , spStop :: [HostEffect]
    , spDestroy :: Either String [HostEffect]
    }

{- | Select the one pure lift for a detected substrate. 'Left' only for a
substrate with no VM provider.
-}
selectSubstrateProvider :: Substrate -> VMHandles -> Either String SubstrateProvider
selectSubstrateProvider sub h = case substrateName sub of
    AppleSilicon -> Right apple
    LinuxCpu -> Right linux
    LinuxGpu -> Right linux
    WindowsCpu -> Right windows
    WindowsGpu -> Right windows
  where
    prefix = vmhGuardPrefix h

    apple =
        let vm = vmhLima h
         in SubstrateProvider
                { spVmId = limaName vm
                , spProviderKind = LimaVMProvider
                , spLiftLayer = ViaLimaVM vm
                , spExists = ExistsProbe Lima ["list", "-q"] LinesMember
                , spLaunch = \env -> do
                    sizing <- limaSizingArgs env
                    pure [RunHostTool Lima (Lima.startVMArgs vm (sizing ++ ["--vm-type", "vz"]))]
                , spStartExisting = [RunHostTool Lima ["start", limaName vm]]
                , spWait = WaitProbe Lima (Lima.shellVMArgs vm ["true"])
                , spTransfer = LimaFileTransfer vm
                , spStop = [RunHostTool Lima (Lima.stopVMArgs vm)]
                , spDestroy = (\argv -> [RunHostTool Lima argv]) <$> Lima.deleteVMArgs prefix vm
                }

    linux =
        let vm = vmhIncus h
         in SubstrateProvider
                { spVmId = vmName vm
                , spProviderKind = IncusVMProvider
                , spLiftLayer = ViaVM vm
                , spExists = ExistsProbe Incus ["list", "--format", "csv", "-c", "n"] LinesMember
                , spLaunch = \env -> do
                    sizing <- incusSizingArgs env
                    pure [RunHostTool Incus (createVMArgs vm (concatMap toLaunchFlag sizing))]
                , spStartExisting = [RunHostTool Incus (startVMArgs vm)]
                , spWait = WaitProbe Incus (execVMArgs vm ["true"])
                , spTransfer = IncusFileTransfer vm
                , spStop = [RunHostTool Incus (stopVMArgs vm)]
                , spDestroy = (\argv -> [RunHostTool Incus argv]) <$> destroyVMArgs prefix vm
                }

    windows =
        let vm = vmhWsl2 h
            distro = Wsl2.wsl2Distro vm
            wslConfig = vmhWslConfigPath h
         in SubstrateProvider
                { spVmId = distro
                , spProviderKind = Wsl2VMProvider
                , spLiftLayer = ViaWsl2VM vm
                , spExists = ExistsProbe Wsl ["--list", "--quiet"] WslQuietMember
                , spLaunch = \env -> do
                    body <- wsl2SizingArgs env
                    budget <- budgetFromResources env
                    let vhd = show (gibibytes (budgetStorageBytes budget)) ++ "GB"
                    pure
                        [ WriteHostFile wslConfig (unlines body)
                        , RunHostTool Wsl Wsl2.wslShutdownArgs
                        , RunHostTool Wsl (Wsl2.wslInstallArgs distro vhd)
                        ]
                , -- WSL2 has no explicit "start"; the readiness probe (@wsl -d … true@)
                  -- boots the distro on demand.
                  spStartExisting = []
                , spWait = WaitProbe Wsl (Wsl2.wslExecArgs distro ["true"])
                , spTransfer = Wsl2MountTransfer vm
                , spStop = [RunHostTool Wsl (Wsl2.wslTerminateArgs distro)]
                , spDestroy =
                    (\argv -> [RunHostTool Wsl argv, RestoreHostFile wslConfig])
                        <$> Wsl2.wslUnregisterArgs prefix distro
                }

    -- incus sizing args are key=value pairs; @root,size=…@ is a device override
    -- (@-d@), the rest are config keys (@-c@).
    toLaunchFlag a
        | "root," `isPrefixOf` a = ["-d", a]
        | otherwise = ["-c", a]

-- | Parse a VM-name list out of an existence-probe's stdout per 'Membership'.
membersOf :: Membership -> String -> [String]
membersOf LinesMember = lines
membersOf WslQuietMember = words . Wsl2.normalizeWslText

{- | Plan one host→guest file transfer (pure). Lima/Incus push to @dst@; WSL2 reads
@src@ in place through its @/mnt@ drive mount, so it emits no host effect.
-}
stageFileEffects :: FileTransfer -> FilePath -> FilePath -> StagedFile
stageFileEffects (IncusFileTransfer vm) src dst =
    StagedFile [RunHostTool Incus (pushFileArgs vm src dst)] dst True
stageFileEffects (LimaFileTransfer vm) src dst =
    StagedFile [RunHostTool Lima (Lima.copyToVMArgs vm src dst)] dst True
stageFileEffects (Wsl2MountTransfer _) src _ =
    StagedFile [] (windowsPathToWslMount src) False

{- | The resolved-tool invocation that runs @cmd@ inside a VM frame, for the
single-layer lift the consumer uses to shell into the distro. 'Nothing' for a
container layer (a container is reached through 'HostBootstrap.Lift', not here).
-}
vmShellArgs :: LiftLayer -> [String] -> Maybe (HostTool, [String])
vmShellArgs (ViaVM vm) cmd = Just (Incus, execVMArgs vm cmd)
vmShellArgs (ViaLimaVM vm) cmd = Just (Lima, Lima.shellVMArgs vm cmd)
vmShellArgs (ViaWsl2VM vm) cmd = Just (Wsl, Wsl2.wslExecArgs (Wsl2.wsl2Distro vm) cmd)
vmShellArgs (ViaContainer _) _ = Nothing

{- | Rewrite a Windows path (@C:\\…@) to its WSL2 drive mount (@/mnt/c/…@), so a
distro reads a host file in place without a copy tool. Pure.
-}
windowsPathToWslMount :: FilePath -> FilePath
windowsPathToWslMount path =
    case path of
        drive : ':' : rest -> "/mnt/" ++ [toLowerAscii drive] ++ map slash rest
        _ -> map slash path
  where
    slash '\\' = '/'
    slash c = c
    toLowerAscii c
        | isAsciiUpper c = toEnum (fromEnum c + 32)
        | otherwise = c
