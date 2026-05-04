/**
 * BEAM Daemon bridge — gates open-design's run/event surface behind
 * `BEAM_DAEMON_URL`. When set, `POST /api/runs`, `GET /api/runs/:id/events`,
 * and `POST /api/runs/:id/cancel` go through here instead of the JS daemon.
 *
 * What this proves: the BEAM Design Daemon at ~/code/beam-design-daemon can
 * back the existing React UI without touching any UI code — the contract
 * surface (ChatSseEvent union from `@open-design/contracts`) is the seam.
 *
 * Architecture:
 *   POST /api/runs                  → opens WS to BEAM, joins channel,
 *                                     sends run.start, returns {runId}.
 *                                     Buffers events into an in-memory queue
 *                                     keyed by runId.
 *   GET /api/runs/:id/events (SSE) → consumes the queue + live stream,
 *                                     translating Channel events to the
 *                                     ChatSseEvent shape the React UI parses.
 *   POST /api/runs/:id/cancel      → sends run.cancel and tears down.
 *
 * Zero npm deps — uses Node 22+'s built-in WebSocket, EventEmitter, fs.
 */

import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";

import type {
  ChatSseEndPayload,
  ChatSseStartPayload,
  DaemonAgentPayload,
  SseErrorPayload,
} from "@open-design/contracts";

// ---- Config -----------------------------------------------------------------

export interface BeamBridgeConfig {
  /** ws:// URL for the BEAM daemon's Phoenix socket (e.g. ws://127.0.0.1:4000/socket/websocket). */
  daemonUrl: string;
  /** Phoenix Channel topic suffix; the daemon's workspace_id. */
  workspaceId: string;
  /** Path to the BEAM daemon's auth token file (mode 0600). */
  tokenPath: string;
  /** How long to retain a completed run's buffered events (ms). */
  retentionMs: number;
  /**
   * Optional agent override. When set, forces every run through this BEAM
   * agent regardless of what the React UI picked. Useful when the JS
   * daemon's `/api/agents` only advertises CLI agents (claude/codex/etc.)
   * and the operator wants HTTP-only paths like `deepinfra`.
   */
  agentOverride: string | null;
  /** Optional model override forwarded to BEAM when the UI didn't pick one. */
  modelOverride: string | null;
}

export function configFromEnv(): BeamBridgeConfig | null {
  const daemonUrl = process.env.BEAM_DAEMON_URL;
  if (daemonUrl == null || daemonUrl === "") return null;
  return {
    daemonUrl,
    workspaceId: process.env.BEAM_WORKSPACE_ID || "open-design",
    tokenPath:
      process.env.BEAM_DESIGN_TOKEN_PATH ||
      join(homedir(), ".beam-design", "auth-token"),
    retentionMs: 5 * 60_000,
    agentOverride: process.env.BEAM_AGENT_ID?.trim() || null,
    modelOverride: process.env.BEAM_MODEL?.trim() || null,
  };
}

function readToken(path: string): string {
  return readFileSync(path, "utf8").trim();
}

// ---- Run registry -----------------------------------------------------------

interface BeamRun {
  runId: string;
  ws: WebSocket;
  emitter: EventEmitter;
  // Replayable buffer so a late `/events` subscriber doesn't miss the start.
  buffer: Array<{ event: string; payload: unknown }>;
  terminal: ChatSseEndPayload | null;
  startedAt: number;
}

const runs = new Map<string, BeamRun>();

function reapStale(retentionMs: number): void {
  const now = Date.now();
  for (const [id, run] of runs) {
    if (run.terminal != null && now - run.startedAt > retentionMs) {
      runs.delete(id);
    }
  }
}

// ---- Phoenix v2 channel helpers --------------------------------------------

interface PhoenixFrame {
  joinRef: string | null;
  ref: string | null;
  topic: string;
  event: string;
  payload: Record<string, unknown>;
}

function frameToWire(frame: PhoenixFrame): string {
  return JSON.stringify([frame.joinRef, frame.ref, frame.topic, frame.event, frame.payload]);
}

function wireToFrame(raw: string): PhoenixFrame | null {
  try {
    const arr = JSON.parse(raw);
    if (!Array.isArray(arr) || arr.length !== 5) return null;
    return { joinRef: arr[0], ref: arr[1], topic: arr[2], event: arr[3], payload: arr[4] };
  } catch {
    return null;
  }
}

// ---- BEAM event → ChatSseEvent translation ---------------------------------

function translateBeamPayload(beamEvent: string, payload: any):
  | { sseEvent: "agent"; data: DaemonAgentPayload }
  | { sseEvent: "stdout"; data: { chunk: string } }
  | { sseEvent: "stderr"; data: { chunk: string } }
  | { sseEvent: "end"; data: ChatSseEndPayload }
  | { sseEvent: "error"; data: SseErrorPayload }
  | null {
  switch (beamEvent) {
    case "run.output": {
      const kind = payload?.kind;
      const delta = String(payload?.delta ?? "");
      if (kind === "agent" || kind === "text") {
        return { sseEvent: "agent", data: { type: "text_delta", delta } };
      }
      if (kind === "status") {
        return { sseEvent: "agent", data: { type: "status", label: delta.trim() || "running" } };
      }
      if (kind === "stderr") {
        return { sseEvent: "stderr", data: { chunk: delta } };
      }
      // stdout / unknown → fall back to stdout
      return { sseEvent: "stdout", data: { chunk: delta } };
    }
    case "run.terminal": {
      const status: ChatSseEndPayload["status"] =
        payload?.status === "succeeded"
          ? "succeeded"
          : payload?.status === "cancelled"
            ? "canceled"
            : "failed";
      return {
        sseEvent: "end",
        data: { code: typeof payload?.exit === "number" ? payload.exit : null, status },
      };
    }
    default:
      return null;
  }
}

// ---- POST /api/runs handler ------------------------------------------------

interface ChatRequestLike {
  agentId?: string;
  message?: string;
  skillId?: string | null;
  designSystemId?: string | null;
  model?: string | null;
  projectId?: string | null;
  conversationId?: string | null;
}

const AGENT_ID_TO_BEAM: Record<string, string> = {
  claude: "claude-code",
  "claude-code": "claude-code",
  anthropic: "claude-code",
  deepinfra: "deepinfra",
};

function mapAgentId(agentId: string | undefined, override: string | null): string {
  if (override != null && override !== "") return override;
  return (agentId && AGENT_ID_TO_BEAM[agentId]) || "claude-code";
}

async function readJsonBody(req: IncomingMessage): Promise<ChatRequestLike> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8")) as ChatRequestLike;
  } catch {
    return {};
  }
}

function generateRunId(): string {
  return "beam_" + Math.random().toString(16).slice(2, 18);
}

export async function handleBeamRunStart(
  config: BeamBridgeConfig,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  reapStale(config.retentionMs);
  const body = await readJsonBody(req);
  const runId = generateRunId();
  const beamAgent = mapAgentId(body.agentId, config.agentOverride);
  const beamModel = body.model ?? config.modelOverride;

  let token: string;
  try {
    token = readToken(config.tokenPath);
  } catch (err) {
    res.statusCode = 500;
    res.setHeader("content-type", "application/json");
    res.end(
      JSON.stringify({
        error: { code: "BEAM_AUTH_TOKEN_MISSING", message: `${config.tokenPath}: ${(err as Error).message}` },
      }),
    );
    return;
  }

  const url = `${config.daemonUrl}?token=${encodeURIComponent(token)}&vsn=2.0.0`;
  const topic = `design:v1:${config.workspaceId}`;

  let ws: WebSocket;
  try {
    ws = new WebSocket(url);
  } catch (err) {
    res.statusCode = 502;
    res.setHeader("content-type", "application/json");
    res.end(
      JSON.stringify({
        error: { code: "BEAM_CONNECT_FAILED", message: (err as Error).message },
      }),
    );
    return;
  }

  const emitter = new EventEmitter();
  const run: BeamRun = {
    runId,
    ws,
    emitter,
    buffer: [],
    terminal: null,
    startedAt: Date.now(),
  };
  runs.set(runId, run);

  // Emit a synthetic `start` event immediately so a fast `/events` consumer
  // sees the run shape before any agent output arrives.
  const startPayload: ChatSseStartPayload = {
    runId,
    agentId: beamAgent,
    bin: beamAgent === "claude-code" ? "claude" : beamAgent,
    cwd: null,
    projectId: body.projectId ?? null,
    model: beamModel ?? null,
  };
  run.buffer.push({ event: "start", payload: startPayload });
  emitter.emit("sse", { event: "start", payload: startPayload });

  let nextRef = 1;
  const send = (event: string, payload: Record<string, unknown>): string => {
    const ref = String(nextRef++);
    ws.send(frameToWire({ joinRef: "1", ref, topic, event, payload }));
    return ref;
  };

  let joined = false;

  ws.addEventListener("open", () => {
    ws.send(frameToWire({ joinRef: "1", ref: String(nextRef++), topic, event: "phx_join", payload: {} }));
  });

  ws.addEventListener("message", (msg) => {
    const frame = wireToFrame(typeof msg.data === "string" ? msg.data : String(msg.data));
    if (frame == null) return;

    if (frame.event === "phx_reply") {
      if (!joined) {
        if ((frame.payload as any)?.status === "ok") {
          joined = true;
          send("run.start", {
            skill_id: body.skillId ?? "html-ppt",
            design_system_id: body.designSystemId ?? "obsidian-claude-gradient",
            prompt: body.message ?? "",
            agent: beamAgent,
            ...(beamModel ? { model: beamModel } : {}),
          });
        } else {
          terminate(run, {
            code: -1,
            status: "failed",
          });
        }
      }
      return;
    }

    const translated = translateBeamPayload(frame.event, frame.payload);
    if (translated == null) return;

    run.buffer.push({ event: translated.sseEvent, payload: translated.data });
    emitter.emit("sse", { event: translated.sseEvent, payload: translated.data });

    if (translated.sseEvent === "end") {
      terminate(run, translated.data);
    }
  });

  ws.addEventListener("error", (err: any) => {
    terminate(run, { code: -1, status: "failed" });
    const message = err?.message ?? String(err);
    const errorPayload: SseErrorPayload = {
      message,
      error: { code: "UPSTREAM_UNAVAILABLE", message },
    };
    run.buffer.push({ event: "error", payload: errorPayload });
    emitter.emit("sse", { event: "error", payload: errorPayload });
  });

  ws.addEventListener("close", () => {
    if (run.terminal == null) {
      terminate(run, { code: -1, status: "failed" });
    }
  });

  // Mirror the JS daemon's contract: synchronous 202 with the runId.
  res.statusCode = 202;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify({ runId }));
}

function terminate(run: BeamRun, payload: ChatSseEndPayload): void {
  if (run.terminal != null) return;
  run.terminal = payload;
  // Don't push another `end` if the translator already did.
  // Caller is responsible for the bookkeeping.
  try {
    run.ws.close(1000, "run-terminal");
  } catch {
    // ignore
  }
}

// ---- GET /api/runs/:id/events handler --------------------------------------

function writeSseFrame(res: ServerResponse, event: string, payload: unknown): void {
  res.write(`event: ${event}\n`);
  res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

export function handleBeamRunEvents(
  _config: BeamBridgeConfig,
  runId: string,
  _req: IncomingMessage,
  res: ServerResponse,
): void {
  const run = runs.get(runId);
  if (run == null) {
    res.statusCode = 404;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: { code: "NOT_FOUND", message: `unknown runId: ${runId}` } }));
    return;
  }

  res.statusCode = 200;
  res.setHeader("content-type", "text/event-stream");
  res.setHeader("cache-control", "no-cache, no-transform");
  res.setHeader("connection", "keep-alive");
  res.setHeader("x-accel-buffering", "no");
  res.flushHeaders?.();

  // Replay buffered events (start, any agent/output already received).
  for (const entry of run.buffer) {
    writeSseFrame(res, entry.event, entry.payload);
  }

  if (run.terminal != null) {
    res.end();
    return;
  }

  const onSse = (entry: { event: string; payload: unknown }) => {
    writeSseFrame(res, entry.event, entry.payload);
    if (entry.event === "end") {
      run.emitter.off("sse", onSse);
      res.end();
    }
  };

  run.emitter.on("sse", onSse);

  // Cleanup on client disconnect.
  res.on("close", () => {
    run.emitter.off("sse", onSse);
  });
}

// ---- POST /api/runs/:id/cancel handler -------------------------------------

export function handleBeamRunCancel(
  _config: BeamBridgeConfig,
  runId: string,
  _req: IncomingMessage,
  res: ServerResponse,
): void {
  const run = runs.get(runId);
  if (run == null) {
    res.statusCode = 404;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: { code: "NOT_FOUND", message: `unknown runId: ${runId}` } }));
    return;
  }

  // Best-effort cancel; v1 of the BEAM channel returns not_yet_implemented
  // for run.cancel (U7 follow-up). Closing the socket is the safe fallback.
  try {
    run.ws.close(1000, "client-cancel");
  } catch {
    // ignore
  }

  res.statusCode = 200;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify({ ok: true }));
}

// ---- Routing helper --------------------------------------------------------

export interface BeamBridgeRouteMatch {
  kind: "start" | "events" | "cancel";
  runId?: string;
}

export function matchBeamBridgeRoute(method: string | undefined, pathname: string): BeamBridgeRouteMatch | null {
  if (method === "POST" && pathname === "/api/runs") return { kind: "start" };
  const eventsMatch = /^\/api\/runs\/([^/]+)\/events$/.exec(pathname);
  if (method === "GET" && eventsMatch?.[1]) return { kind: "events", runId: decodeURIComponent(eventsMatch[1]) };
  const cancelMatch = /^\/api\/runs\/([^/]+)\/cancel$/.exec(pathname);
  if (method === "POST" && cancelMatch?.[1]) return { kind: "cancel", runId: decodeURIComponent(cancelMatch[1]) };
  return null;
}
