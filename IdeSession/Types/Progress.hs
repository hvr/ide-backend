{-# LANGUAGE TemplateHaskell #-}
module IdeSession.Types.Progress (
    Progress(..)
  , initialProgress
  , updateProgress
  , progressStep
  ) where

import Data.Aeson.TH (deriveJSON)

-- | This type represents intermediate progress information during compilation.
newtype Progress = Progress Int
  deriving (Show, Eq, Ord)

$(deriveJSON id ''Progress)

initialProgress :: Progress
initialProgress = Progress 1  -- the progress indicates a start of a step

updateProgress :: String -> Progress -> Progress
updateProgress _msg (Progress n) = Progress (n + 1)

-- | The step number of the progress. Usually corresponds to the number
-- of files already processed.
progressStep :: Progress -> Int
progressStep (Progress n) = n

