{-# LANGUAGE OverloadedStrings #-}

-- | Pure project/lifecycle naming policy; values here grant no backend authority.
module HostBootstrap.Ensure.Colima.Backend.Names (
    deriveColimaNames,
    validColimaProjectProfileName,
    colimaHomePath,
)
where

import Data.Char (isAlphaNum, isAsciiLower, isDigit)
import Data.Either (isRight)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text.Encoding
import HostBootstrap.Digest (sha256Hex)
import HostBootstrap.Reconcile.Error (
    ReconcileError (Conflict, Failure),
    ConflictDetail (ConflictDetail),
    FailureDetail (FailureDetail),
    RecoveryDisposition (DoNotRetry),
 )
import System.FilePath ((</>))

-- | The diagnostic predicate uses the same admission as actual derivation.
validColimaProjectProfileName :: Text.Text -> Bool
validColimaProjectProfileName = isRight . validateProfileName

validateProfileName :: Text.Text -> Either ReconcileError String
validateProfileName projectName
    | not (validProfileName name) =
        Left
            ( Failure
                ( FailureDetail
                    "derive Colima profile"
                    ("invalid project profile name: " <> Text.pack (show name))
                    DoNotRetry
                )
            )
    | name == "default" =
        Left
            ( Conflict
                ( ConflictDetail
                    "colima profile identity"
                    "a project-specific profile"
                    "default"
                    "the shared default Colima profile is never project authority"
                )
            )
    | otherwise = Right name
  where
    name = Text.unpack projectName

deriveColimaNames :: Text.Text -> Text.Text -> Text.Text -> Text.Text -> FilePath -> Either ReconcileError (String, String)
deriveColimaNames projectName lifecycleProfile resourceKey resourceFrame stateRoot = do
    _ <- validateProfileName projectName
    case lifecycleProfile of
        "production" -> Right derived
        profile ->
            case Text.stripPrefix "harness:" profile of
                Just runKey
                    | validHarnessRunKey runKey ->
                        Right derived
                    | otherwise -> invalid "the admitted Harness profile carries an invalid run key"
                Nothing -> invalid "the admitted plan carries an unknown lifecycle profile"
  where
    -- The 128-bit home key is the profile-global authority namespace.  The
    -- short profile is local to that isolated home, keeping Lima's Darwin
    -- socket path below 104 bytes without weakening the home/lock identity.
    digest =
        Text.unpack
            ( hexDigestOfText
                ( Text.intercalate
                    "\NUL"
                    [ "direct-colima-provider-namespace-v1"
                    , projectName
                    , lifecycleProfile
                    , resourceKey
                    , resourceFrame
                    , Text.pack stateRoot
                    ]
                )
            )
    derived = ("h-" ++ take 6 (drop 32 digest), take 32 digest)
    validHarnessRunKey runKey =
        not (Text.null runKey)
            && Text.length runKey <= 48
            && Text.all (\character -> isAlphaNum character || character == '-') runKey
    invalid detail =
        Left
            ( Failure
                ( FailureDetail
                    "derive Colima profile"
                    detail
                    DoNotRetry
                )
            )

hexDigestOfText :: Text.Text -> Text.Text
hexDigestOfText = sha256Hex . Text.Encoding.encodeUtf8

validProfileName :: String -> Bool
validProfileName [] = False
validProfileName (initial : rest) =
    validInitial initial
        && all validRest rest
        && length (initial : rest) <= 63
  where
    validInitial char = isAsciiLower char || isDigit char
    validRest char = validInitial char || char `elem` ("._-" :: String)

colimaHomePath :: FilePath -> String -> FilePath
colimaHomePath home namespaceKey = home </> (".h" ++ namespaceKey)
