{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}

{- | What the cluster's three tools say, as one set of total classifications.

"HostBootstrap.Cluster.Command" says what to ask; this module says what an answer
means. Every function is total over the interpreter's own outcome — @Left@ for a
command that produced no child, @Right@ for one that ran — so every refusal is
reachable by application over values and needs no substitution point to be
exercised (§ NN).

The distinction the whole module exists for is between __"the tool says this is
not here"__ and __"the tool did not answer"__. The first authorizes a mutation
and the second must not, so a report that is too long, that carries a carriage
return or a byte outside ASCII, that does not end in exactly one newline, that
carries an empty row, or that names the same object twice is a __refusal__ rather
than an absence. A driver comparing an identity it did not understand would be
answering a question nobody asked.

One answer deliberately does not refuse. The API server's readiness endpoint
failing is a fact about the control plane rather than about the tool, so it is
'ApiNotReady' — a cluster that is not ready yet is exactly what a readiness poll
expects to see, and turning it into a fault would make waiting impossible.
-}
module HostBootstrap.Cluster.Report (
    -- * What the tools report
    ClusterPresence (..),
    ContainerRunState (..),
    ApiReadiness (..),
    NodeReadiness (..),

    -- * Why a report could not be read
    ClusterReportFault (..),
    clusterReportFaultMessage,

    -- * The total classifiers
    classifyClusterListing,
    classifyNodeContainer,
    classifyNodeContainerIdentity,
    classifyContainerRunState,
    classifyKubeconfig,
    classifyApiReadiness,
    classifyApiNodes,

    -- * Addressing what a report named
    containerReference,

    -- * The shared step and its bounds
    classifyClusterReport,
    clusterReportLineBound,
    kubeconfigByteBound,
    safeClusterName,
)
where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy.Char8 as LazyChar8
import Data.Char (isAlphaNum, isAscii)
import Data.Foldable (toList)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Effect.Run (CapturedRun (capturedExit, capturedStderr, capturedStdout))
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    mkObjectIdentity,
    objectIdentityBytes,
    ownershipFaultMessage,
 )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

-- ---------------------------------------------------------------------------
-- What the tools report

{- | Whether the driver names one cluster.

Two values and no third, because the answer authorizes a decision: absent
authorizes creation, present does not, and everything the driver could say that
is neither of those is a fault rather than a maybe.
-}
data ClusterPresence
    = ClusterPresent
    | ClusterAbsent
    deriving (Eq, Show)

-- | Whether one node container is running.
data ContainerRunState
    = ContainerRunning
    | ContainerNotRunning
    deriving (Eq, Show)

{- | Whether the API server reports itself ready.

Not a fault when it says no: a control plane that has not come up yet is what a
readiness poll is polling for.
-}
data ApiReadiness
    = ApiReady
    | ApiNotReady
    deriving (Eq, Show)

{- | What the API server's node list says about the declared node set.

'NodesUnexpected' is separate from 'NodesNotReady' because they are different
facts, and both are answers rather than faults: a node set that does not match
the declaration is a cluster this run is not looking at yet, and the honest
report is that it is not ready.
-}
data NodeReadiness
    = -- | every declared node is present and reports itself Ready
      NodesReady
    | -- | every declared node is present and at least one is not Ready
      NodesNotReady
    | -- | the API server names a different node set than the plan declares
      NodesUnexpected
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Why a report could not be read

{- | The closed set of reasons a report is not a value.

The four are genuinely distinct to whoever reads them: a command that never ran
names a host that could not launch it, a non-zero exit names the tool's own
diagnostic, a noisy success names output on the wrong stream, and an unreadable
report names bytes outside the shape this module admits.
-}
data ClusterReportFault
    = -- | no child existed, so nothing was reported at all
      ClusterCommandUnrun Text
    | -- | the tool ran and refused, with its own first diagnostic line
      ClusterCommandExited Int Text
    | -- | the tool succeeded and wrote to standard error
      ClusterCommandNoisy Text
    | -- | the tool succeeded and reported something this vocabulary does not admit
      ClusterReportUnreadable Text
    deriving (Eq, Show)

-- | One rendering, so a driver never writes a second description of a refusal.
clusterReportFaultMessage :: ClusterReportFault -> Text
clusterReportFaultMessage fault = case fault of
    ClusterCommandUnrun reason ->
        "the cluster command produced no process: " <> reason
    ClusterCommandExited code diagnostic ->
        "the cluster command exited " <> Text.pack (show code) <> ": " <> diagnostic
    ClusterCommandNoisy diagnostic ->
        "the cluster command succeeded and wrote to standard error: " <> diagnostic
    ClusterReportUnreadable reason ->
        "the cluster report is not one this vocabulary admits: " <> reason

-- ---------------------------------------------------------------------------
-- The bounds

{- | The widest single line a line-oriented cluster report may carry.

Wide enough for the longest container identifier a runtime mints and for a
cluster name at the grammar's own ceiling, narrow enough that a tool answering
with a document is refused rather than scanned.
-}
clusterReportLineBound :: Int
clusterReportLineBound = 512

{- | The widest kubeconfig admitted.

A kubeconfig is a document rather than a row, so it has its own ceiling — large
enough for a multi-cluster file with embedded certificates, small enough that a
tool answering with a stream is refused.
-}
kubeconfigByteBound :: Int
kubeconfigByteBound = 1048576

{- | The portable alphabet a cluster or node name this vocabulary admits.

Bounded and ASCII, because these names are compared against the plan's own and a
name outside the alphabet is a tool answering about something the plan cannot
have declared.
-}
safeClusterName :: String -> Bool
safeClusterName value =
    not (null value)
        && length value <= 128
        && all admissible value
  where
    admissible character =
        isAscii character
            && (isAlphaNum character || character `elem` ("._-" :: String))

-- ---------------------------------------------------------------------------
-- The total classifiers

{- | What the driver's listing says about one cluster.

Narrow on purpose, because a listing is another program's output. A name outside
the portable alphabet and the same name listed twice are each the driver
contradicting itself, and each is a refusal rather than an absence.
-}
classifyClusterListing ::
    -- | the exact cluster the driver is asking about
    String ->
    Either String CapturedRun ->
    Either ClusterReportFault ClusterPresence
classifyClusterListing clusterName captured = do
    names <- classifyClusterReport clusterReportLineBound captured
    if
        | not (all safeClusterName names) ->
            unreadable "the driver listed a cluster name outside the portable alphabet"
        | length names /= length (nub names) ->
            unreadable "the driver listed the same cluster more than once"
        | clusterName `elem` names -> Right ClusterPresent
        | otherwise -> Right ClusterAbsent

{- | The container standing at one node's exact name, if any.

@Right Nothing@ is an authoritative absence: the runtime answered, and nothing
carries that name. More than one is a refusal rather than a choice between them,
because a driver that picked one would be deciding which of two disagreeing
answers to own — and the filter was anchored on both ends precisely so that
cannot happen.
-}
classifyNodeContainer ::
    Either String CapturedRun ->
    Either ClusterReportFault (Maybe ObjectIdentity)
classifyNodeContainer captured = do
    candidates <- classifyClusterReport clusterReportLineBound captured
    case candidates of
        [] -> Right Nothing
        [single] -> Just <$> containerIdentity single
        _ -> unreadable "the runtime named more than one container at one node's exact name"

{- | One container's own identifier, read back against the one a listing produced.

The readback exists because a listing and an inspection are two questions: a name
that moved between them answers the second about a different object, and this is
where that shows up as a refusal rather than as an identity.
-}
classifyNodeContainerIdentity ::
    Either String CapturedRun ->
    Either ClusterReportFault ObjectIdentity
classifyNodeContainerIdentity captured = do
    reported <- classifyClusterReport clusterReportLineBound captured
    case reported of
        [single] -> containerIdentity single
        [] -> unreadable "the runtime reported no identifier for a container it had just named"
        _ -> unreadable "the runtime reported more than one identifier for one container"

{- | The reference the runtime itself answers to, for an identity read here.

Every 'ObjectIdentity' this module mints comes from 'containerIdentity', which
admits only a non-empty ASCII value carrying no whitespace, so the bytes behind
one are exactly the identifier the runtime reported and turning them back into a
reference is exact rather than a decoding guess. That round trip is what lets a
driver address a container by the identity its durable record bound instead of
by the node name a replacement inherits.

Nothing else in this vocabulary produces an identity, so there is no path by
which a kernel-encoded one could arrive here and be rendered as text it never
was.
-}
containerReference :: ObjectIdentity -> String
containerReference =
    Text.unpack . TextEncoding.decodeUtf8Lenient . objectIdentityBytes

containerIdentity :: String -> Either ClusterReportFault ObjectIdentity
containerIdentity value
    | any (`elem` (" \t" :: String)) value =
        unreadable "the runtime reported a container identifier carrying whitespace"
    | not (all isAscii value) =
        unreadable "the runtime reported a container identifier outside ASCII"
    | otherwise = case mkObjectIdentity (TextEncoding.encodeUtf8 (Text.pack value)) of
        Left fault -> unreadable (ownershipFaultMessage fault)
        Right identity -> Right identity

{- | Whether one container is running.

Exactly the two words the runtime's own template renders. Anything else is the
runtime answering a question this vocabulary did not ask.
-}
classifyContainerRunState ::
    Either String CapturedRun ->
    Either ClusterReportFault ContainerRunState
classifyContainerRunState captured = do
    reported <- classifyClusterReport clusterReportLineBound captured
    case reported of
        ["true"] -> Right ContainerRunning
        ["false"] -> Right ContainerNotRunning
        _ -> unreadable "the runtime reported a run state that is neither true nor false"

{- | The kubeconfig body, as bytes to hand to the next question on standard input.

Returned whole rather than split, because it is a document rather than a set of
rows and nothing here interprets it: what this classifier establishes is only
that the driver answered, quietly, in one well-framed ASCII document within the
admitted ceiling.
-}
classifyKubeconfig :: Either String CapturedRun -> Either ClusterReportFault String
classifyKubeconfig captured = do
    body <- capturedReport captured
    if
        | null body -> unreadable "the driver reported an empty kubeconfig"
        | length body > kubeconfigByteBound ->
            unreadable "the driver reported a kubeconfig past the admitted bound"
        | last body /= '\n' ->
            unreadable "the driver reported a kubeconfig that does not end in a newline"
        | '\r' `elem` body ->
            unreadable "the driver reported a kubeconfig carrying a carriage return"
        | not (all isAscii body) ->
            unreadable "the driver reported a kubeconfig carrying a byte outside ASCII"
        | otherwise -> Right body

{- | Whether the API server reports itself ready.

Total, and never a fault: a control plane that refuses the readiness endpoint, or
that answers it noisily, or that cannot be reached at all is a control plane that
is not ready, which is a legitimate answer to the question the poll is asking.
-}
classifyApiReadiness :: Either String CapturedRun -> ApiReadiness
classifyApiReadiness (Left _) = ApiNotReady
classifyApiReadiness (Right run) = case capturedExit run of
    ExitFailure _ -> ApiNotReady
    ExitSuccess
        | not (null (capturedStderr run)) -> ApiNotReady
        | otherwise -> ApiReady

{- | What the API server's node list says about the declared node set.

A malformed document is a refusal, because the API server contradicting its own
schema is not a readiness answer. A well-formed document naming a different node
set is 'NodesUnexpected' rather than a refusal, because it is a true statement
about a cluster this run is not looking at yet.
-}
classifyApiNodes ::
    -- | the node names the plan declares
    [String] ->
    Either String CapturedRun ->
    Either ClusterReportFault NodeReadiness
classifyApiNodes declared captured = do
    body <- capturedReport captured
    if
        | null body -> unreadable "the API server reported an empty node list"
        | last body /= '\n' ->
            unreadable "the API server reported a node list that does not end in a newline"
        | '\r' `elem` body ->
            unreadable "the API server reported a node list carrying a carriage return"
        | otherwise -> case Aeson.decode (LazyChar8.pack body) of
            Nothing -> unreadable "the API server reported a node list this vocabulary cannot decode"
            Just value -> nodeReadiness declared value

nodeReadiness :: [String] -> Aeson.Value -> Either ClusterReportFault NodeReadiness
nodeReadiness declared value = do
    items <- nodeItems value
    names <- traverse nodeName items
    if
        | length names /= length (nub names) ->
            unreadable "the API server named the same node twice"
        | not (all safeClusterName names) ->
            unreadable "the API server named a node outside the portable alphabet"
        | nub names /= nub declared || length names /= length declared -> Right NodesUnexpected
        | all nodeIsReady items -> Right NodesReady
        | otherwise -> Right NodesNotReady

nodeItems :: Aeson.Value -> Either ClusterReportFault [Aeson.Object]
nodeItems (Aeson.Object document) = case KeyMap.lookup "items" document of
    Just (Aeson.Array items) -> traverse objectItem (toList items)
    _ -> unreadable "the API server's node list carries no items array"
nodeItems _ = unreadable "the API server's node list is not an object"

objectItem :: Aeson.Value -> Either ClusterReportFault Aeson.Object
objectItem (Aeson.Object item) = Right item
objectItem _ = unreadable "the API server listed a node that is not an object"

nodeName :: Aeson.Object -> Either ClusterReportFault String
nodeName item = case KeyMap.lookup "metadata" item of
    Just (Aeson.Object metadata) -> case KeyMap.lookup "name" metadata of
        Just (Aeson.String name) -> Right (Text.unpack name)
        _ -> unreadable "the API server listed a node whose name is not a string"
    _ -> unreadable "the API server listed a node carrying no metadata object"

{- | Whether one node carries a Ready condition that is True.

Absence of the condition is not readiness. A node whose status this vocabulary
cannot read is not ready either, which is the safe direction: the answer is only
ever used to decide whether to stop waiting.
-}
nodeIsReady :: Aeson.Object -> Bool
nodeIsReady item = case KeyMap.lookup "status" item of
    Just (Aeson.Object status) -> case KeyMap.lookup "conditions" status of
        Just (Aeson.Array conditions) -> any readyCondition (toList conditions)
        _ -> False
    _ -> False

readyCondition :: Aeson.Value -> Bool
readyCondition (Aeson.Object condition) =
    KeyMap.lookup "type" condition == Just (Aeson.String "Ready")
        && KeyMap.lookup "status" condition == Just (Aeson.String "True")
readyCondition _ = False

-- ---------------------------------------------------------------------------
-- The shared step

{- | What a tool actually reported, or why nothing it wrote is an answer.

Every line-oriented classifier in this module starts here. That is the point:
"the command produced no child", "the tool exited non-zero", "the tool succeeded
and complained on the wrong stream", and "the tool wrote something outside the
admitted shape" are one decision, taken once, rather than four decisions taken
per question and drifting apart.

The framing is strict because these answers are compared against the plan's own
values: a body that does not end in exactly one newline, that carries a carriage
return or a byte outside ASCII, or that carries an empty row is the tool
contradicting itself. Empty output is an empty listing rather than a malformed
one, because a tool that names nothing writes nothing.
-}
classifyClusterReport ::
    -- | the widest single line this question admits
    Int ->
    Either String CapturedRun ->
    Either ClusterReportFault [String]
classifyClusterReport lineBound captured = do
    reported <- capturedReport captured
    reportLines lineBound reported

capturedReport :: Either String CapturedRun -> Either ClusterReportFault String
capturedReport (Left refusal) = Left (ClusterCommandUnrun (Text.pack refusal))
capturedReport (Right run) = case capturedExit run of
    ExitFailure code -> Left (ClusterCommandExited code (firstLine (capturedStderr run)))
    ExitSuccess
        | not (null (capturedStderr run)) ->
            Left (ClusterCommandNoisy (firstLine (capturedStderr run)))
        | otherwise -> Right (capturedStdout run)

reportLines :: Int -> String -> Either ClusterReportFault [String]
reportLines _ "" = Right []
reportLines lineBound reported
    | last reported /= '\n' =
        unreadable "the cluster report does not end in a newline"
    | '\r' `elem` reported =
        unreadable "the cluster report carries a carriage return"
    | not (all isAscii reported) =
        unreadable "the cluster report carries a byte outside ASCII"
    | any null rows =
        unreadable "the cluster report carries an empty row"
    | any ((> lineBound) . length) rows =
        unreadable "the cluster report carries a line past the admitted bound"
    | otherwise = Right rows
  where
    rows = splitOnNewline (init reported)

splitOnNewline :: String -> [String]
splitOnNewline value = case break (== '\n') value of
    (before, []) -> [before]
    (before, _ : rest) -> before : splitOnNewline rest

-- | The first line of a diagnostic, bounded, or a stand-in when there is none.
firstLine :: String -> Text
firstLine value = case filter (not . null) (lines value) of
    [] -> "no diagnostic"
    (line : _) -> Text.pack (take clusterReportLineBound (filter (/= '\r') line))

unreadable :: Text -> Either ClusterReportFault value
unreadable = Left . ClusterReportUnreadable
