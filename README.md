# claude-pr-watch

A local watcher that drives a self-running, dual-Claude-Code-session PR review loop across multiple GitHub repos. Each fire spawns into a shared `tmux` session as a real, attachable, interactive Claude Code session.

## What it does

You push commits to a PR. Within ~90s, a **reviewer** Claude Code session spawns in a throwaway git worktree, runs your project's verification chain, posts inline review comments, and posts a top-level "review note" summarizing intent. When the reviewer posts marker-tagged comments, an **author-responder** session spawns in a separate worktree on a throwaway local branch, fixes what it agrees with (or pushes back with substance on what it doesn't), pushes commits back to the PR branch, and posts replies. The reviewer re-fires when the responder pushes or replies. The loop terminates when the reviewer has nothing new to say.

Both roles are interactive Claude Code sessions — you can `tmux attach` to either window at any time and chat directly with the model.

## Architecture

```
┌─── this repo ─────────────────┐   ┌─── tmux: claude-code-review ─────┐
│  claude-pr-watch (poll loop)  │   │  watcher    (window 0)           │
│   ├─ reads config.json        │   │  <slug>-reviewer-pr<N>           │
│   ├─ polls gh every 90s       ├──►│  <slug>-responder-pr<N>          │
│   ├─ writes state.json        │   │  <slug2>-reviewer-pr<M>          │
│   └─ spawns run-fire.sh       │   │  ...                             │
└───────────────────────────────┘   └──────────────────────────────────┘
                                              │
                                              ▼  per fire
                                    ┌─── run-fire.sh ─────────────────┐
                                    │  cd <throwaway worktree>        │
                                    │  pre-trust workspace            │
                                    │  trap cleanup EXIT              │
                                    │  claude --dangerously-skip-...  │
                                    │       "$(cat <role prompt>)"    │
                                    └──────────────────────────────────┘
                                              │
                                              ▼  via gh + git
                                    ┌─── GitHub ──────────────────────┐
                                    │  PR threads · pushes · labels   │
                                    └──────────────────────────────────┘
```

One window per `(repo, role, PR)` at any time. Auto-kill replaces accumulation.

## Prerequisites

On the machine running the watcher:

- `bash` (4+), `jq`, `tmux`, `git`, `uuidgen` on PATH (`brew install jq tmux` on macOS — others are typically present)
- [`gh`](https://cli.github.com) authenticated (`gh auth login`)
- [`claude`](https://code.claude.com) (Claude Code CLI) on PATH and signed in

On each watched repo:

- A `.claude/prompts/reviewer.md` file — the reviewer role prompt
- A `.claude/prompts/responder.md` file — the author-responder role prompt
- Optionally, a `.claude/settings.json` with tool allowlists / denylists

The prompts can reference these env vars (set by `run-fire.sh`): `$PR_NUMBER`, `$PR_HEAD_SHA`, `$GH_REPO`, `$COMMENT_ID`.

## Setup (from a fresh clone)

```bash
# 1. Clone
git clone git@github.com:Kyu/claude-pr-watch.git
cd claude-pr-watch

# 2. Make scripts executable
chmod +x claude-pr-watch run-fire.sh

# 3. (Optional but recommended) Put the watcher on your PATH
mkdir -p ~/.local/bin
ln -sf "$(pwd)/claude-pr-watch" ~/.local/bin/claude-pr-watch

# 4. Create your local config
cp config.example.json config.json
$EDITOR config.json   # add your repos

# 5. (For each watched repo) Add .claude/prompts/{reviewer,responder}.md
#    and commit them. The watcher's worktrees inherit .claude/ from the
#    repo at the PR head SHA; if .claude/ isn't tracked at that SHA,
#    run-fire.sh copies it from the main checkout as a fallback.

# 6. Seed state so existing open PRs don't fire on startup
claude-pr-watch --seed-only

# 7. Start the loop (recommended: inside the tmux session it will use)
tmux new-session -A -s claude-code-review
claude-pr-watch
# Ctrl+B d to detach. tmux server keeps it running across terminal close.
```

## Daily use

```bash
# Run the poll loop
claude-pr-watch

# One scan, then exit (debug)
claude-pr-watch --once

# Seed state from current GitHub state (fires nothing)
claude-pr-watch --seed-only

# Print state.json
claude-pr-watch status

# Use a non-default config
claude-pr-watch --config /path/to/other.json

# Watch all fires live
tmux attach -t claude-code-review
```

The watcher resolves its own location via symlink (`readlink`-walk on `$BASH_SOURCE`), so the `~/.local/bin` symlink works. Config search order: `$CONFIG_FILE` env > `--config` arg > `$XDG_CONFIG_HOME/claude-pr-watch/config.json` > `<script-dir>/config.json`.

## What gets watched

For each repo in `config.json`, every `interval_seconds` (default 90):

1. List open PRs via `gh pr list`, filtered by `author_filter` (default `@me`), `label_filter` (optional opt-in), and drafts toggle.
2. PRs with the `needs-human` label are always skipped.
3. For each remaining PR, compare current `headRefOid` and `gh api .../pulls/<N>/comments` against `state.json`. Decide:
   - **head SHA changed** → fire **reviewer**
   - **new `<!-- claude-reviewer -->` comment** → fire **responder**
   - **new `<!-- claude-responder -->` comment** → fire **reviewer**
   - both deltas in one tick → reviewer wins (it reads everything anyway)

State updates happen **immediately after spawn** (non-blocking). When a new fire is needed for a `(repo, role, PR)` that already has a tmux window, the watcher decides between killing the prior window (most cases) or skipping this tick (when the user has manually engaged with the prior session — see below).

## Spawn lifecycle (per fire)

1. **Prior-window engagement check.** If a tmux window named `<slug>-<role>-pr<N>` exists, count "real" user messages in the prior fire's claude session jsonl (excludes tool_result echoes that the API encodes as `role:user`). If the count is `> 1` — meaning you've typed beyond the initial prompt — preserve the prior window and skip this tick; you Ctrl+C / `/exit` when ready. Otherwise: kill the prior window (its `EXIT` trap fires on SIGHUP and cleans up worktree + temp branch).
2. **Force-clean stale worktrees.** After the kill, wait briefly for the trap to remove `/tmp/<slug>-<role>-pr<N>-*`. If anything lingers, force-remove it. Then `git worktree prune`.
3. **Worktree creation.** Reviewer: detached at the PR head SHA. Responder: a throwaway local branch `claude-responder/pr<N>-<ts>` starting at `origin/<head_branch>`, configured so `git push` follows upstream back to `origin/<head_branch>` (your main checkout's branch pointer is never touched).
4. **Spawn.** `tmux new-window` runs `run-fire.sh`, which pre-trusts the worktree path in `~/.claude.json` (skips Claude Code's first-run trust prompt) and launches `claude --dangerously-skip-permissions "$(cat .claude/prompts/<role>.md)"`.
5. **Pane logging.** `tmux pipe-pane` mirrors output to `~/.local/state/claude-pr-watch/log/<slug>-<role>-pr<N>-<ts>.log`.
6. **Cleanup.** When claude exits (or window is killed externally), bash's `EXIT` trap removes the worktree and deletes the throwaway `claude-responder/*` branch if one was created.

### Engagement detection

A "real" user message is an entry in `~/.claude/projects/<encoded-worktree-path>/<session>.jsonl` where `type == "user"` and `message.content` is either a string OR an array whose first block has `type == "text"`. Tool results (`type == "tool_result"` as the first block) are excluded.

So: the initial prompt is user-message #1; any human follow-up you type in the attached tmux window is #2+. The watcher uses `count > 1` to decide "user is engaged — leave this window alone."

## Marker convention

- Every **reviewer** comment ends with `<!-- claude-reviewer -->`
- Every **responder** comment/reply ends with `<!-- claude-responder -->`
- Neither side may emit the other's marker (would be a self-loop).
- Human comments (no marker) don't fire anything; the responder ignores marker-less comments inside threads ("the humans took over").

## Config reference

```json
{
  "defaults": {
    "interval_seconds": 90,
    "include_drafts": false,
    "author_filter": "@me",
    "escalation_turns": 3
  },
  "repos": [
    {
      "name": "owner/repo",
      "dir": "~/Projects/repo",
      "author_filter": "",
      "label_filter": "claude-review",
      "include_drafts": false,
      "escalation_turns": 4
    }
  ]
}
```

| Key | Default | Effect |
|---|---|---|
| `interval_seconds` | `90` | Scan tick interval |
| `include_drafts` | `false` | Watch draft PRs (they're typically "not ready for review") |
| `author_filter` | `"@me"` | `gh pr list --author` filter; `""` for any |
| `label_filter` | `""` | If set, only PRs with this label are watched (per-PR opt-in) |
| `escalation_turns` | `3` | Read by the reviewer prompt; the watcher itself just respects the `needs-human` label the reviewer applies |

Per-repo keys override `defaults`. `~` is expanded in `dir`.

## File layout

```
<this repo>/
├── claude-pr-watch              # main script (poll loop, state, spawning)
├── run-fire.sh                  # per-window helper (worktree cleanup + claude)
├── config.example.json          # checked-in template
├── config.json                  # YOUR config (gitignored)
├── .gitignore
└── README.md

~/.local/state/claude-pr-watch/
├── state.json                   # { "owner/repo": { "42": {head_sha, last_comment_id, last_seen} } }
└── log/
    └── <slug>-<role>-pr<N>-<ts>.log
```

## Termination

- **Convergence** — reviewer fire posts no new marker comments → no responder fire → no replies → loop dormant. Watcher keeps polling but nothing fires until you push.
- **Escalation** — any thread hits `escalation_turns` round-trips → reviewer adds `needs-human` label → watcher skips that PR entirely until the label is removed.
- **PR closed/merged** — next scan drops the entry from state automatically.

## Security and trust

`run-fire.sh` does two things that bypass safety prompts inside the spawned `claude` session:

- **Pre-trusts the worktree.** Writes `.projects[<path>].hasTrustDialogAccepted = true` to `~/.claude.json` so Claude Code's first-run "trust this folder?" prompt doesn't gate the fire. Each worktree is throwaway under `/tmp/`, so the trust scope is narrow.
- **Passes `--dangerously-skip-permissions`** to `claude` so per-tool permission prompts (Bash, Edit, Write, etc.) don't block headless runs. The project's `.claude/settings.json` **deny rules still apply** — this flag bypasses only the prompt, not the denylist. Use a deny list to forbid the things you actually don't want (force-push, `cargo run`, `rm -rf`, etc.).

The model is operating in an ephemeral throwaway worktree under your user account. Treat the per-project `.claude/settings.json` allow/deny as the actual security boundary.

## Troubleshooting

- **Fire window never closes on its own.** By design — interactive `claude` sits idle after the work completes. You can attach and chat further. Close with `/exit` or `tmux kill-window`. The cleanup trap removes the worktree either way.
- **`worktree add` failed.** The watcher logs the actual `git` error message. Common cause: a previous worktree got orphaned. The watcher already calls `git worktree prune` before each add; if you still see issues, `git worktree list` in the project to inspect.
- **Reviewer keeps firing on the same head SHA.** `state.json` may be stale. `claude-pr-watch status` to inspect, edit the file directly, restart.
- **Permission prompts still appear inside the claude session.** `--dangerously-skip-permissions` should suppress them, but project-level `.claude/settings.json` deny rules will still fire as prompts. Either remove the offending deny rule or accept the prompt as a safety guardrail.
- **You restarted the watcher and lost in-flight fire state.** That's fine — `state.json` survives restart. Fires don't pick up where they left off, but the next scan re-evaluates deltas and spawns whatever's needed.

## Caveats

- Pure polling; latency = interval. Real-time via webhook is a future upgrade.
- One process per host. No coordination between machines.
- `gh` rate limit (5000 req/hr authenticated) caps active repos × poll frequency. At 90s × ~10 req/scan, ~12 active repos comfortably.
- Cold cargo (or equivalent) build runs per worktree — no shared `CARGO_TARGET_DIR` (concurrent fires would corrupt it). The first fire on a new project pays the full build cost.
- The responder works from `origin/<head_branch>` and pushes back to it. If your local checkout has unpushed commits ahead of origin, you'll need to rebase after the responder pushes.

## License

(Choose your own. Suggest MIT for a tool like this.)
