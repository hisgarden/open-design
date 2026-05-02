defmodule BeamDesign.Web do
  @moduledoc """
  Web layer — Phoenix `Endpoint` (loopback only), `UserSocket` auth handshake,
  and the workspace channel.

  This is the only network surface the daemon exposes (R8). Every
  mutating channel handler delegates into the Slow or Fast layer; this
  layer holds no business state of its own.

  Nested under `BeamDesign` (rather than the conventional Phoenix
  `BeamDesignWeb` sibling) so all layers share a namespace, simplifying
  Boundary's parent/sibling enforcement.
  """
  use Boundary,
    deps: [
      BeamDesign.Protocol,
      BeamDesign.Auth,
      BeamDesign.Workspace,
      BeamDesign.DesignSystems,
      BeamDesign.Skills,
      BeamDesign.Journal,
      BeamDesign.Runs
    ],
    exports: [Endpoint, UserSocket]
end
