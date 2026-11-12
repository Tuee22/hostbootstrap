{- | Typed host configuration: the detected substrate plus the resolved
absolute paths of the host tools.

This is the value the resolver and the @ensure@ reconcilers read. Tools are
resolved once into 'hcToolPaths'; thereafter every invocation reads an
absolute 'AbsExe' from this typed configuration rather than a @$PATH@-resolved
bare name (see @development_plan_standards.md § K@).
-}
module HostBootstrap.HostConfig (
    HostConfig (..),
    HostToolError (..),
    buildHostConfig,
    resolve,
    resolveMaybe,
    resolveInstalled,
)
where

import Control.Exception (Exception, displayException, throwIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import HostBootstrap.HostTool (
    AbsExe,
    HostTool,
    allHostTools,
    discover,
    toolCommandName,
 )
import HostBootstrap.Substrate (Substrate)

-- | The typed host configuration.
data HostConfig = HostConfig
    { hcSubstrate :: Substrate
    , hcToolPaths :: Map HostTool AbsExe
    }
    deriving (Eq, Show)

-- | A host tool was requested but not resolved into the configuration.
newtype HostToolError = UnresolvedTool HostTool
    deriving (Eq, Show)

instance Exception HostToolError where
    displayException (UnresolvedTool tool) =
        "host tool not resolved: " ++ toolCommandName tool ++ " (not found on this host)"

{- | Build a host configuration for a substrate by discovering every tool's
absolute path. Tools that are not installed are simply absent from the map;
a reconciler that needs one probes it via 'resolveMaybe' and fails fast
through 'installAndVerify' if it stays missing after the install plan.
-}
buildHostConfig :: Substrate -> IO HostConfig
buildHostConfig substrate = do
    resolved <- mapM discoverPair allHostTools
    pure
        HostConfig
            { hcSubstrate = substrate
            , hcToolPaths = Map.fromList (mapMaybe sequenceSnd resolved)
            }
  where
    discoverPair tool = do
        mPath <- discover tool
        pure (tool, mPath)
    sequenceSnd (tool, mPath) = fmap (\p -> (tool, p)) mPath

{- | Resolve a tool to its absolute path, throwing 'HostToolError' when the tool
is not present in the configuration.
-}
resolve :: HostConfig -> HostTool -> IO AbsExe
resolve cfg tool = case resolveMaybe cfg tool of
    Just exe -> pure exe
    Nothing -> throwIO (UnresolvedTool tool)

-- | Pure lookup of a resolved tool path.
resolveMaybe :: HostConfig -> HostTool -> Maybe AbsExe
resolveMaybe cfg tool = Map.lookup tool (hcToolPaths cfg)

{- | Resolve a tool that an @ensure@ reconciler may have installed *after* this
configuration was measured.

'hcToolPaths' is measured once, at the start of an invocation, which is the
property that makes every later call read a typed absolute path instead of
consulting @$PATH@ (§ K). On a host that already has its tools that is the whole
story. On a **pristine** host it is not: the chain's own @ensure@ step installs
the provider partway through the same invocation, and every consumer still
holding the configuration measured before it sees the tool as absent. The
authenticated descent hit exactly that — it refused with "the route's host tool
resolves to no absolute path" on a host where the provider VM it was about to
descend into had just been created by that very tool.

This resolves from the typed configuration first and only re-measures the host
when the configuration has no entry, so a tool that was present keeps its
recorded path and cannot be silently replaced mid-invocation. What it never does
is hand a bare command name to anything: 'discover' answers with an absolute
'AbsExe' or with nothing, so the § K contract holds on both branches.
-}
resolveInstalled :: HostConfig -> HostTool -> IO (Maybe AbsExe)
resolveInstalled cfg tool = case resolveMaybe cfg tool of
    Just exe -> pure (Just exe)
    Nothing -> discover tool
