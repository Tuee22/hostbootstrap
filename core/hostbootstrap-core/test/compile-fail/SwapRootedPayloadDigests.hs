module SwapRootedPayloadDigests where

import Data.ByteString (ByteString)
import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (ChildConfigDigest, PayloadDigest, RootedPayloadBinding, rootedPayloadBindingKernel)

swapped :: ByteString -> PayloadDigest -> ChildConfigDigest -> ByteString -> Either Text (RootedPayloadBinding scope generation)
swapped edge payload child signature =
    rootedPayloadBindingKernel edge child payload signature
