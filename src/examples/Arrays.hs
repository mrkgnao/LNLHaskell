{-# LANGUAGE UnicodeSyntax, DataKinds, TypeOperators, KindSignatures,
             TypeInType, GADTs, MultiParamTypeClasses, FunctionalDependencies,
             TypeFamilies, AllowAmbiguousTypes, FlexibleInstances,
             UndecidableInstances, InstanceSigs, TypeApplications, 
             ScopedTypeVariables, ConstraintKinds,
             EmptyCase, RankNTypes, FlexibleContexts, TypeFamilyDependencies
#-}
--             IncoherentInstances


module Arrays where
 
import Data.Kind
import qualified Data.Array.IO as ArrayIO
import Prelude hiding (read)
import Data.Proxy
import Data.Constraint
import System.TimeIt
import Control.Monad (void)
import Debug.Trace

import Types
import Context
import Lang
import Interface


-- Signature
-- ty will get substituted with (LType sig)
data ArraySig sig where
  ArraySig :: * -> ArraySig sig

type Array a = (LType' sig ('ArraySig a) :: LType sig)

-- Array Effect ----------------------------------------------------


class Monad m => HasArrayEffect m where
  type family LArray m a = r | r -> a
  newArray       :: Int -> a -> m (LArray m a)
  readArray      :: LArray m a -> Int -> m a
  writeArray     :: LArray m a -> Int -> a -> m ()
  deallocArray   :: LArray m a -> m ()
  sizeArray      :: LArray m a -> m Int

instance HasArrayEffect IO where
  type LArray IO a = ArrayIO.IOArray Int a
  newArray n     =  ArrayIO.newArray (0,n)
  readArray      =  ArrayIO.readArray
  writeArray     =  ArrayIO.writeArray
  deallocArray _ =  return ()
  sizeArray arr  = do
    (low,high) <- ArrayIO.getBounds arr
    return $ high - low

type family LArray' sig a where
  LArray' sig a = LArray (SigEffect sig) a
type HasArraySig sig = HasArrayEffect (SigEffect sig)

-- Has Array Domain ------------------------------------------

data ArrayLVal (lang :: Lang sig) :: LType sig -> * where
  VArr    :: forall sig (lang :: Lang sig) a. 
             LArray' sig a -> ArrayLVal lang (Array a)

--- Expressions -------------------------------------------
data ArrayLExp (lang :: Lang sig) :: Ctx sig -> LType sig -> * where
  Alloc   :: Int -> a -> ArrayLExp lang 'Empty (Array a)
  Dealloc :: LExp lang g (Array a) -> ArrayLExp lang g One
  Read    :: Int -> LExp lang g (Array a) -> ArrayLExp lang g (Array a ⊗ Lower a)
  Write   :: Int -> LExp lang g (Array a) -> a -> ArrayLExp lang g (Array a)
  Size    :: LExp lang g (Array a) -> ArrayLExp lang g (Array a ⊗ Lower Int)

type ArrayDom = '(ArrayLExp,ArrayLVal)

proxyArray :: Proxy ArrayDom
proxyArray = Proxy

instance Show (ArrayLExp lang g τ) where
  show (Alloc n _) = "Alloc " ++ show n
  show (Dealloc e) = "Dealloc " ++ show e
  show (Read i e) = "Read " ++ show i ++ " " ++ show e
  show (Write i e a) = "Write " ++ show i ++ " " ++ show e
  show (Size e) = "Size " ++ show e


type HasArrayDom (lang :: Lang sig) =
    ( HasArrayEffect (SigEffect sig)
    , WFDomain ArrayDom lang
    , WFDomain OneDom lang, WFDomain TensorDom lang, WFDomain LolliDom lang
    , WFDomain LowerDom lang )
     
alloc :: HasArrayDom lang
      => Int -> a -> LExp lang 'Empty (Array a)
alloc n a = Dom proxyArray $ Alloc n a

allocL :: HasArrayDom lang
       => Int -> a -> Lift lang (Array a)
allocL n a = Suspend $ alloc n a

dealloc :: HasArrayDom lang
        => LExp lang g (Array a) -> LExp lang g One
dealloc = Dom proxyArray . Dealloc

deallocL :: HasArrayDom lang
         => Lift lang (Array a ⊸ One)
deallocL = Suspend $ λ dealloc

read :: HasArrayDom lang
     => Int -> LExp lang g (Array a) -> LExp lang g (Array a ⊗ Lower a)
read i e = Dom proxyArray $ Read i e

readM :: HasArrayDom lang
      => Int -> LinT lang (LState' (Array a)) a
readM i = suspendT $ λ $ read i

write :: HasArrayDom lang
     => Int -> LExp lang g (Array a) -> a -> LExp lang g (Array a)
write i e a = Dom proxyArray $ Write i e a 

writeM :: forall sig (lang :: Lang sig) a.
          HasArrayDom lang
       => Int -> a -> LinT lang (LState' (Array a)) ()
writeM i a = suspendT . λ $ \arr -> write i arr a ⊗ put ()

size :: HasArrayDom lang
     => LExp lang g (Array a) -> LExp lang g (Array a ⊗ Lower Int)
size = Dom proxyArray . Size

sizeM :: HasArrayDom lang => LinT lang (LState' (Array a)) Int
sizeM = suspendT $ λ size

varray :: forall sig (lang :: Lang sig) a.
        HasArrayDom lang
     => LArray' sig a -> LVal lang (Array a)
varray = VDom proxyArray . VArr


instance HasArrayDom lang
      => Domain ArrayDom lang where

-- "what. -- Antal"
  evalDomain _ (Alloc n a) = do -- trace "before" $ return (error "after")
    arr <- newArray n a
    pure $ varray arr
  evalDomain ρ (Dealloc e) = do
    VArr arr <- toDomain @ArrayDom <$> eval' ρ e
    deallocArray arr
    pure vunit
  evalDomain ρ (Read i e) = do
    VArr arr <- toDomain @ArrayDom <$> eval' ρ e
    a <- readArray arr i
    pure $ varray arr `vpair` vput a
  evalDomain ρ (Write i e a) = do
    VArr arr <- toDomain @ArrayDom <$> eval' ρ e
    writeArray arr i a
    pure $ varray arr
  evalDomain ρ (Size e) = do
    VArr arr <- toDomain @ArrayDom <$> eval' ρ e
    len      <- sizeArray arr
    pure $ varray arr `vpair` vput len

foldrArray :: HasArrayDom lang
           => Lift lang (Lower a ⊸ τ ⊸ τ) 
           -> LExp lang 'Empty (τ ⊸ Array a ⊸ Array a ⊗ τ)
foldrArray f = λ $ \seed -> λ $ \arr -> 
    size arr `letPair` \(arr,l) -> l >! \len ->
    foldrArray' len f `app` seed `app` arr
  where
    foldrArray' :: HasArrayDom lang
                => Int -> Lift lang (Lower a ⊸ τ ⊸ τ)
                -> LExp lang 'Empty (τ ⊸ Array a ⊸ Array a ⊗ τ)
    foldrArray' 0 f = λ $ \seed -> λ $ \arr -> arr ⊗ seed
    foldrArray' n f = λ $ \seed -> λ $ \arr ->
        read (n-1) arr `letPair` \(arr,v) ->
        foldrArray' (n-1) f `app` (force f `app` v `app` seed) `app` arr
        

foldrArrayM :: HasArrayDom lang
            => (a -> b -> b)
            -> b -> LinT lang (LState' (Array a)) b
foldrArrayM f b = suspendT . λ $ \arr ->
    foldrArray f' `app` put b `app` arr
  where
    f' = Suspend . λ $ \a' -> a' >! \a ->
                   λ $ \b' -> b' >! \b -> put $ f a b


-- Examples

-- Without monad transformer

fromList :: forall lang a. HasArrayDom lang => [a] -> Lift lang (Array a)
fromList ls = foldr f (allocL (length ls) $ head ls) $ zip ls [1..]
  where
    f :: (a,Int) -> Lift lang (Array a) -> Lift lang (Array a)
    f (a,i) arr = Suspend $ write i (force arr) a


toList :: forall lang a. HasArrayDom lang 
       => Lift lang (Array a) -> Lin lang [a]
toList arr = suspendL $ 
    foldrArray f `app` put [] `app` force arr `letPair` \(arr,ls) ->
    dealloc arr `letUnit` ls
  where
    f :: Lift lang (Lower a ⊸ Lower [a] ⊸ Lower [a])
    f = Suspend $ lowerT2 `app` put (:)

toFromList :: HasArrayDom lang
           => [a] -> Lin lang [a]
toFromList ls = toList $ fromList ls


-- With monad transformer

fromListM :: (HasArrayDom lang, Show a)
         => [a] -> Lift lang (Array a)
fromListM [] = error "Cannot call fromList on an empty list"
fromListM ls@(a:as) = execLState (fromListM' $ zip ls [0..]) (allocL (length ls) a)

fromListM' :: (HasArrayDom lang, Show a)
           => [(a,Int)] -> LinT lang (LState' (Array a)) ()
fromListM' [] = return ()
fromListM' ((a,i):as) = do
  writeM i a
  fromListM' as


toListM :: HasArrayDom lang 
       => Lift lang (Array a) -> Lin lang [a]
toListM arr = evalLState toListM' arr deallocL

toListM' :: HasArrayDom lang
        => LinT lang (LState' (Array a)) [a]
toListM' = foldrArrayM (:) []

toFromListM :: (HasArrayDom lang, Show a)
           => [a] -> Lin lang [a]
toFromListM = toList . fromListM

type MyArraySig = ( 'Sig IO '[ ArraySig, TensorSig, OneSig, LowerSig, LolliSig ] :: Sig)
type MyArrayDom = ( 'Lang '[ ArrayDom, TensorDom, OneDom, LowerDom, LolliDom ] :: Lang MyArraySig )


toFromListIO :: Show a => [a] -> Lin MyArrayDom [a]
toFromListIO = toFromListM











-------------------------------
-- Compare to plain IOArrays --
-------------------------------

-- Invoke with the length of the array
toListPlain :: Int -> LArray IO a -> IO [a]
toListPlain 0 _ = return []
toListPlain i arr = do
  a <- readArray arr (i-1)
  as <- toListPlain (i-1) arr
  return $ as ++ [a]
  
fromListPlain :: [a] -> IO (LArray IO a)
fromListPlain [] = error "Cannot call fromList on an empty list"
fromListPlain ls@(a:as) = do
  arr <- newArray (length ls) a
  fromListPlain' 0 ls arr
  return arr

fromListPlain' :: Int -> [a] -> LArray IO a -> IO ()
fromListPlain' offset [] _ = return ()
fromListPlain' offset (a:as) arr = do
  writeArray arr offset a
  fromListPlain' (offset+1) as arr

toFromListPlain :: [a] -> IO [a]
toFromListPlain ls = do
  arr <- fromListPlain ls
  toListPlain (length ls) arr

plain :: IO [Int]
plain = toFromListPlain $ replicate 1000 3

comp :: Int -> IO ()
comp n = do
  timeIt . void . run $ toFromListIO ls
  timeIt . void $ toFromListPlain ls
  where
    ls = replicate n 3

-- ERROR: NONTERMINATING
{-
type MyArraySig = ( '(IO, '[ ArraySig ]) :: Sig )

type MyArrayDomain = ( '[ ArrayDom ] :: Dom MyArraySig )

-}
