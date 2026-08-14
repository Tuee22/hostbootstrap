module OpenReverseRootIntent where

-- Reverse-root write-ahead state is private lifecycle substrate. Public
-- consumers cannot name it, inspect it, or use it as a mutation seam.
import HostBootstrap.Lifecycle.Mode (ReverseRootIntent)
