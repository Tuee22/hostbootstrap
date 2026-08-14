module GenericPointTeardownDriver where

import Data.Text (Text)
import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data Frame

-- The forest driver classifies every offered point internally. A caller cannot
-- regain the former generic point callback and report arbitrary success without
-- handling the pre-descent/local/descent branches.
driveGeneric ::
    TeardownForest Scope Plan Frame VerbDestroy ->
    (TeardownAuthorizationPoint Scope Plan Frame VerbDestroy -> IO TeardownOutcome) ->
    IO (Either [Text] (CompletedTeardownForest Scope Plan Frame VerbDestroy))
driveGeneric forest attemptPoint =
    driveTeardownForest
        forest
        attemptPoint
        (\_ _ -> pure TeardownReleased)
        (\_ _ -> pure TeardownReleased)
        (\_ _ -> pure ())
