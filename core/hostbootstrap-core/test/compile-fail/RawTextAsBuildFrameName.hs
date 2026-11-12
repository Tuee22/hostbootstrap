module RawTextAsBuildFrameName (update) where
import Data.Text (Text)
import HostBootstrap.Build (BuildBinding (..))
update :: Text -> BuildBinding -> BuildBinding
update identifier binding = binding{buildFrameName = identifier}
