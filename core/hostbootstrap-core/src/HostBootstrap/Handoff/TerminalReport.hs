{-# LANGUAGE OverloadedStrings #-}

{- | Lower forward terminal-report admission.

The coordinator supplies a canonical terminal origin only after its exact
rooted frame session has settled.  This owner has no store, signer, process,
command entry, or Chain authority: it checks the typed session boundary and
turns the already-canonical origin into the one completed forward report.
-}
module HostBootstrap.Handoff.TerminalReport
    ( withForwardRootedTerminalReportKernel
    , withFailedForwardRootedTerminalReportKernel
    )
where

import Data.ByteString (ByteString)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Authority (VerbUp)
import HostBootstrap.Handoff
    ( handoffErrorMessage
    , renderForwardCompletedLifecycleReport
    , renderForwardFailedLifecycleReportWithObservations
    )
import HostBootstrap.Lifecycle.Rooted
    ( RootedFrameSession
    , withRootedFrameSessionKernel
    )

-- | Render completion only for an attached, advanced Up session.
withForwardRootedTerminalReportKernel ::
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId VerbUp ->
    ByteString ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withForwardRootedTerminalReportKernel #-}
withForwardRootedTerminalReportKernel session origin use =
    withRootedFrameSessionKernel session $
        \attached verb _lineage _catalog _frame _path _token _stage ordinal predecessor ->
            if not attached
                then refused "an unopened frame has no terminal settlement"
                else if verb /= "up"
                    then refused "a forward terminal report requires the Up session"
                    else if ordinal <= 1 || not (isJust predecessor)
                        then refused "the rooted frame session has not advanced through settlement"
                        else case renderForwardCompletedLifecycleReport origin of
                            Left failure -> refused (Text.pack (handoffErrorMessage failure))
                            Right report -> report `seq` use report
  where
    refused = pure . Left

-- | Render failure only for an attached, advanced Up session. The binding is
-- the exact retained Offer binding and the non-empty detail comes from the
-- canonical failed observation already settled by the root.
withFailedForwardRootedTerminalReportKernel ::
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId VerbUp ->
    ByteString ->
    [(Text, Text, Text)] ->
    Text ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withFailedForwardRootedTerminalReportKernel #-}
withFailedForwardRootedTerminalReportKernel session binding observations detail use =
    withRootedFrameSessionKernel session $
        \attached verb _lineage _catalog _frame _path _token _stage ordinal predecessor ->
            if not attached
                then refused "an unopened frame has no terminal failure"
                else if verb /= "up"
                    then refused "a forward failure report requires the Up session"
                    else if ordinal <= 1 || not (isJust predecessor)
                        then refused "the rooted frame session has not advanced through failure settlement"
                        else case renderForwardFailedLifecycleReportWithObservations binding observations detail of
                            Left failure -> refused (Text.pack (handoffErrorMessage failure))
                            Right report -> report `seq` use report
  where
    refused = pure . Left
