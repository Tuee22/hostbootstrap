{-# LANGUAGE CPP #-}
-- Compile the production implementation as a test home module without exporting it.
#define HOSTBOOTSTRAP_BARE_TESTING
#include "../../../src/HostBootstrap/CLI/Bare.hs"
