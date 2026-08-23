module ForgeProviderResourceDeclaration where

-- Provider targets are selected only through the two closed smart values; a
-- project cannot construct a declaration carrying arbitrary frame text.
import HostBootstrap.Step
    ( ProviderResourceDeclaration (ProviderResourceAtCurrentFrame)
    )

forged :: ProviderResourceDeclaration
forged = ProviderResourceAtCurrentFrame
