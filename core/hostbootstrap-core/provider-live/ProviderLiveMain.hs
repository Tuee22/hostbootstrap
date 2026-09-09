module Main (main) where

import HostBootstrap.Handoff.Transaction (
    classifyFrameChild,
    frameInterpreter,
    runFrameChildEntry,
 )
import HostBootstrap.Ownership.Shipped (interpretShippedOwnership)
import ProviderLiveRunner (runProviderLiveGate)
import System.Environment (getArgs)

main :: IO ()
main = do
    arguments <- getArgs
    case classifyFrameChild arguments of
        Just entry -> runFrameChildEntry (frameInterpreter interpretShippedOwnership) entry
        Nothing -> runProviderLiveGate
