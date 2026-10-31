---
name: git-worktrees
description: Use before reading or changing code in any git repository. Where repos live (~/src) and how every agent gets its own worktree so parallel agents never conflict.
---

# Repos and worktrees

Several agents work on this machine at the same time, each in its own
session. They must never touch each other's files, so nobody edits a shared
clone.

## 1. The main clone: `~/src/<repo>`

`<repo>` is the last part of the URL without `.git`
(`https://github.com/lassulus/agentd` -> `~/src/agentd`).

- Missing: `git clone <url> ~/src/<repo>`
- Present: `git -C ~/src/<repo> fetch --all --prune`

Never edit files, switch branches or commit in `~/src/<repo>`. It is only
the base for worktrees. Reading it to answer a question is fine.

## 2. Your own worktree: `~/worktrees/<repo>-<topic>`

`<topic>` is a short kebab-case name for your task (`fix-ci`,
`add-sse`). Branch off the remote default branch:

```sh
base=$(git -C ~/src/<repo> symbolic-ref --short refs/remotes/origin/HEAD)  # e.g. origin/main
mkdir -p ~/worktrees
git -C ~/src/<repo> worktree add -b <topic> ~/worktrees/<repo>-<topic> "$base"
```

If the directory or the branch already exists, another agent is probably
using it: pick a different topic. Never reuse or delete someone else's
worktree. If the user tells you to continue in an existing worktree, use
that one.

## 3. Work only inside your worktree

- Run every shell command from the worktree (`cd ~/worktrees/<repo>-<topic> && …`).
- Edit files by absolute paths under the worktree.
- Commit there; the git identity is already set.

## 4. When you are done

End with the worktree path, the branch, and `git log --oneline` of your
commits. Leave the worktree in place (the user reviews it there) and do not
push unless you are asked to.
