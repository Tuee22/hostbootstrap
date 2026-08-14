module EscapeDescentChildFrame where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data Frame
data ChosenChild

escapeChild ::
    TeardownWork Scope Plan Frame VerbDestroy ->
    DescentWork Scope Plan Frame ChosenChild VerbDestroy
escapeChild work =
    eliminateTeardownWork
        work
        (const (error "local work has no child"))
        id
