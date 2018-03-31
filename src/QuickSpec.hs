-- | The main QuickSpec module. Everything you need to run QuickSpec lives here.
--
-- To run QuickSpec, you need to tell it which functions to test. We call the
-- list of functions the /signature/. Here is an example signature, which tells
-- QuickSpec to test the @++@, @reverse@ and @[]@ functions:
--
-- @
-- sig = [
--   `con` "++"      ((++) :: [`A`] -> [`A`] -> [`A`]),
--   `con` "reverse" (reverse :: [`A`] -> [`A`]),
--   `con` "[]"      ([] :: [`A`]) ]
-- @
--
-- The `con` function, used above, adds a function to the signature, given its
-- name and its value. When declaring polymorphic functions in the signature,
-- we use the types `A` to `E` to represent type variables.
-- Having defined this signature, we can say @`quickSpec` sig@ to test it and
-- see the discovered equations.
--
-- If you want to test functions over your own datatypes, those types need to
-- implement `Arbitrary` and `Ord` (if the `Ord` instance is a problem, see `Observe`).
-- You must also declare those instances to QuickSpec, by including them in the
-- signature. For monomorphic types you can do this using `monoType`:
--
-- > data T = ...
-- > main = quickSpec [
-- >   ...,
-- >   `monoType` (Proxy :: Proxy T)]
--
-- You can only declare monomorphic types with `monoType`. If you want to test
-- your own polymorphic types, you must explicitly declare `Arbitrary` and `Ord`
-- instances using the `inst` function.
--
-- You can also use QuickSpec to find conditional equations. To do so, you need
-- to include some /predicates/ in the signature. These are functions returning
-- `Bool` which can appear as conditions in other equations. Declaring a predicate
-- works just like declaring a function, except that you declare it using
-- `predicate` instead of `con`.
--
-- You can also put certain options in the signature. The most useful is
-- `withMaxTermSize', which you can use to tell QuickSpec to generate larger
-- equations.
--
-- The @<https://github.com/nick8325/quickspec/tree/master/examples examples>@
-- directory contains many examples. Here are some interesting ones:
--
-- * @<https://github.com/nick8325/quickspec/tree/master/examples/Arith.hs Arith.hs>@: a simple arithmetic example. Demonstrates basic use of QuickSpec.
-- * @<https://github.com/nick8325/quickspec/tree/master/examples/Lists.hs Lists.hs>@: list functions. Demonstrates testing polymorphic functions.
-- * @<https://github.com/nick8325/quickspec/tree/master/examples/Sorted.hs Sorted.hs>@: sorting. Demonstrates finding conditional equations.
-- * @<https://github.com/nick8325/quickspec/tree/master/examples/IntSet.hs IntSet.hs>@: a few functions from "Data.IntSet". Demonstrates testing user-defined datatypes and finding conditional equations.
-- * @<https://github.com/nick8325/quickspec/tree/master/examples/PrettyPrinting.hs PrettyPrinting.hs>@: pretty printing combinators. Demonstrates testing user-defined datatypes and using observational equality.
-- * @<https://github.com/nick8325/quickspec/tree/master/examples/Parsing.hs Parsing.hs>@: parser combinators. Demonstrates testing polymorphic datatypes and using observational equality.
--
-- You can also find some larger case studies in our paper,
-- <http://www.cse.chalmers.se/~nicsma/papers/quickspec2.pdf Quick
-- specifications for the busy programmer>.

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}
module QuickSpec(
  -- * Running QuickSpec
  quickSpec, Sig, Signature(..),

  -- * Declaring functions and predicates
  con, predicate,
  -- ** Type variables for polymorphic functions
  A, B, C, D, E,

  -- * Declaring types
  monoType, vars, monoTypeWithVars, inst, instFun, Observe(..),

  -- * Including type class constraints
  type (==>), liftC, instanceOf,

  -- * Standard signatures
  -- | The \"prelude\": a standard signature containing useful functions
  --   like '++', which can be used as background theory.
  lists, arith, funs, bools, prelude, without,

  -- * Exploring functions in series
  background, series,

  -- * Customising QuickSpec
  withMaxTermSize, withMaxTests, withMaxTestSize, defaultTo,
  withPruningDepth, withPruningTermSize, withFixedSeed,
  withInferInstanceTypes,

  -- * Re-exported functionality
  Typeable, (:-)(..), Dict(..), Proxy(..), Arbitrary) where

import QuickSpec.Haskell(Predicateable, PredicateTestCase, Names(..), Observe(..))
import qualified QuickSpec.Haskell as Haskell
import qualified QuickSpec.Haskell.Resolve as Haskell
import qualified QuickSpec.Testing.QuickCheck as QuickCheck
import qualified QuickSpec.Pruning.UntypedTwee as Twee
import Test.QuickCheck
import Test.QuickCheck.Random
import Data.Constraint
import Data.Lens.Light
import QuickSpec.Utils
import QuickSpec.Type hiding (defaultTo)
import Data.Proxy
import System.Environment

-- | Run QuickSpec. See the documentation at the top of this file.
quickSpec :: Signature sig => sig -> IO ()
quickSpec sig = do
  -- Undocumented feature for testing :)
  seed <- lookupEnv "QUICKCHECK_SEED"
  let
    sig' = case seed of
      Nothing -> signature sig
      Just xs -> signature [signature sig, withFixedSeed (read xs)]

  Haskell.quickSpec (runSig sig' (Context 1 []) Haskell.defaultConfig)

-- | A signature.
newtype Sig = Sig { unSig :: Context -> Haskell.Config -> Haskell.Config }

-- Settings for building the signature.
-- Int: number of nested calls to 'background'.
-- [String]: list of names to exclude.
data Context = Context Int [String]

instance Monoid Sig where
  mempty = Sig (\_ -> id)
  Sig sig1 `mappend` Sig sig2 = Sig (\ctx -> sig2 ctx . sig1 ctx)

-- | A class of things that can be used as a QuickSpec signature.
class Signature sig where
  -- | Convert the thing to a signature.
  signature :: sig -> Sig

instance Signature Sig where
  signature = id

instance Signature sig => Signature [sig] where
  signature = mconcat . map signature

runSig :: Signature sig => sig -> Context -> Haskell.Config -> Haskell.Config
runSig = unSig . signature

-- | Declare a constant with a given name and value.
-- If the constant you want to use is polymorphic, you can use the types
-- `A`, `B`, `C`, `D`, `E` to monomorphise it, for example:
--
-- > constant "reverse" (reverse :: [A] -> [A])
--
-- QuickSpec will then understand that the constant is really polymorphic.
con :: Typeable a => String -> a -> Sig
con name x =
  Sig $ \ctx@(Context _ names) ->
    if name `elem` names then id else
      unSig (constant (Haskell.con name x)) ctx

constant :: Haskell.Constant -> Sig
constant con =
  Sig $ \(Context n _) ->
    modL Haskell.lens_constants (appendAt n [con])

-- | Type class constraints as first class citizens
type c ==> t = Dict c -> t

-- | Lift a constrained type to a `==>` type which QuickSpec
-- can work with
liftC :: (c => a) -> c ==> a
liftC a Dict = a

-- | Add an instance of a type class to the signature
instanceOf :: forall c. (Typeable c, c) => Sig
instanceOf = inst (Sub Dict :: () :- c)

-- | Declare a predicate with a given name and value.
-- The predicate should be a function which returns `Bool`.
-- It will appear in equations just like any other constant,
-- but will also be allowed to appear as a condition.
--
-- For example:
--
-- @
-- sig = [
--   `con` "delete" (`Data.List.delete` :: Int -> [Int] -> [Int]),
--   `con` "insert" (`Data.List.insert` :: Int -> [Int] -> [Int]),
--   predicate "member" (member :: Int -> [Int] -> Bool) ]
-- @
predicate :: ( Predicateable a
             , Typeable a
             , Typeable (PredicateTestCase a))
             => String -> a -> Sig
predicate name x =
  Sig $ \ctx@(Context _ names) ->
    if name `elem` names then id else
    let (insts, con) = Haskell.predicate name x in
      runSig [addInstances insts `mappend` constant con] ctx

-- | Declare a new monomorphic type.
-- The type must implement `Ord` and `Arbitrary`.
monoType :: forall proxy a. (Ord a, Arbitrary a, Typeable a) => proxy a -> Sig
monoType _ =
  mconcat [
    inst (Sub Dict :: () :- Ord a),
    inst (Sub Dict :: () :- Arbitrary a)]

-- | Declare a new monomorphic type, saying how you want variables of that type to be named.
monoTypeWithVars :: forall proxy a. (Ord a, Arbitrary a, Typeable a) => [String] -> proxy a -> Sig
monoTypeWithVars xs proxy =
  monoType proxy `mappend` vars xs proxy

-- | Customize how variables of a particular type are named.
vars :: forall proxy a. Typeable a => [String] -> proxy a -> Sig
vars xs _ = instFun (Names xs :: Names a)

-- | Declare a typeclass instance. QuickSpec needs to have an `Ord` and
-- `Arbitrary` instance for each type you want it to test.
--
-- For example, if you are testing @`Data.Map.Map` k v@, you will need to add
-- the following two declarations to your signature:
--
-- @
-- `inst` (`Sub` `Dict` :: (Ord A, Ord B) `:-` Ord (Map A B))
-- `inst` (`Sub` `Dict` :: (Arbitrary A, Arbitrary B) `:-` Arbitrary (Map A B))
-- @
inst :: (Typeable c1, Typeable c2) => c1 :- c2 -> Sig
inst = instFun

instFun :: Typeable a => a -> Sig
instFun x = addInstances (Haskell.inst x)

addInstances :: Haskell.Instances -> Sig
addInstances insts =
  Sig (\_ -> modL Haskell.lens_instances (`mappend` insts))

-- | Declare some functions as being background functions.
-- These are functions which are not interesting on their own,
-- but which may appear in interesting laws with non-background functions.
-- Declaring background functions may improve the laws you get out.
--
-- Here is an example, which tests @++@ and @length@, giving @0@ and @+@ as
-- background functions:
--
-- > main = quickSpec [
-- >   con "++" ((++) :: [A] -> [A] -> [A]),
-- >   con "length" (length :: [A] -> Int),
-- >
-- >   background [
-- >     con "0" (0 :: Int),
-- >     con "+" ((+) :: Int -> Int -> Int) ] ]
background :: Signature sig => sig -> Sig
background sig =
  Sig (\(Context _ xs) -> runSig sig (Context 0 xs))

-- | Remove a function or predicate from the signature.
-- Useful in combination with 'prelude' and friends.
without :: Signature sig => sig -> [String] -> Sig
without sig xs =
  Sig (\(Context n ys) -> runSig sig (Context n (ys ++ xs)))

-- | Run QuickCheck on a series of signatures. Tests the functions in the first
-- signature, then adds the functions in the second signature, then adds the
-- functions in the third signature, and so on.
--
-- This can be useful when you have a core API you want to test first, and a
-- larger API you want to test later. The laws for the core API will be printed
-- separately from the laws for the larger API.
--
-- Here is an example which first tests @0@ and @+@ and then adds @++@ and @length@:
--
-- > main = quickSpec [sig1, sig2]
-- >   where
-- >     sig1 = [
-- >       con "0" (0 :: Int),
-- >       con "+" ((+) :: Int -> Int -> Int) ]
-- >     sig2 = [
-- >       con "++" ((++) :: [A] -> [A] -> [A]),
-- >       con "length" (length :: [A] -> Int) ]
series :: Signature sig => [sig] -> Sig
series = foldr op mempty . map signature
  where
    op sig sigs = sig `mappend` later (signature sigs)
    later sig =
      Sig (\(Context n xs) cfg -> unSig sig (Context (n+1) xs) cfg)

-- | Set the maximum size of terms to explore (default: 7).
withMaxTermSize :: Int -> Sig
withMaxTermSize n = Sig (\_ -> setL Haskell.lens_max_size n)

-- | Set how many times to test each discovered law (default: 1000).
withMaxTests :: Int -> Sig
withMaxTests n =
  Sig (\_ -> setL (QuickCheck.lens_num_tests # Haskell.lens_quickCheck) n)

-- | Set the maximum value for QuickCheck's size parameter when generating test
-- data (default: 20).
withMaxTestSize :: Int -> Sig
withMaxTestSize n =
  Sig (\_ -> setL (QuickCheck.lens_max_test_size # Haskell.lens_quickCheck) n)

-- | Set which type polymorphic terms are tested at.
defaultTo :: Typeable a => proxy a -> Sig
defaultTo proxy = Sig (\_ -> setL Haskell.lens_default_to (typeRep proxy))

-- | Set how hard QuickSpec tries to filter out redundant equations (default: no limit).
--
-- If you experience long pauses when running QuickSpec, try setting this number
-- to 2 or 3.
withPruningDepth :: Int -> Sig
withPruningDepth n =
  Sig (\_ -> setL (Twee.lens_max_cp_depth # Haskell.lens_twee) n)

-- | Set the maximum term size QuickSpec will reason about when it filters out
-- redundant equations (default: same as maximum term size).
--
-- If you get laws you believe are redundant, try increasing this number to 1 or
-- 2 more than the maximum term size.
withPruningTermSize :: Int -> Sig
withPruningTermSize n =
  Sig (\_ -> setL (Twee.lens_max_term_size # Haskell.lens_twee) n)

-- | Set the random number seed used for test case generation.
-- Useful if you want repeatable results.
withFixedSeed :: Int -> Sig
withFixedSeed s = Sig (\_ -> setL (QuickCheck.lens_fixed_seed # Haskell.lens_quickCheck) (Just . mkQCGen $ s))

-- | Automatically infer types to add to the universe from
-- available type class instances
withInferInstanceTypes :: Sig
withInferInstanceTypes = Sig (\_ -> setL (Haskell.lens_infer_instance_types) True)

-- | A signature containing boolean functions:
-- @(`||`)@, @(`&&`)@, `not`, `True`, `False`.
bools :: Sig
bools = background [
  "||"    `con` (||),
  "&&"    `con` (&&),
  "not"   `con` not,
  "True"  `con` True,
  "False" `con` False]

-- | A signature containing arithmetic operations:
-- @0@, @1@, @(`+`)@.
-- Instantiate it with e.g. @arith (`Proxy` :: `Proxy` `Int`)@.
arith :: forall proxy a. (Typeable a, Ord a, Num a, Arbitrary a) => proxy a -> Sig
arith proxy = background [
  monoType proxy,
  "0" `con` (0   :: a),
  "1" `con` (1   :: a),
  "+" `con` ((+) :: a -> a -> a)]

-- | A signature containing list operations:
-- @[]@, @(:)@, @(`++`)@.
lists :: Sig
lists = background [
  "[]"      `con` ([]      :: [A]),
  ":"       `con` ((:)     :: A -> [A] -> [A]),
  "++"      `con` ((++)    :: [A] -> [A] -> [A])]

-- | A signature containing higher-order functions:
-- @(`.`)@ and `id`.
-- Useful for testing `map` and similar.
funs :: Sig
funs = background [
  "."  `con` ((.) :: (A -> A) -> (A -> A) -> (A -> A)),
  "id" `con` (id  :: A -> A) ]

-- | The QuickSpec prelude.
-- Contains boolean, arithmetic and list functions, and function composition.
-- For more precise control over what gets included,
-- see 'bools', 'arith', 'lists', 'funs' and 'without'.
prelude :: Sig
prelude = signature [bools, arith (Proxy :: Proxy Int), lists]
