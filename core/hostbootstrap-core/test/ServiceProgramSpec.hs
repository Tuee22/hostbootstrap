{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

{- | The closed, effect-indexed service program (§ AA).

A handler returns a 'ServiceProgram' rather than @IO ()@, so what it may do is
decided by its declared row and the signed ceiling rather than by discipline.
These cover the value-level half. The type-level half — that an undeclared effect
does not compile at all — is @CompileFailSpec@'s @UndeclaredServiceEffect.hs@,
and it cannot be written here: a program demanding an effect outside its row is
rejected by the compiler, so there is no such value for a runtime case to hold.
-}
module ServiceProgramSpec (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    ProjectRootError,
    withCanonicalProjectRoot,
 )
import HostBootstrap.RoleLifecycle
import RoleLifecycleSpec (mutatingEffects, storeDraft, withRole)
import HostBootstrap.Service.Program
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "ServiceProgramSpec" programTests

programTests :: [TestTree]
programTests =
    [ testCase "an authorized program reaches the backend, once per effect" $
        withRole mutatingEffects storeDraft $ \_ _ placement _ -> do
            served <- newIORef []
            authorization <-
                expectAuthorized
                    (authorizeServiceEffects placement (WithEffect NetworkListenName NoEffects))
            let handles = readyServiceHandles ["public", "ingress"]
            public <- expectHandle handles "public"
            ingress <- expectHandle handles "ingress"
            outcome <-
                interpretServiceProgram
                    authorization
                    (recordingBackend served)
                    (serve [(public, "public-app"), (ingress, "ingress-app")])
            outcome @?= Right ()
            -- the backend sees the acquired names, in the handler's order
            readIORef served >>= (@?= [[("public", "public-app"), ("ingress", "ingress-app")]])
    , testCase "a resource the engine never acquired has no handle to name" $ do
        let handles = readyServiceHandles ["public"] :: ReadyServiceHandles ()
        readyServiceHandleNames handles @?= ["public"]
        fmap acquiredResourceName (lookupAcquiredResource handles "public") @?= Just "public"
        -- there is no other producer, so an unacquired name is simply absent
        fmap acquiredResourceName (lookupAcquiredResource handles "private") @?= Nothing
    , testCase "a backend failure is a typed program failure naming its family" $
        withRole mutatingEffects storeDraft $ \_ _ placement _ -> do
            authorization <-
                expectAuthorized
                    (authorizeServiceEffects placement (WithEffect NetworkListenName NoEffects))
            let handles = readyServiceHandles ["public"]
            public <- expectHandle handles "public"
            outcome <-
                interpretServiceProgram
                    authorization
                    failingBackend
                    (serve [(public, "public-app")])
            outcome @?= Left (ServiceEffectFailed (EffectFailure "network-listen" "bind refused"))
    , testCase "durable read and write are core-executed under the admitted root" $
        withServiceRoot $ \directory root ->
            withRole mutatingEffects storeDraft $ \_ _ placement _ -> do
                authorization <-
                    expectAuthorized
                        (authorizeServiceEffects placement (WithEffect DurableStoreName NoEffects))
                marker <-
                    either (assertFailure . show) pure (serviceDurablePath root [".data"] ["marker"])
                before <- interpretServiceProgram authorization refusingBackend (readDurable marker)
                before @?= Right Nothing
                wrote <-
                    interpretServiceProgram
                        authorization
                        refusingBackend
                        (writeDurable marker "durable-v1" >> readDurable marker)
                wrote @?= Right (Just "durable-v1")
                -- it landed under the admitted root, not beside it, and the
                -- backend was never consulted: core executes this family itself
                assertBool
                    ("the durable file is under the root: " ++ durablePathValue marker)
                    (directory `isInfixOf` durablePathValue marker)
    , testCase "a handler cannot name a durable path outside its own root" $
        withServiceRoot $ \_ root -> do
            let escape segments = serviceDurablePath root [".data"] segments
                refused = either (const True) (const False) . escapeAs
                escapeAs :: [Text] -> Either ProjectRootError (DurablePath ())
                escapeAs = escape
            assertBool "climbing out is refused" (refused [".."])
            assertBool "an embedded separator is refused" (refused ["a/b"])
            assertBool "an absolute segment is refused" (refused ["/etc/passwd"])
            assertBool "a bare dot is refused" (refused ["."])
    ]

-- | The demo-shaped payload family for these cases: plain text on every channel.
data TestPayloads

instance ServicePayloads TestPayloads where
    type ListenApp TestPayloads = Text
    type CallRequest TestPayloads = Text
    type CallReply TestPayloads = Text
    type WorkRequest TestPayloads = Text
    type WorkReply TestPayloads = Text

recordingBackend :: IORef [[(Text, Text)]] -> ServiceBackend TestPayloads
recordingBackend served =
    ServiceBackend
        { backendServe = \pairs -> modifyIORef' served (++ [pairs]) >> pure (Right ())
        , backendCall = \_ request -> pure (Right request)
        , backendWork = \_ request -> pure (Right request)
        }

failingBackend :: ServiceBackend TestPayloads
failingBackend =
    ServiceBackend
        { backendServe = \_ -> pure (Left "bind refused")
        , backendCall = \_ _ -> pure (Left "connect refused")
        , backendWork = \_ _ -> pure (Left "spawn refused")
        }

{- | Every member refuses, so a case that reaches the backend when it should not
fails loudly. The durable-store cases use it deliberately: core executes that
family itself, so the backend must stay untouched.
-}
refusingBackend :: ServiceBackend TestPayloads
refusingBackend = failingBackend

{- | An admitted canonical project root, kept inside its own rank-2 bracket so
the scope/root indices never escape it.
-}
withServiceRoot ::
    ( forall rootScope rootId.
      FilePath ->
      CanonicalProjectRoot rootScope rootId ->
      IO ()
    ) ->
    IO ()
withServiceRoot use =
    withSystemTempDirectory "hostbootstrap-service-root" $ \directory -> do
        createDirectoryIfMissing True (directory </> ".build")
        opened <-
            withCanonicalProjectRoot (directory </> ".build" </> "demo.dhall") "." (use directory)
        either (assertFailure . show) pure opened

expectAuthorized ::
    Either RoleLifecycleError (EffectAuthorization scope specDigest planId frame revision instanceId service effects) ->
    IO (EffectAuthorization scope specDigest planId frame revision instanceId service effects)
expectAuthorized = either (assertFailure . roleLifecycleErrorMessage) pure

expectHandle :: ReadyServiceHandles service -> Text -> IO (AcquiredResource service)
expectHandle handles name =
    maybe (assertFailure ("the fixture did not acquire " ++ Text.unpack name)) pure $
        lookupAcquiredResource handles name
