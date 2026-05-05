---
title: "Research notes: multica-ai/multica daemon-and-runtime architecture"
type: research
status: draft
date: 2026-05-05
source: github.com/multica-ai/multica@main
---

# Research notes: multica-ai/multica daemon-and-runtime architecture

## Project shape (one-liner)

**Linear-style task tracker where AI coding agents are first-class teammates.** Built on Go + Next.js + Electron + Phoenix-style WebSocket. The daemon is the local-machine arm that lets a remote-hosted server delegate tasks to the AI CLIs already on your laptop.

This is **NOT** what we are (we're a local-first design tool, no remote server, no managed-issue product). But the daemon-and-runtime *plumbing* is sound and worth borrowing in pieces.

## PATH-scan agent detection — the wire shape

`server/internal/daemon/config.go#LoadConfig` does the canonical PATH probe. The pattern, per-agent:

```go
claudePath := envOrDefault("MULTICA_CLAUDE_PATH", "claude")
if _, err := exec.LookPath(claudePath); err == nil {
    agents["claude"] = AgentEntry{
        Path:  claudePath,
        Model: strings.TrimSpace(os.Getenv("MULTICA_CLAUDE_MODEL")),
    }
}
```

Eleven agents probed: `claude, codex, copilot, opencode, openclaw, hermes, gemini, pi, cursor (cursor-agent), kimi, kiro (kiro-cli)`. Each has:

- A default bin name on PATH (`claude`, `codex`, etc. — `cursor-agent` and `kiro-cli` are non-obvious)
- An env override for the path: `MULTICA_<X>_PATH`
- An env override for the model: `MULTICA_<X>_MODEL`
- An env override for extra CLI args: `MULTICA_<X>_ARGS` (parsed via shell-args)

Empty registry → hard fail with the full menu in the error message: *"no agent CLI found: install claude, codex, copilot, opencode, openclaw, hermes, gemini, pi, cursor-agent, kimi, or kiro-cli and ensure it is on PATH"*.

Detection happens once at config load. Drift (user installs a new agent later) requires daemon restart. Multica's `wakeup.go` reconnects the WebSocket on `runtimeSetCh` so the server immediately learns about restart-time additions.

`server/pkg/agent/agent.go` defines a thin `Backend` interface that all 11 agents implement:

```go
type Backend interface {
    Execute(ctx, prompt, opts ExecOptions) (*Session, error)
}
type Session struct {
    Messages <-chan Message
    Result   <-chan Result
}
```

`LaunchHeader` (same file) maps each agent to a user-visible skeleton like `"claude (stream-json)"`, `"codex app-server"`, `"hermes acp"`. Settings UI shows this so users know what their `MULTICA_<X>_ARGS` get appended to.

## Daemon trust boundary

**Multica's daemon is NOT the privileged kernel** — it's the *local arm* of a remote server. Trust:

- Daemon authenticates *outbound* to the Multica server with an OAuth bearer token stored in `~/.multica/<profile>/auth.json` (90-day PAT minted via `multica login`).
- Daemon binds **only** a localhost `/health` HTTP endpoint on port 19514 (`server/internal/daemon/health.go`). This is read-only metadata (PID, uptime, registered agents, watched workspaces) — no agent execution surface here.
- All command-control goes the *other* direction: server pushes tasks to daemon via WebSocket (`daemonws.hub.go`) plus a 3-second polling fallback.
- Stable daemon identity: `~/.multica/daemon.id` is a one-time-minted UUID v7 written with mode 0600 (`identity.go#EnsureDaemonID`). Survives hostname `.local` drift, profile renames, mDNS state changes.
- `LegacyDaemonIDs` returns historical-format IDs (`<hostname>`, `<hostname>.local`, `<hostname>-<profile>`) emitted at register time so the server can merge old runtime rows into the new UUID-keyed row.

**Compare to ours:** open-design has the *opposite* trust model — the BEAM daemon IS the privileged kernel. Workspace lives on the user's machine, the daemon owns the FS, and clients (the React UI, future editors) connect inbound via WebSocket. So multica's outbound-bearer-token model doesn't translate, but the **stable-UUID identity file** absolutely does — we currently have `BEAM_DESIGN_TOKEN_PATH` for auth but no persistent daemon UUID. Adding one would let multi-client scenarios deduplicate "is this still the same daemon I was talking to" cleanly.

## Agent-as-teammate primitives

Three pieces worth highlighting:

**1. Richer `Message` enum than ours** (`server/pkg/agent/agent.go`):

```go
const (
    MessageText       MessageType = "text"
    MessageThinking   MessageType = "thinking"   // CoT visibility
    MessageToolUse    MessageType = "tool-use"
    MessageToolResult MessageType = "tool-result"
    MessageStatus     MessageType = "status"     // run-state heartbeat
    MessageError      MessageType = "error"
    MessageLog        MessageType = "log"
)
```

Our BEAM `run.output` lumps `:agent | :status | :stderr | :stdout` into `kind`. A typed enum like multica's would let the React UI render thinking/status events distinctly (chain-of-thought transparency, latency masking) without sniffing strings.

**2. Session resumption across runs** (`server/internal/daemon/types.go`):

```go
type Task struct {
    ...
    PriorSessionID string // Claude session ID from a previous task on this issue
    PriorWorkDir   string // work_dir from a previous task on this issue
    ...
}
type ExecOptions struct {
    ...
    ResumeSessionID string // resume a previous agent session
    ...
}
type Message struct {
    ...
    SessionID string // backend session id (Status), for early resume-pointer pinning
    ...
}
```

Each Claude/Codex run captures its session ID; the next run on the same issue resumes that session. The pin happens early (in the `:status` message, before the run completes) so even an interrupted run leaves a recoverable pointer. **This is the actual "agent as teammate" load-bearing piece** — it's what makes "delegate task X to claude" feel like a continuing thread instead of a one-shot. Worth adopting.

**3. Workspace garbage collection** (`server/internal/daemon/gc.go` + `CLI_AND_DAEMON.md`):

Per-task workdir tracked via `.gc_meta.json`. Three modes: full cleanup (done/cancelled + 24h TTL), orphan cleanup (no `.gc_meta.json` + 72h TTL), artifact-only cleanup (preserves `source`, `.git`, `output/`, `logs/`, `.gc_meta.json`; drops `node_modules`, `.next`, `.turbo`). Patterns are basename-only — entries with `/` are silently dropped to prevent path injection. `.git` subtrees are never descended.

We don't have any GC story today (`.od/projects/<id>/` accumulates indefinitely). Adopting the basename-only artifact-pattern model is cheap and high-value.

## Borrow / avoid checklist for our BEAM daemon

| Borrow | Why |
|---|---|
| **PATH-scan pattern**: env override per agent (`<DAEMON>_<X>_PATH` / `_MODEL` / `_ARGS`), `:os.find_executable/1`, `LaunchHeader` shown in settings UI | We currently only have `claude-code` and `deepinfra`. The 11-agent surface multica enumerates is the right target for our agent registry. |
| **Stable daemon UUID** at `~/.beam-design/daemon.id` (mode 0600, UUID v7) | Multi-client deduplication; survives hostname drift. |
| **Typed `Message` enum** with `:thinking` and `:status` events distinct from `:text` | Lets the React UI render CoT and run-state heartbeats correctly without string-sniffing. Affects our `run.output` envelope. |
| **Session-resumption protocol fields** (`prior_session_id`, `prior_work_dir`, `resume_session_id`, early pinning via status events) | The single biggest "agent as teammate" affordance. Threads runs together across the conversation. |
| **Per-workdir `.gc_meta.json` + basename-only artifact patterns** | Cheap, durable cleanup story for `.od/projects/<id>/`. |
| **Clear "agent = entry in a typed registry"** vs. "agent = string passed around" | Our `BeamDesign.Agents.Registry` exists but is thin; widening it to mirror multica's `AgentEntry{Path, Model, Args, Headers}` would force us to design the agent surface explicitly. |

| Avoid | Why |
|---|---|
| **Server-side 3-second polling** (`PollInterval`) | Multica needs it because their server is remote. Our protocol is Phoenix-Channel; the channel push-pulls itself. Adding a poll loop would just duplicate work. |
| **Per-task workspace clone model** (`workspaces_root`, agent runs in a fresh checkout) | They clone repos into ephemeral task dirs because their tasks are issue-scoped. We operate on the user's actual workspace; cloning would break the local-first promise. |
| **Issue/Project/Comment/Inbox data model** | That's their product surface (Linear-for-AI). Not ours. |
| **Outbound OAuth bearer + 90-day PAT** | We're inbound-only; loopback bind + token-on-disk is the right model. Adopting OAuth would just add ceremony. |
| **`runtime_id` as a separate concept from `agent_id`** | They use it because one daemon registers N runtime rows (one per workspace × agent). Our model is one daemon per user; collapsing to `agent_id` keeps the surface smaller. |

## Open questions surfaced by this read

1. Does our `Phoenix.Channel` topic shape need an explicit "session" primitive, or is per-`run_id` good enough? Multica has session IDs that span multiple tasks; we currently have run IDs that are single-shot. Worth deciding before we build a "continue thread" UX.
2. Should `BeamDesign.Agents.Registry` materialize a typed `AgentEntry` struct (path, model, args, launch_header) instead of just listing module names? Cost: ~half-day refactor. Win: settings UI surface, env-override consistency, easier 4th/5th/Nth agent additions.
3. The `MessageType` widening (add `:thinking`, `:status`) is a contract-shape change in `packages/contracts/src/sse/chat.ts`. Worth doing in one bundled commit alongside the BEAM channel change.

## References

- `multica-ai/multica@main:CLI_AND_DAEMON.md` — operator-facing daemon doc
- `multica-ai/multica@main:server/internal/daemon/config.go` — PATH-scan + env-override pattern
- `multica-ai/multica@main:server/internal/daemon/identity.go` — stable UUID + legacy migration
- `multica-ai/multica@main:server/internal/daemon/health.go` — local control-plane shape
- `multica-ai/multica@main:server/internal/daemon/types.go` — Task/Agent/Result wire types
- `multica-ai/multica@main:server/internal/daemon/wakeup.go` — WS push-with-poll-fallback
- `multica-ai/multica@main:server/pkg/agent/agent.go` — Backend interface, Message enum
