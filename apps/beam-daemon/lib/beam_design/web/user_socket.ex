defmodule BeamDesign.Web.UserSocket do
  @moduledoc """
  WebSocket entry point. Performs the bearer-token auth handshake (R19,
  AE3). A connect attempt without `?token=<correct-token>` in the query
  string is refused.

  Every workspace topic flows through this socket. Channel routing is
  declared here; topic-format validation lives in the channel itself.
  """
  use Phoenix.Socket

  alias BeamDesign.Auth

  channel("design:v1:*", BeamDesign.Web.WorkspaceChannel)

  @impl true
  def connect(params, socket, _connect_info) do
    case Auth.Holder.verify(params["token"]) do
      true -> {:ok, socket}
      false -> :error
    end
  end

  @impl true
  def id(_socket), do: nil
end
