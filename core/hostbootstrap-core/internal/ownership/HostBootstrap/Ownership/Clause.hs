{- | The four ownership clauses, as four abstract tokens.

This is the public face of @development_plan_standards.md § EE@'s ordering
theorem. A caller can hold a clause token, read what it discloses, and pass it to
the producer of the next clause — and can do nothing else with it, because the
constructors are not here and are not reachable from outside this package.

The order is therefore not a rule an owner follows. It is the only shape its
program can have: 'Recorded' is produced from 'Entered', 'Bound' from 'Recorded',
and 'Releasable' from 'Bound', so a mutation before the origin record and a
release without the identity binding are terms that do not exist.

Both indices are nominal. @session@ is the protected entry's own rank-2
variable, so a token cannot outlive the entry that authorized it and no second
brand can disagree with it; @object@ names which object the evidence is about,
so evidence gathered for one owned object cannot be presented for another.

The producers live with the seam that reaches a kernel
("HostBootstrap.Ownership.Primitive"), because a token is minted by a clause
actually being held rather than by a caller deciding it has been.
-}
module HostBootstrap.Ownership.Clause
    ( -- * Where an owned object lives
      OwnedTargetPath

      -- * The tokens
    , Entered
    , Recorded
    , Bound
    , Releasable

      -- * Their total eliminators
    , enteredEvidence
    , recordedEvidence
    , boundEvidence
    , releasableEvidence
    )
where

import HostBootstrap.Ownership.Internal
    ( Bound
    , Entered
    , OwnedTargetPath
    , Recorded
    , Releasable
    , boundEvidence
    , enteredEvidence
    , recordedEvidence
    , releasableEvidence
    )
