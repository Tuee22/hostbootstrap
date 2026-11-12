{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Native WSL registration observations.

The production query always reads the current user's fixed WSL namespace.
The borrowed-key reader is a bounded, read-only kernel observation, not a
provider executor or an alternate production query location.
-}
module HostBootstrap.Wsl2.Registration (
    RawWslRegistration (..),
    WslRegistration,
    wslRegistrationIdentity,
    wslRegistrationInstallPath,
    classifyWslRegistration,
    observeWslRegistration,
    readWslRegistrationKey,
) where

import qualified Data.ByteString.Char8 as ByteString
import Data.Char (GeneralCategory (Format, Surrogate), generalCategory, isControl, isHexDigit, toLower)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Foreign.Ptr (Ptr)
import HostBootstrap.Ownership.Object (ObjectIdentity, OwnershipFault (..), mkObjectIdentity)
import qualified System.FilePath.Windows as WindowsPath
#if defined(mingw32_HOST_OS)
import Control.Exception (IOException, bracket, displayException, evaluate, try)
import Control.Monad (forM, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import qualified Data.ByteString as Bytes
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (UnicodeException, strictDecode)
import Foreign.ForeignPtr (newForeignPtr_, withForeignPtr)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (castPtr)
import Foreign.Storable (peek, pokeElemOff)
import System.IO.Error (isDoesNotExistError, isPermissionError)
import qualified System.Win32.Registry as Registry
#endif

-- | Ordinary registry data; constructing it mints no ownership authority.
data RawWslRegistration = RawWslRegistration
    { rawWslIdentifier :: String
    , rawWslName :: String
    , rawWslInstallPath :: FilePath
    , rawWslVersion :: Word32
    } deriving (Eq, Show)

-- | A complete registration admitted by the pure classifier.
data WslRegistration = WslRegistration
    { wslRegistrationIdentity :: ObjectIdentity
    , wslRegistrationInstallPath :: FilePath
    } deriving (Eq, Show)

classifyWslRegistration :: String -> [RawWslRegistration] -> Either OwnershipFault (Maybe WslRegistration)
classifyWslRegistration wanted entries
    | not (registryText 256 wanted) = malformed "the requested WSL name is not bounded, non-empty text"
    | length entries > 1024 = malformed "the WSL registry exceeds 1024 registrations"
    | any (not . registryText 256 . rawWslName) entries = malformed "a WSL registration has an unreadable name"
    | otherwise = case filter sameName entries of
        [] -> Right Nothing
        [entry]
            | rawWslName entry /= wanted -> malformed "a WSL registration differs in case from the requested name"
            | rawWslVersion entry /= 2 -> malformed "the named registration is not a WSL2 distribution"
            | not (registryText 2047 path) || not (WindowsPath.isAbsolute path)
                || any (`elem` [".", ".."]) (WindowsPath.splitDirectories path) ->
                malformed "the WSL install location is not a bounded absolute Windows path"
            | otherwise -> do
                identity <- canonicalIdentity (rawWslIdentifier entry)
                Right (Just (WslRegistration identity path))
          where
            path = rawWslInstallPath entry
        _ -> malformed "multiple WSL registrations match the requested name"
  where
    sameName entry = Text.toCaseFold (Text.pack (rawWslName entry)) == Text.toCaseFold (Text.pack wanted)

canonicalIdentity :: String -> Either OwnershipFault ObjectIdentity
canonicalIdentity raw = case raw of
    '{' : body | length body == 37, last body == '}' ->
        let identifier = init body
            expectedHyphens = [8, 13, 18, 23]
            valid (index, character)
                | index `elem` expectedHyphens = character == '-'
                | otherwise = isHexDigit character && fromEnum character < 128
         in if all valid (zip [0 :: Int ..] identifier)
                then mkObjectIdentity (ByteString.pack (map toLower identifier))
                else malformed "the WSL registration key is not a canonical GUID"
    _ -> malformed "the WSL registration key is not a canonical GUID"

registryText :: Int -> String -> Bool
registryText bound value =
    not (null value) && sum (map units value) <= bound
        && all (\c -> not (isControl c) && generalCategory c `notElem` [Format, Surrogate]) value
  where
    units character = if fromEnum character > 0xffff then 2 else 1

malformed :: Text -> Either OwnershipFault result
malformed = Left . OwnershipMalformed

#if !defined(mingw32_HOST_OS)
unsupportedRegistration :: OwnershipFault
unsupportedRegistration = OwnershipUnsupported "native WSL registration requires Windows"
#endif

-- | Read this user's real registrations; no caller supplies a query root.
observeWslRegistration :: String -> IO (Either OwnershipFault (Maybe WslRegistration))
#if defined(mingw32_HOST_OS)
observeWslRegistration wanted
    | not (registryText 256 wanted) = pure (malformed "the requested WSL name is not bounded, non-empty text")
    | otherwise = do
        opened <- try (Registry.regOpenKeyEx Registry.hKEY_CURRENT_USER
            "Software\\Microsoft\\Windows\\CurrentVersion\\Lxss" Registry.kEY_READ)
        case opened of
            Left failure
                | isDoesNotExistError failure -> pure (Right Nothing)
                | otherwise -> pure (Left (registryFailure "open WSL registrations" failure))
            Right key -> do
                observed <- try (bracket (pure key) Registry.regCloseKey
                    (\held -> withForeignPtr held readWslRegistrationKey))
                pure $ case observed of
                    Left failure -> Left (registryFailure "close WSL registrations" failure)
                    Right entries -> entries >>= classifyWslRegistration wanted
#else
observeWslRegistration _wanted = pure (Left unsupportedRegistration)
#endif

{- | Observe registrations below an already-open native key, borrowing its handle.

The caller keeps the key open throughout this call. This function closes no
handle and writes no value. At most 1024 subkeys and 4096 bytes per string are
admitted. Errors reading children or values never mean an absent registration.
-}
readWslRegistrationKey :: Ptr () -> IO (Either OwnershipFault [RawWslRegistration])
#if defined(mingw32_HOST_OS)
readWslRegistrationKey pointer = runExceptT $ do
    key <- liftIO (newForeignPtr_ pointer)
    names <- registryNames key 0
    forM names $ \name -> do
        outcome <- nativeOperation "read WSL registration" $
            bracket (Registry.regOpenKeyEx key name Registry.kEY_READ) Registry.regCloseKey $ \child ->
                runExceptT (RawWslRegistration name
                    <$> registryString child "DistributionName"
                    <*> registryString child "BasePath"
                    <*> registryVersion child)
        either throwE pure outcome

registryNames :: Registry.HKEY -> Word32 -> ExceptT OwnershipFault IO [String]
registryNames key index = do
    (name, done) <- nativeOperation "enumerate WSL registrations" $
        allocaArray 256 $ \buffer -> do
            -- The SDK decodes this buffer even at ERROR_NO_MORE_ITEMS.
            pokeElemOff buffer 0 0
            Registry.regEnumKey key index buffer 256
    if done /= 0
        then pure []
        else if index == 1024
            then throwE (OwnershipMalformed "the WSL registry exceeds 1024 registrations")
            else (name :) <$> registryNames key (index + 1)

registryString :: Registry.HKEY -> String -> ExceptT OwnershipFault IO String
registryString key field = do
    payload <- nativeOperation "read WSL registration text" $
        allocaBytes 4096 $ \buffer ->
            with (4096 :: Word32) $ \size -> do
                Registry.regGetValue key Nothing (Just field) Registry.rRF_RT_REG_SZ Nothing
                    (Just buffer) (Just size)
                count <- peek size
                if count < 2 || count > 4096 || odd count
                    then pure Nothing
                    else Just <$> Bytes.packCStringLen (castPtr buffer, fromIntegral count)
    bytes <- case payload of
        Just value
            | Bytes.drop (Bytes.length value - 2) value == Bytes.pack [0, 0] ->
                pure (Bytes.take (Bytes.length value - 2) value)
        _ -> throwE (OwnershipMalformed "a WSL registry string has no bounded UTF-16 terminator")
    decoded <- liftIO (try (evaluate (TextEncoding.decodeUtf16LEWith strictDecode bytes))
        :: IO (Either UnicodeException Text))
    case decoded of
        Left _ -> throwE (OwnershipMalformed "a WSL registry string is not valid UTF-16")
        Right text
            | registryText 2047 (Text.unpack text) -> pure (Text.unpack text)
            | otherwise -> throwE (OwnershipMalformed "a WSL registry string contains unreadable text")

registryVersion :: Registry.HKEY -> ExceptT OwnershipFault IO Word32
registryVersion key = do
    (count, version) <- nativeOperation "read WSL registration version" $
        with (0 :: Word32) $ \value ->
            with (4 :: Word32) $ \size -> do
                Registry.regGetValue key Nothing (Just "Version") Registry.rRF_RT_REG_DWORD Nothing
                    (Just (castPtr value)) (Just size)
                (,) <$> peek size <*> peek value
    unless (count == 4) (throwE (OwnershipMalformed "the WSL registration version is not a DWORD"))
    pure version

nativeOperation :: Text -> IO result -> ExceptT OwnershipFault IO result
nativeOperation operation action = ExceptT $ do
    outcome <- try action
    pure (either (Left . registryFailure operation) Right outcome)

registryFailure :: Text -> IOException -> OwnershipFault
registryFailure operation failure
    | isDoesNotExistError failure = OwnershipMalformed "the WSL registration is incomplete"
    | isPermissionError failure = OwnershipProbeFailed operation "the registry key does not permit this observation"
    | otherwise = OwnershipProbeFailed operation
        (Text.take 512 (Text.filter (not . isControl) (Text.pack (displayException failure))))
#else
readWslRegistrationKey _pointer = pure (Left unsupportedRegistration)
#endif
