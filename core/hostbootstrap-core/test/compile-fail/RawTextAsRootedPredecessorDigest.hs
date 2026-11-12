module RawTextAsRootedPredecessorDigest (build, PredecessorDigest) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (LifecycleOrdinal, LifecycleSession, LifecycleStage, PredecessorDigest, RequestDigest, rootedReceiptRecordedResponseUnsignedKernel)

build :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> Text -> Either Text ByteString
build digest path session stage ordinal nonce completion =
    rootedReceiptRecordedResponseUnsignedKernel digest path session stage ordinal nonce completion
