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
import HostBootstrap.Config.Schema (ProjectConfig (..))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Ensure (runTool)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Docker))
import System.Exit (ExitCode)

-- | The local image tag a project's container build produces: @\<project\>:local@.
projectImageTag :: ProjectConfig -> String
projectImageTag cfg = T.unpack (Context.project (context cfg)) ++ ":local"

-- | The @docker build@ argv: build the project's Dockerfile `FROM` the given base
-- image, tagged @\<project\>:local@, from the build context @.@. Pure.
dockerBuildArgs :: ProjectConfig -> String -> [String]
dockerBuildArgs cfg baseImage =
  [ "build",
    "-f",
    T.unpack (dockerfile cfg),
    "--build-arg",
    "BASE_IMAGE=" ++ baseImage,
    "-t",
    projectImageTag cfg,
    "."
  ]

-- | Run the project-container build through the resolved Docker tool.
buildProjectContainer ::
  HostConfig ->
  ProjectConfig ->
  -- | the base image to build `FROM`
  String ->
  IO (Either String (ExitCode, String, String))
buildProjectContainer hostCfg projectCfg baseImage =
  runTool hostCfg Docker (dockerBuildArgs projectCfg baseImage)
