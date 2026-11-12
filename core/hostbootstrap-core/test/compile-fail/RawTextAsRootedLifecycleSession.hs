module RawTextAsRootedLifecycleSession (build, LifecycleSession) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Handoff.Rooted (LifecycleSession, RequestDigest, rootedDescendResponseUnsignedKernel)

build :: RequestDigest -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> Either Text ByteString
build digest path session = rootedDescendResponseUnsignedKernel digest path session
