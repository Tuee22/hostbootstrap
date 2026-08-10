{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Pure admission of one descriptive binary context into an exact project
plan's frame topology.

This module mints only plan-local descriptive evidence.  Its values carry no
command, journal, cursor, protected-store, or mutation authority, and
'withCurrentFrame' performs no runtime-witness I/O.  A 'ProjectFrame' retains
the admitted semantic 'Text' identifier unchanged, including legal Unicode or
delimiter characters; the effectful lifecycle layer, not this pure boundary,
owns canonical UTF-8 framing and durable cursor identity.
-}
module HostBootstrap.ProjectPlan.Frame
    ( CurrentFrame
    , ProjectFrame
    , ValidatedContext
    , FrameError (..)
    , withCurrentFrame
    , currentFrameId
    , projectFrameId
    , validatedContextValue
    )
where

import Data.List (find, isPrefixOf)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Config.Class (ProjectCfg (cfgContext))
import HostBootstrap.Config.Schema (validatedConfigValue)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Lifecycle.Plan (projectPlanValidatedConfigKernel)
import HostBootstrap.ProjectPlan
    ( ProjectPlan
    , topology
    , topologyFrameOrder
    , topologyParentEdges
    )

-- | The current frame of one exact admitted plan.
newtype CurrentFrame scope planId frame = CurrentFrame Text

type role CurrentFrame nominal nominal nominal

{- | The same frame joined to the plan's specification and validated
configuration identities.
-}
newtype ProjectFrame scope specDigest planId configId frame = ProjectFrame Text

type role ProjectFrame nominal nominal nominal nominal nominal

-- | The exact descriptive context admitted for a plan-local frame.
newtype ValidatedContext scope planId frame = ValidatedContext Context.BinaryContext

type role ValidatedContext nominal nominal nominal

{- | A pure frame-admission refusal.

Expected values precede observed values in every mismatch constructor.
'FrameContextTopologyError' preserves the canonical context validator's typed
diagnostic instead of translating it into text.
-}
data FrameError
    = FrameConfigContextMismatch Context.BinaryContext Context.BinaryContext
    | FrameContextTopologyError Context.BinaryContextError
    | FrameTopologyIdsMismatch [Text] [Text]
    | FrameTopologyParentEdgesMismatch [(Text, Text)] [(Text, Text)]
    | FrameCurrentFrameEndpointMismatch Text Text
    deriving (Eq, Show)

{- | Join the exact context retained by an admitted configuration to the
prefix of the topology derived from that same project plan.

The context must equal the plan-retained config context byte-for-value, pass
the total pure topology validator, describe an ordered frame/parent prefix of
the plan topology, and name that prefix's endpoint as its current frame.  Only
after all checks succeed does the rank-2 continuation jointly receive the
three evidence values under one fresh @frame@ identity.  The returned semantic
identifier is not a record-key encoding and is never interpreted here as
lifecycle authority.
-}
withCurrentFrame ::
    (ProjectCfg cfg) =>
    ProjectPlan scope specDigest planId configId cfg ->
    Context.BinaryContext ->
    ( forall frame.
      CurrentFrame scope planId frame ->
      ProjectFrame scope specDigest planId configId frame ->
      ValidatedContext scope planId frame ->
      result
    ) ->
    Either FrameError result
withCurrentFrame plan supplied use
    | supplied /= retained =
        Left (FrameConfigContextMismatch retained supplied)
    | Left failure <- Context.validateTopology supplied =
        Left (FrameContextTopologyError failure)
    | Just currentTopology <-
        find
            ((== Context.currentFrame supplied) . Context.topologyFrameId)
            (Context.topologyFrames supplied)
    , Context.topologyKind currentTopology /= Context.contextKind supplied =
        Left
            ( FrameContextTopologyError
                ( Context.ContextCurrentFrameKindMismatch
                    (Context.currentFrame supplied)
                    (Context.contextKind supplied)
                    (Context.topologyKind currentTopology)
                )
            )
    | not (contextIds `isPrefixOf` planIds) =
        Left
            ( FrameTopologyIdsMismatch
                (take (length contextIds) planIds)
                contextIds
            )
    | not (contextEdges `isPrefixOf` planEdges) =
        Left
            ( FrameTopologyParentEdgesMismatch
                (take (length contextEdges) planEdges)
                contextEdges
            )
    | endpoint : _ <- reverse contextIds
    , Context.currentFrame supplied /= endpoint =
        Left
            ( FrameCurrentFrameEndpointMismatch
                endpoint
                (Context.currentFrame supplied)
            )
    | endpoint : _ <- reverse contextIds =
        Right
            ( use
                (CurrentFrame endpoint)
                (ProjectFrame endpoint)
                (ValidatedContext supplied)
            )
    | otherwise =
        -- 'validateTopology' has already required exactly one root, hence a
        -- non-empty context topology.  Keep the total fallback descriptive in
        -- case that lower invariant changes.
        Left (FrameTopologyIdsMismatch planIds [])
  where
    retained =
        cfgContext
            (validatedConfigValue (projectPlanValidatedConfigKernel plan))
    derived = topology plan
    planIds = map fst (NonEmpty.toList (topologyFrameOrder derived))
    planEdges = topologyParentEdges derived
    contextIds = map Context.topologyFrameId (Context.topologyFrames supplied)
    contextEdges =
        [ (Context.topologyParentId frame, Context.topologyFrameId frame)
        | frame <- Context.topologyFrames supplied
        , not (Text.null (Context.topologyParentId frame))
        ]

-- | The semantic identifier retained by current-frame evidence.
currentFrameId :: CurrentFrame scope planId frame -> Text
currentFrameId (CurrentFrame frameId) = frameId

-- | The semantic identifier retained by exact project-frame evidence.
projectFrameId :: ProjectFrame scope specDigest planId configId frame -> Text
projectFrameId (ProjectFrame frameId) = frameId

-- | The exact descriptive context admitted for this plan-local frame.
validatedContextValue :: ValidatedContext scope planId frame -> Context.BinaryContext
validatedContextValue (ValidatedContext context) = context
