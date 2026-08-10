{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Safe public vocabulary for project authority.

This facade exposes closed descriptive vocabularies and abstract capabilities.
Their protected constructors and reservation machinery live in the unexposed
"HostBootstrap.Authority.Kernel" module and are composed only by the lifecycle
modules that possess the remaining evidence.
-}
module HostBootstrap.Authority (
    VerbUp,
    VerbDown,
    VerbDestroy,
    ProjectVerb (..),
    projectVerbName,
    SomeProjectVerb (..),
    parseProjectVerb,
    PreparePhase,
    ExecutePhase,
    TeardownPhase,
    LifecyclePhase (..),
    lifecyclePhaseName,
    InstalledProjectIdentity,
    withInstalledProjectIdentity,
    normalizeExecutableIdentity,
    installedProjectName,
    VerifiedOsPrincipal,
    verifyOsPrincipal,
    BrokerEpoch,
    brokerEpochWord,
    RootInvocationAuthority,
    RootScopeAuthority,
    rootScopeAuthority,
    rootAuthorityVerb,
    rootAuthorityEpoch,
    rootAuthorityProjectName,
    CommandAuthority,
    commandAuthorityVerb,
    commandAuthorityPhase,
    commandAuthorityFrame,
    commandAuthorityEpoch,
    commandAuthorityInvocation,
    commandAuthorityMatchesStore,
    InvocationId,
    invocationIdText,
    AuthorityError (..),
    authorityErrorMessage,
) where

import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Authority.Kernel (
    AuthorityError (..),
    BrokerEpoch,
    CommandAuthority,
    ExecutePhase,
    InstalledProjectIdentity,
    InvocationId,
    LifecyclePhase (..),
    PreparePhase,
    ProjectVerb (..),
    RootInvocationAuthority,
    RootScopeAuthority,
    SomeProjectVerb (..),
    TeardownPhase,
    VerbDestroy,
    VerbDown,
    VerbUp,
    VerifiedOsPrincipal,
    authorityErrorMessage,
    brokerEpochWord,
    commandAuthorityEpoch,
    commandAuthorityFrame,
    commandAuthorityInvocation,
    commandAuthorityMatchesStore,
    commandAuthorityPhase,
    commandAuthorityVerb,
    installedProjectName,
    invocationIdText,
    lifecyclePhaseName,
    parseProjectVerb,
    projectVerbName,
    rootAuthorityEpoch,
    rootAuthorityProjectName,
    rootAuthorityVerb,
    rootScopeAuthority,
    verifyOsPrincipal,
    withInstalledProjectKernel,
 )
import System.Environment (getExecutablePath)
import System.FilePath (takeFileName)

{- | Open the installed identity only when the declared project name agrees
with the invoked executable basename.  A trailing @.exe@ is ignored
case-insensitively; the project name itself remains case-sensitive.
-}
withInstalledProjectIdentity ::
    Text ->
    (forall projectId. InstalledProjectIdentity projectId -> IO result) ->
    IO (Either AuthorityError result)
withInstalledProjectIdentity declared use = do
    invoked <- normalizeExecutableIdentity <$> getExecutablePath
    case
        withInstalledProjectKernel declared $ \project ->
            if installedProjectName project /= invoked
                then
                    pure
                        ( Left
                            ( AuthorityInvalidIdentity
                                ( "the declared project name "
                                    <> installedProjectName project
                                    <> " does not match the invoked executable "
                                    <> invoked
                                )
                            )
                        )
                else Right <$> use project
        of
        Left failure -> pure (Left failure)
        Right action -> action

-- | Normalize the executable pathname used by installed-identity admission.
normalizeExecutableIdentity :: FilePath -> Text
normalizeExecutableIdentity raw =
    let basename = Text.pack (takeFileName raw)
     in if ".exe" `Text.isSuffixOf` Text.toCaseFold basename
            then Text.dropEnd 4 basename
            else basename
