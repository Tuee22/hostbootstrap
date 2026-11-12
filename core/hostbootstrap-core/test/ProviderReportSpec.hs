{-# LANGUAGE OverloadedStrings #-}

{- | The provider report, applied to values.

Nothing here runs a provider. Every classifier is a total function of the
interpreter's own outcome, so every constructor and every refusal is reached by
handing it one — which is the whole reason the classification was lifted out of
an interpreter program in the first place (§ NN). A stand-in would only be able
to answer what it was told to answer; a value cannot.
-}
module ProviderReportSpec (tests) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as AesonMap
import Data.Aeson ((.=))
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as LazyBytes
import Expect (expectRight)
import HostBootstrap.Wsl2.Registration (RawWslRegistration (..), classifyWslRegistration)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    Origin (OriginAbsent, OriginPresent),
    mkObjectIdentity,
    mkOwnerClaim,
    ownerClaimText,
 )
import HostBootstrap.Substrate.Provider.Report
import qualified HostBootstrap.Reconcile as Reconcile
import HostBootstrap.Substrate.Provider.Command (ProviderSizing (..))
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "provider report"
        [ testGroup "native refusal envelopes" nativeRefusalTests
        , testGroup "native observation metadata" nativeObservationTests
        , testGroup "native Lima sizing" limaSizingTests
        , testGroup "provider sizing" sizingTests
        , testGroup "native Lima instance reports" limaReportTests
        , testGroup "native WSL location claims" wslLocationTests
        , testGroup "what counts as an answer at all" answerTests
        , testGroup "the instance listing" listingTests
        , testGroup "one configuration value" configTests
        , testGroup "the instance identity" identityTests
        , testGroup "the observation a clause is held over" originTests
        ]

sizingTests :: [TestTree]
sizingTests =
    [ testCase "equivalent declared units have one canonical budget" $ do
        canonical <- expectRight (providerSizingBudget (ProviderSizing 2 "2GiB" "12GiB"))
        providerSizingBudget (ProviderSizing 2 "2048MiB" "12288MiB") @?= Right canonical
    , testCase "native Incus reports preserve all three normalized limits" $ do
        canonical <- expectRight (providerSizingBudget (ProviderSizing 2 "2GiB" "12GiB"))
        classifyIncusSizing (ok "2\n") (ok "2147483648\n") (ok "12288MiB\n")
            @?= Right (NativeProviderSizing canonical)
    , testCase "equal native quantities match across unit spellings" $ do
        declared <- expectRight (providerSizingBudget (ProviderSizing 2 "2GiB" "12GiB"))
        observed <- expectRight (classifyIncusSizing (ok "2") (ok "2048MiB") (ok "12884901888"))
        providerSizingMatches declared observed @?= True
    , testCase "decimal memory is not silently rounded to a binary declaration" $ do
        declared <- expectRight (providerSizingBudget (ProviderSizing 2 "2GiB" "12GiB"))
        observed <- expectRight (classifyIncusSizing (ok "2") (ok "2GB") (ok "12GiB"))
        providerSizingMatches declared observed @?= False
    , testCase "every admitted native Incus suffix has an exact byte budget" $ do
        mapM_ (\(unit, bytes) -> do
            incusQuantityBytes ("1" <> unit) @?= Just bytes
            budget <- expectRight (incusSizingBudget (ProviderSizing 2 ("1" <> unit) ("1" <> unit)))
            declared <- expectRight (providerSizingBudget (ProviderSizing 2 (show bytes) (show bytes)))
            budget @?= declared)
            [("", 1), ("B", 1), (" bytes", 1), ("kB", 1000), ("MB", 1000000),
                ("GB", 1000000000), ("TB", 1000000000000), ("PB", 1000000000000000),
                ("EB", 1000000000000000000), ("KiB", 1024), ("MiB", 1048576),
                ("GiB", 1073741824), ("TiB", 1099511627776), ("PiB", 1125899906842624),
                ("EiB", 1152921504606846976)]
    , testCase "native Incus byte overflow and non-ASCII digits refuse" $
        mapM_ (\value -> assertUnreadable "invalid provider sizing"
            (incusSizingBudget (ProviderSizing 2 value "12GiB")))
            ["9223372036854775808", "9EiB", "12invalid", "\x0661GiB"]
    , testCase "zero declared quantities refuse rather than imply no limit" $
        mapM_ (assertUnreadable "invalid provider sizing" . providerSizingBudget)
            [ProviderSizing 0 "2GiB" "12GiB", ProviderSizing 2 "0" "12GiB", ProviderSizing 2 "2GiB" "0"]
    , testCase "a missing native quantity cannot become a budget" $ do
        assertUnreadable "omits the CPU" (classifyIncusSizing (ok "") (ok "2GiB") (ok "12GiB"))
        assertUnreadable "omits the memory" (classifyIncusSizing (ok "2") (ok "") (ok "12GiB"))
        assertUnreadable "omits the root" (classifyIncusSizing (ok "2") (ok "2GiB") (ok ""))
    , testCase "CPU pin sets fractions negatives zero and overflow refuse" $
        mapM_ (\value -> assertUnreadable "positive representable CPU count"
            (classifyIncusSizing (ok value) (ok "2GiB") (ok "12GiB")))
            ["0", "-1", "1.5", "0-1", "18446744073709551616", "18446744073709551617"]
    , testCase "the canonical CPU bound stays exact and larger Word64 values refuse" $ do
        declared <- expectRight (providerSizingBudget (ProviderSizing (fromIntegral (maxBound :: Int)) "2GiB" "12GiB"))
        classifyIncusSizing (ok (show (maxBound :: Int))) (ok "2GiB") (ok "12GiB")
            @?= Right (NativeProviderSizing declared)
        assertUnreadable "DimensionAboveBound BudgetCpu"
            (classifyIncusSizing (ok "18446744073709551615") (ok "2GiB") (ok "12GiB"))
    , testCase "invalid or fractional-byte memory is refused" $
        mapM_ (\value -> assertUnreadable "invalid provider sizing"
            (classifyIncusSizing (ok "2") (ok value) (ok "12GiB"))) ["garbage", "-1", "0", "0.1B"]
    , testCase "invalid or non-positive storage is refused" $
        mapM_ (\value -> assertUnreadable "invalid provider sizing"
            (classifyIncusSizing (ok "2") (ok "2GiB") (ok value))) ["garbage", "-1", "0", "0.1B"]
    , testCase "every native sizing read retains noisy-success refusal" $ do
        let noisy = Right (CapturedRun ExitSuccess "2" "warning\n")
        classifyIncusSizing noisy (ok "2GiB") (ok "12GiB") @?= Left (ProviderCommandNoisy "warning")
        classifyIncusSizing (ok "2") noisy (ok "12GiB") @?= Left (ProviderCommandNoisy "warning")
        classifyIncusSizing (ok "2") (ok "2GiB") noisy @?= Left (ProviderCommandNoisy "warning")
    , testCase "every native sizing read retains the process failure" $ do
        let failed = Right (CapturedRun (ExitFailure 7) "" "denied\n")
        classifyIncusSizing failed (ok "2GiB") (ok "12GiB") @?= Left (ProviderCommandExited 7 "denied")
        classifyIncusSizing (ok "2") failed (ok "12GiB") @?= Left (ProviderCommandExited 7 "denied")
        classifyIncusSizing (ok "2") (ok "2GiB") failed @?= Left (ProviderCommandExited 7 "denied")
    , testCase "every native sizing read retains an unrun command" $ do
        let absent = Left "missing client"
        classifyIncusSizing absent (ok "2GiB") (ok "12GiB") @?= Left (ProviderCommandUnrun "missing client")
        classifyIncusSizing (ok "2") absent (ok "12GiB") @?= Left (ProviderCommandUnrun "missing client")
        classifyIncusSizing (ok "2") (ok "2GiB") absent @?= Left (ProviderCommandUnrun "missing client")
    , testCase "recorded WSL capacity compares only the disk quantity it knows" $ do
        declared <- expectRight (providerSizingBudget (ProviderSizing 2 "2GiB" "12GiB"))
        providerSizingMatches declared (RecordedWslStorage 12884901888) @?= True
        providerSizingMatches declared (RecordedWslStorage 25769803776) @?= False
    , testCase "WSL diagnostics identify shared walls and the recorded cap" $
        observedSizingText (RecordedWslStorage 12884901888)
            @?= "cpu=shared WSL2 wall, memory=shared WSL2 wall, storage=12884901888 bytes (recorded installation cap)"
    , testCase "native conflict sides use one exact canonical rendering" $ do
        declared <- expectRight (providerSizingBudget (ProviderSizing 2 "2GiB" "12GiB"))
        declaredSizingText declared @?= "cpu=2, memory=2147483648 bytes, storage=12884901888 bytes"
        observedSizingText (NativeProviderSizing declared) @?= declaredSizingText declared
    ] <>
    [ testCase ("a different native " <> label <> " does not match") $ do
        declared <- expectRight (providerSizingBudget (ProviderSizing 2 "2GiB" "12GiB"))
        actual <- expectRight (providerSizingBudget sizing)
        providerSizingMatches declared (NativeProviderSizing actual) @?= False
    | (label, sizing) <- [("CPU count", ProviderSizing 3 "2GiB" "12GiB"),
        ("memory limit", ProviderSizing 2 "3GiB" "12GiB"), ("root size", ProviderSizing 2 "2GiB" "13GiB")] ]

limaReportTests :: [TestTree]
limaReportTests =
    [ testCase "an empty native JSON listing is absence" $
        classifyLimaInstanceReport "demo" (ok "") @?= Right Nothing
    , testCase "the exact native row preserves state, directory and claim" $ do
        value <- expectLimaReport (classifyLimaInstanceReport "demo" (jsonRows [limaRow "demo" "Running" "/native/demo" (Just "owner") []]))
        limaInstanceListing value @?= ProviderListing "demo" ProviderRunning
        limaInstanceDirectory value @?= "/native/demo"
        providerConfigValueText (limaInstanceClaim value) @?= Just "owner"
    , testCase "a stopped native row keeps its actual lifecycle state" $ do
        value <- expectLimaReport (classifyLimaInstanceReport "demo" (jsonRows [limaRow "demo" "Stopped" "/native/demo" Nothing []]))
        limaInstanceListing value @?= ProviderListing "demo" ProviderStopped
        limaInstanceClaim value @?= ProviderConfigUnset
    , testCase "prefix neighbors cannot be adopted as the exact instance" $
        classifyLimaInstanceReport "demo" (jsonRows [limaRow "demo-other" "Running" "/native/demo-other" Nothing []]) @?= Right Nothing
    , testCase "the exact row is selected beside another prefix match" $ do
        value <- expectLimaReport (classifyLimaInstanceReport "demo"
            (jsonRows [limaRow "demo-other" "Running" "/native/demo-other" Nothing [], limaRow "demo" "Stopped" "/native/demo" Nothing []]))
        limaInstanceListing value @?= ProviderListing "demo" ProviderStopped
    , testCase "duplicate exact rows refuse" $
        assertUnreadable "repeats the exact instance name" $
            classifyLimaInstanceReport "demo" (jsonRows (replicate 2 (limaRow "demo" "Running" "/native/demo" Nothing [])))
    , testCase "an empty native claim means unset" $ do
        value <- expectLimaReport (classifyLimaInstanceReport "demo" (jsonRows [limaRow "demo" "Running" "/native/demo" (Just "") []]))
        limaInstanceClaim value @?= ProviderConfigUnset
    , testCase "Unicode paths and ordinary metadata are preserved" $ do
        value <- expectLimaReport (classifyLimaInstanceReport "demo" (jsonRows [limaRow "demo" "Running" "/Users/\x00c5/demo" (Just "owner-\x03bb") []]))
        limaInstanceDirectory value @?= "/Users/\x00c5/demo"
        providerConfigValueText (limaInstanceClaim value) @?= Just "owner-\x03bb"
    , testCase "the widest admitted claim is retained" $ do
        value <- expectLimaReport (classifyLimaInstanceReport "demo" (jsonRows [limaRow "demo" "Running" "/native/demo" (Just (replicate 240 'a')) []]))
        providerConfigValueText (limaInstanceClaim value) @?= Just (Text.replicate 240 "a")
    , testCase "a report with no process remains unrun" $
        classifyLimaInstanceReport "demo" (Left "no client") @?= Left (ProviderCommandUnrun "no client")
    , testCase "a noisy native JSON success is refused before parsing" $
        classifyLimaInstanceReport "demo" (Right (CapturedRun ExitSuccess "{}" "warning\n")) @?= Left (ProviderCommandNoisy "warning")
    , testCase "a nonzero native list preserves its bounded diagnostic" $
        classifyLimaInstanceReport "demo" (Right (CapturedRun (ExitFailure 3) "{}" "refused\nsecond")) @?= Left (ProviderCommandExited 3 "refused")
    , testCase "a raw wire format control refuses before JSON field admission" $
        classifyLimaInstanceReport "demo" (ok ("{}\x202e"))
            @?= Left (ProviderReportUnreadable "the provider report carries a control character")
    , testCase "a line past the native JSON bound refuses" $
        assertUnreadable "line past the admitted bound" $ classifyLimaInstanceReport "demo" (ok (replicate 65537 'a'))
    ]
        <> [ testCase ("native JSON refuses " <> label) $
                assertUnreadable reason (classifyLimaInstanceReport "demo" (jsonRows [value]))
           | (label, value, reason) <-
                [ ("missing fields", Aeson.object ["name" .= ("demo" :: String)], "not valid native JSON")
                , ("wrong name type", Aeson.object ["name" .= (7 :: Int), "status" .= ("Running" :: String), "dir" .= ("/native/demo" :: String)], "not valid native JSON")
                , ("empty name", limaRow "" "Running" "/native/demo" Nothing [], "unreadable instance name")
                , ("name control", limaRow "demo\ESC" "Running" "/native/demo" Nothing [], "unreadable instance name")
                , ("unknown state", limaRow "demo" "Starting" "/native/demo" Nothing [], "neither Running nor Stopped")
                , ("state casing", limaRow "demo" "RUNNING" "/native/demo" Nothing [], "neither Running nor Stopped")
                , ("relative directory", limaRow "demo" "Running" "native/demo" Nothing [], "not a bounded absolute path")
                , ("directory for another name", limaRow "demo" "Running" "/native/foreign" Nothing [], "not a bounded absolute path")
                , ("directory traversal", limaRow "demo" "Running" "/native/../demo" Nothing [], "not a bounded absolute path")
                , ("directory control", limaRow "demo" "Running" "/native/\ESC/demo" Nothing [], "not a bounded absolute path")
                , ("directory format control", limaRow "demo" "Running" "/native/\x202e/demo" Nothing [], "not a bounded absolute path")
                , ("directory bound", limaRow "demo" "Running" ("/" <> replicate 4096 'a' <> "/demo") Nothing [], "not a bounded absolute path")
                , ("claim bound", limaRow "demo" "Running" "/native/demo" (Just (replicate 241 'a')) [], "not bounded control-free text")
                , ("escaped claim NUL", limaRow "demo" "Running" "/native/demo" (Just "owner\0foreign") [], "not bounded control-free text")
                , ("escaped claim newline", limaRow "demo" "Running" "/native/demo" (Just "owner\nforeign") [], "not bounded control-free text")
                , ("escaped claim format control", limaRow "demo" "Running" "/native/demo" (Just "owner\x202e") [], "not bounded control-free text")
                , ("native errors", limaRow "demo" "Stopped" "/native/demo" Nothing ["broken config"], "reports native errors")
                ]
           ]
        <> [ testCase ("native JSON refuses syntax " <> label) $
                assertUnreadable "not valid native JSON" (classifyLimaInstanceReport "demo" (ok value))
           | (label, value) <- [("truncated", "{\"name\":"), ("array instead of rows", "[]"), ("trailing text", "{} trailing")]
           ]

limaSizingTests :: [TestTree]
limaSizingTests =
    [ testCase "native numeric fields produce the exact canonical Lima budget" $ do
        native <- expectLimaReport (classifyLimaInstanceReport "demo" (jsonRows [limaSizingFields []]))
        budget <- expectRight (providerSizingBudget (ProviderSizing 2 "4GiB" "40GiB"))
        limaInstanceSizing native @?= budget
    , testCase "the native signed bounds remain exact canonical quantities" $ do
        let maximumBytes = 9223372036854775807 :: Integer
        native <- expectLimaReport (classifyLimaInstanceReport "demo" (jsonRows [limaSizingFields
            [("cpus", Just (Aeson.toJSON (maxBound :: Int))), ("memory", Just (Aeson.toJSON maximumBytes)),
             ("disk", Just (Aeson.toJSON maximumBytes))]]))
        budget <- expectRight (providerSizingBudget (ProviderSizing (fromIntegral (maxBound :: Int))
            (show maximumBytes) (show maximumBytes)))
        limaInstanceSizing native @?= budget
    , testCase "creation config cannot supply missing native sizing fields" $
        assertUnreadable "omits native sizing" (classifyLimaInstanceReport "demo" (jsonRows [limaSizingFields
            [("cpus", Nothing), ("memory", Nothing), ("disk", Nothing),
             ("config", Just (Aeson.object ["cpus" .= (2 :: Int), "memory" .= ("4GiB" :: String),
                 "disk" .= ("40GiB" :: String)]))]]))
    , testCase "an unrelated prefix row need not supply the selected instance's sizing" $
        classifyLimaInstanceReport "another" (jsonRows [limaSizingFields
            [("cpus", Nothing), ("memory", Nothing), ("disk", Nothing)]]) @?= Right Nothing
    , testCase "bounded native numeric parsing refuses enormous exponents" $
        mapM_ (\field -> assertUnreadable "not valid native JSON"
            (classifyLimaInstanceReport "demo" (ok
                ("{\"name\":\"demo\",\"status\":\"Stopped\",\"dir\":\"/native/demo\","
                    <> "\"cpus\":" <> number field "cpus" "2"
                    <> ",\"memory\":" <> number field "memory" "4294967296"
                    <> ",\"disk\":" <> number field "disk" "42949672960" <> "}"))))
            ["cpus", "memory", "disk"]
    ] <>
    [ testCase ("native Lima " <> label <> " drift does not match") $ do
        native <- expectLimaReport (classifyLimaInstanceReport "demo" (jsonRows [limaSizingFields [(field, Just value)]]))
        declared <- expectRight (providerSizingBudget (ProviderSizing 2 "4GiB" "40GiB"))
        providerSizingMatches declared (NativeProviderSizing (limaInstanceSizing native)) @?= False
    | (label, field, value) <- [("CPU", "cpus", Aeson.toJSON (3 :: Int)),
        ("memory", "memory", Aeson.toJSON (8589934592 :: Integer)),
        ("disk", "disk", Aeson.toJSON (85899345920 :: Integer))]
    ] <>
    [ testCase ("native Lima refuses " <> Text.unpack (AesonKey.toText field) <> " " <> label) $
        assertUnreadable reason (classifyLimaInstanceReport "demo"
            (jsonRows [limaSizingFields [(field, value)]]))
    | field <- ["cpus", "memory", "disk"]
    , (label, value, reason) <-
        [ ("missing", Nothing, "omits native sizing")
        , ("null", Just Aeson.Null, "omits native sizing")
        , ("zero", Just (Aeson.toJSON (0 :: Int)), if field == "cpus" then "CPU count is not positive" else "invalid Lima sizing")
        , ("negative", Just (Aeson.toJSON (-1 :: Int)), if field == "cpus" then "CPU count is not positive" else "invalid Lima sizing")
        , ("fraction", Just (Aeson.toJSON (1.5 :: Double)), "not valid native JSON")
        , ("overflow", Just (Aeson.toJSON (9223372036854775808 :: Integer)), "not valid native JSON")
        , ("string units", Just (Aeson.toJSON ("4GiB" :: String)), "not valid native JSON")
        ]
    ]
  where
    number :: String -> String -> String -> String
    number selected field original = if selected == field then "1e1000000" else original

limaSizingFields :: [(AesonKey.Key, Maybe Aeson.Value)] -> Aeson.Value
limaSizingFields changes = case limaRow "demo" "Running" "/native/demo" (Just "owner") [] of
    Aeson.Object row -> Aeson.Object (foldl update row changes)
    _ -> Aeson.Null
  where
    update row (field, Nothing) = AesonMap.delete field row
    update row (field, Just value) = AesonMap.insert field value row

limaRow :: String -> String -> FilePath -> Maybe String -> [String] -> Aeson.Value
limaRow name state directory claim errors = Aeson.object
    [ "name" .= name, "status" .= state, "dir" .= directory, "errors" .= errors
    , "cpus" .= (2 :: Int), "memory" .= (4294967296 :: Integer), "disk" .= (42949672960 :: Integer)
    , "config" .= Aeson.object ["env" .= maybe (Aeson.object []) (\value -> Aeson.object ["HOSTBOOTSTRAP_OWNER" .= value]) claim]
    ]

jsonRows :: [Aeson.Value] -> Either String CapturedRun
jsonRows = ok . unlines . map (escapeFormat . Text.unpack . TextEncoding.decodeUtf8 . LazyBytes.toStrict . Aeson.encode)
  where
    -- Exercise controls hidden by JSON escaping as well as the raw wire case.
    escapeFormat = concatMap (\character -> if character == '\x202e' then "\\u202e" else [character])

expectLimaReport :: Either ProviderReportFault (Maybe LimaInstanceReport) -> IO LimaInstanceReport
expectLimaReport outcome = expectRight outcome >>= maybe (assertFailure "expected the exact native Lima row") pure

wslLocationTests :: [TestTree]
wslLocationTests =
    [ testCase label $ do
        let claim = mkOwnerClaim "this recorded VM"
        registration <- expectRight (classifyWslRegistration "demo"
            [RawWslRegistration "{01234567-89ab-cdef-0123-456789abcdef}" "demo" observed 2])
            >>= maybe (assertFailure "the native registration fixture is absent") pure
        providerConfigValueText (wslLocationClaim expected claim registration)
            @?= if same then Just (ownerClaimText claim) else Nothing
    | (label, expected, observed, same) <-
        [ ("exact owned install path carries the record's claim", "C:\\owned\\demo", "C:\\owned\\demo", True)
        , ("Windows case and separators name the same location", "C:\\Owned\\Demo", "c:/owned/demo", True)
        , ("extended drive spelling names the same location", "C:\\owned\\demo", "\\\\?\\C:\\owned\\demo", True)
        , ("extended UNC spelling names the same location", "\\\\server\\share\\demo", "\\\\?\\UNC\\server\\share\\demo", True)
        , ("a foreign install path carries no claim", "C:\\owned\\demo", "C:\\foreign\\demo", False)
        , ("a prefix neighbor carries no claim", "C:\\owned\\demo", "C:\\owned\\demo-foreign", False)
        ]
    ]

-- ---------------------------------------------------------------------------
-- What counts as an answer

answerTests :: [TestTree]
answerTests =
    [ testCase "a command that produced no child is not an answer" $
        classifyProviderConfigValue (Left "incus not found on this host")
            @?= Left (ProviderCommandUnrun "incus not found on this host")
    , testCase "a non-zero exit carries the provider's own first diagnostic" $
        classifyProviderConfigValue
            (Right (CapturedRun (ExitFailure 1) "" "Error: not found\nsecond line\n"))
            @?= Left (ProviderCommandExited 1 "Error: not found")
    , testCase "a non-zero exit with no diagnostic still names one" $
        classifyProviderConfigValue (Right (CapturedRun (ExitFailure 7) "" ""))
            @?= Left (ProviderCommandExited 7 "no diagnostic")
    , testCase "a success that wrote to standard error is not an answer" $
        classifyProviderConfigValue (Right (CapturedRun ExitSuccess "value\n" "warning\n"))
            @?= Left (ProviderCommandNoisy "warning")
    , testCase "a non-zero exit's rendering retains its numeric code" $
        assertBool
            "the exit code is part of the diagnostic"
            ("2" `Text.isInfixOf` providerReportFaultMessage (ProviderCommandExited 2 "refused"))
    , testCase "provider diagnostics remove the report's forbidden characters" $ do
        let escaped = Right (CapturedRun (ExitFailure 2) "" "\ESC[31mrefused\ESC[0m\nsecond\n")
        classifyProviderConfigValue escaped @?= Left (ProviderCommandExited 2 "[31mrefused[0m")
        case classifyProviderConfigValue escaped of
            Left fault -> assertBool "rendered diagnostics contain no escape" (not ('\ESC' `elem` Text.unpack (providerReportFaultMessage fault)))
            Right _ -> assertFailure "expected the exited provider's refusal"
        classifyProviderConfigValue (Right (CapturedRun ExitSuccess "" "\x0085warning\x202E\n"))
            @?= Left (ProviderCommandNoisy "warning")
        classifyProviderConfigValue (Right (CapturedRun (ExitFailure 3) "" "\ESC\x0085\x202E\n"))
            @?= Left (ProviderCommandExited 3 "no diagnostic")
    , testCase "each fault renders as itself" $ do
        let rendered =
                map
                    providerReportFaultMessage
                    [ ProviderCommandUnrun "no child"
                    , ProviderCommandExited 2 "refused"
                    , ProviderCommandNoisy "noisy"
                    , ProviderReportUnreadable "unreadable"
                    ]
        length rendered @?= 4
        assertBool "the four renderings are distinct" (distinct rendered)
        assertBool
            "each rendering names its own cause"
            (and (zipWith Text.isInfixOf ["no child", "refused", "noisy", "unreadable"] rendered))
    ]

-- ---------------------------------------------------------------------------
-- The listing

listingTests :: [TestTree]
listingTests =
    [ testCase "an empty listing is an authoritative absence" $
        classifyProviderListing "demo" (ok "") @?= Right Nothing
    , testCase "a listing that names only a sibling is an absence" $
        classifyProviderListing "demo" (ok "demo-2,RUNNING\ndemo-3,STOPPED\n") @?= Right Nothing
    , testCase "both admitted lifecycle states are read" $ do
        classifyProviderListing "demo" (ok "demo,RUNNING\n")
            @?= Right (Just (ProviderListing "demo" ProviderRunning))
        classifyProviderListing "demo" (ok "demo-2,RUNNING\ndemo,STOPPED\n")
            @?= Right (Just (ProviderListing "demo" ProviderStopped))
    , testCase "a frozen sibling does not decide the exact instance's state" $ do
        let report = ok "demo,RUNNING\ndemo-gpu,FROZEN\n"
        classifyProviderListing "demo" report @?= Right (Just (ProviderListing "demo" ProviderRunning))
        assertUnreadable "neither RUNNING nor STOPPED" (classifyProviderListing "demo-gpu" report)
    , testCase "a malformed sibling row does not decide the exact instance's shape" $ do
        classifyProviderListing "demo" (ok "demo,RUNNING\ndemo-gpu,STOPPED,extra\n")
            @?= Right (Just (ProviderListing "demo" ProviderRunning))
        classifyProviderListing "demo" (ok "demo-gpu,FROZEN\ndemo-other,STOPPED,extra\n")
            @?= Right Nothing
    , testCase "the exact listing line bound is admitted" $ do
        let name = replicate (providerReportLineBound - length (",RUNNING" :: String)) 'a'
        classifyProviderListing name (ok (name <> ",RUNNING\n"))
            @?= Right (Just (ProviderListing name ProviderRunning))
    , testCase "a carriage return is not part of a state" $
        classifyProviderListing "demo" (ok "demo,RUNNING\r\n")
            @?= Right (Just (ProviderListing "demo" ProviderRunning))
    , testCase "the exact instance listed twice is a refusal, not a choice" $
        assertUnreadable
            "more than once"
            (classifyProviderListing "demo" (ok "demo,RUNNING\ndemo,STOPPED\n"))
    , testCase "a row that is not a name and a state is a refusal" $ do
        assertUnreadable "not a name and a state" (classifyProviderListing "demo" (ok "demo\n"))
        assertUnreadable
            "not a name and a state"
            (classifyProviderListing "demo" (ok "demo,RUNNING,extra\n"))
    , testCase "a row naming no instance is a refusal" $
        assertUnreadable "names no instance" (classifyProviderListing "demo" (ok ",RUNNING\n"))
    , testCase "a lifecycle state outside the admitted two is a refusal" $
        assertUnreadable
            "neither RUNNING nor STOPPED"
            (classifyProviderListing "demo" (ok "demo,FROZEN\n"))
    , testCase "a line past the admitted bound is a refusal" $
        assertUnreadable
            "past the admitted bound"
            (classifyProviderListing "demo" (ok (replicate (providerReportLineBound + 1) 'x' <> "\n")))
    , testCase "a control character in the report is a refusal" $
        assertUnreadable
            "control character"
            (classifyProviderListing "demo" (ok "demo,RUN\ESC[0mNING\n"))
    , testCase "the admitted lifecycle states are the whole set" $
        allProviderRunStates @?= [ProviderRunning, ProviderStopped]
    ]

-- ---------------------------------------------------------------------------
-- One configuration value

configTests :: [TestTree]
configTests =
    [ testCase "no output is an unset key" $
        classifyProviderConfigValue (ok "") @?= Right ProviderConfigUnset
    , testCase "one empty line is the same unset answer as no output" $ do
        classifyProviderConfigValue (ok "\n") @?= Right ProviderConfigUnset
        providerConfigValueText ProviderConfigUnset @?= Nothing
    , testCase "the exact configuration value bound is admitted" $ do
        let value = replicate providerConfigValueBound 'a'
        fmap providerConfigValueText (classifyProviderConfigValue (ok (value <> "\n")))
            @?= Right (Just (Text.pack value))
    , testCase "configuration values refuse Unicode controls and formatting characters" $
        sequence_
            [ assertUnreadable "control character" (classifyProviderConfigValue (ok ("before" <> [character] <> "after\n")))
            | character <- ['\x202E', '\x0085', '\x200D', '\x009F']
            ]
    , testCase "one line is that key's value" $
        fmap providerConfigValueText (classifyProviderConfigValue (ok "0f4d-9b\n"))
            @?= Right (Just "0f4d-9b")
    , testCase "more than one line for one key is a refusal" $
        assertUnreadable
            "more than one line"
            (classifyProviderConfigValue (ok "first\nsecond\n"))
    , testCase "a value past the admitted bound is a refusal" $
        assertUnreadable
            "past the admitted bound"
            (classifyProviderConfigValue (ok (replicate (providerConfigValueBound + 1) 'a' <> "\n")))
    , testCase "the value bound is inside the line bound" $
        assertBool
            "a value the line bound admits can still be refused as a value"
            (providerConfigValueBound < providerReportLineBound)
    ]

-- ---------------------------------------------------------------------------
-- The identity

identityTests :: [TestTree]
identityTests =
    [ testCase "an unset key carries no identity" $
        classifyProviderIdentity (ok "") @?= Right Nothing
    , testCase "an admitted identity is the one the seam mints from the reported bytes" $ do
        expected <- expectIdentity "1f2e-3d.4c:5b_6a"
        classifyProviderIdentity (ok "1f2e-3d.4c:5b_6a\n") @?= Right (Just expected)
    , testCase "an identity outside the grammar is a refusal" $
        assertUnreadable
            "outside the admitted grammar"
            (classifyProviderIdentity (ok "one identity\n"))
    , testCase "an identity the seam will not admit is a refusal" $
        -- The grammar admits it and the seam's own ceiling does not, so the
        -- refusal comes from the one producer that mints identities.
        assertUnreadable
            "over-long"
            (classifyProviderIdentity (ok (replicate (providerConfigValueBound - 1) 'a' <> "\n")))
    ]

-- ---------------------------------------------------------------------------
-- The observation

originTests :: [TestTree]
originTests =
    [ testCase "an unlisted instance with no identity is an absence" $
        providerObservedOrigin Nothing Nothing @?= Right OriginAbsent
    , testCase "a listed instance with an identity is that identity" $ do
        identity <- expectIdentity "9c1f"
        providerObservedOrigin (Just (ProviderListing "demo" ProviderRunning)) (Just identity)
            @?= Right (OriginPresent identity)
    , testCase "an identity for an unlisted instance is a refusal" $ do
        identity <- expectIdentity "9c1f"
        assertUnreadable
            "an instance it does not list"
            (providerObservedOrigin Nothing (Just identity))
    , testCase "a listed instance with no identity is a refusal" $
        assertUnreadable
            "no stable identity"
            (providerObservedOrigin (Just (ProviderListing "demo" ProviderStopped)) Nothing)
    ]

-- ---------------------------------------------------------------------------
-- Helpers

-- | A provider command that ran, succeeded, and wrote exactly this to stdout.
ok :: String -> Either String CapturedRun
ok out = Right (CapturedRun ExitSuccess out "")

assertUnreadable :: (Show value) => Text.Text -> Either ProviderReportFault value -> IO ()
assertUnreadable expected outcome = case outcome of
    Left (ProviderReportUnreadable reason) ->
        assertBool
            ("the refusal says why: " <> Text.unpack reason)
            (expected `Text.isInfixOf` reason)
    other -> assertFailure ("expected an unreadable-report refusal, got " <> show other)

expectIdentity :: Text.Text -> IO ObjectIdentity
expectIdentity raw =
    either
        (\fault -> assertFailure ("expected an identity: " <> show fault))
        pure
        (mkObjectIdentity (TextEncoding.encodeUtf8 raw))

distinct :: (Eq value) => [value] -> Bool
distinct [] = True
distinct (value : rest) = value `notElem` rest && distinct rest

-- These are ordinary codec values; no case supplies native query evidence.
nativeObservationTests :: [TestTree]
nativeObservationTests =
    [ testCase "an independent native observation vector encodes and decodes exactly" $ do
        identity <- expectRight (mkObjectIdentity (Bytes.singleton 0))
        let wire = "[\"hostbootstrap/provider-native-observation/v1\",\"ready\",\"00\"]"
        encodeProviderNativeObservation "ready" identity @?= Right wire
        classifyProviderNativeObservation wire @?= Right ("ready", identity)
    , testCase "the admitted ready and native-identity bounds round-trip" $ do
        identity <- expectRight (mkObjectIdentity (Bytes.replicate 64 255))
        let ready = Text.replicate 256 "r"
        encoded <- expectRight (encodeProviderNativeObservation ready identity)
        classifyProviderNativeObservation encoded @?= Right (ready, identity)
    , testCase "encoding refuses empty overlong and control-bearing ready commitments" $ do
        identity <- expectRight (mkObjectIdentity (Bytes.singleton 0))
        mapM_ (\ready -> encodeProviderNativeObservation ready identity @?= Left
            (ProviderReportUnreadable "the provider ready commitment is empty, overlong or contains controls"))
            ["", Text.replicate 257 "r", "ready\NUL"]
    ] <>
    [ testCase ("native metadata refuses " <> label) $
        case classifyProviderNativeObservation wire of
            Left (ProviderReportUnreadable _) -> pure ()
            other -> assertFailure ("expected unreadable metadata, got " <> show other)
    | (label, wire) <-
        [ ("empty text", "")
        , ("an empty tuple", "[]")
        , ("an object", "{}")
        , ("a different version", tuple ["different", "ready", "00"])
        , ("an empty native identity", tuple [domain, "ready", ""])
        , ("invalid native hex", tuple [domain, "ready", "GG"])
        , ("odd native hex", tuple [domain, "ready", "0"])
        , ("an overlong native identity", tuple [domain, "ready", Text.replicate 65 "00"])
        , ("an empty ready commitment", tuple [domain, "", "00"])
        , ("an overlong ready commitment", tuple [domain, Text.replicate 257 "r", "00"])
        , ("a control-bearing ready commitment", tuple [domain, "ready\NUL", "00"])
        , ("extra tuple fields", tuple [domain, "ready", "00", "extra"])
        , ("leading JSON whitespace", " " <> tuple [domain, "ready", "00"])
        , ("trailing bytes", tuple [domain, "ready", "00"] <> "!")
        , ("an oversized body", Text.replicate 2049 " ")
        ]
    ] <>
    [ testCase ("the shared observation version preserves the " <> label <> " vector") $
        identityObservationVersion raw @?= expected
    | (label, raw, expected) <-
        [ ("empty", "", 1469598103934665603)
        , ("native hex", "00", 11172343261825283451)
        , ("wrapping ASCII", "hello", 25347132070217633)
        ]
    ]
  where
    domain = "hostbootstrap/provider-native-observation/v1"
    tuple :: [Text.Text] -> Text.Text
    tuple = TextEncoding.decodeUtf8 . LazyBytes.toStrict . Aeson.encode

nativeRefusalTests :: [TestTree]
nativeRefusalTests =
    [ testCase "an independent conflict envelope preserves its exact fields" $ do
        encodeProviderNativeRefusal conflict @?= Just conflictWire
        classifyProviderNativeRefusal conflictWire @?= Just conflict
    , testCase "an independent unsupported envelope preserves its exact fields" $ do
        let refusal = Reconcile.Unsupported (Reconcile.UnsupportedDetail "probe" "no native identity")
            wire = "[\"hostbootstrap/provider-native-refusal/v1\",\"unsupported\",\"probe\",\"no native identity\"]"
        encodeProviderNativeRefusal refusal @?= Just wire
        classifyProviderNativeRefusal wire @?= Just refusal
    , testCase "malformed noncanonical and oversized refusal envelopes remain unclassified" $ do
        mapM_ (\wire -> classifyProviderNativeRefusal wire @?= Nothing)
            ["", "[]", "{}", " " <> conflictWire, conflictWire <> "!",
             "[\"different\",\"unsupported\",\"probe\",\"reason\"]",
             "[\"hostbootstrap/provider-native-refusal/v1\",\"unknown\",\"probe\",\"reason\"]",
             Text.replicate 4097 " "]
        encodeProviderNativeRefusal
            (Reconcile.Conflict (Reconcile.ConflictDetail "provider" "" (Text.replicate 4097 "x") "reconcile"))
            @?= Nothing
    , testCase "other failures retain their ordinary failure diagnostic" $
        encodeProviderNativeRefusal (Reconcile.Failure
            (Reconcile.FailureDetail "probe" "transport failed" Reconcile.ReprobeBeforeRetry))
            @?= Nothing
    ]
  where
    conflict = Reconcile.Conflict (Reconcile.ConflictDetail "provider" "before" "after" "reconcile")
    conflictWire = "[\"hostbootstrap/provider-native-refusal/v1\",\"conflict\",\"provider\",\"before\",\"after\",\"reconcile\"]"
