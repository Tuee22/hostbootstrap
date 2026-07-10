{-# LANGUAGE OverloadedStrings #-}

{- | The hostbootstrap-demo webservice: a thin @wai@ application served by @warp@.

Routes: @GET /api/budget@ returns the 'BudgetView' as JSON (the e2e target and
the SPA's data source); @GET /@ serves the SPA shell that loads the
@esbuild@-bundled Halogen app. Kept on the warm @warp@/@wai@/@aeson@ stack (no
servant) so a derived project's container build hits the base-image warm store.
-}
module HostBootstrapDemo.Web.Server (
    app,
    serveWeb,
    indexHtml,
)
where

import Data.Aeson (encode)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Context as Context
import HostBootstrapDemo.Config (ProjectConfig (message))
import HostBootstrapDemo.Web.Api (
    AcceleratorAddFailure,
    AcceleratorAddRequest,
    acceleratorBadRequest,
    acceleratorUnavailable,
    addRequestId,
    budgetView,
    mkAcceleratorAddRequest,
 )
import Network.HTTP.Types (hContentType, status200, status400, status404, status503)
import Network.Wai (Application, Request, Response, pathInfo, queryString, responseFile, responseLBS)
import Network.Wai.Handler.Warp (run)
import Text.Read (readMaybe)

{- | The @esbuild@ bundle path, relative to the directory @service run web@ runs from
(the project root, where @web/public/app.js@ is produced by build #3).
-}
bundlePath :: FilePath
bundlePath = "web/public/app.js"

{- | The @wai@ application, parameterized by the config-driven served @message@
(Sprint 20.1): the budget JSON endpoint (which carries the message), the SPA
shell, the bundled Halogen app, and a 404.
-}
app :: Text -> Application
app msg req respond = case pathInfo req of
    ["api", "budget"] ->
        respond (responseLBS status200 [(hContentType, "application/json")] (encode (budgetView msg)))
    ["api", "accelerator", "add"] ->
        respond (acceleratorAddResponse req)
    ["app.js"] ->
        respond (responseFile status200 [(hContentType, "application/javascript")] bundlePath Nothing)
    [] ->
        respond (responseLBS status200 [(hContentType, "text/html; charset=utf-8")] indexHtml)
    _ ->
        respond (responseLBS status404 [(hContentType, "text/plain")] "not found")

acceleratorAddResponse :: Request -> Response
acceleratorAddResponse req =
    case parseAcceleratorAddRequest req of
        Left failure ->
            responseLBS status400 [(hContentType, "application/json")] (encode failure)
        Right addReq ->
            responseLBS status503 [(hContentType, "application/json")] (encode (acceleratorUnavailable (addRequestId addReq)))

parseAcceleratorAddRequest :: Request -> Either AcceleratorAddFailure AcceleratorAddRequest
parseAcceleratorAddRequest req = do
    rid <- Right (T.pack (maybe "web-ui" BS8.unpack (lookupQuery "requestId")))
    leftRaw <- required "left" rid
    rightRaw <- required "right" rid
    leftVal <- number "left" rid leftRaw
    rightVal <- number "right" rid rightRaw
    Right (mkAcceleratorAddRequest rid leftVal rightVal)
  where
    pairs = queryString req
    lookupQuery key = lookup key pairs >>= id
    required key rid =
        maybe
            (Left (acceleratorBadRequest rid ("missing query parameter: " <> T.pack (BS8.unpack key))))
            Right
            (lookupQuery key)
    number key rid raw =
        maybe
            (Left (acceleratorBadRequest rid ("invalid numeric query parameter: " <> T.pack (BS8.unpack key))))
            Right
            (readMaybe (BS8.unpack raw))

{- | The SPA shell: a minimal HTML document that mounts the @esbuild@ bundle the
@web bridge@ + @spago build@ + @esbuild@ steps produce (served from @/app.js@).
The Playwright e2e drives the rendered tabs; the bundle is built in the project
container (build #3).
-}
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

{- | Serve the webservice as the @web@ cluster-service pod, bound on @0.0.0.0:8080@
and reached through the @30080@ NodePort (the Playwright @baseURL@). Binding all
interfaces lets the in-cluster Playwright run reach it. Reads its own mounted
@<project>.dhall@ via the core generic loader (the cluster-service config the
ConfigMap delivers) and serves the config-driven @message@ from it (Sprint 20.1),
so the served value is whatever the active config carries.
-}
serveWeb :: Int -> IO ()
serveWeb port = do
    cfg <-
        Schema.requireSiblingProjectConfig
            (T.pack "hostbootstrap-demo")
            Context.ServiceCommand
            [] ::
            IO ProjectConfig
    let msg = message cfg
    putStrLn ("web serve: listening on http://0.0.0.0:" ++ show port ++ " (GET /api/budget, GET /); message=" ++ T.unpack msg)
    run port (app msg)
