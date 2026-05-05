import Config

# Runtime configuration — read at boot from env vars so a single release
# artifact can be reconfigured without recompilation. Subsystems that read
# from here arrive in later units (U3 workspace, U5 endpoint, U9 auth);
# the keys below are the agreed contract surface so those units have a
# place to land.

config :beam_design,
  # Where the daemon mints its auth token (U9). Mode 0600 enforced at write.
  auth_token_path:
    System.get_env("BEAM_DESIGN_TOKEN_PATH") ||
      Path.expand("~/.beam-design/auth-token"),

  # Workspace location (U3). Defaults to current working directory; the
  # workspace locator prefers an explicit `.beam-design.toml` if present.
  workspace_dir: System.get_env("BEAM_DESIGN_WORKSPACE_DIR") || File.cwd!()

# Loopback bind only (R18). Endpoint http: pinned to 127.0.0.1; no other
# code path may bind a network socket without going through the Endpoint.
# Skip in :test so config/test.exs's port: 0 ("pick any free") wins —
# otherwise unit tests collide with a live `mix run` daemon already on
# whatever port BEAM_DESIGN_PORT (or 4000) names.
if config_env() != :test do
  config :beam_design, BeamDesign.Web.Endpoint,
    http: [
      ip: {127, 0, 0, 1},
      port: String.to_integer(System.get_env("BEAM_DESIGN_PORT") || "4000")
    ],
    secret_key_base:
      System.get_env("BEAM_DESIGN_SECRET_KEY_BASE") ||
        :crypto.strong_rand_bytes(48) |> Base.encode64()
end

# Tests still need a secret_key_base; supply a deterministic one so
# Phoenix.Endpoint doesn't crash on startup.
if config_env() == :test do
  config :beam_design, BeamDesign.Web.Endpoint,
    secret_key_base: String.duplicate("a", 64)
end
