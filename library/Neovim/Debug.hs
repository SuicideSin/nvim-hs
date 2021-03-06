{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{- |
Module      :  Neovim.Debug
Description :  Utilities to debug Neovim and nvim-hs functionality
Copyright   :  (c) Sebastian Witte
License     :  Apache-2.0

Maintainer  :  woozletoff@gmail.com
Stability   :  experimental
Portability :  GHC

-}
module Neovim.Debug (
    debug,
    debug',
    develMain,
    quitDevelMain,
    restartDevelMain,

    printGlobalFunctionMap,

    runNeovim,
    runNeovim',
    module Neovim,
    ) where

import           Neovim
import           Neovim.Classes
import           Neovim.Context                            (runNeovim)
import qualified Neovim.Context.Internal                   as Internal
import           Neovim.Log                                (disableLogger)
import           Neovim.Main                               (CommandLineOptions (..),
                                                            runPluginProvider)
import           Neovim.RPC.Common                         (RPCConfig)

import           Control.Monad
import qualified Data.Map                                  as Map
import           Foreign.Store

import           UnliftIO.Async                            (Async, async,
                                                            cancel)
import           UnliftIO.Concurrent                       (putMVar, takeMVar)
import           UnliftIO.STM

import           Data.Text.Prettyprint.Doc                 (nest, softline,
                                                            vcat, vsep)
import           Data.Text.Prettyprint.Doc.Render.Terminal (putDoc)

import           Prelude


-- | Run a 'Neovim' function.
--
-- This function connects to the socket pointed to by the environment variable
-- @$NVIM_LISTEN_ADDRESS@ and executes the command. It does not register itself
-- as a real plugin provider, you can simply call neovim-functions from the
-- module "Neovim.API.String" this way.
--
-- Tip: If you run a terminal inside a neovim instance, then this variable is
-- automatically set.
debug :: env -> Internal.Neovim env a -> IO (Either (Doc AnsiStyle) a)
debug env a = disableLogger $ do
    runPluginProvider def { envVar = True } Nothing transitionHandler Nothing
  where
    transitionHandler tids cfg = takeMVar (Internal.transitionTo cfg) >>= \case
        Internal.Failure e ->
            return $ Left e

        Internal.InitSuccess -> do
            res <- Internal.runNeovimInternal
                return
                (cfg { Internal.customConfig = env, Internal.pluginSettings = Nothing })
                a

            mapM_ cancel tids
            return res

        _ ->
            return . Left $ "Unexpected transition state."


-- | Run a 'Neovim'' function.
--
-- @
-- debug' a = fmap fst <$> debug () () a
-- @
--
-- See documentation for 'debug'.
debug' :: Internal.Neovim () a -> IO (Either (Doc AnsiStyle) a)
debug' a = debug () a


-- | This function is intended to be run _once_ in a ghci session that to
-- give a REPL based workflow when developing a plugin.
--
-- Note that the dyre-based reload mechanisms, i.e. the
-- "Neovim.Plugin.ConfigHelper" plugin, is not started this way.
--
-- To use this in ghci, you simply bind the results to some variables. After
-- each reload of ghci, you have to rebind those variables.
--
-- Example:
--
-- @
-- λ 'Right' (tids, cfg) <- 'develMain' 'Nothing'
--
-- λ 'runNeovim'' cfg \$ vim_call_function \"getqflist\" []
-- 'Right' ('Right' ('ObjectArray' []))
--
-- λ :r
--
-- λ 'Right' (tids, cfg) <- 'develMain' 'Nothing'
-- @
--
develMain
    :: Maybe NeovimConfig
    -> IO (Either (Doc AnsiStyle) [Async ()])
develMain mcfg = lookupStore 0 >>= \case
    Nothing -> do
        x <- disableLogger $
                runPluginProvider def { envVar = True } mcfg transitionHandler Nothing
        void $ newStore x
        return x

    Just x ->
        readStore x
  where
    transitionHandler tids cfg = takeMVar (Internal.transitionTo cfg) >>= \case
        Internal.Failure e ->
            return $ Left e

        Internal.InitSuccess -> do
            transitionHandlerThread <- async $ do
                void $ transitionHandler (tids) cfg
            return $ Right (transitionHandlerThread:tids)

        Internal.Quit -> do
            lookupStore 0 >>= \case
                Nothing ->
                    return ()

                Just x ->
                    deleteStore x

            mapM_ cancel tids
            return . Left $ "Quit develMain"

        _ ->
            return . Left $ "Unexpected transition state for develMain."


-- | Quit a previously started plugin provider.
quitDevelMain :: Internal.Config env -> IO ()
quitDevelMain cfg = putMVar (Internal.transitionTo cfg) Internal.Quit


-- | Restart the development plugin provider.
restartDevelMain
    :: Internal.Config RPCConfig
    -> Maybe NeovimConfig
    -> IO (Either (Doc AnsiStyle) [Async ()])
restartDevelMain cfg mcfg = do
    quitDevelMain cfg
    develMain mcfg


-- | Convenience function to run a stateless 'Neovim' function.
runNeovim' :: NFData a
           => Internal.Config env -> Neovim () a -> IO (Either (Doc AnsiStyle) a)
runNeovim' cfg =
    runNeovim (Internal.retypeConfig () cfg)


-- | Print the global function map to the console.
printGlobalFunctionMap :: Internal.Config env -> IO ()
printGlobalFunctionMap cfg = do
    es <- fmap Map.toList . atomically $ readTMVar (Internal.globalFunctionMap cfg)
    let header = "Printing global function map:"
        funs   = map (\(fname, (d, f)) ->
                    nest 3 (pretty fname
                    <> softline <> "->"
                    <> softline <> pretty d <+> ":"
                    <+> pretty f)) es
    putDoc $
        nest 2 $ vsep [header, vcat funs, mempty]


