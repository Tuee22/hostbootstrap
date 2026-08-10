{-# LANGUAGE RankNTypes #-}

module EscapeVerifiedBuildInvocation where

import Data.Text (Text)
import HostBootstrap.Build

data ChosenBuildProject
data ChosenBuildSpec
data ChosenBuildConfig
data ChosenBuildFrame
data ChosenBuildIdentity
data ChosenBuildSource
data ChosenBuildBuilder

selectProject ::
    ImageBuildFrame ChosenBuildProject spec config frame ->
    BuildInvocationAuthority ChosenBuildProject spec config build source builder ->
    IO ()
selectProject _ _ = pure ()

selectSpec ::
    ImageBuildFrame project ChosenBuildSpec config frame ->
    BuildInvocationAuthority project ChosenBuildSpec config build source builder ->
    IO ()
selectSpec _ _ = pure ()

selectConfig ::
    ImageBuildFrame project spec ChosenBuildConfig frame ->
    BuildInvocationAuthority project spec ChosenBuildConfig build source builder ->
    IO ()
selectConfig _ _ = pure ()

selectFrame ::
    ImageBuildFrame project spec config ChosenBuildFrame ->
    BuildInvocationAuthority project spec config build source builder ->
    IO ()
selectFrame _ _ = pure ()

selectBuild ::
    ImageBuildFrame project spec config frame ->
    BuildInvocationAuthority project spec config ChosenBuildIdentity source builder ->
    IO ()
selectBuild _ _ = pure ()

selectSource ::
    ImageBuildFrame project spec config frame ->
    BuildInvocationAuthority project spec config build ChosenBuildSource builder ->
    IO ()
selectSource _ _ = pure ()

selectBuilder ::
    ImageBuildFrame project spec config frame ->
    BuildInvocationAuthority project spec config build source ChosenBuildBuilder ->
    IO ()
selectBuilder _ _ = pure ()

verifyWith ::
    BuildVerificationKey ->
    Text ->
    Text ->
    Text ->
    Text ->
    FilePath ->
    FilePath ->
    BuildChannel ->
    ( forall project spec config frame build source builder.
      ImageBuildFrame project spec config frame ->
      BuildInvocationAuthority project spec config build source builder ->
      IO ()
    ) ->
    IO (Either BuildError ())
verifyWith = verifyBuildInvocation

escapeProject key project spec config coordinator sourceRoot builder channel =
    verifyWith key project spec config coordinator sourceRoot builder channel selectProject

escapeSpec key project spec config coordinator sourceRoot builder channel =
    verifyWith key project spec config coordinator sourceRoot builder channel selectSpec

escapeConfig key project spec config coordinator sourceRoot builder channel =
    verifyWith key project spec config coordinator sourceRoot builder channel selectConfig

escapeFrame key project spec config coordinator sourceRoot builder channel =
    verifyWith key project spec config coordinator sourceRoot builder channel selectFrame

escapeBuild key project spec config coordinator sourceRoot builder channel =
    verifyWith key project spec config coordinator sourceRoot builder channel selectBuild

escapeSource key project spec config coordinator sourceRoot builder channel =
    verifyWith key project spec config coordinator sourceRoot builder channel selectSource

escapeBuilder key project spec config coordinator sourceRoot builder channel =
    verifyWith key project spec config coordinator sourceRoot builder channel selectBuilder
