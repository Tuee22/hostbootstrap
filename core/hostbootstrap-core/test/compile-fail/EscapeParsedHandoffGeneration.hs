{-# LANGUAGE RankNTypes #-}

module EscapeParsedHandoffGeneration where

import Data.ByteString (ByteString)
import HostBootstrap.Handoff

data CallerChosenGeneration

-- Parsing may fix scope only from opaque scope evidence. The generation read
-- from descriptive bytes remains local to the continuation and cannot be
-- relabelled as a caller-selected authority generation.
chooseParsedGeneration ::
    HandoffScope scope ->
    ByteString ->
    Either HandoffError (HandoffBinding scope CallerChosenGeneration)
chooseParsedGeneration scope raw =
    withHandoffBindingFromWire scope raw (\binding -> binding)
