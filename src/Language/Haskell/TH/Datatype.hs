{-# Language CPP #-}
{-# Language DeriveGeneric, DeriveDataTypeable #-}

{- |

This module provides a flattened view of information about data types
and newtypes that can be supported uniformly across multiple verisons
of the template-haskell package.

-}
module Language.Haskell.TH.Datatype
  ( reifyDatatype
  , DatatypeInfo(..)
  , ConstructorInfo(..)
  ) where

import           Data.Data (Data)
import           GHC.Generics (Generic)
import           Language.Haskell.TH

#if MIN_VERSION_template_haskell(2,11,0)
import           Data.List.NonEmpty (NonEmpty(..))
import           Data.Foldable
import qualified Data.Map as Map
import           Data.Map (Map)
import qualified Data.List.NonEmpty as NE
#endif

-- | Normalized information about newtypes and data types.
data DatatypeInfo = DatatypeInfo
  { datatypeContext :: Cxt               -- ^ Data type context (deprecated)
  , datatypeName    :: Name              -- ^ Type constructor
  , datatypeVars    :: [TyVarBndr]       -- ^ Type parameters
  , datatypeDerives :: Cxt               -- ^ Derived constraints
  , datatypeVariant :: DatatypeVariant   -- ^ Extra information
  , datatypeCons    :: [ConstructorInfo] -- ^ Normalize constructor information
  }
  deriving (Show, Eq, Ord, Data, Generic)

data DatatypeVariant
  = Datatype -- ^ Type declared with *data*
  | Newtype  -- ^ Type declared with *newtype*
  deriving (Show, Read, Eq, Ord, Data, Generic)

-- | Normalized information about constructors associated with newtypes and
-- data types.
data ConstructorInfo = ConstructorInfo
  { constructorName    :: Name               -- ^ Constructor name
  , constructorVars    :: [TyVarBndr]        -- ^ Constructor type parameters
  , constructorContext :: Cxt                -- ^ Constructor constraints
  , constructorFields  :: [Type]             -- ^ Constructor fields
  , constructorVariant :: ConstructorVariant -- ^ Extra information
  }
  deriving (Show, Eq, Ord, Data, Generic)


data ConstructorVariant
  = NormalConstructor        -- ^ Constructor without field names
  | InfixConstructor         -- ^ Infix constructor
  | RecordConstructor [Name] -- ^ Constructor with field names
  deriving (Show, Eq, Ord, Data, Generic)


-- | Compute a normalized view of the metadata about a data type or newtype
-- given a type constructor.
reifyDatatype ::
  Name {- ^ type constructor -} ->
  Q DatatypeInfo
reifyDatatype n = normalizeInfo =<< reify n


normalizeInfo :: Info -> Q DatatypeInfo
normalizeInfo (TyConI dec) = normalizeDec dec
normalizeInfo _ = fail "normalizeInfo: Expected a type constructor"


normalizeDec :: Dec -> Q DatatypeInfo
#if MIN_VERSION_template_haskell(2,11,0)
normalizeDec (NewtypeD context name tyvars _kind con derives) =
  normalizeDec' context name tyvars [con] derives Newtype
normalizeDec (DataD context name tyvars _kind cons derives) =
  normalizeDec' context name tyvars cons derives Datatype
#else
normalizeDec (NewtypeD context name tyvars con derives) =
  normalizeDec' context name tyvars [con] (map ConT derives) Newtype
normalizeDec (DataD context name tyvars cons derives) =
  normalizeDec' context name tyvars cons (map ConT derives) Datatype
#endif
normalizeDec _ = fail "normalizeDec: DataD or NewtypeD required"


normalizeDec' ::
  Cxt             {- ^ Datatype context    -} ->
  Name            {- ^ Type constructor    -} ->
  [TyVarBndr]     {- ^ Type parameters     -} ->
  [Con]           {- ^ Constructors        -} ->
  Cxt             {- ^ Derived constraints -} ->
  DatatypeVariant {- ^ Extra information   -} ->
  Q DatatypeInfo
normalizeDec' context name tyvars cons derives variant =
  do let vs = map tvName tyvars
     cons' <- concat <$> traverse (normalizeCon name vs) cons
     pure DatatypeInfo
       { datatypeContext = context
       , datatypeName    = name
       , datatypeVars    = tyvars
       , datatypeCons    = cons'
       , datatypeDerives = derives
       , datatypeVariant = variant
       }


normalizeCon ::
  Name   {- ^ Type constructor -} ->
  [Name] {- ^ Type parameters  -} ->
  Con    {- ^ Constructor      -} ->
  Q [ConstructorInfo]
normalizeCon typename vars = go [] []
  where
    go tyvars context c =
      case c of
        NormalC n xs ->
          pure [ConstructorInfo n tyvars context (map snd xs) NormalConstructor]
        InfixC l n r ->
          pure [ConstructorInfo n tyvars context [snd l,snd r] InfixConstructor]
        RecC n xs ->
          let fns = takeFieldNames xs in
          pure [ConstructorInfo n tyvars context
                  (takeFieldTypes xs) (RecordConstructor fns)]
        ForallC tyvars' context' c' ->
          go (tyvars'++tyvars) (context'++context) c'

#if MIN_VERSION_template_haskell(2,11,0)
        GadtC ns xs innerType ->
          traverse (gadtCase innerType (map snd xs) NormalConstructor) ns
        RecGadtC ns xs innerType ->
          let fns = takeFieldNames xs in
          traverse (gadtCase innerType (takeFieldTypes xs) (RecordConstructor fns)) ns
      where
        gadtCase = normalizeGadtC typename vars tyvars context


normalizeGadtC ::
  Name               {- ^ Type constructor             -} ->
  [Name]             {- ^ Type parameters              -} ->
  [TyVarBndr]        {- ^ Constructor parameters       -} ->
  Cxt                {- ^ Constructor context          -} ->
  Type               {- ^ Declared type of constructor -} ->
  [Type]             {- ^ Constructor field types      -} ->
  ConstructorVariant {- ^ Constructor variant          -} ->
  Name               {- ^ Constructor                  -} ->
  Q ConstructorInfo
normalizeGadtC typename vars tyvars context innerType fields variant name =
  do innerType' <- resolveTypeSynonyms innerType
     case decomposeType innerType' of
       ConT innerTyCon :| ts | typename == innerTyCon ->

         let (substName, context1) = mergeArguments vars ts
             subst   = VarT <$> substName
             tyvars' = [ tv | tv <- tyvars, Map.notMember (tvName tv) subst ]

             context2 = applySubstitution subst <$> context1
             fields'  = applySubstitution subst <$> fields
         in pure (ConstructorInfo name tyvars' (context2 ++ context) fields' variant)

mergeArguments :: [Name] -> [Type] -> (Map Name Name, Cxt)
mergeArguments ns ts = foldl' aux (Map.empty, []) (zip ns ts)
  where
    aux (subst, context) (n,p) =
      case p of
        VarT m | Map.notMember m subst -> (Map.insert m n subst, context)
        _ -> (subst, EqualityT `AppT` VarT n `AppT` p : context)

resolveTypeSynonyms :: Type -> Q Type
resolveTypeSynonyms t =
  let f :| xs = decomposeType t

      notTypeSynCase = foldl AppT f <$> traverse resolveTypeSynonyms xs

  in case f of
       ConT n ->
         do info <- reify n
            case info of
              TyConI (TySynD _ synvars def) ->
                do let argNames    = map tvName synvars
                       (args,rest) = splitAt (length argNames) xs
                       subst       = Map.fromList (zip argNames args)
                   resolveTypeSynonyms (foldl AppT (applySubstitution subst def) rest)

              _ -> notTypeSynCase
       _ -> notTypeSynCase

-- | Decompose a type into a list of it's outermost applications.
--
-- >>> t == foldl1 AppT (decomposeType t)
decomposeType :: Type -> NonEmpty Type
decomposeType = NE.reverse . go
  where
    go (AppT f x) = x NE.<| go f
    go t          = t :| []

applySubstitution :: Map Name Type -> Type -> Type
applySubstitution subst = go
  where
    go (ForallT tvs context t) =
      let subst' = foldl' (flip Map.delete) subst (map tvName tvs) in
      ForallT tvs (applySubstitution subst' <$> context)
                  (applySubstitution subst' t)
    go (AppT f x)      = AppT (go f) (go x)
    go (SigT t k)      = SigT (go t) (go k)
    go (VarT v)        = Map.findWithDefault (VarT v) v subst
    go (InfixT l c r)  = InfixT (go l) c (go r)
    go (UInfixT l c r) = UInfixT (go l) c (go r)
    go (ParensT t)     = ParensT (go t)
    go t               = t

#endif

tvName :: TyVarBndr -> Name
tvName (PlainTV  name  ) = name
tvName (KindedTV name _) = name

takeFieldNames :: [(Name,a,b)] -> [Name]
takeFieldNames xs = [a | (a,_,_) <- xs]

takeFieldTypes :: [(a,b,Type)] -> [Type]
takeFieldTypes xs = [a | (_,_,a) <- xs]