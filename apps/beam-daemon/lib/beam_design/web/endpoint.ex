defmodule BeamDesign.Web.Endpoint do
  @moduledoc """
  Phoenix Endpoint for the BEAM Design Daemon.

  Binds only to 127.0.0.1 (R18). The single socket mount is `/socket`,
  served by `BeamDesign.Web.UserSocket` which performs the bearer-token
  auth handshake (R19).
  """
  use Phoenix.Endpoint, otp_app: :beam_design

  socket("/socket", BeamDesign.Web.UserSocket,
    websocket: true,
    longpoll: false
  )
end
