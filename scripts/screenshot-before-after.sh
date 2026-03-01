#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CAPTURE_JS="$SCRIPT_DIR/capture.js"

REPO=""
REVIEW_ID=""
BASE_BRANCH_INPUT="origin/main"
FEATURE_BRANCH=""
TARGET_URL=""
SERVER_CMD=""
SERVER_PORT="19006"
SERVER_URL=""
SERVER_PORT_SET="false"
SERVER_URL_SET="false"
NO_SERVER="false"
WAIT_TIMEOUT="60"
BROWSER_PATH="/snap/bin/chromium"
BEFORE_PATH=""
AFTER_PATH=""
BEFORE_PATH_SET="false"
AFTER_PATH_SET="false"
CONTEXT_FILE="$HOME/.config/opencode/skills/screenshot-skill/state/context.json"
MODE="auto"
REUSE_BRANCH="false"
WAIT_UNTIL="networkidle2"
DELAY_MS="500"
EXPO_WEB_SERVER="false"

ORIGINAL_BRANCH=""
SERVER_PID=""
SERVER_LOG=""
RESOLVED_REPO=""
BASE_REF=""
BASE_LOCAL=""
ORIGIN_URL=""
ORIGIN_HOST=""
PROJECT_PATH=""
GIT_PROVIDER="unknown"
REVIEW_URL=""
BEFORE_TMP_FILE=""
RUN_FOLDER_NAME=""
RUN_TIMESTAMP=""

declare -a ACTIONS=()

usage() {
  cat <<'EOF'
screenshot-before-after.sh

Capture BEFORE/AFTER screenshots for a React Native web app and update a GitHub PR or GitLab MR.

Required:
  --repo <path>

Optional:
  --review-id <id>                Pull request / merge request ID
  --base-branch <name>            Default: origin/main (accepts origin/main or main)
  --feature-branch <name>         Default: current branch
  --url <url>                     Default: inferred route from diff on --server-url
  --server-cmd <cmd>              Default: autodetect from package.json scripts
  --server-port <port>            Default: 19006
  --server-url <url>              Default: http://127.0.0.1:<port>
  --no-server                     Do not start local dev server
  --wait-timeout <secs>           Default: 60
  --browser <path>                Default: /snap/bin/chromium
  --before-path <path>            Default: <branch>-<timestamp>/before.png
  --after-path <path>             Default: <branch>-<timestamp>/after.png
  --context-file <path>           Default: ~/.config/opencode/skills/screenshot-skill/state/context.json
  --mode <auto|before|after|both> Default: auto
  --reuse-branch                  Keep existing feature branch and avoid branch creation fallback
  --wait-until <mode>             load|domcontentloaded|networkidle0|networkidle2
  --delay-ms <ms>                 Default: 500
  -h, --help

Examples:
  ./screenshot-before-after.sh --repo /work/app --review-id 12 --mode both
  ./screenshot-before-after.sh --repo /work/app --review-id 12 --mode before
  ./screenshot-before-after.sh --repo /work/app --mode after
EOF
}

log() {
  printf '[info] %s\n' "$*"
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

fail() {
  printf '[error] %s\n' "$*" >&2
  exit 1
}

add_action() {
  local item="$1"
  ACTIONS+=("$item")
}

emit_action_list() {
  if [[ "${#ACTIONS[@]}" -eq 0 ]]; then
    return
  fi

  printf 'Completed actions:\n'
  local item
  for item in "${ACTIONS[@]}"; do
    printf -- '- %s\n' "$item"
  done
}

ensure_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
}

validate_relative_repo_path() {
  local value="$1"
  [[ -n "$value" ]] || fail "Screenshot path cannot be empty"
  [[ "$value" != /* ]] || fail "Screenshot paths must be relative to repo, got absolute: $value"
  case "$value" in
    *".."* )
      # Strict traversal defense for this skill.
      if [[ "$value" == ".." || "$value" == ../* || "$value" == */.. || "$value" == */../* ]]; then
        fail "Screenshot path cannot contain '..': $value"
      fi
      ;;
  esac
}

json_get_field() {
  local file="$1"
  local field="$2"
  node - "$file" "$field" <<'NODE'
const fs = require('node:fs');
const file = process.argv[2];
const field = process.argv[3];
try {
  const text = fs.readFileSync(file, 'utf8');
  const data = JSON.parse(text);
  const value = data[field];
  if (value === undefined || value === null) {
    process.stdout.write('');
  } else {
    process.stdout.write(String(value));
  }
} catch {
  process.stdout.write('');
}
NODE
}

write_context() {
  local before_commit="$1"
  local after_commit="$2"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(dirname "$CONTEXT_FILE")"
  node - "$CONTEXT_FILE" "$RESOLVED_REPO" "$BASE_REF" "$FEATURE_BRANCH" "$REVIEW_ID" "$SERVER_URL" "$BEFORE_PATH" "$AFTER_PATH" "$RUN_FOLDER_NAME" "$before_commit" "$after_commit" "$ts" <<'NODE'
const fs = require('node:fs');
const [file, repoPath, baseBranch, featureBranch, reviewId, serverUrl, beforePath, afterPath, runFolderName, beforeCommit, afterCommit, timestamp] = process.argv.slice(2);
const data = {
  repo_path: repoPath,
  base_branch: baseBranch,
  feature_branch: featureBranch,
  review_id: reviewId || '',
  server_url: serverUrl,
  before_path: beforePath,
  after_path: afterPath,
  run_folder_name: runFolderName || '',
  before_commit: beforeCommit || '',
  after_commit: afterCommit || '',
  timestamp,
};
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
NODE
}

start_server() {
  if [[ "$NO_SERVER" == "true" ]]; then
    log "Server startup disabled by --no-server"
    return
  fi

  SERVER_LOG="$(mktemp -t screenshot-skill-server.XXXXXX.log)"
  log "Starting server: $SERVER_CMD"
  (
    cd "$RESOLVED_REPO"
    bash -lc "$SERVER_CMD" >"$SERVER_LOG" 2>&1
  ) &
  SERVER_PID="$!"
}

stop_server() {
  if [[ -n "$SERVER_PID" ]]; then
    if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      kill "$SERVER_PID" >/dev/null 2>&1 || true
      wait "$SERVER_PID" 2>/dev/null || true
    fi
    SERVER_PID=""
  fi
}

wait_for_server() {
  local timeout_secs="$1"
  local elapsed=0
  while (( elapsed < timeout_secs )); do
    if node - "$SERVER_URL" <<'NODE'
const raw = process.argv[2];
if (!raw) process.exit(1);
let parsed;
try {
  parsed = new URL(raw);
} catch {
  process.exit(1);
}
const mod = parsed.protocol === 'https:' ? require('node:https') : require('node:http');
const req = mod.request(parsed, { method: 'GET', timeout: 2000 }, (res) => {
  res.resume();
  process.exit(0);
});
req.on('error', () => process.exit(1));
req.on('timeout', () => {
  req.destroy();
  process.exit(1);
});
req.end();
NODE
    then
      log "Server reachable at $SERVER_URL"
      return
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  warn "Server did not become reachable within ${timeout_secs}s: $SERVER_URL"
  if [[ -n "$SERVER_LOG" && -f "$SERVER_LOG" ]]; then
    warn "Server log ($SERVER_LOG):"
    cat "$SERVER_LOG" >&2
  fi
  fail "Timeout waiting for server"
}

normalize_base_branch() {
  local input="$1"
  local candidate=""

  if [[ "$input" == origin/* ]]; then
    BASE_LOCAL="${input#origin/}"
  else
    BASE_LOCAL="$input"
  fi
  [[ -n "$BASE_LOCAL" ]] || fail "Invalid --base-branch: $input"

  if git -C "$RESOLVED_REPO" show-ref --verify --quiet "refs/remotes/origin/$BASE_LOCAL"; then
    candidate="origin/$BASE_LOCAL"
  elif git -C "$RESOLVED_REPO" show-ref --verify --quiet "refs/heads/$BASE_LOCAL"; then
    candidate="$BASE_LOCAL"
  else
    fail "Base branch not found as origin/$BASE_LOCAL or $BASE_LOCAL"
  fi

  BASE_REF="$candidate"
}

switch_to_branch() {
  local branch="$1"

  if git -C "$RESOLVED_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$RESOLVED_REPO" checkout "$branch" >/dev/null
    return
  fi

  if git -C "$RESOLVED_REPO" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$RESOLVED_REPO" checkout -b "$branch" --track "origin/$branch" >/dev/null
    return
  fi

  if [[ "$REUSE_BRANCH" == "true" ]]; then
    fail "Feature branch '$branch' does not exist locally or on origin, and --reuse-branch is set"
  fi

  warn "Feature branch '$branch' not found. Creating from current HEAD."
  git -C "$RESOLVED_REPO" checkout -b "$branch" >/dev/null
}

capture_shot() {
  local output_path="$1"
  validate_relative_repo_path "$output_path"

  if [[ "$NO_SERVER" == "false" ]]; then
    start_server
    wait_for_server "$WAIT_TIMEOUT"
  fi

  (
    cd "$RESOLVED_REPO"
    node "$CAPTURE_JS" \
      --url "$TARGET_URL" \
      --output "$output_path" \
      --browser "$BROWSER_PATH" \
      --wait-until "$WAIT_UNTIL" \
      --delay-ms "$DELAY_MS" \
      --full-page true
  )

  stop_server
}

get_commit_hash() {
  git -C "$RESOLVED_REPO" rev-parse --short HEAD
}

encode_url_component() {
  local input="$1"
  node - "$input" <<'NODE'
const input = process.argv[2] || '';
process.stdout.write(encodeURIComponent(input));
NODE
}

parse_origin_url() {
  ORIGIN_URL="$(git -C "$RESOLVED_REPO" remote get-url origin)"
  ORIGIN_HOST=""
  PROJECT_PATH=""

  if [[ "$ORIGIN_URL" =~ ^git@([^:]+):(.+)$ ]]; then
    ORIGIN_HOST="${BASH_REMATCH[1]}"
    PROJECT_PATH="${BASH_REMATCH[2]}"
  elif [[ "$ORIGIN_URL" =~ ^ssh://git@([^/]+)/(.+)$ ]]; then
    ORIGIN_HOST="${BASH_REMATCH[1]}"
    PROJECT_PATH="${BASH_REMATCH[2]}"
  elif [[ "$ORIGIN_URL" =~ ^https?://([^/]+)/(.+)$ ]]; then
    ORIGIN_HOST="${BASH_REMATCH[1]}"
    PROJECT_PATH="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  PROJECT_PATH="${PROJECT_PATH%.git}"
  [[ -n "$ORIGIN_HOST" && -n "$PROJECT_PATH" ]]
}

detect_git_provider() {
  local host_lower
  host_lower="$(printf '%s' "$ORIGIN_HOST" | tr '[:upper:]' '[:lower:]')"

  if [[ "$host_lower" == *"github"* ]]; then
    GIT_PROVIDER="github"
    return
  fi
  if [[ "$host_lower" == *"gitlab"* ]]; then
    GIT_PROVIDER="gitlab"
    return
  fi

  GIT_PROVIDER="unknown"
}

build_image_links() {
  local branch_encoded
  branch_encoded="$(encode_url_component "$FEATURE_BRANCH")"
  local branch_literal
  branch_literal="$FEATURE_BRANCH"

  case "$GIT_PROVIDER" in
    gitlab)
      printf 'https://%s/%s/-/raw/%s/%s\n' "$ORIGIN_HOST" "$PROJECT_PATH" "$branch_encoded" "$BEFORE_PATH"
      printf 'https://%s/%s/-/raw/%s/%s\n' "$ORIGIN_HOST" "$PROJECT_PATH" "$branch_encoded" "$AFTER_PATH"
      ;;
    github)
      printf 'https://%s/%s/blob/%s/%s?raw=1\n' "$ORIGIN_HOST" "$PROJECT_PATH" "$branch_literal" "$BEFORE_PATH"
      printf 'https://%s/%s/blob/%s/%s?raw=1\n' "$ORIGIN_HOST" "$PROJECT_PATH" "$branch_literal" "$AFTER_PATH"
      ;;
    *)
      return 1
      ;;
  esac
}

build_review_section() {
  local before_link="$1"
  local after_link="$2"

  cat <<EOF
## Before & After

### Before
![Before]($before_link)

### After
![After]($after_link)
EOF
}

build_default_review_template() {
  local section_text="$1"
  cat <<EOF
## Summary

- Add BEFORE/AFTER screenshot evidence for UI review.

## What Changed

- Capture a deterministic BEFORE screenshot from the base branch.
- Capture an AFTER screenshot from the feature branch.
- Commit and push screenshot assets to the feature branch.

## Validation

- [ ] Visual check completed for BEFORE and AFTER images.
- [ ] Screenshot paths and links render correctly in the review description.

## Notes

- Replace checklist items or add context specific to this change.

$section_text
EOF
}

update_review_description() {
  local section_text="$1"

  if [[ -z "$REVIEW_ID" ]]; then
    warn "No --review-id provided. Skipping review update."
    printf '%s\n' "$section_text"
    return
  fi

  local current_desc=""
  local platform_label="review"

  if [[ "$GIT_PROVIDER" == "gitlab" ]]; then
    platform_label="MR"
    if ! command -v glab >/dev/null 2>&1; then
      warn "glab is not installed. Cannot auto-update GitLab MR."
      printf '\nPaste this into %s #%s description:\n\n%s\n' "$platform_label" "$REVIEW_ID" "$section_text"
      return
    fi
    if ! (cd "$RESOLVED_REPO" && glab auth status >/dev/null 2>&1); then
      warn "glab is not authenticated. Cannot auto-update GitLab MR."
      printf '\nPaste this into %s #%s description:\n\n%s\n' "$platform_label" "$REVIEW_ID" "$section_text"
      return
    fi
    current_desc="$(cd "$RESOLVED_REPO" && glab mr view "$REVIEW_ID" --json description --jq .description 2>/dev/null || true)"
  elif [[ "$GIT_PROVIDER" == "github" ]]; then
    platform_label="PR"
    if ! command -v gh >/dev/null 2>&1; then
      warn "gh is not installed. Cannot auto-update GitHub PR."
      printf '\nPaste this into %s #%s description:\n\n%s\n' "$platform_label" "$REVIEW_ID" "$section_text"
      return
    fi
    current_desc="$(cd "$RESOLVED_REPO" && gh pr view "$REVIEW_ID" --json body --jq .body 2>/dev/null || true)"
  else
    warn "Origin provider is unknown. Cannot auto-update review description."
    printf '\nPaste this into review #%s description:\n\n%s\n' "$REVIEW_ID" "$section_text"
    return
  fi

  local has_existing_template="false"
  if [[ -n "${current_desc//[[:space:]]/}" ]]; then
    has_existing_template="true"
  fi

  if [[ "$has_existing_template" == "false" ]]; then
    log "No existing $platform_label template found. Creating a new template body."
    current_desc="$(build_default_review_template "$section_text")"
  fi

  local new_desc
  new_desc="$(node - "$current_desc" "$section_text" "$has_existing_template" <<'NODE'
const currentDesc = process.argv[2] || '';
const section = process.argv[3] || '';
const hasExistingTemplate = process.argv[4] === 'true';
if (!hasExistingTemplate) {
  process.stdout.write(currentDesc.trimEnd() + '\n');
  process.exit(0);
}
const regex = /\n?## Before & After[\s\S]*?(?=\n##\s|$)/m;
const updated = regex.test(currentDesc)
  ? currentDesc.replace(regex, `\n${section}\n`)
  : `${currentDesc}${currentDesc.trim().length ? '\n\n' : ''}${section}\n`;
process.stdout.write(updated);
NODE
)"

  if [[ "$GIT_PROVIDER" == "gitlab" ]]; then
    (cd "$RESOLVED_REPO" && glab mr update "$REVIEW_ID" --description "$new_desc" >/dev/null)
    log "Updated GitLab MR #$REVIEW_ID description"
    add_action "Updated GitLab MR #$REVIEW_ID description"
    return
  fi

  (cd "$RESOLVED_REPO" && gh pr edit "$REVIEW_ID" --body "$new_desc" >/dev/null)
  log "Updated GitHub PR #$REVIEW_ID description"
  add_action "Updated GitHub PR #$REVIEW_ID description"
}

cleanup() {
  stop_server
  if [[ -n "$BEFORE_TMP_FILE" && -f "$BEFORE_TMP_FILE" ]]; then
    rm -f "$BEFORE_TMP_FILE" || true
  fi
  if [[ -n "$ORIGINAL_BRANCH" ]]; then
    git -C "$RESOLVED_REPO" checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        REPO="${2:-}"
        shift 2
        ;;
      --review-id)
        REVIEW_ID="${2:-}"
        shift 2
        ;;
      --base-branch)
        BASE_BRANCH_INPUT="${2:-}"
        shift 2
        ;;
      --feature-branch)
        FEATURE_BRANCH="${2:-}"
        shift 2
        ;;
      --url)
        TARGET_URL="${2:-}"
        shift 2
        ;;
      --server-cmd)
        SERVER_CMD="${2:-}"
        shift 2
        ;;
      --server-port)
        SERVER_PORT="${2:-}"
        SERVER_PORT_SET="true"
        shift 2
        ;;
      --server-url)
        SERVER_URL="${2:-}"
        SERVER_URL_SET="true"
        shift 2
        ;;
      --no-server)
        NO_SERVER="true"
        shift
        ;;
      --wait-timeout)
        WAIT_TIMEOUT="${2:-}"
        shift 2
        ;;
      --browser)
        BROWSER_PATH="${2:-}"
        shift 2
        ;;
      --before-path)
        BEFORE_PATH="${2:-}"
        BEFORE_PATH_SET="true"
        shift 2
        ;;
      --after-path)
        AFTER_PATH="${2:-}"
        AFTER_PATH_SET="true"
        shift 2
        ;;
      --context-file)
        CONTEXT_FILE="${2:-}"
        shift 2
        ;;
      --mode)
        MODE="${2:-}"
        shift 2
        ;;
      --reuse-branch)
        REUSE_BRANCH="true"
        shift
        ;;
      --wait-until)
        WAIT_UNTIL="${2:-}"
        shift 2
        ;;
      --delay-ms)
        DELAY_MS="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

autodetect_web_script_and_server_cmd() {
  local result
  result="$(node - "$RESOLVED_REPO/package.json" "$SERVER_CMD" <<'NODE'
const fs = require('node:fs');
const pkgPath = process.argv[2];
const given = (process.argv[3] || '').trim();
try {
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
  const scripts = pkg && typeof pkg === 'object' ? pkg.scripts : undefined;
  if (!scripts || typeof scripts !== 'object') {
    process.stdout.write(JSON.stringify({ ok: false, message: 'No web script found in package.json' }));
    process.exit(0);
  }

  const hasWeb = typeof scripts.web === 'string';
  const hasStartWeb = typeof scripts['start:web'] === 'string';
  const hasWebDev = typeof scripts['web:dev'] === 'string';

  if (!hasWeb && !hasStartWeb && !hasWebDev) {
    process.stdout.write(JSON.stringify({ ok: false, message: 'No web script found in package.json' }));
    process.exit(0);
  }

  if (given.length > 0) {
    process.stdout.write(JSON.stringify({ ok: true, serverCmd: given }));
    process.exit(0);
  }

  if (hasWeb) {
    process.stdout.write(JSON.stringify({ ok: true, serverCmd: 'pnpm web' }));
    process.exit(0);
  }
  if (hasStartWeb) {
    process.stdout.write(JSON.stringify({ ok: true, serverCmd: 'pnpm start:web' }));
    process.exit(0);
  }
  process.stdout.write(JSON.stringify({ ok: true, serverCmd: 'pnpm web:dev' }));
} catch {
  process.stdout.write(JSON.stringify({ ok: false, message: 'Cannot read package.json' }));
}
NODE
)"

  local ok
  ok="$(node - "$result" <<'NODE'
const input = process.argv[2];
try { process.stdout.write(String(Boolean(JSON.parse(input).ok))); }
catch { process.stdout.write('false'); }
NODE
)"
  if [[ "$ok" != "true" ]]; then
    local msg
    msg="$(node - "$result" <<'NODE'
const input = process.argv[2];
try { process.stdout.write(String(JSON.parse(input).message || 'Unknown package.json detection error')); }
catch { process.stdout.write('Unknown package.json detection error'); }
NODE
)"
    fail "$msg"
  fi

  SERVER_CMD="$(node - "$result" <<'NODE'
const input = process.argv[2];
try { process.stdout.write(String(JSON.parse(input).serverCmd || '')); }
catch { process.stdout.write(''); }
NODE
)"
  [[ -n "$SERVER_CMD" ]] || fail "Unable to determine server command. Pass --server-cmd."
}

normalize_server_runtime_for_expo() {
  local cmd_lc
  cmd_lc="$(printf '%s' "$SERVER_CMD" | tr '[:upper:]' '[:lower:]')"
  if [[ "$cmd_lc" == *"expo start --web"* || "$cmd_lc" == "pnpm web" || "$cmd_lc" == "pnpm start:web" || "$cmd_lc" == "pnpm web:dev" ]]; then
    EXPO_WEB_SERVER="true"
  fi

  if [[ "$EXPO_WEB_SERVER" == "true" ]]; then
    if [[ "$SERVER_PORT_SET" == "false" && "$SERVER_URL_SET" == "false" ]]; then
      SERVER_PORT="8081"
    fi
  fi
}

sanitize_branch_name_for_path() {
  local branch_name="$1"
  local sanitized
  sanitized="$(printf '%s' "$branch_name" | tr '/ ' '-' | tr -c '[:alnum:]._-' '-')"
  sanitized="$(printf '%s' "$sanitized" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "$sanitized" ]]; then
    sanitized="branch"
  fi
  printf '%s\n' "$sanitized"
}

configure_output_paths_for_run() {
  local ctx_before_path=""
  local ctx_after_path=""
  local ctx_folder=""
  local safe_branch=""

  if [[ "$BEFORE_PATH_SET" == "true" && "$AFTER_PATH_SET" == "false" ]]; then
    AFTER_PATH="$(dirname "$BEFORE_PATH")/after.png"
    AFTER_PATH_SET="true"
  elif [[ "$BEFORE_PATH_SET" == "false" && "$AFTER_PATH_SET" == "true" ]]; then
    BEFORE_PATH="$(dirname "$AFTER_PATH")/before.png"
    BEFORE_PATH_SET="true"
  fi

  if [[ "$BEFORE_PATH_SET" == "true" && "$AFTER_PATH_SET" == "true" ]]; then
    RUN_FOLDER_NAME="$(dirname "$BEFORE_PATH")"
    return
  fi

  if [[ "$MODE" == "after" ]]; then
    ctx_before_path="$(json_get_field "$CONTEXT_FILE" "before_path")"
    ctx_after_path="$(json_get_field "$CONTEXT_FILE" "after_path")"

    if [[ -n "$ctx_before_path" && -n "$ctx_after_path" ]]; then
      BEFORE_PATH="$ctx_before_path"
      AFTER_PATH="$ctx_after_path"
      RUN_FOLDER_NAME="$(dirname "$ctx_before_path")"
      if [[ "$RUN_FOLDER_NAME" == "." ]]; then
        RUN_FOLDER_NAME="$(dirname "$ctx_after_path")"
      fi
      return
    fi

    ctx_folder="$(json_get_field "$CONTEXT_FILE" "run_folder_name")"
    if [[ -z "$ctx_folder" && -n "$ctx_before_path" ]]; then
      ctx_folder="$(dirname "$ctx_before_path")"
    fi
    if [[ -z "$ctx_folder" || "$ctx_folder" == "." ]]; then
      fail "Mode 'after' requires run folder in context. Run --mode before or --mode both first."
    fi
    RUN_FOLDER_NAME="$ctx_folder"
  else
    RUN_TIMESTAMP="$(date -u +%Y%m%d-%H%M%SZ)"
    safe_branch="$(sanitize_branch_name_for_path "$FEATURE_BRANCH")"
    RUN_FOLDER_NAME="${safe_branch}-${RUN_TIMESTAMP}"
  fi

  mkdir -p "$RESOLVED_REPO/screenshots"
  BEFORE_PATH="screenshots/$RUN_FOLDER_NAME/before.png"
  AFTER_PATH="screenshots/$RUN_FOLDER_NAME/after.png"
}

resolve_mode_from_context() {
  if [[ "$MODE" != "auto" ]]; then
    return
  fi

  if [[ ! -f "$CONTEXT_FILE" ]]; then
    MODE="both"
    return
  fi

  local ctx_repo ctx_feature ctx_before ctx_after
  ctx_repo="$(json_get_field "$CONTEXT_FILE" "repo_path")"
  ctx_feature="$(json_get_field "$CONTEXT_FILE" "feature_branch")"
  ctx_before="$(json_get_field "$CONTEXT_FILE" "before_commit")"
  ctx_after="$(json_get_field "$CONTEXT_FILE" "after_commit")"

  if [[ "$ctx_repo" == "$RESOLVED_REPO" && "$ctx_feature" == "$FEATURE_BRANCH" && -n "$ctx_before" && -z "$ctx_after" ]]; then
    MODE="after"
  else
    MODE="both"
  fi
}

commit_screenshots() {
  local changed="true"
  git -C "$RESOLVED_REPO" add -- "$BEFORE_PATH" "$AFTER_PATH"

  if git -C "$RESOLVED_REPO" diff --cached --quiet; then
    changed="false"
    warn "No screenshot changes to commit (idempotent run)."
    add_action "No screenshot file changes to commit"
  else
    git -C "$RESOLVED_REPO" commit -m "chore: update before-after screenshots" >/dev/null
    log "Committed screenshot changes"
    add_action "Committed screenshot files"
  fi

  if [[ "$changed" == "false" ]]; then
    log "Continuing to review update despite no git diff"
  fi
}

push_feature_branch() {
  git -C "$RESOLVED_REPO" push -u origin "$FEATURE_BRANCH" >/dev/null
  log "Pushed branch $FEATURE_BRANCH"
  add_action "Pushed feature branch to origin"

}

create_gitlab_mr_via_push_options() {
  local description_text="$1"
  local title_text
  local description_compact
  title_text="chore: update before-after screenshots"
  description_compact="$(node - "$description_text" <<'NODE'
const input = process.argv[2] || '';
const compact = input.replace(/\r/g, '').replace(/\n+/g, ' ').replace(/\s{2,}/g, ' ').trim();
process.stdout.write(compact);
NODE
)"
  local output

  output="$(git -C "$RESOLVED_REPO" push -u origin "$FEATURE_BRANCH" \
    -o merge_request.create \
    -o "merge_request.target=$BASE_LOCAL" \
    -o "merge_request.title=$title_text" \
    -o "merge_request.description=$description_compact" 2>&1 || true)"

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi
  add_action "Pushed feature branch with GitLab MR options"

  REVIEW_URL="$(node - "$output" <<'NODE'
const input = process.argv[2] || '';
const match = input.match(/https:\/\/[^\s]+\/-\/merge_requests\/(\d+)/);
if (!match) {
  process.stdout.write('');
  process.exit(0);
}
process.stdout.write(match[0]);
NODE
)"

  if [[ -n "$REVIEW_URL" ]]; then
    log "Created GitLab MR: $REVIEW_URL"
    add_action "Resolved GitLab MR URL"
  else
    warn "Could not confirm MR creation from push output"
  fi

  local iid
  iid="$(node - "$REVIEW_URL" <<'NODE'
const url = process.argv[2] || '';
const match = url.match(/\/merge_requests\/(\d+)/);
if (!match) {
  process.stdout.write('');
  process.exit(0);
}
process.stdout.write(match[1]);
NODE
)"
  if [[ -n "$iid" ]]; then
    REVIEW_ID="$iid"
  fi
}

emit_review_url() {
  if [[ -n "$REVIEW_URL" ]]; then
    log "Review URL: $REVIEW_URL"
    add_action "Review URL: $REVIEW_URL"
  elif [[ "$GIT_PROVIDER" == "gitlab" ]]; then
    local branch_encoded
    branch_encoded="$(encode_url_component "$FEATURE_BRANCH")"
    log "Review URL: https://$ORIGIN_HOST/$PROJECT_PATH/-/merge_requests/new?merge_request%5Bsource_branch%5D=$branch_encoded"
    add_action "Review URL: https://$ORIGIN_HOST/$PROJECT_PATH/-/merge_requests/new?merge_request%5Bsource_branch%5D=$branch_encoded"
  fi
}

finalize_push_without_mr_creation() {
  push_feature_branch

  if [[ "$GIT_PROVIDER" == "gitlab" && -z "$REVIEW_ID" ]]; then
    emit_review_url
  fi
}

resolve_feature_ref_for_diff() {
  local candidate="$1"

  if [[ -z "$candidate" || "$candidate" == "HEAD" ]]; then
    printf '%s\n' ""
    return
  fi

  if git -C "$RESOLVED_REPO" show-ref --verify --quiet "refs/heads/$candidate"; then
    printf '%s\n' "$candidate"
    return
  fi

  if git -C "$RESOLVED_REPO" show-ref --verify --quiet "refs/remotes/origin/$candidate"; then
    printf '%s\n' "origin/$candidate"
    return
  fi

  printf '%s\n' ""
}

infer_target_route_from_diff() {
  local feature_ref="$1"
  local diff_files=""

  if [[ -z "$feature_ref" ]]; then
    printf '/\n'
    return
  fi

  diff_files="$(git -C "$RESOLVED_REPO" diff --name-only "$BASE_REF...$feature_ref" 2>/dev/null || true)"

  node - "$diff_files" <<'NODE'
const input = process.argv[2] || '';
const files = input
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean);

const appFiles = files.filter((file) => /^src\/app\/.+\.(tsx|ts|jsx|js)$/.test(file));

const excludedBaseNames = new Set(['_layout', '_sitemap', '+not-found']);

function toRoute(filePath) {
  const withoutPrefix = filePath.replace(/^src\/app\//, '');
  const withoutExt = withoutPrefix.replace(/\.(tsx|ts|jsx|js)$/, '');
  const rawSegments = withoutExt.split('/').filter(Boolean);
  const routeSegments = [];

  for (const segment of rawSegments) {
    if (segment === 'index') {
      continue;
    }
    if (segment.startsWith('(') && segment.endsWith(')')) {
      continue;
    }
    if (segment.startsWith('[') && segment.endsWith(']')) {
      routeSegments.push(segment.startsWith('[...') ? 'all' : '1');
      continue;
    }
    if (segment.startsWith('_') || segment.startsWith('+')) {
      continue;
    }
    routeSegments.push(segment);
  }

  const route = `/${routeSegments.join('/')}`.replace(/\/+/g, '/');
  return route.length > 1 && route.endsWith('/') ? route.slice(0, -1) : route;
}

const candidates = [];
for (const filePath of appFiles) {
  const basenameWithExt = filePath.split('/').pop() || '';
  const basename = basenameWithExt.replace(/\.(tsx|ts|jsx|js)$/, '');
  if (excludedBaseNames.has(basename)) {
    continue;
  }
  candidates.push({ filePath, route: toRoute(filePath) });
}

let chosen = '/';
for (const candidate of candidates) {
  if (candidate.route !== '/') {
    chosen = candidate.route;
    break;
  }
}

if (chosen === '/' && candidates.length > 0) {
  chosen = candidates[0].route;
}

process.stdout.write(chosen || '/');
NODE
}

join_server_url_and_route() {
  local server_url="$1"
  local route_path="$2"

  node - "$server_url" "$route_path" <<'NODE'
const serverUrl = process.argv[2] || '';
const routePath = process.argv[3] || '/';
const normalizedPath = routePath.startsWith('/') ? routePath : `/${routePath}`;
try {
  const url = new URL(serverUrl);
  const basePath = url.pathname.endsWith('/') ? url.pathname.slice(0, -1) : url.pathname;
  url.pathname = `${basePath}${normalizedPath}`.replace(/\/+/g, '/');
  url.search = '';
  url.hash = '';
  process.stdout.write(url.toString());
} catch {
  process.stdout.write(serverUrl);
}
NODE
}

resolve_target_url() {
  if [[ -n "$TARGET_URL" ]]; then
    log "Using explicit target URL: $TARGET_URL"
    add_action "Using explicit target URL"
    return
  fi

  local feature_ref_for_diff
  local inferred_route

  feature_ref_for_diff="$(resolve_feature_ref_for_diff "$FEATURE_BRANCH")"
  if [[ -z "$feature_ref_for_diff" ]]; then
    warn "Could not resolve feature branch ref for diff. Falling back to root route '/'."
    inferred_route="/"
  else
    inferred_route="$(infer_target_route_from_diff "$feature_ref_for_diff")"
  fi

  TARGET_URL="$(join_server_url_and_route "$SERVER_URL" "$inferred_route")"
  log "Auto-selected target route from diff: $inferred_route"
  log "Resolved target URL: $TARGET_URL"
  add_action "Inferred target route from branch diff: $inferred_route"
}

main() {
  parse_args "$@"

  [[ -n "$REPO" ]] || fail "Missing required --repo"
  [[ -d "$REPO" ]] || fail "Repo path does not exist: $REPO"

  ensure_command git
  ensure_command node

  RESOLVED_REPO="$(cd "$REPO" && pwd -P)"
  git -C "$RESOLVED_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "Not a git repository: $RESOLVED_REPO"
  [[ -f "$RESOLVED_REPO/package.json" ]] || fail "Missing package.json in repo: $RESOLVED_REPO"
  [[ -f "$CAPTURE_JS" ]] || fail "Missing capture helper: $CAPTURE_JS"
  parse_origin_url || fail "Could not parse origin remote URL"
  detect_git_provider
  log "Detected git provider from origin: $GIT_PROVIDER ($ORIGIN_HOST)"

  autodetect_web_script_and_server_cmd
  normalize_server_runtime_for_expo

  if [[ -z "$SERVER_URL" ]]; then
    SERVER_URL="http://127.0.0.1:${SERVER_PORT}"
  fi
  ORIGINAL_BRANCH="$(git -C "$RESOLVED_REPO" rev-parse --abbrev-ref HEAD)"
  if [[ -z "$FEATURE_BRANCH" ]]; then
    FEATURE_BRANCH="$ORIGINAL_BRANCH"
  fi

  [[ "$MODE" == "auto" || "$MODE" == "before" || "$MODE" == "after" || "$MODE" == "both" ]] || fail "Invalid --mode: $MODE"
  trap cleanup EXIT

  git -C "$RESOLVED_REPO" fetch origin >/dev/null
  normalize_base_branch "$BASE_BRANCH_INPUT"
  resolve_mode_from_context
  configure_output_paths_for_run
  validate_relative_repo_path "$BEFORE_PATH"
  validate_relative_repo_path "$AFTER_PATH"
  resolve_target_url
  add_action "Capture folder: $RUN_FOLDER_NAME"
  add_action "Before path: $BEFORE_PATH"
  add_action "After path: $AFTER_PATH"
  log "Resolved mode: $MODE"

  local before_commit=""
  local after_commit=""

  if [[ "$MODE" == "before" || "$MODE" == "both" ]]; then
    log "Capturing BEFORE from $BASE_REF"
    git -C "$RESOLVED_REPO" checkout --detach "$BASE_REF" >/dev/null
    capture_shot "$BEFORE_PATH"
    add_action "Captured BEFORE screenshot from $BASE_REF"
    before_commit="$(get_commit_hash)"

    if [[ "$MODE" == "both" ]]; then
      BEFORE_TMP_FILE="$(mktemp -t screenshot-before.XXXXXX.png)"
      cp "$RESOLVED_REPO/$BEFORE_PATH" "$BEFORE_TMP_FILE"
      rm -f "$RESOLVED_REPO/$BEFORE_PATH"
    fi

    write_context "$before_commit" ""
    log "Saved BEFORE context to $CONTEXT_FILE"
    add_action "Saved context file"
  fi

  if [[ "$MODE" == "after" ]]; then
    if [[ ! -f "$CONTEXT_FILE" ]]; then
      fail "Mode 'after' requires a prior BEFORE context file or use --mode both"
    fi
    local ctx_repo ctx_feature ctx_before
    ctx_repo="$(json_get_field "$CONTEXT_FILE" "repo_path")"
    ctx_feature="$(json_get_field "$CONTEXT_FILE" "feature_branch")"
    ctx_before="$(json_get_field "$CONTEXT_FILE" "before_commit")"
    if [[ "$ctx_repo" != "$RESOLVED_REPO" || "$ctx_feature" != "$FEATURE_BRANCH" || -z "$ctx_before" ]]; then
      fail "Mode 'after' requires matching BEFORE context for this repo and feature branch"
    fi
    before_commit="$ctx_before"
    [[ -f "$RESOLVED_REPO/$BEFORE_PATH" ]] || fail "Missing BEFORE screenshot file at $BEFORE_PATH. Run --mode before again or use --mode both."
    if [[ -z "$REVIEW_ID" ]]; then
      REVIEW_ID="$(json_get_field "$CONTEXT_FILE" "review_id")"
    fi
  fi

  if [[ "$MODE" == "after" || "$MODE" == "both" ]]; then
    log "Capturing AFTER from feature branch $FEATURE_BRANCH"
    switch_to_branch "$FEATURE_BRANCH"

    if [[ -n "$BEFORE_TMP_FILE" && -f "$BEFORE_TMP_FILE" ]]; then
      mkdir -p "$RESOLVED_REPO/$(dirname "$BEFORE_PATH")"
      cp "$BEFORE_TMP_FILE" "$RESOLVED_REPO/$BEFORE_PATH"
      rm -f "$BEFORE_TMP_FILE"
      BEFORE_TMP_FILE=""
    fi

    capture_shot "$AFTER_PATH"
    add_action "Captured AFTER screenshot from $FEATURE_BRANCH"
    after_commit="$(get_commit_hash)"

    if [[ "$MODE" == "both" ]]; then
      before_commit="${before_commit:-$(json_get_field "$CONTEXT_FILE" "before_commit")}"
    fi

    write_context "$before_commit" "$after_commit"
    add_action "Updated context with BEFORE/AFTER commits"
    commit_screenshots

    local before_link=""
    local after_link=""
    local section=""
    local review_body=""
    local links=""
    if links="$(build_image_links)"; then
      local line_index=0
      while IFS= read -r link_line; do
        if [[ "$line_index" -eq 0 ]]; then
          before_link="$link_line"
        elif [[ "$line_index" -eq 1 ]]; then
          after_link="$link_line"
          break
        fi
        line_index=$((line_index + 1))
      done <<<"$links"
    else
      warn "Could not build provider-specific links from origin URL. Falling back to relative paths."
      before_link="$BEFORE_PATH"
      after_link="$AFTER_PATH"
    fi

    section="$(build_review_section "$before_link" "$after_link")"

    if [[ "$GIT_PROVIDER" == "gitlab" && -z "$REVIEW_ID" ]]; then
      review_body="$(build_default_review_template "$section")"
      create_gitlab_mr_via_push_options "$review_body"
      emit_review_url
      add_action "Created or reused GitLab MR and printed review URL"
      emit_action_list
      log "Done"
      return
    fi

    finalize_push_without_mr_creation
    update_review_description "$section"
  fi

  emit_action_list
  log "Done"
}

main "$@"
