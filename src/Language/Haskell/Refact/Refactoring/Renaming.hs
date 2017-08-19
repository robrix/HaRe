{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Language.Haskell.Refact.Refactoring.Renaming
  ( rename
  , compRename
  ) where

import qualified Data.Generics         as SYB
import qualified GHC.SYB.Utils         as SYB

import qualified GHC
import qualified Name                  as GHC
-- import qualified OccName               as GHC
import qualified Outputable            as GHC
import qualified RdrName               as GHC

import Control.Monad
import Data.Generics.Strafunski.StrategyLib.StrategyLib hiding (liftIO,MonadPlus,mzero)
import Data.List
import Language.Haskell.GHC.ExactPrint
import Language.Haskell.GHC.ExactPrint.Utils
import Language.Haskell.Refact.API
import System.Directory
import qualified GhcModCore as GM (Options(..))
import qualified Data.Map as Map

{-# ANN module "HLint: ignore Redunant do" #-}
{-# ANN module "HLint: ignore Eta reduce" #-}

{-This refactoring renames an indentifier to a user-specified name.

  Conditions:
    a: the indentifier to be renamed should be defined in the current module.
    b. the user provided name should be a valid name with regard to the name
       space of the identifier.
    c. the new name should not change the semantics of the program, and
       should not cause any name clash/conflict/ambiguity problem in the
       program.

  Attention:
    a. To select an identifier, stop the cursor at the beginning position of
       any occurrence of the identifier.
    b. Renaming a qualified name will not change the qualifier;
    c. In current module, an unqualified name won't become qualified after
       renaming; but, in client modules, an unqualified name might become
       qualified after renaming to avoid ambiguity prolem. In case the new
       name, say 'f', will cause ambiguous occurrence in the current module
       (this is because the identifier 'f' is imported from other modules),
       the user will be prompted to choose another new name or qualify the
       use of 'f' before doing renaming.
  -}

{-In the current implementation, we assume that module name is same as
the file name, but we should keep in mind that people also use unnamed
modules.
-}

-- | Rename the given identifier.
rename :: RefactSettings
       -> GM.Options
       -> FilePath
       -> String
       -> SimpPos
       -> IO [FilePath]
rename settings opts fileName newName (row,col) = do
  absFileName <- canonicalizePath fileName
  runRefacSession settings opts (compRename absFileName newName (row,col))

-- | Body of the refactoring
compRename :: FilePath -> String -> SimpPos -> RefactGhc [ApplyRefacResult]
compRename fileName newName (row,col) = do
    logm $ "Renaming.comp: (fileName,newName,(row,col))=" ++ show (fileName,newName,(row,col))
    parseSourceFileGhc fileName

    parsed       <- getRefactParsed
    modu         <- getModule
    targetModule <- getRefactTargetModule
    nm           <- getRefactNameMap

    -- logDataWithAnns "parsed" parsed

    let modName = maybe (GHC.mkModuleName "Main") fst $ getModuleName parsed

    case locToRdrName (row, col) parsed of
        Just pn'@(GHC.L l rdrName) -> do
            let n = rdrName2NamePure nm pn'
                pn = GHC.L l n
            logm $ "Renaming:(n,modu)=" ++ showGhc (n,modu)

            let occName = GHC.rdrNameOcc rdrName
            let rdrNameStr = GHC.occNameString occName

            logm $ "Renaming:original occName attributes:" ++ showGhc occName ++ occAttributes occName

            unless (nameToString n /= newName) $ error "The new name is same as the old name"
            unless (isValidNewName n rdrNameStr newName) $ error $ "Invalid new name:" ++ newName ++ "!"

            let defineMod = case GHC.nameModule_maybe n of
                             Just mn -> GHC.moduleName mn
                             Nothing -> modName

            unless (defineMod == modName) . error $ mconcat [ "This identifier is defined in module "
                                                            , GHC.moduleNameString defineMod
                                                            , ", please do renaming in that module!"
                                                            ]
            when (isMainModule modu && showGhcQual pn == "Main.main") $
                error "The 'main' function defined in a 'Main' module should not be renamed!"

            newNameGhc <- mkNewGhcName (Just modu) newName
            (refactoredMod, nIsExported) <- applyRefac (doRenaming pn rdrNameStr newName newNameGhc modName)
                                           RSAlreadyLoaded

            logm $ "Renaming:nIsExported=" ++ show nIsExported
            if nIsExported  --no matter whether this pn is used or not.
                then do clients <- clientModsAndFiles targetModule
                        logm ("Renaming: clients=" ++ show clients) -- ++AZ++ debug
                        refactoredClients <- mapM (renameInClientMod n newName newNameGhc) clients
                        return $ refactoredMod : concat refactoredClients
                else return [refactoredMod]
        Nothing -> error "Invalid cursor position!"


-- ---------------------------------------------------------------------

condChecking :: (SYB.Data t)
              => GHC.Name -> String -> GHC.Name -> GHC.ModuleName
              -> t
              -> Bool -> Bool -> RefactGhc ()
condChecking oldPN newName newNameGhc modName ast existChecking exportChecking = do
  condChecking1 oldPN newName newNameGhc modName ast existChecking exportChecking
  nm <- getRefactNameMap
  condChecking2 nm oldPN newName ast

-- ---------------------------------------------------------------------

-- |Actually do the renaming, split into the various things that can
-- be renamed. Returns True if the name is exported
doRenaming :: GHC.Located GHC.Name -> String -> String -> GHC.Name -> GHC.ModuleName -> RefactGhc Bool

--------Rename a value variable name--------------------------------
doRenaming pn@(GHC.L _ oldn) rdrNameStr newNameStr newNameGhc modName = do
    logm $ "doRenaming:(pn,rdrNameStr,newNameStr) = (" ++ intercalate "," [showGhc pn,rdrNameStr,newNameStr] ++ ")"
    parsed <- getRefactParsed
    nm <- getRefactNameMap

    if GHC.isVarName oldn
      then do
        decls <- liftT $ hsDeclsGeneric parsed
        if isDeclaredInRdr nm oldn decls
          then do
            logm "doRenaming:renameInMod isDeclaredInRdr True"
            condChecking oldn newNameStr newNameGhc modName parsed True True
            parsed' <- renameTopLevelVarName oldn newNameStr newNameGhc True
            putRefactParsed parsed' mempty
            isExported oldn
          else do
            logm "doRenaming: not declared at the top level"
            condChecking oldn newNameStr newNameGhc modName parsed False False
            parsed' <- renameTopLevelVarName oldn newNameStr newNameGhc False
            putRefactParsed parsed' mempty
            return False -- Not exported
      else do
        logm "doRenaming:not isVarName"
        condChecking oldn newNameStr newNameGhc modName parsed True True
        parsed' <- renameTopLevelVarName oldn newNameStr newNameGhc True
        putRefactParsed parsed' mempty
        isExported oldn

-- ---------------------------------------------------------------------
{-
From Huiqing Li thesis

p 75

The second part is defined in the local function condChecking2. This function
performs a top-down traversal of the AST until it reaches a syntax entity, say
E, such that E contains the declaration of x , and all the references to the x
in question. E could be the Haskell module, a declaration defining a function, a
declaration defining a pattern binding, an expression, a branch in a
case-expression, or a do statement. The syntax phrase E forms the context for
condition checking, and at the place where it is reached, the function
condChecking' is called, and the traversal terminates.

Inside the function condChecking' , three conditions are checked.

  - The first condition ensures that the new name does not exist in the same
    binding group, where the function declaredVarsInSameGroup (from the API) is
    used to fetch all the variable names declared in the same binding group
    where x [AZ: The old name] is declared.

  - The second condition checks whether the new name will intervene between the
    existing uses of y [AZ: the new name] and its bindings, where function
    hsFreeAndDeclaredNames is used to fetch the free and declared variables in
    the argument syntax phrase.

  - The third condition checks whether the new name is declared somewhere
    between the declaration of identifier to be renamed and one of its
    call-sites, and function hsVisibleNames is used to collect the names which
    are declared in the given syntax phrase and visible to one of the call-sites
    of the identifier.

In the local functions, including inMatch, inPattern, and inAlt , the values
defaultPNT and/or [ ] are used to shadow those variables declared in the same
syntax phrase but in an outer scope.

-}

-- |Some non-trivial condition checking.
-- Returns on success, throws an error on check failure
condChecking2 :: (SYB.Data t) => NameMap -> GHC.Name -> String -> t -> RefactGhc ()
condChecking2 nm oldPN newName t = do
  void $ applyTP (once_buTP (failTP `adhocTP` inMod
                             `adhocTP` inMatch
                             `adhocTP` inExp
                             `adhocTP` inStmts
                             `adhocTP` inDataDefn
                             `adhocTP` inConDecl
                             `adhocTP` inTyClDecl
                     )) t
  where
    -- return True if oldPN is declared by t.
    isDeclaredBy t = isDeclaredBy' t
      where
        isDeclaredBy' t
          = do (_ , d) <- hsFreeAndDeclaredPNs t
               -- logDataWithAnns "isDeclaredBy:t" t
               logm $ "isDeclaredBy:d=" ++ showGhc d
               return (oldPN `elem` d )

    -- The name is a top-level identifier
    inMod (parsed :: GHC.ParsedSource) = do
      decls <- liftT $ hsDeclsGeneric parsed
      isDeclared <- isDeclaredBy decls
      logm $ "Renaming.condChecking2.inMod:isDeclared=" ++ show isDeclared
      if isDeclared
           then condChecking' parsed
           else mzero

    -- The name is declared in a function definition.
#if __GLASGOW_HASKELL__ <= 710
    inMatch (GHC.Match f@(Just (ln,_)) pats  mtype (GHC.GRHSs rhs ds)
             ::GHC.Match GHC.RdrName (GHC.LHsExpr GHC.RdrName)) = do
#else
    inMatch (GHC.Match f@(GHC.FunBindMatch ln isInfix) pats  mtype (GHC.GRHSs rhs ds)
             ::GHC.Match GHC.RdrName (GHC.LHsExpr GHC.RdrName)) = do
#endif
      isDeclaredPats <- isDeclaredBy pats
      isDeclaredDs   <- isDeclaredBy ds
      logm $ "Renaming.condChecking2.inMatch:isDeclared=" ++ show (isDeclaredPats,isDeclaredDs)
      if isDeclaredPats
        then condChecking' (GHC.Match f pats mtype (GHC.GRHSs rhs ds))
        else if isDeclaredDs
          then condChecking' (GHC.Match f []  mtype (GHC.GRHSs rhs ds))
          else mzero
    inMatch _ = mzero

    -- The name is declared in a expression.
    inExp expr@((GHC.L _ (GHC.HsLet ds e)):: GHC.LHsExpr GHC.RdrName) = do
      isDeclaredDs   <- isDeclaredBy ds
      -- logm $ "inExp.HsLet:isDeclaredDs=" ++ show isDeclaredDs
      if isDeclaredDs
        then condChecking' expr
        else mzero
    inExp expr@((GHC.L _ (GHC.HsDo _ ds e)):: GHC.LHsExpr GHC.RdrName) = do
      isDeclared   <- isDeclaredBy ds
      -- logDataWithAnns "inExp.HsDo:expr" expr
      logm $ "inExp.HsDo:isDeclared=" ++ show isDeclared
      if isDeclared
        then condChecking' expr
        else mzero
    inExp _ = mzero
{-
    -- The name is declared in a expression.
    inExp (exp@(Exp (HsLambda pats body))::HsExpP)
      |isDeclaredBy pats
      = condChecking' exp
    inExp (exp@(Exp (HsLet ds e)):: HsExpP)
      |isDeclaredBy ds
      = condChecking' exp
    inExp _ = mzero

    -- The name is declared in a case alternative.
    inAlt (alt@(HsAlt loc p rhs ds)::HsAltP)
      |isDeclaredBy p
      = condChecking' alt
      |isDeclaredBy ds
      = condChecking' (HsAlt loc defaultPat rhs ds)
      |otherwise = mzero

-}

    inStmts (stmt@(GHC.L _ (GHC.LetStmt binds)) :: GHC.LStmt GHC.RdrName (GHC.LHsExpr GHC.RdrName)) = do
      isDeclared   <- isDeclaredBy binds
      if isDeclared
        then condChecking' stmt
        else mzero
    inStmts _ = mzero

    inDataDefn dd@(GHC.HsDataDefn _ ctxt mctype mkindsig cons derivs :: GHC.HsDataDefn GHC.RdrName) = do
      declared <- isDeclaredBy cons
      if declared
        then condChecking' dd
        else mzero

    -- The name is declared in a ConDecl
#if __GLASGOW_HASKELL__ <= 710
    inConDecl (cd@(GHC.ConDecl ns _expr (GHC.HsQTvs _ns bndrs) ctxt
                               dets res _ depc_syntax) :: GHC.ConDecl GHC.RdrName ) =
      case res of
        GHC.ResTyGADT ls typ -> do
          declared <- isDeclaredBy ns
          if declared
            then condChecking' cd
            else mzero
        GHC.ResTyH98 -> do
          declaredn <- isDeclaredBy ns
          declaredd <- isDeclaredBy dets
          if declaredn || declaredd
            then condChecking' cd
            else mzero
#else
    inConDecl cd@(GHC.ConDeclGADT ns _ _ :: GHC.ConDecl GHC.RdrName) = do
      declared <- isDeclaredBy ns
      -- TODO: what about condChecking' ?
      if declared
        then condChecking' cd
        else mzero
    inConDecl cd@(GHC.ConDeclH98 n _ _ dets _) = do
      declaredn <- isDeclaredBy n
      declaredd <- isDeclaredBy dets
      if declaredn || declaredd
        then condChecking' cd
        else mzero
#endif


#if __GLASGOW_HASKELL__ <= 710
    inTyClDecl dd@(GHC.DataDecl ln (GHC.HsQTvs _ns tyvars) defn _ :: GHC.TyClDecl GHC.RdrName) = do
#else
    inTyClDecl dd@(GHC.DataDecl ln tyvars defn _ _ :: GHC.TyClDecl GHC.RdrName) = do
#endif
      declared <- isDeclaredBy dd
      declaredtv <- isDeclaredBy tyvars
      -- logm $ "condChecking2:inTyClDecl:(declared,declaredtv)=" ++ show (declared,declaredtv)
      if declared || declaredtv
        then condChecking' dd
        else mzero
    inTyClDecl _ = mzero

    -- ---------------------------------

    condChecking' t = do
      sameGroupDecls <- declaredVarsInSameGroup nm oldPN t
      -- logm $ "condChecking':sameGroupDecls=" ++ showGhc sameGroupDecls
      when (newName `elem` sameGroupDecls)
            $ error "The new name exists in the same binding group!"
      (f, d) <- hsFreeAndDeclaredNameStrings t
      when (newName `elem` f) $ error "Existing uses of the new name will be captured!"
      -- fetch all the declared variables in t that
      -- are visible to the places where oldPN occurs.
      ds <- hsVisibleNamesRdr oldPN t
      -- logm $ "Renaming.condChecking':t=" ++ showGhc t
      -- logm $ "Renaming.condChecking':ds=" ++ showGhc ds
      when (newName `elem` ds) $ error "The new name will cause name capture!"
      return t

declaredVarsInSameGroup :: (SYB.Data t) => NameMap -> GHC.Name -> t -> RefactGhc [String]
declaredVarsInSameGroup nm n t = do
  -- simplification: we know we are doing a bottom-up process, stopping where
  -- the name is first declared. Hence the declaration has to be at the current
  -- level of @t@
  decls <- liftT $ hsDeclsGeneric t
  let declared = nub $ map showGhc $ getDeclaredVarsRdr nm decls
  return $ filter (/= showGhc n) declared


-- ---------------------------------------------------------------------

condChecking1 :: (SYB.Data t)
              => GHC.Name -> String -> GHC.Name -> GHC.ModuleName
              -> t
              -> Bool -> Bool -> RefactGhc ()
condChecking1 oldPN newName newNameGhc modName ast existChecking exportChecking = do
    -- logm $ "condChecking1:(existChecking, exportChecking)=" ++ show (existChecking, exportChecking)
    -- parsed <- getRefactParsed
    nm     <- getRefactNameMap
     -- f' contains names imported from other modules;
     -- d' contains the top level names declared in this module;
    let (FN f', DN d') = hsFDsFromInsideRdr nm ast
     --filter those qualified free variables in f'
    let (f, _d) = (map nameToString f', map nameToString d')

    let newNameStr = nameToString newNameGhc

    scopeClashNames <- inScopeNames newName

    -- Another implementation option is to add the qualifier to newName automatically.
    when (nonEmptyList $ intersect scopeClashNames f') .
        error $ mconcat [ "The new name will cause an ambiguous occurrence problem, "
                        , "please select another new name or qualify the use of '"
                        , newName ++ "' before renaming!\n"]

    parsed <- getRefactParsed
    let dns = map nameToString $ filter (sameNameSpace oldPN) d'
    -- only check the declared names here
    when (existChecking && newNameStr `elem` dns \\ [nameToString oldPN]) $ do
        logm $ "condChecking1:dns=" ++ intercalate "," dns
        let m = Map.fromList $ map (\n -> (nameToString n,n)) $ filter (sameNameSpace oldPN) d'
            Just dupN = Map.lookup newNameStr m
        logm $ "condChecking1:dupN=" ++ showGhcQual dupN

        case definingTyClDeclsNames nm [dupN] parsed of
          [] -> do
            --the same name has been declared in this module.
            error $ mconcat ["Name '", newName, "' already exists in this module\n"]
          ds -> do
            -- TODO: Check that we do not in fact have a name clash. It is only
            -- safe if we are changing a field name where the name clashes with
            -- a field name in another constructor
            return ()

    when (exportChecking && causeNameClashInExports nm oldPN newNameGhc modName parsed) $
        error "The new name will cause conflicting exports, please select another new name!"

    causeAmbiguity <- causeAmbiguityInExports oldPN newNameGhc
    when (exportChecking && causeAmbiguity) . -- causeAmbiguityInExports oldPN  newNameGhc {- inscps -} renamed
        error $ mconcat ["The new name will cause ambiguity in the exports of module '"
                        , show modName
                        , "' , please select another name!"]

    DN ds' <- hsVisibleDsRdr nm oldPN ast
    let dns2 = map nameToString $ filter (sameNameSpace oldPN) ds'
    when (existChecking && newName `elem` nub (dns2 `union` f) \\ [nameToString oldPN]) .
        error $ mconcat [ "Name '", newName, "' already exists, or renaming '", nameToString oldPN,  "' to '"
                        , newName, "' will change the program's semantics!\n"]

-- ---------------------------------------------------------------------

renameTopLevelVarName :: GHC.Name -> String -> GHC.Name
                      -> Bool -> RefactGhc GHC.ParsedSource
renameTopLevelVarName oldPN newName newNameGhc exportChecking = do
    parsed <- getRefactParsed
    isInScopeUnqual <- isInScopeAndUnqualifiedGhc newName (Just newNameGhc)
    let qual = if exportChecking && isInScopeUnqual then Qualify else PreserveQualify
    renamePN oldPN newNameGhc qual parsed

-- ---------------------------------------------------------------------

renameLocalVarName :: (SYB.Data t) => GHC.Name -> String -> GHC.Name -> t -> RefactGhc t
renameLocalVarName oldPN newName newNameGhc t = do
  nm <- getRefactNameMap
  let qual = PreserveQualify
  (f,d) <- hsFDNamesFromInsideRdr t
  if elem newName (d \\ [showGhc oldPN])  --only check the declared names here.
    then error ("Name '"++newName++"'  already existed\n")
    else do -- get all of those declared names visible to oldPN at where oldPN is used.
            ds <- hsVisibleNamesRdr oldPN t
            -- '\\[pNtoName oldPN]' handles the case in which the new name is same as the old name
            if elem newName ((nub (ds `union` f)) \\[showGhc oldPN])
              then error ("Name '"++newName++"'  already existed, or rename '"
                           ++showGhc oldPN++ "' to '"++newName++
                          "' will change the program's semantics!\n")
              else renamePN oldPN newNameGhc qual t

------------------------------------------------------------------------

renameInClientMod :: GHC.Name -> String -> GHC.Name -> TargetModule
                  -> RefactGhc [ApplyRefacResult]
renameInClientMod oldPN newName newNameGhc targetModule = do
    logm $ "renameInClientMod:(oldPN,newNameGhc,targetModule)=" ++ showGhc (oldPN,newNameGhc,targetModule) -- ++AZ++
    logm $ "renameInClientMod:(newNameGhc module)=" ++ showGhc (GHC.nameModule newNameGhc) -- ++AZ++
    getTargetGhc targetModule

    modName <- getRefactModuleName
    parsed  <- getRefactParsed
    nm      <- getRefactNameMap

    -- We need to find the old name in the module, and get it as a
    -- GHC.Name to know what to look for in the call to renamePN', as it
    -- checks the GHC.nameUnique value.
    newNames <- equivalentNameInNewMod oldPN
    logm $ "renameInClientMod:(newNames)=" ++ showGhcQual newNames

    let newNames' = filter (sameNameSpace oldPN) newNames
    case newNames' of
        []        -> return []
        [oldName] | findNameInRdr nm oldName parsed -> doRenameInClientMod nm oldName modName parsed
                  | otherwise -> do
                      logm "renameInClientMod: name not present in module, returning"
                      return []
        -- ns -> error $ "HaRe: renameInClientMod: could not find name to replace, got:" ++ showGhcQual ns
        ns -> error $ "HaRe: renameInClientMod: could not find name to replace, got:"
          ++ (showGhcQual $ map (\n -> (n,GHC.occNameSpace $ GHC.nameOccName n)) ns)

  where
    doRenameInClientMod nm oldNameGhc modName parsed = do
        -- There are two different tests we need to do here
        -- 1. Does the new name clash with some existing name in the
        --    client mod, in which case it must be qualified
        -- 2. Is the new name module imported qualified, and so needs to
        --    be qualified in the replacement, according to the import
        isInScopeUnqual    <- isInScopeAndUnqualifiedGhc (nameToString oldPN) Nothing
        isInScopeUnqualNew <- isInScopeAndUnqualifiedGhc newName              Nothing
        logm $ "renameInClientMod: (isInScopeAndUnqual,isInScopeUnqualNew)=" ++
               show (isInScopeUnqual, isInScopeUnqualNew) -- ++AZ++

        if isInScopeUnqualNew -- ++AZ++: should this be negated?
            then do
                (refactoredMod, _) <- applyRefac (refactRenameSimple oldNameGhc newName newNameGhc Qualify)
                                                RSAlreadyLoaded
                return [refactoredMod]
            else do
                when (causeNameClashInExports nm oldPN newNameGhc modName parsed) .
                    error $ mconcat [ "The new name will cause conflicting exports in module"
                                    , show newName, ", please select another name!"]
                (refactoredMod, _) <- applyRefac (refactRenameComplex oldNameGhc newName newNameGhc)
                                                RSAlreadyLoaded
                -- TODO: implement rest of this
                return [refactoredMod]

    refactRenameSimple :: GHC.Name -> String -> GHC.Name -> HowToQual -> RefactGhc ()
    refactRenameSimple old newStr new useQual = do
        logm $ "refactRenameSimple:(old,newStr,new,useQual)=" ++ showGhc (old, newStr, new, useQual)
        qualifyTopLevelVar newStr
        parsed <- renamePN old new useQual =<< getRefactParsed
        putRefactParsed parsed mempty
        return ()

    refactRenameComplex :: GHC.Name -> String -> GHC.Name -> RefactGhc ()
    refactRenameComplex old new newGhc = do
        logm $ "refactRenameComplex:(old,new,newGhc)=" ++ showGhc (old, new, newGhc)
        qualifyTopLevelVar new
        worker old new newGhc

    qualifyTopLevelVar :: String -> RefactGhc ()
    qualifyTopLevelVar new = do
        toQualify <- inScopeNames new
        logm $ "renameInClientMod.qualifyTopLevelVar:new:toQualify=" ++ show new ++ ":" ++ showGhc toQualify
        mapM_ qualifyToplevelName toQualify
        return ()

    worker :: GHC.Name -> String -> GHC.Name -> RefactGhc ()
    worker oldPN' newName' newNameGhc' = do
        logm $ "renameInClientMod.worker:(oldPN',newName',newNameGhc')=" ++
               showGhc (oldPN', newName', newNameGhc')
        isInScopeUnqualNew <- isInScopeAndUnqualifiedGhc newName' Nothing
        vs <- hsVisibleNamesRdr oldPN' =<< getRefactParsed  -- Does this check names other than variable names?
        logm $ "renameInClientMod.worker:(vs,oldPN',isInScopeUnqualNew)=" ++
               showGhc (vs, oldPN', isInScopeUnqualNew)

        -- logParsedSource "worker:parsed"

        let qual = if (newName' `elem` (nub vs \\ [nameToString oldPN']) || isInScopeUnqualNew)
                      then Qualify
                      else PreserveQualify
        parsed <- renamePN oldPN' newNameGhc' qual =<< getRefactParsed
        putRefactParsed parsed mempty
        return ()

-- ---------------------------------------------------------------------

causeAmbiguityInExports :: GHC.Name -> GHC.Name -> RefactGhc Bool
causeAmbiguityInExports old newName {- inscps -} = do
    (GHC.L _ (GHC.HsModule _ exps _imps _decls _ _)) <- getRefactParsed
    isInScopeUnqual <- isInScopeAndUnqualifiedGhc (nameToString old) Nothing
    let usedUnqual = usedWithoutQualR newName exps
    logm $ "causeAmbiguityInExports:(isInScopeUnqual,usedUnqual)" ++ show (isInScopeUnqual, usedUnqual)
    return (isInScopeUnqual && usedUnqual)

-- ---------------------------------------------------------------------

isValidNewName :: GHC.Name -> String -> String -> Bool
isValidNewName oldName rdrNameStr newName = res
  where
    doTest :: Bool -> Bool -> String -> Bool
    doTest isCategory isRightType errStr = not isCategory || isRightType || error errStr

    tyconOk = doTest (GHC.isTyConName oldName) (isConId newName) "Invalid type constructor/class name!"

    dataConOk = doTest (GHC.isDataConName oldName) (isConId newName) "Invalid data constructor name!"

    tyVarOk = doTest (GHC.isTyVarName oldName) (isVarId newName) "Invalid type variable name!"

    oldName' = rdrNameStr
    matchNamesOk
        | {- GHC.isValName oldName || -} GHC.isVarName oldName
        = if isVarId oldName' && not (isVarId newName)
              then error "The new name should be an identifier!"
              else if isOperator oldName' && not (isOperator newName)
                       then error "The new name should be an operator!"
                       else (isVarId oldName' && isVarId newName)
                         || (isOperator oldName' && isOperator newName)
                         || (error $ "Invalid new name!" ++ show ( oldName', newName
                                                                , isVarId oldName'
                                                                , isVarId newName
                                                                , isOperator oldName'
                                                                , isOperator newName ))
        | otherwise = True

    res = tyconOk && dataConOk {- && fieldOk && instanceOk -} && tyVarOk && matchNamesOk

-- EOF
