module RawWord64AsRootedLifecycleOrdinal (build, LifecycleOrdinal, Word64) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Handoff.Rooted (LifecycleOrdinal, LifecycleSession, LifecycleStage, RequestDigest, rootedDescendResponseUnsignedKernel)

build :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> Word64 -> ByteString -> ByteString -> Either Text ByteString
build digest path session stage ordinal = rootedDescendResponseUnsignedKernel digest path session stage ordinal
