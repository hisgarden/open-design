defmodule BeamDesign.Workspace.Supervisor do
  @moduledoc """
  Supervisor for the workspace subsystem (config, paths, journal location).

  v1 skeleton holds a single stub child so the supervision tree shape is
  inspectable from IEx. Real children (Workspace.Server, etc.) arrive in U3.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(:ok) do
    children = [
      {BeamDesign.Workspace.Stub, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
