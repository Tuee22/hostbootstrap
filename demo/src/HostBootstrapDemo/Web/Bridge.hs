{- | The @web bridge@ codegen: reflect the webservice API types into PureScript
via @purescript-bridge@ (warmed in the base image's @core.freeze@), so the
Halogen SPA's types match the Haskell API by construction rather than by hand.
-}
module HostBootstrapDemo.Web.Bridge (
    writeBridge,
)
where

import Data.Proxy (Proxy (..))
import HostBootstrapDemo.Web.Api (BudgetView)
import Language.PureScript.Bridge (
    buildBridge,
    defaultBridge,
    mkSumType,
    writePSTypes,
 )

-- | Write the PureScript mirror of 'BudgetView' (and its closure) into @dir@.
writeBridge :: FilePath -> IO ()
writeBridge dir = do
    writePSTypes dir (buildBridge defaultBridge) [mkSumType (Proxy :: Proxy BudgetView)]
    putStrLn ("web bridge: wrote PureScript types (BudgetView) to " ++ dir)
