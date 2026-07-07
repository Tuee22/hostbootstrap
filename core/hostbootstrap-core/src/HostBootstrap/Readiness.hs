-- | A pure, testable readiness/poll combinator that replaces the hand-rolled
-- @waitX _ 0 = die; waitX cfg n = probe >>= ...@ loops scattered across the
-- lifecycle (10 of them, with 3 delays and budgets from 4 to 60). The per-attempt
-- decision ('pollStep') is a total pure function — the unit-tested heart — and the
-- only effectful code is the thin 'pollUntilReadyWith' seam. A sealed 'Ready'
-- witness (constructor hidden in "HostBootstrap.Readiness.Internal"; minted only by
-- 'awaitReady') makes "act before a dependency is ready" a type error wherever a
-- 'Ready' is required.
module HostBootstrap.Readiness
  ( -- * Delay + policy
    Micros (..),
    seconds,
    PollPolicy (..),
    withAttempts,
    pollSchedule,

    -- * Named policies (each pinned to the historical budget of the loop it replaces)
    rolloutPoll,
    pushPoll,
    reachPoll,
    vmBootPoll,
    networkPoll,
    dockerPoll,
    nodePoll,

    -- * Probe + outcome
    ProbeResult (..),
    Probe,
    PollError (..),
    renderPollError,

    -- * The pure decision (unit-tested)
    Decision (..),
    pollStep,

    -- * Drivers
    pollUntilReady,
    pollUntilReadyWith,
    drivePure,

    -- * Readiness witness (phantom-tagged proof; constructor sealed, see "HostBootstrap.Readiness.Internal")
    Ready,
    awaitReady,
    awaitReadyWith,
  )
where

import Control.Concurrent (threadDelay)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Readiness.Internal (Ready (MkReady))

-- | Microseconds — the unit 'threadDelay' takes.
newtype Micros = Micros Int
  deriving (Eq, Ord, Show)

-- | A whole number of seconds as 'Micros'.
seconds :: Int -> Micros
seconds s = Micros (s * 1000000)

-- | An attempt budget and the delay between attempts.
data PollPolicy = PollPolicy
  { ppAttempts :: Int,
    ppDelay :: Micros
  }
  deriving (Eq, Show)

-- | Override a policy's attempt budget (the reachability probe polls at 6/12/24/60).
-- Written to read infix: @reachPoll \`withAttempts\` 24@.
withAttempts :: PollPolicy -> Int -> PollPolicy
withAttempts p n = p {ppAttempts = n}

-- | The pure delay schedule a policy would run: @attempts - 1@ gaps. For tests.
pollSchedule :: PollPolicy -> [Micros]
pollSchedule p = replicate (max 0 (ppAttempts p - 1)) (ppDelay p)

-- The named policies reproduce, exactly, the attempt/delay of each hand-rolled
-- loop they replace, so the refactor is behaviour-preserving. Do not "unify" the
-- numbers — the budgets differ for real reasons (a slow first pull vs a fast probe).
rolloutPoll, pushPoll, reachPoll, vmBootPoll, networkPoll, dockerPoll, nodePoll :: PollPolicy
rolloutPoll = PollPolicy 6 (seconds 5)
pushPoll = PollPolicy 4 (seconds 5)
reachPoll = PollPolicy 24 (seconds 5)
vmBootPoll = PollPolicy 60 (seconds 2)
networkPoll = PollPolicy 20 (seconds 3)
dockerPoll = PollPolicy 30 (seconds 2)
nodePoll = PollPolicy 10 (seconds 3)

-- | A probe's verdict: ready (carrying a payload, e.g. captured stdout to print),
-- not-yet (keep polling), or a deterministic failure (stop now, do not burn the
-- remaining budget on an error that will not clear).
data ProbeResult a
  = ProbeReady a
  | NotReady
  | Failed String
  deriving (Eq, Show)

-- | A probe reads the host config and returns a verdict.
type Probe a = HostConfig -> IO (ProbeResult a)

-- | Why a poll ended without success.
data PollError
  = PollTimeout String
  | PollFailed String
  deriving (Eq, Show)

-- | Render a poll failure into the one-line message a @die@ site prints.
renderPollError :: PollError -> String
renderPollError (PollTimeout lbl) = lbl ++ ": did not become ready within the poll budget"
renderPollError (PollFailed msg) = msg

-- | The pure per-attempt decision — the tested heart of the combinator.
data Decision a
  = Yield a
  | Retry Micros
  | GiveUp PollError
  deriving (Eq, Show)

-- | Decide what to do after attempt @i@ (0-based) returned this verdict.
pollStep :: PollPolicy -> String -> Int -> ProbeResult a -> Decision a
pollStep _ _ _ (ProbeReady a) = Yield a
pollStep _ lbl _ (Failed e) = GiveUp (PollFailed (lbl ++ ": " ++ e))
pollStep pol lbl i NotReady
  | i + 1 >= ppAttempts pol = GiveUp (PollTimeout lbl)
  | otherwise = Retry (ppDelay pol)

-- | Poll @probe@ to readiness, running @recover@ before each retry delay (e.g. an
-- @incus restart@ for the reboot-to-ready loop). The one effectful seam; all the
-- decision logic lives in the pure 'pollStep'.
pollUntilReadyWith ::
  PollPolicy -> String -> (HostConfig -> IO ()) -> Probe a -> HostConfig -> IO (Either PollError a)
pollUntilReadyWith pol lbl recover probe cfg = go 0
  where
    go i = do
      r <- probe cfg
      case pollStep pol lbl i r of
        Yield a -> pure (Right a)
        GiveUp e -> pure (Left e)
        Retry (Micros d) -> recover cfg >> threadDelay d >> go (i + 1)

-- | 'pollUntilReadyWith' with no between-attempt recovery.
pollUntilReady :: PollPolicy -> String -> Probe a -> HostConfig -> IO (Either PollError a)
pollUntilReady pol lbl = pollUntilReadyWith pol lbl (const (pure ()))

-- | A pure driver for tests: fold a canned probe sequence through 'pollStep',
-- returning the outcome and the delays that would have elapsed. A sequence shorter
-- than the budget yields a timeout (a test that means to exhaust the budget
-- supplies exactly @attempts@ 'NotReady's).
drivePure :: PollPolicy -> String -> [ProbeResult a] -> (Either PollError a, [Micros])
drivePure pol lbl = go 0 []
  where
    go _ ds [] = (Left (PollTimeout lbl), reverse ds)
    go i ds (r : rs) = case pollStep pol lbl i r of
      Yield a -> (Right a, reverse ds)
      GiveUp e -> (Left e, reverse ds)
      Retry d -> go (i + 1) (d : ds) rs

-- | Poll to readiness and, on success, mint the phantom-tagged 'Ready' proof
-- (discarding the probe payload). The only way to obtain a @Ready tag@ — so a
-- function requiring @Ready Dep@ cannot run before @Dep@ was observed ready.
awaitReady :: PollPolicy -> String -> Probe a -> HostConfig -> IO (Either PollError (Ready tag))
awaitReady pol lbl = awaitReadyWith pol lbl (const (pure ()))

-- | 'awaitReady' with a between-attempt recovery hook (e.g. a progress note the
-- rollout wait prints while a slow first image pull is still in flight).
awaitReadyWith ::
  PollPolicy -> String -> (HostConfig -> IO ()) -> Probe a -> HostConfig -> IO (Either PollError (Ready tag))
awaitReadyWith pol lbl recover probe cfg = fmap (const MkReady) <$> pollUntilReadyWith pol lbl recover probe cfg
