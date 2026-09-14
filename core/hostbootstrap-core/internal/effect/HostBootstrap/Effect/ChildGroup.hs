{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Ending a child process group, and the grace it is given to end itself.

Two lifecycle transports launch a child into its own process group and later
have to end it: the authenticated process handoff and the durable transaction
that carries one. They had byte-identical copies of this — the same two signals,
the same poll loop, and the same three timeout constants — differing only in
their doc comments. Timeouts that agree by coincidence rather than by
construction are the shape that drifts silently: one copy could have been tuned
and nothing would have said so.

The escalation is deliberate and ordered. A group is first /asked/ to stop, then
given a bounded grace, then ended with something it cannot decline. Every step
tolerates the group having already gone, because a child that exited on its own
is the success case, not an error to report.
-}
module HostBootstrap.Effect.ChildGroup (
    askChildGroupToStop,
    killChildGroup,
    awaitChildExit,
    closeQuietly,
    launchMicros,
    terminationGraceMicros,
    pollMicros,
)
where

import Control.Concurrent (threadDelay)
import qualified Control.Exception as Exception
import System.Exit (ExitCode)
import System.IO (Handle, hClose)
#if defined(mingw32_HOST_OS)
import System.Process (ProcessHandle, getProcessExitCode, terminateProcess)
#else
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcessGroup)
import System.Process (ProcessHandle, getPid, getProcessExitCode)
#endif

{- | Ask the child's own group to stop, or accept that there is no longer one.

The two rows differ only in which primitive names a group. A POSIX host signals
the process group the child was launched into; a Windows host terminates the
child the same launch created. Neither reaches beyond the child's group, because
the launch put the child in its own.
-}
askChildGroupToStop :: ProcessHandle -> IO ()
#if defined(mingw32_HOST_OS)
askChildGroupToStop child = quietly (terminateProcess child)
#else
askChildGroupToStop child = signalChildGroup child sigTERM
#endif

-- | End the child's group with something it cannot decline.
killChildGroup :: ProcessHandle -> IO ()
#if defined(mingw32_HOST_OS)
killChildGroup child = quietly (terminateProcess child)
#else
killChildGroup child = signalChildGroup child sigKILL
#endif

#if !defined(mingw32_HOST_OS)
-- | Signal the child's own group, or accept that there is no longer one.
signalChildGroup :: ProcessHandle -> Signal -> IO ()
signalChildGroup child signal = do
    identity <- getPid child
    case identity of
        Nothing -> pure ()
        Just pid -> do
            signalled <-
                Exception.try (signalProcessGroup signal (fromIntegral pid))
            either (\(_ :: Exception.IOException) -> pure ()) pure signalled
#endif

#if defined(mingw32_HOST_OS)
quietly :: IO () -> IO ()
quietly action = do
    attempted <- Exception.try action
    either (\(_ :: Exception.IOException) -> pure ()) pure attempted
#endif

-- | Poll for the child's exit until the grace runs out.
awaitChildExit :: Int -> ProcessHandle -> IO (Maybe ExitCode)
awaitChildExit remaining child
    | remaining <= 0 = getProcessExitCode child
    | otherwise = do
        exited <- getProcessExitCode child
        case exited of
            Just status -> pure (Just status)
            Nothing -> do
                threadDelay pollMicros
                awaitChildExit (remaining - pollMicros) child

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
