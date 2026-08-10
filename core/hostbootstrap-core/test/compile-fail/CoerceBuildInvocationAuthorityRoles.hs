module CoerceBuildInvocationAuthorityRoles where

import Data.Coerce (coerce)
import HostBootstrap.Build (BuildInvocationAuthority)

data ProjectA
data ProjectB
data SpecA
data SpecB
data ConfigA
data ConfigB
data BuildA
data BuildB
data SourceA
data SourceB
data BuilderA
data BuilderB

wrongProject ::
    BuildInvocationAuthority ProjectA SpecA ConfigA BuildA SourceA BuilderA ->
    BuildInvocationAuthority ProjectB SpecA ConfigA BuildA SourceA BuilderA
wrongProject = coerce

wrongSpec ::
    BuildInvocationAuthority ProjectA SpecA ConfigA BuildA SourceA BuilderA ->
    BuildInvocationAuthority ProjectA SpecB ConfigA BuildA SourceA BuilderA
wrongSpec = coerce

wrongConfig ::
    BuildInvocationAuthority ProjectA SpecA ConfigA BuildA SourceA BuilderA ->
    BuildInvocationAuthority ProjectA SpecA ConfigB BuildA SourceA BuilderA
wrongConfig = coerce

wrongBuild ::
    BuildInvocationAuthority ProjectA SpecA ConfigA BuildA SourceA BuilderA ->
    BuildInvocationAuthority ProjectA SpecA ConfigA BuildB SourceA BuilderA
wrongBuild = coerce

wrongSource ::
    BuildInvocationAuthority ProjectA SpecA ConfigA BuildA SourceA BuilderA ->
    BuildInvocationAuthority ProjectA SpecA ConfigA BuildA SourceB BuilderA
wrongSource = coerce

wrongBuilder ::
    BuildInvocationAuthority ProjectA SpecA ConfigA BuildA SourceA BuilderA ->
    BuildInvocationAuthority ProjectA SpecA ConfigA BuildA SourceA BuilderB
wrongBuilder = coerce
