%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ Management Plugin.
%%
%%   The Initial Developer of the Original Code is VMware, Inc.
%%   Copyright (c) 2007-2010 VMware, Inc.  All rights reserved.
-module(rabbit_mgmt_app).

-behaviour(application).
-export([start/2, stop/1]).

-include_lib("amqp_client/include/amqp_client.hrl").

%% Dummy supervisor - see Ulf Wiger's comment at
%% http://erlang.2086793.n4.nabble.com/initializing-library-applications-without-processes-td2094473.html

%% All of our actual server processes are supervised by rabbit_mgmt_sup, which
%% is started by a rabbit_boot_step (since it needs to start up before queue
%% recovery or the network being up, so it can't be part of our application).
%%
%% However, we still need an application behaviour since we need to depend on
%% the rabbit_mochiweb application and call into it once it's running. Since
%% the application behaviour needs a tree of processes to supervise, this is
%% it...
-behaviour(supervisor).
-export([init/1]).

-define(PREFIX, "api").
-define(UI_PREFIX, "mgmt").
-define(CLI_PREFIX, "cli").
-define(CONTEXT, mgmt).
-ifdef(trace).
-define(SETUP_WM_TRACE, true).
-else.
-define(SETUP_WM_TRACE, false).
-endif.

%% Make sure our database is hooked in *before* listening on the network or
%% recovering queues (i.e. so there can't be any events fired before it starts).
-rabbit_boot_step({rabbit_mgmt_database,
                   [{description, "management statistics database"},
                    {mfa,         {rabbit_sup, start_child,
                                   [rabbit_mgmt_global_sup]}},
                    {requires,    rabbit_event},
                    {enables,     queue_sup_queue_recovery}]}).

start(_Type, _StartArgs) ->
    log_startup(),
    setup_wm_logging(),
    register_contexts(),
    case ?SETUP_WM_TRACE of
        true -> setup_wm_trace_app();
        _    -> ok
    end,
    supervisor:start_link({local,?MODULE},?MODULE,[]).

stop(_State) ->
    ok.

register_contexts() ->
    Dispatch = rabbit_mgmt_dispatcher:dispatcher(),
    rabbit_mochiweb:register_authenticated_static_context(
      mgmt, ?UI_PREFIX, ?MODULE, "priv/www", "Management: Web UI",
      fun (U, P) ->
              case rabbit_access_control:check_user_pass_login(U, P) of
                  {ok, _} -> true;
                  _       -> false
              end
      end),
    rabbit_mochiweb:register_context_handler(mgmt_api, ?PREFIX,
                                             rabbit_webmachine:makeloop(
                                               Dispatch),
                                             "Management: HTTP API"),
    rabbit_mochiweb:register_static_context(mgmt_cli, ?CLI_PREFIX, ?MODULE,
                                            "priv/www-cli",
                                            "Management: Command Line Tool").
setup_wm_logging() ->
    {ok, LogDir} = application:get_env(rabbit_management, http_log_dir),
    case LogDir of
        none ->
            rabbit_webmachine:setup(none);
        _ ->
            rabbit_webmachine:setup(webmachine_logger),
            webmachine_sup:start_logger(LogDir)
    end.

%% This doesn't *entirely* seem to work. It fails to load a non-existent
%% image which seems to partly break it, but some stuff is usable.
setup_wm_trace_app() ->
    Loop = rabbit_webmachine:makeloop([{["wmtrace", '*'],
                                       wmtrace_resource,
                                       [{trace_dir, "/tmp"}]}]),
    rabbit_mochiweb:register_static_context(
      ?CONTEXT, "wmtrace/static", ?MODULE,
      "deps/webmachine/webmachine/priv/trace", none),
    rabbit_mochiweb:register_context_handler(?CONTEXT,
                                             "wmtrace", Loop,
                                             "Webmachine tracer").
log_startup() ->
    {ok, Hostname} = inet:gethostname(),
    URLPrefix = "http://" ++ Hostname ++ ":" ++ integer_to_list(get_port()),
    rabbit_log:info(
      "Management plugin started.~n"
      ++ "HTTP API:       ~s/~s/~n"
      ++ "Management UI:  ~s/~s/~n",
      [URLPrefix, ?PREFIX, URLPrefix, ?UI_PREFIX]).

get_port() ->
    case rabbit_mochiweb:context_listener(?CONTEXT) of
        undefined ->
            exit(rabbit_mochiweb_listener_not_configured);
        {_Instance, Options} ->
            proplists:get_value(port, Options)
    end.

%%----------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one,3,10},[]}}.
