{- | Record which branch of a conditional harness case completed successfully.

Completion means the supplied action returned without an exception. This records
execution and branch selection; the action's assertions establish what it proves.
-}
module ConditionalCase (
    conditionalCase,
    conditionalAction,
    readConditionalCompletions,
    resetConditionalCompletions,
) where

import Control.Exception (mask)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import System.IO.Unsafe (unsafePerformIO)
import Test.Tasty (TestName, TestTree)
import Test.Tasty.HUnit (testCase)

{-# NOINLINE completions #-}
completions :: IORef (Map [TestName] (Int, Int))
completions = unsafePerformIO (newIORef Map.empty)

conditionalCase :: [TestName] -> Bool -> TestName -> IO () -> IO () -> TestTree
conditionalCase family holds name row refusal =
    testCase name (conditionalAction family holds row refusal)

conditionalAction :: [TestName] -> Bool -> IO () -> IO () -> IO ()
conditionalAction family holds row refusal = mask $ \restore -> do
    restore (if holds then row else refusal)
    let increment = if holds then (1, 0) else (0, 1)
        add (rows, refusals) (otherRows, otherRefusals) =
            (rows + otherRows, refusals + otherRefusals)
    atomicModifyIORef' completions $ \observed ->
        (Map.insertWith add family increment observed, ())

readConditionalCompletions :: IO (Map [TestName] (Int, Int))
readConditionalCompletions = readIORef completions

resetConditionalCompletions :: IO ()
resetConditionalCompletions = writeIORef completions Map.empty
