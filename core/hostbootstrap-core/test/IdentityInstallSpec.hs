{-# LANGUAGE OverloadedStrings #-}

module IdentityInstallSpec (tests) where

import qualified Data.ByteString as ByteString
import Data.List (isInfixOf)
import HostBootstrap.Activation (activationSigningKeyFromBytes, activationSigningVerificationKey, activationVerificationKeyBytes, activationVerificationKeyFromBytes)
import HostBootstrap.Build (installedBuildSigningKey)
import HostBootstrap.Handoff (
    installedProjectSigningKey,
    installedVerificationKey,
    projectSigningVerificationKey,
    verificationKeyBytes,
 )
import HostBootstrap.Identity.Install (provisionInstalledIdentity, validateInstalledIdentity)
import System.Directory (removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "installed project identity"
        [ testCase "installs valid handoff, build, and activation identities idempotently" $
            withSystemTempDirectory "hostbootstrap-identity" $ \root -> do
                let executable = root </> "demo"
                    handoffSecret = executable <> ".handoff.key"
                    handoffPublic = executable <> ".handoff.pub"
                    buildSecret = executable <> ".build.key"
                    activationSecret = executable <> ".activation.key"
                    activationPublic = executable <> ".activation.pub"
                expectRight =<< provisionInstalledIdentity executable
                firstHandoff <- ByteString.readFile handoffSecret
                firstPublic <- ByteString.readFile handoffPublic
                firstBuild <- ByteString.readFile buildSecret
                firstActivation <- ByteString.readFile activationSecret
                firstActivationPublic <- ByteString.readFile activationPublic
                ByteString.length firstHandoff @?= 32
                ByteString.length firstPublic @?= 32
                ByteString.length firstBuild @?= 32
                ByteString.length firstActivation @?= 32
                ByteString.length firstActivationPublic @?= 32
                assertBool "the three signing identities are distinct" (length (unique [firstHandoff, firstBuild, firstActivation]) == 3)
                signing <- installedProjectSigningKey handoffSecret >>= either (assertFailure . show) pure
                verification <- installedVerificationKey handoffPublic >>= either (assertFailure . show) pure
                verificationKeyBytes verification
                    @?= verificationKeyBytes (projectSigningVerificationKey signing)
                _ <- installedBuildSigningKey buildSecret >>= either (assertFailure . show) pure
                activationSigning <- either (assertFailure . show) pure (activationSigningKeyFromBytes firstActivation)
                activationVerification <- either (assertFailure . show) pure (activationVerificationKeyFromBytes firstActivationPublic)
                activationVerificationKeyBytes activationVerification
                    @?= activationVerificationKeyBytes (activationSigningVerificationKey activationSigning)
                expectRight =<< validateInstalledIdentity executable
                expectRight =<< provisionInstalledIdentity executable
                ByteString.readFile handoffSecret >>= (@?= firstHandoff)
                ByteString.readFile handoffPublic >>= (@?= firstPublic)
                ByteString.readFile buildSecret >>= (@?= firstBuild)
                ByteString.readFile activationSecret >>= (@?= firstActivation)
                ByteString.readFile activationPublic >>= (@?= firstActivationPublic)
        , testCase "repairs only a missing public half from the retained secret" $
            withSystemTempDirectory "hostbootstrap-identity-repair" $ \root -> do
                let executable = root </> "demo"
                    handoffSecret = executable <> ".handoff.key"
                    handoffPublic = executable <> ".handoff.pub"
                expectRight =<< provisionInstalledIdentity executable
                secret <- ByteString.readFile handoffSecret
                expectedPublic <- ByteString.readFile handoffPublic
                removeFile handoffPublic
                expectRight =<< provisionInstalledIdentity executable
                ByteString.readFile handoffSecret >>= (@?= secret)
                ByteString.readFile handoffPublic >>= (@?= expectedPublic)
        , testCase "refuses a public half whose signing identity is absent" $
            withSystemTempDirectory "hostbootstrap-identity-orphan" $ \root -> do
                let executable = root </> "demo"
                ByteString.writeFile (executable <> ".handoff.pub") (ByteString.replicate 32 7)
                result <- provisionInstalledIdentity executable
                assertLeftContains "without its signing key" result
        , testCase "refuses a mismatched retained handoff pair" $
            withSystemTempDirectory "hostbootstrap-identity-mismatch" $ \root -> do
                let executable = root </> "demo"
                    publicPath = executable <> ".handoff.pub"
                expectRight =<< provisionInstalledIdentity executable
                ByteString.writeFile publicPath (ByteString.replicate 32 7)
                result <- provisionInstalledIdentity executable
                assertLeftContains "does not match" result
        , testCase "repairs a missing activation public half from its retained secret" $
            withSystemTempDirectory "hostbootstrap-activation-identity-repair" $ \root -> do
                let executable = root </> "demo"
                    secretPath = executable <> ".activation.key"
                    publicPath = executable <> ".activation.pub"
                expectRight =<< provisionInstalledIdentity executable
                secret <- ByteString.readFile secretPath
                expectedPublic <- ByteString.readFile publicPath
                removeFile publicPath
                expectRight =<< provisionInstalledIdentity executable
                ByteString.readFile secretPath >>= (@?= secret)
                ByteString.readFile publicPath >>= (@?= expectedPublic)
        , testCase "refuses an activation public half whose signing identity is absent" $
            withSystemTempDirectory "hostbootstrap-activation-identity-orphan" $ \root -> do
                let executable = root </> "demo"
                ByteString.writeFile (executable <> ".activation.pub") (ByteString.replicate 32 7)
                result <- provisionInstalledIdentity executable
                assertLeftContains "activation public key without its signing key" result
        , testCase "refuses a mismatched retained activation pair" $
            withSystemTempDirectory "hostbootstrap-activation-identity-mismatch" $ \root -> do
                let executable = root </> "demo"
                    publicPath = executable <> ".activation.pub"
                expectRight =<< provisionInstalledIdentity executable
                ByteString.writeFile publicPath (ByteString.replicate 32 7)
                result <- provisionInstalledIdentity executable
                assertLeftContains "activation key pair does not match" result
        , testCase "refuses malformed retained signing material" $
            withSystemTempDirectory "hostbootstrap-identity-malformed" $ \root -> do
                let executable = root </> "demo"
                ByteString.writeFile (executable <> ".handoff.key") "short"
                result <- provisionInstalledIdentity executable
                assertLeftContains "invalid installed key" result
        , testCase "read-only validation refuses a missing build identity" $
            withSystemTempDirectory "hostbootstrap-identity-validation" $ \root -> do
                let executable = root </> "demo"
                    buildSecret = executable <> ".build.key"
                expectRight =<< provisionInstalledIdentity executable
                removeFile buildSecret
                result <- validateInstalledIdentity executable
                assertLeftContains "build authority" result
        ]

expectRight :: Either String () -> IO ()
expectRight (Right ()) = pure ()
expectRight (Left reason) = assertFailure reason

assertLeftContains :: String -> Either String () -> IO ()
assertLeftContains needle result = case result of
    Left reason -> assertBool ("expected " <> show needle <> " in " <> show reason) (needle `isInfixOf` reason)
    Right () -> assertFailure ("expected refusal containing " <> show needle)

unique :: (Eq value) => [value] -> [value]
unique [] = []
unique (value : rest) = value : unique (filter (/= value) rest)
