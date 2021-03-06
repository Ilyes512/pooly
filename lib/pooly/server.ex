defmodule Pooly.Server do
  use GenServer
  import Supervisor.Spec

  defmodule State do
    defstruct sup: nil, worker_sup: nil, monitors: nil, size: nil, workers: nil, mfa: nil
  end

  def start_link(sup, pool_config), do: GenServer.start_link(__MODULE__, [sup, pool_config], name: __MODULE__)

  def checkout, do: GenServer.call(__MODULE__, :checkout)

  def checkin(worker_pid), do: GenServer.cast(__MODULE__, {:checkin, worker_pid})

  def status, do: GenServer.call(__MODULE__, :status)

  def init([sup, pool_config]) when is_pid(sup) do
    Process.flag(:trap_exit, true)
    monitors = :ets.new(:monitors, [:private])
    init(pool_config, %State{sup: sup, monitors: monitors})
  end
  def init([{:mfa, mfa} | rest], state), do: init(rest, %{state | mfa: mfa})
  def init([{:size, size} | rest], state), do: init(rest, %{state | size: size})
  def init([_ | rest], state), do: init(rest, state)
  def init([], state) do
    send(self(), :start_worker_supervisor)
    {:ok, state}
  end

  def handle_call(:checkout, {from_pid, _ref}, %{workers: workers, monitors: monitors} = state) do
    case workers do
      [worker | rest] ->
        ref = Process.monitor(from_pid)
        true = :ets.insert(monitors, {worker, ref})
        {:reply, worker, %{state | workers: rest}}
      [] ->
        {:reply, :noproc, state}
    end
  end

  def handle_call(:status, _from, %{workers: workers, monitors: monitors} = state) do
    {:reply, {length(workers), :ets.info(monitors, :size)}, state}
  end

  def handle_cast({:checkin, worker}, %{workers: workers, monitors: monitors} = state) do
    case :ets.lookup(monitors, worker) do
      [{pid, ref}] ->
        true = Process.demonitor(ref)
        true = :ets.delete(monitors, pid)
        {:noreply, %{state | workers: [pid | workers]}}
      [] ->
        {:noreply, state}
    end
  end

  def handle_info(:start_worker_supervisor, state = %State{sup: sup, mfa: mfa, size: size}) do
    {:ok, worker_sup} = Supervisor.start_child(sup, supervisor_spec(mfa))
    workers = prepopulate(size, worker_sup)
    {:noreply, %{state | worker_sup: worker_sup, workers: workers}}
  end

  def handle_info({:DOWN, ref, _, _, _}, %{monitors: monitors, workers: workers} = state) do
    IO.inspect :DOWN
    case :ets.match(monitors, {:"$1", ref}) do
      [[pid]] ->
        true = :ets.delete(monitors, pid)
        new_state = %{state | workers: [pid | workers]}
        {:noreply, new_state}
      [[]] ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, %{monitors: monitors, workers: workers, worker_sup: worker_sup} = state) do
    IO.inspect :EXIT
    case :ets.lookup(monitors, pid) do
      [{pid, ref}] ->
        true = Process.demonitor(ref)
        true = :ets.delete(monitors, pid)
        new_state = %{state | workers: [new_worker(worker_sup) | workers]}
        {:noreply, new_state}
      [[]] ->
        {:noreply, state}
    end
  end

  def handle_info(a, b) do
    IO.inspect [a, b]
  end

  defp prepopulate(size, sup), do: prepopulate(size, sup, [])
  defp prepopulate(size, _sup, workers) when size < 1, do: workers
  defp prepopulate(size, sup, workers), do: prepopulate(size - 1, sup, [new_worker(sup) | workers])
  
  defp new_worker(sup) do
    {:ok, worker} = Supervisor.start_child(sup, [[]])
    worker
  end

  defp supervisor_spec(mfa) do
    opts = [restart: :temporary]
    supervisor(Pooly.WorkerSupervisor, [mfa], opts)
  end
end