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

  # Loopback bind only (R18). The Endpoint (U9) reads this; no other code path
  # may bind a network socket without going through the Endpoint.
  bind_ip: {127, 0, 0, 1},
  bind_port: String.to_integer(System.get_env("BEAM_DESIGN_PORT") || "4000"),

  # Workspace location (U3). Defaults to current working directory; the
  # workspace locator prefers an explicit `.beam-design.toml` if present.
  workspace_dir: System.get_env("BEAM_DESIGN_WORKSPACE_DIR") || File.cwd!()
