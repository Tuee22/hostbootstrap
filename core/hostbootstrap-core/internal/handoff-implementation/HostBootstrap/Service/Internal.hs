{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private representation and exact specification relabelling for the
jointly finalized service registry.

'HostBootstrap.Service' re-exports 'FinalizedServiceRegistry' abstractly
together with every producer and eliminator it owns; the representation stays
here so the nominal specification phantom has exactly one relabelling site.  A
registry admitted under a durably recovered specification index and one
finalized in this invocation are distinct types even when their digests are
equal, and the only authority that can join them is the digest-equality token
minted by 'HostBootstrap.Config.Schema.Internal'.
-}
module HostBootstrap.Service.Internal (
    ServiceId (..),
    ProgramServiceHandler,
    ServiceResourceBackend (..),
    ServiceAction (..),
    FinalizedServiceDefinition (..),
    FinalizedServiceRegistry (..),
    reindexFinalizedServiceRegistryKernel,
)
where

import Data.Text (Text)
import HostBootstrap.Config.Fields.Internal (
    RoleCodec (..),
    RoleParams,
 )
import HostBootstrap.Config.Schema.Internal (
    RecoverySpecReindex,
    recoverySpecReindexDigestKernel,
 )
import HostBootstrap.RoleLifecycle (
    DeclaredEffects,
    RoleAcquireOutcome,
    RolePlanDraft,
    RolePrereqOutcome,
    RoleProbeOutcome,
    RoleReleaseOutcome,
    RoleResourceRequest,
 )
import HostBootstrap.Service.Program (ServiceBackend, ServiceProgram)

-- | A validated service identity. Its constructor stays below this boundary.
newtype ServiceId = ServiceId String
    deriving (Eq, Ord, Show)

{- | One immutable role-parameter bundle in and one closed effect-indexed
program out. The specification, config, secret, and service indices remain
universally quantified; the enclosing definition fixes the payload and row.
-}
type ProgramServiceHandler payload effects fields =
    forall specDigest configId secretDigest service.
    RoleParams specDigest configId secretDigest fields service ->
    ServiceProgram payload service effects ()

{- | The lifecycle half of a program service backend.

The immutable draft and its per-resource operations live in the same
definition as the effect backend.  Selection therefore cannot pair a handler
with another role's acquisition plan, and Serve receives only handles for the
resources this backend actually acquired and probed.
-}
data ServiceResourceBackend = ServiceResourceBackend
    { serviceRolePlanDraft :: RolePlanDraft
    , servicePrerequisite :: IO RolePrereqOutcome
    , serviceAcquireResource :: RoleResourceRequest -> IO RoleAcquireOutcome
    , serviceProbeResource :: RoleResourceRequest -> IO RoleProbeOutcome
    , serviceReleaseResource :: RoleResourceRequest -> IO RoleReleaseOutcome
    }

data ServiceAction fields effects
    = forall payload.
        ProgramServiceAction
        ServiceResourceBackend
        (ServiceBackend payload)
        (ProgramServiceHandler payload effects fields)

{- | One finalized service's identity, scope-specialized projection, declared
effect row, handler, and role codec, all sharing one specification index.
-}
data FinalizedServiceDefinition scope specDigest cfg
    = forall fields effects service.
        FinalizedServiceDefinition
        ServiceId
        (cfg -> Either String (Maybe fields))
        (DeclaredEffects effects)
        (ServiceAction fields effects)
        (RoleCodec scope specDigest fields service)

{- | The closed finalized registry: the exact specification digest its
finalization stamped, and the definitions carrying that same digest.

The retained digest is what makes a relabelling checkable even for a project
that registers no service at all.
-}
data FinalizedServiceRegistry scope specDigest cfg
    = FinalizedServiceRegistry Text [FinalizedServiceDefinition scope specDigest cfg]

type role FinalizedServiceRegistry nominal nominal nominal

{- | Change only the specification phantom of a finalized registry, and only
after the token's expected digest exactly matches the digest the registry and
every one of its role codecs already retain.

The retained identities, projections, declared effect rows, handlers, and role
codec terms are preserved unchanged: this relabels an index, it never finalizes
a second registry.  The caller supplies no digest of its own, so an unequal pair
is a refusal rather than a silently accepted relabelling.
-}
reindexFinalizedServiceRegistryKernel ::
    RecoverySpecReindex targetSpecDigest ->
    FinalizedServiceRegistry scope sourceSpecDigest cfg ->
    Either (Text, Text) (FinalizedServiceRegistry scope targetSpecDigest cfg)
reindexFinalizedServiceRegistryKernel token (FinalizedServiceRegistry retained definitions)
    | expected /= retained = Left (expected, retained)
    | otherwise = FinalizedServiceRegistry retained <$> traverse relabel definitions
  where
    expected = recoverySpecReindexDigestKernel token
    relabel (FinalizedServiceDefinition identity select effects run codec)
        | expected /= internalRoleSpecDigest codec =
            Left (expected, internalRoleSpecDigest codec)
        | otherwise =
            Right
                ( FinalizedServiceDefinition
                    identity
                    select
                    effects
                    run
                    RoleCodec
                        { internalRoleName = internalRoleName codec
                        , internalRoleScopeKind = internalRoleScopeKind codec
                        , internalRoleSpecDigest = internalRoleSpecDigest codec
                        , internalRoleWireCodec = internalRoleWireCodec codec
                        }
                )
