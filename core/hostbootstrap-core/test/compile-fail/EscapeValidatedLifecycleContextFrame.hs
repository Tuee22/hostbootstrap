module EscapeValidatedLifecycleContextFrame where

import HostBootstrap.Config.Class (ProjectCfg)
import HostBootstrap.Context (BinaryContext)
import HostBootstrap.Lifecycle.Context
    ( LifecycleContextError
    , ValidatedLifecycleContext
    , withValidatedLifecycleContext
    )
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.Protected (ProtectedStore)

data SelectedFrame

escapeFrame ::
    (ProjectCfg cfg) =>
    CanonicalProjectRoot scope rootId ->
    ProtectedStore ->
    ProjectPlan scope specification plan configuration cfg ->
    BinaryContext ->
    IO
        ( Either
            LifecycleContextError
            (ValidatedLifecycleContext scope specification plan configuration SelectedFrame)
        )
escapeFrame root store plan context =
    withValidatedLifecycleContext root store plan context pure
