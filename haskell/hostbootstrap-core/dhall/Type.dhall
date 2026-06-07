-- The skeletal hostbootstrap.dhall record type.
--
-- This is the one configuration tier the Python bootstrapper reads; it is
-- identical in shape across every project. The rich project-level and per-case
-- test Dhall are artifacts the project binary generates — core owns only this
-- skeletal type and its decoder (HostBootstrap.Config.Schema).
{ project : Text
, dockerfile : Text
, resources : { cpu : Natural, memory : Text, storage : Text }
}
