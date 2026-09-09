{-# LANGUAGE OverloadedStrings #-}

{- | The one SHA-256 spelling, and the one way to measure a set of paths.

Before this module the tree carried the same hash in several spellings — some
folding nibbles by hand, some relying on @Show (Digest SHA256)@ happening to
render lowercase hex, one prefixing @sha256:@. They agreed, but nothing made
them agree, and a digest that is recomputed elsewhere has to be byte-identical
or the comparison it exists for is meaningless.

'measurePathSetDigest' is the currency primitive the plan's gate evidence uses.
It keeps every property the build-authority measurement already had: entries are
sorted, each is framed as length-prefixed path followed by length-prefixed
contents so moving bytes to a differently named file changes the digest, paths
are encoded as UTF-8 rather than through a lossy low-byte projection, contents
are read as bytes so a locale cannot decode them differently on another gate
host, and a missing input is a typed refusal rather than a digest over nothing.

That last property is the load-bearing one: a digest over an empty set would let
a phase whose cited files have all been deleted keep reporting a stable value.
-}
module HostBootstrap.Digest
  ( sha256Hex,
    frameWire,
    DigestError (..),
    renderDigestError,
    measurePathSetDigest,
  )
where

import Control.Exception.Safe (SomeException, try)
import qualified Crypto.Hash as Hash
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.List (sort)
import Data.Text (Text)
import Data.Word (Word64, Word8)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))

-- | Lowercase hex SHA-256 of a payload.
sha256Hex :: ByteString -> Text
sha256Hex payload =
  Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 payload)))
  where
    hex byte = [hexDigit (byte `shiftR` 4), hexDigit (byte .&. 0x0f)]
    hexDigit nibble = ByteStringChar8.index "0123456789abcdef" (fromIntegral nibble)

{- | Length-prefix a payload so a concatenation of them is unambiguous.

Without the prefix, @"ab" <> "c"@ and @"a" <> "bc"@ would digest the same, and a
path/contents pair could be rearranged into a different pair with one digest.
-}
frameWire :: ByteString -> ByteString
frameWire payload =
  ByteString.pack (word64BigEndian (fromIntegral (ByteString.length payload)))
    <> payload
  where
    word64BigEndian :: Word64 -> [Word8]
    word64BigEndian value =
      [fromIntegral (value `shiftR` shiftBy) | shiftBy <- [56, 48, 40, 32, 24, 16, 8, 0 :: Int]]

-- | Why a path set could not be measured.
newtype DigestError
  = -- | the path that could not be read, and why
    DigestPathUnavailable Text
  deriving (Eq, Show)

renderDigestError :: DigestError -> String
renderDigestError (DigestPathUnavailable detail) = Text.unpack detail

{- | Digest an explicit set of repository-relative paths.

A directory contributes every file beneath it, so a path set may name a tree the
way the plan's @**Implementation**@ fields already do. Paths are normalised to
forward slashes before framing so the same tree measures identically on a gate
host whose separator differs.
-}
measurePathSetDigest :: FilePath -> [FilePath] -> IO (Either DigestError Text)
measurePathSetDigest root paths = do
  collected <- traverse (collect root) (sort paths)
  pure (fmap (sha256Hex . ByteString.concat . map entry . sort . concat) (sequence collected))
  where
    entry (path, contents) =
      frameWire (TextEncoding.encodeUtf8 (Text.pack path)) <> frameWire contents

collect :: FilePath -> FilePath -> IO (Either DigestError [(FilePath, ByteString)])
collect root path = do
  let absolute = root </> path
  isFile <- doesFileExist absolute
  isDirectory <- doesDirectoryExist absolute
  case (isFile, isDirectory) of
    (True, _) -> fmap (fmap (\contents -> [(forwardSlashes path, contents)])) (readBytes absolute)
    (_, True) -> do
      names <- listDirectory absolute
      nested <- traverse (collect root . (path </>)) (sort (filter (`notElem` generatedNames) names))
      pure (fmap concat (sequence nested))
    _ ->
      pure (Left (DigestPathUnavailable (Text.pack (path <> ": no such file or directory"))))

readBytes :: FilePath -> IO (Either DigestError ByteString)
readBytes absolute = do
  loaded <- try (ByteString.readFile absolute) :: IO (Either SomeException ByteString)
  pure $ case loaded of
    Left err -> Left (DigestPathUnavailable (Text.pack (absolute <> ": " <> firstLine (show err))))
    Right contents -> Right contents

{- | Directory names whose contents are generated, not source.

A covers digest answers "has the source this run measured changed since". A
build or interpreter cache changes on every run, so including one would expire a
phase's evidence the moment anything executed — the mechanism caught this on its
own second use, when running the Python suite rewrote @__pycache__@ under a path
a phase's covers set named.

The set is deliberately small and by exact name. A pattern language here would be
a second ignore syntax beside @.gitignore@, and a phase that needs to exclude
something else should name narrower paths instead.
-}
generatedNames :: [FilePath]
generatedNames =
  [ "__pycache__",
    "dist-newstyle",
    ".git",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    ".stack-work",
    "node_modules"
  ]

forwardSlashes :: FilePath -> FilePath
forwardSlashes = map (\c -> if c == '\\' then '/' else c)

firstLine :: String -> String
firstLine = takeWhile (/= '\n')
