#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
watcher="$project_root/skills/watch-pr/scripts/watch-pr.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-pr-watch-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/bin"

cat >"$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count=0
if [ -f "$WATCH_TEST_COUNTER" ]; then
  count=$(cat "$WATCH_TEST_COUNTER")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$WATCH_TEST_COUNTER"

row() {
  local IFS=$'\t'
  printf '%s\n' "$*"
}

case "$count" in
  1)
    row aaa OPEN MERGEABLE NONE 0 '[]' 0 '[]' 1 \
      '[{"path":"old.rb","additions":1,"deletions":0}]' \
      '["old.rb"]' '[]' 2026-08-28T10:00:00Z
    ;;
  2)
    row bbb OPEN MERGEABLE CHANGES_REQUESTED 1 \
      '[{"id":"c1","createdAt":"2026-08-28T10:00:01Z","updatedAt":"2026-08-28T10:00:01Z"}]' \
      1 '[{"id":"r1","state":"CHANGES_REQUESTED","submittedAt":"2026-08-28T10:00:02Z","author":"reviewer"}]' \
      2 '[{"path":"app/a.rb","additions":3,"deletions":1},{"path":"spec/a_spec.rb","additions":4,"deletions":0}]' \
      '["app/a.rb","spec/a_spec.rb"]' '["needs-review"]' 2026-08-28T10:00:02Z
    ;;
  *)
    row ccc OPEN CONFLICTING CHANGES_REQUESTED 2 \
      '[{"id":"c1","createdAt":"2026-08-28T10:00:01Z","updatedAt":"2026-08-28T10:00:01Z"},{"id":"c2","createdAt":"2026-08-28T10:00:03Z","updatedAt":"2026-08-28T10:00:03Z"}]' \
      1 '[{"id":"r1","state":"CHANGES_REQUESTED","submittedAt":"2026-08-28T10:00:02Z","author":"reviewer"}]' \
      2 '[{"path":"app/a.rb","additions":5,"deletions":1},{"path":"spec/a_spec.rb","additions":4,"deletions":0}]' \
      '["app/a.rb","spec/a_spec.rb"]' '["needs-review","reviewed"]' 2026-08-28T10:00:03Z
    ;;
esac
EOF

chmod +x "$test_dir/bin/gh"

start=$(date +%s)
output=$(PATH="$test_dir/bin:$PATH" WATCH_TEST_COUNTER="$test_dir/count" \
  "$watcher" --repo Kyu/jobsworth --pr 1 --interval 1 --settle 1)
elapsed=$(($(date +%s) - start))

[ "$(cat "$test_dir/count")" -eq 3 ]
[ "$elapsed" -ge 2 ]

for expected in \
  'change detected' \
  'conversation comments: new comment(s)' \
  'submitted code reviews: new code review(s)' \
  'CHANGES_REQUESTED observed' \
  'commits/diff: activity' \
  '["app/a.rb","spec/a_spec.rb"]' \
  'labels/tags: activity' \
  'PR state/mergeability: activity'; do
  grep -Fq -- "$expected" <<<"$output"
done

echo "watch-pr integration test passed"
