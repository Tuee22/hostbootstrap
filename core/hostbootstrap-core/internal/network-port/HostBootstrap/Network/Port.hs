{- | A TCP port, and the one place that decides what a TCP port is.

The range @1..65535@ is not an opinion this repository is entitled to hold more
than once. It was held four times — once in the reachability vocabulary, once
in the cluster backend, once in the shipped-exposure codec, and once in the
runtime dependency package — as four byte-identical predicates over 'Int'. They
agreed, but nothing made them agree, and a fifth consumer had no way to tell
which of its integers had been past one of them.

So the range is a constructor rather than a predicate. 'mkPort' is the only way
to obtain a 'Port'; a consumer that needs a boolean asks the producer for one
instead of restating the bound, and a consumer that holds a 'Port' needs no
check at all. 'portNumber' is the only way back out, which is what a wire
codec, a command line, and a rendered authority each need.

This module is deliberately a leaf: it names no scope, no endpoint, no cluster,
and no package, so the backend that resolves an exposure and the vocabulary
that describes where that exposure is reachable can both sit above it. The
reachability vocabulary re-exports it, because that is where a reader looks for
what a port is.
-}
module HostBootstrap.Network.Port (
    Port,
    mkPort,
    portNumber,
)
where

-- | An admitted TCP port. The constructor is private: 'mkPort' is the only mint.
newtype Port = Port Int
    deriving (Eq, Ord)

instance Show Port where
    show (Port number) = "Port " ++ show number

{- | Admit one integer as a port, or refuse it. This is the sole definition of
the range, so a caller that wants the predicate asks for the value and reads
whether it arrived.
-}
mkPort :: Int -> Maybe Port
mkPort number
    | number >= 1 && number <= 65535 = Just (Port number)
    | otherwise = Nothing

-- | The admitted number, for a wire field, an argument vector, or an authority.
portNumber :: Port -> Int
portNumber (Port number) = number
