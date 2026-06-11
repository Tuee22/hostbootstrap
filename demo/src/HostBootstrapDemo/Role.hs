-- | F2 — a stateless **role** over a toy bus + object-store stand-in, the in-tree
-- worked instance of the business-logic role shape (see
-- @documents/architecture/composition_methodology.md@).
--
-- The role consumes budget-eval requests from a request "topic", fetches a static
-- "artifact" (the capacity budget), dispatches to the budget-fit engine, and
-- produces a result "topic" — the deploy ≡ business-logic shape with the demo's
-- own trivial engine. The bus and artifact are **demo-local filesystem
-- stand-ins** (a directory of request/result files; a capacity file): a real
-- consumer points the same shape at a message bus (Pulsar) and an object store
-- (MinIO). Kept dependency-free so it needs no warm-store change.
module HostBootstrapDemo.Role
  ( roleServe,
    roleSubmit,
    budgetFits,
  )
where

import Control.Monad (forM_)
import Data.List (isSuffixOf)
import Data.Maybe (fromMaybe)
import qualified HostBootstrap.Config.Vocab as Vocab
import qualified HostBootstrap.RoleLifecycle as RL
import Numeric.Natural (Natural)
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    listDirectory,
    removeFile,
  )

-- The toy bus + object-store stand-ins (demo-local filesystem).
busRoot, requestDir, resultDir, artifactPath :: FilePath
busRoot = ".role-bus"
requestDir = busRoot ++ "/requests"
resultDir = busRoot ++ "/results"
artifactPath = busRoot ++ "/capacity.artifact"

-- | The engine: does a requested budget fit the capacity budget? (The same
-- dimension-wise verdict the demo's webservice surfaces; here over the pure
-- 'Vocab.Budget' vocabulary, matched positionally to avoid the shared field
-- labels.)
budgetFits :: Vocab.Budget -> Vocab.Budget -> Bool
budgetFits (Vocab.Budget c m s) (Vocab.Budget c' m' s') = c <= c' && m <= m' && s <= s'

renderBudget :: Vocab.Budget -> String
renderBudget (Vocab.Budget c m s) = unwords (map show [c, m, s])

parseBudget :: String -> Maybe Vocab.Budget
parseBudget str = case words str of
  [a, b, c] -> Vocab.Budget <$> readNat a <*> readNat b <*> readNat c
  _ -> Nothing
  where
    readNat :: String -> Maybe Natural
    readNat w = case reads w of
      [(n, "")] -> Just n
      _ -> Nothing

-- | @demo role submit CPU MEMORY STORAGE@: enqueue a budget-eval request onto the
-- toy bus.
roleSubmit :: Vocab.Budget -> IO ()
roleSubmit req = do
  createDirectoryIfMissing True requestDir
  existing <- listDirectory requestDir
  let name = requestDir ++ "/req-" ++ show (length existing) ++ ".txt"
  writeFile name (renderBudget req)
  putStrLn ("role submit: enqueued " ++ renderBudget req ++ " at " ++ name)

-- | @demo role serve@: drain the request topic once — fetch the capacity artifact,
-- dispatch each pending request to 'budgetFits', and produce a result. (A single
-- drain stands in for the long-running 'HostDaemon' role, which would subscribe
-- and serve continuously.)
roleServe :: IO ()
roleServe =
  RL.runRole
    RL.RoleSpec
      { RL.roleAcquire = do
          createDirectoryIfMissing True requestDir
          createDirectoryIfMissing True resultDir
          cap <- fetchCapacity
          putStrLn ("role serve: capacity artifact = " ++ renderBudget cap)
          pure cap,
        RL.roleServe = drainRequests,
        RL.roleDrain = \_ -> putStrLn "role serve: drained"
      }

-- | The Serve phase: drain all pending requests, dispatching each to the engine.
drainRequests :: Vocab.Budget -> IO ()
drainRequests cap = do
  reqs <- listDirectory requestDir
  forM_ (filter (".txt" `isSuffixOf`) reqs) $ \r -> do
    let reqPath = requestDir ++ "/" ++ r
    content <- readFile reqPath
    case parseBudget content of
      Nothing -> putStrLn ("role serve: skipping malformed request " ++ r)
      Just req -> do
        let verdict = budgetFits req cap
        writeFile (resultDir ++ "/" ++ r) (renderBudget req ++ " fits=" ++ show verdict)
        removeFile reqPath
        putStrLn ("role serve: " ++ r ++ " " ++ renderBudget req ++ " -> fits=" ++ show verdict)

-- | Fetch the static capacity artifact (the object-store stand-in), seeding it
-- with the demo's budget ceiling on first run.
fetchCapacity :: IO Vocab.Budget
fetchCapacity = do
  exists <- doesFileExist artifactPath
  if exists
    then fromMaybe defaultCap . parseBudget <$> readFile artifactPath
    else do
      createDirectoryIfMissing True busRoot
      writeFile artifactPath (renderBudget defaultCap)
      pure defaultCap
  where
    defaultCap = Vocab.Budget 6 10 40
