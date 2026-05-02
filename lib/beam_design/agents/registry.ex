defmodule BeamDesign.Agents.Registry do
  @moduledoc """
  Static registry of supported agent backends. Returned in the channel
  `welcome` envelope so clients can discover capability without probing.

  Each entry is what the channel `run.start` payload's `agent` field can
  carry. Add new agents here as their adapters land.
  """

  @doc """
  All currently-supported agent ids and their default models.
  """
  @spec list() :: [%{id: String.t(), kind: String.t(), default_model: String.t() | nil}]
  def list do
    [
      %{id: "claude-code", kind: "cli", default_model: nil}
    ]
  end
end
