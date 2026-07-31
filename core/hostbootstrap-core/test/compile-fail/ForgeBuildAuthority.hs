module ForgeBuildAuthority where

import HostBootstrap.Build
import HostBootstrap.Context (imageBuildContainerContext)

-- The baked image-build config is a file the Dockerfile just wrote. Nothing in
-- this module accepts a BinaryContext, so it cannot reach build authority.
bakedConfig :: ()
bakedConfig = seq (imageBuildContainerContext "demo" "demo" "/workspace/demo") ()

-- Build authority exists only as the result of verifying a signed channel
-- against locally measured sources and binaries.
forgedAuthority :: BuildInvocationAuthority p s c b so bb
forgedAuthority = BuildInvocationAuthority "build-7" "sourcedigest"

-- The frame is minted jointly with that authority, so it cannot be paired with
-- authority from a different build.
forgedFrame :: ImageBuildFrame p s c f
forgedFrame = ImageBuildFrame "image-build-container-0"

-- Phase authority is derived, never asserted.
forgedPhase :: BuildCommandAuthority p s c
forgedPhase = BuildCommandAuthority CheckCodePhase "image-build-container-0"

-- A grant is a signature, not arbitrary bytes.
forgedGrant :: BuildGrant
forgedGrant = BuildGrant "not a signature"

-- The coordinator's signing key cannot be constructed by a consumer.
forgedCoordinator :: BuildCoordinator
forgedCoordinator = BuildCoordinator
