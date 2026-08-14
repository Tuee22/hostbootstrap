module ImportLifecycleRootedReceipt where

import HostBootstrap.Lifecycle.Rooted.Receipt
    ( withRootedReceiptConfirmationKernel
    , withRootedTerminalReportKernel
    )

hidden :: ()
hidden = withRootedTerminalReportKernel `seq` withRootedReceiptConfirmationKernel `seq` ()
