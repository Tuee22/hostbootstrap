module ConstructTransactionInterrupted where

import HostBootstrap.Lifecycle.Session.Testing (
    TransactionFailpoint (TransactionAfterApplying),
    TransactionInterrupted,
 )

-- The public crash injector is a bracket around a real lifecycle action. Its
-- exception remains opaque, so callers cannot manufacture an apparent
-- lifecycle interruption or use a constructor as authority evidence.
forgedInterruption :: TransactionInterrupted
forgedInterruption = TransactionInterrupted TransactionAfterApplying
