#!/usr/bin/env bash
# ~/.claude/claude-smart-resume.sh
#
# Smart Resume for Claude Code — by Karthikeyan N
# MIT License
#
# Foreground wrapper around `claude`. Runs claude normally; if it exits due
# to a rate limit, it prints the reset time, waits precisely until then,
# then resumes the same session — all in the foreground of your terminal.
#
# Works with bash 4+ and zsh. No zsh required.
#
# Setup (add to ~/.bashrc or ~/.zshrc):
#   alias claude="$HOME/.claude/claude-smart-resume.sh"
#
# The real claude binary is called via its absolute path so the alias
# doesn't recurse.

CLAUDE_BIN="/home/karthik/.local/bin/claude"
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
  local session_file="$1" start_line="${2:-1}"
  local reset_line
  # Only scan lines written after start_line so a post-resume loop never
  # re-matches the old "resets …(" entry that is still in the JSONL.
  reset_line=$(tail -n "+${start_line}" "$session_file" 2>/dev/null \
    | grep -i 'resets .*(' | tail -1)
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
    if [[ "${reset_time,,}" =~ ^[0-9]+:[0-9]+[apm]+$ ]]; then
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

  tput civis 2>/dev/null >&2   # hide cursor during countdown

  trap '
    tput cnorm 2>/dev/null >&2
    printf "\r\e[K  \e[33mCancelled.\e[0m Resume manually:\n" >&2
    printf "  claude --resume %s\n\n" "'"$session_id"'" >&2
    exit 0
  ' INT

  local remaining mins secs
  while true; do
    remaining=$(( wake_epoch - $(date +%s) ))
    (( remaining <= 0 )) && break
    mins=$(( remaining / 60 ))
    secs=$(( remaining % 60 ))
    # \r goes to col 0 and overwrites the line in place — universally supported.
    # \e[K clears any leftover chars from a previously longer line.
    printf '\r  \e[2mWaiting until reset.\e[0m  Remaining: \e[33m%d min %02ds\e[0m\e[K' \
      "$mins" "$secs" >&2
    sleep 1
  done
  printf '\r\e[K' >&2   # clear countdown line before resume banner

  tput cnorm 2>/dev/null >&2
  trap - INT
}

# ---------------------------------------------------------------------------
# RL watcher: polls the session JSONL for a "resets …(" entry and sends
# SIGINT to claude the moment one appears — bypassing the interactive
# rate-limit menu automatically.
#
# Previously used a two-phase design that required statusline.sh to write a
# flag file before JSONL polling began. That meant auto-detection only worked
# when statusline.sh was configured as a hook; without it the watcher sat idle
# and the user had to manually Ctrl-C out of claude's rate-limit menu.
#
# Now Phase 1 is removed: JSONL polling starts immediately after the session
# file appears. Cost: wc -l + optional tail|grep every 5 s — negligible.
# statusline.sh is still useful for the statusline display but is no longer
# required for auto-detection to function.
# ---------------------------------------------------------------------------
_rl_watcher() {
  local claude_pid=$1

  # Wait up to 30 s for the session file to be created by claude.
  local session_file='' i=0
  while (( i++ < 30 )) && [[ -z "$session_file" ]]; do
    sleep 1
    session_file=$(find_latest_session)
  done
  [[ -z "$session_file" ]] && return

  # Baseline: snapshot line count so we only watch NEW lines.
  local baseline
  baseline=$(wc -l < "$session_file" 2>/dev/null | tr -d ' ' || echo 0)

  while kill -0 "$claude_pid" 2>/dev/null; do
    sleep 5
    local current
    current=$(wc -l < "$session_file" 2>/dev/null | tr -d ' ' || echo 0)
    if (( current > baseline )); then
      if tail -n "+$(( baseline + 1 ))" "$session_file" 2>/dev/null \
          | grep -qi 'resets .*('; then
        sleep 0.3   # let claude finish writing the entry
        kill -INT "$claude_pid" 2>/dev/null
        return
      fi
      baseline=$current   # advance baseline to avoid re-scanning same lines
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
  # of this shell, then starts JSONL polling for a rate-limit entry.
  (
    exec >/dev/null 2>/dev/null   # belt-and-suspenders: silence all output

    local watcher_self=0 _stat_line
    read -r _stat_line < /proc/self/stat 2>/dev/null \
      && watcher_self=${_stat_line%% *}

    local claude_pid='' i=0
    while (( i++ < 200 )) && [[ -z "$claude_pid" ]]; do
      local raw=''
      read -r raw < "/proc/${my_pid}/task/${my_pid}/children" 2>/dev/null \
        || raw=$(pgrep -d' ' -P "$my_pid" 2>/dev/null) || true
      for pid in $raw; do
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
# Main loop: run claude, detect RL on exit, wait, resume.
#
# Wrapped in main() so that `local` declarations are properly scoped.
# In zsh at script top-level, bare `local varname` (typeset without assignment)
# echoes the current value on every subsequent loop iteration. Wrapping in a
# function prevents that spurious output and works correctly in both bash and zsh.
# ---------------------------------------------------------------------------
main() {
  local resume_id=""   # empty = first run, non-empty = resume run
  local resume_msg="Rate limits have reset — continuing where we left off."
  # Header bar: must equal visual width of the fixed header content (66 cols).
  #   "  Smart Resume for Claude Code  ·  Karthikeyan N  ·  MIT License  "
  #    2 + 28 + 2 + 1 + 2 + 13 + 2 + 1 + 2 + 11 + 2 = 66
  local _bar='──────────────────────────────────────────────────────────────────'  # 66 chars

  while true; do
    # Snapshot the session file's current line count before this run starts.
    # Passed to get_reset_info so only NEW lines are scanned — prevents the
    # post-resume loop where the old "resets …(" entry re-triggers a wait.
    local pre_run_lines=0 pre_run_file=''
    pre_run_file=$(find_latest_session)
    if [[ -n "$pre_run_file" && -f "$pre_run_file" ]]; then
      pre_run_lines=$(wc -l < "$pre_run_file" 2>/dev/null | tr -d ' ' || echo 0)
    fi

    if [[ -z "$resume_id" ]]; then
      _run_claude "$@"
    else
      _run_claude --resume "$resume_id" "$resume_msg"
    fi

    local session_file=''
    session_file=$(find_latest_session)
    [[ -z "$session_file" || ! -f "$session_file" ]] && break

    # start_line: 1-based line to begin scanning from (skip pre-existing lines
    # in the same file; if a new file was created, start from line 1).
    local start_line=1
    [[ "$session_file" == "$pre_run_file" ]] && start_line=$(( pre_run_lines + 1 ))

    # Determine reset epoch — fast path via flag file, fallback via JSONL grep
    local reset_epoch=''
    local rl_warn_flag="${HOME}/.claude/.rl_warn"

    if [[ -f "$rl_warn_flag" ]]; then
      local rl_5h_pct='' rl_5h_reset='' rl_7d_pct='' rl_7d_reset=''
      rl_5h_pct=$(grep   '^5h_pct='   "$rl_warn_flag" | cut -d= -f2)
      rl_5h_reset=$(grep '^5h_reset=' "$rl_warn_flag" | cut -d= -f2)
      rl_7d_pct=$(grep   '^7d_pct='   "$rl_warn_flag" | cut -d= -f2)
      rl_7d_reset=$(grep '^7d_reset=' "$rl_warn_flag" | cut -d= -f2)
      if (( ${rl_5h_pct:-0} >= ${rl_7d_pct:-0} )); then
        reset_epoch=${rl_5h_reset:-0}
      else
        reset_epoch=${rl_7d_reset:-0}
      fi
      (( reset_epoch <= 0 )) && reset_epoch=''
    fi

    if [[ -z "$reset_epoch" ]]; then
      local reset_info=''
      reset_info=$(get_reset_info "$session_file" "$start_line")
      [[ -z "$reset_info" ]] && break

      local reset_time='' reset_tz=''
      reset_time=$(echo "$reset_info" | awk '{print $1}')
      reset_tz=$(echo "$reset_info"   | awk '{print $2}')
      reset_epoch=$(parse_reset_epoch "$reset_time" "$reset_tz") || break
    fi

    local wake_epoch=$(( reset_epoch + BUFFER_SECS ))

    local session_id=''
    session_id=$(basename "$session_file" .jsonl)

    local session_name=''
    session_name=$(get_session_name "$session_file")
    if [[ -z "$session_name" ]]; then
      session_name=$(generate_name)
      name_session "$session_file" "$session_id" "$session_name"
    fi

    # Resuming box bar: dynamic width so │ always aligns regardless of session
    # name length.  Content: "  ✓ Resuming  "<name>"  " = 18 + len(name) cols.
    #   2(indent) + 1(✓) + 9( Resuming) + 2(  ) + 1(") + name + 1(") + 2(  ) = 18+len
    # Use printf '─%.0s' to repeat the multi-byte ─ character; tr is byte-only
    # and corrupts it.
    local _rbar=''
    _rbar=$(printf '─%.0s' $(seq 1 $(( 18 + ${#session_name} ))))

    printf '\n' >&2
    printf '  \e[36m╭%s╮\e[0m\n' "$_bar" >&2
    printf '  \e[36m│\e[0m  \e[1;97mSmart Resume for Claude Code\e[0m  \e[2m·\e[0m  \e[97mKarthikeyan N\e[0m  \e[2m·\e[0m  \e[2mMIT License\e[0m  \e[36m│\e[0m\n' >&2
    printf '  \e[36m╰%s╯\e[0m\n' "$_bar" >&2
    printf '\n' >&2
    printf '  \e[1;33m⚡ Rate limit hit\e[0m\n' >&2
    printf '  \e[2m%s\e[0m\n' "$_bar" >&2
    printf '  \e[2mSession\e[0m  \e[33m"%s"\e[0m\n'  "$session_name" >&2
    printf '  \e[2mResets \e[0m  \e[32m%s\e[0m\n'    "$(date -d "@${reset_epoch}" '+%H:%M:%S %Z  (%Y-%m-%d)')" >&2
    printf '  \e[2mWaking \e[0m  \e[32m%s\e[0m  \e[2m(+%ds buffer)\e[0m\n' \
      "$(date -d "@${wake_epoch}" '+%H:%M:%S %Z')" "$BUFFER_SECS" >&2
    printf '  \e[2m%s\e[0m\n' "$_bar" >&2
    printf '  \e[2mPress Ctrl-C to cancel\e[0m\n' >&2
    printf '\n' >&2

    show_countdown "$wake_epoch" "$session_name" "$session_id"

    printf '\n' >&2
    printf '  \e[36m╭%s╮\e[0m\n' "$_rbar" >&2
    printf '  \e[36m│\e[0m  \e[1;32m✓ Resuming\e[0m  \e[33m"%s"\e[0m  \e[36m│\e[0m\n' "$session_name" >&2
    printf '  \e[36m╰%s╯\e[0m\n' "$_rbar" >&2
    printf '\n' >&2

    resume_id="$session_id"
  done
}

main "$@"
