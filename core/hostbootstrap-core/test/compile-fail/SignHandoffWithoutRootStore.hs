module SignHandoffWithoutRootStore where

import HostBootstrap.Handoff

-- Grant issuance is not a pure signer operation. It must consume the exact
-- token transcript through the root broker's captured protected store first.
unsafeSign ::
    RootBroker scope brokerGeneration verb ->
    HandoffBinding scope brokerGeneration ->
    HandoffChallenge ->
    HandoffGrant scope brokerGeneration
unsafeSign broker binding challenge = signHandoffGrant broker binding challenge
