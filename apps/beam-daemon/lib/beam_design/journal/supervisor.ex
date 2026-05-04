defmodule BeamDesign.Journal.Supervisor do
  @moduledoc """
  Supervisor for the journal indexer + file-watcher. Real indexer in U8.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(:ok) do
    children = [
      {BeamDesign.Journal.Stub, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
