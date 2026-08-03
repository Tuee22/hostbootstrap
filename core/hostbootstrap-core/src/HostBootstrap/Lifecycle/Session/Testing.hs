{- | Deterministic crash injection for lifecycle transaction tests.

This deliberately separate testing surface can only install a thread-local
exception point around an action the caller already possesses. It exports no
transaction target, record key, coordinator permit, or authority constructor;
installing a failpoint by itself performs no protected-store mutation.

The exception constructor is hidden. Production callers that do not
deliberately import this @.Testing@ module see no crash-injection API on
"HostBootstrap.Lifecycle.Session".
-}
module HostBootstrap.Lifecycle.Session.Testing (
    TransactionFailpoint (..),
    TransactionInterrupted,
    withTransactionFailpoint,
) where

import HostBootstrap.Lifecycle.Transaction (
    TransactionFailpoint (..),
    TransactionInterrupted,
    withTransactionFailpoint,
 )
