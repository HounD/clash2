{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections   #-}

-- | Create Netlists out of normalized CoreHW Terms
module CLaSH.Netlist where

import           Control.Applicative        (liftA2)
import           Control.Lens               ((.=), (<<%=))
import qualified Control.Lens               as Lens
import qualified Control.Monad              as Monad
import           Control.Monad.State        (runStateT)
import           Control.Monad.Writer       (listen, runWriterT)
import           Data.Either                (partitionEithers)
import           Data.HashMap.Lazy          (HashMap)
import qualified Data.HashMap.Lazy          as HashMap
import qualified Data.HashSet               as HashSet
import           Data.List                  (elemIndex, nub)
import           Data.Maybe                 (fromMaybe)
import qualified Data.Text.Lazy             as Text
import           Unbound.LocallyNameless    (Embed (..), name2String,
                                             runFreshMT, string2Name, unbind,
                                             unembed, unrebind)

import           CLaSH.Core.DataCon         (DataCon (..))
import           CLaSH.Core.Literal         (Literal (..))
import           CLaSH.Core.Pretty          (showDoc)
import           CLaSH.Core.Term            (Pat (..), Term (..), TmName)
import qualified CLaSH.Core.Term            as Core
import           CLaSH.Core.Type            (Type)
import           CLaSH.Core.Util            (collectArgs, isVar, termType)
import           CLaSH.Core.Var             (Id, Var (..))
import           CLaSH.Netlist.BlackBox
import           CLaSH.Netlist.Id
import           CLaSH.Netlist.Types        as HW
import           CLaSH.Netlist.Util
import           CLaSH.Normalize.Util
import           CLaSH.Primitives.Types     as P
import           CLaSH.Util

-- | Generate a hierarchical netlist out of a set of global binders with
-- @topEntity@ at the top.
genNetlist :: Maybe VHDLState
           -- ^ State for the 'CLaSH.Netlist.VHDL.VHDLM' Monad
           -> HashMap TmName (Type,Term)
           -- ^ Global binders
           -> PrimMap
           -- ^ Primitive definitions
           -> (Type -> Maybe (Either String HWType))
           -- ^ Hardcoded Type -> HWType translator
           -> Maybe Int
           -- ^ Symbol count
           -> TmName
           -- ^ Name of the @topEntity@
           -> IO ([Component],VHDLState)
genNetlist vhdlStateM globals primMap typeTrans mStart topEntity = do
  (_,s) <- runNetlistMonad vhdlStateM globals primMap typeTrans $ genComponent topEntity mStart
  return (HashMap.elems $ _components s, _vhdlMState s)

-- | Run a NetlistMonad action in a given environment
runNetlistMonad :: Maybe VHDLState
                -- ^ State for the 'CLaSH.Netlist.VHDL.VHDLM' Monad
                -> HashMap TmName (Type,Term)
                -- ^ Global binders
                -> PrimMap
                -- ^ Primitive Definitions
                -> (Type -> Maybe (Either String HWType))
                -- ^ Hardcode Type -> HWType translator
                -> NetlistMonad a
                -- ^ Action to run
                -> IO (a,NetlistState)
runNetlistMonad vhdlStateM s p typeTrans
  = runFreshMT
  . flip runStateT s'
  . (fmap fst . runWriterT)
  . runNetlist
  where
    s' = NetlistState s HashMap.empty 0 0 HashMap.empty p (fromMaybe (HashSet.empty,0,HashMap.empty) vhdlStateM) typeTrans

-- | Generate a component for a given function (caching)
genComponent :: TmName -- ^ Name of the function
             -> Maybe Int -- ^ Starting value of the unique counter
             -> NetlistMonad Component
genComponent compName mStart = do
  compExprM <- fmap (HashMap.lookup compName) $ Lens.use bindings
  case compExprM of
    Nothing -> error $ $(curLoc) ++ "No normalized expression found for: " ++ show compName
    Just (_,expr) -> makeCached compName components $
                      genComponentT compName expr mStart

-- | Generate a component for a given function
genComponentT :: TmName -- ^ Name of the function
              -> Term -- ^ Corresponding term
              -> Maybe Int -- ^ Starting value of the unique counter
              -> NetlistMonad Component
genComponentT compName componentExpr mStart = do
  varCount .= fromMaybe 0 mStart
  componentNumber <- cmpCount <<%= (+1)

  let componentName' = (`Text.append` (Text.pack $ show componentNumber))
                     . ifThenElse Text.null
                          (`Text.append` Text.pack "Component_")
                          (`Text.append` Text.pack "_")
                     . mkBasicId
                     . last
                     . Text.splitOn (Text.pack ".")
                     . Text.pack
                     $ name2String compName

  (arguments,binders,result) <- do { normalizedM <- splitNormalized componentExpr
                                   ; case normalizedM of
                                       Right normalized -> mkUniqueNormalized normalized
                                       Left err         -> error err
                                   }

  let ids = HashMap.fromList
          $ map (\(Id v (Embed t)) -> (v,t))
          $ arguments ++ map fst binders

  gamma <- (ids `HashMap.union`) . HashMap.map fst
           <$> Lens.use bindings

  varEnv .= gamma

  typeTrans    <- Lens.use typeTranslator
  let resType  = unsafeCoreTypeToHWType $(curLoc) typeTrans $ ids HashMap.! result
      argTypes = map (\(Id _ (Embed t)) -> unsafeCoreTypeToHWType $(curLoc) typeTrans t) arguments

  let netDecls = map (\(id_,_) ->
                        NetDecl (mkBasicId . Text.pack . name2String $ varName id_)
                                (unsafeCoreTypeToHWType $(curLoc) typeTrans . unembed $ varType id_)
                                Nothing
                     ) $ filter ((/= result) . varName . fst) binders
  (decls,clks) <- listen $ concat <$> mapM (uncurry mkDeclarations . second unembed) binders

  let compInps       = zip (map (mkBasicId . Text.pack . name2String . varName) arguments) argTypes
      compOutp       = (mkBasicId . Text.pack $ name2String result, resType)
      component      = Component componentName' (nub clks) compInps compOutp (netDecls ++ decls)
  return component

-- | Generate a list of Declarations for a let-binder
mkDeclarations :: Id -- ^ LHS of the let-binder
               -> Term -- ^ RHS of the let-binder
               -> NetlistMonad [Declaration]
mkDeclarations bndr (Var _ v) = mkFunApp bndr v []

mkDeclarations bndr e@(Case _ []) =
  error $ $(curLoc) ++ "Case-decompositions with an empty list of alternatives not supported"

mkDeclarations bndr e@(Case (Var scrutTy scrutNm) [alt]) = do
  (pat,Var varTy varTm)  <- unbind alt
  typeTrans    <- Lens.use typeTranslator
  let dstId    = mkBasicId . Text.pack . name2String $ varName bndr
      altVarId = mkBasicId . Text.pack $ name2String varTm
      selId    = mkBasicId . Text.pack $ name2String scrutNm
      modifier = case pat of
        DataPat (Embed dc) ids -> let (_,tms) = unrebind ids
                                  in case elemIndex (Id varTm (Embed varTy)) tms of
                                       Nothing -> Nothing
                                       Just fI -> Just (Indexed (unsafeCoreTypeToHWType $(curLoc) typeTrans scrutTy,dcTag dc - 1,fI))
        _                      -> error $ $(curLoc) ++ "unexpected pattern in extractor: " ++ showDoc e
      extractExpr = Identifier (maybe altVarId (const selId) modifier) modifier
  return [Assignment dstId extractExpr]

mkDeclarations bndr (Case scrut alts) = do
  alts'                  <- mapM unbind alts
  scrutTy                <- termType scrut
  scrutHTy               <- unsafeCoreTypeToHWTypeM $(curLoc) scrutTy
  (scrutExpr,scrutDecls) <- first (mkScrutExpr scrutHTy (fst (last alts'))) <$> mkExpr scrutTy scrut
  (exprs,altsDecls)      <- (second concat . unzip) <$> mapM (mkCondExpr scrutHTy) alts'

  let dstId = mkBasicId . Text.pack . name2String $ varName bndr
  return $! scrutDecls ++ altsDecls ++ [CondAssignment dstId scrutExpr (reverse exprs)]
  where
    mkCondExpr :: HWType -> (Pat,Term) -> NetlistMonad ((Maybe Expr,Expr),[Declaration])
    mkCondExpr scrutHTy (pat,alt) = do
      altTy <- termType alt
      (altExpr,altDecls) <- mkExpr altTy alt
      (,altDecls) <$> case pat of
        DefaultPat           -> return (Nothing,altExpr)
        DataPat (Embed dc) _ -> return (Just (dcToLiteral scrutHTy (dcTag dc)),altExpr)
        LitPat  (Embed (IntegerLiteral i)) -> return (Just (HW.Literal Nothing (NumLit $ fromInteger i)),altExpr)
        _                    -> error $ $(curLoc) ++ "Not an integer literal in LitPat"

    mkScrutExpr :: HWType -> Pat -> Expr -> Expr
    mkScrutExpr scrutHTy pat scrutE = case pat of
      DataPat (Embed dc) _ -> let modifier = Just (DC (scrutHTy,dcTag dc - 1))
                              in case scrutE of
                                  Identifier scrutId _ -> Identifier scrutId modifier
                                  BlackBoxE bbE _      -> BlackBoxE bbE modifier
                                  _ -> error $ $(curLoc) ++ "Not in normal form: Not a variable reference or primitive as subject of a case-statement"
      _ -> scrutE

    dcToLiteral :: HWType -> Int -> Expr
    dcToLiteral Bool 1 = HW.Literal Nothing (BoolLit False)
    dcToLiteral Bool 2 = HW.Literal Nothing (BoolLit True)
    dcToLiteral Bit 1  = HW.Literal Nothing (BitLit H)
    dcToLiteral Bit 2  = HW.Literal Nothing (BitLit L)
    dcToLiteral t i    = HW.Literal (Just $ conSize t) (NumLit (i-1))

mkDeclarations bndr app = do
  let (appF,(args,tyArgs)) = second partitionEithers $ collectArgs app
  args' <- Monad.filterM (liftA2 representableType (Lens.use typeTranslator) . termType) args
  case appF of
    Var _ f
      | all isVar args' && null tyArgs -> mkFunApp bndr f args'
      | otherwise                      -> error $ $(curLoc) ++ "Not in normal form: Var-application with non-Var arguments"
    _ -> do
      (exprApp,declsApp) <- mkExpr (unembed $ varType bndr) app
      let dstId = mkBasicId . Text.pack . name2String $ varName bndr
      return (declsApp ++ [Assignment dstId exprApp])

-- | Generate a list of Declarations for a let-binder where the RHS is a function application
mkFunApp :: Id -- ^ LHS of the let-binder
         -> TmName -- ^ Name of the applied function
         -> [Term] -- ^ Function arguments
         -> NetlistMonad [Declaration]
mkFunApp dst fun args = do
  normalized <- Lens.use bindings
  case HashMap.lookup fun normalized of
    Just _ -> do
      (Component compName hidden compInps compOutp _) <- preserveVarEnv $ genComponent fun Nothing
      if length args == length compInps
        then let dstId         = mkBasicId . Text.pack . name2String $ varName dst
                 args'         = map varToExpr args
                 hiddenAssigns = map (\(i,_) -> (i,Identifier i Nothing)) hidden
                 inpAssigns    = zip (map fst compInps) args'
                 outpAssign    = (fst compOutp,Identifier dstId Nothing)
                 instDecl      = InstDecl compName dstId (outpAssign:hiddenAssigns ++ inpAssigns)
             in return [instDecl]
        else error $ $(curLoc) ++ "under-applied normalized function"
    Nothing -> case args of
      [] -> do
        let dstId = mkBasicId . Text.pack . name2String $ varName dst
        return [Assignment dstId (Identifier (mkBasicId . Text.pack $ name2String fun) Nothing)]
      _ -> error $ $(curLoc) ++ "Unknown function: " ++ showDoc fun

-- | Generate an expression for a term occurring on the RHS of a let-binder
mkExpr :: Type -- ^ Type of the LHS of the let-binder
       -> Term -- ^ Term to convert to an expression
       -> NetlistMonad (Expr,[Declaration]) -- ^ Returned expression and a list of generate BlackBox declarations
mkExpr _ (Core.Literal lit) = return (HW.Literal Nothing . NumLit $ fromInteger  $! i,[])
  where
    i = case lit of
          (IntegerLiteral i') -> i'
          _ -> error $ $(curLoc) ++ "not an integer literal"

mkExpr ty app = do
  let (appF,(args,tyArgs)) = second partitionEithers $ collectArgs app
  hwTy <- unsafeCoreTypeToHWTypeM $(curLoc) ty
  args' <- Monad.filterM (liftA2 representableType (Lens.use typeTranslator) . termType) args
  case appF of
    Data dc
      | all (\e -> isConstant e || isVar e) args' -> mkDcApplication hwTy dc args'
      | otherwise                                 -> error $ $(curLoc) ++ "Not in normal form: DataCon-application with non-Simple arguments"
    Prim nm _ -> do
      bbM <- fmap (HashMap.lookup nm) $ Lens.use primitives
      case bbM of
        Just p@(P.BlackBox {}) ->
          case template p of
            Left templD -> do
              i <- varCount <<%= (+1)
              let tmpNm   = "tmp_" ++ show i
                  tmpId   = Id (string2Name tmpNm) (Embed ty)
                  tmpS    = Text.pack tmpNm
                  netDecl = NetDecl tmpS hwTy Nothing
              (bbCtx,ctxDcls) <- mkBlackBoxContext tmpId args
              bb <- fmap BlackBoxD $! mkBlackBox templD bbCtx
              return (Identifier tmpS Nothing, ctxDcls ++ [netDecl,bb])
            Right templE -> do
              (bbCtx,ctxDcls) <- mkBlackBoxContext (Id (string2Name "_ERROR_") (Embed ty)) args
              bb <- fmap (`BlackBoxE` Nothing) $! mkBlackBox templE bbCtx
              return (bb,ctxDcls)
        _ -> error $ $(curLoc) ++ "No blackbox found: " ++ Text.unpack nm
    Var _ f
      | null args -> return (Identifier (mkBasicId . Text.pack $ name2String f) Nothing,[])
      | otherwise -> error $ $(curLoc) ++ "Not in normal form: top-level binder in argument position: " ++ showDoc app
    _ -> error $ $(curLoc) ++ "Not in normal form: application of a Let/Lam/Case: " ++ showDoc app

-- | Generate an expression for a DataCon application occurring on the RHS of a let-binder
mkDcApplication :: HWType -- ^ HWType of the LHS of the let-binder
                -> DataCon -- ^ Applied DataCon
                -> [Term] -- ^ DataCon Arguments
                -> NetlistMonad (Expr,[Declaration]) -- ^ Returned expression and a list of generate BlackBox declarations
mkDcApplication dstHType dc args = do
  argTys              <- mapM termType args
  (argExprs,argDecls) <- fmap (second concat . unzip) $! mapM (\(e,t) -> mkExpr t e) (zip args argTys)

  fmap (,argDecls) $! case dstHType of
    SP _ dcArgPairs -> do
      let dcNameBS = Text.pack . name2String $ dcName dc
          dcI      = dcTag dc - 1
          dcArgs   = snd $ indexNote ($(curLoc) ++ "No DC with tag: " ++ show dcI) dcArgPairs dcI
      case compare (length dcArgs) (length argExprs) of
        EQ -> return (HW.DataCon dstHType (Just $ DC (dstHType,dcI)) argExprs)
        LT -> error $ $(curLoc) ++ "Over-applied constructor"
        GT -> error $ $(curLoc) ++ "Under-applied constructor"
    Product _ dcArgs ->
      case compare (length dcArgs) (length argExprs) of
        EQ -> return (HW.DataCon dstHType (Just $ DC (dstHType,0)) argExprs)
        LT -> error $ $(curLoc) ++ "Over-applied constructor"
        GT -> error $ $(curLoc) ++ "Under-applied constructor"
    Sum _ _ ->
      return (HW.DataCon dstHType (Just $ DC (dstHType,dcTag dc - 1)) [])
    Bool ->
      let dc' = case name2String $ dcName dc of
                 "True"  -> HW.Literal Nothing (BoolLit True)
                 "False" -> HW.Literal Nothing (BoolLit False)
                 _ -> error $ $(curLoc) ++ "unknown bool literal: " ++ show dc
      in  return dc'
    Bit ->
      let dc' = case name2String $ dcName dc of
                 "H" -> HW.Literal Nothing (BitLit H)
                 "L" -> HW.Literal Nothing (BitLit L)
                 _ -> error $ $(curLoc) ++ "unknown bit literal: " ++ show dc
      in return dc'
    Integer ->
      let dc' = case name2String $ dcName dc of
                  "S#" -> Nothing
                  "I#" -> Nothing
                  _    -> error $ $(curLoc) ++ "not a simple integer: " ++ show dc
      in return (HW.DataCon dstHType dc' argExprs)
    Vector 0 _ -> return (HW.DataCon dstHType Nothing          [])
    Vector 1 _ -> return (HW.DataCon dstHType (Just VecAppend) [head argExprs])
    Vector _ _ -> return (HW.DataCon dstHType (Just VecAppend) argExprs)

    _ -> error $ $(curLoc) ++ "mkDcApplication undefined for: " ++ show dstHType
