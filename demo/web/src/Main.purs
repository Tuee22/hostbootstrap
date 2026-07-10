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
import HostBootstrapDemo.Web.Api (AcceleratorAddFailure(..), AcceleratorAddResult, BudgetView)

-- | The three SPA tabs the Playwright e2e drives.
data Tab = Overview | Budget | Status | Accelerator

derive instance eqTab :: Eq Tab

tabName :: Tab -> String
tabName Overview = "Overview"
tabName Budget = "Budget"
tabName Status = "Status"
tabName Accelerator = "Accelerator"

data AcceleratorState
  = AcceleratorIdle
  | AcceleratorPending
  | AcceleratorSuccess AcceleratorAddResult
  | AcceleratorError AcceleratorAddFailure

type State =
  { tab :: Tab
  , budget :: Maybe BudgetView
  , addLeft :: String
  , addRight :: String
  , accelerator :: AcceleratorState
  }

data Action
  = Select Tab
  | Init
  | SetAddLeft String
  | SetAddRight String
  | SubmitAdd

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  void (runUI component unit body)

component :: forall q i o m. MonadAff m => H.Component q i o m
component =
  H.mkComponent
    { initialState: \_ -> { tab: Overview, budget: Nothing, addLeft: "1.5", addRight: "2.25", accelerator: AcceleratorIdle }
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handleAction, initialize = Just Init }
    }

render :: forall m. State -> H.ComponentHTML Action () m
render st =
  HH.div_
    [ HH.h1_ [ HH.text "hostbootstrap-demo" ]
    , HH.p [ HP.id "message" ] [ HH.text message ]
    , HH.div [ HP.id "tabs" ] (map tabButton [ Overview, Budget, Status, Accelerator ])
    , HH.div [ HP.id "content" ] [ content ]
    ]
  where
  -- The config-driven served message (Sprint 20.1), rendered in a stable shell
  -- element the polymorphic Playwright asserts EXPECTED_MESSAGE against. Empty
  -- until the budget view loads.
  message = case st.budget of
    Nothing -> ""
    Just bv -> (unwrap bv).message
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
            Accelerator ->
              acceleratorPanel st

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Init -> do
    mb <- liftAff fetchBudget
    H.modify_ _ { budget = mb }
  Select t -> H.modify_ _ { tab = t }
  SetAddLeft value -> H.modify_ _ { addLeft = value }
  SetAddRight value -> H.modify_ _ { addRight = value }
  SubmitAdd -> do
    st <- H.get
    H.modify_ _ { accelerator = AcceleratorPending }
    result <- liftAff (fetchAcceleratorAdd st.addLeft st.addRight)
    H.modify_ _ { accelerator = result }

-- | Fetch and decode @GET /api/budget@ into the bridged 'BudgetView'.
fetchBudget :: Aff (Maybe BudgetView)
fetchBudget = do
  resp <- fetch "/api/budget" {}
  t <- resp.text
  pure (hush (jsonParser t) >>= (hush <<< decodeJson))

acceleratorPanel :: forall m. State -> H.ComponentHTML Action () m
acceleratorPanel st =
  HH.div [ HP.id "accelerator" ]
    [ HH.input
        [ HP.id "add-left"
        , HP.type_ HP.InputNumber
        , HP.value st.addLeft
        , HE.onValueInput SetAddLeft
        ]
    , HH.input
        [ HP.id "add-right"
        , HP.type_ HP.InputNumber
        , HP.value st.addRight
        , HE.onValueInput SetAddRight
        ]
    , HH.button
        [ HP.id "add-button", HE.onClick \_ -> SubmitAdd ]
        [ HH.text "Add" ]
    , acceleratorRender st.accelerator
    ]

acceleratorRender :: forall m. AcceleratorState -> H.ComponentHTML Action () m
acceleratorRender = case _ of
  AcceleratorIdle ->
    HH.p [ HP.id "accelerator-state" ] [ HH.text "idle" ]
  AcceleratorPending ->
    HH.p [ HP.id "accelerator-state" ] [ HH.text "pending" ]
  AcceleratorSuccess result ->
    let r = unwrap result
     in HH.div [ HP.id "accelerator-result" ]
          [ HH.p [ HP.id "add-result" ] [ HH.text (show r.result) ]
          , HH.p [ HP.id "add-backend" ] [ HH.text r.backend ]
          , HH.p [ HP.id "add-artifact" ] [ HH.text r.artifactHash ]
          ]
  AcceleratorError failure ->
    let f = unwrap failure
     in HH.div [ HP.id "accelerator-error" ]
          [ HH.p [ HP.id "add-error" ] [ HH.text f.failureMessage ]
          , HH.p [ HP.id "add-backend" ] [ HH.text f.backend ]
          , HH.p [ HP.id "add-artifact" ] [ HH.text f.artifactHash ]
          ]

fetchAcceleratorAdd :: String -> String -> Aff AcceleratorState
fetchAcceleratorAdd left right = do
  resp <- fetch ("/api/accelerator/add?requestId=web-ui&left=" <> left <> "&right=" <> right) {}
  t <- resp.text
  pure (parseAcceleratorResponse t)

parseAcceleratorResponse :: String -> AcceleratorState
parseAcceleratorResponse raw =
  case hush (jsonParser raw) of
    Nothing -> AcceleratorError parseFailure
    Just json ->
      case (hush (decodeJson json) :: Maybe AcceleratorAddResult) of
        Just result -> AcceleratorSuccess result
        Nothing ->
          case (hush (decodeJson json) :: Maybe AcceleratorAddFailure) of
            Just failure -> AcceleratorError failure
            Nothing -> AcceleratorError parseFailure
  where
  parseFailure =
    AcceleratorAddFailure
      { requestId: "web-ui"
      , failureMessage: "invalid accelerator response"
      , backend: "client"
      , artifactHash: ""
      }
