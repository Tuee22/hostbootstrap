{-# LANGUAGE OverloadedStrings #-}

module HarnessConfigAsProduction where

import HostBootstrap.Config.Vocab (
    HarnessAuthority,
    Production,
    SecretRef,
    TestSecret (TestSecret),
    harnessConfigAuthority,
    testPlaintextSecret,
 )

data Project

newtype Config scope = Config (SecretRef scope)

consumeProduction :: Config (Production Project) -> ()
consumeProduction _ = ()

harnessConfigAsProduction :: HarnessAuthority Project runId -> ()
harnessConfigAsProduction authority =
    consumeProduction
        ( Config
            ( testPlaintextSecret
                (harnessConfigAuthority authority)
                (TestSecret "fixture")
            )
        )
