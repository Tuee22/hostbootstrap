module ImportTransactionRunnerFromTestingUnit where

import HostBootstrap.Lifecycle.Transaction (
    ensureTransactionCoordinator,
    recoverProductionTransactions,
    runLifecycleTransaction,
 )

coordinatorProducer = ensureTransactionCoordinator

transactionRunner = runLifecycleTransaction

productionRecoveryRunner = recoverProductionTransactions
