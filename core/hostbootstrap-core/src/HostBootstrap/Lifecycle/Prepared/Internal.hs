module HostBootstrap.Lifecycle.Prepared.Internal (
    PreparedGate,
    preparedGatePlan,
    preparedGateOperation,
    preparedGateSession,
    preparedGateFence,
    preparedGateAttempt,
    preparedGateJournalVersion,
    mintPreparedGate,
) where

import Data.Text (Text)
import Data.Word (Word64)

{- | Proof that one operation's unknown phase was durably recorded before its
backend call, carrying the exact identities and indices that write established.

This module is internal to the package. The public
"HostBootstrap.Lifecycle.Prepared" module keeps the constructor and minting
function hidden.
-}
data PreparedGate = PreparedGate
    { preparedGatePlan :: Text
    , preparedGateOperation :: Text
    , preparedGateSession :: Text
    , preparedGateFence :: Word64
    , preparedGateAttempt :: Word64
    , preparedGateJournalVersion :: Word64
    }
    deriving (Eq, Show)

-- | Package-internal constructor used only after the durable write commits.
mintPreparedGate :: Text -> Text -> Text -> Word64 -> Word64 -> Word64 -> PreparedGate
mintPreparedGate = PreparedGate
