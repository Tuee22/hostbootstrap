module RawTextAsBuildConfigDigest (rawConfig) where
import Data.Text (Text)
import HostBootstrap.Build (BuildChannel, BuildError, BuildVerificationKey, BuildProjectName, BuildSpecDigest, CoordinatorDigest, BuildSourceRoot, BuilderPath, verifyBuildInvocation)
rawConfig ::
    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> Text -> CoordinatorDigest -> BuildSourceRoot -> BuilderPath ->
    BuildChannel -> IO (Either BuildError ())
rawConfig key project spec config coordinator sourceRoot builder channel =
    verifyBuildInvocation key project spec config coordinator sourceRoot builder channel (\_ _ -> pure ())
