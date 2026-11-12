module PayloadDigestAsRootedRequestDigest (build, PayloadDigest, RequestDigest) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Handoff.Rooted (PayloadDigest, RequestDigest, rootedDescendResponseUnsignedKernel)

build :: PayloadDigest -> [Text] -> Text -> Text -> Word64 -> ByteString -> ByteString -> Either Text ByteString
build digest = rootedDescendResponseUnsignedKernel digest
