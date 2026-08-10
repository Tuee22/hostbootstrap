module DispatchUnfinishedBuilder where

import HostBootstrap.CLI
import HostBootstrap.Config.Class

dispatchUnfinished ::
    (ProjectCfg cfg, TestCfg tcfg) =>
    ProjectSpecBuilder cfg tcfg ->
    IO ()
dispatchUnfinished = runHostBootstrapCLI "unfinished"
