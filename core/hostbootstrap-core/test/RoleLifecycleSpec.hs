module RoleLifecycleSpec (tests) where

import Control.Exception (SomeException, try)
import Data.IORef (modifyIORef', newIORef, readIORef)
import HostBootstrap.RoleLifecycle
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "RoleLifecycleSpec"
    [ testCase "rolePhases are ordered Load..Exit" $
        rolePhases @?= [Load, Prereq, Acquire, Ready, Serve, Drain, Exit],
      testCase "runRole acquires, serves, then drains in order" $ do
        steps <- newIORef []
        runRole
          RoleSpec
            { roleAcquire = modifyIORef' steps (++ ["acquire"]),
              roleServe = \_ -> modifyIORef' steps (++ ["serve"]),
              roleDrain = \_ -> modifyIORef' steps (++ ["drain"])
            }
        readIORef steps >>= (@?= ["acquire", "serve", "drain"]),
      testCase "drain runs even when serve throws" $ do
        steps <- newIORef []
        _ <-
          try
            ( runRole
                RoleSpec
                  { roleAcquire = pure (),
                    roleServe = \_ -> ioError (userError "boom"),
                    roleDrain = \_ -> modifyIORef' steps (++ ["drain"])
                  }
            ) ::
            IO (Either SomeException ())
        readIORef steps >>= (@?= ["drain"])
    ]
