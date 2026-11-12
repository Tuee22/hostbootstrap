-- | Bounded live-gate relay observations and cleanup, shared with the test component.
module HostBootstrap.CLI.Bare.Runtime (
    runtimeExposureAssertionWith,
    successfulLine,
    parseLoopbackMapping,
) where

import Control.Concurrent (forkFinally, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (bracket)
import Control.Monad (forM)
import System.Exit (ExitCode (..))

runtimeExposureAssertionWith :: ([String] -> IO (Either String (ExitCode, String, String))) -> (String -> IO ()) -> String -> IO (Either String ())
runtimeExposureAssertionWith runCommand refuse cluster = do
    imageResult <- runCommand ["inspect", "--format", "{{.Image}}", cluster <> "-control-plane"]
    case successfulLine "inspect live-gate node image" imageResult of
        Left refusal -> pure (Left refusal)
        Right image ->
            bracket
                (pure names)
                cleanupCreated
                ( \_ -> do
                    created <- createBoth image
                    case traverse (successfulLine "create live-gate relay") created of
                        Left refusal -> pure (Left refusal)
                        Right identities -> do
                            mappings <- traverse inspectMapping identities
                            pure $ do
                                ports <- sequence mappings
                                case ports of
                                    [first, second]
                                        | first /= second -> Right ()
                                        | otherwise -> Left "cluster-live: concurrent runtime allocations selected the same host port"
                                    _ -> Left "cluster-live: concurrent runtime allocation did not return two mappings"
                )
  where
    names = [cluster <> "-exposure-a", cluster <> "-exposure-b"]

    createBoth image = bracket startWorkers stopWorkers $ \workers ->
        traverse (fmap (either (Left . show) id) . readMVar . snd) workers
      where
        startWorkers = forM names $ \name -> do
            answer <- newEmptyMVar
            thread <- forkFinally
                ( runCommand
                    [ "container", "run", "--detach", "--name", name
                    , "--publish", "127.0.0.1::20000/tcp", "--entrypoint", "/bin/sleep"
                    , image, "infinity"
                    ]
                )
                (putMVar answer)
            pure (thread, answer)
        stopWorkers workers = do
            mapM_ (killThread . fst) workers
            mapM_ (readMVar . snd) workers

    inspectMapping identity = do
        inspected <-
            runCommand
                [ "inspect"
                , "--format"
                , "{{(index (index .NetworkSettings.Ports \"20000/tcp\") 0).HostIp}}:{{(index (index .NetworkSettings.Ports \"20000/tcp\") 0).HostPort}}"
                , identity
                ]
        pure $ do
            binding <- successfulLine "inspect live-gate relay mapping" inspected
            parseLoopbackMapping binding

    cleanupCreated relayNames = do
        _ <- traverse (\name -> runCommand ["container", "rm", "--force", name]) relayNames
        remaining <-
            traverse
                (\name -> runCommand ["container", "ls", "--all", "--quiet", "--filter", "name=^/" <> name <> "$"])
                names
        case traverse (successfulLine "verify live-gate relay absence") remaining of
            Right ["", ""] -> pure ()
            _ -> refuse "cluster-live: an exposure allocation container remains after cleanup"

parseLoopbackMapping :: String -> Either String String
parseLoopbackMapping binding = case break (== ':') binding of
    ("127.0.0.1", ':' : port)
        | not (null port) && all (`elem` ['0' .. '9']) port -> Right port
    _ -> Left ("cluster-live: runtime returned a non-loopback or malformed mapping: " <> binding)

successfulLine :: String -> Either String (ExitCode, String, String) -> Either String String
successfulLine operation outcome = case outcome of
    Left refusal -> Left ("cluster-live: " <> operation <> " failed: " <> refusal)
    Right (ExitFailure code, _, err) -> Left ("cluster-live: " <> operation <> " failed (exit " <> show code <> "): " <> err)
    Right (ExitSuccess, stdoutText, "") -> case lines stdoutText of
        [] | null stdoutText -> Right ""
        [line] | stdoutText == line <> "\n" -> Right line
        _ -> Left ("cluster-live: " <> operation <> " returned malformed output")
    Right (ExitSuccess, _, err) -> Left ("cluster-live: " <> operation <> " wrote stderr on success: " <> err)

