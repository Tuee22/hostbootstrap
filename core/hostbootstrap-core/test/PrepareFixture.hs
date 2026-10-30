{-# LANGUAGE OverloadedStrings #-}

{- | Publish real durable gates in throwaway protected stores for adapter specs.

These fixtures use the retained lower-level 'recordDurableUnknown' writer, not
the production session admission path. The caller chooses the plan, operation,
session, fence and attempt; only the physical journal version comes from the
protected write. Each write still runs inside a real exclusive entry.
-}
module PrepareFixture (
    withGateFor,
    withGateForValuesStore,
    withSuccessorGate,
    gateFor,
    gateForValues,
) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Digest (sha256Hex)
import HostBootstrap.Lifecycle.Prepared (PreparedGate, recordDurableUnknown)
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordVersion),
    ProtectedStore,
    RecordKey,
    mkRecordKey,
    mkRecordName,
    openProtectedStore,
    protectedErrorMessage,
    readProtectedRecord,
    recordTupleSeparator,
    withProtectedEntry,
 )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty.HUnit (assertFailure)

{- | Record @operation@'s unknown phase in a throwaway protected store and run
the action with the resulting gate.

The caller chooses the plan and operation. 'gateFor' fixes the session to
@session-1@, fence to 1 and attempt to 1; only the fresh record's first-write
journal version, 1, comes from the protected store.
-}
withGateFor :: Text -> Text -> (PreparedGate -> IO a) -> IO a
withGateFor planDigest operation use = gateFor planDigest operation >>= use

{- | Keep one store alive for an initial gate and a same-session successor.

Both writes retain the plan, operation, session and fence. The caller chooses
the attempts; the successor re-reads the current physical record version and
uses it as the compare-and-swap expectation. No journal version is supplied by
the caller.
-}
withSuccessorGate ::
    Text ->
    Text ->
    Text ->
    Word64 ->
    Word64 ->
    Word64 ->
    (ProtectedStore -> PreparedGate -> IO PreparedGate -> IO a) ->
    IO a
withSuccessorGate planDigest operation sessionId fence initialAttempt successorAttempt use =
    withGateForValuesStore planDigest operation sessionId fence initialAttempt $ \store initial -> do
        key <- expectKey (fixtureRecordKey planDigest operation sessionId)
        let successor = do
                recorded <-
                    withProtectedEntry store $ \session -> do
                        observed <- readProtectedRecord session key
                        case observed of
                            Left failure -> pure (Left failure)
                            Right Nothing -> assertFailure "the initial prepared-gate record disappeared"
                            Right (Just record) ->
                                recordDurableUnknown
                                    session
                                    key
                                    (ExpectVersion (protectedRecordVersion record))
                                    "EffectOutcomeUnknown"
                                    planDigest
                                    operation
                                    sessionId
                                    fence
                                    successorAttempt
                case recorded of
                    Left failure -> assertFailure (Text.unpack (protectedErrorMessage failure))
                    Right gate -> pure gate
        use store initial successor

-- | The gate alone, for a spec that needs it outside a bracket.
gateFor :: Text -> Text -> IO PreparedGate
gateFor planDigest operation = gateForValues planDigest operation "session-1" 1 1

{- | Mint a gate with caller-selected coordinates for refusal tests.

The fresh store's first write supplies physical journal version 1; the session,
fence and attempt are the caller's values.
-}
gateForValues :: Text -> Text -> Text -> Word64 -> Word64 -> IO PreparedGate
gateForValues planDigest operation sessionId fence attempt =
    withGateForValuesStore planDigest operation sessionId fence attempt (\_ gate -> pure gate)

{- | Keep the real store and its first-write gate alive during the callback.

This uses the unchecked lower-level writer with the caller's coordinates; it
does not perform the production session admission checks.
-}
withGateForValuesStore ::
    Text ->
    Text ->
    Text ->
    Word64 ->
    Word64 ->
    (ProtectedStore -> PreparedGate -> IO a) ->
    IO a
withGateForValuesStore planDigest operation sessionId fence attempt use =
    withSystemTempDirectory "hb-prepare-gate" $ \dir -> do
        opened <- openProtectedStore (dir </> "authority")
        store <- case opened of
            Left failure -> assertFailure (Text.unpack (protectedErrorMessage failure))
            Right ready -> pure ready
        key <- expectKey (fixtureRecordKey planDigest operation sessionId)
        recorded <- withProtectedEntry store $ \session ->
            recordDurableUnknown
                session
                key
                ExpectAbsent
                "EffectOutcomeUnknown"
                planDigest
                operation
                sessionId
                fence
                attempt
        case recorded of
            Left failure -> assertFailure (Text.unpack (protectedErrorMessage failure))
            Right gate -> use store gate

fixtureRecordKey :: Text -> Text -> Text -> Either ProtectedError RecordKey
fixtureRecordKey planDigest operation sessionId = do
    _ <- mkRecordName planDigest
    sessionName <- mkRecordName sessionId
    operationName <- mkRecordName operation
    let digest = sha256Hex (TextEncoding.encodeUtf8 planDigest)
    mkRecordKey ("op." <> digest <> "." <> sessionName <> recordTupleSeparator <> operationName)

expectKey :: Either e RecordKey -> IO RecordKey
expectKey (Right key) = pure key
expectKey (Left _) = assertFailure "the fixture record key is malformed"
