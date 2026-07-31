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
    gateFor,
) where

import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Lifecycle.Prepared (PreparedGate, recordDurableUnknown)
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    RecordKey,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
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

-- | The gate alone, for a spec that needs it outside a bracket.
gateFor :: Text -> Text -> IO PreparedGate
gateFor planDigest operation =
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
                "session-1"
                1
                1
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
