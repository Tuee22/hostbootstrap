module CoerceVerifiedRecoveryWireRoles where

import Data.Coerce (coerce)
import HostBootstrap.Handoff (VerifiedRecoveryWire)

data ScopeA
data ScopeB
data BrokerA
data BrokerB
data VerbA
data VerbB
data PlanA
data PlanB
data FrameA
data FrameB
data DigestA
data DigestB
data WireA
data WireB

type Wire scope broker verb plan frame digest wireId =
    VerifiedRecoveryWire scope broker verb plan frame digest wireId

wrongScope :: Wire ScopeA BrokerA VerbA PlanA FrameA DigestA WireA -> Wire ScopeB BrokerA VerbA PlanA FrameA DigestA WireA
wrongScope = coerce

wrongBroker :: Wire ScopeA BrokerA VerbA PlanA FrameA DigestA WireA -> Wire ScopeA BrokerB VerbA PlanA FrameA DigestA WireA
wrongBroker = coerce

wrongVerb :: Wire ScopeA BrokerA VerbA PlanA FrameA DigestA WireA -> Wire ScopeA BrokerA VerbB PlanA FrameA DigestA WireA
wrongVerb = coerce

wrongPlan :: Wire ScopeA BrokerA VerbA PlanA FrameA DigestA WireA -> Wire ScopeA BrokerA VerbA PlanB FrameA DigestA WireA
wrongPlan = coerce

wrongFrame :: Wire ScopeA BrokerA VerbA PlanA FrameA DigestA WireA -> Wire ScopeA BrokerA VerbA PlanA FrameB DigestA WireA
wrongFrame = coerce

wrongDigest :: Wire ScopeA BrokerA VerbA PlanA FrameA DigestA WireA -> Wire ScopeA BrokerA VerbA PlanA FrameA DigestB WireA
wrongDigest = coerce

wrongWire :: Wire ScopeA BrokerA VerbA PlanA FrameA DigestA WireA -> Wire ScopeA BrokerA VerbA PlanA FrameA DigestA WireB
wrongWire = coerce
