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

Requires `pnpm` ≥ 10.33.2.

### Forcing DeepInfra (or any other BEAM agent) regardless of UI pick

The JS daemon's `/api/agents` only advertises CLI agents (`claude` / `codex` / `gemini` / etc.), so the React UI never offers `deepinfra` as a picker option. Two env knobs let the bridge override at the seam:

| Env var | Effect |
|---|---|
| `BEAM_AGENT_ID` | Forces every run to this BEAM agent id (e.g. `deepinfra`), regardless of what the UI sent. Unset → use the UI's pick via `AGENT_ID_TO_BEAM`. |
| `BEAM_MODEL` | Default model forwarded to BEAM when the UI doesn't carry one. e.g. `deepseek-ai/DeepSeek-V3.2`, `Qwen/Qwen3-Max`, `zai-org/GLM-5.1`. |

```bash
# Terminal 1 — BEAM daemon (DEEPINFRA_API_KEY must be in env)
cd ~/code/beam-design-daemon
BEAM_DESIGN_WORKSPACE_DIR=/Users/jwen/workspace/ml/open-design \
  DEEPINFRA_API_KEY="$DEEPINFRA_API_KEY" \
  mix run --no-halt

# Terminal 2 — web in DeepInfra-only mode (vision-capable default)
cd ~/workspace/ml/open-design
BEAM_DAEMON_URL=ws://127.0.0.1:4000/socket/websocket \
BEAM_AGENT_ID=deepinfra \
BEAM_MODEL=Qwen/Qwen3-VL-235B-A22B-Instruct \
  pnpm tools-dev run web --daemon-port 17456 --web-port 17573
```

Now any chat in the UI streams through DeepInfra's OpenAI-compatible API (`https://api.deepinfra.com/v1/openai`) using the chosen model.

#### Recommended model for Open Design

Open Design's job — extracting palette / typography / layout intent from screenshots, sketches, or reference images, and rendering design systems and prototypes from briefs — needs a real **vision-language** flagship, not a text-only coding model. Default:

| Model | Why |
|---|---|
| **`Qwen/Qwen3-VL-235B-A22B-Instruct`** | DeepInfra's flagship dedicated vision-language model (235B MoE, ~$0.88/1M output). Purpose-built for visual grounding — UI screenshot reading, color/layout extraction, typography description. Already validated in the user's Continue config with the `image_input` capability. **Set as the bridge's default vision model.** |
| `zai-org/GLM-4.6V` | Strong runner-up — newer GLM-V family with reasoning toggle. Swap in if Qwen3-VL is degraded. |
| `Qwen/Qwen3.5-122B-A10B`, `Qwen/Qwen3.6-35B-A3B` | General-purpose multimodal flagships. Better when text dominates and image is incidental. |
| `anthropic/claude-4-opus` (on DeepInfra) | Excellent vision — but routes back to Anthropic upstream and defeats the "escape Anthropic billing" goal of using DeepInfra in the first place. |
| Continue-config coding models (`DeepSeek-V3.2`, `Qwen3-Max`, `Kimi-K2.6`) | Text-only on DeepInfra's text-generation surface — fine for code-heavy chat but wrong tool for design vision. |

#### Image input — current gap, intentional

Setting `BEAM_MODEL` to a vision-capable model is *necessary but not sufficient* for image attachments to reach the model. The BEAM `deep_infra.ex` adapter today sends `messages: [%{role: "user", content: prompt}]` — text-only. To forward image attachments from the React UI's chat (drag-drop / paste), two things must land:

1. **BEAM `deep_infra.ex`** — accept an `images` opt and emit OpenAI's content-array form: `content: [{type: "text", text: ...}, {type: "image_url", image_url: {url: "data:..." or remote URL}}]`.
2. **Bridge** (`apps/web/sidecar/beam-bridge.ts`) — forward `body.attachments` (already in `ChatRequest`) into the `run.start` payload as the channel's `images` field.

Until both ship, the vision model is set up correctly for *text* prompts that *describe* design intent. Image input is a follow-up, separate from the bridge's MVP scope.

##### Other DeepInfra models worth keeping in mind

For specialized non-design needs: `moonshotai/Kimi-K2.6` (multimodal agentic), `deepseek-ai/DeepSeek-V3.2` (cheap text), `Qwen/Qwen3-Max-Thinking` (top-tier reasoning, expensive).

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
- ✅ Live web sidecar against BEAM daemon (DeepInfra path, `pnpm tools-dev run web` on `:17573`): `POST /api/runs` returned `runId=beam_…` (bridge prefix, confirming the bridge handled it ahead of the JS daemon proxy), `GET /api/runs/:id/events` streamed `start → agent text_delta×N ("Hello, it's nice to meet you.") → end status=succeeded code=0`. This closes the only remaining contract assertion left after the smoke test (Next.js + sidecar plumbing exercises the same bridge code path).

## Known gaps (deferred follow-ups, not blocking)

- **Run cancel mid-stream**: closes the socket but doesn't ask the daemon to kill the agent CLI. Real cancel arrives with the BEAM project's U7 follow-up.
- **Multi-tenancy on a single bridge instance**: the run registry is process-local. One sidecar instance per workspace is the current model.
- **Reconnect**: the bridge does not auto-reconnect a dropped WebSocket; the run terminates as failed. Enough for v1 since runs are short.
- **Agent ID coverage**: `AGENT_ID_TO_BEAM` only maps the names open-design's UI surfaces today (`claude`/`claude-code`/`anthropic`/`deepinfra`). Add mappings as new BEAM agents land.
