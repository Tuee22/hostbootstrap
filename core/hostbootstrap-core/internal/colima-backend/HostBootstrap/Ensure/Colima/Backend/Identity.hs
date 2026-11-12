{-# LANGUAGE OverloadedStrings #-}

-- | Pure ownership/invocation encoding; these strings grant no backend authority.
module HostBootstrap.Ensure.Colima.Backend.Identity (
    colimaOwnerToken,
    originRecordName,
    colimaAcquireCallDigest,
    colimaInvocationDigest,
    bindColimaOwner,
    colimaCleanupInvocationDigest,
)
where

import qualified Data.ByteString as ByteString.Strict
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text.Encoding
import Data.Word (Word64)
import HostBootstrap.Digest (sha256Hex)
import HostBootstrap.Ensure.Colima.Backend.Runner (BackendNamespace (..))

colimaOwnerToken :: String -> Text.Text -> Text.Text -> String -> Text.Text -> Text.Text -> Word64 -> String
colimaOwnerToken profileName projectName lifecycleProfile planDigest resourceKey resourceFrame fenceValue =
    "v2-"
        ++ hexText (Text.pack profileName)
        ++ "-"
        ++ hexText projectName
        ++ "-"
        ++ hexText lifecycleProfile
        ++ "-"
        ++ hexText (Text.pack planDigest)
        ++ "-"
        ++ hexText resourceKey
        ++ "-"
        ++ hexText resourceFrame
        ++ "-"
        ++ show fenceValue

hexText :: Text.Text -> String
hexText = concatMap hexByte . ByteString.Strict.unpack . Text.Encoding.encodeUtf8
  where
    digits = "0123456789abcdef"
    hexByte byte =
        [ digits !! fromIntegral (byte `div` 16)
        , digits !! fromIntegral (byte `mod` 16)
        ]

originRecordName :: String -> FilePath
originRecordName ownerSeed =
    ".hostbootstrap-colima-"
        ++ take 32 (Text.unpack (hexDigestOfText (Text.pack ownerSeed)))
        ++ ".origin"

colimaAcquireCallDigest :: String -> String -> String -> FilePath -> Word64 -> [String] -> Text.Text
colimaAcquireCallDigest profileName namespaceKey owner recordPath fenceValue arguments =
    hexDigestOfText
        ( Text.intercalate "\NUL"
            (map Text.pack ("direct-colima-acquire-v1" : profileName : namespaceKey : owner : recordPath : show fenceValue : arguments))
        )

colimaInvocationDigest :: Text.Text -> Text.Text -> Text.Text -> Text.Text -> Word64 -> Word64 -> Word64 -> String
colimaInvocationDigest callDigest plan operation session fenceValue attempt version =
    Text.unpack
        ( hexDigestOfText
            ( Text.intercalate "\NUL"
                [ "direct-colima-invocation-v1", callDigest, plan, operation, session
                , Text.pack (show fenceValue), Text.pack (show attempt), Text.pack (show version)
                ]
            )
        )

bindColimaOwner :: String -> BackendNamespace -> String -> String
bindColimaOwner ownerSeed namespace toolchainFingerprint =
    ownerSeed
        ++ "-"
        ++ digestFields
            [ Text.pack (namespaceColimaHome namespace)
            , Text.pack (namespaceLimaHome namespace)
            , Text.pack (namespaceColimaCacheHome namespace)
            , Text.pack (namespaceTemporaryDirectory namespace)
            ]
        ++ "-" ++ digestFields [Text.pack (namespaceDockerConfig namespace)]
        ++ "-" ++ digestFields [Text.pack (namespaceExecutablePath namespace)]
        ++ "-" ++ digestFields [Text.pack toolchainFingerprint]
  where
    digestFields = Text.unpack . hexDigestOfText . Text.intercalate "\NUL"

-- | A durably bound release survives a new journal session, attempt or version.
-- Only stable teardown coordinates enter this identity.
colimaCleanupInvocationDigest :: Text.Text -> Text.Text -> Text.Text -> Word64 -> String
colimaCleanupInvocationDigest callDigest plan operation fenceValue =
    Text.unpack
        ( hexDigestOfText
            ( Text.intercalate "\NUL"
                [ "direct-colima-cleanup-invocation-v1", callDigest, plan, operation
                , Text.pack (show fenceValue)
                ]
            )
        )

hexDigestOfText :: Text.Text -> Text.Text
hexDigestOfText = sha256Hex . Text.Encoding.encodeUtf8
