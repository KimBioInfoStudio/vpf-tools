module VPF.Frames.TaggedField
  ( Field
  , elfield
  , rgetTagged
  , Tagged(..)
  , untag
  , retagField
  , retagFieldTo
  ) where

import GHC.TypeLits (KnownSymbol)

import Data.Coerce (coerce)
import Data.Tagged (Tagged(..), untag)
import Data.Vinyl (ElField(..), type (∈))
import Data.Vinyl.Derived (KnownField, FieldRec)
import Data.Vinyl.TypeLevel (Fst, Snd)

import Frames (rgetField)


type Field tag = Tagged (Fst tag) (Snd tag)


elfield :: KnownSymbol s => Tagged s a -> ElField '(s, a)
elfield = Field . coerce

rgetTagged :: forall r rs. (KnownField r, r ∈ rs) => FieldRec rs -> Field r
rgetTagged = coerce (rgetField @r)

retagField :: forall r r' s s' a. (r ~ '(s, a), r' ~ '(s', a))
           => Tagged s a -> Tagged s' a
retagField = coerce

retagFieldTo :: forall r' r s' s a. (r ~ '(s, a), r' ~ '(s', a))
             => Tagged s a -> Tagged s' a
retagFieldTo = coerce