{-# LANGUAGE DataKinds #-}
module VACC where

import CLaSH.Prelude

d4 = sing :: Sing 4
d1 = sing :: Sing 1
d2 = sing :: Sing 2


topEntity :: Vec 8 Bit -> Vec 16 Bit
topEntity x = o <++> p <++> q <++> k <++> l
  where
    y = vtake d4 x
    z = vdrop d4 x
    o = vtakeI y :: Vec 2 Bit
    p = vdropI z :: Vec 2 Bit
    q = vselect d1 d2 d4 x
    k = viterate d4 (xor L) H
    l = viterateI (xor H) L :: Vec 4 Bit
