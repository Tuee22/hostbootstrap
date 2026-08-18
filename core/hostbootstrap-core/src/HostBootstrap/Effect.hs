{- | The library's effect-composition surface.

A consuming project composes host commands and must reach the same vocabulary,
the same quoter, the same interpreter, and the same runner the library uses,
because a second copy in a consumer is the same defect as a second copy inside
the library (§ KK). This module is what a consumer imports.
-}
module HostBootstrap.Effect (
    -- * The closed vocabulary
    module HostBootstrap.Effect.Vocabulary,

    -- * The one interpreter
    module HostBootstrap.Effect.Interpreter,

    -- * The one shell quoter
    shellQuoteArg,
    shellQuoteArgs,
    powerShellQuoteArg,

    -- * The one process runner
    CapturedRun (..),
    capturedTriple,
    RunFailure (..),
    renderRunFailure,
    runCaptured,
    RunNamespace (..),
    RunBounds (..),
    BoundedRun (..),
    runBoundedGrouped,
)
where

import HostBootstrap.Effect.Interpreter
import HostBootstrap.Effect.Quote (powerShellQuoteArg, shellQuoteArg, shellQuoteArgs)
import HostBootstrap.Effect.Run (
    BoundedRun (..),
    CapturedRun (..),
    RunBounds (..),
    RunFailure (..),
    RunNamespace (..),
    capturedTriple,
    renderRunFailure,
    runBoundedGrouped,
    runCaptured,
 )
import HostBootstrap.Effect.Vocabulary
