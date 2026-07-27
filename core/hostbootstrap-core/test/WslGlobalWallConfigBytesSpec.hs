{-# LANGUAGE OverloadedStrings #-}

module WslGlobalWallConfigBytesSpec (tests) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word16)
import HostBootstrap.Wsl2.GlobalWall.ConfigBytes
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( Assertion,
    assertFailure,
    testCase,
    (@?=),
  )

managedBody :: [ByteString]
managedBody =
  [ "[general]",
    "instanceIdleTimeout=-1",
    "[wsl2]",
    "processors=6",
    "memory=10GB",
    "swap=10GB",
    "vmIdleTimeout=-1"
  ]

tests :: TestTree
tests =
  testGroup
    "WslGlobalWallConfigBytesSpec"
    [ testCase "absent and present-empty files produce the exact CRLF body" $ do
        spec <- expectRight (mkManagedWslConfigSpec managedBody)
        let expected =
              "[general]\r\ninstanceIdleTimeout=-1\r\n[wsl2]\r\nprocessors=6\r\nmemory=10GB\r\nswap=10GB\r\nvmIdleTimeout=-1\r\n"
        mergeManagedWslConfig ByteString.empty spec @?= Right expected,
      testCase "merge preserves unrelated bytes and keys inside managed sections" $ do
        spec <- expectRight (mkManagedWslConfigSpec managedBody)
        let original =
              "\xEF\xBB\xBF; leading comment\r\n[general]\r\n# general comment\r\ncustomGeneral=yes\r\ninstanceIdleTimeout=5\r\n[experimental]\r\nprocessors=99\r\nunicode=\xE2\x98\x83\r\n[wsl2]\r\nnestedVirtualization=true\r\nmemory=4GB\r\n; wsl comment\r\n"
            expected =
              "\xEF\xBB\xBF; leading comment\r\n[general]\r\n# general comment\r\ncustomGeneral=yes\r\ninstanceIdleTimeout=-1\r\n[experimental]\r\nprocessors=99\r\nunicode=\xE2\x98\x83\r\n[wsl2]\r\nnestedVirtualization=true\r\n; wsl comment\r\nprocessors=6\r\nmemory=10GB\r\nswap=10GB\r\nvmIdleTimeout=-1\r\n"
        desired <- expectRight (mergeManagedWslConfig original spec)
        desired @?= expected
        mergeManagedWslConfig desired spec @?= Right desired,
      testCase "unrelated section ends managed-key recognition" $ do
        spec <- expectRight (mkManagedWslConfigSpec managedBody)
        let original =
              "[general]\ninstanceIdleTimeout=3\n[experimental]\ninstanceIdleTimeout=keep-me\n[wsl2]\nprocessors=2\nmemory=2GB\nswap=2GB\nvmIdleTimeout=5\n"
            expected =
              "[general]\ninstanceIdleTimeout=-1\n[experimental]\ninstanceIdleTimeout=keep-me\n[wsl2]\nprocessors=6\nmemory=10GB\nswap=10GB\nvmIdleTimeout=-1\n"
        mergeManagedWslConfig original spec @?= Right expected,
      testCase "UTF-8 Unicode values cannot hide controlled keys" $ do
        spec <- expectRight (mkManagedWslConfigSpec managedBody)
        let four = ByteString.pack [0xE5, 0x9B, 0x9B]
            snowman = ByteString.pack [0xE2, 0x98, 0x83]
            preserved =
              "note=" <> four <> " ; " <> snowman
            expected =
              "[wsl2]\r\n"
                <> preserved
                <> "\r\nprocessors=6\r\nmemory=10GB\r\nswap=10GB\r\nvmIdleTimeout=-1\r\n[general]\r\ninstanceIdleTimeout=-1\r\n"
            controlledLines =
              [ "memory=" <> four <> "GB",
                "memory=4GB ; " <> snowman
              ]
        mapM_
          ( \controlled ->
              assertExactIdempotent
                spec
                ("[wsl2]\r\n" <> preserved <> "\r\n" <> controlled <> "\r\n")
                expected
          )
          controlledLines,
      testCase "UTF-16 Unicode values cannot hide controlled keys" $ do
        spec <- expectRight (mkManagedWslConfigSpec managedBody)
        let preservedUnits =
              asciiUnits "note=" ++ [0x56DB] ++ asciiUnits " ; " ++ [0x2603]
            expectedUnits =
              asciiUnits "[wsl2]\r\n"
                ++ preservedUnits
                ++ asciiUnits "\r\nprocessors=6\r\nmemory=10GB\r\nswap=10GB\r\nvmIdleTimeout=-1\r\n[general]\r\ninstanceIdleTimeout=-1\r\n"
            controlledUnitLines =
              [ asciiUnits "memory=" ++ [0x56DB] ++ asciiUnits "GB",
                asciiUnits "memory=4GB ; " ++ [0x2603]
              ]
        mapM_
          ( \encode ->
              mapM_
                ( \controlled ->
                    assertExactIdempotent
                      spec
                      ( encode
                          ( asciiUnits "[wsl2]\r\n"
                              ++ preservedUnits
                              ++ asciiUnits "\r\n"
                              ++ controlled
                              ++ asciiUnits "\r\n"
                          )
                      )
                      (encode expectedUnits)
                )
                controlledUnitLines
          )
          [utf16LittleEndianUnits, utf16BigEndianUnits],
      testCase "exact Unicode unrelated sections preserve later controlled-looking keys" $ do
        spec <- expectRight (mkManagedWslConfigSpec managedBody)
        let four = ByteString.pack [0xE5, 0x9B, 0x9B]
            originalUtf8 =
              "[wsl2]\n"
                <> "memory=1GB\n"
                <> "["
                <> four
                <> "]\n"
                <> "memory=keep-under-unrelated-section\n"
            expectedUtf8 =
              "[wsl2]\nprocessors=6\nmemory=10GB\nswap=10GB\nvmIdleTimeout=-1\n"
                <> "["
                <> four
                <> "]\n"
                <> "memory=keep-under-unrelated-section\n"
                <> "[general]\ninstanceIdleTimeout=-1\n"
            originalUnits =
              asciiUnits "[wsl2]\nmemory=1GB\n["
                ++ [0x56DB]
                ++ asciiUnits "]\nmemory=keep-under-unrelated-section\n"
            expectedUnits =
              asciiUnits "[wsl2]\nprocessors=6\nmemory=10GB\nswap=10GB\nvmIdleTimeout=-1\n["
                ++ [0x56DB]
                ++ asciiUnits "]\nmemory=keep-under-unrelated-section\n[general]\ninstanceIdleTimeout=-1\n"
        assertExactIdempotent spec originalUtf8 expectedUtf8
        mapM_
          ( \encode ->
              assertExactIdempotent
                spec
                (encode originalUnits)
                (encode expectedUnits)
          )
          [utf16LittleEndianUnits, utf16BigEndianUnits],
      testCase "ambiguous bracket-prefixed section lines are refused" $ do
        spec <- expectRight (mkManagedWslConfigSpec managedBody)
        let snowman = ByteString.pack [0xE2, 0x98, 0x83]
            trailingCommentUtf8 =
              "[wsl2]\n[experimental] ; "
                <> snowman
                <> "\nmemory=must-not-be-reclassified\n"
            malformedUtf8 =
              "[wsl2]\n[future-section\nswap=must-not-be-reclassified\n"
            trailingCommentUnits =
              asciiUnits "[wsl2]\n[experimental] ; "
                ++ [0x2603]
                ++ asciiUnits "\nmemory=must-not-be-reclassified\n"
            malformedUnits =
              asciiUnits
                "[wsl2]\n[future-section\nswap=must-not-be-reclassified\n"
            ambiguousInputs =
              [ trailingCommentUtf8,
                malformedUtf8,
                utf16LittleEndianUnits trailingCommentUnits,
                utf16BigEndianUnits trailingCommentUnits,
                utf16LittleEndianUnits malformedUnits,
                utf16BigEndianUnits malformedUnits
              ]
        mapM_
          (assertLeftKind isAmbiguous . (`mergeManagedWslConfig` spec))
          ambiguousInputs,
      testCase "duplicate managed sections and controlled keys are ambiguous" $ do
        spec <- expectRight (mkManagedWslConfigSpec managedBody)
        assertLeftKind
          isAmbiguous
          (mergeManagedWslConfig "[general]\na=1\n[general]\nb=2\n" spec)
        assertLeftKind
          isAmbiguous
          ( mergeManagedWslConfig
              "[general]\ninstanceIdleTimeout=1\ninstanceIdleTimeout=2\n"
              spec
          ),
      testCase "managed spec rejects unknown, duplicate, and empty controlled values" $ do
        assertLeftKind
          isInvalidSpec
          (mkManagedWslConfigSpec (managedBody ++ ["unknown=true"]))
        assertLeftKind
          isInvalidSpec
          ( mkManagedWslConfigSpec
              (managedBody ++ ["processors=8"])
          )
        assertLeftKind
          isInvalidSpec
          ( mkManagedWslConfigSpec
              [ "[general]",
                "instanceIdleTimeout=",
                "[wsl2]",
                "processors=6",
                "memory=10GB",
                "swap=10GB",
                "vmIdleTimeout=-1"
              ]
          ),
      testCase "UTF-16LE and UTF-16BE BOM files merge byte-exactly and idempotently" $ do
        spec <- expectRight (mkManagedWslConfigSpec managedBody)
        let source =
              "[general]\r\ncustom=yes\r\ninstanceIdleTimeout=2\r\n[wsl2]\r\nunknown=yes\r\nprocessors=2\r\n"
        mapM_
          (assertUtf16Idempotent spec source)
          [utf16LittleEndian, utf16BigEndian],
      testCase "strict decoder rejects invalid UTF, NUL, lone CR, mixed newlines, and UTF-32" $ do
        spec <- expectRight (mkManagedWslConfigSpec managedBody)
        mapM_
          (assertLeftKind isInvalidBytes . (`mergeManagedWslConfig` spec))
          [ ByteString.pack [0xC0, 0xAF],
            "a\0b",
            "a\rb",
            "a\nb\r\n"
          ]
        assertLeftKind
          isUnsupported
          (mergeManagedWslConfig "\xFF\xFE\x00\x00" spec)
    ]

assertUtf16Idempotent ::
  ManagedWslConfigSpec ->
  String ->
  (ByteString -> ByteString) ->
  Assertion
assertUtf16Idempotent spec source encode = do
  desired <- expectRight (mergeManagedWslConfig (encodeAscii source) spec)
  ByteString.take 2 desired @?= ByteString.take 2 (encode ByteString.empty)
  mergeManagedWslConfig desired spec @?= Right desired
  where
    encodeAscii = encode . ByteString.pack . map (fromIntegral . fromEnum)

assertExactIdempotent ::
  ManagedWslConfigSpec ->
  ByteString ->
  ByteString ->
  Assertion
assertExactIdempotent spec original expected = do
  desired <- expectRight (mergeManagedWslConfig original spec)
  desired @?= expected
  mergeManagedWslConfig desired spec @?= Right desired

utf16LittleEndian :: ByteString -> ByteString
utf16LittleEndian bytes =
  "\xFF\xFE"
    <> ByteString.pack
      (concatMap (\byte -> [byte, 0]) (ByteString.unpack bytes))

utf16BigEndian :: ByteString -> ByteString
utf16BigEndian bytes =
  "\xFE\xFF"
    <> ByteString.pack
      (concatMap (\byte -> [0, byte]) (ByteString.unpack bytes))

asciiUnits :: String -> [Word16]
asciiUnits = map (fromIntegral . fromEnum)

utf16LittleEndianUnits :: [Word16] -> ByteString
utf16LittleEndianUnits units =
  "\xFF\xFE"
    <> ByteString.pack
      (concatMap (\unit -> [fromIntegral unit, fromIntegral (unit `div` 256)]) units)

utf16BigEndianUnits :: [Word16] -> ByteString
utf16BigEndianUnits units =
  "\xFE\xFF"
    <> ByteString.pack
      (concatMap (\unit -> [fromIntegral (unit `div` 256), fromIntegral unit]) units)

isAmbiguous :: ConfigBytesError -> Bool
isAmbiguous (AmbiguousWslConfig _) = True
isAmbiguous _ = False

isInvalidSpec :: ConfigBytesError -> Bool
isInvalidSpec (InvalidManagedSpec _) = True
isInvalidSpec _ = False

isInvalidBytes :: ConfigBytesError -> Bool
isInvalidBytes (InvalidWslConfigBytes _) = True
isInvalidBytes _ = False

isUnsupported :: ConfigBytesError -> Bool
isUnsupported (UnsupportedWslConfigEncoding _) = True
isUnsupported _ = False

expectRight :: Show err => Either err value -> IO value
expectRight result =
  case result of
    Left err -> assertFailure ("expected Right, got Left " ++ show err)
    Right value -> pure value

assertLeftKind ::
  Show err =>
  (err -> Bool) ->
  Either err value ->
  Assertion
assertLeftKind predicate result =
  case result of
    Left err
      | predicate err -> pure ()
      | otherwise -> assertFailure ("unexpected Left " ++ show err)
    Right _ -> assertFailure "expected Left, got Right"
