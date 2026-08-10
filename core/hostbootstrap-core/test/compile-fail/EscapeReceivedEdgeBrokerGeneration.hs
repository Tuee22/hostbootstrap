module EscapeReceivedEdgeBrokerGeneration where

import Data.Text (Text)
import HostBootstrap.Handoff
import HostBootstrap.Handoff.Receiver

data CallerChosenReceivedGeneration

selectGeneration ::
    ReceivedEdge scope CallerChosenReceivedGeneration ->
    IO (Either Text ())
selectGeneration _ = pure (Right ())

escapeGeneration ::
    HandoffScope scope ->
    HandoffChannel ->
    ProjectVerificationKey ->
    ReceiverExpectation ->
    IO (Either ReceiverError ())
escapeGeneration scope channel key expectation =
    withReceivedHandoffEdge scope channel key expectation selectGeneration
