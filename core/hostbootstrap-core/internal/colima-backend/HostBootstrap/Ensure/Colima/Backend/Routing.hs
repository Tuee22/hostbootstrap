module HostBootstrap.Ensure.Colima.Backend.Routing (
    validRoutedDockerArguments,
)
where

{- | Docker parses global options before the subcommand. The managed route
supplies the context itself, so callers must start with an allowed subcommand;
subsequent arguments belong to that subcommand or its child program.
-}
validRoutedDockerArguments :: [String] -> Either String ()
validRoutedDockerArguments arguments =
    case arguments of
        [] -> Left "Docker command requires a subcommand"
        "" : _ -> Left "Docker command requires a subcommand"
        ('-' : _) : _ -> Left "Docker command may not override the owned Colima route"
        command : _
            | command `elem` ["context", "login", "logout", "buildx"] ->
                Left "Docker subcommand is forbidden on the owned Colima route"
            | otherwise -> Right ()
