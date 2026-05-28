# Haskell Dependency Patches

Put temporary dependency patches here only when upstream Hackage bounds or
releases cannot build with GHC 9.12.4. On GHC 9.12.4 the shared dependency set
resolves from Hackage without blanket `allow-newer`, so patches should be rare.
Prefer small checked-in patches over external source overrides, and remove
patches once upstream releases catch up.
