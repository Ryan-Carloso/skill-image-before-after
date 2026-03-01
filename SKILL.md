---
name: gitlab-rn-web-before-after
description: This skill should be used when a user needs automated BEFORE/AFTER screenshots for a React Native web app and wants to commit images to a feature branch and update an existing GitLab merge request description.
---

# GitLab RN Web Before/After Screenshot Skill

Keep scope narrow: capture screenshots only. Avoid implementing requested product code changes.

## Purpose

Capture deterministic BEFORE and AFTER screenshots of a React Native app running on web, store local run state, commit screenshots to a feature branch, and update an existing GitLab MR description with image embeds.

## When to Use

Use when the request is to:

- Capture BEFORE/AFTER screenshots for UI review.
- Attach screenshot evidence to an existing GitLab MR.
- Run in one pass (`both`) or two passes (`before` then `after`) using local context.

Do not use for app feature implementation or MR template generation beyond the screenshot section.

## Files

- `scripts/screenshot-before-after.sh`: Main CLI workflow.
- `scripts/capture.js`: Puppeteer capture helper.
- `scripts/package.json`: Node dependencies for capture helper.

## Setup

Run from this skill directory:

```bash
cd skills/gitlab-rn-web-before-after/scripts
pnpm install
chmod +x screenshot-before-after.sh
```

## Usage

One-step run (recommended):

```bash
./screenshot-before-after.sh --repo /path/to/app --mr-id 123 --mode both
```

Two-step run:

```bash
# Step 1: BEFORE only
./screenshot-before-after.sh --repo /path/to/app --mr-id 123 --mode before

# Step 2: AFTER only (reuses context)
./screenshot-before-after.sh --repo /path/to/app --mode after
```

Manual server mode:

```bash
./screenshot-before-after.sh \
  --repo /path/to/app \
  --mr-id 123 \
  --mode both \
  --no-server \
  --server-url http://127.0.0.1:19006
```

## Context JSON

Default context path:

`~/.config/opencode/skills/screenshot-skill/state/context.json`

Context fields:

- `repo_path`
- `base_branch`
- `feature_branch`
- `mr_id`
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
- Use `glab` for MR updates when available. If unavailable, print markdown snippet and instructions.
