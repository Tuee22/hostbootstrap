{-# LANGUAGE OverloadedStrings #-}

module ProductionPlaintext where

import HostBootstrap.Config.Vocab (
    HarnessAuthority,
    Production,
    SecretRef,
    TestSecret (TestSecret),
    harnessConfigAuthority,
    testPlaintextSecret,
 )

data Project

productionPlaintext ::
    HarnessAuthority Project runId ->
    SecretRef (Production Project)
productionPlaintext authority =
    testPlaintextSecret
        (harnessConfigAuthority authority)
        (TestSecret "fixture")
