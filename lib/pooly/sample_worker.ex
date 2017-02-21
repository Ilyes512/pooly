defmodule Pooly.SampleWorker do
  use GenServer;

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, [])

  def stop(pid), do: GenServer.call(pid, :stop)

  def init(_), do: {:ok, %{}}

  def handle_info(:stop, state), do: {:stop, :normal, state}
end