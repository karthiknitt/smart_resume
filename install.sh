#!/usr/bin/env bash
# Smart Resume for Claude Code — installer
# by Karthikeyan N · MIT License
#
# Usage:
#   ./install.sh
#
# Or one-liner (from the repo root):
#   bash <(curl -fsSL https://raw.githubusercontent.com/karthiknitt/smart_resume/main/install.sh)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
WRAPPER_NAME="claude-smart-resume.sh"
STATUSLINE_NAME="statusline.sh"

# ---------------------------------------------------------------------------
# ANSI helpers
# ---------------------------------------------------------------------------
_bold()   { printf '\e[1m%s\e[0m' "$*"; }
_green()  { printf '\e[32m%s\e[0m' "$*"; }
_yellow() { printf '\e[33m%s\e[0m' "$*"; }
_cyan()   { printf '\e[36m%s\e[0m' "$*"; }
_red()    { printf '\e[31m%s\e[0m' "$*"; }
_dim()    { printf '\e[2m%s\e[0m' "$*"; }

BAR='──────────────────────────────────────────────────────'

header() {
  printf '\n'
  printf "  \e[36m╭%s╮\e[0m\n" "$BAR"
  printf "  \e[36m│\e[0m  \e[1;97m⚡ Smart Resume Installer\e[0m  \e[2m·\e[0m  \e[97mKarthikeyan N\e[0m  \e[2m·\e[0m  \e[2mMIT License\e[0m  \e[36m│\e[0m\n"
  printf "  \e[36m╰%s╯\e[0m\n" "$BAR"
  printf '\n'
}

step()    { printf "  $(_cyan '→') %s\n" "$*"; }
ok()      { printf "  $(_green '✓') %s\n" "$*"; }
warn()    { printf "  $(_yellow '⚠') %s\n" "$*"; }
err()     { printf "  $(_red '✗') %s\n" "$*"; }
info()    { printf "  $(_dim '·') %s\n" "$*"; }

# ---------------------------------------------------------------------------
# Step 1 — Detect CLAUDE_BIN
# ---------------------------------------------------------------------------
detect_claude_bin() {
  step "Detecting Claude Code binary path..."

  # If we're running inside the wrapper alias, `which claude` would return the
  # wrapper itself. Use `command -v` on the real binary via PATH lookup only.
  local bin
  bin=$(command -v claude 2>/dev/null || true)

  # Reject the wrapper itself — it lives in ~/.claude/
  if [[ "$bin" == "${CLAUDE_DIR}/${WRAPPER_NAME}" ]]; then
    # Try to find the real binary by looking at PATH entries
    bin=$(IFS=:; for d in $PATH; do
      [[ "$d" == "$CLAUDE_DIR" ]] && continue
      [[ -x "$d/claude" ]] && echo "$d/claude" && break
    done)
  fi

  if [[ -z "$bin" || ! -x "$bin" ]]; then
    err "Claude Code binary not found in PATH."
    printf '\n'
    printf '  Please install Claude Code first:\n'
    printf '    https://docs.anthropic.com/en/docs/claude-code\n'
    printf '\n'
    printf '  Then re-run this installer.\n\n'
    exit 1
  fi

  CLAUDE_BIN="$bin"
  ok "Found Claude at: $(_bold "$CLAUDE_BIN")"
}

# ---------------------------------------------------------------------------
# Step 2 — Copy scripts to ~/.claude/
# ---------------------------------------------------------------------------
copy_scripts() {
  step "Copying scripts to $(_bold "$CLAUDE_DIR/")..."

  mkdir -p "$CLAUDE_DIR"

  cp "${REPO_DIR}/src/${WRAPPER_NAME}"   "${CLAUDE_DIR}/${WRAPPER_NAME}"
  cp "${REPO_DIR}/src/${STATUSLINE_NAME}" "${CLAUDE_DIR}/${STATUSLINE_NAME}"

  chmod +x "${CLAUDE_DIR}/${WRAPPER_NAME}"
  chmod +x "${CLAUDE_DIR}/${STATUSLINE_NAME}"

  ok "Copied $WRAPPER_NAME"
  ok "Copied $STATUSLINE_NAME"
}

# ---------------------------------------------------------------------------
# Step 3 — Patch CLAUDE_BIN inside the installed wrapper
# ---------------------------------------------------------------------------
patch_claude_bin() {
  step "Patching CLAUDE_BIN in wrapper..."

  local target="${CLAUDE_DIR}/${WRAPPER_NAME}"

  # Replace the CLAUDE_BIN=... line in the installed script
  sed -i "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"${CLAUDE_BIN}\"|" "$target"

  ok "CLAUDE_BIN set to: $(_bold "$CLAUDE_BIN")"
}

# ---------------------------------------------------------------------------
# Step 4 — Patch statusline.sh path in wrapper
# ---------------------------------------------------------------------------
patch_statusline_path() {
  local target="${CLAUDE_DIR}/${WRAPPER_NAME}"
  # The statusline.sh is referenced in settings.json, not in the wrapper itself.
  # Nothing to patch here — statusline.sh is a standalone hook.
  :
}

# ---------------------------------------------------------------------------
# Step 5 — Detect shell and offer alias
# ---------------------------------------------------------------------------
add_alias() {
  step "Configuring shell alias..."

  # Detect the user's preferred shell config file
  local shell_rc=""
  if [[ "${SHELL}" == */zsh ]]; then
    shell_rc="${HOME}/.zshrc"
  elif [[ "${SHELL}" == */bash ]]; then
    shell_rc="${HOME}/.bashrc"
  fi

  local alias_line="alias claude=\"\$HOME/.claude/${WRAPPER_NAME}\""

  if [[ -z "$shell_rc" ]]; then
    warn "Could not detect shell (SHELL=${SHELL:-unset}). Add the alias manually:"
    printf '\n'
    printf '    %s\n\n' "$alias_line"
    return
  fi

  # Idempotency: skip if already present
  if grep -qF "${CLAUDE_DIR}/${WRAPPER_NAME}" "$shell_rc" 2>/dev/null; then
    ok "Alias already present in $(_bold "$shell_rc") — skipping."
    return
  fi

  printf '\n'
  printf "  Add this alias to $(_bold "$shell_rc")?\n"
  printf '    %s\n' "$(_dim "$alias_line")"
  printf '\n'
  printf '  [Y/n] '
  local answer
  read -r answer
  answer="${answer:-y}"

  if [[ "${answer,,}" == y* ]]; then
    printf '\n# Smart Resume for Claude Code\n%s\n' "$alias_line" >> "$shell_rc"
    ok "Alias added to $shell_rc"
    info "Run: $(_bold "source $shell_rc") to activate now"
  else
    warn "Alias skipped. Add it manually when ready:"
    printf '    %s\n' "$alias_line"
  fi
}

# ---------------------------------------------------------------------------
# Step 6 — Patch ~/.claude/settings.json with statusLine hook
# ---------------------------------------------------------------------------
patch_settings_json() {
  step "Configuring statusLine hook in settings.json..."

  local settings_file="${CLAUDE_DIR}/settings.json"
  local statusline_path="${CLAUDE_DIR}/${STATUSLINE_NAME}"

  # Ensure settings.json exists
  if [[ ! -f "$settings_file" ]]; then
    printf '{}' > "$settings_file"
  fi

  # Check if jq is available
  if ! command -v jq &>/dev/null; then
    warn "jq not found — cannot auto-patch settings.json."
    printf '\n'
    printf '  Add this to %s manually:\n' "$settings_file"
    printf '    "statusLine": {\n'
    printf '      "type": "command",\n'
    printf '      "command": "%s"\n' "$statusline_path"
    printf '    }\n\n'
    return
  fi

  # Idempotency: only patch if statusLine key is missing or has different command
  local existing_cmd
  existing_cmd=$(jq -r '.statusLine.command // ""' "$settings_file" 2>/dev/null || true)

  if [[ "$existing_cmd" == "$statusline_path" ]]; then
    ok "statusLine hook already configured — skipping."
    return
  fi

  if [[ -n "$existing_cmd" && "$existing_cmd" != "$statusline_path" ]]; then
    warn "statusLine is already configured (command: $existing_cmd)."
    printf '\n'
    printf '  Overwrite with Smart Resume statusline?\n'
    printf '  [y/N] '
    local answer
    read -r answer
    answer="${answer:-n}"
    [[ "${answer,,}" != y* ]] && { info "statusLine left unchanged."; return; }
  fi

  # Patch via jq (idempotent — merges, doesn't overwrite other keys)
  local tmp
  tmp=$(mktemp)
  jq --arg cmd "$statusline_path" \
    '.statusLine = {"type": "command", "command": $cmd}' \
    "$settings_file" > "$tmp" && mv "$tmp" "$settings_file"

  ok "statusLine hook set to: $(_bold "$statusline_path")"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  printf '\n'
  printf "  \e[36m╭%s╮\e[0m\n" "$BAR"
  printf "  \e[36m│\e[0m  \e[1;32m✓ Installation complete!\e[0m\n"
  printf "  \e[36m╰%s╯\e[0m\n" "$BAR"
  printf '\n'
  printf '  Files installed:\n'
  printf '    %s\n' "$(_bold "${CLAUDE_DIR}/${WRAPPER_NAME}")"
  printf '    %s\n' "$(_bold "${CLAUDE_DIR}/${STATUSLINE_NAME}")"
  printf '\n'
  printf '  To verify the alias is active:\n'
  printf '    %s\n' "$(_dim 'type claude')"
  printf '    %s\n' "$(_dim "# should show: claude is an alias for ${HOME}/.claude/${WRAPPER_NAME}")"
  printf '\n'
  printf '  To opt out for a single command:\n'
  printf '    %s\n' "$(_dim 'command claude [args]')"
  printf '\n'
  printf '  Docs: %s\n' "https://github.com/karthiknitt/smart_resume"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  header
  detect_claude_bin
  copy_scripts
  patch_claude_bin
  add_alias
  patch_settings_json
  print_summary
}

main "$@"
