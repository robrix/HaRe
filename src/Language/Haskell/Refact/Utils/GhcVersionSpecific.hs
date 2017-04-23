{-# LANGUAGE CPP #-}

-- |This module contains all the code that depends on a specific
-- version of GHC, and should be the only one requiring CPP
module Language.Haskell.Refact.Utils.GhcVersionSpecific
  (
    ppType
  , setGhcContext
  , showGhcQual
  )
  where

import qualified DynFlags      as GHC
import qualified GHC           as GHC
import qualified Outputable    as GHC



-- ---------------------------------------------------------------------

ppType :: GHC.Type -> String
#if __GLASGOW_HASKELL__ > 800
ppType x = GHC.renderWithStyle GHC.unsafeGlobalDynFlags (GHC.pprParendType x) (GHC.mkUserStyle GHC.unsafeGlobalDynFlags GHC.neverQualify GHC.AllTheWay)
#elif __GLASGOW_HASKELL__ > 706
ppType x = GHC.renderWithStyle GHC.unsafeGlobalDynFlags (GHC.pprParendType x) (GHC.mkUserStyle GHC.neverQualify GHC.AllTheWay)
#elif __GLASGOW_HASKELL__ > 704
ppType x = GHC.renderWithStyle GHC.tracingDynFlags (GHC.pprParendType x) (GHC.mkUserStyle GHC.neverQualify GHC.AllTheWay)
#else
ppType x = GHC.renderWithStyle                     (GHC.pprParendType x) (GHC.mkUserStyle GHC.neverQualify GHC.AllTheWay)
#endif

-- ---------------------------------------------------------------------

setGhcContext :: GHC.GhcMonad m => GHC.ModSummary -> m ()
#if __GLASGOW_HASKELL__ > 704
setGhcContext modSum = GHC.setContext [GHC.IIModule (GHC.moduleName $ GHC.ms_mod modSum)]
#else
setGhcContext modSum = GHC.setContext [GHC.IIModule (                 GHC.ms_mod modSum)]
#endif

-- ---------------------------------------------------------------------

showGhcQual :: (GHC.Outputable a) => a -> String
showGhcQual x = GHC.showSDocForUser GHC.unsafeGlobalDynFlags GHC.alwaysQualify $ GHC.ppr x

