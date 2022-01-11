{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Frontend.UI.Dialogs.SigBuilder where

import           Control.Error hiding (bool, mapMaybe)
import           Control.Lens
import           Control.Monad (forM, join)
import qualified Data.Aeson as A
import qualified Data.Set as Set
import           Data.Aeson.Parser.Internal (jsonEOF')
import           Data.Attoparsec.ByteString
import           Data.Bifunctor (first, second)
import qualified Data.ByteString.Lazy as LB
import           Data.Functor (void)
import           Data.List (partition)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as LT
import qualified Data.Map as Map
import qualified Data.IntMap as IMap
import           Data.YAML
import qualified Data.YAML.Aeson as Y
import           Pact.Types.ChainMeta
import           Pact.Types.ChainId   (networkId)
import           Pact.Types.RPC
import           Pact.Types.Command
import           Pact.Types.Hash (Hash, hash, toUntypedHash, unHash)
import           Pact.Types.SigData
import           Pact.Types.Util             (decodeBase64UrlUnpadded)
import           Pact.Types.Pretty
import           Pact.Types.Info
import qualified Pact.Types.Term                   as Pact
------------------------------------------------------------------------------
import           Reflex
import           Reflex.Dom hiding (Key, Command)
------------------------------------------------------------------------------
import           Common.Wallet
import           Frontend.Crypto.Class
import           Frontend.Foundation
import           Frontend.Log
import           Frontend.Network
import           Frontend.UI.Dialogs.DeployConfirmation
import           Frontend.UI.Modal
import           Frontend.UI.Transfer
import           Frontend.UI.Widgets
import           Frontend.UI.Widgets.Helpers (dialogSectionHeading)
import           Frontend.Wallet
------------------------------------------------------------------------------
import Frontend.UI.Modal.Impl
------------------------------------------------------------------------------

sigBuilderCfg
  :: forall t m key mConf
   . ( MonadWidget t m
     , HasCrypto key m
     )
  => ModalIde m key t
  -> Event t ()
  -> m (ModalIdeCfg m key t)
sigBuilderCfg m evt = do
  pure $ mempty & modalCfg_setModal .~ (Just (uiSigBuilderDialog m) <$ evt)

uiSigBuilderDialog
  ::
  ( MonadWidget t m
  , Monoid mConf
  , SigBuilderWorkflow t m model key
  )
  => ModalIde m key t
  -> Event t ()
  -> m (mConf, Event t ())
uiSigBuilderDialog model _onCloseExternal = do
  dCloses <- workflow $ txnInputDialog model Nothing
  pure (mempty, switch $ current dCloses)

type SigBuilderWorkflow t m model key =
  ( MonadWidget t m
  , HasNetwork model t
  , HasWallet model key t
  , HasCrypto key m
  , ModalIde m key t ~ model
  )

txnInputDialog
  ::
  ( MonadWidget t m
  , SigBuilderWorkflow t m model key
  )
  => model
  -> Maybe (SigData Text)
  -> Workflow t m (Event t ())
txnInputDialog model mInitVal = Workflow $ mdo
  onClose <- modalHeader $ text "Signature Builder"
  let cwKeys = IMap.elems <$> (model^.wallet_keys)
      selNodes = model ^. network_selectedNodes
      networkId = (fmap (mkNetworkName . nodeVersion) . headMay . rights) <$> selNodes
      keysAndNet = current $ (,) <$> cwKeys <*> networkId
  dmSigData <- modalMain $ divClass "group" $ parseInputToSigDataWidget mInitVal
  (onCancel, approve) <- modalFooter $ (,)
    <$> cancelButton def "Cancel"
    <*> confirmButton (def & uiButtonCfg_disabled .~ ( isNothing <$> dmSigData )) "Approve"
  let approveE = fmapMaybe id $ tag (current dmSigData) approve
      sbr = attachWith (\(keys, net) (sd, pl) -> SigBuilderRequest sd pl net keys) keysAndNet approveE
  return (onCancel <> onClose, checkAndSummarize model <$> sbr)

warningDialog
  :: (MonadWidget t m)
  => Text
  -> Workflow t m (Event t ())
  -> Workflow t m (Event t ())
  -> Workflow t m (Event t ())
warningDialog warningMsg backW nextW = Workflow $ do
  onClose <- modalHeader $ text "Warning"
  void $ modalMain $ do
    el "h3" $ text "Warning"
    el "p" $ text warningMsg
  (back, next) <- modalFooter $ (,)
    <$> confirmButton def "Back"
    <*> confirmButton def "Continue"
  pure $ (onClose, leftmost [ backW <$ back , nextW <$ next ])

errorDialog
  :: (MonadWidget t m)
  => Text
  -> Workflow t m (Event t ())
  -> Workflow t m (Event t ())
errorDialog errorMsg backW = Workflow $ do
  onClose <- modalHeader $ text "Error"
  void $ modalMain $ do
    el "h3" $ text "Error"
    el "p" $ text errorMsg
  back <- modalFooter $ confirmButton def "Back"
  pure $ (onClose, backW <$ back)

checkAndSummarize
  :: SigBuilderWorkflow t m model key
  => model
  -> SigBuilderRequest key
  -> Workflow t m (Event t ())
checkAndSummarize model sbr =
  -- TODO: Add "hash-mismatch" error when Sig-Data hash and payload hash are not identical
  if Set.disjoint cwPubKeys signerPubkeys
     then errorDialog "Chainweaver does not possess any of the keys required for signing" backW
     else checkNetwork
  where
    sigData = _sbr_sigData sbr
    backW = txnInputDialog model (Just sigData)
    nextW = approveSigDialog model sbr
    cwPubKeys = Set.fromList $ fmap (_keyPair_publicKey . _key_pair) $ _sbr_cwKeys sbr
    signerPubkeys = Set.fromList $ rights
      $ fmap (parsePublicKey . _siPubKey)
      $ _pSigners $ _sbr_payload sbr
    cwNetwork = _sbr_currentNetwork sbr
    payloadNetwork = mkNetworkName . view networkId
      <$> (_pNetworkId $ _sbr_payload sbr)
    networkWarning currentKnown mPayNet =
      case mPayNet of
        Nothing -> "The payload you are signing does not have an associated network"
        Just p -> "The payload you are signing has network id: \""
                  <> textNetworkName p <>
                  "\" but your active chainweaver node is on: \""
                  <> textNetworkName currentKnown <> "\""
    checkNetwork =
      case (cwNetwork, payloadNetwork) of
         (Nothing, _) -> nextW
         (Just x, Just y)
           | x == y -> nextW
         (Just x, pNet) -> warningDialog (networkWarning x pNet) backW nextW

approveSigDialog
  :: SigBuilderWorkflow t m model key
  => ModalIde m key t
  -> SigBuilderRequest key
  -> Workflow t m (Event t ())
approveSigDialog model sbr = Workflow $ do
  let sigData = _sbr_sigData sbr
      keys = fmap _key_pair $ _sbr_cwKeys sbr
      dNodeInfos = model^.network_selectedNodes
  onClose <- modalHeader $ text "Approve Transaction"
  sigsOrKeys <- modalMain $ do
    let p = _sbr_payload sbr
        sdHash = toUntypedHash $ _sigDataHash $ _sbr_sigData sbr
    networkWidget p
    txMetaWidget  $ _pMeta p
    sigsOrKeys' <- signerWidget (_keyPair_publicKey <$> keys) (_pSigners p) sdHash
    pactRpcWidget  $ _pPayload p
    pure $ sequence sigsOrKeys'

  (back, sign) <- modalFooter $ (,)
    <$> confirmButton def "Back"
    <*> confirmButton def "Sign"
  let sigsOnSubmit = mapMaybe (\(a, mb) -> fmap (a,) mb) <$> current sigsOrKeys <@ sign
  let workflowEvent = leftmost
        [ txnInputDialog model (Just sigData) <$ back
        , signAndShowSigDialog model sbr keys <$> sigsOnSubmit
        -- , transferAndStatus model nodeInfos (sender, cid) cmd <$ signAndSubmit
        -- , transferAndStatus model (AccountName "jacquin", ChainId "0") cmd nodeInfos <$ signAndSubmit
        ]

  -- => Hash
  -- -> PublicKey
  -- -> m (Dynamic t (PublicKeyHex, Maybe UserSig))
  return (onClose, workflowEvent)

signAndShowSigDialog
  :: SigBuilderWorkflow t m model key
  => ModalIde m key t
  -> SigBuilderRequest key
  -> [KeyPair key]
  -> [(PublicKeyHex, UserSig)]
  -> Workflow t m (Event t ())
signAndShowSigDialog _model sbr keys sigsOrPrivate = Workflow $ do
  onClose <- modalHeader $ text "Signed Txn"
  -- This allows a "loading" page to render before we attempt to do the really computationally
  -- expensive sigs
  pb <- delay 0.0 =<< getPostBuild
  -- TODO: Can we forkIO the sig process and display something after they are done?
  widgetHold_ (modalMain $ text "Loading Signatures ...") $ ffor pb $ \_ ->
    modalMain $ do
      let sd = _sbr_sigData sbr
      sd' <- addSigsToSigData sd keys sigsOrPrivate
      let txt = T.decodeUtf8 $ Y.encode1Strict sd
      void $ uiTxSigner (Just sd) def def
      uiDetailsCopyButton $ constant txt

  (back, finish) <- modalFooter $ (,)
    <$> confirmButton def "Back"
    <*> confirmButton def "Finish"
  return (onClose <> finish, never)

addSigsToSigData
  :: (
       MonadJSM m
     , HasCrypto key m
     )
  => SigData Text
  -> [KeyPair key]
  -- ^ Keys which we are signing with
  -> [(PublicKeyHex, UserSig)]
  -> m (SigData Text)
addSigsToSigData sd signingKeys sigList = do
  --TODO: Double check hash here and fail if they dontmatch
  let -- cmd = encodeAsText $ encode payload
      -- cmdHashL = hash (T.encodeUtf8 cmd)
      hash = unHash $ toUntypedHash $ _sigDataHash sd
      someSigs = _sigDataSigs sd
      pubKeyToTxt =  PublicKeyHex . keyToText . _keyPair_publicKey 
      cwSigners =  fmap (\x -> (pubKeyToTxt x, _keyPair_privateKey x)) signingKeys
      toPactSig sig = UserSig $ keyToText sig
  sigList <- forM someSigs $ \(pkHex, mSig) -> case mSig of
    Just sig -> pure (pkHex, Just sig)
    Nothing -> case pkHex `lookup` cwSigners of
      Just (Just priv) -> do
        sig <- cryptoSign hash priv
        pure (pkHex, Just $ toPactSig sig )
      otherwise -> pure (pkHex, pkHex `lookup` sigList)
  pure $ sd { _sigDataSigs = sigList }

data SigBuilderRequest key = SigBuilderRequest
  { _sbr_sigData        :: SigData Text
  , _sbr_payload        :: Payload PublicMeta Text
  , _sbr_currentNetwork :: Maybe NetworkName
  , _sbr_cwKeys         :: [ Key key ]
  }

signerWidget
  :: (MonadWidget t m, HasCrypto key m)
  => [PublicKey]
  -> [Signer]
  -> Hash
  -> m [Dynamic t (PublicKeyHex, Maybe UserSig)]
signerWidget cwKeys signers sdHash = do
  let (unscoped, scoped) = partition isUnscoped signers
  dUnscoped <- ifEmptyBlankSigner unscoped $ do
    dialogSectionHeading mempty "Unscoped Signers"
    divClass "group" $ do
      fmap catMaybes $ mapM unscopedSignerRow unscoped

  dScoped <- ifEmptyBlankSigner scoped $ do
    dialogSectionHeading mempty "Scoped Signers"
    fmap catMaybes $ mapM scopedSignerRow scoped
  let sigsOrKeys = dScoped <> dUnscoped
  pure sigsOrKeys

  where
    isUnscoped (Signer _ _ _ capList) = capList == []
    ifEmptyBlankSigner l w = if l == [] then (blank >> pure []) else w
    unOwnedSigningInput pub =
      if pub `elem` cwKeys
        then blank >> pure Nothing
        else fmap Just $ uiSigningInput sdHash pub

    unscopedSignerRow s = do
      el "div" $ do
        maybe blank (text . (<> ":") . tshow) $ _siScheme s
        text $ _siPubKey s
        maybe blank (text . (":" <>) . tshow) $ _siAddress s
      elAttr "ul" ("style" =: "margin-block-start: 0; margin-block-end: 0;") $
        mapM_ (elAttr "li" ("style" =: "list-style-type: none;") . text . renderCompactText) $ _siCapList s
      -- uiSigningInput sdHash pkey
      let (Right pkey) = parsePublicKey $ _siPubKey s
      unOwnedSigningInput pkey

    scopedSignerRow signer = do
      divClass "group" $ do
        visible <- divClass "signer__row" $ do
          let accordionCell o = (if o then "" else "accordion-collapsed ") <> "payload__accordion "
          rec
            clk <- elDynClass "div" (accordionCell <$> visible') $ accordionButton def
            visible' <- toggle True clk
          divClass "signer__pubkey" $ text $ _siPubKey signer
          pure visible'
        elDynAttr "div" (ffor visible $ bool ("hidden"=:mempty) mempty)$ do
          el "ul" $ forM_ (_siCapList signer) $ \cap ->
            elAttr "li" ("style" =: "list-style-type:none;")$ text $ renderCompactText cap
        let (Right pkey) = parsePublicKey $ _siPubKey signer
        unOwnedSigningInput pkey



txMetaWidget
  :: MonadWidget t m
  => PublicMeta
  -> m ()
txMetaWidget pm = do
  dialogSectionHeading mempty "Transaction Metadata"
  _ <- divClass "group segment" $ do
    mkLabeledClsInput True "Chain" $ \_ -> text (renderCompactText $ _pmChainId pm)
    mkLabeledClsInput True "Gas Payer" $ \_ -> text (_pmSender pm)
    mkLabeledClsInput True "Gas Price" $ \_ -> text (renderCompactText $ _pmGasPrice pm)
    mkLabeledClsInput True "Gas Limit" $ \_ -> text (renderCompactText $ _pmGasLimit pm)
    let totalGas = fromIntegral (_pmGasLimit pm) * _pmGasPrice pm
    mkLabeledClsInput True "Max Gas Cost" $ \_ -> text $ renderCompactText totalGas <> " KDA"
  pure ()

pactRpcWidget
  :: MonadWidget t m
  => PactRPC Text
  -> m ()
pactRpcWidget (Exec e) = do
  dialogSectionHeading mempty "Code"
  divClass "group" $ do
    el "code" $ text $ tshow $ pretty $ _pmCode e
  case _pmData e of
    A.Null -> blank
    jsonVal -> do
      dialogSectionHeading mempty "Data"
      divClass "group" $ do
        uiTextAreaElement $ def
          & textAreaElementConfig_initialValue .~ (T.decodeUtf8 $ LB.toStrict $ A.encode jsonVal)
          & initialAttributes .~ "disabled" =: "" <> "style" =: "width: 100%"
        pure ()
pactRpcWidget (Continuation c) = do
  dialogSectionHeading mempty "Continuation Data"
  divClass "group" $ do
    mkLabeledClsInput True "Pact ID" $ \_ -> text $ tshow $ _cmPactId c
    mkLabeledClsInput True "Step" $ \_ -> text $ tshow $ _cmStep c
    mkLabeledClsInput True "Rollback" $ \_ -> text $ tshow $ _cmRollback c
    mkLabeledClsInput True "Data" $ \_ -> text $ tshow $ _cmData c
    mkLabeledClsInput True "Proof" $ \_ -> text $ tshow $ _cmProof c

networkWidget :: MonadWidget t m => Payload PublicMeta a -> m ()
networkWidget p = case _pNetworkId p of
  Nothing -> blank
  Just n -> do
    dialogSectionHeading mempty "Network"
    divClass "group" $ text $ n ^. networkId

data DataToBeSigned
  = DTB_SigData (SigData T.Text, Payload PublicMeta Text)
  | DTB_ErrorString String
  | DTB_EmptyString

parseInputToSigDataWidget
  :: MonadWidget t m
  => Maybe (SigData Text)
  -> m (Dynamic t (Maybe (SigData Text, Payload PublicMeta Text)))
parseInputToSigDataWidget mInit =
  divClass "group" $ do
    txt <- fmap value
      $ mkLabeledClsInput False "Paste Transaction" $ \cls ->
          uiTxSigner mInit cls def
    let parsedBytes = parseBytes . T.encodeUtf8 <$> txt
    dyn_ $ ffor parsedBytes $ \case
      DTB_ErrorString e -> elClass "p" "error_inline" $ text $ T.pack e
      _ -> blank
    return $ validInput <$>  parsedBytes
  where
    parsePayload :: Text -> Either String (Payload PublicMeta Text)
    parsePayload cmdText =
      first (const "Invalid cmd field inside SigData.") $
        A.eitherDecodeStrict (T.encodeUtf8 cmdText)

    parseAndAttachPayload sd =
      case parsePayload =<< (justErr "Payload missing" $ _sigDataCmd sd) of
        Left e -> DTB_ErrorString e
        Right p -> DTB_SigData (sd, p)

    parseBytes "" = DTB_EmptyString
    parseBytes bytes =
      -- Parse the JSON, and consume all the input
      case parseOnly jsonEOF' bytes of
        Right val -> case A.fromJSON val of
          A.Success sigData -> parseAndAttachPayload sigData
          A.Error errStr -> DTB_ErrorString errStr
             --TODO: Add payload case later
            -- case A.fromJSON val of
            -- A.Success payload -> Just $ Right payload
            -- A.Error errorStr -> ErrorString errorStr

        -- We did not receive JSON, try parsing it as YAML
        Left _ -> case Y.decode1Strict bytes of
          Right sigData -> parseAndAttachPayload sigData
          Left (pos, errorStr) -> DTB_ErrorString $ prettyPosWithSource pos (LB.fromStrict bytes) errorStr
    validInput DTB_EmptyString = Nothing
    validInput (DTB_ErrorString _) = Nothing
    validInput (DTB_SigData info) = Just info

transferAndStatus
  :: (MonadWidget t m, Monoid mConf, HasLogger model t, HasTransactionLogger m)
  => model
  -> (AccountName, ChainId)
  -> Command Text
  -> [NodeInfo]
  -> Workflow t m (Event t ())
transferAndStatus model (sender, cid) cmd nodeInfos = Workflow $ do
    close <- modalHeader $ text "Transfer Status"
    _ <- elClass "div" "modal__main transaction_details" $
      submitTransactionWithFeedback model cmd sender cid (fmap Right nodeInfos)
    done <- modalFooter $ confirmButton def "Done"
    pure (close <> done, never)
