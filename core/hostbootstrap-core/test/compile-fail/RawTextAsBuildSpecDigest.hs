module RawTextAsBuildSpecDigest (rawSpec) where
import Data.Text (Text)
import HostBootstrap.Build (BuildChannel, BuildError, BuildVerificationKey, BuildProjectName, BuildConfigDigest, CoordinatorDigest, BuildSourceRoot, BuilderPath, verifyBuildInvocation)
rawSpec ::
    BuildVerificationKey -> BuildProjectName -> Text -> BuildConfigDigest -> CoordinatorDigest -> BuildSourceRoot -> BuilderPath ->
    BuildChannel -> IO (Either BuildError ())
rawSpec key project spec config coordinator sourceRoot builder channel =
    verifyBuildInvocation key project spec config coordinator sourceRoot builder channel (\_ _ -> pure ())
