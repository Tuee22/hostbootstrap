{-# LANGUAGE OverloadedStrings #-}

module OwnershipManifestSpec (tests) where

import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as Text
import qualified Expect
import HostBootstrap.Ownership.Manifest
import HostBootstrap.Ownership.Object (OwnershipFault (..), objectIdentityText, parsePayloadDigestHex)
import HostBootstrap.Ownership.Row (observeOwnershipManifestForHost)
import System.Info (os)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests = testGroup "OwnershipManifestSpec"
    [ testCase "malformed manifest wire forms have exact refusals" $ do
        identity <- Expect.expectRight (Expect.kernelIdentityWords 1 2)
        let encodedIdentity = Text.unpack (objectIdentityText identity)
            row path ident mode tag detail = Char8.pack ("ownership-manifest-v1\n" ++ tag ++ " " ++ path ++ " " ++ ident ++ " " ++ mode ++ " " ++ detail ++ "\n")
            generic = Left (OwnershipMalformed "ownership manifest bytes are not canonical")
            hexFault = Left (OwnershipMalformed "ownership manifest hex bytes are not canonical")
            validRow = row "61" encodedIdentity "600" "m" "-"
        forM_ [ByteString.init validRow, "wrong-header\n", "ownership-manifest-v1\nm 61\n", row "61" encodedIdentity "888" "m" "-", row "61" encodedIdentity "600" "m" "x", row "61" encodedIdentity "600" "z" "-", Char8.pack ("ownership-manifest-v1\nm  61 " ++ encodedIdentity ++ " 600 -\n")] $ \wire ->
            parseOwnershipManifest wire @?= generic
        forM_ [row "a" encodedIdentity "600" "m" "-", row "zz" encodedIdentity "600" "m" "-"] $ \wire ->
            parseOwnershipManifest wire @?= hexFault
        parseOwnershipManifest (row "61" "zz" "600" "m" "-")
            @?= Left (OwnershipMalformed "identity is not lowercase hex: zz")
    , testCase "entry and composition producers reject invalid inputs" $ do
        identity <- Expect.expectRight (Expect.kernelIdentityWords 1 2)
        symbolicLinkManifestEntry "link" identity 0o777 "" @?= Left (OwnershipMalformed "an ownership manifest link target is empty or over-long")
        symbolicLinkManifestEntry "link" identity 0o777 (ByteString.replicate 4097 97) @?= Left (OwnershipMalformed "an ownership manifest link target is empty or over-long")
        mutableManifestEntry "a" identity 0o10000 @?= Left (OwnershipMalformed "an ownership manifest mode exceeds permission bits")
        value <- Expect.expectRight (mutableManifestEntry "a" identity 0o600)
        mkOwnershipManifest [value, value] @?= Left (OwnershipMalformed "an ownership manifest names a path twice")
        single <- Expect.expectRight (mkOwnershipManifest [value])
        mergeOwnershipManifests [single, single] @?= Left (OwnershipMalformed "an ownership manifest names a path twice")
        prefixOwnershipManifest "../foreign" single @?= Left (OwnershipMalformed "an ownership manifest prefix is not canonical and relative")
        longEntry <- Expect.expectRight (mutableManifestEntry (ByteString.replicate 4096 97) identity 0o600)
        longManifest <- Expect.expectRight (mkOwnershipManifest [longEntry])
        prefixOwnershipManifest "p" longManifest @?= Left (OwnershipMalformed "an ownership manifest path is not canonical and relative")
    , testCase "every entry kind and a raw byte path round-trip" $ do
        identity <- Expect.expectRight (Expect.kernelIdentityWords 1 2)
        digest <- Expect.expectRight (parsePayloadDigestHex (Text.replicate 64 "a"))
        entries <- traverse Expect.expectRight
            [ mutableManifestEntry "profile/colima.yaml" identity 0o600
            , immutableManifestEntry "immutable" identity 0o644 digest
            , directoryManifestEntry "directory" identity 0o755
            , symbolicLinkManifestEntry "link" identity 0o777 "target"
            , socketManifestEntry (ByteString.pack [0xff]) identity 0o600
            ]
        manifest <- Expect.expectRight (mkOwnershipManifest entries)
        parseOwnershipManifest (renderOwnershipManifest manifest) @?= Right manifest
        assertBool "the raw byte path remains intact" (ByteString.pack [0xff] `elem` map manifestEntryPath (ownershipManifestEntries manifest))
    , testCase "manifest digest is deterministic and identity-sensitive" $ do
        first <- Expect.expectRight (Expect.kernelIdentityWords 1 2)
        second <- Expect.expectRight (Expect.kernelIdentityWords 3 4)
        firstEntry <- Expect.expectRight (mutableManifestEntry "profile/colima.yaml" first 0o600)
        secondEntry <- Expect.expectRight (mutableManifestEntry "_lima/profile/diffdisk" second 0o600)
        changedEntry <- Expect.expectRight (mutableManifestEntry "profile/colima.yaml" second 0o600)
        manifest <- Expect.expectRight (mkOwnershipManifest [firstEntry, secondEntry])
        reordered <- Expect.expectRight (mkOwnershipManifest [secondEntry, firstEntry])
        changed <- Expect.expectRight (mkOwnershipManifest [changedEntry, secondEntry])
        ownershipManifestDigest manifest @?= ownershipManifestDigest reordered
        assertBool "identity changes the manifest digest" (ownershipManifestDigest manifest /= ownershipManifestDigest changed)
        mutableManifestEntry "../foreign" first 0o600 @?= Left (OwnershipMalformed "an ownership manifest path is not canonical and relative")
    , retainedRemainderTests
    , testCase "Windows reports the unsupported native manifest row" $
        if os == "mingw32"
            then observeOwnershipManifestForHost False "unused" >>= (@?= Left (OwnershipUnsupported "the direct-Colima manifest row is unavailable on Windows"))
            else pure ()
    ]

retainedRemainderTests :: TestTree
retainedRemainderTests = testGroup "retained namespace remainders"
    [ testCase "namespace projection preserves a non-UTF-8 relative name" $ do
        let raw = ByteString.singleton 255
        retained <- manifest =<< sequence [file ("docker/" <> raw) 1 0o600, file "colima/other" 2 0o600]
        projected <- manifest =<< sequence [file raw 1 0o600]
        projectOwnershipManifest "docker" retained @?= Right projected
    , testCase "a namespace prefix does not admit partial matches or its own root" $ do
        retained <- manifest =<< sequence [file "docker-other/file" 1 0o600, file "docker" 2 0o600]
        empty <- manifest []
        projectOwnershipManifest "docker" retained @?= Right empty
    , testCase "namespace prefixes must be canonical relative raw paths" $ do
        empty <- manifest []
        forM_ ["", "/docker", "../docker", "docker/"] $ \prefix ->
            projectOwnershipManifest prefix empty
                @?= Left (OwnershipMalformed "the manifest namespace prefix is not canonical and relative")
    , testCase "exact current entries retain their original release authority" $ do
        firstEntry <- file "a" 1 0o600
        secondEntry <- file "b" 2 0o600
        retained <- manifest [firstEntry, secondEntry]
        admitOwnershipManifestRemainders [] retained retained @?= Right [firstEntry, secondEntry]
    , testCase "a present subset skips retained entries already absent" $ do
        firstEntry <- file "a" 1 0o600
        secondEntry <- file "b" 2 0o600
        retained <- manifest [firstEntry, secondEntry]
        current <- manifest [secondEntry]
        admitOwnershipManifestRemainders [] retained current @?= Right [secondEntry]
    , testCase "an empty current namespace owes no remainder removal" $ do
        retained <- manifest =<< sequence [file "file" 1 0o600]
        empty <- manifest []
        admitOwnershipManifestRemainders [] retained empty @?= Right []
    , testCase "a newly introduced path is outside retained authority" $ do
        empty <- manifest []
        current <- manifest =<< sequence [file "new" 1 0o600]
        admitOwnershipManifestRemainders [] empty current
            @?= Left (OwnershipOccupied "a namespace remainder is outside its retained authority: 6e6577")
    , testCase "a replacement identity refuses at its retained raw path" $ do
        retained <- manifest =<< sequence [file "file" 1 0o600]
        current <- manifest =<< sequence [file "file" 2 0o600]
        admitOwnershipManifestRemainders [] retained current @?= changed
    , testCase "a changed mode refuses despite the same identity" $ do
        retained <- manifest =<< sequence [file "file" 1 0o600]
        current <- manifest =<< sequence [file "file" 1 0o400]
        admitOwnershipManifestRemainders [] retained current @?= changed
    , testCase "a changed kind refuses despite the same identity" $ do
        retained <- manifest =<< sequence [file "file" 1 0o600]
        identity <- Expect.expectRight (Expect.kernelIdentityWords 1 1)
        directory <- Expect.expectRight (directoryManifestEntry "file" identity 0o600)
        current <- manifest [directory]
        admitOwnershipManifestRemainders [] retained current @?= changed
    , testCase "cache and tmp exclusions cover complete subtrees but no lookalikes" $ do
        keep <- file "keep" 1 0o600
        retained <- manifest . (keep :) =<< sequence [file "cache/old" 2 0o600, file "tmp/old" 3 0o600]
        current <- manifest . (keep :) =<< sequence [file "cache/new" 4 0o600, file "tmp/deep/new" 5 0o600]
        admitOwnershipManifestRemainders ["cache", "tmp"] retained current @?= Right [keep]
        lookalike <- manifest =<< sequence [file "cache-other" 6 0o600]
        Expect.expectOccupied "a cache prefix lookalike"
            (admitOwnershipManifestRemainders ["cache", "tmp"] retained lookalike)
        admitOwnershipManifestRemainders ["../cache"] retained current
            @?= Left (OwnershipMalformed "a manifest subtree exclusion is not canonical and relative")
    ]
  where
    file path inode mode = do
        identity <- Expect.expectRight (Expect.kernelIdentityWords 1 inode)
        Expect.expectRight (mutableManifestEntry path identity mode)
    manifest = Expect.expectRight . mkOwnershipManifest
    changed = Left (OwnershipOccupied "a namespace remainder differs from its retained authority: 66696c65")

