module Control.Monad.Free
  ( Free(..)
  , FreeC(..)
  , MonadFree, wrap
  , liftF, liftFC
  , pureF, pureFC
  , mapF, injC
  , runFree
  , runFreeM
  , runFreeC
  , runFreeCM
  ) where

import Control.Monad.Trans
import Control.Monad.Eff
import Control.Monad.Rec.Class

import Data.Identity
import Data.Coyoneda
import Data.Either
import Data.Function
import Data.Inject (Inject, inj)

-- | The free `Monad` for a `Functor`.
-- |
-- | The implementation defers the evaluation of monadic binds so that it
-- | is safe to use monadic tail recursion, for example.
data Free f a = Pure a
              | Free (f (Free f a))
              | Gosub (forall s. (forall r. (Unit -> Free f r) -> (r -> Free f a) -> s) -> s)

-- | The free `Monad` for an arbitrary type constructor.
type FreeC f = Free (Coyoneda f)

-- | The `MonadFree` class provides the `wrap` function, which lifts
-- | actions described by a generating functor into a monad.
-- |
-- | The canonical instance of `MonadFree f` is `Free f`.
class MonadFree f m where
  wrap :: forall a. f (m a) -> m a

instance functorFree :: (Functor f) => Functor (Free f) where
  (<$>) f (Pure a) = Pure (f a)
  (<$>) f g = liftA1 f g

instance applyFree :: (Functor f) => Apply (Free f) where
  (<*>) = ap

instance applicativeFree :: (Functor f) => Applicative (Free f) where
  pure = Pure

instance bindFree :: (Functor f) => Bind (Free f) where
  (>>=) (Gosub g) f = Gosub (\h -> g (\a i -> h a (\x -> Gosub (\j -> j (const (i x)) f))))
  (>>=) a         f = Gosub (\h -> h (const a) f)

instance monadFree :: (Functor f) => Monad (Free f)

instance monadTransFree :: MonadTrans Free where
  lift f = Free $ do
    a <- f
    return (Pure a)

instance monadFreeFree :: (Functor f) => MonadFree f (Free f) where
  wrap = Free

-- | Lift an action described by the generating functor `f` into the monad `m`
-- | (usually `Free f`).
liftF :: forall f m a. (Functor f, Monad m, MonadFree f m) => f a -> m a
liftF = wrap <<< (<$>) return

-- | An implementation of `pure` for the `Free` monad.
pureF :: forall f a. (Applicative f) => a -> Free f a
pureF = Free <<< pure <<< Pure

-- | Lift an action described by the generating type constructor `f` into the monad
-- | `FreeC f`.
liftFC :: forall f a. f a -> FreeC f a
liftFC = liftF <<< liftCoyoneda

-- | An implementation of `pure` for the `FreeC` monad.
pureFC :: forall f a. (Applicative f) => a -> FreeC f a
pureFC = liftFC <<< pure

-- | Use a natural transformation to change the generating functor of a `Free` monad.
mapF :: forall f g a. (Functor f, Functor g) => Natural f g -> Free f a -> Free g a
mapF t fa = either (\s -> Free <<< t $ mapF t <$> s) Pure (resume fa)

-- | Embed computations in one `Free` monad as computations in the `Free` monad for
-- | a coproduct type constructor.
-- |
-- | This construction allows us to write computations which are polymorphic in the
-- | particular `Free` monad we use, allowing us to extend the functionality of
-- | our monad later.
injC :: forall f g a. (Inject f g) => FreeC f a -> FreeC g a
injC = mapF (liftCoyonedaT inj)

resume :: forall f a. (Functor f) => Free f a -> Either (f (Free f a)) a
resume f = case f of
  Pure x -> Right x
  Free x -> Left x
  g -> case resumeGosub g of
    Left l -> Left l
    Right r -> resume r
  where
  resumeGosub :: Free f a -> Either (f (Free f a)) (Free f a)
  resumeGosub (Gosub f) = f (\a g ->
    case a unit of
      Pure a -> Right (g a)
      Free t -> Left ((\h -> h >>= g) <$> t)
      Gosub h -> Right (h (\b i -> b unit >>= (\x -> i x >>= g)))
    )

-- | `runFree` runs a computation of type `Free f a`, using a function which unwraps a single layer of
-- | the functor `f` at a time.
runFree :: forall f a. (Functor f) => (f (Free f a) -> Free f a) -> Free f a -> a
runFree fn = runIdentity <<< runFreeM (Identity <<< fn)

-- | `runFreeM` runs a compuation of type `Free f a` in any `Monad` which supports tail recursion.
-- | See the `MonadRec` type class for more details.
runFreeM :: forall f m a. (Functor f, MonadRec m) => (f (Free f a) -> m (Free f a)) -> Free f a -> m a
runFreeM fn = tailRecM \f -> 
  case resume f of
    Left fs -> Left <$> fn fs
    Right a -> return (Right a)

-- | `runFreeC` is the equivalent of `runFree` for type constructors transformed with `Coyoneda`,
-- | hence we have no requirement that `f` be a `Functor`.
runFreeC :: forall f a. (forall a. f a -> a) -> FreeC f a -> a
runFreeC nat = runIdentity <<< runFreeCM (Identity <<< nat)

-- | `runFreeCM` is the equivalent of `runFreeM` for type constructors transformed with `Coyoneda`,
-- | hence we have no requirement that `f` be a `Functor`.
runFreeCM :: forall f m a. (MonadRec m) => Natural f m -> FreeC f a -> m a
runFreeCM nat = runFreeM (liftCoyonedaTF nat)

