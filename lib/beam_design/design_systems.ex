defmodule BeamDesign.DesignSystems do
  @moduledoc """
  Slow layer — design-system loader, in-memory store, and file-watch.

  Mirrors the open-design fork's `design-systems/` directory shape (R11):
  brand-aware asset libraries, each with a `DESIGN.md` and supporting
  files. Hot-reloads on disk change; broadcasts `design_systems.changed`
  through the channel layer.
  """
  use Boundary,
    deps: [BeamDesign.Protocol, BeamDesign.Workspace],
    exports: [Loader, Parser, Parser.DesignSystem]
end
