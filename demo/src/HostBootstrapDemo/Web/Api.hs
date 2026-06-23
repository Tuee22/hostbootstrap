{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}

{- | The hostbootstrap-demo webservice API types.

'BudgetView' is the single response type the SPA renders and the e2e suite
asserts: the project's resource budget, the concurrent pod footprint, and
whether the pods fit — computed by the same canonical 'fitsBudget' the cluster
bring-up uses, so the served value cannot disagree with the cordon. The type is
the source the @web bridge@ verb reflects into PureScript (so the SPA's types
match the API by construction) and the JSON the @web serve@ verb returns.
-}
module HostBootstrapDemo.Web.Api (
    BudgetView (..),
    budgetView,
)
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import HostBootstrap.Cluster.Cordon (fitsBudget)
import qualified HostBootstrap.Config.Vocab as V

{- | The webservice's one view: the config-driven served @message@ (the worked
example, Sprint 20.1), the demo budget, the concurrent web-pod footprint, and the
fits-within verdict.
-}
data BudgetView = BudgetView
    { message :: Text
    , cpu :: Int
    , memory :: Int
    , storage :: Int
    , podReplicas :: Int
    , podCpuLimit :: Int
    , podMemoryLimit :: Int
    , fits :: Bool
    }
    deriving (Eq, Show, Generic, ToJSON, FromJSON)

{- | The demo's declared budget (mirrors the host-level
@hostbootstrap-demo.dhall@: 6 cpu, 10 GiB, 80 GiB) as the vocabulary
'V.Budget'.
-}
demoBudget :: V.Budget
demoBudget = V.Budget 6 10 80

-- | The demo's concurrent web-pod set (the @demoWeb@ schema-gen artifact).
demoPods :: [V.PodResources]
demoPods = [V.PodResources 2 1 1 1 2]

{- | The canonical budget view, parameterized by the config-driven served
@message@ (Sprint 20.1): the fits verdict is the real 'fitsBudget' result, so
@GET /api/budget@ agrees with the bring-up cordon.
-}
budgetView :: Text -> BudgetView
budgetView msg =
    BudgetView
        { message = msg
        , cpu = fromIntegral demoBudget.cpu
        , memory = fromIntegral demoBudget.memory
        , storage = fromIntegral demoBudget.storage
        , podReplicas = 2
        , podCpuLimit = 1
        , podMemoryLimit = 2
        , fits = either (const False) (const True) (fitsBudget demoBudget demoPods)
        }
