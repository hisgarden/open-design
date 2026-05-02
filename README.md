# beam-design-daemon

A long-running local Elixir/OTP daemon that owns the slow layers of a design practice — design system, skills protocol, agent-CLI orchestration, journal indexing — and exposes them via a small Phoenix-Channel-over-WebSocket protocol. UIs (open-design, editors, future clients) consume the protocol; the daemon ships none of its own.

The journal lives as markdown files in your `~/code` workshop. The daemon indexes them; it does not own their storage.

Status: pre-v1 skeleton. See [AGENTS.md](./AGENTS.md) for architecture and conventions.

## Quick start (development)

Requires Elixir `~> 1.19` and Erlang/OTP 26+ (Homebrew installs Elixir 1.19 + OTP 28 with `brew install elixir`).

```bash
mix deps.get
iex -S mix
```

The daemon binds to `127.0.0.1` only. The auth token is minted at startup and written to `~/.beam-design/auth-token` with mode `0600`. Clients (including the demo CLI) read it from there.

## Spec documents

The product shape and the implementation plan live in the open-design fork at `/Users/jwen/workspace/ml/open-design/`:

- [Requirements](../../workspace/ml/open-design/docs/brainstorms/2026-05-02-beam-design-daemon-requirements.md) — what this is and isn't
- [Plan](../../workspace/ml/open-design/docs/plans/2026-05-02-002-feat-beam-design-daemon-skeleton-plan.md) — how the v1 skeleton lands
- [Audit](../../workspace/ml/open-design/docs/audits/2026-05-02-bau-design-audit.md) — security posture forward-applied here

## License

TBD.
