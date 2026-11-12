{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Shared failure-attributed assertions, identity fixtures and kernel probes.

Either assertions preserve the caller's source location through HasCallStack.
Numeric ownership fixtures reach the production identity encoder. The process
probe holds an actual platform-row handle until death, and the shared parent
proof brackets termination and reap rather than simulating a kernel lock.
-}
module Expect (
    expectRight,
    expectRightLabelled,
    expectOwned,
    expectOccupied,
    kernelIdentityWords,
    runOwnershipLockProbe,
    awaitOwnershipProbe,
    awaitOwnershipOpen,
    assertOwnershipReleaseOnDeath,
    expectProbeFailure,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (void)
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import HostBootstrap.Ownership.Object (ObjectIdentity, OwnershipFault (OwnershipOccupied, OwnershipProbeFailed), mkKernelObjectIdentity)
import HostBootstrap.Ownership.Primitive (OwnershipPrimitive (rowCloseHandle, rowCreateFile, rowOpenExclusive), OwnershipRow, withOwnershipRow)
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.FilePath ((</>))
import System.Process (spawnProcess, terminateProcess, waitForProcess)
import Test.Tasty.HUnit (assertFailure)

-- | The value, or a failure naming what came back instead.
expectRight :: (HasCallStack, Show failure) => Either failure value -> IO value
expectRight = either (assertFailure . show) pure

-- | The value, or a failure naming both the expectation and what came back.
expectRightLabelled :: (HasCallStack, Show failure) => String -> Either failure value -> IO value
expectRightLabelled label =
    either (\failure -> assertFailure (label <> ": " <> show failure)) pure

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

expectOccupied :: (HasCallStack, Show value) => String -> Either OwnershipFault value -> IO ()
expectOccupied label outcome = case outcome of
    Left (OwnershipOccupied _) -> pure ()
    Left fault -> assertFailure (label <> " must be occupied, got " <> show fault)
    Right value -> assertFailure (label <> " must be refused, got " <> show value)

-- | A numeric POSIX-shaped identity fixture, through the production encoder.
kernelIdentityWords :: Word64 -> Word64 -> Either OwnershipFault ObjectIdentity
kernelIdentityWords volume object =
    mkKernelObjectIdentity volume (LazyByteString.toStrict (Builder.toLazyByteString (Builder.word64LE object)))

-- | Hold a real row handle until process death; raw handles carry no finalizer.
runOwnershipLockProbe :: OwnershipRow -> FilePath -> FilePath -> IO ()
runOwnershipLockProbe row target readyPath = do
    opened <- withOwnershipRow row (\primitives -> fmap (fmap (const ())) (rowOpenExclusive primitives target))
    case opened of
        Left fault -> fail ("the probe could not hold the object: " <> show fault)
        Right () -> writeFile readyPath "held" >> blockForever
  where
    blockForever = threadDelay 60000000 >> blockForever

-- | Wait for the real child to report its acquired kernel handle.
awaitOwnershipProbe :: HasCallStack => FilePath -> IO ()
awaitOwnershipProbe path = go (600 :: Int)
  where
    go 0 = assertFailure ("the probe never reported holding " <> path)
    go remaining = do
        present <- doesFileExist path
        if present then pure () else threadDelay 50000 >> go (remaining - 1)

-- | Re-open after the holder is reaped, closing every successful acquisition.
awaitOwnershipOpen :: OwnershipRow -> FilePath -> IO (Either OwnershipFault ())
awaitOwnershipOpen row target = go (200 :: Int)
  where
    go remaining = do
        opened <-
            withOwnershipRow row $ \primitives -> do
                attempt <- rowOpenExclusive primitives target
                case attempt of
                    Left fault -> pure (Left fault)
                    Right handle -> rowCloseHandle primitives handle
        case opened of
            Right () -> pure (Right ())
            Left fault
                | remaining <= 0 -> pure (Left fault)
                | otherwise -> threadDelay 25000 >> go (remaining - 1)

-- | A failed probe has its own fault constructor.
expectProbeFailure :: (HasCallStack, Show value) => String -> Either OwnershipFault value -> IO ()
expectProbeFailure label outcome = case outcome of
    Left (OwnershipProbeFailed _ _) -> pure ()
    other -> assertFailure (label <> " must be a probe failure, got " <> show other)

-- | Prove kernel release by terminating and reaping a real handle-holding child.
assertOwnershipReleaseOnDeath :: HasCallStack => OwnershipRow -> String -> FilePath -> IO ()
assertOwnershipReleaseOnDeath row probeArgument root = do
    let file = root </> "file"
        readyPath = root </> "ready"
    withOwnershipRow row (\primitives -> rowCreateFile primitives file "payload") >>= expectOwned "create the file"
    self <- getExecutablePath
    bracket
        (spawnProcess self [probeArgument, file, readyPath])
        (\probe -> terminateProcess probe >> void (waitForProcess probe))
        (\_probe -> do
            awaitOwnershipProbe readyPath
            contended <- withOwnershipRow row (\primitives -> fmap (fmap (const ())) (rowOpenExclusive primitives file))
            expectOccupied "open against a live holder" contended
        )
    released <- awaitOwnershipOpen row file
    case released of
        Right () -> pure ()
        Left fault -> assertFailure ("the kernel did not release the child's handle: " <> show fault)
