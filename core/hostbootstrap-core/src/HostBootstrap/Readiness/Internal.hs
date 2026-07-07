-- | The unsealed innards of "HostBootstrap.Readiness": the 'Ready' witness
-- constructor, exposed ONLY for the test-suite. Production code imports
-- "HostBootstrap.Readiness", which re-exports 'Ready' abstractly (constructor
-- hidden), so a readiness witness can only be minted by an actual poll
-- ('HostBootstrap.Readiness.awaitReady') — making "act before ready"
-- unrepresentable wherever a 'Ready' is required.
module HostBootstrap.Readiness.Internal
  ( Ready (..),
  )
where

-- | A phantom-tagged proof that a dependency has been polled to readiness. @tag@
-- is a phantom (an empty marker type) so @Ready RegistryServing@ and
-- @Ready MinioReady@ are DISTINCT types — a witness minted for one boundary
-- cannot satisfy another. The constructor is exported here only for the
-- test-suite; production code obtains 'Ready' abstractly from
-- "HostBootstrap.Readiness".
data Ready tag = MkReady
