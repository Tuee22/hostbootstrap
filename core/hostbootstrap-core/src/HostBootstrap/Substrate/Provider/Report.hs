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
    ProviderConfigValue (..),

    -- * Why a report could not be read
    ProviderReportFault (..),
    providerReportFaultMessage,

    -- * The total classifiers
    classifyProviderListing,
    classifyProviderConfigValue,
    classifyProviderIdentity,
    providerObservedOrigin,

    -- * The bounds a report is admitted under
    providerReportLineBound,
    providerConfigValueBound,
)
where

import Data.Char (isAlphaNum)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Effect.Run (CapturedRun (capturedExit, capturedStderr, capturedStdout))
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    Origin (OriginAbsent, OriginPresent),
    mkObjectIdentity,
    ownershipFaultMessage,
 )
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

An unset key is an answer rather than an error, because that is how a provider
reports a key an instance does not carry — and telling it apart from a key whose
value is empty is exactly what a driver comparing an owner tag needs.
-}
data ProviderConfigValue
    = ProviderConfigUnset
    | ProviderConfigValue Text
    deriving (Eq, Show)

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

The same ceiling the identity grammar uses, because the value most often read
through it /is/ an identity.
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
    reported <- capturedReport captured
    candidates <- reportLines reported
    rows <- traverse listingRow candidates
    case filter ((== instanceName) . listedInstance) rows of
        [] -> Right Nothing
        [row] -> Right (Just row)
        _ ->
            unreadable
                ( "the provider listed "
                    <> Text.pack (show instanceName)
                    <> " more than once"
                )

listingRow :: String -> Either ProviderReportFault ProviderListing
listingRow line = case splitOnComma line of
    [name, state]
        | null name -> unreadable "a listing row names no instance"
        | otherwise -> ProviderListing name <$> runState state
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

A provider answers an unset key with nothing at all, so an empty report is
'ProviderConfigUnset' and anything else is exactly one bounded line.
-}
classifyProviderConfigValue ::
    Either String CapturedRun ->
    Either ProviderReportFault ProviderConfigValue
classifyProviderConfigValue captured = do
    reported <- capturedReport captured
    reportedLines <- reportLines reported
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

-- ---------------------------------------------------------------------------
-- Shared steps

{- | The captured standard output of a command that ran and succeeded quietly.

Every classifier starts here, so "what counts as an answer at all" is decided
once rather than per question.
-}
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
reportLines :: String -> Either ProviderReportFault [String]
reportLines reported
    | any (> providerReportLineBound) (map length candidates) =
        unreadable "the provider report carries a line past the admitted bound"
    | any (any control) candidates =
        unreadable "the provider report carries a control character"
    | otherwise = Right candidates
  where
    candidates = filter (not . null) (map trimCarriageReturn (lines reported))
    control character = character < ' ' || character == '\DEL'

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
firstLine value = case filter (not . null) (map trimCarriageReturn (lines value)) of
    [] -> "no diagnostic"
    (line : _) -> Text.pack (take providerReportLineBound line)

unreadable :: Text -> Either ProviderReportFault value
unreadable = Left . ProviderReportUnreadable
