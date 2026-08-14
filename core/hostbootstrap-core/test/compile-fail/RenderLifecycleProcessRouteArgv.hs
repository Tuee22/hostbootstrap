module RenderLifecycleProcessRouteArgv where

-- The ordinary lift renders the argv shapes a process route deliberately does
-- not: a container run that may carry a configuration delivery on standard
-- input, and the three VM forms that inherit whatever the host frame held.
-- The public lift facade exposes none of the route's own sanitized renderers,
-- so a consumer cannot obtain a protocol-safe argument vector from it.
import HostBootstrap.Lift
    ( sanitizedLaunch
    , withLifecycleProcessRouteLaunchKernel
    )
