{-# LANGUAGE OverloadedStrings #-}

{- | The pure current-frame entry policy shared by the interpreter and tests.

The authority and store retain their real lower-unit identities. Main supplies
the actual cursor-origin comparison and descriptive cursor/topology projections;
this module imports no main cursor or plan representation and creates no authority.
-}
module HostBootstrap.Chain.EntryPolicy (validateCurrentFrameEntry) where

import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Authority.Kernel (
    CommandAuthority,
    ExecutePhase,
    VerbUp,
    commandAuthorityFrame,
    commandAuthorityMatchesStore,
 )
import HostBootstrap.Protected (ProtectedStore)

-- | Refuse mismatched evidence before the interpreter opens protected state.
validateCurrentFrameEntry ::
    CommandAuthority scope planId frame brokerGeneration VerbUp ExecutePhase ->
    ProtectedStore ->
    Bool ->
    Text ->
    NonEmpty Text ->
    Either String ()
validateCurrentFrameEntry authority store cursorOriginMatches cursorFrame frames
    | not (commandAuthorityMatchesStore authority store) =
        Left "project up: command authority does not belong to the supplied protected store"
    | not cursorOriginMatches =
        Left "project up: command authority and lifecycle cursor origins do not match"
    | current /= cursorFrame =
        Left
            ( "project up: command authority frame "
                ++ Text.unpack current
                ++ " does not match lifecycle cursor frame "
                ++ Text.unpack cursorFrame
            )
    | current `notElem` frames =
        Left
            ( "project up: current frame "
                ++ Text.unpack current
                ++ " is not a frame of the admitted plan (frames: "
                ++ intercalate ", " (map Text.unpack (NonEmpty.toList frames))
                ++ ")"
            )
    | otherwise = Right ()
  where
    current = commandAuthorityFrame authority
