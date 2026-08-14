{-# LANGUAGE RoleAnnotations #-}

{- | Package-private representation and exact recovery refinement for validated
project configurations.

The public schema module re-exports 'ValidatedConfig' abstractly.  Fresh
validation mints it through 'mintValidatedConfigKernel'; recovered Production
construction can change only its specification phantom, and only through a
token that retains the exact recovered-profile digest for comparison here.
-}
module HostBootstrap.Config.Schema.Internal
    ( ValidatedConfig
    , validatedConfigSpecDigest
    , validatedConfigDigest
    , validatedConfigValue
    , mintValidatedConfigKernel
    , RecoverySpecReindex
    , withRecoverySpecReindexKernel
    , recoverySpecReindexDigestKernel
    , reindexValidatedConfigKernel
    )
where

import Data.Text (Text)

{- | A config value admitted by the matching installed project codec together
with the digest of its exact canonical bytes.  The constructor stays below the
public module boundary.
-}
data ValidatedConfig scope specDigest configId config
    = ValidatedConfig Text Text config

type role ValidatedConfig nominal nominal nominal nominal

validatedConfigSpecDigest ::
    ValidatedConfig scope specDigest configId config ->
    Text
validatedConfigSpecDigest (ValidatedConfig specDigest _ _) = specDigest

validatedConfigDigest ::
    ValidatedConfig scope specDigest configId config ->
    Text
validatedConfigDigest (ValidatedConfig _ digest _) = digest

validatedConfigValue ::
    ValidatedConfig scope specDigest configId config ->
    config
validatedConfigValue (ValidatedConfig _ _ value) = value

-- | Package-private constructor used only after the public codec round trip.
mintValidatedConfigKernel ::
    Text ->
    Text ->
    config ->
    ValidatedConfig scope specDigest configId config
mintValidatedConfigKernel = ValidatedConfig

{- | Package-private request to refine one validated config to the exact
specification identity retained by a recovered profile.
-}
newtype RecoverySpecReindex targetSpecDigest
    = RecoverySpecReindex Text

type role RecoverySpecReindex nominal

{- | Mint reindex authority only when the recovered profile and independently
finalized codec retain the same exact specification digest.
-}
withRecoverySpecReindexKernel ::
    Text ->
    Text ->
    (RecoverySpecReindex targetSpecDigest -> result) ->
    Either (Text, Text) result
withRecoverySpecReindexKernel expected observed use
    | expected == observed = Right (use (RecoverySpecReindex expected))
    | otherwise = Left (expected, observed)

{- | The exact specification digest a minted reindex token proves equal.

Every package-private carrier that relabels its own specification phantom reads
its target digest here, so the token stays the single relabelling authority and
no carrier invents a second comparison source.
-}
recoverySpecReindexDigestKernel :: RecoverySpecReindex targetSpecDigest -> Text
recoverySpecReindexDigestKernel (RecoverySpecReindex expected) = expected

{- | Change only the specification phantom after the token's expected digest
exactly matches the opaque config's retained specification digest.

The existing @configId@, canonical digest, and decoded value are preserved.
-}
reindexValidatedConfigKernel ::
    RecoverySpecReindex targetSpecDigest ->
    ValidatedConfig scope sourceSpecDigest configId config ->
    Either
        (Text, Text)
        (ValidatedConfig scope targetSpecDigest configId config)
reindexValidatedConfigKernel
    (RecoverySpecReindex expected)
    (ValidatedConfig observed digest value)
        | expected == observed =
            Right (ValidatedConfig observed digest value)
        | otherwise = Left (expected, observed)
