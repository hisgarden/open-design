defmodule BeamDesign.Runs do
  @moduledoc """
  Fast layer — per-run supervisor (`DynamicSupervisor`) and per-run state.

  One supervised `RunServer` per active run, owning the OTP Port that
  wraps the agent CLI. Crash isolation: a run failure stays inside its
  own GenServer and surfaces as a structured `run.terminal` event
  (R5 / R6 / R15 / AE1). Provenance is written to
  `<workspace>/runs/<run-id>/provenance.json`.
  """
  use Boundary,
    deps: [
      BeamDesign.Protocol,
      BeamDesign.Workspace,
      BeamDesign.DesignSystems,
      BeamDesign.Skills,
      BeamDesign.Conversations,
      BeamDesign.Agents
    ],
    exports: [Supervisor]
end
