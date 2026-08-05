{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Root and command authority for the project lifecycle (§ X, § EE).

Context describes requested placement; it never grants permission.  This module
owns the values that do:

* 'ProjectVerb' is a closed, type-indexed verb.  An @up@ grant and a @down@
  grant have different types, so a retained authority cannot authorize the
  other verb — that is a type error rather than a runtime check.
* 'RootInvocationAuthority' is minted only by a non-config gate that verifies
  installed project identity, OS/operator authorization, the protected
  authority-store identity, and the exact verb.  It is *not* a lifecycle
  profile: the test-harness-and-run-ownership phase's mode transaction combines it with the active mode and the
  still-unbound run lease.  That split is what breaks the
  authority/profile/transition bootstrap cycle.
* 'CommandAuthority' carries a hidden one-use invocation identity.  Minting is
  effectful: 'authorizeProjectCommand' atomically reserves that invocation in
  the protected store against the live broker epoch, so replaying a retained
  authority value — or opening a second session for the same
  plan/frame/verb/phase/epoch — fails rather than repeating an effect.

Nothing here can be constructed from decoded 'HostBootstrap.Context' data, a
declared command class, a capability list, a file path, or a Boolean.
-}
module HostBootstrap.Authority (
    -- * Verbs and phases
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

    -- * Installed project identity
    InstalledProject,
    withInstalledProject,
    installedProjectFor,
    installedProjectName,

    -- * OS/operator authorization
    OperatorAuthorization,
    verifyOperatorAuthorization,

    -- * Broker generations
    BrokerEpoch,
    brokerEpochWord,
    withFreshBrokerEpoch,
    withRecordedBrokerEpoch,

    -- * Root invocation authority
    RootInvocationAuthority,
    withVerifiedRootInvocation,
    rootAuthorityVerb,
    rootAuthorityEpoch,
    rootAuthorityProjectName,

    -- * The root/verb side of Production closure
    ProductionCloseRoot,
    destroyCloseRoot,
    preEffectCloseRoot,
    productionCloseRootVerb,
    ProductionCloseKind (..),

    -- * Command authority
    CommandAuthority,
    authorizeProjectCommand,
    commandAuthorityVerb,
    commandAuthorityPhase,
    commandAuthorityFrame,
    commandAuthorityEpoch,
    commandAuthorityInvocation,
    InvocationId,
    invocationIdText,

    -- * Failures
    AuthorityError (..),
    authorityErrorMessage,
) where

import Data.Bits (xor)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Char (isAlphaNum)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    RecordKey,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    protectedErrorMessage,
    protectedStoreIdentityText,
    readProtectedRecord,
    recordVersionWord,
    sessionStoreIdentity,
    sessionStoreRoot,
 )
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Reconcile (LifecyclePlan, lifecyclePlanDigest, lifecyclePlanFrames)
import System.Directory (Permissions (writable), getPermissions)
import System.IO.Error (catchIOError)

-- Verbs and phases -------------------------------------------------------------

-- | The @project up@ verb index.
data VerbUp

-- | The @project down@ verb index.
data VerbDown

-- | The @project destroy@ verb index.
data VerbDestroy

{- | The closed project verb, indexed by its own type. There is deliberately no
@Verb Text@ constructor: a verb cannot be widened, and an authority for one verb
does not typecheck where another is required.
-}
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

-- | A verb whose index has been hidden, for parsing an operator's argument.
data SomeProjectVerb = forall verb. SomeProjectVerb (ProjectVerb verb)

instance Show SomeProjectVerb where
    show (SomeProjectVerb verb) = show verb

parseProjectVerb :: Text -> Either AuthorityError SomeProjectVerb
parseProjectVerb raw = case raw of
    "up" -> Right (SomeProjectVerb ProjectUp)
    "down" -> Right (SomeProjectVerb ProjectDown)
    "destroy" -> Right (SomeProjectVerb ProjectDestroy)
    _ -> Left (AuthorityUnknownVerb raw)

-- | The phase before any effect: the plan is being opened and validated.
data PreparePhase

-- | The phase in which the interpreter may prepare and run effects.
data ExecutePhase

-- | The reverse-projection phase.
data TeardownPhase

-- | The closed lifecycle phase, indexed like the verb.
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

-- Installed project identity ------------------------------------------------------

{- | The identity of the project this binary *is*. It is generative: the
@projectId@ index is bound by 'withInstalledProject', so two installed projects
cannot exchange authority even when their names round-trip through text.
-}
newtype InstalledProject projectId = InstalledProject Text

instance Show (InstalledProject projectId) where
    show (InstalledProject name) = "InstalledProject " <> show name

installedProjectName :: InstalledProject projectId -> Text
installedProjectName (InstalledProject name) = name

{- | Open the type identity of the installed project. The name is validated
here so every later record key derived from it is well formed.
-}
withInstalledProject ::
    Text ->
    (forall projectId. InstalledProject projectId -> result) ->
    Either AuthorityError result
withInstalledProject raw use
    | Text.null raw = Left (AuthorityInvalidIdentity "the installed project name must not be empty")
    | Text.length raw > 64 =
        Left (AuthorityInvalidIdentity "the installed project name must be at most 64 characters")
    | not (Text.all legal raw) =
        Left
            ( AuthorityInvalidIdentity
                ("the installed project name may contain only alphanumerics, '-', and '_': " <> raw)
            )
    | otherwise = Right (use (InstalledProject raw))
  where
    legal character = isAlphaNum character || character `elem` ("-_" :: String)

{- | The installed identity of a project whose config family the binary already
carries. This is the production opener: @projectId@ is the project's own index —
the one its 'ProjectCfg' instance and scoped codecs use — so a root authority, a
plan, and a config cannot be mixed across projects. 'withInstalledProject' is
the generative peer for a binary with no installed config family.
-}
installedProjectFor ::
    forall projectId cfg.
    (ProjectCfg projectId cfg) =>
    Text ->
    Either AuthorityError (InstalledProject projectId)
installedProjectFor raw =
    withProductionProjectCodec @projectId @cfg (\_installedCodec -> withInstalledProject raw asFixed)
  where
    asFixed :: forall anyId. InstalledProject anyId -> InstalledProject projectId
    asFixed = InstalledProject . installedProjectName

-- OS/operator authorization ---------------------------------------------------------

{- | Evidence that the operating system permits this process to act as the
project's operator.

Stated exactly, this verifies that the current OS principal can write the
protected authority store — the store the lifecycle's mode, lease, journal, and
invocation records live in. It does not attempt to prove a hostile
same-privilege process is absent; § EE explicitly does not claim that exclusion.
-}
data OperatorAuthorization = OperatorAuthorization Text

instance Show OperatorAuthorization where
    show (OperatorAuthorization store) = "OperatorAuthorization " <> show store

verifyOperatorAuthorization ::
    ProtectedSession session ->
    IO (Either AuthorityError OperatorAuthorization)
verifyOperatorAuthorization session = do
    outcome <-
        catchIOError
            (Right . writable <$> getPermissions (sessionStoreRoot session))
            (pure . Left . Text.pack . show)
    pure $ case outcome of
        Left reason -> Left (AuthorityOperatorRefused reason)
        Right False ->
            Left
                ( AuthorityOperatorRefused
                    "the current OS principal cannot write the protected authority store"
                )
        Right True ->
            Right
                ( OperatorAuthorization
                    (protectedStoreIdentityText (sessionStoreIdentity session))
                )

-- Broker generations -----------------------------------------------------------------

{- | One broker generation. The @brokerGeneration@ index is generative, so a
root authority, a lease, and a command authority can only be used together when
they were all minted under the same generation.
-}
newtype BrokerEpoch brokerGeneration = BrokerEpoch Word64
    deriving (Eq, Ord)

instance Show (BrokerEpoch brokerGeneration) where
    show (BrokerEpoch value) = "BrokerEpoch " <> show value

brokerEpochWord :: BrokerEpoch brokerGeneration -> Word64
brokerEpochWord (BrokerEpoch value) = value

{- | Allocate the next broker generation under the store's exclusive entry. The
counter is a protected record, so a generation is never reused across processes
and a crashed run's generation cannot be re-minted.
-}
withFreshBrokerEpoch ::
    ProtectedSession session ->
    InstalledProject projectId ->
    ( forall brokerGeneration.
      BrokerEpoch brokerGeneration ->
      IO (Either AuthorityError result)
    ) ->
    IO (Either AuthorityError result)
withFreshBrokerEpoch session project use =
    case brokerCounterKey project of
        Left failure -> pure (Left failure)
        Right recordKey -> do
            observed <- readProtectedRecord session recordKey
            case observed of
                Left failure -> pure (Left (AuthorityStoreFailure failure))
                Right current -> do
                    let expectation = maybe ExpectAbsent (ExpectVersion . protectedRecordVersion) current
                        next = maybe 1 ((+ 1) . decodeCounter . protectedRecordBytes) current
                    written <-
                        compareAndSwapProtectedRecord
                            session
                            recordKey
                            expectation
                            (encodeCounter next)
                    case written of
                        Left failure -> pure (Left (AuthorityStoreFailure failure))
                        Right _ -> use (BrokerEpoch next)

{- | Re-open the type identity of a generation that a durable record already
names, for recovery paths that must resume a specific generation rather than
allocate a new one.
-}
withRecordedBrokerEpoch ::
    Word64 ->
    ( forall brokerGeneration.
      BrokerEpoch brokerGeneration ->
      IO (Either AuthorityError result)
    ) ->
    IO (Either AuthorityError result)
withRecordedBrokerEpoch value use
    | value == 0 =
        pure
            ( Left
                (AuthorityInvalidIdentity "a recorded broker generation must be strictly positive")
            )
    | otherwise = use (BrokerEpoch value)

decodeCounter :: ByteString -> Word64
decodeCounter raw = case ByteStringChar8.readInt (ByteStringChar8.takeWhile (/= '\n') raw) of
    Just (value, _) | value >= 0 -> fromIntegral value
    _ -> 0

encodeCounter :: Word64 -> ByteString
encodeCounter = ByteStringChar8.pack . show

-- Root invocation authority ------------------------------------------------------------

{- | The independently established right to run one exact verb as the project's
root, under one broker generation. It authorizes nothing by itself: it is an
input to the test-harness-and-run-ownership phase's profile transaction and to 'authorizeProjectCommand'.
-}
data RootInvocationAuthority scope brokerGeneration verb
    = RootInvocationAuthority Text (BrokerEpoch brokerGeneration) (ProjectVerb verb)

instance Show (RootInvocationAuthority scope brokerGeneration verb) where
    show (RootInvocationAuthority project epoch verb) =
        "RootInvocationAuthority "
            <> show project
            <> " "
            <> show epoch
            <> " "
            <> show verb

rootAuthorityVerb :: RootInvocationAuthority scope brokerGeneration verb -> ProjectVerb verb
rootAuthorityVerb (RootInvocationAuthority _ _ verb) = verb

rootAuthorityEpoch ::
    RootInvocationAuthority scope brokerGeneration verb ->
    BrokerEpoch brokerGeneration
rootAuthorityEpoch (RootInvocationAuthority _ epoch _) = epoch

rootAuthorityProjectName :: RootInvocationAuthority scope brokerGeneration verb -> Text
rootAuthorityProjectName (RootInvocationAuthority project _ _) = project

{- | The non-config root gate. It verifies, in this order:

1. the installed project identity (the caller's generative @projectId@);
2. OS/operator authorization for the protected store;
3. the protected authority-store identity — the store's durable binding record
   must already name this project, or be established for it on first use, so a
   store belonging to another project cannot authorize this one;
4. the exact verb, which is fixed by the 'ProjectVerb' index and cannot widen.

It reads no @\<project\>.dhall@, so a decoded context cannot influence it, and it
mints no lifecycle profile.
-}
withVerifiedRootInvocation ::
    ProtectedSession session ->
    InstalledProject projectId ->
    OperatorAuthorization ->
    BrokerEpoch brokerGeneration ->
    ProjectVerb verb ->
    ( RootInvocationAuthority scope brokerGeneration verb ->
      IO (Either AuthorityError result)
    ) ->
    IO (Either AuthorityError result)
withVerifiedRootInvocation session project operator epoch verb use
    | not (operatorMatchesStore session operator) =
        pure
            ( Left
                ( AuthorityOperatorRefused
                    "the operator authorization was issued for a different protected store"
                )
            )
    | otherwise = case authorityBindingKey of
        Left failure -> pure (Left failure)
        Right recordKey -> do
            observed <- readProtectedRecord session recordKey
            case observed of
                Left failure -> pure (Left (AuthorityStoreFailure failure))
                Right (Just record)
                    | decodeText (protectedRecordBytes record) /= installedProjectName project ->
                        pure
                            ( Left
                                ( AuthorityStoreNotOurs
                                    (installedProjectName project)
                                    (decodeText (protectedRecordBytes record))
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
    mint = use (RootInvocationAuthority (installedProjectName project) epoch verb)

operatorMatchesStore :: ProtectedSession session -> OperatorAuthorization -> Bool
operatorMatchesStore session (OperatorAuthorization storeIdentity) =
    storeIdentity == protectedStoreIdentityText (sessionStoreIdentity session)

-- The root/verb side of Production closure ------------------------------------------

{- | Which closed way a Production run reached closure. The distinction is the
whole point: a settled destroy may close, and so may a refusal proven to precede
every acquisition, but partial @up@/@down@ teardown may not be relabelled as
either.
-}
data ProductionCloseKind
    = -- | Closure after a settled @destroy@.
      SettledDestroyClose
    | -- | Closure after a refusal that provably preceded every acquisition.
      PreEffectRefusalClose
    deriving (Eq, Show)

{- | The root/verb half of @ProductionClosureAuthorization@. the test-harness-and-run-ownership phase combines
it with the settled-destroy or no-resources-acquired proof; neither half closes
a project on its own.
-}
data ProductionCloseRoot scope brokerGeneration
    = ProductionCloseRoot ProductionCloseKind Text (BrokerEpoch brokerGeneration)

instance Show (ProductionCloseRoot scope brokerGeneration) where
    show (ProductionCloseRoot kind project epoch) =
        "ProductionCloseRoot " <> show kind <> " " <> show project <> " " <> show epoch

productionCloseRootVerb :: ProductionCloseRoot scope brokerGeneration -> ProductionCloseKind
productionCloseRootVerb (ProductionCloseRoot kind _ _) = kind

-- | Only an exact @destroy@ root can take the settled-destroy branch.
destroyCloseRoot ::
    RootInvocationAuthority scope brokerGeneration VerbDestroy ->
    ProductionCloseRoot scope brokerGeneration
destroyCloseRoot (RootInvocationAuthority project epoch _) =
    ProductionCloseRoot SettledDestroyClose project epoch

{- | Any exact Production verb may take the pre-effect branch; the test-harness-and-run-ownership phase still
requires the separate proof that no project resource was acquired.
-}
preEffectCloseRoot ::
    RootInvocationAuthority scope brokerGeneration verb ->
    ProductionCloseRoot scope brokerGeneration
preEffectCloseRoot (RootInvocationAuthority project epoch _) =
    ProductionCloseRoot PreEffectRefusalClose project epoch

-- Command authority ---------------------------------------------------------------------

-- | A one-use invocation identity. It is recorded durably before it is handed out.
newtype InvocationId = InvocationId Text
    deriving (Eq, Ord)

instance Show InvocationId where
    show (InvocationId value) = "InvocationId " <> show value

invocationIdText :: InvocationId -> Text
invocationIdText (InvocationId value) = value

{- | Authority to run one verb at one frame of one plan in one phase, under one
broker generation, exactly once. The @frame@ index is generative, so an
authority obtained for one frame cannot be presented at another even when the
frame names match.
-}
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

commandAuthorityVerb ::
    CommandAuthority scope planId frame brokerGeneration verb phase -> ProjectVerb verb
commandAuthorityVerb (CommandAuthority _ _ _ verb _) = verb

commandAuthorityPhase ::
    CommandAuthority scope planId frame brokerGeneration verb phase -> LifecyclePhase phase
commandAuthorityPhase (CommandAuthority _ _ _ _ phase) = phase

{- | Mint command authority by atomically reserving its one-use invocation.

The reservation record is keyed by the exact store identity, project, plan
digest, frame, verb, phase, and broker generation. Reserving is a
compare-and-swap from absent, so the second attempt at the same invocation is
'AuthorityInvocationConsumed' and no authority is produced. The frame must be
one the plan actually declares: an authority for a frame outside the plan is
refused before any effect.
-}
authorizeProjectCommand ::
    ProtectedSession session ->
    InstalledProject projectId ->
    RootInvocationAuthority scope brokerGeneration verb ->
    LifecyclePlan scope planId ->
    LifecyclePhase phase ->
    Text ->
    ( forall frame.
      CommandAuthority scope planId frame brokerGeneration verb phase ->
      IO (Either AuthorityError result)
    ) ->
    IO (Either AuthorityError result)
authorizeProjectCommand session project root plan phase frameName use
    | rootAuthorityProjectName root /= installedProjectName project =
        pure
            ( Left
                ( AuthorityStoreNotOurs
                    (installedProjectName project)
                    (rootAuthorityProjectName root)
                )
            )
    | frameName `notElem` lifecyclePlanFrames plan =
        pure (Left (AuthorityUnknownFrame frameName))
    | otherwise = case invocationKey project plan verb phase frameName epoch of
        Left failure -> pure (Left failure)
        Right recordKey -> do
            observed <- readProtectedRecord session recordKey
            case observed of
                Left failure -> pure (Left (AuthorityStoreFailure failure))
                Right (Just record) ->
                    pure
                        ( Left
                            ( AuthorityInvocationConsumed
                                (decodeText (protectedRecordBytes record))
                            )
                        )
                Right Nothing -> do
                    written <-
                        compareAndSwapProtectedRecord
                            session
                            recordKey
                            ExpectAbsent
                            (encodeText (invocationText plan verb phase frameName epoch))
                    case written of
                        Left failure -> pure (Left (AuthorityStoreFailure failure))
                        Right version ->
                            use
                                ( CommandAuthority
                                    ( InvocationId
                                        ( invocationText plan verb phase frameName epoch
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
    verb = rootAuthorityVerb root
    epoch = rootAuthorityEpoch root

invocationText ::
    LifecyclePlan scope planId ->
    ProjectVerb verb ->
    LifecyclePhase phase ->
    Text ->
    BrokerEpoch brokerGeneration ->
    Text
invocationText plan verb phase frameName epoch =
    Text.intercalate
        "/"
        [ lifecyclePlanDigest plan
        , frameName
        , projectVerbName verb
        , lifecyclePhaseName phase
        , Text.pack (show (brokerEpochWord epoch))
        ]

-- Record keys ------------------------------------------------------------------------------

brokerCounterKey :: InstalledProject projectId -> Either AuthorityError RecordKey
brokerCounterKey project =
    storeKey ("broker." <> installedProjectName project <> ".generation")

{- | The store's single project binding. It is deliberately *not* per project:
one protected authority store belongs to one installed project, so a store
established for another project refuses this one rather than quietly growing a
second binding beside it.
-}
authorityBindingKey :: Either AuthorityError RecordKey
authorityBindingKey = storeKey "authority.binding"

invocationKey ::
    InstalledProject projectId ->
    LifecyclePlan scope planId ->
    ProjectVerb verb ->
    LifecyclePhase phase ->
    Text ->
    BrokerEpoch brokerGeneration ->
    Either AuthorityError RecordKey
invocationKey project plan verb phase frameName epoch =
    storeKey
        ( Text.intercalate
            "."
            [ "invocation"
            , installedProjectName project
            , digestFingerprint (lifecyclePlanDigest plan)
            , digestFingerprint frameName
            , projectVerbName verb
            , lifecyclePhaseName phase
            , Text.pack (show (brokerEpochWord epoch))
            ]
        )

{- | Fold arbitrary text into a key-safe fingerprint. Plan digests and frame
identifiers are project-supplied, so they never reach a path segment directly.
-}
digestFingerprint :: Text -> Text
digestFingerprint value =
    Text.pack (showHexWord (Text.foldl' step 1469598103934665603 value))
  where
    step acc character =
        (acc `xor` fromIntegral (fromEnum character)) * 1099511628211

showHexWord :: Word64 -> String
showHexWord value = go value ""
  where
    go remaining acc
        | remaining < 16 = digit remaining : acc
        | otherwise = go (remaining `div` 16) (digit (remaining `mod` 16) : acc)
    digit d
        | d < 10 = toEnum (fromEnum '0' + fromIntegral d)
        | otherwise = toEnum (fromEnum 'a' + fromIntegral d - 10)

storeKey :: Text -> Either AuthorityError RecordKey
storeKey raw = case mkRecordKey raw of
    Left failure -> Left (AuthorityStoreFailure failure)
    Right key -> Right key

encodeText :: Text -> ByteString
encodeText = ByteStringChar8.pack . Text.unpack

decodeText :: ByteString -> Text
decodeText = Text.pack . ByteStringChar8.unpack

-- Failures ------------------------------------------------------------------------------------

data AuthorityError
    = -- | The installed identity or a recorded generation was malformed.
      AuthorityInvalidIdentity Text
    | -- | The operator/OS check refused, with the exact reason.
      AuthorityOperatorRefused Text
    | -- | The protected store is bound to a different project.
      AuthorityStoreNotOurs Text Text
    | -- | The requested frame is not declared by the plan.
      AuthorityUnknownFrame Text
    | -- | This exact invocation has already been consumed.
      AuthorityInvocationConsumed Text
    | -- | An operator supplied a verb outside the closed set.
      AuthorityUnknownVerb Text
    | -- | The protected store itself failed or raced.
      AuthorityStoreFailure ProtectedError
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
    AuthorityUnknownFrame frameName ->
        "frame " <> frameName <> " is not declared by this lifecycle plan"
    AuthorityInvocationConsumed invocation ->
        "invocation " <> invocation <> " has already been consumed"
    AuthorityUnknownVerb raw -> "unknown project verb: " <> raw
    AuthorityStoreFailure inner -> protectedErrorMessage inner
