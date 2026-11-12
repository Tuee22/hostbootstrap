{-# LANGUAGE OverloadedStrings #-}

{- | What a host provider says about an instance, as one total classification.

A driver that holds ownership clauses over a provider instance has to know two
things about it: whether the provider names it at all, and what stable identity
the provider gives it. Both answers arrive as bytes on a described command's
standard output (§ KK), and this module is the one place those bytes become
values.

The point is that the /report/ and the /decision/ are the same value. A driver
that rendered a report and then re-parsed it would have two answers to the same
question, each checked only against itself; here the classifier's result is the
thing the seam's reported face is held over
("HostBootstrap.Ownership.Primitive"), so a driver has nothing left to
interpret.

Nothing in this module executes anything. Every function is total over the
interpreter's own outcome — @Left@ for a command that produced no child, @Right@
for one that ran — so every refusal is reachable by application over values and
needs no substitution point to be exercised (§ NN).

The bounds are deliberate. A provider is another program's output, so a report
that is too long, that carries a control character, that names a lifecycle state
this vocabulary does not have, or that lists the same instance twice is a
__refusal__ rather than a value: a driver comparing an identity it did not
understand would be answering a question nobody asked.
-}
module HostBootstrap.Substrate.Provider.Report (
    -- * What a provider reports about an instance
    ProviderRunState (..),
    allProviderRunStates,
    ProviderListing (..),
    ProviderConfigValue (ProviderConfigUnset),
    providerConfigValueText,

    -- * Why a report could not be read
    ProviderReportFault (..),
    providerReportFaultMessage,

    -- * The total classifiers
    classifyProviderReport,
    classifyProviderListing,
    classifyProviderConfigValue,
    classifyProviderIdentity,
    providerObservedOrigin,
    encodeProviderNativeObservation,
    classifyProviderNativeObservation,
    encodeProviderNativeRefusal,
    classifyProviderNativeRefusal,
    identityObservationVersion,

    -- * Declared sizing and the observations compared with it
    ProviderSizingObservation (..),
    providerSizingBudget,
    incusQuantityBytes,
    incusSizingBudget,
    classifyIncusSizing,
    providerSizingMatches,
    declaredSizingText,
    observedSizingText,
    sizingConflictRemedy,

    -- * Native guest-VM observations
    LimaInstanceReport,
    limaInstanceListing,
    limaInstanceDirectory,
    limaInstanceClaim,
    limaInstanceSizing,
    classifyLimaInstanceReport,
    wslLocationClaim,

    -- * The bounds a report is admitted under
    providerReportLineBound,
    providerConfigValueBound,
)
where

import qualified Data.Aeson as Aeson
import Data.Bits (xor)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as LazyBytes
import Data.Aeson ((.:), (.:?), (.!=))
import qualified Data.Aeson.Types as Aeson
import Data.List (stripPrefix)
import qualified Data.Map.Strict as Map
import Data.Char (GeneralCategory (Format), generalCategory, isAlphaNum, isControl)
import Data.Int (Int64)
import Data.Word (Word64)
import Text.Read (readMaybe)
import HostBootstrap.Cluster.Cordon (budgetFromResources)
import HostBootstrap.Cluster.Cordon.Foundation (ResourceBudget, mkResourceBudget, budgetCpu, budgetMemoryBytes, budgetStorageBytes)
import HostBootstrap.Context (ResourceEnvelope (ResourceEnvelope))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Effect.Run (CapturedRun (capturedExit, capturedStderr, capturedStdout))
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    OwnerClaim,
    ownerClaimText,
    Origin (OriginAbsent, OriginPresent),
    mkObjectIdentity,
    ownershipFaultMessage,
    objectIdentityText,
    parseObjectIdentityHex,
 )
import HostBootstrap.Reconcile (ReconcileError (Conflict, Unsupported), ConflictDetail (..), UnsupportedDetail (..))
import HostBootstrap.Substrate.Provider.Command (ProviderSizing (..), limaOwnerEnvironmentKey)
import HostBootstrap.Wsl2.Registration (WslRegistration, wslRegistrationInstallPath)
import qualified System.FilePath.Posix as PosixPath
import qualified System.FilePath.Windows as WindowsPath
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

-- ---------------------------------------------------------------------------
-- What a provider reports

{- | The lifecycle states a clause-holding driver admits.

Two, because two are the states an ownership transaction can act from: a running
instance can be stopped and a stopped one can be deleted. Every other state a
provider might name — freezing, erroring, migrating — is a report this
vocabulary does not understand, and is refused rather than mapped onto whichever
of these two is closer.
-}
data ProviderRunState
    = ProviderRunning
    | ProviderStopped
    deriving (Eq, Ord, Show, Enum, Bounded)

-- | Every state, so a table over them is total.
allProviderRunStates :: [ProviderRunState]
allProviderRunStates = [minBound .. maxBound]

{- | One row of the provider's own instance listing.

The name is carried beside the state because the provider matches a listing
argument by prefix: a listing asked about @demo@ can answer for @demo-2@ as
well, and a row that does not name the exact instance is not about it.
-}
data ProviderListing = ProviderListing
    { listedInstance :: String
    , listedState :: ProviderRunState
    }
    deriving (Eq, Show)

{- | One configuration value a provider answered for.

An unset key and a key set to the empty string produce the same provider
answer, represented by 'ProviderConfigUnset'. The non-empty branch is private
and produced only by the report classifier; 'providerConfigValueText' presents
its text without offering unchecked construction.
-}
data ProviderConfigValue
    = ProviderConfigUnset
    | ProviderConfigValue Text
    deriving (Eq, Show)

-- | Nothing for an unset key, or the exact non-empty value the report admitted.
providerConfigValueText :: ProviderConfigValue -> Maybe Text
providerConfigValueText ProviderConfigUnset = Nothing
providerConfigValueText (ProviderConfigValue value) = Just value

-- ---------------------------------------------------------------------------
-- Why a report could not be read

{- | The closed set of reasons a report is not a value.

The four are genuinely distinct to whoever reads them: a command that never ran
names a host that could not launch it, a non-zero exit names the provider's own
diagnostic, a noisy success names output on the wrong stream, and an unreadable
report names bytes outside the shape this module admits.
-}
data ProviderReportFault
    = -- | no child existed, so nothing was reported at all
      ProviderCommandUnrun Text
    | -- | the provider ran and refused, with its own first diagnostic line
      ProviderCommandExited Int Text
    | -- | the provider succeeded and wrote to standard error
      ProviderCommandNoisy Text
    | -- | the provider succeeded and reported something this vocabulary does not admit
      ProviderReportUnreadable Text
    deriving (Eq, Show)

-- | One rendering, so a driver never writes a second description of a refusal.
providerReportFaultMessage :: ProviderReportFault -> Text
providerReportFaultMessage fault = case fault of
    ProviderCommandUnrun reason ->
        "the provider command produced no process: " <> reason
    ProviderCommandExited code diagnostic ->
        "the provider command exited " <> Text.pack (show code) <> ": " <> diagnostic
    ProviderCommandNoisy diagnostic ->
        "the provider command succeeded and wrote to standard error: " <> diagnostic
    ProviderReportUnreadable reason ->
        "the provider report is not one this vocabulary admits: " <> reason

-- ---------------------------------------------------------------------------
-- The bounds

{- | The widest single line a provider report may carry.

Wide enough for an instance name beside a state and for the longest identity a
provider mints, narrow enough that a program answering with a document is
refused rather than scanned.
-}
providerReportLineBound :: Int
providerReportLineBound = 512

{- | The widest configuration value admitted.

This 240-character bound covers owner tags and device properties. An identity
is admitted again by 'mkObjectIdentity', whose separate ceiling is 64 bytes.
-}
providerConfigValueBound :: Int
providerConfigValueBound = 240

-- ---------------------------------------------------------------------------
-- The total classifiers

{- | The instance listing, reduced to the one row that names this instance.

@Right Nothing@ is an authoritative absence: the provider answered, and what it
answered does not name this instance. A duplicate row for the exact name is a
refusal rather than a choice between them, because a driver that picked one
would be deciding which of two disagreeing answers to own.
-}
classifyProviderListing ::
    -- | the exact instance the driver is asking about
    String ->
    Either String CapturedRun ->
    Either ProviderReportFault (Maybe ProviderListing)
classifyProviderListing instanceName captured = do
    candidates <- classifyProviderReport providerReportLineBound captured
    if any (null . rowName) candidates
        then unreadable "a listing row names no instance"
        else case filter ((== instanceName) . rowName) candidates of
            [] -> Right Nothing
            [line] -> Just <$> listingRow line
            _ ->
                unreadable
                    ( "the provider listed "
                        <> Text.pack (show instanceName)
                        <> " more than once"
                    )
  where
    rowName = takeWhile (/= ',')

listingRow :: String -> Either ProviderReportFault ProviderListing
listingRow line = case splitOnComma line of
    [name, state] -> ProviderListing name <$> runState state
    _ -> unreadable ("a listing row is not a name and a state: " <> Text.pack (show line))

runState :: String -> Either ProviderReportFault ProviderRunState
runState "RUNNING" = Right ProviderRunning
runState "STOPPED" = Right ProviderStopped
runState other =
    unreadable
        ( "the provider reported the lifecycle state "
            <> Text.pack (show other)
            <> ", which is neither RUNNING nor STOPPED"
        )

{- | One configuration value, or an authoritative absence.

A provider answers an unset key and an empty value with the same empty line,
so both are 'ProviderConfigUnset'. A non-empty answer is one bounded line.
-}
classifyProviderConfigValue ::
    Either String CapturedRun ->
    Either ProviderReportFault ProviderConfigValue
classifyProviderConfigValue captured = do
    reportedLines <- classifyProviderReport providerReportLineBound captured
    case reportedLines of
        [] -> Right ProviderConfigUnset
        [value]
            | length value > providerConfigValueBound ->
                unreadable "the provider reported a configuration value past the admitted bound"
            | otherwise -> Right (ProviderConfigValue (Text.pack value))
        _ -> unreadable "the provider reported more than one line for one configuration key"

{- | The instance's stable identity, as the seam admits identities.

@Right Nothing@ means the provider carries no identity for this key, which is
what an absent instance answers. A value the identity grammar does not admit is
a refusal rather than an identity, so a comparison is never made against
something this vocabulary could not read.
-}
classifyProviderIdentity ::
    Either String CapturedRun ->
    Either ProviderReportFault (Maybe ObjectIdentity)
classifyProviderIdentity captured = do
    value <- classifyProviderConfigValue captured
    case value of
        ProviderConfigUnset -> Right Nothing
        ProviderConfigValue raw
            | not (Text.all identityCharacter raw) ->
                unreadable
                    ( "the provider reported an identity outside the admitted grammar: "
                        <> Text.pack (show (Text.unpack raw))
                    )
            | otherwise ->
                case mkObjectIdentity (TextEncoding.encodeUtf8 raw) of
                    Left fault -> unreadable (ownershipFaultMessage fault)
                    Right identity -> Right (Just identity)

identityCharacter :: Char -> Bool
identityCharacter character = isAlphaNum character || character `elem` (":._-" :: String)

{- | The observation the seam's reported face is held over.

This is the whole join between a provider's answers and the four clauses: a
listing says whether the instance is there and an identity read says which one
it is, and the two must agree. An instance that is listed without an identity and
an identity reported for an instance that is not listed are each a refusal,
because each is the provider contradicting itself and neither is a state a clause
could be held over.
-}
providerObservedOrigin ::
    Maybe ProviderListing ->
    Maybe ObjectIdentity ->
    Either ProviderReportFault Origin
providerObservedOrigin listing identity = case (listing, identity) of
    (Nothing, Nothing) -> Right OriginAbsent
    (Just _, Just observed) -> Right (OriginPresent observed)
    (Nothing, Just _) ->
        unreadable
            "the provider reports an identity for an instance it does not list"
    (Just row, Nothing) ->
        unreadable
            ( "the provider lists "
                <> Text.pack (show (listedInstance row))
                <> " and reports no stable identity for it"
            )

{- | Ordinary sizing evidence, never a provider identity or ownership receipt.

A native VM supplies all three quantities. WSL's installed disk cap supplies
only storage; CPU and memory belong to the separately verified shared wall.
-}
data ProviderSizingObservation
    = NativeProviderSizing ResourceBudget
    | RecordedWslStorage Integer
    deriving (Eq, Show)

-- | Apply the one quantity grammar to the declared instance sizing.
providerSizingBudget :: ProviderSizing -> Either ProviderReportFault ResourceBudget
providerSizingBudget sizing =
    case budgetFromResources (ResourceEnvelope (fromIntegral (sizingCpu sizing))
        (Text.pack (sizingMemory sizing)) (Text.pack (sizingStorage sizing))) of
        Left failure -> unreadable ("invalid provider sizing: " <> Text.take 512 (Text.pack (show failure)))
        Right budget -> Right budget

{- | Incus's exact byte syntax, shared with backend admission.

This is the native protocol adapter. The normalized bytes still enter the
canonical positive ResourceBudget constructor; no unit table is copied into
the transaction or its mismatch renderer.
-}
incusQuantityBytes :: String -> Maybe Integer
incusQuantityBytes raw =
    case (readMaybe digits :: Maybe Integer, lookup suffix unitFactors) of
        (Just amount, Just scale)
            | amount * scale <= toInteger (maxBound :: Int64) -> Just (amount * scale)
        _ -> Nothing
  where
    (digits, suffix) = span (\character -> character >= '0' && character <= '9') raw
    unitFactors =
        [("", 1), ("B", 1), (" bytes", 1)]
            <> zip ["kB", "MB", "GB", "TB", "PB", "EB"] (take 6 (iterate (* 1000) 1000))
            <> zip ["KiB", "MiB", "GiB", "TiB", "PiB", "EiB"] (take 6 (iterate (* 1024) 1024))

incusSizingBudget :: ProviderSizing -> Either ProviderReportFault ResourceBudget
incusSizingBudget sizing = do
    memory <- nativeBytes (sizingMemory sizing)
    storage <- nativeBytes (sizingStorage sizing)
    case mkResourceBudget (fromIntegral (sizingCpu sizing)) memory storage of
        Left failure -> unreadable ("invalid provider sizing: " <> Text.take 512 (Text.pack (show failure)))
        Right budget -> Right budget
  where
    nativeBytes raw = maybe (unreadable "invalid provider sizing: an Incus byte quantity is not representable")
        Right (incusQuantityBytes raw)

-- | Read an Incus CPU count, memory limit and root-device size through the common boundary.
classifyIncusSizing ::
    Either String CapturedRun -> Either String CapturedRun -> Either String CapturedRun ->
    Either ProviderReportFault ProviderSizingObservation
classifyIncusSizing cpuReport memoryReport storageReport = do
    cores <- required "CPU count" cpuReport
    memory <- required "memory limit" memoryReport
    storage <- required "root-device size" storageReport
    count <- case readMaybe (Text.unpack cores) :: Maybe Integer of
        Just value | value > 0 && value <= toInteger (maxBound :: Word64) && Text.all (\c -> c >= '0' && c <= '9') cores -> Right (fromInteger value)
        _ -> unreadable "the native CPU limit is not a positive representable CPU count"
    NativeProviderSizing <$> incusSizingBudget (ProviderSizing count (Text.unpack memory) (Text.unpack storage))
  where
    required label captured = do
        value <- classifyProviderConfigValue captured
        maybe (unreadable ("native sizing omits the " <> label)) Right (providerConfigValueText value)

-- | Compare only quantities the observation actually knows.
providerSizingMatches :: ResourceBudget -> ProviderSizingObservation -> Bool
providerSizingMatches declared observed = case observed of
    NativeProviderSizing actual -> declared == actual
    RecordedWslStorage bytes -> budgetStorageBytes declared == bytes

declaredSizingText :: ResourceBudget -> Text
declaredSizingText budget =
    "cpu=" <> Text.pack (show (budgetCpu budget))
        <> ", memory=" <> Text.pack (show (budgetMemoryBytes budget)) <> " bytes"
        <> ", storage=" <> Text.pack (show (budgetStorageBytes budget)) <> " bytes"

observedSizingText :: ProviderSizingObservation -> Text
observedSizingText observed = case observed of
    NativeProviderSizing budget -> declaredSizingText budget
    RecordedWslStorage bytes ->
        "cpu=shared WSL2 wall, memory=shared WSL2 wall, storage="
            <> Text.pack (show bytes) <> " bytes (recorded installation cap)"

sizingConflictRemedy :: Text
sizingConflictRemedy = "destroy and reprovision the owned provider with the declared sizing"

-- | One admitted native Lima row. Its directory still needs kernel identity.
data LimaInstanceReport = LimaInstanceReport
    { limaInstanceListing :: ProviderListing
    , limaInstanceDirectory :: FilePath
    , limaInstanceClaim :: ProviderConfigValue
    , limaInstanceSizing :: ResourceBudget
    } deriving (Eq, Show)

{- | Read native newline-delimited JSON through the common stream boundary.

Only the exact instance is selected. The directory is a bounded absolute POSIX
path and the claim is ordinary metadata; neither alone authorizes adoption.
Escaped controls are checked after JSON decoding as well as on the wire.
-}
classifyLimaInstanceReport ::
    String -> Either String CapturedRun -> Either ProviderReportFault (Maybe LimaInstanceReport)
classifyLimaInstanceReport wanted captured = do
    rows <- classifyProviderReport 65536 captured
    parsed <- traverse parseRow rows
    if any (not . validName . rowName) parsed
        then unreadable "a Lima JSON row has an unreadable instance name"
        else case filter ((== wanted) . rowName) parsed of
            [] -> Right Nothing
            [row] -> Just <$> admitRow row
            _ -> unreadable "the Lima report repeats the exact instance name"
  where
    rowName (name, _, _, _, _, _) = name
    validName name = not (null name) && length name <= providerConfigValueBound && all (not . reportControl) name
    parseRow line = case Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack line)) >>= Aeson.parseEither nativeRow of
        Left _ -> unreadable "the Lima instance row is not valid native JSON"
        Right row -> Right row
    admitRow (name, state, directory, claim, errors, sizing)
        | not (null errors) = unreadable "the Lima instance reports native errors"
        | length directory > 4096 || not (PosixPath.isAbsolute directory)
            || any reportControl directory
            || any (`elem` [".", ".."]) (PosixPath.splitDirectories directory)
            || PosixPath.takeFileName (PosixPath.dropTrailingPathSeparator directory) /= name =
                unreadable "the Lima instance directory is not a bounded absolute path for this name"
        | otherwise = do
            running <- case state of
                "Running" -> Right ProviderRunning
                "Stopped" -> Right ProviderStopped
                _ -> unreadable "the Lima instance state is neither Running nor Stopped"
            carried <- case claim of
                Nothing -> Right ProviderConfigUnset
                Just value
                    | null value -> Right ProviderConfigUnset
                    | length value > providerConfigValueBound || any reportControl value ->
                        unreadable "the Lima creation claim is not bounded control-free text"
                    | otherwise -> Right (ProviderConfigValue (Text.pack value))
            budget <- nativeBudget sizing
            Right (LimaInstanceReport (ProviderListing name running) directory carried budget)
    nativeBudget (Just cores, Just memory, Just disk)
        | cores <= 0 = unreadable "the Lima native CPU count is not positive"
        | otherwise = case mkResourceBudget (fromIntegral cores) (toInteger memory) (toInteger disk) of
            Left failure -> unreadable ("invalid Lima sizing: " <> Text.pack (show failure))
            Right budget -> Right budget
    nativeBudget _ = unreadable "the Lima instance omits native sizing"

nativeRow :: Aeson.Value -> Aeson.Parser (String, String, FilePath, Maybe String, [String], (Maybe Int64, Maybe Int64, Maybe Int64))
nativeRow = Aeson.withObject "Lima instance" $ \row -> do
    config <- row .:? "config"
    environment <- case config of
        Nothing -> pure Map.empty
        Just settings -> settings .:? "env" .!= Map.empty
    (,,,,,) <$> row .: "name" <*> row .: "status" <*> row .: "dir"
        <*> pure (Map.lookup limaOwnerEnvironmentKey environment) <*> (row .:? "errors" .!= [])
        <*> ((,,) <$> row .:? "cpus" <*> row .:? "memory" <*> row .:? "disk")

{- | The claim of the exact owned WSL location, never of a listed name alone.

Extended drive and UNC spellings name the same Windows location. The original
native path remains in the registration observation; this comparison writes
nothing and the VM transaction separately binds the actual registration GUID.
-}
wslLocationClaim :: FilePath -> OwnerClaim -> WslRegistration -> ProviderConfigValue
wslLocationClaim expected claim registration
    | WindowsPath.equalFilePath (ordinary expected) (ordinary (wslRegistrationInstallPath registration)) =
        ProviderConfigValue (ownerClaimText claim)
    | otherwise = ProviderConfigUnset
  where
    ordinary path
        | Just unc <- stripPrefix "\\\\?\\UNC\\" path = "\\\\" <> unc
        | Just drive <- stripPrefix "\\\\?\\" path = drive
        | otherwise = path

-- ---------------------------------------------------------------------------
-- Shared steps

{- | What a provider actually reported, or why nothing it wrote is an answer.

Every classifier in this module starts here, and so does every driver that reads
a report this module has no vocabulary for. That is the point: "the command
produced no child", "the provider exited non-zero", "the provider succeeded and
complained on the wrong stream", and "the provider wrote something outside the
admitted shape" are one decision, taken once, rather than four decisions taken
per question and drifting apart.

The line bound is the caller's because it is a property of the question rather
than of the transport: an instance name beside a state and an identity are
narrow, and a report carrying an encoded guest stream is not. Everything else —
what counts as a child, what counts as quiet, which characters a report may
carry, and that a trailing newline is not a row — is decided here for all of
them.

Total over the interpreter's own outcome, so every refusal is reachable by
application over values and needs no substitution point (§ NN).
-}
classifyProviderReport ::
    -- | the widest single line this question admits
    Int ->
    Either String CapturedRun ->
    Either ProviderReportFault [String]
classifyProviderReport lineBound captured = do
    reported <- capturedReport captured
    reportLines lineBound reported

-- | The captured standard output of a command that ran and succeeded quietly.
capturedReport :: Either String CapturedRun -> Either ProviderReportFault String
capturedReport (Left refusal) = Left (ProviderCommandUnrun (Text.pack refusal))
capturedReport (Right run) = case capturedExit run of
    ExitFailure code -> Left (ProviderCommandExited code (firstLine (capturedStderr run)))
    ExitSuccess
        | not (null (capturedStderr run)) ->
            Left (ProviderCommandNoisy (firstLine (capturedStderr run)))
        | otherwise -> Right (capturedStdout run)

{- | The report's own lines: non-empty, bounded, and free of control characters.

A blank line is dropped rather than refused, because a trailing newline is how
every one of these commands ends its output and is not a row.
-}
reportLines :: Int -> String -> Either ProviderReportFault [String]
reportLines lineBound reported
    | any (> lineBound) (map length candidates) =
        unreadable "the provider report carries a line past the admitted bound"
    | any (any reportControl) candidates =
        unreadable "the provider report carries a control character"
    | otherwise = Right candidates
  where
    candidates = filter (not . null) (map trimCarriageReturn (lines reported))

-- | Characters that cannot participate in reports or rendered diagnostics.
reportControl :: Char -> Bool
reportControl character = isControl character || generalCategory character == Format

{- | Drop one trailing carriage return.

A provider's own output is line-oriented and a host that terminates lines with
@CRLF@ is describing the same rows, so the carriage return is not part of a
name, a state, or an identity.
-}
trimCarriageReturn :: String -> String
trimCarriageReturn value = case reverse value of
    '\r' : rest -> reverse rest
    _ -> value

-- | Split one line on commas, keeping empty fields so an arity check can see them.
splitOnComma :: String -> [String]
splitOnComma line = reverse (map reverse (foldl' step [""] line))
  where
    step fields ',' = "" : fields
    step (current : rest) character = (character : current) : rest
    step [] character = [[character]]

-- | The first line of a diagnostic, bounded, or a stand-in when there is none.
firstLine :: String -> Text
firstLine value = case filter (not . null) (map clean (lines value)) of
    [] -> "no diagnostic"
    (line : _) -> Text.pack (take providerReportLineBound line)
  where
    clean = filter (not . reportControl) . trimCarriageReturn

unreadable :: Text -> Either ProviderReportFault value
unreadable = Left . ProviderReportUnreadable

-- | Ordinary metadata; neither encoding nor decoding proves native provenance.
encodeProviderNativeObservation :: Text -> ObjectIdentity -> Either ProviderReportFault Text
encodeProviderNativeObservation ready identity
    | Text.null ready || Text.length ready > 256 || Text.any isControl ready =
        Left (ProviderReportUnreadable "the provider ready commitment is empty, overlong or contains controls")
    | otherwise = Right (TextEncoding.decodeUtf8 (LazyBytes.toStrict
        (Aeson.encode ["hostbootstrap/provider-native-observation/v1", ready, objectIdentityText identity])))

-- | One bounded canonical JSON tuple, decoded through the existing identity codec.
classifyProviderNativeObservation :: Text -> Either ProviderReportFault (Text, ObjectIdentity)
classifyProviderNativeObservation raw
    | Bytes.length wire > 2048 =
        Left (ProviderReportUnreadable "the provider native observation exceeds its bound")
    | otherwise = case Aeson.eitherDecodeStrict' wire :: Either String [Text] of
        Right [version, ready, identityHex]
            | version /= "hostbootstrap/provider-native-observation/v1" ->
                Left (ProviderReportUnreadable "the provider native observation has an unknown version")
            | otherwise -> do
                identity <- either (Left . ProviderReportUnreadable . ownershipFaultMessage) Right
                    (parseObjectIdentityHex identityHex)
                canonical <- encodeProviderNativeObservation ready identity
                if canonical == raw then Right (ready, identity)
                    else Left (ProviderReportUnreadable "the provider native observation is not canonical")
        _ -> Left (ProviderReportUnreadable "the provider native observation is not a complete JSON tuple")
  where
    wire = TextEncoding.encodeUtf8 raw

{- | The existing positive observation hash, kept byte-for-byte in behavior.

This is an ordinary observation token. It is not a logical plan generation or
native provenance. The owner still compares complete native identities.
-}
identityObservationVersion :: String -> Word64
identityObservationVersion = max 1 . foldl step 1469598103934665603
  where
    step acc character = (acc `xor` fromIntegral (fromEnum character)) * 1099511628211

-- | A bounded ordinary refusal envelope preserves its sum across the owner relay.
encodeProviderNativeRefusal :: ReconcileError -> Maybe Text
encodeProviderNativeRefusal failure = do
    fields <- case failure of
        Conflict (ConflictDetail key expected actual remedy) ->
            Just ["hostbootstrap/provider-native-refusal/v1", "conflict", key, expected, actual, remedy]
        Unsupported (UnsupportedDetail operation reason) ->
            Just ["hostbootstrap/provider-native-refusal/v1", "unsupported", operation, reason]
        _ -> Nothing
    let wire = LazyBytes.toStrict (Aeson.encode fields)
    if Bytes.length wire <= 4096 then Just (TextEncoding.decodeUtf8 wire) else Nothing

-- | Decode data only; the caller separately verifies package commitment and nonce.
classifyProviderNativeRefusal :: Text -> Maybe ReconcileError
classifyProviderNativeRefusal raw
    | Bytes.length wire > 4096 = Nothing
    | otherwise = do
        fields <- either (const Nothing) Just (Aeson.eitherDecodeStrict' wire :: Either String [Text])
        failure <- case fields of
            ["hostbootstrap/provider-native-refusal/v1", "conflict", key, expected, actual, remedy] ->
                Just (Conflict (ConflictDetail key expected actual remedy))
            ["hostbootstrap/provider-native-refusal/v1", "unsupported", operation, reason] ->
                Just (Unsupported (UnsupportedDetail operation reason))
            _ -> Nothing
        if encodeProviderNativeRefusal failure == Just raw then Just failure else Nothing
  where
    wire = TextEncoding.encodeUtf8 raw
