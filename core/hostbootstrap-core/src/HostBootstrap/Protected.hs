{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The protected, versioned record store the lifecycle authority machinery
compare-and-swaps against.

Every durable decision the lifecycle makes — which mode a project is in, which
broker generation is live, which invocation has already been consumed, which
operation session is open — is a record in this store.  The store is the
mechanism § EE calls "one protected compare-and-swap": it does not interpret
any of those records, it only guarantees that

* no read or write happens outside an OS-released exclusive entry (clause 1 —
  a 'ProtectedSession' is the only key to 'readProtectedRecord' /
  'compareAndSwapProtectedRecord', and it exists only inside
  'withProtectedEntry');
* a write publishes a fully written, flushed temporary by atomic rename, so a
  crash leaves either the old record or the new one and never a torn one;
* a write lands only against the exact version the caller observed, so two
  cooperating runs cannot both win, and the successor version is returned to
  the winner (this is the "sole successor state/permit pair" the callers
  thread);
* the store itself has a durable generative identity, so a retained proof from
  a store that was deleted and recreated cannot be replayed against the new
  one.

The exclusive entry is @base@'s portable 'hLock', which is @flock@/@fcntl@ on
POSIX and @LockFileEx@ on Windows and is released by the kernel when the
holding process dies.  An in-process 'MVar' is held with it because POSIX
record locks are per-process rather than per-thread.

What this buys is exactly what
[ownership_invariant](../documents/architecture/ownership_invariant.md) states:
it excludes crash/retry and concurrent cooperating runs and it detects rather
than silently overwrites foreign mutation.  It does not exclude a hostile
same-privilege process.
-}
module HostBootstrap.Protected (
    -- * The store
    ProtectedStore,
    openProtectedStore,
    protectedStoreRoot,
    ProtectedStoreIdentity,
    protectedStoreIdentity,
    protectedStoreIdentityText,

    -- * Exclusive entry
    ProtectedSession,
    withProtectedEntry,
    tryProtectedEntry,

    -- * Run liveness
    withRunLiveness,
    sessionStoreIdentity,
    sessionStoreRoot,
    verifyProtectedStoreWritable,

    -- * Records
    RecordKey,
    mkRecordKey,
    recordKeyText,
    mkRecordName,
    recordNameIdentity,
    RecordVersion,
    recordVersionWord,
    ProtectedRecord (..),
    Expectation (..),
    readProtectedRecord,
    listProtectedRecords,
    compareAndSwapProtectedRecord,
    compareAndDeleteProtectedRecord,

    -- * Failures
    ProtectedError (..),
    protectedErrorMessage,
) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (bracket, finally, onException)
import Control.Exception.Safe (try)
import qualified Control.Exception.Safe as Safe
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Char (isAlphaNum)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isSuffixOf, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hLock, hTryLock)
import System.Directory (
    createDirectoryIfMissing,
    doesFileExist,
    listDirectory,
    makeAbsolute,
    removeFile,
    renameFile,
 )
import System.FilePath ((<.>), (</>))
import System.IO (
    BufferMode (NoBuffering),
    IOMode (ReadWriteMode),
    hClose,
    hFlush,
    hSetBuffering,
    openFile,
    withFile,
 )
import qualified System.IO as IO
import System.IO.Error (isDoesNotExistError)

-- The store --------------------------------------------------------------------

{- | An opened protected store rooted at one directory. The constructor is
private: a store value exists only after its root, lock file, and durable
identity have been established.
-}
data ProtectedStore = ProtectedStore
    { storeRoot :: FilePath
    , storeIdentity :: ProtectedStoreIdentity
    , storeMutex :: MVar ()
    , storeHolder :: IORef (Maybe ThreadId)
    }

-- | The store's durable generative identity, written once when it is created.
newtype ProtectedStoreIdentity = ProtectedStoreIdentity Text
    deriving (Eq, Ord)

instance Show ProtectedStoreIdentity where
    show (ProtectedStoreIdentity value) = "ProtectedStoreIdentity " <> show value

protectedStoreIdentityText :: ProtectedStoreIdentity -> Text
protectedStoreIdentityText (ProtectedStoreIdentity value) = value

protectedStoreRoot :: ProtectedStore -> FilePath
protectedStoreRoot = storeRoot

protectedStoreIdentity :: ProtectedStore -> ProtectedStoreIdentity
protectedStoreIdentity = storeIdentity

{- | Open (creating if necessary) the protected store under an absolute
directory. The identity file is created exactly once and read thereafter, so
every later process observes the same store identity — and a store that was
removed and recreated presents a different one.
-}
openProtectedStore :: FilePath -> IO (Either ProtectedError ProtectedStore)
openProtectedStore rawRoot
    | null rawRoot = pure (Left (ProtectedInvalid "the protected store root must not be empty"))
    | otherwise = do
        outcome <- try $ do
            root <- makeAbsolute rawRoot
            createDirectoryIfMissing True (root </> recordsDirectory)
            mutex <- newMVar ()
            holder <- newIORef Nothing
            identity <- establishIdentity root mutex holder
            pure (ProtectedStore root identity mutex holder)
        pure (either (Left . ioFailure "open the protected store") Right outcome)

recordsDirectory :: FilePath
recordsDirectory = "records"

lockFileName :: FilePath
lockFileName = "store.lock"

identityFileName :: FilePath
identityFileName = "store.identity"

{- | Read the store's durable identity, creating it exactly once.

The already-established case deliberately does **not** take the exclusive
entry: opening a store must not block behind whatever transaction another
process is currently running, and the identity is immutable once written. Only
first creation takes the lock, and it re-reads under it so two racing creators
still agree on one identity.
-}
establishIdentity ::
    FilePath ->
    MVar () ->
    IORef (Maybe ThreadId) ->
    IO ProtectedStoreIdentity
establishIdentity root mutex holder = do
    existing <- readIdentity path
    case existing of
        Just identity -> pure identity
        Nothing -> withStoreLock root mutex holder $ do
            raced <- readIdentity path
            case raced of
                Just identity -> pure identity
                Nothing -> do
                    nonce <- freshNonce
                    publishBytes path (encodeUtf8 nonce)
                    pure (ProtectedStoreIdentity nonce)
  where
    path = root </> identityFileName

readIdentity :: FilePath -> IO (Maybe ProtectedStoreIdentity)
readIdentity path = do
    present <- doesFileExist path
    if not present
        then pure Nothing
        else do
            raw <- ByteString.readFile path
            let value = Text.strip (decodeUtf8Lenient raw)
            pure (if Text.null value then Nothing else Just (ProtectedStoreIdentity value))

{- | A generative nonce for one store. It is durable after the first write, so
its only requirement is that two stores created on one host do not collide.
-}
freshNonce :: IO Text
freshNonce = do
    stamp <- getMonotonicTimeNSec
    pure (Text.pack ("hbps-" <> showHex64 stamp))

showHex64 :: Word64 -> String
showHex64 value = go value ""
  where
    go remaining acc
        | remaining < 16 = digit remaining : acc
        | otherwise = go (remaining `div` 16) (digit (remaining `mod` 16) : acc)
    digit d
        | d < 10 = toEnum (fromEnum '0' + fromIntegral d)
        | otherwise = toEnum (fromEnum 'a' + fromIntegral d - 10)

-- Exclusive entry ---------------------------------------------------------------

{- | Proof that the caller is inside the store's exclusive entry. The @session@
parameter is bound by 'withProtectedEntry' so a session cannot be smuggled from
one bracket into another, and the record operations accept nothing else.
-}
data ProtectedSession session = ProtectedSession ProtectedStore

sessionStoreIdentity :: ProtectedSession session -> ProtectedStoreIdentity
sessionStoreIdentity (ProtectedSession store) = storeIdentity store

-- | The store's absolute root, for the operator check that must inspect it.
sessionStoreRoot :: ProtectedSession session -> FilePath
sessionStoreRoot (ProtectedSession store) = storeRoot store

{- | Ask the operating system whether the current principal can create and
remove a file in the exact records directory this session protects.

The probe runs inside the store's exclusive entry, uses an exclusive temporary
name, and removes it on normal and catchable-exceptional exit. Opening the
directory or inspecting a portable permissions record is not equivalent on
Windows, where the effective ACL decision is made only by the attempted file
operation.
-}
verifyProtectedStoreWritable ::
    ProtectedSession session ->
    IO (Either ProtectedError ())
verifyProtectedStoreWritable (ProtectedSession store) = do
    outcome <-
        try $
            bracket
                (IO.openBinaryTempFile recordsRoot ".hostbootstrap-write-probe")
                (\(path, handle) -> hClose handle `finally` removeFile path)
                (const (pure ()))
    pure (either (Left . ioFailure "verify write access to the protected record store") Right outcome)
  where
    recordsRoot = storeRoot store </> recordsDirectory

{- | Run an action under the store's OS-released exclusive lock (clause 1). The
lock spans the whole observe/mutate/settle bracket, and the kernel releases it
if this process dies mid-bracket.
-}
withProtectedEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either ProtectedError result)) ->
    IO (Either ProtectedError result)
withProtectedEntry store action = do
    self <- myThreadId
    holder <- readIORef (storeHolder store)
    if holder == Just self
        then
            pure
                ( Left
                    ( ProtectedInvalid
                        "the protected store entry is not re-entrant: use the session already held"
                    )
                )
        else do
            outcome <-
                try
                    ( withStoreLock
                        (storeRoot store)
                        (storeMutex store)
                        (storeHolder store)
                        (action (ProtectedSession store))
                    )
            pure (either (Left . ioFailure "enter the protected store") id outcome)

{- | Attempt the exclusive entry without blocking. 'Nothing' means another
process (or another thread of this one) holds it right now; the caller decides
whether that is contention to wait on or a live peer to report.
-}
tryProtectedEntry ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either ProtectedError result)) ->
    IO (Either ProtectedError (Maybe result))
tryProtectedEntry store action = do
    self <- myThreadId
    holder <- readIORef (storeHolder store)
    if holder == Just self
        then
            pure
                ( Left
                    ( ProtectedInvalid
                        "the protected store entry is not re-entrant: use the session already held"
                    )
                )
        else do
            outcome <-
                try
                    ( tryStoreLock
                        (storeRoot store)
                        (storeMutex store)
                        (storeHolder store)
                        (action (ProtectedSession store))
                    )
            pure $ case outcome of
                Left failure -> Left (ioFailure "enter the protected store" failure)
                Right Nothing -> Right Nothing
                Right (Just inner) -> fmap Just inner

tryStoreLock ::
    FilePath ->
    MVar () ->
    IORef (Maybe ThreadId) ->
    IO result ->
    IO (Maybe result)
tryStoreLock root mutex holder action =
    withMVar mutex $ \() ->
        bracket open closeIfHeld run
  where
    open = do
        handle <- openFile (root </> lockFileName) ReadWriteMode
        hSetBuffering handle NoBuffering
        taken <- hTryLock handle ExclusiveLock `onException` hClose handle
        pure (handle, taken)
    closeIfHeld (handle, taken) = do
        writeIORef holder Nothing
        if taken then hClose handle else hClose handle
    run (_, False) = pure Nothing
    run (_, True) = do
        self <- myThreadId
        writeIORef holder (Just self)
        Just <$> action

{- | Hold a named liveness lock for the whole of @body@, or report that another
process holds it.

This is the § EE clause-1 primitive applied to a /run/ rather than to a single
transaction. The store's own entry is taken and released per transaction, so it
cannot answer "is the run that owns this project still alive?" — and without
that answer an abandoned-run sweep cannot tell a dead predecessor from a live
peer. This lock is held from before the sweep until the run ends, and the kernel
releases it if the process dies, so the question has a truthful answer at every
instant.

@Nothing@ means another process holds it right now. That is deliberately not an
error here: the caller decides whether a live peer is contention or a refusal.
-}
withRunLiveness ::
    ProtectedStore ->
    -- | the lock's stable name, e.g. the installed project name
    Text ->
    IO result ->
    IO (Either ProtectedError (Maybe result))
withRunLiveness store name body = do
    -- Only the ACQUISITION is wrapped: the body's own exceptions must propagate
    -- to the caller unchanged, because the harness engine classifies them. The
    -- lock is still released on that path, by 'finally'.
    prepared <- try acquire
    case prepared of
        Left failure -> pure (Left (ioFailure "take the run liveness lock" failure))
        Right (handle, False) -> do
            hClose handle
            pure (Right Nothing)
        Right (handle, True) ->
            (Right . Just <$> body) `finally` hClose handle
  where
    acquire = do
        let directory = protectedStoreRoot store </> livenessDirectoryName
        createDirectoryIfMissing True directory
        handle <- openFile (directory </> Text.unpack name <.> "lock") ReadWriteMode
        hSetBuffering handle NoBuffering
        taken <- hTryLock handle ExclusiveLock `onException` hClose handle
        pure (handle, taken)

livenessDirectoryName :: FilePath
livenessDirectoryName = "liveness"

{- | Hold the exclusive entry: the process-wide mutex (POSIX record locks are
per-process), the kernel lock, and the holder marker that turns an accidental
re-entry into an explicit refusal rather than a deadlock.
-}
withStoreLock :: FilePath -> MVar () -> IORef (Maybe ThreadId) -> IO result -> IO result
withStoreLock root mutex holder action =
    withMVar mutex $ \() ->
        bracket acquire release (const action)
  where
    acquire = do
        handle <- openFile (root </> lockFileName) ReadWriteMode
        hSetBuffering handle NoBuffering
        hLock handle ExclusiveLock `onException` hClose handle
        self <- myThreadId
        writeIORef holder (Just self)
        pure handle
    release handle = do
        writeIORef holder Nothing
        hClose handle

-- Records -------------------------------------------------------------------------

{- | A validated record name. Keys are restricted to characters that are safe as
a single path segment on every supported host, so a key can never traverse out
of the store.
-}
newtype RecordKey = RecordKey Text
    deriving (Eq, Ord)

instance Show RecordKey where
    show (RecordKey value) = "RecordKey " <> show value

recordKeyText :: RecordKey -> Text
recordKeyText (RecordKey value) = value

{- | Validate a record key.

The length cap is derived from the filesystem, which is what a key ultimately
names: a record is written as @\<key\>.rec@ and published from
@\<key\>.rec.tmp-\<16 hex\>@, so the on-disk component is the key plus 25 bytes,
against the 255-byte component limit APFS and ext4 both impose. 200 leaves
headroom for that suffix and for the longest key the lifecycle actually forms —
an operation key carries the plan digest (@\<specDigest\>:\<planBytesDigest\>@,
81 characters encoded), a session identifier, and the operation's own name.
-}
mkRecordKey :: Text -> Either ProtectedError RecordKey
mkRecordKey raw
    | Text.null raw = Left (ProtectedInvalid "a record key must not be empty")
    | Text.length raw > 200 = Left (ProtectedInvalid "a record key must be at most 200 characters")
    | not (Text.all legal raw) =
        Left
            ( ProtectedInvalid
                ("a record key may contain only alphanumerics, '-', '_', and '.': " <> raw)
            )
    | Text.isPrefixOf "." raw = Left (ProtectedInvalid "a record key must not start with '.'")
    | otherwise = Right (RecordKey raw)
  where
    legal character = isAlphaNum character || character `elem` ("-_." :: String)

{- | Encode one **namespaced identity**, or a path of them, as a record-name
component.

The store's key alphabet is alphanumerics, @-@, @_@, and @.@ — deliberately
narrow, because a key is a filesystem name. Several identities above this module
are namespaced with a colon: a plan operation key (@core:deploy-kind@,
@project:build-image@) and a plan digest (@\<specDigest\>:\<planBytesDigest\>@).
Neither could name a record at all, so the identities the lifecycle actually
wants to key by were unreachable and a caller had to invent a lossy sanitizer.

A plan operation may also be a __relation__ between operations, whose identity is
a @\/@-separated path of them
(@core:deploy-vm\/core:copy-source\/guest-alias@, § CC). A @\/@ can never reach a
filesystem name, so the path is encoded here too rather than sanitized away.

This is the one encoding, and it is **injective**:

* a plain segment (no colon) may contain no @.@, and therefore collides with no
  encoded one;
* an encoded segment's namespace may contain no @.@, so the first @.@ is always
  the separator and @ns.token@ determines @(ns, token)@ uniquely;
* no segment may contain @..@, so an encoded segment holds no adjacent pair of
  dots and @..@ unambiguously separates path segments.

At most one colon per segment is admitted; a second would make the namespace
separator ambiguous. Two distinct identities can therefore never share one
durable record — which a character-replacing sanitizer does not guarantee.
-}
mkRecordName :: Text -> Either ProtectedError Text
mkRecordName raw
    | Text.null raw = refuse raw "must not be empty"
    | otherwise =
        Text.intercalate ".." <$> traverse (recordNameSegment raw) (Text.splitOn "/" raw)

recordNameSegment :: Text -> Text -> Either ProtectedError Text
recordNameSegment raw segment
    | Text.null segment = refuse raw "must not contain an empty path segment"
    | not (Text.all admitted segment) =
        refuse raw "may contain only alphanumerics, '-', '_', '.', '/', and one ':' per segment"
    | Text.isInfixOf ".." segment =
        refuse raw "a path segment may not contain '..'"
    | otherwise = case Text.splitOn ":" segment of
        [plain]
            | Text.any (== '.') plain ->
                refuse raw "a segment with no namespace may not contain '.'"
            | otherwise -> Right plain
        [namespace, token]
            | Text.null namespace -> refuse raw "a namespaced segment needs a namespace"
            | Text.null token -> refuse raw "a namespaced segment needs a token"
            | Text.any (== '.') namespace ->
                refuse raw "a segment's namespace may not contain '.'"
            | otherwise -> Right (namespace <> "." <> token)
        _ -> refuse raw "a segment has at most one namespace"
  where
    admitted character = legal character || character == ':'
    legal character = isAlphaNum character || character `elem` ("-_." :: String)

refuse :: Text -> Text -> Either ProtectedError result
refuse raw reason = Left (ProtectedInvalid ("record name " <> raw <> " " <> reason))

{- | The identity a record-name component denotes. Total inverse of
'mkRecordName' on its image: @..@ separates path segments, the first @.@ of a
segment is the namespace separator, and a segment with no @.@ was never
namespaced.
-}
recordNameIdentity :: Text -> Text
recordNameIdentity name =
    Text.intercalate "/" (map segmentIdentity (Text.splitOn ".." name))
  where
    segmentIdentity segment = case Text.breakOn "." segment of
        (_, rest) | Text.null rest -> segment
        (namespace, rest) -> namespace <> ":" <> Text.drop 1 rest

{- | A record's monotonic version. Version 1 is the first published value; a
record that has never existed has no version at all, which is why 'Expectation'
distinguishes absence from a version rather than using zero.
-}
newtype RecordVersion = RecordVersion Word64
    deriving (Eq, Ord)

instance Show RecordVersion where
    show (RecordVersion value) = "RecordVersion " <> show value

recordVersionWord :: RecordVersion -> Word64
recordVersionWord (RecordVersion value) = value

data ProtectedRecord = ProtectedRecord
    { protectedRecordVersion :: RecordVersion
    , protectedRecordBytes :: ByteString
    }
    deriving (Eq, Show)

-- | What the caller observed, and therefore what the write must still find.
data Expectation
    = ExpectAbsent
    | ExpectVersion RecordVersion
    deriving (Eq, Show)

recordPath :: ProtectedStore -> RecordKey -> FilePath
recordPath store (RecordKey key) =
    storeRoot store </> recordsDirectory </> Text.unpack key <.> "rec"

-- | Read a record, or observe its absence. Total: a decode failure is an error.
readProtectedRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either ProtectedError (Maybe ProtectedRecord))
readProtectedRecord (ProtectedSession store) key = do
    outcome <- try (ByteString.readFile (recordPath store key))
    case outcome of
        Left failure
            | isDoesNotExistError failure -> pure (Right Nothing)
            | otherwise -> pure (Left (ioFailure "read a protected record" failure))
        Right raw -> pure (fmap Just (decodeRecord (recordKeyText key) raw))

-- | Every record key currently present, sorted. Used by the recovery sweeps.
listProtectedRecords ::
    ProtectedSession session ->
    IO (Either ProtectedError [RecordKey])
listProtectedRecords (ProtectedSession store) = do
    outcome <- try (listDirectory (storeRoot store </> recordsDirectory))
    case outcome of
        Left failure
            | isDoesNotExistError failure -> pure (Right [])
            | otherwise -> pure (Left (ioFailure "list protected records" failure))
        Right entries ->
            pure
                ( traverse
                    (mkRecordKey . Text.pack)
                    (sort [dropSuffix ".rec" entry | entry <- entries, ".rec" `isSuffixOf` entry])
                )

dropSuffix :: String -> String -> String
dropSuffix suffix value = take (length value - length suffix) value

{- | Publish @bytes@ only if the record still matches @expectation@, returning
the sole successor version. A mismatch is 'ProtectedVersionMismatch' and nothing
is written, so exactly one of two racing cooperating writers wins.
-}
compareAndSwapProtectedRecord ::
    ProtectedSession session ->
    RecordKey ->
    Expectation ->
    ByteString ->
    IO (Either ProtectedError RecordVersion)
compareAndSwapProtectedRecord session@(ProtectedSession store) key expectation bytes = do
    observed <- readProtectedRecord session key
    case observed of
        Left failure -> pure (Left failure)
        Right current -> case reconcileExpectation key expectation current of
            Left failure -> pure (Left failure)
            Right () -> do
                let next = RecordVersion (successorVersion current)
                outcome <-
                    try
                        ( publishBytes
                            (recordPath store key)
                            (encodeRecord next bytes)
                        )
                pure
                    ( either
                        (Left . ioFailure "publish a protected record")
                        (const (Right next))
                        outcome
                    )

-- | Delete a record only if it still matches @expectation@ (clause 4's shape).
compareAndDeleteProtectedRecord ::
    ProtectedSession session ->
    RecordKey ->
    Expectation ->
    IO (Either ProtectedError ())
compareAndDeleteProtectedRecord session@(ProtectedSession store) key expectation = do
    observed <- readProtectedRecord session key
    case observed of
        Left failure -> pure (Left failure)
        Right current -> case reconcileExpectation key expectation current of
            Left failure -> pure (Left failure)
            Right () -> case current of
                Nothing -> pure (Right ())
                Just _ -> do
                    outcome <- try (removeFile (recordPath store key))
                    pure
                        ( either
                            (Left . ioFailure "delete a protected record")
                            Right
                            outcome
                        )

reconcileExpectation ::
    RecordKey ->
    Expectation ->
    Maybe ProtectedRecord ->
    Either ProtectedError ()
reconcileExpectation key expectation current =
    case (expectation, current) of
        (ExpectAbsent, Nothing) -> Right ()
        (ExpectAbsent, Just record) ->
            Left
                ( ProtectedVersionMismatch
                    (recordKeyText key)
                    Nothing
                    (Just (protectedRecordVersion record))
                )
        (ExpectVersion expected, Just record)
            | protectedRecordVersion record == expected -> Right ()
            | otherwise ->
                Left
                    ( ProtectedVersionMismatch
                        (recordKeyText key)
                        (Just expected)
                        (Just (protectedRecordVersion record))
                    )
        (ExpectVersion expected, Nothing) ->
            Left (ProtectedVersionMismatch (recordKeyText key) (Just expected) Nothing)

successorVersion :: Maybe ProtectedRecord -> Word64
successorVersion Nothing = 1
successorVersion (Just record) =
    recordVersionWord (protectedRecordVersion record) + 1

-- The on-disk record shape --------------------------------------------------------

recordMagic :: ByteString
recordMagic = "hbps1"

encodeRecord :: RecordVersion -> ByteString -> ByteString
encodeRecord (RecordVersion version) bytes =
    ByteString.concat
        [ recordMagic
        , " "
        , ByteStringChar8.pack (show version)
        , "\n"
        , bytes
        ]

decodeRecord :: Text -> ByteString -> Either ProtectedError ProtectedRecord
decodeRecord key raw =
    case ByteStringChar8.break (== '\n') raw of
        (header, rest)
            | ByteString.null rest -> malformed "the record has no header terminator"
            | otherwise -> case ByteStringChar8.words header of
                [magic, version]
                    | magic /= recordMagic -> malformed "unknown record magic"
                    | otherwise -> case ByteStringChar8.readInt version of
                        Just (parsed, remainder)
                            | ByteString.null remainder && parsed > 0 ->
                                Right
                                    ( ProtectedRecord
                                        (RecordVersion (fromIntegral parsed))
                                        (ByteString.drop 1 rest)
                                    )
                        _ -> malformed "the record version is not a positive integer"
                _ -> malformed "the record header is not <magic> <version>"
  where
    malformed reason = Left (ProtectedMalformedRecord key reason)

{- | Write bytes to a fully flushed, invocation-indexed temporary in the same
directory and rename it over the destination, so a reader sees either the old
record or the complete new one.
-}
publishBytes :: FilePath -> ByteString -> IO ()
publishBytes destination bytes = do
    stamp <- getMonotonicTimeNSec
    let temporary = destination <.> ("tmp-" <> showHex64 stamp)
    withFile temporary IO.WriteMode $ \handle -> do
        ByteString.hPut handle bytes
        hFlush handle
    renameFile temporary destination
        `onException` Safe.catchIO (removeFile temporary) (const (pure ()))

-- Failures --------------------------------------------------------------------------

data ProtectedError
    = -- | The store or a key was rejected before any IO.
      ProtectedInvalid Text
    | -- | The observed version was not the expected one; nothing was written.
      ProtectedVersionMismatch Text (Maybe RecordVersion) (Maybe RecordVersion)
    | -- | A record exists but could not be decoded. Never silently ignored.
      ProtectedMalformedRecord Text Text
    | -- | The underlying filesystem operation failed.
      ProtectedIOFailure Text Text
    deriving (Eq, Show)

protectedErrorMessage :: ProtectedError -> Text
protectedErrorMessage failure = case failure of
    ProtectedInvalid reason -> reason
    ProtectedVersionMismatch key expected observed ->
        "protected record "
            <> key
            <> " changed under us (expected "
            <> renderVersion expected
            <> ", observed "
            <> renderVersion observed
            <> ")"
    ProtectedMalformedRecord key reason ->
        "protected record " <> key <> " is malformed: " <> reason
    ProtectedIOFailure operation reason ->
        "could not " <> operation <> ": " <> reason
  where
    renderVersion Nothing = "absent"
    renderVersion (Just version) = Text.pack (show (recordVersionWord version))

ioFailure :: Text -> IOError -> ProtectedError
ioFailure operation failure =
    ProtectedIOFailure operation (Text.pack (show failure))

-- Small helpers ---------------------------------------------------------------------

encodeUtf8 :: Text -> ByteString
encodeUtf8 = ByteStringChar8.pack . Text.unpack

decodeUtf8Lenient :: ByteString -> Text
decodeUtf8Lenient = Text.pack . ByteStringChar8.unpack
