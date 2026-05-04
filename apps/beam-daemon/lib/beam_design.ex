defmodule BeamDesign do
  @moduledoc """
  Top-level namespace for the BEAM Design Daemon.

  Pace-layer boundaries are enforced by the Boundary library. Each
  subsystem (Protocol, Auth, Workspace, DesignSystems, Skills, Journal,
  Runs, Agents, Web) declares `use Boundary` with an explicit `deps:`
  list. Cross-layer calls are validated at compile time.

  This namespace module itself is intentionally NOT a Boundary — making
  it one would force every layer to be a sub-boundary of it, complicating
  the dep graph for no benefit. The layers are independent siblings.

  See `AGENTS.md` for the full pace-layer table and rationale.

  ## Note on Boundary enforcement

  This top-level module is its own boundary, listing every layer as
  a sub-boundary. Each layer module then declares which siblings it
  may depend on. Cross-layer violations surface as Boundary warnings
  during `mix compile`; treating them as errors (`--warnings-as-errors`
  on CI) makes the gate enforced.
  """

  use Boundary,
    deps: [],
    exports: [
      Protocol,
      Auth,
      Workspace,
      DesignSystems,
      Skills,
      Journal,
      Runs,
      Agents,
      Web
    ]
end
