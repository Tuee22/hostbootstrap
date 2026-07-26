{-# LANGUAGE OverloadedStrings #-}

module HarnessConfigAsProduction where

import HostBootstrap.Config.Vocab (
    Production,
    SecretRef,
    TestSecret (TestSecret),
    harnessConfigAuthority,
    testPlaintextSecret,
    withHarnessAuthority,
 )

data Project

newtype Config scope = Config (SecretRef scope)

consumeProduction :: Config (Production Project) -> ()
consumeProduction _ = ()

harnessConfigAsProduction :: ()
harnessConfigAsProduction =
    withHarnessAuthority "run-a" $ \authority ->
        consumeProduction
            ( Config
                ( testPlaintextSecret
                    (harnessConfigAuthority authority)
                    (TestSecret "fixture")
                )
            )
