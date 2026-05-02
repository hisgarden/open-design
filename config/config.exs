import Config

# Compile-time configuration shared across environments. Runtime-only
# concerns (auth token path, network bind, port) live in `config/runtime.exs`
# so they can be overridden by env vars at start time.

config :logger, :default_formatter, format: "$time [$level] $message $metadata\n"

# Phoenix endpoint defaults; per-env overrides land in runtime.exs at boot
# so a single release artifact reconfigures via env vars only.
config :beam_design, BeamDesign.Web.Endpoint,
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  server: true,
  pubsub_server: BeamDesign.PubSub,
  render_errors: [accepts: ["json"]],
  url: [host: "127.0.0.1"]

import_config "#{config_env()}.exs"
