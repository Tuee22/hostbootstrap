{-# LANGUAGE OverloadedStrings #-}

module ProductionPlaintext where

import HostBootstrap.Config.Vocab (
    Production,
    SecretRef,
    TestSecret (TestSecret),
    harnessConfigAuthority,
    testPlaintextSecret,
    withHarnessAuthority,
 )

data Project

productionPlaintext :: SecretRef (Production Project)
productionPlaintext =
    withHarnessAuthority "run-a" $ \authority ->
        testPlaintextSecret
            (harnessConfigAuthority authority)
            (TestSecret "fixture")
