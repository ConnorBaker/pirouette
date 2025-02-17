{-# LANGUAGE ConstrainedClassMethods #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Pirouette.Term.Syntax.SystemF where

import Control.Arrow (first, second)
import Control.Monad.Identity
import Data.Data
import Data.Foldable
import Data.Generics.Uniplate.Data ()
import Data.Generics.Uniplate.Operations (transform)
import Data.Maybe (mapMaybe)
import Data.String
import Data.Void
import GHC.Stack (HasCallStack)
import Optics.TH
import Pirouette.Term.Syntax.Subst

-- * System F

-- ** Annotated Variables

data VarMeta meta ann f
  = Bound (Ann ann) Integer
  | Free f
  | Meta meta -- Meta variables are holes.
  -- Their type is unrelated to the other ones in the term,
  -- allowing to construct heterogeneous terms.
  deriving (Eq, Ord, Functor, Show, Data, Typeable, Foldable, Traversable)

varMapMetaM :: (Monad m) => (meta -> m meta') -> VarMeta meta ann f -> m (VarMeta meta' ann f)
varMapMetaM f (Meta x) = Meta <$> f x
varMapMetaM _ (Bound ann0 i) = return $ Bound ann0 i
varMapMetaM _ (Free x) = return $ Free x

varMapMeta :: (meta -> meta') -> VarMeta meta ann f -> VarMeta meta' ann f
varMapMeta f = runIdentity . varMapMetaM (return . f)

-- | Simple variables can't be metavariables. If we want to implement
--  things like unification algorithms, though, having meta variables
--  becomes interesting.
type Var = VarMeta Void

-- | A 'VarMeta' carries the necessary structure for bound variable substitution.
--  Check "Pirouette.Term.Syntax.Subst" for more on this.
instance IsVar (VarMeta meta ann f) where
  type VarAnn (VarMeta meta ann f) = ann

  isBound (Bound _ i) = Just i
  isBound _ = Nothing

  varMapM f (Bound ann0 i) = Bound ann0 <$> f i
  varMapM _ v = return v

  annMap f (Bound (Ann a) i) = Bound (Ann (f a)) i
  annMap _ v = v

-- ** Kinds

data Kind = KStar | KTo Kind Kind
  deriving (Eq, Ord, Show, Data, Typeable)

-- | Drop the n first arguments of a kind:
--
-- > kindDrop 1 (* -> (* -> *) -> * -> *) == (* -> *) -> * -> *
-- > kindDrop 2 (* -> (* -> *) -> * -> *) == * -> *
-- > kindDrop 3 (* -> (* -> *) -> * -> *) == *
kindDrop :: Int -> Kind -> Kind
kindDrop 0 k = k
kindDrop n (KTo _ k) = kindDrop (n - 1) k
kindDrop _ _ = error "kindDrop: KStar has no arguments to drop"

-- ** Types

data AnnType ann tyVar
  = TyApp tyVar [AnnType ann tyVar]
  | TyFun (AnnType ann tyVar) (AnnType ann tyVar)
  | TyLam (Ann ann) Kind (AnnType ann tyVar)
  | TyAll (Ann ann) Kind (AnnType ann tyVar)
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable, Data, Typeable)

tyBimapM ::
  (Monad m) =>
  (ann -> m ann') ->
  (tyVar -> m tyVar') ->
  AnnType ann tyVar ->
  m (AnnType ann' tyVar')
tyBimapM f g (TyApp n args) = TyApp <$> g n <*> mapM (tyBimapM f g) args
tyBimapM f g (TyFun t u) = TyFun <$> tyBimapM f g t <*> tyBimapM f g u
tyBimapM f g (TyLam a k u) = TyLam <$> mapM f a <*> return k <*> tyBimapM f g u
tyBimapM f g (TyAll a k u) = TyAll <$> mapM f a <*> return k <*> tyBimapM f g u

tyFunArgs :: AnnType ann tyVar -> ([AnnType ann tyVar], AnnType ann tyVar)
tyFunArgs (TyFun u t) = first (u :) $ tyFunArgs t
tyFunArgs t = ([], t)

tyUnwrapBinders :: Int -> AnnType ann tyVar -> ([(Ann ann, Kind)], AnnType ann tyVar)
tyUnwrapBinders n ty
  | n <= 0 = ([], ty)
  | otherwise = case ty of
      TyLam a k rest -> first ((a, k) :) $ tyUnwrapBinders (n - 1) rest
      TyAll a k rest -> first ((a, k) :) $ tyUnwrapBinders (n - 1) rest
      _ -> ([], ty)

-- | Given a @t : AnnType ann ty@, returns how many arguments would we
--  have to provide a @AnnTerm@ of type @t@ to fully saturate it. This includes
--  type arguments!
tyArity :: AnnType ann tyVar -> Int
tyArity (TyAll _ _ t) = 1 + tyArity t
tyArity t = tyMonoArity t

-- | Unlike 'tyArity', we only compute how many type arguments a type can receive
tyPolyArity :: AnnType ann tyVar -> Int
tyPolyArity (TyAll _ _ t) = 1 + tyPolyArity t
tyPolyArity _ = 0

-- | Unlike 'tyArity', we only compute how many term arguments a term of
--  the given type has to receive
tyMonoArity :: AnnType ann tyVar -> Int
tyMonoArity = length . fst . tyFunArgs

-- | Returns whether a type has higher-order functions. We say a type has
-- HO functions iff it has a function to the left of an arrow, anywhere. This
-- can occur directly or indirectly, for instance, the type:
--
-- > Integer -> Maybe (Bool -> Bool) -> X
--
-- Has higher-order functions present nested in 'Maybe'. This current function
-- could be much better given it will also return some false-positives. For instance,
--
-- > Integer -> Const Bool (Bool -> Bool) -> X
--
-- Doesn't really have higher order functions because @Const a b = a@, but we
-- are not worrying about that now, that would require lifting this function to
-- a context that is aware of type definitions.
tyHasHOFuns :: AnnType ann ty -> Bool
-- First case, the obvious HO type: (_ -> _) -> _ ...
tyHasHOFuns (TyFun TyFun {} _) = True
-- Now, if we have somthing other than another arrow to the left of
-- a tyFun, it can still be something like: Maybe (a -> a)
tyHasHOFuns (TyFun a b) = tyHasHOFuns a || tyHasHOFuns b
tyHasHOFuns (TyApp _ args) = tyHasFuns `any` args
tyHasHOFuns (TyLam _ _ at) = tyHasHOFuns at
tyHasHOFuns (TyAll _ _ at) = tyHasHOFuns at

-- | Returns whether this type has arrows anywhere.
tyHasFuns :: AnnType ann ty -> Bool
tyHasFuns (TyFun _ _) = True
tyHasFuns (TyApp _ args) = tyHasFuns `any` args
tyHasFuns (TyLam _ _ at) = tyHasFuns at
tyHasFuns (TyAll _ _ at) = tyHasFuns at

pattern TyPure :: tyVar -> AnnType ann tyVar
pattern TyPure v = TyApp v []

instance (IsVar tyVar) => HasSubst (AnnType ann tyVar) where
  type SubstVar (AnnType ann tyVar) = tyVar
  var = TyPure

  subst s (TyApp n xs) = appN (applySub s n) $ map (subst s) xs
  subst s (TyFun t u) = TyFun (subst s t) (subst s u)
  subst s (TyLam v k t) = TyLam v k (subst (liftSub s) t)
  subst s (TyAll v k t) = TyAll v k (subst (liftSub s) t)

-- | Type-level application (not to be confused with type _instantiation_, 'tyInstantiate').
tyApp :: (IsVar v) => AnnType ann v -> AnnType ann v -> AnnType ann v
tyApp (TyApp n args) u = TyApp n (args ++ [u])
tyApp (TyLam _ _ t) u = subst (singleSub u) t
tyApp TyAll {} _ = error "Can't apply TyAll: did you mean tyInstantiate?"
tyApp TyFun {} _ = error "Can't apply TyFun"

-- | Instantiates a universally quantified type. This is /different/ from type application.
--  Only works if the left argument is a 'TyAll'.
tyInstantiate :: (IsVar v) => AnnType ann v -> AnnType ann v -> AnnType ann v
tyInstantiate (TyAll _ _ t) u = subst (singleSub u) t
tyInstantiate TyApp {} _ = error "Can't instantiate TyApp"
tyInstantiate TyLam {} _ = error "Can't instantiate TyLam: did you mean tyApp?"
tyInstantiate TyFun {} _ = error "Can't instantiate TyFun"

-- | Instantiates a number of 'TyAll's at once.
tyInstantiateN :: (IsVar v) => AnnType ann v -> [AnnType ann v] -> AnnType ann v
tyInstantiateN = foldl' tyInstantiate

-- TODO: write an efficient appN that substitutes multiple variables in one go
instance (IsVar tyVar) => HasApp (AnnType ann tyVar) where
  type AppArg (AnnType ann tyVar) = AnnType ann tyVar
  appN = foldl' tyApp

-- ** Terms

-- | Named de Bruijn System-F terms in normal form with types annotations.
--  The de Bruijn indices for term and type variables are strongly separated.
--  So both the first `Lam` and the first `Abs` introduce a variable with index 0.
--  The @ann@ variable represents the type of
--  names we're using for explicit variable names. It's important to do so
--  to preserve user-given names throughout the transformations.
data AnnTerm ty ann v
  = App v [Arg ty (AnnTerm ty ann v)]
  | Lam (Ann ann) ty (AnnTerm ty ann v) -- Term level lambda (abstract over term to construct term).
  -- It is the one usually denoted λ.
  | Abs (Ann ann) Kind (AnnTerm ty ann v) -- Term level type lambda (abstract over type to construct term).
  -- It is the one usually denoted Λ.
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable, Data, Typeable)

termTyFoldMap :: (Monoid m) => (ty -> m) -> AnnTerm ty ann v -> m
termTyFoldMap f (App _ args) = mconcat $ mapMaybe (fmap f . fromTyArg) args
termTyFoldMap f (Lam _ ty u) = f ty <> termTyFoldMap f u
termTyFoldMap f (Abs _ _ u) = termTyFoldMap f u

-- Gathers all the variable names.
-- Both the term and the type ones.
-- But do not consider the ones introduces by a type level abstraction.
termAnnFold :: (Monoid m) => (ann -> m) -> AnnTerm ty ann v -> m
termAnnFold f (App _ args) = mconcat $ mapMaybe (fmap (termAnnFold f) . fromArg) args
termAnnFold f (Lam (Ann x) _ u) = f x <> termAnnFold f u
termAnnFold f (Abs (Ann x) _ _) = f x

termTrimapM ::
  (Monad m) =>
  (ty -> m ty') ->
  (ann -> m ann') ->
  (v -> m v') ->
  AnnTerm ty ann v ->
  m (AnnTerm ty' ann' v')
termTrimapM f g h (App n args) = App <$> h n <*> mapM (argMapM f (termTrimapM f g h)) args
termTrimapM f g h (Lam a ty u) = Lam <$> mapM g a <*> f ty <*> termTrimapM f g h u
termTrimapM f g h (Abs a k u) = Abs <$> mapM g a <*> return k <*> termTrimapM f g h u

termTrimap ::
  (ty -> ty') ->
  (ann -> ann') ->
  (v -> v') ->
  AnnTerm ty ann v ->
  AnnTerm ty' ann' v'
termTrimap f g h = runIdentity . termTrimapM (return . f) (return . g) (return . h)

termTyMapM :: (Monad m) => (ty -> m ty') -> AnnTerm ty ann v -> m (AnnTerm ty' ann v)
termTyMapM f = termTrimapM f return return

termTyMap :: (ty -> ty') -> AnnTerm ty ann v -> AnnTerm ty' ann v
termTyMap f = runIdentity . termTyMapM (return . f)

termPure :: v -> AnnTerm ty ann v
termPure = flip App []

-- | Applies a transformation to the fist application or abstraction over a type we find while
--  descending down a chain of lambda abstractions. The abstractions
--  are preserved.
preserveLamsM ::
  (Monad m) =>
  (Integer -> AnnTerm ty ann v -> m (AnnTerm ty ann v)) ->
  AnnTerm ty ann v ->
  m (AnnTerm ty ann v)
preserveLamsM f (Lam ann0 ty t) = Lam ann0 ty <$> preserveLamsM (\n -> f (n + 1)) t
preserveLamsM f t = f 0 t

preserveLams ::
  (Integer -> AnnTerm ty ann v -> AnnTerm ty ann v) ->
  AnnTerm ty ann v ->
  AnnTerm ty ann v
preserveLams f = runIdentity . preserveLamsM (\i -> return . f i)

getHeadAbs :: AnnTerm ty ann v -> ([(ann, Kind)], AnnTerm ty ann v)
getHeadAbs (Abs (Ann v) k t) = first ((v, k) :) $ getHeadAbs t
getHeadAbs t = ([], t)

getNHeadAbs :: Int -> AnnTerm ty ann v -> ([(ann, Kind)], AnnTerm ty ann v)
getNHeadAbs 0 t = ([], t)
getNHeadAbs n (Abs (Ann v) k t) = first ((v, k) :) $ getNHeadAbs (n - 1) t
getNHeadAbs _ _ = error "getNHeadAbs: Not enough type-abstractions"

getHeadLams :: AnnTerm ty ann v -> ([(ann, ty)], AnnTerm ty ann v)
getHeadLams (Lam (Ann v) ty t) = first ((v, ty) :) $ getHeadLams t
getHeadLams t = ([], t)

getNHeadLams :: Int -> AnnTerm ty ann v -> ([(ann, ty)], AnnTerm ty ann v)
getNHeadLams 0 t = ([], t)
getNHeadLams n (Lam (Ann v) ty t) = first ((v, ty) :) $ getNHeadLams (n - 1) t
getNHeadLams _ _ = error "getNHeadLams: Not enough lambdas"

withLams :: [(ann, ty)] -> AnnTerm ty ann v -> AnnTerm ty ann v
withLams = foldr (\bv t -> uncurry Lam (first Ann bv) . t) id

data Arg ty v
  = TyArg ty
  | TermArg v
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable, Data, Typeable)

argElim :: (ty -> a) -> (v -> a) -> Arg ty v -> a
argElim _ g (TermArg x) = g x
argElim f _ (TyArg x) = f x

fromArg :: Arg ty v -> Maybe v
fromArg = argElim (const Nothing) Just

fromTyArg :: Arg ty v -> Maybe ty
fromTyArg = argElim Just (const Nothing)

isArg :: Arg ty v -> Bool
isArg = argElim (const False) (const True)

isTyArg :: Arg ty v -> Bool
isTyArg = argElim (const True) (const False)

argMapM :: (Monad m) => (ty -> m ty') -> (v -> m v') -> Arg ty v -> m (Arg ty' v')
argMapM f _ (TyArg x) = TyArg <$> f x
argMapM _ g (TermArg x) = TermArg <$> g x

argMap :: (ty -> ty') -> (v -> v') -> Arg ty v -> Arg ty' v'
argMap f g = runIdentity . argMapM (return . f) (return . g)

firstTyArg :: [Arg ty v] -> Maybe (Arg ty v, [Arg ty v])
firstTyArg [] = Nothing
firstTyArg (ty@TyArg {} : rest) = Just (ty, rest)
firstTyArg (other : rest) = do
  (ty, args) <- firstTyArg rest
  pure (ty, other : args)

firstTermArg :: [Arg ty v] -> Maybe (Arg ty v, [Arg ty v])
firstTermArg [] = Nothing
firstTermArg (ty@TermArg {} : rest) = Just (ty, rest)
firstTermArg (other : rest) = do
  (ty, args) <- firstTermArg rest
  pure (ty, other : args)

-- | Splits the first @n@ type arguments into a separate list, for example:
-- > splitArgs 2 [Arg a, TyArg A, TyArg B, Arg b, TyArg C]
-- >  == ([A, B], [Arg a, Arg b, TyArg C])
splitArgs :: Int -> [Arg ty v] -> ([ty], [Arg ty v])
splitArgs 0 args = ([], args)
splitArgs n (TyArg tyArg : args) = first (tyArg :) $ splitArgs (n - 1) args
splitArgs n (arg : args) = second (arg :) $ splitArgs n args
splitArgs _ [] = error "Less args than poly args count"

instance (Show v, Show ty, Show ann, HasSubst ty, IsVar v) => HasSubst (AnnTerm ty ann v) where
  type SubstVar (AnnTerm ty ann v) = v
  var = termPure

  subst s (App n xs) = appN (applySub s n) $ map (argMap id (subst s)) xs
  subst s (Lam v k t) = Lam v k (subst (liftSub s) t)
  subst s (Abs v k t) = Abs v k (subst s t) -- Here the substitution is not lifted,
  -- since de Bruijn indices for term and type variables do not live in the same world.

substTy ::
  (HasSubst ty) =>
  Sub ty ->
  AnnTerm ty ann v ->
  AnnTerm ty ann v
substTy s (App n args) = App n (map (argMap (subst s) (substTy s)) args)
substTy s (Lam v ty body) = Lam v (subst s ty) (substTy s body)
substTy s (Abs v kd body) = Abs v kd (substTy (liftSub s) body)

termApp ::
  (Show v, Show ty, Show ann, HasSubst ty, IsVar v) =>
  AnnTerm ty ann v ->
  Arg ty (AnnTerm ty ann v) ->
  AnnTerm ty ann v
termApp (App n args) u = App n (args ++ [u])
termApp (Lam _ _ t) (TermArg u) = subst (singleSub u) t
termApp (Abs _ _ t) (TyArg u) = substTy (singleSub u) t
termApp _ _ = error "Mismatched Term/Type application"

-- | Expands a single definition within another term.
--
--  WARNING: Although we're using De Bruijn indices, some code generation targets
--  such as TLA+ are very unhappy about name shadowing, so you might want to map
--  over the result and deshadow bound names.
expandVar ::
  (Show v, Show ty, Show ann, HasSubst ty, Eq v, IsVar v, Data ty, Data ann, Data v) =>
  (v, AnnTerm ty ann v) ->
  AnnTerm ty ann v ->
  AnnTerm ty ann v
expandVar (n, defn) = transform go
  where
    go t@(App v args)
      | n /= v = t
      | otherwise = appN defn args
    go t = t

instance (Show v, Show ty, Show ann, IsVar v, HasSubst ty) => HasApp (AnnTerm ty ann v) where
  type AppArg (AnnTerm ty ann v) = Arg ty (AnnTerm ty ann v)

  -- Single pass substitution;
  -- This function does not work for "hetereogeneous" list of arguments.
  -- All the arguments must be either terms or types.
  appN tm [] = tm
  appN (App n args) us = App n (args ++ us)
  appN tm us@(u : _) =
    case (tm, u) of
      (Lam {}, TermArg _) -> goTerm tm us
      (Abs {}, TyArg _) -> goType tm us
      (_, _) -> error $ "Mismatched Term/Type application " <> show tm <> " and " <> show u
    where
      go getHead getNHead from sub t vs =
        -- first we decide whether we have more lambdas or more arguments;
        let (arity, _) = first length $ getHead t
            n = min arity (length vs)
            -- Now we know we'll be applying n arguments at once.
            (_, body) = getNHead n t
            (args, excess) = splitAt n vs
            sigma = foldl' (\x y -> Just y :< x) (Inc 0)
         in case mapM from args of
              Just as -> appN (sub (sigma as) body) excess
              Nothing -> error "Mismatched Term/Type application"

      goTerm = go getHeadLams getNHeadLams fromArg subst
      goType = go getHeadAbs getNHeadAbs fromTyArg substTy

-- | Maps a function over names, keeping track of the scope by counting
--  how many lambdas have we traversed
mapNameScoped :: (Integer -> v -> v) -> AnnTerm ty ann v -> AnnTerm ty ann v
mapNameScoped f = go 0
  where
    go c (Abs t k body) = Abs t k (go c body)
    go c (Lam v t body) = Lam v t $ go (c + 1) body
    go c (App n args) = App (f c n) $ map (argMap id (go c)) args

-- * Auxiliary Defs

-- ** N-ary Reducing Applications

class (HasSubst term) => HasApp term where
  type AppArg term :: *
  appN :: (IsVar (SubstVar term), HasCallStack) => term -> [AppArg term] -> term

app :: (HasApp term, HasCallStack) => term -> AppArg term -> term
app t arg = appN t [arg]

-- ** Proof-Irrelevant Annotations

newtype Ann x = Ann {ann :: x}
  deriving (Show, Data, Typeable, Functor, Foldable, Traversable)

instance Eq (Ann x) where
  _ == _ = True

instance Ord (Ann x) where
  compare _ _ = EQ

instance IsString x => IsString (Ann x) where
  fromString = Ann . fromString

-- These must go at the end because of Template Haskell restrictions
makePrisms ''VarMeta
makePrisms ''AnnType
makePrisms ''AnnTerm
makePrisms ''Arg
