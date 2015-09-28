{-# LANGUAGE OverloadedStrings, TypeSynonymInstances, FlexibleInstances #-}
import qualified Data.Aeson as A
import Data.Maybe
import Data.Either (partitionEithers)
import Data.Word
import Data.Monoid
import Data.Scientific
import Data.String
import Data.Char (isDigit,toLower)
import qualified Data.RFC1751 as RFC1751
import System.Environment
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as LBS
import Crypto.MAC.HMAC (hmac)
import qualified Crypto.Hash.SHA224 as SHA224 (hash)
import qualified Crypto.Hash.SHA384 as SHA384 (hash)
import Crypto.PBKDF (sha1PBKDF1
                    ,sha256PBKDF1
                    ,sha512PBKDF1
                    ,sha1PBKDF2
                    ,sha256PBKDF2
                    ,sha512PBKDF2
                    )

import Network.Haskoin.Crypto hiding (derivePubPath, derivePath)
import Network.Haskoin.Internals ( curveP, curveN, curveG, integerA, integerB
                                 , getX, getY, addPoint, doublePoint, mulPoint
                                 , makeInfPoint, pubKeyPoint
                                 , OutPoint(OutPoint), Tx(..), Script
                                 , SigHash(SigAll), TxSignature(TxSignature)
                                 , TxIn(..)
                                 , buildAddrTx, txSigHash, encodeSig, decodeSig
                                 , getOutputAddress, decodeOutput
                                 , fromMnemonic
                                 )
import Network.Haskoin.Util
import PrettyScript
import ParseScript
import Mnemonic (hex_to_mn, mn_to_hex)
import DetailedTx (txDetailedJSON,DetailedXPrvKey(..),DetailedXPubKey(..))
import Utils
import Electrum

type TxFile = BS

readTxFile :: TxFile -> IO Tx
readTxFile file = getHex "transaction" <$> BS.readFile (B8.unpack file)

one_btc_in_satoshi :: Num a => a
one_btc_in_satoshi = 10^(8 :: Int)

class Compress a where
  compress   :: a -> a
  uncompress :: a -> a

instance Compress PrvKey where
  compress = toPrvKeyG . fromJust . makePrvKeyC . fromPrvKey
  uncompress = toPrvKeyG . fromJust . makePrvKeyU . fromPrvKey

instance Compress PubKey where
  compress = toPubKeyG . makePubKeyC . pubKeyPoint
  uncompress = toPubKeyG . makePubKeyU . pubKeyPoint

instance Compress Key where
  compress = mapKey compress compress
  uncompress = mapKey uncompress uncompress

decodeBase58E :: BS -> BS
decodeBase58E = fromMaybe (error "invalid base58 encoding") . decodeBase58 . ignoreSpaces

xPrvImportBS :: BS -> Maybe XPrvKey
xPrvImportBS s | "xprv" `BS.isPrefixOf` s = xPrvImport (B8.unpack s)
               | otherwise                = Just $ makeXPrvKey (decodeHex "seed" s)

xPubImportBS :: BS -> Maybe XPubKey
xPubImportBS = xPubImport . B8.unpack

xPrvExportBS :: XPrvKey -> BS
xPrvExportBS = B8.pack . xPrvExport

xPubExportBS :: XPubKey -> BS
xPubExportBS = B8.pack . xPubExport

xPrvImportE :: BS -> XPrvKey
xPrvImportE = fromMaybe (error "invalid extended private key") . xPrvImportBS . ignoreSpaces

data XKey = XPub XPubKey | XPrv XPrvKey

onXKey :: (XPrvKey -> a) -> (XPubKey -> a) -> XKey -> a
onXKey onXPrv _      (XPrv k) = onXPrv k
onXKey _      onXPub (XPub k) = onXPub k

mapXKey :: (XPrvKey -> XPrvKey) -> (XPubKey -> XPubKey) -> XKey -> XKey
mapXKey onXPrv onXPub = onXKey (XPrv . onXPrv) (XPub . onXPub)

xKeyImport :: BS -> Maybe XKey
xKeyImport s
  | "xpub" `BS.isPrefixOf` s = XPub <$> xPubImportBS s
  | otherwise                = XPrv <$> xPrvImportBS s

xKeyImportE :: BS -> XKey
xKeyImportE = fromMaybe (error "invalid extended public or private key") . xKeyImport . ignoreSpaces

xKeyDetails :: XKey -> BS
xKeyDetails = toStrictBS . A.encode . onXKey (A.toJSON . DetailedXPrvKey) (A.toJSON . DetailedXPubKey)

pubXKey :: XKey -> XPubKey
pubXKey (XPub k) = k
pubXKey (XPrv k) = deriveXPubKey k

xMasterImportE :: Hex s => s -> XPrvKey
xMasterImportE = makeXPrvKey . decodeHex "seed"

xKeyExportC :: Char -> XKey -> BS
xKeyExportC 'A' = addrToBase58BS . xPubAddr . pubXKey
xKeyExportC 'P' = putHex . xPubKey . pubXKey
xKeyExportC 'U' = putHex . uncompress . toPubKeyG . xPubKey . pubXKey
xKeyExportC 'M' = xPubExportBS . pubXKey
xKeyExportC 'p' = onXKey (B8.pack . xPrvWif)
                         (error "Private keys can not be derived from extended public keys (expected P/, U/ or M/ not p/)")
xKeyExportC 'u' = onXKey (toWIFBS . uncompress . toPrvKeyG . xPrvKey)
                         (error "Uncompressed private keys can not be derived from extended public keys (expected P/, U/ or M/ not u/)")
xKeyExportC 'm' = onXKey xPrvExportBS
                         (error "Extended private keys can not be derived from extended public keys (expected M/ not m/)")
xKeyExportC  c  = onXKey (error $ "Root path expected to be m/, M/, A/, P/, p/, U/, or u/ not " ++ c : "/")
                         (error $ "Root path expected to be M/, A/, or P/ not " ++ c : "/")

{-
derivePath does not completly subsumes derivePrvPath
as the type is more precise.
-}

derivePrvPath :: String -> XPrvKey -> XPrvKey
derivePrvPath []       = id
derivePrvPath ('/':xs) = goIndex $ span isDigit xs
  where
  goIndex ([], _)       = error "derivePrvPath: empty path segment"
  goIndex (ys, '\'':zs) = derivePrvPath zs . flip primeSubKeyE (read ys)
                        {- This read works because (all isDigit ys && not (null ys)) holds -}
  goIndex (ys, zs)      = derivePrvPath zs . flip prvSubKeyE   (read ys)
                        {- This read works because (all isDigit ys && not (null ys)) holds -}
derivePrvPath _ = error "malformed path"

derivePubPath :: String -> XPubKey -> XPubKey
derivePubPath []       = id
derivePubPath ('/':xs) = goIndex $ span isDigit xs
  where
  goIndex ([], _)     = error "derivePubPath: empty path segment"
  goIndex (_, '\'':_) = error "derivePubPath: hardened subkeys are inaccessible from extended public keys"
  goIndex (ys, zs)    = derivePubPath zs . flip pubSubKeyE (read ys)
                        {- This read works because (all isDigit ys && not (null ys)) holds -}
derivePubPath _ = error "malformed path"

derivePath :: String -> XKey -> XKey
derivePath p = mapXKey (derivePrvPath p) (derivePubPath p)

fromWIFE :: BS -> PrvKey
fromWIFE = fromMaybe (error "invalid WIF private key") . fromWif . B8.unpack . ignoreSpaces

toWIFBS :: PrvKey -> BS
toWIFBS = B8.pack . toWif

base58ToAddrE :: BS -> Address
base58ToAddrE = fromMaybe (error "invalid bitcoin address") . base58ToAddr . B8.unpack . ignoreSpaces

prvSubKeyE :: XPrvKey -> Word32 -> XPrvKey
prvSubKeyE k = prvSubKey k

primeSubKeyE :: XPrvKey -> Word32 -> XPrvKey
primeSubKeyE k = hardSubKey k

pubSubKeyE :: XPubKey -> Word32 -> XPubKey
pubSubKeyE k = pubSubKey k

splitOnBS :: Char -> BS -> (BS,BS)
splitOnBS c s =
  case B8.span (/= c) s of
    (s1, s2) -> (s1, BS.drop 1 s2)

readOutPoint :: BS -> OutPoint
readOutPoint xs = OutPoint (getHexLE "transaction hash" ys) (parseWord32 "output point index" zs) where (ys,zs) = splitOnBS ':' xs

readOutput :: BS -> (String,Word64)
readOutput xs = (B8.unpack ys, parseWord64 "output index" zs) where (ys,zs) = splitOnBS ':' xs

mktx_args :: [BS] -> [Either OutPoint (String,Word64)]
mktx_args [] = []
mktx_args ( "--input":input :args) = Left (readOutPoint input) : mktx_args args
mktx_args (      "-i":input :args) = Left (readOutPoint input) : mktx_args args
mktx_args ("--output":output:args) = Right (readOutput output) : mktx_args args
mktx_args (      "-o":output:args) = Right (readOutput output) : mktx_args args
mktx_args (arg:_) = error $ "mktx_args: unexpected argument " ++ show arg

putTxSig :: Hex s => TxSignature -> s
putTxSig = encodeHex . encodeSig

getTxSig :: Hex s => s -> TxSignature
getTxSig = either error id . decodeSig . decodeHex "transaction signature"

getPubKey :: Hex s => s -> PubKey
getPubKey = getHex "public key"

data Key = Prv PrvKey | Pub PubKey
  deriving (Eq, Show, Read)

onKey :: (PrvKey -> a) -> (PubKey -> a) -> Key -> a
onKey onPrv _     (Prv k) = onPrv k
onKey _     onPub (Pub k) = onPub k

getKey :: BS -> Key
getKey s | Just('0',_) <- B8.uncons s = Pub $ getPubKey s
         | otherwise                  = Prv $ fromWIFE  s

putKey :: Key -> BS
putKey = onKey toWIFBS putHex

mapKey :: (PrvKey -> PrvKey) -> (PubKey -> PubKey) -> Key -> Key
mapKey onPrv onPub = onKey (Prv . onPrv) (Pub . onPub)

pubKey :: Key -> PubKey
pubKey (Prv k) = derivePubKey k
pubKey (Pub k) = k

keyAddr :: Key -> Address
keyAddr = pubKeyAddr . pubKey

addrToBase58BS :: Address -> BS
addrToBase58BS = B8.pack . addrToBase58

keyAddrBase58 :: Key -> BS
keyAddrBase58 = addrToBase58BS . keyAddr

hx_compress :: BS -> BS
hx_compress = putKey . compress . getKey

hx_uncompress :: BS -> BS
hx_uncompress = putKey . uncompress . getKey

hx_mktx :: Hex s => [BS] -> s
hx_mktx args = putHex . either error id . uncurry buildAddrTx
             . partitionEithers . mktx_args $ args

hx_pubkey :: Hex s => [BS] -> BS -> s
hx_pubkey args = putHex . compressIf . pubKey . compat . getKey
  where compressIf :: PubKey -> PubKey
        compressIf = case args of
          [] -> id
          [o] | B8.map toLower o `elem` ["1","true","yes","--compressed","-c"]   -> compress
              | B8.map toLower o `elem` ["0","false","no","--uncompressed","-u"] -> uncompress
          _ -> error "Usage: hx pubkey [--uncompressed|--compressed]"

        -- This is for compatibility with `sx', namely if one gives a
        -- compressed public key with no compression argument the key
        -- is uncompressed.
        -- I would prefer to do nothing here instead.
        compat = mapKey id uncompress

hx_addr :: BS -> BS
hx_addr = keyAddrBase58 . getKey

hx_wif_to_secret :: Hex s => BS -> s
hx_wif_to_secret = encodeHex . runPut' . prvKeyPutMonad . fromWIFE

hx_secret_to_wif :: BS -> BS
hx_secret_to_wif = toWIFBS . fromMaybe (error "invalid private key")
                 . makePrvKey . bsToInteger
                 . decodeHex "private key"

hx_hd_to_wif :: BS -> BS
hx_hd_to_wif = B8.pack . xPrvWif . xPrvImportE

hx_hd_to_address :: BS -> BS
hx_hd_to_address = addrToBase58BS . xPubAddr . pubXKey . xKeyImportE

hx_hd_to_pubkey :: Hex s => BS -> s
hx_hd_to_pubkey = putHex . xPubKey . pubXKey . xKeyImportE

hx_hd_priv :: Maybe (XPrvKey -> Word32 -> XPrvKey, Word32) -> BS -> BS
hx_hd_priv Nothing         = xPrvExportBS . xMasterImportE
hx_hd_priv (Just (sub, i)) = xPrvExportBS . flip sub i . xPrvImportE

hx_hd_pub :: Maybe Word32 -> BS -> BS
hx_hd_pub mi = xPubExportBS . f . pubXKey . xKeyImportE
  where f = maybe id (flip pubSubKeyE) mi

hx_hd_path :: BS -> BS -> BS
hx_hd_path mp =
  case B8.unpack mp of
    []    -> error "Empty path"
    (m:p) -> xKeyExportC m . derivePath p . xKeyImportE

hx_hd_decode :: BS -> BS
hx_hd_decode = xKeyDetails . xKeyImportE

hx_bip39_mnemonic :: Hex s => s -> BS
hx_bip39_mnemonic = either error B8.pack . toMnemonic . decodeHex "mnemonic-as-hex"

hx_bip39_hex :: Hex s => BS -> s
hx_bip39_hex = encodeHex . either error id . fromMnemonic . B8.unpack

hx_bip39_seed :: Hex s => {-passphrase-}BS -> {-mnemonic-}BS -> s
hx_bip39_seed pf = encodeHex . either error id . mnemonicToSeed (B8.unpack pf) . f . B8.unpack
  where f s | isHex s   = either (const s) id (toMnemonic (decodeHex "seed" s))
            | otherwise = s

hx_btc, hx_satoshi :: BS -> BS
hx_btc     = B8.pack . formatScientific Fixed (Just 8) . (/ one_btc_in_satoshi) . readBS
hx_satoshi = B8.pack . formatScientific Fixed (Just 0) . (* one_btc_in_satoshi) . readBS

putSuccess :: IsString s => Bool -> s
putSuccess True  = "Status: Success"
putSuccess False = "Status: Invalid"

-- Just here to conform to `sx'
putSuccess' :: Bool -> BS
putSuccess' True = "Status: OK"
putSuccess'  _   = "Status: Failed"

hx_validaddr :: BS -> BS
hx_validaddr = putSuccess . isJust . base58ToAddr . B8.unpack . trim
  -- Discaring the spaces seems a bit overzealous here
  where trim = B8.unwords . B8.words

hx_decode_addr :: Hex s => BS -> s
hx_decode_addr = putHex . getAddrHash . base58ToAddrE

hx_encode_addr :: Hex s => (Word160 -> Address) -> s -> BS
hx_encode_addr f = addrToBase58BS . f . getHex "address"

hx_base58_encode :: Hex s => s -> BS
hx_base58_encode = encodeBase58 . decodeHex "input"

hx_base58_decode :: Hex s => BS -> s
hx_base58_decode = encodeHex . decodeBase58E

hx_base58check_encode :: Hex s => [BS] -> s -> BS
hx_base58check_encode args = encodeBase58Check
                           . BS.cons ver
                           . decodeHex "input"
  where ver = case args of
                []  -> 1
                [x] -> parseWord8 "version byte" x
                _   -> error "Usage: hx base58check-encode [<VERSION-BYTE>]"

hx_base58check_decode :: [BS] -> BS -> BS
hx_base58check_decode args
  | null args = wrap . BS.uncons . chksum32_decode . decodeBase58E
  | otherwise = error "Usage: hx base58check-decode"
  where wrap (Just (x,xs)) = encodeHex xs <> " " <> showB8 x
        wrap Nothing       = ""

hx_mnemonic :: BS -> BS
hx_mnemonic s = case B8.words s of
  []  -> error "mnemonic: expects either one hexadecimal string or a list of words"
  [x] -> let (y,z) = hex_to_mn x in
         if BS.null z
           then B8.unwords y
           else error "mnemonic: invalid hex encoding"
  xs  -> mn_to_hex xs

hx_rfc1751_key :: Hex s => BS -> s
hx_rfc1751_key = encodeHex
               . fromMaybe (error "invalid RFC1751 mnemonic") . RFC1751.mnemonicToKey
               . B8.unpack

hx_rfc1751_mnemonic :: Hex s => s -> BS
hx_rfc1751_mnemonic = B8.pack
                    . fromMaybe (error "invalid RFC1751 128 bits key") . RFC1751.keyToMnemonic
                    . decodeHex "128 bits key"

brainwallet :: BS -> BS
brainwallet = toWIFBS . makePrvKeyU256 . hash256BS
      -- OR = encodeBase58 . chksum32_encode . BS.cons 128 . hash256BS

hx_brainwallet :: [BS] -> BS
hx_brainwallet [x]           = brainwallet $ x
hx_brainwallet []            = error . brainwallet_usage $ "too few arguments"
hx_brainwallet (x:_)
  | "-" `BS.isPrefixOf` x    = error . brainwallet_usage $ "unexpected argument, " ++ show x
  | otherwise                = error . brainwallet_usage $ "too many arguments"

brainwallet_usage :: String -> String
brainwallet_usage msg = unlines [msg, "Usage: hx brainwallet <PASSPHRASE>"]

getSig :: BS -> Signature
getSig = getHex "signature"

hx_verifysig_modn :: [BS] -> BS
hx_verifysig_modn [msg,pub,sig] = putSuccess $ verifySig (fromIntegral $ getDecStrictN msg) (getSig sig) (getPubKey pub)
hx_verifysig_modn _ = error "Usage: hx verifysig-modn <MESSAGE-DECIMAL-INTEGER> <PUBKEY> <SIGNATURE>"

hx_signmsg_modn :: [BS] -> BS
hx_signmsg_modn [msg,prv] = putHex $ detSignMsg (fromIntegral $ getDecStrictN msg) (fromWIFE prv)
hx_signmsg_modn _ = error "Usage: hx signmsg-modn <MESSAGE-DECIMAL-INTEGER> <PRIVKEY>"

-- set-input FILENAME N SIGNATURE_AND_PUBKEY_SCRIPT
hx_set_input :: TxFile -> BS -> BS -> IO ()
hx_set_input file index script =
  do tx <- readTxFile file
     B8.putStrLn . putHex $ hx_set_input' (parseInt "input index" index) (decodeHex "script" script) tx

hx_set_input' :: Int -> BS.ByteString -> Tx -> Tx
hx_set_input' i si tx = tx{ txIn = updateIndex i (txIn tx) f }
  where f x = x{ scriptInput = si }

hx_validsig' :: Tx -> Int -> Script -> TxSignature -> PubKey -> Bool
hx_validsig' tx i out (TxSignature sig sh) pub =
  pubKeyAddr pub == a && verifySig (txSigHash tx out i sh) sig pub
  where a = getOutputAddress (either error id (decodeOutput out))

hx_validsig :: TxFile -> BS -> BS -> BS -> IO ()
hx_validsig file i s sig =
  do tx <- readTxFile file
     interactLn $ putSuccess'
                . hx_validsig' tx (parseInt "input index" i) (getHex "script" s) (getTxSig sig)
                . getPubKey

hx_sign_input :: TxFile -> BS -> BS -> IO ()
hx_sign_input file index script_code =
  do tx <- readTxFile file
     interactLn $ putTxSig . hx_sign_input' tx (parseInt "input index" index) (getHex "script" script_code) . fromWIFE

-- The pure and typed counter part of hx_sign_input
hx_sign_input' :: Tx -> Int -> Script -> PrvKey -> TxSignature
hx_sign_input' tx index script_output privkey = sig where
  sh  = SigAll False
  msg = txSigHash  tx script_output index sh
  sig = TxSignature (detSignMsg msg privkey) sh

hx_rawscript :: BS -> BS
hx_rawscript = putHex . parseReadP parseScript . B8.unpack

hx_showscript :: BS -> BS
hx_showscript = B8.pack . showDoc . prettyScript . getHex "script"

hx_showtx :: [BS] -> IO ()
hx_showtx [] = LBS.interact $ txDetailedJSON . getHex "transaction"
hx_showtx ["-"] = LBS.interact $ txDetailedJSON . getHex "transaction"
hx_showtx [file] = LBS.putStr . txDetailedJSON =<< readTxFile file
hx_showtx ("-j":xs) = hx_showtx xs
hx_showtx ("--json":xs) = hx_showtx xs
hx_showtx _ = error "Usage: hx showtx [-j|--json] [<TXFILE>]"

hx_hmac :: String -> (BS -> BS) -> Int -> [BS] -> BS
hx_hmac _ h s [key,input] = encodeHex $ hmac h s (decodeHex "hmac key" key) (decodeHex "hmac data" input)
hx_hmac m _ _ _           = error $ "hx hmac-" ++ m ++ " <HEX-KEY> [<HEX-INPUT>]"

hx_PBKDF1 :: (String -> String -> Int -> String) -> BS -> [BS] -> IO ()
hx_PBKDF1 f m = interactArgsLn go
  where
    usage = "hx " ++ B8.unpack m ++ " [--hex] <PASSWORD> [--hex] <SALT> <COUNT>"
    go args0 = let (password,args1) = get_hex_arg "password" usage args0
                   (salt,args2)     = get_hex_arg "salt"     usage args1
                   (count,args3)    = get_int_arg "count"    usage args2
               in no_args usage args3 . B8.pack $ f (B8.unpack password) (B8.unpack salt) count

hx_PBKDF2 :: (String -> String -> Int -> Int -> String) -> BS -> [BS] -> IO ()
hx_PBKDF2 f m = interactArgsLn go
  where
    usage = "hx " ++ B8.unpack m ++ " [--hex] <PASSWORD> [--hex] <SALT> <COUNT> <LENGTH>"
    go args0 = let (password,args1) = get_hex_arg "password" usage args0
                   (salt,args2)     = get_hex_arg "salt"     usage args1
                   (count,args3)    = get_int_arg "count"    usage args2
                   (len,args4)      = get_int_arg "length"   usage args3
               in no_args usage args4 . B8.pack $ f (B8.unpack password) (B8.unpack salt) count len

chksum32_encode :: BS -> BS
chksum32_encode d = d <> encode' (chksum32 d)

chksum32_decode :: BS -> BS
chksum32_decode d | chksum32 pre == decode' post = pre
                  | otherwise                    = error "checksum does not match"
  where (pre,post) = BS.splitAt (BS.length d - 4) d

hx_chksum32 :: [BS] -> BS
hx_chksum32 = withHex (encode' . chksum32) . BS.concat

hx_chksum32_encode :: [BS] -> BS
hx_chksum32_encode = withHex chksum32_encode . BS.concat

hx_chksum32_decode :: [BS] -> BS
hx_chksum32_decode = withHex chksum32_decode . BS.concat

hx_ec_double :: Hex s => [s] -> s
hx_ec_double [p] = putPoint $ doublePoint (getPoint p)
hx_ec_double _   = error "Usage: hx ec-double [<HEX-POINT>]"

hx_ec_multiply :: Hex s => [s] -> s
hx_ec_multiply [x, p] = putPoint $ mulPoint (getHexN x) (getPoint p)
hx_ec_multiply _      = error "Usage: hx ec-multiply <HEX-FIELDN> <HEX-POINT>"

hx_ec_add :: Hex s => [s] -> s
hx_ec_add [p, q] = putPoint $ addPoint (getPoint p) (getPoint q)
hx_ec_add _      = error "Usage: hx ec-add <HEX-POINT> <HEX-POINT>"

hx_ec_tweak_add :: Hex s => [s] -> s
hx_ec_tweak_add [x, p] = putPoint $ addPoint (mulPoint (getHexN x) curveG) (getPoint p)
hx_ec_tweak_add _      = error "Usage: hx ec-tweak-add <HEX-FIELDN> <HEX-POINT>"

hx_ec_add_modp :: Hex s => [s] -> s
hx_ec_add_modp [x, y] = putHexP $ getHexP x + getHexP y
hx_ec_add_modp _      = error "Usage: hx ec-add-modp <HEX-FIELDP> <HEX-FIELDP>"

hx_ec_add_modn :: Hex s => [s] -> s
hx_ec_add_modn [x, y] = putHexN $ getHexN x + getHexN y
hx_ec_add_modn _      = error "Usage: hx ec-add-modn <HEX-FIELDN> <HEX-FIELDN>"

hx_ec_int_modp :: [BS] -> BS
hx_ec_int_modp [x] = putHexP $ getDecModP x
hx_ec_int_modp _   = error "Usage: hx ec-int-modp [<DECIMAL-INTEGER>]"

hx_ec_int_modn :: [BS] -> BS
hx_ec_int_modn [x] = putHexN $ getDecModN x
hx_ec_int_modn _   = error "Usage: hx ec-int-modn [<DECIMAL-INTEGER>]"

hx_ec_x :: Hex s => [s] -> s
hx_ec_x [p] = putHexP . fromMaybe (error "invalid point") . getX $ getPoint p
hx_ec_x _   = error "Usage: hx ec-x [<HEX-POINT>]"

hx_ec_y :: Hex s => [s] -> s
hx_ec_y [p] = putHexP . fromMaybe (error "invalid point") . getY $ getPoint p
hx_ec_y _   = error "Usage: hx ec-y [<HEX-POINT>]"

mainArgs :: [BS] -> IO ()
mainArgs ["addr"]                    = interactLn hx_addr
mainArgs ("validaddr":args)          = interactArgLn "hx validaddr [<ADDRESS>]" hx_validaddr args
mainArgs ["encode-addr", "--script"] = interactLn $ hx_encode_addr ScriptAddress
mainArgs ["encode-addr"]             = interactLn $ hx_encode_addr PubKeyAddress
mainArgs ["decode-addr"]             = interactLn hx_decode_addr

mainArgs ("pubkey":args)             = interactLn $ hx_pubkey args
mainArgs ("brainwallet":args)        = B8.putStrLn $ hx_brainwallet args
mainArgs ["wif-to-secret"]           = interactLn hx_wif_to_secret
mainArgs ["secret-to-wif"]           = interactLn hx_secret_to_wif
mainArgs ["compress"]                = interactLn hx_compress
mainArgs ["uncompress"]              = interactLn hx_uncompress

mainArgs ["hd-priv"]                 = interactLn $ hx_hd_priv   Nothing
mainArgs ["hd-priv", i]              = interactLn . hx_hd_priv $ Just (prvSubKeyE,   parseWord32 "hd-priv index" i)
mainArgs ["hd-priv", "--hard", i]    = interactLn . hx_hd_priv $ Just (primeSubKeyE, parseWord32 "hd-priv index" i)
mainArgs ["hd-pub"]                  = interactLn $ hx_hd_pub    Nothing
mainArgs ["hd-pub", i]               = interactLn . hx_hd_pub  . Just $ parseWord32 "hd-pub index" i
mainArgs ["hd-path", p]              = interactLn $ hx_hd_path p
mainArgs ["hd-decode"]               = interactLn hx_hd_decode
mainArgs ["hd-to-wif"]               = interactLn hx_hd_to_wif
mainArgs ["hd-to-pubkey"]            = interactLn hx_hd_to_pubkey
mainArgs ["hd-to-address"]           = interactLn hx_hd_to_address

mainArgs ["bip39-mnemonic"]          = interactLn hx_bip39_mnemonic
mainArgs ["bip39-hex"]               = interactLn hx_bip39_hex
mainArgs ["bip39-seed"]              = interactLn $ hx_bip39_seed ""
mainArgs ["bip39-seed", pass]        = interactLn $ hx_bip39_seed pass

mainArgs ["rfc1751-key"]             = interactLn hx_rfc1751_key
mainArgs ["rfc1751-mnemonic"]        = interactLn hx_rfc1751_mnemonic
mainArgs ["mnemonic"]                = interactLn hx_mnemonic

mainArgs ("btc":args)                = interactArgLn "hx btc [<SATOSHIS>]" hx_btc     args
mainArgs ("satoshi":args)            = interactArgLn "hx satoshi [<BTCS>]" hx_satoshi args
mainArgs ["base58-encode"]           = interactLn hx_base58_encode
mainArgs ["base58-decode"]           = interactLn hx_base58_decode
mainArgs ("base58check-encode":args) = interactLn $ hx_base58check_encode args
mainArgs ("base58check-decode":args) = interactLn $ hx_base58check_decode args
mainArgs ["integer"]                 = interactLn $ showB8 . bsToInteger . decodeHex "input"
mainArgs ["hex-encode"]              = interactLn encodeHex
mainArgs ["hex-decode"]              = BS.interact $ decodeHex "input"
mainArgs ["encode-hex"]{-deprecated-}= interactLn encodeHex
mainArgs ["decode-hex"]{-deprecated-}= BS.interact $ decodeHex "input"

mainArgs ["ripemd-hash"]             = interactLn $ encodeHex . hash160BS . hash256BS
mainArgs ("ripemd160":args)          = interactHex "hx ripemd160 [<HEX-INPUT>]" hash160BS               args
mainArgs ("sha256":args)             = interactHex "hx sha256    [<HEX-INPUT>]" hash256BS               args
mainArgs ("sha1":args)               = interactHex "hx sha1      [<HEX-INPUT>]" hashSha1BS              args
mainArgs ("hash256":args)            = interactHex "hx hash256   [<HEX-INPUT>]" doubleHash256BS         args
mainArgs ("hash160":args)            = interactHex "hx hash160   [<HEX-INPUT>]" (hash160BS . hash256BS) args

mainArgs ("hmac-sha224":args)        = interactArgsLn (hx_hmac "sha224" SHA224.hash 64)  args
mainArgs ("hmac-sha256":args)        = interactArgsLn (hx_hmac "sha256" hash256BS   64)  args
mainArgs ("hmac-sha384":args)        = interactArgsLn (hx_hmac "sha384" SHA384.hash 128) args
mainArgs ("hmac-sha512":args)        = interactArgsLn (hx_hmac "sha512" hash512BS   128) args
mainArgs (arg@"sha1pbkdf1":args)     = hx_PBKDF1 sha1PBKDF1   arg args
mainArgs (arg@"sha256pbkdf1":args)   = hx_PBKDF1 sha256PBKDF1 arg args
mainArgs (arg@"sha512pbkdf1":args)   = hx_PBKDF1 sha512PBKDF1 arg args
mainArgs (arg@"sha1pbkdf2":args)     = hx_PBKDF2 sha1PBKDF2   arg args
mainArgs (arg@"sha256pbkdf2":args)   = hx_PBKDF2 sha256PBKDF2 arg args
mainArgs (arg@"sha512pbkdf2":args)   = hx_PBKDF2 sha512PBKDF2 arg args

mainArgs ("chksum32":args)           = interactArgs hx_chksum32        args
mainArgs ("chksum32-encode":args)    = interactArgs hx_chksum32_encode args
mainArgs ("chksum32-decode":args)    = interactArgs hx_chksum32_decode args

mainArgs ("ec-double":args)          = interactArgsLn hx_ec_double    args
mainArgs ("ec-add":args)             = interactArgsLn hx_ec_add       args
mainArgs ("ec-multiply":args)        = interactArgsLn hx_ec_multiply  args
mainArgs ("ec-tweak-add":args)       = interactArgsLn hx_ec_tweak_add args
mainArgs ("ec-add-modp":args)        = interactArgsLn hx_ec_add_modp  args
mainArgs ("ec-add-modn":args)        = interactArgsLn hx_ec_add_modn  args
mainArgs ["ec-g"]                    = B8.putStrLn $ putPoint curveG
mainArgs ["ec-p"]                    = B8.putStrLn $ putHex256 (fromInteger curveP  )
mainArgs ["ec-n"]                    = B8.putStrLn $ putHex256 (fromInteger curveN  )
mainArgs ["ec-a"]                    = B8.putStrLn $ putHex256 (fromInteger integerA)
mainArgs ["ec-b"]                    = B8.putStrLn $ putHex256 (fromInteger integerB)
mainArgs ["ec-inf"]                  = B8.putStrLn $ putPoint makeInfPoint
mainArgs ("ec-int-modp":args)        = interactArgsLn hx_ec_int_modp args
mainArgs ("ec-int-modn":args)        = interactArgsLn hx_ec_int_modn args
mainArgs ("ec-x":args)               = interactArgsLn hx_ec_x args
mainArgs ("ec-y":args)               = interactArgsLn hx_ec_y args

mainArgs ("mktx":file:args)          = interactFileArgs hx_mktx file args
mainArgs ["sign-input",f,i,s]        = hx_sign_input f i s
mainArgs ["set-input",f,i,s]         = hx_set_input f i s
mainArgs ["validsig",f,i,s,sig]      = hx_validsig f i s sig
mainArgs ("showtx":args)             = hx_showtx args

mainArgs ("verifysig-modn":args)     = interactArgsLn hx_verifysig_modn args
mainArgs ("signmsg-modn":args)       = interactArgsLn hx_signmsg_modn   args

mainArgs ("rawscript":args)          = interactArgsLn (hx_rawscript . B8.unwords) args
mainArgs ["showscript"]              = interactLn $ hx_showscript

mainArgs ["electrum-mpk"]            = interactLn   hx_electrum_mpk
mainArgs ("electrum-priv":args)      = interactLn $ hx_electrum_priv args
mainArgs ("electrum-pub":args)       = interactLn $ hx_electrum_pub  args
mainArgs ("electrum-addr":args)      = interactLn $ hx_electrum_addr args
mainArgs ("electrum-seq":args)       = interactLn $ hx_electrum_sequence args
mainArgs ["electrum-stretch-seed"]   = interactLn   hx_electrum_stretch_seed

mainArgs _ = error $ unlines ["Unexpected arguments."
                             ,""
                             ,"List of supported commands:"
                             ,""
                             ,"Command names are case-insensitive: SHA256 is equivalent to sha256."
                             ,""
                             ,"# ADDRESSES"
                             ,"hx addr"
                             ,"hx validaddr [<ADDRESS>]"
                             ,"hx decode-addr"
                             ,"hx encode-addr"
                             ,"hx encode-addr --script                   [0]"
                             ,""
                             ,"# KEYS"
                             ,"hx pubkey [--compressed|--uncompressed]"
                             ,"hx wif-to-secret"
                             ,"hx secret-to-wif"
                             ,"hx brainwallet <PASSPHRASE>"
                             ,"hx compress                               [0]"
                             ,"hx uncompress                             [0]"
                             ,""
                             ,"# SCRIPTS"
                             ,"hx rawscript <SCRIPT_OP>*"
                             ,"hx showscript"
                             ,""
                             ,"# TRANSACTIONS"
                             ,"hx mktx <TXFILE> --input <TXHASH>:<INDEX> ... --output <ADDR>:<AMOUNT>"
                             ,"hx showtx [-j|--json] <TXFILE>            [1]"
                             ,"hx sign-input <TXFILE> <INDEX> <SCRIPT_CODE>"
                             ,"hx set-input  <TXFILE> <INDEX> <SIGNATURE_AND_PUBKEY_SCRIPT>"
                             ,"hx validsig   <TXFILE> <INDEX> <SCRIPT_CODE> <SIGNATURE>"
                             ,""
                             ,"# HD WALLET (BIP32)"
                             ,"hx hd-priv                                [0]"
                             ,"hx hd-priv <INDEX>"
                             ,"hx hd-priv --hard <INDEX>"
                             ,"hx hd-pub                                 [0]"
                             ,"hx hd-pub <INDEX>"
                             ,"hx hd-path <PATH>                         [0]"
                             ,"hx hd-decode                              [0]"
                             ,"hx hd-to-wif"
                             ,"hx hd-to-address"
                             ,"hx hd-to-pubkey                           [0]"
                             ,""
                             ,"# ELECTRUM DETERMINISTIC WALLET [2]"
                             ,"hx electrum-mpk"
                             ,"hx electrum-priv <INDEX> [<CHANGE-0|1>] [<RANGE-STOP>]"
                             ,"hx electrum-pub  <INDEX> [<CHANGE-0|1>] [<RANGE-STOP>]"
                             ,"hx electrum-addr <INDEX> [<CHANGE-0|1>] [<RANGE-STOP>]"
                             ,"hx electrum-seq  <INDEX> [<CHANGE-0|1>] [<RANGE-STOP>]"
                             ,"hx electrum-stretch-seed"
                             ,""
                             ,"# ELLIPTIC CURVE MATHS"
                             ,"hx ec-multiply  <HEX-FIELDN> <HEX-POINT>"
                             ,"hx ec-tweak-add <HEX-FIELDN> <HEX-POINT>"
                             ,"hx ec-add-modp  <HEX-FIELDP> <HEX-FIELDP>"
                             ,"hx ec-add-modn  <HEX-FIELDN> <HEX-FIELDN> [0]"
                             ,"hx ec-add       <HEX-POINT>  <HEX-POINT>  [0]"
                             ,"hx ec-double    <HEX-POINT>               [0]"
                             ,"hx ec-g                                   [0]"
                             ,"hx ec-p                                   [0]"
                             ,"hx ec-n                                   [0]"
                             ,"hx ec-a                                   [0]"
                             ,"hx ec-b                                   [0]"
                             ,"hx ec-inf                                 [0]"
                             ,"hx ec-int-modp <DECIMAL-INTEGER>          [0]"
                             ,"hx ec-int-modn <DECIMAL-INTEGER>          [0]"
                             ,"hx ec-x <HEX-POINT>                       [0]"
                             ,"hx ec-y <HEX-POINT>                       [0]"
                             ,""
                             ,"# MNEMONICS AND SEED FORMATS"
                             ,"hx mnemonic"
                             ,"hx bip39-seed [<PASSPHRASE>]           [0][5]"
                             ,"hx bip39-mnemonic                      [0][5]"
                             ,"hx bip39-hex                           [0][5]"
                             ,"hx rfc1751-key                            [0]"
                             ,"hx rfc1751-mnemonic                       [0]"
                             ,""
                             ,"# BASIC ENCODINGS AND CONVERSIONS"
                             ,"hx btc [<SATOSHIS>]                       [3]"
                             ,"hx satoshi [<BTCS>]                       [3]"
                             ,"hx integer                                [0]"
                             ,"hx hex-encode                             [0]"
                             ,"hx hex-decode                             [0]"
                             ,""
                             ,"# BASE58 ENCODING"
                             ,"hx base58-encode"
                             ,"hx base58-decode"
                             ,"hx base58check-encode [<VERSION-BYTE>]"
                             ,"hx base58check-decode"
                             ,""
                             ,"# CHECKSUM32 (first 32bits of double sha256) [0]"
                             ,"hx chksum32 <HEX>*"
                             ,"hx chksum32-encode <HEX>*"
                             ,"hx chksum32-decode <HEX>*"
                             ,""
                             ,"# HASHING"
                             ,"hx ripemd-hash                            [4]"
                             ,"hx sha256      [<HEX-INPUT>]"
                             ,"hx ripemd160   [<HEX-INPUT>]              [0]"
                             ,"hx sha1        [<HEX-INPUT>]              [0]"
                             ,"hx hash160     [<HEX-INPUT>]              [0]"
                             ,"hx hash256                                [0]"
                             ,""
                             ,"# HASH BASED MACs"
                             -- TODO the second argument is not optional yet
                             ,"hx hmac-sha224 <HEX-KEY> [<HEX-INPUT>]        [0]"
                             ,"hx hmac-sha256 <HEX-KEY> [<HEX-INPUT>]        [0]"
                             ,"hx hmac-sha384 <HEX-KEY> [<HEX-INPUT>]        [0]"
                             ,"hx hmac-sha512 <HEX-KEY> [<HEX-INPUT>]        [0]"
                             ,""
                             ,"# PASSWORD BASED KEY DERIVATION FUNCTIONS"
                             ,"hx sha1pbkdf1   [--hex] <PASSWORD> [--hex] <SALT> <COUNT>          [0]"
                             ,"hx sha256pbkdf1 [--hex] <PASSWORD> [--hex] <SALT> <COUNT>          [0]"
                             ,"hx sha512pbkdf1 [--hex] <PASSWORD> [--hex] <SALT> <COUNT>          [0]"
                             ,"hx sha1pbkdf2   [--hex] <PASSWORD> [--hex] <SALT> <COUNT> <LENGTH> [0]"
                             ,"hx sha256pbkdf2 [--hex] <PASSWORD> [--hex] <SALT> <COUNT> <LENGTH> [0]"
                             ,"hx sha512pbkdf2 [--hex] <PASSWORD> [--hex] <SALT> <COUNT> <LENGTH> [0]"
                             ,""
                             ,"[0]: Not available in sx"
                             ,"[1]: `hx showtx` is always using JSON output,"
                             ,"     `-j` and `--json` are ignored."
                             ,"[2]: The compatibility has been checked with electrum and with `sx`."
                             ,"     However if your `sx mpk` returns a hex representation of `64` digits,"
                             ,"     then you *miss* half of it."
                             ,"     Moreover subsequent commands (genpub/genaddr) might behave"
                             ,"     non-deterministically."
                             ,"     Finally they have different names:"
                             ,"       mpk     -> electrum-mpk"
                             ,"       genpub  -> electrum-pub"
                             ,"       genpriv -> electrum-priv"
                             ,"       genaddr -> electrum-addr"
                             ,"     The commands electrum-seq and electrum-stretch-seed expose"
                             ,"     the inner workings of the key derivation process."
                             ,"[3]: Rounding is done upward in `hx` and downard in `sx`."
                             ,"     So they agree `btc 1.4` and `btc 1.9` but on `btc 1.5`,"
                             ,"     `hx` returns `0.00000002` and `sx` returns `0.00000001`."
                             ,"[4]: The `ripemd-hash` command is taking raw-bytes as input,"
                             ,"     while the other hashing commands are taking hexadecimal encoded inputs."
                             ,"     This is for this reason that `hash160` has been added"
                             ,"     (`hx ripemd-hash` is equivalent to `hx encode-hex | hx hash160`"
                             ,"     and `hx hash160` is equivalent to `hx decode-hex | hx ripemd-hash`)."
                             ,"[5]: The commands `hx bip39-mnemonic` and `hx bip39-hex` are inverse of each other."
                             ,"     However, this is the command `hx bip39-seed` which must be used to get"
                             ,"     the root extended private key."
                             ,""
                             ,"PATH      ::= <PATH-HEAD> <PATH-CONT>"
                             ,"PATH-HEAD ::= 'A'   [address (compressed)]"
                             ,"            | 'M'   [extended public  key]"
                             ,"            | 'm'   [extended private key]"
                             ,"            | 'P'   [public  key (compressed)]"
                             ,"            | 'p'   [private key (compressed)]"
                             ,"            | 'U'   [uncompressed public  key]"
                             ,"            | 'u'   [uncompressed private key]"
                             ,"PATH-CONT ::=                                [empty]"
                             ,"            | '/' <INDEX> <PATH-CONT>        [child key]"
                             ,"            | '/' <INDEX> '\\'' <PATH-CONT>  [hardened child key]"
                             ]

main :: IO ()
main = mainArgs . toLowerFirst . map B8.pack =<< getArgs
  where toLowerFirst []     = []
        toLowerFirst (x:xs) = B8.map toLower x : xs
