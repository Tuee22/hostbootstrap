{-# LANGUAGE OverloadedStrings #-}

{- | Mint a real 'PreparedGate' for the adapter specs.

'HostBootstrap.Reconcile.withPreparedOperation' no longer accepts a caller's
attempt and journal version; it accepts the gate, whose sole producer performs
the durable unknown-phase write against a protected store.  There is therefore
no test-only constructor to reach for (§ EE forbids exporting one), so the specs
mint the gate the same way production does: a real store in a temporary
directory, inside a real exclusive entry.
-}
module PrepareFixture (
    withGateFor,
    withSuccessorGate,
    gateFor,
    gateForValues,
) where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Lifecycle.Prepared (PreparedGate, recordDurableUnknown)
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedRecord (protectedRecordVersion),
    RecordKey,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    readProtectedRecord,
    withProtectedEntry,
 )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty.HUnit (assertFailure)

{- | Record @operation@'s unknown phase in a throwaway protected store and run
the action with the resulting gate.

The attempt and journal version are whatever that store's own compare-and-swap
established — which is the point: a spec cannot choose them.
-}
withGateFor :: Text -> Text -> (PreparedGate -> IO a) -> IO a
withGateFor planDigest operation use = gateFor planDigest operation >>= use

{- | Publish an initial gate, then keep its protected store alive while the
caller decides when to publish a real compare-and-swap successor.

The successor action re-enters the same protected store, reads the retained
record version, and writes against that exact version.  This lets replay tests
prove a journal-version change without giving them a way to choose or forge a
journal version.
-}
withSuccessorGate ::
    Text ->
    Text ->
    Text ->
    Text ->
    Word64 ->
    Word64 ->
    Word64 ->
    (PreparedGate -> IO PreparedGate -> IO a) ->
    IO a
withSuccessorGate planDigest operation initialSession successorSession fence initialAttempt successorAttempt use =
    withSystemTempDirectory "hb-prepare-successor-gate" $ \dir -> do
        opened <- openProtectedStore (dir </> "authority")
        store <- case opened of
            Left failure -> assertFailure (Text.unpack (protectedErrorMessage failure))
            Right ready -> pure ready
        key <- expectKey (mkRecordKey ("operation." <> sanitize operation))
        initial <-
            publishGate
                store
                key
                ExpectAbsent
                initialSession
                initialAttempt
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
                                    successorSession
                                    fence
                                    successorAttempt
                case recorded of
                    Left failure -> assertFailure (Text.unpack (protectedErrorMessage failure))
                    Right gate -> pure gate
        use initial successor
  where
    publishGate store key expectation sessionId attempt = do
        recorded <- withProtectedEntry store $ \session ->
            recordDurableUnknown
                session
                key
                expectation
                "EffectOutcomeUnknown"
                planDigest
                operation
                sessionId
                fence
                attempt
        case recorded of
            Left failure -> assertFailure (Text.unpack (protectedErrorMessage failure))
            Right gate -> pure gate

-- | The gate alone, for a spec that needs it outside a bracket.
gateFor :: Text -> Text -> IO PreparedGate
gateFor planDigest operation = gateForValues planDigest operation "session-1" 1 1

-- | Mint a real gate with deliberately chosen record fields for refusal tests.
-- The journal version still comes only from the protected store write.
gateForValues :: Text -> Text -> Text -> Word64 -> Word64 -> IO PreparedGate
gateForValues planDigest operation sessionId fence attempt =
    withSystemTempDirectory "hb-prepare-gate" $ \dir -> do
        opened <- openProtectedStore (dir </> "authority")
        store <- case opened of
            Left failure -> assertFailure (Text.unpack (protectedErrorMessage failure))
            Right ready -> pure ready
        key <- expectKey (mkRecordKey ("operation." <> sanitize operation))
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
            Right gate -> pure gate

-- | Record keys are restricted to an alphabet; operation keys carry separators.
sanitize :: Text -> Text
sanitize = Text.map replace
  where
    replace c
        | c `elem` ("-_." :: String) = c
        | c >= 'a' && c <= 'z' = c
        | c >= 'A' && c <= 'Z' = c
        | c >= '0' && c <= '9' = c
        | otherwise = '-'

expectKey :: Either e RecordKey -> IO RecordKey
expectKey (Right key) = pure key
expectKey (Left _) = assertFailure "the fixture record key is malformed"
