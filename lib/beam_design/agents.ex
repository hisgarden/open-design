defmodule BeamDesign.Agents do
  @moduledoc """
  Fast layer — per-agent CLI adapters (Claude Code, Codex, Copilot, Pi, ACP, …).

  Each adapter is a thin module that knows how to assemble argv and parse
  the streaming output shape for one specific CLI. Volatility absorbed
  here per the requirements doc dependencies/assumptions: if any one CLI's
  surface shifts, only its adapter changes.
  """
  use Boundary, deps: [BeamDesign.Protocol], exports: [ClaudeCode, Registry]
end
