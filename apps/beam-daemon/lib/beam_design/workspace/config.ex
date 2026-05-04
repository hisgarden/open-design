defmodule BeamDesign.Workspace.Config do
  @moduledoc """
  Resolves the active workspace's directories.

  v1: a single workspace per daemon, located via the
  `BEAM_DESIGN_WORKSPACE_DIR` env var (defaulting to the current working
  directory). Sub-paths follow open-design's convention so the same
  directory tree the open-design React app reads is reusable here.
  """

  @spec workspace_dir() :: Path.t()
  def workspace_dir do
    Application.get_env(:beam_design, :workspace_dir) ||
      System.get_env("BEAM_DESIGN_WORKSPACE_DIR") ||
      File.cwd!()
  end

  @spec design_systems_dir() :: Path.t()
  def design_systems_dir, do: Path.join(workspace_dir(), "design-systems")

  @spec skills_dir() :: Path.t()
  def skills_dir, do: Path.join(workspace_dir(), "skills")

  @doc """
  Whether the workspace looks plausibly populated. Used by loaders to
  emit a clearer log line on startup if the configured workspace is
  missing the expected subdirs.
  """
  @spec workspace_ok?() :: boolean()
  def workspace_ok? do
    File.dir?(design_systems_dir()) or File.dir?(skills_dir())
  end
end
