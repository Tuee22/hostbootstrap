module RawManifestAsReceivedActivation (rawReceived) where
import HostBootstrap.Activation
    ( ActivationError, ActivationGrant, ActivationManifest, ActivationVerificationKey
    , RuntimeMeasurement, SelectedActivationManifest, verifyRuntimeRoleActivation )
import HostBootstrap.Protected (ProtectedStore)
rawReceived ::
    ActivationVerificationKey -> ProtectedStore -> SelectedActivationManifest -> ActivationManifest ->
    ActivationGrant -> RuntimeMeasurement -> IO (Either ActivationError ())
rawReceived key store selected received grant measurement =
    verifyRuntimeRoleActivation key store selected received grant measurement (\_ -> pure ())
