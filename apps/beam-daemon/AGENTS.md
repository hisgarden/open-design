# AGENTS — beam-design-daemon

This file is the single source of truth for any agent or returning maintainer entering this repository. Read this file first; then the spec docs cross-referenced below if you need product context.

## What this is

A long-running local Elixir/OTP daemon that owns the slow layers of an architect-maintainer's design practice — design system, skills protocol, agent-CLI orchestration, journal indexing — and exposes them via a single Phoenix-Channel-over-WebSocket protocol. UIs (open-design, editors, future clients) consume the protocol; the daemon ships none of its own.

The journal lives as markdown files in the maintainer's broader `~/code` workshop. The daemon indexes them; it does not own their storage.

## MVP Definition of Done (held until both met)

The repo stays local-only until BOTH:

1. **U6 demonstrated** — `BeamDesign.DesignSystems.Loader` and `BeamDesign.Skills.Loader` read a real workspace's `design-systems/` and `skills/` directories, serve them through the channel, and hot-reload on disk change. The welcome envelope advertises actual content, not empty arrays.
2. **A real (non-spike) frontend driving the daemon end-to-end.** The Node script `scripts/beam-spike.mjs` in the open-design fork is debug scaffolding by design and does NOT count. Per requirement R13, the intended demonstrator is the existing open-design React app driving the daemon as its backend (full U11 sidecar adapter). A new minimal first-party web UI also qualifies if explicitly chosen.

Reasoning: the project is "useful" when the maintainer can do real design work against it, not when the wire protocol works. Real loaders + real UI prove user value, not architectural correctness.

After both ship, re-evaluate: push to a remote (public or private), or hold longer.

## Pace layers (Stewart Brand, *How Buildings Learn*)

The single load-bearing architectural rule. Slow layers must outlive fast layers without being ripped out. Cross-layer dependencies are tracked by the [Boundary](https://hexdocs.pm/boundary/) library — `mix compile` reports forbidden references as warnings.

| Tier | Modules | What it owns | Allowed deps |
|---|---|---|---|
| Contract (slowest) | `BeamDesign.Protocol.*` | Channel topics, message envelope shapes, version constants | (none — this layer depends on no internal modules) |
| Slow | `BeamDesign.Auth.*`, `BeamDesign.Workspace.*`, `BeamDesign.DesignSystems.*`, `BeamDesign.Skills.*`, `BeamDesign.Journal.*` | Workspace config, design-system + skill loaders, journal index, auth token mint/verify | Contract |
| Fast | `BeamDesign.Runs.*`, `BeamDesign.Agents.*` | Per-run supervised GenServers, agent CLI adapters, provenance writes | Contract, Slow |
| Web | `BeamDesign.Web.*` | Phoenix Endpoint (loopback only), UserSocket auth handshake, WorkspaceChannel | Contract, Slow, Fast |

Layout note: every layer is nested under `BeamDesign.*` (including `BeamDesign.Web`, not the conventional Phoenix `BeamDesignWeb` sibling). This is deliberate — Boundary's parent/sibling rules require all layers to share a parent namespace for them to be sibling-dependable.

If you need to cross a layer boundary that's not in this table, the design has changed; update this table and the `use Boundary, deps: [...]` declarations together, never one without the other.

### CI gate for boundary violations

`mix compile --warnings-as-errors` does NOT promote Boundary's warnings to compile errors (the flag only catches Elixir's own compiler warnings). Until a follow-up unit adds a stricter check, the CI gate is:

```bash
mix compile --force 2>&1 | grep -E "forbidden reference|can't be listed as a dependency" && exit 1 || exit 0
```

This is captured as a follow-up task; the warning visibility itself is enough for local development.

## Where things live

- `lib/beam_design/` — the daemon's own modules, grouped by pace-layer subsystem (including `BeamDesign.Web`, the network surface).
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
