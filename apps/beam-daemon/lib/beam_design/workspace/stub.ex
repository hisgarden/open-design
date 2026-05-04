defmodule BeamDesign.Workspace.Stub do
  @moduledoc """
  Placeholder GenServer that lives forever so the workspace supervisor's
  child slot is occupied. Replaced by real workspace state holder in U3.
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{}}
end
