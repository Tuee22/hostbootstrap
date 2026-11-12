{-# LANGUAGE CPP #-}
{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | One acquired child group and its bounded termination grace.

The two lifecycle transports retain their own leader wait and pipe cleanup.
This owner retains the Windows job or POSIX process-group identity independently
of the leader, so polling or reaping that leader cannot discard the group while
descendants are still alive. Both rows keep their native termination primitives.
-}
module HostBootstrap.Effect.ChildGroup (
    ChildGroup,
    withChildGroupProcess,
    askChildGroupToStop,
    killChildGroup,
    awaitChildGroupExit,
    closeQuietly,
    launchMicros,
    terminationGraceMicros,
    pollMicros,
)
where

import Control.Concurrent (threadDelay)
import qualified Control.Exception as Exception
import Data.Maybe (isJust)
import System.IO (Handle, hClose)
import System.Process (CreateProcess, ProcessHandle, getProcessExitCode, withCreateProcess)
#if defined(mingw32_HOST_OS)
import Control.Monad (void)
import Data.Word (Word32)
import Foreign.C.Types (CInt (CInt), CULong)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peekByteOff)
import GHC.Windows (failIfFalse_)
import System.Process (use_process_jobs)
import System.Process.Internals (PHANDLE, ProcessHandle__ (OpenExtHandle, OpenHandle), closePHANDLE, modifyProcessHandle, terminateJobUnsafe)
#else
import System.IO.Error (isDoesNotExistError)
import System.Posix.Signals (Signal, nullSignal, sigKILL, sigTERM, signalProcessGroup)
import System.Posix.Types (ProcessGroupID)
import System.Process (create_group, getPid)
#endif

-- The raw Windows handles are the exact two fields transferred from OpenExtHandle.
-- The process handle still owns the leader; this bracket alone closes the job.
data ChildGroup = ChildGroup ProcessHandle
#if defined(mingw32_HOST_OS)
    PHANDLE PHANDLE
#else
    ProcessGroupID
#endif

{- | Own the acquired group before restoring the caller's execution.

On Windows the process library creates and assigns a kill-on-close job before
resuming the child. Its native acquisition precedes this bracket. Once acquired,
we transfer that exact job out of the library's leader-polling state and retain
it until the outer finalizer, including when inner teardown itself throws.
On POSIX this owner creates a fresh group and captures its identity before
polling or restoring the caller. The outer finalizer retains a kill fallback.
-}
withChildGroupProcess ::
    CreateProcess ->
    (Maybe Handle -> Maybe Handle -> Maybe Handle -> ProcessHandle -> ChildGroup -> IO result) ->
    IO result
withChildGroupProcess process use = Exception.mask $ \restore ->
    withCreateProcess
#if defined(mingw32_HOST_OS)
        (process{use_process_jobs = True})
#else
        (process{create_group = True})
#endif
        $ \input output errors child ->
            Exception.bracket
                (captureChildGroup child)
                releaseChildGroup
                (\group -> restore (use input output errors child group))

captureChildGroup :: ProcessHandle -> IO ChildGroup
#if defined(mingw32_HOST_OS)
captureChildGroup child = modifyProcessHandle child $ \state -> case state of
    OpenExtHandle leader job -> pure (OpenHandle leader, ChildGroup child leader job)
    _ -> ioError (userError "the acquired child process has no Windows job")
#else
captureChildGroup child = do
    identity <- getPid child
    case identity of
        Nothing -> ioError (userError "the acquired child process has no process-group identity")
        Just pid -> pure (ChildGroup child (fromIntegral pid))
#endif

releaseChildGroup :: ChildGroup -> IO ()
#if defined(mingw32_HOST_OS)
releaseChildGroup group@(ChildGroup _ _ job) = Exception.mask_ $
    (killChildGroup group >> void (awaitChildGroupExit terminationGraceMicros group))
        `Exception.finally` closePHANDLE job
#else
releaseChildGroup group = Exception.mask_ $
    stop `Exception.finally` finishRemaining
  where
    stop = do
        askChildGroupToStop group
        ended <- awaitChildGroupExit terminationGraceMicros group
        if ended then pure () else killAndObserve
    finishRemaining = do
        present <- posixGroupPresent group
        if present then killAndObserve else pure ()
    killAndObserve = do
        killChildGroup group
        ended <- awaitChildGroupExit terminationGraceMicros group
        if ended
            then pure ()
            else ioError (userError "the captured child process group did not exit after termination")
#endif

{- | Stop the acquired group. Windows termination is hard, so its grace observes
completion rather than promising a graceful application shutdown.
-}
askChildGroupToStop :: ChildGroup -> IO ()
#if defined(mingw32_HOST_OS)
askChildGroupToStop = terminateWindowsGroup
#else
askChildGroupToStop group = signalChildGroup group sigTERM
#endif

-- | End the group with something it cannot decline.
killChildGroup :: ChildGroup -> IO ()
#if defined(mingw32_HOST_OS)
killChildGroup = terminateWindowsGroup
#else
killChildGroup group = signalChildGroup group sigKILL
#endif

#if defined(mingw32_HOST_OS)
terminateWindowsGroup :: ChildGroup -> IO ()
terminateWindowsGroup (ChildGroup _ leader job) =
    failIfFalse_ "TerminateJobObject" (terminateJobUnsafe (OpenExtHandle leader job) 1)

-- Four LARGE_INTEGER fields followed by four DWORD fields: 48 bytes, with
-- ActiveProcesses at offset 40. This accounting structure has no pointer fields.
windowsGroupEmpty :: PHANDLE -> IO Bool
windowsGroupEmpty job = allocaBytes 48 $ \accounting -> do
    failIfFalse_
        "QueryInformationJobObject"
        (queryInformationJobObject job 1 accounting 48 nullPtr)
    active <- peekByteOff accounting 40 :: IO Word32
    pure (active == 0)

foreign import capi unsafe "windows.h QueryInformationJobObject"
    queryInformationJobObject :: PHANDLE -> CInt -> Ptr () -> Word32 -> Ptr CULong -> IO Bool
#else
-- | Signal only the retained group; only an absent group is already complete.
signalChildGroup :: ChildGroup -> Signal -> IO ()
signalChildGroup (ChildGroup _ processGroup) signal = do
    signalled <- Exception.try (signalProcessGroup signal processGroup) :: IO (Either Exception.IOException ())
    case signalled of
        Right () -> pure ()
        Left failure | isDoesNotExistError failure -> pure ()
        Left failure -> Exception.throwIO failure

posixGroupPresent :: ChildGroup -> IO Bool
posixGroupPresent (ChildGroup _ processGroup) = do
    observed <- Exception.try (signalProcessGroup nullSignal processGroup) :: IO (Either Exception.IOException ())
    case observed of
        Right () -> pure True
        Left failure | isDoesNotExistError failure -> pure False
        Left failure -> Exception.throwIO failure
#endif

-- | Poll both leader completion and native group absence within the budget.
awaitChildGroupExit :: Int -> ChildGroup -> IO Bool
awaitChildGroupExit remaining group = do
    ended <- childGroupEnded group
    if ended || remaining <= 0
        then pure ended
        else do
            threadDelay pollMicros
            awaitChildGroupExit (remaining - pollMicros) group

childGroupEnded :: ChildGroup -> IO Bool
#if defined(mingw32_HOST_OS)
childGroupEnded (ChildGroup child _ job) = do
    ended <- isJust <$> getProcessExitCode child
    empty <- windowsGroupEmpty job
    pure (ended && empty)
#else
childGroupEnded group@(ChildGroup child _) = do
    ended <- isJust <$> getProcessExitCode child
    present <- posixGroupPresent group
    pure (ended && not present)
#endif

closeQuietly :: Handle -> IO ()
closeQuietly handle = do
    closed <- Exception.try (hClose handle)
    either (\(_ :: Exception.IOException) -> pure ()) pure closed

-- | How long a child has to exist at all.
launchMicros :: Int
launchMicros = 30 * 1000000

-- | How long a signalled group has to finish before it is killed.
terminationGraceMicros :: Int
terminationGraceMicros = 10 * 1000000

-- | How often the grace is checked.
pollMicros :: Int
pollMicros = 50 * 1000
