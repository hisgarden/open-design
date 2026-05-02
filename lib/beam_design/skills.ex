defmodule BeamDesign.Skills do
  @moduledoc """
  Slow layer — skill loader, in-memory store, and file-watch.

  Mirrors the open-design fork's `skills/` directory shape (R12):
  markdown-driven artifact recipes (`SKILL.md` + supporting markdown).
  Hot-reloads on disk change; broadcasts `skills.changed`.
  """
  use Boundary, deps: [BeamDesign.Protocol, BeamDesign.Workspace], exports: []
end
