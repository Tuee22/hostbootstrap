module ForgeInstalledProjectIdentity where

import HostBootstrap.Authority

data Project

forged :: InstalledProjectIdentity Project
forged = InstalledProjectIdentity "forged"
