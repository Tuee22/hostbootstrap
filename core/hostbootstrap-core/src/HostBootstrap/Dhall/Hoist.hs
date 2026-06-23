{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | De-duplicate the repeated vocabulary unions in generated Dhall.
--
-- The @ToDhall@-derived renderer inlines a union type's full declaration at
-- every constructor site, so a generated @<project>.dhall@ repeats the 8-way
-- @ContextKind@, 8-way @Capability@, and 11-way @CommandClass@ unions many times
-- over. This module post-processes the embedded Dhall AST before pretty-printing:
-- each repeated union is bound once in a top-level @let@ and its inline
-- occurrences are rewritten to that variable, e.g.
--
-- > let ContextKind = < HostOrchestrator | ... >
-- > in  { ..., context = { contextKind = ContextKind.HostOrchestrator, ... } }
--
-- The output stays a self-contained Dhall value (only @let ... in ...@, no
-- imports), so the in-process @auto@ decoder reads it back with no file or
-- network resolution and a render -> decode -> re-render round-trip is stable.
module HostBootstrap.Dhall.Hoist
  ( NamedUnion,
    unionOf,
    hoistUnions,
    renderHoisted,
  )
where

import Data.Functor.Const (Const (Const), getConst)
import Data.Functor.Identity (Identity (Identity), runIdentity)
import Data.Monoid (Any (Any), getAny)
import Data.Text (Text)
import Data.Void (Void)
import qualified Dhall
import Dhall.Core (Expr, Var (V))
import qualified Dhall.Core
import Dhall.Marshal.Encode (Encoder (declared, embed))

-- | A vocabulary union to hoist: the @let@-binding name and the (note-stripped)
-- union type expression to bind it to.
type NamedUnion = (Text, Expr Void Void)

-- | Build a 'NamedUnion' from a @ToDhall@ enum type. The union expression is the
-- exact type the type reflects to (so it cannot drift from the decoder), denoted
-- so it compares structurally to the inline occurrences inside an embedded value.
unionOf :: forall a. (Dhall.ToDhall a) => Text -> NamedUnion
unionOf name = (name, Dhall.Core.denote (declared (Dhall.inject :: Encoder a)))

-- | Render a @ToDhall@ value to Dhall source text, hoisting the given unions into
-- top-level @let@ bindings. Unions that do not occur in the value are skipped, so
-- no unused binding is emitted.
renderHoisted :: forall a. (Dhall.ToDhall a) => [NamedUnion] -> a -> Text
renderHoisted unions value =
  Dhall.Core.pretty
    (hoistUnions unions (Dhall.Core.denote (embed (Dhall.inject :: Encoder a) value)))

-- | Hoist each union that occurs in the expression into a top-level @let@ and
-- replace its inline occurrences with a reference to that binding.
hoistUnions :: [NamedUnion] -> Expr Void Void -> Expr Void Void
hoistUnions unions expr =
  foldr letBind body present
  where
    present = [u | u@(_, ty) <- unions, occurs ty expr]
    body = foldr (\(name, ty) -> substitute ty (Dhall.Core.Var (V name 0))) expr present
    letBind (name, ty) = Dhall.Core.Let (Dhall.Core.makeBinding name ty)

-- | Whether a subexpression structurally equal to @target@ occurs anywhere in
-- @expr@ (including @expr@ itself).
occurs :: Expr Void Void -> Expr Void Void -> Bool
occurs target = go
  where
    go e
      | e == target = True
      | otherwise = getAny (foldSubExpressions (Any . go) e)

-- | Replace every subexpression structurally equal to @target@ with
-- @replacement@, not recursing into a replaced node.
substitute :: Expr Void Void -> Expr Void Void -> Expr Void Void -> Expr Void Void
substitute target replacement = go
  where
    go e
      | e == target = replacement
      | otherwise = runIdentity (Dhall.Core.subExpressions (Identity . go) e)

-- | Fold a monoid over the immediate subexpressions of an expression.
foldSubExpressions :: (Monoid m) => (Expr Void Void -> m) -> Expr Void Void -> m
foldSubExpressions f e = getConst (Dhall.Core.subExpressions (Const . f) e)
