module EscapeProbe where

import Data.Coerce (coerce)
import HostBootstrap.Readiness (Probe)

data EscapedProbe

-- A received probe's fresh identity is nominal independently of its plan index.
-- It cannot become the caller's concrete marker even when every other index agrees.
escapeProbe ::
    Probe scope planId resourceId resource dependency probeId value ->
    Probe scope planId resourceId resource dependency EscapedProbe value
escapeProbe = coerce
