# AGENTS — beam-design-daemon

This file is the single source of truth for any agent or returning maintainer entering this repository. Read this file first; then the spec docs cross-referenced below if you need product context.

## What this is

A long-running local Elixir/OTP daemon that owns the slow layers of an architect-maintainer's design practice — design system, skills protocol, agent-CLI orchestration, journal indexing — and exposes them via a single Phoenix-Channel-over-WebSocket protocol. UIs (open-design, editors, future clients) consume the protocol; the daemon ships none of its own.

The journal lives as markdown files in the maintainer's broader `~/code` workshop. The daemon indexes them; it does not own their storage.

## Pace layers (Stewart Brand, *How Buildings Learn*)

The single load-bearing architectural rule. Slow layers must outlive fast layers without being ripped out. Cross-layer dependencies are enforced by the [Boundary](https://hexdocs.pm/boundary/) library — `mix compile` fails on a violation.

| Tier | Modules | What it owns | Allowed deps |
|---|---|---|---|
| Contract (slowest) | `BeamDesign.Protocol.*` | Channel topics, message envelope shapes, version constants | (none — this layer depends on no internal modules) |
| Slow | `BeamDesign.Auth.*`, `BeamDesign.Workspace.*`, `BeamDesign.DesignSystems.*`, `BeamDesign.Skills.*`, `BeamDesign.Journal.*` | Workspace config, design-system + skill loaders, journal index, auth token mint/verify | Contract |
| Fast | `BeamDesign.Runs.*`, `BeamDesign.Agents.*` | Per-run supervised GenServers, agent CLI adapters, provenance writes | Contract, Slow |
| Web | `BeamDesignWeb.*` | Phoenix Endpoint (loopback only), UserSocket auth handshake, WorkspaceChannel | Contract, Slow, Fast |

If you need to cross a layer boundary that's not in this table, the design has changed; update this table and the `use Boundary, deps: [...]` declarations together, never one without the other.

## Where things live

- `lib/beam_design/` — the daemon's own modules, grouped by pace-layer subsystem.
- `lib/beam_design_web/` — Phoenix Endpoint, UserSocket, channels. The only network surface.
- `config/runtime.exs` — loopback bind address, port, auth token path. Single source of network/security config.
- `apps_demo_cli/` — throwaway CLI client used to validate the protocol from a real (non-test) consumer. Explicitly not part of the product.
- `test/` — mirrors `lib/`. Integration tests for cross-layer behavior live alongside the layer they originate from.

## Spec documents

The product shape and the implementation plan live in the open-design fork at `/Users/jwen/workspace/ml/open-design/` (a separate repo this daemon was conceived from):

- Requirements (WHAT this is and isn't): `docs/brainstorms/2026-05-02-beam-design-daemon-requirements.md`
- Implementation plan (HOW the v1 skeleton lands): `docs/plans/2026-05-02-002-feat-beam-design-daemon-skeleton-plan.md`
- Companion audit (security posture forward-applied here): `docs/audits/2026-05-02-bau-design-audit.md`

When in doubt about scope or product intent, the requirements doc wins. When in doubt about the next implementation step, the plan wins. When in doubt about security posture, the audit wins.

## Common commands

```bash
mix deps.get                # fetch dependencies
mix compile                 # compile + run boundary checks
mix format                  # format the codebase
mix format --check-formatted  # CI-style format check
mix credo --strict          # lint
mix dialyzer                # static analysis (slow first run, fast after)
mix test                    # run the test suite
iex -S mix                  # interactive shell with the application started
```

## Conventions

- Default to writing no comments in code. Module-level docstrings only when the module's purpose is non-obvious from its name + public API.
- Tests live next to their layer in `test/beam_design/<layer>/...` and `test/beam_design_web/...`. Cross-layer integration scenarios live with the originating layer.
- File-watch-driven behavior gets at least one integration test that actually edits a file on disk; mocks don't prove the watcher chain.
- New external dependencies require a one-line justification in the PR description. Default-deny on adding deps; the layered structure substitutes for most "we need a library for that" instincts.
