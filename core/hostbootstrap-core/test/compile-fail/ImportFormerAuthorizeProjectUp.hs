module ImportFormerAuthorizeProjectUp where

import HostBootstrap.Authority.ProjectPlan (authorizeProjectUp)

former :: ()
former = authorizeProjectUp `seq` ()
