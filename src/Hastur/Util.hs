{-# LANGUAGE OverloadedStrings #-}
module Hastur.Util (loadServerConfig,findServer,takeWhileM,(++),stripCRT, responseTimeoutMicrosecs, putSTMMap, decoupleMessage, mapFromTuples',maybeLookupToEither,makeActionID',maybeToEither,readConfig,forkIO',closeAndDeleteServer,closeServer) where
import Hastur.Types
import Control.Monad (liftM)
import Data.Hashable (hash)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Control.Concurrent.STM.TMVar
import Control.Concurrent.STM (STM,atomically,takeTMVar)
import System.IO (hClose,hIsClosed,hIsEOF,hShow)
import Control.Concurrent(forkIO,killThread,takeMVar)
import Data.List (foldl')
import Prelude hiding ((++))
import GHC.IO.Handle(hClose_help)
maybeToEither :: Maybe a -> T.Text -> Either T.Text a
maybeToEither amaybe anerrmesg =
  case amaybe of
    Just realresult -> Right(realresult)
    Nothing -> Left(anerrmesg)
forkIO' :: IO () -> IO ()
forkIO' action = forkIO action >> return ()
maybeLookupToEither
  :: Ord k => k -> M.Map k a -> T.Text -> Either T.Text a
maybeLookupToEither k m errmsg = maybeToEither (M.lookup k m) errmsg

takeWhileM :: Monad m => (a -> Bool) -> [m a] -> m [a]
takeWhileM p (ma: mas) = do
  a <- ma
  if p a
    then liftM (a : ) $ takeWhileM p mas
    else return []
takeWhileM _ _ = return []

mapFromMaybeServerConfig
  :: Ord k => M.Map k a -> [Maybe (k, a)] -> M.Map k a
mapFromMaybeServerConfig amap listofmaybes =
  foldl1 M.union $ map (\amaybe -> case amaybe of
                    Nothing -> amap
                    Just (k,v) -> M.insert k v amap) listofmaybes

isServerLine :: T.Text -> Bool
isServerLine line = "host" `T.isPrefixOf` line

loadServerConfig :: FilePath
     -> IO (M.Map T.Text (T.Text, T.Text, T.Text))
loadServerConfig path = do
  c <- TIO.readFile path
  return . mapFromMaybeServerConfig M.empty . map extractServerCreds . (filter (isServerLine)) . filterComments' $! c

extractServerCreds
  :: T.Text -> Maybe (T.Text, (T.Text, T.Text, T.Text))
extractServerCreds line = do
  let (_:serverline:[]) = T.splitOn " = " line
      (hostname:port:username:password:_:ssl) = T.splitOn ", " serverline
    in
    case ssl of
      (_:[]) -> Just (hostname,(port,username,password))
      _ -> Nothing

mapFromMaybeList :: [Maybe (T.Text, T.Text)] -> M.Map T.Text T.Text
mapFromMaybeList somelistofmaybes = M.fromList $ map (\maybekv -> case maybekv of
                                                         Nothing -> ("","")
                                                         Just sth -> sth) somelistofmaybes
  
readConfig :: FilePath -> IO (UserConfig)
readConfig file = do
  rawconf <- TIO.readFile file
  return . mapFromMaybeList . map extractCreds $ filterComments' $! rawconf
  

filterComments' :: T.Text -> [T.Text]
filterComments' config = filter (not . (";" `T.isPrefixOf`)) $ T.lines config

findServer :: T.Text -> M.Map T.Text a -> Either T.Text a
findServer what amap = maybeLookupToEither what amap $! "Couldn't find" +++ what +++ " in astmanproxy.conf"
       
extractCreds :: T.Text -> Maybe (T.Text, T.Text)
extractCreds line =
  let (user:pass) = T.splitOn "=" line
  in
    case pass of
      (password:[]) -> Just (user,password)
      _ -> Nothing

stripCRT :: T.Text -> T.Text
stripCRT = T.filter (/= '\r')

makeActionID' :: T.Text -> Command -> ActionID
makeActionID' a c = T.pack . show . hash $ a +++ c
(+++) :: T.Text -> T.Text -> T.Text
a +++ b = a `T.append` b

(++) :: T.Text -> T.Text -> T.Text
a ++ b = a +++ b

putSTMMap
  :: Ord k => TMVar (M.Map k a) -> a -> k -> STM ()
putSTMMap inmap value key = do
  rmap <- takeTMVar inmap
  let newmap = M.insert key value rmap
  putTMVar inmap newmap

responseTimeoutMicrosecs :: Integer
responseTimeoutMicrosecs = 30 * 1000000

decoupleMessage :: T.Text -> Either T.Text [(AMIHeader, AMIData)]
decoupleMessage = Right . map (\(k,v) -> (T.toLower k, T.drop 2 v)) . map (T.breakOn ": ") . T.lines

mapFromTuples' :: Ord k => M.Map k a -> [(k, a)] -> M.Map k a
mapFromTuples' = foldl' (\acc (h,d) -> M.insert h d acc)

deleteServer
  :: TMVar (ServerMap)
     -> AsteriskServer -> IO ()
deleteServer sharedServerMap theServer = do
  let myhostname = getHostnameFromServer . getServerFromAst $! theServer
  _ <- atomically $ do
        servermap <- takeTMVar sharedServerMap
        let newmap = M.delete myhostname servermap
        putTMVar sharedServerMap newmap
  return ()

closeAndDeleteServer
  :: TMVar ServerMap -> AsteriskServer -> IO ()
closeAndDeleteServer sharedServerMap theServer = do
  closeServer theServer
  deleteServer sharedServerMap theServer   

closeServer :: AsteriskServer -> IO ()
closeServer theServer = do
  let m = getThreadIdFromAst $! theServer
  theThread <- atomically (takeTMVar m)
--  putStrLn "killer got threadid"
  killThread theThread
--  putStrLn "killer killed thread"
  (return . getHandleFromServer $! getServerFromAst theServer) >>= hClose
--  putStrLn "killer close handle"
