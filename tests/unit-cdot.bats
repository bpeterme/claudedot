#!/usr/bin/env bats

CDOT_SH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/cdot.sh"

setup() {
  export HOME="$BATS_TMPDIR/home"
  mkdir -p "$HOME/.config/claudedot"
  export CDOT_CLAUDE_DIR="$BATS_TMPDIR/claude"
  mkdir -p "$CDOT_CLAUDE_DIR"
  # shellcheck source=/dev/null
  source "$CDOT_SH"
}

# ---------------------------------------------------------------------------
# cdot version
# ---------------------------------------------------------------------------

@test "cdot version: output starts with 'cdot '" {
  run cdot version
  [ "$status" -eq 0 ]
  [[ "$output" == "cdot "* ]]
}

# ---------------------------------------------------------------------------
# _cdot_project_dir
# ---------------------------------------------------------------------------

@test "_cdot_project_dir: prefixes name with -Workspace-" {
  run _cdot_project_dir "myproject"
  [ "$status" -eq 0 ]
  [ "$output" = "-Workspace-myproject" ]
}

@test "_cdot_project_dir: preserves hyphens in name" {
  run _cdot_project_dir "my-cool-project"
  [ "$status" -eq 0 ]
  [ "$output" = "-Workspace-my-cool-project" ]
}

# ---------------------------------------------------------------------------
# _cdot_history_branch
# ---------------------------------------------------------------------------

@test "_cdot_history_branch: returns history/<name>/<user>@<host>" {
  run _cdot_history_branch "myproject"
  [ "$status" -eq 0 ]
  [ "$output" = "history/myproject/${USER}@$(hostname -s)" ]
}

# ---------------------------------------------------------------------------
# _cdot_is_opted_in
# ---------------------------------------------------------------------------

@test "_cdot_is_opted_in: returns true when project is in list" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/opted-in-true"
  rm -rf "$CDOT_CLAUDE_DIR" && mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  git -C "$CDOT_CLAUDE_DIR" config user.email "t@t.com"
  git -C "$CDOT_CLAUDE_DIR" config user.name "T"
  git -C "$CDOT_CLAUDE_DIR" commit --allow-empty -m "test" 2>/dev/null
  local branch
  branch=$(_cdot_history_branch "bravo")
  git -C "$CDOT_CLAUDE_DIR" update-ref "refs/remotes/origin/$branch" \
    "$(git -C "$CDOT_CLAUDE_DIR" rev-parse HEAD)"
  run _cdot_is_opted_in "bravo"
  [ "$status" -eq 0 ]
}

@test "_cdot_is_opted_in: returns false when project is not in list" {
  CDOT_SYNC_PROJECTS="alpha charlie"
  run _cdot_is_opted_in "bravo"
  [ "$status" -ne 0 ]
}

@test "_cdot_is_opted_in: returns false when list is empty" {
  CDOT_SYNC_PROJECTS=""
  run _cdot_is_opted_in "bravo"
  [ "$status" -ne 0 ]
}

@test "_cdot_is_opted_in: does not match partial word" {
  CDOT_SYNC_PROJECTS="foobar"
  run _cdot_is_opted_in "foo"
  [ "$status" -ne 0 ]
}

@test "_cdot_is_opted_in: matches sole entry in list" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/opted-in-sole"
  rm -rf "$CDOT_CLAUDE_DIR" && mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  git -C "$CDOT_CLAUDE_DIR" config user.email "t@t.com"
  git -C "$CDOT_CLAUDE_DIR" config user.name "T"
  git -C "$CDOT_CLAUDE_DIR" commit --allow-empty -m "test" 2>/dev/null
  local branch
  branch=$(_cdot_history_branch "only")
  git -C "$CDOT_CLAUDE_DIR" update-ref "refs/remotes/origin/$branch" \
    "$(git -C "$CDOT_CLAUDE_DIR" rev-parse HEAD)"
  run _cdot_is_opted_in "only"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# _cdot_write_gitignore
# ---------------------------------------------------------------------------

@test "_cdot_write_gitignore: creates gitignore when absent" {
  local dir="$BATS_TMPDIR/gitignore-new"
  mkdir -p "$dir"
  _cdot_write_gitignore "$dir"
  [ -f "$dir/.gitignore" ]
}

@test "_cdot_write_gitignore: gitignore contains wildcard deny-all" {
  local dir="$BATS_TMPDIR/gitignore-content"
  mkdir -p "$dir"
  _cdot_write_gitignore "$dir"
  run grep -q "^\*$" "$dir/.gitignore"
  [ "$status" -eq 0 ]
}

@test "_cdot_write_gitignore: gitignore allows settings.json" {
  local dir="$BATS_TMPDIR/gitignore-allowlist"
  mkdir -p "$dir"
  _cdot_write_gitignore "$dir"
  run grep -q "^!settings.json" "$dir/.gitignore"
  [ "$status" -eq 0 ]
}

@test "_cdot_write_gitignore: gitignore does not allow projects/" {
  local dir="$BATS_TMPDIR/gitignore-no-projects"
  mkdir -p "$dir"
  _cdot_write_gitignore "$dir"
  run grep -q "projects/" "$dir/.gitignore"
  [ "$status" -ne 0 ]
}

@test "_cdot_write_gitignore: skips write when already correct" {
  local dir="$BATS_TMPDIR/gitignore-skip"
  mkdir -p "$dir"
  echo "correct" > "$dir/.gitignore"
  _cdot_write_gitignore "$dir"
  run cat "$dir/.gitignore"
  [ "$output" = "correct" ]
}

@test "_cdot_write_gitignore: overwrites old format containing !projects/" {
  local dir="$BATS_TMPDIR/gitignore-migrate"
  mkdir -p "$dir"
  printf '*\n!projects/\n!projects/**\n' > "$dir/.gitignore"
  _cdot_write_gitignore "$dir"
  run grep -q "^!projects/" "$dir/.gitignore"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# _cdot_exclude_symlinks
# ---------------------------------------------------------------------------

@test "_cdot_exclude_symlinks: no-op when .git does not exist" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/excl-no-git"
  mkdir -p "$CDOT_CLAUDE_DIR"
  run _cdot_exclude_symlinks
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_cdot_exclude_symlinks: adds symlink path to .git/info/exclude" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/excl-add"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  local target="$BATS_TMPDIR/real-settings.json"
  echo '{}' > "$target"
  ln -sf "$target" "$CDOT_CLAUDE_DIR/settings.json"
  _cdot_exclude_symlinks
  run grep -Fx "settings.json" "$CDOT_CLAUDE_DIR/.git/info/exclude"
  [ "$status" -eq 0 ]
}

@test "_cdot_exclude_symlinks: does not duplicate entry in exclude" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/excl-dedup"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  local target="$BATS_TMPDIR/real-settings-dedup.json"
  echo '{}' > "$target"
  ln -sf "$target" "$CDOT_CLAUDE_DIR/settings.json"
  _cdot_exclude_symlinks
  _cdot_exclude_symlinks
  run bash -c "grep -Fc 'settings.json' '$CDOT_CLAUDE_DIR/.git/info/exclude'"
  [ "$output" -eq 1 ]
}

@test "_cdot_exclude_symlinks: untracks a previously tracked symlink" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/excl-untrack"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  git -C "$CDOT_CLAUDE_DIR" config user.email "test@test.com"
  git -C "$CDOT_CLAUDE_DIR" config user.name "Test"
  local target="$BATS_TMPDIR/real-settings-untrack.json"
  echo '{}' > "$target"
  ln -sf "$target" "$CDOT_CLAUDE_DIR/settings.json"
  git -C "$CDOT_CLAUDE_DIR" add -f settings.json
  _cdot_exclude_symlinks
  run git -C "$CDOT_CLAUDE_DIR" ls-files "settings.json"
  [ -z "$output" ]
}

@test "_cdot_exclude_symlinks: warns about broken symlinks" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/excl-broken"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  ln -sf "/nonexistent/path/settings.json" "$CDOT_CLAUDE_DIR/settings.json"
  run _cdot_exclude_symlinks
  [[ "$output" == *"Broken symlink"* ]]
}

@test "_cdot_exclude_symlinks: no output for valid symlinks" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/excl-valid"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  local target="$BATS_TMPDIR/real-settings-valid.json"
  echo '{}' > "$target"
  ln -sf "$target" "$CDOT_CLAUDE_DIR/settings.json"
  run _cdot_exclude_symlinks
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# _cdot_unlink
# ---------------------------------------------------------------------------

@test "_cdot_unlink: reports not initialized when .git absent" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/unlink-no-git"
  mkdir -p "$CDOT_CLAUDE_DIR"
  run _cdot_unlink --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"not initialized"* ]]
}

@test "_cdot_unlink --force: removes .git directory" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/unlink-git"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  _cdot_unlink --force
  [ ! -d "$CDOT_CLAUDE_DIR/.git" ]
}

@test "_cdot_unlink --force: removes .gitignore" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/unlink-gitignore"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  echo "*" > "$CDOT_CLAUDE_DIR/.gitignore"
  _cdot_unlink --force
  [ ! -f "$CDOT_CLAUDE_DIR/.gitignore" ]
}


@test "_cdot_unlink: aborts without removing .git when user declines" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/unlink-abort"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  printf "n\n" | _cdot_unlink >/dev/null 2>&1 || true
  [ -d "$CDOT_CLAUDE_DIR/.git" ]
}

# ---------------------------------------------------------------------------
# _cdot_config
# ---------------------------------------------------------------------------

@test "_cdot_config: prompts for URL when no remote configured" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/config-no-remote"
  mkdir -p "$CDOT_CLAUDE_DIR"
  out=$(printf '\n' | _cdot_config 2>&1) || true
  [[ "$out" == *"Enter remote URL"* ]]
}

@test "_cdot_config: aborts when empty URL entered" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/config-empty-url"
  mkdir -p "$CDOT_CLAUDE_DIR"
  out=$(printf '\n' | _cdot_config 2>&1) || true
  [[ "$out" == *"Aborted"* ]]
}

@test "_cdot_config: shows remote when already configured" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/config-has-remote"
  rm -rf "$CDOT_CLAUDE_DIR" && mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  git -C "$CDOT_CLAUDE_DIR" remote add origin "https://example.com/repo.git"
  out=$(printf 'n\n' | _cdot_config 2>&1) || true
  [[ "$out" == *"https://example.com/repo.git"* ]]
}

@test "_cdot_config: keeps remote when user declines unlink" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/config-keep-remote"
  rm -rf "$CDOT_CLAUDE_DIR" && mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  git -C "$CDOT_CLAUDE_DIR" remote add origin "https://example.com/repo.git"
  printf "n\n" | _cdot_config >/dev/null 2>&1 || true
  run git -C "$CDOT_CLAUDE_DIR" remote get-url origin
  [ "$status" -eq 0 ]
  [[ "$output" == "https://example.com/repo.git" ]]
}

@test "_cdot_config: unlinks when user confirms" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/config-unlink"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  git -C "$CDOT_CLAUDE_DIR" remote add origin "https://example.com/repo.git"
  printf "y\n" | bash -c "source '$BATS_TEST_DIRNAME/../cdot.sh' 2>/dev/null; CDOT_CLAUDE_DIR='$CDOT_CLAUDE_DIR' _cdot_config" >/dev/null 2>&1 || true
  [ ! -d "$CDOT_CLAUDE_DIR/.git" ]
}

# ---------------------------------------------------------------------------
# _cdot_add guard conditions
# ---------------------------------------------------------------------------

@test "_cdot_add: reports not initialized when .git absent" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/add-no-git"
  mkdir -p "$CDOT_CLAUDE_DIR"
  run _cdot_add "myproject"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not initialized"* ]]
}

@test "_cdot_add: reports already opted in when project is in list" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/add-opted-in"
  local fake_remote="$BATS_TMPDIR/add-opted-in-remote.git"
  rm -rf "$CDOT_CLAUDE_DIR" "$fake_remote"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git init --bare "$fake_remote" 2>/dev/null
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  git -C "$CDOT_CLAUDE_DIR" config user.email "t@t.com"
  git -C "$CDOT_CLAUDE_DIR" config user.name "T"
  git -C "$CDOT_CLAUDE_DIR" remote add origin "$fake_remote"
  git -C "$CDOT_CLAUDE_DIR" commit --allow-empty -m "test" 2>/dev/null
  local branch head
  branch=$(_cdot_history_branch "myproject")
  head=$(git -C "$CDOT_CLAUDE_DIR" rev-parse HEAD)
  git -C "$CDOT_CLAUDE_DIR" push origin "$head:refs/heads/$branch" 2>/dev/null
  run _cdot_add "myproject"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already opted into"* ]]
}

@test "_cdot_add: reports failure and suggests reconfigure when remote is wrong" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/add-push-fail"
  rm -rf "$CDOT_CLAUDE_DIR"
  mkdir -p "$CDOT_CLAUDE_DIR/projects/-Workspace-myproject"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  git -C "$CDOT_CLAUDE_DIR" config user.email "test@test.com"
  git -C "$CDOT_CLAUDE_DIR" config user.name "Test"
  git -C "$CDOT_CLAUDE_DIR" remote add origin "/tmp/nonexistent-cdot-remote-$$"
  run _cdot_add "myproject"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to opt"* ]]
  [[ "$output" == *"reconfigure"* ]]
}

# ---------------------------------------------------------------------------
# _cdot_remove guard conditions
# ---------------------------------------------------------------------------

@test "_cdot_remove: reports not initialized when .git absent" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/remove-no-git"
  mkdir -p "$CDOT_CLAUDE_DIR"
  run _cdot_remove "myproject"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not initialized"* ]]
}

@test "_cdot_remove: reports not opted in when project not in list" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/remove-not-opted"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  CDOT_SYNC_PROJECTS=""
  run _cdot_remove "myproject"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not opted into history sync"* ]]
}

# ---------------------------------------------------------------------------
# _cdot_compact guard conditions
# ---------------------------------------------------------------------------

@test "_cdot_compact: reports not initialized when .git absent" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/compact-no-git"
  mkdir -p "$CDOT_CLAUDE_DIR"
  run _cdot_compact "myproject"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not initialized"* ]]
}

@test "_cdot_compact: reports not opted in when project not in list" {
  CDOT_CLAUDE_DIR="$BATS_TMPDIR/compact-not-opted"
  mkdir -p "$CDOT_CLAUDE_DIR"
  git -C "$CDOT_CLAUDE_DIR" init 2>/dev/null
  CDOT_SYNC_PROJECTS=""
  run _cdot_compact "myproject"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not opted into history sync"* ]]
}
