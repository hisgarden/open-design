ExUnit.start()

# Channel tests assert against the synthetic-run path (deterministic,
# no DeepInfra/ClaudeCode dependency). Set the env var once for the
# whole suite so the channel sees synthetic_runs?() == true and
# returns stub_mode: true responses.
System.put_env("BEAM_DESIGN_SYNTHETIC_RUNS", "1")
