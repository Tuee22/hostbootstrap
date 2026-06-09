module Main where

import Prelude

import Data.Argonaut.Decode (decodeJson)
import Data.Argonaut.Parser (jsonParser)
import Data.Either (hush)
import Data.Maybe (Maybe(..))
import Data.Newtype (unwrap)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Aff.Class (class MonadAff, liftAff)
import Fetch (fetch)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)
import HostBootstrapDemo.Web.Api (BudgetView)

-- | The three SPA tabs the Playwright e2e drives.
data Tab = Overview | Budget | Status

derive instance eqTab :: Eq Tab

tabName :: Tab -> String
tabName Overview = "Overview"
tabName Budget = "Budget"
tabName Status = "Status"

type State = { tab :: Tab, budget :: Maybe BudgetView }

data Action = Select Tab | Init

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  void (runUI component unit body)

component :: forall q i o m. MonadAff m => H.Component q i o m
component =
  H.mkComponent
    { initialState: \_ -> { tab: Overview, budget: Nothing }
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handleAction, initialize = Just Init }
    }

render :: forall m. State -> H.ComponentHTML Action () m
render st =
  HH.div_
    [ HH.h1_ [ HH.text "hostbootstrap-demo" ]
    , HH.div [ HP.id "tabs" ] (map tabButton [ Overview, Budget, Status ])
    , HH.div [ HP.id "content" ] [ content ]
    ]
  where
  tabButton t =
    HH.button
      [ HP.class_ (HH.ClassName "tab"), HE.onClick \_ -> Select t ]
      [ HH.text (tabName t) ]
  content = case st.budget of
    Nothing -> HH.p [ HP.id "loading" ] [ HH.text "loading…" ]
    Just bv ->
      let b = unwrap bv
       in case st.tab of
            Overview ->
              HH.p [ HP.id "overview" ]
                [ HH.text ("budget " <> show b.cpu <> " cpu / " <> show b.memory <> " GiB / " <> show b.storage <> " GiB") ]
            Budget ->
              HH.p [ HP.id "fits" ]
                [ HH.text ("fits: " <> show b.fits) ]
            Status ->
              HH.p [ HP.id "status" ]
                [ HH.text ("pods " <> show b.podReplicas <> " x (cpu " <> show b.podCpuLimit <> ", mem " <> show b.podMemoryLimit <> ")") ]

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Init -> do
    mb <- liftAff fetchBudget
    H.modify_ _ { budget = mb }
  Select t -> H.modify_ _ { tab = t }

-- | Fetch and decode @GET /api/budget@ into the bridged 'BudgetView'.
fetchBudget :: Aff (Maybe BudgetView)
fetchBudget = do
  resp <- fetch "/api/budget" {}
  t <- resp.text
  pure (hush (jsonParser t) >>= (hush <<< decodeJson))
