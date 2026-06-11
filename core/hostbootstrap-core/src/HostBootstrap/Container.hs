-- | The project-container build (build #3): the @docker build@ a project binary
-- runs once it is up, producing the workload image `FROM` the base (see
-- @development_plan_standards.md § M, § N@). The argv builder is pure (so it is
-- unit-tested); 'buildProjectContainer' is the thin IO seam that runs it through
-- the resolved Docker tool.
module HostBootstrap.Container
  ( projectImageTag,
    dockerBuildArgs,
    buildProjectContainer,
  )
where

import qualified Data.Text as T
import HostBootstrap.Config.Schema (StaticBase (..))
import HostBootstrap.Ensure (runTool)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Docker))
import System.Exit (ExitCode)

-- | The local image tag a project's container build produces: @\<project\>:local@.
projectImageTag :: StaticBase -> String
projectImageTag sb = T.unpack (project sb) ++ ":local"

-- | The @docker build@ argv: build the project's Dockerfile `FROM` the given base
-- image, tagged @\<project\>:local@, from the build context @.@. Pure.
dockerBuildArgs :: StaticBase -> String -> [String]
dockerBuildArgs sb baseImage =
  [ "build",
    "-f",
    T.unpack (dockerfile sb),
    "--build-arg",
    "BASE_IMAGE=" ++ baseImage,
    "-t",
    projectImageTag sb,
    "."
  ]

-- | Run the project-container build through the resolved Docker tool.
buildProjectContainer ::
  HostConfig ->
  StaticBase ->
  -- | the base image to build `FROM`
  String ->
  IO (Either String (ExitCode, String, String))
buildProjectContainer cfg sb baseImage = runTool cfg Docker (dockerBuildArgs sb baseImage)
