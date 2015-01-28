> {-# LANGUAGE TypeOperators #-}

> {-# LANGUAGE DataKinds #-}
> {-# LANGUAGE KindSignatures #-}
> {-# LANGUAGE GADTs #-}


> {-# LANGUAGE FlexibleInstances #-}
> {-# LANGUAGE FlexibleContexts #-}
> {-# LANGUAGE PolyKinds #-}
> {-# LANGUAGE UndecidableInstances #-}
> {-# LANGUAGE AllowAmbiguousTypes #-}

> {-# LANGUAGE MultiParamTypeClasses #-}
> {-# LANGUAGE OverlappingInstances #-}
> {-# LANGUAGE FunctionalDependencies #-}

> {-# LANGUAGE TypeFamilies #-}
> {-# LANGUAGE UnicodeSyntax #-}

Пока все умные люди занимаются обсуждением records и OFR мы попробуем в очередной
раз изобрести колесо и попытаться сделать гетерогенные записи.
Поскольку просто делать такие записи не интересно, то попытаемся так же
представить простенькую библиотеку для реляционной алгебры.


> import GHC.TypeLits
> import Data.Type.Equality
> import Data.Proxy

> import           Data.Set (Set)
> import qualified Data.Set as Set
> import           Data.Monoid

Для дальшейней работы нам потребуется два типа, тут можно обойтись и одним, но
так проще. Для начала введем синоним типа обозначающий, что поле "вида" @а@, имеет
тип @b@. 

> data (a::Symbol) :-> b = V b

Так же введем тип отвечающий предыдущему на уровне типов

> data a :--> b 


Теперь все готово для ввода гетерогенных записей, т.е. записей вида ключ-значение.

> data HRec :: [*] -> * where
>   HNil  :: HRec '[]
>   HCons :: KnownSymbol b => a -> HRec xs -> HRec ((b :-> a) ': xs)

Давайте рассмотрим эту запись, перед нами предстало обобщенный алгебраический тип
параметризованный списком на уровне типов, этот список показывает какие связки
тип значение у нас имеются.

> instance Show (HRec '[]) where show _ = "HNil"

> instance (KnownSymbol s, Show (HRec xs), Show a) => Show (HRec ((s :-> a) ': xs)) where
>    show as@(HCons _ hs)  = "HCons (" ++ inner Proxy as ++ ") (" ++ show hs ++ ")"
>      where
>        inner :: (Show a, KnownSymbol s) => Proxy s -> HRec ((s :-> a)':xs) -> String
>        inner p (HCons a _) = symbolVal p ++ " :-> " ++ show a

*Main> let t = (HCons "q" (HCons 5 HNil) :: HRec ["Name" :-> String, "Age" :-> Int])
*Main> :t t
t :: HRec '["Name" :-> String, "Age" :-> Int]
*Main> show t
"HCons (Name :-> \"q\") (HCons (Age :-> 5) (HNil))"

> instance Eq (HRec '[]) where _ == _ = True
> instance (Eq b, Eq (HRec xs)) => Eq (HRec ((a :-> b) ': xs)) where
>   (HCons a as) == (HCons b bs) = a == b && as == bs

> instance Ord (HRec '[]) where compare _ _ = EQ

> instance (Ord b, Ord (HRec xs)) => Ord (HRec ((a :-> b) ': xs)) where
>    (HCons a as) `compare` (HCons b bs) = a `compare` b <> as `compare` bs

-------------------------------------
-- Reading

> class Lookup s a b c | s a b -> c where
>   rlookup' :: Proxy a -> Proxy b -> s a -> c 
> 
> instance Lookup HRec ( (n :-> a) ': xs ) n a where
>   rlookup' _ _ (HCons a _) = a
> 
> instance Lookup HRec xs n c => Lookup HRec ( (m :-> a) ': xs ) n c where
>   rlookup' pa pb (HCons _ xs) = rlookup' (pa' pa) pb xs
>     where
>       pa' :: Proxy (a ': xs) -> Proxy xs
>       pa' _ = Proxy
> 
> rlookupP :: Lookup s a b c => s a -> Proxy b -> c
> rlookupP s b = rlookup' Proxy b s 

-------------------------------------
-- Concat 

> type family Append xs ys where
>   Append '[] ys = ys
>   Append (x ': xs) ys = x ': Append xs ys

> class Merge s a b c | s a b -> c where
>   rmerge :: s a -> s b -> s c
> 
> instance Merge HRec '[] b b where
>   rmerge HNil xs = xs
> 
> instance Merge HRec as b c => Merge HRec (a ': as) b (a ': c) where
>   rmerge (HCons x xs) s = HCons x (rmerge xs s)


> type family Minus xs ys where
>   Minus xs '[] = xs
>   Minus xs (y ': ys) = Minus (MinusInner xs y) ys

> type family MinusInner xs y where
>   MinusInner (y ': xs) y = xs
>   MinusInner (x ': xs) y = x ': MinusInner xs y

-------------------------------------
-- Project

> rcons :: KnownSymbol b => Proxy b -> a -> HRec c -> HRec ( (b :-> a) ': c)
> rcons _ a xs = HCons a xs
> 
> class Project s a b c | s a b -> c where
>   rproject :: s a -> Proxy b -> s c
> 
> instance Project HRec a '[] '[] where
>   rproject _ _ = HNil
> 
> instance (KnownSymbol b, Project HRec a bs c, Lookup HRec a b k) => Project HRec a (b ': bs) ((b :-> k) ': c) where
>   rproject xs p = rcons (pHead p)
>                         (rlookupP xs (pHead p))
>                         (rproject xs (pTail p))
>     where pHead :: Proxy (b ': bs) -> Proxy b
>           pHead _ = Proxy
>           pTail :: Proxy (b ': bs) -> Proxy bs
>           pTail _ = Proxy


> class RPredicate s a b where
>   rpredicate :: s a -> s b -> Bool

> instance RPredicate HRec s '[] where
>   rpredicate _ _ = True

> instance (RPredicate HRec s ps, RPredicate1 HRec s (n :-> (a -> Bool))) => RPredicate HRec s (( n :-> (a -> Bool)) ': ps) where
>   rpredicate s h@(HCons _ xs) = rpredicate1 s (v h) && rpredicate s xs
>     where v :: HRec (n :-> (a -> Bool) ': b) -> (n :-> (a -> Bool))
>           v (HCons f _) = V f


> class RPredicate1 s a b where
>   rpredicate1 :: s a -> b -> Bool

> instance RPredicate1 HRec ((s :-> a) ': as) (s :-> (a -> Bool)) where
>   rpredicate1 (HCons a _) (V f) = f a

> instance RPredicate1 HRec as f => RPredicate1 HRec (a ': as) f where
>   rpredicate1 (HCons a as) f = rpredicate1 as f 

> type family EqPred z where
>   EqPred '[] = '[]
>   EqPred ((n :-> a) ': xs) = (n :-> (a -> Bool)) ': EqPred xs

> class EqPredicate s a b | s a -> b where
>   eqPredicate :: s a -> s b

> instance EqPredicate HRec '[] '[] where
>   eqPredicate HNil = HNil

> instance (EqPredicate HRec as bs, Eq a) => EqPredicate HRec ((n :-> a) ': as) ((n :-> (a -> Bool)) ': bs) where
>   eqPredicate (HCons x xs) = HCons (==x) (eqPredicate xs)

------------------------------------------------------------------------------------------

> newtype RelSet xs = RS { unRS :: Set (HRec xs) }

Relational algebra

1. Переименование
2. Объедиение

> union :: Ord (HRec xs) => RelSet xs -> RelSet xs -> RelSet xs
> union (RS sx) (RS sy) = RS $ sx `Set.union` sy

3. Пересечение

> intersection :: Ord (HRec xs) => RelSet xs -> RelSet xs -> RelSet xs
> intersection (RS sx) (RS sy) = RS $ sx `Set.intersection` sy

4. Вычитание

> subtraction :: Ord (HRec xs) => RelSet xs -> RelSet xs -> RelSet xs
> subtraction (RS sx) (RS sy) = RS $ sx Set.\\ sy

5. Multiplication

> multiplication :: (Merge HRec xs ys (Append xs ys), Ord (HRec (Append xs ys))) => RelSet xs -> RelSet ys -> RelSet (Append xs ys)
> multiplication (RS sx) (RS sy) =
>   RS $ Set.fromList [ x `rmerge` y
>                     | x <- Set.toList sx
>                     , y <- Set.toList sy
>                     ]

6. Выборка

> σ :: (RPredicate HRec xs ys) => RelSet xs -> HRec ys -> RelSet xs
> σ (RS sx) h = RS $ Set.filter (\x -> rpredicate x h) sx

> selection :: (RPredicate HRec xs ys) => RelSet xs -> HRec ys -> RelSet xs
> selection = σ

7. Проекция

> π :: (Project HRec xs ys ys, Ord (HRec ys)) => RelSet xs -> RelSet ys
> π rs = inner Proxy rs 
>   where inner :: (Project HRec xs ys ys, Ord (HRec ys)) => Proxy ys -> RelSet xs -> RelSet ys
>         inner p (RS sx) = RS $ Set.map (\x -> rproject x p) sx

> projection :: (Project HRec xs ys ys, Ord (HRec ys)) => RelSet xs -> RelSet ys
> projection = π 

8. Деление

> division :: (Eq (RelSet ys), Ord (HRec ys), Project HRec xs ys ys, RPredicate HRec xs (EqPred (Minus xs ys)), EqPredicate HRec (Minus xs ys) (EqPred (Minus xs ys)), Ord (HRec (Minus xs ys)), Project HRec xs (Minus xs ys) (Minus xs ys)) => RelSet xs -> RelSet ys -> RelSet (Minus xs ys)
> division rx ry = RS $ Set.fromList [ s | (s,v) <- ps1 Proxy rx, v == ry]
>   where ps1 :: (Ord (HRec ys), Ord (HRec (Minus xs ys)), Project HRec xs (Minus xs ys) (Minus xs ys), RPredicate HRec xs (EqPred (Minus xs ys)), Project HRec xs ys ys, EqPredicate HRec (Minus xs ys) (EqPred (Minus xs ys))) => proxy ys -> RelSet xs -> [(HRec (Minus xs ys), RelSet ys)]
>         ps1 _ rx = [ (x, projection (selection rx (eqPredicate x))) | x <- Set.toList (unRS $ projection rx)]
