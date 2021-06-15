{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PackageImports      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Logging.Tracer.Forward
  (
    forwardTracer
  ) where

import           Codec.CBOR.Term (Term)
import           Codec.Serialise (Serialise (..))
import           Control.Concurrent (forkIO)
import           Control.Concurrent.STM.TBQueue (TBQueue, newTBQueueIO,
                     writeTBQueue)
import           Control.Exception (SomeException, try)
import           Control.Monad (void)
import           Control.Monad.IO.Class
import           Control.Monad.STM (atomically)
import           GHC.Generics (Generic)

-- Temporary solution, to avoid conflicts with trace-dispatcher.
import qualified Control.Tracer as T
import           "contra-tracer" Control.Tracer (contramap, stdoutTracer)
import qualified Data.ByteString.Lazy as LBS
import           Data.IORef
import           Data.Text (unpack)
import           Data.Void (Void)
import           Data.Word (Word16)
import qualified Network.Socket as Socket

import           Ouroboros.Network.Driver.Limits (ProtocolTimeLimits)
import           Ouroboros.Network.IOManager (withIOManager)
import           Ouroboros.Network.Mux (MiniProtocol (..),
                     MiniProtocolLimits (..), MiniProtocolNum (..),
                     MuxMode (..), OuroborosApplication (..),
                     RunMiniProtocol (..), miniProtocolLimits, miniProtocolNum,
                     miniProtocolRun)
import           Ouroboros.Network.Protocol.Handshake.Codec
                     (cborTermVersionDataCodec, noTimeLimitsHandshake,
                     timeLimitsHandshake)
import           Ouroboros.Network.Protocol.Handshake.Type (Handshake)
import           Ouroboros.Network.Protocol.Handshake.Unversioned
                     (UnversionedProtocol (..), UnversionedProtocolData (..),
                     unversionedHandshakeCodec, unversionedProtocolDataCodec)
import           Ouroboros.Network.Protocol.Handshake.Version
                     (acceptableVersion, simpleSingletonVersions)
import           Ouroboros.Network.Snocket (Snocket, localAddressFromPath,
                     localSnocket, socketSnocket)
import           Ouroboros.Network.Socket (connectToNode,
                     nullNetworkConnectTracers)
import           Ouroboros.Network.Util.ShowProxy (ShowProxy (..))

import qualified System.Metrics as EKG
import qualified System.Metrics.Configuration as EKGF
import           System.Metrics.Network.Forwarder (forwardEKGMetrics)
import qualified Trace.Forward.Configuration as TF
import           Trace.Forward.Network.Forwarder (forwardTraceObjects)

import           Cardano.Logging.DocuGenerator
import           Cardano.Logging.Types


-- Instances for 'TraceObject' to forward it using 'trace-forward' library.

deriving instance Generic Privacy
deriving instance Generic SeverityS
deriving instance Generic LoggingContext
deriving instance Generic TraceObject

instance Serialise DetailLevel
instance Serialise Privacy
instance Serialise SeverityS
instance Serialise LoggingContext
instance Serialise TraceObject

instance ShowProxy TraceObject

---------------------------------------------------------------------------

newtype ForwardTracerState = ForwardTracerState {
    ftQueue   :: TBQueue TraceObject
  }

forwardTracer :: forall m. (MonadIO m)
  => TraceConfig
  -> m (Trace m FormattedMessage)
forwardTracer config = do
    tbQueue <- liftIO $ newTBQueueIO
                          (fromIntegral (tcForwarderCacheSize config))
    store <- liftIO $ EKG.newStore
    liftIO $ EKG.registerGcMetrics store
    liftIO $ launchForwardersSimple (tcForwarder config) tbQueue store
    stateRef <- liftIO $ newIORef (ForwardTracerState tbQueue)
    pure $ Trace $ T.arrow $ T.emit $ uncurry3 (output stateRef)
  where
    output ::
         IORef ForwardTracerState
      -> LoggingContext
      -> Maybe TraceControl
      -> FormattedMessage
      -> m ()
    output stateRef LoggingContext {} Nothing (FormattedForwarder lo) = liftIO $ do
      st  <- readIORef stateRef
      atomically $ writeTBQueue (ftQueue st) lo
    output _stateRef LoggingContext {} (Just Reset) _msg = liftIO $ do
      -- TODO JNF discuss reconfiguration
      pure ()
    output _ lk (Just c@Document {}) (FormattedForwarder lo) = do
      case toHuman lo of
        Just hr -> docIt (Stdout HumanFormatUncoloured)
                         (FormattedHuman False "") (lk, Just c, hr)
        Nothing -> pure ()
      case toMachine lo of
        Just mr -> docIt (Stdout MachineFormat) (FormattedMachine "") (lk, Just c, mr)
        Nothing -> pure ()
    output _stateRef LoggingContext {} _ _a = pure ()

launchForwardersSimple :: RemoteAddr -> TBQueue TraceObject -> EKG.Store -> IO ()
launchForwardersSimple endpoint tbQueue store =
  void . forkIO $ launchForwardersSimple'
 where
  launchForwardersSimple' =
    try (launchForwarders' endpoint (ekgConfig, tfConfig) tbQueue store) >>= \case
      Left (_e :: SomeException) ->
        -- There is some problem with the connection with the acceptor, try it again.
        -- TODO JNF What if it runs in an infinite loop?
        launchForwardersSimple'
      Right _ ->
        pure () -- Actually, the function 'connectToNode' never returns.

  ekgConfig :: EKGF.ForwarderConfiguration
  ekgConfig =
    EKGF.ForwarderConfiguration
      { EKGF.forwarderTracer    = contramap show stdoutTracer
      , EKGF.acceptorEndpoint   = forEKGF endpoint
      , EKGF.reConnectFrequency = 1.0
      , EKGF.actionOnRequest    = const (return ())
      }

  tfConfig :: TF.ForwarderConfiguration TraceObject
  tfConfig =
    TF.ForwarderConfiguration
      { TF.forwarderTracer  = contramap show stdoutTracer
      , TF.acceptorEndpoint = forTF endpoint
      , TF.nodeBasicInfo    = return []
      , TF.actionOnRequest  = const (return ())
      }

  forTF (LocalPipe p)      = TF.LocalPipe p
  forTF (RemoteSocket h p) = TF.RemoteSocket h p

  forEKGF (LocalPipe p)      = EKGF.LocalPipe p
  forEKGF (RemoteSocket h p) = EKGF.RemoteSocket h p

launchForwarders'
  :: RemoteAddr
  -> (EKGF.ForwarderConfiguration, TF.ForwarderConfiguration TraceObject)
  -> TBQueue TraceObject
  -> EKG.Store
  -> IO ()
launchForwarders' endpoint configs tbQueue store = withIOManager $ \iocp -> do
  case endpoint of
    LocalPipe localPipe -> do
      let snocket = localSnocket iocp localPipe
          address = localAddressFromPath localPipe
      doConnectToAcceptor snocket address noTimeLimitsHandshake configs tbQueue store
    RemoteSocket host port -> do
      acceptorAddr:_ <- Socket.getAddrInfo Nothing (Just (unpack host)) (Just (show port))
      let snocket = socketSnocket iocp
          address = Socket.addrAddress acceptorAddr
      doConnectToAcceptor snocket address timeLimitsHandshake configs tbQueue store

doConnectToAcceptor
  :: Snocket IO fd addr
  -> addr
  -> ProtocolTimeLimits (Handshake UnversionedProtocol Term)
  -> (EKGF.ForwarderConfiguration, TF.ForwarderConfiguration TraceObject)
  -> TBQueue TraceObject
  -> EKG.Store
  -> IO ()
doConnectToAcceptor snocket address timeLimits (ekgConfig, tfConfig) tbQueue store = do
  -- If there is a network problem (unable to establish the connection
  -- with the acceptor or the connection was broken), thrown exception
  -- will be catched and this function will be re-called.
  connectToNode
    snocket
    unversionedHandshakeCodec
    timeLimits
    (cborTermVersionDataCodec unversionedProtocolDataCodec)
    nullNetworkConnectTracers
    acceptableVersion
    (simpleSingletonVersions
       UnversionedProtocol
       UnversionedProtocolData $
         forwarderApp [ (forwardEKGMetrics ekgConfig store,    1)
                      , (forwardTraceObjects tfConfig tbQueue, 2)
                      ]
    )
    Nothing
    address
 where
  forwarderApp
    :: [(RunMiniProtocol 'InitiatorMode LBS.ByteString IO () Void, Word16)]
    -> OuroborosApplication 'InitiatorMode addr LBS.ByteString IO () Void
  forwarderApp protocols =
    OuroborosApplication $ \_connectionId _shouldStopSTM ->
      [ MiniProtocol
         { miniProtocolNum    = MiniProtocolNum num
         , miniProtocolLimits = MiniProtocolLimits { maximumIngressQueue = maxBound }
         , miniProtocolRun    = prot
         }
      | (prot, num) <- protocols
      ]

-- | Converts a curried function to a function on a triple.
uncurry3 :: (a -> b -> c -> d) -> ((a, b, c) -> d)
uncurry3 f ~(a,b,c) = f a b c