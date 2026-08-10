module CrossProtocolSigningKeys where

import HostBootstrap.Activation
import HostBootstrap.Build
import HostBootstrap.Handoff

projectAsBuild :: ProjectSigningKey -> BuildSigningKey
projectAsBuild = id

projectAsActivation :: ProjectSigningKey -> ActivationSigningKey
projectAsActivation = id

buildAsProject :: BuildSigningKey -> ProjectSigningKey
buildAsProject = id

buildAsActivation :: BuildSigningKey -> ActivationSigningKey
buildAsActivation = id

activationAsProject :: ActivationSigningKey -> ProjectSigningKey
activationAsProject = id

activationAsBuild :: ActivationSigningKey -> BuildSigningKey
activationAsBuild = id
