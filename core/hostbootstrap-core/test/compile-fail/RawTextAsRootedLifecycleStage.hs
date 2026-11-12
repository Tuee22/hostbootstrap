module RawTextAsRootedLifecycleStage (build, LifecycleStage) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Handoff.Rooted (LifecycleSession, LifecycleStage, RequestDigest, rootedSettledResponseUnsignedKernel)

build :: RequestDigest -> [Text] -> LifecycleSession -> Text -> Word64 -> ByteString -> ByteString -> Either Text ByteString
build digest path session stage = rootedSettledResponseUnsignedKernel digest path session stage
