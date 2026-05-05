---
title: "feat: BEAM bridge tool loop — make DeepInfra a real artifact-writing agent"
type: feat
status: active
date: 2026-05-04
origin: hand-conversation 2026-05-04 (chat surface gave 'go to Figma' instead of slides)
---

# feat: BEAM bridge tool loop — make DeepInfra a real artifact-writing agent

**Target tree:** open-design monorepo at `/Users/hisgarden/workspace/ml/open-design/`. All paths in this plan are relative to that root unless otherwise noted. The BEAM daemon lives at `apps/beam-daemon/` (Elixir/Phoenix subtree); the web bridge at `apps/web/sidecar/beam-bridge.ts`; the contracts at `packages/contracts/`.

---

## Summary

Today the BEAM bridge with `BEAM_AGENT_ID=deepinfra` is a thin chat passthrough. It takes the user's raw message, sends it to DeepSeek-V4-Flash as a single user-role turn, and streams text deltas back. It ignores the `skill_id` and `design_system_id` the React UI sends; it has no system prompt; it has no tools; the model has no agency to write files.

This plan turns the DeepInfra path into a **real artifact-writing code-agent** equivalent to (but smaller than) the Claude Code path. Three independently shippable phases:

- **Phase A** — load skill + design system bodies in the BEAM RunServer and inject them as a system message; the model now *understands* the html-ppt format and the active brand.
- **Phase B** — add OpenAI-style `tools=[write_file, read_file, list_files]` with a sandboxed FS execution loop in the BEAM daemon; the model writes real files.
- **Phase C** — wire `projectId` end-to-end so writes land in the JS daemon's `.od/projects/<id>/` and the web sidecar's existing file-watcher feeds them back into the preview pane live.

Each phase is observable on its own (smoke script + UI-visible behavior) and lands as a separate commit.

---

## Problem Frame

The user-visible defect: pick the **Slide deck** project type, type "make me a deck about X", and the model replies in prose ("Open Figma / Keynote / Canva, set up a 1920×1080 frame…"). The right pane stays empty. The model cannot fulfill its role with the current bridge.

Three loose contributors:

1. **No skill prompt** — `apps/beam-daemon/lib/beam_design/runs/run_server.ex#dispatch_agent("deepinfra", ...)` calls `DeepInfra.start(self(), payload["prompt"], ...)` with the raw user message. `payload["skill_id"]` is dropped on the floor.
2. **No tools** — `DeepInfra.stream/5` builds `messages: [{role: "user", content: ...}]` with no `tools` field. DeepSeek-V4-Flash supports OpenAI tool calling but the request never declares any.
3. **No project sandbox** — even if tools were defined, there's no resolved workspace path the model could write to. The bridge doesn't pass `projectId` to BEAM, and the BEAM daemon has no notion of `.od/projects/<id>/`.

Phases mirror the contributor list: A removes (1), B removes (2), C removes (3). After C, the chat surface produces real previewable artifacts entirely off DeepInfra — no Anthropic billing, no Claude Code install.

---

## Requirements

- **R1 — System prompt parity.** When a run is started with `skill_id="html-ppt"` and `design_system_id="agentic"`, the DeepInfra request includes a `system` message with the html-ppt SKILL.md body and the agentic DESIGN.md body. Verified: smoke script asserts a system message is present and contains a known string from each body.
- **R2 — File-writing tool.** The DeepInfra agent advertises a `write_file(path, content)` tool. When the model emits a `tool_calls` delta, BEAM executes the write under a sandboxed root and feeds the result back as a `tool` role message. Loop continues until the model stops calling tools.
- **R3 — Read-back tools.** `read_file(path)` and `list_files(dir?)` are also advertised so the model can inspect skill assets (e.g. `assets/template.html`, `references/layouts.md`) referenced from the SKILL.md it just received.
- **R4 — Sandbox.** All tool path arguments are normalized (`Path.expand` + symlink resolution) and rejected if they escape the project root. Same posture as the JS daemon's project-files routes.
- **R5 — Preview integration.** Files written by BEAM tool calls land at `<JS-daemon-data-dir>/projects/<projectId>/...`. The JS daemon's existing project-files watcher picks them up; the React UI's preview pane reflects them within ≤ 1 second.
- **R6 — SSE event translation.** `run.tool_use` and `run.tool_result` BEAM channel events are mapped to SSE events in the web sidecar so the chat surface shows "wrote slide-1.html" affordances exactly like the Claude Code path.
- **R7 — Backward compatibility.** Plain-text chat (no skill, no project, no tools) still works. Phase A is opt-in via skill_id presence; Phase B's tools are advertised only when a project root is resolvable.
- **R8 — Verification.** Existing `task smoke:bridge` and `task smoke:image` keep passing. New `task smoke:deck` drives a full slide-generation flow end-to-end. `task check` stays green.

---

## Scope Boundaries

### Deferred for later

- Multi-turn conversation history beyond the current run (each `run.start` is still a fresh thread).
- Tool-call cancellation mid-flight (Phase B kills the whole RunServer; finer-grained cancellation is U7-style).
- Bash / shell execution tool (deliberately omitted; html-ppt doesn't need it and it expands the sandbox surface).
- Image-attachment vision flow when the model also wants to call tools (current vision path is text-only output; cross-pollination is a follow-up).
- A second tool-capable agent in BEAM beyond DeepInfra (e.g. OpenAI-direct, Anthropic-direct). Architecture supports it; only DeepInfra is wired in this plan.
- Streaming `write_file` (current design buffers the model's full file content before write; chunked writes are a perf optimization for later).

### Outside this product's identity

- File-system tools that escape the project root (read user home, write `/etc/...`, etc.).
- A general-purpose code-agent (this is design-shaped — html-ppt, blog-post, dashboard, etc. — not a Claude Code competitor).
- Persisting tool-call traces beyond the SSE event log (provenance is a journal-layer concern, see U8 of the v1 skeleton plan).

### Deferred to Follow-Up Work

- **Tool calling for the BEAM-native ClaudeCode agent path.** ClaudeCode CLI already has its own file tools; this plan only touches DeepInfra. A unified tool-event surface across both agents is a later refactor.
- **Synthetic-run mode tool support.** `BEAM_DESIGN_SYNTHETIC_RUNS=1` produces a fake stream; teaching it to fake tool calls is low-value and skipped.

---

## Context & Research

### Relevant Code

**Already built (don't recreate):**
- `apps/beam-daemon/lib/beam_design/skills/loader.ex` — `Skills.Loader.get(id)` returns `%Skill{body: ...}` with the SKILL.md body.
- `apps/beam-daemon/lib/beam_design/design_systems/loader.ex` — `DesignSystems.Loader.get(id)` returns the same shape for DESIGN.md.
- `apps/beam-daemon/lib/beam_design/runs/run_server.ex` — owns the per-run GenServer; `dispatch_agent("deepinfra", payload)` is the integration point.
- `apps/beam-daemon/lib/beam_design/agents/deep_infra.ex` — current chat-only adapter; `stream/5` builds the request body; `parse_sse_buffer/1` already handles SSE chunking.
- `apps/web/sidecar/beam-bridge.ts` — translates between BEAM channel events and the SSE event union the React UI consumes. Already passes `skill_id` and `design_system_id`; needs `project_id` and tool-event translation.
- `apps/daemon/src/prompts/system.ts#composeSystemPrompt` — JS reference for skill+design-system prompt composition. Phase A produces a smaller Elixir analogue, not a full port.

**Touched in this plan:**
- BEAM: `apps/beam-daemon/lib/beam_design/agents/deep_infra.ex`, `apps/beam-daemon/lib/beam_design/runs/run_server.ex`, `apps/beam-daemon/lib/beam_design/web/channels/workspace_channel.ex`. New modules under `apps/beam-daemon/lib/beam_design/agents/` for tool-loop and sandbox.
- Web: `apps/web/sidecar/beam-bridge.ts` — pass `project_id` through; add `tool_use` / `tool_result` event mappings.
- Contracts: `packages/contracts/src/sse/chat.ts` — likely already has tool_use/tool_result event shapes (the JS daemon emits them); confirm and reuse.
- Smoke: new `scripts/beam-deck-smoke.ts`; new `task smoke:deck` in `Taskfile.yml`.

### External References

- DeepInfra OpenAI compat: <https://deepinfra.com/docs/advanced/openai_api>. Tools are passed as `tools: [{type: "function", function: {name, description, parameters}}]`. Tool calls arrive as `tool_calls: [{id, type: "function", function: {name, arguments}}]` deltas inside `choices[0].delta`.
- DeepSeek-V4-Flash tool-calling: documented as supported in the DeepSeek model card. Function-calling format follows OpenAI's; `parallel_tool_calls` defaults true.
- OpenAI streaming tool_calls: arguments arrive in fragments across many deltas, accumulated by `index`. Same accumulator pattern as Claude Code's tool_use partial-input handling (`apps/daemon/src/claude-stream.ts:96`).

---

## Key Technical Decisions

- **System prompt is built in Elixir, not the JS bridge.** The bridge already passes `skill_id` and `design_system_id`; making BEAM compose the system message keeps the bridge a translation layer and lets BEAM-native non-DeepInfra agents reuse the composer. Cost: a small Elixir mirror of `composeSystemPrompt`. This keeps the protocol — BEAM owns workflow, bridge owns transport.
- **Phase A composes a *minimal* system prompt: design system body + skill body.** Skip the JS daemon's discovery/philosophy/critique scaffolding for now. The skill body itself contains its workflow; adding more scaffolding before we have a working tool loop is premature optimization. Revisit after Phase C.
- **Tools are advertised conditionally.** A run without a resolvable project root gets no tools (Phase A only); a run with a project root gets `write_file` + `read_file` + `list_files`. This keeps `task smoke:bridge` (no project) working unchanged.
- **Sandbox root = the open-design project directory `<OD_DATA_DIR>/projects/<projectId>/`.** Match the JS daemon. This means BEAM needs `OD_DATA_DIR` (or its default of `<repo>/.od`) — pass via env at `task beam:up` time.
- **Tool execution is synchronous inside the RunServer GenServer.** Phase B does not spawn extra processes per tool call. File writes are fast; if any tool ever needs to be slow (e.g. network fetch), revisit with a Task per call. Synchronous keeps state transitions simple.
- **The agent loop terminates when the model emits no `tool_calls` in a turn.** Same termination rule as OpenAI-style agents. Hard cap at N=10 turns to bound runaway loops; emits a structured `error: max_iterations` if hit.
- **Tool-call SSE shape matches what the JS daemon already emits** (`event: agent`, `data: { type: "tool_use", id, name, input }` and `data: { type: "tool_result", tool_use_id, content }`). The React UI's `apps/web/src/providers/daemon.ts` already handles these from the Claude Code path, so no UI changes needed.
- **No persistence beyond the run.** Tool calls are not logged to a journal in this plan. Provenance/spec-write is U8 of the v1 skeleton plan and out of scope here.

---

## Open Questions

### Resolved during planning

- **Where does the project root come from?** The web bridge resolves `<JS-daemon-data-dir>/projects/<projectId>` server-side and passes the absolute path to BEAM as `project_dir`. BEAM does no path discovery — it only validates that the resolved path is one it's allowed to write to (must match a configured `OD_DATA_DIR/projects/*` prefix). Trust boundary: the bridge is in the same trust zone as BEAM (both run on the user's machine; bridge is the auth-token holder).
- **What happens when no project is set on the run?** Phase A still applies (skill prompt active). Phase B's tools are simply not advertised → model degrades to chat-only output. Same fallback as today.
- **OpenAI tool_calls vs Anthropic tool_use shapes — which does the SSE event match?** The JS daemon (`apps/daemon/src/claude-stream.ts`) emits Anthropic-shape `tool_use`/`tool_result`. The bridge translates from OpenAI-shape DeepInfra deltas to Anthropic-shape SSE on the way to the UI. One translator, one place.

### To resolve during execution

- **Q1 — Does the html-ppt skill body produce sensible output at DeepSeek-V4-Flash quality?** Phase A first run will tell us. If the model can't follow the skill (vs Claude Sonnet), we may need a stronger model default (DeepSeek-V4-Pro) for deck mode specifically.
- **Q2 — Tool-call concurrency.** DeepSeek may emit multiple tool_calls in one turn (parallel calls). The simplest implementation runs them sequentially; revisit if it's a noticeable latency hit.
- **Q3 — File-watcher race.** The JS daemon's project-files watcher may emit events for files BEAM is mid-writing (write/replace race). Phase C must use atomic writes (write tmp + rename) to avoid serving partial files to the preview.

---

## Plan

### Phase A — System prompt composition (~half day)

**A1. Pull skill + design-system bodies in `RunServer` before dispatching to DeepInfra.**
- File: `apps/beam-daemon/lib/beam_design/runs/run_server.ex`.
- In `dispatch_agent("deepinfra", payload)`, look up `Skills.Loader.get(payload["skill_id"])` and `DesignSystems.Loader.get(payload["design_system_id"])` (both already exist).
- Build the system message via a new module `BeamDesign.Agents.PromptComposer` (`apps/beam-daemon/lib/beam_design/agents/prompt_composer.ex`).

**A2. Implement `BeamDesign.Agents.PromptComposer.build/2`.**
- Input: `%{skill: %Skill{} | nil, design_system: %DesignSystem{} | nil}` plus `mode` (deck/prototype/etc., from `skill.metadata["od"]["mode"]`).
- Output: `String.t()` system prompt.
- Composition (mirrors JS but trimmed): design system DESIGN.md body → skill SKILL.md body → terse glue text ("Treat the active design system as authoritative for tokens. Follow the active skill's workflow exactly.").

**A3. `DeepInfra.start/3` accepts `:system` opt and prepends it to the messages array.**
- File: `apps/beam-daemon/lib/beam_design/agents/deep_infra.ex`.
- Where today the messages list is `[%{role: "user", content: ...}]`, become `[%{role: "system", content: system}, %{role: "user", content: ...}]` when `:system` is present.

**A4. Smoke script asserts the system message is wired.**
- New: `scripts/beam-prompt-smoke.ts` — drives `run.start` with `skill_id="html-ppt"`, captures the first agent chunk, and asserts the model references html-ppt-specific concepts (e.g. mentions "slide" or "deck" structure unprompted).
- Cheap heuristic check; not a perfect proof but catches regressions.

**A5. Commit.** `feat(beam-bridge): inject skill + design system as system prompt for DeepInfra runs`.

### Phase B — Tool calling (~2-3 days)

**B1. Define the tool surface.**
- New module: `BeamDesign.Agents.Tools` (`apps/beam-daemon/lib/beam_design/agents/tools.ex`).
- Function `definitions/0` returns the OpenAI tool list:
  - `write_file(path: string, content: string) -> {ok: true, path, bytes}`
  - `read_file(path: string) -> {content: string} | {error}`
  - `list_files(dir: string?) -> {entries: [{name, type, size}]}`
- All paths are interpreted relative to the run's `project_dir`.

**B2. Implement the sandbox.**
- New module: `BeamDesign.Workspace.Sandbox` (`apps/beam-daemon/lib/beam_design/workspace/sandbox.ex`).
- `safe_resolve(project_dir, rel_path) -> {:ok, abs} | {:error, :escape}`. Uses `Path.expand` + `Path.relative_to` + a final `String.starts_with?` check on the realpath.
- `write_atomic(abs_path, content) -> :ok | {:error, _}`. Writes to `<abs_path>.tmp.<rand>` then `File.rename/2` for the watcher race (Q3).
- Unit tests: trivial path, dotdot escape, symlink-out-of-root, absolute path rejection.

**B3. Tool-call accumulator in the SSE parser.**
- File: `apps/beam-daemon/lib/beam_design/agents/deep_infra.ex`.
- Extend `parse_one_event` and `parse_data_line` to recognize `tool_calls` deltas. Buffer arguments-fragments by `index`. On finish-reason `tool_calls`, emit `{:agent_tool_calls, [%{id, name, arguments}]}` to the parent.

**B4. RunServer tool execution loop.**
- File: `apps/beam-daemon/lib/beam_design/runs/run_server.ex`.
- New state fields: `:messages` (the running message list), `:project_dir`, `:tool_iterations`.
- Handle `{:agent_tool_calls, calls}`: for each call, invoke `Tools.execute/3`, append both the assistant's `tool_calls` message and the tool's `role: "tool"` results to `state.messages`, then re-invoke `DeepInfra.start/3` with the updated history.
- Cap iterations at 10; emit `run.terminal status=failed error=max_iterations` if exceeded.
- Per-call telemetry: `run.tool_use` and `run.tool_result` channel events.

**B5. Bridge translates tool events to SSE.**
- File: `apps/web/sidecar/beam-bridge.ts`.
- Add cases in `translateBeamPayload` for `run.tool_use` → `event: agent, data: {type: "tool_use", id, name, input}` and `run.tool_result` → `event: agent, data: {type: "tool_result", tool_use_id, content}`.
- Confirm the contracts in `packages/contracts/src/sse/chat.ts` already have these event shapes (the Claude Code path uses them).

**B6. `task smoke:deck` end-to-end.**
- New script: `scripts/beam-deck-smoke.ts` — creates a project via the JS daemon, kicks off a BEAM run with `skill_id=html-ppt`, drains SSE, asserts ≥ 1 file was written into the project dir AND that the file is non-empty HTML.
- New Taskfile entry: `smoke:deck`.

**B7. Commit.** `feat(beam-bridge): tool loop — write_file + read_file + list_files for DeepInfra runs`.

### Phase C — Project workspace integration (~1 day)

**C1. Bridge resolves `project_dir` and passes it to BEAM.**
- File: `apps/web/sidecar/beam-bridge.ts`.
- Read `OD_DATA_DIR` (default `<repo>/.od`); resolve `<dataDir>/projects/<body.projectId>` if `body.projectId` is set; pass as `project_dir` in the `run.start` channel payload.

**C2. BEAM channel + RunServer accept and validate `project_dir`.**
- Files: `apps/beam-daemon/lib/beam_design/web/channels/workspace_channel.ex`, `apps/beam-daemon/lib/beam_design/runs/run_server.ex`.
- Validation: `project_dir` must be absolute, must exist, and must match an `OD_DATA_DIR/projects/*` allowlist prefix (configured at boot).
- Plumb the validated path into RunServer state for the tool sandbox.

**C3. Atomic writes are the watcher contract.**
- Already done in B2's `write_atomic`; this is the unit that proves it works under the live watcher.
- Verification: drive `task smoke:deck` while observing the JS daemon's project-files SSE stream — the watcher should emit a single `add` event per file, never `add` then `change` racing.

**C4. UI verification.**
- Manual: with `task web:up:bridge` and `task beam:up` running, open the app, create a Slide deck project, ask for "a 5-slide deck about X", watch the right pane render slides as they're written.
- Automated: extend an existing Playwright spec or add a new one that mocks the BEAM endpoint to drive a deterministic write sequence and asserts the preview frame loads the written `index.html`.

**C5. Commit.** `feat(beam-bridge): project-dir wiring — DeepInfra runs land artifacts in .od/projects/<id>`.

### After C — Open verification

- All three smoke tasks (`bridge`, `image`, `deck`) green.
- `task check` green.
- Manual deck flow in the browser produces visible slides without Anthropic billing.

---

## Sequencing Notes

- A is independent and ships even if B/C never land — better-than-today output for chat-only DeepInfra usage.
- B depends on A's prompt composer (model needs the skill body to know what files to write) and on C's `project_dir` for the sandbox root. Implement B's sandbox + tool definitions first; wire `project_dir` (C1-C2) before B6's smoke runs end-to-end.
- C is small but must come before the smoke test in B6 actually verifies anything. Order during execution: A → C1-C2 → B → B6 → C3-C4.

---

## Work Log

(reverse chronological — newest on top)

### 2026-05-04 — Plan authored

Plan written by claude (auto mode) after the user reported "go to Figma" output from the BEAM bridge with html-ppt skill. Three-phase approach landed; awaiting kickoff.
