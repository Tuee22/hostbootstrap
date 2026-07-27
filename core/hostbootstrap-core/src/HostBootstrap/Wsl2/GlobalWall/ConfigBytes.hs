{-# LANGUAGE OverloadedStrings #-}

{- | Strict, byte-preserving merge for the managed part of @.wslconfig@.

Only five keys are controlled. Unknown keys, comments, whitespace, section
spelling, BOM, and every unrelated byte are retained. Ambiguous duplicate
managed sections or controlled keys are refused instead of guessed.
-}
module HostBootstrap.Wsl2.GlobalWall.ConfigBytes
  ( ManagedWslConfigSpec,
    ConfigBytesError (..),
    mkManagedWslConfigSpec,
    managedSpecLineCount,
    managedSpecIdentityBytes,
    mergeManagedWslConfig,
  )
where

import Data.Bits ((.|.), shiftL, shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word8, Word16)

data ConfigBytesError
  = InvalidManagedSpec String
  | InvalidWslConfigBytes String
  | UnsupportedWslConfigEncoding String
  | AmbiguousWslConfig String
  deriving (Eq, Show)

data ManagedWslConfigSpec = ManagedWslConfigSpec
  { managedGeneralHeader :: ByteString,
    managedGeneralSetting :: ByteString,
    managedWsl2Header :: ByteString,
    managedWsl2Settings :: [ByteString]
  }
  deriving (Eq, Show)

data ConfigEncoding
  = Utf8Encoding Bool
  | Utf16LittleEndian
  | Utf16BigEndian
  deriving (Eq, Show)

data NewlineStyle = NewlineLf | NewlineCrLf
  deriving (Eq, Show)

data EncodedLine = EncodedLine
  { encodedLineContent :: ByteString,
    encodedLineTerminator :: ByteString,
    encodedLineAscii :: Maybe ByteString
  }
  deriving (Eq, Show)

data ParsedConfig = ParsedConfig
  { parsedEncoding :: ConfigEncoding,
    parsedNewline :: NewlineStyle,
    parsedLines :: [EncodedLine]
  }

data TransformedConfig = TransformedConfig
  { transformedHasGeneral :: Bool,
    transformedHasWsl2 :: Bool,
    transformedChunks :: [ByteString]
  }

data ManagedSection = GeneralSection | Wsl2Section
  deriving (Eq, Show)

mkManagedWslConfigSpec ::
  [ByteString] ->
  Either ConfigBytesError ManagedWslConfigSpec
mkManagedWslConfigSpec linesValue = do
  mapM_ validateManagedLine linesValue
  (generalHeader, generalSettings, wslHeader, wslSettings) <-
    collect Nothing Nothing [] Nothing [] linesValue
  generalLine <-
    requireExactlyOne
      "[general] instanceIdleTimeout"
      "instanceidletimeout"
      generalSettings
  processors <- requireExactlyOne "[wsl2] processors" "processors" wslSettings
  memory <- requireExactlyOne "[wsl2] memory" "memory" wslSettings
  swap <- requireExactlyOne "[wsl2] swap" "swap" wslSettings
  vmIdle <-
    requireExactlyOne
      "[wsl2] vmIdleTimeout"
      "vmidletimeout"
      wslSettings
  pure
    ManagedWslConfigSpec
      { managedGeneralHeader = generalHeader,
        managedGeneralSetting = generalLine,
        managedWsl2Header = wslHeader,
        managedWsl2Settings = [processors, memory, swap, vmIdle]
      }
  where
    collect
      current
      generalHeader
      generalSettings
      wslHeader
      wslSettings
      remaining =
        case remaining of
          [] -> do
            finalGeneral <-
              maybe
                (Left (InvalidManagedSpec "managed body requires [general]"))
                Right
                generalHeader
            finalWsl <-
              maybe
                (Left (InvalidManagedSpec "managed body requires [wsl2]"))
                Right
                wslHeader
            Right
              ( finalGeneral,
                reverse generalSettings,
                finalWsl,
                reverse wslSettings
              )
          line : rest ->
            case sectionName line of
              Just "general" ->
                case generalHeader of
                  Just _ ->
                    Left
                      (InvalidManagedSpec "managed body repeats [general]")
                  Nothing ->
                    collect
                      (Just GeneralSection)
                      (Just line)
                      generalSettings
                      wslHeader
                      wslSettings
                      rest
              Just "wsl2" ->
                case wslHeader of
                  Just _ ->
                    Left
                      (InvalidManagedSpec "managed body repeats [wsl2]")
                  Nothing ->
                    collect
                      (Just Wsl2Section)
                      generalHeader
                      generalSettings
                      (Just line)
                      wslSettings
                      rest
              Just _ ->
                Left
                  ( InvalidManagedSpec
                      "only [general] and [wsl2] may be managed"
                  )
              Nothing -> do
                setting <- parseManagedSetting line
                case current of
                  Nothing ->
                    Left
                      ( InvalidManagedSpec
                          "managed settings must follow a section header"
                      )
                  Just GeneralSection ->
                    if fst setting /= "instanceidletimeout"
                      then
                        Left
                          ( InvalidManagedSpec
                              ("unknown controlled [general] key: " ++ show (fst setting))
                          )
                      else
                        collect
                          current
                          generalHeader
                          (setting : generalSettings)
                          wslHeader
                          wslSettings
                          rest
                  Just Wsl2Section ->
                    if fst setting
                      `notElem` ["processors", "memory", "swap", "vmidletimeout"]
                      then
                        Left
                          ( InvalidManagedSpec
                              ("unknown controlled [wsl2] key: " ++ show (fst setting))
                          )
                      else
                        collect
                          current
                          generalHeader
                          generalSettings
                          wslHeader
                          (setting : wslSettings)
                          rest

managedSpecLineCount :: ManagedWslConfigSpec -> Int
managedSpecLineCount spec =
  2 + 1 + length (managedWsl2Settings spec)

managedSpecIdentityBytes :: ManagedWslConfigSpec -> ByteString
managedSpecIdentityBytes spec =
  ByteString.intercalate
    "\n"
    ( managedHeaderAndSettings GeneralSection spec
        ++ managedHeaderAndSettings Wsl2Section spec
    )

mergeManagedWslConfig ::
  ByteString ->
  ManagedWslConfigSpec ->
  Either ConfigBytesError ByteString
mergeManagedWslConfig original spec = do
  parsed <- parseConfig original
  validateExistingAmbiguity
    (parsedEncoding parsed)
    (parsedLines parsed)
  let encoding = parsedEncoding parsed
      newline = parsedNewline parsed
      transformed =
        transformExisting
          encoding
          newline
          spec
          (parsedLines parsed)
      withMissing =
        appendMissingSections encoding newline spec transformed
      prefix = encodingBom encoding
  pure (prefix <> ByteString.concat withMissing)

validateManagedLine :: ByteString -> Either ConfigBytesError ()
validateManagedLine line
  | ByteString.null line =
      Left (InvalidManagedSpec "managed lines must not be empty")
  | ByteString.any (\byte -> byte < 32 || byte > 126) line =
      Left
        ( InvalidManagedSpec
            "managed lines must be printable ASCII without CR, LF, or NUL"
        )
  | otherwise = Right ()

parseManagedSetting ::
  ByteString ->
  Either ConfigBytesError (ByteString, ByteString)
parseManagedSetting line =
  case settingKeyAndValue line of
    Nothing ->
      Left
        (InvalidManagedSpec "managed settings must be non-empty key=value lines")
    Just (key, value)
      | ByteString.null (asciiTrim value) ->
          Left
            (InvalidManagedSpec "managed setting values must not be empty")
      | otherwise -> Right (key, line)

requireExactlyOne ::
  String ->
  ByteString ->
  [(ByteString, ByteString)] ->
  Either ConfigBytesError ByteString
requireExactlyOne label key settings =
  case [line | (observedKey, line) <- settings, observedKey == key] of
    [line] -> Right line
    [] -> Left (InvalidManagedSpec (label ++ " is required"))
    _ -> Left (InvalidManagedSpec (label ++ " must not repeat"))

parseConfig :: ByteString -> Either ConfigBytesError ParsedConfig
parseConfig bytes
  | "\xFF\xFE\x00\x00" `ByteString.isPrefixOf` bytes
      || "\x00\x00\xFE\xFF" `ByteString.isPrefixOf` bytes =
      Left
        ( UnsupportedWslConfigEncoding
            "UTF-32 .wslconfig files are not supported"
        )
  | "\xFF\xFE" `ByteString.isPrefixOf` bytes =
      parseUtf16 Utf16LittleEndian (ByteString.drop 2 bytes)
  | "\xFE\xFF" `ByteString.isPrefixOf` bytes =
      parseUtf16 Utf16BigEndian (ByteString.drop 2 bytes)
  | "\xEF\xBB\xBF" `ByteString.isPrefixOf` bytes =
      parseUtf8 True (ByteString.drop 3 bytes)
  | otherwise = parseUtf8 False bytes

parseUtf8 :: Bool -> ByteString -> Either ConfigBytesError ParsedConfig
parseUtf8 hasBom payload = do
  validateUtf8 payload
  if ByteString.elem 0 payload
    then
      Left
        (InvalidWslConfigBytes "UTF-8 .wslconfig contains a NUL code point")
    else do
      (newline, linesValue) <- splitUtf8Lines payload
      pure
        ParsedConfig
          { parsedEncoding = Utf8Encoding hasBom,
            parsedNewline = newline,
            parsedLines = linesValue
          }

parseUtf16 ::
  ConfigEncoding ->
  ByteString ->
  Either ConfigBytesError ParsedConfig
parseUtf16 encoding payload
  | odd (ByteString.length payload) =
      Left (InvalidWslConfigBytes "UTF-16 .wslconfig has an odd byte count")
  | otherwise = do
      let units = decodeUtf16Units encoding payload
      validateUtf16 units
      (newline, lineUnits) <- splitUtf16Lines units
      pure
        ParsedConfig
          { parsedEncoding = encoding,
            parsedNewline = newline,
            parsedLines =
              [ EncodedLine
                  { encodedLineContent = encodeUtf16Units encoding content,
                    encodedLineTerminator = encodeUtf16Units encoding terminator,
                    encodedLineAscii = asciiFromUnits content
                  }
                | (content, terminator) <- lineUnits
              ]
          }

validateUtf8 :: ByteString -> Either ConfigBytesError ()
validateUtf8 = go . ByteString.unpack
  where
    go [] = Right ()
    go (lead : rest)
      | lead <= 0x7F = go rest
      | lead >= 0xC2 && lead <= 0xDF =
          continuation 1 rest >>= go
      | lead == 0xE0 =
          constrained 0xA0 0xBF rest >>= continuation 1 >>= go
      | lead >= 0xE1 && lead <= 0xEC =
          continuation 2 rest >>= go
      | lead == 0xED =
          constrained 0x80 0x9F rest >>= continuation 1 >>= go
      | lead >= 0xEE && lead <= 0xEF =
          continuation 2 rest >>= go
      | lead == 0xF0 =
          constrained 0x90 0xBF rest >>= continuation 2 >>= go
      | lead >= 0xF1 && lead <= 0xF3 =
          continuation 3 rest >>= go
      | lead == 0xF4 =
          constrained 0x80 0x8F rest >>= continuation 2 >>= go
      | otherwise =
          Left (InvalidWslConfigBytes "invalid UTF-8 in .wslconfig")
    continuation count bytes
      | length bytes < count =
          Left (InvalidWslConfigBytes "truncated UTF-8 in .wslconfig")
      | all isContinuation (take count bytes) =
          Right (drop count bytes)
      | otherwise =
          Left (InvalidWslConfigBytes "invalid UTF-8 continuation byte")
    constrained low high bytes =
      case bytes of
        first : rest
          | first >= low && first <= high -> Right rest
        _ -> Left (InvalidWslConfigBytes "invalid UTF-8 scalar value")
    isContinuation byte = byte >= 0x80 && byte <= 0xBF

validateUtf16 :: [Word16] -> Either ConfigBytesError ()
validateUtf16 = go
  where
    go [] = Right ()
    go (unit : rest)
      | unit == 0 =
          Left (InvalidWslConfigBytes "UTF-16 .wslconfig contains NUL")
      | unit >= 0xD800 && unit <= 0xDBFF =
          case rest of
            low : remaining
              | low >= 0xDC00 && low <= 0xDFFF -> go remaining
            _ ->
              Left
                (InvalidWslConfigBytes "invalid UTF-16 surrogate pair")
      | unit >= 0xDC00 && unit <= 0xDFFF =
          Left (InvalidWslConfigBytes "unpaired UTF-16 low surrogate")
      | otherwise = go rest

splitUtf8Lines ::
  ByteString ->
  Either ConfigBytesError (NewlineStyle, [EncodedLine])
splitUtf8Lines payload = do
  (styles, linesValue) <- go payload
  style <- oneNewlineStyle styles
  pure (style, linesValue)
  where
    go remaining
      | ByteString.null remaining = Right ([], [])
      | otherwise =
          let (beforeLf, fromLf) = ByteString.break (== 10) remaining
           in if ByteString.null fromLf
                then do
                  rejectCarriageReturn beforeLf
                  Right
                    ( [],
                      [ EncodedLine
                          { encodedLineContent = beforeLf,
                            encodedLineTerminator = ByteString.empty,
                            encodedLineAscii = asciiFromUtf8 beforeLf
                          }
                      ]
                    )
                else do
                  let hasCr =
                        not (ByteString.null beforeLf)
                          && ByteString.last beforeLf == 13
                      content =
                        if hasCr
                          then ByteString.init beforeLf
                          else beforeLf
                      terminator = if hasCr then "\r\n" else "\n"
                      style = if hasCr then NewlineCrLf else NewlineLf
                  rejectCarriageReturn content
                  (restStyles, restLines) <- go (ByteString.drop 1 fromLf)
                  Right
                    ( style : restStyles,
                      EncodedLine
                        { encodedLineContent = content,
                          encodedLineTerminator = terminator,
                          encodedLineAscii = asciiFromUtf8 content
                        }
                        : restLines
                    )
    rejectCarriageReturn content =
      if ByteString.elem 13 content
        then
          Left
            (InvalidWslConfigBytes "lone CR in UTF-8 .wslconfig")
        else Right ()

splitUtf16Lines ::
  [Word16] ->
  Either
    ConfigBytesError
    (NewlineStyle, [([Word16], [Word16])])
splitUtf16Lines units = do
  (styles, linesValue) <- go units
  style <- oneNewlineStyle styles
  pure (style, linesValue)
  where
    go remaining =
      case break (== 10) remaining of
        (beforeLf, []) -> do
          rejectCarriageReturn beforeLf
          Right ([], [(beforeLf, []) | not (null beforeLf)])
        (beforeLf, _ : rest) -> do
          let hasCr = not (null beforeLf) && last beforeLf == 13
              content = if hasCr then init beforeLf else beforeLf
              terminator = if hasCr then [13, 10] else [10]
              style = if hasCr then NewlineCrLf else NewlineLf
          rejectCarriageReturn content
          (restStyles, restLines) <- go rest
          Right
            (style : restStyles, (content, terminator) : restLines)
    rejectCarriageReturn content =
      if 13 `elem` content
        then Left (InvalidWslConfigBytes "lone CR in UTF-16 .wslconfig")
        else Right ()

oneNewlineStyle ::
  [NewlineStyle] ->
  Either ConfigBytesError NewlineStyle
oneNewlineStyle [] = Right NewlineCrLf
oneNewlineStyle (style : remaining)
  | all (== style) remaining = Right style
  | otherwise =
      Left
        (InvalidWslConfigBytes "mixed LF and CRLF in .wslconfig")

decodeUtf16Units :: ConfigEncoding -> ByteString -> [Word16]
decodeUtf16Units encoding payload =
  go (ByteString.unpack payload)
  where
    go [] = []
    go (first : second : rest) =
      decodeUnit encoding first second : go rest
    go [_] = []

decodeUnit :: ConfigEncoding -> Word8 -> Word8 -> Word16
decodeUnit Utf16LittleEndian low high =
  fromIntegral low .|. shiftL (fromIntegral high) 8
decodeUnit Utf16BigEndian high low =
  shiftL (fromIntegral high) 8 .|. fromIntegral low
decodeUnit (Utf8Encoding _) _ _ = 0

encodeUtf16Units :: ConfigEncoding -> [Word16] -> ByteString
encodeUtf16Units encoding =
  ByteString.pack . concatMap (encodeUnit encoding)

encodeUnit :: ConfigEncoding -> Word16 -> [Word8]
encodeUnit Utf16LittleEndian unit =
  [fromIntegral (unit .&. 0xFF), fromIntegral (shiftR unit 8)]
encodeUnit Utf16BigEndian unit =
  [fromIntegral (shiftR unit 8), fromIntegral (unit .&. 0xFF)]
encodeUnit (Utf8Encoding _) _ = []

asciiFromUnits :: [Word16] -> Maybe ByteString
asciiFromUnits units
  | all (<= 0x7F) units =
      Just (ByteString.pack (map fromIntegral units))
  | otherwise = Nothing

asciiFromUtf8 :: ByteString -> Maybe ByteString
asciiFromUtf8 bytes
  | ByteString.all (<= 0x7F) bytes = Just bytes
  | otherwise = Nothing

encodingBom :: ConfigEncoding -> ByteString
encodingBom (Utf8Encoding False) = ByteString.empty
encodingBom (Utf8Encoding True) = "\xEF\xBB\xBF"
encodingBom Utf16LittleEndian = "\xFF\xFE"
encodingBom Utf16BigEndian = "\xFE\xFF"

encodeAscii :: ConfigEncoding -> ByteString -> ByteString
encodeAscii (Utf8Encoding _) = id
encodeAscii encoding =
  encodeUtf16Units encoding . map fromIntegral . ByteString.unpack

newlineBytes :: ConfigEncoding -> NewlineStyle -> ByteString
newlineBytes encoding style =
  encodeAscii encoding $
    case style of
      NewlineLf -> "\n"
      NewlineCrLf -> "\r\n"

validateExistingAmbiguity ::
  ConfigEncoding ->
  [EncodedLine] ->
  Either ConfigBytesError ()
validateExistingAmbiguity encoding linesValue = do
  if any (isAmbiguousSectionHeader encoding) linesValue
    then
      Left
        ( AmbiguousWslConfig
            "bracket-prefixed line is not an exact section header"
        )
    else Right ()
  let sectionCounts =
        foldl'
          (\counts line -> incrementSection (lineSection line) counts)
          (0 :: Int, 0 :: Int)
          linesValue
  if fst sectionCounts > 1
    then
      Left (AmbiguousWslConfig "duplicate existing [general] sections")
    else Right ()
  if snd sectionCounts > 1
    then
      Left (AmbiguousWslConfig "duplicate existing [wsl2] sections")
    else Right ()
  validateControlledDuplicates encoding linesValue

incrementSection ::
  Maybe ManagedSection ->
  (Int, Int) ->
  (Int, Int)
incrementSection Nothing counts = counts
incrementSection (Just GeneralSection) (generalCount, wslCount) =
  (generalCount + 1, wslCount)
incrementSection (Just Wsl2Section) (generalCount, wslCount) =
  (generalCount, wslCount + 1)

validateControlledDuplicates ::
  ConfigEncoding ->
  [EncodedLine] ->
  Either ConfigBytesError ()
validateControlledDuplicates encoding = go Nothing []
  where
    go _ _ [] = Right ()
    go current seen (line : rest) =
      if isAnySectionHeader encoding line
        then go (lineSection line) [] rest
        else
          case (current, encodedLineSettingKey encoding line) of
            (Just section, Just key)
              | key `elem` controlledKeys section ->
                  if key `elem` seen
                    then
                      Left
                        ( AmbiguousWslConfig
                            ("duplicate controlled key " ++ show key)
                        )
                    else go current (key : seen) rest
            _ -> go current seen rest

transformExisting ::
  ConfigEncoding ->
  NewlineStyle ->
  ManagedWslConfigSpec ->
  [EncodedLine] ->
  TransformedConfig
transformExisting encoding newline spec =
  finish . foldl' step (Nothing, [], [])
  where
    step (current, seenSections, chunks) line =
      if isAnySectionHeader encoding line
        then
          let nextSection = lineSection line
              chunksWithSettings =
                maybe
                  chunks
                  (\section -> appendSettings section chunks)
                  current
              seenNext =
                case nextSection of
                  Nothing -> seenSections
                  Just section ->
                    if section `elem` seenSections
                      then seenSections
                      else section : seenSections
           in ( nextSection,
                seenNext,
                chunksWithSettings ++ [rawLine line]
              )
        else
          let controlled =
                case (current, encodedLineSettingKey encoding line) of
                  (Just section, Just key) ->
                    key `elem` controlledKeys section
                  _ -> False
           in ( current,
                seenSections,
                if controlled then chunks else chunks ++ [rawLine line]
              )
    finish (current, seenSections, chunks) =
      let finalChunks =
            maybe chunks (\section -> appendSettings section chunks) current
       in TransformedConfig
            { transformedHasGeneral = GeneralSection `elem` seenSections,
              transformedHasWsl2 = Wsl2Section `elem` seenSections,
              transformedChunks = finalChunks
            }
    appendSettings section =
      appendAsciiLines
        encoding
        newline
        (managedSettingLines section spec)

appendMissingSections ::
  ConfigEncoding ->
  NewlineStyle ->
  ManagedWslConfigSpec ->
  TransformedConfig ->
  [ByteString]
appendMissingSections encoding newline spec transformed =
  let chunks = transformedChunks transformed
      withGeneral =
        if transformedHasGeneral transformed
          then chunks
          else
            appendAsciiLines
              encoding
              newline
              (managedHeaderAndSettings GeneralSection spec)
              chunks
   in if transformedHasWsl2 transformed
        then withGeneral
        else
          appendAsciiLines
            encoding
            newline
            (managedHeaderAndSettings Wsl2Section spec)
            withGeneral

isAnySectionHeader :: ConfigEncoding -> EncodedLine -> Bool
isAnySectionHeader encoding line =
  -- Exact unrelated headers, including Unicode-named headers, end managed
  -- ownership.  A bracket-prefixed line which is not exact is rejected by
  -- 'validateExistingAmbiguity' before transformation; accepting it merely as
  -- a boundary could otherwise make us append a second managed section after
  -- syntax whose meaning we do not know.
  case trimAsciiUnits (encodedLineUnits encoding line) of
    91 : rest ->
      case reverse rest of
        93 : interiorReversed -> not (null interiorReversed)
        _ -> False
    _ -> False

isAmbiguousSectionHeader :: ConfigEncoding -> EncodedLine -> Bool
isAmbiguousSectionHeader encoding line =
  case dropWhile isAsciiSpaceUnit (encodedLineUnits encoding line) of
    91 : _ -> not (isAnySectionHeader encoding line)
    _ -> False

encodedLineSettingKey ::
  ConfigEncoding ->
  EncodedLine ->
  Maybe ByteString
encodedLineSettingKey encoding line = do
  -- The value is intentionally not decoded as ASCII.  Only the key prefix
  -- through the first '=' participates in ownership detection, so a valid
  -- Unicode value or inline comment cannot hide a controlled key.  The raw
  -- encoded line remains untouched unless that ASCII prefix names one of the
  -- controlled keys.
  prefix <- asciiPrefixThroughEquals (encodedLineUnits encoding line)
  settingKey prefix

asciiPrefixThroughEquals :: [Word16] -> Maybe ByteString
asciiPrefixThroughEquals units =
  case break (== 61) units of
    (prefix, 61 : _)
      | all (<= 0x7F) prefix ->
          Just
            ( ByteString.pack (map fromIntegral prefix)
                <> "="
            )
    _ -> Nothing

encodedLineUnits :: ConfigEncoding -> EncodedLine -> [Word16]
encodedLineUnits encoding line =
  case encoding of
    Utf8Encoding _ ->
      -- UTF-8 validation has already run.  Mapping bytes is sufficient here
      -- because both section punctuation and the key prefix are ASCII; every
      -- non-ASCII UTF-8 byte is greater than 0x7f and therefore cannot be
      -- mistaken for syntax.
      map fromIntegral (ByteString.unpack (encodedLineContent line))
    Utf16LittleEndian ->
      decodeUtf16Units encoding (encodedLineContent line)
    Utf16BigEndian ->
      decodeUtf16Units encoding (encodedLineContent line)

isAsciiSpaceUnit :: Word16 -> Bool
isAsciiSpaceUnit unit = unit == 32 || unit == 9 || unit == 12

trimAsciiUnits :: [Word16] -> [Word16]
trimAsciiUnits =
  reverse
    . dropWhile isAsciiSpaceUnit
    . reverse
    . dropWhile isAsciiSpaceUnit

appendAsciiLines ::
  ConfigEncoding ->
  NewlineStyle ->
  [ByteString] ->
  [ByteString] ->
  [ByteString]
appendAsciiLines encoding newline linesValue chunks =
  let separator =
        if null chunks || endsInNewline encoding chunks
          then []
          else [newlineBytes encoding newline]
      encoded =
        [ encodeAscii encoding line <> newlineBytes encoding newline
          | line <- linesValue
        ]
   in chunks ++ separator ++ encoded

endsInNewline :: ConfigEncoding -> [ByteString] -> Bool
endsInNewline encoding chunks =
  case reverse chunks of
    [] -> False
    lastChunk : _ ->
      newlineBytes encoding NewlineLf `ByteString.isSuffixOf` lastChunk

managedHeaderAndSettings ::
  ManagedSection ->
  ManagedWslConfigSpec ->
  [ByteString]
managedHeaderAndSettings section spec =
  managedHeader section spec : managedSettingLines section spec

managedHeader ::
  ManagedSection ->
  ManagedWslConfigSpec ->
  ByteString
managedHeader GeneralSection = managedGeneralHeader
managedHeader Wsl2Section = managedWsl2Header

managedSettingLines ::
  ManagedSection ->
  ManagedWslConfigSpec ->
  [ByteString]
managedSettingLines GeneralSection spec = [managedGeneralSetting spec]
managedSettingLines Wsl2Section spec = managedWsl2Settings spec

controlledKeys :: ManagedSection -> [ByteString]
controlledKeys GeneralSection = ["instanceidletimeout"]
controlledKeys Wsl2Section =
  ["processors", "memory", "swap", "vmidletimeout"]

lineSection :: EncodedLine -> Maybe ManagedSection
lineSection line =
  case encodedLineAscii line >>= sectionName of
    Just "general" -> Just GeneralSection
    Just "wsl2" -> Just Wsl2Section
    _ -> Nothing

rawLine :: EncodedLine -> ByteString
rawLine line =
  encodedLineContent line <> encodedLineTerminator line

settingKey :: ByteString -> Maybe ByteString
settingKey = fmap fst . settingKeyAndValue

settingKeyAndValue :: ByteString -> Maybe (ByteString, ByteString)
settingKeyAndValue line
  | ByteString.null trimmed = Nothing
  | ByteString.head trimmed == 35 || ByteString.head trimmed == 59 = Nothing
  | otherwise =
      let (key, suffix) = ByteString.break (== 61) trimmed
       in if ByteString.null suffix || ByteString.null (asciiTrim key)
            then Nothing
            else
              Just
                ( lowerBytes (asciiTrim key),
                  ByteString.drop 1 suffix
                )
  where
    trimmed = asciiTrim line

sectionName :: ByteString -> Maybe ByteString
sectionName line =
  let trimmed = asciiTrim line
   in if ByteString.length trimmed >= 3
        && ByteString.head trimmed == 91
        && ByteString.last trimmed == 93
        then
          Just
            (lowerBytes (asciiTrim (ByteString.init (ByteString.tail trimmed))))
        else Nothing

asciiTrim :: ByteString -> ByteString
asciiTrim =
  ByteString.dropWhileEnd isAsciiSpace . ByteString.dropWhile isAsciiSpace

isAsciiSpace :: Word8 -> Bool
isAsciiSpace byte = byte == 32 || byte == 9 || byte == 12

lowerBytes :: ByteString -> ByteString
lowerBytes = ByteString.map lowerAscii

lowerAscii :: Word8 -> Word8
lowerAscii byte
  | byte >= 65 && byte <= 90 = byte + 32
  | otherwise = byte
