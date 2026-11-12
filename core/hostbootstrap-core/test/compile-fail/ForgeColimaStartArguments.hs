-- | Callers cannot forge a start vector for an unrelated profile.
module ForgeColimaStartArguments where

import HostBootstrap.Ensure.Colima.Command

bad = ColimaStartArguments undefined ["--profile", "default"]
