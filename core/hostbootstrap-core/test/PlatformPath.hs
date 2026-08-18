{-# LANGUAGE CPP #-}

{- | One total constructor for an absolute __host__ fixture path.

A fixture that names a host executable — the tool tables a @HostConfig@ carries,
and the rendered argument vectors a guard compares against them — names a file
on the machine that runs the suite, so its shape is that machine's own.
@\/test\/bin\/incus@ is absolute on a POSIX host and relative on a Windows one,
while 'HostBootstrap.HostTool.mkAbsExe' is the same total constructor in both
places. A POSIX literal therefore builds a suite that proves its contract on one
outer host realization and refuses its own fixture on another (§ JJ).

'hostFixturePath' takes the segments in POSIX form and renders them under the
platform's own root, so the result is @isAbsolute@ on every supported outer host
realization. It is total, and it is total in the way that matters: the root
comes from the platform rather than from the caller, so no argument — empty,
relative, or POSIX-absolute — can produce a path the host would call relative.

A __guest__ path is not a host path. A path inside a managed VM, a node
container, or a mounted durable root names a file on a different machine reached
through one absolute host-provider command, which is the invocation split § K
already draws. Those literals stay POSIX on every host and must not be routed
through this module.
-}
module PlatformPath
    ( hostFixtureRoot
    , hostFixturePath
    )
where

import System.FilePath (joinPath, (</>))

{- | The absolute root of the host running the suite: @\/@ on POSIX and the
system drive on Windows.
-}
hostFixtureRoot :: FilePath
#if defined(mingw32_HOST_OS)
hostFixtureRoot = "C:\\"
#else
hostFixtureRoot = "/"
#endif

{- | Render POSIX-named fixture segments as an absolute path on this host.

@hostFixturePath "\/test\/bin\/incus"@ is @\/test\/bin\/incus@ on POSIX and
@C:\\test\\bin\\incus@ on Windows.
-}
hostFixturePath :: FilePath -> FilePath
hostFixturePath named = hostFixtureRoot </> joinPath (posixSegments named)

-- | Split on @\/@ alone, so the same argument yields the same segments on every host.
posixSegments :: FilePath -> [String]
posixSegments path =
    case break (== '/') (dropWhile (== '/') path) of
        ("", _) -> []
        (segment, rest) -> segment : posixSegments rest
