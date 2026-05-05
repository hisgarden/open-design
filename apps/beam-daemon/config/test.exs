import Config

# Test-only overrides. Disable the HTTP endpoint by default so unit
# tests can run alongside a live `mix run` daemon on :4000 without
# port collisions. Channel/endpoint tests that need a running server
# opt back in via `Application.put_env/3` in their setup blocks.
config :beam_design, BeamDesign.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 0]
