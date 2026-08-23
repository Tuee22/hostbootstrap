{-# LANGUAGE OverloadedStrings #-}

module EscapeFreshRunningProviderDependency where

import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Lifecycle.Execution (StepExecution)
import HostBootstrap.Reconcile (ReconcileError)
import HostBootstrap.Substrate.Provider.Backend (RunningProviderDependency)
import HostBootstrap.Substrate.Provider.Reconcile
    ( ProviderBackendBinding
    , withFreshRunningProviderDependency
    )

data FixedProvider

escape ::
    StepExecution scope planId ->
    ProviderBackendBinding backendId ->
    Text ->
    Text ->
    Word64 ->
    Text ->
    IO (Either ReconcileError (RunningProviderDependency scope planId FixedProvider))
escape execution backend resource route now nonce =
    withFreshRunningProviderDependency
        execution
        "production"
        backend
        resource
        route
        now
        nonce
        id
