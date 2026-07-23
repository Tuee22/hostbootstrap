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
    ShareReconcile (..),
    HostPathShare (..),

    -- * The one pure lift per substrate
    VMHandles (..),
    SubstrateProvider (..),
    selectSubstrateProvider,

    -- * Pure interpreters over the provider's data
    membersOf,
    shareReconcileEffects,
    stageFileEffects,
    vmShellArgs,
    windowsPathToWslMount,

    -- * Guest-side durable alias (one pure state machine, § DD)
    AliasState (..),
    AliasFacts (..),
    classifyAlias,
    AliasAction (..),
    planAliasEnsure,
    AliasRemoval (..),
    planAliasRemove,
)
where

import Data.Char (isAsciiUpper)
import Data.List (dropWhileEnd, isPrefixOf)
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
    addDiskDeviceArgs,
    createVMArgs,
    deviceListArgs,
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
    | -- | merge a @[wsl2]@ body (header + keys) into the @.wslconfig@ at @path@,
      -- preserving the user's other sections (never a full clobber), backing up
      -- the original once so 'RestoreHostFile' can put it back
      MergeWslConfig FilePath [String]
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
    | -- | the name is a RUNNING distro per @wsl --list --verbose@ (the STATE column)
      WslRunningMember
    deriving (Eq, Show)

{- | An idempotency probe: list with @tool args@, then test a caller-owned
membership key (a VM id or managed device name) against the parsed output by
'Membership'.
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

{- | An optional post-create share reconciliation. The probe lists membership
keys, 'srMember' is the managed key to look for, and 'srWhenMissing' is the
effect list to run only when that key is absent. Incus uses this to make its
post-create disk-device attachment idempotent; Lima declares the share at VM
creation and WSL2 already exposes the host drive, so both use 'Nothing'.
-}
data ShareReconcile = ShareReconcile
    { srProbe :: ExistsProbe
    , srMember :: String
    , srWhenMissing :: [HostEffect]
    }
    deriving (Eq, Show)

{- | One host-backed directory as seen on both sides of a provider boundary.
Lima and Incus preserve the absolute path in the guest; WSL2 projects a Windows
drive path into its DrvFs mount. 'hpsReconcile' captures only an extra
/post-create/ step; Lima's create-time option is folded into 'spLaunch'.
-}
data HostPathShare = HostPathShare
    { hpsHostPath :: FilePath
    , hpsGuestPath :: FilePath
    , hpsReconcile :: Maybe ShareReconcile
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

{- | The one pure lift into a substrate. 'spLaunch' is a function because the
sized launch depends on the active 'ResourceEnvelope' and an optional host-path
share; 'spShare' projects a caller-supplied absolute host path into the
provider-specific pure share plan. The launch 'Left' carries a budget-parse
error. The teardown 'spDestroy' is 'Left' when the guard prefix refuses the VM
name.
-}
data SubstrateProvider = SubstrateProvider
    { spVmId :: String
    , spProviderKind :: ProviderKind
    , spLiftLayer :: LiftLayer
    , spExists :: ExistsProbe
    , spLaunch :: ResourceEnvelope -> Maybe HostPathShare -> Either String [HostEffect]
    , spShare :: FilePath -> HostPathShare
    , spStartExisting :: [HostEffect]
    , -- | @Nothing@ where the cordon is baked into the VM at create (Lima/Incus,
      -- which never idle-stop). @Just@ for WSL2, whose cordon is the GLOBAL
      -- @.wslconfig@ that only takes effect on a utility-VM restart: a running-state
      -- probe plus the effects to run when the distro is STOPPED (safe to restart).
      spReconcileCordon :: Maybe (ExistsProbe, [HostEffect])
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
                , spLaunch = \env share -> do
                    sizing <- limaSizingArgs env
                    let mount = maybe [] (Lima.writableMountArgs . hpsHostPath) share
                    pure [RunHostTool Lima (Lima.startVMArgs vm (sizing ++ ["--vm-type", "vz"] ++ mount))]
                , spShare = \source -> HostPathShare source source Nothing
                , spStartExisting = [RunHostTool Lima ["start", limaName vm]]
                , spReconcileCordon = Nothing
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
                , spLaunch = \env _ -> do
                    sizing <- incusSizingArgs env
                    pure [RunHostTool Incus (createVMArgs vm (concatMap toLaunchFlag sizing))]
                , spShare = \source ->
                    let device = "durable-data"
                        target = source
                     in HostPathShare
                            { hpsHostPath = source
                            , hpsGuestPath = target
                            , hpsReconcile =
                                Just
                                    ShareReconcile
                                        { srProbe = ExistsProbe Incus (deviceListArgs vm) LinesMember
                                        , srMember = device
                                        , srWhenMissing = [RunHostTool Incus (addDiskDeviceArgs vm device source target)]
                                        }
                            }
                , spStartExisting = [RunHostTool Incus (startVMArgs vm)]
                , spReconcileCordon = Nothing
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
                , spLaunch = \env _ -> do
                    body <- wsl2SizingArgs env
                    budget <- budgetFromResources env
                    let vhd = show (gibibytes (budgetStorageBytes budget)) ++ "GB"
                    pure
                        [ MergeWslConfig wslConfig body
                        , RunHostTool Wsl Wsl2.wslShutdownArgs
                        , RunHostTool Wsl (Wsl2.wslInstallArgs distro vhd)
                        ]
                , spShare = \source ->
                    HostPathShare
                        { hpsHostPath = source
                        , hpsGuestPath = windowsPathToWslMount source
                        , hpsReconcile = Nothing
                        }
                , -- WSL2 has no explicit "start"; the readiness probe (@wsl -d … true@)
                  -- boots the distro on demand.
                  spStartExisting = []
                , -- Apply the global @.wslconfig@ cordon on reconcile only when the
                  -- distro is STOPPED (a running distro already booted with it live):
                  -- probe the running state, and if stopped run @wsl --shutdown@ so the
                  -- utility VM re-reads @vmIdleTimeout=-1@ on its next cold boot.
                  spReconcileCordon =
                    Just
                        ( ExistsProbe Wsl ["--list", "--verbose"] WslRunningMember
                        , [RunHostTool Wsl Wsl2.wslShutdownArgs]
                        )
                , spWait = WaitProbe Wsl (Wsl2.wslExecArgs distro ["true"])
                , spTransfer = Wsl2MountTransfer vm
                , -- @project down@ terminates the distro AND restores the global
                  -- @.wslconfig@ (crash-recoverable never-clobber): the global cordon
                  -- stops throttling the user's other distros as soon as the stack is
                  -- stopped, not only on @destroy@. The file restore is idempotent
                  -- (a no-op when there was no backup to restore).
                  spStop =
                    [ RunHostTool Wsl (Wsl2.wslTerminateArgs distro)
                    , RestoreHostFile wslConfig
                    ]
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
membersOf WslQuietMember = Wsl2.wslListDistros
membersOf WslRunningMember = Wsl2.wslRunningDistros

{- | Classify a successful share-presence probe into the effects still needed.
No post-create plan means no effects. For an Incus plan, an output containing
the managed device name is already reconciled; otherwise emit its one add
effect. Probe execution and non-zero handling remain in the IO interpreter.
-}
shareReconcileEffects :: HostPathShare -> String -> [HostEffect]
shareReconcileEffects share output =
    case hpsReconcile share of
        Nothing -> []
        Just reconcile ->
            case srProbe reconcile of
                ExistsProbe _ _ membership
                    | srMember reconcile `elem` membersOf membership output -> []
                    | otherwise -> srWhenMissing reconcile

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

-- ---------------------------------------------------------------------------
-- Guest-side durable alias: one pure state machine (§ DD).
--
-- A host-backed durable share is only usable at the Docker boundary through a
-- stable Docker-visible alias — a symlink from a fixed path to the share. The
-- alias is minted by two lanes: the VM-shell lane (trivial guest probes:
-- @test -L@, @readlink@, @test -e@ — no compound @set -eu@, no nested @"$(…)"@,
-- so it survives the Windows PowerShell→@wsl@→@bash@ quoting path, § CC) and the
-- direct Linux-GPU lane (@System.Directory@). Both feed the SAME classifier and
-- planners here, so the absent/linked/collision/ownership logic is written ONCE,
-- not re-implemented per lane (it replaces three hand-coded shell/@System.Directory@
-- copies). Every step is readiness-gated by the consumer (§ CC): the alias cannot
-- be minted before a @Ready DurableShareMounted@ witness proves the share is a
-- writable directory.
-- ---------------------------------------------------------------------------

{- | The observed state of the stable Docker-visible alias that points at a
host-backed durable share (§ DD).
-}
data AliasState
    = -- | nothing exists at the alias path
      AliasAbsent
    | -- | a symlink already pointing at the expected share target (idempotent no-op)
      AliasLinkedCorrectly
    | -- | a symlink pointing somewhere else — a stale/foreign link (a collision)
      AliasLinkedElsewhere FilePath
    | -- | a non-symlink file or directory occupies the path (a collision)
      AliasOccupied
    deriving (Eq, Show)

{- | The raw facts a lane's probes gather about the alias path, classified the same
way by 'classifyAlias'. 'afSymlinkTarget' is @Just t@ exactly when the path is a
symlink (@t@ its @readlink@ / 'getSymbolicLinkTarget' target, or @""@ if the link
is present but its target could not be read); 'afExists' is whether the path exists
as anything at all (@test -e@ / a dir-or-file-or-symlink test).
-}
data AliasFacts = AliasFacts
    { afSymlinkTarget :: Maybe FilePath
    , afExists :: Bool
    }
    deriving (Eq, Show)

{- | Classify the alias path against the expected share target. Total. Trailing
slashes are trimmed before comparison; both lanes create the link with the exact
expected target string, so a correctly-linked alias compares equal.
-}
classifyAlias :: FilePath -> AliasFacts -> AliasState
classifyAlias expected facts = case afSymlinkTarget facts of
    Just t
        | trimTrailingSlash t == trimTrailingSlash expected -> AliasLinkedCorrectly
        | otherwise -> AliasLinkedElsewhere t
    Nothing
        | afExists facts -> AliasOccupied
        | otherwise -> AliasAbsent

trimTrailingSlash :: FilePath -> FilePath
trimTrailingSlash = dropWhileEnd (`elem` ("/\\" :: String))

{- | The action a lane takes to make the alias correct, from its 'AliasState'. An
idempotent correct link is 'AliasLeaveLinked'; an absent path is 'AliasCreateLink';
a collision ('AliasLinkedElsewhere' / 'AliasOccupied') is a 'Left' message — a
deterministic @Failed@ condition (§ CC), surfaced legibly, never a bare exit code.
Pure.
-}
data AliasAction = AliasLeaveLinked | AliasCreateLink
    deriving (Eq, Show)

planAliasEnsure :: FilePath -> FilePath -> AliasState -> Either String AliasAction
planAliasEnsure aliasPath target state = case state of
    AliasAbsent -> Right AliasCreateLink
    AliasLinkedCorrectly -> Right AliasLeaveLinked
    AliasLinkedElsewhere other ->
        Left ("durable alias " ++ aliasPath ++ " points to " ++ other ++ ", expected " ++ target)
    AliasOccupied ->
        Left ("durable alias collision: " ++ aliasPath ++ " already exists and is not a symbolic link to " ++ target)

{- | The teardown action: remove the alias **only** when it is still the exact link
this project owns ('AliasLinkedCorrectly' → 'AliasUnlink'); an absent path or a
foreign non-symlink occupant is left in place with a reason ('AliasKeep'); a
retargeted link is a 'Left' refusal (never silently clobbered). Pure. Mirrors the
never-delete-@.data@ discipline (§ Y): the host target itself is never removed here.
-}
data AliasRemoval = AliasKeep String | AliasUnlink
    deriving (Eq, Show)

planAliasRemove :: FilePath -> FilePath -> AliasState -> Either String AliasRemoval
planAliasRemove aliasPath target state = case state of
    AliasAbsent -> Right (AliasKeep ("durable alias " ++ aliasPath ++ " is already absent"))
    AliasLinkedCorrectly -> Right AliasUnlink
    AliasLinkedElsewhere other ->
        Left ("refusing to remove durable alias " ++ aliasPath ++ ": it points to " ++ other ++ ", expected " ++ target)
    AliasOccupied ->
        Right (AliasKeep ("durable alias path " ++ aliasPath ++ " is occupied by a non-symlink; leaving it untouched"))

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
