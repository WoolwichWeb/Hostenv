module Hostenv.Provider.DnsBackoff (backoffDelays) where

backoffDelays :: Int -> Int -> Int -> [Int]
backoffDelays initialDelay maxDelay totalBudget
    | totalBudget <= 0 = []
    | otherwise = go (max 1 initialDelay) 0
  where
    cap = max 1 maxDelay
    go _ elapsed | elapsed >= totalBudget = []
    go delay elapsed =
        let sleepFor = min delay (totalBudget - elapsed)
            nextDelay = min cap (delay * 2)
         in sleepFor : go nextDelay (elapsed + sleepFor)
