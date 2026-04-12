#!/usr/bin/env zsh
# ~/.claude/claude-smart-resume.sh
#
# Smart Resume for Claude Code — by Karthikeyan N
# MIT License
#
# Foreground wrapper around `claude`. Runs claude normally; if it exits due
# to a rate limit, it prints the reset time, waits precisely until then,
# then resumes the same session — all in the foreground of your terminal.
#
# Setup (add to ~/.zshrc):
#   alias claude="$HOME/.claude/claude-smart-resume.sh"
#
# The real claude binary is called via its absolute path so the alias
# doesn't recurse.

CLAUDE_BIN="${CLAUDE_BIN:-$(which claude 2>/dev/null || echo /usr/local/bin/claude)}"
PROJECTS_DIR="${HOME}/.claude/projects"
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
  # Match any rate-limit line regardless of error key name — the signal is
  # the human-readable "resets <time> (<tz>)" pattern, not a specific JSON field.
  reset_line=$(grep -i 'resets .*(' "$session_file" 2>/dev/null | tail -1)
  [[ -z "$reset_line" ]] && return 0
  local reset_time reset_tz
  # Capture everything between "resets " and the opening paren — handles
  # "7:30pm (tz)", "Apr 26 7:30pm (tz)", "Apr 26, 2026 7:30pm (tz)", etc.
  reset_time=$(echo "$reset_line" | grep -oP '(?i)resets \K[^(]+' | sed 's/[[:space:]]*$//')
  reset_tz=$(echo "$reset_line"   | grep -oP '\([^)]+\)' | tr -d '()')
  [[ -n "$reset_time" && -n "$reset_tz" ]] && echo "${reset_time} ${reset_tz}" || true
}

get_session_name() {
  # Read the JSONL line by line — do NOT use `strings` (binary-file tool that
  # can split or merge JSON objects, causing silent misses on user-set names).
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
  # GNU date -d handles "7:30pm", "Apr 26 7:30pm", "Apr 26, 2026 7:30pm", etc.
  reset_epoch=$(TZ="$reset_tz" date -d "$reset_time" +%s 2>/dev/null) || return 1
  now_epoch=$(date +%s)
  # Only apply next-day rollover when the string was time-only (no date).
  # A full date string ("Apr 26 7:30pm") already resolves to the correct future
  # epoch — adding 86400 would overshoot by a day.
  if (( reset_epoch <= now_epoch )); then
    if [[ "${reset_time:l}" =~ ^[0-9]+:[0-9]+[apm]+$ ]]; then
      reset_epoch=$(( reset_epoch + 86400 ))   # time-only: push to tomorrow
    else
      return 1   # full date already in past — something is wrong, bail out
    fi
  fi
  echo "$reset_epoch"
}

# ---------------------------------------------------------------------------
# Wait until wake_epoch. Prints nothing — the banner already shows the time.
# Ctrl-C prints resume instructions and exits cleanly.
# ---------------------------------------------------------------------------
show_countdown() {
  local wake_epoch="$1" session_name="$2" session_id="$3"

  trap '
    printf "\n  \e[33mCancelled.\e[0m Resume manually when limits clear:\n" >&2
    printf "  claude --resume %s\n\n" "'"$session_id"'" >&2
    exit 0
  ' INT

  local sleep_secs=$(( wake_epoch - $(date +%s) ))
  (( sleep_secs > 0 )) && sleep "$sleep_secs"

  trap - INT
}

# ---------------------------------------------------------------------------
# RL watcher: two-phase design to avoid wasteful JSONL polling.
#
# Phase 1 — cheap: sleeps 5 s between checks of a tiny flag file written by
#   statusline.sh when either rate-limit indicator reaches 90% (display turns
#   red at 80% but the watcher only needs to start when a hit is imminent).
#   Cost: one stat() call every 5 s — effectively zero.
#
# Phase 2 — active: once the flag appears, finds the session JSONL, snapshots
#   the current line count as a baseline (ignores all pre-existing lines,
#   including old RL entries from previous --resume runs), then polls every 2 s
#   for new lines containing the "resets …(" pattern. On detection, sends SIGINT
#   to bypass Claude's interactive rate-limit menu.
#
# Requires statusline.sh to be configured as a hook. Without it the flag never
# appears, Phase 1 loops forever at negligible cost, and the RL menu shows as
# normal (graceful degradation — no crash, no spurious SIGINT).
# ---------------------------------------------------------------------------
_rl_watcher() {
  local claude_pid=$1
  local rl_warn_flag="${HOME}/.claude/.rl_warn"

  # Phase 1: wait for the statusline hook to signal RL >= 90%
  while kill -0 "$claude_pid" 2>/dev/null; do
    [[ -f "$rl_warn_flag" ]] && break
    sleep 5
  done
  kill -0 "$claude_pid" 2>/dev/null || return   # claude already gone

  # Phase 2: RL is red — find the session file and start JSONL polling
  local session_file='' i=0
  while (( i++ < 15 )) && [[ -z "$session_file" ]]; do
    sleep 1
    session_file=$(find_latest_session)
  done
  [[ -z "$session_file" ]] && return

  # Baseline: only watch lines appended after RL turned red
  local baseline
  baseline=$(wc -l < "$session_file" 2>/dev/null || echo 0)

  while kill -0 "$claude_pid" 2>/dev/null; do
    sleep 2
    local current
    current=$(wc -l < "$session_file" 2>/dev/null || echo 0)
    (( current <= baseline )) && continue

    if tail -n "+$(( baseline + 1 ))" "$session_file" 2>/dev/null \
        | grep -qi 'resets .*('; then
      sleep 0.3   # let claude finish writing the entry
      kill -INT "$claude_pid" 2>/dev/null
      return
    fi
  done
}

# ---------------------------------------------------------------------------
# Run claude with the RL watcher active.
#
# Design: run claude DIRECTLY IN THE FOREGROUND — it inherits the terminal
# naturally as a direct child of this shell, with no job control tricks.
# The watcher starts first (in background) and discovers claude's PID by
# reading /proc/<script_pid>/children once claude appears as a child.
#
# Why not background-then-fg?
#   When the script runs as a child of an interactive shell (alias usage),
#   the parent shell owns the terminal session. fg and tcsetpgrp both fail
#   because only the session leader can reassign the foreground process group.
#   Running claude in the foreground bypasses this entirely.
# ---------------------------------------------------------------------------
_run_claude() {
  rm -f "${HOME}/.claude/.rl_warn"   # reset flag — each run starts clean
  local my_pid=$$

  # Start the watcher before claude. It waits for claude to appear as a child
  # of this shell, then hands off to the standard two-phase RL monitor.
  (
    local watcher_self=0 _stat_line
    read -r _stat_line < /proc/self/stat 2>/dev/null \
      && watcher_self=${_stat_line%% *}

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

  trap 'true' INT
  "$CLAUDE_BIN" "$@"
  trap - INT

  kill "$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Main loop: run claude, detect RL on exit, wait, resume
# ---------------------------------------------------------------------------
resume_id=""     # empty = first run, non-empty = resume run
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

  # Determine reset epoch — fast path via flag file, fallback via JSONL grep
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
