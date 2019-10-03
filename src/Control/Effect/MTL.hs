{-# language UndecidableInstances #-}
{-# language AllowAmbiguousTypes #-}
{-# language QuantifiedConstraints #-}
{-# language DerivingVia #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Control.Effect.MTL where

import Control.Effect.Carrier
import Control.Effect.Error
import Control.Effect.Lift
import Control.Effect.Reader
import Control.Effect.State

import Data.Functor.Yoneda

import Control.Monad (join)
import qualified Control.Monad.Trans.Control  as MTC
import qualified Control.Monad.Trans.Identity as MT
import qualified Control.Monad.Trans.Except   as MT
import qualified Control.Monad.Trans.Reader   as MT
import qualified Control.Monad.Trans.State    as MT


newtype StT t a = StT { unStT :: MTC.StT t a }

newtype YoStT t a = YoStT { unYoStT :: Yoneda (StT t) a }
  deriving Functor via Yoneda (StT t)



relayTransControl :: forall sig t m a.
    ( MTC.MonadTransControl t
    , Carrier sig m
    , Effect sig
    , Monad m
    , Monad (t m)
    )
    => (forall x y. (x -> y) -> MTC.StT t x -> MTC.StT t y)
    -> sig (t m) a
    -> t m a
relayTransControl fmap' sig = do
    state <- captureYoT

    yosta <- MTC.liftWith $ \runT -> do
        let runTYo :: forall x. t m x -> m (YoStT t x)
            runTYo = fmap liftYo' . runT

            handler :: forall x. YoStT t (t m x) -> m (YoStT t x)
            handler = runTYo . join . restoreYoT

            handle' :: sig (t m) a -> sig m (YoStT t a)
            handle' = handle state handler

        eff (handle' sig)

    restoreYoT yosta
  where
    restoreYoT :: forall x. YoStT t x -> t m x
    restoreYoT = MTC.restoreT . return . lowerYo'

    captureYoT :: t m (YoStT t ())
    captureYoT = fmap liftYo' MTC.captureT

    liftYo' :: forall x. MTC.StT t x -> YoStT t x
    liftYo' stx = YoStT (Yoneda (\f -> StT (fmap' f stx)))

    lowerYo' :: forall x. YoStT t x -> MTC.StT t x
    lowerYo' = unStT . lowerYoneda . unYoStT


instance (Monad m, Carrier sig m, Effect sig) => Carrier (Error e :+: sig) (MT.ExceptT e m) where
    eff (L (Throw e))     = MT.throwE e
    eff (L (Catch m h k)) = MT.catchE m h >>= k
    eff (R other)         = relayTransControl fmap other


instance (Monad m, Carrier sig m, Effect sig) => Carrier (Lift m) (MT.IdentityT m) where
    eff (Lift m) = MT.IdentityT (m >>= MT.runIdentityT)


instance (Monad m, Carrier sig m, Effect sig) => Carrier (Reader r :+: sig) (MT.ReaderT r m) where
    eff (L (Ask k))       = MT.ask >>= k
    eff (L (Local g m k)) = MT.local g m >>= k
    eff (R other)         = relayTransControl id other


instance (Monad m, Carrier sig m, Effect sig) => Carrier (State s :+: sig) (MT.StateT s m) where
    eff (L (Get k))   = MT.get >>= k
    eff (L (Put s k)) = MT.put s >> k
    eff (R other)     = relayTransControl (\f (a, s) -> (f a, s)) other