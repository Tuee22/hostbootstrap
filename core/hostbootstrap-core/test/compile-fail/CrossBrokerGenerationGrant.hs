module CrossBrokerGenerationGrant (grantForeignGeneration) where

import HostBootstrap.Handoff

grantForeignGeneration ::
    RootBroker scope brokerGenerationA verb ->
    HandoffOffer scope brokerGenerationB ->
    HandoffChallenge ->
    IO (Either HandoffError (HandoffGrant scope brokerGenerationA))
grantForeignGeneration broker offer challenge =
    HostBootstrap.Handoff.grantHandoff broker offer challenge
