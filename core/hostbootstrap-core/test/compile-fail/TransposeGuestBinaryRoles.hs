module TransposeGuestBinaryRoles where

import HostBootstrap.Ensure.GuestBootstrap (
    GuestBootstrapTarget,
    GuestBootstrapperExe,
    GuestBuiltBinary,
    GuestInstalledBinary,
    GuestProjectDir,
    GuestSourceRoot,
    GuestToolchainHome,
    PinnedToolchain (PinnedToolchain),
    mkGuestBootstrapTarget,
    mkGuestBootstrapperExe,
    mkGuestBuiltBinary,
    mkGuestInstalledBinary,
    mkGuestPath,
    mkGuestProjectDir,
    mkGuestSourceRoot,
    mkGuestToolchainHome,
 )

transposed :: Either String GuestBootstrapTarget
transposed = do
    sourcePath <- mkGuestPath "/root/hostbootstrap"
    projectPath <- mkGuestPath "/root/hostbootstrap/demo"
    homePath <- mkGuestPath "/root/.ghcup"
    bootstrapperPath <- mkGuestPath "/root/.local/bin/hostbootstrap"
    builtPath <- mkGuestPath "/root/hostbootstrap/demo/.build/hostbootstrap-demo"
    installedPath <- mkGuestPath "/usr/local/bin/hostbootstrap-demo"
    let source :: GuestSourceRoot
        source = mkGuestSourceRoot sourcePath
        project :: GuestProjectDir
        project = mkGuestProjectDir projectPath
        home :: GuestToolchainHome
        home = mkGuestToolchainHome homePath
        bootstrapper :: GuestBootstrapperExe
        bootstrapper = mkGuestBootstrapperExe bootstrapperPath
        built :: GuestBuiltBinary
        built = mkGuestBuiltBinary builtPath
        installed :: GuestInstalledBinary
        installed = mkGuestInstalledBinary installedPath
    mkGuestBootstrapTarget source project home bootstrapper installed built (PinnedToolchain "9.12.4")
