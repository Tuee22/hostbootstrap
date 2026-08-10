{-# LANGUAGE OverloadedStrings #-}

{- | Lower resource-budget verification and cordoning foundation.

This module owns canonical byte budgets, capacity observation and verification,
the storage-cordon policy, and provider argument rendering from an already
canonical 'ResourceBudget'.  It deliberately knows nothing about configuration
vocabularies, context envelopes, project plans, provider realizations, or
cluster lifecycle code.  "HostBootstrap.Cluster.Cordon" supplies the later
configuration adapters while retaining the public facade.
-}
module HostBootstrap.Cluster.Cordon.Foundation (
    ResourceBudget,
    mkResourceBudget,
    budgetCpu,
    budgetMemoryBytes,
    budgetStorageBytes,
    HostCapacity (..),
    CapacityReadSource (..),
    CapacityReadPlan (..),
    StorageCordonTarget (..),
    StorageCordonMechanism (..),
    StorageCordonUnsupportedReason (..),
    StorageCordonResult (..),
    capacityReadPlan,
    storageCordonPolicy,
    parseQuantity,
    verifyBudget,
    verifyHostBudget,
    hostMemoryReserveBytes,
    colimaSizingArgsForBudget,
    limaSizingArgsForBudget,
    wsl2SizingArgsForBudget,
    managedWslIdleTimeoutHours,
    managedWslIdleTimeoutMillis,
    kindNodeCordonArgsForBudget,
    incusSizingArgsForBudget,
    resolveHostCapacity,
    parseDfAvailableKBytes,
    gibibytes,
)
where

import Control.Exception (SomeException, displayException)
import Control.Exception.Safe (try)
import Data.Char (digitToInt, isDigit)
import Data.Int (Int64)
import Data.List (isPrefixOf)
import qualified Data.Text as T
import HostBootstrap.HostConfig (HostConfig (..), resolveMaybe)
import HostBootstrap.HostTool (HostTool (Df, PowerShell, Sysctl), absExePath)
import HostBootstrap.Substrate (Substrate, SubstrateName (..), renderSubstrateName, substrateName)
import Numeric.Natural (Natural)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

{- | A resolved resource budget in canonical units: whole CPU cores, and memory
/ storage in bytes.
-}
data ResourceBudget = ResourceBudget
    { budgetCpu :: Natural
    , budgetMemoryBytes :: Integer
    , budgetStorageBytes :: Integer
    }
    deriving (Eq, Show)

-- | Construct a positive, bounded canonical budget. Raw record construction is
-- private so zero/negative/overflowed values cannot reach provider builders.
mkResourceBudget :: Natural -> Integer -> Integer -> Either String ResourceBudget
mkResourceBudget cores memoryBytes storageBytes
    | cores == 0 = Left "resource budget: cpu must be positive"
    | cores > fromIntegral (maxBound :: Int) = Left "resource budget: cpu exceeds the supported bound"
    | memoryBytes <= 0 = Left "resource budget: memory must be positive"
    | storageBytes <= 0 = Left "resource budget: storage must be positive"
    | memoryBytes > maxResourceBytes = Left "resource budget: memory exceeds the supported bound"
    | storageBytes > maxResourceBytes = Left "resource budget: storage exceeds the supported bound"
    | otherwise = Right (ResourceBudget cores memoryBytes storageBytes)
  where
    maxResourceBytes = toInteger (maxBound :: Int64)

{- | Resolved host capacity, in the same canonical units. The reads differ by
substrate: Linux reports @/proc/meminfo@ @MemAvailable@ (genuinely spare RAM),
while Apple (@hw.memsize@) and Windows (@TotalPhysicalMemory@) report /total/
physical RAM — so the fields are named for the honest common denominator (the
host's capacity in each dimension), and the @budget + reserve@ headroom gate in
'verifyBudget' keeps a tight host from silently over-committing regardless of
which read a substrate uses.
-}
data HostCapacity = HostCapacity
    { totalCpu :: Natural
    , totalMemoryBytes :: Integer
    , totalStorageBytes :: Integer
    }
    deriving (Eq, Show)

-- | The concrete source used to read a capacity dimension.
data CapacityReadSource
    = ProcCpuinfo
    | ProcMemAvailable
    | SysctlKey String
    | WindowsLogicalProcessors
    | WindowsTotalMemory
    | WindowsSystemDriveFreeSpace
    | -- | free bytes on the filesystem holding @path@, via @df -k@ (Apple/Linux)
      PosixFreeStorage FilePath
    deriving (Eq, Show)

{- | The substrate-specific host-capacity read plan. Pure so the source mapping
stays unit-tested without executing host tools.
-}
data CapacityReadPlan = CapacityReadPlan
    { cpuCapacitySource :: CapacityReadSource
    , memoryCapacitySource :: CapacityReadSource
    , storageCapacitySource :: CapacityReadSource
    }
    deriving (Eq, Show)

-- | The substrate boundary at which a declared storage budget needs a wall.
data StorageCordonTarget
    = ColimaVmStorage
    | LimaVmStorage
    | IncusVmStorage
    | Wsl2DistroStorage
    | BareLinuxStorage
    deriving (Eq, Show)

-- | The concrete storage-wall mechanism represented by the provider builders.
data StorageCordonMechanism
    = ColimaDiskFlag
    | LimaDiskFlag
    | IncusRootDiskLimit
    | Wsl2VhdSize
    deriving (Eq, Show)

-- | A typed reason why a target cannot currently enforce the storage budget.
data StorageCordonUnsupportedReason
    = BareLinuxQuotaAndImageGcUnavailable
    deriving (Eq, Show)

-- | The honest storage-cordon policy result. A supported result identifies the
-- provider mechanism that an interpreter must apply. Bare Linux has neither a
-- quota'd host path nor an image-GC wall, so it returns an explicit typed
-- unsupported result instead of treating the capacity preflight as enforcement.
data StorageCordonResult
    = StorageCordonSupported StorageCordonMechanism
    | StorageCordonUnsupported StorageCordonUnsupportedReason
    deriving (Eq, Show)

-- | Select the represented storage-wall mechanism for a substrate boundary.
storageCordonPolicy :: StorageCordonTarget -> StorageCordonResult
storageCordonPolicy target = case target of
    ColimaVmStorage -> StorageCordonSupported ColimaDiskFlag
    LimaVmStorage -> StorageCordonSupported LimaDiskFlag
    IncusVmStorage -> StorageCordonSupported IncusRootDiskLimit
    Wsl2DistroStorage -> StorageCordonSupported Wsl2VhdSize
    BareLinuxStorage -> StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable

{- | Parse a Kubernetes-style quantity to bytes. Accepts binary suffixes
(@Ki@, @Mi@, @Gi@, @Ti@, optionally followed by @B@) and decimal suffixes
(@K@, @M@, @G@, @T@); a bare number is bytes. The one canonical quantity
grammar. Pure.
-}
parseQuantity :: T.Text -> Either String Integer
parseQuantity raw =
    let t = T.strip raw
        (numText, unitText) = T.span (\c -> isDigit c || c == '.') t
        unit = T.unpack (T.strip unitText)
     in if T.null numText
            then Left ("not a quantity: " ++ T.unpack raw)
            else case readDecimal (T.unpack numText) of
                Left err -> Left err
                Right (numerator, denominator) -> case multiplier unit of
                    Nothing -> Left ("unknown unit: " ++ unit ++ " in quantity: " ++ T.unpack raw)
                    Just m ->
                        let scaled = numerator * m
                         in if scaled `mod` denominator == 0
                                then Right (scaled `div` denominator)
                                else Left ("quantity is not an exact whole-byte value: " ++ T.unpack raw)

readDecimal :: String -> Either String (Integer, Integer)
readDecimal text =
    case break (== '.') text of
        (whole, "")
            | validDigits whole -> Right (digits whole, 1)
        (whole, '.' : fractional)
            | validDigits whole && validDigits fractional ->
                let denominator = 10 ^ length fractional
                 in Right (digits whole * denominator + digits fractional, denominator)
        _ -> Left ("not a number: " ++ text)
  where
    validDigits value = not (null value) && all isDigit value
    digits = foldl' (\total digit -> total * 10 + toInteger (digitToInt digit)) 0

-- | The byte multiplier for a quantity unit. @""@ is bytes.
multiplier :: String -> Maybe Integer
multiplier unit = case unit of
    "" -> Just 1
    "B" -> Just 1
    "Ki" -> Just (k 1)
    "KiB" -> Just (k 1)
    "Mi" -> Just (k 2)
    "MiB" -> Just (k 2)
    "Gi" -> Just (k 3)
    "GiB" -> Just (k 3)
    "Ti" -> Just (k 4)
    "TiB" -> Just (k 4)
    "K" -> Just (d 1)
    "M" -> Just (d 2)
    "G" -> Just (d 3)
    "T" -> Just (d 4)
    _ -> Nothing
  where
    k n = 1024 ^ (n :: Integer)
    d n = 1000 ^ (n :: Integer)

{- | The host-OS reserve subtracted from memory capacity before the budget must
fit: the headroom the host OS, the Docker daemon, and the orchestrator need
above the project budget (see @development_plan_standards.md § O@). Without it a
budget that merely fits under total RAM leaves no room for the host (a 16 GiB
host + 10 GiB VM passes with ~6 GiB left, then thrashes), which is exactly the
gap the preflight closes. ~4 GiB.
-}
hostMemoryReserveBytes :: Integer
hostMemoryReserveBytes = 4 * 1024 ^ (3 :: Integer)

{- | Verify a budget fits within resolved capacity, per dimension. Fails fast with
a one-line diagnostic naming the first dimension that does not fit. This is the
plain fit check the **in-VM cluster-slice** preflight uses — the slice is already
a reserved subset of the VM wall (§ O), checked against the VM's /available/
memory, so it applies **no** extra host reserve. The **metal** host preflight
('verifyHostBudget') adds the host-OS reserve on top.
-}
verifyBudget :: ResourceBudget -> HostCapacity -> Either String ()
verifyBudget b cap
    | budgetCpu b > totalCpu cap =
        Left (overMsg "cpu" (show (budgetCpu b)) (show (totalCpu cap)) "cores")
    | budgetMemoryBytes b > totalMemoryBytes cap =
        Left (overMsg "memory" (showGiB (budgetMemoryBytes b)) (showGiBFloor (totalMemoryBytes cap)) "GiB")
    | budgetStorageBytes b > totalStorageBytes cap =
        Left (overMsg "storage" (showGiB (budgetStorageBytes b)) (showGiBFloor (totalStorageBytes cap)) "GiB")
    | otherwise = Right ()
  where
    overMsg dim want have unit =
        "resource budget exceeds host capacity: "
            ++ dim
            ++ " wants "
            ++ want
            ++ " "
            ++ unit
            ++ ", host has "
            ++ have
            ++ " "
            ++ unit

{- | The **metal** host preflight: like 'verifyBudget' but additionally reserves
'hostMemoryReserveBytes' of memory headroom for the host OS + Docker + the
orchestrator (§ O), so a tight host is refused rather than silently
over-committed when it sizes the VM against /total/ host RAM. This is applied
**only** at the metal frame (the facade's @preflightHostBudget@), never to the in-VM cluster
slice — the slice is already the reserved subset, so re-reserving there would
double-count and fail against the VM's available memory.
-}
verifyHostBudget :: ResourceBudget -> HostCapacity -> Either String ()
verifyHostBudget b cap
    | budgetMemoryBytes b + hostMemoryReserveBytes > totalMemoryBytes cap =
        Left
            ( "resource budget plus host reserve exceeds host memory: wants "
                ++ showGiB (budgetMemoryBytes b)
                ++ " GiB + "
                ++ showGiB hostMemoryReserveBytes
                ++ " GiB host reserve, host has "
                ++ showGiBFloor (totalMemoryBytes cap)
                ++ " GiB"
            )
    | otherwise = verifyBudget b cap

{- | The complete @colima start@ argv that sizes a per-project VM to the budget
(the canonical arg-builder; the Python bootstrapper does not size VMs).
Memory and disk must already be exactly representable in whole GiB (Colima's
unit); an inexact hard ceiling is rejected rather than rounded upward. CPU is
the whole core count. Storage is cordoned here via @--disk@.
-}
colimaSizingArgsForBudget :: String -> ResourceBudget -> Either String [String]
colimaSizingArgsForBudget project b = do
    memoryGiB <- exactGibibytes "Colima memory" (budgetMemoryBytes b)
    storageGiB <- exactGibibytes "Colima storage" (budgetStorageBytes b)
    pure
        [ "start"
        , "--profile"
        , project
        , "--runtime"
        , "docker"
        , "--activate=false"
        , "--cpus"
        , show (budgetCpu b)
        , "--memory"
        , show memoryGiB
        , "--disk"
        , show storageGiB
        ]

-- | The Lima VM sizing flags derived from the same canonical resource parser.
limaSizingArgsForBudget :: ResourceBudget -> Either String [String]
limaSizingArgsForBudget b = do
    memoryGiB <- exactGibibytes "Lima memory" (budgetMemoryBytes b)
    storageGiB <- exactGibibytes "Lima storage" (budgetStorageBytes b)
    pure
        [ "--cpus"
        , show (budgetCpu b)
        , "--memory"
        , show memoryGiB
        , "--disk"
        , show storageGiB
        ]

{- | The applied Linux kind-node cordon argv: a @docker update@ cap on the
resolved control-plane container. @--memory@ is the steady-state RAM cap
(the cluster slice), while @--memory-swap@ is set to @2 ×@ that so the node has
swap headroom equal to its RAM: a transient multi-GB spike (a @kind load@ /
image push materialising a large layer) can burst into swap instead of being
OOM-killed at the floor, while steady-state memory still self-limits to the
slice. Storage carries **no** @docker update@ flag, so it is omitted here and
cordoned per-substrate elsewhere (Colima @--disk@, incus @root,size@, a quota'd
hostPath on bare Linux).
-}
kindNodeCordonArgsForBudget :: String -> ResourceBudget -> Either String [String]
kindNodeCordonArgsForBudget containerName b = do
    pure
        [ "update"
        , "--cpus"
        , show (budgetCpu b)
        , "--memory"
        , show (budgetMemoryBytes b)
        , "--memory-swap"
        , show (2 * budgetMemoryBytes b)
        , containerName
        ]

{- | The incus VM sizing args from the one canonical parser: @limits.cpu@,
@limits.memory@, and @root,size@. Unlike @docker update@, incus cordons
storage at the VM wall, so storage **is** included here (via @root,size@). The
form is a list of @incus@ config arguments the caller applies to the VM.
-}
incusSizingArgsForBudget :: ResourceBudget -> Either String [String]
incusSizingArgsForBudget b = do
    memoryGiB <- exactGibibytes "Incus memory" (budgetMemoryBytes b)
    storageGiB <- exactGibibytes "Incus storage" (budgetStorageBytes b)
    pure
        [ "limits.cpu=" ++ show (budgetCpu b)
        , "limits.memory=" ++ show memoryGiB ++ "GiB"
        , "root,size=" ++ show storageGiB ++ "GiB"
        ]

{- | The WSL2 wall as a @.wslconfig@ @[wsl2]@ body derived from the one canonical
parser. WSL2's only memory/CPU wall is the /global/ utility-VM ceiling this
file sets (there is no per-distro @wsl --memory@/@--cpu@); the provider writes
it and applies it with @wsl --shutdown@ before the distro boots. @swap@ is sized
to the memory budget for OOM headroom so a budget-fitting build is not killed.
Storage is /not/ a @.wslconfig@ key — the per-distro VHDX cap is applied at
install time via @wsl --install --vhd-size@ (see
'HostBootstrap.Wsl2.wslInstallArgs'), so it is intentionally absent here.
Two idle-timeout keys, in two sections, are both required: @[wsl2] vmIdleTimeout@
pins the shared /utility VM/ alive across the gaps between the separate @wsl -d@
steps a lifecycle runs, while @[general] instanceIdleTimeout@ keeps the individual
distro /instance/ alive after the last @wsl@ session ends. @vmIdleTimeout@ governs
only the utility VM, so with it alone the distro (and its kind cluster) still
idle-stops ~15–60 s after @project up@ returns — and the kind control plane does not
recover on the next cold start. @instanceIdleTimeout@ is the peer that closes that
gap (see @documents/engineering/wsl2.md@).

Both keys carry the /finite/ 'managedWslIdleTimeoutMillis' rather than the
never-idle @-1@ they previously used. @-1@ kept the distro from idle-stopping
mid-run, but it also meant the shared utility VM held the whole memory balloon
until the next reboot: a wall that is never released is not a wall the host
shares. A duration measured in hours preserves the mid-run guarantee — the demo
gate runs 25–50 minutes — while guaranteeing the host eventually recovers the
memory even if teardown never runs.
-}
wsl2SizingArgsForBudget :: ResourceBudget -> Either String [String]
wsl2SizingArgsForBudget b = do
    memoryGiB <- exactGibibytes "WSL2 memory" (budgetMemoryBytes b)
    _storageGiB <- exactGibibytes "WSL2 VHDX storage" (budgetStorageBytes b)
    pure
        [ "[general]"
        , "instanceIdleTimeout=" ++ show managedWslIdleTimeoutMillis
        , "[wsl2]"
        , "processors=" ++ show (budgetCpu b)
        , "memory=" ++ show memoryGiB ++ "GB"
        , "swap=" ++ show memoryGiB ++ "GB"
        , "vmIdleTimeout=" ++ show managedWslIdleTimeoutMillis
        ]

{- | How long the managed @.wslconfig@ body keeps the shared utility VM and the
project distro alive after their last session, expressed in whole hours. This is
the single place the duration is chosen; 'managedWslIdleTimeoutMillis' derives
the emitted value so neither call site carries a magic number.

Six hours is an order of magnitude beyond the longest lifecycle this project
runs (the demo gate is 25–50 minutes), so no run can be idle-stopped in the gaps
between its @wsl -d@ steps, while an abandoned run still returns the balloon to
the host the same day.
-}
managedWslIdleTimeoutHours :: Int
managedWslIdleTimeoutHours = 6

{- | 'managedWslIdleTimeoutHours' in the milliseconds both @.wslconfig@
idle-timeout keys are denominated in.
-}
managedWslIdleTimeoutMillis :: Int
managedWslIdleTimeoutMillis = managedWslIdleTimeoutHours * 60 * 60 * 1000

-- | Select the host-capacity read sources for a detected substrate.
capacityReadPlan :: Substrate -> CapacityReadPlan
capacityReadPlan sub = case substrateName sub of
    AppleSilicon -> CapacityReadPlan (SysctlKey "hw.ncpu") (SysctlKey "hw.memsize") posixFreeStorage
    LinuxCpu -> linuxReadPlan
    LinuxGpu -> linuxReadPlan
    WindowsCpu -> windowsReadPlan
    WindowsGpu -> windowsReadPlan
  where
    linuxReadPlan = CapacityReadPlan ProcCpuinfo ProcMemAvailable posixFreeStorage
    windowsReadPlan = CapacityReadPlan WindowsLogicalProcessors WindowsTotalMemory WindowsSystemDriveFreeSpace
    -- The root filesystem's free space stands in for the project root's — the
    -- applied per-substrate storage cordon (Colima @--disk@ / incus @root,size@)
    -- is still the hard wall, but the preflight now gates on real free disk on
    -- Apple/Linux too instead of an unconditional petabyte.
    posixFreeStorage = PosixFreeStorage "/"

{- | Resolve host capacity for the preflight. CPU, memory, and storage
come from the substrate-specific sources selected by 'capacityReadPlan'.
Apple/Linux read the root filesystem's actual free bytes; Windows reads the
system-drive free bytes so WSL2 does not start a large VHDX-backed build on a
disk that cannot satisfy the declared storage budget.
-}
resolveHostCapacity :: HostConfig -> IO (Either String HostCapacity)
resolveHostCapacity cfg = do
    let plan = capacityReadPlan (hcSubstrate cfg)
    cores <- readCores cfg (cpuCapacitySource plan)
    mem <- readAvailableMemory cfg (memoryCapacitySource plan)
    storageCap <- readAvailableStorage cfg (storageCapacitySource plan)
    pure $ do
        c <- cores
        m <- mem
        s <- storageCap
        pure (HostCapacity c m s)

-- | Count CPU cores from the substrate-selected source.
readCores :: HostConfig -> CapacityReadSource -> IO (Either String Natural)
readCores _ ProcCpuinfo = do
    exists <- doesFileExist "/proc/cpuinfo"
    if not exists
        then pure (Left "host capacity: /proc/cpuinfo is not available")
        else do
            result <- try (readFile "/proc/cpuinfo") :: IO (Either SomeException String)
            pure $ case result of
                Right contents ->
                    let n = length (filter ("processor" `isPrefixOf`) (lines contents))
                     in if n > 0
                            then Right (fromIntegral n)
                            else Left "host capacity: no processors found in /proc/cpuinfo"
                Left e -> Left ("host capacity: failed to read /proc/cpuinfo: " ++ displayException e)
readCores cfg (SysctlKey key) = fmap (fmap fromInteger) (readSysctlPositiveInteger cfg key)
readCores cfg WindowsLogicalProcessors =
    fmap (fmap fromInteger) $
        readPowerShellPositiveInteger cfg "(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors"
readCores _ source =
    pure (Left ("host capacity: unsupported CPU source " ++ show source))

-- | Read available memory from the substrate-selected source, in bytes.
readAvailableMemory :: HostConfig -> CapacityReadSource -> IO (Either String Integer)
readAvailableMemory _ ProcMemAvailable = do
    exists <- doesFileExist "/proc/meminfo"
    if not exists
        then pure (Left "host capacity: /proc/meminfo is not available")
        else do
            result <- try (readFile "/proc/meminfo") :: IO (Either SomeException String)
            pure $ case result of
                Right contents -> case findMemAvailable (lines contents) of
                    Just kb -> Right (kb * 1024)
                    Nothing -> Left "host capacity: MemAvailable not found in /proc/meminfo"
                Left e -> Left ("host capacity: failed to read /proc/meminfo: " ++ displayException e)
readAvailableMemory cfg (SysctlKey key) = readSysctlPositiveInteger cfg key
-- Windows reads /total/ physical memory (already in bytes), not free: it mirrors
-- Apple's stable @hw.memsize@ so the preflight is a property of the machine, not a
-- volatile point-in-time free-RAM reading. A budget-fitting host then fails fast
-- before the expensive build rather than passing on transient post-reboot free RAM
-- (see @documents/engineering/applied_cordon.md@).
readAvailableMemory cfg WindowsTotalMemory =
    readPowerShellPositiveInteger cfg "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory"
readAvailableMemory _ source =
    pure (Left ("host capacity: unsupported memory source " ++ show source))

-- | Read available storage from the substrate-selected source, in bytes.
readAvailableStorage :: HostConfig -> CapacityReadSource -> IO (Either String Integer)
readAvailableStorage cfg WindowsSystemDriveFreeSpace =
    readPowerShellPositiveInteger cfg "(Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free"
readAvailableStorage cfg (PosixFreeStorage path) =
    readDfFreeBytes cfg path
readAvailableStorage _ source =
    pure (Left ("host capacity: unsupported storage source " ++ show source))

{- | Read the free bytes of the filesystem holding @path@ via @df -P -k@ (portable
across macOS BSD @df@ and Linux GNU @df@). @-P@ forces the POSIX one-line-per-
filesystem format (no device-name line wrap) and @-k@ forces 1024-byte blocks,
so the data line's 4th field is 1K-blocks available and the free bytes are that
field × 1024. Pure parsing is 'parseDfAvailableKBytes'.
-}
readDfFreeBytes :: HostConfig -> FilePath -> IO (Either String Integer)
readDfFreeBytes cfg path = case resolveMaybe cfg Df of
    Nothing ->
        pure $ Left ("host capacity: df is not resolved for " ++ renderSubstrateName (substrateName (hcSubstrate cfg)))
    Just exe -> do
        result <-
            try (readProcessWithExitCode (absExePath exe) ["-P", "-k", path] "") ::
                IO (Either SomeException (ExitCode, String, String))
        pure $ case result of
            Right (ExitSuccess, out, _) ->
                maybe
                    (Left ("host capacity: could not parse df output for " ++ path))
                    (\kb -> Right (kb * 1024))
                    (parseDfAvailableKBytes out)
            Right (ExitFailure n, _, err) ->
                Left ("host capacity: df -k " ++ path ++ " failed (exit " ++ show n ++ "): " ++ T.unpack (T.strip (T.pack err)))
            Left e ->
                Left ("host capacity: failed to run df -k " ++ path ++ ": " ++ displayException e)

{- | Parse the available-1K-blocks field (4th column) of the data line (2nd line)
of @df -k@ output. Pure.
-}
parseDfAvailableKBytes :: String -> Maybe Integer
parseDfAvailableKBytes out = case drop 1 (lines out) of
    (dataLine : _) -> case drop 3 (words dataLine) of
        (avail : _) -> case reads avail of
            [(n, "")] -> Just n
            _ -> Nothing
        _ -> Nothing
    _ -> Nothing

readPowerShellPositiveInteger :: HostConfig -> String -> IO (Either String Integer)
readPowerShellPositiveInteger cfg expr = case resolveMaybe cfg PowerShell of
    Nothing ->
        pure $ Left ("host capacity: powershell.exe is not resolved for " ++ renderSubstrateName (substrateName (hcSubstrate cfg)))
    Just exe -> do
        result <-
            try (readProcessWithExitCode (absExePath exe) ["-NoProfile", "-Command", expr] "") ::
                IO (Either SomeException (ExitCode, String, String))
        pure $ case result of
            Right (ExitSuccess, out, _) ->
                parsePositiveInteger ("powershell " ++ expr) (T.unpack (T.strip (T.pack out)))
            Right (ExitFailure n, _, err) ->
                Left
                    ( "host capacity: powershell "
                        ++ expr
                        ++ " failed (exit "
                        ++ show n
                        ++ "): "
                        ++ T.unpack (T.strip (T.pack err))
                    )
            Left e ->
                Left ("host capacity: failed to run powershell " ++ expr ++ ": " ++ displayException e)

readSysctlPositiveInteger :: HostConfig -> String -> IO (Either String Integer)
readSysctlPositiveInteger cfg key = do
    value <- readSysctl cfg key
    pure $ do
        raw <- value
        parsePositiveInteger ("sysctl " ++ key) raw

readSysctl :: HostConfig -> String -> IO (Either String String)
readSysctl cfg key = case resolveMaybe cfg Sysctl of
    Nothing ->
        pure $
            Left
                ( "host capacity: sysctl is not resolved for "
                    ++ renderSubstrateName (substrateName (hcSubstrate cfg))
                )
    Just exe -> do
        result <-
            try (readProcessWithExitCode (absExePath exe) ["-n", key] "") ::
                IO (Either SomeException (ExitCode, String, String))
        pure $ case result of
            Right (ExitSuccess, out, _) -> Right (T.unpack (T.strip (T.pack out)))
            Right (ExitFailure n, _, err) ->
                Left
                    ( "host capacity: sysctl "
                        ++ key
                        ++ " failed (exit "
                        ++ show n
                        ++ "): "
                        ++ T.unpack (T.strip (T.pack err))
                    )
            Left e ->
                Left ("host capacity: failed to run sysctl " ++ key ++ ": " ++ displayException e)

parsePositiveInteger :: String -> String -> Either String Integer
parsePositiveInteger label raw = case reads raw of
    [(n, "")]
        | n > 0 -> Right n
        | otherwise -> Left ("host capacity: " ++ label ++ " returned non-positive value " ++ show n)
    _ -> Left ("host capacity: " ++ label ++ " returned non-integer value " ++ show raw)

findMemAvailable :: [String] -> Maybe Integer
findMemAvailable ls = case [w | l <- ls, "MemAvailable:" `isPrefixOf` l, w <- take 1 (drop 1 (words l))] of
    (kb : _) -> case reads kb of
        [(n, "")] -> Just n
        _ -> Nothing
    [] -> Nothing

-- | Bytes to whole gibibytes, rounded up.
gibibytes :: Integer -> Integer
gibibytes bytes = (bytes + gib - 1) `div` gib
  where
    gib = 1024 ^ (3 :: Integer)

exactGibibytes :: String -> Integer -> Either String Integer
exactGibibytes label bytes
    | bytes `mod` gib /= 0 =
        Left (label ++ " must be exactly representable as whole GiB; got " ++ show bytes ++ " bytes")
    | otherwise = Right (bytes `div` gib)
  where
    gib = 1024 ^ (3 :: Integer)

showGiB :: Integer -> String
showGiB = show . gibibytes

{- | Bytes to whole gibibytes rounded DOWN, for the spare-capacity ("have") side
of a budget diagnostic — so a failing check never prints an equal, misleading
"wants N GiB, host has N GiB spare" (the "wants" side rounds up via 'showGiB').
-}
showGiBFloor :: Integer -> String
showGiBFloor bytes = show (bytes `div` (1024 ^ (3 :: Integer)))
