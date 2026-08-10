module EscapeVerifiedConfigWireIdentity where

import HostBootstrap.Config.Class (ProjectCodec)
import HostBootstrap.Config.Schema
    ( ConfigWireAdmissionError
    , ValidatedConfig
    , VerifiedConfigWire
    , withAuthenticatedConfigWire
    )
import HostBootstrap.Handoff (AuthenticatedConfigPayload)

data ChosenWireDigest
data ChosenConfigIdentity

selectDigest ::
    VerifiedConfigWire scope ChosenWireDigest configId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    IO ()
selectDigest _ _ = pure ()

selectConfig ::
    VerifiedConfigWire scope configDigest ChosenConfigIdentity ->
    ValidatedConfig scope specDigest ChosenConfigIdentity (cfg scope) ->
    IO ()
selectConfig _ _ = pure ()

-- Authenticated decoding generates both the exact byte-digest identity and
-- the local config identity. Neither coordinate can be chosen by a caller.
escapeDigest ::
    ProjectCodec scope specDigest cfg ->
    AuthenticatedConfigPayload scope brokerGeneration ->
    IO (Either ConfigWireAdmissionError ())
escapeDigest codec payload =
    withAuthenticatedConfigWire codec payload selectDigest

escapeConfig ::
    ProjectCodec scope specDigest cfg ->
    AuthenticatedConfigPayload scope brokerGeneration ->
    IO (Either ConfigWireAdmissionError ())
escapeConfig codec payload =
    withAuthenticatedConfigWire codec payload selectConfig
