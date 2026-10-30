module RawReadiness where

import HostBootstrap.Readiness

badPolicy :: Micros -> PollPolicy
badPolicy delay = PollPolicy 0 delay

badMicros :: Micros
badMicros = Micros (-1)

badReady :: Ready scope planId resourceId resource dependency
badReady = Ready 0 0 0
