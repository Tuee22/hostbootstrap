{-# LANGUAGE ScopedTypeVariables #-}

{- | Bounded, length-framed messages for the authenticated handoff channel.

This module owns bytes and protocol sequencing only.  It deliberately has no
signing key, protected-store handle, config decoder, or lifecycle authority.
Every message is one outer frame whose body starts with a fixed magic, protocol
version, closed tag, and request id; all remaining values are nested frames.
-}
module HostBootstrap.Handoff.Protocol (
    ProtocolTag (..),
    ProtocolMessage,
    protocolMessage,
    protocolMessageTag,
    protocolMessageRequestId,
    protocolMessageFields,
    encodeProtocolMessage,
    decodeProtocolMessage,
    readProtocolMessage,
    writeProtocolMessage,
    HandoffChannel,
    handoffChannel,
    stdioHandoffChannel,
    channelReceive,
    channelSend,
    ChildProtocolState,
    initialChildProtocolState,
    childProtocolReceive,
    childProtocolSend,
    childProtocolFinished,
    ProtocolError (..),
    protocolErrorMessage,
    protocolMagic,
    protocolVersion,
    protocolMaximumBytes,
) where

import Control.Exception (IOException, try)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Word (Word16, Word64, Word8)
import System.IO (
    BufferMode (BlockBuffering),
    Handle,
    hFlush,
    hSetBinaryMode,
    hSetBuffering,
    stdin,
    stdout,
 )

-- | Stable magic at the start of every decoded body.
protocolMagic :: ByteString
protocolMagic = ByteString.pack [0x48, 0x42, 0x48, 0x46] -- HBHF

-- | The only protocol version this implementation accepts.
protocolVersion :: Word16
protocolVersion = 1

-- | Reject an outer body larger than 8 MiB before allocating it.
protocolMaximumBytes :: Word64
protocolMaximumBytes = 8 * 1024 * 1024

outerHeaderBytes :: Int
outerHeaderBytes = 8

messageHeaderBytes :: Int
messageHeaderBytes = 4 + 2 + 1 + 8

-- | Closed message vocabulary for protocol v1.
data ProtocolTag
    = OfferRequestTag
    | OfferResponseTag
    | OfferTag
    | ChallengeTag
    | GrantRequestTag
    | GrantResponseTag
    | GrantTag
    | AcceptedTag
    | CompletedTag
    | RefusedTag
    deriving (Eq, Ord, Show)

{- | One structurally valid message.  Field bytes are opaque to this layer and
are intentionally redacted from 'Show'.
-}
data ProtocolMessage = ProtocolMessage ProtocolTag Word64 [ByteString]
    deriving (Eq)

instance Show ProtocolMessage where
    show (ProtocolMessage tag requestId fields) =
        "ProtocolMessage {tag = "
            ++ show tag
            ++ ", requestId = "
            ++ show requestId
            ++ ", fields = <"
            ++ show (length fields)
            ++ " redacted>}"

-- | Validate a message before it can be encoded.
protocolMessage :: ProtocolTag -> Word64 -> [ByteString] -> Either ProtocolError ProtocolMessage
protocolMessage tag requestId fields
    | requestId == 0 = Left ProtocolZeroRequestId
    | length fields /= expectedFieldCount tag =
        Left (ProtocolWrongFieldCount tag (expectedFieldCount tag) (length fields))
    | any ((> fromIntegral protocolMaximumBytes) . ByteString.length) fields =
        Left (ProtocolFieldTooLarge protocolMaximumBytes)
    | encodedLength > fromIntegral protocolMaximumBytes =
        Left (ProtocolBodyTooLarge (fromIntegral encodedLength) protocolMaximumBytes)
    | otherwise = Right (ProtocolMessage tag requestId fields)
  where
    encodedLength :: Word64
    encodedLength =
        fromIntegral messageHeaderBytes
            + sum [fromIntegral outerHeaderBytes + fromIntegral (ByteString.length field) | field <- fields]

protocolMessageTag :: ProtocolMessage -> ProtocolTag
protocolMessageTag (ProtocolMessage tag _ _) = tag

protocolMessageRequestId :: ProtocolMessage -> Word64
protocolMessageRequestId (ProtocolMessage _ requestId _) = requestId

-- | Opaque protocol fields for the semantic broker/receiver layer.
protocolMessageFields :: ProtocolMessage -> [ByteString]
protocolMessageFields (ProtocolMessage _ _ fields) = fields

expectedFieldCount :: ProtocolTag -> Int
expectedFieldCount tag = case tag of
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

-- | Encode one message as a complete outer frame.
encodeProtocolMessage :: ProtocolMessage -> ByteString
encodeProtocolMessage (ProtocolMessage tag requestId fields) =
    frame (encodeBody tag requestId fields)

encodeBody :: ProtocolTag -> Word64 -> [ByteString] -> ByteString
encodeBody tag requestId fields =
    protocolMagic
        <> ByteString.pack (word16BigEndian protocolVersion)
        <> ByteString.singleton (tagByte tag)
        <> ByteString.pack (word64BigEndian requestId)
        <> ByteString.concat (map frame fields)

-- | Decode exactly one complete outer frame.
decodeProtocolMessage :: ByteString -> Either ProtocolError ProtocolMessage
decodeProtocolMessage wire = do
    (body, trailing) <- takeFrame wire
    if ByteString.null trailing
        then decodeBody body
        else Left (ProtocolTrailingBytes (ByteString.length trailing))

decodeBody :: ByteString -> Either ProtocolError ProtocolMessage
decodeBody body
    | ByteString.length body < messageHeaderBytes =
        Left (ProtocolTruncated messageHeaderBytes (ByteString.length body))
    | magic /= protocolMagic = Left ProtocolBadMagic
    | decodedVersion /= protocolVersion = Left (ProtocolUnsupportedVersion decodedVersion)
    | otherwise = do
        tag <- byteTag tagValue
        fields <- decodeFields tag fieldBytes
        protocolMessage tag requestId fields
  where
    (magic, afterMagic) = ByteString.splitAt 4 body
    (versionBytes, afterVersion) = ByteString.splitAt 2 afterMagic
    (tagBytes, afterTag) = ByteString.splitAt 1 afterVersion
    (requestBytes, fieldBytes) = ByteString.splitAt 8 afterTag
    decodedVersion = bigEndianWord16 (ByteString.unpack versionBytes)
    tagValue = ByteString.head tagBytes
    requestId = bigEndianWord64 (ByteString.unpack requestBytes)

-- Decode only the closed tag's expected number of fields.  In particular, do
-- not recursively walk an attacker-controlled sequence of empty frames before
-- discovering that the message has too many fields.
decodeFields :: ProtocolTag -> ByteString -> Either ProtocolError [ByteString]
decodeFields tag = go 0 []
  where
    expected = expectedFieldCount tag

    go actual fields raw
        | actual == expected =
            if ByteString.null raw
                then Right (reverse fields)
                else Left (ProtocolWrongFieldCount tag expected (actual + 1))
        | ByteString.null raw = Left (ProtocolWrongFieldCount tag expected actual)
        | otherwise = do
            (fieldValue, remaining) <- takeFrame raw
            go (actual + 1) (fieldValue : fields) remaining

{- | Read one complete message from a handle.  The outer length is checked
before the body is read, and reads are retried until the declared byte count is
present or EOF is observed.
-}
readProtocolMessage :: Handle -> IO (Either ProtocolError ProtocolMessage)
readProtocolMessage handle = do
    headerResult <- try (readExactly handle outerHeaderBytes)
    case headerResult of
        Left (failure :: IOException) -> pure (Left (ProtocolIOFailure (firstLine (show failure))))
        Right (Left actual) -> pure (Left (ProtocolTruncated outerHeaderBytes actual))
        Right (Right header) -> do
            let declared = bigEndianWord64 (ByteString.unpack header)
            if declared > protocolMaximumBytes
                then pure (Left (ProtocolBodyTooLarge declared protocolMaximumBytes))
                else do
                    bodyResult <- try (readExactly handle (fromIntegral declared))
                    pure $ case bodyResult of
                        Left (failure :: IOException) ->
                            Left (ProtocolIOFailure (firstLine (show failure)))
                        Right (Left actual) ->
                            Left (ProtocolTruncated (fromIntegral declared) actual)
                        Right (Right body) -> decodeBody body

-- | Write and flush one complete message.  Diagnostics never include fields.
writeProtocolMessage :: Handle -> ProtocolMessage -> IO (Either ProtocolError ())
writeProtocolMessage handle message = do
    written <- try (ByteString.hPut handle (encodeProtocolMessage message) >> hFlush handle)
    pure $ case written of
        Left (failure :: IOException) -> Left (ProtocolIOFailure (firstLine (show failure)))
        Right () -> Right ()

{- | The two handles one end of an exchange owns: the stream it reads its
peer's messages from, and the stream it writes its own into.

A channel is two handles rather than one bidirectional endpoint because the
transport that actually crosses a VM or container boundary is a pipe pair —
@stdin@ inbound and @stdout@ outbound, the only descriptors a
@docker run@ \/ @limactl shell@ \/ @wsl -d@ boundary carries. A binary that
receives on this channel therefore writes its diagnostics to @stderr@:
@stdout@ carries protocol frames and nothing else, so a stray @putStrLn@
cannot corrupt the exchange.
-}
data HandoffChannel = HandoffChannel
    { channelInbound :: Handle
    , channelOutbound :: Handle
    }

instance Show HandoffChannel where
    show _ = "HandoffChannel <duplex>"

{- | Adopt a handle pair as a channel.

Both handles are put in binary mode, because the frames are bytes and a
locale-dependent text encoding would rewrite them. The outbound handle is
block-buffered and every 'channelSend' flushes, so a message reaches the peer
as one write rather than waiting for a line.
-}
handoffChannel :: Handle -> Handle -> IO HandoffChannel
handoffChannel inbound outbound = do
    hSetBinaryMode inbound True
    hSetBinaryMode outbound True
    hSetBuffering outbound (BlockBuffering Nothing)
    pure (HandoffChannel{channelInbound = inbound, channelOutbound = outbound})

{- | The channel a receiving binary is launched with: @stdin@ inbound,
@stdout@ outbound.
-}
stdioHandoffChannel :: IO HandoffChannel
stdioHandoffChannel = handoffChannel stdin stdout

-- | Read one complete message from the channel's inbound stream.
channelReceive :: HandoffChannel -> IO (Either ProtocolError ProtocolMessage)
channelReceive = readProtocolMessage . channelInbound

-- | Write and flush one complete message to the channel's outbound stream.
channelSend :: HandoffChannel -> ProtocolMessage -> IO (Either ProtocolError ())
channelSend channel = writeProtocolMessage (channelOutbound channel)

readExactly :: Handle -> Int -> IO (Either Int ByteString)
readExactly handle wanted = go [] 0
  where
    go chunks actual
        | actual == wanted = pure (Right (ByteString.concat (reverse chunks)))
        | otherwise = do
            chunk <- ByteString.hGetSome handle (wanted - actual)
            if ByteString.null chunk
                then pure (Left actual)
                else go (chunk : chunks) (actual + ByteString.length chunk)

-- | Runtime receiver sequencing.  Request identity is retained after the
-- first offer and every later message must match it.
data ChildProtocolState
    = ChildAwaitingOffer
    | ChildMustSendChallenge Word64
    | ChildAwaitingGrant Word64
    | ChildMustSendAccepted Word64
    | ChildRunning Word64
    | ChildFinished
    deriving (Eq, Show)

initialChildProtocolState :: ChildProtocolState
initialChildProtocolState = ChildAwaitingOffer

childProtocolFinished :: ChildProtocolState -> Bool
childProtocolFinished ChildFinished = True
childProtocolFinished _ = False

{- | Advance for a message received by the child.

'ChildRunning' is where the channel becomes a *duplex* one. Once the child has
accepted its own edge it may need edges of its own — it is the parent of the
next frame — and the only route to the root is back up the channel it arrived
on. So an admitted child keeps receiving the root's answers to the requests it
relays, and stays admitted while it does: an answer does not end the run, and
the run ends only at 'CompletedTag' or a refusal.
-}
childProtocolReceive :: ChildProtocolState -> ProtocolMessage -> Either ProtocolError ChildProtocolState
childProtocolReceive state message = case (state, protocolMessageTag message) of
    (ChildAwaitingOffer, OfferTag) -> Right (ChildMustSendChallenge requestId)
    -- A parent may decide there is no edge to offer at all. The child has no
    -- request identity yet, so it accepts the refusal on its face and ends: an
    -- announced refusal is strictly better than the closed pipe it replaces.
    (ChildAwaitingOffer, RefusedTag) -> Right ChildFinished
    (ChildAwaitingGrant expected, GrantTag) ->
        requireRequest expected requestId (ChildMustSendAccepted expected)
    (ChildAwaitingGrant expected, RefusedTag) -> requireRequest expected requestId ChildFinished
    (ChildRunning expected, OfferResponseTag) -> requireRequest expected requestId state
    (ChildRunning expected, GrantResponseTag) -> requireRequest expected requestId state
    (ChildRunning expected, RefusedTag) -> requireRequest expected requestId ChildFinished
    _ -> Left (ProtocolInvalidTransition "receive" state (protocolMessageTag message))
  where
    requestId = protocolMessageRequestId message

{- | Advance for a message emitted by the child.

The relay requests an admitted child may raise are the mirror of the answers it
may receive, and they are available only from 'ChildRunning': a frame cannot ask
the root to open an edge before it has been admitted to one itself.
-}
childProtocolSend :: ChildProtocolState -> ProtocolMessage -> Either ProtocolError ChildProtocolState
childProtocolSend state message = case (state, protocolMessageTag message) of
    (ChildMustSendChallenge expected, ChallengeTag) ->
        requireRequest expected requestId (ChildAwaitingGrant expected)
    (ChildMustSendAccepted expected, AcceptedTag) ->
        requireRequest expected requestId (ChildRunning expected)
    (ChildRunning expected, OfferRequestTag) -> requireRequest expected requestId state
    (ChildRunning expected, GrantRequestTag) -> requireRequest expected requestId state
    (ChildRunning expected, CompletedTag) -> requireRequest expected requestId ChildFinished
    (_, RefusedTag)
        | state /= ChildFinished -> requireStateRequest state requestId ChildFinished
    _ -> Left (ProtocolInvalidTransition "send" state (protocolMessageTag message))
  where
    requestId = protocolMessageRequestId message

requireStateRequest :: ChildProtocolState -> Word64 -> ChildProtocolState -> Either ProtocolError ChildProtocolState
requireStateRequest state actual successor = case state of
    ChildMustSendChallenge expected -> requireRequest expected actual successor
    ChildAwaitingGrant expected -> requireRequest expected actual successor
    ChildMustSendAccepted expected -> requireRequest expected actual successor
    ChildRunning expected -> requireRequest expected actual successor
    _ -> Left (ProtocolInvalidTransition "send" state RefusedTag)

requireRequest :: Word64 -> Word64 -> result -> Either ProtocolError result
requireRequest expected actual result
    | expected == actual = Right result
    | otherwise = Left (ProtocolRequestMismatch expected actual)

-- | Structural and transport failures.  No constructor carries protocol field
-- bytes, tokens, config text, keys, challenges, or signatures.
data ProtocolError
    = ProtocolTruncated Int Int
    | ProtocolBodyTooLarge Word64 Word64
    | ProtocolFieldTooLarge Word64
    | ProtocolTrailingBytes Int
    | ProtocolBadMagic
    | ProtocolUnsupportedVersion Word16
    | ProtocolUnknownTag Word8
    | ProtocolZeroRequestId
    | ProtocolWrongFieldCount ProtocolTag Int Int
    | ProtocolRequestMismatch Word64 Word64
    | ProtocolInvalidTransition String ChildProtocolState ProtocolTag
    | ProtocolIOFailure String
    deriving (Eq, Show)

protocolErrorMessage :: ProtocolError -> String
protocolErrorMessage failure = case failure of
    ProtocolTruncated expected actual ->
        "handoff protocol: truncated message (expected "
            ++ show expected
            ++ " bytes, saw "
            ++ show actual
            ++ ")"
    ProtocolBodyTooLarge declared limit ->
        "handoff protocol: declared body "
            ++ show declared
            ++ " exceeds limit "
            ++ show limit
    ProtocolFieldTooLarge limit ->
        "handoff protocol: a field exceeds limit " ++ show limit
    ProtocolTrailingBytes count ->
        "handoff protocol: " ++ show count ++ " trailing bytes"
    ProtocolBadMagic -> "handoff protocol: wrong magic"
    ProtocolUnsupportedVersion version ->
        "handoff protocol: unsupported version " ++ show version
    ProtocolUnknownTag tag -> "handoff protocol: unknown message tag " ++ show tag
    ProtocolZeroRequestId -> "handoff protocol: request id must be nonzero"
    ProtocolWrongFieldCount tag expected actual ->
        "handoff protocol: "
            ++ show tag
            ++ " expects "
            ++ show expected
            ++ " fields, saw "
            ++ show actual
    ProtocolRequestMismatch expected actual ->
        "handoff protocol: request id "
            ++ show actual
            ++ " does not match active request "
            ++ show expected
    ProtocolInvalidTransition direction state tag ->
        "handoff protocol: cannot "
            ++ direction
            ++ " "
            ++ show tag
            ++ " while in "
            ++ show state
    ProtocolIOFailure detail -> "handoff protocol: I/O failure: " ++ detail

frame :: ByteString -> ByteString
frame payload =
    ByteString.pack (word64BigEndian (fromIntegral (ByteString.length payload))) <> payload

takeFrame :: ByteString -> Either ProtocolError (ByteString, ByteString)
takeFrame raw
    | ByteString.length raw < outerHeaderBytes =
        Left (ProtocolTruncated outerHeaderBytes (ByteString.length raw))
    | declared > protocolMaximumBytes =
        Left (ProtocolBodyTooLarge declared protocolMaximumBytes)
    | ByteString.length body < fromIntegral declared =
        Left (ProtocolTruncated (fromIntegral declared) (ByteString.length body))
    | otherwise = Right (ByteString.splitAt (fromIntegral declared) body)
  where
    (header, body) = ByteString.splitAt outerHeaderBytes raw
    declared = bigEndianWord64 (ByteString.unpack header)

tagByte :: ProtocolTag -> Word8
tagByte tag = case tag of
    OfferRequestTag -> 1
    OfferResponseTag -> 2
    OfferTag -> 3
    ChallengeTag -> 4
    GrantRequestTag -> 5
    GrantResponseTag -> 6
    GrantTag -> 7
    AcceptedTag -> 8
    CompletedTag -> 9
    RefusedTag -> 10

byteTag :: Word8 -> Either ProtocolError ProtocolTag
byteTag raw = case raw of
    1 -> Right OfferRequestTag
    2 -> Right OfferResponseTag
    3 -> Right OfferTag
    4 -> Right ChallengeTag
    5 -> Right GrantRequestTag
    6 -> Right GrantResponseTag
    7 -> Right GrantTag
    8 -> Right AcceptedTag
    9 -> Right CompletedTag
    10 -> Right RefusedTag
    _ -> Left (ProtocolUnknownTag raw)

word16BigEndian :: Word16 -> [Word8]
word16BigEndian value =
    [ fromIntegral ((value `shiftR` 8) .&. 0xff)
    , fromIntegral (value .&. 0xff)
    ]

word64BigEndian :: Word64 -> [Word8]
word64BigEndian value =
    [fromIntegral ((value `shiftR` shift) .&. 0xff) | shift <- [56, 48, 40, 32, 24, 16, 8, 0]]

bigEndianWord16 :: [Word8] -> Word16
bigEndianWord16 = foldl' (\acc byte -> (acc `shiftL` 8) .|. fromIntegral byte) 0

bigEndianWord64 :: [Word8] -> Word64
bigEndianWord64 = foldl' (\acc byte -> (acc `shiftL` 8) .|. fromIntegral byte) 0

firstLine :: String -> String
firstLine = takeWhile (/= '\n')
