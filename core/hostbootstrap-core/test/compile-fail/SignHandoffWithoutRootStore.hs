module SignHandoffWithoutRootStore where

import HostBootstrap.Handoff

-- Grant issuance is an effectful transition in the root broker's captured store.
-- It cannot be used as a pure signature over a caller-selected transcript.
unsafeSign ::
    RootBroker scope brokerGeneration verb ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    HandoffGrant scope brokerGeneration
unsafeSign broker offer challenge = grantHandoff broker offer challenge
