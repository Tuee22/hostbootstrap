{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | What the root authorizes and settles for one node of one frame session.

The frame session owner holds the durable row a session *is*. This module holds
what happens inside one: preparing the exact node grant a storeless executor
needs, and settling the observation that comes back. Splitting them is not
bookkeeping — it is the boundary. This module reaches a session only through
its fixed-unit coordinate fold, so it never sees the session's record key,
version, or row bytes and cannot advance or rewrite the session itself. It
derives its own keys from the coordinates it is shown, and every row it writes
is its own.

Both operations are durable-first. A grant does not exist until every exact
unknown row is published and read back; a settlement does not exist until the
observation row is published and read back. Neither produces or signs a
response — the signed bytes are supplied, and the live root endpoint owns
producing them — so no answer can be manufactured here to match a decision
already taken.
-}
module HostBootstrap.Lifecycle.Rooted.Node
    ( withPreparedRootedNodeGrantKernel
    , withSettledRootedNodeKernel
    )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (nub)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Handoff (childConfigDigest, frameWire)
import HostBootstrap.Handoff.Rooted
    ( rootedLifecycleRequestFromWireKernel
    , rootedLifecycleResponseFromWireKernel
    , withRootedLifecycleRequestKernel
    , withRootedLifecycleResponseKernel
    )
import HostBootstrap.Handoff.Runtime
    ( RecursiveHandoffRuntime
    , withRecursiveHandoffRuntimeKernel
    )
import HostBootstrap.Lifecycle.Prepared.Internal
    ( PreparedNodeGrant
    , mintPreparedNodeGrantKernel
    , renderPreparedGatePackageKernel
    , renderPreparedGatePackagesKernel
    )
import HostBootstrap.Lifecycle.Rooted
    ( RootedFrameSession
    , withRootedFrameSessionKernel
    )
import HostBootstrap.Lifecycle.Session
    ( publishRootedUnknownRowKernel
    , rootedNodeUnknownKeyKernel
    , rootedSettlementKeyKernel
    , sessionErrorMessage
    )
import HostBootstrap.Protected (ProtectedStore, RecordKey, recordVersionWord, withProtectedEntry)

{- | Publish every exact durable unknown row, then mint one node's grant.

The ordering is the deliverable, not an implementation detail. The node's own
operation is prepared first, then each projected operation in the catalog's own
order, and every one of them is compare-and-swap published and strictly read
back before the grant exists. A row that comes back as anything other than the
exact bytes rendered for it stops the whole preparation, so a partially
prepared node yields no grant at all rather than a grant covering less than it
claims.

Only an attached session can prepare. An opened-but-unattached session has
answered no @OpenFrame@, so there is no exchange for a grant to belong to, and
the root arm is required again here for the same reason it was required to
open: preparation is a durable root transition.

The signed response is supplied rather than produced. This module names no
response builder and no signer, so a @Descend@ or @Refused@ answer cannot be
turned into a grant here — those are different response families with no
constructor on this path at all.
-}
withPreparedRootedNodeGrantKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProtectedStore ->
    Word64 ->
    Text ->
    Text ->
    [Text] ->
    [Text] ->
    ( forall node.
      PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withPreparedRootedNodeGrantKernel #-}
withPreparedRootedNodeGrantKernel runtime session store generation localPlanDigest node dependencies projectedOperations use =
    withRootedFrameSessionKernel session $
        \attached _verb lineage catalogIdentity frame _path token _stage ordinal _predecessor ->
            withRecursiveHandoffRuntimeKernel runtime $
                \atRoot _project _tag _store _generation _runtimeVerb _keyDigest current ->
                    case admit attached atRoot current of
                        Left failure -> pure (Left failure)
                        Right () -> do
                            prepared <-
                                publishOrdered lineage localPlanDigest catalogIdentity frame token ordinal (node : projectedOperations) []
                            case prepared of
                                Left failure -> pure (Left failure)
                                Right [] -> pure (Left (nodeFailure "no durable unknown row was prepared"))
                                Right (own : projected) ->
                                    use
                                        ( mintPreparedNodeGrantKernel
                                            node
                                            dependencies
                                            own
                                            (renderPreparedGatePackagesKernel projected)
                                        )
  where
    admit attached atRoot current = do
        require "an unattached rooted frame session cannot prepare a node grant" attached
        require "a keyless nested arm cannot prepare a node grant" atRoot
        require "the runtime is not path-agnostic" (isNothing current)
        require "the prepared node key is empty" (not (Text.null node))
        require "a dependency operation key is empty" (not (any Text.null dependencies))
        require "the prepared node appears in its own projections" (node `notElem` projectedOperations)
        require "the projected operation order contains duplicates"
            (length projectedOperations == length (nub projectedOperations))
        require "a projected operation key is empty" (not (any Text.null projectedOperations))
        require "the broker generation is zero" (generation > 0)

    publishOrdered _ _ _ _ _ _ [] packages = pure (Right (reverse packages))
    publishOrdered lineage localDigest catalogIdentity frame token ordinal (operation : remaining) packages =
        case rootedNodeUnknownKeyKernel lineage catalogIdentity frame operation of
            Left failure -> pure (Left (nodeFailure (Text.pack (sessionErrorMessage failure))))
            Right key -> do
                let unknown = renderUnknownRow lineage catalogIdentity frame token operation
                published <- publishExactRow store "unknown" key unknown
                case published of
                    Left failure -> pure (Left failure)
                    Right version ->
                        publishOrdered
                            lineage localDigest catalogIdentity frame token ordinal remaining
                            ( renderPreparedGatePackageKernel
                                localDigest catalogIdentity frame token generation ordinal version
                                : packages
                            )

    renderUnknownRow lineage catalogIdentity frame token operation =
        ByteString.concat
            [ framedText rootedNodeUnknownDomain
            , framedWord 1
            , framedText "unknown"
            , framedText lineage
            , framedText catalogIdentity
            , framedText frame
            , framedText token
            , framedText operation
            ]

{- | Settle one executor observation exactly once, or replay its exact result.

Everything the request echoes is checked against the session's own coordinates
before a byte is written: path, session token, nonce, ordinal, and the
predecessor digest the session recorded when it attached. Only @SettleNode@ and
@DescendResult@ settle; every other request form refuses through one fixed
continuation, so a post-open request of the wrong family cannot reach the
durable transition.

The supplied signed response must belong to the paired @Settled | Refused@
family and must echo the same path, session, nonce, and ordinal. The
observation row is published and strictly read back first, and only then is the
response's digest taken, so a response can never be recorded for an observation
that was not durably settled.

Settling twice is one settlement. The row is keyed by lineage, catalog, frame,
node, and ordinal and its bytes carry the observation, so an exact retry
converges on the record already present; a different observation under the same
coordinates comes back as different bytes and refuses without effect. No child
gate or local execution authority is created here.
-}
withSettledRootedNodeKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProtectedStore ->
    Text ->
    ByteString ->
    ByteString ->
    (Text -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withSettledRootedNodeKernel #-}
withSettledRootedNodeKernel runtime session store node request signedSettled use =
    withRootedFrameSessionKernel session $
        \attached _verb lineage catalogIdentity frame path token _stage ordinal predecessor ->
            withRecursiveHandoffRuntimeKernel runtime $
                \atRoot _project _tag _store _generation _runtimeVerb _keyDigest current ->
                    case admit attached atRoot current path token ordinal predecessor of
                        Left failure -> pure (Left failure)
                        Right observation ->
                            case rootedSettlementKeyKernel lineage catalogIdentity frame node ordinal of
                                Left failure ->
                                    pure (Left (nodeFailure (Text.pack (sessionErrorMessage failure))))
                                Right key -> do
                                    let settled =
                                            renderSettledRow lineage catalogIdentity frame token node ordinal observation
                                    published <- publishExactRow store "settlement" key settled
                                    case published of
                                        Left failure -> pure (Left failure)
                                        Right _ -> use (childConfigDigest signedSettled)
  where
    admit attached atRoot current path token ordinal predecessor = do
        require "an unattached rooted frame session cannot settle a node" attached
        require "a keyless nested arm cannot settle a node" atRoot
        require "the runtime is not path-agnostic" (isNothing current)
        require "the settled node key is empty" (not (Text.null node))
        require "the session has no recorded predecessor" (isJust predecessor)
        decoded <- either (Left . nodeFailure) Right (rootedLifecycleRequestFromWireKernel request)
        (requestPath, requestSession, requestOrdinal, requestNonce, requestPredecessor, body) <-
            withRootedLifecycleRequestKernel
                decoded
                (const outsideSettlement)
                (\_ _ _ _ _ _ -> outsideSettlement)
                (\p s _ o n pre b -> Right (p, s, o, n, pre, b))
                (\p s _ o n pre b -> Right (p, s, o, n, pre, b))
                (\_ _ _ _ _ _ -> outsideSettlement)
                (\_ _ _ _ _ _ -> outsideSettlement)
        require "the settle request echoes another requester path" (requestPath == path)
        require "the settle request echoes another session" (requestSession == token)
        require "the settle request echoes another ordinal" (requestOrdinal == ordinal)
        require "the settle request nonce is empty" (not (ByteString.null requestNonce))
        require "the settle request echoes another predecessor" (Just requestPredecessor == predecessor)
        require "the settled observation is empty" (not (ByteString.null body))
        response <-
            either (Left . nodeFailure) Right (rootedLifecycleResponseFromWireKernel signedSettled)
        (responsePath, responseSession, responseOrdinal, responseNonce) <-
            withRootedLifecycleResponseKernel
                response
                (\_ _ _ _ _ _ -> outsideSettlementFamily)
                (\_ _ _ _ _ _ _ _ _ _ _ -> outsideSettlementFamily)
                (\_ _ _ _ _ _ _ _ -> outsideSettlementFamily)
                (\_ p s _ o n _ _ -> Right (p, s, o, n))
                (\_ _ _ _ _ _ _ _ -> outsideSettlementFamily)
                (\_ _ _ _ _ _ _ _ -> outsideSettlementFamily)
                (\_ p s _ o n _ _ -> Right (p, s, o, n))
        require "the signed response echoes another requester path" (responsePath == path)
        require "the signed response echoes another session" (responseSession == token)
        require "the signed response does not select a successor ordinal" (responseOrdinal > ordinal)
        require "the signed response echoes another nonce" (responseNonce == requestNonce)
        pure body

    outsideSettlement =
        Left (nodeFailure "only a SettleNode or DescendResult request settles a rooted node")
    outsideSettlementFamily =
        Left (nodeFailure "only a paired Settled or Refused response settles a rooted node")

    renderSettledRow lineage catalogIdentity frame token settledNode ordinal observation =
        ByteString.concat
            [ framedText rootedSettlementDomain
            , framedWord 1
            , framedText "settled"
            , framedText lineage
            , framedText catalogIdentity
            , framedText frame
            , framedText token
            , framedText settledNode
            , framedWord ordinal
            , frameWire observation
            ]

{- | Publish one exact row and read it back, or refuse without effect.

The store transition is the neutral absent-then-strict-readback one both durable
rows here use. What makes it exact is the comparison after it: unless the bytes
the store holds are byte-identical to the ones rendered, this refuses, so an
exact retry converges on the record already present while different bytes under
the same coordinates never pass for it.
-}
publishExactRow :: ProtectedStore -> Text -> RecordKey -> ByteString -> IO (Either Text Word64)
publishExactRow store label key expected = do
    entered <- withProtectedEntry store $ \protected ->
        Right <$> publishRootedUnknownRowKernel protected key expected
    pure $ case entered of
        Left failure -> Left (nodeFailure (Text.pack (show failure)))
        Right (Left failure) -> Left (nodeFailure (Text.pack (sessionErrorMessage failure)))
        Right (Right (version, present))
            | present /= expected ->
                Left (nodeFailure ("the durable " <> label <> " row is not this preparation"))
            | otherwise -> Right (recordVersionWord version)

rootedNodeUnknownDomain :: Text
rootedNodeUnknownDomain = "hostbootstrap/rooted-node-unknown"

rootedSettlementDomain :: Text
rootedSettlementDomain = "hostbootstrap/rooted-node-settlement"

framedText :: Text -> ByteString
framedText = frameWire . TextEncoding.encodeUtf8

framedWord :: Word64 -> ByteString
framedWord = frameWire . LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64BE

require :: Text -> Bool -> Either Text ()
require _ True = Right ()
require detail False = Left (nodeFailure detail)

nodeFailure :: Text -> Text
nodeFailure detail = "rooted node: " <> detail
