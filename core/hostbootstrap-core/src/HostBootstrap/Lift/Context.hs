{- | Pure execution-context vocabulary for the self-reference lift.

A context describes where a nested invocation runs; it performs no provider
discovery or mutation.  Provider lifecycle modules reuse the target records
and the three inner transport renderers below, so the command fold and the
lifecycle realizations cannot disagree about how a VM boundary is crossed.
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
    LiftContext (..),
    localContext,
    inVM,
    inLimaVM,
    inWsl2VM,
    inContainer,
    canonicalHostMount,

    -- * Inner transport rendering
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

-- | In-place child-config delivery for a container handoff.
data ConfigDelivery = ConfigDelivery
    { cdWritePath :: FilePath
    , cdExecPath :: FilePath
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

-- | A stack of context layers, outermost-first. The empty stack is local.
newtype LiftContext = LiftContext {liftLayers :: [LiftLayer]}
    deriving (Eq, Show)

-- | The local host: run the binary directly, with no lift.
localContext :: LiftContext
localContext = LiftContext []

-- | Nest an Incus VM as the new innermost layer.
inVM :: IncusVM -> LiftContext -> LiftContext
inVM vm (LiftContext layers) = LiftContext (layers ++ [ViaVM vm])

-- | Nest a Lima VM as the new innermost layer.
inLimaVM :: LimaVM -> LiftContext -> LiftContext
inLimaVM vm (LiftContext layers) = LiftContext (layers ++ [ViaLimaVM vm])

-- | Nest a WSL2 distribution as the new innermost layer.
inWsl2VM :: Wsl2VM -> LiftContext -> LiftContext
inWsl2VM vm (LiftContext layers) = LiftContext (layers ++ [ViaWsl2VM vm])

-- | Nest a terminal container as the new innermost layer.
inContainer :: ContainerLift -> LiftContext -> LiftContext
inContainer container (LiftContext layers) =
    LiftContext (layers ++ [ViaContainer container])

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

-- | @incus exec <name> -- <cmd...>@.
execVMArgs :: IncusVM -> [String] -> [String]
execVMArgs vm command = ["exec", vmName vm, "--"] ++ command

-- | Execute a command inside a Lima VM as root.
shellVMArgs :: LimaVM -> [String] -> [String]
shellVMArgs vm command =
    ["shell", limaName vm, "--", "sudo", "-H"] ++ command

-- | @wsl -d <distro> -- <cmd...>@.
wslExecArgs :: String -> [String] -> [String]
wslExecArgs distro command = ["-d", distro, "--"] ++ command
