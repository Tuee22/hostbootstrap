module CoerceProjectVerb where

import Data.Coerce (coerce)
import HostBootstrap.Authority (ProjectVerb, VerbDestroy, VerbDown)

-- The canonical project verb retains its nominal index; a down admission
-- cannot be relabelled as destroy through representational coercion.
coerceDownAsDestroy :: ProjectVerb VerbDown -> ProjectVerb VerbDestroy
coerceDownAsDestroy = coerce

