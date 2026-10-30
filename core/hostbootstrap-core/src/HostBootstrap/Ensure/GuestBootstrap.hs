{- | The guest bootstrap vocabulary: how the binary comes to exist in a fresh
frame.

This is the one residue § KK names. Every other command the binary issues in a
frame is the binary's own typed operation, lifted (§ LL) — but a frame that has
never run the binary cannot issue one, and § N forbids copying a binary in from
somewhere it already exists. So the steps that /establish/ it there are their own
closed, ordered, typed vocabulary, owned by this module alone.

Being a vocabulary rather than a script is what makes it checkable. Each step
has a probe and actions rendered as argument vectors ('LiftLeaf'), so the plan
is unit-tested without a guest existing. The floor probe reads installed-package
states; the bootstrapper always reinstalls from the staged source before its
verification probe. The two shapes
that look like they need an interpreter do not: a piped installer is a fetch step
followed by a run step, and a working directory is an argument to @env@. Nothing
here is a shell string, and free-form text is as forbidden in this module as it
is anywhere else.

The order is the vocabulary's, not a caller's. 'guestBootstrapPlan' enumerates
'GuestStepKind' through the exhaustive private step constructor, so a new kind
must be implemented and becomes a step every caller runs. A caller selects the
target, never the sequence.

Every path in a step retains an admitted 'GuestPath' (§ MM): it is interpreted
by a process of the frame being bootstrapped, which is Linux on every outer
host. 'mkGuestPath' admits POSIX-absolute paths and refuses anything else —
including the drive-qualified path a Windows outer host would otherwise hand
it. 'mkGuestBootstrapTarget' receives six distinct coordinate roles over those
proofs. Ordinary readers inspect the admitted target without a record-update
route, and its plan alone constructs steps.
The toolchain home must end in @.ghcup@ without a trailing separator, matching
the directory the installer creates under its configured base prefix.
-}
module HostBootstrap.Ensure.GuestBootstrap (
    -- * What a frame needs before the binary exists in it
    GuestPackage (..),
    allGuestPackages,
    guestPackageName,
    PinnedToolchain (..),

    -- * Admitted guest paths
    GuestPath,
    mkGuestPath,
    guestPathValue,
    GuestSourceRoot,
    mkGuestSourceRoot,
    guestSourceRootPath,
    GuestProjectDir,
    mkGuestProjectDir,
    guestProjectDirPath,
    GuestToolchainHome,
    mkGuestToolchainHome,
    guestToolchainHomePath,
    GuestBootstrapperExe,
    mkGuestBootstrapperExe,
    guestBootstrapperExePath,
    GuestBuiltBinary,
    mkGuestBuiltBinary,
    guestBuiltBinaryPath,
    GuestInstalledBinary,
    mkGuestInstalledBinary,
    guestInstalledBinaryPath,

    -- * The target a bootstrap establishes
    GuestBootstrapTarget,
    mkGuestBootstrapTarget,
    guestSourceRoot,
    guestProjectDir,
    guestToolchainHome,
    guestBootstrapperExe,
    guestBuiltBinary,
    guestInstalledBinary,
    guestToolchain,

    -- * The closed, ordered vocabulary
    GuestBootstrapStep,
    GuestStepKind (..),
    guestBootstrapPlan,
    stepKind,
    stepLabel,
    stepProbe,
    floorPackagesSatisfied,
    stepActions,

    -- * The probe-first driver
    GuestStepOutcome (..),
    runGuestBootstrap,
    runGuestBootstrapWith,
) where

import Data.List (intercalate, isPrefixOf)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lift (LiftContext, LiftLeaf (RawCmd), liftLeaf)
import System.Exit (ExitCode (ExitSuccess))
import qualified System.FilePath.Posix as Posix

{- | The distribution packages a fresh Linux frame needs before a Haskell
toolchain can be fetched or a project binary built.

A closed enumeration rather than a string list, because the set is a fact about
the bootstrap rather than a caller's choice: a frame missing one of these fails
during the build with a linker error that names a library, not a package.
-}
data GuestPackage
    = Pipx
    | Python3Venv
    | BuildEssential
    | Curl
    | Git
    | PkgConfig
    | CaCertificates
    | LibGmpDev
    | LibTinfoDev
    | LibNcursesDev
    | Zlib1gDev
    deriving (Eq, Ord, Show, Enum, Bounded)

-- | Every package the guest floor requires, in a stable order.
allGuestPackages :: [GuestPackage]
allGuestPackages = [minBound .. maxBound]

-- | The package's name to the distribution's package manager.
guestPackageName :: GuestPackage -> String
guestPackageName Pipx = "pipx"
guestPackageName Python3Venv = "python3-venv"
guestPackageName BuildEssential = "build-essential"
guestPackageName Curl = "curl"
guestPackageName Git = "git"
guestPackageName PkgConfig = "pkg-config"
guestPackageName CaCertificates = "ca-certificates"
guestPackageName LibGmpDev = "libgmp-dev"
guestPackageName LibTinfoDev = "libtinfo-dev"
guestPackageName LibNcursesDev = "libncurses-dev"
guestPackageName Zlib1gDev = "zlib1g-dev"

{- | The GHC the frame's toolchain is pinned to.

Pinned rather than latest, because the frame builds the same sources the outer
host does and a toolchain that drifts between frames makes one frame's build
evidence say nothing about another's.
-}
newtype PinnedToolchain = PinnedToolchain {toolchainGhcVersion :: String}
    deriving (Eq, Show)

-- | One POSIX-absolute guest path, retaining its original spelling.
newtype GuestPath = GuestPath FilePath
    deriving (Eq)

instance Show GuestPath where
    showsPrec precedence (GuestPath path) = showsPrec precedence path

-- | Admit the guest's path grammar, independently of the outer host.
mkGuestPath :: FilePath -> Either String GuestPath
mkGuestPath path
    | Posix.isAbsolute path = Right (GuestPath path)
    | otherwise = Left ("guest bootstrap: not a POSIX-absolute guest path (§ MM): " ++ path)

-- | The original guest spelling, ready for its argument-vector position.
guestPathValue :: GuestPath -> FilePath
guestPathValue (GuestPath path) = path

-- | The staged repository root, distinguished from other admitted guest paths.
newtype GuestSourceRoot = GuestSourceRoot GuestPath
    deriving (Eq)

instance Show GuestSourceRoot where
    showsPrec precedence (GuestSourceRoot path) = showsPrec precedence path

-- | Label an admitted path as the staged repository root.
mkGuestSourceRoot :: GuestPath -> GuestSourceRoot
mkGuestSourceRoot = GuestSourceRoot

-- | The admitted path retained by the staged repository root.
guestSourceRootPath :: GuestSourceRoot -> GuestPath
guestSourceRootPath (GuestSourceRoot path) = path

-- | The project working directory, distinguished from the other guest paths.
newtype GuestProjectDir = GuestProjectDir GuestPath
    deriving (Eq)

instance Show GuestProjectDir where
    showsPrec precedence (GuestProjectDir path) = showsPrec precedence path

-- | Label an admitted path as the project's working directory.
mkGuestProjectDir :: GuestPath -> GuestProjectDir
mkGuestProjectDir = GuestProjectDir

-- | The admitted path retained by the project's working directory.
guestProjectDirPath :: GuestProjectDir -> GuestPath
guestProjectDirPath (GuestProjectDir path) = path

-- | The pinned toolchain's home, distinguished from the other guest paths.
newtype GuestToolchainHome = GuestToolchainHome GuestPath
    deriving (Eq)

instance Show GuestToolchainHome where
    showsPrec precedence (GuestToolchainHome path) = showsPrec precedence path

-- | Label an admitted path; the target checks the required @.ghcup@ basename.
mkGuestToolchainHome :: GuestPath -> GuestToolchainHome
mkGuestToolchainHome = GuestToolchainHome

-- | The original admitted path retained by the toolchain home.
guestToolchainHomePath :: GuestToolchainHome -> GuestPath
guestToolchainHomePath (GuestToolchainHome path) = path

-- | The installed Python bootstrapper, distinguished from other guest paths.
newtype GuestBootstrapperExe = GuestBootstrapperExe GuestPath
    deriving (Eq)

instance Show GuestBootstrapperExe where
    showsPrec precedence (GuestBootstrapperExe path) = showsPrec precedence path

-- | Label an admitted path as the installed Python bootstrapper.
mkGuestBootstrapperExe :: GuestPath -> GuestBootstrapperExe
mkGuestBootstrapperExe = GuestBootstrapperExe

-- | The admitted path retained by the Python bootstrapper executable.
guestBootstrapperExePath :: GuestBootstrapperExe -> GuestPath
guestBootstrapperExePath (GuestBootstrapperExe path) = path

-- | The planned native build output, distinguished from other guest paths.
newtype GuestBuiltBinary = GuestBuiltBinary GuestPath
    deriving (Eq)

instance Show GuestBuiltBinary where
    showsPrec precedence (GuestBuiltBinary path) = showsPrec precedence path

-- | Label an admitted path as the native build output.
mkGuestBuiltBinary :: GuestPath -> GuestBuiltBinary
mkGuestBuiltBinary = GuestBuiltBinary

-- | The admitted path retained by the native build output.
guestBuiltBinaryPath :: GuestBuiltBinary -> GuestPath
guestBuiltBinaryPath (GuestBuiltBinary path) = path

-- | The planned installation destination, distinguished from other guest paths.
newtype GuestInstalledBinary = GuestInstalledBinary GuestPath
    deriving (Eq)

instance Show GuestInstalledBinary where
    showsPrec precedence (GuestInstalledBinary path) = showsPrec precedence path

-- | Label an admitted path as the binary's installation destination.
mkGuestInstalledBinary :: GuestPath -> GuestInstalledBinary
mkGuestInstalledBinary = GuestInstalledBinary

-- | The admitted path retained by the binary's installation destination.
guestInstalledBinaryPath :: GuestInstalledBinary -> GuestPath
guestInstalledBinaryPath (GuestInstalledBinary path) = path

{- | Where, inside the frame, the bootstrap finds its inputs and leaves its
outputs.

The constructor and record labels are private. Every coordinate retains a
guest-path proof, and 'mkGuestBootstrapTarget' is the only way to build a target.
Ordinary readers inspect it without allowing a coordinate to be replaced.
-}
data GuestBootstrapTarget = GuestBootstrapTarget
    { targetSourceRoot :: GuestSourceRoot
    , targetProjectDir :: GuestProjectDir
    , targetToolchainHome :: GuestToolchainHome
    , targetBootstrapperExe :: GuestBootstrapperExe
    , targetBuiltBinary :: GuestBuiltBinary
    , targetInstalledBinary :: GuestInstalledBinary
    , targetToolchain :: PinnedToolchain
    }
    deriving (Eq)

instance Show GuestBootstrapTarget where
    showsPrec precedence (GuestBootstrapTarget source project home bootstrapper built installed toolchain) =
        showParen (precedence > 10) $
            showString "GuestBootstrapTarget {guestSourceRoot = "
                . shows source
                . showString ", guestProjectDir = "
                . shows project
                . showString ", guestToolchainHome = "
                . shows home
                . showString ", guestBootstrapperExe = "
                . shows bootstrapper
                . showString ", guestBuiltBinary = "
                . shows built
                . showString ", guestInstalledBinary = "
                . shows installed
                . showString ", guestToolchain = "
                . shows toolchain
                . showChar '}'

-- | The staged repository root, as the guest sees it.
guestSourceRoot :: GuestBootstrapTarget -> GuestSourceRoot
guestSourceRoot = targetSourceRoot

-- | The project directory the binary is built from.
guestProjectDir :: GuestBootstrapTarget -> GuestProjectDir
guestProjectDir = targetProjectDir

-- | Where the pinned toolchain installs itself.
guestToolchainHome :: GuestBootstrapTarget -> GuestToolchainHome
guestToolchainHome = targetToolchainHome

-- | The Python bootstrapper, once @pipx@ has installed it.
guestBootstrapperExe :: GuestBootstrapTarget -> GuestBootstrapperExe
guestBootstrapperExe = targetBootstrapperExe

-- | The host-native binary the build produces in the frame.
guestBuiltBinary :: GuestBootstrapTarget -> GuestBuiltBinary
guestBuiltBinary = targetBuiltBinary

-- | Where that binary is installed for the next frame to invoke.
guestInstalledBinary :: GuestBootstrapTarget -> GuestInstalledBinary
guestInstalledBinary = targetInstalledBinary

-- | The pinned toolchain the build runs against.
guestToolchain :: GuestBootstrapTarget -> PinnedToolchain
guestToolchain = targetToolchain

{- | Build a target from six admitted coordinate roles. 'mkGuestPath' establishes
the guest path grammar before each role is supplied (§ MM). This admission
checks the nonempty pinned GHC version, then the original toolchain-home spelling
against the required @.ghcup@ basename.
-}
mkGuestBootstrapTarget ::
    -- | staged repository root
    GuestSourceRoot ->
    -- | project directory
    GuestProjectDir ->
    -- | toolchain home
    GuestToolchainHome ->
    -- | the @pipx@-installed bootstrapper
    GuestBootstrapperExe ->
    -- | the built binary
    GuestBuiltBinary ->
    -- | the installed binary
    GuestInstalledBinary ->
    PinnedToolchain ->
    Either String GuestBootstrapTarget
mkGuestBootstrapTarget sourceRoot projectDir toolchainHome bootstrapper built installed toolchain
    | null (toolchainGhcVersion toolchain) =
        Left "guest bootstrap: the pinned toolchain names no GHC version"
    | Posix.takeFileName (Posix.normalise toolchainHomeValue) /= ".ghcup" =
        Left
            ( "guest bootstrap: the toolchain home must end in .ghcup without a trailing separator: "
                ++ toolchainHomeValue
            )
    | otherwise =
        Right (GuestBootstrapTarget sourceRoot projectDir toolchainHome bootstrapper built installed toolchain)
  where
    toolchainHomeValue = guestPathValue (guestToolchainHomePath toolchainHome)

{- | One step of the bootstrap.

Five, and the reason each is separate is that each is separately /probeable/: a
frame that already carries the packages but not the toolchain must skip the first
and run the second, which a single step cannot express. Constructors are private;
the admitted target supplies every path proof through 'guestBootstrapPlan'.
-}
data GuestBootstrapStep
    = -- | refresh the package index, then install the guest floor
      InstallGuestPackages [GuestPackage]
    | -- | fetch and run the pinned toolchain installer under this home
      InstallPinnedToolchain PinnedToolchain GuestToolchainHome
    | -- | @pipx install@ the Python bootstrapper from the staged source
      InstallGuestBootstrapper GuestSourceRoot GuestBootstrapperExe
    | -- | build the project binary host-native in the frame (§ N)
      BuildGuestProjectBinary GuestProjectDir GuestToolchainHome GuestBootstrapperExe GuestBuiltBinary
    | -- | install that binary where the next frame's lift invokes it
      InstallGuestProjectBinary GuestBuiltBinary GuestInstalledBinary
    deriving (Eq, Show)

-- | The closed bootstrap order, independent of one target's step payloads.
data GuestStepKind
    = FloorStep
    | ToolchainStep
    | BootstrapperStep
    | BuildStep
    | InstallBinaryStep
    deriving (Eq, Show, Enum, Bounded)

{- | The bootstrap, in order, for one target.

Every 'GuestStepKind' is enumerated, and the private constructor function handles
each kind explicitly. A new kind therefore requires an implementation under
@-Werror@ and cannot be omitted from this plan. Callers select only the target.
-}
guestBootstrapPlan :: GuestBootstrapTarget -> [GuestBootstrapStep]
guestBootstrapPlan target =
    map (stepFor target) [minBound .. maxBound]

stepFor :: GuestBootstrapTarget -> GuestStepKind -> GuestBootstrapStep
stepFor target kind = case kind of
    FloorStep -> InstallGuestPackages allGuestPackages
    ToolchainStep -> InstallPinnedToolchain (guestToolchain target) (guestToolchainHome target)
    BootstrapperStep -> InstallGuestBootstrapper (guestSourceRoot target) (guestBootstrapperExe target)
    BuildStep ->
        BuildGuestProjectBinary
            (guestProjectDir target)
            (guestToolchainHome target)
            (guestBootstrapperExe target)
            (guestBuiltBinary target)
    InstallBinaryStep -> InstallGuestProjectBinary (guestBuiltBinary target) (guestInstalledBinary target)

-- | The kind of a rendered step, without inspecting its target payload.
stepKind :: GuestBootstrapStep -> GuestStepKind
stepKind InstallGuestPackages{} = FloorStep
stepKind InstallPinnedToolchain{} = ToolchainStep
stepKind InstallGuestBootstrapper{} = BootstrapperStep
stepKind BuildGuestProjectBinary{} = BuildStep
stepKind InstallGuestProjectBinary{} = InstallBinaryStep

-- | The one-line label a step reports itself under.
stepLabel :: GuestBootstrapStep -> String
stepLabel (InstallGuestPackages packages) =
    "install the guest floor (" ++ show (length packages) ++ " package(s))"
stepLabel (InstallPinnedToolchain toolchain _) =
    "install the pinned toolchain (GHC " ++ toolchainGhcVersion toolchain ++ ")"
stepLabel (InstallGuestBootstrapper source _) =
    "install the Python bootstrapper from " ++ guestPathValue (guestSourceRootPath source)
stepLabel (BuildGuestProjectBinary projectDir _ _ _) =
    "build the project binary host-native in " ++ guestPathValue (guestProjectDirPath projectDir)
stepLabel (InstallGuestProjectBinary _ installed) =
    "install the project binary at " ++ guestPathValue (guestInstalledBinaryPath installed)

{- | The observation that verifies a step.

The floor reads installed-package status lines; other steps use exit status.
The bootstrapper uses this probe only after its unconditional installation.
-}
stepProbe :: GuestBootstrapStep -> LiftLeaf
stepProbe (InstallGuestPackages packages) =
    RawCmd "dpkg-query" (["-W", "-f", "${db:Status-Abbrev}\\n"] ++ map guestPackageName packages)
stepProbe (InstallPinnedToolchain toolchain home) =
    RawCmd "test" ["-x", toolchainHome Posix.</> "bin" Posix.</> "ghcup", "-a", "-x", toolchainHome Posix.</> "ghc" Posix.</> toolchainGhcVersion toolchain Posix.</> "bin" Posix.</> "ghc", "-a", "-x", toolchainHome Posix.</> "bin" Posix.</> "cabal"]
  where
    toolchainHome = guestPathValue (guestToolchainHomePath home)
stepProbe (InstallGuestBootstrapper _ bootstrapper) =
    RawCmd "test" ["-x", guestPathValue (guestBootstrapperExePath bootstrapper)]
stepProbe (BuildGuestProjectBinary _ _ _ built) =
    RawCmd "test" ["-x", guestPathValue (guestBuiltBinaryPath built)]
stepProbe (InstallGuestProjectBinary built installed) =
    RawCmd "cmp" ["-s", guestPathValue (guestBuiltBinaryPath built), guestPathValue (guestInstalledBinaryPath installed)]

-- | Require one installed-state line for every member of a nonempty floor.
floorPackagesSatisfied :: [GuestPackage] -> (ExitCode, String, String) -> Bool
floorPackagesSatisfied packages (code, output, _) =
    code == ExitSuccess
        && not (null packages)
        && length statuses == length packages
        && all ("ii" `isPrefixOf`) statuses
  where
    statuses = lines output

{- | The actions that satisfy a step, in order.

A step is a list rather than a single command wherever the work is genuinely two
commands the frame must run in sequence — refreshing a package index before
installing from it, fetching an installer before running it. That is what keeps
this vocabulary free of the two shapes that otherwise reach for an interpreter: a
pipe becomes two steps, and a working directory becomes an argument.
-}
stepActions :: GuestBootstrapStep -> [LiftLeaf]
stepActions (InstallGuestPackages packages) =
    [ RawCmd "sudo" (aptGet ["update", "-q"])
    , RawCmd "sudo" (aptGet (["install", "-y", "-q"] ++ map guestPackageName packages))
    ]
  where
    aptGet arguments =
        ["-n", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get"] ++ arguments
stepActions (InstallPinnedToolchain toolchain home) =
    [ RawCmd "curl" ["--proto", "=https", "--tlsv1.2", "-sSf", "-o", installer, ghcupInstallerUrl]
    , RawCmd "env" ["BOOTSTRAP_HASKELL_NONINTERACTIVE=1", "BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1", "BOOTSTRAP_HASKELL_GHC_VERSION=" ++ toolchainGhcVersion toolchain, "GHCUP_INSTALL_BASE_PREFIX=" ++ Posix.takeDirectory toolchainHome, "sh", installer]
    ]
  where
    toolchainHome = guestPathValue (guestToolchainHomePath home)
    installer = Posix.takeDirectory toolchainHome Posix.</> ".ghcup-install.sh"
stepActions (InstallGuestBootstrapper source _) =
    [RawCmd "pipx" ["install", "--force", guestPathValue (guestSourceRootPath source)]]
stepActions (BuildGuestProjectBinary projectDir toolchainHome bootstrapper _) =
    [ RawCmd "env" ["-C", guestPathValue (guestProjectDirPath projectDir), "PATH=" ++ intercalate ":" (buildPath toolchainHome bootstrapper), guestPathValue (guestBootstrapperExePath bootstrapper), "build"]
    ]
stepActions (InstallGuestProjectBinary built installed) =
    [RawCmd "sudo" ["-n", "install", "-m", "0755", guestPathValue (guestBuiltBinaryPath built), guestPathValue (guestInstalledBinaryPath installed)]]

{- | The @PATH@ the in-frame build runs with.

Explicit rather than inherited, because the toolchain the previous step installed
is not on the login shell's @PATH@ until a profile the bootstrap never sources
has run, and a build that silently finds a /different/ GHC is exactly the drift
the pin exists to prevent.
-}
buildPath :: GuestToolchainHome -> GuestBootstrapperExe -> [FilePath]
buildPath toolchainHome bootstrapper =
    [ guestPathValue (guestToolchainHomePath toolchainHome) Posix.</> "bin"
    , Posix.takeDirectory (guestPathValue (guestBootstrapperExePath bootstrapper))
    , "/usr/local/sbin"
    , "/usr/local/bin"
    , "/usr/sbin"
    , "/usr/bin"
    , "/sbin"
    , "/bin"
    ]

{- | The pinned toolchain installer's source.

One constant, in the module that owns the toolchain step, rather than a caller's
argument: a frame fetching its toolchain from a location a caller chose is a
supply chain the plan cannot describe.
-}
ghcupInstallerUrl :: String
ghcupInstallerUrl = "https://get-ghcup.haskell.org"

-- | What running one step did.
data GuestStepOutcome
    = -- | the probe already passed; the step ran nothing
      GuestStepSatisfied GuestBootstrapStep
    | -- | the actions ran and the re-probe passed
      GuestStepInstalled GuestBootstrapStep
    deriving (Eq, Show)

{- | Run the bootstrap in a frame: fold every leaf through the one lift
('HostBootstrap.Lift.foldLeaf') into the context the caller supplies.
-}
runGuestBootstrap ::
    HostConfig ->
    LiftContext ->
    GuestBootstrapTarget ->
    IO (Either String [GuestStepOutcome])
runGuestBootstrap cfg ctx = runGuestBootstrapWith (liftLeaf cfg ctx)

{- | Injectable form of 'runGuestBootstrap'.

Ordinary steps probe first, act only on absence, and re-probe after acting. The
bootstrapper always reinstalls from the staged source, then verifies. Stop at
the first step that will not settle.
-}
runGuestBootstrapWith ::
    -- | run one leaf in the frame being bootstrapped
    (LiftLeaf -> IO (Either String (ExitCode, String, String))) ->
    GuestBootstrapTarget ->
    IO (Either String [GuestStepOutcome])
runGuestBootstrapWith runLeaf target = go [] (guestBootstrapPlan target)
  where
    go done [] = pure (Right (reverse done))
    go done (step : rest)
        | stepKind step == BootstrapperStep = installStep done step rest
        | otherwise = do
            satisfied <- succeeds step
            case satisfied of
                Left err -> pure (Left (failure step err))
                Right True -> go (GuestStepSatisfied step : done) rest
                Right False -> installStep done step rest

    installStep done step rest = do
        acted <- runActions (stepActions step)
        case acted of
            Left err -> pure (Left (failure step err))
            Right () -> do
                settled <- succeeds step
                case settled of
                    Left err -> pure (Left (failure step err))
                    Right False ->
                        pure (Left (failure step "still not satisfied after its actions ran"))
                    Right True -> go (GuestStepInstalled step : done) rest

    runActions [] = pure (Right ())
    runActions (leaf : leaves) = do
        outcome <- runLeaf leaf
        case outcome of
            Left err -> pure (Left err)
            Right (ExitSuccess, _, _) -> runActions leaves
            Right (code, _, errOut) ->
                pure (Left (renderLeaf leaf ++ " exited " ++ show code ++ " " ++ errOut))

    succeeds step = do
        outcome <- runLeaf (stepProbe step)
        pure (fmap (probeSatisfied step) outcome)

    probeSatisfied (InstallGuestPackages packages) result = floorPackagesSatisfied packages result
    probeSatisfied _ (code, _, _) = code == ExitSuccess

    failure step reason = "guest bootstrap: " ++ stepLabel step ++ ": " ++ reason

    renderLeaf (RawCmd exe argv) = unwords (exe : argv)
    renderLeaf leaf = show leaf
