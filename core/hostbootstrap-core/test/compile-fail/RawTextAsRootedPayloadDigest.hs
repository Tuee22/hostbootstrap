module RawTextAsRootedPayloadDigest (bind, PayloadDigest) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (PayloadDigest, RootedPayloadBinding, rootedPayloadBindingKernel)

bind :: ByteString -> Text -> Text -> ByteString -> Either Text (RootedPayloadBinding scope generation)
bind edge payload config signature =
    rootedPayloadBindingKernel edge payload config signature
