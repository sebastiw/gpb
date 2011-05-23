%%% Copyright (C) 2010  Tomas Abrahamsson
%%%
%%% Author: Tomas Abrahamsson <tab@lysator.liu.se>
%%%
%%% This library is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU Library General Public
%%% License as published by the Free Software Foundation; either
%%% version 2 of the License, or (at your option) any later version.
%%%
%%% This library is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% Library General Public License for more details.
%%%
%%% You should have received a copy of the GNU Library General Public
%%% License along with this library; if not, write to the Free
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

-module(gpb_compile).
%-compile(export_all).
-export([file/1, file/2]).
-export([msg_defs/2, msg_defs/3]).
-include_lib("kernel/include/file.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../include/gpb.hrl").

%% @spec file(File) -> ok | {error, Reason}
%% @equiv file(File, [])
file(File) ->
    file(File, []).

%% @spec file(File, Opts) -> ok | {ok, Mod, Code} | {error, Reason}
%%            File = string()
%%            Opts = [Opt]
%%            Opt  = {i,directory()} |
%%                   {type_specs, boolean()} | type_specs |
%%                   {verify, optionally | always} |
%%                   {o,directory()} |
%%                   binary |
%%                   {copy_bytes, true | false | auto | integer() | float()}
%%            Mod  = atom()
%%            Code = binary()
%%
%% @doc
%% Compile a .proto file to a .erl file and to a .hrl file.
%%
%% The generated .erl file will use the `gpb' module for runtime
%% support for encoding and decoding.
%%
%% The File must not include path to the .proto file. Example:
%% "SomeDefinitions.proto" is ok, while "/path/to/SomeDefinitions.proto"
%% is not ok.
%%
%% The .proto file is expected to be found in a directories specified by an
%% `{i,directory()}' option. It is possible to specify `{i,directory()}'
%% several times, they will be search in the order specified.
%%
%% The `{type_specs,boolean()}' option enables or disables `::Type()'
%% annotations in the generated .hrl file. Default is currently
%% `false'. If you set it to `true', you may get into troubles for
%% messages referencing other messages, when compiling the generated
%% files. The `type_specs' option is equivalent to `{type_specs,true}'.
%%
%% The `verify' option whether or not to generate code for verifying
%% that, during encoding, values are of correct type and within range.
%% The `verify' option can have the following values:
%% <dl>
%%    <dt>`always'</dt><dd>Generate code that unconditionally
%%        verifies values.</dd>
%%    <dt>`never'</dt><dd>Generate code that never verifies
%%        values time. Encoding will fail if a value of the wrong
%%        type is supplied. This includes forgetting to set a required
%%        message field. Encoding may silently truncate values out of
%%        range for some types.</dd>
%%    <dt>`optionally'</dt><dd>Generate an `encode_msg/2' that accepts
%%        the run-time option `verify' or `{verify,boolean()}' for specifying
%%        whether or not to verify values.</dd>
%% </dl>
%%
%% Erlang value verfication either succeeds or crashes with the `error'
%% `{gpb_type_error,Reason}'. Regardless of the `verify' option,
%% a function, `verify_msg/1' is always generated.
%%
%% The `{o,directory()}' option specifies directory to use for storing
%% the generated `.erl' and `.hrl' files. Default is the same
%% directory as for the proto `File'.
%%
%% The `binary' option will cause the generated and compiled code be
%% returned as a binary. No files will be written. The return value
%% will be on the form `{ok,Mod,Code}' if the compilation is succesful.
%% This option may be useful e.g. when generating test cases.
%%
%% The `copy_bytes' option specifies whether when decoding data of
%% type `bytes', the decoded bytes should be copied or not. Copying
%% requires the `binary' module, which first appeared in Erlang
%% R14A. When not copying decoded bytes, they will become sub binaries
%% of the larger input message binary. This may tie up the memory in
%% the input message binary longer than necessary after it has been
%% decoded. Copying the decoded bytes will avoid creating sub
%% binaries, which will in make it possible to free the input message
%% binary earlier. The `copy_bytes' option can have the following values:
%% <dl>
%%   <dt>`false'</dt><dd>Never copy bytes/(sub-)binaries.</dd>
%%   <dt>`true'</dt><dd>Always copy bytes/(sub-)binaries.</dd>
%%   <dt>`auto'</dt><dd>Copy bytes/(sub-)binaries if the beam vm,
%%           on which the compiler (this module) is running,
%%           has the `binary:copy/1' function.</dd>
%%   <dt>integer() | float()</dt><dd>Copy the bytes/(sub-)binaries if the
%%           message this many times or more larger than the size of the
%%           bytes/(sub-)binary.</dd>
%% </dl>
file(File, Opts) ->
    case parse_file(File, Opts) of
        {ok, Defs} ->
            Ext = filename:extension(File),
            Mod = list_to_atom(filename:basename(File, Ext)),
            DefaultOutDir = filename:dirname(File),
            msg_defs(Mod, Defs, Opts ++ [{o,DefaultOutDir}]);
        {error, _Reason} = Error ->
            Error
    end.

%% @spec msg_defs(Mod, Defs) -> ok | {ok, Mod, Code} | {error, Reason}
%% @equiv msg_defs(Mod, Defs, [])
msg_defs(Mod, Defs) ->
    msg_defs(Mod, Defs, []).

%% @spec msg_defs(Mod, Defs, Opts) -> ok | {ok, Mod, Code} | {error, Reason}
%%            Mod  = atom()
%%            Defs = [Def]
%%            Def = {{enum, EnumName}, Enums} |
%%                  {{msg, MsgName}, MsgFields}
%%            EnumName = atom()
%%            Enums = [{Name, integer()}]
%%            Name = atom()
%%            MsgName = atom()
%%            MsgFields = [#field{}]
%%            Opts = [Opt]
%%            Opt  = {i,directory()} |
%%                   {type_specs, boolean()} |
%%                   {o,directory()} |
%%                   binary |
%%                   {copy_bytes, true | false | auto | integer() | float()}
%%            Code = binary()
%%
%% @doc
%% Compile a list of pre-parsed definitions to file or to a binary.
%% See the {@link file/2} function for furhter description.
msg_defs(Mod, Defs0, Opts0) ->
    {IsAcyclic, Defs} = try_topsort_defs(Defs0),
    possibly_probe_defs(Defs, Opts0),
    Opts1 = possibly_adjust_typespec_opt(IsAcyclic, Opts0),
    OutDir = proplists:get_value(o, Opts1, "."),
    Erl = filename:join(OutDir, atom_to_list(Mod) ++ ".erl"),
    Hrl = change_ext(Erl, ".hrl"),
    case proplists:get_bool(binary, Opts1) of
        true ->
            compile_to_binary(Defs, format_erl(Mod, Defs, Opts1), Opts1);
        false ->
            file_write_file(Erl, format_erl(Mod, Defs, Opts1), Opts1),
            file_write_file(Hrl, format_hrl(Mod, Defs, Opts1), Opts1)
    end.

change_ext(File, NewExt) ->
    filename:join(filename:dirname(File),
                  filename:basename(File, filename:extension(File)) ++ NewExt).

parse_file(FName, Opts) ->
    case parse_file_and_imports(FName, Opts) of
        {ok, {Defs1, _AllImported}} ->
            %% io:format("processed these imports:~n  ~p~n", [_AllImported]),
            %% io:format("Defs1=~n  ~p~n", [Defs1]),
            Defs2 = gpb_parse:flatten_defs(
                      gpb_parse:absolutify_names(Defs1)),
            case gpb_parse:verify_defs(Defs2) of
                ok ->
                    {ok, gpb_parse:normalize_msg_field_options( %% Sort it?
                           gpb_parse:enumerate_msg_fields(
                             gpb_parse:extend_msgs(
                               gpb_parse:resolve_refs(
                                 gpb_parse:reformat_names(Defs2)))))};
                {error, _Reasons} = Error ->
                    Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

parse_file_and_imports(FName, Opts) ->
    parse_file_and_imports(FName, [FName], Opts).

parse_file_and_imports(FName, AlreadyImported, Opts) ->
    case locate_import(FName, Opts) of
        {ok, FName2} ->
            {ok,B} = file_read_file(FName2, Opts),
            %% Add to AlreadyImported to prevent trying to import it again: in
            %% case we get an error we don't want to try to reprocess it later
            %% (in case it is multiply imported) and get the error again.
            AlreadyImported2 = [FName | AlreadyImported],
            case scan_and_parse_string(binary_to_list(B)) of
                {ok, Defs} ->
                    Imports = gpb_parse:fetch_imports(Defs),
                    read_and_parse_imports(Imports,AlreadyImported2,Defs,Opts);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

scan_and_parse_string(S) ->
    case gpb_scan:string(S) of
        {ok, Tokens, _} ->
            case gpb_parse:parse(Tokens++[{'$end', 999}]) of
                {ok, Result} ->
                    {ok, Result};
                {error, {_LNum,_Module,_EMsg}=Reason} ->
                    {error, {parse_error,S,Reason}}
            end;
        {error,Reason} ->
            {error, {scan_error,S,Reason}}
    end.


read_and_parse_imports([Import | Rest], AlreadyImported, Defs, Opts) ->
    case lists:member(Import, AlreadyImported) of
        true ->
            read_and_parse_imports(Rest, AlreadyImported, Defs, Opts);
        false ->
            case import_it(Import, AlreadyImported, Defs, Opts) of
                {ok, {Defs2, Imported2}} ->
                    read_and_parse_imports(Rest, Imported2, Defs2, Opts);
                {error, Reason} ->
                    {error, Reason}
            end
    end;
read_and_parse_imports([], Imported, Defs, _Opts) ->
    {ok, {Defs, Imported}}.

import_it(Import, AlreadyImported, Defs, Opts) ->
    %% FIXME: how do we handle scope of declarations,
    %%        e.g. options/package for imported files?
    case parse_file_and_imports(Import, AlreadyImported, Opts) of
        {ok, {MoreDefs, MoreImported}} ->
            Defs2 = Defs++MoreDefs,
            Imported2 = lists:usort(AlreadyImported++MoreImported),
            {ok, {Defs2, Imported2}};
        {error, Reason} ->
            {error, Reason}
    end.

locate_import(Import, Opts) ->
    ImportPaths = [Path || {i, Path} <- Opts],
    locate_import_aux(ImportPaths, Import, Opts).

locate_import_aux([Path | Rest], Import, Opts) ->
    File = filename:join(Path, Import),
    case file_read_file_info(File, Opts) of
        {ok, #file_info{access = A}} when A == read; A == read_write ->
            {ok, File};
        {ok, #file_info{}} ->
            locate_import_aux(Rest, Import, Opts);
        {error, _Reason} ->
            locate_import_aux(Rest, Import, Opts)
    end;
locate_import_aux([], Import, _Opts) ->
    {error, {import_not_found, Import}}.

try_topsort_defs(Defs) ->
    G = digraph:new(),
    [digraph:add_vertex(G, M) || {{msg,M}, _Fields} <- Defs],
    [[digraph:add_edge(G, From, To) || #field{type={msg,To}} <- Fields]
     || {{msg,From},Fields} <- Defs],
    case digraph_utils:topsort(G) of
        false ->
            digraph:delete(G),
            {false, Defs};
        Order ->
            digraph:delete(G),
            ROrder = lists:reverse(Order),
            OrderedMsgDefs = [lists:keyfind({msg,M},1,Defs) || M <- ROrder],
            {true, OrderedMsgDefs ++ (Defs -- OrderedMsgDefs)}
    end.

possibly_adjust_typespec_opt(true=_IsAcyclic, Opts) ->
    Opts;
possibly_adjust_typespec_opt(false=_IsAcyclic, Opts) ->
    case get_type_specs_by_opts(Opts) of
        true  ->
            io:format("Warning: omitting type specs "
                      "due to cyclic message references.~n"),
            lists:keydelete(type_specs, 1, Opts -- [type_specs]); % disable
        false ->
            Opts
    end.

format_erl(Mod, Defs, Opts) ->
    iolist_to_binary(
      [f("%% Automatically generated, do not edit~n"
         "%% Generated by ~p on ~p~n", [?MODULE, calendar:local_time()]),
       f("-module(~w).~n", [Mod]),
       "\n",
       f("-export([encode_msg/1, encode_msg/2]).~n"),
       f("-export([decode_msg/2]).~n"),
       f("-export([merge_msgs/2]).~n"),
       f("-export([verify_msg/1]).~n"),
       f("-export([get_msg_defs/0]).~n"),
       "\n",
       f("-include(\"~s.hrl\").~n", [Mod]),
       f("-include(\"gpb.hrl\").~n"),
       "\n",
       f("-compile(nowarn_unused_function).~n"),
       %% Enabling inlining seems to cause performance to drop drastically
       %% I've seen decoding performance go down from 76000 msgs/s
       %% to about 10000 msgs/s for a set of mixed message samples.
       %% f("-compile(inline).~n"),
       "\n",
       f("encode_msg(Msg) ->~n"
         "    encode_msg(Msg, []).~n~n"),
       case proplists:get_value(verify, Opts, optionally) of
           optionally ->
               f("encode_msg(Msg, Opts) ->~n"
                 "    case proplists:get_bool(verify, Opts) of~n"
                 "        true  -> verify_msg(Msg);~n"
                 "        false -> ok~n"
                 "    end,~n"
                 "    ~s.~n", [format_encoder_topcase(4, Defs, "Msg")]);
           always ->
               f("encode_msg(Msg, _Opts) ->~n"
                 "    verify_msg(Msg),~n"
                 "    ~s.~n", [format_encoder_topcase(4, Defs, "Msg")]);
           never ->
               f("encode_msg(Msg, _Opts) ->~n"
                 "    ~s.~n", [format_encoder_topcase(4, Defs, "Msg")])
       end,
       "\n",
       f("~s~n", [format_encoders(Defs, Opts)]),
       "\n",
       f("decode_msg(Bin, MsgName) ->~n"
         "    ~s.~n",
         [format_decoder_topcase(4, Defs, "Bin", "MsgName")]),
       "\n",
       f("~s~n", [format_decoders(Defs, Opts)]),
       "\n",
       f("~s~n", [format_msg_merge_code(Defs)]),
       "\n",
       f("verify_msg(Msg) ->~n" %% Option to use gpb:verify_msg??
         "    ~s.~n", [format_verifier_topcase(4, Defs, "Msg")]),
       "\n",
       f("~s~n", [format_verifiers(Defs, Opts)]),
       "\n",
       f("get_msg_defs() ->~n"
         "    [~s].~n", [outdent_first(format_msgs_and_enums(5, Defs))])]).

%% -- encoders -----------------------------------------------------

format_encoder_topcase(Indent, Defs, MsgVar) ->
    IndStr = indent(Indent+4, ""),
    ["case ", MsgVar, " of\n",
     IndStr,
     string:join([f("#~p{} -> ~p(~s)",
                    [MsgName, mk_fn(e_msg_, MsgName), MsgVar])
                  || {{msg, MsgName}, _MsgDef} <- Defs],
                 ";\n"++IndStr),
     "\n",
     indent(Indent, "end")].

format_encoders(Defs, _Opts) ->
    [format_enum_encoders(Defs),
     format_msg_encoders(Defs),
     format_special_field_encoders(Defs),
     format_type_encoders()
    ].

format_enum_encoders(Defs) ->
    [format_enum_encoder(EnumName, EnumDef)
     || {{enum, EnumName}, EnumDef} <- Defs].

format_enum_encoder(EnumName, EnumDef) ->
    FnName = mk_fn(e_enum_, EnumName),
    [string:join([f("~p(~p, Bin) -> <<Bin/binary, ~s>>",
                    [FnName, EnumSym, encode_format_enum_value(EnumValue)])
                  || {EnumSym, EnumValue} <- EnumDef],
                 ";\n"),
     ".\n\n"].

encode_format_enum_value(Value) ->
    <<N:32/unsigned-native>> = <<Value:32/signed-native>>,
    varint_to_byte_text(N).

varint_to_byte_text(N) ->
    Bin = gpb:encode_varint(N),
    string:join([integer_to_list(B) || <<B:8>> <= Bin], ",").

format_msg_encoders(Defs) ->
    [format_msg_encoder(MsgName, MsgDef) || {{msg, MsgName}, MsgDef} <- Defs].

format_msg_encoder(MsgName, []) ->
    FnName = mk_fn(e_msg_, MsgName),
    [f("~p(_Msg) ->~n", [FnName]),
     f("    <<>>.~n~n")];
format_msg_encoder(MsgName, MsgDef) ->
    FnName = mk_fn(e_msg_, MsgName),
    MatchIndent = flength("~p(#~p{", [FnName, MsgName]),
    MatchCommaSep = f(",~n~s", [indent(MatchIndent, "")]),
    FieldMatchings = string:join([f("~p=F~s", [FName, FName])
                                  || #field{name=FName} <- MsgDef],
                                 MatchCommaSep),
    [f("~p(#~p{~s}) ->~n", [FnName, MsgName, FieldMatchings]),
     f("    Bin0 = <<>>,\n"),
     string:join(
       [begin
            FieldEncoderFn = mk_field_encode_fn_name(MsgName, Field),
            ResultVar = if I == length(MsgDef) -> "";
                           true                -> f("Bin~w = ", [I])
                        end,
            RIndent = lists:flatlength(ResultVar),
            KeyTxt = mk_key_txt(FNum, Type),
            if Occurrence == optional ->
                    f("    ~sif F~s == undefined -> Bin~w;~n"
                      "    ~*s  true -> ~p(F~s, <<Bin~w/binary, ~s>>)~n"
                      "    ~*send",
                      [ResultVar, FName, I-1,
                       RIndent, "", FieldEncoderFn, FName, I-1, KeyTxt,
                       RIndent, ""]);
               Occurrence == repeated ->
                    f("    ~sif F~s == [] -> Bin~w;~n"
                      "    ~*s  true -> ~p(F~s, Bin~w)~n"
                      "    ~*send",
                      [ResultVar, FName, I-1,
                       RIndent, "", FieldEncoderFn, FName, I-1,
                       RIndent, ""]);
               Occurrence == required ->
                    f("    ~s~p(F~s, <<Bin~w/binary, ~s>>)",
                      [ResultVar, FieldEncoderFn, FName, I-1, KeyTxt])
            end
        end
        || {I, #field{name=FName, occurrence=Occurrence, type=Type,
                      fnum=FNum}=Field} <- index_seq(MsgDef)],
       ",\n"),
     ".\n",
     "\n"].

mk_key_txt(FNum, Type) ->
    Key = (FNum bsl 3) bor gpb:encode_wire_type(Type),
    varint_to_byte_text(Key).

mk_field_encode_fn_name(MsgName, #field{occurrence=repeated, name=FName}) ->
    mk_fn(e_field_, MsgName, FName);
mk_field_encode_fn_name(MsgName, #field{type={msg,_Msg}, name=FName}) ->
    mk_fn(e_mfield_, MsgName, FName);
mk_field_encode_fn_name(_MsgName, #field{type={enum,EnumName}}) ->
    mk_fn(e_enum_, EnumName);
mk_field_encode_fn_name(_MsgName, #field{type=sint32}) ->
    mk_fn(e_type_, sint);
mk_field_encode_fn_name(_MsgName, #field{type=sint64}) ->
    mk_fn(e_type_, sint);
mk_field_encode_fn_name(_MsgName, #field{type=uint32}) ->
    e_varint;
mk_field_encode_fn_name(_MsgName, #field{type=uint64}) ->
    e_varint;
mk_field_encode_fn_name(_MsgName, #field{type=Type}) ->
    mk_fn(e_type_, Type).

format_special_field_encoders(Defs) ->
    [[format_field_encoder(MsgName, FieldDef)
      || #field{occurrence=Occ, type=Type}=FieldDef <- MsgDef,
         Occ == repeated orelse is_msg_type(Type)]
     || {{msg,MsgName}, MsgDef} <- Defs].

is_msg_type({msg,_}) -> true;
is_msg_type(_)       -> false.

format_field_encoder(MsgName, #field{occurrence=Occurrence}=FieldDef) ->
    [possibly_format_mfield_encoder(MsgName,
                                    FieldDef#field{occurrence=required}),
     case {Occurrence, is_packed(FieldDef)} of
         {repeated, false} -> format_repeated_field_encoder2(MsgName, FieldDef);
         {repeated, true}  -> format_packed_field_encoder2(MsgName, FieldDef);
         {optional, false} -> [];
         {required, false} -> []
     end].

possibly_format_mfield_encoder(MsgName, #field{type={msg,SubMsg}}=FieldDef) ->
    FnName = mk_field_encode_fn_name(MsgName, FieldDef),
    [f("~p(Msg, Bin) ->~n", [FnName]),
     f("    SubBin = ~p(Msg),~n", [mk_fn(e_msg_, SubMsg)]),
     f("    Bin2 = e_varint(byte_size(SubBin), Bin),~n"),
     f("    <<Bin2/binary, SubBin/binary>>.~n~n")];
possibly_format_mfield_encoder(_MsgName, _FieldDef) ->
    [].

format_repeated_field_encoder2(MsgName, #field{fnum=FNum, type=Type}=FDef) ->
    FnName = mk_field_encode_fn_name(MsgName, FDef),
    ElemEncoderFn = mk_field_encode_fn_name(MsgName,
                                            FDef#field{occurrence=required}),
    KeyTxt = mk_key_txt(FNum, Type),
    [f("~p([Elem | Rest], Bin) ->~n", [FnName]),
     f("    Bin2 = <<Bin/binary, ~s>>,~n", [KeyTxt]),
     f("    Bin3 = ~p(Elem, Bin2),~n", [ElemEncoderFn]),
     f("    ~p(Rest, Bin3);~n", [FnName]),
     f("~p([], Bin) ->~n", [FnName]),
     f("    Bin.~n~n")].

format_packed_field_encoder2(MsgName, #field{type=Type}=FDef) ->
    case packed_byte_size_can_be_computed(Type) of
        {yes, BitLen, BitType} ->
            format_knowsize_packed_field_encoder2(MsgName, FDef,
                                                  BitLen, BitType);
        no ->
            format_unknowsize_packed_field_encoder2(MsgName, FDef)
    end.

packed_byte_size_can_be_computed(fixed32)  -> {yes, 32, 'little'};
packed_byte_size_can_be_computed(sfixed32) -> {yes, 32, 'little-signed'};
packed_byte_size_can_be_computed(float)    -> {yes, 32, 'little-float'};
packed_byte_size_can_be_computed(fixed64)  -> {yes, 64, 'little'};
packed_byte_size_can_be_computed(sfixed64) -> {yes, 64, 'little-signed'};
packed_byte_size_can_be_computed(double)   -> {yes, 64, 'little-float'};
packed_byte_size_can_be_computed(_)        -> no.

format_knowsize_packed_field_encoder2(MsgName, #field{name=FName,
                                                      fnum=FNum}=FDef,
                                      BitLen, BitType) ->
    FnName = mk_field_encode_fn_name(MsgName, FDef),
    KeyTxt = mk_key_txt(FNum, bytes),
    PackedFnName = mk_fn(e_pfield_, MsgName, FName),
    [f("~p(Elems, Bin) when Elems =/= [] ->~n", [FnName]),
     f("    Bin2 = <<Bin/binary, ~s>>,~n", [KeyTxt]),
     f("    Bin3 = e_varint(length(Elems) * ~w, Bin2),~n", [BitLen div 8]),
     f("    ~p(Elems, Bin3);~n", [PackedFnName]),
     f("~p([], Bin) ->~n", [FnName]),
     f("    Bin.~n"),
     f("~n"),
     f("~p([Value | Rest], Bin) ->~n", [PackedFnName]),
     f("    Bin2 = <<Bin/binary, Value:~w/~s>>,~n", [BitLen, BitType]),
     f("    ~p(Rest, Bin2);~n", [PackedFnName]),
     f("~p([], Bin) ->~n", [PackedFnName]),
     f("    Bin.~n~n")].

format_unknowsize_packed_field_encoder2(MsgName, #field{name=FName,
                                                        fnum=FNum}=FDef) ->
    FnName = mk_field_encode_fn_name(MsgName, FDef),
    ElemEncoderFn = mk_field_encode_fn_name(MsgName,
                                            FDef#field{occurrence=required}),
    KeyTxt = mk_key_txt(FNum, bytes),
    PackedFnName = mk_fn(e_pfield_, MsgName, FName),
    [f("~p(Elems, Bin) when Elems =/= [] ->~n", [FnName]),
     f("    SubBin = ~p(Elems, <<>>),~n", [PackedFnName]),
     f("    Bin2 = <<Bin/binary, ~s>>,~n", [KeyTxt]),
     f("    Bin3 = e_varint(byte_size(SubBin), Bin2),~n"),
     f("    <<Bin3/binary, SubBin/binary>>;~n"),
     f("~p([], Bin) ->~n", [FnName]),
     f("    Bin.~n"),
     f("~n"),
     f("~p([Value | Rest], Bin) ->~n", [PackedFnName]),
     f("    Bin2 = ~p(Value, Bin),~n", [ElemEncoderFn]),
     f("    ~p(Rest, Bin2);~n", [PackedFnName]),
     f("~p([], Bin) ->~n", [PackedFnName]),
     f("    Bin.~n~n")].

format_type_encoders() ->
    [format_sint_encoder(),
     format_int_encoder(int32, 32),
     format_int_encoder(int64, 64),
     format_bool_encoder(),
     format_fixed_encoder(fixed32,  32, 'little'),
     format_fixed_encoder(sfixed32, 32, 'little-signed'),
     format_fixed_encoder(float,    32, 'little-float'),
     format_fixed_encoder(fixed64,  64, 'little'),
     format_fixed_encoder(sfixed64, 64, 'little-signed'),
     format_fixed_encoder(double,   64, 'little-float'),
     format_string_encoder(),
     format_bytes_encoder(),
     format_varint_encoder()].

format_sint_encoder() ->
    [f("e_type_sint(Value, Bin) when Value >= 0 ->~n"),
     f("    e_varint(Value * 2, Bin);~n"),
     f("e_type_sint(Value, Bin) ->~n"),
     f("    e_varint(Value * -2 - 1, Bin).~n~n")].

format_int_encoder(Type, BitLen) ->
    FnName = mk_fn(e_type_, Type),
    [f("~p(Value, Bin) when 0 =< Value, Value =< 127 ->~n", [FnName]),
     f("    <<Bin/binary, Value>>; %% fast path~n"),
     f("~p(Value, Bin) ->~n", [FnName]),
     f("    <<N:~w/unsigned-native>> = <<Value:~w/signed-native>>,~n",
       [BitLen, BitLen]),
     f("    e_varint(N, Bin).~n~n")].

format_bool_encoder() ->
    [f("e_type_bool(true, Bin)  -> <<Bin/binary, 1>>;~n"),
     f("e_type_bool(false, Bin) -> <<Bin/binary, 0>>.~n~n")].

format_fixed_encoder(Type, BitLen, BitType) ->
    FnName = mk_fn(e_type_, Type),
    [f("~p(Value, Bin) ->~n", [FnName]),
     f("    <<Bin/binary, Value:~p/~s>>.~n~n", [BitLen, BitType])].

format_string_encoder() ->
    [f("e_type_string(S, Bin) ->~n"),
     f("    Utf8 = unicode:characters_to_binary(S),~n"),
     f("    Bin2 = e_varint(byte_size(Utf8), Bin),~n"),
     f("    <<Bin2/binary, Utf8/binary>>.~n~n")].

format_bytes_encoder() ->
    [f("e_type_bytes(Bytes, Bin) ->~n"),
     f("    Bin2 = e_varint(byte_size(Bytes), Bin),~n"),
     f("    <<Bin2/binary, Bytes/binary>>.~n~n")].

format_varint_encoder() ->
    [f("e_varint(N, Bin) when N =< 127 ->~n"),
     f("    <<Bin/binary, N>>;~n"),
     f("e_varint(N, Bin) ->~n"),
     f("    Bin2 = <<Bin/binary, 1:1, (N band 127):7>>,~n"),
     f("    e_varint(N bsr 7, Bin2).~n~n")].

%% -- decoders -----------------------------------------------------

format_decoder_topcase(Indent, Defs, BinVar, MsgNameVar) ->
    ["case ", MsgNameVar, " of\n",
     string:join([indent(Indent+4, f("~p -> ~p(~s)",
                                     [MsgName, mk_fn(d_msg_, MsgName), BinVar]))
                  || {{msg, MsgName}, _MsgDef} <- Defs],
                 ";\n"),
     "\n",
     indent(Indent, f("end"))].

format_decoders(Defs, Opts) ->
    [format_enum_decoders(Defs),
     format_initial_msgs(Defs),
     format_msg_decoders(Defs, Opts)].

format_enum_decoders(Defs) ->
    %% FIXME: enum values can be negative, but "raw" varints are positive
    %%        insert a 2-complement in the mapping in order to move computations
    %%        from runtime to compiletime??
    [[string:join([f("~p(~w) -> ~p",
                     [mk_fn(d_enum_, EnumName), EnumValue, EnumSym])
                   || {EnumSym, EnumValue} <- EnumDef],
                  ";\n"),
      ".\n\n"]
     || {{enum, EnumName}, EnumDef} <- Defs].

format_initial_msgs(Defs) ->
    [format_initial_msg(MsgName, MsgDef, Defs)
     || {{msg, MsgName}, MsgDef} <- Defs].

format_initial_msg(MsgName, MsgDef, Defs) ->
    [f("~p() ->~n", [mk_fn(msg0_, MsgName)]),
     indent(4, format_initial_msg_record(4, MsgName, MsgDef, Defs)),
     ".\n\n"].

format_initial_msg_record(Indent, MsgName, MsgDef, Defs) ->
    MsgNameQLen = flength("~p", [MsgName]),
    f("#~p{~s}",
      [MsgName, format_initial_msg_fields(Indent+MsgNameQLen+2, MsgDef, Defs)]).

format_initial_msg_fields(Indent, MsgDef, Defs) ->
    outdent_first(
      string:join(
        [case Field of
             #field{occurrence=repeated} ->
                 indent(Indent, f("~p = []", [FName]));
             #field{type={msg,FMsgName}} ->
                 FNameQLen = flength("~p", [FName]),
                 {Type, FMsgDef} = lists:keyfind(Type, 1, Defs),
                 indent(Indent, f("~p = ~s",
                                  [FName,
                                   format_initial_msg_record(Indent+FNameQLen+2,
                                                             FMsgName, FMsgDef,
                                                             Defs)]))
         end
         || #field{name=FName, type=Type}=Field <- MsgDef,
            case Field of
                #field{occurrence=repeated} -> true;
                #field{occurrence=optional} -> false;
                #field{type={msg,_}}        -> true;
                _                           -> false
            end],
        ",\n")).

format_msg_decoders(Defs, Opts) ->
    [format_msg_decoder(MsgName, MsgDef, Opts)
     || {{msg, MsgName}, MsgDef} <- Defs].

format_msg_decoder(MsgName, MsgDef, Opts) ->
    [format_msg_decoder_read_field(MsgName, MsgDef),
     format_msg_decoder_reverse_toplevel(MsgName, MsgDef),
     format_field_decoders(MsgName, MsgDef, Opts),
     format_field_adders(MsgName, MsgDef),
     format_field_skippers(MsgName)].

format_msg_decoder_read_field(MsgName, MsgDef) ->
    ReadFieldCases = format_read_field_cases(MsgName, MsgDef),
    [f("~p(Bin) ->~n", [mk_fn(d_msg_, MsgName)]),
     indent(4, f("Msg0 = ~s(),~n", [mk_fn(msg0_, MsgName)])),
     indent(4, f("~p(Bin, 0, 0, Msg0).~n", [mk_fn(d_read_field_def_, MsgName)])),
     "\n",
     f("~p(<<1:1, X:7, Rest/binary>>, N, Acc, Msg) ->~n"
       "    ~p(Rest, N+1, X bsl (N*7) + Acc, Msg);~n",
       [mk_fn(d_read_field_def_, MsgName),
        mk_fn(d_read_field_def_, MsgName)]),
     f("~p(<<0:1, X:7, Rest/binary>>, N, Acc, Msg) ->~n"
       "    Key = X bsl (N*7) + Acc,~n", [mk_fn(d_read_field_def_, MsgName)]),
     if ReadFieldCases == [] ->
             f("    case Key band 7 of  %% WireType~n"
               "        0 -> skip_varint_~s(Rest, Msg);~n"
               "        1 -> skip_64_~s(Rest, Msg);~n"
               "        2 -> skip_length_delimited_~s(Rest, 0, 0, Msg);~n"
               "        5 -> skip_32_~s(Rest, Msg)~n"
               "    end;~n",
               [MsgName,MsgName,MsgName,MsgName]);
        true ->
             f("    case Key bsr 3 of~n"
               "~s"
               "        _ ->~n"
               "            case Key band 7 of  %% WireType~n"
               "                0 -> skip_varint_~s(Rest, Msg);~n"
               "                1 -> skip_64_~s(Rest, Msg);~n"
               "                2 -> skip_length_delimited_~s(Rest,0,0,Msg);~n"
               "                5 -> skip_32_~s(Rest, Msg)~n"
               "            end~n"
               "    end;~n",
               [ReadFieldCases,
                MsgName,MsgName,MsgName,MsgName])
     end,
     f("~p(<<>>, 0, 0, Msg) ->~n"
       "    ~p(Msg).~n~n",
       [mk_fn(d_read_field_def_, MsgName),
        mk_fn(d_reverse_toplevel_fields_, MsgName)])].

format_read_field_cases(MsgName, MsgDef) ->
    [indent(8, f("~p -> ~p(Rest~sMsg);~n",
                 [FNum, mk_fn(d_field_, MsgName, FName),
                  case mk_field_decoder_vi_params(FieldDef) of
                      ""     -> [", "];
                      Params -> [", ", Params, ", "]
                  end]))
     || #field{fnum=FNum, name=FName}=FieldDef <- MsgDef].


mk_field_decoder_vi_params(#field{type=Type}=FieldDef) ->
    case is_packed(FieldDef) of
        false ->
            case Type of
                sint32   -> "0, 0"; %% varint-based
                sint64   -> "0, 0"; %% varint-based
                int32    -> "0, 0"; %% varint-based
                int64    -> "0, 0"; %% varint-based
                uint32   -> "0, 0"; %% varint-based
                uint64   -> "0, 0"; %% varint-based
                bool     -> "0, 0"; %% varint-based
                {enum,_} -> "0, 0"; %% varint-based
                fixed32  -> "";
                sfixed32 -> "";
                float    -> "";
                fixed64  -> "";
                sfixed64 -> "";
                double   -> "";
                string   -> "0, 0"; %% varint-based
                bytes    -> "0, 0"; %% varint-based
                {msg,_}  -> "0, 0"  %% varint-based
            end;
        true ->
            "0, 0" %% length of packed bytes is varint-based
    end.

format_field_decoders(MsgName, MsgDef, Opts) ->
    [[format_field_decoder(MsgName, FieldDef, Opts), "\n"]
     || FieldDef <- MsgDef].

format_field_decoder(MsgName, FieldDef, Opts) ->
    case is_packed(FieldDef) of
        false -> format_non_packed_field_decoder(MsgName, FieldDef, Opts);
        true  -> format_packed_field_decoder(MsgName, FieldDef, Opts)
    end.

format_non_packed_field_decoder(MsgName, #field{type=Type}=FieldDef, Opts)->
    case Type of
        sint32   -> format_vi_based_field_decoder(MsgName, FieldDef, Opts);
        sint64   -> format_vi_based_field_decoder(MsgName, FieldDef, Opts);
        int32    -> format_vi_based_field_decoder(MsgName, FieldDef, Opts);
        int64    -> format_vi_based_field_decoder(MsgName, FieldDef, Opts);
        uint32   -> format_vi_based_field_decoder(MsgName, FieldDef, Opts);
        uint64   -> format_vi_based_field_decoder(MsgName, FieldDef, Opts);
        bool     -> format_vi_based_field_decoder(MsgName, FieldDef, Opts);
        {enum,_} -> format_vi_based_field_decoder(MsgName, FieldDef, Opts);
        fixed32  -> format_uf32_field_decoder(MsgName, FieldDef);
        sfixed32 -> format_sf32_field_decoder(MsgName, FieldDef);
        float    -> format_float_field_decoder(MsgName, FieldDef);
        fixed64  -> format_uf64_field_decoder(MsgName, FieldDef);
        sfixed64 -> format_sf64_field_decoder(MsgName, FieldDef);
        double   -> format_double_field_decoder(MsgName, FieldDef);
        string   -> format_vi_based_field_decoder(MsgName, FieldDef, Opts);
        bytes    -> format_vi_based_field_decoder(MsgName, FieldDef, Opts);
        {msg,_}  -> format_vi_based_field_decoder(MsgName, FieldDef, Opts)
    end.

format_packed_field_decoder(MsgName,#field{name=FName}=FieldDef, Opts)->
    DecodePackWrapFn = mk_fn(d_field_, MsgName, FName),
    #field{opts=FOpts} = FieldDef,
    FieldDefAsNonpacked = FieldDef#field{opts = FOpts -- [packed]},
    [f("~p(<<1:1, X:7, Rest/binary>>, N, Acc, Msg) ->~n", [DecodePackWrapFn]),
     f("    ~p(Rest, N+1, X bsl (N*7) + Acc, Msg);~n", [DecodePackWrapFn]),
     f("~p(<<0:1, X:7, Rest/binary>>, N, Acc, #~p{~p=AccSeq}=Msg) ->~n",
       [DecodePackWrapFn, MsgName, FName]),
     f("    Len = X bsl (N*7) + Acc,~n"),
     f("    <<PackedBytes:Len/binary, Rest2/binary>> = Rest,~n"),
     f("    NewSeq = ~p(PackedBytes~sAccSeq),~n",
       [mk_fn(d_packed_field_, MsgName, FName),
        case mk_field_decoder_vi_params(FieldDefAsNonpacked) of
            ""     -> [", "];
            Params -> [", ", Params, ", "]
        end]),
     f("    NewMsg = Msg#~p{~p=NewSeq},~n", [MsgName, FName]),
     f("    ~p(Rest2, 0, 0, NewMsg).~n~n", [mk_fn(d_read_field_def_, MsgName)]),
     format_packed_field_seq_decoder(MsgName, FieldDef, Opts)].

format_vi_based_field_decoder(MsgName, #field{type=Type, name=FName}, Opts) ->
    BValueExpr = "X bsl (N*7) + Acc",
    {FValueCode, RestVar} = mk_unpack_vi(4, "FValue", BValueExpr, Type, "Rest",
                                         Opts),
    [f("~p(<<1:1, X:7, Rest/binary>>, N, Acc, Msg) ->~n"
       "    ~p(Rest, N+1, X bsl (N*7) + Acc, Msg);~n",
       [mk_fn(d_field_, MsgName, FName),
        mk_fn(d_field_, MsgName, FName)]),
     f("~p(<<0:1, X:7, Rest/binary>>, N, Acc, Msg) ->~n",
       [mk_fn(d_field_, MsgName, FName)]),
     f("~s",
       [FValueCode]),
     f("    NewMsg = ~p(FValue, Msg),~n", [mk_fn(add_field_, MsgName, FName)]),
     f("    ~p(~s, 0, 0, NewMsg).~n",
       [mk_fn(d_read_field_def_, MsgName), RestVar])].

%% -> {FValueCode, Rest2Var}
%% Produce code for setting a variable, FValueVar, depending on the
%% varint type Type, for the raw unpacked expr, BValueExpr.
%%
%% The initial RestVar is the name of the variable holding the rest
%% of the bytes. An updated -- or the same -- such variable is returned.
%%
%% Indent the code to Indent spaces.
%% The resulting code contains one or more statements that ends with comma.
mk_unpack_vi(Indent, FValueVar, BValueExpr, Type, RestVar, Opts) ->
    Rest2Var = RestVar ++ "2",
    case Type of
        sint32 ->
            {[indent(Indent, f("BValue = ~s,~n", [BValueExpr])),
              indent(Indent, f("~s = ~s,~n",
                               [FValueVar,
                                fmt_decode_zigzag(Indent+7, "BValue")]))],
             RestVar};
        sint64 ->
            {[indent(Indent, f("BValue = ~s,~n", [BValueExpr])),
              indent(Indent, f("~s = ~s,~n",
                               [FValueVar,
                                fmt_decode_zigzag(Indent+7, "BValue")]))],
             RestVar};
        int32 ->
            {indent(Indent, f("~s,~n",
                              [fmt_uint_to_int(BValueExpr, FValueVar, 32)])),
             RestVar};
        int64 ->
            {indent(Indent, f("~s,~n",
                              [fmt_uint_to_int(BValueExpr, FValueVar, 64)])),
             RestVar};
        uint32 ->
            {indent(Indent, f("~s = ~s,~n", [FValueVar, BValueExpr])),
             RestVar};
        uint64 ->
            {indent(Indent, f("~s = ~s,~n", [FValueVar, BValueExpr])),
             RestVar};
        bool ->
            {indent(Indent, f("~s = ((~s) =/= 0),~n", [FValueVar, BValueExpr])),
             RestVar};
        {enum, EnumName} ->
            {[indent(Indent, f("~s,~n",
                               [fmt_uint_to_int(BValueExpr, "EnumValue", 32)])),
              indent(Indent, f("~s = ~p(EnumValue),~n",
                               [FValueVar, mk_fn(d_enum_, EnumName)]))],
             RestVar};
        string ->
            {[indent(Indent, f("Len = ~s,~n", [BValueExpr])),
              indent(Indent, f("<<Utf8:Len/binary, ~s/binary>> = ~s,~n",
                               [Rest2Var, RestVar])),
              indent(Indent, f("~s = unicode:characters_to_list("
                               "Utf8,unicode),~n",
                               [FValueVar]))],
             Rest2Var};
        bytes ->
            {[indent(Indent, f("Len = ~s,~n", [BValueExpr])),
              mk_unpack_bytes(Indent, FValueVar, RestVar, Rest2Var, Opts)],
             Rest2Var};
        {msg,Msg2Name} ->
            {[indent(Indent, f("Len = ~s,~n", [BValueExpr])),
              indent(Indent, f("<<MsgBytes:Len/binary, ~s/binary>> = ~s,~n",
                               [Rest2Var, RestVar])),
              indent(Indent, f("~s = decode_msg(MsgBytes, ~p),~n",
                               [FValueVar, Msg2Name]))],
             Rest2Var}
    end.

mk_unpack_bytes(I, FValueVar, RestVar, Rest2Var, Opts) ->
    CompilerHasBinary = (catch binary:copy(<<1>>)) == <<1>>,
    Copy = case proplists:get_value(copy_bytes, Opts, auto) of
               auto when not CompilerHasBinary -> false;
               auto when CompilerHasBinary     -> true;
               true                            -> true;
               false                           -> false;
               N when is_integer(N)            -> N;
               N when is_float(N)              -> N
           end,
    if Copy == false ->
            indent(I, f("<<~s:Len/binary, ~s/binary>> = ~s,~n",
                        [FValueVar, Rest2Var, RestVar]));
       Copy == true ->
            [indent(I, f("<<Bytes:Len/binary, ~s/binary>> = ~s,~n",
                         [Rest2Var, RestVar])),
             indent(I, f("~s = binary:copy(Bytes),~n", [FValueVar]))];
       is_integer(Copy); is_float(Copy) ->
            I2 = I + length(FValueVar) + length(" = "),
            [indent(I, f("<<Bytes:Len/binary, ~s/binary>> = ~s,~n",
                         [Rest2Var, RestVar])),
             indent(I, f("~s = case binary:referenced_byte_size(Bytes) of~n",
                            [FValueVar])),
             indent(I2+4, f("LB when LB >= byte_size(Bytes) * ~w ->~n", [Copy])),
             indent(I2+4+4, f("binary:copy(Bytes);~n")),
             indent(I2+4, f("_ ->~n")),
             indent(I2+4+4, f("Bytes~n")),
             indent(I2, f("end,~n"))]
    end.

fmt_uint_to_int(SrcStr, ResultVar, NumBits) ->
    f("<<~s:~w/signed-native>> = <<(~s):~p/unsigned-native>>",
      [ResultVar, NumBits, SrcStr, NumBits]).

fmt_decode_zigzag(Indent, VarStr) ->
    [f(              "if ~s band 1 =:= 0 -> ~s bsr 1;~n", [VarStr, VarStr]),
     indent(Indent,f("   true -> -((~s + 1) bsr 1)~n", [VarStr])),
     indent(Indent,f("end"))].

format_uf32_field_decoder(MsgName, FieldDef) ->
    format_f_field_decoder(MsgName, 32, 'little', FieldDef).

format_sf32_field_decoder(MsgName, FieldDef) ->
    format_f_field_decoder(MsgName, 32, 'little-signed', FieldDef).

format_float_field_decoder(MsgName, FieldDef) ->
    format_f_field_decoder(MsgName, 32, 'little-float', FieldDef).

format_uf64_field_decoder(MsgName, FieldDef) ->
    format_f_field_decoder(MsgName, 64, 'little', FieldDef).

format_sf64_field_decoder(MsgName, FieldDef) ->
    format_f_field_decoder(MsgName, 64, 'little-signed', FieldDef).

format_double_field_decoder(MsgName, FieldDef) ->
    format_f_field_decoder(MsgName, 64, 'little-float', FieldDef).

format_f_field_decoder(MsgName, BitLen, BitType, #field{name=FName}) ->
    [f("~p(<<Value:~p/~s, Rest/binary>>, Msg) ->~n",
       [mk_fn(d_field_, MsgName, FName), BitLen, BitType]),
     f("    NewMsg = ~p(Value, Msg),~n", [mk_fn(add_field_, MsgName, FName)]),
     f("    ~p(Rest, 0, 0, NewMsg).~n",
       [mk_fn(d_read_field_def_, MsgName)])].

format_packed_field_seq_decoder(MsgName, #field{type=Type}=FieldDef, Opts) ->
    case Type of
        fixed32  -> format_dpacked_nonvi(MsgName, FieldDef, 32, 'little');
        sfixed32 -> format_dpacked_nonvi(MsgName, FieldDef, 32, 'little-signed');
        float    -> format_dpacked_nonvi(MsgName, FieldDef, 32, 'little-float');
        fixed64  -> format_dpacked_nonvi(MsgName, FieldDef, 64, 'little');
        sfixed64 -> format_dpacked_nonvi(MsgName, FieldDef, 64, 'little-signed');
        double   -> format_dpacked_nonvi(MsgName, FieldDef, 64, 'little-float');
        _        -> format_dpacked_vi(MsgName, FieldDef, Opts)
    end.

format_dpacked_nonvi(MsgName, #field{name=FName}, BitLen, BitType) ->
    FnName = mk_fn(d_packed_field_, MsgName, FName),
    [f("~p(<<Value:~p/~s, Rest/binary>>, AccSeq) ->~n",
       [FnName, BitLen, BitType]),
     f("    ~p(Rest, [Value | AccSeq]);~n", [FnName]),
     f("~p(<<>>, AccSeq) ->~n", [FnName]),
     f("    AccSeq.~n")].

format_dpacked_vi(MsgName, #field{name=FName, type=Type}, Opts) ->
    FnName = mk_fn(d_packed_field_, MsgName, FName),
    BValueExpr = "X bsl (N*7) + Acc",
    {FValueCode, RestVar} = mk_unpack_vi(4, "FValue", BValueExpr, Type, "Rest",
                                         Opts),
    [f("~p(<<1:1, X:7, Rest/binary>>, N, Acc, AccSeq) ->~n", [FnName]),
     f("    ~p(Rest, N+1, X bsl (N*7) + Acc, AccSeq);~n", [FnName]),
     f("~p(<<0:1, X:7, Rest/binary>>, N, Acc, AccSeq) ->~n", [FnName]),
     f("~s", [FValueCode]),
     f("    ~p(~s, 0, 0, [FValue | AccSeq]);~n", [FnName, RestVar]),
     f("~p(<<>>, 0, 0, AccSeq) ->~n", [FnName]),
     f("    AccSeq.~n~n")].

format_msg_decoder_reverse_toplevel(MsgName, MsgDef) ->
    MsgNameQLen = flength("~p", [MsgName]),
    FieldsToReverse = [F || F <- MsgDef, F#field.occurrence == repeated],
    if FieldsToReverse /= [] ->
            FieldMatchings =
                outdent_first(
                  string:join(
                    [indent(8+2+MsgNameQLen, f("~p=F~s", [FName, FName]))
                     || #field{name=FName} <- FieldsToReverse],
                    ",\n")),
            FieldReversings =
                outdent_first(
                  string:join(
                    [indent(8+2+MsgNameQLen, f("~p=lists:reverse(F~s)",
                                               [FName, FName]))
                     || #field{name=FName} <- FieldsToReverse],
                    ",\n")),
            [f("~p(~n", [mk_fn(d_reverse_toplevel_fields_, MsgName)]),
             indent(8, f("#~p{~s}=Msg) ->~n", [MsgName, FieldMatchings])),
             indent(4, f("Msg#~p{~s}.~n~n", [MsgName, FieldReversings]))];
       true ->
            [f("~p(Msg) ->~n", [mk_fn(d_reverse_toplevel_fields_, MsgName)]),
             indent(4, f("Msg.~n~n"))]
    end.

format_field_adders(MsgName, MsgDef) ->
    [case classify_field_merge_action(FieldDef) of
        msgmerge  -> format_field_msgmerge_adder(MsgName, FieldDef);
        overwrite -> format_field_overwrite_adder(MsgName, FieldDef);
        seqadd    -> format_field_seqappend_adder(MsgName, FieldDef)
     end
     || FieldDef <- MsgDef].

format_field_overwrite_adder(MsgName, #field{name=FName}) ->
    FAdderFn = mk_fn(add_field_, MsgName, FName),
    [f("~p(NewValue, Msg) ->~n", [FAdderFn]),
     f("    Msg#~p{~p = NewValue}.~n~n", [MsgName, FName])].

format_field_seqappend_adder(MsgName, #field{name=FName}) ->
    FAdderFn = mk_fn(add_field_, MsgName, FName),
    [f("~p(NewValue, #~p{~p=PrevElems}=Msg) ->~n", [FAdderFn, MsgName, FName]),
     f("    Msg#~p{~p = [NewValue | PrevElems]}.~n~n", [MsgName, FName])].

format_field_msgmerge_adder(MsgName, #field{name=FName, type={msg,FMsgName}}) ->
    FAdderFn = mk_fn(add_field_, MsgName, FName),
    MergeFn = mk_fn(merge_msg_, FMsgName),
    [f("~p(NewValue, #~p{~p=undefined}=Msg) ->~n", [FAdderFn, MsgName, FName]),
     f("    Msg#~p{~p = NewValue};~n", [MsgName, FName]),
     f("~p(NewValue, #~p{~p=PrevValue}=Msg) ->~n", [FAdderFn, MsgName, FName]),
     f("    Msg#~p{~p = ~p(PrevValue, NewValue)}.~n~n",
       [MsgName, FName, MergeFn])].

classify_field_merge_action(FieldDef) ->
    case FieldDef of
        #field{occurrence=required, type={msg, _}} -> msgmerge;
        #field{occurrence=optional, type={msg, _}} -> msgmerge;
        #field{occurrence = required}              -> overwrite;
        #field{occurrence = optional}              -> overwrite;
        #field{occurrence = repeated}              -> seqadd
    end.


format_msg_merge_code(Defs) ->
    MsgNames = [MsgName || {{msg, MsgName}, _MsgDef} <- Defs],
    [format_merge_msgs_top_level(MsgNames),
     [format_msg_merger(MsgName, MsgDef)
      || {{msg, MsgName}, MsgDef} <- Defs]].

format_merge_msgs_top_level([]) ->
    [f("merge_msgs(_Prev, New) ->~n"),
     f("    New.~n"),
     f("~n")];
format_merge_msgs_top_level(MsgNames) ->
    [f("merge_msgs(Prev, New) when element(1, Prev) == element(1, New) ->~n"),
     f("   case Prev of~n"),
     f("       ~s~n", [format_merger_top_level_cases(MsgNames)]),
     f("   end.~n"),
     f("~n")].

format_merger_top_level_cases(MsgNames) ->
    string:join([f("#~p{} -> ~p(Prev, New)", [MName, mk_fn(merge_msg_, MName)])
                 || MName <- MsgNames],
                ";\n        ").


format_msg_merger(MsgName, []) ->
    MergeFn = mk_fn(merge_msg_, MsgName),
    [f("~p(_Prev, New) ->~n", [MergeFn]),
     f("    New.~n~n")];
format_msg_merger(MsgName, MsgDef) ->
    MergeFn = mk_fn(merge_msg_, MsgName),
    FInfos = [{classify_field_merge_action(Field), Field} || Field <- MsgDef],
    ToOverwrite = [Field || {overwrite, Field} <- FInfos],
    ToMsgMerge  = [Field || {msgmerge, Field} <- FInfos],
    ToSeqAdd    = [Field || {seqadd, Field} <- FInfos],

    MatchIndent = flength("~p(#~p{", [MergeFn, MsgName]),
    MatchCommaSep = f(",~n~s", [indent(MatchIndent, "")]),

    PFieldMatchings = string:join([f("~p=PF~s", [FName, FName])
                                   || #field{name=FName} <- MsgDef],
                                  MatchCommaSep),
    NFieldMatchings = string:join([f("~p=NF~s", [FName, FName])
                                   || #field{name=FName} <- MsgDef],
                                  MatchCommaSep),

    %% FIXME: reverse order?? ie: do NF ++ PF??
    %%        we'll reverse _top-level_ seq fields lastly when decoding
    UpdateIndent = flength("    #~p(", [MsgName]),
    Overwritings = [begin
                        FUpdateIndent = UpdateIndent + flength("~p = ",[FName]),
                        [f("~p = if NF~s == undefined -> PF~s;~n",
                           [FName, FName, FName]),
                         indent(FUpdateIndent + 3, f("true -> NF~s~n", [FName])),
                         indent(FUpdateIndent, f("end"))]
                    end
                    || #field{name=FName} <- ToOverwrite],
    SeqAddings = [f("~p = PF~s ++ NF~s", [FName, FName, FName])
                  || #field{name=FName} <- ToSeqAdd],
    MsgMergings = [f("~p = ~p(PF~s, NF~s)", [FName, mk_fn(merge_msg_, FMsgName),
                                             FName, FName])
                   || #field{name=FName, type={msg,FMsgName}} <- ToMsgMerge],
    UpdateCommaSep = f(",~n~s", [indent(UpdateIndent, "")]),
    FieldUpdatings = string:join(Overwritings ++ SeqAddings ++ MsgMergings,
                                 UpdateCommaSep),
    FnIndent = flength("~p(", [MergeFn]),
    [f("~p(Prev, undefined) -> Prev;~n", [MergeFn]),
     f("~p(undefined, New) -> New;~n", [MergeFn]),
     f("~p(#~p{~s},~n", [MergeFn, MsgName, PFieldMatchings]),
     indent(FnIndent, f("#~p{~s}) ->~n", [MsgName, NFieldMatchings])),
     f("    #~p{~s}.~n~n", [MsgName, FieldUpdatings])].

format_field_skippers(MsgName) ->
    [format_varint_skipper(MsgName),
     format_length_delimited_skipper(MsgName),
     format_32bit_skipper(MsgName),
     format_64bit_skipper(MsgName)].

format_varint_skipper(MsgName) ->
    SkipFn = mk_fn(skip_varint_, MsgName),
    [f("~p(<<0:1, _:7, Rest/binary>>, Msg) ->~n", [SkipFn]),
     f("    ~p(Rest, 0, 0, Msg);~n", [mk_fn(d_read_field_def_, MsgName)]),
     f("~p(<<1:1, _:7, Rest/binary>>, Msg) ->~n", [SkipFn]),
     f("    ~p(Rest, Msg).~n~n", [SkipFn])].

format_length_delimited_skipper(MsgName) ->
    SkipFn = mk_fn(skip_length_delimited_, MsgName),
    [f("~p(<<1:1, X:7, Rest/binary>>, N, Acc, Msg) ->~n", [SkipFn]),
     f("    ~p(Rest, N+1, X bsl (N*7) + Acc, Msg);~n", [SkipFn]),
     f("~p(<<0:1, X:7, Rest/binary>>, N, Acc, Msg) ->~n", [SkipFn]),
     f("    Length = X bsl (N*7) + Acc,~n"),
     f("    <<_:Length/binary, Rest2/binary>> = Rest,~n"),
     f("    ~p(Rest2, 0, 0, Msg).~n~n", [mk_fn(d_read_field_def_, MsgName)])].

format_32bit_skipper(MsgName) -> format_bit_skipper(MsgName, 32).

format_64bit_skipper(MsgName) -> format_bit_skipper(MsgName, 64).

format_bit_skipper(MsgName, BitLen) ->
    SkipFn = mk_fn(skip_, BitLen, MsgName),
    [f("~p(<<_:~w, Rest/binary>>, Msg) ->~n", [SkipFn, BitLen]),
     f("    ~p(Rest, 0, 0, Msg).~n~n",  [mk_fn(d_read_field_def_, MsgName)])].

%% -- verifiers -----------------------------------------------------

format_verifier_topcase(Indent, Defs, MsgVar) ->
    IndStr = indent(Indent+4, ""),
    ElseCase = "_ -> mk_type_error(not_a_known_message, Msg, [])",
    ["case ", MsgVar, " of\n",
     IndStr,
     string:join([f("#~p{} -> ~p(~s, [])",
                    [MsgName, mk_fn(v_msg_, MsgName), MsgVar])
                  || {{msg, MsgName}, _MsgDef} <- Defs] ++ [ElseCase],
                 ";\n"++IndStr),
     "\n",
     indent(Indent, "end")].

format_verifiers(Defs, _Opts) ->
    [format_msg_verifiers(Defs),
     format_enum_verifiers(Defs),
     format_type_verifiers(),
     format_verifier_auxiliaries()
    ].

format_msg_verifiers(Defs) ->
    [format_msg_verifier(MsgName, MsgDef) || {{msg,MsgName}, MsgDef} <- Defs].

format_msg_verifier(MsgName, []) ->
    FnName = mk_fn(v_msg_, MsgName),
    [f("~p(#~p{}, _Path) ->~n", [FnName, MsgName]),
     f("    ok;~n"),
     f("~p(X, Path) ->~n", [FnName]),
     f("    mk_type_error({expected_msg,~p}, X, Path).~n", [MsgName]),
     f("~n")];
format_msg_verifier(MsgName, MsgDef) ->
    FnName = mk_fn(v_msg_, MsgName),
    MatchIndent = flength("~p(#~p{", [FnName, MsgName]),
    MatchCommaSep = f(",~n~s", [indent(MatchIndent, "")]),
    FieldMatchings = string:join([f("~p=F~s", [FName, FName])
                                  || #field{name=FName} <- MsgDef],
                                 MatchCommaSep),
    [f("~p(#~p{~s}, Path) ->~n", [FnName, MsgName, FieldMatchings]),
     [begin
          FVerifierFn = case Type of
                            {msg,FMsgName}  -> mk_fn(v_msg_, FMsgName);
                            {enum,EnumName} -> mk_fn(v_enum_, EnumName);
                            Type            -> mk_fn(v_type_, Type)
                        end,
          ["    ",
           case Occurrence of
               required ->
                   %% FIXME: check especially for `undefined'
                   %% and if found, error out with required_field_not_set
                   %% specifying expected type
                   f("~p(F~s, [~p | Path])", [FVerifierFn, FName, FName]);
               repeated ->
                   %% FIXME: verify that the field is a list!
                   %% when verifying elements, include the faulty
                   %% element's index (what about a finite atom space?)
                   f("[~p(Elem, [~p | Path]) || Elem <- F~s]",
                     [FVerifierFn, FName, FName]);
               optional ->
                   f("[~p(F~s, [~p | Path]) || F~s /= undefined]",
                     [FVerifierFn, FName, FName, FName])
           end,
           f(",~n")]
      end
      || #field{name=FName, type=Type, occurrence=Occurrence} <- MsgDef],
     f("    ok;~n"),
     f("~p(X, Path) ->~n", [FnName]),
     f("    mk_type_error({expected_msg,~p}, X, Path).~n", [MsgName]),
     f("~n")].

format_enum_verifiers(Defs) ->
    [format_enum_verifier(EnumName, Def) || {{enum,EnumName}, Def} <- Defs].

format_enum_verifier(EnumName, EnumMembers) ->
    FnName = mk_fn(v_enum_, EnumName),
    [[f("~p(~p, _) -> ok;~n", [FnName, EnumSym]) || {EnumSym,_} <- EnumMembers],
     f("~p(X, Path) ->~n", [FnName]),
     f("    mk_type_error({invalid_enum,~p}, X, Path).~n", [EnumName]),
     f("~n")].

format_type_verifiers() ->
    [format_int_verifier(sint32, signed, 32),
     format_int_verifier(sint64, signed, 64),
     format_int_verifier(int32,  signed, 32),
     format_int_verifier(int64,  signed, 64),
     format_int_verifier(uint32, unsigned, 32),
     format_int_verifier(uint64, unsigned, 64),
     format_bool_verifier(),
     format_int_verifier(fixed32, unsigned, 32),
     format_int_verifier(fixed64, unsigned, 64),
     format_int_verifier(sfixed32,signed, 32),
     format_int_verifier(sfixed64,signed, 64),
     format_float_verifier(float),
     format_float_verifier(double),
     format_string_verifier(),
     format_bytes_verifier()].

format_int_verifier(IntType, Signedness, NumBits) ->
    FnName = mk_fn(v_type_, IntType),
    Min = case Signedness of
              unsigned -> 0;
              signed   -> -(1 bsl (NumBits-1))
          end,
    Max = case Signedness of
              unsigned -> 1 bsl NumBits - 1;
              signed   -> 1 bsl (NumBits-1) - 1
          end,
    [f("~p(N, _P) when ~w =< N, N =< ~w ->~n", [FnName, Min, Max]),
     f("    ok;~n"),
     f("~p(N, Path) when is_integer(N) ->~n", [FnName]),
     f("    mk_type_error({value_out_of_range, ~p, ~p, ~w}, N, Path);~n",
       [IntType, Signedness, NumBits]),
     f("~p(X, Path) ->~n", [FnName]),
     f("    mk_type_error({bad_integer, ~p, ~p, ~w}, X, Path).~n",
       [IntType, Signedness, NumBits]),
     f("~n")].

format_bool_verifier() ->
    FnName = mk_fn(v_type_, bool),
    [f("~p(false, _Path) -> ok;~n", [FnName]),
     f("~p(true, _Path)  -> ok;~n", [FnName]),
     f("~p(X, Path)  -> mk_type_error(bad_boolean_value, X, Path).~n",
       [FnName]),
     f("~n")].

format_float_verifier(FlType) ->
    FnName = mk_fn(v_type_, FlType),
    [f("~p(N, _Path) when is_float(N) -> ok;~n", [FnName]),
     %% It seems a float for the corresponding integer value is
     %% indeed packed when doing <<Integer:32/little-float>>.
     %% So let verify accept integers too.
     %% When such a value is unpacked, we get a float.
     f("~p(N, _Path) when is_integer(N) -> ok;~n", [FnName]),
     f("~p(X, Path)  -> mk_type_error(bad_~w_value, X, Path).~n",
       [FnName, FlType]),
     f("~n")].

format_string_verifier() ->
    FnName = mk_fn(v_type_, string),
    [f("~p(S, Path) when is_list(S) ->~n", [FnName]),
     f("    try unicode:characters_to_binary(S),~n"),
     f("        ok~n"),
     f("    catch error:badarg ->~n"),
     f("        mk_type_error(bad_unicode_string, S, Path)~n"),
     f("    end;~n"),
     f("~p(X, Path) ->~n", [FnName]),
     f("    mk_type_error(bad_unicode_string, X, Path).~n"),
     f("~n")].

format_bytes_verifier() ->
    FnName = mk_fn(v_type_, bytes),
    [f("~p(B, _Path) when is_binary(B) ->~n", [FnName]),
     f("    ok;~n"),
     f("~p(X, Path) ->~n", [FnName]),
     f("    mk_type_error(bad_binary_value, X, Path).~n"),
     f("~n")].

format_verifier_auxiliaries() ->
    [f("mk_type_error(Error, ValueSeen, Path) ->~n"),
     f("    Path2 = prettify_path(Path),~n"),
     f("    erlang:error({gpb_type_error,~n"),
     f("                  {Error, [{value, ValueSeen},{path, Path2}]}}).~n"),
     f("~n"),
     f("prettify_path([]) ->~n"),
     f("    top_level;~n"),
     f("prettify_path(PathR) ->~n"),
     f("    list_to_atom(~n"),
     f("        string:join([atom_to_list(E) || E <- lists:reverse(PathR)],~n"),
     f("                    \".\")).~n"),
     f("~n")].

%% -- message defs -----------------------------------------------------

format_msgs_and_enums(Indent, Defs) ->
    Enums = [Item || {{enum, _}, _}=Item <- Defs],
    Msgs  = [Item || {{msg, _}, _}=Item <- Defs],
    [format_enums(Indent, Enums),
     if Enums /= [], Msgs /= [] -> ",\n";
        true                    -> ""
     end,
     format_msgs(Indent, Msgs)].

format_enums(Indent, Enums) ->
    string:join([f("~s~p", [indent(Indent,""), Enum]) || Enum <- Enums],
                ",\n").

format_msgs(Indent, Msgs) ->
    string:join([indent(Indent,
                        f("{~w,~n~s[~s]}",
                          [{msg,Msg},
                           indent(Indent+1, ""),
                           outdent_first(format_efields(Indent+2, Fields))]))
                 || {{msg,Msg},Fields} <- Msgs],
                ",\n").

format_efields(Indent, Fields) ->
    string:join([format_efield(Indent, Field) || Field <- Fields],
                ",\n").

format_efield(I, #field{name=N, fnum=F, rnum=R, type=T,
                        occurrence=Occurrence, opts=Opts}) ->

    [indent(I, f("#field{name=~w, fnum=~w, rnum=~w, type=~w,~n", [N,F,R,T])),
     indent(I, f("       occurrence=~w,~n", [Occurrence])),
     indent(I, f("       opts=~p}", [Opts]))].

%% -- hrl -----------------------------------------------------

format_hrl(Mod, Defs, Opts) ->
    iolist_to_binary(
      [f("-ifndef(~p).~n", [Mod]),
       f("-define(~p, true).~n", [Mod]),
       "\n",
       string:join([format_msg_record(Msg, Fields, Opts, Defs)
                    || {{msg,Msg},Fields} <- Defs],
                   "\n"),
       "\n",
       f("-endif.~n")]).

format_msg_record(Msg, Fields, Opts, Defs) ->
    [f("-record(~p,~n", [Msg]),
     f("        {"),
     outdent_first(format_hfields(8+1, Fields, Opts, Defs)),
     "\n",
     f("        }).~n")].

format_hfields(Indent, Fields, CompileOpts, Defs) ->
    TypeSpecs = get_type_specs_by_opts(CompileOpts),
    string:join(
      lists:map(
        fun({I, #field{name=Name, fnum=FNum, opts=FOpts}=Field}) ->
                DefaultStr = case proplists:get_value(default, FOpts, '$no') of
                                 '$no'   -> "";
                                 Default -> f(" = ~p", [Default])
                             end,
                TypeStr = f("~s", [type_to_typestr(Field, Defs)]),
                CommaSep = if I < length(Fields) -> ",";
                              true               -> "" %% last entry
                           end,
                FieldTxt1 = indent(Indent, f("~w~s", [Name, DefaultStr])),
                FieldTxt2 = if TypeSpecs ->
                                    LineUp = lineup(iolist_size(FieldTxt1), 32),
                                    f("~s~s:: ~s~s", [FieldTxt1, LineUp,
                                                      TypeStr, CommaSep]);
                               not TypeSpecs ->
                                    f("~s~s", [FieldTxt1, CommaSep])
                            end,
                LineUpCol2 = if TypeSpecs -> 52;
                               not TypeSpecs -> 40
                            end,
                LineUpStr2 = lineup(iolist_size(FieldTxt2), LineUpCol2),
                TypeComment = type_to_comment(Field, TypeSpecs),
                f("~s~s% = ~w~s~s",
                  [FieldTxt2, LineUpStr2, FNum,
                   [", " || TypeComment /= ""], TypeComment])
        end,
        index_seq(Fields)),
      "\n").

get_type_specs_by_opts(Opts) ->
    Default = false,
    proplists:get_value(type_specs, Opts, Default).

type_to_typestr(#field{type=Type, occurrence=Occurrence}, Defs) ->
    case Occurrence of
        required -> type_to_typestr_2(Type, Defs);
        repeated -> "[" ++ type_to_typestr_2(Type, Defs) ++ "]";
        optional -> type_to_typestr_2(Type, Defs) ++ " | 'undefined'"
    end.

type_to_typestr_2(sint32, _Defs)   -> "integer()";
type_to_typestr_2(sint64, _Defs)   -> "integer()";
type_to_typestr_2(int32, _Defs)    -> "integer()";
type_to_typestr_2(int64, _Defs)    -> "integer()";
type_to_typestr_2(uint32, _Defs)   -> "non_neg_integer()";
type_to_typestr_2(uint64, _Defs)   -> "non_neg_integer()";
type_to_typestr_2(bool, _Defs)     -> "boolean()";
type_to_typestr_2(fixed32, _Defs)  -> "non_neg_integer()";
type_to_typestr_2(fixed64, _Defs)  -> "non_neg_integer()";
type_to_typestr_2(sfixed32, _Defs) -> "integer()";
type_to_typestr_2(sfixed64, _Defs) -> "integer()";
type_to_typestr_2(float, _Defs)    -> "float()";
type_to_typestr_2(double, _Defs)   -> "float()";
type_to_typestr_2(string, _Defs)   -> "string()";
type_to_typestr_2(bytes, _Defs)    -> "binary()";
type_to_typestr_2({enum,E}, Defs)  -> enum_typestr(E, Defs);
type_to_typestr_2({msg,M}, _DEfs)  -> f("#~p{}", [M]).

enum_typestr(E, Defs) ->
    {value, {{enum,E}, Enumerations}} = lists:keysearch({enum,E}, 1, Defs),
    string:join(["'"++atom_to_list(EName)++"'" || {EName, _} <- Enumerations],
                " | ").

type_to_comment(#field{type=Type}, true=_TypeSpec) ->
    case Type of
        sint32   -> "32 bits";
        sint64   -> "32 bits";
        int32    -> "32 bits";
        int64    -> "32 bits";
        uint32   -> "32 bits";
        uint64   -> "32 bits";
        fixed32  -> "32 bits";
        fixed64  -> "32 bits";
        sfixed32 -> "32 bits";
        sfixed64 -> "32 bits";
        {enum,E} -> "enum "++atom_to_list(E);
        _        -> ""
    end;
type_to_comment(#field{type=Type, occurrence=Occurrence}, false=_TypeSpec) ->
    case Occurrence of
        required -> f("~w", [Type]);
        repeated -> "[" ++ f("~w", [Type]) ++ "]";
        optional -> f("~w (optional)", [Type])
    end.

lineup(CurrentCol, TargetCol) when CurrentCol < TargetCol ->
    lists:duplicate(TargetCol - CurrentCol, $\s);
lineup(_, _) ->
    " ".

indent(Indent, Str) ->
    lists:duplicate(Indent, $\s) ++ Str.

outdent_first(IoList) ->
    lists:dropwhile(fun(C) -> C == $\s end,
                    binary_to_list(iolist_to_binary(IoList))).

mk_fn(Prefix, Suffix) ->
    list_to_atom(lists:concat([Prefix, Suffix])).

mk_fn(Prefix, Middlefix, Suffix) when is_integer(Middlefix) ->
    mk_fn(Prefix, list_to_atom(integer_to_list(Middlefix)), Suffix);
mk_fn(Prefix, Middlefix, Suffix) ->
    list_to_atom(lists:concat([Prefix, Middlefix, "_", Suffix])).

%% -- compile to memory -----------------------------------------------------

compile_to_binary(MsgDefs, ErlCode, Opts) ->
    {ok, Toks, _EndLine} = erl_scan:string(flatten_iolist(ErlCode)),
    FormToks = split_toks_at_dot(Toks),
    Forms = lists:map(fun(Ts) ->
                              {ok, Form} = erl_parse:parse_form(Ts),
                              Form
                      end,
                      FormToks),
    {AttrForms, CodeForms} = split_forms_at_first_code(Forms),
    FieldDef = field_record_to_attr_form(),
    MsgRecordForms = msgdefs_to_record_attrs(MsgDefs),
    COs = [verbose, return_errors, return_warnings | Opts],
    compile:forms(AttrForms ++ [FieldDef] ++ MsgRecordForms ++ CodeForms, COs).

split_toks_at_dot(AllToks) ->
    case lists:splitwith(fun is_no_dot/1, AllToks) of
        {Toks, [{dot,_}=Dot]}        -> [Toks ++ [Dot]];
        {Toks, [{dot,_}=Dot | Rest]} -> [Toks ++ [Dot] | split_toks_at_dot(Rest)]
        end.

is_no_dot({dot,_}) -> false;
is_no_dot(_)       -> true.

split_forms_at_first_code(Forms) -> split_forms_at_first_code_2(Forms, []).

split_forms_at_first_code_2([{attribute,_,_,_}=Attr | Rest], Acc) ->
    split_forms_at_first_code_2(Rest, [Attr | Acc]);
split_forms_at_first_code_2([{function, _, _Name, _, _Clauses}|_]=Code, Acc) ->
    {lists:reverse(Acc), Code}.

field_record_to_attr_form() ->
    record_to_attr(field, record_info(fields, field)).

msgdefs_to_record_attrs(Defs) ->
    [record_to_attr(MsgName, lists:map(fun gpb_field_to_record_field/1, Fields))
     || {{msg, MsgName}, Fields} <- Defs].

record_to_attr(RecordName, Fields) ->
    {attribute, 0, record,
     {RecordName,
      [case F of
           {FName, Default} ->
               {record_field, 0, {atom, 0, FName}, erl_parse:abstract(Default)};
           {FName} ->
               {record_field, 0, {atom, 0, FName}};
           FName when is_atom(FName) ->
               {record_field, 0, {atom, 0, FName}}
       end
       || F <- Fields]}}.

gpb_field_to_record_field(#field{name=FName, opts=Opts}) ->
    case proplists:get_value(default, Opts) of
        undefined -> {FName};
        Default   -> {FName, Default}
    end.

%% -- internal utilities -----------------------------------------------------

is_packed(#field{opts=Opts}) ->
    lists:member(packed, Opts).

index_seq([]) -> [];
index_seq(L)  -> lists:zip(lists:seq(1,length(L)), L).

f(F)   -> f(F,[]).
f(F,A) -> io_lib:format(F,A).

%flength(F) -> iolist_size(f(F)).
flength(F, A) -> iolist_size(f(F, A)).

flatten_iolist(IoList) ->
    binary_to_list(iolist_to_binary(IoList)).

file_read_file(FileName, Opts) ->
    file_op(read_file, [FileName], Opts).

file_read_file_info(FileName, Opts) ->
    file_op(read_file_info, [FileName], Opts).

file_write_file(FileName, Bin, Opts) ->
    file_op(write_file, [FileName, Bin], Opts).

file_op(Fn, Args, Opts) ->
    FileOp = proplists:get_value(file_op, Opts, fun use_the_file_module/2),
    FileOp(Fn, Args).

use_the_file_module(Fn, Args) ->
    apply(file, Fn, Args).

possibly_probe_defs(Defs, Opts) ->
    case proplists:get_value(probe_defs, Opts, '$no') of
        '$no' -> ok;
        Fn    -> Fn(Defs)
    end.
