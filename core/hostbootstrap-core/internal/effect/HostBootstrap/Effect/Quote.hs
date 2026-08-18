{- | The one shell quoter.

§ K fixes /which/ executable an invocation names and § HH the /shape/ it is
launched with. Quoting belongs to neither: it is how an argument survives the
interpreter that will re-split the command line, and it is the one step where a
mistake is silent. An unquoted space becomes two arguments, an unquoted @*@
becomes whatever the working directory happens to contain, and an unquoted
quote ends the argument early — none of which fails at the call site, and each
of which is a different bug in a different frame.

So there is one quoter per grammar and no second copy (§ KK). Written once per
site, the same escape is five functions that agree today and drift the first
time one of them meets a character the others never saw, and no gate compares
them because each passes its own test.

Two grammars are genuinely distinct, because two different interpreters read
them: POSIX @sh@ closes a single-quoted string at the first quote and offers no
escape inside it, so a literal quote leaves and re-enters the quoting; Windows
PowerShell doubles it in place instead. Everything else is literal inside single
quotes in both, which is why single quoting is the shape both use.

This module is a leaf: it is pure, it names no tool, no path, and no process,
and it is reachable from every library that composes a command.
-}
module HostBootstrap.Effect.Quote
    ( shellQuoteArg
    , shellQuoteArgs
    , powerShellQuoteArg
    )
where

{- | Quote one argument for POSIX @sh@.

Single quotes suppress every expansion the shell would otherwise perform, and a
literal quote is spelled by leaving the quoting, escaping it, and re-entering:
@'\\''@. The result is always quoted, including for the empty string, which
would otherwise vanish from the argument vector entirely.
-}
shellQuoteArg :: String -> String
shellQuoteArg value = "'" ++ concatMap escape value ++ "'"
  where
    escape '\'' = "'\\''"
    escape character = [character]

{- | Quote an argument vector for POSIX @sh@ and join it with spaces.

The result can be embedded verbatim in a shell command without re-splitting or
glob expansion, so an argv built in Haskell reaches the far side as the same
argv.
-}
shellQuoteArgs :: [String] -> String
shellQuoteArgs = unwords . map shellQuoteArg

{- | Quote one argument for Windows PowerShell.

PowerShell's single-quoted string is also fully literal, but it spells an
embedded quote by doubling it rather than by leaving the quoting, so the POSIX
escape above would end the string and start a new one.
-}
powerShellQuoteArg :: String -> String
powerShellQuoteArg value = "'" ++ concatMap escape value ++ "'"
  where
    escape '\'' = "''"
    escape character = [character]
