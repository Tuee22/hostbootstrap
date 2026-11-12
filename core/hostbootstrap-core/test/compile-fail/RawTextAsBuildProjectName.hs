module RawTextAsBuildProjectName (rawProject) where
import Data.Text (Text)
import HostBootstrap.Build (BuildChannel, BuildError, BuildVerificationKey, BuildSpecDigest, BuildConfigDigest, CoordinatorDigest, BuildSourceRoot, BuilderPath, verifyBuildInvocation)
rawProject ::
    BuildVerificationKey -> Text -> BuildSpecDigest -> BuildConfigDigest -> CoordinatorDigest -> BuildSourceRoot -> BuilderPath ->
    BuildChannel -> IO (Either BuildError ())
rawProject key project spec config coordinator sourceRoot builder channel =
    verifyBuildInvocation key project spec config coordinator sourceRoot builder channel (\_ _ -> pure ())
