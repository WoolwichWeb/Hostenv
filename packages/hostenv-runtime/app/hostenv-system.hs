module Main (main) where

import qualified Hostenv.System.Acme as Acme
import System.Environment (getArgs)
import System.Exit (exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    "acme" : rest -> Acme.run rest >>= exitWith
    _ -> do
      hPutStrLn stderr "Usage: hostenv-system acme [options] condition [UNIT] | run -- COMMAND | retry HOST ..."
      exitFailure
