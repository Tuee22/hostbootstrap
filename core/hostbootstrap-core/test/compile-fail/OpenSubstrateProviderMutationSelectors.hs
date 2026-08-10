module OpenSubstrateProviderMutationSelectors where

import HostBootstrap.Substrate.Provider (spDestroy, spLaunch)

bad = (spLaunch, spDestroy)
