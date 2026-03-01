---
name: git-host-rn-web-before-after
description: This skill should be used when a user needs automated BEFORE/AFTER screenshots for a React Native web app and wants to commit images to a feature branch and update an existing GitHub pull request or GitLab merge request description by auto-detecting the provider from origin.
---

# Git Host RN Web Before/After Screenshot Skill

Keep scope narrow: capture screenshots only. Avoid implementing requested product code changes.

## Purpose

Capture deterministic BEFORE and AFTER screenshots of a React Native app running on web, store local run state, commit screenshots to a feature branch, and update an existing GitHub PR or GitLab MR description with image embeds.

## When to Use

Use when the request is to:

- Capture BEFORE/AFTER screenshots for UI review.
- Attach screenshot evidence to an existing GitHub PR or GitLab MR.
- Run in one pass (`both`) or two passes (`before` then `after`) using local context.

Do not use for app feature implementation or PR/MR template generation beyond the screenshot section.

## Files

- `scripts/screenshot-before-after.sh`: Main CLI workflow.
- `scripts/capture.js`: Puppeteer capture helper.
- `scripts/package.json`: Node dependencies for capture helper.

## Setup

Run from this skill directory:

```bash
cd skills/git-host-rn-web-before-after/scripts
pnpm install
chmod +x screenshot-before-after.sh
```

## Usage

Use `--review-id` for both GitHub PRs and GitLab MRs.

Provider is always auto-detected from `git remote get-url origin`.
Do not ask the user to choose GitHub vs GitLab when `origin` is available.

One-step run (recommended):

```bash
./screenshot-before-after.sh --repo /path/to/app --review-id 123 --mode both
```

Two-step run:

```bash
# Step 1: BEFORE only
./screenshot-before-after.sh --repo /path/to/app --review-id 123 --mode before

# Step 2: AFTER only (reuses context)
./screenshot-before-after.sh --repo /path/to/app --mode after
```

Manual server mode:

```bash
./screenshot-before-after.sh \
  --repo /path/to/app \
  --review-id 123 \
  --mode both \
  --no-server \
  --server-url http://127.0.0.1:19006
```

Provider-specific examples (same command shape):

```bash
# GitHub repo (origin like git@github.com:org/repo.git)
./screenshot-before-after.sh --repo /path/to/app --review-id 123 --mode both

# GitLab repo (origin like git@gitlab.com:group/repo.git)
./screenshot-before-after.sh --repo /path/to/app --review-id 123 --mode both
```

## Context JSON

Default context path:

`~/.config/opencode/skills/screenshot-skill/state/context.json`

Context fields:

- `repo_path`
- `base_branch`
- `feature_branch`
- `review_id`
- `server_url`
- `before_path`
- `after_path`
- `before_commit`
- `after_commit`
- `timestamp`

Auto mode behavior:

- If context matches `repo_path + feature_branch` and has BEFORE but no AFTER, run AFTER.
- Otherwise run BOTH.

## Operational Notes

- Inspect `<repo>/package.json` and require one of: `scripts.web`, `scripts["start:web"]`, `scripts["web:dev"]`.
- Normalize base branch input so `origin/main` and `main` both work.
- Restore original git branch at end, even on failure.
- Prevent screenshot writes outside repo by rejecting absolute paths and traversal (`..`).
- Detect provider from `git remote get-url origin` host.
- Use `gh` for GitHub PR updates and `glab` for GitLab MR updates when available.
- If provider CLI is unavailable (or provider cannot be recognized), print markdown snippet and manual instructions.

## Troubleshooting

- If `origin` is GitLab, missing `gh` is irrelevant; only `glab` is needed for auto-update.
- If `origin` is GitHub, missing `glab` is irrelevant; only `gh` is needed for auto-update.
- If the target PR/MR has no description/template body, create a standardized template with `Summary`, `What Changed`, `Validation`, `Notes`, and the `Before & After` section.
- This skill does not require `.github/pull_request_template.md` or GitLab MR template files to exist in the repository.
- If no provider CLI is installed, still capture/commit/push screenshots and print markdown for manual paste.
