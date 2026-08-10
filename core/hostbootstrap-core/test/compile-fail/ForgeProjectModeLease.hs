module ForgeProjectModeLease where

import HostBootstrap.Lifecycle.Mode (ProductionMode, ProjectModeLease)

data Project
data BrokerGeneration

-- A mode lease exists only after the protected mode compare-and-swap wins.
forgedModeLease :: ProjectModeLease Project ProductionMode BrokerGeneration
forgedModeLease = ProjectModeLease
