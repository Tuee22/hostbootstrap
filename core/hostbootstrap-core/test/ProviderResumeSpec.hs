{-# LANGUAGE OverloadedStrings #-}

{- | Where a provider transaction stands, applied to values.

The interval this module decides — between the durable record and the identity
binding — is the one a live run cannot be steered into: entering it needs a
process to die at an exact instruction, and a patchable crash point is a
substitution point that has to be trusted to have been reached (§ NN). Written
as a total function of three values it needs none of that, and every standing
and every conflict below is reached by handing it one.
-}
module ProviderResumeSpec (tests) where

import Data.Foldable (for_, traverse_)
import qualified Data.Text as Text
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    ObjectKind (OwnedDirectory, OwnedFile, ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OriginRecord,
    OwnerClaim,
    bindOriginRecord,
    mkKernelObjectIdentity,
    mkOwnerClaim,
    mkPayload,
    originRecord,
    ownerClaimText,
    payloadDigest,
 )
import HostBootstrap.Substrate.Provider.Report (
    ProviderConfigValue (ProviderConfigUnset, ProviderConfigValue),
 )
import HostBootstrap.Substrate.Provider.Resume
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "provider resumption"
        [ testGroup "the four standings" standingTests
        , testGroup "the conflicts" conflictTests
        , testGroup "what a standing discloses" disclosureTests
        ]

-- ---------------------------------------------------------------------------
-- The four standings

standingTests :: [TestTree]
standingTests =
    [ testCase "no record and no instance is where nothing has happened" $
        providerStanding Nothing OriginAbsent ProviderConfigUnset @?= Right NothingDone
    , testCase "a record with no instance is clause 2 held and the command not taken" $
        providerStanding (Just (unboundRecord claim)) OriginAbsent ProviderConfigUnset
            @?= Right (OriginRecorded claim)
    , testCase "an instance under this record's claim is created and not yet bound" $ do
        identity <- expectIdentity 4 9
        providerStanding
            (Just (unboundRecord claim))
            (OriginPresent identity)
            (carrying claim)
            @?= Right (InstanceCreated claim identity)
    , testCase "a bound record over its own instance is owned" $ do
        identity <- expectIdentity 4 9
        record <- expectRecord (bindOriginRecord identity (unboundRecord claim))
        providerStanding (Just record) (OriginPresent identity) (carrying claim)
            @?= Right (InstanceOwned claim identity)
    , testCase "the four standings are the four prefixes of the one clause order" $ do
        identity <- expectIdentity 4 9
        bound <- expectRecord (bindOriginRecord identity (unboundRecord claim))
        reached <-
            traverse
                expectStanding
                [ providerStanding Nothing OriginAbsent ProviderConfigUnset
                , providerStanding (Just (unboundRecord claim)) OriginAbsent ProviderConfigUnset
                , providerStanding (Just (unboundRecord claim)) (OriginPresent identity) (carrying claim)
                , providerStanding (Just bound) (OriginPresent identity) (carrying claim)
                ]
        reached
            @?= [ NothingDone
                , OriginRecorded claim
                , InstanceCreated claim identity
                , InstanceOwned claim identity
                ]
    ]

-- ---------------------------------------------------------------------------
-- The conflicts

conflictTests :: [TestTree]
conflictTests =
    [ testCase "an instance no record claims is never adopted" $ do
        identity <- expectIdentity 1 2
        providerStanding Nothing (OriginPresent identity) (carrying claim)
            @?= Left (InstanceUnderNoRecord identity)
    , testCase "an instance carrying a different claim is not this record's" $ do
        identity <- expectIdentity 1 2
        providerStanding (Just (unboundRecord claim)) (OriginPresent identity) (carrying otherClaim)
            @?= Left (InstanceUnderAnotherClaim (ownerClaimText claim) (ownerClaimText otherClaim))
    , testCase "an instance carrying no claim at all is reported as carrying none" $ do
        identity <- expectIdentity 1 2
        -- Distinct from the empty string, because "carries nothing" and
        -- "carries an empty tag" are different reports.
        case providerStanding (Just (unboundRecord claim)) (OriginPresent identity) ProviderConfigUnset of
            Left (InstanceUnderAnotherClaim expected observed) -> do
                expected @?= ownerClaimText claim
                observed @?= "no claim at all"
            other -> assertFailure ("expected an unclaimed-instance conflict, got " <> show other)
    , testCase "a bound record over a different instance is a replacement" $ do
        bound <- expectIdentity 4 9
        observed <- expectIdentity 4 10
        record <- expectRecord (bindOriginRecord bound (unboundRecord claim))
        providerStanding (Just record) (OriginPresent observed) (carrying claim)
            @?= Left (InstanceReplaced bound observed)
    , testCase "a bound record over no instance is a vanished one" $ do
        bound <- expectIdentity 4 9
        record <- expectRecord (bindOriginRecord bound (unboundRecord claim))
        providerStanding (Just record) OriginAbsent (carrying claim)
            @?= Left (InstanceVanished bound)
    , testCase "a bound record whose instance carries a different claim is refused" $ do
        bound <- expectIdentity 4 9
        record <- expectRecord (bindOriginRecord bound (unboundRecord claim))
        providerStanding (Just record) (OriginPresent bound) (carrying otherClaim)
            @?= Left (InstanceUnderAnotherClaim (ownerClaimText claim) (ownerClaimText otherClaim))
    , testCase "a record another owner wrote is never read as this one's" $ do
        identity <- expectIdentity 4 9
        for_
            [ (originRecord OwnedDirectory OriginAbsent, "a directory")
            , (originRecord (OwnedFile (payloadDigest (mkPayload "bytes"))) OriginAbsent, "a file")
            ]
            ( \(record, described) ->
                providerStanding (Just record) (OriginPresent identity) (carrying claim)
                    @?= Left (RecordNotAClaimedObject described)
            )
    , testCase "a record naming a prior instance was published over something it did not create" $ do
        prior <- expectIdentity 7 7
        providerStanding
            (Just (originRecord (ReportedObject claim) (OriginPresent prior)))
            OriginAbsent
            ProviderConfigUnset
            @?= Left (RecordNamesAPriorInstance prior)
    , testCase "every conflict names both sides and reads as itself" $ do
        bound <- expectIdentity 4 9
        observed <- expectIdentity 4 10
        let messages =
                map
                    providerStandingConflictMessage
                    [ InstanceUnderNoRecord observed
                    , InstanceUnderAnotherClaim "expected" "observed"
                    , InstanceReplaced bound observed
                    , InstanceVanished bound
                    , RecordNotAClaimedObject "a directory"
                    , RecordNamesAPriorInstance observed
                    ]
        length messages @?= 6
        assertBool "the six renderings are distinct" (distinct messages)
        traverse_
            (\message -> assertBool ("a conflict says something: " <> Text.unpack message) (not (Text.null message)))
            messages
        assertBool
            "a claim conflict names both claims"
            ( "expected" `Text.isInfixOf` providerStandingConflictMessage (InstanceUnderAnotherClaim "expected" "observed")
                && "observed" `Text.isInfixOf` providerStandingConflictMessage (InstanceUnderAnotherClaim "expected" "observed")
            )
    ]

-- ---------------------------------------------------------------------------
-- What a standing discloses

disclosureTests :: [TestTree]
disclosureTests =
    [ testCase "a standing discloses its claim exactly when it has a record" $ do
        identity <- expectIdentity 4 9
        map
            standingClaim
            [NothingDone, OriginRecorded claim, InstanceCreated claim identity, InstanceOwned claim identity]
            @?= [Nothing, Just claim, Just claim, Just claim]
    , testCase "a standing discloses its identity exactly when it has an instance" $ do
        identity <- expectIdentity 4 9
        map
            standingIdentity
            [NothingDone, OriginRecorded claim, InstanceCreated claim identity, InstanceOwned claim identity]
            @?= [Nothing, Nothing, Just identity, Just identity]
    ]

-- ---------------------------------------------------------------------------
-- Helpers

claim :: OwnerClaim
claim = mkOwnerClaim "this attempt"

otherClaim :: OwnerClaim
otherClaim = mkOwnerClaim "an earlier attempt"

unboundRecord :: OwnerClaim -> OriginRecord
unboundRecord value = originRecord (ReportedObject value) OriginAbsent

carrying :: OwnerClaim -> ProviderConfigValue
carrying = ProviderConfigValue . ownerClaimText

expectIdentity :: Word -> Word -> IO ObjectIdentity
expectIdentity volume object =
    either
        (\fault -> assertFailure ("expected an identity: " <> show fault))
        pure
        (mkKernelObjectIdentity (fromIntegral volume) (fromIntegral object))

expectRecord :: (Show fault) => Either fault OriginRecord -> IO OriginRecord
expectRecord = either (\fault -> assertFailure ("expected a record: " <> show fault)) pure

expectStanding ::
    Either ProviderStandingConflict ProviderStanding -> IO ProviderStanding
expectStanding =
    either (\conflict -> assertFailure ("expected a standing: " <> show conflict)) pure

distinct :: (Eq value) => [value] -> Bool
distinct [] = True
distinct (value : rest) = value `notElem` rest && distinct rest
