-- | The closed enumeration of external tools and their absolute-path
-- resolution.
--
-- Host-tool resolution doctrine (see @development_plan_standards.md § K@): every
-- external tool is a constructor of the closed 'HostTool' type, and every
-- invocation reads an absolute path. The 'AbsExe' newtype makes a bare command
-- name unrepresentable as a resolved tool — the smart constructor 'mkAbsExe'
-- rejects relative paths. Bare command names are used only for discovery
-- ('toolCommandName' / 'discover'), never for invocation.
module HostBootstrap.HostTool
  ( HostTool (..),
    allHostTools,
    toolCommandName,
    AbsExe,
    absExePath,
    mkAbsExe,
    discover,
  )
where

import System.Directory (findExecutable)
import System.FilePath (isAbsolute)

-- | The closed set of external tools @hostbootstrap-core@ resolves.
data HostTool
  = Docker
  | Colima
  | Brew
  | Ghc
  | Ghcup
  | Kubectl
  | Helm
  | Kind
  | NvidiaSmi
  | Tart
  | Sudo
  | XcodeSelect
  | Incus
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Every host tool, for building a fully-resolved 'HostBootstrap.HostConfig'.
allHostTools :: [HostTool]
allHostTools = [minBound .. maxBound]

-- | The bare command name. Used only to discover the absolute path; never used
-- as a @$PATH@-resolved invocation target.
toolCommandName :: HostTool -> String
toolCommandName Docker = "docker"
toolCommandName Colima = "colima"
toolCommandName Brew = "brew"
toolCommandName Ghc = "ghc"
toolCommandName Ghcup = "ghcup"
toolCommandName Kubectl = "kubectl"
toolCommandName Helm = "helm"
toolCommandName Kind = "kind"
toolCommandName NvidiaSmi = "nvidia-smi"
toolCommandName Tart = "tart"
toolCommandName Sudo = "sudo"
toolCommandName XcodeSelect = "xcode-select"
toolCommandName Incus = "incus"

-- | An absolute path to a resolved executable. The constructor is not exported;
-- 'mkAbsExe' is the only way to build one, so a value of this type is always an
-- absolute path.
newtype AbsExe = AbsExe {absExePath :: FilePath}
  deriving (Eq, Ord, Show)

-- | Build an 'AbsExe', rejecting anything that is not an absolute path (in
-- particular a bare command name).
mkAbsExe :: FilePath -> Either String AbsExe
mkAbsExe fp
  | isAbsolute fp = Right (AbsExe fp)
  | otherwise = Left ("not an absolute path: " ++ fp)

-- | Discover a tool's absolute path. 'System.Directory.findExecutable' returns
-- an absolute path when the command is found on the search path; the result is
-- re-validated through 'mkAbsExe' so a non-absolute hit is rejected.
discover :: HostTool -> IO (Maybe AbsExe)
discover tool = do
  found <- findExecutable (toolCommandName tool)
  pure $ case found of
    Nothing -> Nothing
    Just fp -> either (const Nothing) Just (mkAbsExe fp)
