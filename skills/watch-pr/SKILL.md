---
name: watch-pr
description: Wait for a GitHub pull request to change, then resume the current coding or review task in the same local checkout. Use when the user asks to watch, wait for, or listen for PR updates. Do not use for host-wide background monitoring.
---

# Watch a pull request

Wait inside the active Claude Code or Codex session. Preserve the current task,
role, permissions, and literal local checkout.

## Start watching

1. Stay in the current working directory and worktree. Do not create a worktree,
   clone, switch branches, pull, reset, or stash.
2. Use a repository and PR number stated by the user. Otherwise let the bundled
   script resolve the repository and pull request from the current checkout.
3. Resolve `scripts/watch-pr.sh` relative to this `SKILL.md` and run it in the
   foreground. Pass `--repo OWNER/REPO` and `--pr NUMBER` when they are known.
4. Wait until the script exits. If the execution layer yields a process/session
   handle, keep polling that same handle. An unchanged PR is expected and is not
   a blocker.

The script detects the first change, waits 30 seconds, performs one final
GitHub check, and prints `change detected` with a metadata-only location
summary. Do not expose comment bodies, review bodies, or diff contents merely
because the watcher woke up.

## Resume safely

After the watcher exits:

1. Re-read the PR metadata needed for the existing task.
2. Compare `git rev-parse HEAD` in the current checkout with the PR's
   `headRefOid`.
3. If they differ, report the mismatch. Do not silently update or replace the
   user's local branch.
4. Resume the task that was active before watching, within its original scope
   and permissions.

A review task remains read-only unless the user separately authorized writes.
A coding task may edit only when its existing instructions authorize editing.
Watching never grants permission to comment, approve, request changes, push, or
merge. If the user asked for continuous watching, handle the event and then run
the watcher again.
