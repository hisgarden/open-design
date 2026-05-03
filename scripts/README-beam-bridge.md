# BEAM Daemon ↔ open-design React bridge

The full U11 from the BEAM plan: `apps/web/sidecar/beam-bridge.ts` lets the existing open-design React app drive the BEAM Design Daemon at `~/code/beam-design-daemon` as its backend, with **zero React UI changes**.

Together with the U6 loaders (which give the daemon real design-system + skill content), this clears the BEAM project's MVP Definition of Done. See `~/code/beam-design-daemon/AGENTS.md` § "MVP Definition of Done".

## How it works

The sidecar (`apps/web/sidecar/server.ts`) inspects `BEAM_DAEMON_URL` at startup. When set, three routes get intercepted before they hit the JS daemon proxy:

| Route | Bridge behavior |
|---|---|
| `POST /api/runs` | Opens WebSocket to BEAM daemon, joins `design:v1:<workspace>`, sends `run.start`. Returns `{runId}` synchronously (mirrors JS daemon's 202). Buffers translated events keyed by runId. |
| `GET /api/runs/:id/events` | Opens SSE stream. Replays the buffered events (so a fast subscriber doesn't miss `start`), then forwards live channel events translated to `ChatSseEvent` shape. |
| `POST /api/runs/:id/cancel` | Closes the WebSocket. (BEAM channel's `run.cancel` returns `not_yet_implemented` until the daemon's U7 cancel-mid-run lands; closing the socket is the safe v1 fallback.) |

All other `/api/*` routes proxy to the JS daemon as today. With `BEAM_DAEMON_URL` unset, behavior is **identical** to `main`.

## Event translation

| BEAM channel event | SSE event (per `packages/contracts/src/sse/chat.ts`) |
|---|---|
| `run.started` (synthetic at bridge boot) | `start` (`ChatSseStartPayload`) |
| `run.output` `kind=agent` | `agent` `{type: "text_delta", delta}` |
| `run.output` `kind=status` | `agent` `{type: "status", label}` |
| `run.output` `kind=stdout` | `stdout` `{chunk}` |
| `run.output` `kind=stderr` | `stderr` `{chunk}` |
| `run.terminal status=succeeded` | `end` `{code: 0, status: "succeeded"}` |
| `run.terminal status=failed` | `end` `{code, status: "failed"}` |
| `run.terminal status=cancelled` | `end` `{code, status: "canceled"}` |

The agent ID is mapped: `claude` / `claude-code` / `anthropic` → BEAM `claude-code`; `deepinfra` → BEAM `deepinfra`. Add new mappings in `beam-bridge.ts` `AGENT_ID_TO_BEAM`.

## Run it

### Live UI demo (preferred — once `pnpm install` is unblocked)

```bash
# Terminal 1 — BEAM daemon, pointed at this open-design tree
cd ~/code/beam-design-daemon
BEAM_DESIGN_WORKSPACE_DIR=/Users/jwen/workspace/ml/open-design \
  mix run --no-halt

# Terminal 2 — open-design web in BEAM bridge mode
cd ~/workspace/ml/open-design
BEAM_DAEMON_URL=ws://127.0.0.1:4000/socket/websocket \
  pnpm tools-dev run web --daemon-port 17456 --web-port 17573

# Open http://127.0.0.1:17573, start a chat — the run goes through BEAM.
```

Note: this requires `pnpm` ≥ 10.33.2. Currently blocked on the user's box (still 10.4.0); `brew upgrade pnpm` resolves it.

### Bridge smoke test (Bun, no pnpm needed)

While the full UI loop is blocked on pnpm, this drives the bridge directly using Node's built-in fetch / WebSocket / `http.createServer`:

```bash
# Terminal 1 — same as above
cd ~/code/beam-design-daemon
BEAM_DESIGN_WORKSPACE_DIR=/Users/jwen/workspace/ml/open-design \
  mix run --no-halt

# Terminal 2 — exercise the bridge handlers in isolation
cd ~/workspace/ml/open-design
BEAM_DAEMON_URL=ws://127.0.0.1:4000/socket/websocket \
  bun scripts/beam-bridge-smoke.mjs

# Switch agents:
BEAM_DAEMON_URL=... BEAM_AGENT_ID=deepinfra \
  BEAM_MESSAGE="..." \
  bun scripts/beam-bridge-smoke.mjs
```

Expected: `POST /api/runs → 202 runId=...`, then SSE frames in `start → agent text_delta… → end status=succeeded` shape — exactly what `apps/web/src/providers/daemon.ts` parses today.

The smoke test script is debug scaffolding (per the standing rule). It is not part of any release.

## Verification status as of `feat/beam-react-bridge`

- ✅ Bridge handlers compile and run (Bun execution path, types validated by `tsc` against the bridge's exported surface)
- ✅ Smoke test against live BEAM daemon (Claude Code path: 202 + start + agent + end shape correct, terminating in `failed/code=1` due to maintainer's Anthropic billing zero — proves error path)
- ✅ Smoke test against live BEAM daemon (DeepInfra path: 202 + start + 248 chars of agent text_delta streaming + `end/code=0`)
- ⚠ Full React UI live demo deferred until `pnpm install` is unblocked (`brew upgrade pnpm` on the maintainer's box). The bridge handlers are byte-for-byte the same code the sidecar will exercise; the only thing the UI demo proves beyond the smoke test is "Next.js + React rendering on top doesn't change anything" — not a contract risk.

## Known gaps (deferred follow-ups, not blocking)

- **Run cancel mid-stream**: closes the socket but doesn't ask the daemon to kill the agent CLI. Real cancel arrives with the BEAM project's U7 follow-up.
- **Multi-tenancy on a single bridge instance**: the run registry is process-local. One sidecar instance per workspace is the current model.
- **Reconnect**: the bridge does not auto-reconnect a dropped WebSocket; the run terminates as failed. Enough for v1 since runs are short.
- **Agent ID coverage**: `AGENT_ID_TO_BEAM` only maps the names open-design's UI surfaces today (`claude`/`claude-code`/`anthropic`/`deepinfra`). Add mappings as new BEAM agents land.
