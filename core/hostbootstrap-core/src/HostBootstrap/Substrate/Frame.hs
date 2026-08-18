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
)
where

import Data.List (isPrefixOf)

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
