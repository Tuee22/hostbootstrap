{-# LANGUAGE OverloadedStrings #-}
module ConstructActivationManifest (construct) where
import HostBootstrap.Activation (ActivationManifest (..), ActivationSecretDigest)
construct :: ActivationSecretDigest -> ActivationManifest
construct secret = ActivationManifest "Production" "plan" "spec" "binary" "frame" "revision" "config" secret "service" "roles" ["network"] "/secret"
