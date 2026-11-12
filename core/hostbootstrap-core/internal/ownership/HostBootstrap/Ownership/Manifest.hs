{-# LANGUAGE OverloadedStrings #-}

{- | Canonical identity/content manifests for mutable owned namespaces.

The namespace directory itself holds the four ownership clauses. This value is
the complete descendant allow-list retained beside it: kind, relative path,
opaque kernel identity, mode, and the extra fact needed to revalidate that
kind. Immutable files carry their shared payload digest, symbolic links carry
their exact target bytes, and mutable files/sockets/directories carry no
invented content authority.
-}
module HostBootstrap.Ownership.Manifest (
    OwnershipManifest,
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
    projectOwnershipManifest,
    admitOwnershipManifestRemainders,
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
import Data.Word (Word32, Word8)
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    OwnershipFault (OwnershipMalformed, OwnershipOccupied),
    PayloadDigest,
    objectIdentityText,
    parseObjectIdentityHex,
    parsePayloadDigestHex,
    payloadDigestText,
 )
import Numeric (readHex, readOct, showHex, showOct)

data ManifestEntryKind
    = ManifestMutableFile
    | ManifestImmutableFile PayloadDigest
    | ManifestDirectory
    | ManifestSymbolicLink ByteString.ByteString
    | ManifestSocket
    deriving (Eq, Show)

data OwnershipManifestEntry = OwnershipManifestEntry ByteString.ByteString ObjectIdentity Word32 ManifestEntryKind
    deriving (Eq, Show)

manifestEntryPath :: OwnershipManifestEntry -> ByteString.ByteString
manifestEntryPath (OwnershipManifestEntry path _ _ _) = path

manifestEntryIdentity :: OwnershipManifestEntry -> ObjectIdentity
manifestEntryIdentity (OwnershipManifestEntry _ identity _ _) = identity

manifestEntryMode :: OwnershipManifestEntry -> Word32
manifestEntryMode (OwnershipManifestEntry _ _ mode _) = mode

manifestEntryKind :: OwnershipManifestEntry -> ManifestEntryKind
manifestEntryKind (OwnershipManifestEntry _ _ _ kind) = kind

newtype OwnershipManifest = OwnershipManifest [OwnershipManifestEntry]
    deriving (Eq, Show)

mutableManifestEntry :: ByteString.ByteString -> ObjectIdentity -> Word32 -> Either OwnershipFault OwnershipManifestEntry
mutableManifestEntry path identity mode = entry path identity mode ManifestMutableFile

immutableManifestEntry :: ByteString.ByteString -> ObjectIdentity -> Word32 -> PayloadDigest -> Either OwnershipFault OwnershipManifestEntry
immutableManifestEntry path identity mode digest = entry path identity mode (ManifestImmutableFile digest)

directoryManifestEntry :: ByteString.ByteString -> ObjectIdentity -> Word32 -> Either OwnershipFault OwnershipManifestEntry
directoryManifestEntry path identity mode = entry path identity mode ManifestDirectory

symbolicLinkManifestEntry :: ByteString.ByteString -> ObjectIdentity -> Word32 -> ByteString.ByteString -> Either OwnershipFault OwnershipManifestEntry
symbolicLinkManifestEntry path identity mode target
    | ByteString.null target || ByteString.length target > 4096 = Left (OwnershipMalformed "an ownership manifest link target is empty or over-long")
    | otherwise = entry path identity mode (ManifestSymbolicLink target)

socketManifestEntry :: ByteString.ByteString -> ObjectIdentity -> Word32 -> Either OwnershipFault OwnershipManifestEntry
socketManifestEntry path identity mode = entry path identity mode ManifestSocket

entry :: ByteString.ByteString -> ObjectIdentity -> Word32 -> ManifestEntryKind -> Either OwnershipFault OwnershipManifestEntry
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

prefixOwnershipManifest :: ByteString.ByteString -> OwnershipManifest -> Either OwnershipFault OwnershipManifest
prefixOwnershipManifest prefix (OwnershipManifest entries)
    | not (validRelative prefix) = Left (OwnershipMalformed "an ownership manifest prefix is not canonical and relative")
    | otherwise = traverse (\value -> repath (prefix <> "/" <> manifestEntryPath value, value)) entries >>= mkOwnershipManifest

repath :: (ByteString.ByteString, OwnershipManifestEntry) -> Either OwnershipFault OwnershipManifestEntry
repath (path, OwnershipManifestEntry _ identity mode kind) = entry path identity mode kind

mergeOwnershipManifests :: [OwnershipManifest] -> Either OwnershipFault OwnershipManifest
mergeOwnershipManifests manifests = mkOwnershipManifest (concatMap ownershipManifestEntries manifests)

-- | Project one namespace without decoding any retained name.
projectOwnershipManifest :: ByteString.ByteString -> OwnershipManifest -> Either OwnershipFault OwnershipManifest
projectOwnershipManifest prefix (OwnershipManifest entries)
    | not (validRelative prefix) = Left (OwnershipMalformed "the manifest namespace prefix is not canonical and relative")
    | otherwise = traverse repath
        [ (ByteString.drop (ByteString.length opening) (manifestEntryPath value), value)
        | value <- entries
        , opening `ByteString.isPrefixOf` manifestEntryPath value
        ] >>= mkOwnershipManifest
  where
    opening = prefix <> "/"

-- | Return only present entries whose complete retained authority still matches.
-- Canonical manifests are path-sorted, so a merge skips lawful absence while
-- refusing an added or changed entry. Exclusions cover whole raw subtrees.
admitOwnershipManifestRemainders :: [ByteString.ByteString] -> OwnershipManifest -> OwnershipManifest -> Either OwnershipFault [OwnershipManifestEntry]
admitOwnershipManifestRemainders exclusions (OwnershipManifest retained) (OwnershipManifest current)
    | not (all validRelative exclusions) = Left (OwnershipMalformed "a manifest subtree exclusion is not canonical and relative")
    | otherwise = admit (filter included retained) (filter included current)
  where
    included value = not (any (contains (manifestEntryPath value)) exclusions)
    contains path root = path == root || (root <> "/") `ByteString.isPrefixOf` path
    admit _ [] = Right []
    admit [] (value : _) = outside value
    admit (retainedEntry : retainedRest) observed@(currentEntry : currentRest) =
        case compare (manifestEntryPath retainedEntry) (manifestEntryPath currentEntry) of
            LT -> admit retainedRest observed
            GT -> outside currentEntry
            EQ
                | retainedEntry == currentEntry -> (retainedEntry :) <$> admit retainedRest currentRest
                | otherwise -> Left (OwnershipOccupied ("a namespace remainder differs from its retained authority: " <> label currentEntry))
    outside value = Left (OwnershipOccupied ("a namespace remainder is outside its retained authority: " <> label value))
    label = Text.pack . hexBytes . manifestEntryPath

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
            [ kindTag (manifestEntryKind value)
            , hexBytes (manifestEntryPath value)
            , Text.unpack (objectIdentityText (manifestEntryIdentity value))
            , showOct (manifestEntryMode value) ""
            , kindDetail (manifestEntryKind value)
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
            path <- parseHexBytes rawPath
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

validRelative :: ByteString.ByteString -> Bool
validRelative path =
    not (ByteString.null path)
        && ByteString.length path <= 4096
        && all validComponent (ByteString.split 47 path)
        && not (ByteString.any (`elem` [0, 10, 13]) path)
  where
    validComponent component = not (ByteString.null component) && component /= "." && component /= ".."

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
