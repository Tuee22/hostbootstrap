{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The skeletal @hostbootstrap.dhall@ schema and its in-process decoder.
--
-- This is the one config tier the Python bootstrapper reads; it is identical in
-- shape across projects and carries only the fields needed before any project
-- binary exists. The decoder is in-process Haskell using the @dhall@ library —
-- there is no external @dhall-to-json@ binary. The rich project-level and
-- per-case test Dhall are artifacts the project binary generates; core owns only
-- this skeletal decoder (see @development_plan_standards.md § Q@).
module HostBootstrap.Config.Schema
  ( Skeleton (..),
    Resources (..),
    decodeSkeletonText,
    decodeSkeletonFile,
    renderSkeleton,
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

-- | The skeletal @hostbootstrap.dhall@ record.
data Skeleton = Skeleton
  { project :: Text,
    dockerfile :: Text,
    resources :: Resources
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | Decode a skeletal config from Dhall source text. Throws a typed Dhall error
-- on a malformed or ill-typed config.
decodeSkeletonText :: Text -> IO Skeleton
decodeSkeletonText = Dhall.input auto

-- | Decode a skeletal config from a @hostbootstrap.dhall@ file.
decodeSkeletonFile :: FilePath -> IO Skeleton
decodeSkeletonFile = inputFile auto

-- | A short human-readable summary of a decoded skeleton.
renderSkeleton :: Skeleton -> String
renderSkeleton s =
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
