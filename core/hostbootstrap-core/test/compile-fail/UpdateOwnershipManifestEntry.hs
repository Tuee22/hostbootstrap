{-# LANGUAGE OverloadedStrings #-}
module UpdateOwnershipManifestEntry where

import HostBootstrap.Ownership.Manifest

bad entry = entry { manifestEntryPath = "../x" }
