{-# LANGUAGE OverloadedStrings #-}

{- | What an owned object /is/, stated once and without effects.

@development_plan_standards.md § EE@ says a resource this project mutates must be
owned under four clauses: exclusive entry the kernel releases, a durable origin
record published before the object exists, the created object's own identity
bound to that record, and release conditional on re-observing that identity.

Those clauses are one transaction, and a transaction needs nouns. This module is
the nouns: the kernel's answer for an object's identity, what kind of object is
owned and what bytes this run intends to install, what was there before, the
durable record that says so, and the closed set of ways any of it can fail. Every
owner speaks these — a run's data root, its generated sibling config, the host
wall, and the objects a provider owns at another frame — so a record one owner
writes is readable by every other and a version tag means one thing.

There is no IO here and no runner. Every value is produced by application, so
every property of the vocabulary is provable without a filesystem, and the
primitives that read a kernel live behind the seam this vocabulary is written
for rather than inside it.

Three shapes are deliberately unrepresentable rather than validated:

  * an identity that is empty, over-long, or supplied by a caller — the
    constructor is private and admits only what a kernel answered;
  * a file record with no payload, or a directory record with one — the payload
    is a field of the file's own case rather than a @Maybe@ beside both;
  * a record that claims an identity binding it never made — the binding is
    attached by its own producer and the record carries no updatable field.
-}
module HostBootstrap.Ownership.Object
    ( -- * The kernel's answer
      ObjectIdentity
    , mkObjectIdentity
    , mkKernelObjectIdentity
    , objectIdentityBytes
    , objectIdentityText
    , parseObjectIdentityHex

      -- * What this run intends to install
    , Payload
    , mkPayload
    , payloadBytes
    , PayloadDigest
    , payloadDigest
    , payloadDigestText
    , parsePayloadDigestHex

      -- * The claim a run stamps on an object another authority owns
    , OwnerClaim
    , mkOwnerClaim
    , ownerClaimText
    , parseOwnerClaimHex

      -- * What is owned, and what was there before
    , ObjectKind (..)
    , objectKindIsDirectory
    , Origin (..)
    , originIdentity

      -- * The durable origin record
    , OriginRecord
    , originRecord
    , originRecordKind
    , originRecordOrigin
    , originRecordBinding
    , bindOriginRecord
    , renderOriginRecord
    , parseOriginRecord
    , ownershipRecordVersion

      -- * Failure
    , OwnershipFault (..)
    , ConflictReport (..)
    , ownershipFault
    , ownershipFaultMessage
    )
where

import Data.Bits (shiftR, (.&.))
import qualified Crypto.Hash as Hash
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64, Word8)

-- ---------------------------------------------------------------------------
-- The kernel's answer

{- | A filesystem object's stable kernel identity: @device:inode@ on a POSIX
host, the volume serial number plus file index on a Windows one.

Clause 3 binds ownership to the object the kernel knows, never to the pathname
that currently reaches it, so this is the kernel's answer and nothing else. The
constructor is private: an 'ObjectIdentity' exists only where a row read a
non-empty identity out of a kernel, so an empty or fabricated value can never be
compared as though it were one.
-}
newtype ObjectIdentity = ObjectIdentity ByteString
    deriving (Eq, Ord)

instance Show ObjectIdentity where
    show identity = "ObjectIdentity " <> show (objectIdentityText identity)

{- | Admit raw identity bytes.

Empty is not an identity, and an over-long value is a host reporting something
this vocabulary does not understand — both are refusals rather than values,
because a comparison against either would answer a question nobody asked.
-}
mkObjectIdentity :: ByteString -> Either OwnershipFault ObjectIdentity
mkObjectIdentity raw
    | ByteString.null raw =
        Left (OwnershipUnsupported "the host reported an empty object identity")
    | ByteString.length raw > identityByteCeiling =
        Left (OwnershipUnsupported "the host reported an over-long object identity")
    | otherwise = Right (ObjectIdentity raw)

{- | The widest identity any supported row reports.

A ceiling rather than a fixed width, because the two rows encode different
kernel facts; wide enough for both and narrow enough that a host answering
something else is refused rather than journalled.
-}
identityByteCeiling :: Int
identityByteCeiling = 64

{- | The one encoding every platform row writes.

The volume word first, then the object word, both little-endian. The rows read
different kernel facts — @(st_dev, st_ino)@ on a POSIX host, the volume serial
number and file index on a Windows one — but they encode them the same way and
through this one producer, so an identity a driver compares means the same thing
whichever kernel answered. Written once per row it would be two encodings that
agree until one of them is changed, and nothing would ask them the same question
together.
-}
mkKernelObjectIdentity :: Word64 -> Word64 -> Either OwnershipFault ObjectIdentity
mkKernelObjectIdentity volume object =
    mkObjectIdentity
        ( LazyByteString.toStrict
            ( Builder.toLazyByteString
                (Builder.word64LE volume <> Builder.word64LE object)
            )
        )

objectIdentityBytes :: ObjectIdentity -> ByteString
objectIdentityBytes (ObjectIdentity raw) = raw

-- | The identity as lowercase hex, which is how it is journalled and reported.
objectIdentityText :: ObjectIdentity -> Text
objectIdentityText (ObjectIdentity raw) = hexText raw

{- | Read back a journalled identity.

A value that is not exactly lowercase hex is a malformed record, never a guess:
a record this owner cannot interpret is a fault it reports, because acting on a
half-understood record is how an owner deletes something it does not own.
-}
parseObjectIdentityHex :: Text -> Either OwnershipFault ObjectIdentity
parseObjectIdentityHex raw = do
    bytes <- parseHexText "identity" raw
    mkObjectIdentity bytes

-- ---------------------------------------------------------------------------
-- What this run intends to install

{- | The exact bytes a run intends to publish at an owned file.

Recording the intended payload before the file exists is what makes the crash
window between the origin record and the identity binding resolvable: a run that
died in that window left a file whose bytes either are this payload — in which
case it is this run's and may be removed — or are not, in which case it belongs
to whoever wrote them. See [rationale.md](../../../DEVELOPMENT_PLAN/rationale.md).
-}
newtype Payload = Payload ByteString
    deriving (Eq)

instance Show Payload where
    show payload = "Payload <" <> show (ByteString.length (payloadBytes payload)) <> " bytes>"

{- | Adopt bytes as the payload this run intends to install.

Total: any byte string is a legitimate payload, including an empty one, because
an empty file is a file a run can legitimately own.
-}
mkPayload :: ByteString -> Payload
mkPayload = Payload

payloadBytes :: Payload -> ByteString
payloadBytes (Payload raw) = raw

{- | A payload's SHA-256, which is what a durable record carries.

The record carries the digest rather than the bytes because the record is
durable and small and the payload is neither, and because release only ever asks
whether the bytes on disk are the ones this run installed.
-}
newtype PayloadDigest = PayloadDigest Text
    deriving (Eq, Ord)

instance Show PayloadDigest where
    show (PayloadDigest raw) = "PayloadDigest " <> show raw

payloadDigest :: Payload -> PayloadDigest
payloadDigest (Payload raw) =
    PayloadDigest (hexText (ByteString.pack (ByteArray.unpack (Hash.hashWith Hash.SHA256 raw))))

payloadDigestText :: PayloadDigest -> Text
payloadDigestText (PayloadDigest raw) = raw

{- | Read back a journalled payload digest.

Exactly 64 lowercase hex characters. A shorter, longer, or upper-case value is a
malformed record rather than a digest that happens to look unusual.
-}
parsePayloadDigestHex :: Text -> Either OwnershipFault PayloadDigest
parsePayloadDigestHex raw
    | Text.length raw /= 64 = Left (OwnershipMalformed ("payload digest is not 64 hex characters: " <> raw))
    | not (Text.all lowerHexDigit raw) =
        Left (OwnershipMalformed ("payload digest is not lowercase hex: " <> raw))
    | otherwise = Right (PayloadDigest raw)

-- ---------------------------------------------------------------------------
-- The claim a run stamps on an object another authority owns

{- | The tag this run stamps on an object whose identity another authority
answers for.

A directory or a file is created by the very act that gives it its kernel
identity, so the durable record needs nothing more to tell "the object this run
made" from "an object that was already there". An object another authority owns
is different: it is created by a described command whose answer can be lost, and
the identity that comes back afterwards is one the authority minted rather than
one this run chose. Without a tag, a run that crashed between publishing its
record and reading the identity could not tell its own half-made instance from
one a previous record left behind.

The claim closes that window. It is minted before the creating command, carried
/by/ that command so the object names it from the moment it exists, and written
into the durable record so a later entry can compare the two. A record whose
claim the object does not carry is a record about a different object, and that
is a refusal rather than an adoption.

It is a digest rather than the bytes it was minted from, for the reason a
payload digest is: the record is durable and small, and the only question ever
asked of it is whether two values are equal.
-}
newtype OwnerClaim = OwnerClaim Text
    deriving (Eq, Ord)

instance Show OwnerClaim where
    show (OwnerClaim raw) = "OwnerClaim " <> show raw

{- | Mint a claim from the bytes a run derived it from.

Total, because any bytes hash. What makes a claim /fresh/ is what the caller
puts in: the freshness is a property of the derivation, not of this function,
and the derivation belongs to the owner that knows what distinguishes one of its
attempts from the next.
-}
mkOwnerClaim :: ByteString -> OwnerClaim
mkOwnerClaim raw =
    OwnerClaim (hexText (ByteString.pack (ByteArray.unpack (Hash.hashWith Hash.SHA256 raw))))

ownerClaimText :: OwnerClaim -> Text
ownerClaimText (OwnerClaim raw) = raw

{- | Read back a journalled claim.

Exactly 64 lowercase hex characters, on the same terms as a payload digest: a
record carrying anything else is malformed rather than carrying an unusual
claim.
-}
parseOwnerClaimHex :: Text -> Either OwnershipFault OwnerClaim
parseOwnerClaimHex raw
    | Text.length raw /= 64 = Left (OwnershipMalformed ("owner claim is not 64 hex characters: " <> raw))
    | not (Text.all lowerHexDigit raw) =
        Left (OwnershipMalformed ("owner claim is not lowercase hex: " <> raw))
    | otherwise = Right (OwnerClaim raw)

-- ---------------------------------------------------------------------------
-- What is owned, and what was there before

{- | What a record is about.

The payload digest is a field of the file's own case rather than an optional
value beside both cases, so a file record without one and a directory record
with one are shapes with no term (§ HH). A directory has no payload because its
content is not this run's to install: what a run owns about a directory is that
it created it.

The third case is an object this process's kernel does not answer for — a
provider instance, a cluster — whose identity comes from the authority that owns
it. It carries the claim this run stamps on that object instead of a payload
digest, for the same structural reason: the value that makes its crash window
resolvable is a field of the case that has one.
-}
data ObjectKind
    = OwnedDirectory
    | OwnedFile PayloadDigest
    | ReportedObject OwnerClaim
    deriving (Eq, Show)

objectKindIsDirectory :: ObjectKind -> Bool
objectKindIsDirectory OwnedDirectory = True
objectKindIsDirectory (OwnedFile _) = False
objectKindIsDirectory (ReportedObject _) = False

{- | What the owner observed at the target before it acted.

Recorded absence is a fact the owner established, not an inference from a
missing record: a record that is absent says nothing happened, while a record
saying @absent@ says an owner looked and found nothing. Restoring the world
after a crash needs the second.
-}
data Origin
    = OriginAbsent
    | OriginPresent ObjectIdentity
    deriving (Eq, Show)

originIdentity :: Origin -> Maybe ObjectIdentity
originIdentity OriginAbsent = Nothing
originIdentity (OriginPresent identity) = Just identity

-- ---------------------------------------------------------------------------
-- The durable origin record

{- | The durable record clause 2 publishes before the object exists.

The constructor is private and there is one producer, so a record always names
what was actually observed. The identity binding is attached by its own producer
and the type carries no updatable field, so a record cannot claim a binding it
never made and a bound record cannot be silently rebound to a different object.
-}
data OriginRecord = OriginRecord ObjectKind Origin (Maybe ObjectIdentity)
    deriving (Eq, Show)

{- | Record what is about to be owned and what was there before it. -}
originRecord :: ObjectKind -> Origin -> OriginRecord
originRecord kind origin = OriginRecord kind origin Nothing

originRecordKind :: OriginRecord -> ObjectKind
originRecordKind (OriginRecord kind _ _) = kind

originRecordOrigin :: OriginRecord -> Origin
originRecordOrigin (OriginRecord _ origin _) = origin

originRecordBinding :: OriginRecord -> Maybe ObjectIdentity
originRecordBinding (OriginRecord _ _ binding) = binding

{- | Bind the created object's own identity to the record.

A record may be bound once. Binding a second identity is a conflict rather than
an update, because a record that can be rebound cannot answer clause 4: the
identity release re-observes would be whichever binding was written last rather
than the one this run created.
-}
bindOriginRecord :: ObjectIdentity -> OriginRecord -> Either OwnershipFault OriginRecord
bindOriginRecord identity (OriginRecord kind origin binding) = case binding of
    Nothing -> Right (OriginRecord kind origin (Just identity))
    Just existing
        | existing == identity -> Right (OriginRecord kind origin (Just existing))
        | otherwise ->
            Left
                ( OwnershipConflict
                    ConflictReport
                        { conflictSubject = "the origin record's identity binding"
                        , conflictExpected = OriginPresent existing
                        , conflictObserved = OriginPresent identity
                        }
                )

{- | The one canonical record encoding, shared by every owner.

One line, six space-separated tokens, one trailing newline, and nothing else. A
single fixed shape is what lets one owner read another's record: a per-object
encoding means a version tag means a different thing in each place it appears,
and a record that is merely /probably/ this owner's is a record nobody can act
on.

@
ownership 1 (directory|file|reported) (absent|\<identity hex\>) (-|\<payload digest\>|\<owner claim\>) (-|\<bound identity hex\>)
@

The fifth column carries whichever value the kind's own case has, because both
are the one thing that makes that kind's crash window resolvable and no record
ever has two of them.
-}
renderOriginRecord :: OriginRecord -> ByteString
renderOriginRecord (OriginRecord kind origin binding) =
    encodeUtf8Ascii
        ( Text.unwords
            [ ownershipRecordMagic
            , ownershipRecordVersion
            , kindToken kind
            , originToken origin
            , payloadToken kind
            , bindingToken binding
            ]
            <> "\n"
        )

-- | The only record version this vocabulary writes or accepts.
ownershipRecordVersion :: Text
ownershipRecordVersion = "1"

ownershipRecordMagic :: Text
ownershipRecordMagic = "ownership"

kindToken :: ObjectKind -> Text
kindToken OwnedDirectory = "directory"
kindToken (OwnedFile _) = "file"
kindToken (ReportedObject _) = "reported"

payloadToken :: ObjectKind -> Text
payloadToken OwnedDirectory = absentToken
payloadToken (OwnedFile digest) = payloadDigestText digest
payloadToken (ReportedObject claim) = ownerClaimText claim

originToken :: Origin -> Text
originToken OriginAbsent = "absent"
originToken (OriginPresent identity) = objectIdentityText identity

bindingToken :: Maybe ObjectIdentity -> Text
bindingToken Nothing = absentToken
bindingToken (Just identity) = objectIdentityText identity

absentToken :: Text
absentToken = "-"

{- | Read a record back exactly.

Strict in every direction: the magic, the version, and the token count are
exact, a trailing byte after the single newline is a refusal, and a token that
is neither the absent marker nor well-formed hex is malformed rather than
ignored. A record an owner half-understands is the one input that could make it
delete something it does not own.
-}
parseOriginRecord :: ByteString -> Either OwnershipFault OriginRecord
parseOriginRecord raw = do
    body <- exactLine raw
    case Text.words body of
        [magic, version, kindRaw, originRaw, payloadRaw, bindingRaw]
            | magic /= ownershipRecordMagic ->
                Left (OwnershipMalformed ("ownership record has magic " <> magic))
            | version /= ownershipRecordVersion ->
                Left (OwnershipMalformed ("ownership record has version " <> version))
            | otherwise -> do
                kind <- parseKind kindRaw payloadRaw
                origin <- parseOrigin originRaw
                binding <- parseBinding bindingRaw
                pure (OriginRecord kind origin binding)
        observed ->
            Left
                ( OwnershipMalformed
                    ( "ownership record has "
                        <> Text.pack (show (length observed))
                        <> " fields rather than 6"
                    )
                )

parseKind :: Text -> Text -> Either OwnershipFault ObjectKind
parseKind kindRaw payloadRaw = case kindRaw of
    "directory"
        | payloadRaw == absentToken -> Right OwnedDirectory
        | otherwise -> Left (OwnershipMalformed "a directory record carries no payload digest")
    "file"
        | payloadRaw == absentToken ->
            Left (OwnershipMalformed "a file record carries a payload digest")
        | otherwise -> OwnedFile <$> parsePayloadDigestHex payloadRaw
    "reported"
        | payloadRaw == absentToken ->
            Left (OwnershipMalformed "a reported-object record carries an owner claim")
        | otherwise -> ReportedObject <$> parseOwnerClaimHex payloadRaw
    other -> Left (OwnershipMalformed ("ownership record names kind " <> other))

parseOrigin :: Text -> Either OwnershipFault Origin
parseOrigin "absent" = Right OriginAbsent
parseOrigin raw = OriginPresent <$> parseObjectIdentityHex raw

parseBinding :: Text -> Either OwnershipFault (Maybe ObjectIdentity)
parseBinding raw
    | raw == absentToken = Right Nothing
    | otherwise = Just <$> parseObjectIdentityHex raw

{- | Take the record's one line, refusing anything after it. -}
exactLine :: ByteString -> Either OwnershipFault Text
exactLine raw = do
    body <- decodeAscii raw
    case Text.splitOn "\n" body of
        [line, ""] -> Right line
        _ -> Left (OwnershipMalformed "ownership record is not exactly one terminated line")

-- ---------------------------------------------------------------------------
-- Failure

{- | Every way ownership can fail, and no other.

Closed, because each case licenses a different act: a row that cannot hold a
clause mints no receipt at all, a failed probe is not an absence (§ CC), a
malformed record is never guessed at, an occupied target is left alone, and a
conflict is reported with both identities rather than resolved.
-}
data OwnershipFault
    = -- | The row cannot hold a clause on this host; no receipt may be minted.
      OwnershipUnsupported Text
    | -- | The probe itself failed: @(what was attempted, why)@.
      OwnershipProbeFailed Text Text
    | -- | A durable record could not be interpreted.
      OwnershipMalformed Text
    | -- | The target was already there and this owner does not adopt what it finds.
      OwnershipOccupied Text
    | -- | Release re-observed something other than what it bound.
      OwnershipConflict ConflictReport
    deriving (Eq, Show)

{- | Both sides of a conflict, structured.

The expected and observed sides are 'Origin' rather than 'ObjectIdentity',
because "nothing is there now" is a legitimate observation and reporting it as a
missing identity would lose the distinction the origin record exists to keep.
-}
data ConflictReport = ConflictReport
    { conflictSubject :: Text
    , conflictExpected :: Origin
    , conflictObserved :: Origin
    }
    deriving (Eq, Show)

{- | The total eliminator.

Every reader of a fault goes through this, so a case added to the sum is a
compile error at each reader rather than a branch that silently falls through to
a default.
-}
ownershipFault ::
    (Text -> result) ->
    (Text -> Text -> result) ->
    (Text -> result) ->
    (Text -> result) ->
    (ConflictReport -> result) ->
    OwnershipFault ->
    result
ownershipFault unsupported probeFailed malformed occupied conflict fault = case fault of
    OwnershipUnsupported reason -> unsupported reason
    OwnershipProbeFailed operation reason -> probeFailed operation reason
    OwnershipMalformed reason -> malformed reason
    OwnershipOccupied reason -> occupied reason
    OwnershipConflict report -> conflict report

ownershipFaultMessage :: OwnershipFault -> Text
ownershipFaultMessage =
    ownershipFault
        id
        (\operation reason -> "could not " <> operation <> ": " <> reason)
        id
        id
        ( \report ->
            conflictSubject report
                <> ": expected "
                <> renderOriginSide (conflictExpected report)
                <> ", observed "
                <> renderOriginSide (conflictObserved report)
        )

renderOriginSide :: Origin -> Text
renderOriginSide OriginAbsent = "nothing"
renderOriginSide (OriginPresent identity) = objectIdentityText identity

-- ---------------------------------------------------------------------------
-- Bytes and hex

hexText :: ByteString -> Text
hexText = Text.pack . concatMap hexByte . ByteString.unpack

hexByte :: Word8 -> String
hexByte value = [hexDigit (value `shiftR` 4), hexDigit (value .&. 0x0f)]

hexDigit :: Word8 -> Char
hexDigit value
    | value < 10 = toEnum (fromEnum '0' + fromIntegral value)
    | otherwise = toEnum (fromEnum 'a' + fromIntegral value - 10)

{- | A digit of the one hex alphabet this vocabulary reads and writes.

Lowercase only. Accepting both cases would make two different byte strings
journal the same identity, and a record compared by bytes would then disagree
with itself.
-}
lowerHexDigit :: Char -> Bool
lowerHexDigit character =
    (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')

parseHexText :: Text -> Text -> Either OwnershipFault ByteString
parseHexText subject raw
    | Text.null raw || odd (Text.length raw) || not (Text.all lowerHexDigit raw) =
        Left (OwnershipMalformed (subject <> " is not lowercase hex: " <> raw))
    | otherwise = Right (ByteString.pack (bytes (Text.unpack raw)))
  where
    bytes (high : low : rest) = (nibble high * 16 + nibble low) : bytes rest
    bytes _ = []
    nibble character
        | character >= '0' && character <= '9' =
            fromIntegral (fromEnum character - fromEnum '0')
        | otherwise =
            fromIntegral (fromEnum character - fromEnum 'a' + 10)

{- | Decode a record's bytes as ASCII.

The record's alphabet is hex, spaces, and a handful of keywords, so a byte
outside ASCII is a record this vocabulary did not write. Decoding leniently
would let a replacement record differ from a real one only in bytes nothing
compares.
-}
decodeAscii :: ByteString -> Either OwnershipFault Text
decodeAscii raw
    | ByteString.all (< 0x80) raw =
        Right (Text.pack (map (toEnum . fromIntegral) (ByteString.unpack raw)))
    | otherwise = Left (OwnershipMalformed "ownership record carries a non-ASCII byte")

encodeUtf8Ascii :: Text -> ByteString
encodeUtf8Ascii = ByteString.pack . map (fromIntegral . fromEnum) . Text.unpack
