defmodule BeamDesign.Runs.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-run children. One supervised RunServer per
  active run; crash isolation by design (see plan U7 for run lifecycle).

  v1 skeleton has no children at start; runs are added on demand by the
  channel handler. Real RunServer arrives in U7; for the MVP a synthetic
  stub run is generated inline by the channel without a per-run process.
  """
  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
