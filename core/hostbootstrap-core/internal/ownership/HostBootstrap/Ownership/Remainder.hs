{-# LANGUAGE OverloadedStrings #-}

-- | Release retained descendants without inventing an origin for each one.
-- The directory's bound token retains the live entry and root authority; the
-- manifest entry retains the descendant's exact raw name, kind and identity.
module HostBootstrap.Ownership.Remainder (releaseManifestRemainder) where

import HostBootstrap.Ownership.Clause (Bound, releasableEvidence)
import HostBootstrap.Ownership.Manifest (OwnershipManifestEntry)
import HostBootstrap.Ownership.Object (
    ObjectKind (OwnedDirectory),
    Origin (OriginAbsent),
    OwnershipFault (OwnershipMalformed),
    originRecordKind,
    originRecordOrigin,
 )
import HostBootstrap.Ownership.Posix (posixReleaseManifestEntry)
import HostBootstrap.Ownership.Primitive (
    OwnershipClause (ClauseRecord, ClauseRelease),
    clauseRefusal,
    reobserveOwnedIdentity,
    rowCapabilities,
    withOwnershipRow,
 )
import HostBootstrap.Ownership.Row (ownershipRowForHost)

-- | Absence is success only below the same, still-live owned directory.
-- Both capability checks precede even the root re-observation. Its producer
-- also verifies the bound token's actual entry and owner thread before IO.
releaseManifestRemainder :: Bound session object -> OwnershipManifestEntry -> IO (Either OwnershipFault ())
releaseManifestRemainder parent entry =
    withOwnershipRow ownershipRowForHost $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseRelease of
            Just refusal -> pure (Left refusal)
            Nothing -> case clauseRefusal (rowCapabilities primitives) ClauseRecord of
                Just refusal -> pure (Left refusal)
                Nothing -> do
                    observed <- reobserveOwnedIdentity ownershipRowForHost parent
                    case observed of
                        Left fault -> pure (Left fault)
                        Right live ->
                            releasableEvidence
                                (\root record identity ->
                                    if originRecordKind record == OwnedDirectory
                                        && originRecordOrigin record == OriginAbsent
                                        then posixReleaseManifestEntry root identity entry
                                        else pure (Left (OwnershipMalformed "manifest release requires a directory created by this owner")))
                                live
