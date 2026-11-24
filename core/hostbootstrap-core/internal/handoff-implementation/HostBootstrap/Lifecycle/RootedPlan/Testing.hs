{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Private fault injection for catalog boundary tests. Never exposed to consumers.
module HostBootstrap.Lifecycle.RootedPlan.Testing (CatalogDrift (..), driftCatalogEdge) where

import qualified Data.ByteString as ByteString
import Data.Text (Text)
import HostBootstrap.Lifecycle.RootedPlan (RootedPlanCatalog, withRootedPlanCatalogRootKernel)
import HostBootstrap.Lifecycle.RootedPlan.Internal (ConfigDigest (..), PayloadDigest (..), RootedPlanCatalog (..), StrippedLiftRoute (..))
import HostBootstrap.Lift.Context (IncusVM (IncusVM), LiftLayer (ViaVM), liftContextFromLayers, liftLayers, localContext)
import Unsafe.Coerce (unsafeCoerce)

-- Each alternative changes only the evidence needed to reach one recheck.
data CatalogDrift
    = ChildFrameDrift
    | ConfigEndpointDrift
    | ConfigDigestDrift
    | PayloadDigestDrift
    | PayloadBytesDrift
    | PlanBindingDrift
    | RouteDrift
    | ComposedRouteDrift
    deriving (Eq, Show, Enum, Bounded)

driftCatalogEdge :: CatalogDrift -> RootedPlanCatalog scope rootPlanId brokerGeneration catalogId -> RootedPlanCatalog scope rootPlanId brokerGeneration catalogId
driftCatalogEdge drift catalog =
    case catalog of
        RootedPlanCatalogRoot{} -> error "catalog fault injection requires a descent"
        RootedPlanCatalogDescent ancestors plan binding current parent child raw route payload configDigest payloadDigest keys ->
            withRootedPlanCatalogRootKernel catalog $ \_ _ rootPlan rootCurrent _ ->
                let targetPlan = case drift of
                        ConfigEndpointDrift -> unsafeCoerce rootPlan
                        _ -> plan
                    targetCurrent = case drift of
                        ChildFrameDrift -> unsafeCoerce rootCurrent
                        _ -> current
                    targetBinding = case drift of
                        PlanBindingDrift -> unsafeCoerce ("test-foreign-plan-digest" :: Text)
                        _ -> binding
                    targetConfigDigest = case drift of
                        ConfigDigestDrift -> let ConfigDigest digest = configDigest in ConfigDigest (digest <> "-drift")
                        _ -> configDigest
                    targetPayloadDigest = case drift of
                        PayloadDigestDrift -> let PayloadDigest digest = payloadDigest in PayloadDigest (digest <> "-drift")
                        _ -> payloadDigest
                    targetPayload = case drift of
                        PayloadBytesDrift -> ByteString.snoc payload 0
                        _ -> payload
                    targetRoute = case drift of
                        RouteDrift -> StrippedLiftRoute localContext
                        ComposedRouteDrift ->
                            let StrippedLiftRoute stripped = route
                             in StrippedLiftRoute (either error id (liftContextFromLayers (ViaVM (IncusVM "outer" "fixture") : liftLayers stripped)))
                        _ -> route
                 in RootedPlanCatalogDescent ancestors targetPlan targetBinding targetCurrent parent child raw targetRoute targetPayload targetConfigDigest targetPayloadDigest keys
