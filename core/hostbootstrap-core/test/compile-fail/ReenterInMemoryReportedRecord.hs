{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ReenterInMemoryReportedRecord where

import HostBootstrap.Ownership.Object (ObjectIdentity, ObjectKind (ReportedObject), Origin (OriginAbsent), OwnershipFault, bindOriginRecord, mkOwnerClaim, originRecord)
import HostBootstrap.Ownership.Primitive (StoredOriginRecord, reenterStoredReportedObject)
import HostBootstrap.Protected (ProtectedSession)

reenter :: ProtectedSession session -> ObjectIdentity -> IO (Either OwnershipFault ())
reenter session identity =
    case bindOriginRecord identity (originRecord (ReportedObject (mkOwnerClaim "owner")) OriginAbsent) of
        Left fault -> pure (Left fault)
        Right inMemory -> reenterStoredReportedObject session "/in-memory-reported" inMemory (\_ -> pure (Right ()))
