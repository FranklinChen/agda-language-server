{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-

Manage the J.TextDocumentDidChange messages to keep a local copy of the files
in the client workspace, so that tools at the server can operate on them.
-}
module Language.Haskell.LSP.VFS
  (
    VFS
  , VirtualFile(..)
  , openVFS
  , changeVFS
  , closeVFS

  -- * for tests
  , applyChange
  , sortChanges
  , deleteChars , addChars
  , changeChars
  , yiSplitAt
  ) where

import           Data.Text ( Text )
import           Data.List
#if __GLASGOW_HASKELL__ < 804
import           Data.Monoid
#endif
import qualified Data.Map as Map
import qualified Language.Haskell.LSP.TH.DataTypesJSON      as J
import           Language.Haskell.LSP.Utility
import qualified Yi.Rope as Yi

-- ---------------------------------------------------------------------
{-# ANN module ("hlint: ignore Eta reduce" :: String) #-}
{-# ANN module ("hlint: ignore Redundant do" :: String) #-}
-- ---------------------------------------------------------------------

data VirtualFile =
  VirtualFile {
      _version :: Int
    , _text    :: Yi.YiString
    } deriving (Show)

type VFS = Map.Map J.Uri VirtualFile

-- ---------------------------------------------------------------------

openVFS :: VFS -> J.DidOpenTextDocumentNotification -> IO VFS
openVFS vfs (J.NotificationMessage _ _ params) = do
  let J.DidOpenTextDocumentParams
         (J.TextDocumentItem uri _ version text) = params
  return $ Map.insert uri (VirtualFile version (Yi.fromText text)) vfs

-- ---------------------------------------------------------------------

changeVFS :: VFS -> J.DidChangeTextDocumentNotification -> IO VFS
changeVFS vfs (J.NotificationMessage _ _ params) = do
  let
    J.DidChangeTextDocumentParams vid (J.List changes) = params
    J.VersionedTextDocumentIdentifier uri version = vid
  case Map.lookup uri vfs of
    Just (VirtualFile _ str) -> do
      let str' = applyChanges str changes
      return $ Map.insert uri (VirtualFile version str') vfs
    Nothing -> do
      logs $ "haskell-lsp:changeVfs:can't find uri:" ++ show uri
      return vfs

-- ---------------------------------------------------------------------

closeVFS :: VFS -> J.DidCloseTextDocumentNotification -> IO VFS
closeVFS vfs (J.NotificationMessage _ _ params) = do
  let J.DidCloseTextDocumentParams (J.TextDocumentIdentifier uri) = params
  return $ Map.delete uri vfs

-- ---------------------------------------------------------------------
{-

data TextDocumentContentChangeEvent =
  TextDocumentContentChangeEvent
    { _range       :: Maybe Range
    , _rangeLength :: Maybe Int
    , _text        :: String
    } deriving (Read,Show,Eq)
-}

-- | Apply the list of changes, in descending order of range. Assuming no overlaps.
applyChanges :: Yi.YiString -> [J.TextDocumentContentChangeEvent] -> Yi.YiString
applyChanges str changes' = r
  where
    changes = sortChanges changes'
    r = foldl' applyChange str changes

-- ---------------------------------------------------------------------

applyChange :: Yi.YiString -> J.TextDocumentContentChangeEvent -> Yi.YiString
applyChange _ (J.TextDocumentContentChangeEvent Nothing Nothing str)
  = Yi.fromText str
applyChange str (J.TextDocumentContentChangeEvent (Just (J.Range fm _to)) (Just len) txt) =
  if txt == ""
    then -- delete len chars from fm
      deleteChars str fm len
    else -- add or change, based on length
      if len == 0
        then addChars str fm txt
             -- Note: changeChars comes from applyEdit, emacs will split it into a
             -- delete and an add
        else changeChars str fm len txt
applyChange str (J.TextDocumentContentChangeEvent (Just r@(J.Range (J.Position sl sc) (J.Position el ec))) Nothing txt)
  = applyChange str (J.TextDocumentContentChangeEvent (Just r) (Just len) txt)
    where len = Yi.length region
          (beforeEnd, afterEnd) = Yi.splitAtLine el str
          lastLine = Yi.take ec afterEnd
          lastLine' | sl == el = Yi.drop sc lastLine
                    | otherwise = lastLine
          (_beforeStart, afterStartBeforeEnd) = Yi.splitAtLine sl beforeEnd
          region = Yi.drop sc afterStartBeforeEnd <> lastLine'
applyChange str (J.TextDocumentContentChangeEvent Nothing (Just _) _txt)
  = str

-- ---------------------------------------------------------------------

deleteChars :: Yi.YiString -> J.Position -> Int -> Yi.YiString
deleteChars str (J.Position l c) len = str'
  where
    (before,after) = Yi.splitAtLine l str
    -- after contains the area we care about, starting with the selected line.
    -- Due to LSP zero-based coordinates
    beforeOnLine = Yi.take c after
    after' = Yi.drop (c + len) after
    str' = Yi.append before (Yi.append beforeOnLine after')

-- ---------------------------------------------------------------------

addChars :: Yi.YiString -> J.Position -> Text -> Yi.YiString
addChars str (J.Position l c) new = str'
  where
    (before,after) = Yi.splitAtLine l str
    -- after contains the area we care about, starting with the selected line.
    -- Due to LSP zero-based coordinates
    beforeOnLine = Yi.take c after
    after' = Yi.drop c after
    str' = Yi.concat [before, beforeOnLine, (Yi.fromText new), after']

-- ---------------------------------------------------------------------

changeChars :: Yi.YiString -> J.Position -> Int -> Text -> Yi.YiString
changeChars str (J.Position ls cs) len new = str'
  where
    (before,after) = yiSplitAt ls cs str
    after' = Yi.drop len after

    str' = Yi.concat [before, (Yi.fromText new), after']

-- changeChars :: Yi.YiString -> J.Position -> J.Position -> String -> Yi.YiString
-- changeChars str (J.Position ls cs) (J.Position le ce) new = str'
--   where
--     (before,_after) = yiSplitAt ls cs str
--     (_before,after) = yiSplitAt le ce str

--     str' = Yi.concat [before, (Yi.fromString new), after]
--     -- str' = Yi.concat [before]
--     -- str' = Yi.concat [_before]

-- ---------------------------------------------------------------------

yiSplitAt :: Int -> Int -> Yi.YiString -> (Yi.YiString, Yi.YiString)
yiSplitAt l c str = (before,after)
  where
    (b,a) = Yi.splitAtLine l str
    before = Yi.concat [b,Yi.take c a]
    after = Yi.drop c a


-- ---------------------------------------------------------------------

sortChanges :: [J.TextDocumentContentChangeEvent] -> [J.TextDocumentContentChangeEvent]
sortChanges changes = changes'
  where
    myComp (J.TextDocumentContentChangeEvent (Just r1) _ _)
           (J.TextDocumentContentChangeEvent (Just r2) _ _)
      = compare r2 r1 -- want descending order
    myComp _ _ = EQ
    changes' = sortBy myComp changes

-- ---------------------------------------------------------------------
