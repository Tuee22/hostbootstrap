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
'foldLift' is pure (the argv fold is unit-tested); 'liftSubcommand' interprets
that description. A delivering container is a create/copy/start workflow: its
configuration is copied into the stopped container before its image entry point
starts. Raw tool/probe leaves use the same 'foldLeaf' route, so there is no
parallel tool-level provider dispatcher.

A container closes its VM stack by type: its @ENTRYPOINT@ runs the binary
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
    LiftContext,
    liftLayers,
    liftVMStack,
    VMStack,
    emptyVMStack,
    vmContext,
    liftContextFromLayers,
    terminalContainer,
    mapTerminalContainer,
    localContext,
    inVM,
    inLimaVM,
    inWsl2VM,
    inContainer,
    canonicalHostMount,
    VMPlacement (..),
    foldPlacement,
    lifecyclePlacement,
    execVMArgsAt,
    shellVMArgsAt,
    wslExecArgsAt,
    execVMArgs,
    shellVMArgs,
    wslExecArgs,

    -- * Self-reference
    SelfRef,
    LocalSelfPath (..),
    InVMSelfPath (..),
    mkSelfRef,
    currentSelfRef,
    selfRefInVMPath,

    -- * Generic folding and dispatch
    LiftDispatch (..),
    LiftLeaf (..),
    foldLeaf,
    foldLeafCommand,
    liftContextFrame,
    selfCommand,
    foldLift,
    containerRunArgs,
    containerCreateArgs,
    configDeliveryTar,
    liftStdin,
    liftLeaf,
    liftLeafWithStdin,
    liftLeafWithStdinWith,
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

import Control.Exception (SomeException, displayException, mask, onException, try)
import Control.Exception.Safe (tryAny)
import qualified Data.ByteString as BS
import Data.Char (ord)
import Data.List (find)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified HostBootstrap.Config.Vocab as Vocab
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Quote (shellQuoteArgs)
import HostBootstrap.Effect.Run (CapturedRun, capturedTriple)
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
import HostBootstrap.HostTool (HostTool (Docker, Incus, Lima, Wsl), allHostTools, toolCommandName)
import HostBootstrap.Lift.Context (
    ConfigDelivery (..),
    ContainerLift (..),
    ContainerPlacement (..),
    IncusVM (..),
    LiftContext,
    LiftLayer (..),
    LimaVM (..),
    Wsl2VM (..),
    VMStack,
    VMPlacement (..),
    canonicalHostMount,
    emptyVMStack,
    execVMArgs,
    execVMArgsAt,
    foldPlacement,
    inContainer,
    inLimaVM,
    inVM,
    inWsl2VM,
    lifecyclePlacement,
    liftContextFromLayers,
    liftLayers,
    liftVMStack,
    localContext,
    mapTerminalContainer,
    shellVMArgs,
    shellVMArgsAt,
    terminalContainer,
    vmContext,
    wslExecArgs,
    wslExecArgsAt,
 )
import Numeric (showOct)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import qualified System.FilePath.Posix as Posix
import System.IO (hPutStrLn, stderr)

{- | How to invoke /this binary/ per context. The local path is the running
executable; the in-VM path is a deployment fact (e.g. the pipx/ghcup-installed
@\<project\>@ on the VM's @$PATH@). A container needs no path — its
@ENTRYPOINT@ is the binary.
-}

-- | Where this binary is on the host that is running it.
newtype LocalSelfPath = LocalSelfPath FilePath
    deriving (Eq, Show)

-- | Where this binary is inside the guest it lifts into.
newtype InVMSelfPath = InVMSelfPath FilePath
    deriving (Eq, Show)

{- | The two paths are adjacent, both unvalidated, and both @FilePath@ before
these newtypes existed — so transposing them at a construction site produced a
value that dispatches the guest path locally and the local path in the guest,
and nothing said so. They are distinct types, the constructor is package-private,
and there are no field selectors: a handed value cannot be re-pointed by record
update either.
-}
data SelfRef = SelfRef LocalSelfPath InVMSelfPath
    deriving (Eq, Show)

-- | Build a 'SelfRef' from explicit paths (pure; used by the unit tests).
mkSelfRef :: LocalSelfPath -> InVMSelfPath -> SelfRef
mkSelfRef = SelfRef

-- | Where the binary is inside the guest this reference lifts into.
selfRefInVMPath :: SelfRef -> FilePath
selfRefInVMPath (SelfRef _ (InVMSelfPath path)) = path

selfRefLocalPath :: SelfRef -> FilePath
selfRefLocalPath (SelfRef (LocalSelfPath path) _) = path

{- | Resolve a 'SelfRef' for the running binary: the local path from
'getExecutablePath' (@/proc/self/exe@, not @argv0@); the in-VM path supplied by
the caller (where its bootstrap installs the binary).
-}
currentSelfRef :: InVMSelfPath -> IO SelfRef
currentSelfRef vmP = do
    exe <- getExecutablePath
    pure (mkSelfRef (LocalSelfPath exe) vmP)

{- | The host invocation a lift folds down to: a local self/lifecycle binary,
a local raw tool name to validate, a host tool whose arguments encode the nested
invocation, or a staged container delivery retaining its VM prefix and command.
-}
data LiftDispatch
    = DispatchLocal FilePath [String]
    | DispatchLocalRaw String [String]
    | DispatchTool HostTool [String]
    | DispatchContainerDelivery LiftContext ContainerLift [String]
    deriving (Eq, Show)

{- | The single @docker run@ argv, with the in-container command as its tail.
The fold selects create/copy/start instead when configuration delivery is present.
-}
containerRunArgs :: ContainerLift -> [String] -> [String]
containerRunArgs = containerArgs "run"

-- | Create a stopped container with its image entry point and folded command.
containerCreateArgs :: ContainerLift -> [String] -> [String]
containerCreateArgs = containerArgs "create"

containerArgs :: String -> ContainerLift -> [String] -> [String]
containerArgs operation c inner =
    [operation]
        ++ (["--rm" | clRemoveAfter c])
        ++ concatMap mountArg (clMounts c)
        ++ clExtraArgs c
        ++ [clImage c]
        ++ inner
  where
    mountArg m =
        [ "-v"
        , T.unpack (Vocab.source m)
            ++ ":"
            ++ T.unpack (Vocab.target m)
            ++ (if Vocab.readOnly m then ":ro" else "")
        ]

{- | Encode one UTF-8 configuration as a regular ustar file under the write
path's basename. The directory must already exist inside the container.
All lengths, padding and the checksum count bytes, including Unicode payloads.
-}
configDeliveryTar :: FilePath -> String -> Either String BS.ByteString
configDeliveryTar path input
    | not (Posix.isAbsolute path) || Posix.hasTrailingPathSeparator path || name `elem` ["", ".", "..", "/"] || '\0' `elem` path =
        Left "container config delivery requires a POSIX-absolute file path"
    | BS.length nameBytes > 100 = Left "container config delivery filename exceeds the ustar 100-byte limit"
    | size > 8 ^ (11 :: Int) - 1 = Left "container config delivery payload exceeds the ustar size limit"
    | otherwise = Right (header <> payload <> BS.replicate padding 0 <> BS.replicate 1024 0)
  where
    name = Posix.takeFileName path
    nameBytes = TE.encodeUtf8 (T.pack name)
    payload = TE.encodeUtf8 (T.pack input)
    size = toInteger (BS.length payload)
    padding = (512 - BS.length payload `mod` 512) `mod` 512
    provisional = BS.concat
        [ nameBytes, BS.replicate (100 - BS.length nameBytes) 0
        , octal 8 0o644, octal 8 0, octal 8 0, octal 12 size, octal 12 0
        , BS.replicate 8 32, ascii "0", BS.replicate 100 0, ascii "ustar\0", ascii "00"
        , BS.replicate 64 0, octal 8 0, octal 8 0, BS.replicate 167 0
        ]
    checksum = BS.foldl' (\total byte -> total + toInteger byte) 0 provisional
    header = BS.take 148 provisional <> octal 7 checksum <> ascii " " <> BS.drop 156 provisional
    ascii = BS.pack . map (fromIntegral . ord)
    octal :: Int -> Integer -> BS.ByteString
    octal width value =
        let digits = showOct value ""
         in ascii (replicate (width - 1 - length digits) '0' ++ digits ++ "\0")

{- | The innermost thing a lift runs at the bottom frame: /this binary's/
own subcommand, an admitted lifecycle binary, or a raw executable and arguments.
A local raw executable must exactly name a registered 'HostTool'. In a VM the
guest runs that executable; in a container the executable and arguments are
passed to the image @ENTRYPOINT@ (the binary) as its arguments. The same pure
fold places the leaf in its declared frame; the 'LiftLayer' selects the crossing.
-}
data LiftLeaf
    = SelfSub SelfRef [String]
    | {- | an executable and its arguments; the executable is separate from
      argv, so an empty argument vector cannot accidentally supply or omit it
      -}
      RawCmd String [String]
    | LifecycleProcessCmd String [String]
    deriving (Eq, Show)

{- | A reachability-probe leaf: a quiet, bounded @curl@ of @url@. Placed in the
frame where the endpoint is published (the VM), it folds to
@incus exec \<vm\> -- curl …@ / @limactl shell \<vm\> -- curl …@, so the one
probe value is correct on every provider regardless of host port-forwarding.
-}
reachLeaf :: String -> LiftLeaf
reachLeaf url = RawCmd "curl" ["-fsS", "-m", "5", "-o", "/dev/null", url]

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
    RawCmd "curl" ["-sS", "-m", "15", "-o", "/dev/null", "-D", "-", "-X", "POST", url]

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
    RawCmd "curl" ["-sS", "-m", "15", "-o", "/dev/null", "-D", "-", "-X", "PATCH", "-H", "Content-Type:application/octet-stream", "-d", payload, url]

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
    RawCmd "curl" ["-fsS", "-m", "15", "-o", "/dev/null", "-X", "PUT", url]

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
    RawCmd "curl" ["-sS", "-m", "10", "-o", "/dev/null", "-I", "-w", "%{http_code} %{redirect_url}", url]

-- | The argv to run once inside the innermost VM (no remaining layers).
leafInVMArgv :: LiftLeaf -> [String]
leafInVMArgv (SelfSub self sub) = selfRefInVMPath self : sub
leafInVMArgv (RawCmd exe argv) = exe : argv
leafInVMArgv (LifecycleProcessCmd binary argv) = binary : argv

{- | The command tail passed after a container image. A 'SelfSub' relies on the
container @ENTRYPOINT@ being the binary, so only the subcommand is passed.
-}
leafContainerInner :: LiftLeaf -> [String]
leafContainerInner (SelfSub _ sub) = sub
leafContainerInner (RawCmd exe argv) = exe : argv
leafContainerInner (LifecycleProcessCmd _ argv) = argv

-- | The dispatch when the stack is empty (run at the local host frame).
leafLocalDispatch :: LiftLeaf -> LiftDispatch
leafLocalDispatch (SelfSub self sub) = DispatchLocal (selfRefLocalPath self) sub
leafLocalDispatch (RawCmd exe args) = DispatchLocalRaw exe args
leafLocalDispatch (LifecycleProcessCmd binary argv) = DispatchLocal binary argv

{- | Fold a context stack and a 'LiftLeaf' into a command or staged delivery.
Ordinary and lifecycle leaves use the same VM renderers and inner fold with
different placement values. Lima retains its provider-root default. Under
@§ K@ only the outermost dispatch names a tool the resolver maps to an absolute
path; every nested tool is the target's own bare @$PATH@ name.
-}
foldLeaf :: LiftContext -> LiftLeaf -> LiftDispatch
foldLeaf context leaf =
    case terminal of
        Just container
            | Just _ <- clConfigDelivery container ->
                DispatchContainerDelivery prefix container (leafContainerInner leaf)
        _ -> build layers
  where
    placement = case leaf of
        LifecycleProcessCmd{} -> lifecyclePlacement
        _ -> foldPlacement
    limaPlacement = placement{placementElevated = True}
    prefix = vmContext (liftVMStack context)
    terminal = terminalContainer context
    layers = liftLayers prefix ++ maybe [] (\container -> [ViaContainer container]) terminal

    build [] = leafLocalDispatch leaf
    build (ViaVM vm : rest) = DispatchTool Incus (execVMArgsAt placement vm (insideVM rest))
    build (ViaLimaVM vm : rest) = DispatchTool Lima (shellVMArgsAt limaPlacement vm (insideVM rest))
    build (ViaWsl2VM vm : rest) = DispatchTool Wsl (wslExecArgsAt placement (wsl2Distro vm) (insideVM rest))
    build (ViaContainer c : _) = DispatchTool Docker (containerRunArgs c (leafContainerInner leaf))

    -- The argv to run inside a VM, given the remaining inner layers.
    insideVM [] = leafInVMArgv leaf
    insideVM (ViaVM vm : rest) = toolCommandName Incus : execVMArgsAt placement vm (insideVM rest)
    insideVM (ViaLimaVM vm : rest) = toolCommandName Lima : shellVMArgsAt limaPlacement vm (insideVM rest)
    insideVM (ViaWsl2VM vm : rest) = toolCommandName Wsl : wslExecArgsAt placement (wsl2Distro vm) (insideVM rest)
    insideVM (ViaContainer c : _) = toolCommandName Docker : containerRunArgs c (leafContainerInner leaf)

{- | Fold a context stack and a subcommand of /this binary/ into the host
invocation — the 'SelfSub' special case of 'foldLeaf'.
-}
foldLift :: SelfRef -> LiftContext -> [String] -> LiftDispatch
foldLift self ctx sub = foldLeaf ctx (SelfSub self sub)

{- | The projection text a terminal delivering container supplies as default
lift input, else empty. Callers pass it explicitly; the staged workflow archives
it for copying before the image entry point starts (§ X).
-}
liftStdin :: LiftContext -> String
liftStdin context = case terminalContainer context of
    Just container -> maybe "" (T.unpack . cdPayload) (clConfigDelivery container)
    Nothing -> ""

{- | The frame a context stack lands in, outermost crossing first (§ MM).

Descriptive rather than constructive: the argument vector that performs each
crossing comes from 'foldLeaf' and from nowhere else. This says only /where/
that argv is interpreted, which is what decides the grammar of the paths it
carries.
-}
liftContextFrame :: LiftContext -> EffectFrame
liftContextFrame context = case map crossingOf (liftLayers context) of
    [] -> OuterHost
    (outermost : inner) -> CrossedInto outermost inner
  where
    crossingOf (ViaVM vm) = CrossIncusVM (vmName vm)
    crossingOf (ViaLimaVM vm) = CrossLimaVM (limaName vm)
    crossingOf (ViaWsl2VM vm) = CrossWsl2VM (wsl2Distro vm)
    crossingOf (ViaContainer c) = CrossContainer (clImage c)

{- | The described command a leaf folds down to in a context (§ KK): the one
fold's dispatch, together with the frame that interprets it. An unregistered
local raw executable or a multi-command delivery is refused before interpretation.
-}
foldLeafCommand :: LiftContext -> LiftLeaf -> Either String HostCommand
foldLeafCommand ctx leaf =
    inFrame (liftContextFrame ctx) <$> case foldLeaf ctx leaf of
        DispatchLocal exe args -> Right (selfCommand exe args)
        DispatchLocalRaw exe args ->
            case find ((== exe) . toolCommandName) allHostTools of
                Just tool -> Right (hostCommand tool args)
                Nothing -> Left ("local executable is not a registered host tool: " ++ exe)
        DispatchTool tool args -> Right (hostCommand tool args)
        DispatchContainerDelivery{} -> Left "container config delivery requires the staged command runner"

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

{- | Run a 'LiftLeaf' in a context: fold to its command or staged delivery, then
hand each real command to the one interpreter.
-}
liftLeaf ::
    HostConfig ->
    LiftContext ->
    LiftLeaf ->
    IO (Either String (ExitCode, String, String))
liftLeaf cfg ctx leaf = liftLeafWithStdin cfg ctx leaf ""

{- | Like 'liftLeaf', with explicit standard input. A delivering container copies
that input as its configuration before starting with empty stdin; other contexts
feed it to their single invocation. 'liftLeaf' supplies empty input.
-}
liftLeafWithStdin ::
    HostConfig ->
    LiftContext ->
    LiftLeaf ->
    String ->
    IO (Either String (ExitCode, String, String))
liftLeafWithStdin cfg = liftLeafWithStdinWith (interpretHostCommand cfg)

{- | The production workflow over a supplied described-command interpreter.
Creation and copy chatter stay internal; the final start result is returned.
Once an ID is known, requested removal is attempted on dependent-step failure
or exception. Cleanup refusal augments the primary diagnostic; it neither
replaces the primary failure nor proves a container remains after auto-removal.
-}
liftLeafWithStdinWith ::
    (HostCommand -> IO (Either String CapturedRun)) ->
    LiftContext ->
    LiftLeaf ->
    String ->
    IO (Either String (ExitCode, String, String))
liftLeafWithStdinWith run ctx leaf input =
    case terminalContainer ctx of
        Just container
            | Just delivery <- clConfigDelivery container ->
                runContainerDelivery
                    run
                    (vmContext (liftVMStack ctx))
                    container
                    delivery
                    (leafContainerInner leaf)
                    input
        _ -> case foldLeafCommand ctx leaf of
            Left refusal -> pure (Left refusal)
            Right command -> fmap capturedTriple <$> run (withCommandStdin input command)

runContainerDelivery ::
    (HostCommand -> IO (Either String CapturedRun)) ->
    LiftContext -> ContainerLift -> ConfigDelivery -> [String] -> String ->
    IO (Either String (ExitCode, String, String))
runContainerDelivery run prefix container delivery inner input = case archiveInput of
    Left refusal -> pure (Left refusal)
    Right archive -> mask $ \restore -> do
        created <- restore (runStage (containerCreateArgs container inner) "")
        case created of
            Right (ExitSuccess, output, _) -> case words output of
                [identifier] | length identifier == 64 && all hexDigit identifier -> do
                    outcome <- restore (copyAndStart identifier archive) `onException` reportCleanup identifier
                    if succeeded outcome
                        then pure outcome
                        else do
                            cleanupFailure <- cleanup identifier
                            pure (appendCleanup cleanupFailure outcome)
                _ -> pure (Left "docker create did not return one full container ID")
            _ -> pure created
  where
    archiveInput = do
        archive <- configDeliveryTar (cdWritePath delivery) input
        either
            (const (Left "container config delivery archive is not UTF-8"))
            (Right . T.unpack)
            (TE.decodeUtf8' archive)

    hexDigit character = character >= '0' && character <= '9' || character >= 'a' && character <= 'f'
    succeeded (Right (ExitSuccess, _, _)) = True
    succeeded _ = False

    runStage arguments stdinInput = case foldLeafCommand prefix (RawCmd (toolCommandName Docker) arguments) of
        Left refusal -> pure (Left refusal)
        Right command -> fmap capturedTriple <$> run (withCommandStdin stdinInput command)

    copyAndStart identifier archive = do
        copied <- runStage ["cp", "-", identifier ++ ":" ++ Posix.takeDirectory (cdWritePath delivery)] archive
        if succeeded copied
            then runStage ["start", "-a", identifier] ""
            else pure copied

    cleanup identifier
        | not (clRemoveAfter container) = pure Nothing
        | otherwise = do
            attempted <- tryAny (runStage ["rm", "-f", identifier] "")
            pure $ case attempted of
                Left failure -> Just (displayException failure)
                Right (Left refusal) -> Just refusal
                Right (Right (ExitSuccess, _, _)) -> Nothing
                Right (Right (status, output, errors)) ->
                    Just ("docker rm -f exited " ++ show status ++ ": " ++ output ++ errors)

    appendCleanup Nothing primary = primary
    appendCleanup (Just detail) primary = case primary of
        Left refusal -> Left (refusal ++ "\ncontainer cleanup failed: " ++ detail)
        Right (status, output, errors) -> Right (status, output, errors ++ "\ncontainer cleanup failed: " ++ detail)

    -- An exception is already propagating. A second cleanup/reporting failure,
    -- including interruption, must not replace that original exception.
    reportCleanup identifier = do
        attempted <- try (cleanup identifier) :: IO (Either SomeException (Maybe String))
        case either (Just . displayException) id attempted of
            Nothing -> pure ()
            Just detail -> do
                _ <- try (hPutStrLn stderr ("container cleanup failed: " ++ detail)) :: IO (Either SomeException ())
                pure ()

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

{- | Like 'liftSubcommand', with explicit input. A delivering container copies
it as configuration before starting; other contexts pass it to the invocation.
'liftSubcommand' supplies empty input.
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
