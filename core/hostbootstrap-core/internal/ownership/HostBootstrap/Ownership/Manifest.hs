{-# LANGUAGE OverloadedStrings #-}

{- | Canonical identity/content manifests for mutable owned namespaces.

The namespace directory itself holds the four ownership clauses. This value is
the complete descendant allow-list retained beside it: kind, relative path,
opaque kernel identity, mode, and the extra fact needed to revalidate that
kind. Immutable files carry their shared payload digest, symbolic links carry
their exact target bytes, and mutable files/sockets/directories carry no
invented content authority.
-}
module HostBootstrap.Ownership.Manifest
  ( OwnershipManifest,
    OwnershipManifestEntry,
    ManifestEntryKind (..),
    mutableManifestEntry,
    immutableManifestEntry,
    directoryManifestEntry,
    symbolicLinkManifestEntry,
    socketManifestEntry,
    manifestEntryPath,
    manifestEntryIdentity,
    manifestEntryMode,
    manifestEntryKind,
    mkOwnershipManifest,
    ownershipManifestEntries,
    prefixOwnershipManifest,
    mergeOwnershipManifests,
    ownershipManifestDigest,
    ownershipDirectoryChainDigest,
    renderOwnershipManifest,
    parseOwnershipManifest,
  )
where

import qualified Crypto.Hash as Hash
import Data.Bits ((.&.))
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString.Char8
import Data.List (group, sortOn)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text.Encoding
import Data.Word (Word32, Word8)
import HostBootstrap.Ownership.Object
  ( ObjectIdentity,
    OwnershipFault (OwnershipMalformed),
    PayloadDigest,
    objectIdentityText,
    parseObjectIdentityHex,
    parsePayloadDigestHex,
    payloadDigestText,
  )
import Numeric (readHex, readOct, showHex, showOct)
import System.FilePath (isAbsolute, normalise, splitDirectories)

data ManifestEntryKind
  = ManifestMutableFile
  | ManifestImmutableFile PayloadDigest
  | ManifestDirectory
  | ManifestSymbolicLink ByteString.ByteString
  | ManifestSocket
  deriving (Eq, Show)

data OwnershipManifestEntry = OwnershipManifestEntry
  { manifestEntryPath :: FilePath,
    manifestEntryIdentity :: ObjectIdentity,
    manifestEntryMode :: Word32,
    manifestEntryKind :: ManifestEntryKind
  }
  deriving (Eq, Show)

newtype OwnershipManifest = OwnershipManifest [OwnershipManifestEntry]
  deriving (Eq, Show)

mutableManifestEntry :: FilePath -> ObjectIdentity -> Word32 -> Either OwnershipFault OwnershipManifestEntry
mutableManifestEntry path identity mode = entry path identity mode ManifestMutableFile

immutableManifestEntry :: FilePath -> ObjectIdentity -> Word32 -> PayloadDigest -> Either OwnershipFault OwnershipManifestEntry
immutableManifestEntry path identity mode digest = entry path identity mode (ManifestImmutableFile digest)

directoryManifestEntry :: FilePath -> ObjectIdentity -> Word32 -> Either OwnershipFault OwnershipManifestEntry
directoryManifestEntry path identity mode = entry path identity mode ManifestDirectory

symbolicLinkManifestEntry :: FilePath -> ObjectIdentity -> Word32 -> ByteString.ByteString -> Either OwnershipFault OwnershipManifestEntry
symbolicLinkManifestEntry path identity mode target
  | ByteString.null target || ByteString.length target > 4096 = Left (OwnershipMalformed "an ownership manifest link target is empty or over-long")
  | otherwise = entry path identity mode (ManifestSymbolicLink target)

socketManifestEntry :: FilePath -> ObjectIdentity -> Word32 -> Either OwnershipFault OwnershipManifestEntry
socketManifestEntry path identity mode = entry path identity mode ManifestSocket

entry :: FilePath -> ObjectIdentity -> Word32 -> ManifestEntryKind -> Either OwnershipFault OwnershipManifestEntry
entry path identity mode kind
  | not (validRelative path) = Left (OwnershipMalformed "an ownership manifest path is not canonical and relative")
  | mode .&. 0o7777 /= mode = Left (OwnershipMalformed "an ownership manifest mode exceeds permission bits")
  | otherwise = Right (OwnershipManifestEntry path identity mode kind)

mkOwnershipManifest :: [OwnershipManifestEntry] -> Either OwnershipFault OwnershipManifest
mkOwnershipManifest entries
  | any ((> 1) . length) (group (map manifestEntryPath ordered)) = Left (OwnershipMalformed "an ownership manifest names a path twice")
  | otherwise = Right (OwnershipManifest ordered)
  where
    ordered = sortOn manifestEntryPath entries

ownershipManifestEntries :: OwnershipManifest -> [OwnershipManifestEntry]
ownershipManifestEntries (OwnershipManifest entries) = entries

prefixOwnershipManifest :: FilePath -> OwnershipManifest -> Either OwnershipFault OwnershipManifest
prefixOwnershipManifest prefix (OwnershipManifest entries)
  | not (validRelative prefix) = Left (OwnershipMalformed "an ownership manifest prefix is not canonical and relative")
  | otherwise = mkOwnershipManifest [value {manifestEntryPath = prefix ++ "/" ++ manifestEntryPath value} | value <- entries]

mergeOwnershipManifests :: [OwnershipManifest] -> Either OwnershipFault OwnershipManifest
mergeOwnershipManifests manifests = mkOwnershipManifest (concatMap ownershipManifestEntries manifests)

ownershipManifestDigest :: OwnershipManifest -> String
ownershipManifestDigest = show . Hash.hashWith Hash.SHA256 . renderOwnershipManifest

ownershipDirectoryChainDigest :: OwnershipManifest -> String
ownershipDirectoryChainDigest (OwnershipManifest entries) =
  show
    ( Hash.hashWith
        Hash.SHA256
        (renderOwnershipManifest (OwnershipManifest (filter isDirectoryEntry entries)))
    )
  where
    isDirectoryEntry value = manifestEntryKind value == ManifestDirectory

renderOwnershipManifest :: OwnershipManifest -> ByteString.ByteString
renderOwnershipManifest (OwnershipManifest entries) =
  ByteString.Char8.pack (unlines ("ownership-manifest-v1" : map renderEntry entries))
  where
    renderEntry value =
      unwords
        [ kindTag (manifestEntryKind value),
          hexBytes (Text.Encoding.encodeUtf8 (Text.pack (manifestEntryPath value))),
          Text.unpack (objectIdentityText (manifestEntryIdentity value)),
          showOct (manifestEntryMode value) "",
          kindDetail (manifestEntryKind value)
        ]
    kindTag ManifestMutableFile = "m"
    kindTag (ManifestImmutableFile _) = "f"
    kindTag ManifestDirectory = "d"
    kindTag (ManifestSymbolicLink _) = "l"
    kindTag ManifestSocket = "s"
    kindDetail ManifestMutableFile = "-"
    kindDetail (ManifestImmutableFile digest) = Text.unpack (payloadDigestText digest)
    kindDetail ManifestDirectory = "-"
    kindDetail (ManifestSymbolicLink target) = hexBytes target
    kindDetail ManifestSocket = "-"

parseOwnershipManifest :: ByteString.ByteString -> Either OwnershipFault OwnershipManifest
parseOwnershipManifest raw
  | ByteString.null raw || ByteString.last raw /= 10 = malformed
  | otherwise = case ByteString.Char8.lines raw of
      "ownership-manifest-v1" : rows -> do
        entries <- traverse parseEntry rows
        manifest <- mkOwnershipManifest entries
        if renderOwnershipManifest manifest == raw then Right manifest else malformed
      _ -> malformed
  where
    parseEntry row = case words (ByteString.Char8.unpack row) of
      [tag, rawPath, rawIdentity, rawMode, detail] -> do
        pathBytes <- parseHexBytes rawPath
        path <- either (const malformed) (Right . Text.unpack) (Text.Encoding.decodeUtf8' pathBytes)
        identity <- parseObjectIdentityHex (Text.pack rawIdentity)
        mode <- parseMode rawMode
        case (tag, detail) of
          ("m", "-") -> mutableManifestEntry path identity mode
          ("f", digest) -> parsePayloadDigestHex (Text.pack digest) >>= immutableManifestEntry path identity mode
          ("d", "-") -> directoryManifestEntry path identity mode
          ("l", target) -> parseHexBytes target >>= symbolicLinkManifestEntry path identity mode
          ("s", "-") -> socketManifestEntry path identity mode
          _ -> malformed
      _ -> malformed
    parseMode value = case readOct value of
      [(mode, "")] -> Right mode
      _ -> malformed
    malformed = Left (OwnershipMalformed "ownership manifest bytes are not canonical")

validRelative :: FilePath -> Bool
validRelative path =
  not (null path)
    && length path <= 4096
    && not (isAbsolute path)
    && normalise path == path
    && all validComponent (splitDirectories path)
    && all (`notElem` ("\r\n\0" :: String)) path
  where
    validComponent component = not (null component) && component /= "." && component /= ".."

hexBytes :: ByteString.ByteString -> String
hexBytes = concatMap byteHex . ByteString.unpack
  where
    byteHex byte = let rendered = showHex byte "" in replicate (2 - length rendered) '0' ++ rendered

parseHexBytes :: String -> Either OwnershipFault ByteString.ByteString
parseHexBytes raw
  | null raw || odd (length raw) = malformed
  | otherwise = ByteString.pack <$> traverse pair (pairs raw)
  where
    pairs [] = []
    pairs (first : second : rest) = [first, second] : pairs rest
    pairs _ = []
    pair value = case readHex value of
      [(parsed, "")] | parsed <= fromIntegral (maxBound :: Word8) -> Right parsed
      _ -> malformed
    malformed = Left (OwnershipMalformed "ownership manifest hex bytes are not canonical")
