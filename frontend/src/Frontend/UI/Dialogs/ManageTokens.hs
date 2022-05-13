{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Frontend.UI.Dialogs.ManageTokens
  ( uiManageTokensDialog
  ) where


import Control.Lens hiding (failover)
import Control.Error (hush)
import Control.Monad (foldM, forM, void)
import Data.Bifunctor (first)
import Data.List (foldl', sort)
import Data.Either (rights)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as Map
import qualified Data.Text as T
import Data.These
import Reflex.Dom

import Pact.Types.Exp
import Pact.Types.PactValue
import Pact.Types.Pretty  (renderCompactText)
import Pact.Types.Names   (parseModuleName)
import Pact.Types.Runtime (ModuleName)

import Frontend.Crypto.Class (HasCrypto(..))
import Frontend.Foundation hiding (Arg)
import Frontend.Log (HasLogger(..))
import Frontend.ModuleExplorer.ModuleRef
import Frontend.Network
import Frontend.UI.Common
import Frontend.UI.Modal
import Frontend.UI.FormWidget (mkCfg)
import Frontend.UI.Widgets
import Frontend.UI.Widgets.Helpers
import Frontend.Wallet

-- | A function for inverting a map, that goes from a key type to a list type.
--
-- [(1, ['a', 'b']), (2, ['b', 'c'])] => [('a', [1]), ('b', [1,2]), ('c', [2])]
invertMap :: (Ord a) => Map.Map k [a] -> Map.Map a [k]
invertMap m = foldl' (\mp (k, as) ->
  foldl' (\mp1 a -> Map.insertWith (++) a [k] mp1) mp as
  ) Map.empty $ Map.toList m

-- | A modal for watching request keys
uiManageTokensDialog
  :: ( Flattenable mConf t
     , Monoid mConf
     , HasLogger model t
     , HasCrypto key m
     , HasTransactionLogger m
     , HasNetwork model t
     , HasWalletCfg mConf key t
     , HasWallet model key t
     , MonadWidget t m
     , HasCrypto key (Performable m)
     )
  => model -> Event t () -> m (mConf, Event t ())
uiManageTokensDialog model onCloseExternal = do
  (conf, closes) <- splitE <$> manageTokens model onCloseExternal
  mConf <- flatten conf
  close <- switchHold never closes
  pure (mConf, close)

tokenInputWidget
  :: ( DomBuilder t m
     , PostBuild t m
     , MonadHold t m
     , DomBuilderSpace m ~ GhcjsDomSpace
     , PerformEvent t m
     , TriggerEvent t m
     , MonadJSM (Performable m)
     , MonadFix m
     , HasLogger model t
     , HasNetwork model t
     , HasCrypto key (Performable m)
     , HasTransactionLogger m
     , MonadSample t (Performable m)
     , MonadIO m
     )
  => model
  -> Map.Map ChainId [ModuleName]
  -> Event t () -- Validation trigger
  -> Behavior t [ModuleName]
  -> m (Dynamic t (Maybe ModuleName))
tokenInputWidget model chainToModuleMap eTrigger bLocalList = do
  --TODO: Sample higher?
  netMeta <- sample $ current $ getNetworkNameAndMeta model
  let tokenValidator' = tokenValidator netMeta bLocalList
      tokenInput = textFormAsyncValidationWidget PopoverState_Disabled
        moduleListId tokenValidator' (Just eTrigger)
  rec
    dmFung <- fmap (value . fst) $ mkLabeledInput True "Enter Token" tokenInput $ mkCfg Nothing
      & setValue .~ (Just eClear)
    let eClear = Nothing <$ (fmapMaybe id $ updated dmFung)
  pure dmFung
  where
    moduleToChainMap = invertMap chainToModuleMap

    -- TODO: Is this an appropriate way to query all chains a node provides access to?
    chainList = Map.keys chainToModuleMap

    isModuleFungiblePact moduleName =
      -- Writing the query in this way allows us to restrict the functions that can produce an error
      -- In the query below, only the `describe-module` function can generate an error.
      -- If `describe-module` generated an error, it means that the user entered module is not present on any chain.
      -- If `describe-module` didn't generate any error, it means that the user entered module is a valid module,
      --      though it might not be a valid "fungible-v2" contract. For this contract, we should return a False.
      "(let ((moduleDesc (describe-module \"" <> moduleName <> "\")))" <>
        "(contains \"fungible-v2\"" <>
          "(if (contains 'interfaces moduleDesc)" <>
            "(at 'interfaces moduleDesc)" <>
            "[]" <>
            ")))"

    checkModuleIsFungible (netName, netMetadata) evModule = do
      --TODO: This is a bad hack to get the modname used in the req
      dModName <- holdDyn Nothing $ Just <$> evModule
      let net = model ^. network
      -- In case the module exists on some chains, this will store the list of those chainIds.
      -- If the module does not exist on any chains, it will store all the chainIds.
      let chainIdsToCheck = fromMaybe chainList . flip Map.lookup moduleToChainMap
      reqEv <- performEvent $ evModule <&> \mdule -> forM (chainIdsToCheck mdule) $ \chainId ->
        mkSimpleReadReq (isModuleFungiblePact (renderCompactText mdule))
          netName netMetadata $ ChainRef Nothing chainId
      respEv <- performLocalRead (model ^. logger) net reqEv
      pure $ attach (current dModName) respEv <&> \(mModule, responses) -> case mModule of
        Nothing -> Validation_Failure "Empty Module Name"
        Just mdule ->
          -- In the following foldM, we have used Either as a Monad to short circuit the fold.
          -- We short circuit the fold as soon as we find a `True`.
          -- Note: In order to short circuit, we need to use `Left`, which is commonly used for errors.
          --       Here, `Left` does NOT represent errors, only a way to short circuit.
          -- If we encounter an unknown error, we keep the already existing error with us.
          either id id $
            foldM (\err (_, netErrorResult) ->
              case netErrorResult of
                That (_, pVal) -> case pVal of
                  PLiteral (LBool b) -> if b
                    then Left $ Validation_Success mdule
                    else Right $ Validation_Failure "Contract not a token"
                  x -> Right err
                _ -> Right err
              ) (Validation_Failure "This module does not exist on any chain") responses

    tokenValidator netAndMeta bLocalList inputEv = do
      let
        inputEvAndModList = attach bLocalList inputEv
        -- eNetAndMeta = tag (current $ getNetworkNameAndMeta net) inputEv
        (failureEv, validNameEv) = fanEither $ ffor inputEvAndModList $ \(localList, rawInput) -> do
          case parseModuleName rawInput of
            -- User input is not a valid module name
            Left err -> Left $ Validation_Failure "Invalid module name"
            -- User input is a valid module name, check if it already exists on any chain
            Right mdule -> case mdule `elem` localList of
              True -> Left $ Validation_Failure "Token already added"
              False -> Right mdule
      rec
        -- Tags requests that go out so that any stale responses are ignored
        resultEv <- checkModuleIsFungible netAndMeta validNameEv
        reqCount <- count validNameEv
        respCount <- count resultEv
        let reqAndResCount = current $ (==) <$> reqCount <*> respCount
        resultEv' <- delay 0.0 resultEv


      pure $ leftmost [failureEv, gate reqAndResCount resultEv']

uiAddToken
  :: (
       MonadWidget t m
     , HasLogger model t
     , HasTransactionLogger m
     , HasNetwork model t
     , HasCrypto key (Performable m)
     )
  => model
  -> Map.Map ChainId [ModuleName]
  -> Dynamic t (NonEmpty ModuleName)
  -> m (Dynamic t (Maybe ModuleName))
uiAddToken model moduleMap dTokenListNE = do
  dialogSectionHeading mempty "Add Tokens"
  divClass "flex" $ mdo
    dmFung <- divClass "group flex-grow" $ do
      let dTokenList = fmap NE.toList $ current dTokenListNE
      tokenInputWidget model moduleMap addTokenEv dTokenList
    addTokenEv <- flip confirmButton "Add"  $ def
      & uiButtonCfg_class .~ "margin"
    pure dmFung

uiFavoriteTokens
  :: MonadWidget t m
  => Dynamic t (NonEmpty ModuleName)
  -> m (Event t ModuleName)
uiFavoriteTokens dTokenListNE = do
  dialogSectionHeading mempty "My Tokens"
  eeDelete <- networkView $ dTokenListNE <&> \neTokenList -> do
    let (kda:rest) = NE.toList neTokenList
        -- sorted; except for kda which is always at the top
        sortedTokens = kda:(sort rest)
    delClicks <- forM sortedTokens $ \token -> do
      delToken <- divClass "flex paddingLeftTopRight" $ do
        divClass "flex-grow paddingTop" $ text $ renderTokenName token
        if token == kdaToken
          then pure never
          else deleteButtonNaked def
      pure $ token <$ delToken
    pure $ leftmost delClicks
  switchHold never eeDelete

-- | Allow the user to input a new fungible
manageTokens
  :: ( Monoid mConf
     , MonadWidget t m
     , HasLogger model t
     , HasTransactionLogger m
     , HasNetwork model t
     , HasWallet model key t
     , HasWalletCfg mConf key t
     , HasCrypto key (Performable m)
     , MonadSample t (Performable m)
     )
  => model
  -> Event t () -- ^ Modal was externally closed
  -> m (Event t (mConf, Event t ()))
manageTokens model _ = do
  close <- modalHeader $ text "Manage Tokens"
  let modulesAndNet = (,) <$> model ^. network_modules <*> model ^. network_selectedNetwork
  networkView $  modulesAndNet <&> \(chainToModuleMap, net) ->
    if (Map.null chainToModuleMap)
    then do
      modalMain $ text "Loading Tokens..."
      pure mempty
    else mdo
      (dmFung, deleteEv) <- modalMain $ do
        (,) <$> uiAddToken model chainToModuleMap dLocalList
            <*> uiFavoriteTokens dLocalList
      done <- modalFooter $ confirmButton def "Done"

      initialTokens <- sample $ current $ model ^. wallet_tokenList
      let initialTokens' = fromMaybe defaultTokenList $ Map.lookup net initialTokens
      let
        addToken (t :| ts) newToken = t :| (newToken : ts)
        deleteToken (t :| ts) token = t :| filter (/= token) ts
        processUserAction action tokens = either (deleteToken tokens) (addToken tokens) action
        addEv = fmapMaybe id $ updated dmFung
      dLocalList <- foldDyn processUserAction initialTokens' $ leftmost
        [ Left <$> deleteEv
        , Right <$> addEv
        ]
      let
        bToken = current $ _wallet_fungible $ model ^. wallet
        eActiveToken = fmapMaybe id $
          attach bToken (updated dLocalList) <&> \(activeFungible, tokenList) ->
            -- If currently selected token is not in the new local list
            -- that means it was deleted by the user. Switch to the head element ie "coin".
            if activeFungible `notElem` tokenList
            then Just $ NE.head tokenList
            else Nothing
        conf = mempty & walletCfg_moduleList .~ ((\localLst -> (net,localLst)) <$> updated dLocalList)
                      & walletCfg_fungibleModule .~ eActiveToken
      pure (conf, done <> close)
