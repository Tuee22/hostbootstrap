-- The static-base hostbootstrap.dhall record type.
--
-- This is the one configuration tier the Python bootstrapper reads; it is
-- identical in shape across every project. The rich project-level and per-case
-- test Dhall are artifacts the project binary generates — core owns only this
-- static-base type and its decoder (HostBootstrap.Config.Schema). An anti-drift
-- test asserts this type and the Python-side dhall/package.dhall `Config` share
-- one shape.
{ project : Text
, dockerfile : Text
, resources : { cpu : Natural, memory : Text, storage : Text }
}
