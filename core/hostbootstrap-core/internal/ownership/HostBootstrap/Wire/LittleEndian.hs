{- | Reading fixed-width little-endian words off a wire.

Two of this project's wires — the shipped ownership transaction and the global
host wall's durable record — frame their fields with a little-endian length
prefix, and each had written the same byte-to-word conversion out. It is one
wire convention, so it is one function here, and a decoder that wants it
supplies the bytes its own truncation refusal already checked for.

Nothing here refuses: a decoder decides what "not enough bytes" means in its own
error vocabulary, and this only interprets the bytes it is handed. Handing it
fewer than the width interprets exactly those, which is why every caller reads
the width first.
-}
module HostBootstrap.Wire.LittleEndian (
    word32LE,
    word64LE,
) where

import Data.Bits (Bits, shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word32, Word64)

-- | The first four bytes, least significant first.
word32LE :: ByteString -> Word32
word32LE = littleEndian 4

-- | The first eight bytes, least significant first.
word64LE :: ByteString -> Word64
word64LE = littleEndian 8

{- | Fold the first @width@ bytes into a word, least significant byte first.

Folding from the right builds the word most-significant byte outwards, so the
shift count is never written per byte and no index can be out of range.
-}
littleEndian :: (Bits word, Num word) => Int -> ByteString -> word
littleEndian width =
    ByteString.foldr accumulate 0 . ByteString.take width
  where
    accumulate byte accumulated = shiftL accumulated 8 .|. fromIntegral byte
