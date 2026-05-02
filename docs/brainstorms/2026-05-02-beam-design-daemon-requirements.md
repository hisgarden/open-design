---
date: 2026-05-02
topic: beam-design-daemon
---

# BEAM Design Daemon — a long-running local brain that owns the slow layers of an architect-maintainer's design practice

## Summary

A long-running local daemon, written in Elixir/OTP, that owns the slow layers of an architect-maintainer's design practice — design system, skills protocol, agent-CLI orchestration, journal indexing — and exposes them via a small documented protocol. Existing tools (open-design, editors, terminals) become clients; the journal lives directly as markdown in the user's `~/code` workshop and the design knowledge produced there travels into other projects naturally.

---

## Problem Frame

A solo product designer / solution architect uses agent-CLI tools (Claude Code, Codex, Copilot, Pi, ACP) to produce shipping UI and design specifications from a curated design system. The work happens intermittently — they live with the codebase, return to it after weeks or months, and need to maintain it without paying a relearning tax each time.

Today's full-stack apps that bundle this workflow (open-design among them) collapse the slow and fast layers into one codebase. A 2433-line server file mixes routing, persistence, validation, and provider integration. UI god-components carry both rendering and business state. The maintainer can't change one layer without touching the others, and the journal practice — capturing what worked across runs and why — falls off the table because there's no surface designed for it. Design knowledge stays trapped inside the project that produced it instead of flowing outward into the maintainer's broader code workshop at `~/code`.

The pain isn't agent quality, isn't the design-system idea, and isn't BEAM-vs-Node. It's that the architecture doesn't respect Stewart Brand's pace layers: the slow layers (design vocabulary, skills, decisions worth keeping) are entangled with the fast layers (a specific run, a specific provider integration, a specific UI experiment), so neither layer can age at its own rate.

---

## Actors

- A1. **Architect-Maintainer** — the primary human actor. A solo product designer + solution architect who is not a full-time coder and not a UI designer. Uses the daemon intermittently, maintains its codebase periodically, lives with it for years.
- A2. **Agent CLI process** — Claude Code, Codex, Copilot, Pi, ACP, or other code-agent CLIs the maintainer has installed. The daemon spawns and supervises them; they emit streaming output and may crash.
- A3. **Client UI** — any program that consumes the daemon's protocol. open-design (the React/Electron app) is the first intended client; future clients include a thin first-party CLI, possibly an editor plugin, possibly a small web UI built specifically to demo the daemon. Clients are explicitly replaceable.
- A4. **Provider API** — external HTTP services (OpenAI, Replicate, Volcengine, Google, etc.) used for media generation and other agent capabilities. May fail, rate-limit, or change shape.
- A5. **The `~/code` workshop** — the maintainer's broader filesystem of in-flight projects, including this daemon's own source. The journal lives here as markdown files, and design knowledge produced by the daemon flows into other projects in this workshop naturally because it is files in the right place.

---

## Key Flows

- F1. **Run an agent against a design system to produce a UI artifact**
  - **Trigger:** A4-equipped client tells the daemon: "run skill X against design system Y with prompt Z"
  - **Actors:** A1 (originating the request via A3), A3 (relaying), the daemon (orchestrating), A2 (executing), A4 (called by A2 for media if needed)
  - **Steps:** Client submits run intent → daemon validates against skill + design system → daemon spawns supervised agent process → daemon streams agent output back through the protocol → client renders artifact preview → run terminates with success or crash
  - **Outcome:** A UI artifact (HTML/CSS/components) exists at a known location; the run is recorded as a first-class entity with full provenance (skill, design system, model, prompts, outputs)
  - **Covered by:** R1, R3, R5, R8, R12, R14

- F2. **Distill a session into a design spec (spec-last journaling)**
  - **Trigger:** A1 finishes a working session and decides what was worth keeping
  - **Actors:** A1, A3 (offering distillation surface), the daemon (recording)
  - **Steps:** Maintainer reviews the session's runs and artifacts → selects what worked, why, and what was rejected → distillation gets written as markdown into the user's `~/code` journal location → daemon indexes the new spec entry against the runs and artifacts it references
  - **Outcome:** A markdown spec file exists in the maintainer's workshop, anchored to the specific runs that produced it; a future maintainer (the same person, 6 months later) can locate the spec by directory navigation and traverse back to the original runs
  - **Covered by:** R6, R7, R9, R10

- F3. **Surface prior decisions when starting a new session**
  - **Trigger:** A1 begins a new session that is adjacent to past work (same design system, same skill, similar prompt)
  - **Actors:** A1, A3, the daemon
  - **Steps:** Client opens a new session → daemon's journal index surfaces relevant prior spec entries based on design system, skill, and recent activity → maintainer reads what past-them learned before sinking time into new runs
  - **Outcome:** The maintainer starts the session informed by their own prior conclusions instead of repeating dead ends
  - **Covered by:** R7, R10, R11

- F4. **Add or upgrade a client without touching the brain**
  - **Trigger:** A1 wants to use a new UI (e.g., an editor plugin, or a fresh first-party UI) against the same daemon
  - **Actors:** A1 (writing the new client), A3 (the new client), the daemon (unchanged)
  - **Steps:** Client implements the daemon's documented protocol → connects → uses the same runs, artifacts, journal as every other client
  - **Outcome:** A new client works without any changes to the daemon's source. The daemon's protocol is the load-bearing contract; the daemon's internals are not exposed
  - **Covered by:** R4, R13

- F5. **Recover from an agent or provider crash**
  - **Trigger:** An agent process or provider call dies mid-run
  - **Actors:** The daemon (supervisor), A2 or A4 (the dying actor), A3 (observing)
  - **Steps:** Supervised process crashes → daemon's supervision tree restarts the relevant component → run is marked failed with its exit reason recorded → other concurrent runs continue undisturbed → client receives a structured failure event and can decide whether to retry
  - **Outcome:** The daemon stays up. Failed runs are inspectable. The blast radius of a single failure is one run, not the workspace
  - **Covered by:** R8, R15, R16

---

## Requirements

**Persona and posture**
- R1. The product is a long-running local daemon installed on the maintainer's machine. It is not a hosted service. It is not a workspace application with bundled UI.
- R2. The architecture must be navigable by an architect-maintainer who is not a full-time coder, returning to the codebase after weeks or months away.
- R3. Slow layers (design system vocabulary, skills, protocol contract, decisions worth keeping) must be modifiable without touching fast layers (specific runs, specific provider integrations, specific clients). The reverse must also hold.

**Daemon shape**
- R4. The daemon ships no first-party UI as part of the product. A thin client (CLI or small web UI) may be built alongside the daemon as throwaway demo scaffolding; that scaffolding is explicitly not part of the product surface.
- R5. The daemon orchestrates external agent CLI processes (Claude Code, Codex, Copilot, Pi, ACP, and similar) by spawning, supervising, streaming output from, and reaping them.
- R6. Every long-lived component in the daemon (run supervisors, watchers, indexers, provider clients) is supervised under OTP. The daemon must remain available to other clients when any single component crashes.
- R7. The daemon owns and indexes the journal but does not own the journal's storage location. Journal content lives as markdown files inside the maintainer's broader `~/code` workshop, written and discoverable by ordinary directory navigation.

**Protocol (the load-bearing slow contract)**
- R8. The daemon exposes a single documented protocol that all clients consume. The protocol is the externally-visible product surface; the daemon's internals are not exposed.
- R9. The protocol is versioned. Breaking changes to protocol shape follow a documented deprecation policy that gives existing clients a migration window.
- R10. Multiple clients may connect to the daemon concurrently. Two clients (e.g., open-design and an editor plugin) operating against the same workspace must produce a coherent shared view of runs, artifacts, and journal entries.

**Inherited from open-design's main idea**
- R11. The daemon supports design systems as first-class brand-aware asset libraries (the same shape as open-design's `design-systems/` directory).
- R12. The daemon supports the skill protocol — markdown-driven artifact recipes (the same shape as open-design's `skills/` directory).
- R13. Open-design itself is one of the intended clients. Within a bounded effort (target: 1–2 weeks of integration work after v1), the existing open-design React/Electron app should be capable of running against this daemon as its backend.

**Journal and spec (spec-last sequencing)**
- R14. Runs come first; specs come after. The product does not require the maintainer to author a spec before generating UI. The product provides a surface for distilling a session's runs into a spec after the fact.
- R15. Every run is a first-class entity with full provenance: which skill, which design system, which agent CLI, which model, which prompts, which artifacts produced, when, and what its terminal state was.
- R16. Spec entries written into the journal anchor back to the specific runs and artifacts they reference. Following an anchor from a 6-month-old spec to its source runs must succeed without manual reconciliation.
- R17. Design knowledge captured in spec entries flows into the maintainer's broader `~/code` workshop without an export step — because the spec entries are already files in the right place.

**Security posture (forward-applied from the open-design audit)**
- R18. The daemon binds only to loopback. No network surface is reachable from other machines on the LAN by default.
- R19. Every mutating protocol surface requires authentication via a local secret (file-based, restrictive permissions). Default-deny on every mutating route. Read-only liveness signals may be unauthenticated.
- R20. Any sandboxed preview surface a client renders against daemon-streamed content must not require `allow-same-origin`. Daemon-streamed agent output must be safe to render in a sandboxed iframe with `allow-scripts` only.
- R21. All protocol input is validated against an explicit shape at the boundary. Internal modules trust validated input; external input is never trusted.

---

## Acceptance Examples

- AE1. **Covers R6, R8, R10.** Given two clients (open-design and a CLI) are connected to the same daemon, when an agent process inside the daemon crashes mid-run, then both clients receive a structured failure event for that run, the daemon stays up, and the unaffected client's other in-flight runs continue without interruption.
- AE2. **Covers R7, R14, R16, R17.** Given the maintainer finished a session and wrote a spec entry distilling three runs into "this layout pattern won," when 6 months pass and the maintainer opens a new session against the same design system, then the journal index surfaces that spec entry, and following its anchors back to the original three runs succeeds and shows their original artifacts.
- AE3. **Covers R18, R19.** Given the daemon is running on a laptop on a public network, when another machine on that network attempts to reach the daemon's protocol port, then the connection is refused at the network layer (loopback bind), and even a successful local connection without the auth secret is rejected at the protocol layer.
- AE4. **Covers R3, R4.** Given the maintainer wants to replace the demo client with a different UI 18 months after v1 ships, when they implement the daemon's documented protocol in the new UI, then the new UI works against an unchanged daemon, and the daemon's source code does not require any modification.
- AE5. **Covers R9, R10.** Given the daemon ships protocol v2 with a breaking change, when an old v1 client connects, then the daemon either serves it through a documented compatibility shim for the deprecation window or rejects the connection with a clear "client is too old, upgrade to support protocol v2" structured error — never silently malfunctioning.

---

## Success Criteria

- The maintainer can come back to the daemon's codebase after a 3-month gap and modify exactly one layer (e.g., add a new skill, replace the journal indexer, swap a provider client) without needing to read the others.
- Open-design (the existing JS app) is made into a working client of the daemon within 1–2 weeks of v1 launching, validating that the protocol is real and external clients are tractable.
- A design decision recorded in the journal during a session is locatable 6 months later via the maintainer's existing `~/code/...` directory navigation, without requiring the daemon to be running and without specialized tools.
- An agent CLI crash, a provider API failure, or a malformed client request never requires restarting the daemon; failures are localized.
- A handoff to `ce-plan` produces a plan that addresses architecture and protocol shape without re-litigating product positioning, actors, or scope.

---

## Scope Boundaries

### Deferred for later

- Multi-user / team collaboration on the same daemon
- A polished first-party UI as a shipping product (the demo client is throwaway scaffolding)
- Migration tooling from an existing open-design SQLite database
- Desktop packaging (Electron / Tauri / Wails / native installers beyond brew/asdf-style)
- Provider-API integrations beyond the minimum needed for the daemon to be useful at v1
- BEAM node clustering / multi-machine distribution
- Hot-code-reloading workflow as a user-facing feature (the runtime supports it; not exposing it intentionally in v1)

### Outside this product's identity

- A LiveView-based design tool — this would put UI rendering inside the daemon, defeating the whole reason for Shape C
- A general-purpose code agent — this is design-shaped; it is not competing with Claude Code, Cursor, Copilot, or Pi as agent surfaces
- A design-asset marketplace (Figma Community, Dribbble, etc.)
- A WYSIWYG design editor — the daemon observes runs and indexes journals, it does not draw
- A multi-tenant cloud product — positioning is local-only single-user; clouding it would re-introduce every problem this shape exists to escape

---

## Key Decisions

- **Daemon-as-product, not workspace-app.** The product is the brain, not a UI shell around the brain. UIs are clients of the published protocol. Rationale: enforces pace layers via process and repository boundary rather than convention; output flows to `~/code` natively because the journal is files; doesn't fork upstream — open-design becomes a client.
- **BEAM/Elixir runtime.** Long-lived supervised daemon talking to flaky external CLIs and provider APIs is a textbook OTP application. The "let it crash" model is exactly the right error posture for this problem shape, not an aesthetic preference.
- **Journal lives in `~/code`, not in daemon-owned storage.** Markdown files in the maintainer's existing workshop directory. The daemon indexes; it does not own. Rationale: design knowledge must travel between projects without an export step; a database that the daemon owns would make the data only-as-portable-as-the-daemon.
- **Spec-last sequencing baked into the workflow.** Runs are first-class; spec is the after-the-fact distillation. Rationale: the maintainer already journals this way (today's `docs/plans` discipline). Imposing spec-first would fight the actual practice.
- **Protocol is the slow load-bearing contract.** Versioning the protocol matters more than versioning any other surface. Rationale: clients are external; breaking the protocol breaks every consumer at once.
- **Open-design is a client, not a competitor.** Stays on `nexu-io/open-design` upstream sync; the JS-side audit work remains relevant for that fork, applied in service of making it a good client of this daemon.
- **Default-deny security posture from day one.** Loopback bind, file-secret auth on every mutating route, sandboxed-iframe-safe streaming output, validated protocol input. Forward-applied from the open-design audit findings; not retrofitted later.
- **No first-party UI as the product.** A thin client may exist for demos; it is explicitly throwaway. Rationale: building a polished UI alongside the daemon would inflate surface area, contradict pace-layer separation, and re-create open-design's existing problems on a new stack.

---

## Dependencies / Assumptions

- BEAM/Elixir 1.16+ on OTP 26+ (current stable as of 2026-05); verify exact minimum during planning.
- Single-machine assumption — no BEAM node clustering in v1 (deferred).
- The maintainer is comfortable installing and running a long-running local daemon (brew/asdf-style installation).
- The agent CLIs the daemon supervises (Claude Code, Codex, Copilot, Pi, ACP) continue to expose stable enough invocation/streaming surfaces that an OTP Port wrapper around them is practical. If any one CLI's interface is unstable, that integration's adapter takes the volatility, not the rest of the system.
- The open-design upstream protocol surface (`packages/contracts`) is stable enough that mapping it to the new daemon's protocol within the 1–2 week target in R13 is realistic. Verify by reading `packages/contracts/` during planning.
- The maintainer already has a `~/code` workshop with an established directory convention; the daemon does not impose a layout, only requires that the journal location is configurable per workspace.

---

## Outstanding Questions

### Resolve Before Planning

- *(none — the product shape is decided. Architecture and protocol questions below are properly planning-time work.)*

### Deferred to Planning

- [Affects R8, R9, R10][Technical] **Protocol shape.** Candidates surveyed in planning: Phoenix Channels (WebSocket framing, BEAM-native, easy from JS clients), gRPC (strong typing, schema evolution, heavier client integration), MCP (Anthropic's emerging Model Context Protocol — semantic match, ecosystem alignment, maturity unclear), JSON-over-HTTP+SSE (simplest, weakest contract). Must pick one that supports concurrent multi-client (R10), versioned evolution (R9), and is reasonably approachable from the open-design React client within the 1–2 week integration target (R13).
- [Affects R5, R6][Technical] **Agent-CLI process model.** OTP Port vs `System.cmd` for spawning agent CLIs. Streaming line-buffered stdout, structured JSON event parsing, and graceful kill on client disconnect must all work. Likely one supervised GenServer per active run.
- [Affects R7, R16][Technical] **Journal indexing strategy.** File-watch (FileSystem) plus an in-memory index rebuilt on startup, vs persistent index (SQLite, Mnesia, ETS). Picks based on journal size assumptions and query patterns surfaced during planning.
- [Affects R11, R12][Technical] **Design system and skill loading.** Are these read once per workspace, watched for changes, hot-reloaded? How are they versioned? Where do they live on disk relative to `~/code`?
- [Affects R13][Needs research] **open-design adapter shape.** What's the smallest change to the open-design React app that makes it talk to this daemon instead of the existing Express daemon? Read `packages/contracts/`, `apps/web/sidecar/`, `apps/web/src/providers/daemon.ts` during planning to size this concretely.
- [Affects R15, R16][Technical] **Run and artifact storage layout.** Where do run records live? Where do artifact files live (in the workspace? in a daemon cache? both, with one being canonical)? Reproducibility of a run from its provenance record — is that a v1 promise or deferred?
- [Affects R20, R21][Technical] **Streaming output sanitization at the protocol boundary.** What guarantees does the daemon make about agent-emitted content reaching clients? If a client renders the content in a sandboxed iframe, what additional escaping or framing is needed at the daemon side?
- [Affects R4][Product, plan-time] **Demo client choice.** A small CLI is fastest to build and easiest to demo for a backend-shaped product. A small web UI better validates that real UI clients can use the protocol. Plan should pick one (or sequence both) and explicitly mark whichever is built as throwaway.
- [Affects R1][Operational] **Installation and process lifecycle.** brew formula, asdf plugin, mix release, or systemd-style launchd plist on macOS? How does the daemon start on login? How does the maintainer stop, upgrade, or uninstall it cleanly?
