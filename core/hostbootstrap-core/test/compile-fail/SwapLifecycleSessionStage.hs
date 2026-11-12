module SwapLifecycleSessionStage where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Handoff.Rooted (LifecycleSession, LifecycleStage, RequestDigest, rootedSettledResponseUnsignedKernel)

swapped :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> Word64 -> ByteString -> ByteString -> Either Text ByteString
swapped digest path session stage ordinal nonce body =
    rootedSettledResponseUnsignedKernel digest path stage session ordinal nonce body
