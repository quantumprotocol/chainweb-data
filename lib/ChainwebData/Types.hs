{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module ChainwebData.Types
  ( -- * Types
    PowHeader(..)
  , asBlock
  , hashToDbHash
    -- * Utils
  , groupsOf
  ) where

import           BasePrelude
import           Chainweb.Api.BlockHeader
import           Chainweb.Api.BytesLE
import           Chainweb.Api.ChainId (ChainId(..))
import           Chainweb.Api.Hash
import           Chainweb.Api.MinerData
import           ChainwebDb.Types.Block
import           ChainwebDb.Types.DbHash (DbHash(..))
import           Data.Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import           Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import           Control.Lens
import           Data.Aeson.Lens
import           Network.Wai.EventSource.Streaming

---

data PowHeader = PowHeader
  { _hwp_header :: BlockHeader
  , _hwp_powHash :: T.Text }

instance FromEvent PowHeader where
  fromEvent bs = do
    hu <- decode' @Value $ BL.fromStrict bs
    PowHeader
      <$> (hu ^? key "header"  . _JSON)
      <*> (hu ^? key "powHash" . _JSON)

asBlock :: PowHeader -> MinerData -> Block
asBlock (PowHeader bh ph) m = Block
  { _block_creationTime = posixSecondsToUTCTime $ _blockHeader_creationTime bh
  , _block_chainId      = unChainId $ _blockHeader_chainId bh
  , _block_height       = _blockHeader_height bh
  , _block_parent       = DbHash . hashB64U $ _blockHeader_parent bh
  , _block_hash         = DbHash . hashB64U $ _blockHeader_hash bh
  , _block_payload      = DbHash . hashB64U $ _blockHeader_payloadHash bh
  , _block_target       = fromInteger $ leToInteger $ unBytesLE $ _blockHeader_target bh
  , _block_weight       = fromInteger $ leToInteger $ unBytesLE $ _blockHeader_weight bh
  , _block_epochStart   = posixSecondsToUTCTime $ _blockHeader_epochStart bh
  , _block_nonce        = _blockHeader_nonce bh
  , _block_flags        = _blockHeader_flags bh
  , _block_powHash      = DbHash ph
  , _block_miner_acc    = _minerData_account m
  , _block_miner_pred   = _minerData_predicate m }

-- | Convert to the "pretty" hash representation that URLs, etc., expect.
hashToDbHash :: Hash -> DbHash
hashToDbHash = DbHash . hashB64U

-- | Break a list into groups of @n@ elements. The last item in the result is
-- not guaranteed to have the same length as the others.
groupsOf :: Int -> [a] -> [[a]]
groupsOf n as
  | n <= 0 = []
  | otherwise = go as
  where
    go [] = []
    go bs = xs : go rest
      where
        (xs, rest) = splitAt n bs

--------------------------------------------------------------------------------
-- Orphans

instance ToJSON BlockHeader where
  toJSON _ = object []
