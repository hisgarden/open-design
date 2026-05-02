defmodule BeamDesign.Journal do
  @moduledoc """
  Slow layer — journal indexer and `spec.write` handler.

  Watches the workspace's journal directory (markdown files in `~/code`),
  parses frontmatter + body, maintains an ETS index keyed by file path
  with secondary indexes by anchors and design-system id (R7 / R14 / R16).
  Anchors connect spec entries back to specific runs (provenance).
  """
  use Boundary, deps: [BeamDesign.Protocol, BeamDesign.Workspace], exports: []
end
