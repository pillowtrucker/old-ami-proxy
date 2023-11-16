{-# LANGUAGE OverloadedStrings #-}
module Hastur.Proxy where
import Hastur.Types
import Hastur.Util(maybeLookupToEither,makeActionID',maybeToEither,maybeLookupToEither,takeWhileM,(++),stripCRT, responseTimeoutMicrosecs,decoupleMessage,mapFromTuples',forkIO')
import Network.Socket (SockAddr,withSocketsDo,getAddrInfo,defaultHints,addrFlags,socketToHandle,SocketType(Stream),defaultProtocol,addrAddress,addrFamily,socket,bind,listen,Socket,accept,ServiceName,AddrInfoFlag(AI_PASSIVE))
import Control.Concurrent.STM (retry,putTMVar,takeTMVar,STM,atomically, readTMVar,TMVar,tryTakeTMVar,tryPutTMVar)
import System.IO (hIsClosed,hClose,hIsEOF,BufferMode(LineBuffering),hSetBuffering,Handle,IOMode(ReadWriteMode))
import System.Timeout(timeout)
import qualified Data.Map as M
import qualified Safe as S
import qualified Control.Exception as Ex
import qualified Data.Text as T
import Data.Text.IO(putStrLn,hPutStr,hGetLine)
import Prelude hiding (putStrLn,(++))
import Data.Hash.MD5
import Control.Concurrent.MVar
import Control.Concurrent(killThread,ThreadId)
msgok :: T.Text
msgok = "Response: Success\r\n"
msgnotok :: T.Text
msgnotok = "Response: Failure\r\n"

lookupServerInMap :: ServerMap -> Hostname -> Either T.Text AsteriskServer
lookupServerInMap amimap ws = maybeLookupToEither ws amimap ("Couldn't find server" ++ ws)
serverThread
  :: ServiceName
     -> TMVar ServerMap
     -> TMVar ResponseMap
     -> TMVar UserConfig
     -> IO ()
serverThread port sharedservermap responsemap userconfig = withSocketsDo $ do
  addrinfos <- getAddrInfo (Just (defaultHints {addrFlags = [AI_PASSIVE]})) Nothing (Just port)
  
  let serveraddr = head addrinfos
  sock <- socket (addrFamily serveraddr) Stream defaultProtocol
  bind sock (addrAddress serveraddr)
  listen sock 5
  lock <- newMVar ()  
  procRequests lock sock
  where   
    handlerfunc = ourClient
    procRequests :: MVar () -> Socket -> IO ()
    procRequests lock mastersock = do
      (connsock, clientaddr) <- accept mastersock
      thehandle <- socketToHandle connsock ReadWriteMode
      clientlock <- newMVar ()
      hPutStr thehandle "Asterisk Call Manager/1.1\r\n"
      forkIO' $ procMessages clientlock thehandle clientaddr
      procRequests lock mastersock
    procMessages :: MVar () -> Handle -> SockAddr -> IO ()
    procMessages lock hdl clientaddr = do
--      putStrLn $ "Client connecting from: " ++ (T.pack $! show clientaddr)
      hSetBuffering hdl LineBuffering
      theLoop $ Client clientaddr hdl lock "" False
        where
          theLoop aclient = do
            let connhdl = getHandleFromClient $! aclient
            closed <- hIsClosed connhdl
            iseof <- hIsEOF connhdl
            let done = closed || iseof
            if done then do
              if (not closed) then hClose connhdl else return ()
  --            putStrLn $ "client disconnected: " ++ (T.pack $! show clientaddr)
            else do
              messages <- takeWhileM (/= "\r") (repeat $ hGetLine connhdl) >>= return . T.unlines
              theclient <- handleMessages clientaddr aclient messages
              theLoop theclient
    handleMessages clientaddr connhdl msg = handlerfunc clientaddr connhdl msg >>= return
    ourClient :: SockAddr -> OurClient -> T.Text -> IO OurClient
    ourClient addr theclient msg =
      let parsed = decoupleMessage $! stripCRT msg
          reallyParsed = case parsed of
            Left(_) -> [("","")]
            Right(ok) -> ok
          requestmap = mapFromTuples' M.empty reallyParsed
          connhdl = getHandleFromClient $! theclient
          clientlock = getLockFromClient $! theclient
          getServerFromRequest =
            let inRequest = M.lookup "server" requestmap
            in
              case inRequest of
                Just s -> return $ Right(s)
                Nothing -> return $ Left("NOT FOUND")
          clPartial = Client addr connhdl clientlock
          authorised = getAuthorised theclient
          spewMessageAndReturn :: Bool -> T.Text -> IO (OurClient)
          spewMessageAndReturn isok custommsg = let prefix = if(isok) then msgok else msgnotok in do
            hPutStr connhdl $ prefix ++ "Message: " ++ custommsg ++ "\r\n\r\n"
            return theclient
          bail = spewMessageAndReturn False
          (>>>) :: Either T.Text a -> (a -> IO OurClient) -> IO OurClient
          k >>> f = case k of
            Right(m) -> f m
            Left(errmesg) -> bail errmesg
          eitherfirstheader = maybeToEither (S.headMay reallyParsed) "Empty request."
          sendToServerOrBail :: AsteriskServer -> Command -> ActionID -> MVar (ThreadId) -> IO (Maybe(ActionID))
          sendToServerOrBail server m aid haveLock =
            Ex.handle ((\e -> do
                           putStrLn $ "exception in client thread" ++ (T.pack $! show e)
                           hPutStr connhdl $ msgnotok ++ "Message: " ++ (T.pack $! show e) ++ "\r\n"
                           let --underlyingAsterisk = getServerFromAst $! server
                               --serverHandle = getHandleFromServer $! underlyingAsterisk
                               serverReaderThreadMVar = getThreadIdFromAst $! server
                           --maybeServerReaderThreadId <- atomically $ do
                             --maybeThreadID <- tryTakeTMVar serverReaderThreadMVar
                             --case maybeThreadID of
                                    --Nothing -> return Nothing
                                    --Just serverReaderThreadId -> return $ Just serverReaderThreadId
                           doIHaveLock <- tryTakeMVar haveLock
                           case doIHaveLock of
                             Nothing -> return ()
                             Just theLock -> do
                               killThread theLock
                               _ <- atomically $ tryPutTMVar serverReaderThreadMVar theLock
                               return ()
                           --case maybeServerReaderThreadId of
                             --Nothing -> case doIHaveLock of
                               --Nothing -> return ()
                               --Just yesIHaveTheLock -> killThread yesIHaveTheLock >> hClose serverHandle
                             --Just tid -> killThread tid >> hClose serverHandle
                           return Nothing) :: IOError -> IO (Maybe(ActionID))) $ do
              let underlyingAsterisk = getServerFromAst $! server
                  serverHandle = getHandleFromServer $! underlyingAsterisk
                  serverReaderThreadMVar = getThreadIdFromAst $! server
              --isServerClosed <- hIsClosed serverHandle
              --if isServerClosed then return Nothing else do
              readerId <- atomically $ takeTMVar serverReaderThreadMVar
              --putStrLn "got lock"
              _ <- putMVar haveLock readerId
              --putStrLn "put lock in mvar"
              killThread readerId
              hPutStr serverHandle m
              --putStrLn "sent server message"
              _ <- atomically $ tryPutTMVar serverReaderThreadMVar readerId
              --putStrLn "returned lock"
              return $ Just aid
          forwardWithActionID aid m ser = do
            let rebuilt_request = "ActionID: " ++ aid ++ "\r\n" ++ (T.unlines m) ++ "\r\n"
            haveLock <- newEmptyMVar
            isok <- sendToServerOrBail ser rebuilt_request aid haveLock
            return $ maybeToEither isok "Failed sending command to server."          
          fetchTheResponseFromSharedMap :: ActionID -> IO OurClient
          fetchTheResponseFromSharedMap aid = do
            response <- timeout (fromInteger responseTimeoutMicrosecs) $ (atomically $ getTheResponse aid)
            maybeToEither response ("Timed out waiting for endpoint to supply response for actionid " ++ aid) >>> \re -> do
              withMVar clientlock $! \_ -> do
                hPutStr connhdl (re ++ "\r\n")
                return theclient
          getTheResponse :: ActionID -> STM Response
          getTheResponse actionID = do
            rmap <- takeTMVar responsemap
            let response = M.lookup actionID rmap
            case response of
              Just theresponse ->
                let newrmap = M.delete actionID rmap
                in putTMVar responsemap newrmap >> return theresponse
              Nothing -> retry
          generateOrForwardAID maybeaid = case maybeaid of
            Just rid -> rid
            Nothing -> (makeActionID' (T.pack $! show addr) msg)
          remoteAID = M.lookup "actionid" requestmap
          theAID = generateOrForwardAID remoteAID
          challenge = "1234"
          authorisedContext :: IO OurClient
          authorisedContext = do
            --putStrLn msg
            eitherfirstheader >>> \fh ->
              case (\(h,d) -> (T.toLower h, d)) fh of
                ("server",_) -> let wantedaction = maybeLookupToEither "action" requestmap "No Action specified." in wantedaction >>> handleData
                ("action",d') -> handleData d'
                _ -> bail $ "Mangled request, ignoring."
            where forwardAndWaitForResponse = do
                    mws <- getServerFromRequest
                    let ws = case mws of
                          Left(s) -> s
                          Right(s) -> s
                    amiservermap <- atomically $ readTMVar sharedservermap
                    lookupServerInMap amiservermap ws >>> \fws -> do
                      forkIO' $ do
                        status <- forwardWithActionID theAID (T.lines msg) $! fws
                        case status of
                          Right(aid) -> do
                            fetchTheResponseFromSharedMap aid >> return ()
                          Left(theError) -> putStrLn ("Error getting response: " ++ theError) >> return ()
                      return theclient
                  handleData da = do
                    case T.toLower da of
                      "login" ->
                        bail "You are already logged in"
                      "" -> bail $ "EMPTY ACTION"
                      _ -> forwardAndWaitForResponse
          anonymousContext = do
            --putStrLn msg
            uconfig <- atomically $! readTMVar userconfig
            let getPassword u = maybeLookupToEither u uconfig "No such user."
                getSupUsername = maybeLookupToEither "username" requestmap "Empty username."
                getSupPassword _ = maybeLookupToEither "secret" requestmap "Empty password."                
                epass = getPassword
                authoriseUser u p = do
                   epass u >>> \ep ->
                    if (p == ep) then do
                      _ <- spewMessageAndReturn True "Authentication accepted"
                      return $ clPartial u True
                    else bail "Wrong password."
            eitherfirstheader >>> \fh ->
              case (\(h,d) -> (T.toLower h, T.toLower d)) fh of
                ("action",whataction) ->
                  case whataction of       
                    "login" -> do
                      let isChallengeResponse = M.lookup "key" requestmap
                      case isChallengeResponse of
                       Just k -> do
                         getSupUsername >>> \user -> do
                            let metispass = getPassword $! user
                            metispass >>> \p -> do
                              -- TODO (maybe, not really necessary or useful in this case): make the challenge a random number/string and hold onto it for verification
                              let computeddigest = md5s (Str $! T.unpack (challenge ++ p))
                              if (T.unpack k == computeddigest) then do
                                hPutStr connhdl $ msgok ++ "Message: Authentication accepted\r\n" ++ "ActionID: " ++ theAID ++ "\r\n\r\n"
                                return $ clPartial user True
                              else bail "Bad challenge response."
                       Nothing -> do
                          getSupUsername >>> \user ->
                            getSupPassword user >>>
                              (\supass -> 
                                authoriseUser user supass)
                    "challenge" -> do
                      hPutStr connhdl $ msgok ++ "ActionID: " ++ theAID ++ "\r\nChallenge: " ++ challenge ++ "\r\n\r\n"
                      return $ clPartial "" False
                    "command" -> bail "Please log in before sending commands."
                    rubbish -> bail $ "Unknown/unimplemented action: " ++ rubbish
                _ -> bail $ "Mangled request, ignoring."
      in
        if (authorised) then authorisedContext else anonymousContext
