-- {-# LANGUAGE GHCForeignImportPrim #-}
-- {-# LANGUAGE UnboxedTuples #-}
-- {-# LANGUAGE BangPatterns #-}
-- {-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnliftedFFITypes #-}


module Main where
import System.IO (hPutStrLn, stderr)
import GHC.Conc (newStablePtrPrimMVar, PrimMVar)
import Foreign (StablePtr)
import Data.Array.Byte (ByteArray)
import GHC.Exts (Array#)

main = 
  hPutStrLn stderr "Hello 1"

foreign export ccall pdk_test_nix_on_eval :: IO ()
pdk_test_nix_on_eval = do
  _ <- hPutStrLn stderr "void"
  _ <- hPutStrLn stderr "(builtins.getFlake github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e).legacyPackages.x86_64-linux.hello.meta.description"
  _ <- hPutStrLn stderr "raw"
  let user_data = "(builtins.getFlake github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e).legacyPackages.x86_64-linux.hello.meta.description"
  nix_on_eval
    "pdk_test_nix_on_eval_callback"
    user_data
    (length user_data)
    ()
    2
  return ()

-- foreign import ccall "nix_on_eval"
--   nix_on_eval :: StablePtr PrimMVar -> Int -> Ptr Result -> IO ()

foreign import ccall
  "nix_on_eval" nix_on_eval ::
  StablePtr Int -> -- func_name
  StablePtr Int -> -- user_data_ptr
  Int -> -- user_data_len
  StablePtr Int -> -- expression
  Int -> -- format
  IO ()
