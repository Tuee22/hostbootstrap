{-# LANGUAGE OverloadedStrings #-}

{- | The stable kernel identity clause 3 of @development_plan_standards.md § EE@
demands, shared by every owned filesystem object.

Clause 3 says ownership binds to the object the kernel knows, never to the
pathname that currently reaches it.  Two harness-owned objects need exactly that
binding — the run's @.test_data\/\<runId\>@ directory
("HostBootstrap.Harness.DataRoot") and the run's generated sibling
@\<project\>.dhall@ ("HostBootstrap.Harness.GeneratedConfig") — and the identity
they bind is the same @(volume, index)@ pair read the same way.  It lives here so
the two protocols cannot drift apart, and so a substrate that cannot supply the
identity refuses both at one place.

The identity itself, its bounds, and its hex journal codec belong to
"HostBootstrap.Ownership.Object", which is the one vocabulary every owner speaks;
this module adds the host seam the two harness protocols read it through and
maps that vocabulary's faults into its own. One type means a record one owner
writes is comparable with an identity another owner read.

The constructor is private: an 'ObjectIdentity' exists only where a backend read
a non-empty identity out of the kernel, so an empty or fabricated value can never
be compared as though it were one.
-}
module HostBootstrap.Harness.Identity (
    -- * Identity
    ObjectIdentity,
    mkObjectIdentity,
    objectIdentityBytes,
    objectIdentityText,
    parseObjectIdentityHex,

    -- * The host seam
    ObjectIdentityBackend (..),

    -- * Failures
    IdentityFault (..),
    identityFaultMessage,
) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    objectIdentityBytes,
    objectIdentityText,
    ownershipFault,
 )
import qualified HostBootstrap.Ownership.Object as Object

{- | Admit raw identity bytes, in this module's fault vocabulary.

The bounds are the shared vocabulary's; only the fault type differs, and it
differs through that vocabulary's total eliminator rather than through a pattern
match that could quietly stop covering a case.
-}
mkObjectIdentity :: ByteString -> Either IdentityFault ObjectIdentity
mkObjectIdentity = either (Left . identityFaultFrom) Right . Object.mkObjectIdentity

-- | Read back a journalled identity, in this module's fault vocabulary.
parseObjectIdentityHex :: Text -> Either IdentityFault ObjectIdentity
parseObjectIdentityHex = either (Left . identityFaultFrom) Right . Object.parseObjectIdentityHex

{- | Carry a shared-vocabulary fault into this protocol's own.

An occupied target and a conflict have no meaning to an identity probe, so both
arrive as the probe fault they in fact are rather than as a case this vocabulary
would have to invent a name for.
-}
identityFaultFrom :: Object.OwnershipFault -> IdentityFault
identityFaultFrom =
    ownershipFault
        IdentityUnsupported
        IdentityProbeFailed
        IdentityMalformed
        (IdentityProbeFailed "read an unoccupied object identity")
        (IdentityProbeFailed "read one object identity" . Object.conflictSubject)

{- | How a driver reads a path's stable kernel identity.

@Right Nothing@ is an authoritative absence; @Left@ is a probe fault, never a
false absence (§ CC).  Production supplies
"HostBootstrap.Harness.Identity.Native"; a test injects one that reports
'IdentityUnsupported' to prove that a host without a stable identity mints no
ownership at all.
-}
newtype ObjectIdentityBackend = ObjectIdentityBackend
    { observeObjectIdentity ::
        FilePath ->
        IO (Either IdentityFault (Maybe ObjectIdentity))
    }

-- | Why an identity could not be established.  Each owning protocol maps these
-- into its own failure vocabulary rather than leaking this one to its callers.
data IdentityFault
    = -- | The host cannot supply a stable identity; no receipt may be minted.
      IdentityUnsupported Text
    | -- | The probe itself failed: @(what was attempted, why)@.
      IdentityProbeFailed Text Text
    | -- | A journalled identity could not be interpreted.
      IdentityMalformed Text
    deriving (Eq, Show)

identityFaultMessage :: IdentityFault -> Text
identityFaultMessage fault = case fault of
    IdentityUnsupported reason -> reason
    IdentityProbeFailed operation reason -> "could not " <> operation <> ": " <> reason
    IdentityMalformed reason -> reason
