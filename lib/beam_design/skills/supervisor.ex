defmodule BeamDesign.Skills.Supervisor do
  @moduledoc """
  Supervisor for the skills loader + watcher + store. Real loader in U6.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(:ok) do
    children = [
      BeamDesign.Skills.Loader
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
