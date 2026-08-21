{-# LANGUAGE OverloadedStrings #-}

{- | Where a cluster transaction stands, applied to values.

Every standing and every conflict below is reached by handing the decision three
values. Nothing here creates a cluster, kills a process at an instruction, or
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
    ObjectKind (OwnedDirectory, OwnedFile, ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OriginRecord,
    bindOriginRecord,
    objectIdentityText,
    mkObjectIdentity,
    mkOwnerClaim,
    mkPayload,
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
        , testGroup "one node inside the cluster" nodeTests
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

published, bound :: OriginRecord
published =
    originRecord
        (ReportedObject (mkOwnerClaim (TextEncoding.encodeUtf8 "hostbootstrap/cluster-origin/v1")))
        OriginAbsent
bound = either (error . show) id (bindOriginRecord ours published)

-- ---------------------------------------------------------------------------
-- With no durable record

unrecordedTests :: [TestTree]
unrecordedTests =
    [ testCase "no record, no cluster, and no node is nothing done" $
        clusterStanding Nothing ClusterAbsent OriginAbsent @?= Right ClusterNothingDone
    , testCase "a cluster nothing claims is refused rather than adopted" $
        clusterStanding Nothing ClusterPresent OriginAbsent @?= Left ClusterUnderNoRecord
    , testCase "a node container nothing claims is refused rather than adopted" $
        clusterStanding Nothing ClusterAbsent (OriginPresent theirs) @?= Left ClusterUnderNoRecord
    , testCase "a whole cluster nothing claims is refused rather than adopted" $
        clusterStanding Nothing ClusterPresent (OriginPresent theirs) @?= Left ClusterUnderNoRecord
    ]

-- ---------------------------------------------------------------------------
-- With a published, unbound record

recordedTests :: [TestTree]
recordedTests =
    [ testCase "a published record beside nothing is the creating command not taken effect" $
        clusterStanding (Just published) ClusterAbsent OriginAbsent @?= Right ClusterOriginRecorded
    , testCase "a published record beside a whole cluster is this record's own half-made one" $
        clusterStanding (Just published) ClusterPresent (OriginPresent ours)
            @?= Right (ClusterCreatedUnbound ours)
    , testCase "a named cluster with no node container is the two authorities disagreeing" $
        clusterStanding (Just published) ClusterPresent OriginAbsent @?= Left ClusterOutcomeUnknown
    , testCase "a node container with no named cluster is the other disagreement" $
        clusterStanding (Just published) ClusterAbsent (OriginPresent theirs)
            @?= Left ClusterOutcomeUnknown
    ]

-- ---------------------------------------------------------------------------
-- With a bound record

boundTests :: [TestTree]
boundTests =
    [ testCase "the bound identity standing at a present cluster is ownership" $
        clusterStanding (Just bound) ClusterPresent (OriginPresent ours) @?= Right (ClusterOwned ours)
    , testCase "a different container at the same node is a replacement" $
        clusterStanding (Just bound) ClusterPresent (OriginPresent theirs)
            @?= Left (NodeReplaced ours theirs)
    , testCase "a named cluster with no node container is the two authorities disagreeing" $
        clusterStanding (Just bound) ClusterPresent OriginAbsent @?= Left ClusterWithoutItsNode
    , testCase "a node container outliving its cluster is the other disagreement" $
        clusterStanding (Just bound) ClusterAbsent (OriginPresent ours)
            @?= Left (NodeWithoutItsCluster ours)
    , testCase "both gone under a bound record is a vanished object rather than nothing done" $
        clusterStanding (Just bound) ClusterAbsent OriginAbsent @?= Left (NodeVanished ours)
    ]

-- ---------------------------------------------------------------------------
-- With a record this vocabulary did not write

foreignRecordTests :: [TestTree]
foreignRecordTests =
    [ testCase "a directory record under this key is not read as a cluster's" $
        clusterStanding (Just directoryRecord) ClusterAbsent OriginAbsent
            @?= Left (RecordNotAClaimedObject "a directory")
    , testCase "a file record under this key is not read as a cluster's" $
        clusterStanding (Just fileRecord) ClusterAbsent OriginAbsent
            @?= Left (RecordNotAClaimedObject "a file")
    , testCase "a record naming a prior object was published over something it did not create" $
        clusterStanding (Just priorRecord) ClusterAbsent OriginAbsent
            @?= Left (RecordNamesAPriorObject theirs)
    , testCase "the same three refusals hold for one node's own record" $
        map
            (\record -> nodeStanding (Just record) OriginAbsent)
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
            (ReportedObject (mkOwnerClaim (TextEncoding.encodeUtf8 "hostbootstrap/cluster-origin/v1")))
            (OriginPresent theirs)

-- ---------------------------------------------------------------------------
-- One node inside the cluster

nodeTests :: [TestTree]
nodeTests =
    [ testCase "no record and no container is nothing done" $
        nodeStanding Nothing OriginAbsent @?= Right ClusterNothingDone
    , testCase "a container nothing claims is refused rather than adopted" $
        nodeStanding Nothing (OriginPresent theirs) @?= Left ClusterUnderNoRecord
    , testCase "a published record beside no container is the command not taken effect" $
        nodeStanding (Just published) OriginAbsent @?= Right ClusterOriginRecorded
    , testCase "a published record beside a container is this record's own half-made one" $
        nodeStanding (Just published) (OriginPresent ours) @?= Right (ClusterCreatedUnbound ours)
    , testCase "the bound container is ownership" $
        nodeStanding (Just bound) (OriginPresent ours) @?= Right (ClusterOwned ours)
    , testCase "a different container is a replacement" $
        nodeStanding (Just bound) (OriginPresent theirs) @?= Left (NodeReplaced ours theirs)
    , testCase "no container under a bound record is a vanished object" $
        nodeStanding (Just bound) OriginAbsent @?= Left (NodeVanished ours)
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
