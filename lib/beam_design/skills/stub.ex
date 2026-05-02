defmodule BeamDesign.Skills.Stub do
  @moduledoc "Placeholder GenServer; real loader arrives in U6."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{}}
end
