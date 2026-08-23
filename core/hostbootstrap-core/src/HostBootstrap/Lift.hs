{- | The self-reference compositional lift: run a subcommand of /this same
binary/ in a nested execution context by invoking the binary again there.

This is the one foundational composition primitive (see
@development_plan_standards.md § U@). A deployment is ordinary @IO@ sequencing
of @ensure@/deploy steps; crossing a context boundary is the binary
re-invoking its own subcommand in the nested context — @limactl shell \<vm\> --
\<pb\> \<subcmd\>@ or @incus exec \<vm\> -- \<pb\> \<subcmd\>@ for a VM,
@docker run --rm \<image\> \<subcmd\>@ for a
container (whose @ENTRYPOINT@ /is/ the binary). A nested call runs the same
@optparse-applicative@ command tree, so each step runs "locally" in whatever
context it was placed in, unaware it was lifted.

Contexts compose as a stack of layers ('LiftContext'), outermost-first.
'foldLift' is pure (the argv fold is unit-tested); 'liftSubcommand' is the thin
@IO@ seam. Raw tool/probe leaves use the same 'foldLeaf' route, so there is no
parallel tool-level provider dispatcher.

A container layer is terminal in the fold: its @ENTRYPOINT@ runs the binary
directly, so the subcommand is passed bare after the image and any deeper
nesting is the in-container binary's own runtime self-lift.
-}
module HostBootstrap.Lift (
    -- * Provider targets
    IncusVM (..),
    LimaVM (..),
    Wsl2VM (..),

    -- * Contexts
    LiftLayer (..),
    ContainerPlacement (..),
    ContainerLift (..),
    ConfigDelivery (..),
    LiftContext (..),
    localContext,
    inVM,
    inLimaVM,
    inWsl2VM,
    inContainer,
    canonicalHostMount,
    execVMArgs,
    shellVMArgs,
    wslExecArgs,

    -- * Self-reference
    SelfRef (..),
    mkSelfRef,
    currentSelfRef,

    -- * Generic folding and dispatch
    LiftDispatch (..),
    LiftLeaf (..),
    foldLeaf,
    foldLeafCommand,
    liftContextFrame,
    selfCommand,
    foldLift,
    containerRunArgs,
    configWriteScript,
    liftStdin,
    liftLeaf,
    liftLeafWithStdin,
    liftSubcommand,
    liftSubcommandWithStdin,
    runSelf,
    runSelfWithStdin,
    shellQuoteArgs,

    -- * Later composition and network leaves
    reachLeaf,
    blobUploadSessionLeaf,
    blobUploadPatchLeaf,
    blobUploadFinishLeaf,
    blobHeadLeaf,
    lifecycleProcessLeaf,
)
where

import qualified Data.Text as T
import qualified HostBootstrap.Config.Vocab as Vocab
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Quote (shellQuoteArgs)
import HostBootstrap.Effect.Run (capturedTriple)
import HostBootstrap.Effect.Vocabulary (
    EffectFrame (CrossedInto, OuterHost),
    EffectStdio (CaptureStreams),
    EffectTarget (SelfTarget),
    FrameCrossing (CrossContainer, CrossIncusVM, CrossLimaVM, CrossWsl2VM),
    HostCommand (..),
    hostCommand,
    inFrame,
    withCommandStdin,
 )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Incus, Lima, Wsl), toolCommandName)
import HostBootstrap.Lift.Context (
    ConfigDelivery (..),
    ContainerLift (..),
    ContainerPlacement (..),
    IncusVM (..),
    LiftContext (..),
    LiftLayer (..),
    LimaVM (..),
    Wsl2VM (..),
    canonicalHostMount,
    execVMArgs,
    inContainer,
    inLimaVM,
    inVM,
    inWsl2VM,
    localContext,
    shellVMArgs,
    wslExecArgs,
 )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode)

{- | How to invoke /this binary/ per context. The local path is the running
executable; the in-VM path is a deployment fact (e.g. the pipx/ghcup-installed
@\<project\>@ on the VM's @$PATH@). A container needs no path — its
@ENTRYPOINT@ is the binary.
-}
data SelfRef = SelfRef
    { localSelfPath :: FilePath
    , inVMSelfPath :: FilePath
    }
    deriving (Eq, Show)

-- | Build a 'SelfRef' from explicit paths (pure; used by the unit tests).
mkSelfRef :: FilePath -> FilePath -> SelfRef
mkSelfRef localP vmP = SelfRef{localSelfPath = localP, inVMSelfPath = vmP}

{- | Resolve a 'SelfRef' for the running binary: the local path from
'getExecutablePath' (@/proc/self/exe@, not @argv0@); the in-VM path supplied by
the caller (where its bootstrap installs the binary).
-}
currentSelfRef :: FilePath -> IO SelfRef
currentSelfRef vmP = do
    exe <- getExecutablePath
    pure (mkSelfRef exe vmP)

{- | The resolved host invocation a lift folds down to: either run the binary
itself locally, or run a host tool (@incus@/@docker@) whose args encode the
nested invocation.
-}
data LiftDispatch
    = DispatchLocal FilePath [String]
    | DispatchTool HostTool [String]
    deriving (Eq, Show)

{- | The @docker run@ argv for a container layer, with the in-container command as
the tail. Pure.
-}
containerRunArgs :: ContainerLift -> [String] -> [String]
containerRunArgs c inner =
    ["run"]
        ++ (["--rm" | clRemoveAfter c])
        ++ concatMap mountArg (clMounts c)
        ++ deliveryArgs
        ++ clExtraArgs c
        ++ [clImage c]
        ++ innerTail
  where
    -- With config delivery: keep the container's @stdin@ open (@-i@) so the
    -- in-container @cat@ receives the piped projection, and override the
    -- @ENTRYPOINT@ to a @sh@ that writes the sibling then @exec@s the binary.
    (deliveryArgs, innerTail) = case clConfigDelivery c of
        Nothing -> ([], inner)
        Just cd -> (["-i", "--entrypoint", "sh"], ["-c", configWriteScript cd inner])
    mountArg m =
        [ "-v"
        , T.unpack (Vocab.source m)
            ++ ":"
            ++ T.unpack (Vocab.target m)
            ++ (if Vocab.readOnly m then ":ro" else "")
        ]

{- | The @sh -c@ body a delivering container runs: write the piped @stdin@ (the
child projection) to the sibling config path, then @exec@ the child binary with
the folded subcommand. The write path and the exec argv are single-quoted
('shellQuoteArgs') so no re-splitting or glob expansion occurs; the payload
itself is /not/ in the script — it flows on @stdin@. Pure.
-}
configWriteScript :: ConfigDelivery -> [String] -> String
configWriteScript cd inner =
    "cat > "
        ++ shellQuoteArgs [cdWritePath cd]
        ++ " && exec "
        ++ shellQuoteArgs (cdExecPath cd : inner)

{- | The innermost thing a lift runs at the bottom frame: either /this binary's/
own subcommand (whose path differs by frame — local vs in-VM), or an arbitrary
fixed command run as-is in that frame (e.g. @curl …@ or @bash -lc …@). The raw
form lets the /same/ pure fold place a reachability probe (or any command) into
the correct frame, so an assertion is provider-agnostic by construction — the
only thing that varies across Lima and Incus is the 'LiftLayer' constructor.
-}
data LiftLeaf
    = SelfSub SelfRef [String]
    | RawCmd [String]
    | LifecycleProcessCmd String [String]
    deriving (Eq, Show)

{- | A reachability-probe leaf: a quiet, bounded @curl@ of @url@. Placed in the
frame where the endpoint is published (the VM), it folds to
@incus exec \<vm\> -- curl …@ / @limactl shell \<vm\> -- curl …@, so the one
probe value is correct on every provider regardless of host port-forwarding.
-}
reachLeaf :: String -> LiftLeaf
reachLeaf url = RawCmd ["curl", "-fsS", "-m", "5", "-o", "/dev/null", url]

{- | The fixed child-process leaf used by authenticated lifecycle descent.
Provider-specific root/noninteractive placement is rendered only by
'foldLeaf'; the route layer supplies merely the admitted binary and marker.
-}
lifecycleProcessLeaf :: String -> [String] -> LiftLeaf
lifecycleProcessLeaf = LifecycleProcessCmd

{- | Open a blob-upload session and print the response headers.

The registry's upload is deliberately two-step: this @POST@ answers @202@ with a
@Location@ for the session. A @POST@ carrying @?digest=@ does /not/ complete the
upload on @registry:2@ — it also answers @202@ and stores nothing, which is a
silent no-op that a fail-fast check cannot distinguish from success. Verified
directly against @registry:2@ before this was written.

Headers go to stdout (@-D -@) so the @Location@ is parsed in Haskell rather than
by a shell pipeline in the guest (§ CC).
-}
blobUploadSessionLeaf :: String -> LiftLeaf
blobUploadSessionLeaf url =
    RawCmd ["curl", "-sS", "-m", "15", "-o", "/dev/null", "-D", "-", "-X", "POST", url]

{- | Send the blob's bytes into an open upload session and print the response
headers, which carry the session's next @Location@.

This step is **not** optional, even for a one-byte blob. Skipping it and putting
the bytes in the final @PUT@ works against a filesystem-backed registry but
fails against an S3-backed one with
@InvalidRequest: You must specify at least one part@ — the driver completes a
multipart upload that has no parts. Verified directly against @registry:2@
backed by MinIO.

The content type must be @application/octet-stream@; curl's @-d@ otherwise sends
form encoding and the registry answers @bad Content-Type@. It is written without
a space after the colon, which HTTP permits, so every argument stays space-free
for the host->guest quoting path (§ CC).
-}
blobUploadPatchLeaf :: String -> String -> LiftLeaf
blobUploadPatchLeaf payload url =
    RawCmd
        [ "curl"
        , "-sS"
        , "-m"
        , "15"
        , "-o"
        , "/dev/null"
        , "-D"
        , "-"
        , "-X"
        , "PATCH"
        , "-H"
        , "Content-Type:application/octet-stream"
        , "-d"
        , payload
        , url
        ]

{- | Complete a blob upload against its session URL, which must already carry
@&digest=@.

This exists so a blob route can be proved /before/ an image push: a registry
that has never been written to has no blob to request, and a @404@ is not
evidence that blob delivery works. Fail-fast (@-f@), because an upload that did
not happen must not be mistaken for one that did. Every argument is
space-free, so it survives the host->guest quoting path unchanged (§ CC).
-}
blobUploadFinishLeaf :: String -> LiftLeaf
blobUploadFinishLeaf url =
    RawCmd ["curl", "-fsS", "-m", "15", "-o", "/dev/null", "-X", "PUT", url]

{- | @HEAD@ one blob and report the status and any @Location@, without following
it.

Deliberately **not** fail-fast: a @307@ is a perfectly valid HTTP response and is
exactly the observation that must be classified rather than swallowed. The
redirect is not followed, because whether this client /could/ follow it is the
question being asked (§ GG). Stays a single simple command so it survives the
host->guest quoting path unchanged (§ CC).
-}
blobHeadLeaf :: String -> LiftLeaf
blobHeadLeaf url =
    RawCmd
        [ "curl"
        , "-sS"
        , "-m"
        , "10"
        , "-o"
        , "/dev/null"
        , "-I"
        , "-w"
        , "%{http_code} %{redirect_url}"
        , url
        ]

-- | The argv to run once inside the innermost VM (no remaining layers).
leafInVMArgv :: LiftLeaf -> [String]
leafInVMArgv (SelfSub self sub) = inVMSelfPath self : sub
leafInVMArgv (RawCmd argv) = argv
leafInVMArgv (LifecycleProcessCmd binary argv) = binary : argv

{- | The command tail passed after a container image. A 'SelfSub' relies on the
container @ENTRYPOINT@ being the binary, so only the subcommand is passed.
-}
leafContainerInner :: LiftLeaf -> [String]
leafContainerInner (SelfSub _ sub) = sub
leafContainerInner (RawCmd argv) = argv
leafContainerInner (LifecycleProcessCmd _ argv) = argv

-- | The dispatch when the stack is empty (run at the local host frame).
leafLocalDispatch :: LiftLeaf -> LiftDispatch
leafLocalDispatch (SelfSub self sub) = DispatchLocal (localSelfPath self) sub
leafLocalDispatch (RawCmd (exe : args)) = DispatchLocal exe args
leafLocalDispatch (RawCmd []) = DispatchLocal "" []
leafLocalDispatch (LifecycleProcessCmd binary argv) = DispatchLocal binary argv

{- | Fold a context stack and a 'LiftLeaf' into the host invocation. Pure, so the
argv is unit-tested. Encodes the @§ K@ rule already implicit in 'execVMArgs':
only the outermost host dispatch names a tool that the resolver maps to an
absolute path; every nested tool is the target's own bare @$PATH@ name.
-}
foldLeaf :: LiftContext -> LiftLeaf -> LiftDispatch
foldLeaf (LiftContext layers) leaf = build layers
  where
    build [] = leafLocalDispatch leaf
    build [ViaVM vm]
        | LifecycleProcessCmd binary argv <- leaf =
            DispatchTool Incus (["exec", vmName vm, "--cwd", "/", "-T", "--", binary] ++ argv)
    build [ViaLimaVM vm]
        | LifecycleProcessCmd binary argv <- leaf =
            DispatchTool Lima (["shell", limaName vm, "--workdir", "/", "--", "sudo", "-n", "-H", binary] ++ argv)
    build [ViaWsl2VM vm]
        | LifecycleProcessCmd binary argv <- leaf =
            DispatchTool Wsl (["-d", wsl2Distro vm, "--cd", "/", "--", "sudo", "-n", "-H", binary] ++ argv)
    build (ViaVM vm : rest) = DispatchTool Incus (execVMArgs vm (insideVM rest))
    build (ViaLimaVM vm : rest) = DispatchTool Lima (shellVMArgs vm (insideVM rest))
    build (ViaWsl2VM vm : rest) = DispatchTool Wsl (wslExecArgs (wsl2Distro vm) (insideVM rest))
    build (ViaContainer c : _) = DispatchTool Docker (containerRunArgs c (leafContainerInner leaf))

    -- The argv to run inside a VM, given the remaining inner layers.
    insideVM [] = leafInVMArgv leaf
    insideVM (ViaVM vm : rest) = toolCommandName Incus : execVMArgs vm (insideVM rest)
    insideVM (ViaLimaVM vm : rest) = toolCommandName Lima : shellVMArgs vm (insideVM rest)
    insideVM (ViaWsl2VM vm : rest) = toolCommandName Wsl : wslExecArgs (wsl2Distro vm) (insideVM rest)
    insideVM (ViaContainer c : _) = toolCommandName Docker : containerRunArgs c (leafContainerInner leaf)

{- | Fold a context stack and a subcommand of /this binary/ into the host
invocation — the 'SelfSub' special case of 'foldLeaf'.
-}
foldLift :: SelfRef -> LiftContext -> [String] -> LiftDispatch
foldLift self ctx sub = foldLeaf ctx (SelfSub self sub)

{- | The @stdin@ a context wants piped into its innermost container handoff: a
terminal container layer's config-delivery payload (the narrowed child
projection), else empty. Pure. Lets the recursive handoff stream the child
config in-place without a host-side file or a config bind-mount (§ X).
-}
liftStdin :: LiftContext -> String
liftStdin (LiftContext layers) = case reverse layers of
    (ViaContainer c : _) -> maybe "" (T.unpack . cdPayload) (clConfigDelivery c)
    _ -> ""

{- | The frame a context stack lands in, outermost crossing first (§ MM).

Descriptive rather than constructive: the argument vector that performs each
crossing comes from 'foldLeaf' and from nowhere else. This says only /where/
that argv is interpreted, which is what decides the grammar of the paths it
carries.
-}
liftContextFrame :: LiftContext -> EffectFrame
liftContextFrame (LiftContext layers) = case map crossingOf layers of
    [] -> OuterHost
    (outermost : inner) -> CrossedInto outermost inner
  where
    crossingOf (ViaVM vm) = CrossIncusVM (vmName vm)
    crossingOf (ViaLimaVM vm) = CrossLimaVM (limaName vm)
    crossingOf (ViaWsl2VM vm) = CrossWsl2VM (wsl2Distro vm)
    crossingOf (ViaContainer c) = CrossContainer (clImage c)

{- | The described command a leaf folds down to in a context (§ KK): the one
fold's dispatch, together with the frame that interprets it.
-}
foldLeafCommand :: LiftContext -> LiftLeaf -> HostCommand
foldLeafCommand ctx leaf =
    inFrame (liftContextFrame ctx) $ case foldLeaf ctx leaf of
        DispatchLocal exe args -> selfCommand exe args
        DispatchTool tool args -> hostCommand tool args

{- | A command naming this binary — or any executable the caller already holds an
absolute path for — rather than a resolved 'HostTool'.
-}
selfCommand :: FilePath -> [String] -> HostCommand
selfCommand exe args =
    HostCommand
        { commandTarget = SelfTarget exe
        , commandArguments = args
        , commandStdio = CaptureStreams ""
        , commandFrame = OuterHost
        }

{- | Run a 'LiftLeaf' in a context: fold to the described command, then hand it
to the one interpreter.
-}
liftLeaf ::
    HostConfig ->
    LiftContext ->
    LiftLeaf ->
    IO (Either String (ExitCode, String, String))
liftLeaf cfg ctx leaf = liftLeafWithStdin cfg ctx leaf ""

{- | Like 'liftLeaf', but feed @input@ to the folded invocation on @stdin@ (the
streamed child-config channel). 'liftLeaf' is @liftLeafWithStdin … ""@, so an
empty @input@ is byte-identical to it.
-}
liftLeafWithStdin ::
    HostConfig ->
    LiftContext ->
    LiftLeaf ->
    String ->
    IO (Either String (ExitCode, String, String))
liftLeafWithStdin cfg ctx leaf input =
    fmap capturedTriple <$> interpretHostCommand cfg (withCommandStdin input (foldLeafCommand ctx leaf))

{- | Run a subcommand of this binary in a context — the 'SelfSub' special case of
'liftLeaf'.
-}
liftSubcommand ::
    HostConfig ->
    SelfRef ->
    LiftContext ->
    [String] ->
    IO (Either String (ExitCode, String, String))
liftSubcommand cfg self ctx sub = liftLeaf cfg ctx (SelfSub self sub)

{- | Like 'liftSubcommand', but feed @input@ to the nested invocation on @stdin@ —
the channel the recursive handoff uses to stream the next frame's child config
in-place (§ X). 'liftSubcommand' is @liftSubcommandWithStdin … ""@.
-}
liftSubcommandWithStdin ::
    HostConfig ->
    SelfRef ->
    LiftContext ->
    [String] ->
    String ->
    IO (Either String (ExitCode, String, String))
liftSubcommandWithStdin cfg self ctx sub = liftLeafWithStdin cfg ctx (SelfSub self sub)

{- | Run a local executable (the binary itself — not a 'HostTool') capturing its
exit/stdout/stderr; 'Left' on an exec failure. The configuration is the one
every described command is interpreted against; a self target consults none of
it.
-}
runSelf :: HostConfig -> FilePath -> [String] -> IO (Either String (ExitCode, String, String))
runSelf cfg exe args = runSelfWithStdin cfg exe args ""

{- | Like 'runSelf', but feed @stdin@ to the binary — the channel a streamed child
config travels on when the innermost frame is local.
-}
runSelfWithStdin :: HostConfig -> FilePath -> [String] -> String -> IO (Either String (ExitCode, String, String))
runSelfWithStdin cfg exe args input =
    fmap capturedTriple <$> interpretHostCommand cfg (withCommandStdin input (selfCommand exe args))
