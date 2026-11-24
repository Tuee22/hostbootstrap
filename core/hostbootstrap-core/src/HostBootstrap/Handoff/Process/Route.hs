{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | The one way a rooted lifecycle exchange is allowed to reach a child.

A lift route says where a nested frame runs. It does not say that the child's
standard input and output are a protocol channel, and every argv shape the
ordinary lift renders is free to assume they are not: a container delivery may
consume standard input as a configuration archive, a VM layer may inherit
whatever descriptors its host process happened to hold, and either may carry
plan-authored extra arguments that detach the child, allocate a terminal, or
replace its entrypoint. Any one of those silently turns the channel this phase
needs into a channel somebody else is also writing to.

So a process route is a lift route with the ambiguity removed. It is derived
from a catalog-admitted package rather than assembled, it renders exactly one
argv shape per provider, and everything a plan could have added to that shape
is a refusal rather than a passthrough. The configuration payload in
particular has nowhere to go here: 'ConfigDelivery' consumes the supplied input
in a create/copy/start workflow, while this route requires one child whose input
and output carry the root's protocol. A route carrying delivery cannot be derived.

A route points in exactly one direction: down, at the child a frame is about
to launch. It is not that frame's own place in the conversation. Those are
different edges, and a middle frame holds both at once — it is a nested frame
of the root and the parent of a deeper child — so a value that carried both
would let a frame open a session for the child it is spawning instead of for
itself. What lives beside the route here is therefore only the one step that
has no owner yet: the opening a frame raises for itself before it has any
coordinates to hold. Everything after that opening is the storeless frame
executor's, which already owns the root-selected path, session, stage,
ordinal, and predecessor and the closed post-open request families.

Nothing here spawns anything. The route is the description a process owner
later obeys, and this module names no process, descriptor, handle, or
protected store.
-}
module HostBootstrap.Handoff.Process.Route (
    LifecycleProcessRoute,
    withForwardLifecycleProcessRouteKernel,
    withNestedForwardLifecycleProcessRouteKernel,
    withRecoveryLifecycleProcessRouteForKernel,
    withLifecycleProcessRouteLaunchKernel,
    withLifecycleChildOpeningKernel,
)
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Char (isSpace)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Authority (ProjectVerb)
import HostBootstrap.Config.Vocab (Mount (..))
import HostBootstrap.Handoff (
    HandoffBindingInput,
    ProjectVerificationKey,
    RootedLifecycleResponse,
    handoffErrorMessage,
    requestedChildFrame,
    requestedParentFrame,
    requestedPhase,
    withVerifiedRootedLifecycleResponse,
 )
import HostBootstrap.Handoff.Recovery (withRecoveryChildPackageKernel)
import HostBootstrap.Handoff.Rooted (
    renderRootedLifecycleRequestKernel,
    rootedOpenFrameRequestKernel,
    withRootedLifecycleResponseKernel,
 )
import HostBootstrap.Handoff.Runtime (
    RecursiveHandoffRuntime,
    withNestedArmRecursiveHandoffRuntimeKernel,
 )
import HostBootstrap.HostTool (HostTool)
import HostBootstrap.Lift (LiftDispatch (DispatchTool), foldLeaf, lifecycleProcessLeaf)
import HostBootstrap.Lift.Context (
    ContainerLift (clConfigDelivery, clExtraArgs, clImage, clMounts, clPlacement, clRemoveAfter),
    ContainerPlacement (DirectHostContainer, ProviderGuestContainer),
    IncusVM (vmName),
    LiftContext,
    LiftLayer (ViaContainer, ViaLimaVM, ViaVM, ViaWsl2VM),
    LimaVM (limaName),
    Wsl2VM (wsl2Distro),
    liftContextFromLayers,
    liftLayers,
    mapTerminalContainer,
 )
import HostBootstrap.ProjectPlan.Handoff.Internal (
    CatalogForwardHandoff,
    withCatalogForwardProcessInputsKernel,
 )
import HostBootstrap.Teardown.Internal (ReverseDescent, withReverseDescentProcessInputsKernel)

{- | One sanitized child invocation and the exchange it may carry.

The seven indices are nominal. Derivation introduces fresh parent and child
indices; those indices do not encode or independently verify frame names.
The admitted binding input supplies the frame names retained in the route.

An admitted route holds the closed verb, the two frame names its edge joins,
and the launch it renders: the host tool the outermost dispatch names, the
exact argument vector, and whether that shape carries Docker's @-i@ argument.
The frame's opening is separate from this route. The route holds no store,
session, journal, signing key, descriptor, or process handle.
-}
data LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb where
    LifecycleProcessRoute ::
        ProjectVerb verb ->
        Text ->
        Text ->
        HostTool ->
        [Text] ->
        ChannelInteractivity ->
        LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb

type role LifecycleProcessRoute nominal nominal nominal nominal nominal nominal nominal

instance Show (LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb) where
    show LifecycleProcessRoute{} = "LifecycleProcessRoute <launch>"

{- | Whether the terminal container shape includes Docker's @-i@ argument.
Every provider receives the protocol through piped standard input; VM shapes
do not require that Docker-specific flag. This distinction stays in the route.
-}
data ChannelInteractivity
    = InteractiveChannel
    | NoninteractiveChannel

{- | One rendered launch: the outermost host tool, the exact argument vector,
and the channel that vector asks for.
-}
data AdmittedLaunch = AdmittedLaunch HostTool [Text] ChannelInteractivity

{- | One admitted descent edge: the parent frame, the child frame, and the
launch rendered across it.

This is what a derivation produces, and it deliberately carries no index. A
route is minted from one of these at each of the four construction sites, so
admitting an edge and sealing a route for it remain two acts rather than one.
-}
data AdmittedEdge = AdmittedEdge Text Text AdmittedLaunch

{- | The admitted layers of a composed route and the channel its terminal
layer asks for. Only that terminal layer decides the channel, so
interactivity travels out of the recursion rather than into it.
-}
data AdmittedLayers = AdmittedLayers [LiftLayer] (Maybe ValidatedPath) ChannelInteractivity

{- | Text that has passed the closed argument grammar, and text that has
passed it and is an absolute delimiter-free path besides.

Neither wrapper exists for its own sake. Every renderer below consumes one of
these rather than a bare 'Text', so \"this value was admitted\" is a property
of the value a call site holds rather than of the order it happened to call
two functions in.
-}
newtype ValidatedArgument = ValidatedArgument {admittedText :: Text}

newtype ValidatedPath = ValidatedPath {admittedPathText :: Text}

{- | Derive the forward route for one catalog-admitted descent edge.

Everything the route is made of comes out of the package: the stripped
plan-owned lift route it retains and the binding input that names the exact
parent and child frames the catalog admitted. The two remaining arguments name
no coordinate — the verb is the closed invocation singleton this route runs
under, and the target binary path is the deployment fact a VM layer needs and
a container layer must not be given, because a container's entrypoint is
already the binary.

The forward edge is an execute-phase descent, so a binding input claiming any
other phase is refused before a launch is rendered.
-}
withForwardLifecycleProcessRouteKernel ::
    CatalogForwardHandoff
        scope
        rootPlanId
        brokerGeneration
        catalogId
        parentFrame
        childPlanDigest
        childConfigId
        childFrame ->
    ProjectVerb verb ->
    Text ->
    ( forall parent child.
      LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withForwardLifecycleProcessRouteKernel #-}
withForwardLifecycleProcessRouteKernel package verb targetBinary use =
    withCatalogForwardProcessInputsKernel package $ \route input _payload ->
        case derive verb "execute" (withoutConfigDelivery route) input targetBinary of
            Left failure -> pure (Left failure)
            Right (AdmittedEdge parent child (AdmittedLaunch tool argv interactivity)) ->
                use (LifecycleProcessRoute verb parent child tool argv interactivity)

{- | Derive the same forward route inside an authenticated child projection.

The private child caller obtains both arguments together from
@withImmediateTargetKernel@; this seam exists because the root-only catalog
package cannot cross into a storeless process.  The ordinary execute-phase and
single-layer sanitization remain identical to the root derivation.
-}
withNestedForwardLifecycleProcessRouteKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    LiftContext ->
    HandoffBindingInput ->
    ProjectVerb verb ->
    Text ->
    ( forall rootPlanId catalogId parent child.
      LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withNestedForwardLifecycleProcessRouteKernel runtime route input verb targetBinary use =
    runtime `seq`
        case derive verb "execute" route input targetBinary of
            Left failure -> pure (Left failure)
            Right (AdmittedEdge parent child (AdmittedLaunch tool argv interactivity)) ->
                use (LifecycleProcessRoute verb parent child tool argv interactivity)

{- | Derive a reverse route from one prepared descent. Its package, lift,
binding input and verb remain coupled to that descent's nominal lineage.
-}
withRecoveryLifecycleProcessRouteForKernel ::
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    Text ->
    ( forall rootPlanId catalogId parent child.
      LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withRecoveryLifecycleProcessRouteForKernel descent targetBinary use =
    withReverseDescentProcessInputsKernel descent $ \package route input verb ->
        case admitted package route input verb of
            Left failure -> pure (Left failure)
            Right (AdmittedEdge parent child (AdmittedLaunch tool argv interactivity)) ->
                use (LifecycleProcessRoute verb parent child tool argv interactivity)
  where
    admitted package route input verb = do
        withRecoveryChildPackageKernel package $ \childConfig adapter -> do
            require "the recovery package carries no child configuration" (not (ByteString.null childConfig))
            require "the recovery package carries no recovery adapter" (not (ByteString.null adapter))
        derive verb "teardown" (withoutConfigDelivery route) input targetBinary

withoutConfigDelivery :: LiftContext -> LiftContext
withoutConfigDelivery =
    mapTerminalContainer (\container -> container{clConfigDelivery = Nothing})

{- | Seal one route from an already admitted edge and its plan-owned lift.

The two frame names are the binding input's own, so no caller names the edge a
route joins, and they must be a real descent rather than a frame reaching
itself.
-}
derive ::
    ProjectVerb verb ->
    Text ->
    LiftContext ->
    HandoffBindingInput ->
    Text ->
    Either Text AdmittedEdge
derive verb phase route input targetBinary = do
    require "the admitted edge names an empty parent frame" (not (Text.null parent))
    require "the admitted edge names an empty child frame" (not (Text.null child))
    require "the admitted edge joins one frame to itself" (parent /= child)
    require
        ("the admitted edge is not a " <> phase <> "-phase descent")
        (requestedPhase input == phase)
    require "a forward process route must carry exactly one lift layer"
        (phase /= "execute" || length (liftLayers route) == 1)
    launch <- sanitizedLaunch route child targetBinary (subcommand verb)
    pure (AdmittedEdge parent child launch)
  where
    parent = requestedParentFrame input
    child = requestedChildFrame input

{- | The only command a process route ever places in a child.

The marker carries no verb or coordinate.  Those facts arrive only in the
authenticated Offer on the private channel, so command-line text cannot
compete with the root's signed account of the exchange.
-}
subcommand :: ProjectVerb verb -> [Text]
subcommand _verb = ["--hostbootstrap-lifecycle-child"]

{- | Render the closed single-layer or root-relative lifecycle route grammar.

Catalog edges have one layer; reverse recovery may retain several VM layers
and an optional terminal container. A Docker container carries @-i@ and runs at
@/@; the VM providers run at @/@, reaching root through noninteractive sudo
where the guest's default user is not root. Every provider receives piped input.

What the shapes have in common on the other side is that nothing a plan
authored reaches them. Container extra arguments, a configuration delivery, a
container that outlives its exchange, and any name that could be read as an
option, a separator, or a descriptor request are each refused, so the
overrides that would detach the child, allocate a terminal, reattach standard
input, replace the entrypoint, move the working directory, or forward a signal
have no path into the rendered vector.
-}
sanitizedLaunch :: LiftContext -> Text -> Text -> [Text] -> Either Text AdmittedLaunch
sanitizedLaunch route child targetBinary inner = case liftLayers route of
    [ViaContainer container] -> do
        require "a container layer needs no target binary path" (Text.null targetBinary)
        admitted <- admittedContainer child container
        folded [ViaContainer admitted] "" inner InteractiveChannel
    [ViaVM vm] -> do
        binary <- sanitizedPath "the admitted target binary" targetBinary
        name <- sanitizedArgument "the admitted Incus instance" (Text.pack (vmName vm))
        folded [ViaVM vm{vmName = Text.unpack (admittedText name)}] (admittedPathText binary) inner NoninteractiveChannel
    [ViaLimaVM vm] -> do
        binary <- sanitizedPath "the admitted target binary" targetBinary
        name <- sanitizedArgument "the admitted Lima instance" (Text.pack (limaName vm))
        folded [ViaLimaVM vm{limaName = Text.unpack (admittedText name)}] (admittedPathText binary) inner NoninteractiveChannel
    [ViaWsl2VM vm] -> do
        binary <- sanitizedPath "the admitted target binary" targetBinary
        name <- sanitizedArgument "the admitted WSL distribution" (Text.pack (wsl2Distro vm))
        folded [ViaWsl2VM vm{wsl2Distro = Text.unpack (admittedText name)}] (admittedPathText binary) inner NoninteractiveChannel
    layers@(_ : _ : _) -> do
        AdmittedLayers admitted binary interactivity <- validateComposedLayers child layers targetBinary
        folded admitted (maybe "" admittedPathText binary) inner interactivity
    _ -> Left (routeFailure "a process route carries exactly one plan-owned lift layer")

{- | Validate the root-relative route used when the rooted reverse coordinator
must reach a descendant below its immediate child. Every constituent edge keeps
the same closed checks as a one-layer route; only a terminal container may make
the lifecycle binary path implicit.
-}
validateComposedLayers :: Text -> [LiftLayer] -> Text -> Either Text AdmittedLayers
validateComposedLayers child layers targetBinary = go layers
  where
    go [] = Left (routeFailure "a composed process route is empty")
    go [ViaContainer container] = do
        require "a container layer needs no target binary path" (Text.null targetBinary)
        admitted <- admittedContainer child container
        pure (AdmittedLayers [ViaContainer admitted] Nothing InteractiveChannel)
    go [ViaVM vm] = validateTerminalVm "Incus instance" (Text.pack (vmName vm)) (\name -> ViaVM vm{vmName = Text.unpack (admittedText name)})
    go [ViaLimaVM vm] = validateTerminalVm "Lima instance" (Text.pack (limaName vm)) (\name -> ViaLimaVM vm{limaName = Text.unpack (admittedText name)})
    go [ViaWsl2VM vm] = validateTerminalVm "WSL distribution" (Text.pack (wsl2Distro vm)) (\name -> ViaWsl2VM vm{wsl2Distro = Text.unpack (admittedText name)})
    go (ViaVM vm : rest) = do
        name <- sanitizedArgument "the admitted Incus instance" (Text.pack (vmName vm))
        AdmittedLayers admitted binary interactivity <- go rest
        pure (AdmittedLayers (ViaVM vm{vmName = Text.unpack (admittedText name)} : admitted) binary interactivity)
    go (ViaLimaVM vm : rest) = do
        name <- sanitizedArgument "the admitted Lima instance" (Text.pack (limaName vm))
        AdmittedLayers admitted binary interactivity <- go rest
        pure (AdmittedLayers (ViaLimaVM vm{limaName = Text.unpack (admittedText name)} : admitted) binary interactivity)
    go (ViaWsl2VM vm : rest) = do
        name <- sanitizedArgument "the admitted WSL distribution" (Text.pack (wsl2Distro vm))
        AdmittedLayers admitted binary interactivity <- go rest
        pure (AdmittedLayers (ViaWsl2VM vm{wsl2Distro = Text.unpack (admittedText name)} : admitted) binary interactivity)
    go (ViaContainer _ : _) =
        Left (routeFailure "a container layer is terminal in a composed process route")

    validateTerminalVm label name layer = do
        binary <- sanitizedPath "the admitted target binary" targetBinary
        admitted <- sanitizedArgument ("the admitted " <> label) name
        pure (AdmittedLayers [layer admitted] (Just binary) NoninteractiveChannel)

admittedContainer :: Text -> ContainerLift -> Either Text ContainerLift
admittedContainer child container = do
    require
        "the admitted container layer delivers a configuration on standard input"
        (isNothing (clConfigDelivery container))
    require
        "the admitted container layer carries plan-authored extra arguments"
        (null (clExtraArgs container))
    require
        "the admitted container layer outlives its own exchange"
        (clRemoveAfter container)
    frame <- sanitizedArgument "the admitted child frame" child
    image <- sanitizedArgument "the admitted container image" (Text.pack (clImage container))
    mounts <- traverse sanitizedMount (clMounts container)
    let placementArgs = case clPlacement container of
            ProviderGuestContainer -> []
            DirectHostContainer -> ["-e", "HOSTBOOTSTRAP_DIRECT_CONTAINER=linux-gpu"]
    pure
        container
            { clImage = Text.unpack (admittedText image)
            , clMounts = mounts
            , clExtraArgs =
                [ "-i"
                , "--network=host"
                , "-e"
                , "HOSTBOOTSTRAP_CURRENT_FRAME=" <> Text.unpack (admittedText frame)
                , "-e"
                , "HOSTBOOTSTRAP_REGISTRY_AUTH"
                ]
                    ++ placementArgs
                    ++ ["-w", "/"]
            }

folded :: [LiftLayer] -> Text -> [Text] -> ChannelInteractivity -> Either Text AdmittedLaunch
folded layers binary inner interactivity = do
    route <- case liftContextFromLayers layers of
        Left failure -> Left (routeFailure ("the sanitized lift context is invalid: " <> Text.pack failure))
        Right context -> Right context
    case foldLeaf route (lifecycleProcessLeaf (Text.unpack binary) (map Text.unpack inner)) of
        DispatchTool tool argv -> Right (AdmittedLaunch tool (map Text.pack argv) interactivity)
        _ -> Left (routeFailure "a process route must cross exactly one frame")

{- | Admit one bind mount for the shared Lift renderer, or refuse it.

Both halves must be absolute and free of the delimiter the rendered pair uses,
so a source or target cannot smuggle a further mount option past the colon.
-}
sanitizedMount :: Mount -> Either Text Mount
sanitizedMount mount = do
    from <- sanitizedPath "the admitted mount source" (source mount)
    to <- sanitizedPath "the admitted mount target" (target mount)
    pure (Mount (admittedPathText from) (admittedPathText to) (readOnly mount))

sanitizedPath :: Text -> Text -> Either Text ValidatedPath
sanitizedPath label value = do
    admitted <- admittedText <$> sanitizedArgument label value
    require (label <> " is not absolute") ("/" `Text.isPrefixOf` admitted)
    require (label <> " reaches outside itself") (".." `notElem` Text.splitOn "/" admitted)
    require (label <> " carries the mount delimiter") (not (Text.isInfixOf ":" admitted))
    pure (ValidatedPath admitted)

{- | Admit one derived argument against the closed grammar.

An argument that is empty, carries whitespace, or reads as an option is refused rather than
escaped, because a route that has to quote its own arguments is a route whose
shape is no longer fixed.
-}
sanitizedArgument :: Text -> Text -> Either Text ValidatedArgument
sanitizedArgument label value = do
    require (label <> " is empty") (not (Text.null value))
    require (label <> " carries whitespace") (not (Text.any isSpace value))
    require (label <> " reads as an option or a separator") (not ("-" `Text.isPrefixOf` value))
    pure (ValidatedArgument value)

{- | Borrow the launch this route renders, and nothing else.

The continuation receives the host tool and exact argument vector. The process
owner pipes standard input for every provider. It receives no frame, verb,
coordinate, or route value, and its result is fixed.
-}
withLifecycleProcessRouteLaunchKernel ::
    LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb ->
    (HostTool -> [Text] -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withLifecycleProcessRouteLaunchKernel #-}
withLifecycleProcessRouteLaunchKernel route use = case route of
    LifecycleProcessRoute _ _ _ tool argv _ -> use tool argv

{- | Raise this frame's own opening and admit the answer to it.

This is deliberately not a fold on the route. A route describes the child a
frame is about to launch; an opening belongs to the frame's own conversation
with the root, and those are different edges — the launch points down and the
session points up. A middle frame holds both at once, and giving one value
both would let a frame open a session for the child it is spawning rather than
for itself.

What a frame needs to open is therefore only what it already has: the nested
arm of its own installed runtime, which exists because an authenticated parent
edge produced it, and the independently installed verification key. A root arm
speaks for no authenticated frame and is refused, so a frame that nobody
admitted opens nothing here.

The only value a caller supplies beyond that is the fresh nonce. The request
built from it is the four-field 'OpenFrame' — the one shape in the protocol
carrying no path, session, stage, ordinal, or predecessor — and it travels
through the frame's own carrier to the root. The signed answer is verified
against the installed key and against those exact request bytes before one
field of it is read, and only an @Opened@ is admitted; every other family
leaves through a single refusal.

What the continuation receives is the exact request and the exact signed
response and nothing decoded. That pair is what a storeless frame executor is
built from, and the executor verifies both again for itself, so no coordinate
this module read becomes a coordinate the executor took on trust. Everything
after the opening — successor stages, ordinals, predecessors, and the closed
post-open request families — is the executor's, not this module's.
-}
withLifecycleChildOpeningKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    ProjectVerificationKey ->
    ByteString ->
    (ByteString -> IO (Either Text ByteString)) ->
    (ByteString -> ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withLifecycleChildOpeningKernel #-}
withLifecycleChildOpeningKernel runtime key nonce carry use =
    withNestedArmRecursiveHandoffRuntimeKernel runtime $ \_ _ _ _ _ _ admittedFrame ->
        case built admittedFrame of
            Left failure -> pure (Left failure)
            Right request -> do
                answered <- carry request
                case answered >>= admit request of
                    Left failure -> pure (Left failure)
                    Right signedOpened -> use request signedOpened
  where
    built admittedFrame = do
        require "the opening frame is empty" (not (Text.null admittedFrame))
        request <- either (Left . routeFailure) Right (rootedOpenFrameRequestKernel nonce)
        pure (renderRootedLifecycleRequestKernel request)

    admit request signedOpened = do
        verified <- verifiedResponse key request signedOpened
        withRootedLifecycleResponseKernel
            verified
            (\_ _ _ _ _ _ -> Right signedOpened)
            (\_ _ _ _ _ _ _ _ _ _ _ -> beforeOpened)
            (\_ _ _ _ _ _ _ _ -> beforeOpened)
            (\_ _ _ _ _ _ _ _ -> beforeOpened)
            (\_ _ _ _ _ _ _ _ -> beforeOpened)
            (\_ _ _ _ _ _ _ _ -> beforeOpened)
            (\_ _ _ _ _ _ _ _ -> beforeOpened)

    beforeOpened =
        Left (routeFailure "only a verified Opened response opens a lifecycle child frame")

-- | Turn signed bytes into a response only through the installed key.
verifiedResponse ::
    ProjectVerificationKey ->
    ByteString ->
    ByteString ->
    Either Text RootedLifecycleResponse
verifiedResponse key request signed =
    either
        (Left . routeFailure . Text.pack . handoffErrorMessage)
        Right
        (withVerifiedRootedLifecycleResponse key request signed id)

require :: Text -> Bool -> Either Text ()
require _ True = Right ()
require detail False = Left (routeFailure detail)

routeFailure :: Text -> Text
routeFailure detail = "lifecycle process route: " <> detail
