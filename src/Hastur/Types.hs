module Hastur.Types where
import Network.Socket (SockAddr,ServiceName)
import System.IO (Handle)
import qualified Data.Text as T
import qualified Data.Map as M
import Control.Concurrent.MVar
import Data.Time(UTCTime)
import Control.Concurrent.STM(TChan,TMVar)
import Control.Concurrent(ThreadId)
type Port = ServiceName
type PortNum = Integer


data AsteriskServer = AsteriskServer {
  getServerFromAst :: Server,
  getUsernameFromServer :: T.Text,
  getPasswordFromServer :: T.Text,
  getOutputChannelFromAst :: TChan (Maybe T.Text),
  getThreadIdFromAst :: TMVar (ThreadId)
                                     }
data Server = Server {
  getHostnameFromServer :: T.Text,
  getSocketFromServer :: SockAddr,
  getHandleFromServer :: Handle  
                         }
type Command = T.Text
type Response = T.Text
type Hostname = T.Text
type ServerMap = M.Map Hostname AsteriskServer
type ServerPool = [Maybe Server]


data Broker = Broker {
  getSubscriptionList:: SubscriptionList,
  getServerFromBroker :: Server
                     }
data SubscriptionList = SubscriptionList [M.Map String Handle]
type AMIHeader = T.Text
type AMIData = T.Text
type Prefix = T.Text
type Subscriber = Handle
type ActionID = T.Text
data OurClient = Client {
  getSocketFromClient :: SockAddr,
  getHandleFromClient :: Handle,
  getLockFromClient :: (MVar ()),
  getUsernameFromClient :: T.Text,
  getAuthorised :: Bool
                       }

type ResponseMap = M.Map ActionID Response
type UserConfig = M.Map T.Text T.Text
data CustomConfig = CustomConfig {
                    getPort :: Int,
                    getDBUser :: String,
                    getDBPass :: String,
                    getDBHost :: String,
                    getDBName :: String,
                    getDBPort :: Int
                    }
type AMIMessage = M.Map AMIHeader AMIData
type Event = AMIMessage
type RawEvent = T.Text
type UniqueID = Double
type UIDMap = M.Map UniqueID Events
data Events = Events {
                     getPrefixFromEvents :: Maybe Prefix,
                     getEventListFromEvents :: [(RawEvent, Event)],
                     getTimeStampFromEvents :: UTCTime}
type Lock = MVar ()
type SubscriberMap = M.Map Prefix (Subscriber, Lock)
type RawAMIMessage = T.Text
