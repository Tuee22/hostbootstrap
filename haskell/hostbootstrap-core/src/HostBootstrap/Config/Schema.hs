{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The static-base @hostbootstrap.dhall@ schema and its in-process decoder.
--
-- This is the one config tier the Python bootstrapper reads; it is identical in
-- shape across projects and carries only the fields needed before any project
-- binary exists. The decoder is in-process Haskell using the @dhall@ library and
-- backs @config show@ after the binary exists; the pre-binary read is done by
-- the Python bootstrapper via the pinned @dhall-to-json@. The rich project-level
-- and per-case test Dhall are artifacts the project binary generates; core owns
-- only this static-base decoder (see @development_plan_standards.md § Q@).
module HostBootstrap.Config.Schema
  ( StaticBase (..),
    Resources (..),
    decodeStaticBaseText,
    decodeStaticBaseFile,
    renderStaticBase,
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall, auto, inputFile)
import qualified Dhall
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | The per-project resource budget: the single field both the Python layer and
-- the project binary consume (see @development_plan_standards.md § O@).
data Resources = Resources
  { cpu :: Natural,
    memory :: Text,
    storage :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | The static-base @hostbootstrap.dhall@ record.
data StaticBase = StaticBase
  { project :: Text,
    dockerfile :: Text,
    resources :: Resources
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | Decode a static-base config from Dhall source text. Throws a typed Dhall
-- error on a malformed or ill-typed config.
decodeStaticBaseText :: Text -> IO StaticBase
decodeStaticBaseText = Dhall.input auto

-- | Decode a static-base config from a @hostbootstrap.dhall@ file.
decodeStaticBaseFile :: FilePath -> IO StaticBase
decodeStaticBaseFile = inputFile auto

-- | A short human-readable summary of a decoded static-base config.
renderStaticBase :: StaticBase -> String
renderStaticBase s =
  T.unpack $
    T.unlines
      [ "project:    " <> project s,
        "dockerfile: " <> dockerfile s,
        "resources:  cpu="
          <> T.pack (show (cpu (resources s)))
          <> " memory="
          <> memory (resources s)
          <> " storage="
          <> storage (resources s)
      ]
