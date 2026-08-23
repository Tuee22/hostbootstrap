{- | Every external effect used by the direct-Colima owner, as values in the
repository's one host-command vocabulary.

This module contains no runner.  Keeping construction here makes the tool set
and exact argument vectors independently testable while the ownership driver
holds its protected entry around interpretation.
-}
module HostBootstrap.Ensure.Colima.Command
  ( colimaCommandTools,
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

import HostBootstrap.Effect.Vocabulary (HostCommand, hostCommand)
import HostBootstrap.Ensure.Colima.Backend.Routing (validRoutedDockerArguments)
import HostBootstrap.HostTool (HostTool (Colima, Docker, Lima))

colimaCommandTools :: [HostTool]
colimaCommandTools = [Colima, Docker, Lima]

listColimaProfilesCommand :: HostCommand
listColimaProfilesCommand = hostCommand Colima ["list", "--json"]

startColimaProfileCommand :: [String] -> HostCommand
startColimaProfileCommand = hostCommand Colima

deleteColimaProfileCommand :: String -> HostCommand
deleteColimaProfileCommand profile =
  hostCommand Colima ["delete", "--profile", profile, "--force", "--data"]

readColimaMachineIdCommand :: String -> HostCommand
readColimaMachineIdCommand profile =
  hostCommand Colima ["ssh", "--profile", profile, "--", "cat", "/etc/machine-id"]

listLimaDisksCommand :: HostCommand
listLimaDisksCommand = hostCommand Lima ["disk", "list", "--json"]

inspectDockerContextCommand :: String -> HostCommand
inspectDockerContextCommand context = hostCommand Docker ["context", "inspect", context]

listDockerContextsCommand :: HostCommand
listDockerContextsCommand = hostCommand Docker ["context", "ls", "--format", "{{json .}}"]

removeDockerContextCommand :: String -> HostCommand
removeDockerContextCommand context = hostCommand Docker ["context", "rm", "--force", context]

routedDockerCommand :: String -> [String] -> Either String HostCommand
routedDockerCommand profile arguments =
  if validRoutedDockerArguments arguments
    then Right (hostCommand Docker (["--context", "colima-" ++ profile] ++ arguments))
    else Left "Docker command may not override the owned Colima route"
