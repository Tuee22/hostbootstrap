{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

{- | The fixed dependencies a frame installs before it can take part in a
recursive lifecycle handoff.

A recursive handoff needs two things and nothing more: whose signature to
trust, and whether this frame is the one that may sign. This module installs
exactly those.

What it deliberately is not is a capability. A 'RecursiveHandoffRuntime' holds
no signing key, protected store, root broker, channel, catalog, or frame
session; it opens no journal and mutates nothing durable. Its one eliminator
hands back derived identity coordinates under a fixed unit result, so holding
one lets a frame say who it is — never do the routing's authorized work.

The lifecycle-only policy is absence rather than a filter. This module names no
protocol tag, no activation manifest, no build material, and no channel, so a
runtime cannot express a route to any of them; a frame that wants one has to go
somewhere else and be refused there on its own terms.

The distinction it does carry is the one that matters at every depth. The root
arm is derived from a live root broker and its matching scope, so it names the
private signer. Every other arm is derived from an already authenticated parent
edge and names a keyless relay that can only move exact bytes. Reading that
distinction off a runtime is how later work stays honest about which frame is
allowed to sign, without any frame being handed the means to decide otherwise.
-}
module HostBootstrap.Handoff.Runtime
    ( RecursiveHandoffRuntime
    , rootRecursiveHandoffRuntimeKernel
    , nestedRecursiveHandoffRuntimeKernel
    , withRecursiveHandoffRuntimeKernel
    , withRootArmRecursiveHandoffRuntimeKernel
    , withNestedArmRecursiveHandoffRuntimeKernel
    )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority
    ( ProjectVerb
    , RootInvocationAuthority
    , brokerEpochWord
    , projectVerbName
    , rootAuthorityEpoch
    , rootAuthorityProjectName
    , rootAuthorityVerb
    )
import HostBootstrap.Authority.Kernel (rootAuthorityStoreIdentity)
import HostBootstrap.Handoff
    ( BrokerRoute
    , HandoffBinding
    , HandoffScope
    , RootBroker
    , brokerRouteCurrentFrame
    , brokerRouteVerificationKeyDigest
    , handoffBrokerGeneration
    , handoffChildFrame
    , handoffInstalledProject
    , handoffScope
    , handoffScopeProject
    , handoffScopeTag
    , handoffStoreIdentity
    , handoffVerb
    , rootBrokerVerificationKey
    , verificationKeyDigest
    )

{- | One frame's installed recursive-handoff trust and arm.

The two arms are the whole content of the type. Both retain the same derived
identity coordinates — installed project, scope tag, protected-store identity,
broker generation, and installed verification-key digest — and the closed verb
this invocation runs under. Only the nested arm additionally retains the
authenticated frame its keyless relay speaks for, because only a nested frame
has one; the root is path-agnostic and has none.
-}
data RecursiveHandoffRuntime scope brokerGeneration verb where
    RootRecursiveHandoffRuntime ::
        ProjectVerb verb ->
        Text ->
        Text ->
        Text ->
        Word64 ->
        ByteString ->
        RecursiveHandoffRuntime scope brokerGeneration verb
    NestedRecursiveHandoffRuntime ::
        ProjectVerb verb ->
        Text ->
        Text ->
        Text ->
        Word64 ->
        ByteString ->
        Text ->
        RecursiveHandoffRuntime scope brokerGeneration verb

type role RecursiveHandoffRuntime nominal nominal nominal

instance Show (RecursiveHandoffRuntime scope brokerGeneration verb) where
    show RootRecursiveHandoffRuntime{} = "RecursiveHandoffRuntime <root signing arm>"
    show NestedRecursiveHandoffRuntime{} = "RecursiveHandoffRuntime <keyless relay arm>"

{- | Install the root arm from the live broker and its matching scope.

Every retained coordinate comes from the admitted root environment: the
invocation authority supplies the installed project, protected-store identity,
broker generation, and verb, the scope evidence supplies the descriptive tag,
and the broker itself supplies the verification identity a child independently
installs. No key, tag, domain, or policy is accepted from a caller, and the
broker is not retained.

The route is cross-checked rather than trusted: its advertised key digest must
be the one this broker's own public half hashes to, and it must carry no
authenticated current frame, because a root has none.
-}
rootRecursiveHandoffRuntimeKernel ::
    RootBroker scope brokerGeneration verb ->
    HandoffScope scope ->
    BrokerRoute scope brokerGeneration ->
    RootInvocationAuthority scope brokerGeneration verb ->
    ProjectVerb verb ->
    Either Text (RecursiveHandoffRuntime scope brokerGeneration verb)
{-# OPAQUE rootRecursiveHandoffRuntimeKernel #-}
rootRecursiveHandoffRuntimeKernel broker scope route root verb = do
    require "the scope evidence names a different installed project than the root authority"
        (handoffScopeProject scope == project)
    require "the runtime verb differs from the root authority"
        (verbName == projectVerbName (rootAuthorityVerb root))
    require "the root route advertises a different installed verification key"
        (brokerRouteVerificationKeyDigest route == keyDigest)
    require "a root runtime cannot hold an authenticated current frame"
        (isNothing (brokerRouteCurrentFrame route))
    requireIdentity project tag store generation keyDigest verbName
    pure (RootRecursiveHandoffRuntime verb project tag store generation keyDigest)
  where
    project = rootAuthorityProjectName root
    tag = handoffScopeTag scope
    store = rootAuthorityStoreIdentity root
    generation = brokerEpochWord (rootAuthorityEpoch root)
    verbName = projectVerbName verb
    keyDigest =
        TextEncoding.encodeUtf8 (verificationKeyDigest (rootBrokerVerificationKey broker))

{- | Install a nested arm from one already authenticated parent edge.

The binding is the authenticated record of what the root opened, so the
coordinates are the root's rather than this frame's. The route must name this
frame as its authenticated current frame, which is exactly what distinguishes a
relayed route from the root's own; a nested runtime therefore cannot be built
from a route that has no frame, and the root arm cannot be built from one that
has.
-}
nestedRecursiveHandoffRuntimeKernel ::
    BrokerRoute scope brokerGeneration ->
    HandoffBinding scope brokerGeneration ->
    ProjectVerb verb ->
    Either Text (RecursiveHandoffRuntime scope brokerGeneration verb)
{-# OPAQUE nestedRecursiveHandoffRuntimeKernel #-}
nestedRecursiveHandoffRuntimeKernel route binding verb = do
    require "the runtime verb differs from the authenticated edge"
        (verbName == handoffVerb binding)
    require "the relayed route does not name the authenticated child frame"
        (brokerRouteCurrentFrame route == Just frame)
    require "the authenticated child frame is empty" (not (Text.null frame))
    requireIdentity project tag store generation keyDigest verbName
    pure (NestedRecursiveHandoffRuntime verb project tag store generation keyDigest frame)
  where
    project = handoffInstalledProject binding
    tag = handoffScope binding
    store = handoffStoreIdentity binding
    generation = handoffBrokerGeneration binding
    verbName = projectVerbName verb
    frame = handoffChildFrame binding
    keyDigest = brokerRouteVerificationKeyDigest route

{- | Read one runtime's arm and identity without opening a route.

The continuation receives whether this frame signs locally, the installed
project, scope tag, protected-store identity, broker generation, invocation
verb, installed verification-key digest, and the nested arm's authenticated
frame if it has one. It receives no key, store, broker, channel, or route
value, and its result is fixed, so no caller-selected outcome escapes an
elimination.
-}
withRecursiveHandoffRuntimeKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    ( Bool ->
      Text ->
      Text ->
      Text ->
      Word64 ->
      Text ->
      ByteString ->
      Maybe Text ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withRecursiveHandoffRuntimeKernel #-}
withRecursiveHandoffRuntimeKernel runtime use = case runtime of
    RootRecursiveHandoffRuntime verb project tag store generation keyDigest ->
        use True project tag store generation (projectVerbName verb) keyDigest Nothing
    NestedRecursiveHandoffRuntime verb project tag store generation keyDigest frame ->
        use False project tag store generation (projectVerbName verb) keyDigest (Just frame)

{- | Read one runtime that must be the signing arm, and nothing else.

The general eliminator above is honest about both arms, which is what a caller
that only wants to say who it is needs. A caller that is about to reach the
root's own signer needs the opposite: the nested arm must not be describable at
all, so it is refused here rather than handed over with a @False@ beside it.

What the continuation receives is therefore the root's identity without the
authenticated frame the general fold carries, because a root has none. It still
receives no key, store, broker, channel, or route, and its result is still
fixed, so this narrows which runtimes may proceed without widening what any of
them discloses.
-}
withRootArmRecursiveHandoffRuntimeKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    ( Text ->
      Text ->
      Text ->
      Word64 ->
      Text ->
      ByteString ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withRootArmRecursiveHandoffRuntimeKernel #-}
withRootArmRecursiveHandoffRuntimeKernel runtime use = case runtime of
    RootRecursiveHandoffRuntime verb project tag store generation keyDigest ->
        use project tag store generation (projectVerbName verb) keyDigest
    NestedRecursiveHandoffRuntime{} ->
        pure (Left (failure "a keyless nested arm has no root recursive handoff runtime"))

{- | Read one runtime that must be the keyless relay arm, and nothing else.

This is the narrowing the root fold above is the mirror of. A caller that is
about to open a child's protocol channel needs the opposite guarantee from one
about to reach the signer: the frame on the far end must be an authenticated
nested frame, not a root standing in for one, so the root arm is refused here
rather than handed over with a @Nothing@ beside it.

What the continuation receives is therefore the same installed identity the
general fold discloses, except that the authenticated frame arrives as the
frame itself. A caller no longer has a case to write for a runtime that has
none, which is what stops a route from being derived against a frame nobody
authenticated. It still receives no key, store, broker, channel, or route, and
its result is still fixed.
-}
withNestedArmRecursiveHandoffRuntimeKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    ( Text ->
      Text ->
      Text ->
      Word64 ->
      Text ->
      ByteString ->
      Text ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withNestedArmRecursiveHandoffRuntimeKernel #-}
withNestedArmRecursiveHandoffRuntimeKernel runtime use = case runtime of
    NestedRecursiveHandoffRuntime verb project tag store generation keyDigest frame ->
        use project tag store generation (projectVerbName verb) keyDigest frame
    RootRecursiveHandoffRuntime{} ->
        pure (Left (failure "a root arm speaks for no authenticated nested frame"))

requireIdentity :: Text -> Text -> Text -> Word64 -> ByteString -> Text -> Either Text ()
requireIdentity project tag store generation keyDigest verbName = do
    require "the installed project is empty" (not (Text.null project))
    require "the scope tag is empty" (not (Text.null tag))
    require "the protected-store identity is empty" (not (Text.null store))
    require "the broker generation is zero" (generation > 0)
    require "the installed verification-key digest is empty" (not (ByteString.null keyDigest))
    require "the invocation verb is empty" (not (Text.null verbName))

require :: Text -> Bool -> Either Text ()
require _ True = Right ()
require detail False = Left (failure detail)

failure :: Text -> Text
failure detail = "recursive handoff runtime: " <> detail
