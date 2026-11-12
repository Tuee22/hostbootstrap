-- A caller cannot unpack or construct the private dependency snapshot entries.
module ForgeDependencySnapshot where

import HostBootstrap.Reconcile (DependencySnapshot)

forgedProbeEntry ::
    DependencySnapshot scope planId ->
    DependencySnapshot scope planId
forgedProbeEntry (DependencySnapshot entries) = DependencySnapshot entries
