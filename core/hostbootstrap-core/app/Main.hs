{- | The bare @hostbootstrap@ binary: the core command tree with no project
commands. It is built like any project binary (host-native on every
substrate), not baked into the base image. Project binaries provide their own
@Main@ that calls 'runHostBootstrapCLI' with a project spec.
-}
module Main (main) where

import HostBootstrap.CLI (runBareHostBootstrapCLI)

main :: IO ()
main = runBareHostBootstrapCLI "hostbootstrap"
