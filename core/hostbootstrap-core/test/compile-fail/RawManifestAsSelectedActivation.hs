module RawManifestAsSelectedActivation (rawSelected) where
import HostBootstrap.Activation
    ( ActivationError, ActivationGrant, ActivationManifest, ActivationVerificationKey
    , RuntimeMeasurement, ReceivedActivationManifest, verifyRuntimeRoleActivation )
import HostBootstrap.Protected (ProtectedStore)
rawSelected ::
    ActivationVerificationKey -> ProtectedStore -> ActivationManifest -> ReceivedActivationManifest ->
    ActivationGrant -> RuntimeMeasurement -> IO (Either ActivationError ())
rawSelected key store selected received grant measurement =
    verifyRuntimeRoleActivation key store selected received grant measurement (\_ -> pure ())
