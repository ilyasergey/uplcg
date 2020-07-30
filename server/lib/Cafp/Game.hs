{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
module Cafp.Game
    ( PlayerId
    , Cards (..)
    , Game (..)
    , gameCards, gamePlayers, gameNextPlayerId

    , newGame
    , joinGame
    , leaveGame

    , processClientMessage

    , gameViewForPlayer
    ) where

import           Cafp.Messages
import           Control.Lens        (at, ix, over, to, (%~), (&), (.~), (^.),
                                      (^?))
import           Control.Lens.TH     (makeLenses)
import qualified Data.HashMap.Strict as HMS
import           Data.Maybe          (fromMaybe)
import           Data.Text           (Text)
import qualified Data.Text           as T

type PlayerId = Int

data Game = Game
    { _gameCards        :: !Cards
    , _gamePlayers      :: !(HMS.HashMap Int Text)
    , _gameNextPlayerId :: !Int
    } deriving (Show)

makeLenses ''Game

newGame :: Cards -> Game
newGame cards = Game cards HMS.empty 1

joinGame :: Game -> (PlayerId, Game)
joinGame game =
    let pid = game ^. gameNextPlayerId
        name = "Player " <> T.pack (show pid) in
    ( pid
    , game & gameNextPlayerId %~ succ & gamePlayers %~ HMS.insert pid name
    )

leaveGame :: PlayerId -> Game -> Game
leaveGame pid = over gamePlayers $ HMS.delete pid

processClientMessage :: PlayerId -> ClientMessage -> Game -> Game
processClientMessage pid msg game = case msg of
    ChangeMyName name ->
        game & gamePlayers . ix pid .~ name

gameViewForPlayer :: PlayerId -> Game -> GameView
gameViewForPlayer self game =
    let opponents = map snd . HMS.toList . HMS.delete self $ game ^. gamePlayers
        name = fromMaybe "" $ game ^. gamePlayers . at self in
    GameView
        { gameViewOpponents = opponents
        , gameViewMyName    = name
        , gameViewBlackCard = Just $ BlackCard 0
        , gameViewHand      = [WhiteCard x | x <- [0 .. 9]]
        }
