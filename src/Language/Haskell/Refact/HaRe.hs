{-# LANGUAGE ScopedTypeVariables #-}
module Language.Haskell.Refact.HaRe
 (
 -- * Data Structures
   RefactSettings(..)
 , VerboseLevel (..)
 , defaultSettings
 , SimpPos
 -- ** Re-exported from ghc-mod
 , GM.Options(..)
 , GM.defaultOptions

 -- * Refactorings
 , ifToCase,        compIfToCase
 , duplicateDef,    compDuplicateDef
 , liftToTopLevel,  compLiftToTopLevel
 , liftOneLevel,    compLiftOneLevel
 , demote,          compDemote
 , rename,          compRename
 , addOneParameter, compAddOneParameter
 , rmOneParameter,  compRmOneParameter
 , deleteDef,       compDeleteDef
 -- , swapArgs
 , roundTrip
-- , introduceTypeSyn
-- , unwrapTypeSyn
 , genApplicative, compGenApplicative
 )
where

import Language.Haskell.Refact.Refactoring.AddRmParam
import Language.Haskell.Refact.Refactoring.Case
import Language.Haskell.Refact.Refactoring.DupDef
import Language.Haskell.Refact.Refactoring.MoveDef
import Language.Haskell.Refact.Refactoring.Renaming
--import Language.Haskell.Refact.Refactoring.IntroduceTypeSyn
import Language.Haskell.Refact.Refactoring.DeleteDef
--import Language.Haskell.Refact.Refactoring.UnwrapTypeSyn
import Language.Haskell.Refact.Refactoring.GenApplicative
-- import Language.Haskell.Refact.Refactoring.SwapArgs
import Language.Haskell.Refact.Refactoring.RoundTrip
import Language.Haskell.Refact.Utils.Monad
import Language.Haskell.Refact.Utils.Types
import qualified GhcModCore as GM (Options(..),defaultOptions)
