{-# LANGUAGE OverloadedStrings #-}

module ForgeActivationSecretDigest where

import HostBootstrap.Activation

-- Private-bundle identity must be computed from bytes or decoded canonically.
forgedSecretDigest :: ActivationSecretDigest
forgedSecretDigest = ActivationSecretDigest "hunter2"
