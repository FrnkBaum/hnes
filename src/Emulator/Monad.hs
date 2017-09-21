{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Emulator.Monad (
    MonadEmulator(..)
  , IOEmulator
  , runIOEmulator
) where

import           Control.Monad.Reader (ReaderT, ask, runReaderT)
import           Control.Monad.ST     (RealWorld, stToIO)
import           Control.Monad.Trans  (MonadIO, lift)
import           Emulator.Cartridge
import           Emulator.Nes         as Nes

class Monad m => MonadEmulator m where
  load :: Nes.Address a -> m a
  store :: Nes.Address a -> a -> m ()

newtype IOEmulator a = IOEmulator (ReaderT (Nes RealWorld)  IO a)
  deriving (Functor, Applicative, Monad, MonadIO)

instance MonadEmulator IOEmulator where
  {-# INLINE load #-}
  load address = IOEmulator $ do
    mem <- ask
    lift $ stToIO $ Nes.read mem address
  {-# INLINE store #-}
  store address word = IOEmulator $ do
    mem <- ask
    lift $ stToIO $ Nes.write mem address word

runIOEmulator :: Cartridge -> IOEmulator a ->  IO a
runIOEmulator cart (IOEmulator reader) = do
  mem <- stToIO $ Nes.new cart
  runReaderT reader mem
