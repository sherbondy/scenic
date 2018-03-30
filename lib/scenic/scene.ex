#
#  Created by Boyd Multerer on 5/8/17.
#  Copyright © 2017 Kry10 Industries. All rights reserved.
#
# Build from the pieces of older versions of Scene
#

# in general anything in the Scene's "internal" section of the state should
# be accessed through Scene apis. Future versions may change the formatting
# this data as needed, but will try to keep the APIs compatible.


defmodule Scenic.Scene do
  alias Scenic.Scene
  alias Scenic.Graph
  alias Scenic.ViewPort
  alias Scenic.ViewPort.Input.Context
  alias Scenic.Primitive
  require Logger

  import IEx

  @dynamic_scenes     :dynamic_scenes
  @ets_scenes_table       :_scenic_viewport_scenes_table_
  @ets_activation_table   :_scenic_viewport_activation_table_

  defmodule Registration do
    defstruct pid: nil, parent_pid: nil, dynamic_supervisor_pid: nil, supervisor_pid: nil
  end


  @callback init( any ) :: {:ok, any}

  # interacting with the scene's graph
  
  @callback handle_call(any, any, any) :: {:reply, any, any} | {:noreply, any}
  @callback handle_cast(any, any) :: {:noreply, any}
  @callback handle_info(any, any) :: {:noreply, any}

#  @callback handle_raw_input(any, any, any) :: {:noreply, any, any}
  @callback handle_input(any, any, any) :: {:noreply, any, any}

  @callback filter_event( any, any ) :: { :continue, any, any } | {:stop, any}

#  @callback handle_reset(any, any) :: {:noreply, any, any}
#  @callback handle_update(any, any) :: {:noreply, any, any}
  @callback handle_activate(any, any) :: {:noreply, any}
  @callback handle_deactivate(any) :: {:noreply, any}


  #===========================================================================
  # calls for setting up a scene inside of a supervisor

#  def child_spec({ref, scene_module}), do:
#    child_spec({ref, scene_module, nil})

  def child_spec({parent, ref, scene_module, args}) do
    %{
      id: ref,
      start: {__MODULE__, :start_link, [{parent, ref, scene_module, args}]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  #===========================================================================
  # client APIs. In general if the first parameter is an atom or a pid, then it is coming
  # from another process. call or cast to the real one.
  # if the first parameter is state, then this is already on the right process
  # to be called by other processes

  def find_by_screen_pos( pos, pid ) do
    GenServer.call(pid, {:find_by_screen_pos, pos})
  end


  def send_event( event, event_chain )
  def send_event( event, [] ), do: :ok
  def send_event( event, [scene_pid | tail] ) do
    GenServer.cast(scene_pid, {:event, event, tail})
  end

#  def terminate( scene_pid ) do
#    GenServer.cast(scene_pid, :terminate)
#  end

  #--------------------------------------------------------
#  def active?( scene_ref ) when is_atom(scene_ref) or is_reference(scene_ref) do
#    case :ets.lookup(@ets_scenes_table, scene_ref ) do
#      [{_,{_,_,_,active,args}}] -> {active,args}
#      _ -> {:error, :not_found}
#    end
#  end

  def activate( scene_ref, args ) do
IO.puts "-----------> activate #{inspect(scene_ref)}"
    with {:ok, pid} <- to_pid(scene_ref) do
      GenServer.call(pid, {:activate, args})
    end
  end

  def deactivate( scene_ref ) do
IO.puts "-----------> deactivate #{inspect(scene_ref)}"
    with {:ok, pid} <- to_pid(scene_ref) do
      GenServer.call(pid, :deactivate)
    end
  end


  #--------------------------------------------------------
  def get_activation( scene_ref ) do
    case :ets.lookup(@ets_activation_table, scene_ref ) do
      [{_,args}] -> {:ok, args}
      [] -> {:error, :not_found}
    end
  end

  def registration( scene_ref ) do
    case :ets.lookup(@ets_scenes_table, scene_ref ) do
      [{_,registration}] -> {:ok, registration}
      [] -> {:error, :not_found}
    end
  end

  def child_supervisor_pid( scene_ref ) do
    with { :ok, registration } <- registration( scene_ref ) do
      {:ok, registration.dynamic_supervisor_pid}
    end
  end

  def supervisor_pid( scene_ref ) do
    with { :ok, registration } <- registration( scene_ref ) do
      {:ok, registration.supervisor_pid}
    end
  end

  def to_pid( scene_ref ) do
    with { :ok, registration } <- registration( scene_ref ) do
      {:ok, registration.pid}
    end
  end

  def parent_pid( scene_ref ) do
    with { :ok, registration } <- registration( scene_ref ) do
      case registration.parent_pid do
        nil ->
          {:error, :not_found}
        pid ->
          {:ok, pid}
      end
    end
  end

  def child_pids( scene_ref ) do
    with { :ok, dyn_sup } <- child_supervisor_pid( scene_ref ) do
      pids = DynamicSupervisor.which_children( dyn_sup )
      |> Enum.reduce( [], fn
        {_, pid, :worker, [Scene]}, acc -> 
          # easy case. scene is the direct child
          [ pid | acc ]

        {_, pid, :supervisor, [Scene.Supervisor]}, acc ->
          # hard case. the scene is under it's own supervisor
          Supervisor.which_children( pid )
          |> Enum.reduce( [], fn
            {_, pid, :worker, [Scene]}, acc -> [ pid | acc ]
            _, acc -> acc
          end)
      end)
      {:ok, pids}
    end
  end

  #--------------------------------------------------------
  def pid_to_scene( pid ) do
    case :ets.match(:_scenic_viewport_scenes_table_, {:"$1", %{pid: pid}}) do
      [[scene_ref]] -> {:ok, scene_ref}
      _ -> {:error, :not_found}
    end
  end

  #--------------------------------------------------------
  def stop( scene_ref ) do
    # figure out what to stop
    pid_to_stop = case supervisor_pid( scene_ref ) do
      {:ok, pid} ->
        pid
      _ ->
        {:ok, pid} = to_pid(scene_ref)
        pid
    end

    # first, get the parent's dynamic supervisor. If there isn't one,
    # then this is supervised by the app developer
    with {:ok, parent_pid} <- parent_pid( scene_ref ),
      {:ok, parent_scene} <- pid_to_scene( parent_pid ),
      {:ok, parent_dyn_sup} <- child_supervisor_pid( scene_ref ) do
        # stop the scene
        DynamicSupervisor.terminate_child(parent_dyn_sup, pid_to_stop)
    else
      {:error, :not_found} ->
        # attempt to stop this as a dynamic root
        case DynamicSupervisor.terminate_child(@dynamic_scenes, pid_to_stop) do
          :ok -> :ok
          {:error, :not_found} -> {:error, :not_dynamic}
        end

      _ ->
        {:error, :not_dynamic}
    end
  end

  #--------------------------------------------------------
  def broadcast_children(scene_ref, msg) do
    with {:ok, pids} <- child_pids( scene_ref ) do
      Enum.each(pids, &GenServer.cast(&1, msg) )
    end
  end

  #--------------------------------------------------------
  def call_children(scene_ref, msg) do
    with {:ok, pids} <- child_pids( scene_ref ) do
      Enum.reduce(pids, [], fn(pid, tasks)->
        task = Task.async( fn -> GenServer.call(pid, msg) end)
        [task | tasks]
      end)
      |> Enum.reduce( [], fn(task, responses) ->
        [Task.await(task) | responses]
      end)
    end
  end

  #--------------------------------------------------------
  def cast_parent(scene_ref, msg) do
    with {:ok, parent_pid} <- parent_pid( scene_ref ) do
      GenServer.cast(parent_pid, msg)
    end
  end

  #--------------------------------------------------------
  def call_parent(scene_ref, msg) do
    with {:ok, parent_pid} <- parent_pid( scene_ref ) do
      GenServer.call(parent_pid, msg)
    end
  end

  #--------------------------------------------------------
  def cast(scene_ref, msg) do
    with {:ok, pid} <- to_pid( scene_ref ) do
      GenServer.cast(pid, msg)
    end
  end

  #--------------------------------------------------------
  def call(scene_ref, msg) do
    with {:ok, pid} <- to_pid( scene_ref ) do
      GenServer.call(pid, msg)
    end
  end


  #===========================================================================
  # the using macro for scenes adopting this behavioiur
  defmacro __using__(_opts) do
    quote do
      @behaviour Scenic.Scene

      #--------------------------------------------------------
      # Here so that the scene can override if desired
      def init(_),                                do: {:ok, nil}
      def handle_activate( _args, state ),        do: {:noreply, state}
      def handle_deactivate( state ),             do: {:noreply, state}
 
      def handle_call(_msg, _from, state),        do: {:reply, :err_not_handled, state}
      def handle_cast(_msg, state),               do: {:noreply, state}
      def handle_info(_msg, state),               do: {:noreply, state}

#      def handle_raw_input( event, graph, scene_state ),  do: {:noreply, graph, scene_state}
      def handle_input( event, _, scene_state ),  do: {:noreply, scene_state}
      def filter_event( event, scene_state ),     do: {:continue, event, scene_state}

      def send_event( event, %Scenic.ViewPort.Input.Context{} = context ), do:
        Scenic.Scene.send_event( event, context.event_chain )

      def start_child_scene( parent_scene, ref, opts ), do:
        Scenic.Scene.start_child_scene( parent_scene, ref, __MODULE__, opts )

      #--------------------------------------------------------
#      add local shortcuts to things like get/put graph and modify element
#      do not add a put element. keep it at modify to stay atomic
      #--------------------------------------------------------
      defoverridable [
        init:                   1,
        handle_activate:        2,
        handle_deactivate:      1,

        handle_call:            3,
        handle_cast:            2,
        handle_info:            2,

        handle_input:           3,
        filter_event:           2,

        start_child_scene:      3
      ]

    end # quote
  end # defmacro


  #===========================================================================
  # internal code to this module

  #===========================================================================
  # Scene initialization


  #--------------------------------------------------------
#  def start_link(super_pid, ref, module) do
#    name_ref = make_ref()
#    GenServer.start_link(__MODULE__, {ref, module, nil})
#  end

  def start_link({parent, name, module, args}) when is_atom(name) do
    GenServer.start_link(__MODULE__, {parent, name, module, args}, name: name)
  end

  def start_link({parent, ref, module, args}) when is_reference(ref) do
    GenServer.start_link(__MODULE__, {parent, ref, module, args})
  end

  #--------------------------------------------------------
  def init( {parent, scene_ref, module, args} ) do
    Process.put(:scene_ref, scene_ref)

    # update the scene with the parent and supervisor info
    ViewPort.register_scene( scene_ref, %Registration{ pid: self() })

    GenServer.cast(self(), {:after_init, scene_ref, args})

    state = %{
      scene_ref: scene_ref,
      parent: parent,
      scene_module: module
    }

    {:ok, state}
  end


  #--------------------------------------------------------
  # this a root-level dynamic scene
  def start_child_scene( @dynamic_scenes, ref, mod, opts ) do
    # start the scene supervision tree
    {:ok, supervisor_pid} = DynamicSupervisor.start_child(  @dynamic_scenes,
      {Scenic.Scene.Supervisor, {ref, mod, opts}}
    )

    # we want to return the pid of the scene itself. not the supervisor
    scene_pid = Supervisor.which_children( supervisor_pid )
    |> Enum.find_value( fn 
      {_, pid, :worker, [Scenic.Scene]} ->
        pid
      _ ->
        nil
    end)

    {:ok, scene_pid}
  end

  #--------------------------------------------------------
  # this is starting as the child of another scene
  def start_child_scene( parent_scene, ref, mod, opts ) do
    # get the dynamic supervisor for the parent
    case child_supervisor_pid( parent_scene ) do
      {:ok, child_sup_pid} ->
        # start the scene supervision tree
        {:ok, supervisor_pid} = DynamicSupervisor.start_child( child_sup_pid,
          {Scenic.Scene.Supervisor, {ref, mod, opts}}
        )

        # we want to return the pid of the scene itself. not the supervisor
        scene_pid = Supervisor.which_children( supervisor_pid )
        |> Enum.find_value( fn 
          {_, pid, :worker, [Scenic.Scene]} ->
            pid
          _ ->
            nil
        end)

        {:ok, scene_pid}
      _ ->
        {:error, :invalid_parent}
    end
  end





  #--------------------------------------------------------
  # somebody has a screen position and wants an uid for it
  def handle_call({:find_by_screen_pos, pos}, _from, %{graph: graph} = state) do
    uid = case Graph.find_by_screen_point( graph, pos ) do
      %Primitive{uid: uid} -> uid
      _ -> nil
    end
    {:reply, uid, state}
  end



  #--------------------------------------------------------
  def handle_call({:activate, args}, %{
    scene_ref: scene_ref,
    scene_module: mod,
    scene_state: sc_state,
  } = state) do
IO.puts "SCENE ACTIVATE"
    Viewport.register_activation( scene_ref, args )
    # tell the scene it is being activated
    {:noreply, sc_state} = mod.handle_activate( args, sc_state )
    { :noreply, %{state | scene_state: sc_state} }
  end


  #--------------------------------------------------------
  # support for losing focus
  def handle_call(:deactivate, _, %{
    scene_module: mod,
    scene_state: sc_state,
  } = state) do
IO.puts "SCENE DEACTIVATE"
    # tell the scene it is being deactivated
    {:noreply, sc_state} = mod.handle_deactivate( sc_state )
    { :reply, :ok, %{state | scene_state: sc_state} }
  end

  #--------------------------------------------------------
  # generic call. give the scene a chance to handle it
  def handle_call(msg, from, %{scene_module: mod, scene_state: sc_state} = state) do
    {:reply, reply, sc_state} = mod.handle_call(msg, from, sc_state)
    {:reply, reply, %{state | scene_state: sc_state}}
  end


  #===========================================================================
  # default cast handlers.

  #--------------------------------------------------------
  def handle_cast({:after_init, scene_ref, args}, %{
    parent: parent,
    scene_module: module
  } = state) do

    # get the scene supervisors
    [supervisor_pid | _] = self()
    |> Process.info()
    |> get_in([:dictionary, :"$ancestors"])
    # make sure this really is a scene supervisor, not something else
    supervisor_pid = case Process.info(supervisor_pid) do
      nil -> nil
      info ->
        case get_in( info, [:dictionary, :"$initial_call"] ) do
          {:supervisor, Scene.Supervisor, _} ->
            supervisor_pid
          _ ->
            nil
        end
    end

    dynamic_children_pid = Supervisor.which_children( supervisor_pid )
    |> Enum.find_value( fn 
      {DynamicSupervisor, pid, :supervisor, [DynamicSupervisor]} -> pid
      _ -> nil
    end)

    # update the scene with the parent and supervisor info
    ViewPort.register_scene( scene_ref, %Registration{
      pid: self(),
      parent_pid: parent,
      dynamic_supervisor_pid: dynamic_children_pid,
      supervisor_pid: supervisor_pid
    })

    # initialize the scene itself
    {:ok, sc_state} = module.init( args )

    # if this init is recovering from a crash, then the scene_ref will be able to
    # recover a list of graphs associated with it. Activate the ones that are... active
    sc_state = ViewPort.list_scene_activations( scene_ref )
    |> Enum.reduce( sc_state, fn({id,args},ss) ->
      {:noreply, ss} = module.handle_activate( id, args, ss )
      ss
    end)

    state = state
    |> Map.put( :scene_state, sc_state)
    |> Map.put( :supervisor_pid, supervisor_pid)
    |> Map.put( :dynamic_children_pid, dynamic_children_pid)

    {:noreply, state}
  end

  #--------------------------------------------------------
#  def handle_cast(:terminate, %{ supervisor_pid: supervisor_pid } = state) do
#    Supervisor.stop(supervisor_pid)
#    {:noreply, state}
#  end

  #--------------------------------------------------------
  def handle_cast({:input, event, context}, 
  %{scene_module: mod, scene_state: sc_state} = state) do
    {:noreply, sc_state} = mod.handle_input(event, context, sc_state )
    {:noreply, %{state | scene_state: sc_state}}
  end


  #--------------------------------------------------------
  def handle_cast({:event, event, event_chain}, 
  %{scene_module: mod, scene_state: sc_state} = state) do

    sc_state = case mod.filter_event(event, sc_state ) do
      { :continue, event, sc_state } ->
        send_event( event, event_chain )
        sc_state

      {:stop, sc_state} ->
        sc_state
    end
    
    {:noreply, %{state | scene_state: sc_state}}
  end

  #--------------------------------------------------------
  # generic cast. give the scene a chance to handle it
  def handle_cast(msg, %{scene_module: mod, scene_state: sc_state} = state) do
    {:noreply, sc_state} = mod.handle_cast(msg, sc_state)
    {:noreply, %{state | scene_state: sc_state}}
  end

  def handle_cast(msg, state) do
#    pry()
    {:noreply, state}
  end

  #===========================================================================
  # info handlers

  #--------------------------------------------------------
  # generic info. give the scene a chance to handle it
  def handle_info(msg, %{scene_module: mod, scene_state: sc_state} = state) do
    {:noreply, sc_state} = mod.handle_info(msg, sc_state)
    {:noreply, %{state | scene_state: sc_state}}
  end

  #============================================================================
  # utilities

  #--------------------------------------------------------
  # internal utility. Given a pid to a Scenic.Scene.Supervisor
  # return the pid of the scene it supervises
#  defp find_supervised_scene( supervisor_pid ) do
#    Supervisor.which_children( supervisor_pid )
#    |> Enum.find_value( fn 
#      {_, pid, :worker, [Scenic.Scene]} ->
#        pid
#      _ ->
#        nil
#    end)
#  end

end








