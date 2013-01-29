{-# LANGUAGE CPP #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

#ifndef MIN_VERSION_base
#define MIN_VERSION_base(x,y,z) 0
#endif
--------------------------------------------------------------------
-- |
-- Module    :  Analytics.Meta
-- Copyright :  (c) Edward Kmett 2011-2013
-- License   :  BSD3
-- Maintainer:  Edward Kmett <ekmett@gmail.com>
-- Stability :  experimental
-- Portability: non-portable
--
-- Skolem and Meta variables
--------------------------------------------------------------------
module Analytics.Meta
  (
  -- * Meta variables
    Meta(Meta,Skolem)
  , metaId, metaRef
  -- ** Meta Prisms
  , skolem
  -- ** Union-By-Rank
  , Rank, metaRank, bumpRank
  -- ** Working with Meta
  , newMeta
  , newSkolem
  , readMeta
  , writeMeta
  -- ** Pruning
  , cycles
  , semiprune
  , zonk
  -- * MetaEnv
  , MetaEnv
  , HasMetaEnv(..)
  , MonadMeta
  -- * The unification monad
  , M, runM, runM_
  , throwM
  , fresh
  ) where
import Control.Applicative
import Control.Exception
import Control.Lens
import Control.Monad
import Control.Monad.Reader.Class
import Control.Monad.ST (ST, runST)
import Control.Monad.ST.Class
import Control.Monad.ST.Unsafe
import Data.Foldable
import Data.Function (on)
import Data.Functor.Compose
import Data.IntSet as IntSet
import Data.Monoid
import Data.Set as Set
import Data.STRef
import Data.Traversable
import Data.Word
import Analytics.Diagnostic
import Analytics.Syntax

------------------------------------------------------------------------------
-- MetaEnv
------------------------------------------------------------------------------

data MetaEnv s = MetaEnv { _metaRendering :: Rendering, _metaFresh :: {-# UNPACK #-} !(STRef s Int) }

makeClassy ''MetaEnv

instance HasRendering (MetaEnv s) where
  rendering = metaRendering

------------------------------------------------------------------------------
-- Meta
------------------------------------------------------------------------------

-- | Rank for union-by-rank viewing meta-variables as disjoint set forests
type Rank = Word

bumpRank :: STRef s Rank -> ST s ()
#if MIN_VERSION_base(4,6,0)
bumpRank w = modifySTRef' w (+1)
#else
bumpRank w = do
  n <- readSTRef w
  let n' = n + 1
  n' `seq` writeSTRef w n'
#endif

-- | A meta variable for skolemization and unification
data Meta s f
  = Meta   { _metaId :: !Int
           , _metaRef :: !(STRef s (Maybe (f (Meta s f))))
           , _metaRank :: !(STRef s Rank)
           }
  | Skolem { _metaId :: !Int }

makeLenses ''Meta

-- | This 'Prism' matches 'Skolem' variables.
skolem :: Prism' (Meta s f) Int
skolem = prism Skolem $ \t -> case t of
  Skolem i -> Right i
  _        -> Left t

instance Show (Meta s f) where
  showsPrec d (Meta i _ _) = showParen (d > 10) $
    showString "Meta " . showsPrec 11 i . showString " ..."
  showsPrec d (Skolem i) = showParen (d > 10) $
    showString "Skolem " . showsPrec 11 i

instance Eq (Meta s f) where
  (==) = (==) `on` view metaId
  {-# INLINE (==) #-}

instance Ord (Meta s f) where
  compare = compare `on` view metaId
  {-# INLINE compare #-}

-- | Construct a new meta variable
newMeta :: MonadMeta s m => m (Meta s f)
newMeta = Meta <$> fresh <*> liftST (newSTRef Nothing) <*> liftST (newSTRef 0)
{-# INLINE newMeta #-}

-- | Construct a new Skolem variable that unifies only with itself.
newSkolem :: MonadMeta s m => m (Meta s f)
newSkolem = Skolem <$> fresh
{-# INLINE newSkolem #-}

-- | Read a meta variable
readMeta :: MonadMeta s m => Meta s f -> m (Maybe (f (Meta s f)))
readMeta (Meta _ r _) = liftST $ readSTRef r
readMeta (Skolem _)     = return Nothing
{-# INLINE readMeta #-}

-- | Write to a meta variable
writeMeta :: MonadMeta s m => Meta s f -> f (Meta s f) -> m ()
writeMeta (Meta _ r _) a = liftST $ writeSTRef r (Just a)
writeMeta (Skolem _) _     = fail "writeMeta: skolem"
{-# INLINE writeMeta #-}

cc :: (Functor m, Functor n) => Iso (m a) (n b) (Compose m (Const a) x) (Compose n (Const b) y)
cc = iso (Compose . fmap Const) (fmap getConst . getCompose)

-- | Retrieve the set of all cyclic meta-variables
--
-- This matters because when reporting a cycle we may encounter other
-- already formed cycles.
cycles :: (Foldable f, MonadMeta s m) => IntSet -> f (Meta s f) -> m (Set (Meta s f))
cycles = auf cc traverse_ . go where
  go is m@(Meta i r _)
    | is^.contains i = return $ Set.singleton m
    | otherwise = liftST (readSTRef r) >>= \mb -> case mb of
      Just b  -> cycles (IntSet.insert i is) b
      Nothing -> return mempty
  go _ _ = return mempty
{-# INLINE cycles #-}

-- | Path-compression
semiprune :: (Variable f, Monad f, MonadMeta s m) => f (Meta s f) -> m (f (Meta s f))
semiprune t0 = case preview var t0 of
  Just v0 -> loop t0 v0
  Nothing -> return t0
  where
    loop t1 v1 = readMeta v1 >>= \mb -> case mb of
      Nothing -> return t1
      Just t  -> case preview var t of
        Nothing -> return t
        Just v  -> do
          fv <- loop t v
          writeMeta v1 fv
          return fv
{-# INLINE semiprune #-}

-- | Expand meta variables recursively
zonk :: (MonadMeta s m, Traversable f, Monad f) => IntSet -> f (Meta s f) -> (Set (Meta s f) -> m (f (Meta s f))) -> m (f (Meta s f))
zonk is fs occ = fmap join . for fs $ \m -> readMeta m >>= \mv -> case mv of
  Nothing  -> return (return m)
  Just fmf
    | is^.contains (m^.metaId) -> cycles is fmf >>= occ
    | otherwise -> do
    r <- zonk (is & contains (m^.metaId) .~ True) fmf occ
    r <$ writeMeta m r

------------------------------------------------------------------------------
-- Result
------------------------------------------------------------------------------

-- | The internal result type used by 'M'.
data Result a
  = Error !Diagnostic
  | OK !Int a

instance Functor Result where
  fmap f (OK n a) = OK n (f a)
  fmap _ (Error d) = Error d
  {-# INLINE fmap #-}

------------------------------------------------------------------------------
-- M
------------------------------------------------------------------------------

type MonadMeta s m = (Applicative m, MonadST m, MonadReader (MetaEnv (World m)) m, World m ~ s)

-- | The unification monad provides a 'fresh' variable supply and tracks a current
-- 'Rendering' to blame for any unification errors.
newtype M s a = M { unM :: MetaEnv s -> ST s a }

instance Functor (M s) where
  fmap f (M m) = M (fmap f . m)
  {-# INLINE fmap #-}

instance Applicative (M s) where
  pure = return
  {-# INLINE pure #-}
  (<*>) = ap
  {-# INLINE (<*>) #-}

instance Monad (M s) where
  return = M . const . return
  {-# INLINE return #-}
  M m >>= k = M $ \ e -> do
    a <- m e
    unM (k a) e
  {-# INLINE (>>=) #-}
  fail s = M $ \e -> unsafeIOToST $ throwIO $! die e s

instance MonadST (M s) where
  type World (M s) = s
  liftST m = M $ \_ -> m
  {-# INLINE liftST #-}

instance MonadReader (MetaEnv s) (M s) where
  ask = M $ \e -> return e
  {-# INLINE ask #-}
  local f (M m) = M (m . f)
  {-# INLINE local #-}

instance Monoid m => Monoid (M s m) where
  mempty  = pure mempty
  mappend = liftA2 mappend

catchingST :: Getting (First a) SomeException t a b -> ST s r -> (a -> ST s r) -> ST s r
catchingST l m h = unsafeIOToST $ catchJust (preview l) (unsafeSTToIO m) (unsafeSTToIO . h)
{-# INLINE catchingST #-}

-- | Throw a 'Diagnostic' error.
throwM :: MonadMeta s m => Diagnostic -> m a
throwM d = liftST $ unsafeIOToST (throwIO d)
{-# INLINE throwM #-}

-- | Evaluate an expression in the 'M' 'Monad' with a fresh variable supply.
runM :: Rendering -> (forall s. M s a) -> Either Diagnostic a
runM r m = runST $ do
  i <- newSTRef 0
  catchingST _Diagnostic (Right <$> unM m (MetaEnv r i)) (return . Left)
{-# INLINE runM #-}

-- | Evaluate an expression in the 'M' 'Monad' with a fresh variable supply, throwing any errors returned.
runM_ :: Rendering -> (forall s. M s a) -> a
runM_ r m = runST $ do
  i <- newSTRef 0
  unM m (MetaEnv r i)

-- | Generate a 'fresh' variable
fresh :: MonadMeta s m => m Int
fresh = do
  s <- view metaFresh
  liftST $ do
    i <- readSTRef s
    writeSTRef s $! i + 1
    return i
{-# INLINE fresh #-}
