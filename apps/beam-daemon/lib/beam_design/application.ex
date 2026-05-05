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
      BeamDesign.Conversations,
      BeamDesign.Runs,
      BeamDesign.Agents,
      BeamDesign.Web
    ]

  @impl true
  def start(_type, _args) do
    children = [
      # PubSub before Endpoint so Phoenix can broadcast through it.
      {Phoenix.PubSub, name: BeamDesign.PubSub},
      BeamDesign.Auth.Holder,
      BeamDesign.Workspace.Supervisor,
      BeamDesign.DesignSystems.Supervisor,
      BeamDesign.Skills.Supervisor,
      BeamDesign.Journal.Supervisor,
      BeamDesign.Conversations.Store,
      BeamDesign.Runs.Supervisor,
      BeamDesign.Web.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BeamDesign.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
