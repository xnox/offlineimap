{- offlineimap component
Copyright (C) 2002-2008 John Goerzen <jgoerzen@complete.org>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{-
The OfflineIMAP v6 algorithm worked like this:

call remoterepos.syncfoldersto(localrepos, [statusrepos])

for each folder, call 
 syncfolder(remotename, remoterepos, remotefolder, localrepos, statusrepos, quick)
   this:
   sets localfolder = local folder
   adds localfolder to mbnames
   sets statusfolder = status folder
   if localfolder.getuidvalidity() == None, removes anything in statusfolder
   
   statusfolder.cachemessagelist()

   localfolder.cachemessagelist()

   Check UID validity
   Save UID validity

   remotefolder.cachemessagelist()

   if not statusfolder.isnewfolder():
        # Delete local copies of remote messages.  This way,
        # if a message's flag is modified locally but it has been
        # deleted remotely, we'll delete it locally.  Otherwise, we
        # try to modify a deleted message's flags!  This step
        # need only be taken if a statusfolder is present; otherwise,
        # there is no action taken *to* the remote repository.
        remotefolder.syncmessagesto_delete(localfolder, [localfolder,
                                                         statusfolder])
        localfolder.syncmessagesto(statusfolder, [remotefolder, statusfolder])

   # Synchroonize remote changes
   remotefolder.syncmessagesto(localfolder, [localfolder, statusfolder])

   # Make sure the status folder is up-to-date.
   ui.syncingmessages(localrepos, localfolder, statusrepos, statusfolder)
   localfolder.syncmessagesto(statusfolder)
   statusfolder.save()
   localrepos.restore_atime()
   
        

call forgetfolders on local and remote
-}

module Data.Syncable where
import qualified Data.Map as Map

type SyncCollection k = Map.Map k ()

data (Eq k, Ord k, Show k) => 
    SyncCommand k = 
           DeleteItem k
         | CopyItem k
    deriving (Eq, Ord, Show)

{- | Perform a bi-directional sync.  Compared to the last known state of
the child, evaluate the new states of the master and child.  Return a list of
changes to make to the master and list of changes to make to the child to
bring them into proper sync.

This relationship should hold:

>let (masterCmds, childCmds) = syncBiDir masterState childState lastChildState
>unaryApplyChanges masterState masterCmds == 
> unaryApplyChanges childState childCmds
-}
syncBiDir :: (Ord k, Show k) =>
            SyncCollection k  -- ^ Present state of master
         -> SyncCollection k  -- ^ Present state of child
         -> SyncCollection k  -- ^ Last state of child
         -> ([SyncCommand k], [SyncCommand k]) -- ^ Changes to make to (master, child)
syncBiDir masterstate childstate lastchildstate =
    (masterchanges, childchanges)
    where masterchanges = (map DeleteItem .
                          findDeleted childstate masterstate $ lastchildstate)
                          ++ 
                          (map CopyItem .
                           findAdded childstate masterstate $ lastchildstate)
          childchanges = (map DeleteItem . 
                          findDeleted masterstate childstate $ lastchildstate)
                         ++
                         (map CopyItem .
                          findAdded masterstate childstate $ lastchildstate)

{- | Returns a list of keys that exist in state2 and lastchildstate
but not in state1 -}
findDeleted :: Ord k =>
               SyncCollection k -> SyncCollection k -> SyncCollection k ->
               [k]
findDeleted state1 state2 lastchildstate =
    Map.keys . Map.difference (Map.intersection state2 lastchildstate) $ state1

{- | Returns a list of keys that exist in state1 but in neither 
state2 nor lastchildstate -}
findAdded :: (Ord k, Eq k) =>
               SyncCollection k -> SyncCollection k -> SyncCollection k ->
               [k]
findAdded state1 state2 lastchildstate =
    Map.keys . Map.difference state1 . Map.union state2 $ lastchildstate

{- | Returns a list of keys that exist in the passed state -}
filterKeys :: (Ord k) => 
              SyncCollection k -> [k] -> [k]
filterKeys state keylist =
    concatMap keyfunc keylist
    where keyfunc k =
              case Map.lookup k state of
                Nothing -> []
                Just _ -> [k]

{- | Apply the specified changes to the given SyncCollection.  Returns
a new SyncCollection with the changes applied.  If changes are specified
that would apply to UIDs that do not exist in the source list, these changes
are silently ignored. -}
unaryApplyChanges :: (Eq k, Ord k, Show k) => 
                     SyncCollection k -> [SyncCommand k] -> SyncCollection k
unaryApplyChanges collection commands =
    let makeChange collection (DeleteItem key) =
            Map.delete key collection
        makeChange collection (CopyItem key) =
            Map.insert key () collection
    in foldl makeChange collection commands
