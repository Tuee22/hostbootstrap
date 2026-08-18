module HostBootstrap.Ensure.Colima.Backend.Runner
  ( BackendNamespace (..),
    validNamespace,
    BoundedProcessResult (..),
    runBoundedPython,
    BoundedToolResult (..),
    runBoundedTool,
  )
where

import HostBootstrap.Effect.Run
  ( BoundedRun (..),
    CapturedRun (capturedExit, capturedStderr, capturedStdout),
    RunBounds (..),
    RunNamespace (..),
    runBoundedGrouped,
  )
import HostBootstrap.Ensure.Colima.Backend.Program.Supervisor (commandSupervisorProgram)
import System.Exit (ExitCode)
import System.FilePath (isAbsolute, splitSearchPath)

data BackendNamespace = BackendNamespace
  { namespaceHomeDirectory :: FilePath,
    namespaceColimaHome :: FilePath,
    namespaceLimaHome :: FilePath,
    namespaceColimaCacheHome :: FilePath,
    namespaceTemporaryDirectory :: FilePath,
    namespaceDockerConfig :: FilePath,
    namespaceWorkingDirectory :: FilePath,
    namespaceExecutablePath :: String
  }
  deriving (Eq, Show)

validNamespace :: BackendNamespace -> Bool
validNamespace namespace =
  all validAbsolute
    [ namespaceHomeDirectory namespace,
      namespaceColimaHome namespace,
      namespaceLimaHome namespace,
      namespaceColimaCacheHome namespace,
      namespaceTemporaryDirectory namespace,
      namespaceDockerConfig namespace,
      namespaceWorkingDirectory namespace
    ]
    && not (null executableDirectories)
    && all validAbsolute executableDirectories
  where
    executableDirectories = splitSearchPath (namespaceExecutablePath namespace)
    validAbsolute path = isAbsolute path && not (null path) && not (any (== '\0') path)

data BoundedProcessResult
  = BoundedProcessCompleted ExitCode String String
  | BoundedProcessTimedOut
  | BoundedProcessOutputLimit
  | BoundedProcessException String

data BoundedToolResult
  = BoundedToolCompleted ExitCode String String
  | BoundedToolTimedOut
  | BoundedToolFailed String
  deriving (Eq, Show)

runBoundedTool :: Int -> BackendNamespace -> FilePath -> FilePath -> [String] -> IO BoundedToolResult
runBoundedTool timeoutSeconds namespace supervisorPython executable args
  | timeoutSeconds <= 0 || timeoutSeconds > 900 = pure (BoundedToolFailed "invalid-timeout")
  | not (validNamespace namespace) = pure (BoundedToolFailed "invalid-namespace")
  | not (isAbsolute supervisorPython) || not (isAbsolute executable) = pure (BoundedToolFailed "non-absolute-executable")
  | otherwise = do
      outcome <-
        runBoundedGrouped
          (colimaBounds (timeoutSeconds * 1000 * 1000))
          (colimaNamespace namespace)
          supervisorPython
          (["-I", "-S", "-c", commandSupervisorProgram, executable] ++ args)
      pure $ case outcome of
        BoundedFailed err -> BoundedToolFailed err
        BoundedTimedOut -> BoundedToolTimedOut
        BoundedOutputLimit -> BoundedToolFailed "output-limit"
        BoundedCompleted run ->
          BoundedToolCompleted (capturedExit run) (capturedStdout run) (capturedStderr run)

runBoundedPython :: Int -> BackendNamespace -> FilePath -> [String] -> IO BoundedProcessResult
runBoundedPython commandTimeoutSeconds namespace executable args = do
  outcome <-
    runBoundedGrouped
      (colimaBounds (backendTimeoutMicros commandTimeoutSeconds))
      (colimaNamespace namespace)
      executable
      args
  pure $ case outcome of
    BoundedFailed err -> BoundedProcessException err
    BoundedTimedOut -> BoundedProcessTimedOut
    BoundedOutputLimit -> BoundedProcessOutputLimit
    BoundedCompleted run ->
      BoundedProcessCompleted (capturedExit run) (capturedStdout run) (capturedStderr run)

-- | Colima's row of the bounded-run table: a five-times command budget with a
-- thirty second floor, a 16 MiB transcript ceiling, and six seconds of grace
-- before the group is killed. The numbers are Colima's; the runner is not.
colimaBounds :: Int -> RunBounds
colimaBounds wallMicros =
  RunBounds
    { boundWallMicros = wallMicros,
      boundOutputBytes = 16 * 1024 * 1024,
      boundTerminationGraceMicros = 6 * 1000 * 1000
    }

colimaNamespace :: BackendNamespace -> RunNamespace
colimaNamespace namespace =
  RunNamespace
    { runWorkingDirectory = namespaceWorkingDirectory namespace,
      runEnvironment = closedEnvironment namespace
    }

closedEnvironment :: BackendNamespace -> [(String, String)]
closedEnvironment namespace =
  [ ("HOME", namespaceHomeDirectory namespace),
    ("COLIMA_HOME", namespaceColimaHome namespace),
    ("LIMA_HOME", namespaceLimaHome namespace),
    ("COLIMA_CACHE_HOME", namespaceColimaCacheHome namespace),
    ("TMPDIR", namespaceTemporaryDirectory namespace),
    ("DOCKER_CONFIG", namespaceDockerConfig namespace),
    ("PATH", namespaceExecutablePath namespace),
    ("LANG", "C"),
    ("LC_ALL", "C")
  ]

backendTimeoutMicros :: Int -> Int
backendTimeoutMicros commandTimeoutSeconds =
  (5 * commandTimeoutSeconds + 30) * 1000 * 1000
