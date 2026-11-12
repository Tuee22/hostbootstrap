module RawTextAsCoordinatorDigest (verify) where
import Data.Text (Text)
import HostBootstrap.Build (BuildChannel, BuildError, BuildVerificationKey, BuildProjectName, BuildSpecDigest, BuildConfigDigest, BuildSourceRoot, BuilderPath, verifyBuildInvocation)
verify ::
    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest -> Text -> BuildSourceRoot -> BuilderPath ->
    BuildChannel -> IO (Either BuildError ())
verify key project spec config coordinator sourceRoot builder channel =
    verifyBuildInvocation key project spec config coordinator sourceRoot builder channel (\_ _ -> pure ())
