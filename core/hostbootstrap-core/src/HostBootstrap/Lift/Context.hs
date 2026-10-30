{- | Pure execution-context vocabulary for the self-reference lift.

A context describes where a nested invocation runs; it performs no provider
discovery or mutation. The command fold and lifecycle channel render every VM
crossing through the same three pure transport renderers, differing only in
the placement they pass. Provider modules reuse these target records and
renderers from the lower vocabulary.
-}
module HostBootstrap.Lift.Context (
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

    -- * Inner transport rendering
    VMPlacement (..),
    foldPlacement,
    lifecyclePlacement,
    execVMArgsAt,
    shellVMArgsAt,
    wslExecArgsAt,
    execVMArgs,
    shellVMArgs,
    wslExecArgs,
)
where

import qualified Data.Text as T
import HostBootstrap.Config.Vocab (Mount)
import qualified HostBootstrap.Config.Vocab as Vocab
import HostBootstrap.ProjectRoot (
    CanonicalHostPath,
    CanonicalProjectRoot,
    canonicalHostPathValue,
 )

{- | An Incus VM: its name and the image it launches from
(e.g. @"images:ubuntu/24.04"@).
-}
data IncusVM = IncusVM
    { vmName :: String
    , vmImage :: String
    }
    deriving (Eq, Show)

-- | A Lima-backed Linux VM, identified by its Lima instance name.
newtype LimaVM = LimaVM
    { limaName :: String
    }
    deriving (Eq, Show)

-- | A WSL2-backed Linux VM, identified by its distribution name.
newtype Wsl2VM = Wsl2VM
    { wsl2Distro :: String
    }
    deriving (Eq, Show)

-- | The filesystem projection copied into a container before its entry point starts.
data ConfigDelivery = ConfigDelivery
    { cdWritePath :: FilePath
    , cdPayload :: T.Text
    }
    deriving (Eq, Show)

-- | The closed provider placement of a container boundary.
data ContainerPlacement = ProviderGuestContainer | DirectHostContainer
    deriving (Eq, Show)

-- | A @docker run@ container layer.
data ContainerLift = ContainerLift
    { clImage :: String
    , clPlacement :: ContainerPlacement
    , clMounts :: [Mount]
    , clExtraArgs :: [String]
    , clRemoveAfter :: Bool
    , clConfigDelivery :: Maybe ConfigDelivery
    }
    deriving (Eq, Show)

-- | One context-boundary layer: a VM provider or a container.
data LiftLayer
    = ViaVM IncusVM
    | ViaLimaVM LimaVM
    | ViaWsl2VM Wsl2VM
    | ViaContainer ContainerLift
    deriving (Eq, Show)

-- | A closed VM stack with at most one terminal container.
data LiftContext = LiftContext VMStack (Maybe ContainerLift)
    deriving (Eq)

instance Show LiftContext where
    showsPrec precedence context =
        showParen (precedence > 10) $
            showString "LiftContext {liftLayers = "
                . shows (liftLayers context)
                . showString "}"

-- | The complete context layers, outermost-first.
liftLayers :: LiftContext -> [LiftLayer]
liftLayers (LiftContext (VMStack prefix) container) =
    prefix ++ maybe [] (\terminal -> [ViaContainer terminal]) container

-- | The open VM prefix retained by a closed context.
liftVMStack :: LiftContext -> VMStack
liftVMStack (LiftContext stack _) = stack

-- | An open stack of VM crossings, outermost-first.
newtype VMStack = VMStack [LiftLayer]
    deriving (Eq, Show)

-- | Start an open stack with no VM crossings.
emptyVMStack :: VMStack
emptyVMStack = VMStack []

-- | Close an open VM stack as a VM-only execution context.
vmContext :: VMStack -> LiftContext
vmContext stack = LiftContext stack Nothing

{- | Admit VM crossings followed by at most one terminal container. The original
layer order and spelling are retained. Duplicate containers take refusal
precedence when the list also places a VM after a container.
-}
liftContextFromLayers :: [LiftLayer] -> Either String LiftContext
liftContextFromLayers layers = do
    (prefix, container) <- splitLiftLayers layers
    Right (LiftContext (VMStack prefix) container)

-- | Project the optional terminal container retained by this context.
terminalContainer :: LiftContext -> Maybe ContainerLift
terminalContainer (LiftContext _ container) = container

{- | Change only the terminal container, retaining its VM prefix. A VM-only
context is unchanged without applying the function.
-}
mapTerminalContainer :: (ContainerLift -> ContainerLift) -> LiftContext -> LiftContext
mapTerminalContainer change (LiftContext stack container) =
    LiftContext stack (fmap change container)

splitLiftLayers :: [LiftLayer] -> Either String ([LiftLayer], Maybe ContainerLift)
splitLiftLayers [] = Right ([], Nothing)
splitLiftLayers (layer : rest) = case layer of
    ViaVM _ -> prepend
    ViaLimaVM _ -> prepend
    ViaWsl2VM _ -> prepend
    ViaContainer container
        | null rest -> Right ([], Just container)
        | any isContainer rest -> Left "lift context contains more than one container layer"
        | otherwise -> Left "lift context contains a VM layer after a container"
  where
    prepend = do
        (prefix, terminal) <- splitLiftLayers rest
        Right (layer : prefix, terminal)
    isContainer ViaVM{} = False
    isContainer ViaLimaVM{} = False
    isContainer ViaWsl2VM{} = False
    isContainer ViaContainer{} = True

-- | The local host: run the binary directly, with no lift.
localContext :: LiftContext
localContext = vmContext emptyVMStack

-- | Nest an Incus VM as the new innermost layer.
inVM :: IncusVM -> VMStack -> VMStack
inVM vm (VMStack layers) = VMStack (layers ++ [ViaVM vm])

-- | Nest a Lima VM as the new innermost layer.
inLimaVM :: LimaVM -> VMStack -> VMStack
inLimaVM vm (VMStack layers) = VMStack (layers ++ [ViaLimaVM vm])

-- | Nest a WSL2 distribution as the new innermost layer.
inWsl2VM :: Wsl2VM -> VMStack -> VMStack
inWsl2VM vm (VMStack layers) = VMStack (layers ++ [ViaWsl2VM vm])

-- | Close an open VM stack with one terminal container.
inContainer :: ContainerLift -> VMStack -> LiftContext
inContainer container stack = LiftContext stack (Just container)

-- | Build a container mount from one exact canonical project root.
canonicalHostMount ::
    CanonicalProjectRoot scope rootId ->
    CanonicalHostPath scope rootId ->
    FilePath ->
    Bool ->
    Mount
canonicalHostMount _ hostPath containerPath readOnly =
    Vocab.Mount
        (T.pack (canonicalHostPathValue hostPath))
        (T.pack containerPath)
        readOnly

-- | Placement of an invocation within one VM crossing.
data VMPlacement = VMPlacement
    { placementWorkdir :: Maybe FilePath
    , placementNonInteractive :: Bool
    , placementElevated :: Bool
    }
    deriving (Eq, Show)

-- | Ordinary invocation, retaining the guest's working directory and user.
foldPlacement :: VMPlacement
foldPlacement = VMPlacement Nothing False False

-- | The root, noninteractive invocation used by the lifecycle channel.
lifecyclePlacement :: VMPlacement
lifecyclePlacement = VMPlacement (Just "/") True True

-- | Incus already invokes the command as root, independently of elevation.
execVMArgsAt :: VMPlacement -> IncusVM -> [String] -> [String]
execVMArgsAt placement vm command =
    ["exec", vmName vm]
        ++ maybe [] (\directory -> ["--cwd", directory]) (placementWorkdir placement)
        ++ ["-T" | placementNonInteractive placement]
        ++ ["--"]
        ++ command

-- | Place an invocation in Lima, elevating only when requested.
shellVMArgsAt :: VMPlacement -> LimaVM -> [String] -> [String]
shellVMArgsAt placement vm command =
    ["shell"]
        ++ maybe [] (\directory -> ["--workdir", directory]) (placementWorkdir placement)
        ++ [limaName vm, "--"]
        ++ elevationArgs placement
        ++ command

-- | Place an argv in WSL2 without the distribution's default shell.
wslExecArgsAt :: VMPlacement -> String -> [String] -> [String]
wslExecArgsAt placement distro command =
    ["-d", distro]
        ++ maybe [] (\directory -> ["--cd", directory]) (placementWorkdir placement)
        ++ ["--exec"]
        ++ elevationArgs placement
        ++ command

elevationArgs :: VMPlacement -> [String]
elevationArgs placement
    | placementElevated placement =
        ["sudo"] ++ ["-n" | placementNonInteractive placement] ++ ["-H"]
    | otherwise = []

-- | @incus exec <name> -- <cmd...>@.
execVMArgs :: IncusVM -> [String] -> [String]
execVMArgs = execVMArgsAt foldPlacement

-- | Execute a command inside a Lima VM as root.
shellVMArgs :: LimaVM -> [String] -> [String]
shellVMArgs = shellVMArgsAt (foldPlacement{placementElevated = True})

-- | @wsl -d <distro> --exec <cmd...>@, without the distribution's default shell.
wslExecArgs :: String -> [String] -> [String]
wslExecArgs = wslExecArgsAt foldPlacement
