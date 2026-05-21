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

# ---------------------------------------------------------
# help
# ---------------------------------------------------------

_cdot_help() {
    cat <<'EOF'
cdot — Claude environment sync

Usage:
  cdot               Pull and push config + current project history
  cdot list          List projects with history sync and sizes
  cdot add           Opt current project into history sync
  cdot remove        Stop syncing current project
  cdot compact       Squash current project's history to one commit
  cdot prune         Remove old/oversized history branches (--all: all projects)

Maintenance:
  cdot config        Set or remove sync remote (interactive)
  cdot doctor        Run environment diagnostics
  cdot version       Show version

Companion tools:
  cbox               claudebox — Claude Code container runtime
  flux               flux — Large-file routing for your projects (git + R2 storage)

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
CDOT_SYNC_PROJECTS="${CDOT_SYNC_PROJECTS:-}"
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
  [[ " ${CDOT_SYNC_PROJECTS:-} " == *" $1 "* ]]
}

_cdot_register() {
  local name="$1" action="$2"
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/claudedot/cdot.env"
  local current="${CDOT_SYNC_PROJECTS:-}"
  local new_value

  if [[ "$action" == "add" ]]; then
    [[ " $current " == *" $name "* ]] && return 0
    new_value="${current:+$current }$name"
  else
    new_value=$(printf '%s' "$current" | tr ' ' '\n' | grep -vxF "$name" | tr '\n' ' ' || true)
    new_value="${new_value% }"
  fi

  local tmp
  tmp=$(mktemp)
  mkdir -p "$(dirname "$config")"
  if [[ -f "$config" ]]; then
    grep -v "^CDOT_SYNC_PROJECTS=" "$config" > "$tmp" || true
  fi
  printf 'CDOT_SYNC_PROJECTS="%s"\n' "$new_value" >> "$tmp"
  mv "$tmp" "$config"
  CDOT_SYNC_PROJECTS="$new_value"
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

  # Bail if a rebase is in progress (unresolved pull conflict)
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

  # Nothing new to commit
  git -C "$dir" diff --cached --quiet && return 0

  git -C "$dir" commit -m "sync — $(_cdot_machine_id) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if git -C "$dir" push; then
    return 0
  fi

  # Only retry if an upstream tracking branch is configured (genuine rejection)
  if git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    echo "Push rejected, rebasing..."
    if git -C "$dir" pull --rebase && git -C "$dir" push; then
      echo "✔ Synced (after rebase)"
      return 0
    fi
  fi

  echo "⚠  Sync push failed — changes saved locally."
  echo "   Retry manually: git -C \"$dir\" push"
}

# Allowlist for main branch — config only. projects/ is handled via per-project
# history branches and is intentionally excluded here.
# Overwritten if the old format (containing !projects/) is detected (migration).
_cdot_write_gitignore() {
  local dir="$1"
  if [[ -f "$dir/.gitignore" ]] && ! grep -q "^!projects/" "$dir/.gitignore" 2>/dev/null; then
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
    if [[ -n "${CDOT_SYNC_PROJECTS:-}" ]]; then
      echo "Projects currently opted in: $CDOT_SYNC_PROJECTS"
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

  local config="${XDG_CONFIG_HOME:-$HOME/.config}/claudedot/cdot.env"
  if [[ -f "$config" ]]; then
    local tmp
    tmp=$(mktemp)
    grep -v "^CDOT_SYNC_PROJECTS=" "$config" > "$tmp" || true
    mv "$tmp" "$config"
  fi
  CDOT_SYNC_PROJECTS=""

  echo "✔ Sync unlinked. Config files remain at $dir"
  echo "  Run 'cdot config' to set up sync again."
}

_cdot_config() {
  local dir="$CDOT_CLAUDE_DIR"

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

  echo "Pushing history for '$name'..."

  local tmp_index
  tmp_index=$(mktemp "$dir/.git/cdot-history-index.XXXXXX")
  trap "rm -f '$tmp_index'" RETURN
  GIT_INDEX_FILE="$tmp_index" git -C "$dir" add "projects/$project_dir/" 2>/dev/null
  local tree
  tree=$(GIT_INDEX_FILE="$tmp_index" git -C "$dir" write-tree 2>/dev/null)
  rm -f "$tmp_index"
  trap - RETURN

  [[ -n "$tree" ]] || { echo "⚠  Failed to build history tree for '$name'."; return 1; }

  local parent_args=()
  local parent
  parent=$(git -C "$dir" rev-parse --verify "refs/remotes/origin/$branch" 2>/dev/null)
  [[ -n "$parent" ]] && parent_args=(-p "$parent")

  # Skip if history hasn't changed since last push, but only if the remote
  # branch actually exists — a stale local tracking ref (e.g. after cdot remove)
  # must not suppress a fresh push.
  if [[ -n "$parent" ]]; then
    local parent_tree
    parent_tree=$(git -C "$dir" rev-parse "${parent}^{tree}" 2>/dev/null)
    if [[ "$tree" == "$parent_tree" ]]; then
      git -C "$dir" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null \
        | grep -q . && return 0
    fi
  fi

  echo "Pushing history for '$name'..."

  local commit
  commit=$(git -C "$dir" commit-tree "$tree" "${parent_args[@]}" \
    -m "sync — $(_cdot_machine_id) — $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null)

  [[ -n "$commit" ]] || { echo "⚠  Failed to create history commit for '$name'."; return 1; }

  if git -C "$dir" push origin "$commit:refs/heads/$branch" 2>&1; then
    _cdot_size_check
    return 0
  else
    echo "⚠  History push failed for '$name'."
    echo "   Retry manually: git -C \"$dir\" push origin $commit:refs/heads/$branch"
    return 1
  fi
}

_cdot_add() {
  local name="$1"
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cdot config"; return 1; }

  if _cdot_is_opted_in "$name"; then
    echo "Project '$name' is already opted into history sync on this machine."
    return 0
  fi

  _cdot_register "$name" add
  _cdot_push_history "$name"
  echo "✔ Project '$name' opted into history sync on this machine."
}

_cdot_remove() {
  local name="$1"
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cdot config"; return 1; }

  if ! _cdot_is_opted_in "$name"; then
    echo "Project '$name' is not opted into history sync."
    return 1
  fi

  local branch
  branch=$(_cdot_history_branch "$name")

  _cdot_register "$name" remove

  if git -C "$dir" push origin --delete "$branch" 2>/dev/null; then
    echo "✔ History for '$name' removed from remote."
  else
    echo "⚠  Could not delete remote branch (may not exist)."
  fi
  echo "   '$name' removed from history sync on this machine."
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
  tmp_index=$(mktemp "$dir/.git/cdot-compact-index.XXXXXX")
  trap "rm -f '$tmp_index'" RETURN
  GIT_INDEX_FILE="$tmp_index" git -C "$dir" add "projects/$project_dir/" 2>/dev/null
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

_cdot_list() {
  local dir="$CDOT_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cdot config"; return 1; }

  echo "Fetching remote refs..."
  git -C "$dir" fetch origin 2>/dev/null || true

  local host
  host=$(_cdot_machine_id)
  local found=false

  while IFS= read -r ref; do
    found=true
    local branch="${ref#refs/heads/}"
    local project="${branch#history/}"
    project="${project%/$host}"

    local project_dir
    project_dir=$(_cdot_project_dir "$project")

    local last_date
    last_date=$(git -C "$dir" log -1 --format="%ci" \
      "refs/remotes/origin/$branch" 2>/dev/null | cut -d' ' -f1)

    local size_mb="?"
    [[ -d "$dir/projects/$project_dir" ]] && \
      size_mb=$(du -sm "$dir/projects/$project_dir" 2>/dev/null | awk '{print $1}')

    local opted=""
    _cdot_is_opted_in "$project" && opted=" ✔"

    printf "  %-30s  last: %s  size: %smb%s\n" \
      "$project" "${last_date:-?}" "$size_mb" "$opted"
  done < <(git -C "$dir" ls-remote --heads origin "history/*/$host" 2>/dev/null \
    | awk '{print $2}')

  $found || echo "No history branches found for this machine."
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

    if [[ -n "${CDOT_SYNC_PROJECTS:-}" ]]; then
      echo "  history projects: $CDOT_SYNC_PROJECTS"
    else
      echo "  history projects: none (use: cdot add)"
    fi
  else
    echo "ℹ sync not configured (run: cdot config)"
  fi
}

_cdot_doctor() {
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
      _cdot_pull
      _cdot_push
      _cdot_pull_history "$name"
      _cdot_push_history "$name"
      ;;

    config)   _cdot_config ;;
    add)      _cdot_add "$name" ;;
    remove)   _cdot_remove "${2:-$name}" ;;
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cdot "$@"
fi
