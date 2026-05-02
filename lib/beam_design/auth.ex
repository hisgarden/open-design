defmodule BeamDesign.Auth do
  @moduledoc """
  Slow layer — auth token mint, file write (mode 0600), and timing-safe verify.

  Forward-applied from the open-design audit (R18 / R19 / AE3): the daemon
  binds only to loopback, and every mutating protocol surface requires the
  bearer token from the file the launcher writes at startup.
  """
  use Boundary, deps: [BeamDesign.Protocol], exports: []
end
