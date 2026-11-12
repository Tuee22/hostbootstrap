{-# LANGUAGE RankNTypes #-}
module EscapeOwnedObjectIndex where
import HostBootstrap.Ownership.Clause (Entered)
import HostBootstrap.Ownership.Object (OwnershipFault)
import HostBootstrap.Ownership.Primitive (OwnershipRow, enterOwnedObject)
import HostBootstrap.Protected (ProtectedSession)
escapes :: OwnershipRow -> ProtectedSession session -> FilePath -> IO (Either OwnershipFault (Entered session escaped))
escapes row session target = enterOwnedObject row session target (\entered -> pure (Right entered))
