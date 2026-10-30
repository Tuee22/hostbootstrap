module EscapeDetachedChild where

import HostBootstrap.Detached

escaped :: DetachedLaunch -> IO (Either DetachedLaunchError (DetachedIO escaped ()))
escaped launch = withDetachedChild launch $ \child -> pure (terminateDetachedChild child)
