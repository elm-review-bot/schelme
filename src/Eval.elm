module Eval exposing (BuiltIn, Function, NameSpace, Term(..), compile, eval, evalFtn, evalTerms, parseNumber, parseString, parseSymbol, run, showTerm, sxpToTerm, sxpsToTerms, termString)

import Dict exposing (Dict)
import ParseHelp exposing (listOf)
import Parser as P
    exposing
        ( (|.)
        , (|=)
        , DeadEnd
        , Parser
        , Problem
        , Step(..)
        , andThen
        , chompIf
        , chompWhile
        , end
        , float
        , getChompedString
        , keyword
        , lazy
        , loop
        , map
        , oneOf
        , run
        , sequence
        , succeed
        , symbol
        )
import SExpression exposing (Sxp(..))
import Util exposing (first, rest)


type alias Function a =
    { args : List String, body : List (Term a) }


type Term a
    = TString String
    | TNumber Float
    | TList (List (Term a))
    | TSymbol String
    | TFunction (Function a)
    | TBuiltIn (BuiltIn a)
    | TSideEffector (SideEffector a)


type alias NameSpace a =
    Dict String (Term a)


type alias BuiltIn a =
    List (Term a) -> ( NameSpace a, a ) -> Result String ( NameSpace a, Term a )


type alias SideEffector a =
    List (Term a) -> ( NameSpace a, a ) -> Result String ( ( NameSpace a, a ), Term a )


compile : String -> Result String (List (Term a))
compile text =
    Result.mapError Util.deadEndsToString
        (P.run SExpression.sSxps text
            |> Result.andThen sxpsToTerms
        )


run : List (Term a) -> ( NameSpace a, a ) -> Result String ( ( NameSpace a, a ), Term a )
run terms ns =
    List.foldl
        (\term rns ->
            rns
                |> Result.andThen
                    (\( ns2, _ ) ->
                        eval term ns2
                    )
        )
        (Ok ( ns, TList [] ))
        terms


showTerm : Term a -> String
showTerm term =
    case term of
        TString str ->
            "string: " ++ str

        TNumber n ->
            "number: " ++ String.fromFloat n

        TList terms ->
            "list: " ++ String.concat (List.intersperse ", " (List.map showTerm terms))

        TSymbol str ->
            "symbol: " ++ str

        TFunction fn ->
            "function: " ++ String.concat (List.intersperse ", " fn.args)

        TBuiltIn bi ->
            "builtin"

        TSideEffector se ->
            "sideeffector"


evalFtn : Function a -> List (Term a) -> ( NameSpace a, a ) -> Result String ( ( NameSpace a, a ), Term a )
evalFtn fn argterms ns =
    evalTerms argterms ns
        |> Result.andThen
            (\terms ->
                case Util.mbPList fn.args terms of
                    Nothing ->
                        Err "number of args and terms don't match!"

                    Just pl ->
                        let
                            fnns =
                                List.foldr
                                    (\( s, t ) ( foldns, aval ) ->
                                        ( Dict.insert s t foldns, aval )
                                    )
                                    ns
                                    pl
                        in
                        List.foldl
                            (\t rbns ->
                                Result.andThen (\( rns, _ ) -> eval t rns) rbns
                            )
                            (Ok ( fnns, TList [] ))
                            fn.body
            )


{-| eval terms, throwing away any changes they make to the namespace (and to 'a')
-}
evalTerms : List (Term a) -> ( NameSpace a, a ) -> Result String (List (Term a))
evalTerms terms ns =
    List.foldr
        (\rset rstms ->
            rstms
                |> Result.andThen
                    (\tms ->
                        rset |> Result.andThen (\( etns, ettm ) -> Ok (ettm :: tms))
                    )
        )
        (Ok [])
        (List.map (\tm -> eval tm ns) terms)


eval : Term a -> ( NameSpace a, a ) -> Result String ( ( NameSpace a, a ), Term a )
eval term ns =
    case term of
        TString str ->
            Ok ( ns, TString str )

        TNumber n ->
            Ok ( ns, TNumber n )

        TList terms ->
            case List.head terms of
                Nothing ->
                    Ok ( ns, TList terms )

                Just t ->
                    case eval t ns of
                        Ok ( nns, et ) ->
                            case et of
                                TFunction fn ->
                                    evalFtn fn (Util.rest terms) nns
                                        |> Result.andThen
                                            (\( fns, fterm ) ->
                                                -- throw away the final function namespace
                                                Ok ( nns, fterm )
                                            )

                                TBuiltIn bif ->
                                    let
                                        ( bns, ba ) =
                                            ns
                                    in
                                    bif (Util.rest terms) ns
                                        |> Result.map (\( bins, bitm ) -> ( ( bins, ba ), bitm ))

                                TSideEffector se ->
                                    se (Util.rest terms) ns

                                other ->
                                    Ok ( ns, other )

                        Err e ->
                            Err e

        TSymbol s ->
            case Dict.get s (Tuple.first ns) of
                Just t ->
                    Ok ( ns, t )

                Nothing ->
                    Err <| "symbol not found: " ++ s

        TFunction f ->
            Ok ( ns, TFunction f )

        TBuiltIn b ->
            Ok ( ns, TBuiltIn b )

        TSideEffector se ->
            Ok ( ns, TSideEffector se )


sxpToTerm : Sxp -> Result (List DeadEnd) (Term a)
sxpToTerm sxp =
    case sxp of
        STerm str ->
            P.run termString str

        SList sterms ->
            Result.map TList
                (List.foldr
                    (\ts rslt ->
                        case rslt of
                            Ok lst ->
                                case sxpToTerm ts of
                                    Ok term ->
                                        Ok <| term :: lst

                                    Err e ->
                                        Err e

                            Err e ->
                                Err e
                    )
                    (Ok [])
                    sterms
                )


sxpsToTerms : List Sxp -> Result (List DeadEnd) (List (Term a))
sxpsToTerms sxps =
    List.foldr
        (\sxp rs ->
            Result.andThen
                (\terms ->
                    sxpToTerm sxp
                        |> Result.andThen (\t -> Ok (t :: terms))
                )
                rs
        )
        (Ok [])
        sxps


termString : Parser (Term a)
termString =
    oneOf
        [ parseString
        , parseNumber
        , parseSymbol
        ]


{-| parse a quoted string, without any provision for escaped quotes
-}
parseString : Parser (Term a)
parseString =
    succeed TString
        |. symbol "\""
        |= getChompedString
            (chompWhile (\c -> c /= '"'))
        |. symbol "\""
        |. end


parseSymbol : Parser (Term a)
parseSymbol =
    succeed TSymbol
        |= getChompedString
            (chompWhile (\c -> c /= '"'))
        |. end


parseNumber : Parser (Term a)
parseNumber =
    succeed TNumber
        |= float
        |. end
