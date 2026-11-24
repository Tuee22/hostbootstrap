{-# LANGUAGE OverloadedStrings #-}

{- | The pure classification behind the reverse child's core-managed action.

'HostBootstrap.Command.Child.Reverse' performs the fence checks and supplies the
real cluster releases; this module decides, by value, which recovery profile an
authenticated scope names and which outcome a reverse policy and action produce,
so each result is tested without a process, a store, or a cluster.
-}
module HostBootstrap.Command.Child.Reverse.Internal (
    recoveryProfileNameKernel,
    coreManagedReverseKernel,
) where

import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Step (
    ReversePolicy (CoreManagedReverse),
    TeardownAction (DeleteCluster),
    TeardownOutcome (TeardownFailed, TeardownForeignRetained, TeardownReleased),
 )

-- | The recovery profile an authenticated handoff scope names.
recoveryProfileNameKernel :: Text -> Either Text Text
recoveryProfileNameKernel scope
    | scope == "Production" = Right "production"
    | Just runName <- Text.stripPrefix "Harness " scope
    , not (Text.null runName) =
        Right ("harness:" <> runName)
    | otherwise = Left "reverse child: the authenticated handoff carries an unknown lifecycle scope"

{- | The outcome of one fenced core-managed reverse action. Only a core-managed
cluster deletion touches the host: the recorded exposure is released first, and
the retained cluster only after that succeeds. Every other action answers
without invoking either release.
-}
coreManagedReverseKernel ::
    (Show failure) =>
    ReversePolicy ->
    TeardownAction ->
    IO (Either failure ()) ->
    IO (Either failure ()) ->
    IO TeardownOutcome
coreManagedReverseKernel policy action releaseExposure releaseCluster = case (policy, action) of
    (CoreManagedReverse, DeleteCluster) -> do
        exposure <- releaseExposure
        case exposure of
            Left failure -> pure (TeardownFailed (show failure))
            Right () -> do
                released <- releaseCluster
                pure $ case released of
                    Left failure -> TeardownFailed (show failure)
                    Right () -> TeardownReleased
    (CoreManagedReverse, _) ->
        pure (TeardownForeignRetained "released with the cluster that contains it")
    _ ->
        pure (TeardownForeignRetained "the node acquired nothing this frame must release")
