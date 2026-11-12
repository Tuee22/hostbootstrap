module RawFilePathAsShippedAuthority (forge) where
import HostBootstrap.Ownership.Shipped (ShippedAuthorityPath)
forge :: FilePath -> ShippedAuthorityPath
forge path = path
