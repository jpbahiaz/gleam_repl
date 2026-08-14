-module(repl_ffi).
-export([
    get_line/1,
    load_binary/3,
    safe_apply/3,
    tuple_element/2,
    format_exception/1,
    is_tty/0,
    tty_begin/0,
    tty_end/0,
    tty_read/0,
    tty_write/1
]).

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

is_tty() ->
    tty_isatty(stdin) orelse tty_isatty(stdout).

tty_isatty(Which) ->
    try prim_tty:isatty(Which) of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end.

%% One prim_tty session for the whole REPL. init/1 starts linked
%% reader/writer processes named <us>_reader / <us>_writer; calling
%% init again crashes with "name is in use". Flip raw/cooked with reinit/2.
tty_begin() ->
    ensure_registered(),
    process_flag(trap_exit, true),
    case get(repl_prim) of
        undefined -> first_init();
        State -> resume_raw(State)
    end.

tty_end() ->
    case get(repl_prim) of
        undefined ->
            ok;
        State ->
            put(repl_prim_buf, <<>>),
            try
                put(repl_prim, prim_tty:reinit(State, #{input => cooked, output => cooked}))
            catch
                _:_ -> ok
            end
    end,
    flush_exits(),
    nil.

first_init() ->
    try
        ok = prim_tty:load(),
        error_logger:tty(false),
        State =
            try prim_tty:init(#{input => raw, output => raw})
            after error_logger:tty(true)
            end,
        put(repl_prim, State),
        put(repl_prim_buf, <<>>),
        prim_tty:read(State),
        {ok, nil}
    catch
        _:_ ->
            {error, nil}
    end.

resume_raw(State) ->
    try
        New = prim_tty:reinit(State, #{input => raw, output => raw}),
        put(repl_prim, New),
        prim_tty:read(New),
        {ok, nil}
    catch
        _:_ ->
            {error, nil}
    end.

tty_read() ->
    case get(repl_prim_buf) of
        <<B, Rest/binary>> ->
            put(repl_prim_buf, Rest),
            {byte, B};
        _ ->
            wait_byte()
    end.

tty_write(Bin) when is_binary(Bin) ->
    case get(repl_prim) of
        undefined ->
            io:put_chars(standard_io, Bin);
        State ->
            prim_tty:write(State, Bin)
    end,
    nil;
tty_write(List) when is_list(List) ->
    tty_write(unicode:characters_to_binary(List)).

wait_byte() ->
    case get(repl_prim) of
        undefined ->
            tty_eof;
        State ->
            #{read := Ref} = prim_tty:handles(State),
            receive
                {Ref, {data, <<>>}} ->
                    prim_tty:read(State),
                    wait_byte();
                {Ref, {data, Data}} ->
                    put(repl_prim_buf, Data),
                    prim_tty:read(State),
                    tty_read();
                {Ref, eof} ->
                    tty_eof;
                {'EXIT', _, _} ->
                    wait_byte()
            end
    end.

ensure_registered() ->
    case erlang:process_info(self(), registered_name) of
        {registered_name, _} ->
            ok;
        [] ->
            try unregister(repl_tty_owner) catch _:_ -> ok end,
            true = register(repl_tty_owner, self()),
            ok
    end.

flush_exits() ->
    receive
        {'EXIT', _, _} -> flush_exits()
    after 0 ->
        ok
    end.
