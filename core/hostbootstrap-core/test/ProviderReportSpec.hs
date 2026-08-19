{-# LANGUAGE OverloadedStrings #-}

{- | The provider report, applied to values.

Nothing here runs a provider. Every classifier is a total function of the
interpreter's own outcome, so every constructor and every refusal is reached by
handing it one — which is the whole reason the classification was lifted out of
an interpreter program in the first place (§ NN). A stand-in would only be able
to answer what it was told to answer; a value cannot.
-}
module ProviderReportSpec (tests) where

import Data.Either (isLeft)
import qualified Data.Text as Text
import HostBootstrap.Effect.Run (CapturedRun (..))
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    Origin (OriginAbsent, OriginPresent),
    mkObjectIdentity,
 )
import HostBootstrap.Substrate.Provider.Report
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "provider report"
        [ testGroup "what counts as an answer at all" answerTests
        , testGroup "the instance listing" listingTests
        , testGroup "one configuration value" configTests
        , testGroup "the instance identity" identityTests
        , testGroup "the observation a clause is held over" originTests
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
    , testCase "one line is that key's value" $
        classifyProviderConfigValue (ok "0f4d-9b\n")
            @?= Right (ProviderConfigValue "0f4d-9b")
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
    , testCase "the seam's producer is the only admission" $
        -- What the grammar lets through and what the seam admits are different
        -- questions, and both are asked.
        assertBool
            "a bare grammar check would admit an identity the seam refuses"
            (isRight (mkObjectIdentity "aa") && isLeft (mkObjectIdentity ""))
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

isRight :: Either fault value -> Bool
isRight = either (const False) (const True)
