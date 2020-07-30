module Messages exposing(..)

import Json.Decode
import Json.Encode exposing (Value)
-- The following module comes from bartavelle/json-helpers
import Json.Helpers exposing (..)
import Dict exposing (Dict)
import Set exposing (Set)


type BlackCard  =
    BlackCard String

jsonDecBlackCard : Json.Decode.Decoder ( BlackCard )
jsonDecBlackCard =
    Json.Decode.lazy (\_ -> Json.Decode.map BlackCard (Json.Decode.string))


jsonEncBlackCard : BlackCard -> Value
jsonEncBlackCard (BlackCard v1) =
    Json.Encode.string v1



type WhiteCard  =
    WhiteCard String

jsonDecWhiteCard : Json.Decode.Decoder ( WhiteCard )
jsonDecWhiteCard =
    Json.Decode.lazy (\_ -> Json.Decode.map WhiteCard (Json.Decode.string))


jsonEncWhiteCard : WhiteCard -> Value
jsonEncWhiteCard (WhiteCard v1) =
    Json.Encode.string v1



type alias GameView  =
   { opponents: (List String)
   , myName: String
   , blackCard: (Maybe BlackCard)
   , hand: (List WhiteCard)
   }

jsonDecGameView : Json.Decode.Decoder ( GameView )
jsonDecGameView =
   Json.Decode.succeed (\popponents pmyName pblackCard phand -> {opponents = popponents, myName = pmyName, blackCard = pblackCard, hand = phand})
   |> required "opponents" (Json.Decode.list (Json.Decode.string))
   |> required "myName" (Json.Decode.string)
   |> fnullable "blackCard" (jsonDecBlackCard)
   |> required "hand" (Json.Decode.list (jsonDecWhiteCard))

jsonEncGameView : GameView -> Value
jsonEncGameView  val =
   Json.Encode.object
   [ ("opponents", (Json.Encode.list Json.Encode.string) val.opponents)
   , ("myName", Json.Encode.string val.myName)
   , ("blackCard", (maybeEncode (jsonEncBlackCard)) val.blackCard)
   , ("hand", (Json.Encode.list jsonEncWhiteCard) val.hand)
   ]



type ServerMessage  =
    Welcome Int
    | SyncGameView GameView
    | Bye 

jsonDecServerMessage : Json.Decode.Decoder ( ServerMessage )
jsonDecServerMessage =
    let jsonDecDictServerMessage = Dict.fromList
            [ ("Welcome", Json.Decode.lazy (\_ -> Json.Decode.map Welcome (Json.Decode.int)))
            , ("SyncGameView", Json.Decode.lazy (\_ -> Json.Decode.map SyncGameView (jsonDecGameView)))
            , ("Bye", Json.Decode.lazy (\_ -> Json.Decode.succeed Bye))
            ]
    in  decodeSumObjectWithSingleField  "ServerMessage" jsonDecDictServerMessage

jsonEncServerMessage : ServerMessage -> Value
jsonEncServerMessage  val =
    let keyval v = case v of
                    Welcome v1 -> ("Welcome", encodeValue (Json.Encode.int v1))
                    SyncGameView v1 -> ("SyncGameView", encodeValue (jsonEncGameView v1))
                    Bye  -> ("Bye", encodeValue (Json.Encode.list identity []))
    in encodeSumObjectWithSingleField keyval val



type ClientMessage  =
    ChangeMyName String

jsonDecClientMessage : Json.Decode.Decoder ( ClientMessage )
jsonDecClientMessage =
    Json.Decode.lazy (\_ -> Json.Decode.map ChangeMyName (Json.Decode.string))


jsonEncClientMessage : ClientMessage -> Value
jsonEncClientMessage (ChangeMyName v1) =
    Json.Encode.string v1


