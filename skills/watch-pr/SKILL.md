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
   script resolve the open PR for the current branch. If none exists, the script
   waits for a PR whose remote head matches the branch and current local HEAD.
3. Pass `--next-pr-any-branch` only when the user explicitly asks for the next
   PR created anywhere in the repository. This selects a PR but never checks out
   its branch; the local-head safety check still applies.
4. Resolve `scripts/watch-pr.sh` relative to this `SKILL.md` and launch it once.
   Pass `--repo OWNER/REPO` and `--pr NUMBER` when they are known.

## Wait without token churn

The watcher's shell-level GitHub polling is cheap. Repeatedly returning an
unchanged process status to the model is not. Launch exactly one watcher and
keep idle waiting below the model layer:

- In Claude Code, prefer a background shell task that sends a completion
  notification. Start it once and do not poll its output while it is running.
- In Codex, prefer a host execution primitive that owns the long-running
  command and wakes the agent only when it exits. If it yields a process handle,
  reuse that handle with the host's blocking wait or longest supported wait.
  When the tool layer can wait repeatedly inside one tool invocation, keep the
  handle waits there so intermediate timeouts never return to the model.
- Never build a model-driven loop around `ps`, `jobs`, `kill -0`, output-file
  checks, fresh shell calls, or short process-handle polls. Do not narrate an
  unchanged status or reason about it between waits.
- Do not blindly detach with `&` or `nohup`: without a host completion event,
  the agent cannot resume automatically. If the host offers neither completion
  notification nor a blocking process wait, report that limitation instead of
  spending model turns simulating a watcher.

An unchanged PR is expected and is not a blocker. Waiting itself requires no
reasoning; resume work only when the process produces output or exits.

The script detects the first change, waits 30 seconds, performs one final
GitHub check, and prints `change detected` with a metadata-only location
summary. Do not expose comment bodies, review bodies, or diff contents merely
because the watcher woke up.

If the script starts before a matching PR exists, PR creation is the first
change: it attaches to that PR, performs the 30-second final check, and exits so
the active task can handle the initial PR. Reuse the discovered `--pr NUMBER`
on every later watch to remain imprinted on the same PR.

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
