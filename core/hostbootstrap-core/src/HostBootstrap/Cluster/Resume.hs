{-# LANGUAGE OverloadedStrings #-}

{- | Where a cluster ownership transaction stands, as one value.

The four clauses are one transaction but not one process. A run publishes its
durable record, creates a cluster through the one interpreter (§ KK), and binds
the identity the container runtime answers with — and it can die between any two
of those. What the next entry does is decided entirely by three facts: the record
the protected store holds, what the driver says about the cluster's name, and
what the runtime says about the node container the record binds
("HostBootstrap.Cluster.Report").

This module is that decision, and it is a __total function of those three
values__. That matters because the interval between clause 2 and clause 3 is
precisely the interval a live test cannot reliably enter: reaching it needs a
process to die at an exact instruction. Written as a function it needs nothing of
the sort — every standing and every conflict is reached by handing it a value
(§ NN).

__A cluster carries no claim, and the record is what stands in for one.__ A
provider stamps this run's owner tag onto the instance as it creates it, so an
instance that exists names the record that made it. The cluster driver has
nowhere to put such a tag: what it creates is a name and a set of node
containers, and neither carries a byte this project chose. What answers instead
is the record's own existence. A record is published only from
'ClusterNothingDone' — the driver naming no cluster and the runtime naming no
container — inside the protected store's exclusive entry, so a published record
is proof that this transaction found the name free and took it. A cluster
standing beside that record is therefore this transaction's own half-made
cluster, and 'ClusterCreatedUnbound' is a standing to resume from rather than an
object to adopt. The two answers must agree for it to be one: a driver that names
the cluster while the runtime names no container, or the reverse, is
'ClusterOutcomeUnknown' and is refused.

Identity closes the window in the other direction: once a node container's
identifier is bound, a cluster deleted and recreated out of band under the same
name presents a different identifier and is a conflict.
-}
module HostBootstrap.Cluster.Resume (
    -- * Where the transaction stands
    ClusterStanding (..),
    standingIdentity,

    -- * Why it stands nowhere
    ClusterStandingConflict (..),
    clusterStandingConflictMessage,

    -- * The decisions
    clusterStanding,
    nodeStanding,
)
where

import Data.Text (Text)
import HostBootstrap.Cluster.Report (ClusterPresence (ClusterAbsent, ClusterPresent))
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    ObjectKind (OwnedDirectory, OwnedFile, ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OriginRecord,
    objectIdentityText,
    originRecordBinding,
    originRecordKind,
    originRecordOrigin,
 )

-- ---------------------------------------------------------------------------
-- Where the transaction stands

{- | The four places a cluster transaction can legitimately stand.

They are the four prefixes of the one clause order, and nothing else is
reachable: a record cannot exist without clause 1 having been held, a binding
cannot exist without a record, and an object this record's transaction created
cannot exist without that record having been published over its absence first.
-}
data ClusterStanding
    = -- | no record, no cluster, and no node: nothing has happened yet
      ClusterNothingDone
    | -- | clause 2 is durable and the creating command has not taken effect
      ClusterOriginRecorded
    | -- | the object exists under this record and clause 3 is not held
      ClusterCreatedUnbound ObjectIdentity
    | -- | clauses 1 through 3 are held: this is this record's object
      ClusterOwned ObjectIdentity
    deriving (Eq, Show)

-- | The identity the runtime answered with, where there is an object.
standingIdentity :: ClusterStanding -> Maybe ObjectIdentity
standingIdentity ClusterNothingDone = Nothing
standingIdentity ClusterOriginRecorded = Nothing
standingIdentity (ClusterCreatedUnbound identity) = Just identity
standingIdentity (ClusterOwned identity) = Just identity

-- ---------------------------------------------------------------------------
-- Why it stands nowhere

{- | The closed set of states that are not a standing.

Each is a case where continuing would mean owning something this project did not
make, or acting on two answers that disagree. None is resolved here: a conflict
is reported with both sides so an operator learns which of them happened, because
the seam's own rule is that a conflict is reported rather than resolved.
-}
data ClusterStandingConflict
    = -- | something stands at this name and no durable record claims it
      ClusterUnderNoRecord
    | -- | the record is published and unbound, and the two authorities disagree
      ClusterOutcomeUnknown
    | -- | the record is bound and a different container stands at the node
      NodeReplaced ObjectIdentity ObjectIdentity
    | -- | the record is bound and its node container is gone
      NodeVanished ObjectIdentity
    | -- | the driver names the cluster and the runtime names no node container for it
      ClusterWithoutItsNode
    | -- | the runtime still holds this record's node container and the driver names no cluster
      NodeWithoutItsCluster ObjectIdentity
    | -- | the record under this key describes something else entirely
      RecordNotAClaimedObject Text
    | -- | the record names an object that was there before it
      RecordNamesAPriorObject ObjectIdentity
    deriving (Eq, Show)

-- | One rendering, so a driver never writes a second description of a conflict.
clusterStandingConflictMessage :: ClusterStandingConflict -> Text
clusterStandingConflictMessage conflict = case conflict of
    ClusterUnderNoRecord ->
        "something already stands at this cluster's name under no durable record of this project's, \
        \and this transaction adopts nothing it finds"
    ClusterOutcomeUnknown ->
        "this record is published and not yet bound, and the driver and the runtime disagree about \
        \whether the cluster it names exists"
    NodeReplaced expected observed ->
        "this record is bound to "
            <> objectIdentityText expected
            <> " and the runtime now names "
            <> objectIdentityText observed
            <> " at the same node"
    NodeVanished expected ->
        "this record is bound to "
            <> objectIdentityText expected
            <> " and the runtime names no container at all"
    ClusterWithoutItsNode ->
        "the driver names this cluster and the runtime names no container for the node that carries \
        \its identity"
    NodeWithoutItsCluster observed ->
        "the runtime still holds "
            <> objectIdentityText observed
            <> " and the driver names no cluster at this name"
    RecordNotAClaimedObject described ->
        "the record under this key describes " <> described
    RecordNamesAPriorObject observed ->
        "the record names the prior object "
            <> objectIdentityText observed
            <> ", so it was published over something it did not create"

-- ---------------------------------------------------------------------------
-- The decisions

{- | Where the cluster transaction stands, from the three facts that decide it.

The driver's answer and the runtime's answer are both required, and they must
agree. A cluster the driver names whose identity-carrying node container is
absent, and a node container that outlives the cluster the driver names, are each
one of the two authorities contradicting the other — and acting on either would
be acting on a cluster whose parts are in a state neither authority describes.
-}
clusterStanding ::
    -- | the durable record the protected store holds under this cluster's key
    Maybe OriginRecord ->
    -- | what the driver's listing says about this cluster's name
    ClusterPresence ->
    -- | what the runtime says about the node container clause 3 binds
    Origin ->
    Either ClusterStandingConflict ClusterStanding
clusterStanding Nothing presence observed = case (presence, observed) of
    (ClusterAbsent, OriginAbsent) -> Right ClusterNothingDone
    _ -> Left ClusterUnderNoRecord
clusterStanding (Just record) presence observed = do
    claimedRecord record
    priorlessRecord record
    case originRecordBinding record of
        Nothing -> case (presence, observed) of
            (ClusterAbsent, OriginAbsent) -> Right ClusterOriginRecorded
            (ClusterPresent, OriginPresent identity) -> Right (ClusterCreatedUnbound identity)
            _ -> Left ClusterOutcomeUnknown
        Just bound -> case (presence, observed) of
            (ClusterPresent, OriginPresent identity)
                | identity == bound -> Right (ClusterOwned bound)
                | otherwise -> Left (NodeReplaced bound identity)
            (ClusterPresent, OriginAbsent) -> Left ClusterWithoutItsNode
            (ClusterAbsent, OriginPresent identity) -> Left (NodeWithoutItsCluster identity)
            (ClusterAbsent, OriginAbsent) -> Left (NodeVanished bound)

{- | Where one node's own transaction stands.

The same decision with the driver's answer removed, because a node other than the
one carrying the cluster's identity is an owned object inside the cluster rather
than the cluster itself: the driver has nothing to say about it, and the runtime
has everything.
-}
nodeStanding ::
    -- | the durable record the protected store holds under this node's key
    Maybe OriginRecord ->
    -- | what the runtime says about the node's container
    Origin ->
    Either ClusterStandingConflict ClusterStanding
nodeStanding Nothing OriginAbsent = Right ClusterNothingDone
nodeStanding Nothing (OriginPresent _) = Left ClusterUnderNoRecord
nodeStanding (Just record) observed = do
    claimedRecord record
    priorlessRecord record
    case (originRecordBinding record, observed) of
        (Nothing, OriginAbsent) -> Right ClusterOriginRecorded
        (Nothing, OriginPresent identity) -> Right (ClusterCreatedUnbound identity)
        (Just bound, OriginAbsent) -> Left (NodeVanished bound)
        (Just bound, OriginPresent identity)
            | identity == bound -> Right (ClusterOwned bound)
            | otherwise -> Left (NodeReplaced bound identity)

{- | Require that this record is one this vocabulary wrote.

A record under this key that describes a directory or a file was written by
another owner, and reading it as though it were this one's is exactly how a
driver comes to act on somebody else's record.
-}
claimedRecord :: OriginRecord -> Either ClusterStandingConflict ()
claimedRecord record = case originRecordKind record of
    ReportedObject _ -> Right ()
    OwnedDirectory -> Left (RecordNotAClaimedObject "a directory")
    OwnedFile _ -> Left (RecordNotAClaimedObject "a file")

{- | A claimed-object record always records an absence.

Clause 1 refuses to record over an object it found, so a record naming a prior
identity is one this vocabulary did not write.
-}
priorlessRecord :: OriginRecord -> Either ClusterStandingConflict ()
priorlessRecord record = case originRecordOrigin record of
    OriginAbsent -> Right ()
    OriginPresent identity -> Left (RecordNamesAPriorObject identity)
