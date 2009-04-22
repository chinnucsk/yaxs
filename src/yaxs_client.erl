%%%-------------------------------------------------------------------
%%% File    : yaxs_client.erl
%%% Author  : Andreas Stenius <kaos@astekk.se>
%%% Description : 
%%%
%%% Created : 21 Apr 2009 by Andreas Stenius <kaos@astekk.se>
%%%-------------------------------------------------------------------
-module(yaxs_client).

-behaviour(gen_fsm).

%% API
-export([start_link/0, set_socket/2, sax_event/2]).

%% gen_fsm callbacks
-export([
	 init/1, 
	 handle_event/3,
	 handle_sync_event/4, 
	 handle_info/3, 
	 terminate/3, 
	 code_change/4
	]).

%% FSM states
-export([
	 wait_for_socket/2,
	 wait_for_stream/2,
	 streaming/2
	]).

-define(SERVER, ?MODULE).

-include("yaxs.hrl").

-record(state, {
	  sax,
	  client = #yaxs_client{}
	 }).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> ok,Pid} | ignore | {error,Error}
%% Description:Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this function
%% does not return until Module:init/1 has returned.  
%%--------------------------------------------------------------------
start_link() ->
    gen_fsm:start_link(?MODULE, [], []).

set_socket(Pid, Sock) ->
    gen_fsm:send_event(Pid, {socket_ready, Sock}).

sax_event(Pid, Event) ->
    gen_fsm:send_event(Pid, {sax, Event}).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, StateName, State} |
%%                         {ok, StateName, State, Timeout} |
%%                         ignore                              |
%%                         {stop, StopReason}                   
%% Description:Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/3,4, this function is called by the new process to 
%% initialize. 
%%--------------------------------------------------------------------
init([]) ->
    {ok, wait_for_socket, #state{ client=#yaxs_client{ pid=self() }}}.

%%--------------------------------------------------------------------
%% Function: 
%% state_name(Event, State) -> {next_state, NextStateName, NextState}|
%%                             {next_state, NextStateName, 
%%                                NextState, Timeout} |
%%                             {stop, Reason, NewState}
%% Description:There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same name as
%% the current state name StateName is called to handle the event. It is also 
%% called if a timeout occurs. 
%%--------------------------------------------------------------------
wait_for_socket({socket_ready, Sock}, #state{ client=Client} = State) ->
    inet:setopts(Sock, [{active, once}]),
    {ok, {IP, Port}} = inet:peername(Sock),
    Addr = io_lib:format("~s:~p", [inet_parse:ntoa(IP), Port]),
    error_logger:info_msg("Client connected: ~s", [Addr]),
    
    {next_state, wait_for_stream,
     State#state{
       client = Client#yaxs_client{
		  sock = Sock,
		  addr = Addr
		 }
      }
    }.

wait_for_stream({sax, {open_stream, _Attrs}=Event}, State) ->
    yaxs_event:publish(Event, State#state.client),
    {next_state, streaming, State}.

streaming({sax, {open_stream, _Attrs}}, State) ->
    {next_state, streaming, State};

streaming({sax, close}, State) ->
    {stop, normal, State}.


%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, From, State) -> {next_state, NextStateName, NextState} |
%%                                   {next_state, NextStateName, 
%%                                     NextState, Timeout} |
%%                                   {reply, Reply, NextStateName, NextState}|
%%                                   {reply, Reply, NextStateName, 
%%                                    NextState, Timeout} |
%%                                   {stop, Reason, NewState}|
%%                                   {stop, Reason, Reply, NewState}
%% Description: There should be one instance of this function for each
%% possible state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/2,3, the instance of this function with the same
%% name as the current state name StateName is called to handle the event.
%%--------------------------------------------------------------------
%% state_name(_Event, _From, State) ->
%%     Reply = ok,
%%     {reply, Reply, state_name, State}.

%%--------------------------------------------------------------------
%% Function: 
%% handle_event(Event, StateName, State) -> {next_state, NextStateName, 
%%						  NextState} |
%%                                          {next_state, NextStateName, 
%%					          NextState, Timeout} |
%%                                          {stop, Reason, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: 
%% handle_sync_event(Event, From, StateName, 
%%                   State) -> {next_state, NextStateName, NextState} |
%%                             {next_state, NextStateName, NextState, 
%%                              Timeout} |
%%                             {reply, Reply, NextStateName, NextState}|
%%                             {reply, Reply, NextStateName, NextState, 
%%                              Timeout} |
%%                             {stop, Reason, NewState} |
%%                             {stop, Reason, Reply, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/2,3, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% Function: 
%% handle_info(Info,StateName,State)-> {next_state, NextStateName, NextState}|
%%                                     {next_state, NextStateName, NextState, 
%%                                       Timeout} |
%%                                     {stop, Reason, NewState}
%% Description: This function is called by a gen_fsm when it receives any
%% other message than a synchronous or asynchronous event
%% (or a system message).
%%--------------------------------------------------------------------
handle_info({tcp, Sock, Data}, StateName, State) ->
    inet:setopts(Sock, [{active, once}]),
    try
	{next_state, StateName, 
	 State#state{ sax =
		     yaxs_sax:parse(Data, 
				    fun sax_event/2,
				    State#state.sax)
		     }
	}
    catch
	throw:Error ->
	    {stop, {sax_error, Error}, State}
    end;

handle_info({tcp_closed, _Sock}, _StateName, State) ->
    error_logger:info_msg("Client disconnected: ~s~n", [(State#state.client)#yaxs_client.addr]),
    {stop, normal, #state{}}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, StateName, State) -> void()
%% Description:This function is called by a gen_fsm when it is about
%% to terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, State) ->
    error_logger:info_msg("Terminate yaxs_client in state ~p.~nReason: ~p~n", 
			  [_StateName, _Reason]),
    case (State#state.client)#yaxs_client.sock of
	undefined ->
	    ok;
	Sock ->
	    catch gen_tcp:close(Sock),
	    ok
    end.

%%--------------------------------------------------------------------
%% Function:
%% code_change(OldVsn, StateName, State, Extra) -> {ok, StateName, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
