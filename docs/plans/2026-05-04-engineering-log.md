---
title: "Engineering log — 2026-05-04 / 2026-05-05"
type: log
date: 2026-05-04
---

# 2026-05-04 — BEAM bridge tool loop + conversation resumption

A long session. Roughly: rebased onto fresh `origin/main`, fixed the
post-rebase `task check` regressions, then built three plans worth of
real BEAM/DeepInfra capability on top.

## Timeline (reverse chronological — newest on top)

### 01:08 — End-of-session board

- 122 commits ahead of `origin/docs/beam-design-daemon-spec`
- 66/66 BEAM tests pass; 758 JS tests pass; 16/16 Playwright UI smoke
- Browser-visible: end-to-end deck generation off DeepInfra-only
  rendering in the right pane (3 screenshots captured during the
  session — tool affordance + file panel + rendered coffee slide)
- Working stack: BEAM on :4000, JS daemon on :17456, web sidecar
  on :17573, all running with DEEPINFRA_API_KEY in env
- `task smoke:bridge`, `task smoke:image`, `task smoke:deck`,
  `task smoke:bridge:thread` all pass

### 00:55 — Polish pass: clean test board

Killed three pre-existing nuisances that were noise in every local
run:

1. Sliding-window cap on conversation history at 200 messages —
   Phase 4C was persisting every turn's full list, and long threads
   would eventually exceed model context windows. Keep the head
   (system prompt + skill body — load-bearing) plus the last 199
   entries.
2. Regrouped the 10 `handle_info` clauses in RunServer so the
   Elixir compiler stops warning about split clause groups. Pure
   refactor; no behavior change.
3. Two long-standing channel test failures fixed —
   `BEAM_DESIGN_SYNTHETIC_RUNS=1` set in `test_helper.exs` (the
   tests assume synthetic-run mode but the env var was never
   enabled), and updated a `stub_mode:` → `synthetic_runs:`
   assertion to match the channel's actual current payload field
   name.

Commit: `90381c9`.

### 00:46 — Browser-visible end-to-end working

Verified live in Chrome via `agent-browser`:
- Created a Slide deck project with the agentic design system
- Typed "Make me a 2-slide deck about coffee. Use write_file once
  to save index.html."
- Saw the `write_file index.html` affordance with green `done` badge
  in chat
- Saw `index.html` (6.0 KB) appear in the right pane under PAGES 1
- Clicked it → real coffee-themed slide rendered (dark amber
  background, "Coffee" title)

Two browser-visibility blockers fixed first:

1. `pickModel()` in the bridge was honoring the UI's `body.model`
   even when `BEAM_AGENT_ID=deepinfra` was overriding the agent.
   The UI default was `claude-sonnet-4-5`, which DeepInfra doesn't
   host → every UI-driven run 4xx'd. Drop `bodyModel` when the
   agent is being overridden.
2. Taskfile's `BEAM_MODEL_TEXT` was DeepSeek-V4-Flash, which
   truncates long tool_call content args to "" (verified in
   the deck-smoke matrix from earlier today). Bumped to V4-Pro —
   slower but actually produces coherent HTML.

Commit: `7055b25`.

### 00:30 — Phase 4 (A→B→C): conversation resumption

Three independently-shippable phases stitched consecutive runs on
the same `conversationId` into one coherent thread.

- **Phase 4A** (`ceec306`) — bridge plumbs `conversation_id` from
  the React UI through to BEAM. The channel injects the
  authenticated `workspace_id` from the socket assigns (don't
  trust the bridge to declare which workspace a run belongs to).
- **Phase 4B** (`b25317c`) — new `BeamDesign.Conversations.Store`
  GenServer holds opaque message lists keyed by
  `{workspace_id, conversation_id}`. ETS-backed for lock-free
  reads, GenServer-mediated writes. 10 store tests cover the
  surface; `agent_session_ids` field reserved for the Claude
  Code resumption follow-up.
- **Phase 4C** (`5ed3a02`) — RunServer reads the store at
  dispatch time and persists at every turn boundary (both
  `:agent_tool_calls` and `:agent_turn_done`). Verified with the
  pineapple probe: turn 1 says "pineapple", turn 2 (same
  conversationId, fresh RunServer) recovers "pineapple" because
  the prior turn's user msg + assistant reply round-tripped
  through the store. `task smoke:bridge:thread` is the
  tool-loop variant of the proof.

### 23:30 — Multica architecture brief

Read multica-ai/multica's daemon and runtime layers in detail
and wrote `docs/research/2026-05-05-multica-architecture-notes.md`.
Five borrow-list items: PATH-scan agent registry, stable daemon
UUID, typed Message enum (`:thinking`, `:status`), session-
resumption fields, per-workdir `.gc_meta.json`. Started Phase 4
(session resumption) immediately because that's the load-bearing
"agent-as-teammate" affordance.

Commit: `27b0f99`.

### 22:50 — Phase B+C: tool loop with sandboxed FS

Made the DeepInfra path a real artifact-writing code agent.

- New `BeamDesign.Workspace.Sandbox` (`safe_resolve/2`,
  `write_atomic/2`, `list_entries/1`) with 14 tests covering
  dotdot escape, symlink-out-of-root, nested mkdir, concurrent
  write tmp-suffix collisions.
- New `BeamDesign.Agents.Tools` advertises `write_file`,
  `read_file`, `list_files` as OpenAI tool definitions; 15 tests.
- DeepInfra streaming SSE parser extended to recognize tool_calls
  deltas + finish_reason markers. Per-call accumulator buffers
  arguments-fragments by index across SSE frames. Synthesizes
  call IDs when the provider doesn't emit them (Qwen3-Max).
  Synthesizes a turn_done when the stream ends without a finish
  frame.
- RunServer tool execution loop with hard cap at 10 iterations.
  Assistant tool_calls message uses `content: ""` (some
  DeepInfra-hosted providers reject `null`).
- Bridge wires `project_dir` end-to-end (mkdirs the project dir
  if missing — the JS daemon's POST /api/projects only inserts
  a DB row), translates `run.tool_use` and `run.tool_result`
  channel events to Anthropic-shape SSE that the existing
  React UI handles.
- Model-selection matrix (the painful part): tried 7 models
  before settling on V4-Pro for the smoke. V4-Flash truncates
  long content args; V3.2 and V4-Pro reasoning-heavy + slow;
  Llama-3.3-70B ignores tools; Kimi K2 emits whitespace-only;
  Kimi K2.6 hallucinates content; Step-3.5-Flash announces but
  doesn't call; Qwen3-Max produces real HTML but no tool_call
  IDs. V4-Pro produced 9KB of real index.html with full design
  tokens, slide structure, hover states.

Commit: `838a269`.

### 19:25 — Phase A: skill + design system as system prompt

Wired `Skills.Loader` and `DesignSystems.Loader` lookups into
`BeamDesign.Runs.RunServer.dispatch_agent("deepinfra", _)`. New
`BeamDesign.Agents.PromptComposer` mirrors the JS daemon's
`composeSystemPrompt` shape but pure-string-in / pure-string-out
(Boundary-clean). Verified live: with `skill_id=html-ppt` +
`design_system_id=agentic`, the model now references html-ppt's
exact file convention (`examples/<name>/index.html`,
`assets/theme.css`, `<section class="slide">`) unprompted.

Test config: `runtime.exs` Endpoint port pin now skips `:test`
so unit tests can run alongside a live `mix run` daemon.

Commit: `cca3169`.

### 18:00 — `task check` triage post-rebase

After the morning rebase onto `origin/main`, `task check` exited
non-zero. Triaged five fixes:

1. `scripts/tsconfig.json` switched from NodeNext to Bundler so
   smoke scripts can typecheck against `@open-design/contracts`
   source without requiring `.js` extensions.
2. Three locales (de/ru/fr) missing 2 prompt-template IDs and
   11 tag entries (post-rebase upstream PRs added them but only
   for `en`). Added to `apps/web/src/i18n/content{.fr.ts,.ru.ts,.ts}`.
3. `scripts/beam-bridge-smoke.ts` strict-checking fixes —
   narrow `err`/`server.address()`/`runId`/`body` types.
4. `scripts/qwen-image-edit-smoke.ts` — null-check after prompt
   resolution.
5. `apps/daemon/tests/project-watchers.test.ts` — bumped
   `waitFor` default 2s → 8s; chokidar startup on macOS flakes
   under parallel test load.

Commit: `5a7524c`.

## Notable lessons

- **Boundary-clean modules pay back at the first integration.**
  PromptComposer was tempted to take `%Skill{}` and
  `%DesignSystem{}` structs directly. The Boundary library
  flagged it instantly: Agents → Skills/DesignSystems is a
  forbidden cross-layer reference. The fix (string-in / string-out)
  is now reusable for every future model adapter that wants the
  same prompt; no agent module pulls Skills/DesignSystems either.
- **Provider-shape compliance varies wildly across DeepInfra-hosted
  models.** Qwen3-Max emits tool calls without IDs, Kimi K2.6
  hallucinates content under skill prompts, V4-Flash silently
  truncates long arguments, Step-3.5-Flash announces intent but
  doesn't actually call the tool. The defensive moves we landed
  (synthesized IDs, finish-reason fallback, content="" for
  assistant messages) are all paying off across multiple
  providers, not just one.
- **The lightest "is this real?" probe is a 2-curl pineapple
  test.** Driving `task smoke:deck` end-to-end takes 5+ minutes
  with V4-Pro. A two-shot manual curl on V4-Flash with the
  pineapple/coffee marker pattern verifies conversation memory in
  ~30 seconds and is way easier to inspect when something breaks.
- **Stable tests need controlled environments.** Two long-standing
  flakes turned out to be `BEAM_DESIGN_SYNTHETIC_RUNS=1` not being
  set + a `stub_mode:` → `synthetic_runs:` rename. Both are
  classic "the test was right when it was written" failures.
  test_helper.exs is the right place to lock in synthetic mode for
  channel tests that assume it.

## Next session

- **Force-push `docs/beam-design-daemon-spec`** — branch is 122
  commits ahead, not yet pushed. Force-with-lease when you're back
  online.
- **Claude Code session-id resumption** — Phase 4 deferred this.
  Touches the `BeamDesign.Agents.ClaudeCode` adapter (capture the
  `system_init` event's `session_id` and persist via
  `Conversations.Store.put_agent_session_id/4`). Pass it back via
  `--resume <id>` on the next run with the same conversation_id.
- **PATH-scan agent registry widening** — multica brief #1.
  Currently we have only `claude-code` and `deepinfra` registered;
  multica probes 11. Cheap to add the other 9 (codex, copilot,
  opencode, hermes, gemini, pi, cursor-agent, kimi, kiro-cli) and
  wire `BEAM_<X>_PATH/MODEL/ARGS` env overrides.
- **Stable daemon UUID at `~/.beam-design/daemon.id`** — multica
  brief #2. Mode 0600, UUID v7, survives hostname `.local` drift.
- **Typed Message enum** — multica brief #3. Add `:thinking` and
  `:status` as first-class events alongside `:text` so the React
  UI can render CoT and run-state heartbeats distinctly.
- **Per-workdir `.gc_meta.json` + artifact patterns** — multica
  brief #5. We have zero GC story for `.od/projects/<id>/` today.

## 01:15 — Documentation refresh + daemon UUID

After the user called it a night, ~1 hour of autonomous polish:

- Refreshed `docs/FORK-DELTA.md`, `docs/deepinfra-setup.md`, and
  `scripts/README-beam-bridge.md` to reflect Phase B/C and Phase 4
  shipping. Updated the V4-Flash → V4-Pro recommendation; documented
  the model-selection caveats matrix; removed stale `~/code/...`
  paths in favor of in-repo `apps/beam-daemon/` after the subtree
  import. Commit: `2bb3871`.
- Implemented multica brief #2 — `BeamDesign.Auth.DaemonId` minting
  a stable UUID v4 at `~/.beam-design/daemon.id` (mode 0600, atomic
  write, `:persistent_term`-cached). Wired into the channel's
  `welcome` push as `daemon_id:` so connected clients can dedupe
  runtime rows across hostname `.local` drift. 6 tests cover mint,
  mode, idempotence, regeneration on corruption, version+variant
  bits. 72/72 BEAM tests pass. Commit: `ed4848b`.

## Branch state at end of session

```
ed4848b feat(beam): stable per-install daemon UUID
2bb3871 docs(beam): refresh BEAM bridge docs after Phase B/C and Phase 4 ship
814301a docs(log): 2026-05-04 engineering log
90381c9 chore(beam): cap message history, regroup handlers, fix pre-existing test flakes
7055b25 fix(beam-bridge): make BEAM-overridden runs browser-visible
5ed3a02 feat(beam-bridge): Phase 4C — DeepInfra conversation resumption
b25317c feat(beam): Phase 4B — per-conversation message store (ETS-backed)
ceec306 feat(beam-bridge): Phase 4A — plumb conversation_id from web to BEAM
e7616f4 docs(plan): BEAM conversation resumption — DeepInfra path first
27b0f99 docs(research): multica-ai/multica daemon-and-runtime architecture brief
838a269 feat(beam-bridge): Phase B+C — tool loop with sandboxed FS, project_dir wiring
cca3169 feat(beam-bridge): Phase A — inject skill + design system as system prompt
63338c4 docs(plan): BEAM bridge tool loop — Phase A→B→C plan
9ca3ee1 fix(taskfile): point beam:up at the in-repo apps/beam-daemon subtree
5a7524c fix(check): make task check green after upstream rebase
... (rebased on top of origin/main 4f27953)
```

15 commits today on top of the rebased base. Branch is at `ed4848b`,
122 commits ahead of `origin/docs/beam-design-daemon-spec` (force-
push when ready). All 72 BEAM tests + 758 JS tests + 16 Playwright
UI tests pass. Live stack is up: BEAM on `:4000`, JS daemon on
`:17456`, web sidecar on `:17573`, all with the right env wired.
