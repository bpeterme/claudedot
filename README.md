# claudedot

A shell utility (`cdot`) that syncs your [Claude Code](https://github.com/anthropics/claude-code) config, [opencode](https://opencode.ai) config, Claude's memory of each project, and per-project conversation history across machines via a private git remote.

Config files (settings, keybindings, global instructions), opencode config and Claude's project memory sync automatically on every run. Project conversation history is opt-in per project and stored on isolated branches — it never touches the main branch. If [claudebox](https://github.com/bpeterme/claudebox) is installed, `cdot` runs automatically at session start and exit for both Claude Code and opencode sessions with no manual steps needed.

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

**Project memory**

| Command | Description |
|---------|-------------|
| `cdot memory` | Show the size of Claude's memory per project |
| `cdot memory wipe [<project>]` | Delete a project's memory on this machine and, at their next sync, on all others |

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
| `opencode.json` | opencode config (API keys, model settings) |
| `projects/*/memory/**` | Claude's memory of each project (see below) |

> [!CAUTION]
> `opencode.json` may contain API keys in plain text. Ensure your sync remote is a **private** repository.
>
> cdot installs the **committed** `opencode.json` on your machine, never the file in the sync folder: claudebox containers can write that folder, and opencode runs the commands its config names (MCP servers). On a machine without its own opencode config, a changed `opencode.json` in the sync folder is not synced; it is kept as `opencode.json.rejected`. Note that the sync folder, and so this file with its API keys, is readable inside claudebox containers.

Symlinks are excluded from sync automatically. If a dangling symlink arrives from another machine, `cdot` warns and removes it from the index.

### Project memory sync

Claude Code keeps notes per project in `projects/<project>/memory/`: rules you gave it, decisions, and what is left to do. These sync on `main` for **every** project, with no opt-in, so a note written on one machine ("build X next session") is there when you start on another. Memory is small, typically a few KB to a few hundred KB per project.

- Two machines adding notes at the same time never stop a sync: memory files merge with git's `union` driver, so `MEMORY.md` keeps both index lines. If the same note changed on both machines, both versions are kept and `cdot` names the file; ask Claude in that project to tidy it.
- `cdot` warns when a project's memory is over `CDOT_MEMORY_WARN_KB`, and when all projects together pass `CDOT_MEMORY_TOTAL_WARN_KB` (default: number of projects × the per-project limit). Nothing is deleted automatically: whether a note is still relevant takes reading it, so ask Claude to consolidate, or start over with `cdot memory wipe`.
- `cdot memory wipe` deletes a project's memory everywhere. A machine with a session open in that project at the time may report a sync conflict at its next sync.
- Memory is never part of the per-machine history branches below, so an older copy there cannot bring wiped or outdated notes back.

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

If [claudebox](https://github.com/bpeterme/claudebox) is installed, it calls the appropriate cdot plumbing commands automatically at session start and exit — no manual `cdot` invocations are needed during normal use.

| Session type | cdot calls |
|---|---|
| `cbox` (Claude Code) | `cdot _pull` / `cdot _push` + history equivalents |
| `cbox oc` (opencode) | `cdot _pull-opencode` / `cdot _push-opencode` |

claudebox passes its Claude folder (`CBOX_CLAUDE_DIR`, default `~/.config/claudebox/.claude`) as `CDOT_CLAUDE_DIR`, so these calls sync the folder containers use. A `CDOT_CLAUDE_DIR` set in `cdot.env` takes precedence.

> [!NOTE]
> opencode stores conversation history in a single SQLite database (`~/.local/share/opencode/opencode.db`) rather than per-project files, so history sync for opencode sessions is not currently supported. Config sync (`opencode.json`) works normally.

## Configuration

Create `~/.config/claudedot/cdot.env` to override defaults. See [`cdot.env.example`](cdot.env.example) for all options. If `$XDG_CONFIG_HOME` is set, the file goes in `$XDG_CONFIG_HOME/claudedot/cdot.env` instead.

| Variable | Default | Description |
|----------|---------|-------------|
| `CDOT_CLAUDE_DIR` | `~/.claude` | Claude Code config directory to sync |
| `CDOT_OPENCODE_CONFIG` | `~/.config/opencode/opencode.json` | opencode config file to sync (may contain API keys — keep your remote private) |
| `CDOT_SYNC_SIZE_WARN_MB` | `500` | Warn when total history size across opted-in projects exceeds this threshold (MB) |
| `CDOT_MEMORY_WARN_KB` | `64` | Warn when one project's memory exceeds this size (KB) |
| `CDOT_MEMORY_TOTAL_WARN_KB` | projects × `CDOT_MEMORY_WARN_KB` | Warn when all project memory together exceeds this size (KB) |

> [!WARNING]
> **Do not place `CDOT_CLAUDE_DIR` (default `~/.claude`) on iCloud Drive, Dropbox Smart Sync, Google Drive Stream, or any on-demand cloud storage.** These services evict file contents to stubs when not recently accessed. A git operation on an evicted file produces a corrupt commit or silently reads the wrong content.
>
> **Do not run continuous sync tools (Syncthing, rsync daemons, etc.) on the same directory alongside `cdot`.** claudedot is designed to be the sync mechanism — a parallel sync tool will race with claudedot's git operations and risk corrupt history or lost writes.

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
