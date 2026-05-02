import Config

# Compile-time configuration shared across environments. Runtime-only
# concerns (auth token path, network bind, port) live in `config/runtime.exs`
# so they can be overridden by env vars at start time.

config :logger, :default_formatter, format: "$time [$level] $message $metadata\n"

import_config "#{config_env()}.exs"
