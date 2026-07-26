module CrossFinalizationCodec where

import HostBootstrap.Config.Class

requireSameFinalization ::
    ProjectCodec scope digest cfg ->
    ProjectCodec scope digest cfg ->
    ()
requireSameFinalization _ _ = ()

combineDifferentFinalizations ::
    ProjectCodec scope leftDigest cfg ->
    ProjectCodec scope rightDigest cfg ->
    ()
combineDifferentFinalizations left right =
    requireSameFinalization left right
