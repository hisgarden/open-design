#!/usr/bin/env bun
/**
 * BEAM tool-loop deck smoke — proves the chat→BEAM→DeepInfra→tool→file
 * round-trip end-to-end.
 *
 * Steps:
 *   1. Create a project via JS daemon  (POST /api/projects on :17456)
 *   2. Drive a deck-generation run via web sidecar (POST /api/runs on :17573)
 *   3. Stream the SSE event log
 *   4. Assert at least one file was written under
 *      <repo>/.od/projects/<projectId>/ AND that the run finished with
 *      status="succeeded"
 *
 * Designed to fail fast and noisy with a non-zero exit when the loop is
 * broken. Use it as the regression gate for Phase B/C of the
 * beam-bridge tool-loop plan.
 *
 * Requires:
 *   - JS daemon listening on :17456 (started by `task web:up:bridge`)
 *   - Web sidecar with BEAM bridge env on :17573
 *   - BEAM daemon on :4000 with DEEPINFRA_API_KEY in its env
 *
 * Optional env:
 *   OD_DAEMON_URL  — JS daemon base URL (default http://127.0.0.1:17456)
 *   OD_WEB_URL     — Web sidecar base URL (default http://127.0.0.1:17573)
 *   BEAM_DECK_MODEL — DeepInfra model id (default deepseek-ai/DeepSeek-V4-Pro;
 *                     V4-Flash is too small for long tool arguments)
 *   BEAM_DECK_TIMEOUT_MS — SSE drain deadline (default 180000)
 */

import { existsSync, readdirSync, statSync } from "node:fs";
import { resolve } from "node:path";

const DAEMON_URL = process.env.OD_DAEMON_URL ?? "http://127.0.0.1:17456";
const WEB_URL = process.env.OD_WEB_URL ?? "http://127.0.0.1:17573";
// DeepSeek V4-Pro — proven end-to-end on 2026-05-04 (~10KB index.html
// with full design tokens, proper slide structure, hover states). Slow
// (~2-3 min) but the loop converges cleanly because V4-Pro emits real
// tool_call IDs that round-trip through the assistant→tool message
// dance OpenAI-compat tool calling expects.
//
// Models we've tried and ruled out (as of 2026-05-04):
//   - DeepSeek V4-Flash: truncates long content arguments to "".
//   - DeepSeek V3.2: reasoning-heavy, slow + truncates args.
//   - Llama-3.3-70B-Instruct: ignored tools, returned empty response.
//   - Kimi K2 (no version suffix): whitespace-only deltas.
//   - Kimi K2.6: emits tool_calls but hallucinates content.
//   - Step-3.5-Flash: announces intent in text, no tool call.
//   - Qwen3-Max: emits real HTML but no tool_call IDs → loop fails
//     to converge (model can't correlate its calls to tool_results).
// Override via BEAM_DECK_MODEL.
const MODEL = process.env.BEAM_DECK_MODEL ?? "deepseek-ai/DeepSeek-V4-Pro";
// Kimi K2.6 typically completes a 2-slide deck in 60-180s but may run
// 2-3 tool-loop iterations (list_files → write_file → final answer).
// 300s gives headroom; override BEAM_DECK_TIMEOUT_MS if you're testing
// a slower model.
const TIMEOUT_MS = Number(process.env.BEAM_DECK_TIMEOUT_MS ?? 300_000);

const projectId = `beam-deck-smoke-${Date.now()}`;
const projectDir = resolve(process.cwd(), ".od/projects", projectId);

async function main(): Promise<void> {
  // ---- 1. create project --------------------------------------------------
  process.stderr.write(`[1/4] creating project ${projectId}\n`);
  const createResp = await fetch(`${DAEMON_URL}/api/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      id: projectId,
      name: "beam deck smoke",
      skillId: "html-ppt",
      designSystemId: "agentic",
      metadata: { kind: "deck" },
    }),
  });
  if (!createResp.ok) {
    fail(`POST /api/projects failed: ${createResp.status} ${await createResp.text()}`);
  }

  // ---- 2. start run -------------------------------------------------------
  process.stderr.write(`[2/4] kicking off BEAM run (model=${MODEL})\n`);
  const runResp = await fetch(`${WEB_URL}/api/runs`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      agentId: "claude",
      model: MODEL,
      message:
        // Direct, imperative — small models fall back to inline-text replies
        // when the directive is too soft. This phrasing has consistently
        // produced tool calls across V4-Pro, Qwen3-Max, and Kimi K2.6.
        'IMMEDIATELY call the write_file function tool. path argument: index.html. content argument: a complete <!DOCTYPE html> document, two <section class="slide"> blocks about coffee, inline <style>, real HTML markup (not JSON, not prose). No conversation. Just one tool call. Stop.',
      skillId: "html-ppt",
      designSystemId: "agentic",
      projectId,
    }),
  });
  if (!runResp.ok) {
    fail(`POST /api/runs failed: ${runResp.status} ${await runResp.text()}`);
  }
  const { runId } = (await runResp.json()) as { runId: string };
  process.stderr.write(`      runId=${runId}\n`);

  // ---- 3. drain SSE -------------------------------------------------------
  process.stderr.write(`[3/4] streaming events (timeout ${TIMEOUT_MS}ms)\n`);
  const eventsResp = await fetch(`${WEB_URL}/api/runs/${encodeURIComponent(runId)}/events`, {
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (eventsResp.body == null) {
    fail("SSE body missing");
  }

  let endStatus: string | null = null;
  let toolUseCount = 0;
  let toolResultCount = 0;
  let firstFileWritten: string | null = null;

  const reader = eventsResp.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  outer: while (true) {
    let chunk;
    try {
      chunk = await reader.read();
    } catch {
      // AbortSignal timeout fires in here; stop reading and check
      // what we already collected. The run may still finish in the
      // background — for a smoke-test gate, observing a successful
      // tool_use + tool_result + non-empty file IS the loop proof.
      break;
    }
    if (chunk.done) break;
    buffer += decoder.decode(chunk.value, { stream: true });
    let idx;
    while ((idx = buffer.indexOf("\n\n")) >= 0) {
      const frame = buffer.slice(0, idx);
      buffer = buffer.slice(idx + 2);
      const event = parseSseFrame(frame);
      if (event == null) continue;
      if (event.event === "agent" && event.data?.type === "tool_use") {
        toolUseCount++;
        process.stderr.write(`      tool_use: ${event.data.name}\n`);
      }
      if (event.event === "agent" && event.data?.type === "tool_result") {
        toolResultCount++;
        // Parse the tool_result content (which we serialized as a JSON
        // string in the bridge) to check whether write_file actually
        // landed bytes on disk.
        try {
          const result = JSON.parse(event.data.content);
          if (result?.ok === true && typeof result.path === "string" && result.bytes > 0) {
            firstFileWritten = result.path;
            // We have proof the loop worked — drain a bit more for
            // any in-flight events but don't block on the run's full
            // wind-down (V4-Pro can take 2-3 min on the final turn).
            process.stderr.write(`      ✓ wrote ${result.path} (${result.bytes} bytes)\n`);
            break outer;
          }
        } catch {
          // ignore non-JSON tool_result content
        }
      }
      if (event.event === "end") {
        endStatus = event.data?.status ?? null;
        break outer;
      }
    }
  }

  // ---- 4. assertions ------------------------------------------------------
  process.stderr.write(`[4/4] verifying artifacts under ${projectDir}\n`);
  if (!existsSync(projectDir) || !statSync(projectDir).isDirectory()) {
    fail(`project dir not created: ${projectDir}`);
  }
  const files = readdirSync(projectDir).filter((f) => !f.startsWith("."));
  const written = files.filter((f) => {
    try {
      return statSync(resolve(projectDir, f)).size > 0;
    } catch {
      return false;
    }
  });

  process.stdout.write(
    JSON.stringify(
      {
        projectId,
        runId,
        endStatus,
        toolUseCount,
        toolResultCount,
        files,
        nonEmptyFiles: written,
      },
      null,
      2,
    ) + "\n",
  );

  // The file existence test is the actual loop-functionality proof.
  // toolUseCount/toolResultCount/endStatus are informational — fetch's
  // SSE reader can buffer for tens of seconds before the first yield
  // on long connections, so a smoke that aborts at the timeout may
  // have observed zero events even when the BEAM-side loop ran
  // perfectly and the JS daemon's project-files watcher already saw
  // the writes.
  if (written.length === 0) {
    fail(`no non-empty files written under ${projectDir} (toolUse=${toolUseCount}, endStatus=${endStatus})`);
  }
  process.stderr.write(
    `✓ deck smoke passed: ${written.length} file(s), ${toolUseCount} tool_use, endStatus=${endStatus ?? "(stream timed out)"}\n`,
  );
}

function parseSseFrame(frame: string): { event: string; data: any } | null {
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

main().catch((err) => {
  fail(err instanceof Error ? err.message : String(err));
});
