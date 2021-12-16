{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Common.Route where

{- -- You will probably want these imports for composing Encoders.
import Prelude hiding (id, (.))
import Control.Category
-}

import           Control.Category       ((.))
import           Control.Monad.Except   (MonadError)
import           Data.Map               (Map)
import           Data.Functor.Identity
import           Data.Text              (Text)
import           Prelude                hiding (id, (.))

import           Obelisk.OAuth.Provider (OAuthProviderId)
import           Obelisk.OAuth.Route    (OAuthRoute (..),
                                         oAuthProviderIdEncoder,
                                         oAuthRouteEncoder)
import           Obelisk.Route
import           Obelisk.Route.TH

data BackendRoute :: * -> * where
  -- | Used to handle unparsable routes.
  BackendRoute_Missing :: BackendRoute ()
  -- You can define any routes that will be handled specially by the backend here.
  -- i.e. These do not serve the frontend, but do something different, such as serving static files.

  -- | Networks to connect to. This is served by pact.kadena.io so that the mac
  -- apps have an up-to-date network list.
  BackendRoute_Networks :: BackendRoute ()

  -- | Serve robots.txt at the right place.
  BackendRoute_Robots :: BackendRoute ()

  BackendRoute_OAuthGetToken :: BackendRoute OAuthProviderId

  -- | Serve the CSS, generated by Sass.
  BackendRoute_Css :: BackendRoute ()

-- | This type is used to define frontend routes, i.e. ones for which the backend will serve the frontend.
data FrontendRoute :: * -> * where
  FrontendRoute_Contracts :: FrontendRoute (Maybe (R ContractRoute))
  FrontendRoute_Accounts :: FrontendRoute (Map Text (Maybe Text))
  FrontendRoute_Keys :: FrontendRoute ()
  FrontendRoute_Resources :: FrontendRoute ()
  FrontendRoute_Settings :: FrontendRoute ()

data ContractRoute a where
  -- | Route for loading an example.
  ContractRoute_Example :: ContractRoute [Text]
  -- | Route for loading a stored file/module.
  ContractRoute_Stored  :: ContractRoute [Text]
  -- | Route for loading GitHub gists.
  ContractRoute_Gist  :: ContractRoute [Text]
  -- | Route for loading a deployed module.
  ContractRoute_Deployed :: ContractRoute [Text]
  -- | Route when editing a new file.
  ContractRoute_New :: ContractRoute ()
  -- | Route for auth handling
  ContractRoute_OAuth :: ContractRoute (R OAuthRoute)

backendRouteEncoder
  :: Encoder (Either Text) Identity (R (FullRoute BackendRoute FrontendRoute)) PageName
backendRouteEncoder = handleEncoder (\_e -> hoistR (FullRoute_Frontend . ObeliskRoute_App) landingPageRoute) $
  pathComponentEncoder $ \case
    FullRoute_Backend backendRoute -> case backendRoute of
      BackendRoute_Missing
        -> PathSegment "missing" $ unitEncoder mempty
      BackendRoute_Networks
        -> PathSegment "networks" $ unitEncoder mempty
      BackendRoute_Robots
        -> PathSegment "robots.txt" $ unitEncoder mempty
      BackendRoute_OAuthGetToken
        -> PathSegment "oauth-get-token" $ pathOnlyEncoder . singletonListEncoder . oAuthProviderIdEncoder
      BackendRoute_Css
        -> PathSegment "sass.css" $ unitEncoder mempty
    FullRoute_Frontend obeliskRoute -> obeliskRouteSegment obeliskRoute $ \case
      FrontendRoute_Contracts -> PathSegment "contracts" $ maybeEncoder (unitEncoder mempty) contractRouteEncoder
      FrontendRoute_Accounts -> PathSegment "accounts" $ queryOnlyEncoder
      -- FrontendRoute_Accounts -> PathSegment "accounts" $ unitEncoder mempty
      FrontendRoute_Keys -> PathSegment "keys" $ unitEncoder mempty
      FrontendRoute_Settings -> PathSegment "settings" $ unitEncoder mempty
      FrontendRoute_Resources -> PathSegment "resources" $ unitEncoder mempty

contractRouteEncoder :: (MonadError Text parse, MonadError Text check) => Encoder parse check (R ContractRoute) PageName
contractRouteEncoder = pathComponentEncoder $ \case
  ContractRoute_Example -> PathSegment "example" $ pathOnlyEncoderIgnoringQuery
  ContractRoute_Stored -> PathSegment "stored" $ pathOnlyEncoderIgnoringQuery
  ContractRoute_Gist -> PathSegment "gist" $ pathOnlyEncoderIgnoringQuery
  ContractRoute_Deployed -> PathSegment "deployed" $ pathOnlyEncoderIgnoringQuery
  ContractRoute_New -> PathSegment "new" $ unitEncoder mempty
  ContractRoute_OAuth -> PathSegment "oauth" $ oAuthRouteEncoder

-- | Stolen from Obelisk as it is not exported. (Probably for a reason, but it
-- seems to do what we want right now.
pathOnlyEncoderIgnoringQuery :: (Applicative check, MonadError Text parse) => Encoder check parse [Text] PageName
pathOnlyEncoderIgnoringQuery = unsafeMkEncoder $ EncoderImpl
  { _encoderImpl_decode = \(path, _query) -> pure path
  , _encoderImpl_encode = \path -> (path, mempty)
  }

landingPageRoute :: R FrontendRoute
landingPageRoute = FrontendRoute_Accounts :/ mempty

concat <$> mapM deriveRouteComponent
  [ ''BackendRoute
  , ''FrontendRoute
  , ''ContractRoute
  ]
