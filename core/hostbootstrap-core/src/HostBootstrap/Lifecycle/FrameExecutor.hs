{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | What one nested frame is, once the root has answered its opening.

A frame executor is deliberately the poorest value in the recursive lifecycle.
It holds no protected store, journal, lease, snapshot, catalog row, signing
key, session opener, or settlement operation, and there is no function from one
to any of those. What it holds is a place in a conversation: the canonical path
the root admitted, the opaque session and stage the root selected, the ordinal
the root said comes next, and the digest of the last complete signed response.
Every one of those arrived inside a response this frame independently verified
against the installed key, so none of them is this frame's own claim.

The asymmetry that makes the arrangement work is that those coordinates
authorize nothing. A frame can say which exchange it is in; it cannot say that
an effect may run. That sentence is the root's, and it arrives as a signed
@Prepared@ answer carrying gate packages the root could only render after every
exact durable unknown row was published and read back. This module's job at
that point is not to trust the answer but to check that the answer is about the
work this frame actually has: the authorized node must be one of the frame's
own plan nodes, its ordered dependencies must be that node's own, its projected
gates must be that node's own projections in the plan's order, and every gate
package must name this frame, this plan, and this session.

Only after all of that does the executor mint the local 'PreparedGate' the
effect runs behind. That is why this module is the one place outside the
journal that may reach 'mintPreparedGate': the gate it mints restates a durable
row the root already wrote, and every coordinate in it came out of bytes the
root signed.

Advancing is equally passive. The executor never chooses a successor stage or
ordinal; it copies the ones the verified response selected, and takes its next
predecessor as the digest of that response's complete signed bytes. A frame
that fabricates a coordinate is not a frame that gets ahead — it is a frame
whose next request fails to pair.
-}
module HostBootstrap.Lifecycle.FrameExecutor
    ( FrameExecutor
    , withOpenedFrameExecutorKernel
    , withFrameExecutorRequestKernel
    , withAdvancedFrameExecutorKernel
    , withExecutedFrameNodeKernel
    )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (find, nub)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority (ProjectVerb)
import HostBootstrap.Handoff
    ( AuthenticatedRootScope
    , ProjectVerificationKey
    , RootedLifecycleResponse
    , childConfigDigest
    , handoffErrorMessage
    , withVerifiedRootedLifecycleResponse
    )
import HostBootstrap.Handoff.Rooted
    ( renderRootedLifecycleRequestKernel
    , rootedCloseFrameRequestKernel
    , rootedNextNodeRequestKernel
    , rootedReceiptConfirmRequestKernel
    , rootedSettleNodeRequestKernel
    , withRootedLifecycleResponseKernel
    )
import HostBootstrap.Lifecycle.Execution.Internal
    ( ExecutionNode
    , ResourceCarrier
    , executionNodeDependencyKeys
    , executionNodeFrame
    , executionNodeOperationKey
    , executionNodeProjectedKeys
    , newResourceCarrier
    )
import HostBootstrap.Lifecycle.Prepared.Internal
    ( PreparedGate
    , mintPreparedGate
    , readPreparedGatePackageKernel
    , readPreparedGatePackagesKernel
    , renderPreparedGatePackagesKernel
    , renderPreparedNodeKeysKernel
    )

{- | One nested frame's place in its root-owned exchange.

The seven indices are all nominal, and five of them are minted by the opening
rather than chosen: a frame cannot name its own root plan, broker generation,
catalog, frame, or session index and be handed an executor for it, so one
frame's executor is not another's even where every retained value happens to
agree.

The retained values are the verified root scope, the closed invocation verb,
the frame's own name, plan digest, and plan nodes, its frame-local carrier, and
the four coordinates the root selected. The carrier is indexed by the same
scope and frame index, so a handle acquired in one frame is unreadable in
another even though the erased form carries no index of its own.
-}
data FrameExecutor
    scope rootPlanId brokerGeneration catalogId frame sessionId verb
    where
    FrameExecutor ::
        AuthenticatedRootScope scope ->
        ProjectVerb verb ->
        Text ->
        Text ->
        [ExecutionNode] ->
        ResourceCarrier scope frame ->
        [Text] ->
        Text ->
        Text ->
        Word64 ->
        Text ->
        FrameExecutor scope rootPlanId brokerGeneration catalogId frame sessionId verb

type role FrameExecutor nominal nominal nominal nominal nominal nominal nominal

instance
    Show (FrameExecutor scope rootPlanId brokerGeneration catalogId frame sessionId verb)
    where
    show _ = "FrameExecutor <storeless>"

{- | Open one executor from the exact verified answer to this frame's opening.

Nothing here is taken on the requester's word. The signed response is verified
against the independently installed key and against the exact @OpenFrame@ bytes
this frame sent, so a response answering a different request cannot reach the
fold at all. Only an @Opened@ may open an executor; every other response family
leaves through one fixed refusal, which is what stops a @Refused@ or a
post-open answer from being read as permission to start.

The frame's own plan is supplied rather than derived, because a storeless frame
reconstructs its cataloged target plan locally and this module is not where
that happens. What this module insists on is that the nodes supplied are this
frame's: every node must name the frame being opened, and their operation keys
must be distinct, so a plan carrying one key twice can never make a later exact
comparison ambiguous.

The retained coordinates are exactly the response's. The path is the one the
root admitted, the session and stage are the root's opaque selections, the
ordinal is the one the root said comes next, and the first predecessor is the
digest of the complete signed bytes just verified — the same digest the root
recorded before it released them.
-}
withOpenedFrameExecutorKernel ::
    ProjectVerificationKey ->
    AuthenticatedRootScope scope ->
    ProjectVerb verb ->
    Text ->
    Text ->
    [ExecutionNode] ->
    ByteString ->
    ByteString ->
    ( forall rootPlanId brokerGeneration catalogId frame sessionId.
      FrameExecutor scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withOpenedFrameExecutorKernel #-}
withOpenedFrameExecutorKernel key scope verb frameName planDigest nodes request signedOpened use =
    case admit of
        Left failure -> pure (Left failure)
        Right (path, session, stage, ordinal) -> do
            carrier <- newResourceCarrier
            use
                ( FrameExecutor
                    scope
                    verb
                    frameName
                    planDigest
                    nodes
                    carrier
                    path
                    session
                    stage
                    ordinal
                    (childConfigDigest signedOpened)
                )
  where
    admit = do
        require "the executing frame is empty" (not (Text.null frameName))
        require "the frame plan digest is empty" (not (Text.null planDigest))
        require "the frame plan has no execution node" (not (null nodes))
        require
            "a supplied execution node belongs to another frame"
            (all ((== frameName) . executionNodeFrame) nodes)
        require
            "the frame plan carries one operation key twice"
            (length keys == length (nub keys))
        verified <- verifiedResponse key request signedOpened
        withRootedLifecycleResponseKernel
            verified
            (\_ path session stage ordinal _ -> Right (path, session, stage, ordinal))
            (\_ _ _ _ _ _ _ _ _ _ _ -> beforeOpened)
            (\_ _ _ _ _ _ _ _ -> beforeOpened)
            (\_ _ _ _ _ _ _ _ -> beforeOpened)
            (\_ _ _ _ _ _ _ _ -> beforeOpened)
            (\_ _ _ _ _ _ _ _ -> beforeOpened)
            (\_ _ _ _ _ _ _ _ -> beforeOpened)

    keys = map executionNodeOperationKey nodes

    beforeOpened =
        Left (executorFailure "only a verified Opened response opens a frame executor")

{- | Build this frame's next request from coordinates it did not choose.

The four post-open families a frame may raise are named by a closed selector
rather than assembled from parts, so there is no shape here that produces a
request outside them and none at all that produces an @OpenFrame@ — an executor
exists only because one was already answered.

Every echoed coordinate is the executor's own retained one. The caller supplies
the fresh nonce and, for the one body-bearing family, the observation; it
supplies no path, session, stage, ordinal, or predecessor, so holding an
executor is not a way to move the exchange to a position the root has not yet
selected.

What escapes is the exact canonical request wire and nothing else, so the
caller can send those bytes and later verify the answer against them without
receiving an executor, coordinate, plan, node, or carrier.
-}
withFrameExecutorRequestKernel ::
    FrameExecutor scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text ->
    ByteString ->
    Maybe ByteString ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withFrameExecutorRequestKernel #-}
withFrameExecutorRequestKernel executor family nonce body use =
    case built of
        Left failure -> pure (Left failure)
        Right request -> use (renderRootedLifecycleRequestKernel request)
  where
    FrameExecutor _ _ _ _ _ _ path session stage ordinal predecessor = executor
    built = case (family, body) of
        ("next-node", Nothing) ->
            wire (rootedNextNodeRequestKernel path session stage ordinal nonce predecessor)
        ("close-frame", Nothing) ->
            wire (rootedCloseFrameRequestKernel path session stage ordinal nonce predecessor)
        ("receipt-confirm", Nothing) ->
            wire (rootedReceiptConfirmRequestKernel path session stage ordinal nonce predecessor)
        ("settle-node", Just observation) ->
            wire
                ( rootedSettleNodeRequestKernel
                    path
                    session
                    stage
                    ordinal
                    nonce
                    predecessor
                    observation
                )
        (_, Just _) ->
            Left (executorFailure "only a settle-node request carries an observation body")
        _ -> Left (executorFailure "a frame executor raises no request outside its four families")
    wire = either (Left . executorFailure) Right

{- | Advance to the successor the verified response selected.

The response is verified against the installed key and the exact request it
answers before a coordinate is read, so an unpaired or unsigned answer never
reaches an advance. An @Opened@ cannot advance an executor, because an executor
exists only where an opening was already answered and a second one would mean
two openings for one frame.

The successor stage and ordinal are the response's own, and the ordinal must be
strictly greater than the one just used — a root reissuing the same ordinal
would be authorizing one position twice. The next predecessor is the digest of
the complete signed bytes, which is the value the root will require the next
request to echo.
-}
withAdvancedFrameExecutorKernel ::
    FrameExecutor scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProjectVerificationKey ->
    ByteString ->
    ByteString ->
    ( FrameExecutor scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withAdvancedFrameExecutorKernel #-}
withAdvancedFrameExecutorKernel executor key request signedResponse use =
    case advanced of
        Left failure -> pure (Left failure)
        Right successor -> use successor
  where
    FrameExecutor scope verb frameName planDigest nodes carrier path session _ ordinal _ = executor
    advanced = do
        verified <- verifiedResponse key request signedResponse
        (responsePath, responseSession, successorStage, successorOrdinal) <-
            withRootedLifecycleResponseKernel
                verified
                (\_ _ _ _ _ _ -> afterOpened)
                (\_ p s st o _ _ _ _ _ _ -> Right (p, s, st, o))
                (\_ p s st o _ _ _ -> Right (p, s, st, o))
                (\_ p s st o _ _ _ -> Right (p, s, st, o))
                (\_ p s st o _ _ _ -> Right (p, s, st, o))
                (\_ p s st o _ _ _ -> Right (p, s, st, o))
                (\_ p s st o _ _ _ -> Right (p, s, st, o))
        require "the verified response echoes another requester path" (responsePath == path)
        require "the verified response echoes another session" (responseSession == session)
        require
            "the verified response does not select a successor ordinal"
            (successorOrdinal > ordinal)
        pure
            ( FrameExecutor
                scope
                verb
                frameName
                planDigest
                nodes
                carrier
                path
                session
                successorStage
                successorOrdinal
                (childConfigDigest signedResponse)
            )

    afterOpened =
        Left (executorFailure "an Opened response cannot advance an opened frame executor")

{- | Run one node's local effect behind the gate the root already recorded.

The four packages are not arguments here — they are read out of the signed
answer this frame verified, and only out of a @Prepared@ one. Every other
response family, including a signed @Refused@ and the @Descend@ that means this
node is somebody else's work, leaves through one fixed refusal, so "the root
answered" and "the root authorized this effect" cannot be confused at the only
call site where the difference matters.

The comparison happens before the mint and the mint before the effect. The
authorized node the answer names must be one of this frame's own plan nodes;
that node's ordered dependencies must be exactly the ones the plan gave it; and
the projected gates must be exactly that node's own projections, in the plan's
order and with the same count. Each gate package must in turn name this frame's
plan digest, this frame, and this session, and the projected list must
re-render byte-identically from the packages it carried, so a list that decodes
into the same set in another order is a different list.

Only then is 'mintPreparedGate' reached, and what it is given comes entirely
out of the packages: the attempt and journal version are the root's durable
coordinates, which a storeless frame has no other way to know. The effect runs
behind those gates and returns one closed observation, which is the only thing
the continuation may produce.

Nothing durable happens here. There is no store, no compare-and-swap, and no
settlement — the observation goes back to the root as an ordinary request, and
the root alone decides that it settled.
-}
withExecutedFrameNodeKernel ::
    FrameExecutor scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProjectVerificationKey ->
    ByteString ->
    ByteString ->
    ( ExecutionNode ->
      PreparedGate ->
      [PreparedGate] ->
      ResourceCarrier scope frame ->
      IO (Either Text ByteString)
    ) ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withExecutedFrameNodeKernel #-}
withExecutedFrameNodeKernel executor key request signedPrepared run use =
    case admit of
        Left failure -> pure (Left failure)
        Right (node, gate, projected) -> do
            observed <- run node gate projected carrier
            case observed of
                Left failure -> pure (Left failure)
                Right observation
                    | ByteString.null observation ->
                        pure (Left (executorFailure "the local effect returned an empty observation"))
                    | otherwise -> use observation
  where
    FrameExecutor _ _ frameName planDigest nodes carrier path session _ _ _ = executor

    admit = do
        verified <- verifiedResponse key request signedPrepared
        (responsePath, responseSession, authorized, dependencies, operationGate, projectedGates) <-
            withRootedLifecycleResponseKernel
                verified
                (\_ _ _ _ _ _ -> outsidePrepared)
                (\_ p s _ _ _ n d o g _ -> Right (p, s, n, d, o, g))
                (\_ _ _ _ _ _ _ _ -> outsidePrepared)
                (\_ _ _ _ _ _ _ _ -> outsidePrepared)
                (\_ _ _ _ _ _ _ _ -> outsidePrepared)
                (\_ _ _ _ _ _ _ _ -> outsidePrepared)
                (\_ _ _ _ _ _ _ _ -> outsidePrepared)
        require "the Prepared response echoes another requester path" (responsePath == path)
        require "the Prepared response echoes another session" (responseSession == session)
        node <-
            maybe
                (Left (executorFailure "the authorized node is not one of this frame's plan nodes"))
                Right
                ( find
                    ((== authorized) . TextEncoding.encodeUtf8 . executionNodeOperationKey)
                    nodes
                )
        require
            "the authorized dependencies are not this node's own"
            (dependencies == renderPreparedNodeKeysKernel (executionNodeDependencyKeys node))
        packages <- readPreparedGatePackagesKernel projectedGates
        require
            "the projected gate list is not the canonical one it carries"
            (renderPreparedGatePackagesKernel packages == projectedGates)
        require
            "the projected gates are not this node's own projections"
            (length packages == length (executionNodeProjectedKeys node))
        gate <- gateFor (executionNodeOperationKey node) operationGate
        projected <- traverse (uncurry gateFor) (zip (executionNodeProjectedKeys node) packages)
        pure (node, gate, projected)

    outsidePrepared =
        Left (executorFailure "only a verified Prepared response authorizes a local effect")

    gateFor operation package = do
        (packagePlan, _catalog, packageFrame, packageSession, generation, attempt, journalVersion) <-
            readPreparedGatePackageKernel package
        require "a gate package names another plan" (packagePlan == planDigest)
        require "a gate package names another frame" (packageFrame == frameName)
        require "a gate package names another session" (packageSession == session)
        require "a gate package carries a zero supersession generation" (generation > 0)
        pure (mintPreparedGate packagePlan operation packageSession generation attempt journalVersion)

{- | Turn signed bytes into a response only through the installed key.

Every entry point above goes through this one helper, so there is no branch in
this module that reads a coordinate off bytes that were not verified against
both the installed key and the exact request they claim to answer.
-}
verifiedResponse ::
    ProjectVerificationKey ->
    ByteString ->
    ByteString ->
    Either Text RootedLifecycleResponse
verifiedResponse key request signed =
    either
        (Left . executorFailure . Text.pack . handoffErrorMessage)
        Right
        (withVerifiedRootedLifecycleResponse key request signed id)

require :: Text -> Bool -> Either Text ()
require _ True = Right ()
require detail False = Left (executorFailure detail)

executorFailure :: Text -> Text
executorFailure detail = "frame executor: " <> detail
