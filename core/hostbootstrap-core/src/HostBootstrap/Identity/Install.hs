{-# LANGUAGE OverloadedStrings #-}

{- | Installation of the long-lived identities owned by one project binary.

The Python bootstrapper can build a project binary but deliberately does not
implement project cryptography.  Immediately after copying a newly built
binary to its stable path, it invokes the private entry defined here.  The
binary then installs (or validates) the five sibling artifacts its Production
root needs:

* @<executable>.handoff.key@ — the root-only handoff signing seed;
* @<executable>.handoff.pub@ — its independently installed public half; and
* @<executable>.build.key@ — the distinct image-build signing seed;
* @<executable>.activation.key@ — the distinct runtime-activation signing seed; and
* @<executable>.activation.pub@ — its independently installed public half.

Existing valid identities are retained across rebuilds.  A missing public half
is repaired from the retained handoff seed, but a public key without its secret
or a mismatched pair is refused: silently replacing either case would change
the installed project identity.
-}
module HostBootstrap.Identity.Install (
    provisionInstalledIdentity,
    validateInstalledIdentity,
) where

import Control.Exception (SomeException, finally, try)
import Control.Monad (unless, when)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import HostBootstrap.Activation (
    ActivationSigningKey,
    ActivationVerificationKey,
    activationErrorMessage,
    activationSigningKeyFromBytes,
    activationSigningVerificationKey,
    activationVerificationKeyBytes,
    activationVerificationKeyFromBytes,
 )
import HostBootstrap.Build (
    buildErrorMessage,
    buildSigningKeyFromBytes,
    installedBuildSigningKey,
 )
import HostBootstrap.Config.Install.Native (linkNoReplace)
import HostBootstrap.Handoff (
    handoffErrorMessage,
    installedProjectSigningKey,
    installedVerificationKey,
    projectSigningKeyFromBytes,
    projectSigningVerificationKey,
    verificationKeyBytes,
 )
import System.Directory (doesFileExist, removeFile)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (hClose, hFlush, hIsOpen, openBinaryTempFile)

-- | Install or validate all sibling identities for an absolute executable.
provisionInstalledIdentity :: FilePath -> IO (Either String ())
provisionInstalledIdentity executable = do
    let handoffSecretPath = executable <> ".handoff.key"
        handoffPublicPath = executable <> ".handoff.pub"
        buildSecretPath = executable <> ".build.key"
        activationSecretPath = executable <> ".activation.key"
        activationPublicPath = executable <> ".activation.pub"
    secretPresent <- doesFileExist handoffSecretPath
    publicPresent <- doesFileExist handoffPublicPath
    activationSecretPresent <- doesFileExist activationSecretPath
    activationPublicPresent <- doesFileExist activationPublicPath
    if publicPresent && not secretPresent
        then
            pure
                ( Left
                    ( "identity install: refusing an installed handoff public key without its signing key at "
                        <> handoffPublicPath
                    )
                )
        else
            if activationPublicPresent && not activationSecretPresent
                then pure (Left ("identity install: refusing an installed activation public key without its signing key at " <> activationPublicPath))
                else do
                    handoffSeed <- ensureSecret handoffSecretPath validateHandoffSeed
                    case handoffSeed of
                        Left reason -> pure (Left reason)
                        Right seed -> do
                            signing <- case projectSigningKeyFromBytes seed of
                                Left err -> pure (Left (handoffErrorMessage err))
                                Right key -> pure (Right key)
                            case signing of
                                Left reason -> pure (Left ("identity install: " <> reason))
                                Right key -> do
                                    handoffPublic <-
                                        ensurePublic
                                            handoffPublicPath
                                            (verificationKeyBytes (projectSigningVerificationKey key))
                                    case handoffPublic of
                                        Left reason -> pure (Left reason)
                                        Right () -> do
                                            buildSeed <- ensureSecret buildSecretPath validateBuildSeed
                                            case buildSeed of
                                                Left reason -> pure (Left reason)
                                                Right _ -> do
                                                    activationSeed <- ensureSecret activationSecretPath validateActivationSeed
                                                    case activationSeed of
                                                        Left reason -> pure (Left reason)
                                                        Right seedBytes ->
                                                            case activationSigningKeyFromBytes seedBytes of
                                                                Left failure -> pure (Left ("identity install: " <> activationErrorMessage failure))
                                                                Right activationSigning -> do
                                                                    activationPublic <-
                                                                        ensureActivationPublic
                                                                            activationPublicPath
                                                                            (activationVerificationKeyBytes (activationSigningVerificationKey activationSigning))
                                                                    case activationPublic of
                                                                        Left reason -> pure (Left reason)
                                                                        Right () -> validateInstalledIdentity executable

-- | Validate the complete installed identity without creating or changing it.
validateInstalledIdentity :: FilePath -> IO (Either String ())
validateInstalledIdentity executable = do
    let handoffSecretPath = executable <> ".handoff.key"
        handoffPublicPath = executable <> ".handoff.pub"
        buildSecretPath = executable <> ".build.key"
        activationSecretPath = executable <> ".activation.key"
        activationPublicPath = executable <> ".activation.pub"
    signing <- installedProjectSigningKey handoffSecretPath
    verification <- installedVerificationKey handoffPublicPath
    buildSigning <- installedBuildSigningKey buildSecretPath
    activationSigning <- loadActivationSigning activationSecretPath
    activationVerification <- loadActivationVerification activationPublicPath
    pure $ do
        handoffSigning <- either (Left . ("identity install: " <>) . handoffErrorMessage) Right signing
        handoffVerification <- either (Left . ("identity install: " <>) . handoffErrorMessage) Right verification
        _ <- either (Left . ("identity install: " <>) . buildErrorMessage) Right buildSigning
        installedActivationSigning <- activationSigning
        installedActivationVerification <- activationVerification
        if verificationKeyBytes handoffVerification /= verificationKeyBytes (projectSigningVerificationKey handoffSigning)
            then Left ("identity install: installed handoff key pair does not match at " <> handoffPublicPath)
            else
                if activationVerificationKeyBytes installedActivationVerification
                    /= activationVerificationKeyBytes (activationSigningVerificationKey installedActivationSigning)
                    then Left ("identity install: installed activation key pair does not match at " <> activationPublicPath)
                    else Right ()

validateHandoffSeed :: ByteString -> Either String ()
validateHandoffSeed bytes =
    case projectSigningKeyFromBytes bytes of
        Left err -> Left (handoffErrorMessage err)
        Right _ -> Right ()

validateBuildSeed :: ByteString -> Either String ()
validateBuildSeed bytes =
    case buildSigningKeyFromBytes bytes of
        Left err -> Left (buildErrorMessage err)
        Right _ -> Right ()

validateActivationSeed :: ByteString -> Either String ()
validateActivationSeed bytes =
    case activationSigningKeyFromBytes bytes of
        Left err -> Left (activationErrorMessage err)
        Right _ -> Right ()

loadActivationSigning :: FilePath -> IO (Either String ActivationSigningKey)
loadActivationSigning path = do
    loaded <- try (ByteString.readFile path) :: IO (Either SomeException ByteString)
    pure $ case loaded of
        Left err -> Left ("identity install: failed to read " <> path <> ": " <> firstLine (show err))
        Right bytes -> either (Left . ("identity install: " <>) . activationErrorMessage) Right (activationSigningKeyFromBytes bytes)

loadActivationVerification :: FilePath -> IO (Either String ActivationVerificationKey)
loadActivationVerification path = do
    loaded <- try (ByteString.readFile path) :: IO (Either SomeException ByteString)
    pure $ case loaded of
        Left err -> Left ("identity install: failed to read " <> path <> ": " <> firstLine (show err))
        Right bytes -> either (Left . ("identity install: " <>) . activationErrorMessage) Right (activationVerificationKeyFromBytes bytes)

ensureSecret :: FilePath -> (ByteString -> Either String ()) -> IO (Either String ByteString)
ensureSecret path validate = do
    present <- doesFileExist path
    unless present $ do
        seed <- getRandomBytes 32
        _ <- publishNoReplace path seed
        pure ()
    loaded <- try (ByteString.readFile path) :: IO (Either SomeException ByteString)
    pure $ case loaded of
        Left err -> Left ("identity install: failed to read " <> path <> ": " <> firstLine (show err))
        Right bytes -> case validate bytes of
            Left reason -> Left ("identity install: invalid installed key at " <> path <> ": " <> reason)
            Right () -> Right bytes

ensurePublic :: FilePath -> ByteString -> IO (Either String ())
ensurePublic path expected = do
    present <- doesFileExist path
    unless present $ do
        _ <- publishNoReplace path expected
        pure ()
    loaded <- installedVerificationKey path
    pure $ case loaded of
        Left err -> Left ("identity install: " <> handoffErrorMessage err)
        Right actual
            | verificationKeyBytes actual == expected -> Right ()
            | otherwise -> Left ("identity install: installed handoff key pair does not match at " <> path)

ensureActivationPublic :: FilePath -> ByteString -> IO (Either String ())
ensureActivationPublic path expected = do
    present <- doesFileExist path
    unless present $ do
        _ <- publishNoReplace path expected
        pure ()
    loaded <- loadActivationVerification path
    pure $ case loaded of
        Left reason -> Left reason
        Right actual
            | activationVerificationKeyBytes actual == expected -> Right ()
            | otherwise -> Left ("identity install: installed activation key pair does not match at " <> path)

-- Publish completed bytes without replacing a competing or retained identity.
-- openBinaryTempFile creates the private temporary with owner-only access on
-- POSIX; the hard-link publication retains those permissions. Restrictive
-- permissions are also safe for the public half.
publishNoReplace :: FilePath -> ByteString -> IO Bool
publishNoReplace destination bytes = do
    let directory = takeDirectory destination
        template = "." <> takeFileName destination <> ".install"
    (temporary, handle) <- openBinaryTempFile directory template
    let cleanup = do
            open <- hIsOpen handle
            when open (hClose handle)
            lingering <- doesFileExist temporary
            when lingering (removeFile temporary)
        publish = do
            ByteString.hPut handle bytes
            hFlush handle
            hClose handle
            linked <- try (linkNoReplace temporary destination) :: IO (Either SomeException ())
            pure (either (const False) (const True) linked)
    publish `finally` cleanup

firstLine :: String -> String
firstLine = takeWhile (/= '\n')
