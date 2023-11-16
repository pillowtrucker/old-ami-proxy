import Hastur.Types
import Hastur.Util(loadServerConfig,readConfig,forkIO',closeServer,responseTimeoutMicrosecs)
import Hastur.Proxy (serverThread)
import Hastur.AMIClient(buildAMIPool,buildServerMapFromPool,mainAMIEndpointLoop)
import qualified Control.Monad.Parallel as Par
import qualified Data.Map as M
import System.Environment (getArgs,getProgName)
import Control.Concurrent.STM.TMVar
import Control.Concurrent.STM (atomically,retry)
import System.Posix.Signals(installHandler,sigHUP,Handler(Catch))
--import System.Posix.User(setUserID,setGroupID)
import Control.Concurrent (threadDelay, newEmptyMVar,putMVar,forkIO,MVar,ThreadId,killThread,takeMVar)
import System.IO(stdout,hSetBuffering,BufferMode(LineBuffering))
data ClientThread = ClientThread ThreadId Port (TMVar ServerMap) (TMVar ResponseMap) (TMVar UserConfig)

--kickServers :: MVar ClientThread -> IO ()
--kickServers clientThread = takeMVar clientThread >>= \(ClientThread threadId p sMap responseMap userConfig) -> killThread threadId >> atomically (readTMVar sMap) >>= Par.mapM_ (\s -> closeServer s ) . M.elems >> (forkIO $! serverThread p sMap responseMap userConfig) >>= \newId -> putMVar clientThread $! ClientThread newId p sMap responseMap userConfig

makeUserConfig :: FilePath -> IO (TMVar (UserConfig))
makeUserConfig path = do
  parsedusers <- readConfig path
  atomically $ newTMVar parsedusers

updateUserConfig
  :: FilePath -> TMVar (UserConfig) -> IO ()
updateUserConfig path var = do
  _ <- atomically $ takeTMVar var
  newparsedusers <- readConfig path
  atomically $ putTMVar var newparsedusers
kickServers :: TMVar (ServerMap) -> IO ()
kickServers sMap = atomically (readTMVar sMap) >>= Par.mapM_ (\s -> closeServer s ) . M.elems
updateServerConfig
  :: FilePath
     -> TMVar (ResponseMap)
     -> TMVar (ServerMap)
     -> IO ()
updateServerConfig path responseMap sharedServerMap = do
  
  oldServers <- atomically $ takeTMVar sharedServerMap
  let sList = M.elems oldServers
  forkIO' $ Par.forM_ sList closeServer
  newServerAuth <- loadServerConfig path
  let serverList = M.keys newServerAuth
  maybeServerPool <- buildAMIPool serverList
  let serverMap = M.empty
  _ <- atomically $ putTMVar sharedServerMap $! foldl1 M.union (map (\s -> buildServerMapFromPool s serverMap) maybeServerPool)
  l_smap <- atomically $ readTMVar sharedServerMap
  let actualPool = M.elems l_smap
  forkIO' $ Par.mapM_ (\x -> mainAMIEndpointLoop x responseMap sharedServerMap False) actualPool
main :: IO ()
main = do
  myargs <- getArgs
  myname <- getProgName
  hSetBuffering stdout LineBuffering
  case myargs of
    (port:uconfigpath:[]) -> do
      spinUp port uconfigpath
    (port:[]) -> do
      let uconfigpath = "/etc/asterisk/astmanproxy.users"
      spinUp port uconfigpath
    _ -> fail $ "Usage: " ++ myname ++ " port [config_filename]"
  where
    spinUp p ucp = do
      let serverConfigPath = "/etc/asterisk/astmanproxy.conf"
      responseMap <- atomically $ newTMVar M.empty
      userConfig <- makeUserConfig ucp
      smapShared <- atomically $ newTMVar M.empty
      proxyClientsServer <- newEmptyMVar
      updateServerConfig serverConfigPath responseMap smapShared
      proxyClientsServerId <- forkIO $! serverThread p smapShared responseMap userConfig
      putMVar proxyClientsServer $ ClientThread proxyClientsServerId p smapShared responseMap userConfig
--      _ <- installHandler sigHUP (Catch (updateUserConfig ucp userConfig >> kickServers proxyClientsServer)) Nothing
      _ <- installHandler sigHUP (Catch (updateUserConfig ucp userConfig >> kickServers smapShared)) Nothing
      --threadDelay (fromInteger responseTimeoutMicrosecs)
      let block = do
            sm <- readTMVar smapShared
            if (M.null sm) then
              return True
              else
              retry
      isDone <- atomically $ block
      if (isDone) then putStrLn "All servers died, exiting." else error "something's gone horribly wrong"
