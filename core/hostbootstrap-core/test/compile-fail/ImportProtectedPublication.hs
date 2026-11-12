module ImportProtectedPublication where

import HostBootstrap.Protected.Publication (syncPublishedFile)

bypass = syncPublishedFile
