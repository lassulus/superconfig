# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is lassulus's personal NixOS/nix-darwin configuration repository, built on clan-core for managing multiple machines. It includes:
- Multiple machine configurations in `machines/`
- Configuration modules in `configs/` and `modules/`
- Custom packages in `pkgs/`
- packages which could in theory be upstreamed to nixkgs should go into the pkgs folder, in the tools folder we add tools we write ourself which are more complex or not upstreamable

## Key Architecture Components

### Machine Management
- **Clan-core**: Primary framework for managing multiple machines
- **Secrets**: Uses password-store for secrets management via clan.core.vars

### Network Overlays
The repository manages multiple overlay networks:
- **Tor**: Anonymous network access

### Module System
- `configs/`: Main configuration modules
- `configs/default.nix`: imported by all machines
- `modules/`: Custom NixOS module definitions
- Stockholm modules are also imported for krebs infrastructure

## Common Development Commands

```bash
# Enter development shell
nix develop

# Deploy a NixOS machine (tools/deploy): one Secure Enclave unlock for all
# secrets, builds on the target, shows source/closure diff, asks before
# switching. `s` runs apps from ~/src/superconfig, so pass --flake to deploy
# a different checkout/worktree. NEVER use `clan machines update`: it
# decrypts each secret separately and fails on the Secure Enclave prompt.
s deploy --flake . <MACHINE_NAME>

# Agents: deploy only when the user asked for it, and then always with
# --yes. Without it the run stops at the [y/N] switch prompt (and the source
# diff can wait in a pager) and looks hung. --yes skips both; the diffs are
# still printed, so read them in the output afterwards.
s deploy --flake . --yes <MACHINE_NAME>

# Format code
nix fmt

# Build NixOS configuration
nix build .#nixosConfigurations.<machine-name>.config.system.build.toplevel

# Build Darwin configuration
nix build .#darwinConfigurations.barnacle.system

# Deploy/rebuild Darwin configuration (for barnacle)
sudo darwin-rebuild switch --flake .#barnacle

# Access machines via SSH (as root, see below)
ssh root@<machine-name>.r  # via retiolum
torify ssh root@$(pass show machines/<machine-name>/tor-hostname)  # via tor
```

## Remote Machine Access

**CRITICAL**: For privileged work on a remote machine (firewall rules,
journals of system services, systemctl, reading /run/secrets, ...), ssh in as
root (`ssh root@<machine>.r`). NEVER use `sudo` on remote systems. Ssh as the
normal user (`lass@`) only to act as that user, e.g. to run user tools.

## Important: Git Staging for Flake Evaluation

**CRITICAL**: New nix files must be staged (git add) before they are available in flake evaluation. When creating new packages, modules, or any nix files, always run `git add <files>` before testing with `nix build`, `nix run`, etc.

## Git Push Policy

**CRITICAL**: NEVER `git push` to any remote. Local commits are fine when asked.
A push happens only when the user runs it themselves or explicitly says
"push" for that specific change in the current conversation. This includes
all remotes (origin, HTTPS via gh credentials, pair) and all branches.

Changes reach master through pull requests on tangled.org, not direct
pushes. The repo lives on our knot
(`knot.lassul.us/lass.pds.lassul.us/superconfig`); GitHub is a read-only
mirror. When the user says "push", push the branch to your own fork on
knot.lassul.us and open a PR with `tg` (tangled.org/aly.codes/tg):

```bash
git fetch knot && git rebase knot/master
git push fork HEAD:<branch>
tg pr create -R lass.pds.lassul.us/superconfig \
  --source-repo <your handle>/superconfig -H <branch> -B master -t "<subject>"
```

The user reviews and merges on tangled.org. Every hour (or on demand)
`.github/workflows/mirror-from-knot.yml` fast-forwards GitHub master to the
knot's master and then runs CI (`.github/workflows/ci.yml`): the build of all
NixOS machines on GitHub runners, with hestia (GitHub Actions cache) as
binary cache; every CI build is pushed to cache.lassul.us (niks3), so
deploys substitute the toplevels from there. Every 5 minutes
`.github/workflows/tangled-prs.yml` runs the same CI on new rounds of open
PRs (without pushing to the cache) and comments the result on the PR; wait
for "CI ✓" before asking for review. Never push or merge on
GitHub: a diverged GitHub master stops the mirror.

## Machine Facts and Secrets via vars

- SSH public keys
- Network identities (retiolum, zerotier)
- Syncthing IDs
- DKIM keys (for mail servers)

Secrets are managed via password-store and uploaded to `/run/secrets` on deployment.

## Adding New Machines

1. Create directory `machines/<name>/`
2. Add `config.nix`, `physical.nix`, and optionally `disk.nix`
3. Generate facts using clan-cli
4. Add to inventory in `flake.nix`
5. Deploy using `s deploy --flake . <name>` (agents add `--yes`)

## Pre-Commit

**CRITICAL**: Always run `nix fmt` before committing to ensure all files pass the treefmt formatting check in CI.

## Commit Message Guidelines

- Use simple, descriptive commit messages without attribution footers
- Use flake attribute paths as prefixes (e.g., `tools.mutt:` not just `mutt:`)
- For flake.lock updates, use: "flake.lock: update"
- Follow existing patterns seen in git log
