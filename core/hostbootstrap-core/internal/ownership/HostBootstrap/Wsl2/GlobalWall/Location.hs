{-# LANGUAGE OverloadedStrings #-}

{- | Package-private location of the current user's global wall.

The Windows entry chooses the target and state directory after admitting its
profile. This record pairs that target with the protected store holding
clauses 1 and 2. Raw construction and store/key access stay inside the package;
the public driver re-exports the opaque type, target reporting and read-only presence.
-}
module HostBootstrap.Wsl2.GlobalWall.Location (
    HostWallLocation,
    openHostWallLocation,
    hostWallTargetPath,
    hostWallProtectedStore,
    hostWallActiveRecordKey,
    hostWallOwnershipPresent,
    hostWallTarget,
    hostWallStore,
    hostWallActiveKey,
    hostWallFenceKey,
) where

import qualified Data.Text as Text
import HostBootstrap.Protected (
    ProtectedError,
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    readProtectedRecord,
 )

data HostWallLocation = HostWallLocation
    { hostWallTarget :: FilePath
    , hostWallStore :: ProtectedStore
    , hostWallActiveKey :: RecordKey
    , hostWallFenceKey :: RecordKey
    }

hostWallTargetPath :: HostWallLocation -> FilePath
hostWallTargetPath = hostWallTarget

-- | The actual store used by the driver and real-store crash fixtures.
hostWallProtectedStore :: HostWallLocation -> ProtectedStore
hostWallProtectedStore = hostWallStore

hostWallActiveRecordKey :: HostWallLocation -> RecordKey
hostWallActiveRecordKey = hostWallActiveKey

-- | Observe the canonical active record inside the caller's live entry.
--
-- This projection returns presence only: no record key, store or mutation
-- authority leaves it. Malformed retained bytes still mean ownership remains.
hostWallOwnershipPresent :: ProtectedSession session -> IO (Either ProtectedError Bool)
hostWallOwnershipPresent session = case mkRecordKey wallActiveRecordKey of
    Left failure -> pure (Left failure)
    Right key -> do
        observed <- readProtectedRecord session key
        pure (fmap (maybe False (const True)) observed)

{- | Open the protected store beside the target chosen by the Windows entry.

The caller supplies its journal-failure constructor, keeping this private
location independent of the public driver error sum. Opening and key
admission remain one computation with the same protected-store failures.
-}
openHostWallLocation ::
    (String -> fault) ->
    FilePath ->
    FilePath ->
    IO (Either fault HostWallLocation)
openHostWallLocation failure target stateDirectory = do
    opened <- openProtectedStore stateDirectory
    pure $ do
        store <- storeResult failure opened
        active <- storeResult failure (mkRecordKey wallActiveRecordKey)
        fence <- storeResult failure (mkRecordKey wallFenceRecordKey)
        Right
            HostWallLocation
                { hostWallTarget = target
                , hostWallStore = store
                , hostWallActiveKey = active
                , hostWallFenceKey = fence
                }

storeResult :: (String -> fault) -> Either ProtectedError value -> Either fault value
storeResult failure = either (Left . failure . Text.unpack . protectedErrorMessage) Right

wallActiveRecordKey :: Text.Text
wallActiveRecordKey = "wall.hostbootstrap-global.active"

wallFenceRecordKey :: Text.Text
wallFenceRecordKey = "wall.hostbootstrap-global.fence"
