{-# LANGUAGE OverloadedStrings #-}

module ConstructEmptyProviderConfigValue where

import HostBootstrap.Substrate.Provider.Report

emptyValue :: ProviderConfigValue
emptyValue = ProviderConfigValue ""
