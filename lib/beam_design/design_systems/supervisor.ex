defmodule BeamDesign.DesignSystems.Supervisor do
  @moduledoc """
  Supervisor for the design-systems loader + watcher + store.

  v1 skeleton holds a single stub child. Real loader/watcher arrives in U6.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(:ok) do
    children = [
      BeamDesign.DesignSystems.Loader
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
