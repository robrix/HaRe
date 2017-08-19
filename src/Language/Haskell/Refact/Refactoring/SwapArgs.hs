{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Language.Haskell.Refact.Refactoring.SwapArgs (swapArgs) where

import qualified Data.Generics.Aliases as SYB
import qualified GHC.SYB.Utils         as SYB

import qualified Name                  as GHC
import qualified GHC

import qualified GhcModCore as GM (Options(..))
import Language.Haskell.Refact.API

import Data.Generics.Schemes

import Language.Haskell.GHC.ExactPrint.Types
import System.Directory



-- TODO: replace args with specific parameters
swapArgs :: RefactSettings -> GM.Options -> [String] -> IO [FilePath]
swapArgs settings opts args
  = do let fileName = args!!0
           row = (read (args!!1)::Int)
           col = (read (args!!2)::Int)
       absFileName <- canonicalizePath fileName
       runRefacSession settings opts (comp absFileName (row,col))


comp :: String -> SimpPos
     -> RefactGhc [ApplyRefacResult]
comp fileName (row, col) = do
       parseSourceFileGhc fileName
       parsed  <- getRefactParsed
       nm      <- getRefactNameMap

       let name = locToNameRdrPure nm (row, col) parsed

       case name of
            -- (Just pn) -> do refactoredMod@(_, (_t, s)) <- applyRefac (doSwap pnt pn) (Just modInfo) fileName
            (Just pn) -> do
                            (refactoredMod,_) <- applyRefac (doSwap pn) (RSFile fileName)
                            return [refactoredMod]
            Nothing   -> error "Incorrect identifier selected!"
       --if isFunPNT pnt mod    -- Add this back in ++ CMB +++
       -- then do
              --        rs <-if isExported pnt exps
       --               then  applyRefacToClientMods (doSwap pnt) fileName
       --               else  return []
       -- writeRefactoredFiles False (r:rs)
       -- else error "\nInvalid cursor position!"

       -- putStrLn (showToks t)
       -- writeRefactoredFiles False [refactoredMod]
       -- putStrLn ("here" ++ (SYB.showData SYB.Parser 0 mod))  -- $ show [fileName, beginPos, endPos]
       -- putStrLn "Completd"


doSwap :: GHC.Name -> RefactGhc ()
doSwap n1 = do
    parsed <- getRefactParsed
    logm $ "doSwap:parsed=" ++ SYB.showData SYB.Parser 0 parsed
    nm <- getRefactNameMap
    parsed' <- everywhereM (SYB.mkM (inMod nm)
                           `SYB.extM` (inExp nm)
                           `SYB.extM` (inType nm)
                           `SYB.extM` (inTypeDecl nm)
                           ) parsed
    -- this needs to be bottom up +++ CMB +++
    putRefactParsed parsed' emptyAnns
    return ()

    where
         -- 1. The definition is at top level...
#if __GLASGOW_HASKELL__ <= 710
         inMod nm ((GHC.FunBind ln2 infixity (GHC.MG matches p m1 m2) a locals tick)::GHC.HsBind GHC.RdrName)
#else
         inMod nm ((GHC.FunBind ln2 (GHC.MG (GHC.L lm matches) p m1 m2) a locals tick)::GHC.HsBind GHC.RdrName)
#endif
            | GHC.nameUnique n1 == GHC.nameUnique (rdrName2NamePure nm ln2)
                    = do logm ("inMatch>" ++ SYB.showData SYB.Parser 0 ln2 ++ "<")
                         newMatches <- updateMatches matches
#if __GLASGOW_HASKELL__ <= 710
                         return (GHC.FunBind ln2 infixity (GHC.MG newMatches p m1 m2) a locals tick)
#else
                         return (GHC.FunBind ln2 (GHC.MG (GHC.L lm newMatches) p m1 m2) a locals tick)
#endif
         inMod _ func = return func

         -- 2. All call sites of the function...
         inExp nm ((GHC.L l (GHC.HsApp (GHC.L e0 (GHC.HsApp e e1)) e2))::GHC.LHsExpr GHC.RdrName)
            | cond
                   -- =  update e2 e1 =<< update e1 e2 expr
                   = do
                       -- expr1 <- update e1 e2 expr
                       -- expr2 <- update e2 e1 expr1
                       -- return expr2
                       return (GHC.L l (GHC.HsApp (GHC.L e0 (GHC.HsApp e e2)) e1))
            where
              cond = case (expToNameRdr nm e) of
                Nothing -> False
                Just n2 -> GHC.nameUnique n2 == GHC.nameUnique n1
         inExp _ e = return e

         -- 3. Type signature...
#if __GLASGOW_HASKELL__ <= 710
         inType nm (GHC.L x (GHC.TypeSig [lname] types pns)::GHC.LSig GHC.RdrName)
#else
         inType nm (GHC.L x (GHC.TypeSig [lname] (GHC.HsIB ivs (GHC.HsWC wcs mwc types)))::GHC.LSig GHC.RdrName)
#endif
           | GHC.nameUnique (rdrName2NamePure nm lname) == GHC.nameUnique n1
                = do
                     logm $ "doSwap.inType"
                     let (t1:t2:ts) = tyFunToList types
                     -- t1' <- update t1 t2 t1
                     -- t2' <- update t2 t1 t2
                     let t1' = t2
                     let t2' = t1
#if __GLASGOW_HASKELL__ <= 710
                     return (GHC.L x (GHC.TypeSig [lname] (tyListToFun (t1':t2':ts)) pns))
#else
                     return (GHC.L x (GHC.TypeSig [lname] (GHC.HsIB ivs (GHC.HsWC wcs mwc (tyListToFun (t1':t2':ts))))))
#endif

#if __GLASGOW_HASKELL__ <= 710
         inType nm (GHC.L _x (GHC.TypeSig (n:ns) _types _)::GHC.LSig GHC.RdrName)
#else
         inType nm (GHC.L _x (GHC.TypeSig (n:ns) _types )::GHC.LSig GHC.RdrName)
#endif
           | GHC.nameUnique n1 `elem` (map (\n' -> GHC.nameUnique (rdrName2NamePure nm n')) (n:ns))
            = error "Error in swapping arguments in type signature: signature bound to muliple entities!"

         inType _ ty = return ty

         inTypeDecl nm (GHC.L l (GHC.SigD s)) = do
           (GHC.L _ s') <- inType nm (GHC.L l s)
           return (GHC.L l (GHC.SigD s'))
         inTypeDecl _ x = return x

#if __GLASGOW_HASKELL__ <= 710
         tyFunToList (GHC.L _ (GHC.HsForAllTy _ _ _ _ (GHC.L _ (GHC.HsFunTy t1 t2)))) = t1 : (tyFunToList t2)
#else
         tyFunToList (GHC.L _ (GHC.HsForAllTy _ (GHC.L _ (GHC.HsFunTy t1 t2)))) = t1 : (tyFunToList t2)
#endif
         tyFunToList (GHC.L _ (GHC.HsFunTy t1 t2)) = t1 : (tyFunToList t2)
         tyFunToList t = [t]

         tyListToFun []   = error "SwapArgs.tyListToFun" -- Keep the exhaustiveness checker happy
         tyListToFun [t1] = t1
         tyListToFun (t1:ts) = GHC.noLoc (GHC.HsFunTy t1 (tyListToFun ts))

         updateMatches [] = return []
         updateMatches ((GHC.L x (GHC.Match mfn pats nothing rhs)::GHC.LMatch GHC.RdrName (GHC.LHsExpr GHC.RdrName)):matches)
           = case pats of
               (p1:p2:ps) -> do
                                -- p1' <- update p1 p2 p1
                                -- p2' <- update p2 p1 p2
                                let p1' = p2
                                let p2' = p1
                                matches' <- updateMatches matches
                                return ((GHC.L x (GHC.Match mfn (p1':p2':ps) nothing rhs)):matches')
               [p] -> return [GHC.L x (GHC.Match mfn [p] nothing rhs)]
               []  -> return [GHC.L x (GHC.Match mfn [] nothing rhs)]


