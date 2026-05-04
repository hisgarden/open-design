defmodule BeamDesign.Protocol.Version do
  @moduledoc """
  Protocol version constant. Bumped on a breaking change to the channel
  message envelopes; clients negotiate via the `design:v<N>:*` topic
  prefix.
  """

  @version 1

  @spec current() :: pos_integer()
  def current, do: @version

  @spec topic_prefix() :: String.t()
  def topic_prefix, do: "design:v#{@version}"
end
