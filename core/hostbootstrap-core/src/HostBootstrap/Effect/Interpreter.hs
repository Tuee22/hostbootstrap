{-# LANGUAGE CPP #-}

{- | The one interpreter for the closed effect vocabulary.

§ KK admits one vocabulary and one interpreter, and puts the interpreter in the
library beside the vocabulary rather than in a consumer. An interpreter that
lives in a consumer cannot be reused by a second consumer, so the second one
writes its own — and then two answers exist to "what does this effect do", each
tested only against itself.

The split this module holds is the one § KK asks for. 'resolveLaunch' is pure:
it turns a described command into the executable and argument vector the host
will actually launch, including the one reframing an outer host imposes, and it
can be tested without starting anything. Everything else is a thin seam over the
one process runner.

Two seams are genuinely the caller's and are taken as arguments rather than
guessed. The global WSL wall is acquired under a /project's/ ownership identity,
which the library does not know; and what a run prints is the caller's report,
not the library's. Both arrive in an 'EffectEnvironment'. What does /not/ arrive
that way is any decision about how a command is resolved, launched, or judged:
those are the interpreter's, once.
-}
module HostBootstrap.Effect.Interpreter (
    -- * Interpreting one described command
    resolveLaunch,
    interpretHostCommand,

    -- * Interpreting an effect list
    EffectEnvironment (..),
    EffectFailurePolicy (..),
    EffectFailure (..),
    renderEffectFailure,
    interpretHostEffects,
)
where

import Control.Monad (unless)
import Data.Bifunctor (bimap)
import HostBootstrap.Effect.Run (CapturedRun (..), renderRunFailure, runCaptured)
import HostBootstrap.Effect.Vocabulary (
    DirectHostAction (..),
    EffectStdio (effectStdin),
    EffectTarget (..),
    HostCommand (..),
    HostEffect (..),
 )
import HostBootstrap.HostConfig (HostConfig, resolveMaybe)
import HostBootstrap.HostTool (HostTool, absExePath, toolCommandName)
import System.Exit (ExitCode (..))
#ifdef mingw32_HOST_OS
import HostBootstrap.Effect.Quote (powerShellQuoteArg)
import HostBootstrap.HostTool (HostTool (PowerShell, Wsl))
#endif

{- | Turn a described command into the executable and argument vector the host
will launch, or a typed refusal naming the tool that is not resolved.

Pure, and total for a resolved configuration. It is the one place an outer host
may reframe an invocation: on Windows a WSL command is launched through
PowerShell, because @wsl.exe@ started directly from a non-console parent does not
reliably deliver its own exit status. The reframed command line is built with the
one PowerShell quoter, so an argument that contains a quote or a space reaches
the far side as the same argument.
-}
resolveLaunch :: HostConfig -> HostCommand -> Either String (FilePath, [String])
resolveLaunch cfg command = case commandTarget command of
    SelfTarget path -> Right (path, commandArguments command)
    ToolTarget tool -> resolveTool tool
  where
    arguments = commandArguments command

    resolveTool :: HostTool -> Either String (FilePath, [String])
#ifdef mingw32_HOST_OS
    resolveTool Wsl = do
        shell <- resolved PowerShell
        wsl <- resolved Wsl
        let line = unwords ("&" : map powerShellQuoteArg (wsl : arguments)) ++ "; exit $LASTEXITCODE"
        pure (shell, ["-NoProfile", "-Command", line])
#endif
    resolveTool tool = do
        exe <- resolved tool
        pure (exe, arguments)

    resolved tool =
        maybe
            (Left (toolCommandName tool ++ " not found on this host"))
            (Right . absExePath)
            (resolveMaybe cfg tool)

{- | Run one described command through the one process runner.

'Left' is a command that produced no child — an unresolved tool or a failed
exec. A child that ran and exited non-zero is 'Right' with that exit code,
because its own diagnostic is in the streams it wrote.
-}
interpretHostCommand :: HostConfig -> HostCommand -> IO (Either String CapturedRun)
interpretHostCommand cfg command = case resolveLaunch cfg command of
    Left refusal -> pure (Left refusal)
    Right (executable, arguments) -> do
        outcome <- runCaptured executable arguments (effectStdin (commandStdio command))
        pure (bimap renderRunFailure id outcome)

{- | The seams an effect interpreter cannot supply for itself.

The wall is acquired under a project's own ownership identity — the library has
none — and a run's transcript belongs to whoever is reporting it.
-}
data EffectEnvironment = EffectEnvironment
    { effectAcquireGlobalWall :: [String] -> IO ()
    , effectReleaseGlobalWall :: [String] -> IO ()
    , effectEcho :: String -> IO ()
    -- ^ receives text exactly as it should appear, newlines included
    }

{- | How a failing command is treated.

Two policies, because two are genuinely distinct. A launch or staging list stops
at the first failure, since everything after it would run against a state that
was never established. An idempotent teardown continues, because a VM that is
already gone is not a teardown failure — but it says so under one intent line,
so a skipped step is visible rather than silent.
-}
data EffectFailurePolicy
    = FailFast
    | BestEffort String
    deriving (Eq, Show)

-- | Why an effect list stopped. Closed, with a total renderer.
data EffectFailure
    = -- | the command ran and refused: target description, argv, exit code, stdout, stderr
      EffectCommandFailed String [String] Int String String
    | -- | no child existed: target description and the refusal
      EffectCommandUnavailable String String
    deriving (Eq, Show)

renderEffectFailure :: EffectFailure -> String
renderEffectFailure (EffectCommandFailed target arguments code out err) =
    target
        ++ " "
        ++ unwords arguments
        ++ " failed (exit "
        ++ show code
        ++ ")\n"
        ++ out
        ++ err
renderEffectFailure (EffectCommandUnavailable _target refusal) = refusal

{- | Interpret a list of described effects under one failure policy.

The wall effects are always run through the environment's own owner, including
under 'BestEffort': leaving the shared utility VM cordoned, or leaving the
operator's original @.wslconfig@ unrestored, is a durable global side effect a
green teardown must not report.
-}
interpretHostEffects ::
    EffectEnvironment ->
    EffectFailurePolicy ->
    HostConfig ->
    [HostEffect] ->
    IO (Either EffectFailure ())
interpretHostEffects environment policy cfg = go
  where
    go [] = pure (Right ())
    go (effect : remaining) = do
        outcome <- one effect
        case outcome of
            Left failure -> pure (Left failure)
            Right () -> go remaining

    one (ApplyGlobalWslWall body) = Right <$> effectAcquireGlobalWall environment body
    one (ReleaseGlobalWslWall body) = Right <$> effectReleaseGlobalWall environment body
    one (RunDirectHost action) = Right <$> effectEcho environment (directHostReport action)
    one (RunHostCommand command) = do
        announce
        result <- interpretHostCommand cfg command
        case result of
            Right run
                | capturedExit run == ExitSuccess -> do
                    unless (null (capturedStdout run)) (effectEcho environment (capturedStdout run))
                    pure (Right ())
            Right run -> judge (failureOf command run)
            Left refusal -> judge (EffectCommandUnavailable (describeTarget command) refusal)

    announce = case policy of
        FailFast -> pure ()
        BestEffort intent -> effectEcho environment (intent ++ "\n")

    judge failure = case policy of
        FailFast -> pure (Left failure)
        BestEffort _ -> do
            effectEcho environment ("  (skipped: " ++ skipReason failure ++ ")\n")
            pure (Right ())

    failureOf command run =
        EffectCommandFailed
            (describeTarget command)
            (commandArguments command)
            (exitStatus (capturedExit run))
            (capturedStdout run)
            (capturedStderr run)

    exitStatus ExitSuccess = 0
    exitStatus (ExitFailure n) = n

    skipReason (EffectCommandFailed _ _ _ _ err) = takeWhile (/= '\n') err
    skipReason (EffectCommandUnavailable _ refusal) = refusal

-- | How a command's target is named in a diagnostic. Never an invocation target.
describeTarget :: HostCommand -> String
describeTarget command = case commandTarget command of
    ToolTarget tool -> toolCommandName tool
    SelfTarget path -> path

{- | What an explicit direct-host transition reports.

The local frame requires no guest mutation, but acknowledging the closed action
keeps this truthful realization distinct from an unimplemented empty effect list.
-}
directHostReport :: DirectHostAction -> String
directHostReport RealizeDirectHost =
    "provider: selected the already-local direct-host frame; no guest provisioning is required\n"
directHostReport ReconcileDirectHostReady =
    "provider: reconciled the already-local direct-host frame to ready\n"
