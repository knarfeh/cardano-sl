-- | Generation of genesis data for testnet.

module Pos.Core.Genesis.Generate
       ( GeneratedGenesisData (..)
       , generateSecrets

       , generateFakeAvvm
       , generateFakeAvvmGenesis

       , generateGenesisData
       ) where

import           Universum

import           Crypto.Random                           (MonadRandom, getRandomBytes)
import qualified Data.HashMap.Strict                     as HM
import qualified Data.Map.Strict                         as Map
import           Serokell.Util.Verify                    (VerificationRes (..),
                                                          formatAllErrors, verifyGeneric)

import           Pos.Binary.Class                        (asBinary, serialize')
import           Pos.Binary.Core.Address                 ()
import           Pos.Core.Address                        (Address,
                                                          IsBootstrapEraAddr (..),
                                                          addressHash, deriveLvl2KeyPair,
                                                          makePubKeyAddressBoot,
                                                          makeRedeemAddress)
import           Pos.Core.Coin                           (coinPortionToDouble, mkCoin,
                                                          unsafeIntegerToCoin)
import           Pos.Core.Configuration.BlockVersionData (HasGenesisBlockVersionData,
                                                          genesisBlockVersionData)
import           Pos.Core.Configuration.Protocol         (HasProtocolConstants, vssMaxTTL,
                                                          vssMinTTL)
import qualified Pos.Core.Genesis.Constants              as Const
import           Pos.Core.Genesis.Types                  (AddrDistribution,
                                                          BalanceDistribution (..),
                                                          FakeAvvmOptions (..),
                                                          GenesisInitializer (..),
                                                          GenesisWStakeholders (..),
                                                          TestnetBalanceOptions (..),
                                                          TestnetDistribution (..))
import           Pos.Core.Types                          (BlockVersionData (bvdMpcThd))
import           Pos.Core.Vss                            (VssCertificate,
                                                          VssCertificatesMap,
                                                          mkVssCertificate)
import           Pos.Crypto                              (EncryptedSecretKey,
                                                          RedeemPublicKey, SecretKey,
                                                          VssKeyPair, deterministic,
                                                          emptyPassphrase, keyGen,
                                                          randomNumberInRange,
                                                          redeemDeterministicKeyGen,
                                                          safeKeyGen, toPublic,
                                                          toVssPublicKey, vssKeyGen)

-- | Data generated by @genTestnetOrMainnetData@ using genesis-spec.
data GeneratedGenesisData = GeneratedGenesisData
    { ggdNonAvvmDistr     :: ![AddrDistribution]
    -- ^ Address distribution for non avvm addresses
    , ggdBootStakeholders :: !GenesisWStakeholders
    -- ^ Set of boot stakeholders (richmen addresses or custom addresses)
    , ggdGtData           :: !VssCertificatesMap
    -- ^ Genesis vss data (vss certs of richmen)
    , ggdSecretKeys       :: !(Maybe [(SecretKey, EncryptedSecretKey, VssKeyPair)])
    -- ^ Secret keys for non avvm addresses
    , ggdFakeAvvmSeeds    :: !(Maybe [ByteString])
    -- ^ Fake avvm seeds (needed only for testnet)
    }

generateGenesisData
    :: (HasProtocolConstants, HasGenesisBlockVersionData)
    => GenesisInitializer
    -> GeneratedGenesisData
generateGenesisData TestnetInitializer{..} = deterministic (serialize' tiSeed) $ do
    (fakeAvvmDistr, seeds) <- generateFakeAvvmGenesis tiFakeAvvmBalance
    testnetGenData <- generateTestnetData tiTestBalance tiDistribution
    let testnetDistr = ggdNonAvvmDistr testnetGenData
    pure $
        testnetGenData
        { ggdNonAvvmDistr = testnetDistr ++ fakeAvvmDistr
        , ggdFakeAvvmSeeds = Just seeds
        }
generateGenesisData MainnetInitializer{..} =
    GeneratedGenesisData [] miBootStakeholders miVssCerts Nothing Nothing

-- | Generates keys and vss certs for testnet data.
generateTestnetData
    :: (HasProtocolConstants, HasGenesisBlockVersionData, MonadRandom m)
    => TestnetBalanceOptions
    -> TestnetDistribution
    -> m GeneratedGenesisData
generateTestnetData tso@TestnetBalanceOptions{..} distrSpec = do
    (richmenList, poorsList) <-
        (,) <$> replicateM (fromIntegral tboRichmen) (generateSecretsAndAddress Nothing tboUseHDAddresses)
            <*> replicateM (fromIntegral tboPoors)   (generateSecretsAndAddress Nothing tboUseHDAddresses)

    let skVssCerts = map (\(sk, _, _, vc, _) -> (sk, vc)) $ richmenList ++ poorsList
    let richSkVssCerts = take (fromIntegral tboRichmen) skVssCerts
    let secretKeys = map (\(sk, hdwSk, vssSk, _, _) -> (sk, hdwSk, vssSk)) $ richmenList ++ poorsList

    let distr = genTestnetDistribution tso
        genesisAddrs = map (makePubKeyAddressBoot . toPublic . fst) skVssCerts
                    <> map (view _5) poorsList
        genesisAddrDistr = [(genesisAddrs, distr)]

    case distr of
        RichPoorBalances {} -> pass
        _                   -> error "Impossible type of generated testnet balance"
    let toStakeholders = Map.fromList . map ((,1) . addressHash . toPublic . fst)
    let toVss = HM.fromList . map (_1 %~ addressHash . toPublic)

    let (bootStakeholders, gtData) =
            case distrSpec of
                TestnetRichmenStakeDistr    -> (toStakeholders richSkVssCerts, toVss richSkVssCerts)
                TestnetCustomStakeDistr{..} -> (getGenesisWStakeholders tcsdBootStakeholders, tcsdVssCerts)

    pure $ GeneratedGenesisData
        { ggdNonAvvmDistr = genesisAddrDistr
        , ggdBootStakeholders = GenesisWStakeholders bootStakeholders
        , ggdGtData = gtData
        , ggdSecretKeys = Just secretKeys
        , ggdFakeAvvmSeeds = Nothing
        }

generateFakeAvvmGenesis
    :: (MonadRandom m)
    => FakeAvvmOptions -> m ([AddrDistribution], [ByteString])
generateFakeAvvmGenesis FakeAvvmOptions{..} = do
    fakeAvvmPubkeysAndSeeds <- replicateM (fromIntegral faoCount) generateFakeAvvm

    let gcdAddresses = map (makeRedeemAddress . fst) fakeAvvmPubkeysAndSeeds
        gcdDistribution = CustomBalances $
            replicate (length gcdAddresses)
                      (mkCoin $ fromIntegral faoOneBalance)

    pure ([(gcdAddresses, gcdDistribution)], map snd fakeAvvmPubkeysAndSeeds)

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

generateSecretsAndAddress
    :: (HasProtocolConstants, MonadRandom m)
    => Maybe (SecretKey, EncryptedSecretKey)  -- ^ plain key & hd wallet root key
    -> Bool                                   -- ^ whether address contains hd payload
    -> m (SecretKey, EncryptedSecretKey, VssKeyPair, VssCertificate, Address)
    -- ^ secret key, vss key pair, vss certificate,
    -- hd wallet account address with bootstrap era distribution
generateSecretsAndAddress mbSk hasHDPayload= do
    (sk, hdwSk, vss) <- generateSecrets mbSk

    expiry <- fromInteger <$>
        randomNumberInRange (vssMinTTL - 1) (vssMaxTTL - 1)
    let vssPk = asBinary $ toVssPublicKey vss
        vssCert = mkVssCertificate sk vssPk expiry
        -- This address is used only to create genesis data. We don't
        -- put it into a keyfile.
        hdwAccountPk =
            if not hasHDPayload then makePubKeyAddressBoot (toPublic sk)
            else
                fst $ fromMaybe (error "generateKeyfile: pass mismatch") $
                deriveLvl2KeyPair (IsBootstrapEraAddr True) emptyPassphrase hdwSk
                    Const.accountGenesisIndex Const.wAddressGenesisIndex
    pure (sk, hdwSk, vss, vssCert, hdwAccountPk)

generateFakeAvvm :: MonadRandom m => m (RedeemPublicKey, ByteString)
generateFakeAvvm = do
    seed <- getRandomBytes 32
    let (pk, _) = fromMaybe
            (error "Impossible - seed is not 32 bytes long") $
            redeemDeterministicKeyGen seed
    pure (pk, seed)

generateSecrets
    :: (MonadRandom m)
    => Maybe (SecretKey, EncryptedSecretKey)
    -> m (SecretKey, EncryptedSecretKey, VssKeyPair)
generateSecrets mbSk = do
    -- plain key & hd wallet root key
    (sk, hdwSk) <-
        case mbSk of
            Just x -> return x
            Nothing ->
                (,) <$> (snd <$> keyGen) <*>
                (snd <$> safeKeyGen emptyPassphrase)
    vss <- vssKeyGen
    pure (sk, hdwSk, vss)

-- | Generates balance distribution for testnet.
genTestnetDistribution :: HasGenesisBlockVersionData => TestnetBalanceOptions -> BalanceDistribution
genTestnetDistribution TestnetBalanceOptions{..} =
    checkConsistency $ RichPoorBalances {..}
  where
    richs = fromIntegral tboRichmen
    poors = fromIntegral tboPoors * 2  -- for plain and hd wallet keys
    testBalance = fromIntegral tboTotalBalance

    -- Calculate actual balances
    desiredRichBalance = getShare tboRichmenShare testBalance
    oneRichmanBalance = desiredRichBalance `div` richs +
        if desiredRichBalance `mod` richs > 0 then 1 else 0
    realRichBalance = oneRichmanBalance * richs
    poorsBalance = testBalance - realRichBalance
    onePoorBalance = if poors == 0 then 0 else poorsBalance `div` poors
    realPoorBalance = onePoorBalance * poors

    mpcBalance = getShare (coinPortionToDouble $ bvdMpcThd genesisBlockVersionData) testBalance

    sdRichmen = fromInteger richs
    sdRichBalance = unsafeIntegerToCoin oneRichmanBalance
    sdPoor = fromInteger poors
    sdPoorBalance = unsafeIntegerToCoin onePoorBalance

    -- Consistency checks
    everythingIsConsistent :: [(Bool, Text)]
    everythingIsConsistent =
        [ ( realRichBalance + realPoorBalance <= testBalance
          , "Real rich + poor balance is more than desired."
          )
        , ( oneRichmanBalance >= mpcBalance
          , "Richman's balance is less than MPC threshold"
          )
        , ( onePoorBalance < mpcBalance
          , "Poor's balance is more than MPC threshold"
          )
        ]

    checkConsistency :: a -> a
    checkConsistency = case verifyGeneric everythingIsConsistent of
        VerSuccess        -> identity
        VerFailure errors -> error $ formatAllErrors errors

    getShare :: Double -> Integer -> Integer
    getShare sh n = round $ sh * fromInteger n
