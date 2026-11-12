{- | Commands used by the direct-Colima owner, as values in the repository's
host-command vocabulary.

This module contains no runner.  Keeping construction here makes the tool set
and exact argument vectors independently testable while the ownership driver
holds its protected entry around interpretation.
-}
module HostBootstrap.Ensure.Colima.Command (
    ColimaProfile,
    mkColimaProfile,
    DockerContextName,
    dockerContextForProfile,
    dockerContextNameText,
    ColimaStartArguments,
    mkColimaStartArguments,
    colimaStartProfile,
    listColimaProfilesCommand,
    startColimaProfileCommand,
    deleteColimaProfileCommand,
    readColimaMachineIdCommand,
    listLimaDisksCommand,
    inspectDockerContextCommand,
    listDockerContextsCommand,
    removeDockerContextCommand,
    routedDockerCommand,
)
where

import Data.List (isPrefixOf)
import HostBootstrap.Effect.Vocabulary (HostCommand, hostCommand)
import HostBootstrap.Ensure.Colima.Backend.Routing (validRoutedDockerArguments)
import HostBootstrap.HostTool (HostTool (Colima, Docker, Lima))

-- A profile is admitted by the same validator used to derive ownership keys.
newtype ColimaProfile = ColimaProfile String
    deriving (Eq, Show)

mkColimaProfile :: String -> Either String ColimaProfile
mkColimaProfile value
    | length value == 8 && take 2 value == "h-" && all isLowerHex (drop 2 value) = Right (ColimaProfile value)
    | otherwise = Left "invalid direct-Colima profile"
  where
    isLowerHex character = character >= '0' && character <= '9' || character >= 'a' && character <= 'f'

-- Context names are derived only from an admitted Colima profile.
newtype DockerContextName = DockerContextName String
    deriving (Eq, Show)

dockerContextForProfile :: ColimaProfile -> DockerContextName
dockerContextForProfile (ColimaProfile profile) = DockerContextName ("colima-" ++ profile)

dockerContextNameText :: DockerContextName -> String
dockerContextNameText (DockerContextName context) = context

listColimaProfilesCommand :: HostCommand
listColimaProfilesCommand = hostCommand Colima ["list", "--json"]

-- Start arguments retain the validated profile and reject a later profile override.
data ColimaStartArguments = ColimaStartArguments ColimaProfile [String]
    deriving (Eq, Show)

mkColimaStartArguments :: ColimaProfile -> [String] -> Either String ColimaStartArguments
mkColimaStartArguments profile@(ColimaProfile name) arguments = case arguments of
    "start" : "--profile" : actual : rest
        | actual == name && not (any overridesProfile rest) -> Right (ColimaStartArguments profile rest)
    _ -> Left "invalid direct-Colima start arguments"
  where
    overridesProfile argument = argument == "--profile" || "--profile=" `isPrefixOf` argument || "-p" `isPrefixOf` argument

colimaStartProfile :: ColimaStartArguments -> ColimaProfile
colimaStartProfile (ColimaStartArguments profile _) = profile

startColimaProfileCommand :: ColimaStartArguments -> HostCommand
startColimaProfileCommand (ColimaStartArguments (ColimaProfile profile) arguments) =
    hostCommand Colima (["start", "--profile", profile] ++ arguments)

deleteColimaProfileCommand :: ColimaProfile -> HostCommand
deleteColimaProfileCommand (ColimaProfile profile) =
    hostCommand Colima ["delete", "--profile", profile, "--force", "--data"]

readColimaMachineIdCommand :: ColimaProfile -> HostCommand
readColimaMachineIdCommand (ColimaProfile profile) =
    hostCommand Colima ["ssh", "--profile", profile, "--", "cat", "/etc/machine-id"]

listLimaDisksCommand :: HostCommand
listLimaDisksCommand = hostCommand Lima ["disk", "list", "--json"]

inspectDockerContextCommand :: DockerContextName -> HostCommand
inspectDockerContextCommand (DockerContextName context) = hostCommand Docker ["context", "inspect", context]

listDockerContextsCommand :: HostCommand
listDockerContextsCommand = hostCommand Docker ["context", "ls", "--format", "{{json .}}"]

removeDockerContextCommand :: DockerContextName -> HostCommand
removeDockerContextCommand (DockerContextName context) = hostCommand Docker ["context", "rm", "--force", context]

routedDockerCommand :: DockerContextName -> [String] -> Either String HostCommand
routedDockerCommand (DockerContextName context) arguments = do
    validRoutedDockerArguments arguments
    pure (hostCommand Docker (["--context", context] ++ arguments))
