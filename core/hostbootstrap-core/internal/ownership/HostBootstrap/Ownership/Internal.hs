{-# LANGUAGE RoleAnnotations #-}

{- | The four clause tokens, and the only place their constructors exist.

@development_plan_standards.md § EE@ states the four ownership clauses as an
order: enter exclusively, record the origin before the object exists, bind the
created object's own identity to that record, and release only after
re-observing it. An order stated in prose is restated at every owner and drifts
at one of them. Stated in types it is checked once, by the compiler, at every
owner at once (§ HH).

So each clause mints a token, and the producer of each token demands its
predecessor. A mutation consumes the recorded origin and a release consumes the
bound identity, so performing either out of order is a program with no term
rather than a review comment.

Two indices ride on every token, both nominal:

  * @session@ is the /protected entry's own/ rank-2 variable, not a second brand
    beside it. A token therefore cannot outlive the entry that authorized it,
    and there are no two facts about the same entry that could disagree.
  * @object@ names which object the token is about, so evidence gathered for one
    owned object cannot be presented for another.

The target the token names rides on the token too. It is the owner's own
absolute path — the seam holds no pathname policy — and carrying it means the
clause producers take no path argument at all, so there is no call at which a
matching token and a different path could be presented together.

Neither index is coercible, and no token carries a producer here that a caller
outside this package could reach: this module is Cabal-private and its
importers are this phase's own facade and the seam that mints the tokens.
-}
module HostBootstrap.Ownership.Internal
    ( -- * Where an owned object lives
      OwnedTargetPath

      -- * The tokens
    , Entered (..)
    , Recorded (..)
    , Bound (..)
    , Releasable (..)

      -- * Their total eliminators
    , enteredEvidence
    , recordedEvidence
    , boundEvidence
    , releasableEvidence
    )
where

import HostBootstrap.Ownership.Object (ObjectIdentity, Origin, OriginRecord)

{- | Where an owned object lives, as its owner named it.

An absolute path the owner supplied, carried rather than derived: deriving one
would be a pathname policy, and a seam that has one is a seam that decides which
object an owner meant.
-}
type OwnedTargetPath = FilePath

{- | Clause 1 held: this object is exclusively entered under @session@, and this
is what was observed at it before anything was written.

The observation rides on the token rather than beside it because the whole point
of clause 1 is that nothing else could have changed the object between the look
and the record. An origin passed separately is an origin that might have been
observed before the entry.
-}
type role Entered nominal nominal
data Entered session object = Entered OwnedTargetPath Origin

{- | Clause 2 held: the origin record is durably published, and the object it
describes does not exist yet.

The record is unbound here by construction — 'bindOriginRecord' has not run —
which is what makes the crash window resolvable: a run that died between this
token and the next left a record saying what was there before and what it
intended to install.
-}
type role Recorded nominal nominal
data Recorded session object = Recorded OwnedTargetPath OriginRecord

{- | Clause 3 held: the object exists, its own kernel identity has been read, and
the durable record now names it.

Both the bound record and the identity ride on the token because release needs
the identity to compare against and the record to remove; taking either from
somewhere else would let a release compare against an identity this transaction
never bound.
-}
type role Bound nominal nominal
data Bound session object = Bound OwnedTargetPath OriginRecord ObjectIdentity

{- | Clause 4's precondition held: the object at the target has just been
re-observed and is the identity this transaction bound.

A token rather than a boolean, because the act it authorizes — removing the
object and its record — must not be reachable from a comparison someone else
made earlier.
-}
type role Releasable nominal nominal
data Releasable session object = Releasable OwnedTargetPath OriginRecord ObjectIdentity

{- | Disclose what clause 1 established.

Each eliminator is a continuation rather than a field selector, so a token that
gains a fact is a compile error at every reader rather than a reader that
silently keeps looking at the old ones.
-}
enteredEvidence :: (OwnedTargetPath -> Origin -> result) -> Entered session object -> result
enteredEvidence use (Entered target origin) = use target origin

-- | Disclose the durably published record clause 2 wrote.
recordedEvidence :: (OwnedTargetPath -> OriginRecord -> result) -> Recorded session object -> result
recordedEvidence use (Recorded target record) = use target record

-- | Disclose the bound record and the identity clause 3 bound to it.
boundEvidence ::
    (OwnedTargetPath -> OriginRecord -> ObjectIdentity -> result) -> Bound session object -> result
boundEvidence use (Bound target record identity) = use target record identity

-- | Disclose the record to remove and the identity that was just re-observed.
releasableEvidence ::
    (OwnedTargetPath -> OriginRecord -> ObjectIdentity -> result) -> Releasable session object -> result
releasableEvidence use (Releasable target record identity) = use target record identity
