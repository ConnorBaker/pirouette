import qualified Language.Pirouette.ExampleSpec as Ex
import qualified Language.Pirouette.PlutusIR.ToTermSpec as FP
import qualified Pirouette.Term.Syntax.SystemFSpec as SF
import qualified Pirouette.Term.TransformationsSpec as Tr
import qualified Pirouette.Transformations.EtaExpandSpec as Eta
import Test.Tasty

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Pirouette"
    [ testGroup "SystemF" SF.tests,
      testGroup
        "Transformations"
        [testGroup "EtaExpand" Eta.tests],
      testGroup "Term" [testGroup "Transformations" Tr.tests],
      testGroup
        "Language"
        [ testGroup "PlutusIR" FP.tests,
          testGroup "Example" Ex.tests
        ]
    ]
