{-# LANGUAGE OverloadedStrings #-}

{- | CBOR protocol for the demo accelerator daemon.

This module intentionally implements the tiny CBOR subset the demo protocol
needs: text-keyed maps whose values are text or IEEE-754 doubles. That keeps the
wire contract deterministic without adding another dependency to the warm store.
-}
module HostBootstrapDemo.Accelerator.Protocol (
    AcceleratorMessage (..),
    AcceleratorResponse (..),
    correlateResponse,
    decodeAcceleratorMessage,
    encodeAcceleratorMessage,
    responseRequestId,
)
where

import Control.Applicative (Alternative (..))
import Control.Monad (replicateM)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as BS
import Data.ByteString.Builder (Builder, toLazyByteString, word16BE, word32BE, word64BE, word8)
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word16, Word32, Word64, Word8)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import HostBootstrapDemo.Web.Api (
    AcceleratorAddFailure (AcceleratorAddFailure),
    AcceleratorAddRequest (AcceleratorAddRequest),
    AcceleratorAddResult (AcceleratorAddResult),
 )

data AcceleratorMessage
    = AcceleratorRequest AcceleratorAddRequest
    | AcceleratorResult AcceleratorAddResult
    | AcceleratorFailure AcceleratorAddFailure
    deriving (Eq, Show)

data AcceleratorResponse
    = AcceleratorSucceeded AcceleratorAddResult
    | AcceleratorFailed AcceleratorAddFailure
    deriving (Eq, Show)

responseRequestId :: AcceleratorResponse -> Text
responseRequestId (AcceleratorSucceeded (AcceleratorAddResult rid _ _ _)) = rid
responseRequestId (AcceleratorFailed (AcceleratorAddFailure rid _ _ _)) = rid

correlateResponse :: Text -> AcceleratorResponse -> Either Text AcceleratorResponse
correlateResponse expected response
    | responseRequestId response == expected = Right response
    | otherwise =
        Left
            ( "accelerator response request-id mismatch: expected "
                <> expected
                <> ", got "
                <> responseRequestId response
            )

encodeAcceleratorMessage :: AcceleratorMessage -> BS.ByteString
encodeAcceleratorMessage =
    LBS.toStrict . toLazyByteString . encodeMessage

decodeAcceleratorMessage :: BS.ByteString -> Either Text AcceleratorMessage
decodeAcceleratorMessage bytes = do
    (fields, rest) <- runParser parseMap bytes
    if BS.null rest
        then messageFromFields fields
        else Left "trailing bytes after accelerator CBOR message"

encodeMessage :: AcceleratorMessage -> Builder
encodeMessage (AcceleratorRequest (AcceleratorAddRequest rid leftVal rightVal)) =
    encodeMap
        [ ("type", TextValue "request")
        , ("requestId", TextValue rid)
        , ("left", DoubleValue (realToFrac leftVal))
        , ("right", DoubleValue (realToFrac rightVal))
        ]
encodeMessage (AcceleratorResult (AcceleratorAddResult rid resultVal backendName hash)) =
    encodeMap
        [ ("type", TextValue "result")
        , ("requestId", TextValue rid)
        , ("result", DoubleValue (realToFrac resultVal))
        , ("backend", TextValue backendName)
        , ("artifactHash", TextValue hash)
        ]
encodeMessage (AcceleratorFailure (AcceleratorAddFailure rid message backendName hash)) =
    encodeMap
        [ ("type", TextValue "failure")
        , ("requestId", TextValue rid)
        , ("failureMessage", TextValue message)
        , ("backend", TextValue backendName)
        , ("artifactHash", TextValue hash)
        ]

data CborValue = TextValue Text | DoubleValue Double
    deriving (Eq, Show)

encodeMap :: [(Text, CborValue)] -> Builder
encodeMap fields =
    encodeMajorLen 5 (fromIntegral (length fields))
        <> foldMap (\(key, value) -> encodeText key <> encodeValue value) fields

encodeValue :: CborValue -> Builder
encodeValue (TextValue value) = encodeText value
encodeValue (DoubleValue value) = word8 0xfb <> word64BE (castDoubleToWord64 value)

encodeText :: Text -> Builder
encodeText value =
    let utf8 = TE.encodeUtf8 value
     in encodeMajorLen 3 (fromIntegral (BS.length utf8)) <> foldMap word8 (BS.unpack utf8)

encodeMajorLen :: Word8 -> Word64 -> Builder
encodeMajorLen major len
    | len < 24 = word8 (majorTag major .|. fromIntegral len)
    | len <= fromIntegral (maxBound :: Word8) =
        word8 (majorTag major .|. 24) <> word8 (fromIntegral len)
    | len <= fromIntegral (maxBound :: Word16) =
        word8 (majorTag major .|. 25) <> word16BE (fromIntegral len)
    | len <= fromIntegral (maxBound :: Word32) =
        word8 (majorTag major .|. 26) <> word32BE (fromIntegral len)
    | otherwise =
        word8 (majorTag major .|. 27) <> word64BE len

majorTag :: Word8 -> Word8
majorTag major = major `shiftL` 5

newtype Parser a = Parser {runParser :: BS.ByteString -> Either Text (a, BS.ByteString)}

instance Functor Parser where
    fmap f parser =
        Parser $ \bytes -> do
            (value, rest) <- runParser parser bytes
            Right (f value, rest)

instance Applicative Parser where
    pure value = Parser (\bytes -> Right (value, bytes))
    parserFn <*> parserValue =
        Parser $ \bytes -> do
            (f, rest) <- runParser parserFn bytes
            (value, rest') <- runParser parserValue rest
            Right (f value, rest')

instance Monad Parser where
    parser >>= f =
        Parser $ \bytes -> do
            (value, rest) <- runParser parser bytes
            runParser (f value) rest

instance Alternative Parser where
    empty = Parser (const (Left "empty parser"))
    parserA <|> parserB =
        Parser $ \bytes ->
            case runParser parserA bytes of
                Right value -> Right value
                Left _ -> runParser parserB bytes

parseMap :: Parser [(Text, CborValue)]
parseMap = do
    len <- parseLength 5
    replicateM (fromIntegral len) ((,) <$> parseText <*> parseValue)

parseValue :: Parser CborValue
parseValue =
    (TextValue <$> parseText) <|> (DoubleValue <$> parseDouble)

parseText :: Parser Text
parseText = do
    len <- parseLength 3
    raw <- takeBytes (fromIntegral len)
    case TE.decodeUtf8' raw of
        Left err -> failParser ("invalid UTF-8 text in accelerator CBOR message: " <> T.pack (show err))
        Right txt -> pure txt

parseDouble :: Parser Double
parseDouble = do
    tag <- takeByte
    if tag == 0xfb
        then castWord64ToDouble <$> parseWord64BE
        else failParser "expected CBOR double"

parseLength :: Word8 -> Parser Word64
parseLength expectedMajor = do
    initial <- takeByte
    let major = initial `shiftR` 5
        additional = initial .&. 0x1f
    if major == expectedMajor
        then parseAdditional additional
        else failParser ("expected CBOR major type " <> T.pack (show expectedMajor))

parseAdditional :: Word8 -> Parser Word64
parseAdditional additional
    | additional < 24 = pure (fromIntegral additional)
    | additional == 24 = fromIntegral <$> takeByte
    | additional == 25 = fromIntegral <$> parseWord16BE
    | additional == 26 = fromIntegral <$> parseWord32BE
    | additional == 27 = parseWord64BE
    | otherwise = failParser "indefinite CBOR lengths are not supported"

parseWord16BE :: Parser Word16
parseWord16BE = do
    a <- takeByte
    b <- takeByte
    pure ((fromIntegral a `shiftL` 8) .|. fromIntegral b)

parseWord32BE :: Parser Word32
parseWord32BE = do
    a <- takeByte
    b <- takeByte
    c <- takeByte
    d <- takeByte
    pure
        ( (fromIntegral a `shiftL` 24)
            .|. (fromIntegral b `shiftL` 16)
            .|. (fromIntegral c `shiftL` 8)
            .|. fromIntegral d
        )

parseWord64BE :: Parser Word64
parseWord64BE = do
    a <- takeByte
    b <- takeByte
    c <- takeByte
    d <- takeByte
    e <- takeByte
    f <- takeByte
    g <- takeByte
    h <- takeByte
    pure
        ( (fromIntegral a `shiftL` 56)
            .|. (fromIntegral b `shiftL` 48)
            .|. (fromIntegral c `shiftL` 40)
            .|. (fromIntegral d `shiftL` 32)
            .|. (fromIntegral e `shiftL` 24)
            .|. (fromIntegral f `shiftL` 16)
            .|. (fromIntegral g `shiftL` 8)
            .|. fromIntegral h
        )

takeByte :: Parser Word8
takeByte =
    Parser $ \bytes ->
        case BS.uncons bytes of
            Nothing -> Left "unexpected end of accelerator CBOR message"
            Just (byte, rest) -> Right (byte, rest)

takeBytes :: Int -> Parser BS.ByteString
takeBytes count =
    Parser $ \bytes ->
        let (prefix, rest) = BS.splitAt count bytes
         in if BS.length prefix == count
                then Right (prefix, rest)
                else Left "unexpected end of accelerator CBOR message"

failParser :: Text -> Parser a
failParser message = Parser (const (Left message))

messageFromFields :: [(Text, CborValue)] -> Either Text AcceleratorMessage
messageFromFields fields = do
    tag <- requireText "type" fields
    case tag of
        "request" ->
            AcceleratorRequest
                <$> ( AcceleratorAddRequest
                        <$> requireText "requestId" fields
                        <*> (realToFrac <$> requireDouble "left" fields)
                        <*> (realToFrac <$> requireDouble "right" fields)
                    )
        "result" ->
            AcceleratorResult
                <$> ( AcceleratorAddResult
                        <$> requireText "requestId" fields
                        <*> (realToFrac <$> requireDouble "result" fields)
                        <*> requireText "backend" fields
                        <*> requireText "artifactHash" fields
                    )
        "failure" ->
            AcceleratorFailure
                <$> ( AcceleratorAddFailure
                        <$> requireText "requestId" fields
                        <*> requireText "failureMessage" fields
                        <*> requireText "backend" fields
                        <*> requireText "artifactHash" fields
                    )
        other -> Left ("unknown accelerator message type: " <> other)

requireText :: Text -> [(Text, CborValue)] -> Either Text Text
requireText key fields =
    case lookup key fields of
        Just (TextValue value) -> Right value
        Just (DoubleValue _) -> Left ("accelerator CBOR field is not text: " <> key)
        Nothing -> Left ("missing accelerator CBOR field: " <> key)

requireDouble :: Text -> [(Text, CborValue)] -> Either Text Double
requireDouble key fields =
    case lookup key fields of
        Just (DoubleValue value) -> Right value
        Just (TextValue _) -> Left ("accelerator CBOR field is not a double: " <> key)
        Nothing -> Left ("missing accelerator CBOR field: " <> key)
