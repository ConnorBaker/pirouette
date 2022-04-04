{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}

-- | This is Pirouette's SMT solver interface; you probably won't need to import
--  anything under the @SMT/@ folder explicitely unless you're trying to do some
--  very specific things or declaring a language. In which case, you probably
--  want only "Pirouette.SMT.Base" and "Pirouette.SMT.SimpleSMT" to bring get the necessary
--  classes and definitions in scope. Check "Language.Pirouette.PlutusIR.SMT" for an example.
module Pirouette.SMT
  ( SolverT (..),
    checkSat,
    runSolverT,
    solverPush,
    solverPop,
    declareDatatype,
    declareDatatypes,
    declareVariables,
    declareVariable,
    assert,
    assertNot,

    -- * Convenient re-exports
    Constraint (..),
    AtomicConstraint (..),
    SimpleSMT.Result (..),
    module Base,
  )
where

import Control.Applicative
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State.Class
import qualified Data.Map as M
import Data.Maybe (mapMaybe)
import Pirouette.SMT.Base as Base
import Pirouette.SMT.Constraints
import qualified Pirouette.SMT.SimpleSMT as SimpleSMT
import Pirouette.SMT.Translation
import Pirouette.Term.Syntax
import qualified Pirouette.Term.Syntax.SystemF as R

-- | Solver monad for a specific solver, passed as a phantom type variable @s@ (refer to 'IsSolver' for more)
--  to know the supported solvers. That's a phantom type variable used only to distinguish
--  solver-specific operations, such as initialization
newtype SolverT m a = SolverT {unSolverT :: ReaderT SimpleSMT.Solver m a}
  deriving (Functor)
  deriving newtype (Applicative, Monad, MonadReader SimpleSMT.Solver, MonadIO)

instance MonadTrans SolverT where
  lift = SolverT . lift

deriving instance MonadState s m => MonadState s (SolverT m)

deriving instance MonadError e m => MonadError e (SolverT m)

deriving instance Alternative m => Alternative (SolverT m)

-- | Runs a computation that requires a session with a solver. The first parameter is
-- an action that launches a solver. Check 'cvc4_ALL_SUPPORTED' for an example.
runSolverT :: forall m a. (MonadIO m) => IO SimpleSMT.Solver -> SolverT m a -> m a
runSolverT s (SolverT comp) = liftIO s >>= runReaderT comp

-- | Returns 'Sat', 'Unsat' or 'Unknown' for the current solver session.
checkSat :: (MonadIO m) => SolverT m SimpleSMT.Result
checkSat = do
  solver <- ask
  liftIO $ SimpleSMT.check solver

-- | Pushes the solver context, creating a checkpoint. This is useful if you plan to execute
--  many queries that share definitions. A typical use pattern would be:
--
--  > declareDatatypes ...
--  > forM_ varsAndExpr $ \(vars, expr) -> do
--  >   solverPush
--  >   declareVariables vars
--  >   assert expr
--  >   r <- checkSat
--  >   solverPop
--  >   return r
solverPush :: (MonadIO m) => SolverT m ()
solverPush = do
  solver <- ask
  liftIO $ SimpleSMT.push solver

-- | Pops the current checkpoint, check 'solverPush' for an example.
solverPop :: (MonadIO m) => SolverT m ()
solverPop = do
  solver <- ask
  liftIO $ SimpleSMT.pop solver

-- | Declare a single datatype in the current solver session.
declareDatatype :: (LanguageSMT lang, MonadIO m) => Name -> TypeDef lang -> ExceptT String (SolverT m) [Name]
declareDatatype typeName (Datatype _ typeVariabes _ cstrs) = do
  solver <- ask
  constr' <- mapM constructorFromPIR cstrs
  liftIO $ do
    SimpleSMT.declareDatatype
      solver
      (toSmtName typeName)
      (map (toSmtName . fst) typeVariabes)
      constr'
  return $ typeName : map fst cstrs

-- | Declare a set of datatypes in the current solver session, in the order specified by
-- the dependency order passed as the second argument. You can generally get its value
-- from a 'PirouetteDepOrder' monad.
declareDatatypes ::
  (LanguageSMT lang, MonadIO m) => M.Map Name (Definition lang) -> [R.Arg Name Name] -> ExceptT String (SolverT m) [Name]
declareDatatypes decls orderedNames = do
  let tyNames = mapMaybe (R.argElim Just (const Nothing)) orderedNames
  usedNames <- forM tyNames $ \tyname ->
    case M.lookup tyname decls of
      Just (DTypeDef tdef) -> declareDatatype tyname tdef
      _ -> return []
  return $ concat usedNames

-- | Declare (name and type) all the variables of the environment in the SMT
-- solver. This step is required before asserting constraints mentioning any of these variables.
declareVariables :: (LanguageSMT lang, MonadIO m) => M.Map Name (Type lang) -> ExceptT String (SolverT m) ()
declareVariables = mapM_ (uncurry declareVariable) . M.toList

-- | Declares a single variable in the current solver session.
declareVariable :: (LanguageSMT lang, MonadIO m) => Name -> Type lang -> ExceptT String (SolverT m) ()
declareVariable varName varTy = do
  solver <- ask
  tySExpr <- translateType varTy
  liftIO $ void (SimpleSMT.declare solver (toSmtName varName) tySExpr)

-- | Asserts a constraint; check 'Constraint' for more information
-- | The functions 'assert' and 'assertNot' output a boolean,
-- stating if the constraint was fully passed to the SMT solver,
-- or if a part was lost during the translation process.
assert ::
  (LanguageSMT lang, ToSMT meta, MonadIO m) =>
  M.Map Name (Type lang) ->
  [Name] ->
  Constraint lang meta ->
  SolverT m Bool
assert env knownNames c =
  SolverT $ ReaderT $ \solver -> do
    (isTotal,expr) <- constraintToSExpr env knownNames c
    liftIO $ SimpleSMT.assert solver expr
    return isTotal

assertNot ::
  (LanguageSMT lang, ToSMT meta, MonadIO m) =>
  M.Map Name (Type lang) ->
  [Name] ->
  Constraint lang meta ->
  SolverT m Bool
assertNot env knownNames c =
  SolverT $ ReaderT $ \solver -> do
    (isTotal, expr) <- constraintToSExpr env knownNames c
    liftIO $ SimpleSMT.assert solver (SimpleSMT.not expr)
    return isTotal
