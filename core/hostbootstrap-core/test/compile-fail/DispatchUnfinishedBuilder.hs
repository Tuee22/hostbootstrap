{-# LANGUAGE MultiParamTypeClasses #-}

module DispatchUnfinishedBuilder where

import HostBootstrap.CLI
import HostBootstrap.Config.Class

dispatchUnfinished ::
    (ProjectCfg projectId cfg, TestCfg tcfg) =>
    ProjectSpecBuilder projectId cfg tcfg ->
    IO ()
dispatchUnfinished = runHostBootstrapCLI "unfinished"
