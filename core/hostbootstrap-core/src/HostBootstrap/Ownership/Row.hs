{-# LANGUAGE CPP #-}

{- | Which ownership row this host runs.

Two rows exist and no more. @development_plan_standards.md § LL@ makes a
platform a row of one frame table rather than a module of parallel logic, and
the four clauses are written once above them
("HostBootstrap.Ownership.Primitive"); a third row would be a third place a
clause is implemented, which is the shape the seam exists to prevent.

The selection is a build fact rather than a runtime probe. Which kernel this
binary was compiled against decides which primitives exist at all — a POSIX
@lstat@ and an @fcntl@ lock, or @GetFileInformationByHandle@ and @LockFileEx@ —
so asking the running host would be asking a question the compiler has already
answered, and answering it twice is how the two answers come to disagree.

Both rows are compiled on every host family and the one that cannot apply
answers a total refusal (§ JJ), so this module selects between two values that
both exist everywhere. A caller therefore always holds a row; what differs is
what that row says when it is asked to hold a clause.
-}
module HostBootstrap.Ownership.Row
    ( ownershipRowForHost
    , hostOwnershipSupported
    )
where

import HostBootstrap.Ownership.Primitive
    ( OwnershipCapabilities (holdsStableIdentity)
    , OwnershipRow
    , rowCapabilities
    , withOwnershipRow
    )
#if defined(mingw32_HOST_OS)
import HostBootstrap.Ownership.Windows (windowsOwnershipRow)
#else
import HostBootstrap.Ownership.Posix (posixOwnershipRow)
#endif

{- | The row for the kernel this binary was built for.

Total, and the only production selector: an owner reaches a row through this and
never by naming a platform module, so there is exactly one place that decides
which kernel holds a clause.
-}
ownershipRowForHost :: OwnershipRow
#if defined(mingw32_HOST_OS)
ownershipRowForHost = windowsOwnershipRow
#else
ownershipRowForHost = posixOwnershipRow
#endif

{- | Whether the row this host runs can hold the clauses at all.

Derived from the row's own declaration rather than from a second host test, so
a caller that needs to know whether a case will exercise a kernel or record a
refusal asks the same value 'clauseRefusal' asks (§ NN).
-}
hostOwnershipSupported :: Bool
hostOwnershipSupported =
    withOwnershipRow ownershipRowForHost (holdsStableIdentity . rowCapabilities)
