module ReportedOriginAsDirectory where

import HostBootstrap.Ownership.Object (ObjectKind (OwnedDirectory))
import HostBootstrap.Ownership.Primitive (recordReportedOrigin)

bad entered publish = recordReportedOrigin entered OwnedDirectory publish
