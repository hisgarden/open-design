# DeepInfra setup — chat + vision + image gen behind one key

This fork wires DeepInfra into both the chat surface (via the BEAM bridge) and the image surface (Open Design's Image tab). One `DEEPINFRA_API_KEY` covers:

- text chat (DeepSeek V4-Flash by default, V4-Pro when you want top-tier reasoning)
- vision chat (Qwen3-VL-235B for image attachments)
- image generation (5 models — Qwen-Image-Max, FLUX-2-pro, Wan-2.7-Image-Edit, Qwen-Image-Edit, Seedream-4)

No OpenAI or Anthropic billing required for the hot path.

## Get a key

Sign up at <https://deepinfra.com>, create a key from the dashboard. Models listed below are paid (`no-free-anon` tag); a small balance covers a lot of generation.

## Save the key — macOS Keychain

Storing the key in plain text in `.env` files defeats the point. macOS Keychain holds it encrypted; your shell sources it on each login.

```bash
# add the key (you'll be prompted; input is hidden):
security add-generic-password -U -a "$USER" -s "deepinfra-api-key" -w
```

Verify it's there:

```bash
security find-generic-password -s "deepinfra-api-key" -a "$USER" -w | head -c 6 ; echo "…"
```

(macOS will pop a Keychain prompt the first time `security` runs in a new shell session. Tick "Always Allow".)

Add this line to `~/.zshrc` (or your shell init):

```bash
export DEEPINFRA_API_KEY="$(security find-generic-password -a "$USER" -s 'deepinfra-api-key' -w 2>/dev/null)"
```

Reload the shell:

```bash
source ~/.zshrc
echo "${DEEPINFRA_API_KEY:0:6}…"   # should print first 6 chars + ellipsis
```

## Image surface — works immediately

After the key is in env, restart the daemon and open the Image tab. The DeepInfra section in the model picker offers four cards plus a flagged-weak option:

| Pick | When |
|---|---|
| **`Qwen-Image-Max`** | Hand-drawn, text-heavy explainers (xkcd, Thing Explainer, storybook). **Best default.** |
| `FLUX-2-pro` | Photoreal / modern illustration. Avoid for hand-drawn aesthetics. |
| `Wan-2.7-Image-Edit` | High-fidelity i2i style transfer (the crayon-rework / xkcd-rework templates point here). |
| `Qwen-Image-Edit` | Cheaper/lower-fidelity edit alternative. |
| `Seedream-4`, `FLUX-2-klein-4b` | Wired but their hints flag in-image text as weak. Use for non-label-heavy work only. |

## Chat surface — opt in via the BEAM bridge

The chat (Prototype / Slide deck) routes via the BEAM Design Daemon when `BEAM_DAEMON_URL` is set. With the bridge active, every run goes through DeepInfra (no Anthropic billing, no Claude Code install required):

```bash
# in one terminal — start the BEAM daemon (Elixir)
cd apps/beam-daemon
BEAM_DESIGN_WORKSPACE_DIR="$(pwd)/../.." mix run --no-halt

# in another terminal — start web with bridge enabled
# (or just `task web:up:bridge` — the Taskfile bakes these defaults in)
cd /Users/hisgarden/workspace/ml/open-design
BEAM_DAEMON_URL=ws://127.0.0.1:4000/socket/websocket \
BEAM_AGENT_ID=deepinfra \
BEAM_MODEL_TEXT=deepseek-ai/DeepSeek-V4-Pro \
BEAM_MODEL_VISION=Qwen/Qwen3-VL-235B-A22B-Instruct \
  pnpm tools-dev run web --daemon-port 17456 --web-port 17573
```

The bridge auto-routes by request shape:
- text-only chats → `BEAM_MODEL_TEXT` (DeepSeek V4-Pro for the tool-loop deck path)
- chats with image attachments → `BEAM_MODEL_VISION` (Qwen3-VL-235B, ~$0.88/1M out)

Without `BEAM_DAEMON_URL`, the chat surface uses the JS daemon's CLI-agent path (Claude Code etc.) exactly as upstream does.

## Tool loop: what makes the deck path different

When `skill_id=html-ppt` (or any skill that asks the agent to *write* artifacts) and a project is set, the BEAM bridge advertises three OpenAI-compatible function tools — `write_file`, `read_file`, `list_files` — sandboxed under `<OD_DATA_DIR>/projects/<id>/`. The model writes real HTML files; the JS daemon's project-files watcher feeds them into the React UI's preview pane.

This is what gives you slides on the right side of the screen instead of "go to Figma" prose.

**Model-selection caveats** — verified across DeepInfra-hosted models, baked into the smoke-test defaults:

- **V4-Pro** is the right default for the deck path. Slower (~60-180s per turn) but reliably round-trips long tool_call content arguments (5-10KB of HTML per call).
- **V4-Flash** silently truncates long tool_call content args to `""`. Fine for plain chat; do NOT use for the deck path.
- Other DeepInfra models tried and ruled out: Qwen3-Max (no tool_call IDs), Llama-3.3-70B (announces intent but doesn't call), Kimi K2 (whitespace deltas), Kimi K2.6 (hallucinates content), Step-3.5-Flash (announces but doesn't call).

## Conversation memory across runs

Consecutive runs on the same `conversationId` (which the React UI mints automatically per chat thread) share message history via an ETS-backed BEAM-side store. Turn 2 sees turn 1's user message + assistant tool_calls + tool_results without any project re-upload — the model picks up the thread from where it left off.

This means "now make slide 2 darker" works the way you'd expect after the deck is generated, instead of starting from scratch.

## Optional — alternative text-tier models

```bash
# Cheap chat-only mode (no tool calls, no deck generation)
BEAM_MODEL_TEXT=deepseek-ai/DeepSeek-V4-Flash

# Legacy v3.2 (slightly older + slightly more expensive than v4-flash; no reason to pick this for fresh setups)
BEAM_MODEL_TEXT=deepseek-ai/DeepSeek-V3.2
```

## Smoke-test the wire without the UI

A CLI smoke that drives the daemon's image route directly:

```bash
node --experimental-strip-types scripts/qwen-image-edit-smoke.ts \
  --model wan-2.7-image-edit \
  --image /path/to/reference.png \
  --template prompt-templates/image/illustration-crayon-kid-drawing-rework.json \
  --name "first-test"
```

Output lands in `.od/projects/qwen-img-smoke-first-test-<ts>/`. On macOS the script `open`s the result automatically.

For text-only or t2i smoke, omit `--image` and use a t2i model:

```bash
node --experimental-strip-types scripts/qwen-image-edit-smoke.ts \
  --model qwen-image-max \
  --prompt "your prompt here" \
  --name "t2i-test"
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `403 cross-origin request rejected` from `/api/projects/:id/media/generate` | Daemon's `isLocalSameOrigin` guard fired; you're hitting the daemon from a non-127.0.0.1 origin. Use the script (which binds to localhost) instead. |
| `deepinfra image 422: string_too_long` | Prompt exceeded 2100 chars (DeepInfra inference cap). Trim. |
| `deepinfra image 500: request_info init exception` | Model-specific — its body schema needs more than `{prompt}`. Check `apps/daemon/src/media.ts:DEEPINFRA_IMAGE_MODELS` for the per-model `buildBody`. |
| `deepinfra image: response had no images/output/image field` | Decoder didn't recognize the response shape. Inspect the raw response (curl direct to `/v1/inference/<model>`) and add the missing key to `renderDeepInfraImage`'s fall-through. |
| Garbled text in generated images | Inherent t2i limitation when many small labels are asked at once. Reduce label count, re-roll, or accept and overlay real text in post-edit. |

## Related docs

- [`FORK-DELTA.md`](./FORK-DELTA.md) — what this fork adds vs. upstream
- [`scripts/README-beam-bridge.md`](../scripts/README-beam-bridge.md) — bridge architecture, event translation, smoke recipes
- `apps/beam-daemon/AGENTS.md` — BEAM-side architecture (inside the subtree)
