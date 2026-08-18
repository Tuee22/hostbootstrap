{- | The closed effect vocabulary.

§ K fixes /which/ executable an invocation names and § HH the /shape/ it is
launched with. § KK fixes what a host-level command /is/: a value in one closed
vocabulary, describing the tool, its exact argument vector, its stdio
disposition, and the frame whose process will interpret it — never a string an
interpreter re-splits, and never an argument vector built by a function that
also runs it.

Everything here is pure. Argument construction is separately testable precisely
because nothing in this module can execute anything; execution belongs to
"HostBootstrap.Effect.Interpreter" alone, and the one process runner beneath it.

The frame is part of the value rather than context a caller remembers, because
it is what decides a path's grammar (§ MM). A path in a command bound for a
guest frame is POSIX on every outer host, and the same path in a command bound
for the outer host is drive-qualified on Windows; nothing about how the string
was derived says which, only which process will read it. 'framePathGrammar' is
the one place that question is answered.

A crossing is /recorded/ here, not rendered here. The argument vector that
crosses into a frame comes from the lift's single fold (§ LL); this vocabulary
carries the resulting argv together with a description of where it lands, so an
effect can be inspected, compared, and tested without a second renderer being
invented to explain it.
-}
module HostBootstrap.Effect.Vocabulary (
    -- * A described host command
    HostCommand (..),
    hostCommand,
    withCommandStdin,
    inFrame,

    -- * The three axes a command differs by
    EffectTarget (..),
    EffectStdio (..),
    EffectFrame (..),
    FrameCrossing (..),

    -- * Which grammar a frame's paths obey
    PathGrammar (..),
    framePathGrammar,
    frameCrossings,

    -- * The closed effect vocabulary
    HostEffect (..),
    DirectHostAction (..),
    hostToolEffect,
)
where

import HostBootstrap.HostTool (HostTool)

{- | Which executable a described command names (§ K).

There is no constructor for a bare command name, because a name resolved through
@$PATH@ is exactly the invocation § K exists to prevent. A tool is named by its
closed 'HostTool' constructor and resolved once; the binary itself is named by
the path the caller already holds for it.
-}
data EffectTarget
    = -- | resolved from the typed host configuration
      ToolTarget HostTool
    | -- | this binary, at a path the caller already holds
      SelfTarget FilePath
    deriving (Eq, Show)

{- | The stdio disposition of a described command (§ HH).

One constructor, because a described command has exactly one lawful shape: it
feeds a string on standard input and reads both output streams, so its failure
cause is somewhere a reader can find it. The two other lawful shapes are not
described commands at all — a child that outlives its launcher is
"HostBootstrap.Detached"'s, and a child holding an inherited descriptor pair is
the handoff process route's — and each seals its own disposition rather than
taking one as a parameter.

It is a constructor rather than a bare 'String' so that a call site cannot omit
the disposition, which is the property § HH asks of it.
-}
newtype EffectStdio = CaptureStreams {effectStdin :: String}
    deriving (Eq, Show)

{- | One frame boundary the command's argument vector already crosses.

The name each carries is the provider's own handle for the frame — a VM name, a
distribution, an image — which is what makes two crossings comparable. It is
descriptive: the argv that performs the crossing came from the lift's one fold.
-}
data FrameCrossing
    = CrossIncusVM String
    | CrossLimaVM String
    | CrossWsl2VM String
    | CrossContainer String
    deriving (Eq, Show)

{- | Which frame's process interprets the command.

'CrossedInto' is non-empty by construction: a command that crosses nothing is
'OuterHost', and the difference between the two is not a length a caller must
check.
-}
data EffectFrame
    = -- | interpreted by a process of the machine the binary is running on
      OuterHost
    | -- | interpreted in another frame, outermost crossing first
      CrossedInto FrameCrossing [FrameCrossing]
    deriving (Eq, Show)

-- | The crossings a frame is reached through, outermost first. Empty for 'OuterHost'.
frameCrossings :: EffectFrame -> [FrameCrossing]
frameCrossings OuterHost = []
frameCrossings (CrossedInto outermost inner) = outermost : inner

{- | The path grammar a frame's own process admits (§ MM).

Two, because two processes read paths: the machine the binary runs on, whose
grammar is its own and is drive-qualified on Windows, and every frame reached
through a host-provider command, which is Linux and therefore POSIX on every
outer host.
-}
data PathGrammar
    = HostPathGrammar
    | PosixGuestGrammar
    deriving (Eq, Show)

{- | Answer "which grammar does a path in this command obey" from the frame
alone.

This is the one place the question is answered, so a validator cannot reason
from the wrong end. A path derived from a host value is still a guest path when
a guest process reads it: the derivation says nothing and the interpretation
says everything.
-}
framePathGrammar :: EffectFrame -> PathGrammar
framePathGrammar OuterHost = HostPathGrammar
framePathGrammar CrossedInto{} = PosixGuestGrammar

{- | A described host-level command: the four things § KK requires of one, and
nothing else.
-}
data HostCommand = HostCommand
    { commandTarget :: EffectTarget
    , commandArguments :: [String]
    , commandStdio :: EffectStdio
    , commandFrame :: EffectFrame
    }
    deriving (Eq, Show)

{- | The ordinary command: a resolved tool run on the outer host with empty
standard input.
-}
hostCommand :: HostTool -> [String] -> HostCommand
hostCommand tool arguments =
    HostCommand
        { commandTarget = ToolTarget tool
        , commandArguments = arguments
        , commandStdio = CaptureStreams ""
        , commandFrame = OuterHost
        }

{- | Feed a command's standard input.

Used to hand a secret to a tool on a channel that is not @argv@, so it never
appears in a process listing.
-}
withCommandStdin :: String -> HostCommand -> HostCommand
withCommandStdin input command = command{commandStdio = CaptureStreams input}

{- | Record which frame interprets a command whose argument vector already
crosses into it.

The crossing itself is the lift fold's; this only says where the result lands,
so a reader and a validator agree with the fold rather than re-deriving it.
-}
inFrame :: EffectFrame -> HostCommand -> HostCommand
inFrame frame command = command{commandFrame = frame}

{- | A single pure host-side effect the lifecycle interpreter runs.

'ApplyGlobalWslWall' and 'ReleaseGlobalWslWall' are the WSL2 @.wslconfig@ wall (a
/global/ user file); 'RunHostCommand' is a described host-level command, and
'RunDirectHost' makes an already-local host transition explicit.

Neither wall effect carries a pathname. The wall is the current user's one
@%UserProfile%\\.wslconfig@, derived by
'HostBootstrap.Wsl2.GlobalWall.Windows' itself, and it is acquired through the
identity-owning host-wall backend rather than a backup copy: an origin record is
journalled before the first mutation and release is conditioned on re-observing
the same object. Release therefore carries the same managed body it was applied
with, because the wall's specification identity binds owner and body together —
a different declaration is a structured conflict, not an overwrite.
-}
data HostEffect
    = -- | acquire the per-user global WSL wall with this managed body
      ApplyGlobalWslWall [String]
    | -- | release the per-user global WSL wall applied with this managed body
      ReleaseGlobalWslWall [String]
    | -- | run one described host-level command
      RunHostCommand HostCommand
    | -- | perform an explicit lifecycle transition on the already-local host
      RunDirectHost DirectHostAction
    deriving (Eq, Show)

-- | The ordinary effect: a resolved tool run on the outer host.
hostToolEffect :: HostTool -> [String] -> HostEffect
hostToolEffect tool arguments = RunHostCommand (hostCommand tool arguments)

{- | Direct-host lifecycle transitions are explicit effects, not silent empty
lists. The generic interpreter can therefore distinguish "the local host is the
selected frame" from "the provider forgot to implement this operation".
-}
data DirectHostAction
    = RealizeDirectHost
    | ReconcileDirectHostReady
    deriving (Eq, Show)
