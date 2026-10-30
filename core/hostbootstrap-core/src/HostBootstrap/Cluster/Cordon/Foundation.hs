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
    BudgetDimension (..),
    QuantityError (..),
    renderQuantityError,
    ResourceBudget,
    mkResourceBudget,
    budgetCpu,
    budgetMemoryBytes,
    budgetStorageBytes,
    HostCapacity (..),
    CpuSource (..),
    MemorySource (..),
    StorageSource (..),
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
    kindNodeCordonLimitsForBudget,
    incusSizingArgsForBudget,
    resolveHostCapacity,
    parseCpuinfoProcessors,
    parseMemAvailableBytes,
    parsePositiveInteger,
    parseDfAvailableKBytes,
    gibibytes,
)
where

import Control.Exception (SomeException, displayException)
import Control.Exception.Safe (try)
import Data.Bifunctor (first)
import Data.Char (digitToInt, isDigit)
import Data.Int (Int64)
import Data.List (isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.IO as TextIO
import HostBootstrap.Cluster.Cordon.WindowsCapacity (
    readWindowsLogicalProcessors,
    readWindowsSystemDriveFreeSpace,
    readWindowsTotalMemory,
    renderWindowsCapacityError,
 )
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun (CapturedRun))
import HostBootstrap.Effect.Vocabulary (hostCommand)
import HostBootstrap.HostConfig (HostConfig (..), resolveMaybe)
import HostBootstrap.HostTool (HostTool (Df, Sysctl))
import HostBootstrap.Substrate (
    HostFrame (AppleFrame, LinuxFrame, WindowsFrame),
    Substrate,
    renderSubstrateName,
    substrateFrame,
    substrateName,
 )
import Numeric.Natural (Natural)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))

{- | A resolved resource budget in canonical units: whole CPU cores, and memory
/ storage in bytes. The constructor is private and the readers are ordinary
functions, so an admitted value exposes no record-update route.
-}
data ResourceBudget = ResourceBudget Natural Integer Integer
    deriving (Eq)

instance Show ResourceBudget where
    showsPrec precedence (ResourceBudget cores memoryBytes storageBytes) =
        showParen (precedence > 10) $
            showString "ResourceBudget {budgetCpu = "
                . shows cores
                . showString ", budgetMemoryBytes = "
                . shows memoryBytes
                . showString ", budgetStorageBytes = "
                . shows storageBytes
                . showChar '}'

-- | The validated whole CPU-core count, without a record-update route.
budgetCpu :: ResourceBudget -> Natural
budgetCpu (ResourceBudget cores _ _) = cores

-- | The validated memory ceiling in bytes.
budgetMemoryBytes :: ResourceBudget -> Integer
budgetMemoryBytes (ResourceBudget _ memoryBytes _) = memoryBytes

-- | The validated storage ceiling in bytes.
budgetStorageBytes :: ResourceBudget -> Integer
budgetStorageBytes (ResourceBudget _ _ storageBytes) = storageBytes

{- | Which dimension of a canonical budget an answer is about.

The three dimensions are the budget's own fields, so a refusal names one of them
rather than spelling it as a word inside a sentence.
-}
data BudgetDimension = BudgetCpu | BudgetMemory | BudgetStorage
    deriving (Eq, Show)

{- | Why a canonical quantity or budget could not be constructed.

A caller that needs to know /which/ dimension was refused, or /which/ bound it
broke, reads it off the value. 'renderQuantityError' is the one place that turns
one into the operator-facing sentence, so the diagnostic and the machine-readable
answer cannot drift apart.
-}
data QuantityError
    = -- | the dimension is zero or negative
      DimensionNotPositive BudgetDimension
    | -- | the dimension is above the supported bound
      DimensionAboveBound BudgetDimension
    | -- | the text does not begin with a number
      QuantityNotANumber T.Text
    | -- | the numeric part is not a decimal number
      QuantityMalformedNumber String
    | -- | the unit suffix is not one of the accepted ones
      QuantityUnknownUnit String T.Text
    | -- | the value scales to a fraction of a byte
      QuantityNotWholeBytes T.Text
    deriving (Eq, Show)

-- | The operator-facing sentence one refusal carries.
renderQuantityError :: QuantityError -> String
renderQuantityError err = case err of
    DimensionNotPositive dimension ->
        "resource budget: " ++ renderDimension dimension ++ " must be positive"
    DimensionAboveBound dimension ->
        "resource budget: " ++ renderDimension dimension ++ " exceeds the supported bound"
    QuantityNotANumber raw -> "not a quantity: " ++ T.unpack raw
    QuantityMalformedNumber text -> "not a number: " ++ text
    QuantityUnknownUnit unit raw ->
        "unknown unit: " ++ unit ++ " in quantity: " ++ T.unpack raw
    QuantityNotWholeBytes raw ->
        "quantity is not an exact whole-byte value: " ++ T.unpack raw

renderDimension :: BudgetDimension -> String
renderDimension BudgetCpu = "cpu"
renderDimension BudgetMemory = "memory"
renderDimension BudgetStorage = "storage"

{- | Construct a positive, bounded canonical budget. Its private constructor
keeps zero/negative/overflowed values out of provider builders.
-}
mkResourceBudget :: Natural -> Integer -> Integer -> Either QuantityError ResourceBudget
mkResourceBudget cores memoryBytes storageBytes
    | cores == 0 = Left (DimensionNotPositive BudgetCpu)
    | cores > fromIntegral (maxBound :: Int) = Left (DimensionAboveBound BudgetCpu)
    | memoryBytes <= 0 = Left (DimensionNotPositive BudgetMemory)
    | storageBytes <= 0 = Left (DimensionNotPositive BudgetStorage)
    | memoryBytes > maxResourceBytes = Left (DimensionAboveBound BudgetMemory)
    | storageBytes > maxResourceBytes = Left (DimensionAboveBound BudgetStorage)
    | otherwise = Right (ResourceBudget cores memoryBytes storageBytes)
  where
    maxResourceBytes = toInteger (maxBound :: Int64)

{- | Resolved host capacity, in the same canonical units. The reads differ by
substrate: Linux reports @/proc/meminfo@ @MemAvailable@ (genuinely spare RAM),
while Apple (@hw.memsize@) and Windows (@GlobalMemoryStatusEx@) report /total/
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

-- | The concrete source used to read logical CPU capacity.
data CpuSource
    = ProcCpuinfo
    | CpuSysctlKey String
    | WindowsLogicalProcessors
    deriving (Eq, Show)

-- | The concrete source used to read memory capacity.
data MemorySource
    = ProcMemAvailable
    | MemorySysctlKey String
    | WindowsTotalMemory
    deriving (Eq, Show)

-- | The concrete source used to read available storage capacity.
data StorageSource
    = WindowsSystemDriveFreeSpace
    | -- | free bytes on the filesystem holding @path@, via @df -k@ (Apple/Linux)
      PosixFreeStorage FilePath
    deriving (Eq, Show)

{- | The substrate-specific host-capacity read plan. Pure so the source mapping
stays unit-tested without executing host tools.
-}
data CapacityReadPlan = CapacityReadPlan
    { cpuCapacitySource :: CpuSource
    , memoryCapacitySource :: MemorySource
    , storageCapacitySource :: StorageSource
    }
    deriving (Eq, Show)

-- | The substrate boundary at which a declared storage budget needs a wall.
data StorageCordonTarget
    = ColimaVmStorage
    | LimaVmStorage
    | IncusVmStorage
    | Wsl2DistroStorage
    | DockerNodeStorage
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
    | DockerUpdateStorageUnavailable
    deriving (Eq, Show)

{- | The honest storage-cordon policy result. A supported result identifies the
provider mechanism that an interpreter must apply. Bare Linux has neither a
quota'd host path nor an image-GC wall, and Docker cannot update a node's storage
ceiling. Both return explicit typed unsupported results instead of treating the
capacity preflight as enforcement.
-}
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
    DockerNodeStorage -> StorageCordonUnsupported DockerUpdateStorageUnavailable
    BareLinuxStorage -> StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable

{- | Parse a Kubernetes-style quantity to bytes. Accepts binary suffixes
(@Ki@, @Mi@, @Gi@, @Ti@, optionally followed by @B@) and decimal suffixes
(@K@, @M@, @G@, @T@); a bare number is bytes. The one canonical quantity
grammar. Pure.
-}
parseQuantity :: T.Text -> Either QuantityError Integer
parseQuantity raw =
    let t = T.strip raw
        (numText, unitText) = T.span (\c -> isDigit c || c == '.') t
        unit = T.unpack (T.strip unitText)
     in if T.null numText
            then Left (QuantityNotANumber raw)
            else case readDecimal (T.unpack numText) of
                Left err -> Left err
                Right (numerator, denominator) -> case multiplier unit of
                    Nothing -> Left (QuantityUnknownUnit unit raw)
                    Just m ->
                        let scaled = numerator * m
                         in if scaled `mod` denominator == 0
                                then Right (scaled `div` denominator)
                                else Left (QuantityNotWholeBytes raw)

readDecimal :: String -> Either QuantityError (Integer, Integer)
readDecimal text =
    case break (== '.') text of
        (whole, "")
            | validDigits whole -> Right (digits whole, 1)
        (whole, '.' : fractional)
            | validDigits whole && validDigits fractional ->
                let denominator = 10 ^ length fractional
                 in Right (digits whole * denominator + digits fractional, denominator)
        _ -> Left (QuantityMalformedNumber text)
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
above the project budget (see @development_plan_standards.md § O@). A 13 GiB
budget fits under a 16 GiB host's total RAM, but its 4 GiB reserve makes the
preflight refuse: 13 + 4 exceeds 16. The reserve is 4 GiB.
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
Memory and storage must already be exactly representable in whole GiB (Colima's
unit); an inexact hard ceiling is rejected rather than rounded upward. CPU is
the whole core count. Colima has two writable disks, so the declared storage
ceiling is split between a fixed 20 GiB root disk and the remaining runtime data
disk. A declaration that cannot leave at least one whole GiB for runtime data is
rejected instead of silently exceeding the declared total.

The fixed false/none flags close Colima defaults that otherwise read templates,
modify host SSH/Kubernetes state, mount the effective home, or enable a global
network helper outside the exact provider namespace.
-}
colimaSizingArgsForBudget :: String -> ResourceBudget -> Either String [String]
colimaSizingArgsForBudget project b = do
    memoryGiB <- exactGibibytes "Colima memory" (budgetMemoryBytes b)
    storageGiB <- exactGibibytes "Colima storage" (budgetStorageBytes b)
    if storageGiB <= colimaRootDiskGiB
        then
            Left
                ( "Colima storage must exceed the fixed "
                    ++ show colimaRootDiskGiB
                    ++ " GiB writable root disk; got "
                    ++ show storageGiB
                    ++ " GiB"
                )
        else
            pure
                [ "start"
                , "--profile"
                , project
                , "--runtime"
                , "docker"
                , "--activate=false"
                , "--template=false"
                , "--ssh-config=false"
                , "--mount"
                , "none"
                , "--kubernetes=false"
                , "--network-address=false"
                , "--mount-inotify=false"
                , "--cpus"
                , show (budgetCpu b)
                , "--memory"
                , show memoryGiB
                , "--root-disk"
                , show colimaRootDiskGiB
                , "--disk"
                , show (storageGiB - colimaRootDiskGiB)
                ]

colimaRootDiskGiB :: Integer
colimaRootDiskGiB = 20

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
slice. Storage carries **no** @docker update@ flag, so this node target is
explicitly unsupported. Provider storage walls are the Colima and Lima disks,
the Incus root disk, and the WSL2 VHDX; bare Linux is also unsupported.
-}
kindNodeCordonArgsForBudget :: String -> ResourceBudget -> Either String [String]
kindNodeCordonArgsForBudget containerName b = do
    limits <- kindNodeCordonLimitsForBudget b
    pure (["update"] <> limits <> [containerName])

{- | The same wall as the limit flags alone, with no container named.

A driver that addresses a node container by the identity its durable record
bound has nowhere to put a name, and a second rendering of the same three flags
would be a copy that agrees with this one until one of them is changed. The
argv-shaped renderer above is therefore this list with the verb in front and the
container behind it, so there is exactly one statement of what a cluster budget
caps.

Docker stores CPU in signed 64-bit NanoCPUs and memory/swap in signed 64-bit
bytes. The Linux daemon requires at least 6 MiB of memory, and the CLI parses
byte counts through binary64, so memory must survive that conversion exactly.
All range checks use unbounded integers before rendering; doubling an exact
memory value preserves its binary64 precision.
-}
kindNodeCordonLimitsForBudget :: ResourceBudget -> Either String [String]
kindNodeCordonLimitsForBudget b
    | toInteger (budgetCpu b) > maxCpuCores =
        Left
            ( "Docker CPU budget "
                ++ show (budgetCpu b)
                ++ " cores exceeds the signed 64-bit NanoCPUs limit of "
                ++ show maxCpuCores
                ++ " whole cores"
            )
    | memoryBytes < minimumMemoryBytes =
        Left
            ( memoryLabel
                ++ " is below the Linux daemon minimum of "
                ++ show minimumMemoryBytes
                ++ " bytes"
            )
    | swapBytes > maxSignedBytes =
        Left
            ( memoryLabel
                ++ " doubles to "
                ++ show swapBytes
                ++ " bytes, exceeding the signed 64-bit --memory-swap limit of "
                ++ show maxSignedBytes
                ++ " bytes"
            )
    | (truncate (fromInteger memoryBytes :: Double) :: Integer) /= memoryBytes =
        Left (memoryLabel ++ " is not exactly representable by the Docker CLI binary64 byte parser")
    | otherwise =
        Right
            [ "--cpus"
            , show (budgetCpu b)
            , "--memory"
            , show memoryBytes
            , "--memory-swap"
            , show swapBytes
            ]
  where
    maxSignedBytes = toInteger (maxBound :: Int64)
    maxCpuCores = maxSignedBytes `div` 1000000000
    minimumMemoryBytes = 6291456
    memoryBytes = budgetMemoryBytes b
    swapBytes = 2 * memoryBytes
    memoryLabel = "Docker memory budget " ++ show memoryBytes ++ " bytes"

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
shares. The finite six-hour policy gives roughly twice the recorded Windows
demo gate's 2 h 57 min duration, leaving headroom for gaps between its sessions
while allowing an abandoned runtime to become idle later.
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

Six hours gives roughly a twofold margin over the recorded Windows demo gate's
2 h 57 min duration, leaving headroom for gaps between its @wsl -d@ sessions.
The finite policy also allows an abandoned runtime to become idle later.
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
capacityReadPlan sub = case substrateFrame sub of
    AppleFrame -> appleReadPlan
    LinuxFrame -> linuxReadPlan
    WindowsFrame -> windowsReadPlan
  where
    appleReadPlan = CapacityReadPlan (CpuSysctlKey "hw.ncpu") (MemorySysctlKey "hw.memsize") posixFreeStorage
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
readCores :: HostConfig -> CpuSource -> IO (Either String Natural)
readCores _ ProcCpuinfo = do
    exists <- doesFileExist "/proc/cpuinfo"
    if not exists
        then pure (Left "host capacity: /proc/cpuinfo is not available")
        else do
            result <- try (TextIO.readFile "/proc/cpuinfo") :: IO (Either SomeException T.Text)
            pure $ case result of
                Right contents -> parseCpuinfoProcessors (T.unpack contents)
                Left e -> Left ("host capacity: failed to read /proc/cpuinfo: " ++ displayException e)
readCores cfg (CpuSysctlKey key) = fmap (fmap fromInteger) (readSysctlPositiveInteger cfg key)
readCores _ WindowsLogicalProcessors =
    fmap (fmap fromInteger . first renderWindowsCapacityError) readWindowsLogicalProcessors

-- | Read available memory from the substrate-selected source, in bytes.
readAvailableMemory :: HostConfig -> MemorySource -> IO (Either String Integer)
readAvailableMemory _ ProcMemAvailable = do
    exists <- doesFileExist "/proc/meminfo"
    if not exists
        then pure (Left "host capacity: /proc/meminfo is not available")
        else do
            result <- try (TextIO.readFile "/proc/meminfo") :: IO (Either SomeException T.Text)
            pure $ case result of
                Right contents -> parseMemAvailableBytes (T.unpack contents)
                Left e -> Left ("host capacity: failed to read /proc/meminfo: " ++ displayException e)
readAvailableMemory cfg (MemorySysctlKey key) = readSysctlPositiveInteger cfg key
-- Windows reads /total/ physical memory (already in bytes), not free: it mirrors
-- Apple's stable @hw.memsize@ so the preflight is a property of the machine, not a
-- volatile point-in-time free-RAM reading. A budget-fitting host then fails fast
-- before the expensive build rather than passing on transient post-reboot free RAM
-- (see @documents/engineering/applied_cordon.md@).
readAvailableMemory _ WindowsTotalMemory =
    fmap (first renderWindowsCapacityError) readWindowsTotalMemory

-- | Read available storage from the substrate-selected source, in bytes.
readAvailableStorage :: HostConfig -> StorageSource -> IO (Either String Integer)
readAvailableStorage _ WindowsSystemDriveFreeSpace =
    fmap (first renderWindowsCapacityError) readWindowsSystemDriveFreeSpace
readAvailableStorage cfg (PosixFreeStorage path) =
    readDfFreeBytes cfg path

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
    Just _ -> do
        outcome <- interpretHostCommand cfg (hostCommand Df ["-P", "-k", path])
        pure $ case outcome of
            Right (CapturedRun ExitSuccess out _) ->
                maybe
                    (Left ("host capacity: could not parse df output for " ++ path))
                    (\kb -> Right (kb * 1024))
                    (parseDfAvailableKBytes out)
            Right (CapturedRun (ExitFailure n) _ err) ->
                Left ("host capacity: df -k " ++ path ++ " failed (exit " ++ show n ++ "): " ++ T.unpack (T.strip (T.pack err)))
            Left failure ->
                Left ("host capacity: failed to run df -k " ++ path ++ ": " ++ failure)

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
    Just _ -> do
        outcome <- interpretHostCommand cfg (hostCommand Sysctl ["-n", key])
        pure $ case outcome of
            Right (CapturedRun ExitSuccess out _) -> Right (T.unpack (T.strip (T.pack out)))
            Right (CapturedRun (ExitFailure n) _ err) ->
                Left
                    ( "host capacity: sysctl "
                        ++ key
                        ++ " failed (exit "
                        ++ show n
                        ++ "): "
                        ++ T.unpack (T.strip (T.pack err))
                    )
            Left failure ->
                Left ("host capacity: failed to run sysctl " ++ key ++ ": " ++ failure)

-- | Count the logical processor entries in Linux cpuinfo text.
parseCpuinfoProcessors :: String -> Either String Natural
parseCpuinfoProcessors contents =
    let count = length (filter ("processor" `isPrefixOf`) (lines contents))
     in if count > 0
            then Right (fromIntegral count)
            else Left "host capacity: no processors found in /proc/cpuinfo"

-- | Read Linux meminfo's available-memory count and convert kB to bytes.
parseMemAvailableBytes :: String -> Either String Integer
parseMemAvailableBytes contents = case findMemAvailable (lines contents) of
    Just kb -> Right (kb * 1024)
    Nothing -> Left "host capacity: MemAvailable not found in /proc/meminfo"

-- | Parse a positive whole-number capacity after stripping surrounding space.
parsePositiveInteger :: String -> String -> Either String Integer
parsePositiveInteger label raw = case reads (T.unpack (T.strip (T.pack raw))) of
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
