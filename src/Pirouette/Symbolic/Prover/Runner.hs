{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Pirouette.Symbolic.Prover.Runner where

import Control.Monad.Identity
import Control.Monad.Reader
import Data.Default
import qualified Data.Map as M
import Pirouette.Monad
import Pirouette.Symbolic.Eval
import Pirouette.Symbolic.Prover
import Pirouette.Term.Syntax (pretty)
import Pirouette.Term.Syntax.Base
import Pirouette.Transformations
import System.Console.ANSI
import qualified Test.Tasty.HUnit as Test

data AssumeProve lang = Term lang :==>: Term lang
  deriving (Eq, Show)

-- | Parameters for an incorrectness logic run
data IncorrectnessParams lang = IncorrectnessParams
  { ipTarget :: Term lang,
    ipTargetType :: Type lang,
    ipCondition :: AssumeProve lang
  }

-- | The result type of 'runIncorrectnessLogic', returning the first (if any)
--  path that is a counterexample to the supplied 'IncorrectnessParams'.
--  If you would like finer grained control, look at 'execIncorrectnessLogic'.
type IncorrectnessResult lang = Maybe (Path lang (EvaluationWitness lang))

-- | Runs an incorrectness logic check for a single term, i.e., receives no
-- environment of definitions.
runIncorrectnessLogicSingl ::
  (Language lang, LanguageBuiltinTypes lang, LanguageSymEval lang) =>
  Options ->
  IncorrectnessParams lang ->
  IncorrectnessResult lang
runIncorrectnessLogicSingl opts =
  runIncorrectnessLogic opts (PrtUnorderedDefs M.empty)

runIncorrectnessLogic ::
  (Language lang, LanguageBuiltinTypes lang, LanguageSymEval lang) =>
  Options ->
  PrtUnorderedDefs lang ->
  IncorrectnessParams lang ->
  IncorrectnessResult lang
runIncorrectnessLogic opts prog parms =
  runIdentity $ execIncorrectnessLogic (proveAny opts isCounter) prog parms
  where
    isCounter Path {pathResult = CounterExample _ _, pathStatus = s}
      | s /= OutOfFuel = True
    isCounter _ = False

-- | Prepares a 'IncorrectnessParams' into a 'Problem', to be passed to
--  some worker function. Chances are that you are looking for
--  'runIncorrectnessLogic' instead, unless you want a specific analysis.
--  If that's not the case, the arguments to worker that you want will
--  likely be 'prove', 'proveUnbounded' or 'proveAny' from "Pirouette.Symbolic.Prove"
execIncorrectnessLogic ::
  (Language lang, LanguageBuiltinTypes lang, Monad m) =>
  -- | Worker to run on the processed definitions
  (Problem lang -> ReaderT (PrtOrderedDefs lang) m res) ->
  PrtUnorderedDefs lang ->
  IncorrectnessParams lang ->
  m res
execIncorrectnessLogic toDo prog (IncorrectnessParams fn ty (assume :==>: toProve)) = do
  -- First, we apply a series of transformations to our program that will enable
  -- us to translate it to SMTLIB later on
  let orderedDecls =
        elimEvenOddMutRec
          . defunctionalize
          . monomorphize
          $ prog
  -- Now we can contextualize the necessary terms and run the worker
  flip runReaderT orderedDecls $ do
    ty' <- contextualizeType ty
    fn' <- contextualizeTerm fn
    assume' <- contextualizeTerm assume
    toProve' <- contextualizeTerm toProve
    toDo (Problem ty' fn' assume' toProve')

printIRResult ::
  Int ->
  IncorrectnessResult lang ->
  IO ()
printIRResult _ (Just Path {pathResult = CounterExample _ model}) = do
  setSGR [SetColor Foreground Vivid Yellow]
  putStrLn "💸 COUNTEREXAMPLE FOUND"
  setSGR [Reset]
  print $ pretty model
printIRResult steps _ = do
  setSGR [SetColor Foreground Vivid Green]
  putStrLn $ "✔️ NO COUNTEREXAMPLES FOUND AFTER " <> show steps <> " STEPS"
  setSGR [Reset]

assertIRResult :: IncorrectnessResult lang -> Test.Assertion
assertIRResult (Just Path {pathResult = CounterExample _ _}) =
  Test.assertFailure "Counterexample found"
assertIRResult _ = return ()

-- | Check for counterexamples for an incorrectness logic triple and
-- pretty-print the result
replIncorrectnessLogic ::
  (Language lang, LanguageBuiltinTypes lang, LanguageSymEval lang) =>
  Int ->
  PrtUnorderedDefs lang ->
  IncorrectnessParams lang ->
  IO ()
replIncorrectnessLogic maxCstrs defs params =
  printIRResult maxCstrs $
    runIncorrectnessLogic (def {shouldStop = (> maxCstrs) . sestConstructors}) defs params

replIncorrectnessLogicSingl ::
  (Language lang, LanguageBuiltinTypes lang, LanguageSymEval lang) =>
  Int ->
  IncorrectnessParams lang ->
  IO ()
replIncorrectnessLogicSingl maxCstrs params =
  printIRResult maxCstrs $
    runIncorrectnessLogicSingl (def {shouldStop = (> maxCstrs) . sestConstructors}) params

-- | Assert a test failure (Tasty HUnit integration) when the result of the
-- incorrectness logic execution reveals an error or a counterexample.
assertIncorrectnessLogic ::
  (Language lang, LanguageBuiltinTypes lang, LanguageSymEval lang) =>
  Int ->
  PrtUnorderedDefs lang ->
  IncorrectnessParams lang ->
  Test.Assertion
assertIncorrectnessLogic maxCstrs defs params =
  assertIRResult (runIncorrectnessLogic (def {shouldStop = (> maxCstrs) . sestConstructors}) defs params)
