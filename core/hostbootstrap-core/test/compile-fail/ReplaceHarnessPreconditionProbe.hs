module ReplaceHarnessPreconditionProbe where

-- The Harness precondition probe is held privately so a caller cannot inject a
-- successful observation by replacing it.
import HostBootstrap.Lifecycle.Mode (HarnessPreconditions)

replaced :: HarnessPreconditions -> HarnessPreconditions
replaced preconditions = preconditions {harnessPreconditionProbe = pure (Right ())}
