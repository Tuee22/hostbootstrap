{-# LANGUAGE OverloadedStrings #-}

module ForgeRecordKey where

import HostBootstrap.Protected (RecordKey)

forged :: RecordKey
forged = RecordKey "../../x"
