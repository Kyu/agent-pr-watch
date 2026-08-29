#!/usr/bin/env bash
set -uo pipefail

repo=""
pr=""
poll_interval=15
settle_seconds=30
next_pr_any_branch=0

usage() {
  cat <<'EOF'
Usage: watch-pr.sh [options]

Options:
  --repo OWNER/REPO    GitHub repository (default: current repository)
  --pr NUMBER          Pull request (default: open PR for current branch)
  --next-pr-any-branch Wait for the next PR created in the repository
  --interval SECONDS   Poll interval (default: 15)
  --settle SECONDS     Delay before the final check (default: 30)
  -h, --help           Show this help
EOF
}

die() {
  echo "watch-pr: $*" >&2
  exit 2
}

require_value() {
  [ "$#" -ge 2 ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      require_value "$@"
      repo=$2
      shift 2
      ;;
    --pr)
      require_value "$@"
      pr=$2
      shift 2
      ;;
    --next-pr-any-branch)
      next_pr_any_branch=1
      shift
      ;;
    --interval)
      require_value "$@"
      poll_interval=$2
      shift 2
      ;;
    --settle)
      require_value "$@"
      settle_seconds=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

case "$poll_interval" in
  ''|*[!0-9]*) die "--interval must be a positive integer" ;;
esac
[ "$poll_interval" -gt 0 ] || die "--interval must be a positive integer"

case "$settle_seconds" in
  ''|*[!0-9]*) die "--settle must be a non-negative integer" ;;
esac

case "$pr" in
  ''|*[!0-9]*)
    [ -z "$pr" ] || die "--pr must be a positive integer"
    ;;
esac
[ -z "$pr" ] || [ "$pr" -gt 0 ] || die "--pr must be a positive integer"
[ "$next_pr_any_branch" -eq 0 ] || [ -z "$pr" ] ||
  die "--pr and --next-pr-any-branch cannot be used together"

command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required"

if [ -z "$repo" ]; then
  repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner') ||
    die "could not resolve the current GitHub repository"
fi

checkout_branch=""
waiting_for_pr=0

resolve_checkout_pr() {
  local local_head
  local_head=$(git rev-parse HEAD) || return 1

  gh pr list --repo "$repo" --state open --head "$checkout_branch" --limit 20 \
    --json number,headRefOid,createdAt \
    --jq "map(select(.headRefOid == \"$local_head\")) | sort_by(.createdAt) | last.number // empty"
}

latest_pr_number() {
  gh pr list --repo "$repo" --state all --limit 100 \
    --json number --jq 'sort_by(.number) | last.number // 0'
}

next_pr_after() {
  local baseline=$1
  gh pr list --repo "$repo" --state all --limit 100 \
    --json number \
    --jq "map(select(.number > $baseline)) | sort_by(.number) | first.number // empty"
}

if [ -z "$pr" ] && [ "$next_pr_any_branch" -eq 1 ]; then
  while ! baseline_pr=$(latest_pr_number); do
    echo "watch-pr: GitHub read failed while establishing the PR baseline; retry in $poll_interval seconds" >&2
    sleep "$poll_interval"
  done

  waiting_for_pr=1
  echo "watch-pr: waiting for the next PR created in $repo after #$baseline_pr"

  while [ -z "$pr" ]; do
    sleep "$poll_interval"
    if ! pr=$(next_pr_after "$baseline_pr"); then
      echo "watch-pr: GitHub read failed while waiting for the next PR; retry in $poll_interval seconds" >&2
      pr=""
    fi
  done
elif [ -z "$pr" ]; then
  command -v git >/dev/null 2>&1 || die "git is required to resolve the current branch"
  checkout_branch=$(git symbolic-ref --quiet --short HEAD) ||
    die "cannot wait for a branch PR from a detached HEAD; pass --pr or --next-pr-any-branch"

  while [ -z "$pr" ]; do
    if ! pr=$(resolve_checkout_pr); then
      echo "watch-pr: GitHub read failed while resolving a PR for $checkout_branch; retry in $poll_interval seconds" >&2
      pr=""
      sleep "$poll_interval"
      continue
    fi

    if [ -z "$pr" ]; then
      if [ "$waiting_for_pr" -eq 0 ]; then
        echo "watch-pr: no open PR at local HEAD for $checkout_branch"
        echo "watch-pr: waiting for a PR for this local branch"
        waiting_for_pr=1
      fi
      sleep "$poll_interval"
    fi
  done
fi

snapshot() {
  gh pr view "$pr" --repo "$repo" \
    --json headRefOid,state,mergeable,reviewDecision,comments,reviews,changedFiles,files,labels,updatedAt \
    --jq '[
      (.headRefOid // "NONE"),
      (.state // "UNKNOWN"),
      (.mergeable // "UNKNOWN"),
      (.reviewDecision // "NONE"),
      ((.comments | length) | tostring),
      ([.comments[] | {
        id: (.id | tostring),
        createdAt: (.createdAt // ""),
        updatedAt: (.updatedAt // "")
      }] | sort_by(.id) | tojson),
      ((.reviews | length) | tostring),
      ([.reviews[] | {
        id: (.id | tostring),
        state: (.state // ""),
        submittedAt: (.submittedAt // ""),
        author: (.author.login // "")
      }] | sort_by(.id) | tojson),
      ((.changedFiles // (.files | length)) | tostring),
      ([.files[] | {
        path: (.path // ""),
        additions: (.additions // 0),
        deletions: (.deletions // 0)
      }] | sort_by(.path) | tojson),
      ([.files[].path] | sort | .[0:20] | tojson),
      ([.labels[].name] | sort | tojson),
      (.updatedAt // "UNKNOWN")
    ] | @tsv'
}

emit_summary() {
  local before=$1 detected=$2 confirmed=$3 event_kind=${4:-change}
  local b_head b_state b_merge b_decision b_comment_count b_comments
  local b_review_count b_reviews b_file_count b_files b_labels b_updated
  local d_head d_state d_merge d_decision d_comments
  local d_reviews d_files d_labels d_updated
  local f_head f_state f_merge f_decision f_comment_count f_comments
  local f_review_count f_reviews f_file_count f_files f_paths f_labels f_updated
  local areas=0 comment_kind review_kind requested_note _

  IFS=$'\t' read -r b_head b_state b_merge b_decision b_comment_count b_comments \
    b_review_count b_reviews b_file_count b_files _ b_labels b_updated <<<"$before"
  IFS=$'\t' read -r d_head d_state d_merge d_decision _ d_comments \
    _ d_reviews _ d_files _ d_labels d_updated <<<"$detected"
  IFS=$'\t' read -r f_head f_state f_merge f_decision f_comment_count f_comments \
    f_review_count f_reviews f_file_count f_files f_paths f_labels f_updated <<<"$confirmed"

  echo "change detected"
  echo "where changed:"

  if [ "$event_kind" = "attached" ]; then
    echo "- pull request: created/attached ($repo#$pr)"
    areas=$((areas + 1))
  fi

  if [ "$b_comments" != "$d_comments" ] || [ "$d_comments" != "$f_comments" ]; then
    comment_kind="comment activity"
    if [ "$f_comment_count" -gt "$b_comment_count" ]; then
      comment_kind="new comment(s)"
    fi
    echo "- conversation comments: $comment_kind ($b_comment_count -> $f_comment_count total)"
    areas=$((areas + 1))
  fi

  if [ "$b_reviews" != "$d_reviews" ] || [ "$d_reviews" != "$f_reviews" ]; then
    review_kind="code-review activity"
    if [ "$f_review_count" -gt "$b_review_count" ]; then
      review_kind="new code review(s)"
    fi
    requested_note=""
    case "$d_reviews$f_reviews" in
      *CHANGES_REQUESTED*) requested_note="; CHANGES_REQUESTED observed" ;;
    esac
    echo "- submitted code reviews: $review_kind ($b_review_count -> $f_review_count total; confirmed decision: $f_decision$requested_note)"
    areas=$((areas + 1))
  elif [ "$b_decision" != "$d_decision" ] || [ "$d_decision" != "$f_decision" ]; then
    echo "- review decision / requested-changes status: activity (confirmed: $f_decision)"
    areas=$((areas + 1))
  fi

  if [ "$b_head" != "$d_head" ] || [ "$d_head" != "$f_head" ] || \
     [ "$b_files" != "$d_files" ] || [ "$d_files" != "$f_files" ]; then
    echo "- commits/diff: activity; confirmed file paths ($b_file_count -> $f_file_count total, up to 20 shown): $f_paths"
    areas=$((areas + 1))
  fi

  if [ "$b_labels" != "$d_labels" ] || [ "$d_labels" != "$f_labels" ]; then
    echo "- labels/tags: activity"
    areas=$((areas + 1))
  fi

  if [ "$b_state" != "$d_state" ] || [ "$d_state" != "$f_state" ] || \
     [ "$b_merge" != "$d_merge" ] || [ "$d_merge" != "$f_merge" ]; then
    echo "- PR state/mergeability: activity (confirmed: $f_state / $f_merge)"
    areas=$((areas + 1))
  fi

  if [ "$areas" -eq 0 ] && { [ "$b_updated" != "$d_updated" ] || [ "$d_updated" != "$f_updated" ]; }; then
    echo "- other PR metadata: activity"
  fi
}

if [ "$waiting_for_pr" -eq 1 ]; then
  while ! detected=$(snapshot); do
    echo "watch-pr: attached to $repo#$pr but its initial read failed; retry in $poll_interval seconds" >&2
    sleep "$poll_interval"
  done

  echo "watch-pr: attached to $repo#$pr"
  sleep "$settle_seconds"

  confirmation_failed=0
  if ! confirmed=$(snapshot); then
    confirmed=$detected
    confirmation_failed=1
  fi

  empty_snapshot=$'NONE\tNONE\tNONE\tNONE\t0\t[]\t0\t[]\t0\t[]\t[]\t[]\tNONE'
  emit_summary "$empty_snapshot" "$detected" "$confirmed" attached
  if [ "$confirmation_failed" -eq 1 ]; then
    echo "- confirmation: final GitHub read failed; summary uses the first attached snapshot"
  fi
  exit 0
fi

while ! previous=$(snapshot); do
  echo "watch-pr: initial GitHub read failed; retry in $poll_interval seconds" >&2
  sleep "$poll_interval"
done

echo "watch-pr: watching $repo#$pr"

while true; do
  sleep "$poll_interval"
  if ! current=$(snapshot); then
    echo "watch-pr: GitHub read failed; retry in $poll_interval seconds" >&2
    continue
  fi

  if [ "$current" != "$previous" ]; then
    detected=$current
    sleep "$settle_seconds"

    confirmation_failed=0
    if ! confirmed=$(snapshot); then
      confirmed=$detected
      confirmation_failed=1
    fi

    emit_summary "$previous" "$detected" "$confirmed"
    if [ "$confirmation_failed" -eq 1 ]; then
      echo "- confirmation: final GitHub read failed; summary uses the first detected snapshot"
    fi
    exit 0
  fi
done
