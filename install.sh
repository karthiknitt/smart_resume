#!/usr/bin/env bash
# Smart Resume for Claude Code — installer
# by Karthikeyan N · MIT License
#
# Usage:
#   git clone https://github.com/karthiknitt/smart_resume.git
#   cd smart_resume && ./install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
WRAPPER_NAME="claude-smart-resume.sh"   # destination — always the same name
STATUSLINE_NAME="statusline.sh"

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_platform() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "wsl"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    echo "macos"
  else
    echo "linux"
  fi
}

PLATFORM=$(detect_platform)
case "$PLATFORM" in
  wsl)   PLATFORM_LABEL="WSL (Windows Subsystem for Linux)"
         WRAPPER_SRC="claude-smart-resume-wsl.sh" ;;
  macos) PLATFORM_LABEL="macOS"
         WRAPPER_SRC="claude-smart-resume-macos.sh" ;;
  *)     PLATFORM_LABEL="Linux"
         WRAPPER_SRC="claude-smart-resume.sh" ;;
esac

# Guard: abort early if platform script not bundled yet
if [[ ! -f "${REPO_DIR}/src/${WRAPPER_SRC}" ]]; then
  printf '\n  \e[31m✗\e[0m macOS support is not yet available. Coming in v0.3.\n'
  printf '    See: https://github.com/karthiknitt/smart_resume/releases\n\n'
  exit 1
fi

# ---------------------------------------------------------------------------
# ANSI helpers
# ---------------------------------------------------------------------------
_bold()   { printf '\e[1m%s\e[0m' "$*"; }
_green()  { printf '\e[32m%s\e[0m' "$*"; }
_yellow() { printf '\e[33m%s\e[0m' "$*"; }
_cyan()   { printf '\e[36m%s\e[0m' "$*"; }
_red()    { printf '\e[31m%s\e[0m' "$*"; }
_dim()    { printf '\e[2m%s\e[0m' "$*"; }

# BAR width = visual width of header content (no emoji — emoji width is
# terminal-dependent and breaks alignment):
#   "  Smart Resume Installer  ·  Karthikeyan N  ·  MIT License  "
#    2 + 22 + 2 + 1 + 2 + 13 + 2 + 1 + 2 + 11 + 2 = 60
BAR='────────────────────────────────────────────────────────────'  # 60 chars

header() {
  printf '\n'
  printf "  \e[36m╭%s╮\e[0m\n" "$BAR"
  printf "  \e[36m│\e[0m  \e[1;97mSmart Resume Installer\e[0m  \e[2m·\e[0m  \e[97mKarthikeyan N\e[0m  \e[2m·\e[0m  \e[2mMIT License\e[0m  \e[36m│\e[0m\n"
  printf "  \e[36m╰%s╯\e[0m\n" "$BAR"
  printf '\n'
}

step()    { printf "  $(_cyan '→') %s\n" "$*"; }
ok()      { printf "  $(_green '✓') %s\n" "$*"; }
warn()    { printf "  $(_yellow '⚠') %s\n" "$*"; }
err()     { printf "  $(_red '✗') %s\n" "$*"; }
info()    { printf "  $(_dim '·') %s\n" "$*"; }

# ---------------------------------------------------------------------------
# Step 0 — Check dependencies
#
# Never runs sudo. If anything is missing, prints the exact install command
# the user should run (with sudo where required) and exits cleanly.
# The user installs the deps, then re-runs ./install.sh.
# ---------------------------------------------------------------------------
check_dependencies() {
  step "Checking dependencies..."

  local missing=()

  # jq — required to auto-patch ~/.claude/settings.json with the statusLine hook
  command -v jq      &>/dev/null || missing+=("jq")

  # python3 — macOS only: parse_reset_epoch uses stdlib datetime (BSD date lacks -d)
  if [[ "$PLATFORM" == "macos" ]]; then
    command -v python3 &>/dev/null || missing+=("python3")
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "All dependencies present."
    return 0
  fi

  err "Missing: ${missing[*]}"
  printf '\n'

  # Build the install command for the detected package manager.
  # brew does not require sudo; all others do — we print but never run the command.
  local install_cmd=""
  if   command -v apt-get &>/dev/null; then
    install_cmd="sudo apt-get install -y ${missing[*]}"
  elif command -v dnf     &>/dev/null; then
    install_cmd="sudo dnf install -y ${missing[*]}"
  elif command -v pacman  &>/dev/null; then
    install_cmd="sudo pacman -S --noconfirm ${missing[*]}"
  elif command -v brew    &>/dev/null; then
    install_cmd="brew install ${missing[*]}"
  fi

  if [[ -n "$install_cmd" ]]; then
    printf '  Install the missing packages with:\n\n'
    printf '    \e[1m%s\e[0m\n\n' "$install_cmd"
  else
    printf '  No supported package manager detected.\n'
    printf '  Install these packages manually: \e[1m%s\e[0m\n\n' "${missing[*]}"
  fi

  printf '  Then re-run this installer:\n\n'
  printf '    \e[1m./install.sh\e[0m\n\n'
  exit 1
}

# ---------------------------------------------------------------------------
# Step 1 — Detect CLAUDE_BIN
# ---------------------------------------------------------------------------
detect_claude_bin() {
  step "Detecting Claude Code binary path..."
  info "Detected platform: $(_bold "$PLATFORM_LABEL")"

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

  cp "${REPO_DIR}/src/${WRAPPER_SRC}"    "${CLAUDE_DIR}/${WRAPPER_NAME}"
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

  # Detect the user's login shell and pick the right RC file
  local active_shell
  active_shell=$(basename "${SHELL:-}")

  local shell_rc=""
  case "$active_shell" in
    zsh)
      shell_rc="${HOME}/.zshrc"
      ;;
    bash)
      # macOS bash uses .bash_profile; Linux/WSL uses .bashrc
      if [[ -f "${HOME}/.bash_profile" && "$(uname -s)" == "Darwin" ]]; then
        shell_rc="${HOME}/.bash_profile"
      else
        shell_rc="${HOME}/.bashrc"
      fi
      ;;
    *)
      warn "Shell '$(_bold "$active_shell")' not recognised. Add the alias manually:"
      printf '\n'
      printf '    alias claude="%s/.claude/%s"\n\n' "$HOME" "$WRAPPER_NAME"
      return
      ;;
  esac

  info "Detected shell: $(_bold "$active_shell") → $(_bold "$shell_rc")"

  local alias_line="alias claude=\"\$HOME/.claude/${WRAPPER_NAME}\""

  # Idempotency: skip if already present
  if grep -qF "${CLAUDE_DIR}/${WRAPPER_NAME}" "$shell_rc" 2>/dev/null; then
    ok "Alias already in $(_bold "$shell_rc") — skipping."
    return
  fi

  printf '\n'
  printf '  Add this alias to %s?\n' "$(_bold "$shell_rc")"
  printf '    %s\n' "$(_dim "$alias_line")"
  printf '\n'
  printf '  [Y/n] '
  local answer
  read -r answer
  answer="${answer:-y}"

  if [[ "${answer,,}" == y* ]]; then
    printf '\n# Smart Resume for Claude Code\n%s\n' "$alias_line" >> "$shell_rc"
    ok "Alias added to $(_bold "$shell_rc")"
    # Attempt to activate immediately. Works when this installer is sourced
    # (source ./install.sh); in a subprocess it loads the alias for this
    # process only — new terminals will pick it up automatically.
    # shellcheck disable=SC1090
    if source "$shell_rc" 2>/dev/null; then
      ok "Alias sourced — active in new terminals and any sourced session"
    else
      info "Open a new terminal to activate, or run: $(_bold "source $shell_rc")"
    fi
  else
    warn "Alias skipped. Add manually when ready:"
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
  # Completion box: content is "  ✓ Installation complete!  " = 28 visible chars.
  # BAR = 54 chars, so right-pad with (54 - 28) = 26 spaces to close the box cleanly.
  local DONE_BAR='────────────────────────────'   # 28 dashes = width of box content
  printf '\n'
  printf "  \e[36m╭%s╮\e[0m\n" "$DONE_BAR"
  printf "  \e[36m│\e[0m  \e[1;32m✓ Installation complete!\e[0m  \e[36m│\e[0m\n"
  printf "  \e[36m╰%s╯\e[0m\n" "$DONE_BAR"
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
  check_dependencies
  detect_claude_bin
  copy_scripts
  patch_claude_bin
  add_alias
  patch_settings_json
  print_summary
}

main "$@"
