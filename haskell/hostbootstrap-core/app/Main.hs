-- | The skeletal @hostbootstrap@ binary baked into the base image: the core
-- command tree with no project commands. Project binaries provide their own
-- @Main@ that calls 'runHostBootstrapCLI' with project subcommands.
module Main (main) where

import HostBootstrap.CLI (runHostBootstrapCLI)

main :: IO ()
main = runHostBootstrapCLI "hostbootstrap" []
