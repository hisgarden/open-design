defmodule BeamDesign.Workspace do
  @moduledoc """
  Slow layer — workspace location and journal-path resolution.

  Locates the active workspace via configuration (a `.beam-design.toml` or
  similar at the workspace root) and resolves the journal directory under
  the maintainer's `~/code` workshop (R7 / R17). Other slow-layer modules
  consume the resolved paths from here.
  """
  use Boundary, deps: [BeamDesign.Protocol], exports: []
end
