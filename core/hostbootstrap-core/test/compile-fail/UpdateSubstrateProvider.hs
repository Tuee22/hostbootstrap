module UpdateSubstrateProvider where

import HostBootstrap.Substrate.Provider

replaceMutationPlanner :: SubstrateProvider -> SubstrateProvider
replaceMutationPlanner provider = provider {spLaunch = undefined, spDestroy = undefined}
