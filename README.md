# claudedot

A shell utility (`cdot`) that syncs your [Claude Code](https://github.com/anthropics/claude-code) config and per-project conversation history across machines via a private git remote.

Config files (settings, keybindings, global instructions) sync automatically on every run. Project conversation history is opt-in per project and stored on isolated branches — it never touches the main branch. If [claudebox](https://github.com/bpeterme/claudebox) is installed, `cdot` runs automatically at session start and exit with no manual steps needed.

## Prerequisites

- git

## Installation

### Homebrew (recommended)

```bash
brew tap bpeterme/claudedot
brew install bpeterme/claudedot/claudedot
cdot --help
```

### Manual

```bash
git clone https://github.com/bpeterme/claudedot.git ~/claudedot
```

Add to your `~/.zshrc` or `~/.bashrc`:

```bash
source ~/claudedot/cdot.sh
```

Then:

```bash
cdot --help
```

## Quick Start

```bash
cdot config    # connect to your sync remote (a private git repo you control)
cdot           # pull and push config + any opted-in project history
```

To sync conversation history for the current project:

```bash
cd ~/my-project
cdot add       # opt this project into history sync
cdot           # push history for the first time
```

## Commands

| Command | Description |
|---------|-------------|
| `cdot` | Pull and push config + current project history |
| `cdot config` | Set or remove sync remote (interactive) |

**Project history**

| Command | Description |
|---------|-------------|
| `cdot add` | Opt current project into history sync |
| `cdot remove [<project>]` | Stop syncing current project (or named project) on this machine |
| `cdot delete <project>` | Delete all sync history for a project across all machines |
| `cdot read` | Browse conversations from other machines (read-only, no download) |
| `cdot list` | List projects with history sync and sizes |
| `cdot compact` | Squash current project's history to a single commit |
| `cdot prune` | Remove old or oversized history branches (`--all`: all projects on this machine) |

**Maintenance**

| Command | Description |
|---------|-------------|
| `cdot doctor` | Run environment diagnostics (includes companion tool status) |
| `cdot version` | Show version |

## How It Works

### Config sync

Config files are tracked on the `main` branch of your sync remote using a gitignore allowlist — only explicitly listed files are committed, everything else is excluded. On each run, `cdot` commits any local changes, rebases on the latest remote state, and pushes.

Files synced by default:

| File | Description |
|------|-------------|
| `settings.json` | Claude Code settings |
| `CLAUDE.md` | Global instructions |
| `keybindings.json` | Key bindings |
| `*.sh` | User scripts (e.g. statusline scripts) |
| `plugins/**` | Plugin configuration |
| `skills/**` | User-defined skills |
| `rules/**` | User-defined rules |
| `agents/**` | User-defined agents |
| `output-styles/**` | Output style definitions |

Symlinks are excluded from sync automatically. If a dangling symlink arrives from another machine, `cdot` warns and removes it from the index.

### Project history sync

Each opted-in project gets its own branch: `history/<project>/<user>@<host>`. History is written as orphan commits on a separate git index — it never touches the `main` branch or your config. Pulling history extracts the archive directly to the working tree without affecting the git index.

This means:
- Config and history are completely isolated from each other
- Multiple machines each have their own history branch for the same project
- `cdot compact` replaces the branch with a single commit, keeping remote storage small
- `cdot prune` removes branches by age or size
- `cdot read` lets you browse conversations from any other synced machine without downloading them locally
- `cdot delete <project>` removes all remote history branches for a project across all machines

### claudebox integration

If [claudebox](https://github.com/bpeterme/claudebox) is installed, it calls `cdot _pull` and `cdot _push` (and the history equivalents) automatically at session start and exit. No manual `cdot` invocations are needed during normal use.

## Configuration

Create `~/.config/claudedot/cdot.env` to override defaults. See [`cdot.env.example`](cdot.env.example) for all options. If `$XDG_CONFIG_HOME` is set, the file goes in `$XDG_CONFIG_HOME/claudedot/cdot.env` instead.

| Variable | Default | Description |
|----------|---------|-------------|
| `CDOT_CLAUDE_DIR` | `~/.claude` | Claude Code config directory to sync |
| `CDOT_SYNC_SIZE_WARN_MB` | `500` | Warn when total history size across opted-in projects exceeds this threshold (MB) |

## Companion Tools

### [claudebox](https://github.com/bpeterme/claudebox)

[claudebox](https://github.com/bpeterme/claudebox) (`cbox`) runs Claude Code inside an isolated container scoped to your current project directory. When claudebox is installed alongside claudedot, sync runs automatically at every session boundary — no manual invocation needed.

```bash
brew tap bpeterme/claudebox
brew install bpeterme/claudebox/claudebox
cbox           # start Claude Code in a container for the current project
```

### [flux](https://github.com/bpeterme/flux)

[flux](https://github.com/bpeterme/flux) handles automatic file routing between any git remote and Cloudflare R2 object storage. If your projects involve large assets alongside code, flux manages the file transport layer for assets that don't belong in a regular git repo.

```bash
brew tap bpeterme/flux
brew install bpeterme/flux/flux
flux add       # initialise flux in a git repository
```

## License

MIT
