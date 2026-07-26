{-# LANGUAGE OverloadedStrings #-}

module CrossRunPlaintext where

import HostBootstrap.Config.Vocab (
    Harness,
    HarnessConfigAuthority,
    SecretRef,
    TestSecret (TestSecret),
    testPlaintextSecret,
 )

data Project

crossRunPlaintext ::
    HarnessConfigAuthority Project runA ->
    SecretRef (Harness Project runB)
crossRunPlaintext authority =
    testPlaintextSecret authority (TestSecret "fixture")
