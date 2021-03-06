{-|
Module      : Data.HdrHistogram.Mutable
Copyright   : (c) Josh Bohde, 2015
License     : GPL-3
Maintainer  : josh@joshbohde.com
Stability   : experimental
Portability : POSIX

A Haskell implementation of <http://www.hdrhistogram.org/ HdrHistogram>.
It allows storing counts of observed values within a range,
while maintaining precision to a configurable number of significant
digits.

The mutable histogram allows only writes, and conversion to and from
pure histograms. It follows the original implementation, and has
similar performance characteristics. Current recording benchmarks take
about 9ns, and allocates 16 bytes.

-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Data.HdrHistogram.Mutable (
  -- * Histogram
  Histogram(..), new, fromConfig,

  -- * Writing
  record, recordValues,

  -- * Converting
  freeze, unsafeFreeze, thaw, unsafeThaw,

  -- * Re-exports
  Config, HasConfig
  ) where

import           Control.DeepSeq                   (NFData, deepseq, rnf)
import           Control.Monad.Primitive           (PrimMonad, PrimState)
import           Data.Bits                         (FiniteBits)
import qualified Data.HdrHistogram                 as H
import           Data.HdrHistogram.Config
import           Data.HdrHistogram.Config.Internal
import           Data.Primitive.MutVar             (MutVar, modifyMutVar',
                                                    newMutVar, readMutVar)
import           Data.Proxy                        (Proxy (Proxy))
import           Data.Tagged                       (Tagged (Tagged))
import qualified Data.Vector.Unboxed               as U
import qualified Data.Vector.Unboxed.Mutable       as MU
import           GHC.Generics                      (Generic)

-- | A mutable 'Histogram'
data Histogram s c value count = Histogram {
  _config    :: HistogramConfig value,
  totalCount :: MutVar s count,
  counts     :: U.MVector s count
} deriving (Generic)

instance (NFData value, NFData count) => NFData (Histogram s config value count) where
  rnf (Histogram c _ vec) = deepseq c $ deepseq vec ()

-- | Construct a 'Histogram'
new :: forall m config a count.
      (PrimMonad m, HasConfig config,
       Integral a, FiniteBits a,
       U.Unbox count, Integral count) =>
      m (Histogram (PrimState m) config a count)
new = fromConfig (Tagged c :: Tagged config (HistogramConfig a))
  where
    c = getConfig p
    p = Proxy :: Proxy config

-- | Construct a 'Histogram' from the given 'HistogramConfig'. In this
-- case 'c' is a phantom type.
fromConfig :: (PrimMonad m, U.Unbox count, Integral count) => Tagged c (HistogramConfig value) -> m (Histogram (PrimState m) c value count)
fromConfig (Tagged c) = do
  vect <- MU.replicate (size c) 0
  totals <- newMutVar 0
  return Histogram {
    _config = c,
    totalCount = totals,
    counts = vect
  }


{-# INLINEABLE record #-}
-- | Record value single value to the 'Histogram'
record :: (Integral value, Integral count, FiniteBits value, U.Unbox count, PrimMonad m) =>
         Histogram (PrimState m) c value count -> value -> m ()
record h val = recordValues h val 1

{-# INLINEABLE recordValues #-}
-- | Record a multiple instances of a value value to the 'Histogram'
recordValues :: (Integral value, Integral count, FiniteBits value, U.Unbox count, PrimMonad m) =>
               Histogram (PrimState m) config value count -> value -> count -> m ()
recordValues h val count = do
  modifyMutVar' (totalCount h) (+ count)
  modify (counts h) (+ count) (indexForValue c val)
  where
    c = _config h
    modify v f i = do
      a <- MU.unsafeRead v i
      MU.unsafeWrite v i (f a)

-- | Convert a mutable 'Histogram' to a pure 'Histogram'
freeze :: (MU.Unbox count, PrimMonad m) => Histogram (PrimState m) config value count -> m (H.Histogram config value count)
freeze (Histogram c total vec) = do
  t <- readMutVar total
  v <- U.freeze vec
  return $ H.Histogram c t v

-- | Convert a mutable 'Histogram' to a pure 'Histogram'. The mutable cannot counte reused after this.
unsafeFreeze :: (MU.Unbox count, PrimMonad m) => Histogram (PrimState m) config value count -> m (H.Histogram config value count)
unsafeFreeze (Histogram c total vec) = do
  t <- readMutVar total
  v <- U.unsafeFreeze vec
  return $ H.Histogram c t v

-- | Convert a pure 'Histogram' to a mutable 'Histogram'.
thaw :: (MU.Unbox count, PrimMonad m) => H.Histogram config value count -> m (Histogram (PrimState m) config value count)
thaw (H.Histogram c total vec) = do
  t <- newMutVar total
  v <- U.thaw vec
  return $ Histogram c t v

-- | Convert a pure 'Histogram' to a mutable 'Histogram'. The pure cannot counte reused after this.
unsafeThaw :: (MU.Unbox count, PrimMonad m) => H.Histogram config value count -> m (Histogram (PrimState m) config value count)
unsafeThaw (H.Histogram c total vec) = do
  t <- newMutVar total
  v <- U.unsafeThaw vec
  return $ Histogram c t v
