{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module HarnessConfigAsProduction where

import HostBootstrap.Config.Vocab (
    HarnessAuthority,
    Harness,
    Production,
    ProductionSecretRefWire,
    SecretRef,
    TestSecret (TestSecret),
    harnessConfigAuthority,
    productionSecretRefWire,
    testPlaintextSecret,
 )

data Project

harnessConfigAsProduction :: HarnessAuthority Project runId -> ProductionSecretRefWire
harnessConfigAsProduction authority =
    productionSecretRefWire @Project
        ( testPlaintextSecret
            (harnessConfigAuthority authority)
            (TestSecret "fixture")
        )
