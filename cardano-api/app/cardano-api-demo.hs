
import           Cardano.Api

import           Cardano.Prelude

import qualified Data.ByteString.Char8 as BS

main :: IO ()
main = do
  keyPair <- byronGenKeyPair
  BS.putStrLn $ renderKeyPairView keyPair

  -- Could also be 'Testnet x'.
  let pubKey = mkPublicKey keyPair
  BS.putStrLn $ renderPublicKeyView pubKey

  let addr = byronPubKeyAddress pubKey Mainnet
  BS.putStrLn $ renderAddressView addr
