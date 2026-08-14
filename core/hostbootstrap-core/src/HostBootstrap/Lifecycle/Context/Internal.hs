{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private representation and eliminators for exact lifecycle
context admission.

The public facade can mint this package only after joining one canonical root,
protected store, admitted plan, current frame, project frame, and descriptive
context.  Later lifecycle-entry modules may borrow those retained values only
through the root- or nested-specific continuation below.  No downstream module
can import this representation.
-}
module HostBootstrap.Lifecycle.Context.Internal
    ( ValidatedLifecycleContext
    , LifecycleContextError (..)
    , mintValidatedLifecycleContext
    , withValidatedRootLifecycleContext
    , withValidatedNestedLifecycleContext
    , lifecycleContextErrorMessage
    )
where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Context (BinaryContextError)
import HostBootstrap.ProjectPlan
    ( ProjectPlan
    , topology
    , topologyFrameOrder
    , topologyParentEdges
    )
import HostBootstrap.ProjectPlan.Frame
    ( CurrentFrame
    , FrameError
    , ProjectFrame
    , ValidatedContext
    , currentFrameId
    , projectFrameId
    , validatedContextValue
    )
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.Protected (ProtectedStore)
import qualified HostBootstrap.Context as Context

-- | The exact frame's structural position in the admitted plan topology.
data LifecycleFrameMembership
    = LifecycleRootFrame
    | LifecycleNestedFrame

{- | The exact descriptive/effect boundary admitted for one lifecycle frame.

The canonical-root identity remains existential because it is local to root
admission; the five externally relevant identities are nominal and cannot be
relabelled with 'coerce'.  The constructor and every retained authority
projection are package-private.
-}
data ValidatedLifecycleContext scope specDigest planId configId frame where
    ValidatedLifecycleContext ::
        CanonicalProjectRoot scope rootId ->
        ProtectedStore ->
        CurrentFrame scope planId frame ->
        ProjectFrame scope specDigest planId configId frame ->
        ValidatedContext scope planId frame ->
        LifecycleFrameMembership ->
        ValidatedLifecycleContext scope specDigest planId configId frame

type role ValidatedLifecycleContext nominal nominal nominal nominal nominal

-- | Structured lifecycle-context admission failures.
data LifecycleContextError
    = LifecycleContextBinaryContextError BinaryContextError
    | LifecycleContextPlanRootMismatch FilePath FilePath
    | LifecycleContextSourceRootMismatch FilePath FilePath
    | LifecycleContextStoreRootMismatch FilePath FilePath
    | LifecycleContextStoreIdentityMismatch Text Text
    | LifecycleContextFrameError FrameError
    | LifecycleContextPlanRootCount [Text]
    | LifecycleContextFrameEvidenceMismatch Text Text Text
    | LifecycleContextFrameOutsidePlan Text
    | LifecycleContextRootFrameRequired Text
    | LifecycleContextNestedFrameRequired Text
    deriving (Eq, Show)

{- | Mint the opaque package and derive root membership solely from the exact
plan topology and the jointly admitted frame evidence.

The caller cannot supply a root Boolean or a frame name.  The repeated runtime
checks are intentional: later internal refactors cannot silently weaken the
fact that all three retained frame views identify the same admitted node.
-}
mintValidatedLifecycleContext ::
    ProjectPlan scope specDigest planId configId cfg ->
    CanonicalProjectRoot scope rootId ->
    ProtectedStore ->
    CurrentFrame scope planId frame ->
    ProjectFrame scope specDigest planId configId frame ->
    ValidatedContext scope planId frame ->
    Either
        LifecycleContextError
        (ValidatedLifecycleContext scope specDigest planId configId frame)
mintValidatedLifecycleContext plan root store current projectFrame validated
    | currentId /= projectId || currentId /= contextId =
        Left
            ( LifecycleContextFrameEvidenceMismatch
                currentId
                projectId
                contextId
            )
    | currentId `notElem` orderedFrames =
        Left (LifecycleContextFrameOutsidePlan currentId)
    | [rootId] <- roots =
        Right
            ( ValidatedLifecycleContext
                root
                store
                current
                projectFrame
                validated
                ( if currentId == rootId
                    then LifecycleRootFrame
                    else LifecycleNestedFrame
                )
            )
    | otherwise = Left (LifecycleContextPlanRootCount roots)
  where
    currentId = currentFrameId current
    projectId = projectFrameId projectFrame
    contextId = Context.currentFrame (validatedContextValue validated)
    derived = topology plan
    orderedFrames = map fst (NonEmpty.toList (topologyFrameOrder derived))
    childFrames = map snd (topologyParentEdges derived)
    roots = filter (`notElem` childFrames) orderedFrames

{- | Borrow the exact retained evidence only when this frame is the unique
root derived from the admitted plan topology.
-}
withValidatedRootLifecycleContext ::
    ValidatedLifecycleContext scope specDigest planId configId frame ->
    ( forall rootId.
      CanonicalProjectRoot scope rootId ->
      ProtectedStore ->
      CurrentFrame scope planId frame ->
      ProjectFrame scope specDigest planId configId frame ->
      ValidatedContext scope planId frame ->
      result
    ) ->
    Either LifecycleContextError result
withValidatedRootLifecycleContext
    (ValidatedLifecycleContext root store current projectFrame validated membership)
    use =
        case membership of
            LifecycleRootFrame -> Right (use root store current projectFrame validated)
            LifecycleNestedFrame ->
                Left (LifecycleContextRootFrameRequired (currentFrameId current))

{- | Borrow the exact retained evidence only when this frame is a non-root
member of the admitted plan topology.
-}
withValidatedNestedLifecycleContext ::
    ValidatedLifecycleContext scope specDigest planId configId frame ->
    ( forall rootId.
      CanonicalProjectRoot scope rootId ->
      ProtectedStore ->
      CurrentFrame scope planId frame ->
      ProjectFrame scope specDigest planId configId frame ->
      ValidatedContext scope planId frame ->
      result
    ) ->
    Either LifecycleContextError result
withValidatedNestedLifecycleContext
    (ValidatedLifecycleContext root store current projectFrame validated membership)
    use =
        case membership of
            LifecycleRootFrame ->
                Left (LifecycleContextNestedFrameRequired (currentFrameId current))
            LifecycleNestedFrame -> Right (use root store current projectFrame validated)

-- | Render one stable, single-line lifecycle-context admission diagnostic.
lifecycleContextErrorMessage :: LifecycleContextError -> String
lifecycleContextErrorMessage failure =
    case failure of
        LifecycleContextBinaryContextError detail ->
            "lifecycle context: " ++ Context.contextErrorMessage detail
        LifecycleContextPlanRootMismatch expected actual ->
            mismatch "plan root" expected actual
        LifecycleContextSourceRootMismatch expected actual ->
            mismatch "context source root" expected actual
        LifecycleContextStoreRootMismatch expected actual ->
            mismatch "protected-store root" expected actual
        LifecycleContextStoreIdentityMismatch expected actual ->
            textMismatch "protected-store identity" expected actual
        LifecycleContextFrameError detail ->
            "lifecycle context: frame admission failed: " ++ show detail
        LifecycleContextPlanRootCount roots ->
            "lifecycle context: admitted plan topology must have one root, got "
                ++ show (map Text.unpack roots)
        LifecycleContextFrameEvidenceMismatch current project context ->
            "lifecycle context: retained frame evidence disagrees (current "
                ++ show (Text.unpack current)
                ++ ", project "
                ++ show (Text.unpack project)
                ++ ", context "
                ++ show (Text.unpack context)
                ++ ")"
        LifecycleContextFrameOutsidePlan frame ->
            "lifecycle context: frame is outside the admitted plan: "
                ++ show (Text.unpack frame)
        LifecycleContextRootFrameRequired frame ->
            "lifecycle context: root frame required, got " ++ show (Text.unpack frame)
        LifecycleContextNestedFrameRequired frame ->
            "lifecycle context: nested frame required, got " ++ show (Text.unpack frame)
  where
    mismatch label expected actual =
        "lifecycle context: "
            ++ label
            ++ " mismatch (expected "
            ++ show expected
            ++ ", got "
            ++ show actual
            ++ ")"
    textMismatch label expected actual =
        mismatch label (Text.unpack expected) (Text.unpack actual)
