#!/usr/bin/env bun
/**
 * BEAM conversation-resumption smoke — proves Phase 4C wires the
 * Conversations.Store correctly so a 2nd run on the same
 * conversationId sees the 1st run's user msg + assistant tool_calls
 * + tool results in its initial messages payload.
 *
 * Steps:
 *   1. Create a project via JS daemon
 *   2. Run TURN 1 with conversationId=X: ask the model to write
 *      a file with a memorable marker word in the content.
 *   3. Run TURN 2 with the SAME conversationId=X: ask the model
 *      "what marker word did you write to the file in your last
 *      turn?". Capture the streamed text.
 *   4. Assert the captured text contains the marker word — the only
 *      way the model could know it is by having the prior history
 *      replayed as messages on turn 2.
 *
 * Without Phase 4C the test fails: turn 2 starts fresh, the model
 * has no idea what we wrote in turn 1.
 *
 * Requires:
 *   - JS daemon on :17456
 *   - Web sidecar with BEAM bridge on :17573
 *   - BEAM daemon on :4000 with DEEPINFRA_API_KEY
 *
 * Optional env:
 *   BEAM_THREAD_MODEL — default deepseek-ai/DeepSeek-V4-Pro
 *   BEAM_THREAD_TIMEOUT_MS — per-turn deadline, default 300000
 */

import { existsSync, readdirSync, statSync } from "node:fs";
import { resolve } from "node:path";

const DAEMON_URL = process.env.OD_DAEMON_URL ?? "http://127.0.0.1:17456";
const WEB_URL = process.env.OD_WEB_URL ?? "http://127.0.0.1:17573";
const MODEL = process.env.BEAM_THREAD_MODEL ?? "deepseek-ai/DeepSeek-V4-Pro";
const TIMEOUT_MS = Number(process.env.BEAM_THREAD_TIMEOUT_MS ?? 300_000);

const projectId = `beam-thread-smoke-${Date.now()}`;
const conversationId = `conv-${projectId}`;
// A nonsense marker word the model could not produce by chance.
const marker = `marker_${Math.random().toString(36).slice(2, 10)}`;
const projectDir = resolve(process.cwd(), ".od/projects", projectId);

interface SseEvent {
  event: string;
  data: any;
}

async function main(): Promise<void> {
  process.stderr.write(`[1/5] creating project ${projectId}\n`);
  const createResp = await fetch(`${DAEMON_URL}/api/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      id: projectId,
      name: "beam thread smoke",
      skillId: "html-ppt",
      designSystemId: "agentic",
      metadata: { kind: "deck" },
    }),
  });
  if (!createResp.ok) fail(`create project: ${createResp.status} ${await createResp.text()}`);

  // ---- TURN 1 ------------------------------------------------------------
  process.stderr.write(`[2/5] TURN 1 — write the marker (${marker}) into a file\n`);
  const t1RunId = await startRun({
    message: `Use write_file once. path: notes.txt. content: the single word "${marker}" — exactly that, no quotes, no other text. Then stop.`,
  });
  process.stderr.write(`      runId=${t1RunId}\n`);
  const t1 = await drainEvents(t1RunId);
  if (t1.toolUseCount === 0 || t1.firstFileWritten == null) {
    fail(
      `TURN 1 did not write a file (toolUse=${t1.toolUseCount}, file=${t1.firstFileWritten}, end=${t1.endStatus})`,
    );
  }
  process.stderr.write(`      ✓ wrote ${t1.firstFileWritten} (${t1.firstFileBytes} bytes)\n`);

  // ---- TURN 2 ------------------------------------------------------------
  process.stderr.write(`[3/5] TURN 2 — ask what marker was written\n`);
  const t2RunId = await startRun({
    message:
      "What is the single marker word you just wrote into notes.txt? Reply with only the marker word and nothing else. No explanation.",
  });
  process.stderr.write(`      runId=${t2RunId}\n`);
  const t2 = await drainEvents(t2RunId);

  // ---- 4. Verify ---------------------------------------------------------
  process.stderr.write(`[4/5] verifying turn 2 references the marker\n`);
  const recovered = (t2.text ?? "").toLowerCase();
  process.stdout.write(
    JSON.stringify(
      {
        projectId,
        conversationId,
        turn1: {
          runId: t1RunId,
          toolUseCount: t1.toolUseCount,
          firstFileWritten: t1.firstFileWritten,
          endStatus: t1.endStatus,
        },
        turn2: {
          runId: t2RunId,
          textPreview: t2.text?.slice(0, 200),
          endStatus: t2.endStatus,
        },
        marker,
        markerInTurn2Text: recovered.includes(marker.toLowerCase()),
      },
      null,
      2,
    ) + "\n",
  );

  if (!recovered.includes(marker.toLowerCase())) {
    fail(
      `marker "${marker}" not found in turn 2 reply — Phase 4C resumption isn't wired (turn 2 saw a fresh thread). Got: ${JSON.stringify(t2.text?.slice(0, 200))}`,
    );
  }
  process.stderr.write(`[5/5] ✓ thread smoke passed: marker "${marker}" round-tripped through the store\n`);
}

async function startRun(opts: { message: string }): Promise<string> {
  const resp = await fetch(`${WEB_URL}/api/runs`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      agentId: "claude",
      model: MODEL,
      message: opts.message,
      skillId: "html-ppt",
      designSystemId: "agentic",
      projectId,
      conversationId,
    }),
  });
  if (!resp.ok) fail(`POST /api/runs: ${resp.status} ${await resp.text()}`);
  const { runId } = (await resp.json()) as { runId: string };
  return runId;
}

interface DrainResult {
  toolUseCount: number;
  toolResultCount: number;
  firstFileWritten: string | null;
  firstFileBytes: number | null;
  endStatus: string | null;
  text: string | null;
}

async function drainEvents(runId: string): Promise<DrainResult> {
  const resp = await fetch(`${WEB_URL}/api/runs/${encodeURIComponent(runId)}/events`, {
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (resp.body == null) fail("SSE body missing");

  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  let toolUseCount = 0;
  let toolResultCount = 0;
  let firstFileWritten: string | null = null;
  let firstFileBytes: number | null = null;
  let endStatus: string | null = null;
  let text = "";

  outer: while (true) {
    let chunk;
    try {
      chunk = await reader.read();
    } catch {
      break;
    }
    if (chunk.done) break;
    buffer += decoder.decode(chunk.value, { stream: true });
    let idx;
    while ((idx = buffer.indexOf("\n\n")) >= 0) {
      const frame = buffer.slice(0, idx);
      buffer = buffer.slice(idx + 2);
      const ev = parseSseFrame(frame);
      if (ev == null) continue;
      if (ev.event === "agent" && ev.data?.type === "text_delta") {
        text += String(ev.data.delta ?? "");
      }
      if (ev.event === "agent" && ev.data?.type === "tool_use") {
        toolUseCount++;
      }
      if (ev.event === "agent" && ev.data?.type === "tool_result") {
        toolResultCount++;
        try {
          const result = JSON.parse(ev.data.content);
          if (result?.ok && result.path && firstFileWritten == null) {
            firstFileWritten = result.path;
            firstFileBytes = result.bytes ?? null;
          }
        } catch {
          // ignore non-JSON
        }
      }
      if (ev.event === "end") {
        endStatus = ev.data?.status ?? null;
        break outer;
      }
    }
  }

  return {
    toolUseCount,
    toolResultCount,
    firstFileWritten,
    firstFileBytes,
    endStatus,
    text: text || null,
  };
}

function parseSseFrame(frame: string): SseEvent | null {
  let event = "message";
  const dataLines: string[] = [];
  for (const line of frame.split("\n")) {
    if (line.startsWith("event:")) event = line.slice(6).trim();
    else if (line.startsWith("data:")) dataLines.push(line.slice(5).trim());
  }
  if (dataLines.length === 0) return null;
  try {
    return { event, data: JSON.parse(dataLines.join("\n")) };
  } catch {
    return { event, data: dataLines.join("\n") };
  }
}

function fail(msg: string): never {
  process.stderr.write(`✗ ${msg}\n`);
  process.exit(1);
}

main().catch((err) => fail(err instanceof Error ? err.message : String(err)));

// Reference imports so unused-locals lints don't flag the safety net.
void existsSync;
void readdirSync;
void statSync;
void projectDir;
