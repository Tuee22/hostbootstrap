{-# LANGUAGE OverloadedStrings #-}

module ImportPlanResource where

import HostBootstrap.Plan.Resource (PlannedResource (PlannedResource))

-- Only the private plan kernel can construct the shared resource identity.
forged :: PlannedResource scope planId resourceId resource frame
forged = PlannedResource "digest" "resource" "frame"
