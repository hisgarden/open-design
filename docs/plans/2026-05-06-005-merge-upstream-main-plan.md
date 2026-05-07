---
title: "Plan — Merge upstream/main into docs/beam-design-daemon-spec"
date: 2026-05-06
status: in_progress
---

# Objective

Merge `upstream/main` (nexu-io/open-design) into the local feature branch
`docs/beam-design-daemon-spec` so the BEAM bridge work catches up with the
last 47 upstream commits, and resolve the four content conflicts surfaced
during the merge.

## Context

- Branch was last synced with upstream at commit `b675ba8` (Merge upstream
  nexu-io/open-design@main). 47 new commits have landed upstream since,
  including a fork (`origin/main` is 78 behind upstream).
- BEAM bridge work (~21 commits) is the only ahead-divergence. None of
  the BEAM-specific files conflict with upstream.
- Conflicts are concentrated in the media subsystem and one web component:
  - `apps/daemon/src/media-models.ts` (1 hunk — model registry)
  - `apps/daemon/src/media.ts` (4 hunks — provider routing)
  - `apps/web/src/media/models.ts` (1 hunk — web-side model list)
  - `apps/web/src/components/NewProjectPanel.tsx` (1 hunk — small)
- The conflicts come from upstream adding a Nano Banana provider while the
  local branch already added DeepInfra (FLUX-2-pro/klein, Qwen-Image-Max,
  Seedream-4, Wan-2.7, Qwen-Image-Edit) entries in the same lists. Both
  sets are additive — keep both.

## Steps

- [x] Fetch upstream + origin, audit divergence, summarise to user.
- [x] Run `git merge upstream/main --no-edit`, accept conflicts surfaced.
- [ ] Resolve `apps/daemon/src/media-models.ts` — keep both DeepInfra
  block (HEAD) and Nano Banana entry (upstream).
- [ ] Resolve `apps/daemon/src/media.ts` — read all 4 hunks; keep
  DeepInfra provider routing AND nanobanana provider routing.
- [ ] Resolve `apps/web/src/media/models.ts` — symmetric to media-models.
- [ ] Resolve `apps/web/src/components/NewProjectPanel.tsx` — small hunk,
  inspect and reconcile.
- [ ] Run `pnpm install` (workspace-shape may have shifted; new packages
  added upstream).
- [ ] Run `pnpm guard` and `pnpm typecheck`.
- [ ] Run package-scoped tests for `@open-design/daemon` and
  `@open-design/web` to validate the resolved files.
- [ ] Spot-check BEAM-specific files (apps/web/sidecar/beam-bridge.ts,
  apps/beam-daemon/**) were not touched by upstream — sanity only.
- [ ] Commit the merge (no `Co-authored-by` — repo policy).
- [ ] Report final status: ahead/behind, test results, any deferred work.

## Expected outcome

- Single merge commit on `docs/beam-design-daemon-spec` resolving the four
  conflicts additively (both sets of media providers preserved).
- `pnpm guard`, `pnpm typecheck`, and the daemon + web vitest suites pass.
- BEAM work untouched and still ahead of `upstream/main`.
- Engineering log entry summarising the merge.

## Risks / watch-items

- The merge brought in many new files (qoder-stream, transcript-export,
  manual-edit-mode, connection-test, social-media-dashboard skill, etc.).
  These are net-new and shouldn't conflict, but typecheck may surface
  a contracts-package signature drift.
- e2e/ has been substantially restructured upstream (case files removed,
  new `e2e/lib/` and `e2e/ui/` layout). I am not running e2e in this
  pass — out of scope. Leave for a follow-up if the user wants it.
- pnpm-lock.yaml is in the merge — if `pnpm install` rewrites it, capture
  whatever it produces.
