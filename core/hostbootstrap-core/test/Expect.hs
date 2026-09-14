{-# LANGUAGE ScopedTypeVariables #-}

{- | Unwrapping an 'Either' in a test, once.

Seventeen spec modules each defined their own @expectRight@, in nine signature
shapes that differed only in what they called the type variables and whether
they took a label. They agreed about the interesting part and disagreed about
the rest: one used 'fail' rather than 'assertFailure', so its failures arrived as
an exception with no test attribution, and two fixed the failure type to one
concrete fault so they could not be used anywhere else.

'HasCallStack' is the reason to have one of these at all. Without it a failure
points at the helper; with it, it points at the assertion that failed.
-}
module Expect (
    expectRight,
    expectRightLabelled,
    expectLeft,
    expectOwned,
    expectOccupied,
)
where

import GHC.Stack (HasCallStack)
import Test.Tasty.HUnit (assertFailure)

-- | The value, or a failure naming what came back instead.

-- | The value, or a failure naming what came back instead.
expectRight :: (HasCallStack, Show failure) => Either failure value -> IO value
expectRight = either (assertFailure . show) pure

-- | The value, or a failure naming both the expectation and what came back.
expectRightLabelled :: (HasCallStack, Show failure) => String -> Either failure value -> IO value
expectRightLabelled label =
    either (\failure -> assertFailure (label <> ": " <> show failure)) pure

-- | The failure, or a failure naming the value that was not supposed to arrive.
expectLeft :: (HasCallStack, Show value) => String -> Either failure value -> IO failure
expectLeft label =
    either pure (\value -> assertFailure (label <> ": expected a refusal, got " <> show value))

{- | The two halves of an ownership-row clause, shared by both platform rows.

The POSIX and Windows row suites carried byte-identical copies of these, which
is how the two rows drifted to eighteen clauses and eleven without anything
noticing: a suite that is copied rather than shared has no place to state what
both rows must answer. The messages are preserved exactly, because they are what
a failing row prints.
-}
expectOwned :: (HasCallStack, Show failure) => String -> Either failure value -> IO ()
expectOwned label outcome = case outcome of
    Right _ -> pure ()
    Left fault -> assertFailure ("could not " <> label <> ": " <> show fault)

expectOccupied :: (HasCallStack, Show value) => String -> Either failure value -> IO ()
expectOccupied label outcome = case outcome of
    Left _ -> pure ()
    Right value -> assertFailure (label <> " must be refused, got " <> show value)
