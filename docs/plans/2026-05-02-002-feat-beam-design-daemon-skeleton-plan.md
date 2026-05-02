---
title: "feat: BEAM design daemon — v1 skeleton through open-design adapter spike"
type: feat
status: active
date: 2026-05-02
origin: docs/brainstorms/2026-05-02-beam-design-daemon-requirements.md
---

# feat: BEAM design daemon — v1 skeleton through open-design adapter spike

**Target repo:** new project at `~/code/beam-design-daemon/` (created in U1; the path may be adjusted at U1 time). Repo-relative paths in this plan are relative to that new project root unless they reference `packages/contracts/...`, `apps/web/sidecar/...`, or `apps/web/src/providers/daemon.ts` — those paths are in the open-design fork at `/Users/jwen/workspace/ml/open-design/` and are referenced as anchors for U10–U11.

---

## Summary

Build a v1 long-running Elixir/OTP daemon that owns design-system loading, skill loading, agent-CLI orchestration, and journal indexing, exposing a single Phoenix-Channel-over-WebSocket protocol. Validate the protocol's reality by spiking an adapter that lets the existing open-design React client drive one capability through the new daemon.

---

## Problem Frame

Origin doc establishes the product shape (Shape C: daemon-as-product, no first-party UI, journal in `~/code`, pace-layered architecture). The plan-level problem is sequencing: a greenfield BEAM project of this scope has many tractable starting points, and the wrong order produces a brain that nothing can talk to (no client) or a client that has nothing to talk to (no brain). Sequence the skeleton so the protocol contract lands early, supervision is in place before any long-lived code, and the smallest credible end-to-end loop ships before deeper capability is built.

(see origin: `docs/brainstorms/2026-05-02-beam-design-daemon-requirements.md`)

---

## Requirements

This plan advances every R-ID in the origin doc to "scaffolded and demonstrated end-to-end" — not "feature-complete." Specifically:

- R1, R2, R3 (persona / posture / pace layers) — addressed by U1, U2, U4, U9 establishing the layered project shape from day one.
- R4, R5, R6 (daemon shape, agent CLI orchestration, OTP supervision) — U4, U7.
- R7 (journal lives in `~/code`, daemon indexes) — U3, U8.
- R8, R9, R10 (protocol is the slow contract, versioned, multi-client) — U5.
- R11, R12 (design system + skill loading inherited from open-design) — U6.
- R13 (open-design becomes a client within 1–2 weeks) — U10, U11.
- R14, R15, R16, R17 (spec-last journaling with provenance, files in `~/code`) — U3, U8, plus an explicit spec-write surface in U10's CLI.
- R18, R19, R20, R21 (default-deny security posture from day one) — U9 baked in; verified per-unit at U5, U7, U10.

**Origin actors:** A1 Architect-Maintainer, A2 Agent CLI process, A3 Client UI, A4 Provider API, A5 `~/code` workshop.
**Origin flows:** F1 Run agent / produce artifact, F2 Distill spec, F3 Surface prior decisions, F4 Add/upgrade client, F5 Recover from crash.
**Origin acceptance examples:** AE1 (covers R6, R8, R10) — multi-client crash isolation; AE2 (covers R7, R14, R16, R17) — spec anchors survive 6 months; AE3 (covers R18, R19) — loopback + auth deny; AE4 (covers R3, R4) — replace client without daemon change; AE5 (covers R9, R10) — protocol versioning behavior under v1↔v2.

---

## Scope Boundaries

### Deferred for later

- Multi-user / team collaboration on the same daemon
- A polished first-party UI as a shipping product (the U10 CLI is throwaway scaffolding)
- Migration tooling from an existing open-design SQLite database
- Desktop packaging beyond `mix release` (Tauri / native installers)
- Provider-API integrations (OpenAI, Replicate, Volcengine, etc.) beyond what the agent CLIs already invoke themselves
- BEAM node clustering / multi-machine distribution
- Hot-code-reloading workflow as a user-facing feature

### Outside this product's identity

- LiveView-based design tool (puts UI rendering inside the daemon, defeating Shape C)
- General-purpose code agent (this is design-shaped, not competing with Claude Code / Cursor / Copilot as agent surfaces)
- Design-asset marketplace
- WYSIWYG design editor
- Multi-tenant cloud product

### Deferred to Follow-Up Work

- **Full open-design client port**: U11 is a one-route spike to validate the contract, not the complete adapter. The full port (every `/api/*` route in open-design's Express daemon mapped to the new Channel protocol) is a separate plan in the open-design fork repo, expected after the BEAM v1 ships.
- **JS-side audit fixes** (`fix/bau-design-remediation` branch): U1–U10 of the prior plan stay live in the open-design fork — they make open-design a *good* client of the new daemon, separately from this plan's work.
- **CI / release pipeline** for the BEAM project: GitHub Actions config and `mix release` artifact publishing. Out of scope for v1 skeleton; add when the project has external consumers.

---

## Context & Research

### Relevant Code and Patterns

- `packages/contracts/src/` (in open-design fork) — the typed cross-app DTO surface. U5's Channel protocol shapes must be expressible in these contracts so the U11 adapter is a translation, not a re-design. Subdirectories: `api/`, `sse/`, `prompts/`, plus `common.ts`, `errors.ts`, `examples.ts`, `tasks.ts`.
- `apps/web/sidecar/index.ts` and `apps/web/sidecar/server.ts` (in open-design fork) — the existing sidecar bootstrap pattern. The U11 adapter lives next to or inside this sidecar so the React UI continues to talk to its same-origin proxy without changes.
- `apps/web/src/providers/daemon.ts` (in open-design fork) — the existing fetch+SSE client the React UI uses. U11 must preserve this shape; the adapter translates between Channel events and the SSE event union the provider already expects.
- `apps/daemon/src/server.ts` and surrounding files (in open-design fork) — the inspiration for the route surface, NOT a port target. The new daemon owns its own shape; the JS daemon is one of several clients.

### Institutional Learnings

- No existing `docs/solutions/` in the open-design fork; the BEAM project starts with no institutional learnings of its own.
- The open-design audit (`docs/audits/2026-05-02-bau-design-audit.md`) supplies forward-applied security posture — loopback bind, default-deny auth, no `allow-same-origin` iframe sandboxes.

### External References

- Phoenix Channels documentation — long-lived bidirectional WebSocket channels with built-in topic/subscriber model. JS client (`phoenix.js`) is small and self-contained.
- OTP Design Principles (`hexdocs.pm/elixir/`) — supervisor strategies (`:one_for_one`, `:one_for_all`, `:rest_for_one`), DynamicSupervisor for per-run children, GenServer state lifecycle.
- `mix release` — build a self-contained Erlang release for distribution as a runtime binary.
- File-watching: `:file_system` (Hex package, supervised) for cross-platform inotify/fsevents.

---

## Key Technical Decisions

- **Phoenix Channels over WebSocket as the v1 protocol.** Native to Phoenix, multi-client by construction, bidirectional streaming for agent-output-in / commands-back, versioned via topic naming (`design:v1:*`). MCP (Model Context Protocol) was considered but its v1 spec is still consolidating; revisit for v2.
- **Single OTP application, not an umbrella.** The pace layers are enforced by *module boundary discipline + Boundary library checks*, not by separate Mix apps. Umbrella apps add ceremony (per-app deps, version drift, build complexity) without buying enforcement that Boundary doesn't already provide. Revisit if any layer needs independent versioning.
- **Channel protocol is the only external surface.** No REST endpoints, no GraphQL, no separate gRPC. Reduces blast radius and forces the protocol to carry everything. A `/health` HTTP endpoint may exist for unauthenticated liveness only (no app data).
- **DynamicSupervisor per agent run.** One supervised GenServer per active run, owning the Port (or `Porcelain` process) that wraps the agent CLI. Crash isolation per run; daemon stays up; AE1 holds.
- **Journal storage: markdown files in user-configured workspace path under `~/code`. Index in ETS, rebuilt on startup, kept warm via supervised file-watcher.** No SQLite for v1 — the journal is small (≤ 10K entries assumed), ETS holds it comfortably, startup rebuild is sub-second at expected scale. SQLite-backed index can be added later without changing journal-on-disk shape.
- **Auth via file-secret bearer token, written by daemon at startup with mode 0600.** Same model the open-design audit recommends. Token sent in WebSocket connect params; channel join refused without it. Loopback-only Endpoint bind (`127.0.0.1`).
- **Agent CLI integration via OTP Port (`:erlang.open_port`).** Line-buffered stdout, structured JSON event parsing, graceful kill on client disconnect. `Porcelain` was considered but its maintenance has slowed; staying with built-in Ports avoids a fragile dependency.
- **U11 adapter lives in the open-design fork's web sidecar, not in the BEAM daemon.** The daemon speaks Channels only; the JS sidecar adapts to the existing `apps/web/src/providers/daemon.ts` SSE shape. This keeps the daemon's protocol clean and contains the JS-side interop work in one file.
- **Forward-applied security posture.** Every unit that introduces a network or process boundary explicitly verifies: loopback bind, auth check, sandbox-safe streaming output, validated input. This is a per-unit checklist, not a separate hardening pass.

---

## Open Questions

### Resolved During Planning

- **Protocol shape:** Phoenix Channels over WebSocket. (See Key Technical Decisions for the reasoning vs gRPC, MCP, HTTP+SSE.)
- **Project structure:** single OTP application with module-level pace-layer boundaries enforced by Boundary, not umbrella.
- **Demo client:** CLI first (U10). A web UI is deferred — the open-design adapter spike (U11) is itself the "real UI" validation.
- **Journal index storage:** ETS in-memory, rebuilt on startup. SQLite revisited only if scale warrants.
- **Workspace location:** maintainer-configurable per-workspace; daemon does not impose a layout. Default discovery: a `.beam-design.toml` (or similar) at the workspace root naming the journal directory.

### Deferred to Implementation

- **Exact agent-CLI launch arguments and env passthrough** per agent (Claude Code, Codex, Copilot, Pi, ACP). Each adapter is a few-line module; final shape depends on inspecting current CLI flags during U7.
- **Channel topic naming convention details** beyond the `design:v1:<workspace>` prefix. Sub-topics for runs, journal, design-systems get pinned during U5.
- **Workspace config file format** (`.beam-design.toml` vs `.beam-design.exs` vs `beam-design.json`). Decide during U3 based on whether maintainer-readability vs Elixir-loadability matters more in the first hour of use.
- **`mix release` configuration** for end-user installation (target: brew formula or asdf plugin in a follow-up). Skeleton must build a release; distribution shape is post-v1.
- **Exact ETS table layout** for the journal index — depends on read patterns surfaced during U8.

---

## Output Structure

The new project lives at `~/code/beam-design-daemon/`. Expected layout after U1–U2:

    beam-design-daemon/
    ├── .formatter.exs
    ├── .credo.exs
    ├── .gitignore
    ├── AGENTS.md                          # navigability for the maintainer (R2)
    ├── README.md
    ├── mix.exs
    ├── mix.lock
    ├── config/
    │   ├── config.exs
    │   ├── dev.exs
    │   ├── test.exs
    │   └── runtime.exs                    # loopback bind + auth token (R18, R19)
    ├── lib/
    │   ├── beam_design.ex                 # public top-level (rare; mostly module-only)
    │   ├── beam_design/
    │   │   ├── application.ex             # OTP supervision tree root (R6, U4)
    │   │   ├── auth/                      # SLOW: token mint + verify (R19, U9)
    │   │   ├── workspace/                 # SLOW: workspace config, paths (R7, U3)
    │   │   ├── design_systems/            # SLOW: loader + watcher (R11, U6)
    │   │   ├── skills/                    # SLOW: loader + watcher (R12, U6)
    │   │   ├── journal/                   # SLOW: index + file watch (R7, R16, U8)
    │   │   ├── runs/                      # FAST: per-run supervisor + state (R5, R15, U7)
    │   │   ├── agents/                    # FAST: per-agent CLI adapters (R5, U7)
    │   │   └── protocol/                  # CONTRACT: channel topics, message shapes (R8, R9, U5)
    │   └── beam_design_web/
    │       ├── endpoint.ex                # loopback bind, channel mounting (R18, U5, U9)
    │       ├── user_socket.ex             # auth handshake (R19, U9)
    │       └── channels/                  # one channel per top-level topic (U5)
    ├── priv/
    │   └── plts/                          # dialyzer cache
    ├── test/
    │   ├── support/
    │   ├── beam_design/
    │   └── beam_design_web/
    └── apps_demo_cli/                     # U10 throwaway CLI client; lives here so it's
                                            # visibly separate from the daemon source

Note: this is a scope declaration showing the expected output shape. The implementer may refine the layout during U1–U2 if a better division emerges. Per-unit `**Files:**` sections are authoritative for what each unit creates.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```text
                      Architect-Maintainer (A1)
                              │
                ┌─────────────┼─────────────┐
                │             │             │
              CLI           open-design   future client
            (U10 demo)    (via U11 adapter)  (any)
                │             │             │
                └─────WebSocket / Phoenix Channel─────┘
                              │
              ╔═══════════════▼═══════════════╗
              ║       BEAM Design Daemon       ║
              ║                                ║
              ║  ┌──────────────────────────┐  ║
              ║  │ CONTRACT (slowest)       │  ║
              ║  │   protocol/  topics +    │  ║   ← versioned (R9)
              ║  │             envelopes    │  ║      single external surface (R8)
              ║  └──────────────────────────┘  ║
              ║                                ║
              ║  ┌──────────────────────────┐  ║
              ║  │ SLOW                     │  ║
              ║  │   workspace/             │  ║   ← config & paths (R7)
              ║  │   design_systems/        │  ║   ← R11
              ║  │   skills/                │  ║   ← R12
              ║  │   journal/               │  ║   ← index over ~/code md files (R7, R16)
              ║  │   auth/                  │  ║   ← token mint/verify (R19)
              ║  └──────────────────────────┘  ║
              ║                                ║
              ║  ┌──────────────────────────┐  ║
              ║  │ FAST                     │  ║
              ║  │   runs/  DynamicSup → 1  │  ║   ← per-run GenServer (R5, R15)
              ║  │         GenServer per    │  ║      crash isolation (R6, AE1)
              ║  │         active run       │  ║
              ║  │   agents/  CLI adapters  │  ║   ← Port-wrapped per-CLI (R5)
              ║  └──────────────────────────┘  ║
              ║                                ║
              ║  ┌──────────────────────────┐  ║
              ║  │ Application supervisor   │  ║
              ║  │   :one_for_one over the  │  ║
              ║  │   above subtrees         │  ║
              ║  └──────────────────────────┘  ║
              ╚═══════════════╤════════════════╝
                              │
                              │ reads/writes
                              ▼
                    ~/code/<workspace>/
                      ├── design-systems/        ← R11
                      ├── skills/                ← R12
                      ├── journal/*.md           ← R7, R17 (files in workshop)
                      └── runs/<run-id>/         ← R15 provenance + artifacts
```

Channel-protocol message shape (sketch — final shapes pin down in U5):

```text
# client → server
{"event": "join",        "topic": "design:v1:<workspace>", "payload": {"token": "..."}}
{"event": "run.start",   "topic": "...", "ref": "<client-ref>",
                          "payload": {"skill_id": "...", "design_system_id": "...", "prompt": "..."}}
{"event": "run.cancel",  "topic": "...", "ref": "<client-ref>", "payload": {"run_id": "..."}}
{"event": "spec.write",  "topic": "...", "ref": "<client-ref>",
                          "payload": {"path": "journal/...md", "body": "...", "anchors": ["run_id_1", ...]}}

# server → client (push)
{"event": "run.started",  "topic": "...", "payload": {"run_id": "...", "started_at": "..."}}
{"event": "run.output",   "topic": "...", "payload": {"run_id": "...", "delta": "...", "kind": "stdout|agent|stderr"}}
{"event": "run.terminal", "topic": "...", "payload": {"run_id": "...", "status": "succeeded|failed|cancelled", "exit": ...}}
{"event": "journal.indexed", "topic": "...", "payload": {"path": "...", "anchors": [...], "indexed_at": "..."}}
{"event": "design_systems.changed", "topic": "...", "payload": {"id": "...", "change": "added|modified|removed"}}
```

---

## Implementation Units

Units are grouped into four phases for readability. The U-IDs are stable across phases.

### Phase 1 — Foundation (U1, U2, U4, U9)

- U1. **Project skeleton + tooling**

**Goal:** New Elixir project at `~/code/beam-design-daemon/` with `mix new`, Phoenix as a dep (without LiveView/HTML/static-asset generators), formatter, Credo, Dialyzer, and a top-level `AGENTS.md` that names the pace layers and links back to this plan.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Create: `mix.exs` (deps: `:phoenix`, `:phoenix_pubsub`, `:jason`, `:plug_cowboy`, `:file_system`, `{:boundary, "~> 0.10", runtime: false}`, `{:credo, only: [:dev, :test], runtime: false}`, `{:dialyxir, only: [:dev], runtime: false}`)
- Create: `.formatter.exs`, `.credo.exs`, `.gitignore`
- Create: `AGENTS.md` (pace-layer map, link to this plan, link to origin requirements doc)
- Create: `README.md` (1 page: what it is, how to start, where the journal goes)
- Create: `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs`

**Approach:**
- Use `mix new --sup beam_design`, then add Phoenix as a dep (no `mix phx.new` — that pulls in HTML/LiveView/static asset machinery this product explicitly rejects per Scope Boundaries).
- `runtime.exs` reads `BEAM_DESIGN_TOKEN_PATH` env var (defaulting to `~/.beam-design/auth-token`) and the loopback bind config — wired in U9.
- `AGENTS.md` is the maintainer's first stop on a cold return; it must name the four layers and where each lives in `lib/`.

**Patterns to follow:**
- Standard Elixir project conventions (no innovation here).
- AGENTS.md style from the open-design fork — terse, navigable, links to durable docs.

**Test scenarios:**
- Test expectation: none — pure scaffolding, no behavior. `mix compile`, `mix format --check-formatted`, and `mix credo --strict` must pass.

**Verification:**
- `mix compile` succeeds with zero warnings.
- `mix format --check-formatted` and `mix credo --strict` pass.
- `AGENTS.md` exists and a maintainer can locate the four pace-layer directories from it.

---

- U2. **Pace-layered module boundaries enforced by Boundary**

**Goal:** Module-level pace layers from the High-Level Technical Design are declared and enforced. Slow layers may not depend on fast layers; the contract layer may not depend on anything internal; fast layers may depend on slow layers but not on each other except through documented seams.

**Requirements:** R3

**Dependencies:** U1

**Files:**
- Modify: `mix.exs` (Boundary already added in U1; this unit adds the boundary check task to the default `mix compile` flow)
- Create: `lib/beam_design.ex` with a top-level `use Boundary` declaration
- Create: each pace-layer directory's `*.ex` root module with `use Boundary, deps: [...]` declarations

**Approach:**
- Declare four boundary tiers: `Contract` (`Protocol.*`), `Slow` (`Auth.*`, `Workspace.*`, `DesignSystems.*`, `Skills.*`, `Journal.*`), `Fast` (`Runs.*`, `Agents.*`), `Web` (`BeamDesignWeb.*`).
- Allowed deps: `Web → Contract, Slow, Fast`; `Fast → Slow, Contract`; `Slow → Contract`; `Contract → (none)`.
- `mix compile` fails on a boundary violation. CI gate is "compile clean."

**Execution note:** Test-first via `mix boundary` — declare the layers, attempt a violating call from `Slow` into `Fast`, confirm `mix compile` reports the violation, then remove the bad call.

**Patterns to follow:**
- The Boundary library's hexdocs has a clear monolith-with-boundaries example; mirror it.

**Test scenarios:**
- Test expectation: none — boundary rules are themselves the test. Verification is a clean `mix compile` after intentionally adding and removing a boundary violation during U2 itself.

**Verification:**
- `mix compile` flags any cross-layer dep that violates the declared graph.
- Documenting the boundary rules in `AGENTS.md` (added in U1; updated here) gives the maintainer the rule of law for future changes.

---

- U4. **OTP supervision tree skeleton**

**Goal:** `BeamDesign.Application` starts a `:one_for_one` top supervisor with placeholder children for each long-lived subsystem (workspace, design-systems, skills, journal, runs, web endpoint). Each child is a no-op stub that starts and lives, so the tree shape is inspectable in IEx before any subsystem has real behavior.

**Requirements:** R6, AE1

**Dependencies:** U1, U2

**Files:**
- Modify: `lib/beam_design/application.ex`
- Create: `lib/beam_design/workspace/supervisor.ex` (stub)
- Create: `lib/beam_design/design_systems/supervisor.ex` (stub)
- Create: `lib/beam_design/skills/supervisor.ex` (stub)
- Create: `lib/beam_design/journal/supervisor.ex` (stub)
- Create: `lib/beam_design/runs/supervisor.ex` (DynamicSupervisor stub for per-run children)
- Test: `test/beam_design/application_test.exs`

**Approach:**
- Top-level supervisor strategy: `:one_for_one`. A subsystem crash restarts only that subsystem.
- `Runs.Supervisor` is a `DynamicSupervisor` so per-run children come and go without restart-cascading.
- Each stub `child_spec` returns a process that lives forever (e.g., a GenServer that does nothing). Real behavior comes in U6, U7, U8.

**Execution note:** Test-first. Application start asserts each named supervisor is alive before any subsystem does anything.

**Patterns to follow:**
- Standard OTP `Application` + supervision-tree pattern from `hexdocs.pm/elixir/Application.html`.

**Test scenarios:**
- Happy path: `Application.start/2` returns `{:ok, pid}` and `Process.whereis(BeamDesign.Workspace.Supervisor)`, `... .DesignSystems.Supervisor`, etc., all return live PIDs.
- Edge case: killing one named child supervisor causes only that one to be restarted; siblings keep their PIDs.
- **Covers AE1.** Killing a child of `Runs.Supervisor` does not affect `Workspace.Supervisor` or any other peer subtree.

**Verification:**
- `iex -S mix` and inspecting the supervision tree shows the expected named processes.
- Test suite passes including the kill-and-survive scenarios.

---

- U9. **Auth token + loopback-only Endpoint**

**Goal:** Daemon mints a 256-bit hex token at startup, writes it to a 0600-permission file at the configured path, and refuses any WebSocket connection without `?token=<correct-token>` in the query string. Phoenix Endpoint binds only to `127.0.0.1`.

**Requirements:** R18, R19, AE3

**Dependencies:** U1, U4

**Files:**
- Create: `lib/beam_design/auth/token.ex` (mint, write file with 0600, read, timing-safe verify)
- Create: `lib/beam_design_web/endpoint.ex`
- Create: `lib/beam_design_web/user_socket.ex` (auth handshake at `connect/3`)
- Modify: `lib/beam_design/application.ex` (mint token + start endpoint)
- Modify: `config/runtime.exs`
- Test: `test/beam_design/auth/token_test.exs`
- Test: `test/beam_design_web/endpoint_bind_test.exs`
- Test: `test/beam_design_web/user_socket_test.exs`

**Approach:**
- Token: `:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)`.
- File write: `File.write!/3` with `[:write, :binary, {:mode, 0o600}]`; the parent directory created with mode 0700.
- Endpoint config in `runtime.exs`: `http: [ip: {127, 0, 0, 1}, port: <port>]`. No `https`. No `host` config that would imply LAN reachability.
- `UserSocket.connect/3` reads `params["token"]`, compares against the in-memory token via `Plug.Crypto.secure_compare/2`, returns `:error` on mismatch.

**Execution note:** Test-first. Write the failing tests for bind address, file mode, and 401-on-bad-token before implementing.

**Patterns to follow:**
- The forward-applied posture from `docs/audits/2026-05-02-bau-design-audit.md` (in the open-design fork) — same shape, ported to Elixir.

**Test scenarios:**
- Happy path: token file exists at the configured path with mode `0o600`.
- Happy path: WebSocket connect with correct `token` query param returns `{:ok, _}` from `UserSocket.connect/3`.
- Edge case: token regenerates on every daemon restart.
- Edge case: parent directory is created with mode `0o700` if absent.
- Error path: WebSocket connect with no token, wrong token, or empty token returns `:error`.
- Error path: token file write fails (read-only FS) — daemon refuses to start (does not run unauthenticated).
- **Covers AE3.** Endpoint binds only to `127.0.0.1` (assert `Process.info(endpoint_pid)` and the listening socket address); a second connect attempt without the token is rejected at the channel layer.

**Verification:**
- `pnpm`-equivalent: `mix test` passes including the auth and bind tests.
- Manual: `lsof -iTCP -sTCP:LISTEN -P` shows the daemon listening on `127.0.0.1:<port>` only.
- Manual: `stat -f '%A' ~/.beam-design/auth-token` reports `600`.

---

### Phase 2 — Core Capability (U3, U5, U6)

- U3. **Workspace model + journal location config**

**Goal:** A `Workspace` module that locates the active workspace via a `.beam-design.toml` (or chosen alternative — see Deferred to Implementation) at the workspace root. Reads the journal directory path (defaulting to `<workspace>/journal/`), validates it lives somewhere under `~/code` per origin R7, and exposes the resolved paths to other subsystems.

**Requirements:** R7, R17

**Dependencies:** U1

**Files:**
- Create: `lib/beam_design/workspace/config.ex`
- Create: `lib/beam_design/workspace/locator.ex`
- Modify: `lib/beam_design/workspace/supervisor.ex` (start a Workspace GenServer that holds the active workspace state)
- Test: `test/beam_design/workspace/config_test.exs`
- Test: `test/beam_design/workspace/locator_test.exs`

**Approach:**
- Workspace state held in a single GenServer (one workspace per daemon for v1; multi-workspace deferred). Future-flexibility note: the GenServer's identity is `{:via, Registry, ...}` so multi-workspace is a Registry change later, not a rewrite.
- The journal-must-be-under-`~/code` constraint is a soft warning, not a hard error — log loudly but allow override (the maintainer might have an unusual layout).

**Execution note:** Test-first.

**Patterns to follow:**
- Standard GenServer-as-state-holder pattern.

**Test scenarios:**
- Happy path: a workspace dir with `.beam-design.toml` naming `journal: "journal/"` resolves to `<workspace>/journal/`.
- Happy path: a workspace dir without a config file resolves journal to the default `<workspace>/journal/`.
- Edge case: an absolute journal path in the config is honored.
- Edge case: a journal path outside `~/code` triggers a warning log but proceeds.
- Error path: a malformed config file returns a structured error, daemon refuses to start the workspace.

**Verification:**
- `mix test` passes.
- IEx inspection: `BeamDesign.Workspace.current/0` returns the resolved paths as a struct.

---

- U5. **Phoenix Channel protocol v1**

**Goal:** A single channel under topic `design:v1:<workspace>` accepting the message envelopes sketched in High-Level Technical Design. Stub handlers reply with structured error events (no real run/journal/spec behavior yet — that lands in U6, U7, U8). The channel is the load-bearing slow contract per origin R8.

**Requirements:** R8, R9, R10, R20, R21

**Dependencies:** U4, U9

**Files:**
- Create: `lib/beam_design_web/channels/workspace_channel.ex`
- Create: `lib/beam_design/protocol/envelopes.ex` (incoming and outgoing message shapes as plain structs/maps; **no Ecto, no Jason custom encoders for v1**)
- Create: `lib/beam_design/protocol/version.ex` (current protocol version constant + version-mismatch helper)
- Modify: `lib/beam_design_web/user_socket.ex` (mount the workspace channel)
- Test: `test/beam_design_web/channels/workspace_channel_test.exs`

**Approach:**
- Channel `join/3` checks the topic format `design:v1:<workspace_id>`, rejects mismatches with a structured error (see AE5).
- All incoming messages flow through `Protocol.Envelopes.parse_incoming/2` which validates shape and returns `{:ok, parsed}` or `{:error, reason}`. Default-deny on unknown event names.
- Outgoing messages are constructed via `Protocol.Envelopes.build_outgoing/2` so the wire format has one source of truth.
- Stub handlers for `run.start`, `run.cancel`, `spec.write` reply with `{:reply, {:error, %{reason: "not_yet_implemented"}}, socket}` so the channel surface is testable end-to-end before any subsystem is real.

**Execution note:** Test-first. The contract is the slow layer; landing tests for it before adding any behavior makes future modifications trace through the test suite.

**Patterns to follow:**
- `Phoenix.Channel` standard patterns from hexdocs.

**Test scenarios:**
- Happy path: client joins `design:v1:my-workspace` with a valid token → join succeeds, server pushes a `welcome` event with protocol version and capabilities.
- Edge case: two clients join the same topic — both receive each other's broadcast events (e.g., `journal.indexed` push from one is observed by the other).
- Edge case: a client sends `run.start` with all required fields → channel replies `{:error, %{reason: "not_yet_implemented"}}` (placeholder; real behavior in U7).
- Error path: client sends an unknown event name → channel replies with structured error, does not crash.
- Error path: client sends `run.start` missing required fields → channel replies with `{:error, %{reason: "invalid_payload", details: [...]}}`.
- **Covers AE5.** A client joining `design:v0:my-workspace` is rejected with a clear "client too old, expected v1" error envelope, not a silent failure.
- **Covers AE1, AE3** (in part): a client without auth or with the wrong token cannot join (delegated to U9's auth, but verified end-to-end through the channel here).
- **Covers AE4** (in part): a hypothetical second client (a CLI in U10) joining the same topic receives the same broadcast events, demonstrating that the protocol is the only contract clients need.

**Verification:**
- `mix test` passes.
- A scratch IEx session can connect via `Phoenix.ChannelTest.connect/2`, join the channel, and receive the `welcome` event.

---

- U6. **Design system + skill loaders with file-watch**

**Goal:** Two supervised loaders that read the workspace's design-systems and skills directories on startup, hot-reload on disk changes via `:file_system`, and broadcast `design_systems.changed` / `skills.changed` events through the channel layer. Read-side API exposes "list available", "get by ID", and "subscribe to changes."

**Requirements:** R11, R12

**Dependencies:** U3, U4, U5

**Files:**
- Create: `lib/beam_design/design_systems/loader.ex`
- Create: `lib/beam_design/design_systems/store.ex` (in-process state holder, ETS-backed for multi-reader access)
- Create: `lib/beam_design/skills/loader.ex`
- Create: `lib/beam_design/skills/store.ex`
- Create: `lib/beam_design/fs/watcher.ex` (thin wrapper around `:file_system` so the loaders share supervision policy)
- Modify: `lib/beam_design/design_systems/supervisor.ex` (start the loader + store + watcher)
- Modify: `lib/beam_design/skills/supervisor.ex` (same shape)
- Modify: `lib/beam_design_web/channels/workspace_channel.ex` (broadcast change events)
- Test: `test/beam_design/design_systems/loader_test.exs`
- Test: `test/beam_design/skills/loader_test.exs`
- Test: `test/beam_design_web/channels/workspace_channel_change_broadcast_test.exs`

**Approach:**
- Mirror the open-design fork's `design-systems/` and `skills/` directory shape. A design system is a directory with a `DESIGN.md` and asset files; a skill is a directory with a `SKILL.md` and supporting markdown.
- Parse YAML frontmatter from the markdown for metadata; the body is opaque (passed through to clients verbatim, sandboxing is the client's job per R20).
- File-watch is debounced (250ms) — bursts of editor saves should not produce a thundering herd of broadcasts.

**Execution note:** Test-first. The "edit a file → watcher fires → store updates → channel broadcasts" chain is exactly the integration scenario test mocks would not prove.

**Patterns to follow:**
- ETS table per store, owned by the store GenServer so the table dies with the process and gets rebuilt on supervision restart.

**Test scenarios:**
- Happy path: starting the loader against a fixture directory of two design systems populates the store with both, addressable by ID.
- Happy path: same for skills.
- Edge case: a malformed `DESIGN.md` (missing required frontmatter) is logged and skipped; the rest of the directory still loads.
- Edge case: the workspace directory is empty — loader starts cleanly with an empty store.
- Error path: the workspace directory does not exist — loader logs a structured error and exits with `{:stop, :no_workspace_dir}`; supervisor restart policy holds.
- Integration: editing a `DESIGN.md` on disk triggers a `design_systems.changed` broadcast on the channel within 500ms, observed by a connected test client.
- Integration: deleting a skill directory triggers a `skills.changed` broadcast with `change: "removed"`.

**Verification:**
- `mix test` passes including the disk-edit integration scenarios.
- Manual: edit a DESIGN.md in a real workspace; observe a broadcast in an IEx-connected test client.

---

### Phase 3 — Interactive Behavior (U7, U8)

- U7. **Agent run orchestrator (Port-wrapped CLIs)**

**Goal:** `Runs.Supervisor` (DynamicSupervisor from U4) starts a `Runs.RunServer` per active run. Each `RunServer` opens a Port to the requested agent CLI, streams `stdout/stderr` line-by-line back through the channel as `run.output` events, records full provenance (skill, design system, agent CLI, model, prompts, exit status) to `runs/<run-id>/provenance.json` in the workspace, and emits `run.terminal` on exit. `run.cancel` from a client gracefully kills the Port.

**Requirements:** R5, R6, R15, AE1

**Dependencies:** U4, U5, U6

**Files:**
- Create: `lib/beam_design/runs/run_server.ex` (one GenServer per run; owns the Port)
- Create: `lib/beam_design/runs/provenance.ex` (write `provenance.json` atomically)
- Create: `lib/beam_design/agents/registry.ex` (which CLIs are available; argv-builder per CLI)
- Create: `lib/beam_design/agents/claude_code.ex` (one adapter; others deferred to follow-up plans)
- Modify: `lib/beam_design_web/channels/workspace_channel.ex` (handle `run.start` and `run.cancel`, push `run.started` / `run.output` / `run.terminal`)
- Test: `test/beam_design/runs/run_server_test.exs`
- Test: `test/beam_design_web/channels/workspace_channel_run_test.exs` (integration through the channel)

**Approach:**
- Port options: `[:binary, :exit_status, :stderr_to_stdout, :line, args: argv]`. Line-buffering keeps SSE-friendly chunking.
- Run lifecycle states: `:starting → :running → :succeeded | :failed | :cancelled`. State machine lives inside the RunServer; transitions logged.
- Provenance is written **once at start** (skill, design system, prompts, argv) and **once at terminal** (exit, end timestamp, output checksums).
- `run.cancel` sends `Port.close/1`; if the process doesn't exit within 2s, escalate to `Port.command/2` with a kill signal envelope, then force-kill via the OS as last resort.
- One agent CLI adapter for v1: Claude Code. Other agents deferred (see Deferred to Follow-Up Work).

**Execution note:** Test-first for the lifecycle transitions and cancel paths (the long-tail bugs in run orchestration are timing-sensitive — characterization tests pay off).

**Patterns to follow:**
- Standard GenServer + Port pattern; `hexdocs.pm/elixir/Port.html`.

**Test scenarios:**
- Happy path: starting a run with a fake CLI (a shell script that prints lines and exits 0) produces a `run.started`, several `run.output` events with `kind: "stdout"`, and a `run.terminal` with `status: "succeeded"`.
- Happy path: provenance.json is written at start and updated at terminal with exit status.
- Edge case: cancellation mid-run delivers a `run.terminal` with `status: "cancelled"` within 2.5s.
- Edge case: cancelling a run that has already exited is a no-op (no double-terminal event).
- Error path: starting a run with an unknown skill or design system → channel replies `{:error, %{reason: "unknown_skill"}}`, no RunServer started.
- Error path: agent CLI exits non-zero → `run.terminal` with `status: "failed"` and exit code populated.
- Error path: agent CLI binary not on PATH → `run.terminal` with `status: "failed"` and a clear error message.
- Integration: two concurrent runs on different topics emit independent event streams; killing one (force-kill of its OS process) leaves the other running. **Covers AE1.**
- Integration: client disconnect mid-run gracefully terminates the run via the channel's `terminate/2` callback.

**Verification:**
- `mix test` passes.
- Manual: run a real `claude code` invocation against a tiny prompt and observe streaming output through the channel via the U10 CLI client.

---

- U8. **Journal indexer + spec.write handler**

**Goal:** A `Journal.Indexer` watches the workspace's journal directory, parses markdown files (frontmatter + body), maintains an ETS index keyed by file path with secondary indexes by `anchors` (run IDs referenced) and `design_system_id`. Channel `spec.write` event writes a markdown file at the requested path and the indexer picks it up via the watcher (no special-case write-then-index path; the watcher is the source of truth).

**Requirements:** R7, R14, R16, AE2

**Dependencies:** U3, U5, U6

**Files:**
- Create: `lib/beam_design/journal/indexer.ex`
- Create: `lib/beam_design/journal/parser.ex` (frontmatter + body)
- Create: `lib/beam_design/journal/spec_writer.ex` (atomic write with anchor validation)
- Modify: `lib/beam_design/journal/supervisor.ex`
- Modify: `lib/beam_design_web/channels/workspace_channel.ex` (handle `spec.write`, push `journal.indexed`)
- Test: `test/beam_design/journal/indexer_test.exs`
- Test: `test/beam_design/journal/parser_test.exs`
- Test: `test/beam_design/journal/spec_writer_test.exs`
- Test: `test/beam_design_web/channels/workspace_channel_journal_test.exs`

**Approach:**
- Indexer reuses the `Fs.Watcher` from U6 with debounce.
- ETS table: `:journal_index`, owned by the Indexer GenServer; primary key is the relative path; secondary lookups via match specs.
- Anchor validation: when `spec.write` carries `anchors: [run_id_1, ...]`, each anchor must reference a real run (in `runs/<run_id>/provenance.json`); unknown anchors return `{:error, %{reason: "unknown_anchor", anchors: [...]}}`.
- Atomic write: write to a temp file in the same directory, then `File.rename!/2` — partial writes never visible to other readers.

**Execution note:** Test-first.

**Patterns to follow:**
- `Fs.Watcher` from U6.

**Test scenarios:**
- Happy path: parsing a fixture markdown with `---` frontmatter and body returns the parsed metadata and body verbatim.
- Happy path: a `spec.write` for a new file writes the file atomically, the watcher sees it, the indexer indexes it, and a `journal.indexed` event is broadcast.
- Edge case: a journal file with no frontmatter parses with empty metadata and the full body.
- Edge case: a journal file with malformed frontmatter logs a warning, indexes with empty metadata, body still readable.
- Edge case: the journal directory is empty at startup — indexer starts, ETS table exists and is empty.
- Error path: `spec.write` to a path outside the configured journal directory is rejected with `{:error, %{reason: "outside_journal_dir"}}`.
- Error path: `spec.write` with anchors that reference nonexistent runs is rejected before the file is written.
- **Covers AE2.** A spec written today, with anchors to three runs, can be located 6 months later via the index by querying for anchors-containing-run-X, and following the anchors back to the original `runs/<run-id>/provenance.json` succeeds.
- Integration: editing a journal file directly on disk (outside the daemon) triggers a re-index and a broadcast.

**Verification:**
- `mix test` passes.
- IEx: query the index with a known anchor, get the spec entry back.

---

### Phase 4 — Validation (U10, U11)

- U10. **Demo CLI client (`apps_demo_cli/`)**

**Goal:** A throwaway CLI that opens a WebSocket channel connection to the daemon, lists available skills and design systems, starts a run, streams its output to the terminal, and writes a spec entry from a multiline prompt. Validates the protocol from a real (non-test) client. Marked as throwaway scaffolding in its README.

**Requirements:** R4, R13 (in part — proves the protocol is real before U11 attempts the full open-design adapter)

**Dependencies:** U5, U6, U7, U8

**Files:**
- Create: `apps_demo_cli/mix.exs`
- Create: `apps_demo_cli/lib/demo_cli.ex` (entry point + arg parsing)
- Create: `apps_demo_cli/lib/demo_cli/client.ex` (uses `:gun` or `:websockex` to speak Phoenix Channel framing)
- Create: `apps_demo_cli/README.md` ("This is throwaway scaffolding for the BEAM Design Daemon. It is not part of the product.")
- Test: `apps_demo_cli/test/demo_cli/client_test.exs`

**Approach:**
- Subcommands: `list-skills`, `list-design-systems`, `run <skill-id> --design-system <id> --prompt <text>`, `spec <path> --anchors <id,id,...>`.
- The CLI reads the daemon's auth token from the standard path (or a `--token-file` flag) and includes it in the connect URL.
- This is the smallest credible "real client" that exercises every channel handler. It is explicitly throwaway per Scope Boundaries.

**Execution note:** Test-first for the protocol-shape assertions; the CLI surface itself can be characterization-tested.

**Patterns to follow:**
- Plain Elixir CLI patterns; `OptionParser`.

**Test scenarios:**
- Happy path: `list-skills` against a daemon with two skills returns both skill IDs.
- Happy path: `run` against the fake-CLI agent from U7's test fixture streams output to stdout and exits 0 on success.
- Happy path: `spec` writes a journal file and confirms a `journal.indexed` broadcast.
- Error path: missing token file → CLI prints a clear "auth-token not found at <path>; is the daemon running?" message and exits non-zero.
- Error path: daemon not running → CLI prints "could not connect to daemon at <url>" and exits non-zero.

**Verification:**
- `cd apps_demo_cli && mix escript.build && ./demo_cli list-skills` returns expected output against a running daemon.
- `mix test` passes.

---

- U11. **open-design adapter spike (one route)**

**Goal:** One capability of the open-design React app — pick the smallest one that exercises a full streaming run, e.g., `POST /api/runs` plus its SSE response — is rerouted through a new "BEAM mode" in the open-design web sidecar to call the BEAM daemon's WebSocket channel, translating Channel events into the SSE event union the existing `apps/web/src/providers/daemon.ts` already expects.

**Requirements:** R13, AE4

**Dependencies:** U5, U7

**Files:**
- Modify: `apps/web/sidecar/server.ts` (in the open-design fork — gated by a `BEAM_DAEMON_URL` env var so default behavior is unchanged)
- Create: `apps/web/sidecar/beam-adapter.ts` (in the open-design fork)
- Test: `apps/web/sidecar/beam-adapter.test.ts` (in the open-design fork — characterization)

**Approach:**
- The adapter opens a single shared WebSocket to the BEAM daemon (token read from the standard path), joins the workspace topic, and translates incoming Channel events to SSE-frame strings.
- Map: Channel `run.started` → SSE event `start`; `run.output` → SSE `text` or `agent` (depending on `kind`); `run.terminal` → SSE `done` (or `error` on non-zero exit).
- Default behavior (no `BEAM_DAEMON_URL` env var) is unchanged — the existing JS daemon path keeps working.
- **This unit lives in the open-design fork repo, not the BEAM project.** It validates the contract is real and adapter-able.

**Execution note:** Test-first for the event translation table; the WebSocket integration is exercised by a manual smoke test against a running BEAM daemon.

**Patterns to follow:**
- `apps/web/sidecar/server.ts` existing patterns; `apps/web/src/providers/daemon.ts` for the SSE event shapes.

**Test scenarios:**
- Happy path: a Channel `run.output` with `kind: "stdout"` translates to the same SSE frame shape `apps/web/src/providers/daemon.ts` would produce from the existing JS daemon.
- Happy path: a Channel `run.terminal` with `status: "succeeded"` translates to the SSE frame the React UI treats as run-complete.
- Edge case: with `BEAM_DAEMON_URL` unset, `apps/web/sidecar/server.ts` behaves exactly as it does on `main`.
- Error path: BEAM daemon unreachable when `BEAM_DAEMON_URL` is set → the sidecar returns a 503 with a clear message; the React UI shows a graceful failure (no infinite spinner).
- **Covers AE4.** The React UI source code is unchanged for this capability; the adapter is the only modification. Rerouting back to the JS daemon (unset `BEAM_DAEMON_URL`) restores prior behavior with no UI changes.

**Verification:**
- `pnpm --filter @open-design/web test` passes including the adapter test.
- Manual end-to-end: with `BEAM_DAEMON_URL=ws://127.0.0.1:<port>/socket` set, run the open-design web app, kick off a single run from the UI, observe streaming output identical in shape to the JS-daemon path.

---

## System-Wide Impact

- **Interaction graph:** Channel handlers depend on Slow stores (DesignSystems, Skills, Workspace) and Fast supervisors (Runs); Slow stores depend on `Fs.Watcher`; Auth gates the channel join. Boundary library enforces the dep direction at compile time (U2).
- **Error propagation:** Per-run failures stay in their `RunServer` and surface as structured `run.terminal` events. Subsystem-level failures restart only that subsystem (`:one_for_one`). Channel-level errors return `{:reply, {:error, ...}}` envelopes with a `reason` field; never crash the channel process unless an invariant is violated.
- **State lifecycle risks:** ETS tables die with their owner process; supervision restart rebuilds them from disk via the watcher's initial scan. Atomic file writes in U8 prevent partial-state visibility. Provenance JSON in U7 is written twice (start + terminal) — the start record stands alone if the run never reaches terminal.
- **API surface parity:** The Channel protocol is the only public surface. There is no REST/GraphQL parity to maintain. The U11 adapter is the bridge to open-design's existing surface, contained in one file in the JS fork.
- **Integration coverage:** Disk-edit-triggers-broadcast (U6, U8), concurrent-runs-isolated (U7, AE1), real-CLI-streaming (U10 manual smoke, U11 manual end-to-end). Mocks alone do not prove these.
- **Unchanged invariants:** The open-design fork's existing JS daemon, React UI, contract package, and audit-fix work (`fix/bau-design-remediation` branch) all continue to function. The U11 adapter is gated by an env var; the default code path through `apps/web/sidecar/server.ts` is unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| BEAM-as-stack is unfamiliar to the maintainer; productivity drops vs JS for the first few units. | Pace-layered structure + small per-unit scope means each unit is a learnable piece. AGENTS.md and Boundary enforcement substitute for institutional intuition. |
| Phoenix Channels framing is JS-friendly but the open-design adapter (U11) still requires a WebSocket client in the sidecar. | U11 is intentionally a small spike, not the full port. If the WebSocket→SSE translation is uglier than expected, that's evidence to refine the protocol *now* before more clients ship. |
| Agent CLI Port behavior under load (long-running runs, large output) is not characterized. | U7's test scenarios include concurrent runs with significant output volume against a fake CLI; real CLI smoke test in U10 catches the rest. If real-CLI behavior diverges, the agents/<adapter>.ex layer absorbs the volatility (per origin Dependencies). |
| Journal indexing scale assumption (≤ 10K entries, ETS is fine) breaks for a power user. | Index API is stable; storage backend swap to SQLite is a single-module change in the journal layer. Documented in Key Technical Decisions as the upgrade path. |
| File-watcher behavior differs across macOS / Linux / WSL. | `:file_system` library handles cross-platform; debounce window is conservative. Smoke-test on at least macOS (the maintainer's primary platform) before merging U6. |
| The U11 spike succeeds for one route but the full open-design port turns out to be a multi-week effort. | This is acknowledged in Deferred to Follow-Up Work. R13's "1–2 week integration" target applies to the spike establishing feasibility, not to the full port. |
| OWASP audit findings need to be re-derived in the BEAM project rather than ported mechanically. | U9 ports them as forward-applied posture; the same shape (loopback bind + token + sandbox-safe streaming) maps cleanly because the principles are language-agnostic. |
| Boundary library overhead on `mix compile` slows iteration. | Boundary's check is cheap (microseconds per module). If it ever becomes a bottleneck, scope the check to CI only. |

---

## Documentation / Operational Notes

- `AGENTS.md` in the new project (created in U1, expanded in U2) is the maintainer's single navigation entry. Update it when the pace-layer assignments change.
- `README.md` in the new project covers: what it is in three lines, `mix deps.get && iex -S mix` to start in dev, how to run a workspace, where the auth token lives, where the journal lives.
- A short "Connecting clients" doc explaining the Channel protocol shapes ships when U10 and U11 land — it is the contract reference, separate from internal docs.
- No release / monitoring / rollout work in this plan. v1 is local-only; ops concerns live in a follow-up plan.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-02-beam-design-daemon-requirements.md](../brainstorms/2026-05-02-beam-design-daemon-requirements.md)
- Open-design audit (forward-applied security posture): `docs/audits/2026-05-02-bau-design-audit.md`
- Companion JS-side remediation plan (work that makes open-design a good client of this daemon): `docs/plans/2026-05-02-001-fix-bau-design-remediation-plan.md`
- Open-design contract surface (anchor for U11 translation): `packages/contracts/src/`
- Open-design web sidecar (anchor for U11): `apps/web/sidecar/`
- Open-design daemon provider (target shape for U11 SSE translation): `apps/web/src/providers/daemon.ts`
- External: Phoenix Channels (`hexdocs.pm/phoenix/channels.html`), OTP Application/Supervisor docs (`hexdocs.pm/elixir/`), Boundary library (`hexdocs.pm/boundary/`), `:file_system` Hex package.
