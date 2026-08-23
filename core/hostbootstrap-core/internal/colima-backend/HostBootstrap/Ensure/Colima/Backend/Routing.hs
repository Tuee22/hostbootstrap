module HostBootstrap.Ensure.Colima.Backend.Routing
  ( validRoutedDockerArguments,
  )
where

-- | Admit only commands whose connection and credential route remains the
-- exact owned Colima context. Refusal is decided before any effect.
validRoutedDockerArguments :: [String] -> Bool
validRoutedDockerArguments arguments =
  case arguments of
    command : _ -> validCommand command && all validArgument arguments
    [] -> False
  where
    validCommand command =
      case command of
        initial : _ ->
          initial /= '-'
            && command `notElem` ["context", "login", "logout", "buildx"]
        [] -> False
    validArgument value =
      value `notElem` exactOverrides
        && not (any (`prefixOf` value) attachedOverrides)
    exactOverrides =
      [ "-c", "-H", "--context", "--host", "--config", "--tls",
        "--tlsverify", "--tlscacert", "--tlscert", "--tlskey"
      ]
    attachedOverrides =
      [ "-c", "-H", "--context=", "--host=", "--config=", "--tls=",
        "--tlsverify=", "--tlscacert=", "--tlscert=", "--tlskey="
      ]
    prefixOf prefix value = take (length prefix) value == prefix
