{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Portable, plan-indexed reconciliation for a provider-guest durable alias.

The preparation and settlement algebra is pure; the backend that observes and
mutates the guest is injected as a 'GuestExec' so it runs identically on every
provider substrate (all three provider guests are the same Ubuntu image reached
through @incus exec@ / @limactl shell@ / @wsl -d@) and against a real POSIX
filesystem under test.

The backend holds the four Locked-Origin Identity Ownership clauses of
@development_plan_standards.md § EE@ with the guest realization from
@documents/architecture/ownership_invariant.md@: exclusive entry is a @flock -x@
held across each observe/mutate/settle bracket; the alias object's identity is
its symlink's own @(device, inode)@ pair, read with @stat@ (which lstats a
symlink by default); and conditional release re-observes that identity and
@unlink@s only on an exact match, in one guest invocation so the compare and the
unlink cannot straddle a foreign replacement.  This excludes crash/retry and
cooperating races and /detects/ foreign mutation; it does not exclude a hostile
same-privilege process, and no substrate supplies that exclusion.  A guest that
lacks a required tool is 'Unsupported' and mints no receipt.
-}
module HostBootstrap.Substrate.Provider.Alias (
    GuestAliasSpec,
    mkGuestAliasSpec,
    guestAliasPath,
    guestAliasTarget,
    PreparedGuestAliasCall,
    withPreparedGuestAliasCall,
    AliasCallObservation (..),
    settlePreparedGuestAliasCall,
    GuestExec (..),
    GuestCommandResult (..),
    StrongAliasBackend,
    discoverStrongAliasBackend,
    runPreparedGuestAliasCall,
    PreparedGuestAliasRelease,
    withPreparedGuestAliasRelease,
    runPreparedGuestAliasRelease,
)
where

import Data.Bits (xor)
import Data.List (intercalate, stripPrefix)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Reconcile (
    BackendReconcileObservation (..),
    ConflictDetail (..),
    DependencySnapshot,
    DurableAliasResource,
    DurableShareResource,
    FailureDetail (..),
    ForeignObservation (..),
    Managed,
    Observed,
    OwnershipReceipt,
    PlannedEdge,
    PlannedResource,
    PreparedOperation,
    PreparedPreconditions,
    PriorCommitProof,
    Provisioned,
    ReconcileError (..),
    ReconcileResult,
    RecoveryDisposition (DoNotRetry),
    ResourceHandle,
    Unclassified,
    UnsupportedDetail (..),
    completePreparedUnchanged,
    completeReconcile,
    plannedGuestAliasOperation,
    resourceHandleGeneration,
    resourceHandleKey,
    validateOwnershipReceipt,
    withOperationPreconditions,
    withPreparedOperation,
 )
import HostBootstrap.Substrate.Provider (
    SubstrateProvider,
    spProviderKind,
 )

data GuestAliasSpec = GuestAliasSpec FilePath FilePath
    deriving (Eq, Show)

mkGuestAliasSpec :: FilePath -> FilePath -> Either ReconcileError GuestAliasSpec
mkGuestAliasSpec aliasPath target
    | not (guestAbsolute aliasPath) =
        invalid "alias path must be an absolute POSIX guest path"
    | not (guestAbsolute target) =
        invalid "alias target must be an absolute POSIX guest path"
    | '\0' `elem` aliasPath || '\0' `elem` target =
        invalid "alias path and target must not contain NUL"
    | trimGuestPath aliasPath == trimGuestPath target =
        invalid "alias path and target must differ"
    | otherwise = Right (GuestAliasSpec aliasPath target)
  where
    invalid reason =
        Left
            ( Failure
                (FailureDetail "validate provider guest alias" reason DoNotRetry)
            )

guestAliasPath :: GuestAliasSpec -> FilePath
guestAliasPath (GuestAliasSpec aliasPath _) = aliasPath

guestAliasTarget :: GuestAliasSpec -> FilePath
guestAliasTarget (GuestAliasSpec _ target) = target

guestAbsolute :: FilePath -> Bool
guestAbsolute ('/' : _) = True
guestAbsolute _ = False

trimGuestPath :: FilePath -> FilePath
trimGuestPath "/" = "/"
trimGuestPath value = reverse (dropWhile (== '/') (reverse value))

aliasCallDigest :: GuestAliasSpec -> Text
aliasCallDigest spec =
    "guest-alias:"
        <> sized (guestAliasPath spec)
        <> ":"
        <> sized (guestAliasTarget spec)
  where
    sized value = Text.pack (show (length value)) <> ":" <> Text.pack value

data PreparedGuestAliasCall scope planId aliasId shareId operationKey callDigest attempt journalVersion
    = PreparedGuestAliasCall
        GuestAliasSpec
        (ResourceHandle scope planId aliasId DurableAliasResource Unclassified Observed)
        (PreparedOperation scope planId aliasId DurableAliasResource operationKey callDigest attempt journalVersion)
        (PreparedPreconditions scope planId aliasId DurableAliasResource operationKey callDigest attempt journalVersion)

withPreparedGuestAliasCall ::
    PlannedResource scope planId aliasId DurableAliasResource aliasFrame ->
    PlannedEdge
        scope
        planId
        aliasId
        DurableAliasResource
        aliasFrame
        shareId
        DurableShareResource
        shareFrame ->
    ResourceHandle scope planId aliasId DurableAliasResource Unclassified Observed ->
    DependencySnapshot scope planId ->
    GuestAliasSpec ->
    PreparedGate ->
    ( forall operationKey callDigest attempt journalVersion.
      PreparedGuestAliasCall
        scope
        planId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
      result
    ) ->
    IO (Either ReconcileError result)
withPreparedGuestAliasCall planned edge aliasHandle snapshot spec gate consume =
    case plannedGuestAliasOperation planned edge aliasHandle (aliasCallDigest spec) of
        Left err -> pure (Left err)
        Right descriptor -> do
            sealed <- withOperationPreconditions descriptor snapshot
            pure $ do
                preconditionSet <- sealed
                withPreparedOperation
                    descriptor
                    preconditionSet
                    gate
                    ( \prepared preconditions ->
                        consume
                            ( PreparedGuestAliasCall
                                spec
                                aliasHandle
                                prepared
                                preconditions
                            )
                    )

{- | Structured result from the protected backend boundary.  Created/repaired
observations authorize ownership only after settlement against the exact
prepared operation.  A compatible link without prior commit proof is explicitly
foreign.
-}
data AliasCallObservation
    = AliasCallCreated Word64
    | AliasCallRepaired Word64
    | AliasCallAlreadyExact Word64
    | AliasCallForeign Word64 ForeignObservation
    | AliasCallConflict ConflictDetail
    | AliasCallUnsupported UnsupportedDetail
    | AliasCallFailed FailureDetail
    deriving (Eq, Show)

settlePreparedGuestAliasCall ::
    Maybe (PriorCommitProof scope planId aliasId DurableAliasResource) ->
    PreparedGuestAliasCall
        scope
        planId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
    AliasCallObservation ->
    Either
        ReconcileError
        (ReconcileResult scope planId aliasId DurableAliasResource Provisioned)
settlePreparedGuestAliasCall
    priorProof
    (PreparedGuestAliasCall spec handle prepared preconditions)
    observation =
        case observation of
            AliasCallCreated generation ->
                completeReconcile handle prepared preconditions (BackendCreated generation)
            AliasCallRepaired generation ->
                completeReconcile handle prepared preconditions (BackendRepaired generation)
            AliasCallAlreadyExact generation
                | generation /= resourceHandleGeneration handle ->
                    Left
                        ( Conflict
                            ( ConflictDetail
                                (resourceHandleKey handle)
                                ("generation=" <> showText (resourceHandleGeneration handle))
                                ("generation=" <> showText generation)
                                "reprobe the alias before classifying the exact link"
                            )
                        )
                | Just proof <- priorProof ->
                    completePreparedUnchanged handle prepared preconditions proof
                | otherwise ->
                    completeReconcile
                        handle
                        prepared
                        preconditions
                        ( BackendForeign
                            generation
                            ( ForeignObservation
                                (Text.pack (guestAliasPath spec))
                                "correct target observed without matching committed ownership"
                            )
                        )
            AliasCallForeign generation foreignState ->
                completeReconcile
                    handle
                    prepared
                    preconditions
                    (BackendForeign generation foreignState)
            AliasCallConflict detail -> Left (Conflict detail)
            AliasCallUnsupported detail -> Left (Unsupported detail)
            AliasCallFailed detail -> Left (Failure detail)

showText :: (Show value) => value -> Text
showText = Text.pack . show

{- | How the backend runs a command in the provider guest.  Production supplies
a runner that dispatches through the provider lift (@incus exec@ /
@limactl shell@ / @wsl -d@); a test injects one that runs the argv against a
real POSIX filesystem so the four-clause protocol is exercised on every
substrate.  This is a plain effect handle, not authority: the opaque
'StrongAliasBackend' capability is minted only by 'discoverStrongAliasBackend'.
-}
newtype GuestExec = GuestExec
    {runGuestCommand :: [String] -> IO GuestCommandResult}

{- | The captured outcome of one guest command.  @guestCommandOk@ is the
exit-zero verdict; the streams carry the parseable backend report and any
diagnostic.
-}
data GuestCommandResult = GuestCommandResult
    { guestCommandOk :: Bool
    , guestCommandStdout :: String
    , guestCommandStderr :: String
    }
    deriving (Eq, Show)

{- | Capability for a backend that holds the four Locked-Origin Identity
Ownership clauses for a provider-guest durable alias.  Its constructor is
private: it is minted only by 'discoverStrongAliasBackend' after that verifies
the guest exposes the POSIX ownership tools.
-}
data StrongAliasBackend = StrongAliasBackend SubstrateProvider GuestExec

{- | Probe the guest for @flock@, @stat@, @ln@, @readlink@, and @unlink@ and,
only when they are all present, mint the backend.  A guest missing a tool is
'Unsupported' and mints no capability.
-}
discoverStrongAliasBackend ::
    SubstrateProvider ->
    GuestExec ->
    IO (Either ReconcileError StrongAliasBackend)
discoverStrongAliasBackend provider exec = do
    result <- runGuestCommand exec ["sh", "-c", ownershipToolProbe]
    pure $
        if guestCommandOk result
            then Right (StrongAliasBackend provider exec)
            else
                Left
                    ( Unsupported
                        ( UnsupportedDetail
                            "reconcile provider guest durable alias"
                            ( "the guest for "
                                <> Text.pack (show (spProviderKind provider))
                                <> " lacks a POSIX ownership tool"
                                <> " (flock, stat, ln, readlink, unlink)"
                            )
                        )
                    )

{- | A single compound observation with no nested command substitution, so it
survives the Windows PowerShell → @wsl@ → @bash@ path (§ readiness discipline).
-}
ownershipToolProbe :: String
ownershipToolProbe =
    intercalate
        " && "
        [ "command -v " <> tool <> " >/dev/null 2>&1"
        | tool <- ["flock", "stat", "ln", "readlink", "unlink", "sed"]
        ]

{- | Observe the alias under an exclusive @flock@ and, if it is absent, create
the symlink.  The reported change echoes the plan-assigned generation the
prepared operation must confirm ('completeReconcile' rejects a mismatch); the
alias object's kernel identity (@device:inode@) is the clause-3 binding and is
journalled in a guest-side origin record (clause 2) so conditional release can
compare against it (clause 4) rather than a pathname.
-}
runPreparedGuestAliasCall ::
    StrongAliasBackend ->
    PreparedGuestAliasCall
        scope
        planId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
    IO AliasCallObservation
runPreparedGuestAliasCall
    (StrongAliasBackend _ exec)
    (PreparedGuestAliasCall spec handle _ _) = do
        result <-
            runGuestCommand
                exec
                (flockWrapped spec aliasReconcileScript)
        pure (parseReconcileReport spec (resourceHandleGeneration handle) result)

{- | Wrap a guest script in @flock -x \<lock\> sh -c \<script\> _ alias target
record@ so the exclusive lock is held across the whole observe/mutate/settle
bracket (clause 1).  The lock file sits beside the alias and is auto-created
by @flock@.
-}
flockWrapped :: GuestAliasSpec -> String -> [String]
flockWrapped spec script =
    [ "flock"
    , "-x"
    , aliasLockPath spec
    , "sh"
    , "-c"
    , script
    , "hb-alias"
    , guestAliasPath spec
    , guestAliasTarget spec
    , aliasRecordPath spec
    ]

aliasLockPath :: GuestAliasSpec -> FilePath
aliasLockPath spec = guestAliasPath spec ++ ".hb-alias.lock"

{- | The clause-2 durable origin record: it names the exact original state
(absent / a foreign occupant / an already-present link identity) before the
first mutation, then the managed identity we created, so a crashed retry
restores the recorded truth rather than inferring it.
-}
aliasRecordPath :: GuestAliasSpec -> FilePath
aliasRecordPath spec = guestAliasPath spec ++ ".hb-alias.origin"

-- | Positional args: @$1@ alias, @$2@ target, @$3@ record.
aliasReconcileScript :: String
aliasReconcileScript =
    unlines
        [ "alias=\"$1\"; target=\"$2\"; rec=\"$3\""
        , -- clause 2: record the exact origin before the first mutation.
          "if [ ! -e \"$rec\" ]; then"
        , "  if [ -L \"$alias\" ]; then"
        , "    printf 'origin present %s\\n' \"$(stat -c '%d:%i' \"$alias\")\" > \"$rec\""
        , "  elif [ -e \"$alias\" ]; then"
        , "    printf 'origin occupied\\n' > \"$rec\""
        , "  else"
        , "    printf 'origin absent\\n' > \"$rec\""
        , "  fi"
        , "fi"
        , -- observe + act (clause 3: bind to device:inode, never the name).
          "if [ -L \"$alias\" ]; then"
        , "  id=$(stat -c '%d:%i' \"$alias\")"
        , "  if [ \"$(readlink \"$alias\")\" = \"$target\" ]; then"
        , "    printf 'EXACT %s\\n' \"$id\""
        , "  else"
        , "    printf 'FOREIGN %s repoint\\n' \"$id\""
        , "  fi"
        , "elif [ -e \"$alias\" ]; then"
        , "  printf 'FOREIGN %s occupied\\n' \"$(stat -c '%d:%i' \"$alias\")\""
        , "elif ln -s \"$target\" \"$alias\"; then"
        , "  id=$(stat -c '%d:%i' \"$alias\")"
        , "  printf 'managed %s\\n' \"$id\" >> \"$rec\""
        , "  printf 'CREATED %s\\n' \"$id\""
        , "else"
        , "  printf 'FAILED\\n'"
        , "fi"
        ]

parseReconcileReport ::
    GuestAliasSpec ->
    Word64 ->
    GuestCommandResult ->
    AliasCallObservation
parseReconcileReport spec generation result
    | not (guestCommandOk result) =
        AliasCallFailed
            ( FailureDetail
                "reconcile provider guest durable alias"
                ( "the guest exclusive-entry command failed: "
                    <> firstLineText (guestCommandStderr result)
                )
                DoNotRetry
            )
    | otherwise = case words (firstLine (guestCommandStdout result)) of
        ("CREATED" : _) -> AliasCallCreated generation
        ("EXACT" : _) -> AliasCallAlreadyExact generation
        ("FOREIGN" : identity : rest) ->
            AliasCallForeign
                (identityGeneration identity)
                ( ForeignObservation
                    (Text.pack (guestAliasPath spec))
                    (foreignReason rest)
                )
        ("FAILED" : _) ->
            AliasCallFailed
                ( FailureDetail
                    "reconcile provider guest durable alias"
                    "the guest could not create the durable alias symlink"
                    DoNotRetry
                )
        _ ->
            AliasCallFailed
                ( FailureDetail
                    "reconcile provider guest durable alias"
                    ( "unparseable backend report: "
                        <> firstLineText (guestCommandStdout result)
                    )
                    DoNotRetry
                )
  where
    foreignReason ("repoint" : _) =
        "the alias is a symlink to a different target"
    foreignReason ("occupied" : _) =
        "the alias path is occupied by a non-symlink object"
    foreignReason _ = "the alias is not the managed link"

{- | Fold a @device:inode@ identity to a positive generation for a foreign
observation (a foreign generation must be strictly positive; § EE).
-}
identityGeneration :: String -> Word64
identityGeneration = max 1 . foldl step 1469598103934665603
  where
    step acc c = (acc `xor` fromIntegral (fromEnum c)) * 1099511628211

firstLine :: String -> String
firstLine value = case lines value of
    (l : _) -> l
    [] -> ""

firstLineText :: String -> Text
firstLineText = Text.pack . firstLine

data PreparedGuestAliasRelease scope planId aliasId phase releaseId
    = PreparedGuestAliasRelease
        GuestAliasSpec
        (ResourceHandle scope planId aliasId DurableAliasResource Managed phase)
        (OwnershipReceipt scope planId aliasId DurableAliasResource)
        Word64

{- | Prepare conditional deletion.  A foreign/unmanaged handle does not type
check here, and the receipt must match the exact managed generation.
-}
withPreparedGuestAliasRelease ::
    GuestAliasSpec ->
    ResourceHandle scope planId aliasId DurableAliasResource Managed phase ->
    OwnershipReceipt scope planId aliasId DurableAliasResource ->
    Word64 ->
    ( forall releaseId.
      PreparedGuestAliasRelease scope planId aliasId phase releaseId ->
      result
    ) ->
    Either ReconcileError result
withPreparedGuestAliasRelease spec handle receipt conditionalVersion consume
    | conditionalVersion == 0 =
        Left
            ( Failure
                (FailureDetail "prepare guest alias release" "conditional version must be positive" DoNotRetry)
            )
    | otherwise = do
        validateOwnershipReceipt handle receipt
        Right
            ( consume
                (PreparedGuestAliasRelease spec handle receipt conditionalVersion)
            )

{- | Conditional release (clause 4): re-observe the alias's identity under the
same exclusive @flock@ and @unlink@ only on an exact @device:inode@ match
against the managed identity recorded in the guest origin record (clause 2).
Any other observation is a structured 'Conflict', the alias is left
untouched, and no receipt is consumed.
-}
runPreparedGuestAliasRelease ::
    StrongAliasBackend ->
    PreparedGuestAliasRelease scope planId aliasId phase releaseId ->
    IO (Either ReconcileError ())
runPreparedGuestAliasRelease
    (StrongAliasBackend _ exec)
    (PreparedGuestAliasRelease spec _ _ _) = do
        result <- runGuestCommand exec (flockWrapped spec aliasReleaseScript)
        pure (parseReleaseReport spec result)

-- | Positional args: @$1@ alias, @$2@ target, @$3@ record.
aliasReleaseScript :: String
aliasReleaseScript =
    unlines
        [ "alias=\"$1\"; target=\"$2\"; rec=\"$3\""
        , "managed=''"
        , "if [ -f \"$rec\" ]; then managed=$(sed -n 's/^managed //p' \"$rec\"); fi"
        , "cur=$(stat -c '%d:%i' \"$alias\" 2>/dev/null || printf absent)"
        , "if [ -L \"$alias\" ] && [ \"$(readlink \"$alias\")\" = \"$target\" ] \\"
        , "  && [ -n \"$managed\" ] && [ \"$cur\" = \"$managed\" ]; then"
        , "  if unlink \"$alias\"; then rm -f \"$rec\"; printf 'RELEASED\\n'; \\"
        , "  else printf 'FAILED\\n'; fi"
        , "else"
        , "  printf 'CONFLICT observed=%s expected=%s\\n' \"$cur\" \"$managed\""
        , "fi"
        ]

parseReleaseReport :: GuestAliasSpec -> GuestCommandResult -> Either ReconcileError ()
parseReleaseReport spec result
    | not (guestCommandOk result) =
        Left
            ( Failure
                ( FailureDetail
                    "release provider guest durable alias"
                    ( "the guest exclusive-entry command failed: "
                        <> firstLineText (guestCommandStderr result)
                    )
                    DoNotRetry
                )
            )
    | otherwise = case words (firstLine (guestCommandStdout result)) of
        ("RELEASED" : _) -> Right ()
        ("CONFLICT" : fields) ->
            Left
                ( Conflict
                    ( ConflictDetail
                        (Text.pack (guestAliasPath spec))
                        ("device:inode=" <> keyField "expected" fields)
                        ("device:inode=" <> keyField "observed" fields)
                        "reprobe the alias identity before releasing it"
                    )
                )
        ("FAILED" : _) ->
            Left
                ( Failure
                    ( FailureDetail
                        "release provider guest durable alias"
                        "the guest could not unlink the durable alias"
                        DoNotRetry
                    )
                )
        _ ->
            Left
                ( Failure
                    ( FailureDetail
                        "release provider guest durable alias"
                        ( "unparseable backend report: "
                            <> firstLineText (guestCommandStdout result)
                        )
                        DoNotRetry
                    )
                )

{- | Extract @key=value@ from a whitespace-split report, defaulting to
@\"unknown\"@ (or @\"absent\"@ for the empty managed field).
-}
keyField :: String -> [String] -> Text
keyField key fields =
    case [value | field <- fields, Just value <- [stripPrefix (key ++ "=") field]] of
        (value : _) | not (null value) -> Text.pack value
        _ -> "unknown"
