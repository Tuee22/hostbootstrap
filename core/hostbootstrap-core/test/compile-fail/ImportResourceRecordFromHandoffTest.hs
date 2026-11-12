module ImportResourceRecordFromHandoffTest where

import Data.Text (Text)
import HostBootstrap.Lifecycle.ResourceRecord (resourceRecordPrefixKernel)

retained :: Text -> Either Text Text
retained = resourceRecordPrefixKernel
