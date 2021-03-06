{-# OPTIONS_GHC -fno-warn-orphans #-}

{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Chainweb.Server where

------------------------------------------------------------------------------
import           Chainweb.Api.BlockHeader (BlockHeader(..))
import           Chainweb.Api.ChainId
import           Chainweb.Api.Hash
import           Control.Applicative
import           Control.Concurrent
import           Control.Error
import           Control.Monad.Except
import           Data.Foldable
import           Data.IORef
import qualified Data.Pool as P
import           Data.Sequence (Seq)
import qualified Data.Sequence as S
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Tuple.Strict (T2(..))
import           Database.Beam hiding (insert)
import           Database.Beam.Backend.SQL
import           Database.Beam.Postgres
import           Control.Lens
import           Network.Wai
import           Network.Wai.Handler.Warp
import           Network.Wai.Middleware.Cors
import           Servant.API
import           Servant.Server
import           Text.Printf
------------------------------------------------------------------------------
import           Chainweb.Api.BlockPayloadWithOutputs
import           Chainweb.Coins
import           Chainweb.Database
import           Chainweb.Env
import           Chainweb.Listen
import           Chainweb.Lookups
import           ChainwebData.Types
import           ChainwebData.Api
import           ChainwebData.Pagination
import           ChainwebData.TxSummary
import           ChainwebDb.Types.Block
import           ChainwebDb.Types.DbHash
import           ChainwebDb.Types.Transaction
------------------------------------------------------------------------------

setCors :: Middleware
setCors = cors . const . Just $ simpleCorsResourcePolicy
    { corsRequestHeaders = simpleHeaders
    }

data ServerState = ServerState
    { _ssRecentTxs :: RecentTxs
    , _ssTransactionCount :: Maybe Int
    , _ssCirculatingCoins :: Maybe Double
    } deriving (Eq,Ord,Show)

ssRecentTxs
    :: Functor f
    => (RecentTxs -> f RecentTxs)
    -> ServerState -> f ServerState
ssRecentTxs = lens _ssRecentTxs setter
  where
    setter sc v = sc { _ssRecentTxs = v }

ssTransactionCount
    :: Functor f
    => (Maybe Int -> f (Maybe Int))
    -> ServerState -> f ServerState
ssTransactionCount = lens _ssTransactionCount setter
  where
    setter sc v = sc { _ssTransactionCount = v }

ssCirculatingCoins
    :: Functor f
    => (Maybe Double -> f (Maybe Double))
    -> ServerState -> f ServerState
ssCirculatingCoins = lens _ssCirculatingCoins setter
  where
    setter sc v = sc { _ssCirculatingCoins = v }

apiServer :: Env -> ServerEnv -> IO ()
apiServer env senv = do
  circulatingCoins <- queryCirculatingCoins env
  putStrLn $ "Total coins in circulation: " <> show circulatingCoins
  let pool = _env_dbConnPool env
  recentTxs <- RecentTxs . S.fromList <$> queryRecentTxs (logFunc senv) pool
  numTxs <- getTransactionCount (logFunc senv) pool
  ssRef <- newIORef $ ServerState recentTxs numTxs (hush circulatingCoins)
  circulationTid <- forkIO $ scheduledUpdates env senv pool ssRef
  listenTid <- forkIO $ listenWithHandler env $
    serverHeaderHandler env (_serverEnv_verbose senv) pool ssRef
  Network.Wai.Handler.Warp.run (_serverEnv_port senv) $ setCors $ serve chainwebDataApi $
    (recentTxsHandler ssRef :<|>
    searchTxs (logFunc senv) pool) :<|>
    statsHandler ssRef

scheduledUpdates
  :: Env
  -> ServerEnv
  -> P.Pool Connection
  -> IORef ServerState
  -> IO ()
scheduledUpdates env senv pool ssRef = forever $ do
    threadDelay (60 * 60 * 24 * micros)

    putStrLn "Recalculating coins in circulation:"
    circulatingCoins <- queryCirculatingCoins env
    print circulatingCoins
    let f ss = (ss & ssCirculatingCoins %~ (hush circulatingCoins <|>), ())
    atomicModifyIORef' ssRef f

    numTxs <- getTransactionCount (logFunc senv) pool
    putStrLn $ "Updated number of transactions: " <> show numTxs
    let g ss = (ss & ssTransactionCount %~ (numTxs <|>), ())
    atomicModifyIORef' ssRef g
  where
    micros = 1000000

statsHandler :: IORef ServerState -> Handler ChainwebDataStats
statsHandler ssRef = liftIO $ fmap mkStats $ readIORef ssRef
  where
    mkStats ss = ChainwebDataStats (_ssTransactionCount ss)
                                   (_ssCirculatingCoins ss)

recentTxsHandler :: IORef ServerState -> Handler [TxSummary]
recentTxsHandler ss = liftIO $ fmap (toList . _recentTxs_txs . _ssRecentTxs) $ readIORef ss

serverHeaderHandler :: Env -> Bool -> P.Pool Connection -> IORef ServerState -> PowHeader -> IO ()
serverHeaderHandler env verbose pool ssRef ph@(PowHeader h _) = do
  let chain = _blockHeader_chainId h
  let height = _blockHeader_height h
  let pair = T2 (_blockHeader_chainId h) (hashToDbHash $ _blockHeader_payloadHash h)
  payloadWithOutputs env pair >>= \case
    Nothing -> printf "[FAIL] Couldn't fetch parent for: %s\n"
      (hashB64U $ _blockHeader_hash h)
    Just pl -> do
      let hash = _blockHeader_hash h
          ts = S.fromList $ map (mkTxSummary chain height hash . fst) $ _blockPayloadWithOutputs_transactionsWithOutputs pl
          f ss = (ss & ssRecentTxs %~ addNewTransactions ts
                     & (ssTransactionCount . _Just) +~ (S.length ts), ())

      let msg = printf "Got new header on chain %d height %d" (unChainId chain) height
          addendum = if S.length ts == 0
                       then ""
                       else printf " with %d transactions" (S.length ts)
      when verbose $ putStrLn (msg <> addendum)

      atomicModifyIORef' ssRef f
      insertNewHeader pool ph pl


instance BeamSqlBackendIsString Postgres (Maybe Text)
instance BeamSqlBackendIsString Postgres (Maybe String)

searchTxs
  :: (String -> IO ())
  -> P.Pool Connection
  -> Maybe Limit
  -> Maybe Offset
  -> Maybe Text
  -> Handler [TxSummary]
searchTxs _ _ _ _ Nothing = do
    throwError $ err404 { errBody = "You must specify a search string" }
searchTxs printLog pool limit offset (Just search) = do
    liftIO $ putStrLn $ "Transaction search: " <> T.unpack search
    liftIO $ P.withResource pool $ \c -> do
      res <- runBeamPostgresDebug printLog c $
        runSelectReturningList $ select $ do
        limit_ lim $ offset_ off $ orderBy_ (desc_ . getHeight) $ do
          tx <- all_ (_cddb_transactions database)
          blk <- all_ (_cddb_blocks database)
          guard_ (_tx_block tx `references_` blk)
          guard_ (_tx_code tx `like_` val_ (Just searchString))
          return
             ( (_tx_chainId tx)
             , (_block_height blk)
             , (unBlockId $ _tx_block tx)
             , (_tx_creationTime tx)
             , (_tx_requestKey tx)
             , (_tx_sender tx)
             , (_tx_code tx)
             , (_tx_goodResult tx)
             )
      return $ mkSummary <$> res
  where
    lim = maybe 10 (min 100 . unLimit) limit
    off = maybe 0 unOffset offset
    getHeight (_,a,_,_,_,_,_,_) = a
    mkSummary (a,b,c,d,e,f,g,h) = TxSummary a b (unDbHash c) d e f g (maybe TxFailed (const TxSucceeded) h)
    searchString = "%" <> search <> "%"

data h :. t = h :. t deriving (Eq,Ord,Show,Read,Typeable)
infixr 3 :.

type instance QExprToIdentity (a :. b) = (QExprToIdentity a) :. (QExprToIdentity b)
type instance QExprToField (a :. b) = (QExprToField a) :. (QExprToField b)


queryRecentTxs :: (String -> IO ()) -> P.Pool Connection -> IO [TxSummary]
queryRecentTxs printLog pool = do
    liftIO $ putStrLn "Getting recent transactions"
    P.withResource pool $ \c -> do
      res <- runBeamPostgresDebug printLog c $
        runSelectReturningList $ select $ do
        limit_ 20 $ orderBy_ (desc_ . getHeight) $ do
          tx <- all_ (_cddb_transactions database)
          blk <- all_ (_cddb_blocks database)
          guard_ (_tx_block tx `references_` blk)
          return
             ( (_tx_chainId tx)
             , (_block_height blk)
             , (unBlockId $ _tx_block tx)
             , (_tx_creationTime tx)
             , (_tx_requestKey tx)
             , (_tx_sender tx)
             , (_tx_code tx)
             , (_tx_goodResult tx)
             )
      return $ mkSummary <$> res
  where
    getHeight (_,a,_,_,_,_,_,_) = a
    mkSummary (a,b,c,d,e,f,g,h) = TxSummary a b (unDbHash c) d e f g (maybe TxFailed (const TxSucceeded) h)

getTransactionCount :: (String -> IO ()) -> P.Pool Connection -> IO (Maybe Int)
getTransactionCount printLog pool = do
    P.withResource pool $ \c -> do
      runBeamPostgresDebug printLog c $ runSelectReturningOne $ select $
        aggregate_ (\_ -> as_ @Int countAll_) (all_ (_cddb_transactions database))

data RecentTxs = RecentTxs
  { _recentTxs_txs :: Seq TxSummary
  } deriving (Eq,Ord,Show)

getSummaries :: RecentTxs -> [TxSummary]
getSummaries (RecentTxs s) = toList s

addNewTransactions :: Seq TxSummary -> RecentTxs -> RecentTxs
addNewTransactions txs (RecentTxs s1) = RecentTxs s2
  where
    maxTransactions = 10
    s2 = S.take maxTransactions $ txs <> s1

logFunc :: ServerEnv -> String -> IO ()
logFunc e s = if _serverEnv_verbose e then putStrLn s else return ()
