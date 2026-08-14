{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | One root-owned journal session for an exact catalog frame.

This is the only place the recursive plan catalog meets the durable session
operations, and the direction is deliberately one-way: the catalog tells this
module which frame exists and what its canonical path is, and the store tells
it what is already recorded. A request tells it nothing.

That is the whole point of the shape. Every coordinate a rooted exchange runs
on — the requester path, the session token, the stage, and the next ordinal —
is selected here from root evidence before any request is read. An 'OpenFrame'
carries only a nonce, so there is no field in it that could name a session, a
path, an ordinal, a journal key, or a catalog row even if a caller wanted to.
What a request can do is attach to a session the root already opened, or replay
an attachment that already happened; it cannot bring one into being.

A newly opened session has no predecessor-response digest, because nothing has
been answered yet. The first predecessor appears only when the exact nine-field
root-signed @Opened@ has been produced and read back, and it is the digest of
those complete signed bytes. Signing itself belongs to the live root endpoint,
not here: this module records the digest of bytes it is handed, so nothing in
it can mint a response.

Failures here are all pre-attachment, and pre-attachment failure is an outer
refusal — the authenticated-handoff transport's existing one. This module
therefore produces no rooted @Refused@ at all; that form is post-open only.
-}
module HostBootstrap.Lifecycle.Rooted
    ( RootedFrameSession
    , withRootOpenedFrameSessionKernel
    , withAttachedRootedFrameSessionKernel
    , withRootedFrameOpeningKernel
    , withRootedFrameSessionKernel
    )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority (ProjectVerb, projectVerbName)
import HostBootstrap.Handoff (childConfigDigest, frameWire, maxWireBytes)
import HostBootstrap.Handoff.Rooted
    ( rootedLifecycleRequestFromWireKernel
    , rootedOpenedResponseUnsignedKernel
    , withRootedLifecycleRequestKernel
    )
import HostBootstrap.Handoff.Runtime
    ( RecursiveHandoffRuntime
    , withRecursiveHandoffRuntimeKernel
    , withRootArmRecursiveHandoffRuntimeKernel
    )
import HostBootstrap.Lifecycle.RootedPlan
    ( RootedPlanCatalog
    , rootedPlanCatalogRecordIdentityKernel
    , withRootedPlanCatalogEntriesKernel
    , withRootedPlanCatalogRootKernel
    )
import HostBootstrap.Lifecycle.Session
    ( SessionError
    , attachRootedFrameSessionRecordKernel
    , openRootedFrameSessionRecordKernel
    , rootedFrameSessionKeyKernel
    , sessionErrorMessage
    )
import HostBootstrap.ProjectPlan.Frame (currentFrameId)
import HostBootstrap.Protected
    ( ProtectedStore
    , RecordKey
    , RecordVersion
    , withProtectedEntry
    )

{- | One root-owned frame session through its two durable states.

Opened retains the root-selected coordinates and the exact durable row they
were published as. Attached nests that exact opening with the admitted nonce,
the first predecessor digest, and its own successor row. Neither constructor
retains a store, catalog, runtime, request, or response value: what escapes an
elimination is coordinates, and coordinates authorize nothing.
-}
data RootedFrameSession
    scope rootPlanId brokerGeneration catalogId frame sessionId verb
    where
    OpenedRootedFrameSession ::
        ProjectVerb verb ->
        Text ->
        Text ->
        Text ->
        [Text] ->
        Text ->
        Text ->
        Word64 ->
        RecordKey ->
        RecordVersion ->
        ByteString ->
        RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb
    AttachedRootedFrameSession ::
        RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
        ByteString ->
        Text ->
        RecordVersion ->
        ByteString ->
        RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb

type role RootedFrameSession nominal nominal nominal nominal nominal nominal nominal

instance Show (RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb) where
    show OpenedRootedFrameSession{} = "RootedFrameSession <opened>"
    show AttachedRootedFrameSession{} = "RootedFrameSession <attached>"

{- | Open one root-owned session for an exact catalog frame.

Nothing here is caller-selected. The requester path is the catalog's own
descent chain to this frame, the session token is a digest of the root lineage,
catalog identity, frame, and verb — opaque, and stable so that reopening
converges rather than forking — the stage is the fixed initial one, and the
next ordinal is the first nonzero one. The record key is derived from root
lineage, catalog identity, and frame alone.

The runtime is checked before the store is opened, and it must be the root arm:
a keyless nested arm cannot open a session, which is what keeps journal
ownership at the topology root. The published row carries no
predecessor-response digest, because at this point nothing has been answered.

Both the frame and session indices are existential, so a caller cannot name the
type of one frame's session and be handed another's — the indices are minted by
the opening rather than chosen by whoever asked for it.
-}
withRootOpenedFrameSessionKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    ProtectedStore ->
    ProjectVerb verb ->
    Text ->
    Text ->
    ( forall frame sessionId.
      RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withRootOpenedFrameSessionKernel #-}
withRootOpenedFrameSessionKernel runtime catalog store verb rootPlanDigest requestedFrame use =
    withRecursiveHandoffRuntimeKernel runtime $ \atRoot _project _tag _store generation runtimeVerb _keyDigest frame ->
        case admit atRoot generation runtimeVerb frame of
            Left failure -> pure (Left failure)
            Right (path, key, opened) -> do
                entered <- withProtectedEntry store $ \session ->
                    Right <$> openRootedFrameSessionRecordKernel session key opened
                case entered of
                    Left failure -> refused (Text.pack (show failure))
                    Right (Left failure) -> refused (Text.pack (sessionErrorMessage failure))
                    Right (Right (version, present))
                        | present /= opened ->
                            refused "the durable rooted frame session row is not this opening"
                        | otherwise ->
                            use
                                ( OpenedRootedFrameSession
                                    verb rootPlanDigest catalogIdentity requestedFrame path
                                    (sessionTokenFor path) initialStage initialOrdinal
                                    key version opened
                                )
  where
    catalogIdentity = rootedPlanCatalogRecordIdentityKernel catalog
    verbName = projectVerbName verb

    admit atRoot generation runtimeVerb frame = do
        require "a keyless nested arm cannot open a root frame session" atRoot
        require "the runtime is not path-agnostic" (isNothing frame)
        require "the runtime verb differs from the session verb" (runtimeVerb == verbName)
        require "the broker generation is zero" (generation > 0)
        require "the root plan digest is empty" (not (Text.null rootPlanDigest))
        require "the catalog identity is empty" (not (Text.null catalogIdentity))
        path <- canonicalRequesterPath
        require "the root frame has no rooted requester path" (not (null path))
        key <- sessionFailure (rootedFrameSessionKeyKernel rootPlanDigest catalogIdentity requestedFrame)
        let opened = renderOpenedRow path
        require "the rooted frame session row exceeds the durable bound"
            (fromIntegral (ByteString.length opened) <= maxWireBytes)
        pure (path, key, opened)

    {- The catalog's own descent chain to this frame, root-nearest-to-leaf —
    the exact order a sealed external relay envelope is built in, where every
    serving hop prepends its own current frame before forwarding. The root
    itself never appears, because it is the endpoint rather than a hop. Every
    component comes from an admitted descent edge, so a frame no edge names, a
    frame two edges name, and a chain that walks more levels than the catalog
    holds all refuse: a caller can name a frame and be told the one path that
    frame has, and can neither order nor extend it. -}
    canonicalRequesterPath = climb (length edges) requestedFrame []
      where
        edges =
            withRootedPlanCatalogEntriesKernel
                catalog
                (\_plan _binding _current parent child _raw _route _payload _config _payload' _keys -> (parent, child))
        rootFrame = withRootedPlanCatalogRootKernel catalog (\_ _ _ current _ -> currentFrameId current)
        climb remaining frame path
            | frame == rootFrame = Right path
            | remaining <= (0 :: Int) =
                Left (rootedFailure "the admitted descent chain does not reach the root frame")
            | otherwise = case [parent | (parent, child) <- edges, child == frame] of
                [parent] -> climb (remaining - 1) parent (frame : path)
                [] -> Left (rootedFailure "no admitted descent edge names the requested frame")
                _ -> Left (rootedFailure "more than one admitted descent edge names the requested frame")

    sessionTokenFor path =
        childConfigDigest
            ( ByteString.concat
                ( [ framedText "hostbootstrap/rooted-frame-session-token"
                  , framedWord 1
                  , framedText rootPlanDigest
                  , framedText catalogIdentity
                  , framedText requestedFrame
                  , framedText verbName
                  , framedWord (fromIntegral (length path))
                  ]
                    ++ map framedText path
                )
            )

    renderOpenedRow path =
        ByteString.concat
            ( [ framedText rootedFrameSessionDomain
              , framedWord 1
              , framedText "opened"
              , framedText rootPlanDigest
              , framedText catalogIdentity
              , framedText requestedFrame
              , framedText verbName
              , framedText (sessionTokenFor path)
              , framedText initialStage
              , framedWord initialOrdinal
              , framedWord (fromIntegral (length path))
              ]
                ++ map framedText path
            )

    refused = pure . Left . rootedFailure

{- | Attach one exact 'OpenFrame' to an already opened session, or replay it.

Everything is resolved before a byte is written. The runtime must still be the
root arm, the sealed external envelope path must equal the path the session
itself retains, and the request must decode as exactly an @OpenFrame@ — whose
only field is its nonce. A post-open request form cannot attach at all.

The replay identity is the attached row itself, and that row frames root
lineage, catalog identity, envelope path, and nonce together. Two attachments
therefore collide only when all four agree, so the same nonce under a different
lineage, catalog, or path is a different attachment rather than a replay of
this one.

The predecessor is the lowercase SHA-256 digest of the complete signed @Opened@
bytes as supplied — this module neither produces nor signs a response, and the
digest it records is of bytes it was handed rather than bytes it chose.
-}
withAttachedRootedFrameSessionKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProtectedStore ->
    [Text] ->
    ByteString ->
    ByteString ->
    ( RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withAttachedRootedFrameSessionKernel #-}
withAttachedRootedFrameSessionKernel runtime opened store envelope request signedOpened use =
    case opened of
        AttachedRootedFrameSession{} ->
            pure (Left (rootedFailure "the rooted frame session is already attached"))
        OpenedRootedFrameSession _ rootPlanDigest catalogIdentity _ path _ _ _ key version openedBytes ->
            withRecursiveHandoffRuntimeKernel runtime $ \atRoot _project _tag _store _generation _verb _keyDigest frame ->
                case admit atRoot frame path rootPlanDigest catalogIdentity openedBytes of
                    Left failure -> pure (Left failure)
                    Right (nonce, predecessor, attached) -> do
                        entered <- withProtectedEntry store $ \session ->
                            Right
                                <$> attachRootedFrameSessionRecordKernel
                                    session key version openedBytes attached
                        case entered of
                            Left failure -> refused (Text.pack (show failure))
                            Right (Left failure) -> refused (Text.pack (sessionErrorMessage failure))
                            Right (Right attachedVersion) ->
                                use
                                    ( AttachedRootedFrameSession
                                        opened nonce predecessor attachedVersion attached
                                    )
  where
    admit atRoot frame path rootPlanDigest catalogIdentity openedBytes = do
        require "a keyless nested arm cannot attach a root frame session" atRoot
        require "the runtime is not path-agnostic" (isNothing frame)
        require "the sealed external envelope is not the session's own path" (envelope == path)
        require "the signed Opened response is empty" (not (ByteString.null signedOpened))
        require "the signed Opened response exceeds the durable bound"
            (fromIntegral (ByteString.length signedOpened) <= maxWireBytes)
        decoded <- either (Left . rootedFailure) Right (rootedLifecycleRequestFromWireKernel request)
        nonce <-
            withRootedLifecycleRequestKernel
                decoded
                Right
                (\_ _ _ _ _ _ -> postOpen)
                (\_ _ _ _ _ _ _ -> postOpen)
                (\_ _ _ _ _ _ _ -> postOpen)
                (\_ _ _ _ _ _ -> postOpen)
                (\_ _ _ _ _ _ -> postOpen)
        let predecessor = childConfigDigest signedOpened
            attached = renderAttachedRow rootPlanDigest catalogIdentity path openedBytes nonce predecessor
        require "the attached rooted frame session row exceeds the durable bound"
            (fromIntegral (ByteString.length attached) <= maxWireBytes)
        pure (nonce, predecessor, attached)

    postOpen = Left (rootedFailure "only an OpenFrame request attaches a rooted frame session")

    renderAttachedRow rootPlanDigest catalogIdentity path openedBytes nonce predecessor =
        ByteString.concat
            ( [ framedText rootedFrameSessionDomain
              , framedWord 1
              , framedText "attached"
              , frameWire openedBytes
              , framedText rootPlanDigest
              , framedText catalogIdentity
              , framedWord (fromIntegral (length path))
              ]
                ++ map framedText path
                ++ [frameWire nonce, framedText predecessor]
            )

    refused = pure . Left . rootedFailure

{- | Answer one exact 'OpenFrame' from the session the root already opened.

This is the join the live root endpoint stands on, and every value in the
answer comes from the left of it. The requester supplies an envelope and a
nonce; the session supplies the admitted canonical path, the opaque token, the
stage, and the next ordinal; and the response names the request only by the
digest of the exact bytes that arrived. Nothing a requester sent selects a
coordinate.

The envelope is checked as a grammar before it is checked as an identity, and
the grammar is the post-open request codec's own: one to 256 components, none
empty, none wider than 4,096 encoded bytes. A path that is malformed is refused
on those terms rather than compared, so an oversized or empty component never
reaches the session comparison at all. Only then must it equal the path this
session retains.

Signing is a continuation because this module cannot sign. It renders the exact
nine-field unsigned @Opened@, hands those bytes out, and takes back the
complete signed response; the durable attachment then records that response's
digest and reads it back before the caller may release it. So the order is
fixed in the one direction that matters — no answer leaves the root before the
root durably holds what it answered.

An already attached session refuses here rather than opening a second exchange,
and a post-open request form cannot reach this path at all, because the
attachment it delegates to admits only an @OpenFrame@.
-}
withRootedFrameOpeningKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProtectedStore ->
    [Text] ->
    ByteString ->
    (ByteString -> IO (Either Text ByteString)) ->
    ( RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      ByteString ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withRootedFrameOpeningKernel #-}
withRootedFrameOpeningKernel runtime session store envelope request sign use =
    withRootArmRecursiveHandoffRuntimeKernel runtime $
        \_project _tag _store generation _runtimeVerb _keyDigest ->
            withRootedFrameSessionKernel session $
                \attached _verb _lineage catalogIdentity _frame path token stage ordinal _predecessor ->
                    case admit attached generation catalogIdentity path token stage ordinal of
                        Left failure -> pure (Left failure)
                        Right unsigned -> do
                            signed <- sign unsigned
                            case signed of
                                Left failure -> pure (Left failure)
                                Right signedOpened ->
                                    withAttachedRootedFrameSessionKernel
                                        runtime
                                        session
                                        store
                                        envelope
                                        request
                                        signedOpened
                                        (\opened -> use opened signedOpened)
  where
    admit attached generation catalogIdentity path token stage ordinal = do
        require "an attached rooted frame session cannot answer a second opening" (not attached)
        require "the broker generation is zero" (generation > 0)
        require "the catalog identity is empty" (not (Text.null catalogIdentity))
        requireEnvelopeGrammar
        require "the sealed external envelope is not the session's own path" (envelope == path)
        decoded <- either (Left . rootedFailure) Right (rootedLifecycleRequestFromWireKernel request)
        _ <-
            withRootedLifecycleRequestKernel
                decoded
                Right
                (\_ _ _ _ _ _ -> postOpenOpening)
                (\_ _ _ _ _ _ _ -> postOpenOpening)
                (\_ _ _ _ _ _ _ -> postOpenOpening)
                (\_ _ _ _ _ _ -> postOpenOpening)
                (\_ _ _ _ _ _ -> postOpenOpening)
        either
            (Left . rootedFailure)
            Right
            (rootedOpenedResponseUnsignedKernel (childConfigDigest request) path token stage ordinal)

    {- The sealed external ancestry uses the same grammar as the post-open
    inner path, and it is enforced before the identity comparison so a
    malformed envelope is refused on its own terms. -}
    requireEnvelopeGrammar = do
        require "the sealed external envelope is empty" (not (null envelope))
        require "the sealed external envelope exceeds the requester path depth"
            (length envelope <= maxRootedRequesterComponents)
        require "the sealed external envelope contains an empty component"
            (not (any Text.null envelope))
        require "the sealed external envelope contains an oversized component"
            ( all
                ( (<= maxRootedRequesterComponentBytes)
                    . ByteString.length
                    . TextEncoding.encodeUtf8
                )
                envelope
            )

    postOpenOpening =
        Left (rootedFailure "only an OpenFrame request opens a rooted frame exchange")

{- | Read one session's root-selected coordinates without opening a route.

The continuation receives whether this session has attached, its verb, root
lineage, catalog identity, frame, canonical requester path, opaque session
token, stage, next ordinal, and the first predecessor digest once one exists.
It receives no store, key, record version, catalog, runtime, request, or
response, and its result is fixed.
-}
withRootedFrameSessionKernel ::
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ( Bool ->
      Text ->
      Text ->
      Text ->
      Text ->
      [Text] ->
      Text ->
      Text ->
      Word64 ->
      Maybe Text ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withRootedFrameSessionKernel #-}
withRootedFrameSessionKernel session use = case session of
    OpenedRootedFrameSession verb lineage catalogIdentity frame path token stage ordinal _ _ _ ->
        use False (projectVerbName verb) lineage catalogIdentity frame path token stage ordinal Nothing
    AttachedRootedFrameSession
        (OpenedRootedFrameSession verb lineage catalogIdentity frame path token stage ordinal _ _ _)
        _ predecessor _ _ ->
            use True (projectVerbName verb) lineage catalogIdentity frame path token stage ordinal (Just predecessor)
    AttachedRootedFrameSession AttachedRootedFrameSession{} _ _ _ _ ->
        pure (Left (rootedFailure "a rooted frame session cannot nest two attachments"))

rootedFrameSessionDomain :: Text
rootedFrameSessionDomain = "hostbootstrap/rooted-frame-session"

initialStage :: Text
initialStage = "open"

initialOrdinal :: Word64
initialOrdinal = 1

maxRootedRequesterComponents :: Int
maxRootedRequesterComponents = 256

maxRootedRequesterComponentBytes :: Int
maxRootedRequesterComponentBytes = 4096

framedText :: Text -> ByteString
framedText = frameWire . TextEncoding.encodeUtf8

framedWord :: Word64 -> ByteString
framedWord = frameWire . LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64BE

sessionFailure :: Either SessionError result -> Either Text result
sessionFailure = either (Left . rootedFailure . Text.pack . sessionErrorMessage) Right

require :: Text -> Bool -> Either Text ()
require _ True = Right ()
require detail False = Left (rootedFailure detail)

rootedFailure :: Text -> Text
rootedFailure detail = "rooted frame session: " <> detail
