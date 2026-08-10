module ProjectSigningKeyAsVerificationKey where

import HostBootstrap.Handoff

substituteSecret :: ProjectSigningKey -> ProjectVerificationKey
substituteSecret = id
