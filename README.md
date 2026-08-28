# agent-pr-watch

`agent-pr-watch` lets Claude Code or Codex wait for a GitHub pull request to
change and then continue the current task in the same literal local checkout.

It is deliberately session-owned: there is no daemon, scheduler, tmux session,
spawned review agent, throwaway worktree, or background configuration file.

## Requirements

- Bash
- An authenticated [GitHub CLI](https://cli.github.com/) (`gh`)
- A local checkout whose current branch has a pull request, unless `--repo` and
  `--pr` are supplied explicitly

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
- Codex: `$watch-pr Watch PR 42 and then continue the review.`
- Natural language: `Watch the current PR and resume this task when it changes.`

The skill runs the watcher in the foreground. When a change is first noticed,
it waits 30 seconds, checks GitHub one more time, and returns `change detected`
with a short metadata-only summary of where activity occurred:

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

## Run the script directly

```bash
skills/watch-pr/scripts/watch-pr.sh --repo OWNER/REPO --pr 42
```

Options:

```text
--repo OWNER/REPO    GitHub repository; defaults to the current repository
--pr NUMBER          Pull request; defaults to the PR for the current branch
--interval SECONDS   Poll interval; defaults to 15
--settle SECONDS     Final-check delay; defaults to 30
```

The legacy `config.json` filename remains ignored so an existing private config
cannot accidentally be committed, but it is no longer read or needed.
