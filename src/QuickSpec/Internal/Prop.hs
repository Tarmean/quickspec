{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE DeriveGeneric, TypeFamilies, DeriveFunctor, FlexibleInstances, MultiParamTypeClasses, UndecidableInstances, FlexibleContexts, TypeOperators #-}
module QuickSpec.Internal.Prop where

import Control.Monad
import qualified Data.DList as DList
import Data.Ord
import QuickSpec.Internal.Type
import QuickSpec.Internal.Utils
import QuickSpec.Internal.Term
import GHC.Generics(Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Control.Monad.Trans.State.Strict
import Data.List

data Prop a =
  (:=>:) {
    lhs :: [Equation a],
    rhs :: Equation a }
  deriving (Show, Generic, Functor)

instance Symbolic f a => Symbolic f (Prop a) where
  termsDL (lhs :=>: rhs) =
    termsDL rhs `mplus` termsDL lhs
  subst sub (lhs :=>: rhs) =
    subst sub lhs :=>: subst sub rhs

instance Ord a => Eq (Prop a) where
  x == y = x `compare` y == EQ
instance Ord a => Ord (Prop a) where
  compare = comparing (\p -> (usort (lhs p), rhs p))

infix 4 :=>:

literals :: Prop a -> [Equation a]
literals p = rhs p:lhs p

unitProp :: Equation a -> Prop a
unitProp p = [] :=>: p

mapFun :: (fun1 -> fun2) -> Prop (Term fun1) -> Prop (Term fun2)
mapFun f = fmap (fmap f)

instance Typed a => Typed (Prop a) where
  typ _ = typeOf True
  otherTypesDL p = DList.fromList (literals p) >>= typesDL
  typeSubst_ sub (lhs :=>: rhs) =
    map (typeSubst_ sub) lhs :=>: typeSubst_ sub rhs

instance Pretty a => Pretty (Prop a) where
  pPrint ([] :=>: rhs) = pPrint rhs
  pPrint p =
    hsep (punctuate (text " &") (map pPrint (lhs p))) <+> text "=>" <+> pPrint (rhs p)

data Equation a = a :=: a deriving (Show, Eq, Ord, Generic, Functor)

instance Symbolic f a => Symbolic f (Equation a) where
  termsDL (t :=: u) = termsDL t `mplus` termsDL u
  subst sub (t :=: u) = subst sub t :=: subst sub u

infix 5 :=:

instance Typed a => Typed (Equation a) where
  typ (t :=: _) = typ t
  otherTypesDL (t :=: u) = otherTypesDL t `mplus` typesDL u
  typeSubst_ sub (x :=: y) = typeSubst_ sub x :=: typeSubst_ sub y

instance Pretty a => Pretty (Equation a) where
  pPrintPrec _ _ (x :=: y)
    | isTrue x = pPrint y
    | isTrue y = pPrint x
    | otherwise = pPrint x <+> text "=" <+> pPrint y
    where
      -- XXX this is a hack
      isTrue x = show (pPrint x) == "True"

infix 4 ===
(===) :: a -> a -> Prop a
x === y = [] :=>: x :=: y

----------------------------------------------------------------------
-- Making properties look pretty (naming variables, etc.)
----------------------------------------------------------------------

prettyProp ::
  (Typed fun, Apply (Term fun), PrettyTerm fun) =>
  (Type -> [String]) -> Prop (Term fun) -> Doc
prettyProp cands = pPrint . snd . nameVars cands

prettyPropQC ::
  (Typed fun, Apply (Term fun), PrettyTerm fun) =>
  Int -> (Type -> [String]) -> Prop (Term fun) -> Doc
prettyPropQC nth cands x =
  hang (text first_char <+> text "counterexample" <+> (text $ show $ show $ pPrint yo) <+> text "$") 4
   $ hang ((text "\\" <> sep (fmap (uncurry pPrintSig) (Map.assocs var_defs))) <+> text "->") 2
   $ hsep [ parens (pPrint lhs)
          , text "==="
          , parens (pPrint rhs)
          ]

  where
    first_char =
      case nth of
        1 -> "["
        _ -> ","
    (var_defs, (ctx :=>: yo@(lhs :=: rhs))) = nameVars cands x
    pPrintSig name ty = parens $ text name <+> text "::" <+> pPrintType ty


data Named fun = Name String | Ordinary fun
instance Pretty fun => Pretty (Named fun) where
  pPrintPrec _ _ (Name name) = text name
  pPrintPrec l p (Ordinary fun) = pPrintPrec l p fun
instance PrettyTerm fun => PrettyTerm (Named fun) where
  termStyle Name{} = curried
  termStyle (Ordinary fun) = termStyle fun

nameVars :: (Type -> [String]) -> Prop (Term fun) -> (Map.Map String Type, Prop (Term (Named fun)))
nameVars cands p =
  (var_defs, subst (\x -> Map.findWithDefault undefined x sub) (fmap (fmap Ordinary) p))
  where
    sub = Map.fromList sub_map
    (sub_map, var_defs) = (runState (mapM assign (nub (vars p))) Map.empty)
    assign x = do
      s <- get
      let ty = typ x
          names = supply (cands ty)
          name = head (filter (`Map.notMember` s) names)
      modify (Map.insert name ty)
      return (x, Fun (Name name))
