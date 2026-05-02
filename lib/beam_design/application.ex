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
      # Subsystem supervisors arrive in U4. Empty for now so the application
      # starts cleanly; the supervision tree shape is the unit's deliverable.
    ]

    opts = [strategy: :one_for_one, name: BeamDesign.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
