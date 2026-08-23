{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Snapshot-only frame reconstruction for configless teardown recovery.
module HostBootstrap.Lifecycle.Recovery
    ( RecoveredProjectFrame
    , recoveredFrameName
    , recoveredFrameParent
    , recoveredFrameAdapter
    , withRecoveredProjectFramesKernel
    , withMigratedRecoveredProjectFramesKernel
    , withRecoveredChildProjectionBinding
    , foldRecoveredFrameResources
    , RecoveredForestSettled
    , recoveredForestFrameOrder
    , recoveredForestOwnedCount
    , recoveredForestReleasedCount
    , recoveredForestPlanDigest
    , driveRecoveredForestKernel
    )
where

import Data.List (nub)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Lifecycle.Plan
    ( CanonicalPlanSnapshot
    , canonicalPlanSnapshotDigest
    , canonicalPlanRecoveryFramesKernel
    , canonicalPlanResourceMembersKernel
    )
import HostBootstrap.Lifecycle.ResourceRecord
    ( RehydratedOwnershipReceipt
    , RehydratedReleasedTombstone
    , RehydratedResourceHandle
    , RehydratedResourceSet
    , foldRehydratedResourceSetKernel
    , rehydratedHandleFrameKernel
    , rehydratedTombstoneFrameKernel
    , rehydratedResourceSetPlanKernel
    , rehydratedResourceSetDigestKernel
    )
import HostBootstrap.Handoff
    ( HandoffError (HandoffBindingMismatch)
    , RecoveryProjectionBinding
    , RootBroker
    , mkRecoveryProjectionBinding
    , withRecoveryProjectionBindingInput
    )

data RecoveredProjectFrame scope planId brokerGeneration frame =
    RecoveredProjectFrame
        Text
        (Maybe Text)
        Text
        Word64
        (RehydratedResourceSet scope planId brokerGeneration)

type role RecoveredProjectFrame nominal nominal nominal nominal

data RecoveredForestSettled scope planId brokerGeneration =
    RecoveredForestSettled Text [Text] Int Int

type role RecoveredForestSettled nominal nominal nominal

recoveredForestFrameOrder :: RecoveredForestSettled scope planId brokerGeneration -> [Text]
recoveredForestFrameOrder (RecoveredForestSettled _ frames _ _) = frames

recoveredForestOwnedCount :: RecoveredForestSettled scope planId brokerGeneration -> Int
recoveredForestOwnedCount (RecoveredForestSettled _ _ owned _) = owned

recoveredForestReleasedCount :: RecoveredForestSettled scope planId brokerGeneration -> Int
recoveredForestReleasedCount (RecoveredForestSettled _ _ _ released) = released

recoveredForestPlanDigest :: RecoveredForestSettled scope planId brokerGeneration -> Text
recoveredForestPlanDigest (RecoveredForestSettled plan _ _ _) = plan

recoveredFrameName :: RecoveredProjectFrame scope planId brokerGeneration frame -> Text
recoveredFrameName (RecoveredProjectFrame frame _ _ _ _) = frame

recoveredFrameParent :: RecoveredProjectFrame scope planId brokerGeneration frame -> Maybe Text
recoveredFrameParent (RecoveredProjectFrame _ parent _ _ _) = parent

recoveredFrameAdapter :: RecoveredProjectFrame scope planId brokerGeneration frame -> (Text, Word64)
recoveredFrameAdapter (RecoveredProjectFrame _ _ adapter revision _) = (adapter, revision)

-- | Root-only construction of the exact parent-to-child recovery adapter.
-- The complete-set digest is part of the signed wire bytes, while the frame
-- values contribute the only accepted plan and edge coordinates.
withRecoveredChildProjectionBinding ::
    RootBroker scope brokerGeneration verb ->
    RecoveredProjectFrame scope planId brokerGeneration parentFrame ->
    RecoveredProjectFrame scope planId brokerGeneration childFrame ->
    ( forall planDigest recoveryParent recoveryChild recoveryWireDigest.
      ByteString ->
      RecoveryProjectionBinding
        scope brokerGeneration verb planDigest recoveryParent recoveryChild recoveryWireDigest ->
      result
    ) ->
    Either HandoffError result
withRecoveredChildProjectionBinding broker parent child use = do
    let parentResources = recoveredFrameResources parent
        childResources = recoveredFrameResources child
        parentName = recoveredFrameName parent
        childName = recoveredFrameName child
        plan = rehydratedResourceSetPlanKernel parentResources
        setDigest = rehydratedResourceSetDigestKernel parentResources
    if recoveredFrameParent child /= Just parentName
        then Left (HandoffBindingMismatch "the recovered frames do not form the requested parent-child edge")
        else
            if rehydratedResourceSetDigestKernel childResources /= setDigest
                then Left (HandoffBindingMismatch "the recovered frames do not retain the same complete resource set")
                else do
                    nested <- withRecoveryProjectionBindingInput plan parentName childName $ \input ->
                        let wire = recoveryAdapterWire setDigest child
                         in mkRecoveryProjectionBinding broker input wire (use wire)
                    nested

recoveredFrameResources ::
    RecoveredProjectFrame scope planId brokerGeneration frame ->
    RehydratedResourceSet scope planId brokerGeneration
recoveredFrameResources (RecoveredProjectFrame _ _ _ _ resources) = resources

recoveryAdapterWire ::
    Text ->
    RecoveredProjectFrame scope planId brokerGeneration frame ->
    ByteString
recoveryAdapterWire setDigest frame =
    LazyByteString.toStrict . Builder.toLazyByteString . mconcat . map field $
        [ "hostbootstrap/recovered-frame-adapter"
        , "1"
        , TextEncoding.encodeUtf8 setDigest
        , TextEncoding.encodeUtf8 (recoveredFrameName frame)
        , TextEncoding.encodeUtf8 adapter
        , word revision
        ]
  where
    (adapter, revision) = recoveredFrameAdapter frame
    field bytes = Builder.word64BE (fromIntegral (ByteString.length bytes)) <> Builder.byteString bytes
    word = LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64BE

withRecoveredProjectFramesKernel ::
    CanonicalPlanSnapshot ->
    RehydratedResourceSet scope planId brokerGeneration ->
    (forall frame. RecoveredProjectFrame scope planId brokerGeneration frame -> result -> result) ->
    result ->
    Either Text result
withRecoveredProjectFramesKernel snapshot resources consume initial = do
    if rehydratedResourceSetPlanKernel resources == canonicalPlanSnapshotDigest snapshot
        then Right ()
        else Left "the recovered frame resource set belongs to another plan"
    rows <- canonicalPlanRecoveryFramesKernel snapshot
    mapM_ admitAdapter rows
    let names = nub [frame | (frame, _, _) <- rows]
        parentOf frame = case takeWhile (/= frame) names of
            [] -> Nothing
            preceding -> Just (last preceding)
        adapterOf frame = case [(kind, revision) | (observed, kind, revision) <- rows, observed == frame] of
            [] -> ("preserve", 1)
            first : _ -> first
        step value frame =
            let (adapter, revision) = adapterOf frame
             in consume (RecoveredProjectFrame frame (parentOf frame) adapter revision resources) value
    pure (foldl step initial names)
  where
    admitAdapter (_, kind, revision)
        | kind `elem` ["preserve", "core-managed", "project-managed", "step-declared"]
            && revision == 1 = Right ()
        | otherwise = Left "the recovery adapter is not in the project-owned closed table"

-- | Recover candidate frames over the superseded resource set only when both
-- snapshots describe exactly the same durable resource coordinates.
withMigratedRecoveredProjectFramesKernel ::
    CanonicalPlanSnapshot ->
    CanonicalPlanSnapshot ->
    RehydratedResourceSet scope planId brokerGeneration ->
    (forall frame. RecoveredProjectFrame scope planId brokerGeneration frame -> result -> result) ->
    result ->
    Either Text result
withMigratedRecoveredProjectFramesKernel candidate superseded resources consume initial = do
    if rehydratedResourceSetPlanKernel resources == canonicalPlanSnapshotDigest superseded
        then Right ()
        else Left "the migrated recovery resource set belongs to another superseded plan"
    candidateMembers <- canonicalPlanResourceMembersKernel candidate
    supersededMembers <- canonicalPlanResourceMembersKernel superseded
    if candidateMembers == supersededMembers
        then recover candidate
        else Left "the migrated recovery snapshots have different resource membership"
  where
    recover snapshot = do
        rows <- canonicalPlanRecoveryFramesKernel snapshot
        mapM_ admitAdapter rows
        let names = nub [frame | (frame, _, _) <- rows]
            parentOf frame = case takeWhile (/= frame) names of
                [] -> Nothing
                preceding -> Just (last preceding)
            adapterOf frame = case [(kind, revision) | (observed, kind, revision) <- rows, observed == frame] of
                [] -> ("preserve", 1)
                first : _ -> first
            step value frame =
                let (adapter, revision) = adapterOf frame
                 in consume (RecoveredProjectFrame frame (parentOf frame) adapter revision resources) value
        pure (foldl step initial names)
    admitAdapter (_, kind, revision)
        | kind `elem` ["preserve", "core-managed", "project-managed", "step-declared"]
            && revision == 1 = Right ()
        | otherwise = Left "the recovery adapter is not in the project-owned closed table"

foldRecoveredFrameResources ::
    RecoveredProjectFrame scope planId brokerGeneration frame ->
    result ->
    (forall id. result -> RehydratedResourceHandle scope planId id brokerGeneration -> RehydratedOwnershipReceipt scope planId id brokerGeneration -> result) ->
    (forall id. result -> RehydratedReleasedTombstone scope planId id brokerGeneration -> result) ->
    result
foldRecoveredFrameResources (RecoveredProjectFrame frame _ _ _ resources) initial onOwned onReleased =
    snd $ foldRehydratedResourceSetKernel resources initial owned released
  where
    owned value handle receipt
        | rehydratedHandleFrameKernel handle == frame = onOwned value handle receipt
        | otherwise = value
    released value tombstone
        | rehydratedTombstoneFrameKernel tombstone == frame = onReleased value tombstone
        | otherwise = value

-- | Drive the exact recovered forest child-first. Released members are counted
-- as already terminal and never enter the backend callback.
driveRecoveredForestKernel ::
    CanonicalPlanSnapshot ->
    RehydratedResourceSet scope planId brokerGeneration ->
    (forall id.
      Text ->
      Text ->
      Word64 ->
      RehydratedResourceHandle scope planId id brokerGeneration ->
      RehydratedOwnershipReceipt scope planId id brokerGeneration ->
      IO (Either Text ())) ->
    IO (Either Text (RecoveredForestSettled scope planId brokerGeneration))
driveRecoveredForestKernel snapshot resources runOwned =
    case validate of
        Left failure -> pure (Left failure)
        Right (frames, rows) -> go frames rows 0 0
  where
    validate = do
        if rehydratedResourceSetPlanKernel resources == canonicalPlanSnapshotDigest snapshot
            then Right ()
            else Left "the recovered forest resource set belongs to another plan"
        rows <- canonicalPlanRecoveryFramesKernel snapshot
        mapM_ admitAdapter rows
        pure (reverse (nub [frame | (frame, _, _) <- rows]), rows)
    admitAdapter (_, kind, revision)
        | kind `elem` ["preserve", "core-managed", "project-managed", "step-declared"]
            && revision == 1 = Right ()
        | otherwise = Left "the recovery adapter is not in the project-owned closed table"
    go [] _ owned released = pure (Right (RecoveredForestSettled (canonicalPlanSnapshotDigest snapshot) [] owned released))
    go ordered@(frame : remaining) rows owned released = do
        let (adapter, revision) = case [(kind, rev) | (observed, kind, rev) <- rows, observed == frame] of
                first : _ -> first
                [] -> ("preserve", 1)
            (actions, releasedHere) =
                snd $
                    foldRehydratedResourceSetKernel resources ([], 0 :: Int)
                        (\(pending, count) handle receipt ->
                            if rehydratedHandleFrameKernel handle == frame
                                then (pending <> [runOwned frame adapter revision handle receipt], count)
                                else (pending, count))
                        (\(pending, count) tombstone ->
                            if rehydratedTombstoneFrameKernel tombstone == frame
                                then (pending, count + 1)
                                else (pending, count))
        outcome <- runActions actions
        case outcome of
            Left failure -> pure (Left failure)
            Right count -> do
                settled <- go remaining rows (owned + count) (released + releasedHere)
                pure $ case settled of
                    Left failure -> Left failure
                    Right (RecoveredForestSettled plan _ totalOwned totalReleased) ->
                        Right (RecoveredForestSettled plan ordered totalOwned totalReleased)
    runActions [] = pure (Right 0)
    runActions (action : remaining) = do
        outcome <- action
        case outcome of
            Left failure -> pure (Left failure)
            Right () -> fmap ((+ 1) <$>) (runActions remaining)
