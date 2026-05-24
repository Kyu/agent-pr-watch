#!/usr/bin/env bash
# run-fire.sh — invoked by claude-pr-watch inside a fresh tmux window.
# Runs `claude` interactively against the role's prompt, then cleans up
# the worktree on exit (regardless of how the session ended).
#
# Required env (set via `tmux new-window -e`):
#   ROLE         reviewer | responder
#   PR           PR number
#   HEAD_SHA     PR head commit SHA
#   REPO         owner/name on GitHub
#   REPO_DIR     local path to the main checkout (where .claude/ lives)
#   WT           the throwaway worktree path
#   COMMENT_ID   id of the triggering comment (responder only; "" otherwise)

set -u

: "${ROLE:?missing ROLE}" "${PR:?missing PR}" "${REPO:?missing REPO}"
: "${REPO_DIR:?missing REPO_DIR}" "${WT:?missing WT}"

cleanup() {
  local rc=$?
  cd "$REPO_DIR" 2>/dev/null || cd /tmp
  # Capture the worktree's branch (if any) before removing it, so we can
  # delete the throwaway `claude-responder/*` branch the watcher created.
  local wt_branch=""
  if [ -d "$WT" ]; then
    wt_branch=$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null || true)
  fi
  git worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
  if [[ "$wt_branch" == claude-responder/* ]]; then
    git -C "$REPO_DIR" branch -D "$wt_branch" 2>/dev/null || true
  fi
  echo
  echo "--- claude exited (rc=$rc). worktree removed. press enter to close. ---"
  read -r || true
}
trap cleanup EXIT

PROMPT_FILE="$REPO_DIR/.claude/prompts/${ROLE}.md"
if [ ! -f "$PROMPT_FILE" ]; then
  echo "missing prompt: $PROMPT_FILE" >&2
  exit 1
fi

# If .claude/ isn't part of the PR branch's tree (e.g., committed only on
# main), copy it in from the main checkout so settings.json + prompts are
# available to this claude session.
if [ ! -d ".claude" ] && [ -d "$REPO_DIR/.claude" ]; then
  cp -r "$REPO_DIR/.claude" .
fi

# Expose context to the prompt as env vars (referenced in the .md files).
export PR_NUMBER="$PR"
export PR_HEAD_SHA="$HEAD_SHA"
export GH_REPO="$REPO"
export COMMENT_ID="${COMMENT_ID:-}"

# Pre-trust this worktree so Claude Code's first-run trust prompt doesn't
# gate the fire. Trust state lives in ~/.claude.json under
# .projects[<canonical_path>].hasTrustDialogAccepted. macOS canonicalizes
# /tmp -> /private/tmp so we use `pwd -P` to match.
pretrust_workspace() {
  local cfg="$HOME/.claude.json"
  [ -f "$cfg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local canonical
  canonical="$(cd "$WT" && pwd -P)"

  # Short mutex so concurrent fires don't clobber each other's writes.
  local lock="/tmp/.claude-pr-watch.json.lock"
  local tries=30
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$((tries - 1))
    [ "$tries" -le 0 ] && return 0   # give up; one trust prompt isn't fatal
    sleep 0.1
  done

  local tmp="$cfg.pr-watch.$$"
  if jq --arg p "$canonical" '.projects[$p].hasTrustDialogAccepted = true' \
       "$cfg" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$cfg"
  fi
  rm -f "$tmp" 2>/dev/null
  rmdir "$lock" 2>/dev/null
}
pretrust_workspace

echo "================================================================"
echo "  role:    $ROLE"
echo "  repo:    $REPO"
echo "  PR:      #$PR"
echo "  head:    ${HEAD_SHA:0:12}"
echo "  wt:      $WT"
[ -n "${COMMENT_ID:-}" ] && echo "  comment: $COMMENT_ID"
echo "================================================================"
echo

# Pass the prompt body as the initial user message. Claude executes it,
# then drops into interactive mode — you can attach and chat further.
#
# --dangerously-skip-permissions: skip per-tool permission prompts so the
# fire runs unattended. Risk is bounded: worktree is throwaway under /tmp,
# .claude/settings.json deny rules still apply, and the role prompts have
# hard prohibitions. The workspace trust gate (separate) is handled by
# pretrust_workspace above.
#
# NOTE: Do NOT `exec` — it replaces bash and the EXIT trap (worktree
# cleanup, post-exit message) never fires. Just run normally so bash
# resumes after claude exits and the trap can run.
claude --dangerously-skip-permissions "$(cat "$PROMPT_FILE")"
