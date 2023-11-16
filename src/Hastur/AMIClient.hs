{-# LANGUAGE OverloadedStrings #-}
module Hastur.AMIClient(buildAMIPool,mainAMIEndpointLoop,buildServerMapFromPool) where
import Hastur.Types
import qualified Control.Exception as Ex
import Network.Socket (getAddrInfo,socket,addrFamily,SocketType (Stream),addrAddress,SocketOption (KeepAlive),setSocketOption,defaultProtocol,connect,socketToHandle)
import System.IO (IOMode (ReadWriteMode),hSetBuffering,BufferMode (LineBuffering),hIsClosed,hClose)
import qualified Control.Monad.Parallel as Par
import Hastur.Util(loadServerConfig,findServer,takeWhileM,(++),stripCRT, responseTimeoutMicrosecs, putSTMMap, decoupleMessage, mapFromTuples',forkIO',closeAndDeleteServer)
import qualified Data.Text as T
import Data.Text.IO(hPutStr,putStrLn,hGetLine)
import qualified Data.Map.Strict as M
import Control.Concurrent.STM (atomically,takeTMVar,putTMVar,TMVar, STM,newTChan,readTChan,writeTChan,swapTMVar,newEmptyTMVar,tryTakeTMVar)
import Control.Concurrent (threadDelay,forkIO,myThreadId,takeMVar,putMVar,newMVar,newEmptyMVar)

import Prelude hiding (putStrLn,putStr, (++))

connectToRealAMI :: Hostname -> PortNum -> Integer -> IO (Maybe AsteriskServer)
connectToRealAMI hostname portnum attempt =
  let maxAttempts = 2880
      exceptionHandler :: IOError -> IO (Maybe AsteriskServer)
      exceptionHandler e = do
        if (attempt >= maxAttempts) then do
          putStrLn $ "Exception in server thread: " ++ (T.pack $! show e) ++ " Bailing out of " ++ hostname
          return Nothing
        else do
          putStrLn $ "Exception in server thread: " ++ (T.pack $! show e) ++ " Attempt " ++ (T.pack $! show attempt) ++ " Retrying.."
          threadDelay (fromInteger responseTimeoutMicrosecs)
          connectToRealAMI hostname portnum (attempt + 1)        
  in
    Ex.handle exceptionHandler $ do
    addrinfos <- getAddrInfo Nothing (Just (T.unpack hostname)) (Just $! show portnum)
    let serveraddr = head addrinfos
    sock <- socket (addrFamily serveraddr) Stream defaultProtocol
    setSocketOption sock KeepAlive 1
    let serversockaddr = addrAddress serveraddr
    connect sock serversockaddr
    -- TODO: this can be specified by a command line argument, don't hardcode this
    amiconfig <- loadServerConfig "/etc/asterisk/astmanproxy.conf"
    h <- socketToHandle sock ReadWriteMode
    hSetBuffering h LineBuffering
    let eitherserver = findServer hostname amiconfig
    case eitherserver of
     Left(errmsg) -> putStrLn errmsg >> return Nothing
     Right(_,amiuser,amipass) -> do
      putStrLn ("Connected to " ++ hostname)
      outputChan <- atomically $ newTChan
      threadTMVar <- atomically $ newEmptyTMVar
      return $ Just $ AsteriskServer (Server hostname serversockaddr h) amiuser amipass outputChan threadTMVar
    

buildAMIPool :: [Hostname] -> IO [Maybe AsteriskServer]
buildAMIPool servernames =
    let exceptionHandler :: IOError -> IO [Maybe AsteriskServer]
        exceptionHandler e = do
          putStrLn $ "Exception propagated outside an individual connection/login thread : "
            ++ (T.pack $! show e) ++ " Bailing out.."
          return [Nothing]
    in
      Ex.handle exceptionHandler $ do
      pool <- Par.mapM (\s -> connectToRealAMI s 5038 1) servernames
      Par.mapM (\ser -> case ser of
                   Just s -> loginToAMI s
                   Nothing -> return Nothing ) pool
        
loginToAMI :: AsteriskServer -> IO (Maybe AsteriskServer)
loginToAMI server = Ex.handle
  (\e -> do
      let hostname = getHostnameFromServer . getServerFromAst $! server
          printable_socket = T.pack $! show . getSocketFromServer . getServerFromAst $! server
          theerror = T.pack $! show (e:: IOError)
      putStrLn $ "Exception raised while logging in to " ++ hostname ++ " " ++ theerror ++ " " ++ printable_socket
      return Nothing ) $ do
          let h = getHandleFromServer . getServerFromAst $! server
              u = getUsernameFromServer $! server
              p = getPasswordFromServer $! server
              hostname = getHostnameFromServer $! getServerFromAst $! server
          hPutStr h $ "Action: Login\r\nUsername: " ++ u ++ "\r\nSecret: " ++ p ++ "\r\nEvents: Off\r\n\r\n"
          response <- takeWhileM (/= "\r") (repeat $ hGetLine h)
          putStrLn $ T.unlines response
          if ( "Authentication accepted" `T.isInfixOf` (T.unlines response) ) then do
            putStrLn $! "Logged in to " ++ hostname
            return $ Just server else return Nothing
buildServerMapFromPool
  :: Maybe AsteriskServer -> M.Map Hostname AsteriskServer -> M.Map Hostname AsteriskServer
buildServerMapFromPool s sm = case s of
  Just z -> M.insert (getHostnameFromServer . getServerFromAst $! z) z sm
  Nothing -> sm

    
mainAMIEndpointLoop
  :: AsteriskServer
     -> TMVar (M.Map ActionID RawAMIMessage)
     -> TMVar (M.Map Hostname AsteriskServer)
     -> Bool
     -> IO ()
mainAMIEndpointLoop aserver responsemap sharedservermap exRaised = do
 Ex.handle ((\e -> putStrLn ("exception in server thread: " ++ (getHostnameFromServer . getServerFromAst $! aserver) ++ ": " ++(T.pack $! show e)) >> atomically (tryTakeTMVar (getThreadIdFromAst aserver)) >> mainAMIEndpointLoop aserver responsemap sharedservermap True):: IOError -> IO ()) $ do
  let myhandle = getHandleFromServer . getServerFromAst $! aserver
      myhostname = getHostnameFromServer . getServerFromAst $! aserver
  closed <- hIsClosed $! myhandle
  let done = (closed||exRaised) -- || iseof)
      deleteSelfAndBail = closeAndDeleteServer sharedservermap aserver
  if done then do
    newserver <- connectToRealAMI myhostname 5038 1
    case newserver of
      Just anewserver -> do
        loggedinserver <- loginToAMI anewserver
        case loggedinserver of
          Just anewloggedinserver -> do
            atomically $ do
              servermap <- takeTMVar sharedservermap
              let newservermap = (M.insert myhostname anewloggedinserver) . (M.delete myhostname) $ servermap
              putTMVar sharedservermap newservermap
            forkIO' $ mainAMIEndpointLoop anewloggedinserver responsemap sharedservermap False
            return ()
          Nothing -> do
            putStrLn $ "Managed to reconnect to " ++ myhostname ++ " but failed logging in."
            deleteSelfAndBail
      Nothing -> do
        putStrLn $ "All attempts to reconnect to " ++ myhostname ++ " failed. Giving up on this one."
        deleteSelfAndBail
  else do
    let serverLines = getOutputChannelFromAst aserver
        threadExceptionHandle :: Ex.SomeException -> IO ()
        threadExceptionHandle = (\_ -> atomically $ writeTChan serverLines Nothing)
    blockingThread <- forkIO $
     Ex.handle threadExceptionHandle $ do 
       takeWhileM (/= "\r") (repeat $ hGetLine myhandle) >>= \theLines -> atomically $ writeTChan serverLines $! Just $! T.unlines theLines
    let myMutableThreadId = getThreadIdFromAst aserver
    _ <- atomically $ tryTakeTMVar myMutableThreadId >> putTMVar myMutableThreadId blockingThread
    maybeMessages <- atomically $ readTChan serverLines
    let continueParsing messages = do
          let parsing_result = if ("Event" `T.isPrefixOf` messages) then decoupleMessage messages else Left(messages)
          forkIO' $ case parsing_result of
            Left(_) -> do
              let putResponse' = putResponse responsemap 
                  parsed = parseAMIMessage messages
                  requestmap = mapFromTuples' M.empty parsed         
                  l_actionid = M.lookup "actionid" requestmap
                  readdServerHeader' = readdServerHeader myhostname
              case l_actionid of
               Just aid -> do
                forkIO' $ atomically $ putResponse' (readdServerHeader' messages) aid
                return ()
               Nothing -> return ()
            Right(_) -> putStrLn $ "Event caught but this is not an event filter."
    case maybeMessages of
      Nothing -> return ()
      Just m -> forkIO' (continueParsing m)
    mainAMIEndpointLoop aserver responsemap sharedservermap False

parseAMIMessage :: RawAMIMessage -> [(AMIHeader, AMIData)]
parseAMIMessage = map (\(h,d) -> (T.toLower h, T.drop 2 d)) . map (T.breakOn ": " . stripCRT) . T.lines


putResponse
  :: TMVar (M.Map ActionID RawAMIMessage) -> RawAMIMessage -> ActionID -> STM ()
putResponse responsemap actionid theresponse = putSTMMap responsemap actionid theresponse

readdServerHeader :: Hostname -> RawAMIMessage -> RawAMIMessage
readdServerHeader h m = m ++ "Server: " ++ h ++ "\r\n"
