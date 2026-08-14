module ForgeSubtreeSettlement where

import HostBootstrap.Authority (ProjectVerb (ProjectDestroy), VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data Frame

-- Only exact completed-forest verification may mint frame settlement.
forgedSubtree :: SubtreeSettled Scope Plan Frame VerbDestroy
forgedSubtree = SubtreeSettled ProjectDestroy "digest" "frame" []

-- Only exact root/topology promotion may mint project-wide closure evidence.
forgedDestroy :: DestroySettled Scope Plan
forgedDestroy = DestroySettled "digest" []
