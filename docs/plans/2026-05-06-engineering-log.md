---
title: "Engineering log — 2026-05-06"
type: log
date: 2026-05-06
---

# 2026-05-06 — Upstream sync sweep

## Timeline (reverse chronological — newest on top)

### 22:11 — BAU adjustment: plans go to `docs/plans/`, not `.claude/`

User clarified that since they run multiple agents/models in this repo,
plan files should be model-neutral and in-repo. Moved
`.claude/plan.md` → `docs/plans/2026-05-06-005-merge-upstream-main-plan.md`
and saved a project-scoped feedback memory so future sessions don't
repeat the mistake.

### 22:08 — Merge `upstream/main` started, 4 conflicts surfaced

`git merge upstream/main` auto-merged most files but left content
conflicts in:

- `apps/daemon/src/media-models.ts` (1 hunk)
- `apps/daemon/src/media.ts` (4 hunks)
- `apps/web/src/media/models.ts` (1 hunk)
- `apps/web/src/components/NewProjectPanel.tsx` (1 hunk)

Diagnosis: upstream added a Nano Banana provider; HEAD already added
DeepInfra (FLUX-2, Qwen-Image-Max, Seedream-4, Wan-2.7, Qwen-Image-Edit).
The two sets are additive — resolution should keep both blocks. Plan
`2026-05-06-005-merge-upstream-main-plan.md` tracks the resolution.

### 22:05 — Upstream audit

Fetched `upstream` and `origin`. Numbers:

- `origin/main` is 78 commits behind `upstream/main`.
- `docs/beam-design-daemon-spec` is 47 behind `upstream/main`, ~21 ahead.
- 11 new release tags (latest `open-design-v0.4.1` + 14 beta tags).

Notable upstream changes since last merge (`b675ba8`): Nano Banana image
provider, Qoder CLI adapter, manual edit mode, connection-tester, big
e2e restructure into `e2e/lib/` + `e2e/ui/`, social-media-dashboard
skill, Linux headless mode, accent-color theme, plus daemon stability
fixes (Copilot stdin, OpenCode error frames, Node-24 ZIP import,
`.venv` watcher exclusion).

## Open work

- Resolve the 4 merge conflicts (media additive merge + small
  NewProjectPanel hunk).
- Run `pnpm install`, `pnpm guard`, `pnpm typecheck`, daemon + web
  vitest suites.
- Commit merge.

E2E rerun is out of scope for this pass — directory shape changed
substantially upstream.
