{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Pirouette.SMT.Constraints where

import Data.Void
import qualified Data.List as List (filter)
import Pirouette.SMT.Common
import Pirouette.SMT.Datatypes
import qualified Pirouette.SMT.SimpleSMT as SmtLib
import Pirouette.Term.Syntax
import Pirouette.Term.Syntax.Base
import Pirouette.Term.Syntax.SystemF
import qualified PlutusCore as P
import Data.Map (Map)
import qualified Data.Map as Map
import Debug.Trace
import Data.Bifunctor (bimap)

-- | Bindings from names to types (for the assign constraints)
type Env = Map Name PrtType

-- | Constraints of a path during symbolic execution
-- We would like to have
-- type Constraint = Bot | And (Map Name [PrtTerm]) [(PrtTerm, PrtTerm)]
-- It is isomorphic to our current type, but with better access time to the variable assignements.
data Constraint
  = Assign Name PrtTerm
  | OutOfFuelEq PrtTerm PrtTerm
  | And [Constraint]
  | Bot

-- | Declare constants and assertions in an SMT solver based on a constraint
-- that characterizes a path in the symbolic execution of a Plutus IR term.
--
-- We cannot just generate SExpr for smtlib (instantiating the Translatable
-- class) because of Assign constraints which need to declare names as a side
-- effect and And constraints which need to run these declarations in the right
-- order.
--
-- There is an issue for now when generating assertions such as:
-- x : Bool
-- x = Nil
-- because Nil has type List a. Nil must be applied to Bool.
--
-- There are two ways to sort things out:
--
-- 1. Use SMTlib's "match" term 
-- e.g. assert ((match x ((Nil true) ((Cons y ys) false))))
--
-- 2. Use the weird "as" SMTLib term
-- assert (= x (as Nil (List Bool)))
-- The weird thing is that Cons should be "cast"/"applied"/"coerced" (which is
-- right?) to List Bool as well although it is a constructor of arity > 0
-- The "as" term seems to mean "here *** is a constructor of that concrete
-- type", but it is not type application
--
-- 3. Use the, weird as well, "_ is" template/function/whatever
-- (assert ((_ is Nil) x))
-- In our case, it seems to be a shortcut that is equivalent to #1
--
-- All these solutions lead to the same sat result and examples
assertConstraint :: SmtLib.Solver -> Env -> Constraint -> IO ()
assertConstraint s env (Assign name term) =
  do
    let smtName = toSmtName name
    let (Just ty) = Map.lookup name env
    SmtLib.assert s (SmtLib.symbol smtName `SmtLib.eq` translateData ty term)
assertConstraint s _ (OutOfFuelEq term1 term2) =
  SmtLib.assert s (translate term1 `SmtLib.eq` translate term2)
assertConstraint s env (And constraints) =
  sequence_ (assertConstraint s env <$> constraints)
assertConstraint s _ Bot = SmtLib.assert s (SmtLib.bool False)

declareVariables :: SmtLib.Solver -> Env -> IO ()
declareVariables s env =
  sequence_ (uncurry (SmtLib.declare s) . bimap toSmtName translate <$> Map.toList env)

translateData :: PrtType -> PrtTerm -> SmtLib.SExpr
translateData ty (App var@(B (Ann name) _) []) = translate var
translateData ty (App (F (FreeName name)) args) =
  SmtLib.app
    (SmtLib.as (SmtLib.symbol (toSmtName name)) (translate ty))
    (translate <$> List.filter isNotType args)
    where
      isNotType :: Arg PrtType PrtTerm -> Bool
      isNotType (TyArg _) = False
      isNotType _ = True
translateData ty _ = error "Illegal term in translate data"

instance Translatable (AnnTerm (AnnType Name (Var Name (TypeBase Name))) Name (Var Name (PIRBase P.DefaultFun Name))) where
  translate (App var args) = SmtLib.app (translate var) (translate <$> args)
  translate (Lam ann ty term) = error "Translate term to smtlib: Lambda abstraction in term"
  translate (Abs ann kind term) = error "Translate term to smtlib: Type abstraction in term"
  translate (Hole h) = error "Translate term to smtlib: Hole"

instance Translatable (Var Name (PIRBase P.DefaultFun Name)) where
  translate (B (Ann name) _) = SmtLib.symbol (toSmtName name)
  translate (F (FreeName name)) = SmtLib.symbol (toSmtName name)
  translate (F _) = error "todo"

instance
  Translatable
    ( Arg
        (AnnType Name (Var Name (TypeBase Name)))
        ( AnnTermH
            Void
            (AnnType Name (Var Name (TypeBase Name)))
            Name
            (Var Name (PIRBase P.DefaultFun Name))
        )
    )
  where
  translate (TyArg ty) = translate ty
  translate (Arg term) = translate term
