{- | The guest bootstrap vocabulary: how the binary comes to exist in a fresh
frame.

This is the one residue § KK names. Every other command the binary issues in a
frame is the binary's own typed operation, lifted (§ LL) — but a frame that has
never run the binary cannot issue one, and § N forbids copying a binary in from
somewhere it already exists. So the steps that /establish/ it there are their own
closed, ordered, typed vocabulary, owned by this module alone.

Being a vocabulary rather than a script is what makes it checkable. Each step is
a value with two renderings — the probe that decides whether it is already
satisfied, and the action that satisfies it — and both are argument vectors
('LiftLeaf'), so the plan is unit-tested without a guest existing. The two shapes
that look like they need an interpreter do not: a piped installer is a fetch step
followed by a run step, and a working directory is an argument to @env@. Nothing
here is a shell string, and free-form text is as forbidden in this module as it
is anywhere else.

The order is the vocabulary's, not a caller's. 'guestBootstrapPlan' is total over
the step constructors, so a step added here is a step every caller runs; a caller
selects the target, never the sequence.

Every path in a step is a __guest__ path (§ MM): it is interpreted by a process
of the frame being bootstrapped, which is Linux on every outer host, so
'mkGuestBootstrapTarget' admits POSIX-absolute paths and refuses anything else —
including the drive-qualified path a Windows outer host would otherwise hand it.
-}
module HostBootstrap.Ensure.GuestBootstrap (
    -- * What a frame needs before the binary exists in it
    GuestPackage (..),
    allGuestPackages,
    guestPackageName,
    PinnedToolchain (..),

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
    GuestBootstrapStep (..),
    guestBootstrapPlan,
    stepLabel,
    stepProbe,
    stepActions,

    -- * The probe-first driver
    GuestStepOutcome (..),
    runGuestBootstrap,
    runGuestBootstrapWith,
) where

import Data.List (intercalate)
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

{- | Where, inside the frame, the bootstrap finds its inputs and leaves its
outputs.

The constructor is not exported: every field is a guest path, and
'mkGuestBootstrapTarget' is the only way to build one, so a host path cannot
reach a guest process by being assigned to a field.
-}
data GuestBootstrapTarget = GuestBootstrapTarget
    { guestSourceRoot :: FilePath
    -- ^ the staged repository root, as the guest sees it
    , guestProjectDir :: FilePath
    -- ^ the project directory the binary is built from
    , guestToolchainHome :: FilePath
    -- ^ where the pinned toolchain installs itself
    , guestBootstrapperExe :: FilePath
    -- ^ the Python bootstrapper, once @pipx@ has installed it
    , guestBuiltBinary :: FilePath
    -- ^ the host-native binary the build produces in the frame
    , guestInstalledBinary :: FilePath
    -- ^ where that binary is installed for the next frame to invoke
    , guestToolchain :: PinnedToolchain
    -- ^ the pinned toolchain the build runs against
    }
    deriving (Eq, Show)

{- | Build a target, refusing any path a guest process would not interpret as an
absolute path of its own (§ MM).

The refusal is the point rather than a formality: on a Windows outer host every
path the caller already holds is drive-qualified, and a drive-qualified string
reaching a Linux guest is a relative path there — it is created, silently, in
whatever directory the guest happened to start in.
-}
mkGuestBootstrapTarget ::
    -- | staged repository root
    FilePath ->
    -- | project directory
    FilePath ->
    -- | toolchain home
    FilePath ->
    -- | the @pipx@-installed bootstrapper
    FilePath ->
    -- | the built binary
    FilePath ->
    -- | the installed binary
    FilePath ->
    PinnedToolchain ->
    Either String GuestBootstrapTarget
mkGuestBootstrapTarget sourceRoot projectDir toolchainHome bootstrapper built installed toolchain
    | not (null offenders) =
        Left
            ( "guest bootstrap: not a POSIX-absolute guest path (§ MM): "
                ++ intercalate ", " offenders
            )
    | null (toolchainGhcVersion toolchain) =
        Left "guest bootstrap: the pinned toolchain names no GHC version"
    | otherwise =
        Right
            GuestBootstrapTarget
                { guestSourceRoot = sourceRoot
                , guestProjectDir = projectDir
                , guestToolchainHome = toolchainHome
                , guestBootstrapperExe = bootstrapper
                , guestBuiltBinary = built
                , guestInstalledBinary = installed
                , guestToolchain = toolchain
                }
  where
    offenders =
        [ path
        | path <- [sourceRoot, projectDir, toolchainHome, bootstrapper, built, installed]
        , not (Posix.isAbsolute path)
        ]

{- | One step of the bootstrap.

Five, and the reason each is separate is that each is separately /probeable/: a
frame that already carries the packages but not the toolchain must skip the first
and run the second, which a single step cannot express.
-}
data GuestBootstrapStep
    = -- | refresh the package index, then install the guest floor
      InstallGuestPackages [GuestPackage]
    | -- | fetch and run the pinned toolchain installer under this home
      InstallPinnedToolchain PinnedToolchain FilePath
    | -- | @pipx install@ the Python bootstrapper from the staged source
      InstallGuestBootstrapper FilePath FilePath
    | -- | build the project binary host-native in the frame (§ N)
      BuildGuestProjectBinary FilePath FilePath FilePath FilePath
    | -- | install that binary where the next frame's lift invokes it
      InstallGuestProjectBinary FilePath FilePath
    deriving (Eq, Show)

{- | The bootstrap, in order, for one target.

Total over the step constructors: adding a step to the vocabulary without adding
it here is a non-exhaustive-patterns warning at the one site that must know, and
callers cannot reorder what they do not choose.
-}
guestBootstrapPlan :: GuestBootstrapTarget -> [GuestBootstrapStep]
guestBootstrapPlan target =
    [ InstallGuestPackages allGuestPackages
    , InstallPinnedToolchain (guestToolchain target) (guestToolchainHome target)
    , InstallGuestBootstrapper (guestSourceRoot target) (guestBootstrapperExe target)
    , BuildGuestProjectBinary
        (guestProjectDir target)
        (guestToolchainHome target)
        (guestBootstrapperExe target)
        (guestBuiltBinary target)
    , InstallGuestProjectBinary (guestBuiltBinary target) (guestInstalledBinary target)
    ]

-- | The one-line label a step reports itself under.
stepLabel :: GuestBootstrapStep -> String
stepLabel (InstallGuestPackages packages) =
    "install the guest floor (" ++ show (length packages) ++ " package(s))"
stepLabel (InstallPinnedToolchain toolchain _) =
    "install the pinned toolchain (GHC " ++ toolchainGhcVersion toolchain ++ ")"
stepLabel (InstallGuestBootstrapper source _) =
    "install the Python bootstrapper from " ++ source
stepLabel (BuildGuestProjectBinary projectDir _ _ _) =
    "build the project binary host-native in " ++ projectDir
stepLabel (InstallGuestProjectBinary _ installed) =
    "install the project binary at " ++ installed

{- | The probe that decides whether a step is already satisfied.

Every probe is a plain argument vector whose exit status /is/ the answer, so the
decision needs no output parsing and no protocol between the guest and the
caller.
-}
stepProbe :: GuestBootstrapStep -> LiftLeaf
stepProbe (InstallGuestPackages packages) =
    RawCmd ("dpkg-query" : "-W" : map guestPackageName packages)
stepProbe (InstallPinnedToolchain _ toolchainHome) =
    RawCmd ["test", "-x", toolchainHome Posix.</> "bin" Posix.</> "ghcup"]
stepProbe (InstallGuestBootstrapper _ bootstrapper) =
    RawCmd ["test", "-x", bootstrapper]
stepProbe (BuildGuestProjectBinary _ _ _ built) =
    RawCmd ["test", "-x", built]
stepProbe (InstallGuestProjectBinary _ installed) =
    RawCmd ["test", "-x", installed]

{- | The actions that satisfy a step, in order.

A step is a list rather than a single command wherever the work is genuinely two
commands the frame must run in sequence — refreshing a package index before
installing from it, fetching an installer before running it. That is what keeps
this vocabulary free of the two shapes that otherwise reach for an interpreter: a
pipe becomes two steps, and a working directory becomes an argument.
-}
stepActions :: GuestBootstrapStep -> [LiftLeaf]
stepActions (InstallGuestPackages packages) =
    [ RawCmd (aptGet ["update", "-q"])
    , RawCmd (aptGet (["install", "-y", "-q"] ++ map guestPackageName packages))
    ]
  where
    aptGet arguments =
        ["sudo", "-n", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get"] ++ arguments
stepActions (InstallPinnedToolchain toolchain toolchainHome) =
    [ RawCmd
        [ "curl"
        , "--proto"
        , "=https"
        , "--tlsv1.2"
        , "-sSf"
        , "-o"
        , installer
        , ghcupInstallerUrl
        ]
    , RawCmd
        [ "env"
        , "BOOTSTRAP_HASKELL_NONINTERACTIVE=1"
        , "BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1"
        , "BOOTSTRAP_HASKELL_GHC_VERSION=" ++ toolchainGhcVersion toolchain
        , "GHCUP_INSTALL_BASE_PREFIX=" ++ Posix.takeDirectory toolchainHome
        , "sh"
        , installer
        ]
    ]
  where
    installer = Posix.takeDirectory toolchainHome Posix.</> ".ghcup-install.sh"
stepActions (InstallGuestBootstrapper source _) =
    [RawCmd ["pipx", "install", "--force", source]]
stepActions (BuildGuestProjectBinary projectDir toolchainHome bootstrapper _) =
    [ RawCmd
        [ "env"
        , "-C"
        , projectDir
        , "PATH=" ++ intercalate ":" (buildPath toolchainHome bootstrapper)
        , bootstrapper
        , "build"
        ]
    ]
stepActions (InstallGuestProjectBinary built installed) =
    [RawCmd ["sudo", "-n", "install", "-m", "0755", built, installed]]

{- | The @PATH@ the in-frame build runs with.

Explicit rather than inherited, because the toolchain the previous step installed
is not on the login shell's @PATH@ until a profile the bootstrap never sources
has run, and a build that silently finds a /different/ GHC is exactly the drift
the pin exists to prevent.
-}
buildPath :: FilePath -> FilePath -> [FilePath]
buildPath toolchainHome bootstrapper =
    [ toolchainHome Posix.</> "bin"
    , Posix.takeDirectory bootstrapper
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

Probe first, act only on a failed probe, re-probe after acting, and stop at the
first step that will not settle — the same control flow
'HostBootstrap.Ensure.installAndVerify' holds for a host reconciler (§ L), over a
frame instead of a host.
-}
runGuestBootstrapWith ::
    -- | run one leaf in the frame being bootstrapped
    (LiftLeaf -> IO (Either String (ExitCode, String, String))) ->
    GuestBootstrapTarget ->
    IO (Either String [GuestStepOutcome])
runGuestBootstrapWith runLeaf target = go [] (guestBootstrapPlan target)
  where
    go done [] = pure (Right (reverse done))
    go done (step : rest) = do
        satisfied <- succeeds (stepProbe step)
        case satisfied of
            Left err -> pure (Left (failure step err))
            Right True -> go (GuestStepSatisfied step : done) rest
            Right False -> do
                acted <- runActions (stepActions step)
                case acted of
                    Left err -> pure (Left (failure step err))
                    Right () -> do
                        settled <- succeeds (stepProbe step)
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

    succeeds leaf = do
        outcome <- runLeaf leaf
        pure (fmap (\(code, _, _) -> code == ExitSuccess) outcome)

    failure step reason = "guest bootstrap: " ++ stepLabel step ++ ": " ++ reason

    renderLeaf (RawCmd argv) = unwords argv
    renderLeaf leaf = show leaf
