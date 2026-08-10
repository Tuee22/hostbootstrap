{-# LANGUAGE OverloadedStrings #-}

module ForgeImageBuildFrame where

import HostBootstrap.Build

data Project
data Spec
data Config
data Frame

-- A frame is minted only beside the invocation authority that verified it.
forgedFrame :: ImageBuildFrame Project Spec Config Frame
forgedFrame = ImageBuildFrame "image-build-container-0"
