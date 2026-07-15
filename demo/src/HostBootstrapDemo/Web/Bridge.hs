{-# LANGUAGE OverloadedStrings #-}

{- | The @web bridge@ codegen: reflect the webservice API types into PureScript
via @purescript-bridge@ (warmed in the base image's @core.freeze@), so the
Halogen SPA's types match the Haskell API by construction rather than by hand.
-}
module HostBootstrapDemo.Web.Bridge (
    writeBridge,
)
where

import Control.Applicative ((<|>))
import Data.Proxy (Proxy (..))
import HostBootstrapDemo.Web.Api (AcceleratorAddFailure, AcceleratorAddResult, BudgetView)
import Language.PureScript.Bridge (
    BridgePart,
    buildBridge,
    defaultBridge,
    mkSumType,
    typeName,
    writePSTypes,
    (^==),
 )
import Language.PureScript.Bridge.PSTypes (psNumber)

floatBridge :: BridgePart
floatBridge = typeName ^== "Float" >> pure psNumber

-- | Write the PureScript mirror of 'BudgetView' (and its closure) into @dir@.
writeBridge :: FilePath -> IO ()
writeBridge dir = do
    writePSTypes
        dir
        (buildBridge (defaultBridge <|> floatBridge))
        [ mkSumType (Proxy :: Proxy BudgetView)
        , mkSumType (Proxy :: Proxy AcceleratorAddResult)
        , mkSumType (Proxy :: Proxy AcceleratorAddFailure)
        ]
    putStrLn ("web bridge: wrote PureScript types (BudgetView, AcceleratorAddResult, AcceleratorAddFailure) to " ++ dir)
