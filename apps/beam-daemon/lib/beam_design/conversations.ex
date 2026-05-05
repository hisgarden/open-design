defmodule BeamDesign.Conversations do
  @moduledoc """
  Slow layer — per-conversation state store.

  Stitches consecutive runs on the same `{workspace_id, conversation_id}`
  into one coherent thread. Read by RunServer at dispatch time to seed
  the agent's message history; written at every turn boundary so a
  mid-conversation crash leaves a recoverable trace.

  v1 is RAM-only (ETS, lost on daemon restart). Durable persistence
  is a separate plan; see
  `docs/plans/2026-05-05-004-feat-beam-conversation-resumption-plan.md`.

  Stores opaque message lists — knowing what a "message" looks like
  is the agent adapter's job (DeepInfra: OpenAI-shape; future Claude
  Code: Anthropic-shape). Keeping the store agent-agnostic means a
  single module serves every adapter.
  """
  use Boundary, deps: [BeamDesign.Protocol], exports: [Store]
end
