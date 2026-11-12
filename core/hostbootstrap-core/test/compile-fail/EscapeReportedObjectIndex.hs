{-# LANGUAGE RankNTypes #-}
module EscapeReportedObjectIndex where
import HostBootstrap.Ownership.Clause (Entered)
import HostBootstrap.Ownership.Object (OwnershipFault, Origin (OriginAbsent))
import HostBootstrap.Ownership.Primitive (enterReportedObject)
import HostBootstrap.Protected (ProtectedSession)
escapes :: ProtectedSession session -> FilePath -> IO (Either OwnershipFault (Entered session escaped))
escapes session target = enterReportedObject session target OriginAbsent (\entered -> pure (Right entered))
