module ImportServiceInternal where

-- A downstream consumer cannot import the hidden owner of the finalized
-- service registry, its constructors, or its specification reindex kernel.
import HostBootstrap.Service.Internal
