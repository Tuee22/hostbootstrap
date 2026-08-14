module HostBootstrap.Ensure.Colima.Backend.Resolver.Override
  ( ResolverOverride (..),
    withResolverOverride,
    currentResolverOverride,
  )
where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (finally, mask)
import Data.Word (Word64)
import HostBootstrap.Ensure.Colima.Backend.Runner (BoundedToolResult)
import System.IO.Unsafe (unsafePerformIO)

-- This request contains only fixture execution data.  The real resolver
-- facade still parses, validates, and settles every fresh execution before it
-- can construct an opaque trusted toolchain.
data ResolverOverride = ResolverOverride
  { resolverOverrideRoot :: !FilePath,
    resolverOverrideHome :: !FilePath,
    resolverOverrideBootstrapDevice :: !Word64,
    resolverOverrideBootstrapInode :: !Word64,
    resolverOverrideExecution :: IO BoundedToolResult
  }

{-# NOINLINE resolverOverrides #-}
resolverOverrides :: MVar [(ThreadId, ResolverOverride)]
resolverOverrides = unsafePerformIO (newMVar [])

withResolverOverride :: ResolverOverride -> IO a -> IO (Either String a)
withResolverOverride override action =
  mask $ \restore -> do
    thread <- myThreadId
    installed <-
      modifyMVar resolverOverrides $ \entries ->
        if any ((== thread) . fst) entries
          then pure (entries, False)
          else pure ((thread, override) : entries, True)
    if not installed
      then pure (Left "resolver-override-nested")
      else
        (Right <$> restore action)
          `finally` modifyMVar_ resolverOverrides (pure . filter ((/= thread) . fst))

currentResolverOverride :: IO (Maybe ResolverOverride)
currentResolverOverride = do
  thread <- myThreadId
  lookup thread <$> readMVar resolverOverrides
