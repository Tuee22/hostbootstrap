{-# LANGUAGE OverloadedStrings #-}

-- | The hostbootstrap-demo webservice: a thin @wai@ application served by @warp@.
--
-- Routes: @GET /api/budget@ returns the 'BudgetView' as JSON (the e2e target and
-- the SPA's data source); @GET /@ serves the SPA shell that loads the
-- @esbuild@-bundled Halogen app. Kept on the warm @warp@/@wai@/@aeson@ stack (no
-- servant) so a derived project's container build hits the base-image warm store.
module HostBootstrapDemo.Web.Server
  ( app,
    serveWeb,
    indexHtml,
  )
where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as LBS
import Network.HTTP.Types (hContentType, status200, status404)
import Network.Wai (Application, pathInfo, responseFile, responseLBS)
import Network.Wai.Handler.Warp (run)
import HostBootstrapDemo.Web.Api (budgetView)

-- | The @esbuild@ bundle path, relative to the directory @web serve@ runs from
-- (the project root, where @web/public/app.js@ is produced by build #3).
bundlePath :: FilePath
bundlePath = "web/public/app.js"

-- | The @wai@ application: the budget JSON endpoint, the SPA shell, the bundled
-- Halogen app, and a 404.
app :: Application
app req respond = case pathInfo req of
  ["api", "budget"] ->
    respond (responseLBS status200 [(hContentType, "application/json")] (encode budgetView))
  ["app.js"] ->
    respond (responseFile status200 [(hContentType, "application/javascript")] bundlePath Nothing)
  [] ->
    respond (responseLBS status200 [(hContentType, "text/html; charset=utf-8")] indexHtml)
  _ ->
    respond (responseLBS status404 [(hContentType, "text/plain")] "not found")

-- | The SPA shell: a minimal HTML document that mounts the @esbuild@ bundle the
-- @web bridge@ + @spago build@ + @esbuild@ steps produce (served from @/app.js@).
-- The Playwright e2e drives the rendered tabs; the bundle is built in the project
-- container (build #3).
indexHtml :: LBS.ByteString
indexHtml =
  LBS.fromStrict
    "<!doctype html>\n\
    \<html lang=\"en\">\n\
    \<head><meta charset=\"utf-8\"><title>hostbootstrap-demo</title></head>\n\
    \<body>\n\
    \  <div id=\"app\"></div>\n\
    \  <script src=\"/app.js\"></script>\n\
    \</body>\n\
    \</html>\n"

-- | Serve the webservice on the incus host (the Playwright @baseURL@). Binds all
-- interfaces so the container-side Playwright run can reach the host.
serveWeb :: Int -> IO ()
serveWeb port = do
  putStrLn ("web serve: listening on http://0.0.0.0:" ++ show port ++ " (GET /api/budget, GET /)")
  run port app
