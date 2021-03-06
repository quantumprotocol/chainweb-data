{-# LANGUAGE OverloadedStrings #-}

module Chainweb.Coins where

------------------------------------------------------------------------------
import           Control.Error
import           Control.Lens
import           Data.Aeson
import           Data.Decimal
import           Data.Text (Text)
import qualified Data.Text as T
import           Pact.ApiReq
import           Pact.Server.API
import           Pact.Types.API
import           Pact.Types.ChainId
import           Pact.Types.ChainMeta
import           Pact.Types.Command
import           Pact.Types.Exp
import           Pact.Types.Hash
import           Pact.Types.PactValue
import           Servant.API
import           Servant.Client
import           Text.Printf
------------------------------------------------------------------------------
import           Chainweb.Api.ChainId (unChainId)
import           Chainweb.Env hiding (Command)
------------------------------------------------------------------------------

coinQuery :: String
coinQuery =
  "(fold (+) 0 (map (at 'balance) (map (read coin.coin-table) (keys coin.coin-table))))"

queryCirculatingCoins :: Env -> IO (Either String Double)
queryCirculatingCoins env = do
  echains <- mapM (sendCoinQuery env . unChainId) (_env_chains env)
  return $ do
    chains <- sequence echains
    return $ realToFrac $ sum chains

sendCoinQuery :: Env -> Int -> IO (Either String Decimal)
sendCoinQuery env chain = do
  let (Url h p) = _env_nodeUrl env
      ChainwebVersion network = _env_chainwebVersion env
      path = printf "/chainweb/0.0/%s/chain/%d/pact" network chain
      cenv = mkClientEnv (_env_httpManager env) (BaseUrl Https h p path)
  cmd <- mkPactCommand (NetworkId network) (ChainId $ T.pack $ show chain) coinQuery
  eres <- runClientM (pactLocal cmd) cenv
  return $ do
    cr <- fmapL (const "Network error") eres
    let PactResult pr = _crResult cr
    pv <- fmapL (const "Pact error") pr
    case pv of
      PLiteral l -> note "Unexpected literal" $ l ^? _LDecimal
      _ -> Left "Unexpected pact value"

mkPublicMeta :: ChainId -> TxCreationTime -> PublicMeta
mkPublicMeta chain ct =
  PublicMeta chain "nosender" 10000000 0.000000000001 600 (ct - 60)

mkPactCommand :: NetworkId -> ChainId -> String -> IO (Command Text)
mkPactCommand network chain code = do
    ct <- getCurrentCreationTime
    let pm = mkPublicMeta chain ct
    mkExec code Null pm [] (Just network) Nothing


pactSend :: SubmitBatch -> ClientM RequestKeys
pactPoll :: Poll -> ClientM PollResponses
pactListen :: ListenerRequest -> ClientM ListenResponse
pactLocal :: Command Text -> ClientM (CommandResult Hash)

pactSend :<|> pactPoll :<|> pactListen :<|> pactLocal = client apiV1API
