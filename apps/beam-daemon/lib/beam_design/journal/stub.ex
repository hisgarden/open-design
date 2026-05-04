defmodule BeamDesign.Journal.Stub do
  @moduledoc "Placeholder GenServer; real indexer arrives in U8."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{}}
end
