---
title: "feat: BEAM conversation resumption — runs on the same conversationId form one thread"
type: feat
status: active
date: 2026-05-05
origin: docs/research/2026-05-05-multica-architecture-notes.md (#4 in the borrow checklist)
---

# feat: BEAM conversation resumption

**Target tree:** open-design monorepo at `/Users/hisgarden/workspace/ml/open-design/`. BEAM daemon at `apps/beam-daemon/`; web bridge at `apps/web/sidecar/beam-bridge.ts`.

---

## Summary

Today every BEAM run is independent. The user types "make a deck about coffee", DeepInfra writes `index.html`, the run terminates, the per-run GenServer dies. The user types "now make slide 2 darker" — a fresh run with no memory of slide 1, no message history, no skill context already digested. The agent re-reads everything (or worse, ignores the prior context entirely).

This plan stitches consecutive runs on the same `conversationId` into one coherent thread. After this lands, "make slide 2 darker" picks up where the prior run left off — the model sees its own prior tool calls, its own writes, the user's prior turn — without us re-uploading the project on every request.

Three independently shippable phases. 4A and 4B are pure plumbing (no LLM behavior change). 4C is where the user-visible win lands.

---

## Problem Frame

Today's path on a follow-up turn:

1. React UI sends `POST /api/runs` with the same `conversationId` it sent before — but the bridge drops it on the way to BEAM (the field exists in `ChatRequestLike` at `apps/web/sidecar/beam-bridge.ts:234` but is never put into the `run.start` payload).
2. BEAM's `WorkspaceChannel` receives `run.start` with no conversation context.
3. `RunServer.dispatch_agent("deepinfra", payload)` builds a fresh `messages` list of `[system, user]` — the system prompt comes from the skill body, the user message is whatever was just typed.
4. DeepInfra streams a response that has never seen the prior conversation. If the user is referring to "slide 2" from earlier, the model has no slide 1 in context to compare against.

The defect is that `conversationId` exists in the contract surface but nothing in BEAM treats it as a load-bearing key.

---

## Requirements

- **R1 — `conversation_id` flows end-to-end.** React UI → bridge → BEAM channel → RunServer → Conversations store. Verified: `task smoke:bridge` driven twice with the same `conversationId` shows the second run's request payload includes the first run's user message + assistant response in `messages`.
- **R2 — DeepInfra runs on the same conversationId share a message history.** A second run sees the first run's user message, assistant tool_calls, and tool results in its initial `messages` payload. The agent CLI never receives a re-uploaded project — it just sees the prior conversation.
- **R3 — The store survives RunServer death within a daemon process.** ETS-backed, written to before the per-run GenServer terminates. Lost on daemon restart in v1 (durable persistence is a follow-up).
- **R4 — Backward compatibility.** Runs without `conversation_id` (Phase B's smoke, anything pre-this-change) keep working unchanged. The store is consulted only when an id is supplied.
- **R5 — Conversations are per-workspace.** A run started on `design:v1:workspace-A` cannot read messages stored under `design:v1:workspace-B` even if the conversation_id collides. Compound key: `{workspace_id, conversation_id}`.
- **R6 — Verification.** New `task smoke:bridge:thread` drives a 2-turn smoke: turn 1 writes a file, turn 2 references the file by name and the model's response confirms it has the prior file context. Existing `smoke:bridge`, `smoke:image`, `smoke:deck`, `task check` all stay green.

---

## Scope Boundaries

### Deferred for later

- **Claude Code session-id resumption.** Claude Code's CLI takes `--resume <session_id>`; this plan does not capture or pass that. DeepInfra-only resumption first; Claude Code is its own follow-up plan.
- **Persistence across daemon restarts.** v1 is RAM-only. A follow-up plan adds journal-backed snapshots so a daemon crash mid-conversation doesn't reset the thread.
- **Message-history compaction.** Long threads will eventually exceed the model's context window. v1 sends every prior turn unchanged; sliding-window or summarization is a separate plan.
- **Multi-agent threads.** If a user switches agents mid-conversation (claude → deepinfra), v1 does NOT translate Claude's session into DeepInfra's message history (or vice versa). Each agent type sees only the messages it itself authored.
- **Conversation eviction.** v1 has no LRU; entries persist for the daemon's lifetime. Real eviction is a separate plan.
- **Status-event early pinning** (multica's `Message.SessionID` on `:status` events). Phase 4D candidate; v1 only persists at run.terminal time.

### Outside this product's identity

- A user-facing "thread history" UI surface — that already exists in the React UI as the chat conversation; we're just making BEAM honor it server-side.
- A Linear-style "issue / project / task" data model — that's multica's product shape, not ours.
- Cross-machine conversation sync — single-daemon-per-machine is the design; sync is out of scope.

---

## Context & Research

### Relevant code

**Already built (don't recreate):**
- `apps/web/sidecar/beam-bridge.ts:234` — `conversationId` already declared in `ChatRequestLike`, just unused in the `run.start` payload at line 429-437.
- `apps/beam-daemon/lib/beam_design/web/channels/workspace_channel.ex:201` — `validate_run_start/1` validates required fields; conversation_id is optional and pass-through-able.
- `apps/beam-daemon/lib/beam_design/runs/run_server.ex:104` — `dispatch_agent("deepinfra", payload, state)` is where messages are assembled. Hook point for "load prior history before building messages".
- ETS is already used by `Skills.Loader` and `DesignSystems.Loader` — same pattern transfers.

**Touched in this plan:**
- New module: `apps/beam-daemon/lib/beam_design/conversations/store.ex` — ETS-backed per-conversation state.
- New boundary: `apps/beam-daemon/lib/beam_design/conversations.ex`.
- `apps/beam-daemon/lib/beam_design/application.ex` — supervise the new store.
- `apps/beam-daemon/lib/beam_design/runs/run_server.ex` — read+write the store on `:agent_turn_done`.
- `apps/beam-daemon/lib/beam_design/runs.ex` — Boundary deps update to include `Conversations`.
- `apps/web/sidecar/beam-bridge.ts` — pass `conversation_id` in `run.start`.
- `scripts/beam-thread-smoke.ts` (new) + `Taskfile.yml` (new task entry).

### External references

- multica's `prior_session_id` / `prior_work_dir` plumbing (`server/internal/daemon/types.go`) — load-bearing pattern we're cribbing structurally.
- OpenAI tool-calling spec — assistant tool_calls + role:tool messages must round-trip with stable IDs. Phase B already nailed this for one turn; we just persist the same shape across turns.

---

## Key Technical Decisions

- **ETS for v1, not GenServer state, not SQLite.** ETS gives concurrent reads from any RunServer without contention. GenServer-as-store would serialize all reads; SQLite would add a dep + migration story for what is currently a pure RAM concern. When persistence becomes a real requirement (daemon restart resumption), revisit with a journal-on-disk pattern (same shape as `Skills.Loader`'s file-watcher).
- **Compound key `{workspace_id, conversation_id}`.** Two workspaces with colliding conversation_ids must not bleed into each other. R5.
- **Persist the *whole* message list, not just deltas.** Cheap (a few KB per turn) and avoids reconstruction bugs on read. Compaction is a future concern.
- **Persist at `:agent_turn_done` and at `run.terminal`.** Multi-turn tool loops persist between turns so a mid-conversation crash doesn't lose the partial trace. multica calls this "early pinning"; we land it cheaply because we already have a turn-completion hook.
- **The store does not own message-shape concerns.** It treats messages as opaque JSON-serializable maps. Knowing what a "message" looks like is the agent adapter's job. This keeps `BeamDesign.Conversations` a generic per-conversation kv, not a DeepInfra-specific module.
- **No "first run vs follow-up run" distinction at the API level.** Every run-start passes `conversation_id` (or doesn't); the store handles "I have priors" vs "fresh start" transparently. The web bridge always sends it when present.
- **Deferred: claude-code session_id capture.** That work touches `BeamDesign.Agents.ClaudeCode` and the JSON event parser, not the conversations store. Storing a Claude session_id is one extra field in the store struct when the time comes; the data shape already accommodates it.

---

## Open Questions

### Resolved during planning

- **Where does `conversation_id` come from on first turn?** The React UI mints it on conversation creation (`POST /api/projects/:id/conversations`). The bridge already receives it in `ChatRequestLike.conversationId`. No daemon-side minting needed.
- **What if two runs on the same conversation start simultaneously?** Won't happen at the UI level (React UI gates one in-flight run per conversation), but defensively: the second `RunServer` reads the store at dispatch time, gets whatever was last committed, and proceeds. The first run's later writes will append on top of the second's — slight risk of message-order anomaly but no corruption. Acceptable for v1; UI gating makes it a non-issue in practice.
- **What about the existing `smoke:deck` script?** It does NOT pass `conversation_id`, so it stays unchanged — fresh-thread behavior is the no-id default. New `smoke:bridge:thread` exercises the new path.

### To resolve during execution

- **Q1 — Should we cap message history at N turns to prevent context-overflow embarrassment in v1?** Probably yes, ~50-turn cap with newest kept. But low priority — html-ppt deck threads rarely exceed 5 turns. Tactical decision during 4C.
- **Q2 — Should the store key off the workspace channel's `workspace_id` socket assignment, or should the bridge send it explicitly?** The channel already has it via `socket.assigns.workspace_id`. Cleanest is BEAM-side: pull from socket, don't trust the bridge. Decision during 4B.

---

## Plan

### Phase 4A — Bridge plumbing (~half day)

**4A.1.** `apps/web/sidecar/beam-bridge.ts` — add `conversation_id: body.conversationId` to the `run.start` payload (sibling of `project_dir`, `skill_id`, etc.). Conditional spread so undefined doesn't show up as the literal string "undefined".

**4A.2.** `apps/beam-daemon/lib/beam_design/web/channels/workspace_channel.ex` — `validate_run_start/1` keeps `conversation_id` optional. Channel pulls `workspace_id` from the topic (it already does for other purposes) and passes both to `Runs.Supervisor.start_run`.

**4A.3.** `apps/beam-daemon/lib/beam_design/runs/run_server.ex` — read `payload["conversation_id"]` and `payload["workspace_id"]` into State, but no behavior change yet. Logs both at info level for verification.

**4A.4.** Manual probe: drive `task smoke:bridge` twice with explicit `conversationId` in the curl body; confirm BEAM log shows the same id both times.

**4A.5.** Commit: `feat(beam-bridge): plumb conversation_id from web bridge to BEAM RunServer`.

### Phase 4B — Conversations store (~half day)

**4B.1.** New module: `apps/beam-daemon/lib/beam_design/conversations.ex` — Boundary declaration: `use Boundary, deps: [BeamDesign.Protocol], exports: [Store]`.

**4B.2.** New module: `apps/beam-daemon/lib/beam_design/conversations/store.ex` — GenServer supervising an ETS table. Public API:
  - `start_link/1`
  - `get(workspace_id, conversation_id) :: {:ok, %ConversationState{}} | :not_found`
  - `put_messages(workspace_id, conversation_id, messages)` (replace whole list — cheap, simple)
  - `clear(workspace_id, conversation_id)` (for tests / explicit user "new thread")
  - `count/0` (telemetry)
  - `ConversationState` struct: `%{workspace_id, conversation_id, messages, updated_at, agent_session_ids: %{}}`. `agent_session_ids` is reserved for the Claude Code follow-up; left empty in this plan.

**4B.3.** `apps/beam-daemon/lib/beam_design/application.ex` — supervise `BeamDesign.Conversations.Store` after `Skills.Supervisor` and `DesignSystems.Supervisor`.

**4B.4.** Tests: `apps/beam-daemon/test/beam_design/conversations/store_test.exs` — get-not-found, put-then-get, workspace isolation, replace semantics, count.

**4B.5.** Commit: `feat(beam): per-conversation message store (ETS-backed)`.

### Phase 4C — DeepInfra resumption (~half day)

**4C.1.** `apps/beam-daemon/lib/beam_design/runs/run_server.ex` — extend Runs Boundary deps to include `Conversations`. In `dispatch_agent("deepinfra", payload, state)`:
  - Read prior messages via `Conversations.Store.get(workspace_id, conversation_id)`.
  - If found: initial `messages` list = prior_messages ++ [new_user_msg]. The system message is NOT prepended again — it lives at the head of the prior history.
  - If not found: initial `messages` list = [system, new_user_msg] (current Phase B behavior).

**4C.2.** Persist the running message list at every turn boundary. In the existing `:agent_tool_calls` handler, after appending assistant tool_calls + tool results, immediately call `Conversations.Store.put_messages(workspace_id, conversation_id, state.messages)`. Same in `:agent_turn_done` for the final-stop case.

**4C.3.** Conditional: skip all of 4C.1/4C.2 if `conversation_id` is nil. Backward-compat: Phase B's smoke and any other no-conversation_id callers keep working.

**4C.4.** New script: `scripts/beam-thread-smoke.ts`. Two-turn smoke driving the same `conversationId`:
  - Turn 1: `"Use write_file to create index.html with a single <h1>Coffee</h1>."`. Asserts the file lands.
  - Turn 2: `"What did you write to index.html in your last turn? Answer in one sentence."`. Asserts the model's response references "Coffee" or "h1" — proving it has the prior history.
  - DeepInfra's response in turn 2 is text-only, so we just check the streamed text deltas.

**4C.5.** New task: `task smoke:bridge:thread` invokes the script.

**4C.6.** Commit: `feat(beam-bridge): DeepInfra conversation resumption — runs on the same conversationId share message history`.

---

## Sequencing Notes

4A is independent and ships value (clean log output when conversations are tagged). 4B is independent (the store works without consumers). 4C depends on both.

Execution order: 4A → 4B → 4C. Tests at every phase; commit at every phase boundary.

---

## Work Log

(reverse chronological — newest on top)

### 2026-05-05 — Plan authored

After landing Phase B+C of the tool-loop plan and reading the multica architecture brief (`docs/research/2026-05-05-multica-architecture-notes.md`), the highest-leverage gap is "every run is amnesiac". This plan addresses #4 in the multica borrow-list (session-resumption), starting with the DeepInfra path. Claude Code resumption is a parallel follow-up that touches the agent adapter, not the conversations store.
