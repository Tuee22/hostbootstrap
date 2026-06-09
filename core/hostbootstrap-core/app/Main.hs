-- | The bare @hostbootstrap@ binary: the core command tree with no project
-- commands. It is built like any project binary (host-native on every
-- substrate), not baked into the base image. Project binaries provide their own
-- @Main@ that calls 'runHostBootstrapCLI' with project subcommands.
module Main (main) where

import HostBootstrap.CLI (runHostBootstrapCLI)

main :: IO ()
main = runHostBootstrapCLI "hostbootstrap" []
