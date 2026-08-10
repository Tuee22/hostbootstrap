{-# LANGUAGE OverloadedStrings #-}

module EscapeInstalledProjectIdentity where

import HostBootstrap.Authority

data ChosenProject

escaped :: IO (Either AuthorityError (InstalledProjectIdentity ChosenProject))
escaped =
    withInstalledProjectIdentity "chosen-project" $ \identity ->
        pure identity
