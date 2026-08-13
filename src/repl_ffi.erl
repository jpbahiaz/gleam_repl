-module(repl_ffi).
-export([get_line/1, load_binary/3, safe_apply/3, tuple_element/2, format_exception/1]).

get_line(Prompt) when is_binary(Prompt) ->
    get_line(unicode:characters_to_list(Prompt));
get_line(Prompt) ->
    case io:get_line(Prompt) of
        eof ->
            eof;
        {error, _} ->
            eof;
        Line ->
            {read, unicode:characters_to_binary(Line)}
    end.

load_binary(Module, Filename, Binary) when is_binary(Filename) ->
    load_binary(Module, unicode:characters_to_list(Filename), Binary);
load_binary(Module, Filename, Binary) ->
    case code:load_binary(Module, Filename, Binary) of
        {module, _} ->
            {ok, nil};
        {error, Reason} ->
            {error, Reason}
    end.

safe_apply(Module, Function, Args) ->
    try
        {ok, erlang:apply(Module, Function, Args)}
    catch
        Class:Reason:Stack ->
            {error, {Class, Reason, Stack}}
    end.

tuple_element(Tuple, Index) when is_tuple(Tuple), is_integer(Index) ->
    element(Index, Tuple);
tuple_element(Value, _Index) ->
    Value.

format_exception({_Class, Reason, _Stack}) ->
    format_reason(Reason);
format_exception(Reason) ->
    format_reason(Reason).

format_reason(Reason) ->
    case find_message(Reason) of
        {ok, Msg} -> Msg;
        error -> iolist_to_binary(io_lib:format("~tp", [Reason]))
    end.

find_message(#{message := Msg}) when is_binary(Msg) ->
    {ok, Msg};
find_message({message, Msg}) when is_binary(Msg) ->
    {ok, Msg};
find_message(Term) when is_tuple(Term) ->
    find_message(tuple_to_list(Term));
find_message([Head | Tail]) ->
    case find_message(Head) of
        {ok, _} = Ok -> Ok;
        error -> find_message(Tail)
    end;
find_message(Map) when is_map(Map) ->
    find_message(maps:to_list(Map));
find_message(_) ->
    error.
