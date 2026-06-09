--| hostbootstrap static-base project-config schema (Dhall).
--
-- This is the one configuration tier the Python bootstrapper reads; it is
-- identical in shape across every project. It matches
-- `haskell/hostbootstrap-core/dhall/Type.dhall` (an anti-drift test asserts the
-- two share one shape): the rich project-level and per-case test Dhall are
-- artifacts the project binary generates — core owns only this static-base type
-- and its in-process decoder.
--
-- A project's `hostbootstrap.dhall` imports this package (injected as `H`) and
-- builds a typed value: `H.config { project = …, dockerfile = …, resources = …
-- }`. The schema carries only the fields the pre-binary Python layer needs:
-- the project name, the Dockerfile to build the project container, and the
-- resource budget used to size the per-project cordon.

let Resources = { cpu : Natural, memory : Text, storage : Text }

let Config = { project : Text, dockerfile : Text, resources : Resources }

let config
    : Config -> Config
    = \(c : Config) -> c

in  { Resources, Config, config }
