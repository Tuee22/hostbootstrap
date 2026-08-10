{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private authority representations and protected-store kernels.

This module is deliberately not exposed by the Cabal library.  Public callers
receive only the abstract facade in "HostBootstrap.Authority"; higher lifecycle
modules combine their own typed evidence before invoking these kernels.
-}
module HostBootstrap.Authority.Kernel (
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
    withInstalledProjectKernel,
    installedProjectName,
    VerifiedOsPrincipal,
    verifyOsPrincipal,
    BrokerEpoch,
    brokerEpochWord,
    withFreshBrokerEpochKernel,
    withReifiedAllocatedBrokerEpochKernel,
    RootScopeWitness (..),
    RootInvocationAuthority,
    RootScopeAuthority,
    withVerifiedRootInvocationKernel,
    withExistingVerifiedRootInvocationKernel,
    rootScopeAuthority,
    rootScopeProjectName,
    rootScopeStoreIdentity,
    rootScopeEpochWord,
    rootAuthorityVerb,
    rootAuthorityEpoch,
    rootAuthorityProjectName,
    rootAuthorityStoreIdentity,
    ProductionCloseRoot,
    destroyCloseRoot,
    preEffectCloseRoot,
    productionCloseRootVerb,
    ProductionCloseKind (..),
    CommandAuthority,
    commandAuthorityVerb,
    commandAuthorityPhase,
    commandAuthorityFrame,
    commandAuthorityEpoch,
    commandAuthorityInvocation,
    commandAuthorityMatchesStore,
    commandAuthorityOriginMatchesKernel,
    InvocationId,
    invocationIdText,
    CommandReservation,
    commandReservationKernel,
    childCommandReservationKernel,
    reserveCommandInvocationKernel,
    AuthorityError (..),
    authorityErrorMessage,
) where

import qualified Crypto.Hash as Hash
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Char (isAlphaNum, isAscii)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.ProjectScope (Harness, Production)
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    protectedErrorMessage,
    protectedStoreIdentity,
    protectedStoreIdentityText,
    readProtectedRecord,
    recordVersionWord,
    sessionStoreIdentity,
    verifyProtectedStoreWritable,
 )

data VerbUp

data VerbDown

data VerbDestroy

data ProjectVerb verb where
    ProjectUp :: ProjectVerb VerbUp
    ProjectDown :: ProjectVerb VerbDown
    ProjectDestroy :: ProjectVerb VerbDestroy

instance Show (ProjectVerb verb) where
    show = Text.unpack . projectVerbName

instance Eq (ProjectVerb verb) where
    _ == _ = True

projectVerbName :: ProjectVerb verb -> Text
projectVerbName ProjectUp = "up"
projectVerbName ProjectDown = "down"
projectVerbName ProjectDestroy = "destroy"

data SomeProjectVerb = forall verb. SomeProjectVerb (ProjectVerb verb)

instance Show SomeProjectVerb where
    show (SomeProjectVerb verb) = show verb

parseProjectVerb :: Text -> Either AuthorityError SomeProjectVerb
parseProjectVerb raw = case raw of
    "up" -> Right (SomeProjectVerb ProjectUp)
    "down" -> Right (SomeProjectVerb ProjectDown)
    "destroy" -> Right (SomeProjectVerb ProjectDestroy)
    _ -> Left (AuthorityUnknownVerb raw)

data PreparePhase

data ExecutePhase

data TeardownPhase

data LifecyclePhase phase where
    Prepare :: LifecyclePhase PreparePhase
    Execute :: LifecyclePhase ExecutePhase
    Teardown :: LifecyclePhase TeardownPhase

instance Show (LifecyclePhase phase) where
    show = Text.unpack . lifecyclePhaseName

lifecyclePhaseName :: LifecyclePhase phase -> Text
lifecyclePhaseName Prepare = "prepare"
lifecyclePhaseName Execute = "execute"
lifecyclePhaseName Teardown = "teardown"

type role InstalledProjectIdentity nominal
newtype InstalledProjectIdentity projectId = InstalledProjectIdentity Text

instance Show (InstalledProjectIdentity projectId) where
    show (InstalledProjectIdentity name) = "InstalledProjectIdentity " <> show name

installedProjectName :: InstalledProjectIdentity projectId -> Text
installedProjectName (InstalledProjectIdentity name) = name

withInstalledProjectKernel ::
    Text ->
    (forall projectId. InstalledProjectIdentity projectId -> result) ->
    Either AuthorityError result
withInstalledProjectKernel raw use
    | Text.null raw = Left (AuthorityInvalidIdentity "the installed project name must not be empty")
    | Text.length raw > 64 =
        Left (AuthorityInvalidIdentity "the installed project name must be at most 64 characters")
    | not (Text.all legal raw) =
        Left
            ( AuthorityInvalidIdentity
                ("the installed project name may contain only alphanumerics, '-', and '_': " <> raw)
            )
    | otherwise = Right (use (InstalledProjectIdentity raw))
  where
    legal character =
        isAscii character
            && (isAlphaNum character || character `elem` ("-_" :: String))

newtype VerifiedOsPrincipal = VerifiedOsPrincipal Text

instance Show VerifiedOsPrincipal where
    show (VerifiedOsPrincipal store) = "VerifiedOsPrincipal " <> show store

verifyOsPrincipal ::
    ProtectedSession session ->
    IO (Either AuthorityError VerifiedOsPrincipal)
verifyOsPrincipal session = do
    outcome <- verifyProtectedStoreWritable session
    pure $ case outcome of
        Left failure -> Left (AuthorityOperatorRefused (protectedErrorMessage failure))
        Right () ->
            Right
                ( VerifiedOsPrincipal
                    (protectedStoreIdentityText (sessionStoreIdentity session))
                )

type role BrokerEpoch nominal
data BrokerEpoch brokerGeneration = BrokerEpoch Text Text Word64
    deriving (Eq, Ord)

instance Show (BrokerEpoch brokerGeneration) where
    show (BrokerEpoch _project _store value) = "BrokerEpoch " <> show value

brokerEpochWord :: BrokerEpoch brokerGeneration -> Word64
brokerEpochWord (BrokerEpoch _project _store value) = value

withFreshBrokerEpochKernel ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    ( forall brokerGeneration.
      BrokerEpoch brokerGeneration ->
      IO (Either AuthorityError result)
    ) ->
    IO (Either AuthorityError result)
withFreshBrokerEpochKernel session project use =
    case brokerCounterKey project of
        Left failure -> pure (Left failure)
        Right recordKey -> do
            observed <- readProtectedRecord session recordKey
            case observed of
                Left failure -> pure (Left (AuthorityStoreFailure failure))
                Right current -> do
                    case nextCounter current of
                        Left failure -> pure (Left failure)
                        Right next -> do
                            let expectation =
                                    maybe ExpectAbsent (ExpectVersion . protectedRecordVersion) current
                            written <-
                                compareAndSwapProtectedRecord
                                    session
                                    recordKey
                                    expectation
                                    (encodeCounter next)
                            case written of
                                Left failure -> pure (Left (AuthorityStoreFailure failure))
                                Right _ ->
                                    use
                                        ( BrokerEpoch
                                            (installedProjectName project)
                                            (protectedStoreIdentityText (sessionStoreIdentity session))
                                            next
                                        )

{- | Reify one already-recorded, nonzero broker generation without advancing
the protected allocation counter.

Recovery may reopen only the exact currently allocated generation; either an
older or a future recorded value is durable broker drift.  The fresh phantom
exists only inside the continuation and retains the exact project/store origin
observed from this protected session.
-}
withReifiedAllocatedBrokerEpochKernel ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    Word64 ->
    ( forall brokerGeneration.
      BrokerEpoch brokerGeneration ->
      IO (Either AuthorityError result)
    ) ->
    IO (Either AuthorityError result)
withReifiedAllocatedBrokerEpochKernel session project recorded use
    | recorded == 0 =
        pure (Left (AuthorityInvalidIdentity "a recorded broker generation must be positive"))
    | otherwise =
        case brokerCounterKey project of
            Left failure -> pure (Left failure)
            Right recordKey -> do
                observed <- readProtectedRecord session recordKey
                case observed of
                    Left failure -> pure (Left (AuthorityStoreFailure failure))
                    Right Nothing ->
                        pure
                            ( Left
                                ( AuthorityInvalidIdentity
                                    "the recorded broker generation has no allocation counter"
                                )
                            )
                    Right (Just record) ->
                        case decodeCounter (protectedRecordBytes record) of
                            Left failure -> pure (Left failure)
                            Right allocated
                                | recorded /= allocated ->
                                    pure
                                        ( Left
                                            ( AuthorityInvalidIdentity
                                                "the recorded broker generation does not match the allocated counter"
                                            )
                                        )
                                | otherwise ->
                                    use
                                        ( BrokerEpoch
                                            (installedProjectName project)
                                            (protectedStoreIdentityText (sessionStoreIdentity session))
                                            recorded
                                        )

nextCounter :: Maybe ProtectedRecord -> Either AuthorityError Word64
nextCounter Nothing = Right 1
nextCounter (Just record) = do
    current <- decodeCounter (protectedRecordBytes record)
    if current == maxBound
        then Left (AuthorityInvalidIdentity "the broker generation counter is exhausted")
        else Right (current + 1)

decodeCounter :: ByteString -> Either AuthorityError Word64
decodeCounter raw =
    case ByteStringChar8.readInteger raw of
        Just (value, remainder)
            | (ByteStringChar8.null remainder || remainder == "\n")
                && value > 0
                && value <= toInteger (maxBound :: Word64) ->
                Right (fromInteger value)
        _ -> Left (AuthorityInvalidIdentity "the broker generation counter is malformed")

encodeCounter :: Word64 -> ByteString
encodeCounter = ByteStringChar8.pack . show

data RootScopeWitness projectId scope where
    ProductionRootScope :: RootScopeWitness projectId (Production projectId)
    HarnessRootScope :: RootScopeWitness projectId (Harness projectId runId)

type role RootInvocationAuthority nominal nominal nominal
data RootInvocationAuthority scope brokerGeneration verb
    = RootInvocationAuthority
        Text
        Text
        (BrokerEpoch brokerGeneration)
        (ProjectVerb verb)

instance Show (RootInvocationAuthority scope brokerGeneration verb) where
    show (RootInvocationAuthority project _store epoch verb) =
        "RootInvocationAuthority "
            <> show project
            <> " "
            <> show epoch
            <> " "
            <> show verb

type role RootScopeAuthority nominal
data RootScopeAuthority scope = RootScopeAuthority Text Text Word64

rootScopeAuthority ::
    RootInvocationAuthority scope brokerGeneration verb ->
    RootScopeAuthority scope
rootScopeAuthority (RootInvocationAuthority project storeIdentity epoch _) =
    RootScopeAuthority project storeIdentity (brokerEpochWord epoch)

-- | Package-private runtime projection used by the lifecycle-mode kernel.
-- Public callers receive only the opaque scope authority through the facade.
rootScopeProjectName :: RootScopeAuthority scope -> Text
rootScopeProjectName (RootScopeAuthority project _ _) = project

-- | The exact durable protected-store identity that minted this scope.
rootScopeStoreIdentity :: RootScopeAuthority scope -> Text
rootScopeStoreIdentity (RootScopeAuthority _ storeIdentity _) = storeIdentity

-- | The broker epoch observed by the originating root invocation.
rootScopeEpochWord :: RootScopeAuthority scope -> Word64
rootScopeEpochWord (RootScopeAuthority _ _ epoch) = epoch

rootAuthorityVerb :: RootInvocationAuthority scope brokerGeneration verb -> ProjectVerb verb
rootAuthorityVerb (RootInvocationAuthority _ _ _ verb) = verb

rootAuthorityEpoch ::
    RootInvocationAuthority scope brokerGeneration verb ->
    BrokerEpoch brokerGeneration
rootAuthorityEpoch (RootInvocationAuthority _ _ epoch _) = epoch

rootAuthorityProjectName :: RootInvocationAuthority scope brokerGeneration verb -> Text
rootAuthorityProjectName (RootInvocationAuthority project _ _ _) = project

rootAuthorityStoreIdentity :: RootInvocationAuthority scope brokerGeneration verb -> Text
rootAuthorityStoreIdentity (RootInvocationAuthority _ storeIdentity _ _) = storeIdentity

withVerifiedRootInvocationKernel ::
    RootScopeWitness projectId scope ->
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    VerifiedOsPrincipal ->
    BrokerEpoch brokerGeneration ->
    ProjectVerb verb ->
    ( RootInvocationAuthority scope brokerGeneration verb ->
      IO (Either AuthorityError result)
    ) ->
    IO (Either AuthorityError result)
withVerifiedRootInvocationKernel _ session project principal epoch verb use
    | not (principalMatchesStore session principal) =
        pure
            ( Left
                ( AuthorityOperatorRefused
                    "the operator authorization was issued for a different protected store"
                )
            )
    | not (epochMatches session project epoch) =
        pure
            ( Left
                ( AuthorityEpochOriginMismatch
                    (installedProjectName project)
                    (protectedStoreIdentityText (sessionStoreIdentity session))
                )
            )
    | otherwise = case authorityBindingKey of
        Left failure -> pure (Left failure)
        Right recordKey -> do
            observed <- readProtectedRecord session recordKey
            case observed of
                Left failure -> pure (Left (AuthorityStoreFailure failure))
                Right (Just record) ->
                    case decodeText (protectedRecordBytes record) of
                        Left failure -> pure (Left failure)
                        Right recordedProject
                            | recordedProject /= installedProjectName project ->
                                pure
                                    ( Left
                                        ( AuthorityStoreNotOurs
                                            (installedProjectName project)
                                            recordedProject
                                        )
                                    )
                            | otherwise -> mint
                Right Nothing -> do
                    written <-
                        compareAndSwapProtectedRecord
                            session
                            recordKey
                            ExpectAbsent
                            (encodeText (installedProjectName project))
                    case written of
                        Left failure -> pure (Left (AuthorityStoreFailure failure))
                        Right _ -> mint
  where
    mint =
        use
            ( RootInvocationAuthority
                (installedProjectName project)
                (protectedStoreIdentityText (sessionStoreIdentity session))
                epoch
                verb
            )

{- | Read-only counterpart to 'withVerifiedRootInvocationKernel' for recovery.

The durable authority binding must already exist and match the installed
project.  Unlike fresh admission, this helper never creates a missing binding.
-}
withExistingVerifiedRootInvocationKernel ::
    RootScopeWitness projectId scope ->
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    VerifiedOsPrincipal ->
    BrokerEpoch brokerGeneration ->
    ProjectVerb verb ->
    ( RootInvocationAuthority scope brokerGeneration verb ->
      IO (Either AuthorityError result)
    ) ->
    IO (Either AuthorityError result)
withExistingVerifiedRootInvocationKernel _ session project principal epoch verb use
    | not (principalMatchesStore session principal) =
        pure
            ( Left
                ( AuthorityOperatorRefused
                    "the operator authorization was issued for a different protected store"
                )
            )
    | not (epochMatches session project epoch) =
        pure
            ( Left
                ( AuthorityEpochOriginMismatch
                    (installedProjectName project)
                    (protectedStoreIdentityText (sessionStoreIdentity session))
                )
            )
    | otherwise = case authorityBindingKey of
        Left failure -> pure (Left failure)
        Right recordKey -> do
            observed <- readProtectedRecord session recordKey
            case observed of
                Left failure -> pure (Left (AuthorityStoreFailure failure))
                Right Nothing ->
                    pure
                        ( Left
                            ( AuthorityMalformedBinding
                                "the existing protected authority binding is missing"
                            )
                        )
                Right (Just record) ->
                    case decodeText (protectedRecordBytes record) of
                        Left failure -> pure (Left failure)
                        Right recordedProject
                            | recordedProject /= installedProjectName project ->
                                pure
                                    ( Left
                                        ( AuthorityStoreNotOurs
                                            (installedProjectName project)
                                            recordedProject
                                        )
                                    )
                            | otherwise ->
                                use
                                    ( RootInvocationAuthority
                                        (installedProjectName project)
                                        (protectedStoreIdentityText (sessionStoreIdentity session))
                                        epoch
                                        verb
                                    )

principalMatchesStore :: ProtectedSession session -> VerifiedOsPrincipal -> Bool
principalMatchesStore session (VerifiedOsPrincipal storeIdentity) =
    storeIdentity == protectedStoreIdentityText (sessionStoreIdentity session)

epochMatches ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    BrokerEpoch brokerGeneration ->
    Bool
epochMatches session project (BrokerEpoch epochProject epochStore _value) =
    epochProject == installedProjectName project
        && epochStore == protectedStoreIdentityText (sessionStoreIdentity session)

data ProductionCloseKind
    = SettledDestroyClose
    | PreEffectRefusalClose
    deriving (Eq, Show)

type role ProductionCloseRoot nominal nominal
data ProductionCloseRoot scope brokerGeneration
    = ProductionCloseRoot ProductionCloseKind Text Text (BrokerEpoch brokerGeneration)

instance Show (ProductionCloseRoot scope brokerGeneration) where
    show (ProductionCloseRoot kind project _store epoch) =
        "ProductionCloseRoot " <> show kind <> " " <> show project <> " " <> show epoch

productionCloseRootVerb :: ProductionCloseRoot scope brokerGeneration -> ProductionCloseKind
productionCloseRootVerb (ProductionCloseRoot kind _ _ _) = kind

destroyCloseRoot ::
    RootInvocationAuthority scope brokerGeneration VerbDestroy ->
    ProductionCloseRoot scope brokerGeneration
destroyCloseRoot (RootInvocationAuthority project store epoch _) =
    ProductionCloseRoot SettledDestroyClose project store epoch

preEffectCloseRoot ::
    RootInvocationAuthority scope brokerGeneration verb ->
    ProductionCloseRoot scope brokerGeneration
preEffectCloseRoot (RootInvocationAuthority project store epoch _) =
    ProductionCloseRoot PreEffectRefusalClose project store epoch

newtype InvocationId = InvocationId Text
    deriving (Eq, Ord)

instance Show InvocationId where
    show (InvocationId value) = "InvocationId " <> show value

invocationIdText :: InvocationId -> Text
invocationIdText (InvocationId value) = value

type role CommandAuthority nominal nominal nominal nominal nominal nominal
data CommandAuthority scope planId frame brokerGeneration verb phase
    = CommandAuthority
        InvocationId
        Text
        (BrokerEpoch brokerGeneration)
        (ProjectVerb verb)
        (LifecyclePhase phase)

instance Show (CommandAuthority scope planId frame brokerGeneration verb phase) where
    show (CommandAuthority invocation frameName epoch verb phase) =
        "CommandAuthority "
            <> show invocation
            <> " "
            <> show frameName
            <> " "
            <> show epoch
            <> " "
            <> show verb
            <> " "
            <> show phase

commandAuthorityInvocation ::
    CommandAuthority scope planId frame brokerGeneration verb phase -> InvocationId
commandAuthorityInvocation (CommandAuthority invocation _ _ _ _) = invocation

commandAuthorityFrame ::
    CommandAuthority scope planId frame brokerGeneration verb phase -> Text
commandAuthorityFrame (CommandAuthority _ frameName _ _ _) = frameName

commandAuthorityEpoch ::
    CommandAuthority scope planId frame brokerGeneration verb phase ->
    BrokerEpoch brokerGeneration
commandAuthorityEpoch (CommandAuthority _ _ epoch _ _) = epoch

{- | Check that a command authority's retained broker epoch originated in the
supplied protected store.

The broker-generation phantom relates authority and cursor evidence, but a
'ProtectedStore' is intentionally not indexed.  An effectful boundary that
accepts a store separately must therefore perform this retained-origin check
before opening any record in it.
-}
commandAuthorityMatchesStore ::
    CommandAuthority scope planId frame brokerGeneration verb phase ->
    ProtectedStore ->
    Bool
commandAuthorityMatchesStore
    (CommandAuthority _ _ (BrokerEpoch _ epochStore _) _ _)
    store =
        epochStore
            == protectedStoreIdentityText (protectedStoreIdentity store)

-- | Package-private complete retained-origin comparison for composite gates.
commandAuthorityOriginMatchesKernel ::
    CommandAuthority scope planId frame brokerGeneration verb phase ->
    Text ->
    Text ->
    Word64 ->
    Bool
commandAuthorityOriginMatchesKernel
    (CommandAuthority _ _ (BrokerEpoch epochProject epochStore epochWord) _ _)
    project
    store
    generation =
        epochProject == project
            && epochStore == store
            && epochWord == generation

commandAuthorityVerb ::
    CommandAuthority scope planId frame brokerGeneration verb phase -> ProjectVerb verb
commandAuthorityVerb (CommandAuthority _ _ _ verb _) = verb

commandAuthorityPhase ::
    CommandAuthority scope planId frame brokerGeneration verb phase -> LifecyclePhase phase
commandAuthorityPhase (CommandAuthority _ _ _ _ phase) = phase

type role CommandReservation nominal nominal nominal nominal nominal nominal
data CommandReservation scope planId frame brokerGeneration verb phase
    = CommandReservation
        Text
        Text
        Text
        Text
        (BrokerEpoch brokerGeneration)
        (ProjectVerb verb)
        (LifecyclePhase phase)

commandReservationKernel ::
    RootInvocationAuthority scope brokerGeneration verb ->
    Text ->
    LifecyclePhase phase ->
    Text ->
    CommandReservation scope planId frame brokerGeneration verb phase
commandReservationKernel root planDigest phase frameName =
    CommandReservation
        (rootAuthorityProjectName root)
        (rootAuthorityStoreIdentity root)
        planDigest
        frameName
        (rootAuthorityEpoch root)
        (rootAuthorityVerb root)
        phase

{- | Package-private reservation constructor for an authenticated child.

Unlike the root constructor this takes retained descriptive origin because a
child deliberately has no 'RootInvocationAuthority'.  Its sole caller first
checks those values against the opaque child-plan authority, exact admitted
plan, acquisition journal, frame, cursor, and context before this reservation
enters protected state.
-}
childCommandReservationKernel ::
    Text ->
    Text ->
    Word64 ->
    ProjectVerb verb ->
    Text ->
    LifecyclePhase phase ->
    Text ->
    CommandReservation scope planId frame brokerGeneration verb phase
childCommandReservationKernel project store generation verb planDigest phase frameName =
    CommandReservation
        project
        store
        planDigest
        frameName
        (BrokerEpoch project store generation)
        verb
        phase

reserveCommandInvocationKernel ::
    ProtectedSession session ->
    InstalledProjectIdentity projectId ->
    CommandReservation scope planId frame brokerGeneration verb phase ->
    ( CommandAuthority scope planId frame brokerGeneration verb phase ->
      IO (Either AuthorityError result)
    ) ->
    IO (Either AuthorityError result)
reserveCommandInvocationKernel
    session
    project
    (CommandReservation rootProject rootStore planDigest frameName epoch verb phase)
    use
        | rootProject /= installedProjectName project =
            pure
                ( Left
                    ( AuthorityStoreNotOurs
                        (installedProjectName project)
                        rootProject
                    )
                )
        | rootStore /= currentStore =
            pure (Left (AuthorityWrongStore rootStore currentStore))
        | otherwise = case invocationKey identity of
            Left failure -> pure (Left failure)
            Right recordKey -> do
                observed <- readProtectedRecord session recordKey
                case observed of
                    Left failure -> pure (Left (AuthorityStoreFailure failure))
                    Right (Just record)
                        | protectedRecordBytes record == identity ->
                            pure (Left (AuthorityInvocationConsumed invocation))
                        | otherwise ->
                            pure (Left (AuthorityReservationConflict invocation))
                    Right Nothing -> do
                        written <-
                            compareAndSwapProtectedRecord
                                session
                                recordKey
                                ExpectAbsent
                                identity
                        case written of
                            Left failure -> pure (Left (AuthorityStoreFailure failure))
                            Right version ->
                                use
                                    ( CommandAuthority
                                        ( InvocationId
                                            ( invocation
                                                <> "#"
                                                <> Text.pack (show (recordVersionWord version))
                                            )
                                        )
                                        frameName
                                        epoch
                                        verb
                                        phase
                                    )
  where
    currentStore = protectedStoreIdentityText (sessionStoreIdentity session)
    identity =
        reservationIdentity
            rootProject
            rootStore
            planDigest
            frameName
            epoch
            verb
            phase
    invocation = "command-" <> sha256Hex identity

reservationIdentity ::
    Text ->
    Text ->
    Text ->
    Text ->
    BrokerEpoch brokerGeneration ->
    ProjectVerb verb ->
    LifecyclePhase phase ->
    ByteString
reservationIdentity project storeIdentity planDigest frameName epoch verb phase =
    ByteStringChar8.concat
        [ field (TextEncoding.encodeUtf8 project)
        , field (TextEncoding.encodeUtf8 storeIdentity)
        , field (TextEncoding.encodeUtf8 planDigest)
        , field (TextEncoding.encodeUtf8 frameName)
        , field (ByteStringChar8.pack (show (brokerEpochWord epoch)))
        , field (TextEncoding.encodeUtf8 (projectVerbName verb))
        , field (TextEncoding.encodeUtf8 (lifecyclePhaseName phase))
        ]
  where
    field bytes =
        ByteStringChar8.pack (show (ByteStringChar8.length bytes))
            <> ":"
            <> bytes

brokerCounterKey :: InstalledProjectIdentity projectId -> Either AuthorityError RecordKey
brokerCounterKey project =
    storeKey ("broker." <> installedProjectName project <> ".generation")

authorityBindingKey :: Either AuthorityError RecordKey
authorityBindingKey = storeKey "authority.binding"

invocationKey ::
    ByteString ->
    Either AuthorityError RecordKey
invocationKey identity = storeKey ("invocation." <> sha256Hex identity)

sha256Hex :: ByteString -> Text
sha256Hex bytes =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 bytes)))
  where
    hex byte =
        [ ByteStringChar8.index "0123456789abcdef" (fromIntegral (byte `div` 16))
        , ByteStringChar8.index "0123456789abcdef" (fromIntegral (byte `mod` 16))
        ]

storeKey :: Text -> Either AuthorityError RecordKey
storeKey raw = case mkRecordKey raw of
    Left failure -> Left (AuthorityStoreFailure failure)
    Right key -> Right key

encodeText :: Text -> ByteString
encodeText = TextEncoding.encodeUtf8

decodeText :: ByteString -> Either AuthorityError Text
decodeText raw = case TextEncoding.decodeUtf8' raw of
    Left failure -> Left (AuthorityMalformedBinding (Text.pack (show failure)))
    Right value -> Right value

data AuthorityError
    = AuthorityInvalidIdentity Text
    | AuthorityOperatorRefused Text
    | AuthorityStoreNotOurs Text Text
    | AuthorityWrongStore Text Text
    | AuthorityEpochOriginMismatch Text Text
    | AuthorityMalformedBinding Text
    | AuthorityUnknownFrame Text
    | AuthorityInvocationConsumed Text
    | AuthorityReservationConflict Text
    | AuthorityUnknownVerb Text
    | AuthorityStoreFailure ProtectedError
    deriving (Eq, Show)

authorityErrorMessage :: AuthorityError -> Text
authorityErrorMessage failure = case failure of
    AuthorityInvalidIdentity reason -> reason
    AuthorityOperatorRefused reason -> "operator authorization refused: " <> reason
    AuthorityStoreNotOurs expected observed ->
        "the protected authority store belongs to "
            <> observed
            <> ", not "
            <> expected
    AuthorityWrongStore expected observed ->
        "authority belongs to protected store "
            <> expected
            <> ", not "
            <> observed
    AuthorityEpochOriginMismatch project storeIdentity ->
        "the broker epoch does not belong to project "
            <> project
            <> " in protected store "
            <> storeIdentity
    AuthorityMalformedBinding reason ->
        "the protected authority binding is malformed: " <> reason
    AuthorityUnknownFrame frameName ->
        "frame " <> frameName <> " is not declared by this lifecycle plan"
    AuthorityInvocationConsumed invocation ->
        "invocation " <> invocation <> " has already been consumed"
    AuthorityReservationConflict invocation ->
        "invocation " <> invocation <> " conflicts with an existing reservation"
    AuthorityUnknownVerb raw -> "unknown project verb: " <> raw
    AuthorityStoreFailure inner -> protectedErrorMessage inner
