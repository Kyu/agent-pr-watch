#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
watcher="$project_root/skills/watch-pr/scripts/watch-pr.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-pr-watch-pre-pr-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/bin"

cat >"$test_dir/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  symbolic-ref)
    printf '%s\n' 'feature/new-pr'
    ;;
  rev-parse)
    printf '%s\n' 'local-head'
    ;;
  *)
    echo "unexpected git command: $*" >&2
    exit 1
    ;;
esac
EOF

cat >"$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

counter_file="$WATCH_TEST_DIR/${WATCH_TEST_MODE}-count"
count=0
if [ -f "$counter_file" ]; then
  count=$(<"$counter_file")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$counter_file"

snapshot() {
  local IFS=$'\t'
  printf '%s\n' "$*"
}

snapshot_row() {
  snapshot "remote-head" OPEN MERGEABLE NONE 0 '[]' 0 '[]' 2 \
    '[{"path":"app/a.rb","additions":3,"deletions":1},{"path":"spec/a_spec.rb","additions":4,"deletions":0}]' \
    '["app/a.rb","spec/a_spec.rb"]' '["ready"]' 2026-08-28T10:00:00Z
}

case "$WATCH_TEST_MODE:$1:$2:$count" in
  branch:pr:list:1)
    ;;
  branch:pr:list:2)
    printf '%s\n' 42
    ;;
  branch:pr:view:3|branch:pr:view:4)
    snapshot_row
    ;;
  any:pr:list:1)
    printf '%s\n' 10
    ;;
  any:pr:list:2)
    ;;
  any:pr:list:3)
    printf '%s\n' 11
    ;;
  any:pr:view:4|any:pr:view:5)
    snapshot_row
    ;;
  *)
    echo "unexpected gh call ($WATCH_TEST_MODE #$count): $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$test_dir/bin/git" "$test_dir/bin/gh"

branch_output=$(PATH="$test_dir/bin:$PATH" WATCH_TEST_DIR="$test_dir" \
  WATCH_TEST_MODE=branch "$watcher" --repo Kyu/jobsworth \
  --interval 1 --settle 1)

for expected in \
  'no open PR at local HEAD for feature/new-pr' \
  'waiting for a PR for this local branch' \
  'attached to Kyu/jobsworth#42' \
  'change detected' \
  'pull request: created/attached (Kyu/jobsworth#42)' \
  'commits/diff: activity'; do
  grep -Fq -- "$expected" <<<"$branch_output"
done

any_output=$(PATH="$test_dir/bin:$PATH" WATCH_TEST_DIR="$test_dir" \
  WATCH_TEST_MODE=any "$watcher" --repo Kyu/jobsworth \
  --next-pr-any-branch --interval 1 --settle 1)

for expected in \
  'waiting for the next PR created in Kyu/jobsworth after #10' \
  'attached to Kyu/jobsworth#11' \
  'change detected' \
  'pull request: created/attached (Kyu/jobsworth#11)'; do
  grep -Fq -- "$expected" <<<"$any_output"
done

if PATH="$test_dir/bin:$PATH" "$watcher" --repo Kyu/jobsworth --pr 1 \
  --next-pr-any-branch >/dev/null 2>&1; then
  echo "--pr and --next-pr-any-branch unexpectedly succeeded" >&2
  exit 1
fi

echo "watch-pr pre-PR integration tests passed"
