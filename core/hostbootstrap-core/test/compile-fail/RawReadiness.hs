module RawReadiness where

import HostBootstrap.Readiness

badPolicy :: PollPolicy
badPolicy = PollPolicy 0 (Micros (-1))

badReady :: Ready scope planId resourceId resource dependency
badReady = Ready 0 0 0
