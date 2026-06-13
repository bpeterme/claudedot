#!/bin/bash
# shellcheck shell=bash

# cdot — Claude environment sync
# Install via Homebrew:
#   brew tap bpeterme/claudedot && brew install bpeterme/claudedot/claudedot
# Or source this file in .bashrc or .zshrc:
#   source /path/to/claudedot/cdot.sh

# =========================================================
# cdot - Claude Environment Sync
# =========================================================

_CDOT_YELLOW='\033[1;33m'; _CDOT_NC='\033[0m'

# ---------------------------------------------------------
# help
# ---------------------------------------------------------

_cdot_help() {
    clear
    cat <<'EOF'
cdot — Claude environment sync

Usage:
  cdot               Sync config and current project history (bidirectional)
  cdot list          List projects with history sync and sizes
  cdot read          Browse conversations from other machines (read-only, no download)
  cdot add           Opt current project into history sync
  cdot remove        Stop syncing current project
  cdot delete        Delete all sync history for a project across all machines
  cdot compact       Squash current project's history to one commit
  cdot prune         Remove old/oversized history branches (--all: all projects)

Maintenance:
  cdot config        Set or remove sync remote (interactive)
  cdot doctor        Run environment diagnostics
  cdot version       Show version

Companion tools:
  cbox help          claudebox — Claude Code container runtime
  flux help          flux — Large-file routing for your projects (git + R2 storage)

Help:
  cdot help
  cdot --help
  cdot -h
EOF
}

# ---------------------------------------------------------
# config
# ---------------------------------------------------------

_CDOT_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claudedot/cdot.env"
if [[ -f "$_CDOT_CONFIG" ]]; then
  . "$_CDOT_CONFIG"
elif [[ -d "$(dirname "$_CDOT_CONFIG")" ]]; then
  echo "⚠  cdot: config dir exists but cdot.env not found — check filename: $_CDOT_CONFIG" >&2
fi
unset _CDOT_CONFIG

CDOT_CLAUDE_DIR="${CDOT_CLAUDE_DIR:-$HOME/.claude}"
CDOT_SYNC_SIZE_WARN_MB="${CDOT_SYNC_SIZE_WARN_MB:-500}"

_CDOT_VERSION="dev"
if [[ "$_CDOT_VERSION" == "dev" ]]; then
  _v=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --short HEAD 2>/dev/null) || true
  [[ -n "$_v" ]] && _CDOT_VERSION="HEAD-$_v"
  unset _v
fi

# ---------------------------------------------------------
# helpers
# ---------------------------------------------------------

_cdot_name() {
  local name
  name=$(basename "$PWD" \
    | tr -cs '[:alnum:]' '-' \
    | sed 's/^-*//;s/-*$//')

  echo "${name:-project}"
}

_cdot_project_dir() {
  echo "-Workspace-$1"
}

_cdot_machine_id() {
  echo "${USER}@$(hostname -s)"
}

_cdot_history_branch() {
  echo "history/$1/$(_cdot_machine_id)"
}

_cdot_is_opted_in() {
  local name="$1"
  local branch
  branch=$(_cdot_history_branch "$name")
  git -C "$CDOT_CLAUDE_DIR" rev-parse --verify \
    "refs/remotes/origin/$branch" >/dev/null 2>&1 || return 1
}

# ---------------------------------------------------------
# sync — config (main branch)
# ---------------------------------------------------------

# Finds symlinks in the claude config dir, adds them to the per-machine local
# exclude (never committed), untracks them from the git index if needed, and
# warns about broken ones. Distinguishes stale local symlinks (target under
# $HOME — leftover from a prior installation) from ones likely pulled from
# another machine (target is an absolute path to a different machine's home).
_cdot_exclude_symlinks() {
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0

  local exclude_file="$dir/.git/info/exclude"
  local broken_local=()
  local broken_remote=()

  while IFS= read -r -d '' symlink; do
    local rel="${symlink#"$dir/"}"

    # Append to the per-machine local exclude if not already listed
    if ! grep -qxF "$rel" "$exclude_file" 2>/dev/null; then
      echo "$rel" >> "$exclude_file"
    fi

    # Untrack from git index so the next push commits a deletion, clearing
    # the symlink from the remote and other machines
    git -C "$dir" rm --cached --ignore-unmatch "$rel" >/dev/null 2>&1

    if [[ ! -e "$symlink" ]]; then
      local target
      target=$(readlink "$symlink")
      # If the target is under $HOME or a typical local home prefix, it's a
      # stale local symlink (e.g. a debug pointer left by a previous install),
      # not something pulled from another machine.
      if [[ "$target" == "$HOME"* || "$target" == /Users/* || "$target" == /home/* ]]; then
        broken_local+=("$rel → $target")
      else
        broken_remote+=("$rel → $target")
      fi
    fi
  done < <(find "$dir" \( -path "$dir/.git" -prune \) -o \( -type l -print0 \))

  if [[ ${#broken_local[@]} -gt 0 ]]; then
    echo "⚠  Stale local symlink(s) found — target no longer exists:"
    for b in "${broken_local[@]}"; do
      echo "   $b"
    done
    echo "   Excluded from sync."
  fi

  if [[ ${#broken_remote[@]} -gt 0 ]]; then
    echo "⚠  Broken symlink(s) in Claude config — likely pulled from another machine:"
    for b in "${broken_remote[@]}"; do
      echo "   $b (target missing)"
    done
    echo "   Removed from sync. Restore your own symlinks manually."
  fi
}

# Finds embedded git repos staged as gitlinks (mode 160000), removes them from
# the index, and adds them to info/exclude so they stay out of future commits.
# Embedded repos staged this way would create a submodule reference without a
# .gitmodules entry, which breaks clones on other machines.
_cdot_exclude_gitlinks() {
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0

  local exclude_file="$dir/.git/info/exclude"
  local found=()

  while IFS=$'\t' read -r _ path; do
    [[ -z "$path" ]] && continue

    if ! grep -qxF "$path" "$exclude_file" 2>/dev/null; then
      echo "$path" >> "$exclude_file"
    fi

    git -C "$dir" rm --cached --ignore-unmatch "$path" >/dev/null 2>&1
    found+=("$path")
  done < <(git -C "$dir" ls-files --stage 2>/dev/null | grep "^160000")

  if [[ ${#found[@]} -gt 0 ]]; then
    echo "⚠  Embedded git repo(s) found — excluded from sync:"
    for p in "${found[@]}"; do
      echo "   $p"
    done
    echo "   Use 'git submodule add' if you intended to track one."
  fi
}

_cdot_pull() {
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0
  command -v git >/dev/null || return 0

  # Auto-heal: if remote exists but current branch has no tracking, set it
  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    if ! git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
      local _branch; _branch=$(git -C "$dir" branch --show-current 2>/dev/null)
      [[ -n "$_branch" ]] && \
        git -C "$dir" branch --set-upstream-to="origin/$_branch" "$_branch" 2>/dev/null || true
    fi
  fi

  # Only pull if a tracking branch is configured
  git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1 || return 0

  echo "Pulling Claude config..."
  git -C "$dir" pull --rebase 2>&1 \
    || echo "⚠  Sync pull failed — continuing with local state"

  # Exclude and warn about any symlinks that arrived from the remote
  _cdot_exclude_symlinks
}

_cdot_push() {
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0
  command -v git >/dev/null || return 0

  # Bail if a rebase is in progress (unresolved conflict from a prior sync)
  if [[ -d "$dir/.git/rebase-merge" || -d "$dir/.git/rebase-apply" ]]; then
    echo "⚠  Rebase in progress in $dir — resolve conflicts before syncing."
    return 1
  fi

  # Only push if a remote is configured
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || return 0

  git -C "$dir" add -A
  # Un-stage symlinks and embedded git repos — .gitignore allowlist overrides
  # info/exclude so we must remove them from the index after staging, not before
  _cdot_exclude_symlinks
  _cdot_exclude_gitlinks

  # Commit local changes first so the working tree is clean before pulling
  if ! git -C "$dir" diff --cached --quiet; then
    git -C "$dir" commit -m "sync — $(_cdot_machine_id) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  # Pull remote changes onto a clean tree — local commit rebases on top if needed
  if git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    git -C "$dir" pull --rebase 2>&1 \
      || { echo "⚠  Sync conflict — resolve manually, then run 'cdot' again."; return 1; }
    _cdot_exclude_symlinks
  fi

  if git -C "$dir" push; then
    return 0
  fi

  echo "⚠  Sync push failed — changes saved locally."
  echo "   Retry manually: git -C \"$dir\" push"
}

# Allowlist for main branch — config only. projects/ is handled via per-project
# history branches and is intentionally excluded here.
# Overwritten if the old format (containing !projects/) is detected (migration).
_cdot_write_gitignore() {
  local dir="$1"
  if [[ -f "$dir/.gitignore" ]] \
      && ! grep -q "^!projects/" "$dir/.gitignore" 2>/dev/null \
      && grep -q "^!skills/" "$dir/.gitignore" 2>/dev/null; then
    return 0
  fi
  cat > "$dir/.gitignore" <<'EOF'
# Ignore everything — only explicitly listed items are synced.
*

# This file itself
!.gitignore

# Claude Code config
!settings.json
!CLAUDE.md
!keybindings.json

# User scripts (e.g. statusline-command.sh)
!*.sh

# Plugin configuration
!plugins/
!plugins/**

# User-defined extensions
!skills/
!skills/**
!rules/
!rules/**
!agents/
!agents/**
!output-styles/
!output-styles/**
EOF
}

_cdot_init() {
  local remote="$1"
  local dir="$CDOT_CLAUDE_DIR"

  if [[ -z "$remote" ]]; then
    echo "Error: remote URL required"
    return 1
  fi

  if ! command -v git >/dev/null; then
    echo "Error: git not found"
    return 1
  fi

  mkdir -p "$dir"

  if [[ ! -d "$dir/.git" ]]; then
    git -C "$dir" init -b main 2>/dev/null \
      || { git -C "$dir" init && git -C "$dir" branch -M main 2>/dev/null || true; }
  fi

  _cdot_write_gitignore "$dir"

  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    local old_remote
    old_remote=$(git -C "$dir" remote get-url origin 2>/dev/null)
    git -C "$dir" remote set-url origin "$remote"
    [[ "$old_remote" != "$remote" ]] && echo "Re-initializing sync (was: $old_remote)"
  else
    git -C "$dir" remote add origin "$remote"
  fi

  # Detect whether the remote has history and what its default branch is
  local remote_default=""
  if git -C "$dir" fetch origin 2>/dev/null; then
    remote_default=$(git -C "$dir" ls-remote --symref origin HEAD 2>/dev/null \
      | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')
  fi

  if [[ -n "$remote_default" ]]; then
    # Remote has history — commit any local state, then rebase on top of remote
    git -C "$dir" add -A
    _cdot_exclude_symlinks
    _cdot_exclude_gitlinks
    if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
      git -C "$dir" commit -m "local state before initial sync — $(_cdot_machine_id)"
    fi
    git -C "$dir" branch --set-upstream-to="origin/$remote_default" main 2>/dev/null || true
    if git -C "$dir" rebase "origin/$remote_default"; then
      echo "✔ Sync initialized — pulled existing config from remote."
    else
      local conflicts
      conflicts=$(git -C "$dir" diff --name-only --diff-filter=U 2>/dev/null)
      echo ""
      echo "⚠  Config conflict during initial sync."
      echo "   Your local config and the remote have diverged on the same file(s)."
      echo ""
      if [[ -n "$conflicts" ]]; then
        echo "   Conflicting files:"
        while IFS= read -r f; do
          echo "     $f"
        done <<< "$conflicts"
        echo ""
      fi
      echo "   In each conflicting file, '<<<<<<< HEAD' is the remote config"
      echo "   and '>>>>>>>' is your local config. Edit to resolve, then:"
      echo ""
      echo "     cd $dir"
      echo "     git add <file>"
      echo "     git rebase --continue"
      echo ""
      echo "   To discard your local config and use the remote as-is:"
      echo "     git -C \"$dir\" rebase --abort"
      echo "     git -C \"$dir\" reset --hard origin/$remote_default"
      echo ""
      echo "   Once resolved, run 'cdot' to push your merged config."
      return 1
    fi

  else
    # Remote is empty — push local state
    git -C "$dir" add -A
    _cdot_exclude_symlinks
    _cdot_exclude_gitlinks
    if ! git -C "$dir" diff --cached --quiet 2>/dev/null \
        || ! git -C "$dir" log -1 >/dev/null 2>&1; then
      git -C "$dir" commit --allow-empty -m "initial sync — $(_cdot_machine_id)"
    fi
    if git -C "$dir" push -u origin main; then
      echo "✔ Sync initialized — pushed local config to remote."
    else
      echo "⚠  Push failed. Check remote access and retry:"
      echo "   git -C \"$dir\" push -u origin main"
    fi
  fi

  if command -v cbox >/dev/null 2>&1; then
    echo "Config will now sync automatically on cbox start and exit."
    echo "Use 'cdot add' to opt the current project into history sync."
  else
    echo "Run 'cdot pull' / 'cdot push' to sync manually (auto-sync requires cbox)."
  fi
}

_cdot_unlink() {
  local dir="$CDOT_CLAUDE_DIR"
  local force=""
  [[ "${1:-}" == "--force" ]] && force=1

  if [[ ! -d "$dir/.git" ]]; then
    echo "Sync is not initialized — nothing to unlink."
    return 0
  fi

  local remote
  remote=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "none")

  if [[ -z "$force" ]]; then
    echo "This will remove the local sync git repo at:"
    echo "  $dir/.git"
    echo "Remote: $remote"
    echo ""
    local synced_count machine
    machine=$(_cdot_machine_id)
    synced_count=$(git -C "$dir" branch -r 2>/dev/null \
      | grep -c "origin/history/[^/]*/$machine$" || true)
    if (( synced_count > 0 )); then
      echo "Synced projects on this machine: $synced_count"
      echo "Their local history branches will be deleted with the repo."
      echo ""
    fi
    echo "Your config files will not be touched (only sync metadata is removed)."
    echo ""
    printf "Continue? [y/N] "
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }
  fi

  rm -rf "$dir/.git"
  rm -f "$dir/.gitignore"

  echo "✔ Sync unlinked. Config files remain at $dir"
  echo "  Run 'cdot config' to set up sync again."
}

_cdot_config() {
  local dir="$CDOT_CLAUDE_DIR"
  clear

  if [[ ! -d "$dir/.git" ]] || ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    printf "Enter remote URL: "
    read -r remote
    [[ -z "$remote" ]] && { echo "Aborted."; return 0; }
    _cdot_init "$remote"
  else
    local remote
    remote=$(git -C "$dir" remote get-url origin 2>/dev/null)
    echo "Sync remote: $remote"
    echo ""
    printf "Unlink sync? [y/N] "
    read -r reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
      _cdot_unlink --force
    else
      echo "No changes made."
    fi
  fi
}

# ---------------------------------------------------------
# sync — history (per-project branches: history/<project>/<user>@<host>)
# ---------------------------------------------------------

_cdot_size_check() {
  local warn_mb="${CDOT_SYNC_SIZE_WARN_MB:-500}"
  local size_mb
  size_mb=$(du -sm "$CDOT_CLAUDE_DIR/projects/" 2>/dev/null | awk '{print $1}')
  [[ -z "$size_mb" ]] && return 0
  if (( size_mb > warn_mb )); then
    echo "⚠  Project history is ${size_mb}MB (threshold: ${warn_mb}MB)"
    echo "   Consider: cdot prune --older-than 30d"
    echo "             cdot compact"
  fi
}

_cdot_pull_history() {
  local name="$1"
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0
  command -v git >/dev/null || return 0
  _cdot_is_opted_in "$name" || return 0

  local branch
  branch=$(_cdot_history_branch "$name")

  local before
  before=$(git -C "$dir" rev-parse --verify "refs/remotes/origin/$branch" 2>/dev/null || true)

  git -C "$dir" fetch origin \
    "refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || return 0

  local after
  after=$(git -C "$dir" rev-parse --verify "refs/remotes/origin/$branch" 2>/dev/null || true)

  # Branch doesn't exist on remote, or nothing new since last pull
  [[ -z "$after" || "$before" == "$after" ]] && return 0

  echo "Pulling history for '$name'..."
  # Extract directly to working tree — does not touch main's index
  git -C "$dir" archive "refs/remotes/origin/$branch" \
    | tar -x -C "$dir" 2>/dev/null || true
}

_cdot_push_history() {
  local name="$1"
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0
  command -v git >/dev/null || return 0
  _cdot_is_opted_in "$name" || return 0

  if [[ -d "$dir/.git/rebase-merge" || -d "$dir/.git/rebase-apply" ]]; then
    echo "⚠  Rebase in progress in $dir — resolve conflicts before syncing."
    return 1
  fi

  local project_dir
  project_dir=$(_cdot_project_dir "$name")
  [[ -d "$dir/projects/$project_dir" ]] || return 0

  local branch
  branch=$(_cdot_history_branch "$name")

  local tmp_index
  tmp_index=$(mktemp -u "$dir/.git/cdot-history-index.XXXXXX")
  trap "rm -f '$tmp_index'" RETURN
  GIT_INDEX_FILE="$tmp_index" git -C "$dir" add --force "projects/$project_dir/" 2>/dev/null || true
  local tree
  tree=$(GIT_INDEX_FILE="$tmp_index" git -C "$dir" write-tree 2>/dev/null || true)
  rm -f "$tmp_index"
  trap - RETURN

  [[ -n "$tree" ]] || { echo "⚠  Failed to build history tree for '$name'."; return 1; }

  local parent_args=()
  local parent
  parent=$(git -C "$dir" rev-parse --verify "refs/remotes/origin/$branch" 2>/dev/null || true)
  [[ -n "$parent" ]] && parent_args=(-p "$parent")

  # Skip if history hasn't changed since last push, but only if the remote
  # branch actually exists — a stale local tracking ref (e.g. after cdot remove)
  # must not suppress a fresh push.
  if [[ -n "$parent" ]]; then
    local parent_tree
    parent_tree=$(git -C "$dir" rev-parse "${parent}^{tree}" 2>/dev/null || true)
    if [[ "$tree" == "$parent_tree" ]]; then
      git -C "$dir" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null \
        | grep -q . && return 0
    fi
  fi

  echo "Pushing history for '$name'..."

  local commit
  commit=$(git -C "$dir" commit-tree "$tree" "${parent_args[@]}" \
    -m "sync — $(_cdot_machine_id) — $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true)

  [[ -n "$commit" ]] || { echo "⚠  Failed to create history commit for '$name'."; return 1; }

  local push_out
  push_out=$(git -C "$dir" push origin "$commit:refs/heads/$branch" 2>&1)
  local push_rc=$?
  if [[ $push_rc -eq 0 ]]; then
    _cdot_size_check
    return 0
  else
    printf '%s\n' "$push_out"
    echo "⚠  History push failed for '$name'."
    if printf '%s\n' "$push_out" | grep -qE "not allowed|does not appear to be|Repository not found|Could not read from remote"; then
      local remote_url
      remote_url=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "unknown")
      echo "   Remote access error — the remote may have moved or been renamed."
      echo "   Configured remote: $remote_url"
      echo "   To reconfigure: cdot config <new-remote-url>"
    else
      echo "   Retry manually: git -C \"$dir\" push origin $commit:refs/heads/$branch"
    fi
    return 1
  fi
}

_cdot_add() {
  local name="$1"
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cdot config"; return 1; }

  local branch
  branch=$(_cdot_history_branch "$name")

  # Check against remote (not local tracking ref, which can be stale)
  if git -C "$dir" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null | grep -q .; then
    echo "Project '$name' is already opted into history sync on this machine."
    return 0
  fi
  # Clean up any stale tracking ref
  git -C "$dir" update-ref -d "refs/remotes/origin/$branch" 2>/dev/null || true

  local empty_tree commit
  empty_tree=$(git hash-object -t tree /dev/null)
  commit=$(git -C "$dir" commit-tree "$empty_tree" \
    -m "add — $(_cdot_machine_id) — $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true)

  [[ -n "$commit" ]] || { echo "⚠  Failed to create initial commit."; return 1; }

  local push_out
  push_out=$(git -C "$dir" push origin "$commit:refs/heads/$branch" 2>&1)
  if [[ $? -eq 0 ]]; then
    git -C "$dir" fetch origin \
      "refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1 || true
    echo "✔ Project '$name' opted into history sync on this machine."
    _cdot_push_history "$name"
  else
    printf '%s\n' "$push_out"
    echo "⚠  Failed to opt '$name' into history sync."
    if printf '%s\n' "$push_out" | grep -qE "not allowed|does not appear to be|Repository not found|Could not read from remote"; then
      local remote_url
      remote_url=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "unknown")
      echo "   Remote access error — the remote may have moved or been renamed."
      echo "   Configured remote: $remote_url"
      echo "   To reconfigure: cdot config <new-remote-url>"
    fi
    return 1
  fi
}

_cdot_remove() {
  local name="$1"
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cdot config"; return 1; }

  local branch
  branch=$(_cdot_history_branch "$name")

  if ! git -C "$dir" rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    echo "Project '$name' is not opted into history sync on this machine."
    return 1
  fi

  if git -C "$dir" push origin --delete "$branch" 2>/dev/null; then
    echo "✔ History for '$name' removed from remote."
  else
    echo "⚠  Could not delete remote branch (may not exist)."
  fi
  git -C "$dir" update-ref -d "refs/remotes/origin/$branch" 2>/dev/null || true
  echo "   '$name' removed from history sync on this machine."
}

_cdot_delete() {
  local name="$1"
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cdot config"; return 1; }
  [[ -n "$name" ]] || { echo "Usage: cdot delete <project>"; return 1; }
  clear

  echo "Fetching remote refs..."
  git -C "$dir" fetch origin 2>/dev/null || true

  local branches
  branches=$(git -C "$dir" ls-remote --heads origin "history/$name/*" 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/heads/||')

  if [[ -z "$branches" ]]; then
    echo "No remote history found for '$name'."
    return 1
  fi

  echo "This will delete all remote history branches for '$name':"
  echo "$branches" | sed 's/^/  /'
  printf "Continue? [y/N] "
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }

  local failed=false
  while IFS= read -r branch; do
    if git -C "$dir" push origin --delete "$branch" 2>/dev/null; then
      echo "✔ Deleted $branch"
    else
      echo "⚠  Could not delete $branch"
      failed=true
    fi
  done <<< "$branches"

  local this_branch
  this_branch=$(_cdot_history_branch "$name")
  if git -C "$dir" rev-parse --verify "refs/remotes/origin/$this_branch" >/dev/null 2>&1; then
    git -C "$dir" update-ref -d "refs/remotes/origin/$this_branch" 2>/dev/null || true
    echo "✔ '$name' removed from local tracking refs on this machine."
  fi

  $failed && echo "⚠  Some branches could not be deleted." || \
    echo "✔ All remote history for '$name' deleted."
}

_cdot_compact() {
  local name="$1"
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cdot config"; return 1; }

  if ! _cdot_is_opted_in "$name"; then
    echo "Project '$name' is not opted into history sync. Run: cdot add"
    return 1
  fi

  local project_dir branch
  project_dir=$(_cdot_project_dir "$name")
  branch=$(_cdot_history_branch "$name")

  [[ -d "$dir/projects/$project_dir" ]] || { echo "No history found for '$name'."; return 1; }

  local tmp_index
  tmp_index=$(mktemp -u "$dir/.git/cdot-compact-index.XXXXXX")
  trap "rm -f '$tmp_index'" RETURN
  GIT_INDEX_FILE="$tmp_index" git -C "$dir" add --force "projects/$project_dir/" 2>/dev/null
  local tree
  tree=$(GIT_INDEX_FILE="$tmp_index" git -C "$dir" write-tree 2>/dev/null)
  rm -f "$tmp_index"
  trap - RETURN

  [[ -n "$tree" ]] || { echo "⚠  Failed to build tree for compact."; return 1; }

  # Orphan commit — no parent, drops all prior history on this branch
  local commit
  commit=$(git -C "$dir" commit-tree "$tree" \
    -m "compact — $(_cdot_machine_id) — $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null)

  [[ -n "$commit" ]] || { echo "⚠  Failed to create compact commit."; return 1; }

  if git -C "$dir" push --force origin "$commit:refs/heads/$branch"; then
    echo "✔ History for '$name' compacted to a single commit."
  else
    echo "⚠  Compact push failed."
    echo "   Retry: git -C \"$dir\" push --force origin $commit:refs/heads/$branch"
  fi
}

_cdot_prune() {
  local name="$1"; shift
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cdot config"; return 1; }

  local older_than_days="" size_limit_mb="" force=false all_projects=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)        all_projects=true; shift ;;
      --older-than) older_than_days="${2%[dD]}"; shift 2 ;;
      --over)       size_limit_mb="${2%[mM]}";   shift 2 ;;
      --force)      force=true; shift ;;
      *) echo "Unknown flag: $1"; return 1 ;;
    esac
  done

  if [[ -z "$older_than_days" && -z "$size_limit_mb" ]]; then
    echo "Usage: cdot prune --older-than <N>d [--force]"
    echo "       cdot prune --over <N>m [--force]"
    echo "       add --all to operate on all projects on this machine"
    return 1
  fi
  clear

  echo "Fetching remote refs..."
  git -C "$dir" fetch origin 2>/dev/null || true

  local host; host=$(_cdot_machine_id)
  local branches=()

  if $all_projects; then
    while IFS= read -r ref; do
      [[ -n "$ref" ]] && branches+=("${ref#refs/heads/}")
    done < <(git -C "$dir" ls-remote --heads origin "history/*/$host" 2>/dev/null \
      | awk '{print $2}')
  else
    local branch; branch=$(_cdot_history_branch "$name")
    local ref
    ref=$(git -C "$dir" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk '{print $2}')
    [[ -n "$ref" ]] && branches+=("$branch")
  fi

  if [[ ${#branches[@]} -eq 0 ]]; then
    $all_projects && echo "No history branches found for this machine." \
      || echo "No history branch found for project '$name'. Run: cdot add"
    return 0
  fi

  local candidates=()
  local now_ts
  now_ts=$(date +%s)

  for branch in "${branches[@]}"; do
    local project="${branch#history/}"
    project="${project%/$host}"
    local should_prune=false

    if [[ -n "$older_than_days" ]]; then
      local last_ts
      last_ts=$(git -C "$dir" log -1 --format="%ct" \
        "refs/remotes/origin/$branch" 2>/dev/null)
      if [[ -n "$last_ts" ]]; then
        local cutoff=$(( now_ts - older_than_days * 86400 ))
        (( last_ts < cutoff )) && should_prune=true
      fi
    fi

    if [[ -n "$size_limit_mb" ]]; then
      local project_dir proj_mb=0
      project_dir=$(_cdot_project_dir "$project")
      proj_mb=$(du -sm "$dir/projects/$project_dir" 2>/dev/null | awk '{print $1}')
      (( proj_mb > size_limit_mb )) && should_prune=true
    fi

    $should_prune && candidates+=("$branch")
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "No branches match the prune criteria."
    return 0
  fi

  echo "Branches to delete:"
  for branch in "${candidates[@]}"; do
    echo "  $branch"
  done

  if ! $force; then
    printf "Delete %d branch(es)? [y/N] " "${#candidates[@]}"
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }
  fi

  for branch in "${candidates[@]}"; do
    if git -C "$dir" push origin --delete "$branch" 2>/dev/null; then
      echo "✔ Deleted $branch"
    else
      echo "⚠  Failed to delete $branch"
    fi
  done
}

# ---------------------------------------------------------
# read — browse another machine's conversations (no local download)
# ---------------------------------------------------------

_cdot_format_conversation() {
  python3 -c '
import sys, json

BOLD  = "\033[1m"
DIM   = "\033[2m"
CYAN  = "\033[36m"
GREEN = "\033[32m"
RESET = "\033[0m"
HR    = "\033[2m" + chr(0x2500) * 72 + "\033[0m"

skip = ("local-command-caveat", "system-reminder", "command-name",
        "command-message", "command-args")

def extract(content):
    if isinstance(content, str):
        t = content.strip()
        return None if (not t or any(m in t for m in skip)) else t
    if isinstance(content, list):
        parts = [b.get("text","").strip() for b in content
                 if isinstance(b,dict) and b.get("type")=="text"
                 and b.get("text","").strip()
                 and not any(m in b.get("text","") for m in skip)]
        return "\n".join(parts) or None
    return None

first = True
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except: continue

    msg  = d.get("message", {})
    role = msg.get("role") or d.get("role", "")
    ts   = d.get("timestamp", "")[11:16]

    if role not in ("user", "assistant"): continue

    text = extract(msg.get("content", ""))
    if not text: continue

    if not first: print(HR)
    first = False

    label = BOLD + (CYAN + "YOU" if role == "user" else GREEN + "CLAUDE") + RESET
    print(label + "  " + DIM + ts + RESET)
    print()
    print(text)
    print()
'
}

_cdot_read() {
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cdot config"; return 1; }
  command -v python3 >/dev/null || { echo "python3 is required for cdot read"; return 1; }

  local this_machine
  this_machine=$(_cdot_machine_id)

  local machine="${1:-}"
  local project_name="${2:-}"

  # ── Step 1: pick machine + project ─────────────────────────────────────────
  if [[ -z "$machine" || -z "$project_name" ]]; then
    echo "Fetching remote refs..."
    git -C "$dir" fetch origin 2>/dev/null || true

    # Collect all history branches excluding current machine
    local -a combo_machine=() combo_project=() combo_date=()
    while IFS= read -r branch; do
      [[ -z "$branch" ]] && continue
      local m p
      m="${branch##*/}"
      p="${branch%/*}"
      [[ "$m" == "$this_machine" ]] && continue
      [[ -n "$machine" && "$m" != "$machine" ]] && continue
      local last_date
      last_date=$(git -C "$dir" log -1 --format="%ci" \
        "refs/remotes/origin/history/$branch" 2>/dev/null | cut -d' ' -f1)
      combo_machine+=("$m")
      combo_project+=("$p")
      combo_date+=("${last_date:-?}")
    done < <(git -C "$dir" branch -r 2>/dev/null \
      | grep "origin/history/" \
      | sed 's|.*origin/history/||;s/[[:space:]]//g' \
      | sort)

    if [[ ${#combo_machine[@]} -eq 0 ]]; then
      [[ -n "$machine" ]] \
        && echo "No history found for machine '$machine'." \
        || echo "No other machines have history synced."
      return 0
    fi

    clear
    printf "Remote conversations:\n\n"
    printf "  %-3s  %-28s  %-22s  %s\n" "#" "Machine" "Project" "Last sync"
    printf "  %s\n" "$(printf '%0.s─' {1..75})"
    local i
    for (( i=0; i<${#combo_machine[@]}; i++ )); do
      printf "  %-3d  %-28s  %-22s  %s\n" \
        "$(( i+1 ))" "${combo_machine[$i]}" "${combo_project[$i]}" "${combo_date[$i]}"
    done

    printf "\nSelect [1-%d] or q to quit: " "${#combo_machine[@]}"
    local choice
    IFS= read -r choice </dev/tty
    [[ "$choice" == "q" || "$choice" == "Q" || -z "$choice" ]] && return 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#combo_machine[@]} )); then
      echo "Invalid selection."
      return 1
    fi
    machine="${combo_machine[$(( choice - 1 ))]}"
    project_name="${combo_project[$(( choice - 1 ))]}"
  fi

  # ── Step 2: list conversations for machine + project ─────────────────────────
  local branch="history/$project_name/$machine"
  git -C "$dir" fetch origin "refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || true

  if ! git -C "$dir" rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    echo "No history found for '$machine' / '$project_name'."
    return 1
  fi

  local project_dir
  project_dir=$(_cdot_project_dir "$project_name")

  echo "Loading conversation list..."
  local -a raw_entries=()
  while IFS=$'\t' read -r size path <&3; do
    local head_data ts preview
    # "; :" drains the pipeline exit status — prevents SIGPIPE from killing
    # the function when the user's shell has ERR_EXIT / pipefail set
    head_data=$(git -C "$dir" show "refs/remotes/origin/$branch:$path" 2>/dev/null \
      | head -c 3000; :)
    ts=$(echo "$head_data" | grep -o '"timestamp":"[^"]*"' | head -1 \
      | sed 's/"timestamp":"//;s/T.*//'; :)
    preview=$(echo "$head_data" | python3 -c '
import sys, json
skip = ("local-command-caveat","system-reminder","command-name")
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        msg = d.get("message",{})
        if msg.get("role") == "user":
            c = msg.get("content","")
            t = c if isinstance(c,str) else " ".join(
                b.get("text","") for b in c
                if isinstance(b,dict) and b.get("type")=="text")
            t = t.strip().replace("\n"," ")
            if t and not any(m in t for m in skip):
                print(t[:65])
                break
    except: pass
' 2>/dev/null; :)
    raw_entries+=("${ts:-0000-00-00}|${size}|${path}|${preview:-?}")
  done 3< <(git -C "$dir" ls-tree -l "refs/remotes/origin/$branch" \
    -- "projects/$project_dir/" 2>/dev/null \
    | awk '$2=="blob" && $NF ~ /\.jsonl$/ {print $4"\t"$NF}')

  if [[ ${#raw_entries[@]} -eq 0 ]]; then
    echo "No conversations found for '$project_name' on '$machine'."
    return 0
  fi

  # Sort newest first (mapfile is bash-only; use a read loop for zsh compat)
  local _sorted
  _sorted=$(printf '%s\n' "${raw_entries[@]}" | sort -r; :)
  raw_entries=()
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && raw_entries+=("$_line")
  done <<< "$_sorted"

  clear
  printf "Conversations on '%s' — '%s':\n\n" "$machine" "$project_name"
  printf "  %-3s  %-10s  %-6s  %s\n" "#" "Date" "Size" "Preview"
  printf "  %s\n" "$(printf '%0.s─' {1..80})"

  local -a conv_paths=()
  local j
  for (( j=0; j<${#raw_entries[@]}; j++ )); do
    local ts sz path preview
    IFS='|' read -r ts sz path preview <<< "${raw_entries[$j]}"
    local size_fmt
    if (( sz > 1048576 )); then
      size_fmt="$(( sz / 1048576 ))M"
    elif (( sz > 1024 )); then
      size_fmt="$(( sz / 1024 ))K"
    else
      size_fmt="${sz}B"
    fi
    printf "  %-3d  %-10s  %-6s  %s\n" "$(( j+1 ))" "$ts" "$size_fmt" "$preview"
    conv_paths+=("$path")
  done

  printf "\nSelect [1-%d] or q to quit: " "${#conv_paths[@]}"
  local choice
  IFS= read -r choice </dev/tty
  [[ "$choice" == "q" || "$choice" == "Q" || -z "$choice" ]] && return 0
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#conv_paths[@]} )); then
    echo "Invalid selection."
    return 1
  fi

  # ── Step 3: stream selected conversation through pager ──────────────────────
  local selected="${conv_paths[$(( choice - 1 ))]}"
  git -C "$dir" show "refs/remotes/origin/$branch:$selected" 2>/dev/null \
    | _cdot_format_conversation \
    | less -R
}

_cdot_branch_size_mb() {
  local dir="$1" ref="$2"
  git -C "$dir" ls-tree -r --long "$ref" 2>/dev/null \
    | awk '{sum += $4} END {printf "%d", sum/1024/1024}'
}

_cdot_list() {
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cdot config"; return 1; }
  clear

  echo "Fetching remote refs..."
  # --prune removes stale local tracking refs so _cdot_is_opted_in stays accurate
  local _fetch_err
  if ! _fetch_err=$(git -C "$dir" fetch --prune origin 2>&1 >/dev/null); then
    printf "  ⚠  Fetch failed — other machines may be missing from this view\n"
    [[ -n "$_fetch_err" ]] && printf "     %s\n" "$_fetch_err"
  fi

  local this_machine
  this_machine=$(_cdot_machine_id)

  # Column layout (used throughout):
  #   col1: 2-char status (✔ /○ /· /  )
  #   col2: project name, 28 chars left-padded
  #   col3: last date, 10 chars (YYYY-MM-DD or ?)
  #   col4: size, 4-char right-aligned number + " mb"
  #   col5: status tag
  local _FMT_OK _FMT_PEND _FMT_NOT_IN _FMT_OTHER
  _FMT_OK="    ✔  %-28s  last: %-10s  size: %4s mb  [in sync]\n"
  _FMT_PEND="${_CDOT_YELLOW}    ○  %-28s  [pending first sync]${_CDOT_NC}\n"
  _FMT_NOT_IN="    ·  %-28s  [not opted in — use: cdot add]\n"
  _FMT_OTHER="       %-28s  last: %-10s  size: %4s mb\n"

  # ── config (main branch) ─────────────────────────────────────────────────────
  local main_remote
  main_remote=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "none")
  local config_size_mb config_last_date
  config_size_mb=$(_cdot_branch_size_mb "$dir" HEAD)
  config_last_date=$(git -C "$dir" log -1 --format="%ci" HEAD 2>/dev/null | cut -d' ' -f1)
  printf "\n  configuration files  (%s)\n" "$main_remote"
  if git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    local ahead behind
    ahead=$(git -C "$dir" rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
    behind=$(git -C "$dir" rev-list --count HEAD..@{u} 2>/dev/null || echo "0")
    if [[ "$ahead" == "0" && "$behind" == "0" ]]; then
      # shellcheck disable=SC2059
      printf "$_FMT_OK" "config" "${config_last_date:-?}" "$config_size_mb"
    elif [[ "$ahead" != "0" && "$behind" == "0" ]]; then
      printf "${_CDOT_YELLOW}    ○  %-28s  last: %-10s  size: %4s mb  [unpushed]${_CDOT_NC}\n" \
        "config" "${config_last_date:-?}" "$config_size_mb"
    elif [[ "$ahead" == "0" ]]; then
      printf "${_CDOT_YELLOW}    ○  %-28s  last: %-10s  size: %4s mb  [behind]${_CDOT_NC}\n" \
        "config" "${config_last_date:-?}" "$config_size_mb"
    else
      printf "${_CDOT_YELLOW}    ○  %-28s  last: %-10s  size: %4s mb  [diverged]${_CDOT_NC}\n" \
        "config" "${config_last_date:-?}" "$config_size_mb"
    fi
  else
    printf "    ○  %-28s  last: %-10s  size: %4s mb  [no upstream]\n" \
      "config" "${config_last_date:-?}" "$config_size_mb"
  fi

  # ── history branches — read from local tracking refs (post-prune = remote) ──
  local all_branches
  all_branches=$(git -C "$dir" branch -r 2>/dev/null \
    | grep "origin/history/" \
    | sed 's|.*origin/||;s/[[:space:]]//g')

  if [[ -z "$all_branches" ]]; then
    printf "\n  No projects opted into history sync. Use: cdot add\n\n"
    return 0
  fi

  # All unique project names: from remote branches + local projects/ dirs
  local all_projects remote_projects local_projects
  remote_projects=$(echo "$all_branches" \
    | sed 's|history/\([^/]*\)/.*|\1|')
  local_projects=$(ls "$dir/projects/" 2>/dev/null \
    | grep "^-Workspace-" \
    | sed 's/^-Workspace-//')
  all_projects=$(printf "%s\n%s" "$remote_projects" "$local_projects" | sort -u)

  # Projects opted in on this machine
  local this_machine_projects
  this_machine_projects=$(echo "$all_branches" \
    | grep "history/[^/]*/$this_machine$" \
    | sed "s|history/\([^/]*\)/$this_machine\$|\1|")

  # Extract unique machines, current machine first
  local machines
  machines=$(echo "$all_branches" \
    | sed 's|history/[^/]*/||' \
    | sort -u \
    | awk -v cur="$this_machine" '$0==cur{print; next} {others[NR]=$0} END{for(i in others) print others[i]}')

  # If this machine has no branches at all, still show the section header
  if ! echo "$machines" | grep -qx "$this_machine"; then
    machines=$(printf "%s\n%s" "$this_machine" "$machines")
  fi

  while IFS= read -r machine; do
    [[ -z "$machine" ]] && continue

    if [[ "$machine" == "$this_machine" ]]; then
      printf "\n  %s  [this machine]\n" "$machine"
    else
      printf "\n  %s\n" "$machine"
    fi

    while IFS= read -r branch; do
      local project="${branch#history/}"
      project="${project%/$machine}"

      # "add — " commit message = opted in but never synced real content yet
      local last_msg
      last_msg=$(git -C "$dir" log -1 --format="%s" \
        "refs/remotes/origin/$branch" 2>/dev/null)

      local last_date
      last_date=$(git -C "$dir" log -1 --format="%ci" \
        "refs/remotes/origin/$branch" 2>/dev/null | cut -d' ' -f1)

      local project_dir size_mb
      project_dir=$(_cdot_project_dir "$project")
      if [[ "$machine" == "$this_machine" ]]; then
        size_mb="?"
        [[ -d "$dir/projects/$project_dir" ]] && \
          size_mb=$(du -sm "$dir/projects/$project_dir" 2>/dev/null | awk '{print $1}')
      else
        size_mb=$(_cdot_branch_size_mb "$dir" "refs/remotes/origin/$branch")
      fi

      if [[ "$machine" == "$this_machine" ]]; then
        if [[ "$last_msg" == "add — "* ]]; then
          # shellcheck disable=SC2059
          printf "$_FMT_PEND" "$project"
        else
          # shellcheck disable=SC2059
          printf "$_FMT_OK" "$project" "${last_date:-?}" "$size_mb"
        fi
      else
        # shellcheck disable=SC2059
        printf "$_FMT_OTHER" "$project" "${last_date:-?}" "$size_mb"
      fi
    done < <(echo "$all_branches" | grep "history/[^/]*/$machine$")

    # For this machine: show projects synced elsewhere but not opted in here
    if [[ "$machine" == "$this_machine" ]]; then
      while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        echo "$this_machine_projects" | grep -qx "$project" && continue
        # shellcheck disable=SC2059
        printf "$_FMT_NOT_IN" "$project"
      done <<< "$all_projects"
    fi
  done <<< "$machines"

  echo ""
}

# ---------------------------------------------------------
# doctor
# ---------------------------------------------------------

_cdot_doctor_inline() {
  if [[ -d "$CDOT_CLAUDE_DIR/.git" ]]; then
    local sync_remote
    sync_remote=$(git -C "$CDOT_CLAUDE_DIR" remote get-url origin 2>/dev/null || echo "none")
    echo "✔ sync enabled (remote: $sync_remote)"

    local ahead behind
    ahead=$(git -C "$CDOT_CLAUDE_DIR" rev-list --count @{u}..HEAD 2>/dev/null || echo "?")
    behind=$(git -C "$CDOT_CLAUDE_DIR" rev-list --count HEAD..@{u} 2>/dev/null || echo "?")
    echo "  ahead: $ahead  behind: $behind"

    local machine synced_count
    machine=$(_cdot_machine_id)
    synced_count=$(git -C "$CDOT_CLAUDE_DIR" branch -r 2>/dev/null \
      | grep -c "origin/history/[^/]*/$machine$" || true)
    if (( synced_count > 0 )); then
      echo "  history projects: $synced_count synced on this machine"
    else
      echo "  history projects: none (use: cdot add)"
    fi
  else
    echo "ℹ sync not configured (run: cdot config)"
  fi
}

_cdot_doctor() {
  clear
  echo "== cdot doctor =="
  echo "Version: $_CDOT_VERSION"

  echo
  echo "[environment]"

  command -v git >/dev/null \
    && echo "✔ git found" \
    || echo "✘ git not found"

  [[ -d "$CDOT_CLAUDE_DIR" ]] \
    && echo "✔ Claude config dir exists ($CDOT_CLAUDE_DIR)" \
    || echo "✘ Claude config dir missing ($CDOT_CLAUDE_DIR)"

  echo
  echo "[cdot]"
  _cdot_doctor_inline

  echo
  echo "[cbox]"
  if command -v cbox >/dev/null 2>&1; then
    cbox _doctor
  else
    echo "ℹ cbox not installed"
    echo "  Install: brew tap bpeterme/claudebox && brew install claudebox"
  fi

  echo
  echo "[flux]"
  if command -v flux >/dev/null 2>&1; then
    flux _doctor
  else
    echo "ℹ flux not installed — large-file sync unavailable"
    echo "  Install: brew tap bpeterme/flux && brew install flux"
  fi
}

# ---------------------------------------------------------
# public command
# ---------------------------------------------------------

cdot() {
  local name
  name=$(_cdot_name)

  case "${1:-}" in

    "")
      [[ -d "$CDOT_CLAUDE_DIR/.git" ]] \
        || { echo "Sync not initialized. Run: cdot config"; return 1; }
      clear
      _cdot_push
      _cdot_pull_history "$name"
      _cdot_push_history "$name"
      ;;

    config)   _cdot_config ;;
    read)     _cdot_read "${2:-}" "${3:-}" ;;
    add)      _cdot_add "$name" ;;
    remove)   _cdot_remove "${2:-$name}" ;;
    delete)   _cdot_delete "${2:-}" ;;
    compact)  _cdot_compact "$name" ;;
    prune)    _cdot_prune "$name" "${@:2}" ;;
    list)     _cdot_list ;;
    doctor)   _cdot_doctor ;;

    version)
      echo "cdot $_CDOT_VERSION"
      ;;

    help|--help|-h)
      _cdot_help
      ;;

    cbox)
      if command -v cbox >/dev/null 2>&1; then
        cbox help
      else
        echo "claudebox is not installed."
        echo "Install: brew tap bpeterme/claudebox && brew install bpeterme/claudebox/claudebox"
        return 1
      fi
      ;;

    flux)
      if command -v flux >/dev/null 2>&1; then
        flux help
      else
        echo "flux is not installed."
        echo "Install: brew tap bpeterme/flux && brew install bpeterme/flux/flux"
        return 1
      fi
      ;;

    # Plumbing: called by cbox, not shown in help
    _api-version)   echo "1" ;;
    _pull)          _cdot_pull ;;
    _push)          _cdot_push ;;
    _pull-history)  _cdot_pull_history "${2:-}" ;;
    _push-history)  _cdot_push_history "${2:-}" ;;
    _doctor)        _cdot_doctor_inline ;;

    *)
      echo "Unknown command: $1"
      echo
      _cdot_help
      return 1
      ;;
  esac
}

# ---------------------------------------------------------
# shell completion
# ---------------------------------------------------------

_cdot_list_opted_in_names() {
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0
  local machine
  machine=$(_cdot_machine_id)
  git -C "$dir" branch -r 2>/dev/null \
    | grep "origin/history/" \
    | grep "/${machine}$" \
    | sed "s|.*origin/history/\([^/]*\)/${machine}\$|\1|"
}

_cdot_list_all_project_names() {
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0
  git -C "$dir" branch -r 2>/dev/null \
    | grep "origin/history/" \
    | sed 's|.*origin/history/\([^/]*\)/.*|\1|' \
    | sort -u
}

if [[ -n "${ZSH_VERSION:-}" ]]; then
  _cdot_zsh_complete() {
    case $CURRENT in
      2)
        compadd list read add remove delete compact prune config doctor version help
        ;;
      3)
        local -a projects
        case "${words[2]}" in
          remove)
            projects=($(_cdot_list_opted_in_names))
            (( ${#projects[@]} )) && compadd -a projects
            ;;
          delete)
            projects=($(_cdot_list_all_project_names))
            (( ${#projects[@]} )) && compadd -a projects
            ;;
        esac
        ;;
    esac
  }
  (( ${+functions[compdef]} )) && compdef _cdot_zsh_complete cdot
elif [[ -n "${BASH_VERSION:-}" ]]; then
  _cdot_bash_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    COMPREPLY=()

    if [[ $COMP_CWORD -eq 1 ]]; then
      COMPREPLY=( $(compgen -W \
        "list read add remove delete compact prune config doctor version help" \
        -- "$cur") )
    elif [[ $COMP_CWORD -eq 2 ]]; then
      case "$prev" in
        remove)
          COMPREPLY=( $(compgen -W "$(_cdot_list_opted_in_names)" -- "$cur") )
          ;;
        delete)
          COMPREPLY=( $(compgen -W "$(_cdot_list_all_project_names)" -- "$cur") )
          ;;
      esac
    fi
  }
  complete -F _cdot_bash_complete cdot
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cdot "$@"
fi
