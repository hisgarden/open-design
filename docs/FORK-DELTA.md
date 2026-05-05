# Fork delta — `hisgarden/open-design`

This fork extends [`nexu-io/open-design`](https://github.com/nexu-io/open-design) with two complementary additions, both opt-in and gated by env vars (default behavior matches upstream byte-for-byte when nothing is configured):

## 1. BEAM Design Daemon as an alternate back-end

A parallel re-implementation of the daemon in Elixir/Phoenix on the BEAM VM, reachable from the existing React UI without any UI code changes. Each run becomes a supervised GenServer reachable through a Phoenix Channel — replacing the JS event-loop architecture's "share one process for all concurrent agents" with BEAM/OTP supervision and message-passing.

| Surface | What you get |
|---|---|
| `apps/beam-daemon/` | Full Elixir source (subtree-merged from `hisgarden/beam-design-daemon`). Has its own `mix.exs` + `lib/` + `test/`; pnpm ignores it. |
| `apps/web/sidecar/beam-bridge.ts` | Translation layer. Gated by `BEAM_DAEMON_URL`. When set, intercepts `POST /api/runs`, `GET /api/runs/:id/events`, and `POST /api/runs/:id/cancel` before they hit the JS daemon. When unset, no-op. |

**The DeepInfra path is now a real artifact-writing code agent**, not a chat passthrough. The BEAM daemon offers `write_file` / `read_file` / `list_files` as OpenAI-compatible function tools (sandboxed under `<project_dir>` = `<OD_DATA_DIR>/projects/<id>`). When chat with `skill_id=html-ppt` lands, the model writes real `index.html` (etc.) into the project directory; the JS daemon's project-files watcher picks them up and the React UI's preview pane renders them — entirely off DeepInfra, no Anthropic billing, no Claude Code install.

Consecutive runs on the same `conversationId` share message history via an ETS-backed `BeamDesign.Conversations.Store`, keyed by `{workspace_id, conversation_id}`. Turn 2 sees turn 1's user msg + assistant tool_calls + tool_results without re-uploading the project — true thread continuity, the load-bearing "agent-as-teammate" piece.

**Bridge env knobs:**

| Var | Effect |
|---|---|
| `BEAM_DAEMON_URL` | `ws://...` URL of the BEAM Phoenix endpoint. Unset → bridge disabled. |
| `BEAM_AGENT_ID` | Forces every run to a specific BEAM agent (`deepinfra` / `claude-code`), overriding the UI's pick. When set, the bridge also drops the UI's `body.model` (it would name the prior agent's vocab — e.g. `claude-sonnet-4-5` — and DeepInfra wouldn't host it). |
| `BEAM_MODEL_TEXT` | Default model for text-only chats. **For tool-loop / deck generation, use `deepseek-ai/DeepSeek-V4-Pro`** — V4-Flash truncates long tool_call content arguments to `""`. V4-Pro is slower (~60-180s per turn) but reliable. |
| `BEAM_MODEL_VISION` | Default model when chat carries image attachments. Recommended: `Qwen/Qwen3-VL-235B-A22B-Instruct` (~$0.88/1M out). |
| `BEAM_MODEL` | Legacy single-tier fallback when `_TEXT`/`_VISION` aren't set. |
| `BEAM_ATTACHMENT_ROOTS` | Colon-separated roots for resolving relative attachment paths (default: sidecar cwd). |
| `BEAM_MAX_IMAGE_BYTES` | Hard cap per attached image (default 5 MiB). |

**Smoke tests:**

| Task | What it proves |
|---|---|
| `task smoke:bridge` | Chat passthrough works end-to-end (BEAM → DeepInfra → SSE). |
| `task smoke:image` | Image generation (separate path: JS daemon → DeepInfra `/api/media/generate`). |
| `task smoke:deck` | Tool loop writes a real `index.html` deck under `.od/projects/<id>/`. |
| `task smoke:bridge:thread` | Conversation memory: turn 2 recovers a marker from turn 1 without being told. |

**Model selection caveats** (verified 2026-05-04 across DeepInfra-hosted models):

- **DeepSeek-V4-Pro** — flagship; reliable tool-call ID emission and long content args. Default for `BEAM_MODEL_TEXT` when running the deck path. Slower (~60-180s).
- **DeepSeek-V4-Flash** — fast for plain chat; **silently truncates long tool_call content args to `""`**. Don't use for the deck path.
- **Qwen3-Max** — produces real HTML in tool args but doesn't emit tool_call IDs. The bridge synthesizes IDs to keep the loop converging, but some providers may still fail to correlate; flagged-risky.
- **Llama-3.3-70B-Instruct, Step-3.5-Flash** — announce intent ("I'll create…") in text but don't actually call the tool. Don't use.
- **Kimi K2 / K2.6** — whitespace-only deltas (K2) or hallucinated content (K2.6 produced invoice prose when asked for a coffee deck). Don't use.

See [`scripts/README-beam-bridge.md`](../scripts/README-beam-bridge.md) and [`docs/plans/2026-05-04-003-feat-beam-bridge-tool-loop-plan.md`](./plans/2026-05-04-003-feat-beam-bridge-tool-loop-plan.md) for the full architecture and verification stories.

## 2. DeepInfra as a first-class image provider

The Image tab now lists DeepInfra alongside OpenAI / Volcengine / xAI Grok in the model picker, with five wired models covering text-to-image and image-to-image:

| Model | Mode | When to use |
|---|---|---|
| `qwen-image-max` | t2i | **Default for hand-drawn / text-heavy explainers** (xkcd, Thing Explainer, storybook). |
| `flux-2-pro` | t2i | Top-tier for **photoreal / modern illustration**; weak on hand-drawn aesthetics. |
| `wan-2.7-image-edit` | i2i | High-fidelity style transfer (e.g., reworking an existing image into the crayon template). |
| `qwen-image-edit` | i2i | Cheaper / lower-fidelity edit. |
| `seedream-4`, `flux-2-klein-4b` | t2i | Hint-flagged: in-image text rendering is weak. Use for non-label-heavy aesthetics. |

Single API key (`DEEPINFRA_API_KEY`) covers all five. See [`docs/deepinfra-setup.md`](./deepinfra-setup.md) for the keychain-backed setup story.

## Three new prompt templates

Image-to-image rework templates that pair naturally with `wan-2.7-image-edit`:

| Template | Best for |
|---|---|
| `illustration-crayon-kid-drawing-rework` | Warm, decorative, kid-storybook explainers (already in upstream). |
| `illustration-xkcd-stick-figure-rework` | Quick comic-strip explainers, dry-humor diagrams. |
| `illustration-thing-explainer-rework` | Deeply-labeled technical explainers using only the *ten hundred most-used English words* — the right pick for jargon-heavy concepts (privacy, cryptography, infrastructure). Embeds a translation table for credentials/protocol jargon. |

## Practical lessons captured during smoke testing

These are baked into the model picker hints so future users don't have to re-discover them:

1. **`Qwen-Image-Max` for text-heavy work.** Best in-image text rendering of any DeepInfra-hosted model tested. Hit-or-miss but workable; re-roll on garble.
2. **`FLUX-2-pro` is style-specific.** Excellent on photoreal/modern; **does not understand "xkcd" or "hand-drawn" anchors** — pivots to clean vector-icon style instead.
3. **Label density is the bottleneck**, not the model. Dense Kasumigaseki-style callouts garble every model; cap at ~5–6 labels per image for legibility.
4. **Save keepers immediately.** Each generation is independent; same prompt won't re-roll the same image.
5. **`flux-2-klein-4b` and `seedream-4`** are wired but flagged-weak for text. Pick them only when text fidelity doesn't matter.

## Hybrid repo arrangement

The BEAM daemon source lives in **two places** by design:

- `hisgarden/beam-design-daemon` (private, default branch `feat/v1-skeleton`) — canonical for BEAM-only commits.
- `apps/beam-daemon/` here — synced via `git subtree`. Bidirectional sync stays open:

```bash
# pull BEAM-only changes from the standalone repo
git subtree pull --prefix=apps/beam-daemon \
  /Users/jwen/code/beam-design-daemon feat/v1-skeleton

# push BEAM-only changes back to the standalone repo
git subtree push --prefix=apps/beam-daemon \
  /Users/jwen/code/beam-design-daemon feat/v1-skeleton
```

## What's NOT in this fork

- **No new npm dependencies** — the bridge uses Node 22+'s built-in WebSocket, EventEmitter, and fs.
- **No upstream behavior changed** — every addition is gated by env or only triggers on new picker selections.
- **No CLI agent removed** — Claude Code, Codex, etc. still work as upstream intends.
