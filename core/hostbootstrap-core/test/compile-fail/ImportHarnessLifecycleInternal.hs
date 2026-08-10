module ImportHarnessLifecycleInternal where

import HostBootstrap.Harness.Lifecycle.Internal (HarnessLifecycle)

cannotImportPrivateLifecycle :: HarnessLifecycle -> HarnessLifecycle
cannotImportPrivateLifecycle = id
