{-# LANGUAGE OverloadedStrings #-}

module HandoffProtocolSpec (tests) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.Word (Word8)
import HostBootstrap.Handoff
import System.IO (Handle, SeekMode (AbsoluteSeek), hSeek, hSetBinaryMode)
import System.IO.Temp (withSystemTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "HandoffProtocolSpec"
        [ testCase "every v1 tag round-trips with its exact field shape" $ do
            messages <- traverse makeMessage (zip [1 ..] allTags)
            traverse_ (\message -> decodeProtocolMessage (encodeProtocolMessage message) @?= Right message) messages
        , testCase "wrong magic, version, tag, and zero request id are distinct refusals" $ do
            valid <- expectRight (protocolMessage AcceptedTag 7 ["binding-digest"])
            let wire = encodeProtocolMessage valid
            decodeProtocolMessage (replaceByte 8 0 wire) @?= Left ProtocolBadMagic
            decodeProtocolMessage (replaceByte 13 2 wire) @?= Left (ProtocolUnsupportedVersion 2)
            decodeProtocolMessage (replaceByte 14 99 wire) @?= Left (ProtocolUnknownTag 99)
            decodeProtocolMessage (zeroRequestId wire) @?= Left ProtocolZeroRequestId
        , testCase "short and oversized outer frames refuse before decoding fields" $ do
            decodeProtocolMessage (ByteString.take 4 (wireFor AcceptedTag 3 ["ok"]))
                @?= Left (ProtocolTruncated 8 4)
            let short = ByteString.take 10 (wireFor AcceptedTag 3 ["ok"])
            case decodeProtocolMessage short of
                Left (ProtocolTruncated _ _) -> pure ()
                other -> assertFailure ("expected body truncation, got " <> show other)
            let hostile = ByteString.replicate 8 0xff <> "x"
            case decodeProtocolMessage hostile of
                Left (ProtocolBodyTooLarge declared limit) -> do
                    assertBool "declared size exceeds limit" (declared > limit)
                    limit @?= protocolMaximumBytes
                other -> assertFailure ("expected size refusal, got " <> show other)
        , testCase "outer trailing bytes and wrong field counts are rejected" $ do
            let wire = wireFor AcceptedTag 4 ["binding-digest"]
            decodeProtocolMessage (wire <> "trailing")
                @?= Left (ProtocolTrailingBytes 8)
            protocolMessage OfferTag 4 ["missing-fields"]
                @?= Left (ProtocolWrongFieldCount OfferTag 4 1)
        , testCase "the handle codec flushes and reads an exact framed message" $
            withSystemTempFile "hostbootstrap-handoff-protocol" $ \_ handle -> do
                hSetBinaryMode handle True
                message <- expectRight (protocolMessage ChallengeTag 9 ["fresh-challenge"])
                writeProtocolMessage handle message >>= (@?= Right ())
                hSeek handle AbsoluteSeek 0
                readProtocolMessage handle >>= (@?= Right message)
        , testCase "the handle reader reports a truncated body and rejects an oversized header without reading it" $ do
            withWire (ByteString.take 18 (wireFor GrantTag 11 ["certificate", "signature"])) $ \handle -> do
                result <- readProtocolMessage handle
                case result of
                    Left (ProtocolTruncated _ _) -> pure ()
                    other -> assertFailure ("expected truncated handle read, got " <> show other)
            withWire (ByteString.replicate 8 0xff <> "body-must-not-be-read") $ \handle -> do
                result <- readProtocolMessage handle
                case result of
                    Left (ProtocolBodyTooLarge declared limit) -> assertBool "oversized header refused" (declared > limit)
                    other -> assertFailure ("expected oversized handle refusal, got " <> show other)
        , testCase "the child state machine binds one request through offer, challenge, grant, acceptance, and completion" $ do
            offer <- expectRight (protocolMessage OfferTag 21 ["certificate", "binding", "token", "config"])
            challenge <- expectRight (protocolMessage ChallengeTag 21 ["challenge"])
            grant <- expectRight (protocolMessage GrantTag 21 ["certificate-digest", "signature"])
            accepted <- expectRight (protocolMessage AcceptedTag 21 ["binding-digest"])
            completed <- expectRight (protocolMessage CompletedTag 21 ["success"])
            afterOffer <- expectRight (childProtocolReceive initialChildProtocolState offer)
            afterChallenge <- expectRight (childProtocolSend afterOffer challenge)
            afterGrant <- expectRight (childProtocolReceive afterChallenge grant)
            running <- expectRight (childProtocolSend afterGrant accepted)
            finished <- expectRight (childProtocolSend running completed)
            assertBool "completion is terminal" (childProtocolFinished finished)
        , testCase "wrong request ids, duplicate transitions, and premature completion refuse" $ do
            offer <- expectRight (protocolMessage OfferTag 31 ["certificate", "binding", "token", "config"])
            wrongChallenge <- expectRight (protocolMessage ChallengeTag 32 ["challenge"])
            completed <- expectRight (protocolMessage CompletedTag 31 ["success"])
            afterOffer <- expectRight (childProtocolReceive initialChildProtocolState offer)
            childProtocolSend afterOffer wrongChallenge
                @?= Left (ProtocolRequestMismatch 31 32)
            case childProtocolReceive afterOffer offer of
                Left (ProtocolInvalidTransition "receive" _ OfferTag) -> pure ()
                other -> assertFailure ("expected duplicate-offer refusal, got " <> show other)
            case childProtocolSend afterOffer completed of
                Left (ProtocolInvalidTransition "send" _ CompletedTag) -> pure ()
                other -> assertFailure ("expected premature-completion refusal, got " <> show other)
        , testCase "protocol rendering and errors never contain field bytes" $ do
            message <- expectRight (protocolMessage OfferTag 41 [secret, secret, secret, secret])
            let rendered = show message <> protocolErrorMessage (ProtocolWrongFieldCount OfferTag 4 1)
            assertBool "secret protocol fields were rendered" (not (ByteString.unpack secret `containsBytesIn` rendered))
            assertBool "redaction marker is visible" ("redacted" `contains` rendered)
        ]

allTags :: [ProtocolTag]
allTags =
    [ OfferRequestTag
    , OfferResponseTag
    , OfferTag
    , ChallengeTag
    , GrantRequestTag
    , GrantResponseTag
    , GrantTag
    , AcceptedTag
    , CompletedTag
    , RefusedTag
    ]

makeMessage :: (Word, ProtocolTag) -> IO ProtocolMessage
makeMessage (requestId, tag) =
    expectRight
        (protocolMessage tag (fromIntegral requestId) (replicate (fieldCount tag) "field"))

fieldCount :: ProtocolTag -> Int
fieldCount tag = case tag of
    OfferRequestTag -> 1
    OfferResponseTag -> 1
    OfferTag -> 4
    ChallengeTag -> 1
    GrantRequestTag -> 2
    GrantResponseTag -> 1
    GrantTag -> 2
    AcceptedTag -> 1
    CompletedTag -> 1
    RefusedTag -> 2

wireFor :: ProtocolTag -> Word -> [ByteString] -> ByteString
wireFor tag requestId fields =
    either (error . show) encodeProtocolMessage (protocolMessage tag (fromIntegral requestId) fields)

replaceByte :: Int -> Word -> ByteString -> ByteString
replaceByte index value wire =
    ByteString.take index wire
        <> ByteString.singleton (fromIntegral value)
        <> ByteString.drop (index + 1) wire

zeroRequestId :: ByteString -> ByteString
zeroRequestId wire = ByteString.take 15 wire <> ByteString.replicate 8 0 <> ByteString.drop 23 wire

withWire :: ByteString -> (Handle -> IO result) -> IO result
withWire wire use =
    withSystemTempFile "hostbootstrap-handoff-protocol" $ \_ handle -> do
        hSetBinaryMode handle True
        ByteString.hPut handle wire
        hSeek handle AbsoluteSeek 0
        use handle

secret :: ByteString
secret = "SECRET-PROTOCOL-FIELD-DO-NOT-PRINT"

expectRight :: (Show failure) => Either failure value -> IO value
expectRight (Right value) = pure value
expectRight (Left failure) = assertFailure ("expected success, got " <> show failure)

containsBytesIn :: [Word8] -> String -> Bool
containsBytesIn bytes rendered = contains (map (toEnum . fromIntegral) bytes) rendered

contains :: String -> String -> Bool
contains needle haystack = any (needle `prefixOf`) (tails haystack)
  where
    tails [] = [[]]
    tails value@(_ : rest) = value : tails rest
    prefixOf [] _ = True
    prefixOf _ [] = False
    prefixOf (x : xs) (y : ys) = x == y && prefixOf xs ys
