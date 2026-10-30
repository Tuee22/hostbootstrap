{-# LANGUAGE OverloadedStrings #-}

module UpdateConfigArtifactSchema where

import HostBootstrap.Dhall.Gen (ConfigArtifact, coreArtifacts, schemaText)

-- The imported reader does not expose a record-update label.
replaceSchema :: Maybe ConfigArtifact
replaceSchema = case coreArtifacts of
    artifact : _ -> Just (artifact{schemaText = "Bool"})
    [] -> Nothing
