{-| Example usage of this module:

>>> import Data.Vector.Unboxed
>>> let v = fromList [maxBound, 0] :: Vector Word64
>>> let sbv = prepare v
>>> index sbv 63
Just True
>>> index sbv 64
Just False
>>> rank sbv 27
Just 27
>>> rank sbv 128
Just 64

    This module is based on the paper "Broadword Implementation of Rank/Select
    Queries":

    <http://vigna.di.unimi.it/ftp/papers/Broadword.pdf>
-}

module Succinct.Vector (
    -- * Construction
      SuccinctBitVector
    , prepare

    -- * Queries
    , index
    , unsafeIndex
    , rank
    , unsafeRank
    ) where

-- TODO: Compress original bit vector

import Control.DeepSeq (NFData(..))
import Data.Bits ((.|.), (.&.))
import Data.Word (Word16, Word64)

import qualified Data.Bits           as Bits
import qualified Data.Vector.Generic as Generic
import qualified Data.Vector.Unboxed as Unboxed

-- $setup
-- >>> :set -XScopedTypeVariables
-- >>> import Data.Vector.Unboxed as Unboxed
-- >>> import Test.QuickCheck
-- >>> instance (Prim a, Arbitrary a) => Arbitrary (Vector a) where arbitrary = fmap fromList arbitrary

{-| Like `index` except that the bit index is not checked

    This will silently fail and return garbage if you supply an invalid index
-}
unsafeIndex :: SuccinctBitVector -> Int -> Bool
unsafeIndex i n = Bits.testBit w8 r
  where
    (q, r) = quotRem n 64
    w8 = Unboxed.unsafeIndex (bits i) q


-- | @(index i n)@ retrieves the bit at the index @n@
index :: SuccinctBitVector -> Int -> Maybe Bool
index i n =
    if 0 <= n && n < size i
    then Just (unsafeIndex i n)
    else Nothing

{-| A bit vector enriched with an index that adds O(1) `rank` and `select`
    queries

    The `SuccinctBitVector` increases the original bit vector's size by 25%
-}
data SuccinctBitVector = SuccinctBitVector
    { size    :: !Int
    -- ^ Size of original bit vector, in bits
    , rank9   :: !(Unboxed.Vector Word64)
    -- ^ Two-level index of cached rank calculations at Word64 boundaries
    , select9 :: !Select9
    -- ^ Primary and secondary inventory used for select calculations
    , bits    :: !(Unboxed.Vector Word64)
    -- ^ Original bit vector
    } deriving (Show)

instance NFData SuccinctBitVector where
    rnf i = i `seq` ()

data Select9 = Select9
    { primary   :: !(Unboxed.Vector Int)
    , secondary :: !(Unboxed.Vector Word64)
    } deriving (Show)

data Level = First | Second

data Status = Status
                   !Level
    {-# UNPACK #-} !Word64  -- Current rank
    {-# UNPACK #-} !Int     -- Position in vector

popCount :: Word64 -> Word64
popCount x0 = Bits.unsafeShiftR (x3 * 0x0101010101010101) 56
  where
    x1 = x0 - (Bits.unsafeShiftR (x0 .&. 0xAAAAAAAAAAAAAAAA) 1)
    x2 = (x1 .&. 0x3333333333333333) + ((Bits.unsafeShiftR x1 2) .&. 0x3333333333333333)
    x3 = (x2 + (Bits.unsafeShiftR x2 4)) .&. 0x0F0F0F0F0F0F0F0F

{-| Create an `SuccinctBitVector` from a `Unboxed.Vector` of bits packed as
    `Word64`s

    You are responsible for padding your data to the next `Word64` boundary
-}
prepare :: Unboxed.Vector Word64 -> SuccinctBitVector
prepare v = SuccinctBitVector
    { size    = lengthInBits
    , rank9   = vRank
    , select9 = Select9 v1 v2
    , bits    = v
    }
  where
    lengthInBits = len * 64

    len = Unboxed.length v

    -- TODO: What happens if `len == 0`?
    vRankLen = 2 * (((len - 1) `div` 8) + 1) + 1

    vRank = Unboxed.unfoldrN vRankLen iStep iBegin
      where
        iStep (Status level r i0) = Just (case level of
            First  -> (r , Status Second r       i0)
            Second -> (r', Status First (r + r8) i8) )
              where
                i1 = i0 + 1
                i2 = i1 + 1
                i3 = i2 + 1
                i4 = i3 + 1
                i5 = i4 + 1
                i6 = i5 + 1
                i7 = i6 + 1
                i8 = i7 + 1

                count i =
                    if i < len
                    then popCount (Unboxed.unsafeIndex v i)
                    else 0

                r1 =      count i0
                r2 = r1 + count i1
                r3 = r2 + count i2
                r4 = r3 + count i3
                r5 = r4 + count i4
                r6 = r5 + count i5
                r7 = r6 + count i6
                r8 = r7 + count i7

                r' = r1
                 .|. Bits.unsafeShiftL r2  9
                 .|. Bits.unsafeShiftL r3 18
                 .|. Bits.unsafeShiftL r4 27
                 .|. Bits.unsafeShiftL r5 36
                 .|. Bits.unsafeShiftL r6 45
                 .|. Bits.unsafeShiftL r7 54

        iBegin = Status First 0 0

    -- TODO: Check to see if point-free style interferes with fusion
    v1 :: Unboxed.Vector Int
    v1 =
          flip Unboxed.snoc lengthInBits
        ( Unboxed.map (\(_, i) -> i)
        ( Unboxed.filter (\(j, _) -> j `rem` 512 == 0)
        ( Unboxed.imap (,)
        ( oneIndices
          v ))))

    oneIndices :: Unboxed.Vector Word64 -> Unboxed.Vector Int
    oneIndices v =
          Unboxed.map (\(i, _) -> i)
        ( Unboxed.filter (\(_, b) -> b)
        ( Unboxed.imap (,)
        ( Unboxed.concatMap (\w64 ->
            Unboxed.generate 64 (Bits.testBit w64) )
          v )))
    {-# INLINE oneIndices #-}

    count :: Int -> Word64
    count basicBlockIndex =
        let i = basicBlockIndex * 2
        in  if i < Unboxed.length vRank
            then Unboxed.unsafeIndex vRank i
            else fromIntegral (maxBound :: Word16)

    -- TODO: What if the vector is empty?
    locate :: Unboxed.Vector Int -> Int -> Int
    locate v i =
        if i < Unboxed.length v
        then Unboxed.unsafeIndex v i
        else 0

    v2 =
        ( Unboxed.concatMap (\(p, q) ->
            -- TODO: Explain the deviation from the paper here
            let basicBlockBegin = p `div` 512
                basicBlockEnd   = q `div` 512
                numBasicBlocks  = basicBlockEnd - basicBlockBegin
                span            = numBasicBlocks * 2
            in  case () of
                  _ | numBasicBlocks < 1 ->
                        Unboxed.empty
                    | numBasicBlocks < 8 ->
                        Unboxed.generate span (\i ->
                                 if  i < 2
                            then let w16 j = count (basicBlockBegin + 4 * i + j)
                                           - count basicBlockBegin
                                     w64   =                    w16 0
                                         .|. Bits.unsafeShiftL (w16 1) 16
                                         .|. Bits.unsafeShiftL (w16 2) 32
                                         .|. Bits.unsafeShiftL (w16 3) 48
                                 in  w64
                            else 0 )
                    | numBasicBlocks < 64 ->
                        Unboxed.generate span (\i ->
                                 if  i < 2
                            then let w16 j = count (basicBlockBegin + 8 * (4 * i + j))
                                           - count basicBlockBegin
                                     w64   =                    w16 0
                                         .|. Bits.unsafeShiftL (w16 1) 16
                                         .|. Bits.unsafeShiftL (w16 2) 32
                                         .|. Bits.unsafeShiftL (w16 3) 48
                                 in  w64
                            else if  i < 18
                            then let w16 j = count (basicBlockBegin + 4 * (i - 2) + j)
                                           - count basicBlockBegin
                                     w64   =                    w16 0
                                         .|. Bits.unsafeShiftL (w16 1) 16
                                         .|. Bits.unsafeShiftL (w16 2) 32
                                         .|. Bits.unsafeShiftL (w16 3) 48
                                 in  w64
                            else 0 )
                    | numBasicBlocks < 128 ->
                        let ones =
                                oneIndices (Unboxed.unsafeSlice p (q - p) v)
                        in  Unboxed.generate span (\i ->
                                let w16 j = fromIntegral (locate ones (4 * i + j))
                                    w64 =                      w16 0
                                        .|. Bits.unsafeShiftL (w16 1) 16
                                        .|. Bits.unsafeShiftL (w16 2) 32
                                        .|. Bits.unsafeShiftL (w16 3) 48
                                in  w64 )
                    | numBasicBlocks < 256 ->
                        let ones =
                                oneIndices (Unboxed.unsafeSlice p (q - p) v)
                        in  Unboxed.generate span (\i ->
                                let w32 j = fromIntegral (locate ones (2 * i + j))
                                    w64 =                      w32 0
                                        .|. Bits.unsafeShiftL (w32 1) 32
                                in  w64 )
                    | otherwise ->
                        let ones =
                                oneIndices (Unboxed.unsafeSlice p (q - p) v)
                        in  Unboxed.generate span (\i ->
                                let w64 = fromIntegral (p + locate ones i)
                                in  w64 ) )
        ) (Unboxed.zip v1 (Unboxed.drop 1 v1))

{-| Like `rank` except that the bit index is not checked

    This will silently fail and return garbage if you supply an invalid index
-}
unsafeRank :: SuccinctBitVector -> Int -> Word64
unsafeRank (SuccinctBitVector _ rank9_ _ bits_) p =
        f
    +   ((Bits.unsafeShiftR s (fromIntegral ((t + (Bits.unsafeShiftR t 60 .&. 0x8)) * 9))) .&. 0x1FF)
    +   popCount (Unboxed.unsafeIndex bits_ w .&. mask)
  where
    (w, b) = quotRem p 64
    (q, r) = quotRem w 8
    f      = Unboxed.unsafeIndex rank9_ (2 * q    )
    s      = Unboxed.unsafeIndex rank9_ (2 * q + 1)
    t      = fromIntegral (r - 1) :: Word64
    mask   = negate (Bits.shiftL 0x1 (64 - b))

{-| @(rank i n)@ computes the number of ones up to, but not including the bit at
    index @n@

>>> rank (prepare (fromList [0, maxBound])) 66
Just 2

    The bits are 0-indexed, so @rank i 0@ always returns 0 and @rank i (size i)@
    returns the total number of ones in the bit vector

prop> rank (prepare v) 0 == Just 0
prop> let sv = prepare v in rank sv (size sv) == Just (Unboxed.sum (Unboxed.map popCount v))

    This returns a valid value wrapped in a `Just` when:

> 0 <= n <= size i

    ... and returns `Nothing` otherwise

prop> let sv = prepare v in (0 <= n && n <= size sv) || (rank sv n == Nothing)
-}
rank :: SuccinctBitVector -> Int -> Maybe Word64
rank i p =
    if 0 <= p && p <= size i
    then Just (unsafeRank i p)
    else Nothing
