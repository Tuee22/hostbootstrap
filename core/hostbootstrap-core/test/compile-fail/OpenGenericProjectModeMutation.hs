module OpenGenericProjectModeMutation where

-- Callers receive only the scope-specific protected transitions. The generic
-- mode mutation kernel is not part of the public lifecycle surface.
import HostBootstrap.Lifecycle.Mode (acquireMode)
