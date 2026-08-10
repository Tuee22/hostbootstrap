module HandoffGrantAsActivationGrant where

import HostBootstrap.Activation (ActivationGrant)
import HostBootstrap.Handoff (HandoffGrant)

substituteHandoffGrant :: HandoffGrant scope broker -> ActivationGrant
substituteHandoffGrant = id
