{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}

-- A definition cannot accept an unrestricted IO handler.
module IOServiceHandler where

import HostBootstrap.Service (ProgramServiceHandler)

data Payload

handler :: ProgramServiceHandler Payload '[] ()
handler _ = putStrLn "escape"
