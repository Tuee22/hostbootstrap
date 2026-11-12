module ImportConfigInstallFromHandoffTest where

import HostBootstrap.Config.Install.Native (linkNoReplace)

retained :: FilePath -> FilePath -> IO ()
retained = linkNoReplace
