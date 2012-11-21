{-# LANGUAGE ScopedTypeVariables, TemplateHaskell #-}
-- | Implementation of the server that controls the long-running GHC instance.
-- This is the place where the GHC-specific part joins the part
-- implementing the general RPC infrastructure.
--
-- The modules importing any GHC internals, as well as the modules
-- implementing the  RPC infrastructure, should be accessible to the rest
-- of the program only indirectly, through the @GhcServer@ module.
module GhcServer
  ( -- * Types involved in the communication
    PCounter, GhcRequest(..), GhcResponse(..)
    -- * A handle to the server
  , GhcServer
    -- * Server-side operations
  , createGhcServer
    -- * Client-side operations
  , forkGhcServer
  , rpcGhcServer
  , shutdownGhcServer
  ) where

-- getExecutablePath is in base only for >= 4.6
import qualified Control.Exception as Ex
import System.Environment.Executable (getExecutablePath)
import System.FilePath ((</>), takeExtension)
import System.Directory
import Data.Aeson.TH (deriveJSON)
import System.IO
  ( stdin
  , stdout
  , stderr
  )
import Control.Monad (void)
import Control.Concurrent
  ( forkIO
  , myThreadId
  )
import Control.Concurrent.MVar
  ( newMVar
  , putMVar
  , modifyMVar_
  , takeMVar
  , isEmptyMVar
  )

import RpcServer
import Common
import GhcRun
import Progress

type PCounter = Int
data GhcRequest  = ReqCompute (Maybe [String]) FilePath
  deriving Show
data GhcResponse = RespWorking PCounter | RespDone [SourceError]
  deriving Show

$(deriveJSON id ''GhcRequest)
$(deriveJSON id ''GhcResponse)

-- Keeps the dynamic portion of the options specified at server startup
-- (they are among the options listed in SessionConfig).
-- They are only fed to GHC if no options are set via a session update command.
newtype GhcInitData = GhcInitData { dOpts :: DynamicOpts }

type GhcServer = RpcServer GhcRequest GhcResponse

-- * Server-side operations

hsExtentions:: [FilePath]
hsExtentions = [".hs", ".lhs"]

-- TODO: Do we want to return partial error information while it's
-- generated by runGHC, e.g., warnings? We could either try to run checkModule
-- file by file (do depanalSource and then DFS over the resulting graph,
-- doing \ m -> load (LoadUpTo m)) or rewrite collectSrcError to place
-- warnings in an mvar instead of IORef and read from it into Progress,
-- as soon as they appear.
ghcServerEngine :: GhcInitData -> GhcRequest
                -> IO (Progress GhcResponse GhcResponse)
ghcServerEngine GhcInitData{dOpts}
                (ReqCompute ideNewOpts configSourcesDir) = do
  mvCounter <- newMVar (Right 0)  -- Report progress step [0/n], too.
  let forkCatch :: IO () -> IO ()
      forkCatch p = do
        tid <- myThreadId
        void $ forkIO $ Ex.catch p (\ (ex :: Ex.SomeException) ->
                                     Ex.throwTo tid ex)
  forkCatch $ do
    cnts <- getDirectoryContents configSourcesDir
    let files = map (configSourcesDir </>)
                $ filter ((`elem` hsExtentions) . takeExtension) cnts
        incrementCounter (Right c) = Right (c + 1)
        incrementCounter (Left _)  = error "ghcServerEngine: unexpected Left"
        updateCounter = do
          -- Don't block, GHC should not be slowed down.
          b <- isEmptyMVar mvCounter
          if b
            -- Indicate that another one file was type-checked.
            then putMVar mvCounter (Right 1)
            -- If not consumed, increment count and keep working.
            else modifyMVar_ mvCounter (return . incrementCounter)
        dynOpts = maybe dOpts optsToDynFlags ideNewOpts
    errs <- checkModule files dynOpts updateCounter
    -- Don't block, GHC should not be slowed down.
    b <- isEmptyMVar mvCounter
    if b
      then putMVar mvCounter (Left errs)
      else modifyMVar_ mvCounter (return . const (Left errs))
  let p :: Int -> Progress GhcResponse GhcResponse
      p counter = Progress $ do
        -- Block until GHC processes the next file.
        merrs <- takeMVar mvCounter
        case merrs of
          Right new -> do
            -- Add the count of files type-checked since last time reported.
            -- The count is 1, unless the machine is busy and @p@ runs rarely.
            let newCounter = new + counter
            return $ Right (RespWorking newCounter, p newCounter)
          Left errs ->
            return $ Left $ RespDone errs
  return (p 0)

createGhcServer :: [String] -> IO ()
createGhcServer opts = do
  dOpts <- submitStaticOpts opts
  rpcServer stdin stdout stderr (ghcServerEngine GhcInitData{..})

-- * Client-side operations

forkGhcServer :: [String] -> FilePath -> IO GhcServer
forkGhcServer opts configTempDir = do
  prog <- getExecutablePath
  forkRpcServer prog ("--server" : opts) configTempDir

rpcGhcServer :: GhcServer -> (Maybe [String]) -> FilePath
             -> (Progress GhcResponse GhcResponse -> IO a) -> IO a
rpcGhcServer gs ideNewOpts configSourcesDir handler =
  rpcWithProgress gs (ReqCompute ideNewOpts configSourcesDir) handler

shutdownGhcServer :: GhcServer -> IO ()
shutdownGhcServer gs = shutdown gs
