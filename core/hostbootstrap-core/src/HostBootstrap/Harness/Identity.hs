{-# LANGUAGE OverloadedStrings #-}

{- | The stable kernel identity clause 3 of @development_plan_standards.md § EE@
demands, shared by every owned filesystem object.

Clause 3 says ownership binds to the object the kernel knows, never to the
pathname that currently reaches it.  Two harness-owned objects need exactly that
binding — the run's @.test_data\/\<runId\>@ directory
("HostBootstrap.Harness.DataRoot") and the run's generated sibling
@\<project\>.dhall@ ("HostBootstrap.Harness.GeneratedConfig") — and the identity
they bind is the same @(volume, index)@ pair read the same way.  It lives here so
the two protocols cannot drift apart, and so a substrate that cannot supply the
identity refuses both at one place.

The constructor is private: an 'ObjectIdentity' exists only where a backend read
a non-empty identity out of the kernel, so an empty or fabricated value can never
be compared as though it were one.
-}
module HostBootstrap.Harness.Identity (
    -- * Identity
    ObjectIdentity,
    mkObjectIdentity,
    objectIdentityBytes,
    objectIdentityText,
    parseObjectIdentityHex,

    -- * The host seam
    ObjectIdentityBackend (..),

    -- * Failures
    IdentityFault (..),
    identityFaultMessage,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Char (isHexDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word8)

{- | A filesystem object's stable kernel identity: @device:inode@ on POSIX, the
volume serial number plus file index on Windows.
-}
newtype ObjectIdentity = ObjectIdentity ByteString
    deriving (Eq, Ord)

instance Show ObjectIdentity where
    show identity = "ObjectIdentity " <> show (objectIdentityText identity)

-- | Admit raw identity bytes.  Empty is not an identity, and an over-long value
-- is a host reporting something this protocol does not understand.
mkObjectIdentity :: ByteString -> Either IdentityFault ObjectIdentity
mkObjectIdentity raw
    | ByteString.null raw =
        Left (IdentityUnsupported "the host reported an empty object identity")
    | ByteString.length raw > 64 =
        Left (IdentityUnsupported "the host reported an over-long object identity")
    | otherwise = Right (ObjectIdentity raw)

objectIdentityBytes :: ObjectIdentity -> ByteString
objectIdentityBytes (ObjectIdentity raw) = raw

-- | The identity as lowercase hex, which is how it is journalled and reported.
objectIdentityText :: ObjectIdentity -> Text
objectIdentityText (ObjectIdentity raw) =
    Text.pack (concatMap hexByte (ByteString.unpack raw))

hexByte :: Word8 -> String
hexByte value = [hexDigit (value `div` 16), hexDigit (value `mod` 16)]

hexDigit :: Word8 -> Char
hexDigit value
    | value < 10 = toEnum (fromEnum '0' + fromIntegral value)
    | otherwise = toEnum (fromEnum 'a' + fromIntegral value - 10)

-- | Read back a journalled identity.  A value that is not exactly lowercase hex
-- is a malformed record, never a guess.
parseObjectIdentityHex :: Text -> Either IdentityFault ObjectIdentity
parseObjectIdentityHex raw
    | Text.null raw || odd (Text.length raw) || not (Text.all isHexDigit raw) =
        Left (IdentityMalformed ("identity is not lowercase hex: " <> raw))
    | otherwise = mkObjectIdentity (ByteString.pack (bytes (Text.unpack raw)))
  where
    bytes (high : low : rest) = (nibble high * 16 + nibble low) : bytes rest
    bytes _ = []
    nibble character
        | character >= '0' && character <= '9' =
            fromIntegral (fromEnum character - fromEnum '0')
        | otherwise =
            fromIntegral (fromEnum character - fromEnum 'a' + 10)

{- | How a driver reads a path's stable kernel identity.

@Right Nothing@ is an authoritative absence; @Left@ is a probe fault, never a
false absence (§ CC).  Production supplies
"HostBootstrap.Harness.Identity.Native"; a test injects one that reports
'IdentityUnsupported' to prove that a host without a stable identity mints no
ownership at all.
-}
newtype ObjectIdentityBackend = ObjectIdentityBackend
    { observeObjectIdentity ::
        FilePath ->
        IO (Either IdentityFault (Maybe ObjectIdentity))
    }

-- | Why an identity could not be established.  Each owning protocol maps these
-- into its own failure vocabulary rather than leaking this one to its callers.
data IdentityFault
    = -- | The host cannot supply a stable identity; no receipt may be minted.
      IdentityUnsupported Text
    | -- | The probe itself failed: @(what was attempted, why)@.
      IdentityProbeFailed Text Text
    | -- | A journalled identity could not be interpreted.
      IdentityMalformed Text
    deriving (Eq, Show)

identityFaultMessage :: IdentityFault -> Text
identityFaultMessage fault = case fault of
    IdentityUnsupported reason -> reason
    IdentityProbeFailed operation reason -> "could not " <> operation <> ": " <> reason
    IdentityMalformed reason -> reason
