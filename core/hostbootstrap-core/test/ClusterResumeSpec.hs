{-# LANGUAGE OverloadedStrings #-}

{- | Where a cluster transaction stands, applied to values.

Every standing and every conflict below is reached by handing the decision the claim and three
observations. Nothing here creates a cluster, kills a process at an instruction, or
arranges for a crash: the interval between clause 2 and clause 3 is exactly the
one a live run cannot be steered into, which is why the decision is a function
(§ NN).

The record values are built through the ownership vocabulary's own constructor,
so a case cannot assert about a record shape the store could never hold.
-}
module ClusterResumeSpec (tests) where

import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Report (ClusterPresence (ClusterAbsent, ClusterPresent))
import HostBootstrap.Cluster.Resume
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    OwnerClaim,
    ObjectKind (OwnedDirectory, OwnedFile, ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OriginRecord,
    bindOriginRecord,
    mkObjectIdentity,
    mkOwnerClaim,
    mkPayload,
    objectIdentityText,
    originRecord,
    payloadDigest,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "cluster resumption"
        [ testGroup "with no durable record" unrecordedTests
        , testGroup "with a published, unbound record" recordedTests
        , testGroup "with a bound record" boundTests
        , testGroup "with a record this vocabulary did not write" foreignRecordTests
        , testGroup "another plan generation" generationTests
        , testGroup "one node inside the cluster" nodeTests
        , testGroup "node removal completion" removalCompletionTests
        , testGroup "release resumption" releaseResumptionTests
        , testGroup "refused create retirement" refusedCreateTests
        , testGroup "how a conflict reads" renderingTests
        ]

-- ---------------------------------------------------------------------------
-- Values

identityOf :: String -> ObjectIdentity
identityOf value =
    either (error . show) id (mkObjectIdentity (TextEncoding.encodeUtf8 (Text.pack value)))

ours, theirs :: ObjectIdentity
ours = identityOf (replicate 64 'a')
theirs = identityOf (replicate 64 'b')

ourClaim, otherClaim :: OwnerClaim
ourClaim = mkOwnerClaim (TextEncoding.encodeUtf8 "hostbootstrap/cluster-origin/v1")
otherClaim = mkOwnerClaim (TextEncoding.encodeUtf8 "another-plan-generation")

published, bound :: OriginRecord
published =
    originRecord
        (ReportedObject ourClaim)
        OriginAbsent
bound = either (error . show) id (bindOriginRecord ours published)

-- ---------------------------------------------------------------------------
-- With no durable record

unrecordedTests :: [TestTree]
unrecordedTests =
    [ testCase "no record, no cluster, and no node is nothing done" $
        clusterStanding ourClaim Nothing ClusterAbsent OriginAbsent @?= Right ClusterNothingDone
    , testCase "a cluster nothing claims is refused rather than adopted" $
        clusterStanding ourClaim Nothing ClusterPresent OriginAbsent @?= Left ClusterUnderNoRecord
    , testCase "a node container nothing claims is refused rather than adopted" $
        clusterStanding ourClaim Nothing ClusterAbsent (OriginPresent theirs) @?= Left ClusterUnderNoRecord
    , testCase "a whole cluster nothing claims is refused rather than adopted" $
        clusterStanding ourClaim Nothing ClusterPresent (OriginPresent theirs) @?= Left ClusterUnderNoRecord
    ]

-- ---------------------------------------------------------------------------
-- With a published, unbound record

recordedTests :: [TestTree]
recordedTests =
    [ testCase "a published record beside nothing is the creating command not taken effect" $
        clusterStanding ourClaim (Just published) ClusterAbsent OriginAbsent @?= Right ClusterOriginRecorded
    , testCase "an unbound record beside a whole cluster has a created-unbound standing" $
        clusterStanding ourClaim (Just published) ClusterPresent (OriginPresent ours)
            @?= Right (ClusterCreatedUnbound ours)
    , testCase "a named cluster with no node container is the two authorities disagreeing" $
        clusterStanding ourClaim (Just published) ClusterPresent OriginAbsent @?= Left ClusterOutcomeUnknown
    , testCase "a node container with no named cluster is the other disagreement" $
        clusterStanding ourClaim (Just published) ClusterAbsent (OriginPresent theirs)
            @?= Left ClusterOutcomeUnknown
    ]

-- ---------------------------------------------------------------------------
-- With a bound record

boundTests :: [TestTree]
boundTests =
    [ testCase "the bound identity standing at a present cluster is ownership" $
        clusterStanding ourClaim (Just bound) ClusterPresent (OriginPresent ours) @?= Right (ClusterOwned ours)
    , testCase "a different container at the same node is a replacement" $
        clusterStanding ourClaim (Just bound) ClusterPresent (OriginPresent theirs)
            @?= Left (NodeReplaced ours theirs)
    , testCase "a named cluster with no node container is the two authorities disagreeing" $
        clusterStanding ourClaim (Just bound) ClusterPresent OriginAbsent @?= Left ClusterWithoutItsNode
    , testCase "a node container outliving its cluster is the other disagreement" $
        clusterStanding ourClaim (Just bound) ClusterAbsent (OriginPresent ours)
            @?= Left (NodeWithoutItsCluster ours)
    , testCase "both gone under a bound record is a vanished object rather than nothing done" $
        clusterStanding ourClaim (Just bound) ClusterAbsent OriginAbsent @?= Left (NodeVanished ours)
    ]

-- ---------------------------------------------------------------------------
-- With a record this vocabulary did not write

foreignRecordTests :: [TestTree]
foreignRecordTests =
    [ testCase "a directory record under this key is not read as a cluster's" $
        clusterStanding ourClaim (Just directoryRecord) ClusterAbsent OriginAbsent
            @?= Left (RecordNotAClaimedObject "a directory")
    , testCase "a file record under this key is not read as a cluster's" $
        clusterStanding ourClaim (Just fileRecord) ClusterAbsent OriginAbsent
            @?= Left (RecordNotAClaimedObject "a file")
    , testCase "a record naming a prior object was published over something it did not create" $
        clusterStanding ourClaim (Just priorRecord) ClusterAbsent OriginAbsent
            @?= Left (RecordNamesAPriorObject theirs)
    , testCase "the same three refusals hold for one node's own record" $
        map
            (\record -> nodeStanding ourClaim (Just record) OriginAbsent)
            [directoryRecord, fileRecord, priorRecord]
            @?= [ Left (RecordNotAClaimedObject "a directory")
                , Left (RecordNotAClaimedObject "a file")
                , Left (RecordNamesAPriorObject theirs)
                ]
    ]
  where
    directoryRecord = originRecord OwnedDirectory OriginAbsent
    fileRecord =
        originRecord
            (OwnedFile (payloadDigest (mkPayload (TextEncoding.encodeUtf8 "bytes"))))
            OriginAbsent
    priorRecord =
        originRecord
            (ReportedObject ourClaim)
            (OriginPresent theirs)

-- ---------------------------------------------------------------------------
-- One node inside the cluster

nodeTests :: [TestTree]
nodeTests =
    [ testCase "no record and no container is nothing done" $
        nodeStanding ourClaim Nothing OriginAbsent @?= Right ClusterNothingDone
    , testCase "a container nothing claims is refused rather than adopted" $
        nodeStanding ourClaim Nothing (OriginPresent theirs) @?= Left ClusterUnderNoRecord
    , testCase "a published record beside no container is the command not taken effect" $
        nodeStanding ourClaim (Just published) OriginAbsent @?= Right ClusterOriginRecorded
    , testCase "a published record beside a container is this record's own half-made one" $
        nodeStanding ourClaim (Just published) (OriginPresent ours) @?= Right (ClusterCreatedUnbound ours)
    , testCase "the bound container is ownership" $
        nodeStanding ourClaim (Just bound) (OriginPresent ours) @?= Right (ClusterOwned ours)
    , testCase "a different container is a replacement" $
        nodeStanding ourClaim (Just bound) (OriginPresent theirs) @?= Left (NodeReplaced ours theirs)
    , testCase "no container under a bound record is a vanished object" $
        nodeStanding ourClaim (Just bound) OriginAbsent @?= Left (NodeVanished ours)
    , testCase "the identity a standing carries is exactly the observed one" $ do
        standingIdentity (ClusterOwned ours) @?= Just ours
        standingIdentity (ClusterCreatedUnbound ours) @?= Just ours
        standingIdentity ClusterOriginRecorded @?= Nothing
        standingIdentity ClusterNothingDone @?= Nothing
    ]

-- ---------------------------------------------------------------------------
-- How a conflict reads

renderingTests :: [TestTree]
renderingTests =
    [ testCase "every conflict renders once, and names both sides where it has two" $ do
        let rendered =
                map
                    clusterStandingConflictMessage
                    [ ClusterUnderNoRecord
                    , ClusterOutcomeUnknown
                    , NodeReplaced ours theirs
                    , NodeVanished ours
                    , ClusterWithoutItsNode
                    , NodeWithoutItsCluster theirs
                    , RecordNotAClaimedObject "a directory"
                    , RecordNamesAPriorObject theirs
                    , RecordClaimedByAnotherGeneration
                    ]
        assertBool "no conflict renders as nothing" (all (not . Text.null) rendered)
        assertBool
            "a replacement names the bound identity and the observed one"
            ( all
                (`Text.isInfixOf` clusterStandingConflictMessage (NodeReplaced ours theirs))
                [objectIdentityText ours, objectIdentityText theirs]
            )
        assertBool
            "the outcome-unknown refusal says which two answers disagree"
            ("disagree" `Text.isInfixOf` clusterStandingConflictMessage ClusterOutcomeUnknown)
    ]

-- No process or provider stand-in participates in generation decisions.
generationTests :: [TestTree]
generationTests =
    [ testCase "an unbound cluster record under another claim refuses" $
        clusterStanding ourClaim (Just foreignPublished) ClusterPresent (OriginPresent ours)
            @?= Left RecordClaimedByAnotherGeneration
    , testCase "a bound cluster record under another claim refuses even at the same identity" $
        clusterStanding ourClaim (Just foreignBound) ClusterPresent (OriginPresent ours)
            @?= Left RecordClaimedByAnotherGeneration
    , testCase "an unbound node record under another claim refuses" $
        nodeStanding ourClaim (Just foreignPublished) (OriginPresent ours)
            @?= Left RecordClaimedByAnotherGeneration
    , testCase "a bound node record under another claim refuses even at the same identity" $
        nodeStanding ourClaim (Just foreignBound) (OriginPresent ours)
            @?= Left RecordClaimedByAnotherGeneration
    , testCase "record preflight validates claims without inventing runtime observations" $ do
        map (validateClusterOriginRecord ourClaim) [published, bound] @?= [Right (), Right ()]
        map (validateClusterOriginRecord ourClaim) [foreignPublished, foreignBound]
            @?= [Left RecordClaimedByAnotherGeneration, Left RecordClaimedByAnotherGeneration]
    ]
  where
    foreignPublished = originRecord (ReportedObject otherClaim) OriginAbsent
    foreignBound = either (error . show) id (bindOriginRecord ours foreignPublished)

refusedCreateTests :: [TestTree]
refusedCreateTests =
    [ testCase "absent cluster and control plane permit retiring unbound origins" $
        refusedCreateOriginsMayRetire ClusterAbsent OriginAbsent @?= True
    , testCase "a named cluster preserves the refused create origins" $
        refusedCreateOriginsMayRetire ClusterPresent OriginAbsent @?= False
    , testCase "a present control plane preserves the refused create origins" $
        refusedCreateOriginsMayRetire ClusterAbsent (OriginPresent ours) @?= False
    , testCase "a whole standing cluster preserves the refused create origins" $
        refusedCreateOriginsMayRetire ClusterPresent (OriginPresent ours) @?= False
    ]

releaseResumptionTests :: [TestTree]
releaseResumptionTests =
    [ testCase "a deleted bound control plane resumes under either listing" $
        map (\presence -> clusterReleaseStanding ourClaim (Just bound) presence OriginAbsent) [ClusterAbsent, ClusterPresent]
            @?= replicate 2 (Right (ClusterOwned ours))
    , testCase "a remaining bound container resumes even when the cluster is unlisted" $
        clusterReleaseStanding ourClaim (Just bound) ClusterAbsent (OriginPresent ours) @?= Right (ClusterOwned ours)
    , testCase "release preserves replacement identity refusal under either listing" $
        map (\presence -> clusterReleaseStanding ourClaim (Just bound) presence (OriginPresent theirs)) [ClusterAbsent, ClusterPresent]
            @?= replicate 2 (Left (NodeReplaced ours theirs))
    , testCase "release never relaxes the stored generation" $
        clusterReleaseStanding otherClaim (Just bound) ClusterAbsent OriginAbsent @?= Left RecordClaimedByAnotherGeneration
    , testCase "an absent bound worker carries its retained identity" $
        nodeReleaseStanding ourClaim (Just bound) OriginAbsent @?= Right (ClusterOwned ours)
    , testCase "an absent unbound record remains an origin" $
        nodeReleaseStanding ourClaim (Just published) OriginAbsent @?= Right ClusterOriginRecorded
    , testCase "an unrecorded present node remains unclaimed" $
        nodeReleaseStanding ourClaim Nothing (OriginPresent theirs) @?= Left ClusterUnderNoRecord
    , testCase "an unbound cluster still requires agreeing observations" $
        clusterReleaseStanding ourClaim (Just published) ClusterAbsent (OriginPresent ours) @?= Left ClusterOutcomeUnknown
    ]

removalCompletionTests :: [TestTree]
removalCompletionTests =
    [ testCase "an absent unbound node needs no removal" $
        nodeRemovalComplete Nothing OriginAbsent @?= Right True
    , testCase "an absent bound node permits record retirement" $
        nodeRemovalComplete (Just ours) OriginAbsent @?= Right True
    , testCase "a surviving bound node requires another probe" $
        nodeRemovalComplete (Just ours) (OriginPresent ours) @?= Right False
    , testCase "a replacement refuses record retirement with both identities" $
        nodeRemovalComplete (Just ours) (OriginPresent theirs) @?= Left (NodeReplaced ours theirs)
    , testCase "an unclaimed present node refuses retirement" $
        nodeRemovalComplete Nothing (OriginPresent theirs) @?= Left ClusterUnderNoRecord
    ]
