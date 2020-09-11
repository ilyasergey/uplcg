{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types        #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
module Uplcg.Game
    ( PlayerId
    , Table (..)
    , Player (..)
    , Game (..)
    , gameLog, gameCards, gamePlayers, gameNextPlayerId

    , newGame
    , joinGame
    , leaveGame

    , processClientMessage

    , gameViewForPlayer
    ) where

import           Control.Lens                 (Lens', at, iall, ifor_, imap, ix,
                                               orOf, to, (%%=), (%=), (%~), (&),
                                               (+=), (.=), (.~), (^.), (^..),
                                               (^?), _1, _2, _3)
import           Control.Lens.TH              (makeLenses, makePrisms)
import           Control.Monad                (guard)
import           Control.Monad.State          (State, execState, modify,
                                               runState, state)
import           Data.Bifunctor               (first)
import           Data.Foldable                (for_)
import qualified Data.HashMap.Strict          as HMS
import           Data.List                    (sort)
import           Data.Maybe                   (fromMaybe)
import           Data.Ord                     (Down (..), comparing)
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import qualified Data.Vector                  as V
import qualified Data.Vector.Algorithms.Merge as V
import           Data.Vector.Instances        ()
import           System.Random                (StdGen)
import           Uplcg.Messages
import           VectorShuffling.Immutable    (shuffle)

type PlayerId = Int

type Proposal = V.Vector WhiteCard

data Table
    = TableProposing
        !BlackCard
        !(HMS.HashMap PlayerId Proposal)
    | TableVoting
        !BlackCard
        !(V.Vector (Proposal, [PlayerId]))
        !(HMS.HashMap PlayerId Int)
    | TableTally
        !BlackCard
        !(V.Vector VotedView)
    deriving (Show)

data Player = Player
    { _playerId     :: !PlayerId
    , _playerName   :: !Text
    , _playerHand   :: !(V.Vector WhiteCard)
    , _playerAdmin  :: !Bool
    , _playerPoints :: !Int
    } deriving (Show)

data Game = Game
    { _gameCards        :: !Cards
    , _gameSeed         :: !StdGen
    , _gameLog          :: ![Text]
    , _gameBlack        :: ![BlackCard]
    , _gameWhite        :: ![WhiteCard]
    , _gamePlayers      :: !(HMS.HashMap PlayerId Player)
    , _gameTable        :: !Table
    , _gameNextPlayerId :: !Int
    } deriving (Show)

makePrisms ''Table
makeLenses ''Player
makeLenses ''Game

popCard
    :: (Cards -> V.Vector t) -> (Int -> c) -> Lens' Game [c]
    -> State Game c
popCard getDeck mk queue = state $ \game -> case game ^. queue of
    (x : xs) -> (x, game & queue .~ xs)
    []        ->
        let deck = game ^. gameCards . to getDeck
            idxs = V.imap (\i _ -> mk i) deck
            (cs, seed) = first V.toList $ shuffle idxs (game ^. gameSeed) in
        case cs of
            []     -> error "popCard: Cards are empty"
            x : xs -> (x, game & queue .~ xs & gameSeed .~ seed)

popBlackCard :: State Game BlackCard
popBlackCard = popCard cardsBlack BlackCard gameBlack

-- | Draw N white cards, that can't be part of the current hand.  Use a maximum
-- number of iterations as protection.
popWhiteCards :: V.Vector WhiteCard -> Int -> State Game (V.Vector WhiteCard)
popWhiteCards = go (10 :: Int)
  where
    go iters hand n
        | iters <= 0 = V.replicateM n popWhiteCard
        | n <= 0     = pure V.empty
        | otherwise  = do
            white <- popWhiteCard
            if white `V.elem` hand
                then go (iters - 1) hand n
                else V.cons white <$> go (iters - 1) (V.cons white hand) (n - 1)

    popWhiteCard :: State Game WhiteCard
    popWhiteCard = popCard cardsWhite WhiteCard gameWhite

newGame :: Cards -> StdGen -> Game
newGame cards gen = flip execState state0 $ do
    black <- popBlackCard
    gameTable .= TableProposing black HMS.empty
  where
    state0 = Game
        { _gameCards        = cards
        , _gameSeed         = gen
        , _gameLog          = []
        , _gameBlack        = []
        , _gameWhite        = []
        , _gamePlayers      = HMS.empty
        , _gameTable        = TableProposing (BlackCard 0) HMS.empty
        , _gameNextPlayerId = 1
        }

defaultHandSize :: Int
defaultHandSize = 8

drawNewWhiteCards :: Game -> Game
drawNewWhiteCards game = flip execState game $ do
    ifor_ (game ^. gamePlayers) $ \pid player -> do
        let num = defaultHandSize - V.length (player ^. playerHand)
        new <- popWhiteCards (player ^. playerHand) num
        gamePlayers . ix pid . playerHand %= (<> new)

assignAdmin :: Game -> Game
assignAdmin game
    -- Admin already assigned.
    | orOf (gamePlayers . traverse . playerAdmin) game = game
    -- Assign to first player
    | (p1 : _) <- sort (game ^. gamePlayers . to HMS.keys) =
        game & gamePlayers . ix p1 . playerAdmin .~ True
    -- No players
    | otherwise = game

joinGame :: Maybe Player -> Game -> (PlayerId, Game)
joinGame mbPlayer = runState $ do
    player <- case mbPlayer of
        Nothing -> do
            pid <- gameNextPlayerId %%= (\x -> (x, x + 1))
            let name = "Player " <> T.pack (show pid)
            hand <- popWhiteCards V.empty defaultHandSize
            pure $ Player pid name hand False 0
        Just p -> pure $ p & playerAdmin .~ False
    gamePlayers %= HMS.insert (player ^. playerId) player
    modify assignAdmin
    pure $ player ^. playerId

leaveGame :: PlayerId -> Game -> (Maybe Player, Game)
leaveGame pid game = case game ^? gamePlayers . ix pid of
    Nothing -> (Nothing, game)
    Just p  -> (Just p, assignAdmin $ game & gamePlayers %~ HMS.delete pid)

blackCardBlanks :: Cards -> BlackCard -> Int
blackCardBlanks cards (BlackCard c) =
    maybe 0 (length . T.breakOnAll "_") $ cardsBlack cards V.!? c

maximaOn :: Ord o => (a -> o) -> [a] -> [a]
maximaOn f = \case [] -> []; x : xs -> go [x] (f x) xs
  where
    go best _         []       = reverse best
    go best bestScore (x : xs) =
        let score = f x in
        case compare score bestScore of
            LT -> go best bestScore xs
            EQ -> go (x : best) bestScore xs
            GT -> go [x] score xs

tallyVotes
    :: Game
    -> (V.Vector (Proposal, [PlayerId]))
    -> (HMS.HashMap PlayerId Int)
    -> (V.Vector VotedView, [PlayerId])
tallyVotes game shuffled votes =
    let counts :: HMS.HashMap Int Int  -- Index, votes received.
        counts = HMS.fromListWith (+) [(idx, 1) | (_, idx) <- HMS.toList votes]
        best = map fst . maximaOn snd $ HMS.toList counts in
    ( byScore $ V.imap (\i (proposal, players) -> VotedView
        { votedProposal = proposal
        , votedScore    = fromMaybe 0 $ HMS.lookup i counts
        , votedWinners  = V.fromList $ do
            guard $ i `elem` best
            p <- players
            game ^.. gamePlayers . ix p . playerName
        })
        shuffled
    , [player | idx <- best, player <- snd $ shuffled V.! idx]
    )
  where
    byScore = V.modify $ V.sortBy . comparing $ Down . votedScore

-- | Create nice messages about the winners in the logs.
votedMessages :: Cards -> BlackCard -> V.Vector VotedView -> [T.Text]
votedMessages cards (BlackCard black) voteds = do
    voted <- V.toList voteds
    guard $ V.length (votedWinners voted) > 0
    pure $
        T.intercalate ", " (V.toList $ votedWinners voted) <> " won with " <>
        cardsBlack cards V.! black <> " | " <>
        T.intercalate " / "
            [ cardsWhite cards V.! i
            | WhiteCard i <- V.toList $ votedProposal voted
            ]

stepGame :: Bool -> Game -> Game
stepGame skip game = case game ^. gameTable of
    TableProposing black proposals
        -- Everyone has proposed.
        | skip || iall (const . (`HMS.member` proposals)) (game ^. gamePlayers) ->
            let proposalsMap = HMS.fromListWith (++) $ do
                    (pid, proposal) <- HMS.toList proposals
                    pure (proposal, [pid])
                (shuffled, seed) = shuffle
                    (V.fromList $ HMS.toList proposalsMap) (game ^. gameSeed) in
            -- There's a recursive call because in some one-player cases we
            -- skip the voting process entirely.
            stepGame False $ game
                & gameSeed .~ seed
                & gameTable .~ TableVoting black shuffled HMS.empty
                & gamePlayers %~ imap (\pid player ->
                    let used = fromMaybe V.empty $ HMS.lookup pid proposals in
                    player & playerHand %~ V.filter (not . (`V.elem` used)))
        | otherwise -> game

    TableVoting black shuffled votes
        -- Everyone has voted.
        | skip || iall hasVoted (game ^. gamePlayers) ->
            let (voted, wins) = tallyVotes game shuffled votes in
            flip execState game $ do
            for_ wins $ \win -> gamePlayers . ix win . playerPoints += 1
            gameTable .= TableTally black voted
            gameLog %= (votedMessages (game ^. gameCards) black voted ++)
        | otherwise -> game
      where
        hasVoted pid _ = HMS.member pid votes ||
            -- The person cannot vote for anything since all the proposals
            -- are theirs.  This can happen when the game starts out with a
            -- single person.
            V.all (\(_, pids) -> pid `elem` pids) shuffled

    TableTally _ _ -> game

processClientMessage :: PlayerId -> ClientMessage -> Game -> Game
processClientMessage pid msg game = case msg of
    ChangeMyName name
        | T.length name > 32 -> game
        | otherwise -> game & gamePlayers . ix pid . playerName .~ name

    ProposeWhiteCards cs
        -- Bad card(s) proposed, i.e. not in hand of player.
        | any (not . (`elem` hand)) cs -> game
        -- Proposal already made.
        | Just _ <- game ^? gameTable . _TableProposing . _2 . ix pid -> game
        -- Not enough cards submitted.
        | Just b <- game ^? gameTable . _TableProposing . _1
        , blackCardBlanks (game ^. gameCards) b /= length cs -> game
        -- All good.
        | otherwise -> stepGame False $
            game & gameTable . _TableProposing . _2 . at pid .~ Just cs

    SubmitVote i -> case game ^. gameTable of
        TableProposing _ _ -> game
        TableTally _ _ -> game
        TableVoting _ shuffled votes
            -- Vote out of bounds.
            | i < 0 || i >= V.length shuffled -> game
            -- Already voted.
            | pid `HMS.member` votes -> game
            -- Can't vote for self.
            | pid `elem` snd (shuffled V.! i) -> game
            -- Ok vote.
            | otherwise -> stepGame False $ game
                & gameTable . _TableVoting . _3 . at pid .~ Just i

    AdminConfirmTally
        | TableTally _ _ <- game ^. gameTable, admin ->
            flip execState game $ do
            black <- popBlackCard
            gameTable .= TableProposing black HMS.empty
            modify drawNewWhiteCards
        | otherwise -> game

    AdminSkipProposals
        | TableProposing _ _ <- game ^. gameTable, admin -> stepGame True $
            game & gameLog %~ ("Admin skipped proposals" :)
        | otherwise -> game

    AdminSkipVotes
        | TableVoting _ _ _ <- game ^. gameTable, admin -> stepGame True $
            game & gameLog %~ ("Admin skipped votes" :)
        | otherwise -> game
  where
    hand  = game ^.. gamePlayers . ix pid . playerHand . traverse
    admin = fromMaybe False $ game ^? gamePlayers . ix pid . playerAdmin

gameViewForPlayer :: PlayerId -> Game -> GameView
gameViewForPlayer self game =
    let playerView pid player = PlayerView
            { playerViewName = player ^. playerName
            , playerViewAdmin = player ^. playerAdmin
            , playerViewReady = case game ^. gameTable of
                TableProposing _ proposals -> HMS.member pid proposals
                TableVoting _ _ votes      -> HMS.member pid votes
                TableTally _ _             -> False
            , playerViewPoints = player ^. playerPoints
            }

        table = case game ^. gameTable of
            TableProposing black proposals ->
                Proposing black . fromMaybe V.empty $ HMS.lookup self proposals
            TableVoting black shuffled votes -> Voting
                black
                (fst <$> shuffled)
                (V.findIndex ((self `elem`) . snd) shuffled)
                (HMS.lookup self votes)
            TableTally black voted -> Tally black voted in
    GameView
        { gameViewPlayers = V.fromList . map snd . HMS.toList
            . HMS.delete self . imap playerView $ game ^. gamePlayers
        , gameViewMe      = maybe dummy (playerView self) $
            game ^? gamePlayers . ix self
        , gameViewTable   = table
        , gameViewHand    = fromMaybe V.empty $
            game ^? gamePlayers . ix self . playerHand
        }

  where
    dummy = PlayerView "" False False 0
