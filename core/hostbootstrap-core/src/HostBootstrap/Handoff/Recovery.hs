{-# LANGUAGE OverloadedStrings #-}

{- | Neutral canonical bytes for one recovery child package.

This Cabal-private module owns only the bounded two-field codec. It imports no
handoff authority, cryptography, protected store, receiver, or catalog owner.
-}
module HostBootstrap.Handoff.Recovery
    ( RecoveryChildPackage
    , recoveryChildPackageKernel
    , recoveryChildPackageFromWireKernel
    , renderRecoveryChildPackageKernel
    , withRecoveryChildPackageKernel
    )
where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import Data.Word (Word64, Word8)

-- | Exact child configuration and recovery adapter transported as one payload.
data RecoveryChildPackage = RecoveryChildPackage ByteString ByteString

recoveryPackageLimit :: Word64
recoveryPackageLimit = 8 * 1024 * 1024

-- | Package-private checked constructor for the eventual catalog producer.
recoveryChildPackageKernel ::
    ByteString ->
    ByteString ->
    Either Text RecoveryChildPackage
recoveryChildPackageKernel childConfig adapter = do
    require (not (ByteString.null childConfig)) "has an empty child config"
    require (not (ByteString.null adapter)) "has an empty recovery adapter"
    require
        ( 16
            + toInteger (ByteString.length childConfig)
            + toInteger (ByteString.length adapter)
            <= toInteger recoveryPackageLimit
        )
        "is larger than the bounded recovery payload"
    pure (RecoveryChildPackage childConfig adapter)

-- | Strictly decode exactly two canonical frames.
recoveryChildPackageFromWireKernel ::
    ByteString ->
    Either Text RecoveryChildPackage
recoveryChildPackageFromWireKernel raw = do
    require
        (fromIntegral (ByteString.length raw) <= recoveryPackageLimit)
        "is larger than the bounded recovery payload"
    (childConfig, afterConfig) <- takeRecoveryFrame raw
    (adapter, trailing) <- takeRecoveryFrame afterConfig
    require (ByteString.null trailing) "has trailing bytes"
    package <- recoveryChildPackageKernel childConfig adapter
    require
        (renderRecoveryChildPackageKernel package == raw)
        "is not canonical"
    pure package

-- | Canonical two-frame package bytes.
renderRecoveryChildPackageKernel :: RecoveryChildPackage -> ByteString
renderRecoveryChildPackageKernel (RecoveryChildPackage childConfig adapter) =
    recoveryFrame childConfig <> recoveryFrame adapter

-- | Expose package fields only to a package-internal continuation.
withRecoveryChildPackageKernel ::
    RecoveryChildPackage ->
    (ByteString -> ByteString -> result) ->
    result
withRecoveryChildPackageKernel (RecoveryChildPackage childConfig adapter) use =
    use childConfig adapter

require :: Bool -> Text -> Either Text ()
require True _ = Right ()
require False detail = Left detail

recoveryFrame :: ByteString -> ByteString
recoveryFrame payload =
    ByteString.pack (word64BigEndian (fromIntegral (ByteString.length payload)))
        <> payload

takeRecoveryFrame :: ByteString -> Either Text (ByteString, ByteString)
takeRecoveryFrame raw
    | ByteString.length raw < 8 = Left "is truncated before a frame header"
    | declared > recoveryPackageLimit = Left "contains an oversized field"
    | fromIntegral (ByteString.length body) < declared =
        Left "is truncated inside a field"
    | otherwise = Right (ByteString.splitAt (fromIntegral declared) body)
  where
    (header, body) = ByteString.splitAt 8 raw
    declared = bigEndianWord64 (ByteString.unpack header)

word64BigEndian :: Word64 -> [Word8]
word64BigEndian value =
    [fromIntegral ((value `shiftR` shift) .&. 0xff) | shift <- [56, 48, 40, 32, 24, 16, 8, 0]]

bigEndianWord64 :: [Word8] -> Word64
bigEndianWord64 = foldl (\value byte -> (value `shiftL` 8) .|. fromIntegral byte) 0
