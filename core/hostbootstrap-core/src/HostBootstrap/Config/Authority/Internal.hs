{- | Private construction boundary for harness configuration authority.

Only lifecycle code that has acquired a typed Harness root imports this module's
minting function. Public configuration vocabulary re-exports the authority
types and their narrowing/read-only eliminators, but no constructor or opener
from arbitrary text.
-}
module HostBootstrap.Config.Authority.Internal (
    HarnessAuthority,
    HarnessConfigAuthority,
    mintHarnessAuthority,
    mintAuthenticatedHarnessConfigAuthority,
    harnessConfigAuthority,
    harnessRunName,
    harnessConfigRunName,
) where

import Data.Text (Text)

-- | Authority for one exact generative Harness root.
newtype HarnessAuthority projectId runId = HarnessAuthority Text

-- | Narrow authority allowed to introduce fixture plaintext for that run.
newtype HarnessConfigAuthority projectId runId = HarnessConfigAuthority Text

-- | Mint authority while constructing the matching typed lifecycle root.
mintHarnessAuthority :: Text -> HarnessAuthority projectId runId
mintHarnessAuthority = HarnessAuthority

{- | Mint the narrow authority after another package-private boundary has
authenticated the exact Harness scope capsule.
-}
mintAuthenticatedHarnessConfigAuthority :: Text -> HarnessConfigAuthority projectId runId
mintAuthenticatedHarnessConfigAuthority = HarnessConfigAuthority

-- | Narrow root authority to config-assembly authority.
harnessConfigAuthority ::
    HarnessAuthority projectId runId ->
    HarnessConfigAuthority projectId runId
harnessConfigAuthority (HarnessAuthority runName) = HarnessConfigAuthority runName

-- | Descriptive run name; this does not expose or recreate authority.
harnessRunName :: HarnessAuthority projectId runId -> Text
harnessRunName (HarnessAuthority runName) = runName

-- | Internal read needed to bind fixture plaintext to its exact run.
harnessConfigRunName :: HarnessConfigAuthority projectId runId -> Text
harnessConfigRunName (HarnessConfigAuthority runName) = runName
