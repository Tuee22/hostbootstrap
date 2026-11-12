module RawTextAsRootedRequestDigest (build, RequestDigest) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Handoff.Rooted (RequestDigest, rootedDescendResponseUnsignedKernel)

build :: Text -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> Either Text ByteString
build digest = rootedDescendResponseUnsignedKernel digest
