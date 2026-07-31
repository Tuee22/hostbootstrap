module ForgeVerifiedHandoff where

import HostBootstrap.Handoff

sampleBinding :: HandoffBinding
sampleBinding =
    HandoffBinding
        { handoffScope = "Production"
        , handoffPlanRevision = "rev-1"
        , handoffBrokerGeneration = 1
        , handoffParentFrame = "vm-orchestrator-1"
        , handoffChildFrame = "vm-project-container-2"
        , handoffChildConfigDigest = "0"
        , handoffVerb = "up"
        , handoffPhase = "execute"
        }

-- Raw wire cannot be promoted: a verified handoff exists only as the result of
-- signature verification plus one-time token consumption.
promotedWire :: VerifiedHandoff scope brokerGeneration
promotedWire = VerifiedHandoff sampleBinding "message = \"attacker\""

-- Nor can child authority be asserted without a verified handoff behind it.
assertedChild :: ChildPlanAuthority scope brokerGeneration
assertedChild = ChildPlanAuthority sampleBinding

-- A parent cannot construct the signing broker: only 'withRootBroker' mints it,
-- and only from a verified root invocation.
forgedBroker :: RootBroker scope brokerGeneration verb
forgedBroker = RootBroker

-- A relay cannot be minted around an arbitrary binding, so a parent cannot give
-- itself an edge the root never authorized.
forgedRelay :: BrokerRelay scope brokerGeneration
forgedRelay = BrokerRelay sampleBinding

-- A grant is not constructible from bytes that were never signed.
forgedGrant :: HandoffGrant
forgedGrant = HandoffGrant "not a signature"

-- A challenge must be freshly minted by the receiver, not chosen by the sender.
chosenChallenge :: HandoffChallenge
chosenChallenge = HandoffChallenge "predictable"

-- The installed verification key cannot be built from arbitrary bytes.
forgedKey :: ProjectVerificationKey
forgedKey = ProjectVerificationKey "attacker key"
