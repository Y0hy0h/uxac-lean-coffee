port module Main exposing (Model, Msg(..), init, main, update, view)

import Browser
import Browser.Dom exposing (Error(..))
import Css exposing (auto, num, pct, px, rem, zero)
import Css.Animations as Animations
import Css.Global as Global
import Css.Media as Media
import Dict exposing (Dict)
import Html.Styled as Html exposing (Attribute, Html, button, div, form, h1, h2, img, input, label, li, ol, span, text, textarea)
import Html.Styled.Attributes as Attributes exposing (css, src, type_, value)
import Html.Styled.Events exposing (on, onClick, onInput, onMouseEnter, onSubmit)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import List.Extra as List
import Random
import Remote exposing (Remote(..))
import Set exposing (Set)
import SortedDict exposing (SortedDict)
import Time
import UUID


main =
    Browser.element
        { view = view >> Html.toUnstyled
        , init = init
        , update = update
        , subscriptions = subscriptions
        }



---- MODEL ----


type alias Model =
    { inDiscussion : Maybe TopicId
    , topics : Remote TopicList
    , readTopics : Set TopicId
    , topicsBeingEdited : Dict TopicId String
    , discussed : List ( TopicId, Maybe Time.Posix )
    , votes : Remote Votes
    , continuationVoteActive : Remote Bool
    , continuationVotes : Remote (List ContinuationVote)
    , deadline : Maybe Time.Posix
    , now : Maybe Time.Posix
    , timerInput : String
    , newTopicInput : String
    , user : Remote User
    , error : Maybe Error
    , workspace : Maybe String
    , uuidSeeds : UUID.Seeds

    {- This allows us to specify that a server should add a timestamp
       in a document's field.
       See https://firebase.google.com/docs/firestore/manage-data/add-data#server_timestamp.
    -}
    , timestampField : TimestampField
    }


type alias TopicList =
    SortedDict TopicId Topic


type alias TopicId =
    String


type alias Topic =
    { topic : String
    , creator : String
    , createdAt : Maybe Time.Posix
    }


type alias VoteCountMap =
    TopicId -> Int


sortTopicList : VoteCountMap -> TopicList -> TopicList
sortTopicList voteCountMap oldTopics =
    SortedDict.stableSortWith (topicListSort voteCountMap) oldTopics


isTopicListSorted : VoteCountMap -> TopicList -> Bool
isTopicListSorted voteCountMap topics =
    let
        sorted =
            sortTopicList voteCountMap topics
    in
    sorted == topics


topicListSort : VoteCountMap -> (( TopicId, Topic ) -> ( TopicId, Topic ) -> Order)
topicListSort voteCountMap =
    \( id1, _ ) ( id2, _ ) ->
        let
            votes1 =
                voteCountMap id1

            votes2 =
                voteCountMap id2
        in
        compare votes1 votes2
            |> inverseOrder


inverseOrder : Order -> Order
inverseOrder order =
    case order of
        EQ ->
            EQ

        LT ->
            GT

        GT ->
            LT


type alias Votes =
    Dict TopicId (List UserId)


type alias Vote =
    { userId : UserId, topicId : TopicId }


voteFrom : User -> TopicId -> Vote
voteFrom user topicId =
    { userId = getUserId user, topicId = topicId }


type alias ContinuationVote =
    { userId : UserId
    , vote : Continuation
    }


type Continuation
    = MoveOn
    | Stay
    | Abstain


type User
    = AnonymousUser { id : UserId }
    | GoogleUser { id : UserId, email : String, isAdmin : Remote Bool, adminActive : Bool }


setAdminActiveForUser : Bool -> Remote User -> Remote User
setAdminActiveForUser adminActive remoteUser =
    case remoteUser of
        Got (GoogleUser user) ->
            Got (GoogleUser { user | adminActive = adminActive })

        user ->
            user


isAdminActiveForUser : Remote User -> Bool
isAdminActiveForUser user =
    case user of
        Got (GoogleUser googleUser) ->
            let
                isAdmin =
                    Remote.toMaybe googleUser.isAdmin
                        |> Maybe.withDefault False
            in
            isAdmin && googleUser.adminActive

        _ ->
            False


getUserId : User -> UserId
getUserId user =
    case user of
        AnonymousUser { id } ->
            id

        GoogleUser { id } ->
            id


type alias UserId =
    String


type alias Error =
    { summary : String
    , info : ErrorInfo
    }


type ErrorInfo
    = FirestoreError FirestoreErrorInfo
    | ParsingError Decode.Error


type alias FirestoreErrorInfo =
    { code : String, errorMessage : String }


type alias TimestampField =
    Decode.Value


type alias Flags =
    { timestampField : TimestampField
    , workspaceQuery : String
    , uuidSeeds : { seed1 : Int, seed2 : Int, seed3 : Int, seed4 : Int }
    }


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        workspaceQueryPrefix =
            "?workspace="

        workspace =
            if String.startsWith workspaceQueryPrefix flags.workspaceQuery then
                let
                    sanitizedWorkspace =
                        String.dropLeft (String.length workspaceQueryPrefix) flags.workspaceQuery
                            |> String.trim
                in
                if String.isEmpty sanitizedWorkspace then
                    Nothing

                else
                    Just sanitizedWorkspace

            else
                Nothing

        uuidSeeds =
            { seed1 = Random.initialSeed flags.uuidSeeds.seed1
            , seed2 = Random.initialSeed flags.uuidSeeds.seed2
            , seed3 = Random.initialSeed flags.uuidSeeds.seed3
            , seed4 = Random.initialSeed flags.uuidSeeds.seed4
            }
    in
    ( { inDiscussion = Nothing
      , topics = Loading
      , readTopics = Set.empty
      , topicsBeingEdited = Dict.empty
      , discussed = []
      , votes = Loading
      , continuationVoteActive = Loading
      , continuationVotes = Loading
      , deadline = Nothing
      , now = Nothing
      , timerInput = "10"
      , newTopicInput = ""
      , user = Loading
      , error = Nothing
      , workspace = workspace
      , uuidSeeds = uuidSeeds
      , timestampField = flags.timestampField
      }
    , Cmd.none
    )



---- UPDATE ----


type Msg
    = UserReceived (Result Decode.Error User)
    | IsAdminReceived Bool
    | LogInWithGoogleClicked
    | SetAdmin Bool
    | DecodeError Decode.Error
    | TopicChangesReceived TopicChanges
    | VotesReceived Votes
    | TopicInDiscussionReceived (Maybe TopicId)
    | ContinuationVoteActiveReceived Bool
    | ContinuationVotesReceived (List ContinuationVote)
    | DiscussedTopicsReceived (List ( TopicId, Maybe Time.Posix ))
    | DeadlineReceived (Maybe Time.Posix)
    | Read TopicId
    | SaveTopic User
    | EditTopicClicked TopicId
    | TopicEdited TopicId String
    | SaveTopicClicked TopicId
    | DeleteTopic TopicId
    | Discuss TopicId
    | FinishDiscussionClicked
    | VoteAgainClicked
    | SortTopics
    | Upvote User TopicId
    | RemoveUpvote User TopicId
    | StartContinuationVote
    | ClearContinuationVote
    | ContinuationVoteSent ContinuationVote
    | RemoveContinuationVote UserId
    | ErrorReceived (Result Decode.Error FirestoreErrorInfo)
    | DismissError
    | NewTopicInputChanged String
    | Tick Time.Posix
    | TimerInputChanged String
    | TimerStarted
    | TimerCleared


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        voteCountMap =
            voteCountMapFromVotes model.votes
    in
    case msg of
        UserReceived result ->
            case result of
                Ok user ->
                    ( { model | user = Got user }, firestoreSubscriptionsCmd model.workspace )

                Err error ->
                    ( { model | error = Just (processParsingError error) }, Cmd.none )

        IsAdminReceived isAdmin ->
            let
                newUser =
                    case model.user of
                        Got (GoogleUser user) ->
                            Got (GoogleUser { user | isAdmin = Got isAdmin })

                        user ->
                            user
            in
            ( { model | user = newUser }, Cmd.none )

        LogInWithGoogleClicked ->
            ( model, logInWithGoogle_ () )

        SetAdmin isAdmin ->
            ( { model | user = setAdminActiveForUser isAdmin model.user }, Cmd.none )

        DecodeError error ->
            ( { model | error = Just (processParsingError error) }, Cmd.none )

        TopicChangesReceived changes ->
            ( { model | topics = updateTopicList voteCountMap changes model.topics }, Cmd.none )

        VotesReceived votes ->
            let
                newModel =
                    case model.votes of
                        Loading ->
                            { model
                                | votes = Got votes

                                -- If the votes are coming in for the first time, immediately sort the topics.
                                , topics =
                                    Remote.map
                                        (sortTopicList <| voteCountMapFromVotes <| Got votes)
                                        model.topics
                            }

                        Got _ ->
                            { model | votes = Got votes }
            in
            ( newModel, Cmd.none )

        ContinuationVoteActiveReceived isActive ->
            ( { model | continuationVoteActive = Got isActive }, Cmd.none )

        ContinuationVotesReceived continuationVotes ->
            ( { model | continuationVotes = Got continuationVotes }, Cmd.none )

        TopicInDiscussionReceived topic ->
            ( { model | inDiscussion = topic }, Cmd.none )

        DiscussedTopicsReceived discussed ->
            ( { model | discussed = discussed }, Cmd.none )

        DeadlineReceived deadline ->
            ( { model | deadline = deadline }, Cmd.none )

        ErrorReceived result ->
            case result of
                Ok info ->
                    ( { model | error = Just <| processFirestoreError info }, Cmd.none )

                Err error ->
                    ( { model | error = Just (processParsingError error) }, Cmd.none )

        DismissError ->
            ( { model | error = Nothing }, Cmd.none )

        Read topicId ->
            ( { model | readTopics = Set.insert topicId model.readTopics }, Cmd.none )

        SaveTopic user ->
            case model.newTopicInput of
                "" ->
                    ( { model | newTopicInput = "" }, Cmd.none )

                topic ->
                    let
                        ( uuid, newSeeds ) =
                            UUID.step model.uuidSeeds

                        topicId =
                            UUID.toString uuid

                        newTopic =
                            { topic = topic
                            , userId = getUserId user
                            , createdAt = model.timestampField
                            }

                        newRead =
                            Set.insert topicId model.readTopics
                    in
                    ( { model
                        | newTopicInput = ""
                        , readTopics = newRead
                        , uuidSeeds = newSeeds
                      }
                    , submitTopic model.workspace topicId newTopic
                    )

        EditTopicClicked id ->
            let
                maybeTopic =
                    Remote.toMaybe model.topics
                        |> Maybe.andThen (SortedDict.get id)
                        |> Maybe.map .topic

                newTopicsBeingEdited =
                    case maybeTopic of
                        Just topic ->
                            Dict.insert id topic model.topicsBeingEdited

                        _ ->
                            model.topicsBeingEdited
            in
            ( { model | topicsBeingEdited = newTopicsBeingEdited }, selectTextarea_ id )

        TopicEdited id newEdit ->
            let
                newTopicsBeingEdited =
                    model.topicsBeingEdited
                        |> Dict.update id (Maybe.map (\_ -> newEdit))
            in
            ( { model | topicsBeingEdited = newTopicsBeingEdited }, Cmd.none )

        SaveTopicClicked id ->
            case
                Dict.get id model.topicsBeingEdited
                    |> Maybe.andThen
                        (\newEdit ->
                            Remote.toMaybe model.topics
                                |> Maybe.andThen (SortedDict.get id)
                                |> Maybe.map (\topic -> ( topic, newEdit ))
                        )
            of
                Just ( topic, newEdit ) ->
                    let
                        newTopicsBeingEdited =
                            Dict.remove id model.topicsBeingEdited

                        newTopic =
                            { topic | topic = newEdit }
                    in
                    ( { model | topicsBeingEdited = newTopicsBeingEdited }, setTopic model.workspace id newTopic )

                _ ->
                    ( model, Cmd.none )

        DeleteTopic id ->
            ( model, deleteTopic model.workspace id model.votes )

        Discuss topicId ->
            ( model, submitTopicInDiscussion model.workspace topicId )

        FinishDiscussionClicked ->
            case model.inDiscussion of
                Just inDiscussion ->
                    let
                        cmds =
                            Cmd.batch
                                [ finishDiscussion model.workspace inDiscussion model.timestampField
                                , clearContinuationVotes model.workspace (Remote.toMaybe model.continuationVotes)
                                , clearDeadline model.workspace
                                ]
                    in
                    ( model, cmds )

                Nothing ->
                    ( model, Cmd.none )

        VoteAgainClicked ->
            case model.inDiscussion of
                Just inDiscussion ->
                    ( model, removeTopicInDiscussion model.workspace )

                Nothing ->
                    ( model, Cmd.none )

        StartContinuationVote ->
            ( model, startContinuationVote model.workspace )

        ClearContinuationVote ->
            ( model, clearContinuationVotes model.workspace (Remote.toMaybe model.continuationVotes) )

        ContinuationVoteSent vote ->
            ( model, submitContinuationVote model.workspace vote )

        RemoveContinuationVote userId ->
            ( model, retractContinuationVote model.workspace userId )

        SortTopics ->
            ( { model | topics = Remote.map (sortTopicList voteCountMap) model.topics }, Cmd.none )

        Upvote user topicId ->
            ( model, submitVote model.workspace (voteFrom user topicId) )

        RemoveUpvote user topicId ->
            ( model, retractVote model.workspace (voteFrom user topicId) )

        NewTopicInputChanged value ->
            ( { model | newTopicInput = value }, Cmd.none )

        Tick now ->
            ( { model | now = Just now }, Cmd.none )

        TimerInputChanged newInput ->
            ( { model | timerInput = newInput }, Cmd.none )

        TimerStarted ->
            let
                maybeTimerInput =
                    String.toInt model.timerInput
            in
            case ( model.now, maybeTimerInput ) of
                ( Just now, Just timerInput ) ->
                    let
                        sanitizedTimerInput =
                            timerInput
                                |> atLeast 0

                        timerInputInMilliseconds =
                            sanitizedTimerInput * 1000 * 60

                        deadline =
                            Time.posixToMillis now
                                + timerInputInMilliseconds
                                |> Time.millisToPosix

                        cmds =
                            Cmd.batch
                                [ submitDeadline model.workspace deadline
                                , clearContinuationVotes model.workspace (Remote.toMaybe model.continuationVotes)
                                ]
                    in
                    ( model, cmds )

                _ ->
                    ( model, Cmd.none )

        TimerCleared ->
            ( model, clearDeadline model.workspace )


processParsingError : Decode.Error -> Error
processParsingError decodeError =
    { summary = "I received some weird data. Hopefully we can just ignore it, but something might not be working anymore."
    , info = ParsingError decodeError
    }


processFirestoreError : FirestoreErrorInfo -> Error
processFirestoreError info =
    { summary = "There was a problem with the database."
    , info = FirestoreError info
    }


voteCountMapFromVotes : Remote Votes -> VoteCountMap
voteCountMapFromVotes remoteVotes =
    \topicId ->
        case remoteVotes of
            Loading ->
                0

            Got votes ->
                Dict.get topicId votes |> Maybe.withDefault [] |> List.length


updateTopicList : VoteCountMap -> TopicChanges -> Remote TopicList -> Remote TopicList
updateTopicList voteCountMap changes remoteTopics =
    (case remoteTopics of
        Loading ->
            List.foldl (\( id, topic ) topics -> SortedDict.insert id topic topics) SortedDict.empty changes.added
                |> sortTopicList voteCountMap

        Got currentTopics ->
            let
                topicsRemoved =
                    List.foldl (\id topics -> SortedDict.remove id topics) currentTopics changes.removed

                topicsModified =
                    List.foldl (\( id, newTopic ) topics -> SortedDict.update id (Maybe.map (\_ -> newTopic)) topics) topicsRemoved changes.modified
            in
            List.foldl (\( id, topic ) topics -> SortedDict.insert id topic topics) topicsModified changes.added
    )
        |> Got


submitTopic : Maybe String -> TopicId -> NewTopicSubmission -> Cmd msg
submitTopic workspace id newTopic =
    setDoc
        { docPath = topicCollectionPath workspace ++ [ id ]
        , doc =
            newTopicEncoder
                newTopic
        }


setTopic : Maybe String -> TopicId -> Topic -> Cmd msg
setTopic workspace topicId newTopic =
    let
        topicPath =
            topicCollectionPath workspace ++ [ topicId ]
    in
    setDoc
        { docPath = topicPath
        , doc = topicEncoder newTopic
        }


deleteTopic : Maybe String -> TopicId -> Remote Votes -> Cmd msg
deleteTopic workspace topicId votes =
    let
        topicPath =
            topicCollectionPath workspace ++ [ topicId ]

        {- We delete all associated votes as well.
           TODO: This smells like there might be a race condition when others add votes when we delete them. Instead, use batches. See https://github.com/Y0hy0h/uxac-lean-coffee/issues/37.
        -}
        votePaths =
            Remote.toMaybe votes
                |> Maybe.withDefault Dict.empty
                |> Dict.get topicId
                |> Maybe.withDefault []
                |> List.map (\userId -> topicVotePath workspace { userId = userId, topicId = topicId })
    in
    deleteDocs (topicPath :: votePaths)


submitVote : Maybe String -> Vote -> Cmd msg
submitVote workspace vote =
    setDoc
        { docPath = topicVotePath workspace vote
        , doc =
            topicVoteEncoder vote
        }


topicVotePath : Maybe String -> Vote -> Path
topicVotePath workspace ids =
    voteCollectionPath workspace ++ [ ids.userId ++ ":" ++ ids.topicId ]


retractVote : Maybe String -> Vote -> Cmd msg
retractVote workspace vote =
    deleteDocs [ topicVotePath workspace vote ]


startContinuationVote : Maybe String -> Cmd msg
startContinuationVote workspace =
    setDoc
        { docPath = continuationVoteActiveDocPath workspace
        , doc = encodeContinuationVoteActive True
        }


submitContinuationVote : Maybe String -> ContinuationVote -> Cmd msg
submitContinuationVote workspace vote =
    setDoc
        { docPath = continuationVotePath workspace vote.userId
        , doc = continuationVoteEncoder vote
        }


retractContinuationVote : Maybe String -> UserId -> Cmd msg
retractContinuationVote workspace userId =
    deleteDocs
        [ continuationVotePath workspace userId
        ]


clearContinuationVotes : Maybe String -> Maybe (List ContinuationVote) -> Cmd msg
clearContinuationVotes workspace maybeVotes =
    case maybeVotes of
        Nothing ->
            Cmd.none

        Just votes ->
            deleteDocs
                ([ continuationVoteActiveDocPath workspace ]
                    ++ List.map
                        (\vote ->
                            continuationVotePath workspace vote.userId
                        )
                        votes
                )


continuationVotePath : Maybe String -> UserId -> Path
continuationVotePath workspace userId =
    continuationVoteCollectionPath workspace ++ [ userId ]


submitTopicInDiscussion : Maybe String -> TopicId -> Cmd msg
submitTopicInDiscussion workspace topicId =
    setDoc
        { docPath = inDiscussionDocPath workspace
        , doc = topicIdEncoder topicId
        }


finishDiscussion : Maybe String -> TopicId -> TimestampField -> Cmd msg
finishDiscussion workspace topicId timestamp =
    Cmd.batch
        [ deleteDocs [ inDiscussionDocPath workspace ]
        , insertDoc
            { collectionPath = discussedCollectionPath workspace
            , doc = discussedTopicEncoder topicId timestamp
            }
        ]


removeTopicInDiscussion : Maybe String -> Cmd msg
removeTopicInDiscussion workspace =
    deleteDocs [ inDiscussionDocPath workspace ]


submitDeadline : Maybe String -> Time.Posix -> Cmd msg
submitDeadline workspace deadline =
    setDoc
        { docPath = discussionDeadlineDocPath workspace
        , doc = encodeDeadline deadline
        }


clearDeadline : Maybe String -> Cmd msg
clearDeadline workspace =
    deleteDocs
        [ discussionDeadlineDocPath workspace
        ]



---- VIEW ----


view : Model -> Html Msg
view model =
    let
        isAdmin =
            isAdminActiveForUser model.user

        heading =
            "UXAC Lean Coffee"
                ++ (if isAdmin then
                        " (Admin)"

                    else
                        ""
                   )

        continuationVotes =
            if Remote.toMaybe model.continuationVoteActive |> Maybe.withDefault False then
                Remote.toMaybe model.continuationVotes

            else
                Nothing

        { inDiscussion, topicList, discussedList } =
            processTopics model
    in
    div
        [ css
            [ bodyFont
            , Global.descendants [ Global.h2 [ headingStyle ] ]
            , Css.margin2 zero auto
            ]
        ]
        [ div
            [ css
                [ limitWidth
                , Css.marginBottom (rem 1)
                , listItemSpacing
                ]
            ]
            ([ div
                [ css
                    [ Css.displayFlex
                    , Css.flexDirection Css.row
                    , Css.alignItems Css.center
                    ]
                ]
                [ logo
                , h1 [ css [ Css.margin zero ] ] [ text heading ]
                ]
             ]
                ++ [ settingsView model.user ]
                ++ errorView model.error
                ++ [ discussionView model.user inDiscussion continuationVotes model model.timerInput ]
                ++ discussedTopics model.user discussedList
                ++ [ topicEntry model.user model.newTopicInput ]
            )
        , topicsToVote model.user topicList (sortBarView model.votes model.topics)
        ]


logo : Html Msg
logo =
    img
        [ src "./logo.svg"
        , Attributes.width 512
        , Attributes.height 512
        , Attributes.alt ""
        , css
            [ Css.maxHeight (rem 2)
            , Css.width auto
            , Css.marginRight (rem 1)
            ]
        ]
        []


limitWidth : Css.Style
limitWidth =
    Css.batch
        [ Css.maxWidth (rem 32)
        , Css.marginLeft auto
        , Css.marginRight auto
        ]


headingStyle : Css.Style
headingStyle =
    Css.fontSize (rem 1.2)


type alias TopicWithVotes =
    ( TopicId
    , { topic : Topic
      , mark : Mark
      , votes : List UserId
      , beingEdited : Maybe String
      }
    )


type Mark
    = Unread
    | NoMark


processTopics :
    { a
        | inDiscussion : Maybe TopicId
        , topics : Remote TopicList
        , readTopics : Set TopicId
        , topicsBeingEdited : Dict TopicId String
        , discussed : List ( TopicId, Maybe Time.Posix )
        , votes : Remote Votes
    }
    ->
        { inDiscussion : Maybe TopicWithVotes
        , topicList : Remote (List TopicWithVotes)
        , discussedList : List TopicWithVotes
        }
processTopics model =
    case model.topics of
        Loading ->
            { inDiscussion = Nothing, topicList = Loading, discussedList = [] }

        Got topics ->
            let
                topicsWithVotes =
                    Remote.toMaybe model.votes
                        |> Maybe.map
                            (\votes ->
                                SortedDict.toList topics
                                    |> List.map
                                        (\( id, topic ) ->
                                            let
                                                mark =
                                                    if Set.member id model.readTopics then
                                                        NoMark

                                                    else
                                                        Unread
                                            in
                                            ( id
                                            , { topic = topic
                                              , votes =
                                                    Dict.get id votes
                                                        |> Maybe.withDefault []
                                              , mark = mark
                                              , beingEdited = Dict.get id model.topicsBeingEdited
                                              }
                                            )
                                        )
                            )
                        |> Maybe.withDefault []

                ( maybeInDiscussion, remainingTopics ) =
                    Maybe.map (\topicId -> extract (\( id, entry ) -> id == topicId) topicsWithVotes)
                        model.inDiscussion
                        |> Maybe.withDefault ( Nothing, topicsWithVotes )

                discussedDict =
                    Dict.fromList model.discussed

                ( discussedUnsorted, toVote ) =
                    List.foldl
                        (\( id, t ) ( currentDiscussed, currentToVote ) ->
                            case Dict.get id discussedDict of
                                Just time ->
                                    ( ( ( id, t ), time ) :: currentDiscussed, currentToVote )

                                Nothing ->
                                    ( currentDiscussed, currentToVote ++ [ ( id, t ) ] )
                        )
                        ( [], [] )
                        remainingTopics

                discussed =
                    let
                        -- This is the biggest integer we can have. (See https://package.elm-lang.org/packages/elm/core/latest/Basics#Int)
                        maxInt =
                            (2 ^ 53) - 1
                    in
                    List.sortBy
                        (\( _, time ) ->
                            Maybe.map Time.posixToMillis time
                                |> Maybe.withDefault maxInt
                        )
                        discussedUnsorted
                        |> List.reverse
                        |> List.map Tuple.first
            in
            { inDiscussion = maybeInDiscussion
            , topicList = Got toVote
            , discussedList = discussed
            }


extract : (a -> Bool) -> List a -> ( Maybe a, List a )
extract predicate list =
    List.partition predicate list
        |> Tuple.mapFirst List.head


settingsView : Remote User -> Html Msg
settingsView remoteUser =
    Html.details [ css [ detailsStyle ] ]
        [ Html.summary [] [ text "Settings & Privacy Policy" ]
        , Html.div [ css [ Css.marginTop (rem 1) ] ]
            (case remoteUser of
                Loading ->
                    [ Html.p [] [ text "Connecting…" ] ]

                Got (AnonymousUser user) ->
                    [ Html.p [] [ text ("Logged in anonymously as " ++ user.id ++ ".") ]
                    , Html.button
                        [ css [ buttonStyle ]
                        , onClick LogInWithGoogleClicked
                        ]
                        [ text "Log in via Google" ]
                    ]

                Got (GoogleUser user) ->
                    let
                        settings =
                            if Remote.toMaybe user.isAdmin |> Maybe.withDefault False then
                                if isAdminActiveForUser remoteUser then
                                    [ Html.button [ css [ buttonStyle ], onClick (SetAdmin False) ] [ text "Deactivate admin" ] ]

                                else
                                    [ Html.button [ css [ buttonStyle ], onClick (SetAdmin True) ] [ text "Activate admin" ] ]

                            else
                                [ Html.p [ css [ Css.fontStyle Css.italic ] ]
                                    [ text "You do not have moderator rights, so you cannot activate the moderator tools." ]
                                , Html.p [ css [ Css.fontStyle Css.italic ] ]
                                    [ text "If you would like to become a moderator, ask someone who manages this app to add you to the list of moderators and tell them the email address you are logged in with."
                                    ]
                                ]
                    in
                    [ Html.p [] [ text ("Logged in via Google as " ++ user.email ++ ".") ]
                    ]
                        ++ settings
            )
        , Html.div [ css [ Css.marginTop (rem 2) ] ]
            [ Html.h2 [] [ Html.text "Privacy Policy" ]
            , Html.p [] [ Html.text "We use ", Html.a [ Attributes.href "https://firebase.google.com/" ] [ Html.text "Google Firebase" ], Html.text ". Specifically, we use its Authentication, Cloud Firestore and Hosting services. You can read their ", Html.a [ Attributes.href "https://firebase.google.com/terms/" ] [ Html.text "Terms of Service" ], Html.text ", their ", Html.a [ Attributes.href "https://firebase.google.com/terms/data-processing-terms" ] [ Html.text "Data Processing and Security Terms" ], Html.text ", and their support page on ", Html.a [ Attributes.href "https://firebase.google.com/support/privacy" ] [ Html.text "Privacy and Security" ], Html.text "." ]
            , Html.p []
                [ Html.text "When you open the app, we log you in using Firebase Authentication with an anonymous account to authenticate you. You can also optionally log in with a Google account so that we can give you moderator rights. This helps us ensure that only you can edit your topics and only admins can moderate the discussion."
                ]
            , Html.p [] [ Html.text "The data you send us is stored in Cloud Firestore. The app maintainers have access to it and may modify or delete it at their discretion. To request a copy, modification, or deletion of your data, please contact us at ", Html.a [ Attributes.href "mailto:uxac-lean-coffee@googlegroups.com" ] [ Html.text "uxac-lean-coffee@googlegroups.com" ], Html.text "." ]
            ]
        ]


errorView : Maybe Error -> List (Html Msg)
errorView maybeError =
    case maybeError of
        Just error ->
            [ div
                [ css
                    [ Css.border3 (px 1) Css.solid (Css.hsl 0 0.8 0.75)
                    , borderRadius
                    , listItemSpacing
                    , Css.padding (rem 1)
                    , Css.displayFlex
                    , Css.flexDirection Css.column
                    , Css.alignItems Css.flexStart
                    ]
                ]
                [ Html.details
                    [ css
                        [ Css.border3 (px 1) Css.solid (Css.hsl 0 0 0)
                        , borderRadius
                        , listItemSpacing
                        , containerPadding
                        , Css.width (pct 100)
                        , Css.boxSizing Css.borderBox
                        ]
                    ]
                    [ Html.summary [] [ text error.summary ]
                    , div [ css [ Css.fontStyle Css.italic ] ] [ text "Detailed info for experts:" ]
                    , Html.pre [ css [ Css.whiteSpace Css.normal ] ]
                        [ Html.code [] [ text <| stringFromErrorInfo error.info ]
                        ]
                    ]
                , div
                    [ css
                        [ Css.fontStyle Css.italic
                        ]
                    ]
                    [ text "Please report this error to the person who invited you here." ]
                , button
                    [ css
                        [ buttonStyle
                        ]
                    , onClick DismissError
                    ]
                    [ text "Close this message" ]
                ]
            ]

        Nothing ->
            []


discussionView :
    Remote User
    -> Maybe TopicWithVotes
    -> Maybe (List ContinuationVote)
    -> { b | now : Maybe Time.Posix, deadline : Maybe Time.Posix }
    -> String
    -> Html Msg
discussionView creds maybeDiscussedTopic continuationVotes times timerInput =
    div
        [ css
            [ borderRadius
            , Css.padding (rem 1)
            , Css.backgroundColor (Css.hsl primaryHue 1 0.5)
            , listItemSpacing
            ]
        ]
        ([ h2 [ css [ Css.margin zero ] ] [ text "In discussion" ]
         ]
            ++ (case maybeDiscussedTopic of
                    Just topic ->
                        [ topicToDiscussCard creds topic
                        ]

                    Nothing ->
                        [ card
                            [ Css.boxShadow5 Css.inset zero (rem 0.1) (rem 0.3) (Css.hsla 0 0 0 0.25)
                            , Css.backgroundColor Css.transparent
                            ]
                            []
                            [ div
                                [ css
                                    [ Css.width (pct 100)
                                    , Css.minHeight (rem 5)
                                    , Css.fontStyle Css.italic
                                    ]
                                ]
                                [ text "Currently there is no topic in discussion. Vote for one below."
                                ]
                            ]
                        ]
               )
            ++ [ remainingTime creds times timerInput ]
            ++ continuationVote creds continuationVotes
        )


remainingTime :
    Remote User
    -> { b | now : Maybe Time.Posix, deadline : Maybe Time.Posix }
    -> String
    -> Html Msg
remainingTime remoteUser times currentInput =
    case times.now of
        Nothing ->
            div [] [ text "Loading timer…" ]

        Just now ->
            let
                timeDisplay =
                    remainingTimeDisplay { now = now, deadline = times.deadline }

                maybeTimeInput =
                    if isAdminActiveForUser remoteUser then
                        [ remainingTimeInput currentInput ]

                    else
                        []
            in
            div [ css [ listItemSpacing ] ]
                (maybeTimeInput
                    ++ [ div [] [ timeDisplay ] ]
                )


remainingTimeDisplay : { a | now : Time.Posix, deadline : Maybe Time.Posix } -> Html Msg
remainingTimeDisplay times =
    div []
        [ case times.deadline of
            Nothing ->
                text "The timer has not yet started."

            Just deadline ->
                let
                    difference =
                        Time.posixToMillis deadline
                            - Time.posixToMillis times.now

                    differenceMinutes =
                        ceiling (toFloat difference / (60 * 1000))
                            -- Cap at 0 to prevent negative times.
                            |> atLeast 0

                    message =
                        if differenceMinutes == 1 then
                            "Less than 1 minute left…"

                        else if differenceMinutes == 0 then
                            "Time has run out."

                        else
                            String.fromInt differenceMinutes ++ " minutes left…"

                    blinkAnimation duration =
                        let
                            blinkInPercent =
                                1 / duration

                            fadeOutPercent =
                                (2 / 3 * blinkInPercent * 100)
                                    |> round

                            fadeInPercent =
                                (blinkInPercent * 100)
                                    |> round
                        in
                        Css.batch
                            [ Css.animationName <|
                                Animations.keyframes
                                    [ ( 0, [ Animations.opacity (num 1) ] )
                                    , ( fadeOutPercent, [ Animations.opacity (num 0) ] )
                                    , ( fadeInPercent, [ Animations.opacity (num 1) ] )
                                    ]
                            , Css.animationDuration (Css.sec duration)
                            , Css.property "animation-iteration-count" "infinite"
                            ]

                    maybeAnimation =
                        if differenceMinutes == 1 then
                            blinkAnimation 10

                        else if differenceMinutes == 0 then
                            blinkAnimation 3

                        else
                            Css.batch []
                in
                div
                    [ css
                        [ maybeAnimation
                        ]
                    ]
                    [ text message ]
        ]


atLeast : Int -> Int -> Int
atLeast minimum value =
    max minimum value


remainingTimeInput : String -> Html Msg
remainingTimeInput currentInput =
    div
        [ css
            [ Css.displayFlex
            , Css.flexDirection Css.row
            , Css.alignItems Css.center
            ]
        ]
        [ form [ onSubmit TimerStarted ]
            [ input
                [ type_ "number"
                , value currentInput
                , onInput TimerInputChanged
                , Attributes.min "0"
                , Attributes.required True
                , css [ inputStyle ]
                ]
                []
            , input
                [ type_ "submit"
                , value "Start timer"
                , css
                    [ buttonStyle
                    , Css.marginLeft (rem 1)
                    ]
                ]
                []
            ]
        , button [ css [ buttonStyle, Css.marginLeft (rem 1) ], onClick TimerCleared ]
            [ text "Clear timer"
            ]
        ]


backgroundColor : Css.Style
backgroundColor =
    Css.backgroundColor (Css.hsl primaryHue 0.2 0.95)


discussedTopics : Remote User -> List TopicWithVotes -> List (Html Msg)
discussedTopics model topics =
    case List.length topics of
        0 ->
            []

        numberOfTopics ->
            let
                pluralizedHeading =
                    case numberOfTopics of
                        1 ->
                            "1 discussed topic"

                        n ->
                            String.fromInt n ++ " dicussed topics"
            in
            [ Html.details
                [ css
                    [ detailsStyle ]
                ]
                [ Html.summary [] [ text pluralizedHeading ]
                , ol
                    [ css
                        [ listUnstyle
                        , listItemSpacing
                        , Css.marginTop (rem 1)
                        ]
                    ]
                    (List.map
                        (\topic ->
                            li []
                                [ finishedTopicCard model topic
                                ]
                        )
                        topics
                    )
                ]
            ]


detailsStyle : Css.Style
detailsStyle =
    Css.batch
        [ containerPadding
        , backgroundColor
        , borderRadius
        ]


continuationVote : Remote User -> Maybe (List ContinuationVote) -> List (Html Msg)
continuationVote remoteUser maybeContinuationVotes =
    case remoteUser of
        Loading ->
            []

        Got user ->
            let
                maybeAdminButtons =
                    if isAdminActiveForUser remoteUser then
                        case maybeContinuationVotes of
                            Nothing ->
                                [ button
                                    [ onClick StartContinuationVote
                                    , css [ buttonStyle ]
                                    ]
                                    [ text "Start vote" ]
                                ]

                            Just votes ->
                                [ button
                                    [ onClick ClearContinuationVote
                                    , css [ buttonStyle ]
                                    ]
                                    [ text "Clear vote" ]
                                , div [] [ text ("There are " ++ String.fromInt (List.length votes) ++ " votes in total.") ]
                                ]

                    else
                        []

                maybeVoteButtons =
                    case maybeContinuationVotes of
                        Nothing ->
                            []

                        Just votes ->
                            [ continuationVoteButtons user votes ]
            in
            maybeAdminButtons ++ maybeVoteButtons


continuationVoteButtons : User -> List ContinuationVote -> Html Msg
continuationVoteButtons user continuationVotes =
    let
        ( moveOnVotes, remainingVotes ) =
            List.partition (\vote -> vote.vote == MoveOn) continuationVotes

        ( stayVotes, abstainVotes ) =
            List.partition (\vote -> vote.vote == Stay) remainingVotes

        stayButton =
            voteButton user
                (List.map .userId stayVotes)
                { upvote = ContinuationVoteSent { userId = getUserId user, vote = Stay }
                , downvote = RemoveContinuationVote (getUserId user)
                }
                (\count -> text <| "Discuss more (" ++ String.fromInt count ++ ")")

        abstainButton =
            voteButton user
                (List.map .userId abstainVotes)
                { upvote = ContinuationVoteSent { userId = getUserId user, vote = Abstain }
                , downvote = RemoveContinuationVote (getUserId user)
                }
                (\count -> text <| "Neutral (" ++ String.fromInt count ++ ")")

        moveOnButton =
            voteButton user
                (List.map .userId moveOnVotes)
                { upvote = ContinuationVoteSent { userId = getUserId user, vote = MoveOn }
                , downvote = RemoveContinuationVote (getUserId user)
                }
                (\count -> text <| "Next topic (" ++ String.fromInt count ++ ")")
    in
    div
        [ css
            [ Css.displayFlex
            , Css.flexDirection Css.row
            , Css.justifyContent Css.spaceBetween
            ]
        ]
        [ stayButton, abstainButton, moveOnButton ]


topicEntry : Remote User -> String -> Html Msg
topicEntry user newTopicInput =
    div
        [ css
            [ containerPadding
            , borderRadius
            , backgroundColor
            ]
        ]
        [ submitForm user newTopicInput ]


topicsToVote : Remote User -> Remote (List TopicWithVotes) -> Html Msg -> Html Msg
topicsToVote creds remoteTopics toolbar =
    div
        [ css
            [ backgroundColor
            , containerPadding
            , borderRadius
            ]
        ]
        [ div
            [ css
                [ Css.displayFlex
                , Css.flexDirection Css.row
                , Css.flexWrap Css.wrap
                , Css.alignItems Css.center
                , Css.marginBottom (rem 1)
                ]
            ]
            [ h2
                [ css
                    [ Css.margin zero
                    , Css.marginRight (rem 1)
                    ]
                ]
                [ let
                    unreadCount =
                        Remote.toMaybe remoteTopics
                            |> Maybe.map
                                (List.filter (\( _, entry ) -> entry.mark == Unread)
                                    >> List.length
                                )
                            |> Maybe.withDefault 0

                    unread =
                        if unreadCount > 0 then
                            " (" ++ String.fromInt unreadCount ++ " unread)"

                        else
                            ""
                  in
                  text ("Suggested topics" ++ unread)
                ]
            , toolbar
            ]
        , case remoteTopics of
            Loading ->
                text "Loading topics…"

            Got topics ->
                case List.length topics of
                    0 ->
                        span
                            [ css
                                [ Css.fontStyle Css.italic
                                ]
                            ]
                            [ text "No topics suggested yet. Add a topic above." ]

                    _ ->
                        topicsToVoteList creds topics toolbar
        ]


topicsToVoteList : Remote User -> List TopicWithVotes -> Html Msg -> Html Msg
topicsToVoteList creds topics toolbar =
    let
        breakpoint =
            rem 40
    in
    ol
        [ css
            [ listUnstyle
            , Css.displayFlex
            , Css.flexDirection Css.column
            , Media.withMedia [ Media.all [ Media.maxWidth breakpoint ] ]
                [ listItemSpacing
                ]
            , Media.withMedia [ Media.all [ Media.minWidth breakpoint ] ]
                [ Css.property
                    "display"
                    "grid"

                -- TODO: Consider allowing smaller widths on narrow devices via media queries.
                , Css.property "grid-template-columns" "repeat(auto-fill, minmax(20rem, 1fr))"
                , Css.property "row-gap" "2rem"
                , Css.property "column-gap" "1rem"
                ]
            ]
        ]
        (List.map
            (\topic ->
                li
                    []
                    [ topicToVoteCard creds topic ]
            )
            topics
        )


listUnstyle : Css.Style
listUnstyle =
    Css.batch
        [ Css.padding zero
        , Css.margin zero
        , Css.listStyle Css.none
        ]


listItemSpacing : Css.Style
listItemSpacing =
    Global.children
        [ Global.everything
            [ Global.adjacentSiblings
                [ Global.everything
                    [ Css.marginTop (rem 1)
                    ]
                ]
            ]
        ]


borderRadius : Css.Style
borderRadius =
    Css.borderRadius (rem 0.5)


containerPadding : Css.Style
containerPadding =
    Css.padding2 (rem 1) (rem 1)


bodyFont : Css.Style
bodyFont =
    Css.fontFamilies [ "Verdana", .value Css.sansSerif ]


stringFromErrorInfo : ErrorInfo -> String
stringFromErrorInfo info =
    case info of
        FirestoreError { code, errorMessage } ->
            errorMessage ++ " (code " ++ code ++ ")"

        ParsingError decodeError ->
            Decode.errorToString decodeError


sortBarView : Remote Votes -> Remote TopicList -> Html Msg
sortBarView votes remoteTopics =
    let
        voteCountMap =
            voteCountMapFromVotes votes

        showButton =
            case remoteTopics of
                Got topics ->
                    if not (isTopicListSorted voteCountMap topics) then
                        True

                    else
                        False

                _ ->
                    False

        visibility =
            if showButton then
                Css.visibility Css.visible

            else
                Css.visibility Css.hidden
    in
    div
        [ css
            [ visibility
            ]
        ]
        [ sortBar ]


sortBar : Html Msg
sortBar =
    sortButton


sortButton : Html Msg
sortButton =
    button [ css [ buttonStyle ], onClick SortTopics ] [ text "Sort" ]


topicToDiscussCard : Remote User -> TopicWithVotes -> Html Msg
topicToDiscussCard remoteUser ( topicId, entry ) =
    let
        voteCount =
            List.length entry.votes

        mayMod =
            mayModify remoteUser entry.topic.creator

        maybeVoteAgainButton =
            if isAdminActiveForUser remoteUser then
                [ button
                    [ css [ buttonStyle ]
                    , onClick VoteAgainClicked
                    ]
                    [ text "Vote again" ]
                ]

            else
                []

        maybeFinishButton =
            if isAdminActiveForUser remoteUser then
                [ button
                    [ css [ buttonStyle ]
                    , onClick FinishDiscussionClicked
                    ]
                    [ text "Finish" ]
                ]

            else
                []

        maybeDeleteButton =
            if isAdminActiveForUser remoteUser then
                [ deleteButton topicId
                ]

            else
                []
    in
    topicCard
        []
        []
        { content = text entry.topic.topic
        , toolbar =
            [ votesIndicator voteCount ]
                ++ maybeFinishButton
                ++ maybeVoteAgainButton
                ++ maybeDeleteButton
        }


topicToVoteCard : Remote User -> TopicWithVotes -> Html Msg
topicToVoteCard remoteUser ( topicId, entry ) =
    let
        maybeDiscussButton =
            if isAdminActiveForUser remoteUser then
                [ button [ onClick (Discuss topicId), css [ buttonStyle ] ] [ text "Discuss" ] ]

            else
                []

        mayMod =
            mayModify remoteUser entry.topic.creator

        content =
            case entry.beingEdited of
                Just edit ->
                    form
                        [ css
                            [ Css.displayFlex
                            , Css.justifyContent Css.spaceBetween
                            , Css.alignItems Css.start
                            ]
                        , onSubmit (SaveTopicClicked topicId)
                        ]
                        [ textarea
                            [ Attributes.id topicId
                            , value edit
                            , onInput (TopicEdited topicId)
                            , Attributes.autofocus True
                            , css
                                [ inputStyle
                                , bodyFont
                                , Css.width (pct 100)
                                , Css.lineHeight (rem 1)
                                ]
                            ]
                            []
                        , div [ css [ Css.marginLeft (rem 1) ] ] [ saveButton topicId ]
                        ]

                Nothing ->
                    let
                        maybeEditButton =
                            if mayMod then
                                [ editButton topicId ]

                            else
                                []
                    in
                    div
                        [ css
                            [ Css.displayFlex
                            , Css.justifyContent Css.spaceBetween
                            , Css.alignItems Css.start
                            ]
                        ]
                        ([ text entry.topic.topic ] ++ maybeEditButton)

        maybeDeleteButton =
            if mayMod then
                [ deleteButton topicId ]

            else
                []

        styles =
            case entry.mark of
                Unread ->
                    let
                        borderWidth =
                            0.25
                    in
                    [ Css.border3 (rem borderWidth) Css.solid (Css.hsl primaryHue 1 0.6)
                    , Css.margin (rem -borderWidth)
                    ]

                _ ->
                    []

        attributes =
            case entry.mark of
                Unread ->
                    [ onMouseEnter (Read topicId), on "touchstart" (Decode.succeed <| Read topicId) ]

                _ ->
                    []
    in
    topicCard
        styles
        attributes
        { content = content
        , toolbar =
            maybeTopicVoteButton remoteUser ( topicId, entry )
                ++ maybeDiscussButton
                ++ maybeDeleteButton
        }


finishedTopicCard : Remote User -> TopicWithVotes -> Html Msg
finishedTopicCard creds ( topicId, entry ) =
    let
        voteCount =
            List.length entry.votes

        mayMod =
            mayModify creds entry.topic.creator

        maybeDeleteButton =
            if mayMod then
                [ deleteButton topicId ]

            else
                []
    in
    topicCard
        []
        []
        { content = text entry.topic.topic
        , toolbar =
            [ votesIndicator voteCount ]
                ++ maybeDeleteButton
        }


maybeTopicVoteButton : Remote User -> TopicWithVotes -> List (Html Msg)
maybeTopicVoteButton remoteUser ( topicId, entry ) =
    case remoteUser of
        Loading ->
            []

        Got user ->
            let
                upvoteMsg =
                    Upvote user topicId

                downvoteMsg =
                    RemoveUpvote user topicId
            in
            [ voteButton user
                entry.votes
                { upvote = upvoteMsg, downvote = downvoteMsg }
                votesText
            ]


voteButton : User -> List UserId -> { upvote : Msg, downvote : Msg } -> (Int -> Html Msg) -> Html Msg
voteButton user votes msgs content =
    let
        voteCount =
            List.length votes

        userAlreadyVoted =
            List.any (\userId -> userId == getUserId user) votes

        state =
            if userAlreadyVoted then
                { action = msgs.downvote
                , color = Css.hsl primaryHue 1 0.72
                , border = Css.borderWidth (px 2)
                , margin = px 0
                }

            else
                { action = msgs.upvote
                , color = Css.hsl 0 0 1
                , border = Css.batch []
                , margin = px 1
                }
    in
    button
        [ onClick state.action
        , css
            [ buttonStyle
            , Css.backgroundColor state.color
            , state.border
            , Css.margin state.margin
            ]
        ]
        [ content voteCount ]


votesIndicator : Int -> Html Msg
votesIndicator count =
    div [ css [ smallBorderRadius, backgroundColor, buttonPadding ] ]
        [ votesText count
        ]


votesText : Int -> Html Msg
votesText count =
    text
        ("👍 " ++ String.fromInt count)


saveButton : TopicId -> Html Msg
saveButton topicId =
    button
        [ onClick (SaveTopicClicked topicId)
        , css [ buttonStyle ]
        ]
        [ text "Save" ]


editButton : TopicId -> Html Msg
editButton topicId =
    button
        [ onClick (EditTopicClicked topicId)
        , css [ buttonStyle ]
        ]
        [ text "Edit" ]


deleteButton : TopicId -> Html Msg
deleteButton topicId =
    button
        [ onClick (DeleteTopic topicId)
        , css [ buttonStyle ]
        ]
        [ text "Delete" ]


mayModify : Remote User -> UserId -> Bool
mayModify remoteUser creator =
    if isAdminActiveForUser remoteUser then
        True

    else
        case remoteUser of
            Loading ->
                False

            Got user ->
                getUserId user == creator


topicCard : List Css.Style -> List (Attribute Msg) -> { content : Html Msg, toolbar : List (Html Msg) } -> Html Msg
topicCard styles attributes { content, toolbar } =
    card
        styles
        attributes
        [ div
            [ css
                [ Css.displayFlex
                , Css.flexDirection Css.column
                ]
            ]
            [ content
            , div
                [ css
                    [ Css.marginTop (rem 1)
                    , Css.displayFlex
                    , Css.flexDirection Css.row
                    , Css.flexWrap Css.wrap
                    , Css.justifyContent Css.spaceBetween
                    ]
                ]
                toolbar
            ]
        ]


submitForm : Remote User -> String -> Html Msg
submitForm fetchedUser currentInput =
    case fetchedUser of
        Loading ->
            text "Connecting…"

        Got user ->
            newTopicForm user currentInput


newTopicForm : User -> String -> Html Msg
newTopicForm user currentInput =
    form
        [ css [ Css.displayFlex, Css.flexDirection Css.column, Css.alignItems Css.flexStart ]
        , onSubmit (SaveTopic user)
        ]
        [ label [ css [ Css.displayFlex, Css.flexDirection Css.column, Css.width (pct 100) ] ]
            [ text "Add a topic"
            , input
                [ value currentInput
                , onInput NewTopicInputChanged
                , css
                    [ inputStyle
                    , Css.marginTop (rem 0.3)
                    ]
                ]
                []
            ]
        , input [ type_ "submit", value "Submit", css [ buttonStyle, Css.marginTop (rem 1) ] ] []
        ]


inputStyle : Css.Style
inputStyle =
    Css.batch
        [ Css.padding2 (rem 0.5) (rem 0.5)
        , smallBorderRadius
        , Css.border3 (px 1) Css.solid (Css.hsl 0 0 0)
        , Css.boxShadow5 Css.inset (rem 0.1) (rem 0.1) (rem 0.1) (Css.hsla 0 0 0 0.15)
        ]


smallBorderRadius : Css.Style
smallBorderRadius =
    Css.borderRadius (rem 0.3)


card : List Css.Style -> List (Attribute Msg) -> List (Html Msg) -> Html Msg
card styles attributes content =
    div
        ([ css
            ([ Css.padding (rem 1)
             , borderRadius
             , Css.boxShadow4 zero (rem 0.1) (rem 0.3) (Css.hsla 0 0 0 0.25)
             , Css.backgroundColor (Css.hsl 0 0 1)
             ]
                ++ styles
            )
         ]
            ++ attributes
        )
        content


buttonStyle : Css.Style
buttonStyle =
    Css.batch
        [ buttonPadding
        , Css.border3 (px 1) Css.solid (Css.hsl 0 0 0)
        , smallBorderRadius
        , Css.backgroundColor (Css.hsl 0 0 1)
        , Css.boxShadow4 (rem 0.1) (rem 0.1) (rem 0.1) (Css.hsla 0 0 0 0.15)
        , Css.hover
            [ Css.property "filter" "brightness(90%)"
            ]
        ]


buttonPadding : Css.Style
buttonPadding =
    Css.padding2 (rem 0.3) (rem 0.5)


primaryHue : Float
primaryHue =
    52



--- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ receiveFirestoreSubscriptions
        , receiveUser_ (Decode.decodeValue userDecoder >> UserReceived)
        , receiveIsAdmin_ IsAdminReceived
        , receiveError_ (Decode.decodeValue firestoreErrorDecoder >> ErrorReceived)
        , Time.every 1000 Tick
        ]



--- PORTS


topicCollectionPath : Maybe String -> Path
topicCollectionPath workspace =
    [ "topics" ]
        |> prependWorkspace workspace


voteCollectionPath : Maybe String -> Path
voteCollectionPath workspace =
    [ "votes" ]
        |> prependWorkspace workspace


inDiscussionDocPath : Maybe String -> Path
inDiscussionDocPath workspace =
    [ "discussion", "topic" ]
        |> prependWorkspace workspace


discussionDeadlineDocPath : Maybe String -> Path
discussionDeadlineDocPath workspace =
    [ "discussion", "deadline" ]
        |> prependWorkspace workspace


continuationVoteActiveDocPath : Maybe String -> Path
continuationVoteActiveDocPath workspace =
    [ "discussion", "continuationVote" ]
        |> prependWorkspace workspace


continuationVoteCollectionPath : Maybe String -> Path
continuationVoteCollectionPath workspace =
    [ "continuationVotes" ]
        |> prependWorkspace workspace


discussedCollectionPath : Maybe String -> Path
discussedCollectionPath workspace =
    [ "discussed" ]
        |> prependWorkspace workspace


prependWorkspace : Maybe String -> Path -> Path
prependWorkspace maybeWorkspace path =
    case maybeWorkspace of
        Nothing ->
            path

        Just workspace ->
            [ "workspaces", workspace ] ++ path


firestoreSubscriptionsCmd : Maybe String -> Cmd Msg
firestoreSubscriptionsCmd workspace =
    Cmd.batch
        [ subscribe { kind = CollectionChanges, path = topicCollectionPath workspace, tag = TopicChangesTag }
        , subscribe { kind = Collection, path = voteCollectionPath workspace, tag = VotesTag }
        , subscribe { kind = Doc, path = inDiscussionDocPath workspace, tag = InDiscussionTag }
        , subscribe { kind = Doc, path = continuationVoteActiveDocPath workspace, tag = ContinuationVoteActiveTag }
        , subscribe { kind = Collection, path = continuationVoteCollectionPath workspace, tag = ContinuationVotesTag }
        , subscribe { kind = Collection, path = discussedCollectionPath workspace, tag = DiscussedTag }
        , subscribe { kind = Doc, path = discussionDeadlineDocPath workspace, tag = DeadlineTag }
        ]


subscribe : SubscriptionInfo -> Cmd msg
subscribe info =
    encodeSubscriptionInfo info
        |> subscribe_


port subscribe_ : Encode.Value -> Cmd msg


type alias SubscriptionInfo =
    { kind : SubscriptionKind
    , path : Path
    , tag : SubscriptionTag
    }


encodeSubscriptionInfo : SubscriptionInfo -> Encode.Value
encodeSubscriptionInfo info =
    Encode.object
        [ ( "kind", encodeSubscriptionKind info.kind )
        , ( "path", encodePath info.path )
        , ( "tag", encodeSubscriptionTag info.tag )
        ]


type SubscriptionKind
    = Collection
    | CollectionChanges
    | Doc


encodeSubscriptionKind : SubscriptionKind -> Encode.Value
encodeSubscriptionKind kind =
    let
        raw =
            case kind of
                Collection ->
                    "collection"

                CollectionChanges ->
                    "collectionChanges"

                Doc ->
                    "doc"
    in
    Encode.string raw


subscriptionKindDecoder : Decoder SubscriptionKind
subscriptionKindDecoder =
    Decode.string
        |> Decode.andThen
            (\raw ->
                case raw of
                    "collection" ->
                        Decode.succeed Collection

                    "collectionChanges" ->
                        Decode.succeed CollectionChanges

                    "doc" ->
                        Decode.succeed Doc

                    _ ->
                        Decode.fail "Invalid subscription kind"
            )


type alias Path =
    List String


encodePath : Path -> Encode.Value
encodePath path =
    String.join "/" path
        |> Encode.string


type SubscriptionTag
    = TopicChangesTag
    | VotesTag
    | InDiscussionTag
    | ContinuationVoteActiveTag
    | ContinuationVotesTag
    | DiscussedTag
    | DeadlineTag


encodeSubscriptionTag : SubscriptionTag -> Encode.Value
encodeSubscriptionTag tag =
    let
        raw =
            case tag of
                TopicChangesTag ->
                    "topicChanges"

                VotesTag ->
                    "votes"

                InDiscussionTag ->
                    "inDiscussion"

                ContinuationVoteActiveTag ->
                    "continuationVoteActive"

                ContinuationVotesTag ->
                    "continuationVotes"

                DiscussedTag ->
                    "discussed"

                DeadlineTag ->
                    "deadline"
    in
    Encode.string raw


subscriptionTagDecoder : Decoder SubscriptionTag
subscriptionTagDecoder =
    Decode.string
        |> Decode.andThen
            (\raw ->
                case raw of
                    "topicChanges" ->
                        Decode.succeed TopicChangesTag

                    "votes" ->
                        Decode.succeed VotesTag

                    "inDiscussion" ->
                        Decode.succeed InDiscussionTag

                    "continuationVoteActive" ->
                        Decode.succeed ContinuationVoteActiveTag

                    "continuationVotes" ->
                        Decode.succeed ContinuationVotesTag

                    "discussed" ->
                        Decode.succeed DiscussedTag

                    "deadline" ->
                        Decode.succeed DeadlineTag

                    _ ->
                        Decode.fail "Invalid subscription kind"
            )


receiveFirestoreSubscriptions : Sub Msg
receiveFirestoreSubscriptions =
    receive_ parseFirestoreSubscription


port receive_ : (Encode.Value -> msg) -> Sub msg


parseFirestoreSubscription : Encode.Value -> Msg
parseFirestoreSubscription value =
    let
        decoded =
            Decode.decodeValue
                (Decode.field "tag" subscriptionTagDecoder
                    |> Decode.andThen
                        (\tag ->
                            let
                                dataDecoder : Decoder Msg
                                dataDecoder =
                                    case tag of
                                        TopicChangesTag ->
                                            topicChangesDecoder
                                                |> Decode.map TopicChangesReceived

                                        VotesTag ->
                                            votesDecoder
                                                |> Decode.map VotesReceived

                                        InDiscussionTag ->
                                            inDiscussionDecoder
                                                |> Decode.map TopicInDiscussionReceived

                                        ContinuationVoteActiveTag ->
                                            continuationVoteActiveDecoder
                                                |> Decode.map ContinuationVoteActiveReceived

                                        ContinuationVotesTag ->
                                            continuationVotesDecoder
                                                |> Decode.map ContinuationVotesReceived

                                        DiscussedTag ->
                                            discussedDecoder
                                                |> Decode.map DiscussedTopicsReceived

                                        DeadlineTag ->
                                            deadlineDecoder
                                                |> Decode.map DeadlineReceived
                            in
                            Decode.field "data" dataDecoder
                        )
                )
                value
    in
    case decoded of
        Ok msg ->
            msg

        Err error ->
            DecodeError error


changeDecoder : (ChangeType -> String -> value -> a) -> Decoder value -> Decoder (List a)
changeDecoder mapping valueDecoder =
    Decode.list <|
        Decode.map3 mapping
            (Decode.field "changeType" changeTypeDecoder)
            (Decode.field "id" Decode.string)
            valueDecoder


type ChangeType
    = Added
    | Modified
    | Removed


changeTypeDecoder : Decoder ChangeType
changeTypeDecoder =
    Decode.string
        |> Decode.andThen
            (\raw ->
                case raw of
                    "added" ->
                        Decode.succeed Added

                    "modified" ->
                        Decode.succeed Modified

                    "removed" ->
                        Decode.succeed Removed

                    _ ->
                        Decode.fail "Invalid change type"
            )


type alias InsertDocInfo =
    { collectionPath : Path, doc : Encode.Value }


insertDoc : InsertDocInfo -> Cmd msg
insertDoc info =
    Encode.object
        [ ( "path", encodePath info.collectionPath )
        , ( "doc", info.doc )
        ]
        |> insertDoc_


port insertDoc_ : Encode.Value -> Cmd msg


type alias SetDocInfo =
    { docPath : Path, doc : Encode.Value }


setDoc : SetDocInfo -> Cmd msg
setDoc info =
    Encode.object
        [ ( "path", encodePath info.docPath )
        , ( "doc", info.doc )
        ]
        |> setDoc_


port setDoc_ : Encode.Value -> Cmd msg


deleteDocs : List Path -> Cmd msg
deleteDocs paths =
    Encode.object
        [ ( "paths", Encode.list encodePath paths )
        ]
        |> deleteDocs_


port deleteDocs_ : Encode.Value -> Cmd msg


port receiveUser_ : (Encode.Value -> msg) -> Sub msg


port receiveIsAdmin_ : (Bool -> msg) -> Sub msg


port receiveError_ : (Encode.Value -> msg) -> Sub msg


port selectTextarea_ : String -> Cmd msg


port logInWithGoogle_ : () -> Cmd msg



-- DECODERS


topicChangesDecoder : Decoder TopicChanges
topicChangesDecoder =
    changeDecoder
        (\changeType id topic ->
            ( changeType
            , id
            , topic
            )
        )
        topicDecoder
        |> Decode.map
            (List.foldl
                (\( changeType, id, topic ) changes ->
                    case changeType of
                        Added ->
                            { changes | added = changes.added ++ [ ( id, topic ) ] }

                        Modified ->
                            { changes | modified = changes.modified ++ [ ( id, topic ) ] }

                        Removed ->
                            { changes | removed = changes.removed ++ [ id ] }
                )
                emptyChanges
            )


type alias TopicChanges =
    { added : List ( TopicId, Topic )
    , modified : List ( TopicId, Topic )
    , removed : List TopicId
    }


emptyChanges : TopicChanges
emptyChanges =
    { added = [], modified = [], removed = [] }


topicDecoder : Decoder Topic
topicDecoder =
    Decode.map3
        (\topic userId createdAt ->
            { topic = topic
            , creator = userId
            , createdAt = createdAt
            }
        )
        (dataField "topic" Decode.string)
        (dataField "userId" Decode.string)
        (dataField "createdAt" (Decode.nullable timestampDecoder))


dataField : String -> Decoder a -> Decoder a
dataField field decoder =
    Decode.field "data" (Decode.field field decoder)


userDecoder : Decoder User
userDecoder =
    Decode.field "provider" Decode.string
        |> Decode.andThen
            (\provider ->
                case provider of
                    "anonymous" ->
                        Decode.field "id" Decode.string
                            |> Decode.map (\id -> AnonymousUser { id = id })

                    "google.com" ->
                        Decode.map2
                            (\id email ->
                                GoogleUser
                                    { id = id
                                    , email = email
                                    , isAdmin = Loading
                                    , adminActive = False
                                    }
                            )
                            (Decode.field "id" Decode.string)
                            (Decode.field "email" Decode.string)

                    _ ->
                        Decode.fail ("Unkown provider `" ++ provider ++ "`.")
            )


timestampEncoder : Time.Posix -> Encode.Value
timestampEncoder time =
    let
        milliseconds =
            Time.posixToMillis time

        seconds =
            toFloat milliseconds
                / 1000
                |> round

        nanoseconds =
            milliseconds * 1000000
    in
    Encode.object
        [ ( "seconds", Encode.int seconds )
        , ( "nanoseconds", Encode.int nanoseconds )
        ]


timestampDecoder : Decoder Time.Posix
timestampDecoder =
    Decode.map2
        (\seconds nanoseconds ->
            let
                {- The nanoseconds count the fractions of seconds.
                   See https://firebase.google.com/docs/reference/js/firebase.firestore.Timestamp.
                -}
                milliseconds =
                    (toFloat seconds * 1000)
                        + (toFloat nanoseconds / 1000000)
            in
            Time.millisToPosix (round milliseconds)
        )
        (Decode.field "seconds" Decode.int)
        (Decode.field "nanoseconds" Decode.int)


votesDecoder : Decoder Votes
votesDecoder =
    Decode.list
        (Decode.map2
            (\topicId userId ->
                ( topicId, userId )
            )
            (dataField "topicId" Decode.string)
            (dataField "userId" Decode.string)
        )
        |> Decode.map
            (List.foldl
                (\( topicId, userId ) dict ->
                    Dict.update topicId
                        (\maybeUsers ->
                            case maybeUsers of
                                Nothing ->
                                    Just [ userId ]

                                Just users ->
                                    Just (userId :: users)
                        )
                        dict
                )
                Dict.empty
            )


inDiscussionDecoder : Decoder (Maybe TopicId)
inDiscussionDecoder =
    Decode.maybe (Decode.field "topicId" Decode.string)


continuationVoteActiveDecoder : Decoder Bool
continuationVoteActiveDecoder =
    Decode.maybe (Decode.field "isActive" Decode.bool)
        |> Decode.map
            (\maybeIsActive ->
                let
                    isActive =
                        maybeIsActive |> Maybe.withDefault False
                in
                isActive
            )


encodeContinuationVoteActive : Bool -> Encode.Value
encodeContinuationVoteActive isActive =
    Encode.object [ ( "isActive", Encode.bool isActive ) ]


continuationVotesDecoder : Decoder (List ContinuationVote)
continuationVotesDecoder =
    Decode.list
        (Decode.map2
            (\userId vote ->
                { userId = userId
                , vote = vote
                }
            )
            (dataField "userId" Decode.string)
            (dataField "vote" continuationDecoder)
        )


discussedDecoder : Decoder (List ( TopicId, Maybe Time.Posix ))
discussedDecoder =
    Decode.list
        (Decode.map2 Tuple.pair
            (dataField "topicId" Decode.string)
            (dataField "finishedAt" (Decode.maybe timestampDecoder))
        )


deadlineDecoder : Decoder (Maybe Time.Posix)
deadlineDecoder =
    Decode.maybe
        (Decode.field "time" Decode.int
            |> Decode.map
                (\raw ->
                    Time.millisToPosix raw
                )
        )


encodeDeadline : Time.Posix -> Encode.Value
encodeDeadline deadline =
    Encode.object [ ( "time", Time.posixToMillis deadline |> Encode.int ) ]


firestoreErrorDecoder : Decoder FirestoreErrorInfo
firestoreErrorDecoder =
    Decode.map2
        (\code errorMessage ->
            { code = code, errorMessage = errorMessage }
        )
        (Decode.field "code" Decode.string)
        (Decode.field "message" Decode.string)


type alias NewTopicSubmission =
    { topic : String, userId : String, createdAt : TimestampField }


newTopicEncoder : NewTopicSubmission -> Encode.Value
newTopicEncoder { topic, userId, createdAt } =
    Encode.object
        [ ( "topic", Encode.string topic )
        , ( "userId", Encode.string userId )
        , ( "createdAt", createdAt )
        ]


topicEncoder : Topic -> Encode.Value
topicEncoder topic =
    Encode.object
        [ ( "topic", Encode.string topic.topic )
        , ( "userId", Encode.string topic.creator )
        , ( "createdAt", maybeEncoder timestampEncoder topic.createdAt )
        ]


maybeEncoder : (a -> Encode.Value) -> Maybe a -> Encode.Value
maybeEncoder encoder maybe =
    case maybe of
        Just a ->
            encoder a

        Nothing ->
            Encode.null


topicVoteEncoder : Vote -> Encode.Value
topicVoteEncoder vote =
    Encode.object
        [ ( "userId", Encode.string vote.userId )
        , ( "topicId", Encode.string vote.topicId )
        ]


topicIdEncoder : TopicId -> Encode.Value
topicIdEncoder topicId =
    Encode.object
        [ ( "topicId", Encode.string topicId )
        ]


discussedTopicEncoder : TopicId -> TimestampField -> Encode.Value
discussedTopicEncoder id timestamp =
    Encode.object
        [ ( "topicId", Encode.string id )
        , ( "finishedAt", timestamp )
        ]


continuationVoteEncoder : ContinuationVote -> Encode.Value
continuationVoteEncoder vote =
    Encode.object
        [ ( "userId", Encode.string vote.userId )
        , ( "vote", encodeContinuation vote.vote )
        ]


encodeContinuation : Continuation -> Encode.Value
encodeContinuation continuation =
    let
        string =
            case continuation of
                MoveOn ->
                    "moveOn"

                Stay ->
                    "stay"

                Abstain ->
                    "abstain"
    in
    Encode.string string


continuationDecoder : Decoder Continuation
continuationDecoder =
    Decode.string
        |> Decode.andThen
            (\raw ->
                case raw of
                    "moveOn" ->
                        Decode.succeed MoveOn

                    "stay" ->
                        Decode.succeed Stay

                    "abstain" ->
                        Decode.succeed Abstain

                    _ ->
                        Decode.fail "Invalid continuation vote"
            )
