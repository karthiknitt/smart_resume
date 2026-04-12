#!/usr/bin/env zsh
# ~/.claude/claude-smart-resume-wsl.sh
#
# Smart Resume for Claude Code — by Karthikeyan N
# MIT License
#
# WSL (Windows Subsystem for Linux) version of the rate-limit auto-resume wrapper.
#
# WSL runs a full Linux kernel, so this is functionally identical to the Linux
# version. The only WSL-specific considerations are where Claude stores sessions:
#
#   Option A — Claude installed natively inside WSL (most common):
#     Sessions: ~/.claude/projects/   (inside WSL)
#     Binary:   ~/.local/bin/claude   (or /usr/local/bin/claude)
#
#   Option B — Windows Claude Code app called via WSL path interop:
#     Sessions: /mnt/c/Users/<Name>/AppData/Roaming/Claude/projects/
#     Binary:   /mnt/c/Users/<Name>/AppData/Local/AnthropicClaude/claude.exe
#
# Run `which claude` and `ls ~/.claude/projects/` to confirm which applies.
#
# Setup (add to ~/.zshrc inside WSL):
#   alias claude="$HOME/.claude/claude-smart-resume-wsl.sh"

# ---------------------------------------------------------------------------
# CONFIGURE THESE for your WSL setup
# ---------------------------------------------------------------------------

# Option A — Claude installed natively inside WSL (most common):
CLAUDE_BIN="${HOME}/.local/bin/claude"
PROJECTS_DIR="${HOME}/.claude/projects"

# Option B — Windows Claude binary via WSL interop (uncomment if needed):
# WIN_USER="YourWindowsUsername"
# CLAUDE_BIN="/mnt/c/Users/${WIN_USER}/AppData/Local/AnthropicClaude/claude.exe"
# PROJECTS_DIR="/mnt/c/Users/${WIN_USER}/AppData/Roaming/Claude/projects"

# ---------------------------------------------------------------------------
BUFFER_SECS=60

# ANSI helpers — all write to stderr so they never corrupt --print output
_bold()    { printf '\e[1m%s\e[0m'    "$*" >&2; }
_dim()     { printf '\e[2m%s\e[0m'    "$*" >&2; }
_yellow()  { printf '\e[33m%s\e[0m'   "$*" >&2; }
_green()   { printf '\e[32m%s\e[0m'   "$*" >&2; }
_cyan()    { printf '\e[36m%s\e[0m'   "$*" >&2; }
_red()     { printf '\e[31m%s\e[0m'   "$*" >&2; }
_magenta() { printf '\e[35m%s\e[0m'   "$*" >&2; }
_white()   { printf '\e[1;97m%s\e[0m' "$*" >&2; }
_nl()      { printf '\n' >&2; }

# ---------------------------------------------------------------------------
find_latest_session() {
  local encoded_cwd
  encoded_cwd=$(pwd | sed 's|/|-|g; s|^-||')
  local session_dir="${PROJECTS_DIR}/${encoded_cwd}"
  if [[ -d "$session_dir" ]]; then
    find "$session_dir" -maxdepth 1 -name "*.jsonl" -type f \
      -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
  else
    find "$PROJECTS_DIR" -maxdepth 2 -name "*.jsonl" -type f \
      -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
  fi
}

get_reset_info() {
  local session_file="$1"
  local reset_line
  reset_line=$(grep -i 'resets .*(' "$session_file" 2>/dev/null | tail -1)
  [[ -z "$reset_line" ]] && return 0

  local reset_time reset_tz
  # (?i) inline flag makes the extraction pattern case-insensitive (handles RESETS)
  reset_time=$(echo "$reset_line" | grep -oP '(?i)resets \K[^(]+' | sed 's/[[:space:]]*$//')
  reset_tz=$(echo "$reset_line"   | grep -oP '\([^)]+\)' | tr -d '()')

  [[ -n "$reset_time" && -n "$reset_tz" ]] && echo "${reset_time} ${reset_tz}" || true
}

# Use grep -F + grep -oP — never use `strings` on JSONL (can split JSON objects)
get_session_name() {
  grep -F '"type":"custom-title"' "$1" 2>/dev/null \
    | tail -1 \
    | grep -oP '"customTitle":"\K[^"]+' || true
}

name_session() {
  local session_file="$1" session_id="$2" name="$3"
  printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' \
    "$name" "$session_id" >> "$session_file"
}

generate_name() {
  local date_tag cwd_slug
  date_tag=$(date '+%Y-%m-%d')
  cwd_slug=$(pwd | awk -F/ '{n=NF; if(n>=2) printf "%s-%s", $(n-1), $n; else print $n}' \
    | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')
  echo "rl-${date_tag}-${cwd_slug}"
}

parse_reset_epoch() {
  local reset_time="$1" reset_tz="$2"
  local reset_epoch now_epoch
  reset_epoch=$(TZ="$reset_tz" date -d "$reset_time" +%s 2>/dev/null) || return 1
  now_epoch=$(date +%s)
  if (( reset_epoch <= now_epoch )); then
    # Use :l (zsh lowercase modifier) to make AM/PM check case-insensitive
    if [[ "${reset_time:l}" =~ ^[0-9]+:[0-9]+[apm]+$ ]]; then
      reset_epoch=$(( reset_epoch + 86400 ))
    else
      return 1
    fi
  fi
  echo "$reset_epoch"
}

# ---------------------------------------------------------------------------
# Live countdown — updates a single line every second (no scrolling)
# ---------------------------------------------------------------------------
show_countdown() {
  local wake_epoch="$1" session_name="$2" session_id="$3"
  local resume_at
  resume_at=$(date -d "@${wake_epoch}" '+%H:%M %Z')

  trap '
    printf "\r\e[2K" >&2
    printf "\n  \e[33mCancelled.\e[0m Resume manually when limits clear:\n" >&2
    printf "    claude --resume %s\n\n" "'"$session_id"'" >&2
    exit 0
  ' INT

  while true; do
    local now remaining hrs mins secs
    now=$(date +%s)
    remaining=$(( wake_epoch - now ))
    (( remaining <= 0 )) && break

    hrs=$(( remaining / 3600 ))
    mins=$(( (remaining % 3600) / 60 ))
    secs=$(( remaining % 60 ))

    if (( hrs > 0 )); then
      printf '\r\e[2K  \e[33m↻ %d:%02d:%02d remaining — resuming "%s" at %s\e[0m' \
        "$hrs" "$mins" "$secs" "$session_name" "$resume_at" >&2
    else
      printf '\r\e[2K  \e[33m↻ %d:%02d remaining — resuming "%s" at %s\e[0m' \
        "$mins" "$secs" "$session_name" "$resume_at" >&2
    fi

    sleep 1
  done

  printf '\r\e[2K' >&2
  trap - INT
}

# ---------------------------------------------------------------------------
# RL watcher — two-phase design.
# Phase 1: cheap flag-file poll every 5 s (waits for statusline RL >= 90%).
# Phase 2: JSONL poll every 2 s once flag appears; sends SIGINT on detection.
# ---------------------------------------------------------------------------
_rl_watcher() {
  local claude_pid=$1
  local rl_warn_flag="${HOME}/.claude/.rl_warn"

  while kill -0 "$claude_pid" 2>/dev/null; do
    [[ -f "$rl_warn_flag" ]] && break
    sleep 5
  done
  kill -0 "$claude_pid" 2>/dev/null || return

  local session_file='' i=0
  while (( i++ < 15 )) && [[ -z "$session_file" ]]; do
    sleep 1
    session_file=$(find_latest_session)
  done
  [[ -z "$session_file" ]] && return

  local baseline
  baseline=$(wc -l < "$session_file" 2>/dev/null || echo 0)

  while kill -0 "$claude_pid" 2>/dev/null; do
    sleep 2
    local current
    current=$(wc -l < "$session_file" 2>/dev/null || echo 0)
    (( current <= baseline )) && continue

    if tail -n +"$(( baseline + 1 ))" "$session_file" 2>/dev/null \
        | grep -qi 'resets .*('; then
      sleep 0.3
      kill -INT "$claude_pid" 2>/dev/null
      return
    fi
  done
}

# ---------------------------------------------------------------------------
# Run claude in the foreground with a silent background watcher.
#
# WSL has /proc (Linux kernel), so we use /proc/self/stat to get the
# watcher subshell's own PID and /proc/PID/task/PID/children for child
# discovery — same approach as the Linux version.
# ---------------------------------------------------------------------------
_run_claude() {
  rm -f "${HOME}/.claude/.rl_warn"
  local my_pid=$$

  (
    # /proc/self/stat first field = this subshell's PID (read builtin resolves
    # /proc/self in-process, not as a child — gives the subshell's actual PID)
    local watcher_self=0 _stat_line
    read -r _stat_line < /proc/self/stat 2>/dev/null \
      && watcher_self=${_stat_line%% *}
    # Fallback: sh -c 'echo $PPID' (PPID of child sh = this subshell)
    (( watcher_self == 0 )) && watcher_self=$(sh -c 'echo $PPID' 2>/dev/null || echo 0)

    local claude_pid='' i=0
    while (( i++ < 200 )) && [[ -z "$claude_pid" ]]; do
      local raw=''
      read -r raw < "/proc/${my_pid}/task/${my_pid}/children" 2>/dev/null \
        || raw=$(pgrep -d' ' -P "$my_pid" 2>/dev/null) || true
      for pid in ${=raw}; do
        [[ "$pid" == "$watcher_self" ]] && continue
        claude_pid=$pid; break
      done
      [[ -z "$claude_pid" ]] && sleep 0.05
    done

    [[ -n "$claude_pid" ]] && _rl_watcher "$claude_pid"
  ) > /dev/null 2>/dev/null &
  local watcher_pid=$!

  # 'true' not '' — Node.js resets inherited signal handlers on exec,
  # so SIGINT still reaches claude; the wrapper catches it and moves on.
  trap 'true' INT
  "$CLAUDE_BIN" "$@"
  trap - INT

  kill "$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Main loop: run claude, detect RL on exit, wait, resume
# ---------------------------------------------------------------------------
resume_id=""
resume_msg="Rate limits have reset — continuing where we left off."

while true; do
  if [[ -z "$resume_id" ]]; then
    _run_claude "$@"
  else
    _run_claude --resume "$resume_id" "$resume_msg"
  fi

  local session_file
  session_file=$(find_latest_session)
  [[ -z "$session_file" || ! -f "$session_file" ]] && break

  # Fast path: statusline hook pre-computed epochs into the flag file.
  # Fallback: grep+parse the JSONL.
  local reset_epoch=""
  local rl_warn_flag="${HOME}/.claude/.rl_warn"

  if [[ -f "$rl_warn_flag" ]]; then
    local rl_5h_pct rl_5h_reset rl_7d_pct rl_7d_reset
    rl_5h_pct=$(grep   '^5h_pct='   "$rl_warn_flag" | cut -d= -f2)
    rl_5h_reset=$(grep '^5h_reset=' "$rl_warn_flag" | cut -d= -f2)
    rl_7d_pct=$(grep   '^7d_pct='   "$rl_warn_flag" | cut -d= -f2)
    rl_7d_reset=$(grep '^7d_reset=' "$rl_warn_flag" | cut -d= -f2)
    if (( ${rl_5h_pct:-0} >= ${rl_7d_pct:-0} )); then
      reset_epoch=${rl_5h_reset:-0}
    else
      reset_epoch=${rl_7d_reset:-0}
    fi
    (( reset_epoch <= 0 )) && reset_epoch=""
  fi

  if [[ -z "$reset_epoch" ]]; then
    local reset_info
    reset_info=$(get_reset_info "$session_file")
    [[ -z "$reset_info" ]] && break

    local reset_time reset_tz
    reset_time=$(echo "$reset_info" | awk '{print $1}')
    reset_tz=$(echo "$reset_info"   | awk '{print $2}')
    reset_epoch=$(parse_reset_epoch "$reset_time" "$reset_tz") || break
  fi

  local wake_epoch=$(( reset_epoch + BUFFER_SECS ))

  local session_id
  session_id=$(basename "$session_file" .jsonl)

  local session_name
  session_name=$(get_session_name "$session_file")
  if [[ -z "$session_name" ]]; then
    session_name=$(generate_name)
    name_session "$session_file" "$session_id" "$session_name"
  fi

  local sleep_secs=$(( wake_epoch - $(date +%s) ))

  local _bar='──────────────────────────────────────────────────────'
  printf '\n' >&2
  printf '  \e[36m╭%s╮\e[0m\n' "$_bar" >&2
  printf '  \e[36m│\e[0m  \e[1;97m⚡ Smart Resume\e[0m  \e[2m·\e[0m  \e[97mKarthikeyan N\e[0m  \e[2m·\e[0m  \e[2mMIT License\e[0m  \e[36m│\e[0m\n' >&2
  printf '  \e[36m╰%s╯\e[0m\n' "$_bar" >&2
  printf '\n' >&2
  printf '  \e[1;33m⚡ Rate limit hit\e[0m\n' >&2
  printf '  \e[2m%s\e[0m\n' "$_bar" >&2
  printf '  \e[2mSession\e[0m  \e[33m"%s"\e[0m\n'  "$session_name" >&2
  printf '  \e[2mResets \e[0m  \e[32m%s\e[0m\n'    "$(date -d "@${reset_epoch}" '+%H:%M:%S %Z  (%Y-%m-%d)')" >&2
  printf '  \e[2mWaking \e[0m  \e[32m%s\e[0m  \e[2m(+%ds buffer)\e[0m\n' \
    "$(date -d "@${wake_epoch}" '+%H:%M:%S %Z')" "$BUFFER_SECS" >&2
  printf '  \e[2mWait   \e[0m  \e[33m%ds  (%d min)\e[0m\n' "$sleep_secs" "$(( sleep_secs / 60 ))" >&2
  printf '  \e[2m%s\e[0m\n' "$_bar" >&2
  printf '  \e[2mPress Ctrl-C to cancel\e[0m\n' >&2
  printf '\n' >&2

  show_countdown "$wake_epoch" "$session_name" "$session_id"

  printf '\n' >&2
  printf '  \e[36m╭%s╮\e[0m\n' "$_bar" >&2
  printf '  \e[36m│\e[0m  \e[1;32m✓ Resuming\e[0m  \e[33m"%s"\e[0m\n' "$session_name" >&2
  printf '  \e[36m╰%s╯\e[0m\n' "$_bar" >&2
  printf '\n' >&2

  resume_id="$session_id"
done
