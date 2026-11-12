-- | Caller-selected naming inputs cannot enter through the public library.
module ImportColimaNames where

import HostBootstrap.Ensure.Colima.Backend.Names

bad :: FilePath
bad = colimaHomePath "/caller-home" "caller-key"
