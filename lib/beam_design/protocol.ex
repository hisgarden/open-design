defmodule BeamDesign.Protocol do
  @moduledoc """
  Contract layer (slowest pace layer).

  Channel topics, message envelope shapes, and protocol version constants.
  This layer is the load-bearing slow contract — it depends on no other
  internal module so that breaking changes here surface immediately as
  compile errors elsewhere, never as runtime drift.

  See `AGENTS.md` and the requirements doc R8 / R9 / R10 for why the
  protocol surface is the only externally-visible product surface.
  """
  use Boundary, deps: [], exports: []
end
