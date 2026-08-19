{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The two ends of one frame crossing: the parent that runs a transaction at
another frame, and the process that recognizes it is that frame.

Everything else in this phase authenticates an /admission/ — a parent offers an
edge, a child challenges it, the root grants it, and only then does the child
hold anything. A frame crossing is a different shape. The parent already owns
the object the transaction is about; what it lacks is a process where that
object lives. So this module carries one opaque transaction out and one opaque
outcome back, and interprets neither: the bytes belong to whichever phase owns
the object, and the framing belongs here.

The far side has to be reachable before it can be interesting, and reaching it
is entirely a question of argument vectors. A process of this binary is handed
no environment, no descriptor it can name, and no coordinate that says which
frame it woke up in — it has @argv@ and two streams. So 'classifyFrameChild' is
a total pure function of @argv@ alone, it runs before the parser, and what it
returns carries nothing: no path, no authority, no caller-selected action, and
no route to a project's extension streams (§ P). A frame child is a frame child
regardless of which spec built the binary, so the bare binary and every project
binary reach this entry by the same route.

The marker names nothing an operator can use. It is absent from @--help@
because it is not in the command tree at all, and a process launched with it
refuses unless its standard input and output are the protocol channel — which,
outside a frame crossing, they are not.

What the child does with a transaction is not this phase's to decide. This phase
validates the crossing's structure and carries an answer; the phase that owns an
object installs the interpreter that produces its outcome, and the interpreter
is a parameter of the child entry rather than a branch here. A frame that cannot
read the bytes it was handed answers a refusal rather than closing the pipe, so
a parent learns that the far side declined instead of inferring it from a stream
that ended.
-}
module HostBootstrap.Handoff.Transaction
    ( -- * The far side
      FrameChildEntry
    , classifyFrameChild
    , frameChildArguments
    , FrameInterpreter
    , frameInterpreter
    , runFrameChildEntry

      -- * The near side
    , withFrameChildTransaction
    , FrameAnswer (..)
    , readFrameAnswer
    )
where

import qualified Control.Exception as Exception
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Handoff.Protocol
    ( HandoffChannel
    , ProtocolError
    , ProtocolMessage
    , ProtocolTag (FrameOutcomeTag, FrameTransactionTag, RefusedTag)
    , channelReceive
    , channelSend
    , handoffChannel
    , protocolErrorMessage
    , protocolMessage
    , protocolMessageFields
    , protocolMessageRequestId
    , protocolMessageTag
    , withPrivateProtocolStdio
    )
import HostBootstrap.HostConfig (HostConfig, resolveMaybe)
import HostBootstrap.HostTool (absExePath)
import HostBootstrap.Lift
    ( LiftContext
    , LiftDispatch (DispatchLocal, DispatchTool)
    , SelfRef
    , foldLift
    )
import Control.Concurrent (threadDelay)
import System.Exit (ExitCode, die)
import System.IO (Handle, hClose)
import System.Process
    ( CreateProcess (close_fds, create_group, std_err, std_in, std_out)
    , ProcessHandle
    , StdStream (CreatePipe, Inherit)
    , getProcessExitCode
    , proc
    , waitForProcess
    , withCreateProcess
    )
import System.Timeout (timeout)
#if defined(mingw32_HOST_OS)
import System.Process (interruptProcessGroupOf, terminateProcess)
#else
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcessGroup)
import System.Process (getPid)
#endif

-- ---------------------------------------------------------------------------
-- The far side

{- | Evidence that this process is the far side of a frame crossing.

It is deliberately the poorest value in the module. A frame child is told
nothing by being one: not which frame it is, not which object the transaction
concerns, not who launched it, and not what it may do. Everything it will ever
learn arrives on the channel, authenticated by whoever owns the object, so
there is no field here for a coordinate to hide in and no function from this to
a path, an authority, or an action.
-}
data FrameChildEntry = FrameChildEntry
    deriving (Eq, Show)

{- | The complete argument vector a frame child is launched with.

It is a list rather than a marker string because it is what the lift fold
places at the leaf, and a leaf argv with a second element would be a different
process. 'classifyFrameChild' compares against exactly this, so the launch and
the recognition cannot drift apart.
-}
frameChildArguments :: [String]
frameChildArguments = ["--hostbootstrap-frame-child"]

{- | Decide, from @argv@ alone, whether this process is a frame child.

Total and pure. The argument vector is compared whole: a marker with anything
before it, anything after it, a different spelling, or a different case is not
this entry, because a frame child is launched by the fold below and by nothing
else, and the fold produces exactly one vector.
-}
classifyFrameChild :: [String] -> Maybe FrameChildEntry
classifyFrameChild argv
    | argv == frameChildArguments = Just FrameChildEntry
    | otherwise = Nothing

{- | Answer exactly one transaction on the channel this process was launched
with, then return.

The descriptors are taken through the isolation this phase already owns, so the
protocol pair is private and an ordinary write inside anything that runs here
becomes a diagnostic rather than a byte in the middle of a frame. A stream that
does not decode as the channel is the operator case — someone typed the marker
— and it is refused with a diagnostic and a failing status rather than
answered.
-}
runFrameChildEntry :: FrameInterpreter -> FrameChildEntry -> IO ()
runFrameChildEntry interpret FrameChildEntry = do
    served <- withPrivateProtocolStdio (serveOneFrameTransaction interpret)
    either (die . Text.unpack . frameChildFailure) pure served

{- | How a frame answers one transaction it was handed.

Opaque in both directions, so the framing never learns what the bytes mean and
the phase that owns the object never learns how they travelled. The interpreter
is supplied by the caller because it is not this phase's: what a transaction
/means/ belongs to the phase that owns the object, and this one owns only the
framing.
-}
newtype FrameInterpreter = FrameInterpreter (ByteString -> IO (Either Text ByteString))

{- | Install an interpreter for the objects a phase owns. -}
frameInterpreter :: (ByteString -> IO (Either Text ByteString)) -> FrameInterpreter
frameInterpreter = FrameInterpreter



{- | Read one framed transaction and send one framed answer.

The read is the whole admission check this end performs: a frame child holds no
key, no store, and no authority, so there is nothing here for a signature to
protect. What it does hold is the framing, and a stream that is not this
protocol is refused before a request identity exists.
-}
serveOneFrameTransaction :: FrameInterpreter -> HandoffChannel -> IO (Either Text ())
serveOneFrameTransaction (FrameInterpreter interpret) channel = do
    received <- channelReceive channel
    case received of
        Left failure -> pure (Left (protocolFailure failure))
        Right message
            | protocolMessageTag message /= FrameTransactionTag ->
                pure
                    ( Left
                        ( "expected a frame transaction, saw "
                            <> Text.pack (show (protocolMessageTag message))
                        )
                    )
            | otherwise -> case protocolMessageFields message of
                [transaction] -> do
                    answered <- interpret transaction
                    case answered of
                        Left detail ->
                            sendRefusal
                                channel
                                (protocolMessageRequestId message)
                                (TextEncoding.encodeUtf8 detail)
                        Right outcome ->
                            sendOutcome channel (protocolMessageRequestId message) outcome
                fields ->
                    pure
                        ( Left
                            ( "a frame transaction carries one field, saw "
                                <> Text.pack (show (length fields))
                            )
                        )

{- | Carry back what the interpreter produced, in the frame it belongs in.

An answer rather than a closed pipe, for the same reason every other refusal in
this phase is sent: a parent that reads a refusal knows its child declined,
while a parent that reads EOF knows only that something ended.
-}
sendOutcome :: HandoffChannel -> Word64 -> ByteString -> IO (Either Text ())
sendOutcome channel request outcome =
    sendFramed channel (protocolMessage FrameOutcomeTag request [outcome])

sendRefusal :: HandoffChannel -> Word64 -> ByteString -> IO (Either Text ())
sendRefusal channel request detail =
    sendFramed channel (protocolMessage RefusedTag request [uninterpretedCode, detail])

sendFramed :: HandoffChannel -> Either ProtocolError ProtocolMessage -> IO (Either Text ())
sendFramed channel built = case built of
    Left failure -> pure (Left (protocolFailure failure))
    Right message -> do
        sent <- channelSend channel message
        pure (either (Left . protocolFailure) Right sent)

{- | The one code a frame's refusal carries.

The detail is the frame's own; the code says only that the far side declined,
because this phase does not interpret what it declined about.
-}
uninterpretedCode :: ByteString
uninterpretedCode = "unavailable"


-- ---------------------------------------------------------------------------
-- The near side

{- | Run one transaction at the frame @context@ names, and leave nothing behind.

The invocation is produced by the lift fold and by nothing else: the caller
supplies the context stack, and the leaf is this binary's own frame-child
entry, so there is no argument through which an executable, an image, or an
argument vector is chosen. A local context runs the transaction in this frame's
own child process; a context with layers folds to the host tool that crosses
them, resolved to an absolute path through the installed configuration (§ K).

The child lives inside one bracket. It is launched into its own process group
with its standard input and output on private pipes and its standard error
inherited, so diagnostics reach the operator while the protocol keeps the pipes
to itself. On the way out — a returned outcome, a refusal, a protocol failure,
an exception, or asynchronous cancellation alike — the group is asked to stop,
given a fixed grace, killed if it is still there, and reaped unconditionally,
and every descriptor this bracket opened is closed.

Ending the /group/ rather than the process is what makes a shell or provider
the child launched go away with it. That is a platform row: it is compiled on
every gate host and conditionalized only where it names a signal, so no host
family loses this entry from the build (§ JJ).
-}
withFrameChildTransaction ::
    HostConfig ->
    SelfRef ->
    LiftContext ->
    -- | the transaction, opaque here and owned by the phase that produced it
    ByteString ->
    IO (Either Text ByteString)
withFrameChildTransaction config self context transaction =
    case foldLift self context frameChildArguments of
        DispatchLocal executable arguments -> spawned executable arguments
        DispatchTool tool arguments ->
            case resolveMaybe config tool of
                Nothing ->
                    pure
                        ( Left
                            (frameChildFailure "the crossing's host tool resolves to no absolute path")
                        )
                Just executable -> spawned (absExePath executable) arguments
  where
    spawned executable arguments =
        withCreateProcess (frameChildProcess executable arguments) $
            \inbound outbound _ child ->
                case (inbound, outbound) of
                    (Just childStdin, Just childStdout) ->
                        Exception.bracket_
                            (pure ())
                            (endChildGroup child childStdin childStdout)
                            (exchange childStdin childStdout)
                    _ ->
                        pure
                            ( Left
                                (frameChildFailure "the child was launched without its own pipes")
                            )

    exchange childStdin childStdout = do
        opened <- timeout launchMicros (handoffChannel childStdout childStdin)
        case opened of
            Nothing ->
                pure
                    ( Left
                        (frameChildFailure "the child never opened its protocol channel")
                    )
            Just channel -> oneTransaction channel transaction

{- | The only process shape this owner ever launches. -}
frameChildProcess :: FilePath -> [String] -> CreateProcess
frameChildProcess executable arguments =
    (proc executable arguments)
        { std_in = CreatePipe
        , std_out = CreatePipe
        , std_err = Inherit
        , create_group = True
        , close_fds = True
        }

{- | Send the transaction, read the answer, and classify it.

One request is outstanding at a time and exactly one answer ends the exchange,
so the request identity is fixed rather than negotiated: there is no second
message for a counter to disambiguate, and a child that echoes a different one
is answering something this parent never asked.
-}
oneTransaction :: HandoffChannel -> ByteString -> IO (Either Text ByteString)
oneTransaction channel transaction =
    case protocolMessage FrameTransactionTag frameTransactionRequest [transaction] of
        Left failure -> pure (Left (protocolFailure failure))
        Right request -> do
            sent <- channelSend channel request
            case sent of
                Left failure -> pure (Left (protocolFailure failure))
                Right () -> do
                    received <- channelReceive channel
                    pure $ case received of
                        Left failure -> Left (protocolFailure failure)
                        Right answer ->
                            readFrameAnswer
                                frameTransactionRequest
                                (protocolMessageRequestId answer)
                                (frameAnswer answer)

{- | The request identity every frame crossing uses. -}
frameTransactionRequest :: Word64
frameTransactionRequest = 1

{- | What a frame said, projected out of the message it said it in.

The projection exists so that the /decision/ a parent makes about a crossing is
a total function of values rather than of a message only this library can build
(§ NN). A reader that has to launch a process to reach a branch cannot cover the
branches a process does not take, and the branch that matters most here is the
one where a frame answers something this exchange never asked for.
-}
data FrameAnswer
    = -- | the transaction's outcome, uninterpreted here
      FrameOutcome ByteString
    | -- | the frame declined, carrying its own code and detail
      FrameRefusal ByteString ByteString
    | -- | a tag the framing allows and this exchange does not, and its arity
      FrameUnexpected Text Int
    deriving (Eq, Show)

frameAnswer :: ProtocolMessage -> FrameAnswer
frameAnswer message =
    case (protocolMessageTag message, protocolMessageFields message) of
        (FrameOutcomeTag, [outcome]) -> FrameOutcome outcome
        (RefusedTag, [code, detail]) -> FrameRefusal code detail
        (tag, fields) -> FrameUnexpected (Text.pack (show tag)) (length fields)

{- | Decide what one answer means for the request it had to answer.

Total. An outcome is returned uninterpreted, because its bytes belong to
whichever phase produced the transaction; a refusal is reported with the
frame's own code and detail, so the reason survives the crossing; and an answer
to a different request is a failure of the exchange rather than a late reply,
because exactly one request is ever outstanding.
-}
readFrameAnswer :: Word64 -> Word64 -> FrameAnswer -> Either Text ByteString
readFrameAnswer expected observed answer
    | observed /= expected =
        Left
            ( frameChildFailure
                ( "the child answered request "
                    <> Text.pack (show observed)
                    <> " rather than "
                    <> Text.pack (show expected)
                )
            )
    | otherwise = case answer of
        FrameOutcome outcome -> Right outcome
        FrameRefusal code detail ->
            Left
                ( frameChildFailure
                    ( "the frame refused the transaction: "
                        <> TextEncoding.decodeUtf8Lenient code
                        <> ": "
                        <> TextEncoding.decodeUtf8Lenient detail
                    )
                )
        FrameUnexpected tag fields ->
            Left
                ( frameChildFailure
                    ( "the child answered "
                        <> tag
                        <> " with "
                        <> Text.pack (show fields)
                        <> " fields"
                    )
                )

-- ---------------------------------------------------------------------------
-- Ending the child

{- | End the child's whole group, then reap it, whatever happened above.

Termination is attempted first and escalated only if the group is still present
after the grace, because a child that is finishing an effect deserves the chance
to finish it; the escalation exists because a child that is not finishing
anything must not become the operator's problem. The wait is unconditional — a
reaped child is the only kind that is not a zombie — and the pipes are closed
last, quietly, because a descriptor left open outlives the process that
justified it.
-}
endChildGroup :: ProcessHandle -> Handle -> Handle -> IO ()
endChildGroup child childStdin childStdout = do
    finished <- getProcessExitCode child
    case finished of
        Just _ -> pure ()
        Nothing -> do
            askChildGroupToStop child
            lingering <- waitFor terminationGraceMicros child
            case lingering of
                Just _ -> pure ()
                Nothing -> killChildGroup child
    _ <- Exception.try (waitForProcess child) :: IO (Either Exception.SomeException ExitCode)
    closeQuietly childStdin
    closeQuietly childStdout

{- | Ask the child's own group to stop, or accept that there is no longer one.

The two rows differ only in which primitive names a group. A POSIX host signals
the process group the child was launched into; a Windows host interrupts the
console process group the same launch created. Neither reaches beyond the
child's group, because the launch put the child in its own.
-}
askChildGroupToStop :: ProcessHandle -> IO ()
#if defined(mingw32_HOST_OS)
askChildGroupToStop child = quietly (interruptProcessGroupOf child)
#else
askChildGroupToStop child = signalChildGroup child sigTERM
#endif

{- | End the child's group with something it cannot decline. -}
killChildGroup :: ProcessHandle -> IO ()
#if defined(mingw32_HOST_OS)
killChildGroup child = quietly (terminateProcess child)
#else
killChildGroup child = signalChildGroup child sigKILL
#endif

#if !defined(mingw32_HOST_OS)
{- | Signal the child's own group, or accept that there is no longer one. -}
signalChildGroup :: ProcessHandle -> Signal -> IO ()
signalChildGroup child signal = do
    identity <- getPid child
    case identity of
        Nothing -> pure ()
        Just pid -> quietly (signalProcessGroup signal (fromIntegral pid))
#endif

{- | Poll for the child's exit until the grace runs out. -}
waitFor :: Int -> ProcessHandle -> IO (Maybe ExitCode)
waitFor remaining child
    | remaining <= 0 = getProcessExitCode child
    | otherwise = do
        exited <- getProcessExitCode child
        case exited of
            Just status -> pure (Just status)
            Nothing -> do
                threadDelay pollMicros
                waitFor (remaining - pollMicros) child

closeQuietly :: Handle -> IO ()
closeQuietly handle = quietly (hClose handle)

quietly :: IO () -> IO ()
quietly act = do
    attempted <- Exception.try act
    either (\(_ :: Exception.IOException) -> pure ()) pure attempted

{- | How long a child has to exist at all. -}
launchMicros :: Int
launchMicros = 30 * 1000000

{- | How long a signalled group has to finish before it is killed. -}
terminationGraceMicros :: Int
terminationGraceMicros = 10 * 1000000

{- | How often the grace is checked. -}
pollMicros :: Int
pollMicros = 50 * 1000

protocolFailure :: ProtocolError -> Text
protocolFailure = frameChildFailure . Text.pack . protocolErrorMessage

frameChildFailure :: Text -> Text
frameChildFailure detail = "frame child: " <> detail
