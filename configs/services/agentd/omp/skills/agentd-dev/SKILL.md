---
name: agentd-dev
description: Use when changing agentd (github.com/lassulus/agentd), the service that runs you, or when asked to deploy, test or roll back an agentd build on this machine.
---

# Working on agentd itself

You run inside agentd. Its source is github.com/lassulus/agentd; work on it
like any repo (git-worktrees skill: clone in `~/src/agentd`, your worktree in
`~/worktrees/agentd-<topic>`).

## Test before you deploy

```sh
cd ~/worktrees/agentd-<topic>
nix develop -c go vet ./...
nix develop -c go test ./...
nix flake check
```

Do not deploy a build whose tests fail.

## Deploy your build

```sh
nix build --out-link ~/dev/agentd ~/worktrees/agentd-<topic>
```

As soon as the link changes, systemd restarts agentd on that build. The
restart kills every running agent, **including you**, in the middle of your
turn. So before you run it:

1. Commit your work.
2. Say in your reply what you are deploying (worktree, commit) and that the
   session ends here; this command is your last action of the turn.

Every agent's history stays; the next message to an agent resumes its
session on the new build.

## Roll back

```sh
rm ~/dev/agentd
```

agentd restarts on the version pinned in the machine config.

## Rules

- Deploy only when the user asked you to.
- Leave `~/dev` alone except for the `agentd` link.
