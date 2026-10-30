{- | Private fixtures for presenting real authority evidence from a different
installed identity or protected store. These re-export the kernel's own types
and producers; the public library exposes no raw identity or root opener.
-}
module HostBootstrap.Authority.Testing (
    RootScopeWitness (ProductionRootScope),
    commandReservationKernel,
    invocationKey,
    reservationIdentity,
    reserveCommandInvocationKernel,
    rootScopeProjectName,
    rootScopeStoreIdentity,
    rootScopeEpochWord,
    withExistingVerifiedRootInvocationKernel,
    withFreshBrokerEpochKernel,
    withInstalledProjectKernel,
    withReifiedAllocatedBrokerEpochKernel,
    withVerifiedRootInvocationKernel,
) where

import HostBootstrap.Authority.Kernel (
    RootScopeWitness (ProductionRootScope),
    commandReservationKernel,
    invocationKey,
    reservationIdentity,
    reserveCommandInvocationKernel,
    rootScopeProjectName,
    rootScopeStoreIdentity,
    rootScopeEpochWord,
    withExistingVerifiedRootInvocationKernel,
    withFreshBrokerEpochKernel,
    withInstalledProjectKernel,
    withReifiedAllocatedBrokerEpochKernel,
    withVerifiedRootInvocationKernel,
 )
