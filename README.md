# agent-pr-watch

`agent-pr-watch` lets Claude Code or Codex wait for a GitHub pull request to
change and then continue the current task in the same literal local checkout.

It is deliberately session-owned: there is no daemon, scheduler, tmux session,
spawned review agent, throwaway worktree, or background configuration file.

## Requirements

- Bash
- An authenticated [GitHub CLI](https://cli.github.com/) (`gh`)
- A local checkout. The watcher can start before the current branch has a pull
  request and attach when one appears.

## Install

### Claude Code

From a shell:

```bash
claude plugin marketplace add Kyu/agent-pr-watch
claude plugin install agent-pr-watch@agent-pr-watch
```

Or run the equivalent commands inside Claude Code:

```text
/plugin marketplace add Kyu/agent-pr-watch
/plugin install agent-pr-watch@agent-pr-watch
/reload-plugins
```

### Codex

```bash
codex plugin marketplace add Kyu/agent-pr-watch
codex plugin add agent-pr-watch@agent-pr-watch
```

Start a new Codex session after installation so it loads the bundled skill.

### Update or remove

```bash
# Claude Code
claude plugin marketplace update agent-pr-watch
claude plugin update agent-pr-watch@agent-pr-watch
claude plugin uninstall agent-pr-watch@agent-pr-watch

# Codex
codex plugin marketplace upgrade agent-pr-watch
codex plugin add agent-pr-watch@agent-pr-watch
codex plugin remove agent-pr-watch
```

## Use from an agent

After installing the plugin, start the agent in the local checkout that should
remain authoritative:

- Claude Code: `/agent-pr-watch:watch-pr Watch PR 42 and then continue the review.`
- Codex: `$agent-pr-watch:watch-pr Watch PR 42 and then continue the review.`
- Natural language: `Watch the current PR and resume this task when it changes.`
- Before a current-branch PR exists: `Watch this branch; review its PR as soon as it is opened.`
- Any branch: `Watch the next PR created anywhere in this repository, then review it.`

The skill launches one watcher process. Claude Code uses a background-task
completion notification. Codex runs one foreground shell call with a 24-hour
timeout, or the longest timeout its host supports, and does not poll it from the
model. The live call completes and wakes Codex when the watcher exits. When a
change is first noticed, the watcher waits 30 seconds, checks GitHub one more
time, and returns `change detected` with a short metadata-only summary of where
activity occurred:

- conversation comments
- submitted code reviews and requested-changes status
- commits/diff and confirmed changed-file paths
- labels/tags
- PR state and mergeability

It never includes comment bodies, review bodies, or diff contents in that
summary.

The watcher does not switch, pull, reset, or create a worktree. After it wakes,
the skill compares the checked-out `HEAD` with the PR head and reports any
mismatch rather than silently changing the checkout.

When the current branch has no PR yet, the watcher waits for an open PR whose
head matches that branch and the current local `HEAD`. PR creation wakes the
agent for the initial task. `--next-pr-any-branch` instead selects the first PR
created anywhere in the repository after watching starts; it never switches the
local checkout, so the same local-head safety check still applies.

## Run the script directly

```bash
skills/watch-pr/scripts/watch-pr.sh --repo OWNER/REPO --pr 42
```

Options:

```text
--repo OWNER/REPO    GitHub repository; defaults to the current repository
--pr NUMBER          Pull request; defaults to an open PR for the current branch
--next-pr-any-branch Wait for the next PR created anywhere in the repository
--interval SECONDS   Poll interval; defaults to 15
--settle SECONDS     Final-check delay; defaults to 30
```

The legacy `config.json` filename remains ignored so an existing private config
cannot accidentally be committed, but it is no longer read or needed.
