module CallerSelectedDescentSubtree where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.Teardown

data Scope
data Plan
data Parent
data Child

-- The descent package already retains the exact child projection. A second
-- CurrentFrame has no argument position through which it can select/relabel it.
withSecondFrame ::
    DescentWork Scope Plan Parent Child VerbDestroy ->
    CurrentFrame Scope Plan Child ->
    (TeardownPlan Scope Plan Child VerbDestroy -> result) ->
    result
withSecondFrame descent current use =
    withDescentWorkSubtree descent current use

-- Descriptive child text likewise cannot substitute for the eliminator.
withChildName ::
    DescentWork Scope Plan Parent Child VerbDestroy ->
    String
withChildName descent = withDescentWorkSubtree descent "child"
