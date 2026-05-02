defmodule BeamDesign.Application do
  @moduledoc false

  use Application

  use Boundary,
    deps: [
      BeamDesign.Protocol,
      BeamDesign.Auth,
      BeamDesign.Workspace,
      BeamDesign.DesignSystems,
      BeamDesign.Skills,
      BeamDesign.Journal,
      BeamDesign.Runs,
      BeamDesign.Agents,
      BeamDesign.Web
    ]

  @impl true
  def start(_type, _args) do
    children = [
      BeamDesign.Workspace.Supervisor,
      BeamDesign.DesignSystems.Supervisor,
      BeamDesign.Skills.Supervisor,
      BeamDesign.Journal.Supervisor,
      BeamDesign.Runs.Supervisor
      # BeamDesign.Web.Endpoint added in U9
    ]

    opts = [strategy: :one_for_one, name: BeamDesign.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
