{-# LANGUAGE ScopedTypeVariables #-}

module CrossScopeProjectRoot where

import Data.Text (Text)
import HostBootstrap.Config.Class (ProjectCfg, ProjectCodec)
import HostBootstrap.Config.Schema (withSiblingValidatedProjectConfigRoot)
import HostBootstrap.Context (CommandClass (HostOrchestratorCommand))
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)

data ConfigScope
data ForeignScope

crossScopeRoot ::
    ProjectCfg cfg =>
    ProjectCodec ConfigScope specDigest cfg ->
    Text ->
    IO ()
crossScopeRoot codec projectName =
    withSiblingValidatedProjectConfigRoot
        codec
        projectName
        HostOrchestratorCommand
        []
        (\_ _ _ (_ :: CanonicalProjectRoot ForeignScope rootId) -> pure ())
