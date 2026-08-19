{- | The closed frame table's shared computations (§ LL).

A provider does not own a workflow. It owns a __frame__: a way to reach a
context, plus the small closed table of facts that context differs by. A
behaviour true of every frame is written once here and instantiated from that
table; a provider module carries only what is true of its own frame.

The guarded destructive delete is the clearest case. Three providers each had
one, and the three differed in exactly the places nobody compares: the noun in
the refusal, whether the verb was @delete@ or @unregister@, and — the part that
matters — that each independently admitted an empty guard prefix, under which
@isPrefixOf@ is true of every name and the guard removes whatever it is pointed
at. Each copy passed its own test, because each test only asked whether a
differently-prefixed name refused.
-}
module HostBootstrap.Substrate.Frame (
    FrameNoun (..),
    allFrameNouns,
    renderFrameNoun,
    guardedDeleteArgs,

    -- * Which row holds a frame's ownership clauses
    FrameOwnershipRow (..),
    frameOwnershipRow,
    frameOwnsLocally,
)
where

import Data.List (isPrefixOf)
import HostBootstrap.Effect.Vocabulary (EffectFrame (CrossedInto, OuterHost))

{- | What a frame's own vocabulary calls the thing a destructive delete removes.

A row's datum rather than a code path: the refusal reads in the operator's own
terms without the computation being written again to say so.
-}
data FrameNoun
    = LimaInstance
    | IncusInstance
    | Wsl2Distribution
    deriving (Eq, Ord, Show, Enum, Bounded)

-- | Every noun, so a table over them is total.
allFrameNouns :: [FrameNoun]
allFrameNouns = [minBound .. maxBound]

renderFrameNoun :: FrameNoun -> String
renderFrameNoun LimaInstance = "Lima VM"
renderFrameNoun IncusInstance = "incus VM"
renderFrameNoun Wsl2Distribution = "WSL2 distro"

{- | The one guarded destructive delete.

The guard is that the name carries the project's own prefix, so a lifecycle
cannot remove a frame it did not create. Two degenerate inputs refuse before the
prefix is even compared, because both make the guard vacuous rather than strict:
an empty prefix is a prefix of every name, and an empty name is a frame the
argument vector could not have addressed anyway.

The row supplies only its own argv, and receives the name after the guard has
admitted it — so a provider module cannot render a delete for a name the guard
would have refused.
-}
guardedDeleteArgs ::
    -- | what this frame calls the thing being removed
    FrameNoun ->
    -- | the project's guard prefix
    String ->
    -- | the frame's own name for it
    String ->
    -- | the row's argument vector, given an admitted name
    (String -> [String]) ->
    Either String [String]
guardedDeleteArgs noun prefix name argv
    | null prefix =
        Left
            ( "refusing to delete "
                ++ renderFrameNoun noun
                ++ " under an empty guard prefix, which admits every name: "
                ++ name
            )
    | null name =
        Left
            ( "refusing to delete "
                ++ renderFrameNoun noun
                ++ " with no name under the guard prefix '"
                ++ prefix
                ++ "'"
            )
    | prefix `isPrefixOf` name = Right (argv name)
    | otherwise =
        Left
            ( "refusing to delete "
                ++ renderFrameNoun noun
                ++ " not carrying the guard prefix '"
                ++ prefix
                ++ "': "
                ++ name
            )

-- ---------------------------------------------------------------------------
-- The ownership-primitive column

{- | Which of the ownership rows holds a frame's four clauses (§ EE, § LL).

The table's other columns say which tool reaches a frame and which grammar its
paths obey (§ MM); this one says whose kernel answers when an object at that
frame is owned. It is a /declaration/ rather than a value a caller runs: a
crossed frame's row is held by a process at that frame, which is what makes the
shipped transaction a transport rather than a third implementation of the
clauses.
-}
data FrameOwnershipRow
    = -- | the row this binary was built for, run in this process
      HostOwnershipRow
    | -- | the POSIX row, run by a process at the frame that owns the object
      PosixOwnershipRow
    deriving (Eq, Ord, Show, Enum, Bounded)

{- | The column, total over the closed frame axis.

Every frame this project reaches through a host-provider command is Linux, so
there is exactly one answer for every crossing and no per-provider entry to fall
out of step. The outer host is the only frame whose row is a build fact about
/this/ binary.
-}
frameOwnershipRow :: EffectFrame -> FrameOwnershipRow
frameOwnershipRow OuterHost = HostOwnershipRow
frameOwnershipRow CrossedInto{} = PosixOwnershipRow

{- | Whether this process's own row is the one that holds the frame's clauses.

Derived from the column rather than from a second test of the frame, so a
caller deciding whether to run a transaction here or ship it asks the same
value the table answers.
-}
frameOwnsLocally :: EffectFrame -> Bool
frameOwnsLocally frame = frameOwnershipRow frame == HostOwnershipRow
