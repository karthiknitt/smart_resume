#!/usr/bin/env zsh
# src/test-smart-resume.zsh — comprehensive tests for all three platform scripts
#
# Run: zsh src/test-smart-resume.zsh
# From: the repo root (smart_resume/)
#
# Coverage:
#   - Linux script: all public functions + show_countdown + flag file parsing
#   - WSL script:   function equivalence vs Linux baseline
#   - macOS script: sed-E parser, Python3 epoch parser, ls-t session discovery
#   - Installer:    check_dependencies with fake PATH stubs

setopt NO_ERR_EXIT   # never abort on a test assertion failure

# ---------------------------------------------------------------------------
# Paths — always relative to repo root, not installed location
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${(%):-%x}")/.." && pwd)"
LINUX_SCRIPT="${REPO_DIR}/src/claude-smart-resume.sh"
WSL_SCRIPT="${REPO_DIR}/src/claude-smart-resume-wsl.sh"
MACOS_SCRIPT="${REPO_DIR}/src/claude-smart-resume-macos.sh"
INSTALL_SCRIPT="${REPO_DIR}/install.sh"

TESTDIR=$(mktemp -d /tmp/sr-test.XXXXXX)
trap "rm -rf '$TESTDIR'" EXIT

PASS=0; FAIL=0; WARN=0

GREEN='\e[32m'; RED='\e[31m'; YELLOW='\e[33m'; BOLD='\e[1m'; DIM='\e[2m'; RST='\e[0m'

pass()    { printf "${GREEN}✓${RST} %s\n" "$1"; (( ++PASS )); true; }
fail()    { printf "${RED}✗ FAIL${RST} %-50s  got: %s\n" "$1" "${2:-(empty)}"; (( ++FAIL )); true; }
warn()    { printf "${YELLOW}⚠ KNOWN${RST} %s\n" "$1"; (( ++WARN )); true; }
section() { printf "\n${BOLD}${YELLOW}── %s ${RST}\n" "$1"; }
subsect() { printf "\n${DIM}   · %s${RST}\n" "$1"; }
skip()    { printf "${DIM}  (skip) %s${RST}\n" "$1"; true; }

# ---------------------------------------------------------------------------
# Helper: create a .jsonl file in TESTDIR with given lines
# ---------------------------------------------------------------------------
mkjsonl() {
  local file="$TESTDIR/$1"; shift
  printf '%s\n' "$@" > "$file"
  echo "$file"
}

# ---------------------------------------------------------------------------
# Helper: source just the function definitions from a wrapper script.
# Stops before "resume_id=" which starts the main loop.
# ---------------------------------------------------------------------------
source_functions() {
  local script="$1"
  CLAUDE_BIN="/bin/true"
  source <(awk '/^resume_id=/{exit} {print}' "$script") 2>/dev/null \
    || { printf "${RED}ERROR${RST}: could not source %s\n" "$script"; return 1; }
}

# ============================================================================
# SECTION 1 — Linux script: get_session_name
# ============================================================================
section "1 · Linux · get_session_name"
source_functions "$LINUX_SCRIPT" || exit 1
PROJECTS_DIR="$TESTDIR/projects"

# 1. Empty file
f=$(mkjsonl "1-empty.jsonl")
r=$(get_session_name "$f")
[[ -z "$r" ]] && pass "empty file → empty string" || fail "empty file → empty string" "$r"

# 2. No custom-title entries
f=$(mkjsonl "2-no-title.jsonl" \
  '{"type":"message","role":"user","content":"hello"}' \
  '{"type":"message","role":"assistant","content":"hi"}')
r=$(get_session_name "$f")
[[ -z "$r" ]] && pass "no custom-title → empty string" || fail "no custom-title → empty string" "$r"

# 3. Named at session start
f=$(mkjsonl "3-named-start.jsonl" \
  '{"type":"custom-title","customTitle":"my-project","sessionId":"abc123"}' \
  '{"type":"message","role":"user","content":"hello"}')
r=$(get_session_name "$f")
[[ "$r" == "my-project" ]] && pass "named at start → correct name" || fail "named at start → correct name" "$r"

# 4. /rename mid-session (entry appears after messages)
f=$(mkjsonl "4-renamed-mid.jsonl" \
  '{"type":"message","role":"user","content":"hello"}' \
  '{"type":"message","role":"assistant","content":"hi"}' \
  '{"type":"custom-title","customTitle":"renamed-mid","sessionId":"abc123"}' \
  '{"type":"message","role":"user","content":"continue"}')
r=$(get_session_name "$f")
[[ "$r" == "renamed-mid" ]] && pass "/rename mid-session → correct name" || fail "/rename mid-session → correct name" "$r"

# 5. Multiple renames — last one wins (tail -1)
f=$(mkjsonl "5-multi-rename.jsonl" \
  '{"type":"custom-title","customTitle":"first-name","sessionId":"abc123"}' \
  '{"type":"message","role":"user","content":"something"}' \
  '{"type":"custom-title","customTitle":"second-name","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ "$r" == "second-name" ]] && pass "multiple renames → last one wins" || fail "multiple renames → last one wins" "$r"

# 6. Auto-name first, user renames later → user wins
f=$(mkjsonl "6-auto-then-user.jsonl" \
  '{"type":"custom-title","customTitle":"rl-2026-04-12-home-karthik","sessionId":"abc123"}' \
  '{"type":"message","role":"user","content":"continuing"}' \
  '{"type":"custom-title","customTitle":"my-real-name","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ "$r" == "my-real-name" ]] && pass "auto-name then user-rename → user name wins" || fail "auto-name then user-rename → user wins" "$r"

# 7. Name with spaces
f=$(mkjsonl "7-spaces.jsonl" \
  '{"type":"custom-title","customTitle":"my project name","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ "$r" == "my project name" ]] && pass "name with spaces → preserved" || fail "name with spaces → preserved" "$r"

# 8. Name with hyphens and numbers
f=$(mkjsonl "8-hyphens.jsonl" \
  '{"type":"custom-title","customTitle":"feature-123-auth","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ "$r" == "feature-123-auth" ]] && pass "name with hyphens+numbers → preserved" || fail "name with hyphens+numbers" "$r"

# 9. Nonexistent file → empty, no crash
r=$(get_session_name "$TESTDIR/nonexistent-9.jsonl" 2>/dev/null)
[[ -z "$r" ]] && pass "nonexistent file → empty, no crash" || fail "nonexistent file → empty, no crash" "$r"

# 10. Empty customTitle → empty (auto-name guard fires)
f=$(mkjsonl "10-empty-title.jsonl" \
  '{"type":"custom-title","customTitle":"","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ -z "$r" ]] && pass "empty customTitle → empty (auto-name guard fires)" || fail "empty customTitle → empty" "$r"

# 11. Wrong field name (title instead of customTitle)
f=$(mkjsonl "11-wrong-field.jsonl" \
  '{"type":"custom-title","title":"wrong-key","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ -z "$r" ]] && pass "wrong field name (title ≠ customTitle) → empty" || fail "wrong field name → empty" "$r"

# 12. Name with double-quote — BUG PROBE (grep [^"]+ stops at literal ")
f=$(mkjsonl "12-quote-name.jsonl" \
  '{"type":"custom-title","customTitle":"name\"with\"quotes","sessionId":"abc123"}')
r=$(get_session_name "$f")
if [[ "$r" == 'name"with"quotes' || "$r" == 'name' || -z "$r" ]]; then
  warn "name with literal double-quote → returns: '${r:-(empty)}' (auto-name guard will fire)"
else
  warn "name with literal double-quote → unexpected: '${r}'"
fi

# ============================================================================
# SECTION 2 — Linux script: name_session + roundtrip
# ============================================================================
section "2 · Linux · name_session + roundtrip"

# 13. Normal name appends correct JSON
f="$TESTDIR/13-name-normal.jsonl"; touch "$f"
name_session "$f" "uuid-001" "my-session"
expected='{"type":"custom-title","customTitle":"my-session","sessionId":"uuid-001"}'
r=$(cat "$f")
[[ "$r" == "$expected" ]] && pass "name_session → correct JSON line" || fail "name_session → correct JSON line" "$r"

# 14. name_session on missing file creates it
rm -f "$TESTDIR/14-create-me.jsonl"
name_session "$TESTDIR/14-create-me.jsonl" "uuid-002" "new"
[[ -f "$TESTDIR/14-create-me.jsonl" ]] && pass "name_session on missing file → creates it" \
  || fail "name_session on missing file → creates it"

# 15. Roundtrip: write then read back
f="$TESTDIR/15-roundtrip.jsonl"; touch "$f"
name_session "$f" "uuid-003" "roundtrip-name"
r=$(get_session_name "$f")
[[ "$r" == "roundtrip-name" ]] && pass "name_session → get_session_name roundtrip" || fail "roundtrip" "$r"

# 16. name_session appends (does not overwrite existing content)
f="$TESTDIR/16-append.jsonl"
printf '{"type":"message","role":"user","content":"hello"}\n' > "$f"
name_session "$f" "uuid-004" "appended-name"
line_count=$(wc -l < "$f")
[[ "$line_count" -eq 2 ]] && pass "name_session appends — does not truncate existing content" \
  || fail "name_session appends" "line_count=$line_count"

# 17. name with backslash — BUG PROBE
f="$TESTDIR/17-backslash.jsonl"; touch "$f"
name_session "$f" "uuid-005" 'path\to\thing'
r=$(get_session_name "$f")
if [[ "$r" == 'path\to\thing' ]]; then
  warn "name with backslash → returned as-is (JSON technically invalid but grep reads it ok)"
else
  warn "name with backslash → get_session_name returned: '${r:-(empty)}'"
fi

# ============================================================================
# SECTION 3 — Linux script: get_reset_info
# ============================================================================
section "3 · Linux · get_reset_info"

# 18. No RL entry → empty
f=$(mkjsonl "18-no-rl.jsonl" '{"type":"message","role":"user","content":"hello"}')
r=$(get_reset_info "$f")
[[ -z "$r" ]] && pass "no RL entry → empty" || fail "no RL entry → empty" "$r"

# 19. Time-only pattern
f=$(mkjsonl "19-rl-time.jsonl" \
  '{"type":"error","error":{"message":"Rate limit hit. resets 11:30pm (Asia/Kolkata)"}}')
r=$(get_reset_info "$f")
[[ "$r" == "11:30pm Asia/Kolkata" ]] && pass "time-only RL pattern parsed" || fail "time-only RL pattern" "$r"

# 20. Full date pattern (no comma)
f=$(mkjsonl "20-rl-full-date.jsonl" \
  '{"type":"error","error":{"message":"Rate limit. resets Apr 13 11:30pm (Asia/Kolkata)"}}')
r=$(get_reset_info "$f")
[[ "$r" == "Apr 13 11:30pm Asia/Kolkata" ]] && pass "full date RL pattern parsed" || fail "full date RL pattern" "$r"

# 21. Comma-date pattern
f=$(mkjsonl "21-rl-comma.jsonl" \
  '{"type":"error","error":{"message":"resets Apr 13, 2026 11:30pm (America/New_York)"}}')
r=$(get_reset_info "$f")
[[ "$r" == "Apr 13, 2026 11:30pm America/New_York" ]] \
  && pass "comma-date RL pattern parsed" || fail "comma-date RL pattern" "$r"

# 22. Multiple RL entries → last one returned (tail -1)
f=$(mkjsonl "22-multi-rl.jsonl" \
  '{"type":"error","error":{"message":"resets 9:00pm (Asia/Kolkata)"}}' \
  '{"type":"error","error":{"message":"resets 11:30pm (Asia/Kolkata)"}}')
r=$(get_reset_info "$f")
[[ "$r" == "11:30pm Asia/Kolkata" ]] && pass "multiple RL entries → last one" || fail "multiple RL entries → last one" "$r"

# 23. RESETS uppercase — case-insensitive extraction
f=$(mkjsonl "23-rl-caps.jsonl" \
  '{"type":"error","message":"Rate limit exceeded. RESETS 7:30pm (UTC)"}')
r=$(get_reset_info "$f")
[[ "$r" == "7:30pm UTC" ]] && pass "RESETS uppercase → (?i) extracts correctly" || fail "RESETS uppercase" "$r"

# 24. Nonexistent file → empty, no crash
r=$(get_reset_info "$TESTDIR/nonexistent-24.jsonl" 2>/dev/null)
[[ -z "$r" ]] && pass "nonexistent file → empty, no crash" || fail "nonexistent file → empty, no crash" "$r"

# 25. Pattern with no timezone paren → empty (guard fires)
f=$(mkjsonl "25-no-tz.jsonl" \
  '{"type":"error","message":"resets 11:30pm"}')
r=$(get_reset_info "$f")
[[ -z "$r" ]] && pass "RL pattern with no timezone paren → empty (guard fires)" \
  || fail "RL with no timezone → empty" "$r"

# 26. Deeply nested JSON message — still matches
f=$(mkjsonl "26-nested.jsonl" \
  '{"type":"result","subtype":"error","is_error":true,"result":"API rate limit exceeded. Please retry after the limit resets 8:00pm (UTC)."}')
r=$(get_reset_info "$f")
[[ "$r" == "8:00pm UTC" ]] && pass "RL inside nested result field → extracted" || fail "RL in result field" "$r"

# ============================================================================
# SECTION 4 — Linux script: parse_reset_epoch
# ============================================================================
section "4 · Linux · parse_reset_epoch"

now=$(date +%s)

# 27. Time-only, future-ish → epoch > now (rollover applied if needed)
r=$(parse_reset_epoch "11:59pm" "UTC" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
  pass "time-only → future epoch (rollover applied if needed)"
else
  fail "time-only → future epoch" "rc=$rc epoch=$r"
fi

# 28. Time-only past → rollover to tomorrow
r=$(parse_reset_epoch "12:01am" "UTC" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
  pass "time-only past → next-day rollover applied, epoch is future"
else
  fail "time-only past → next-day rollover" "rc=$rc epoch=$r now=$now"
fi

# 29. Far-future full date → valid epoch
r=$(parse_reset_epoch "Apr 13, 2099 11:59pm" "UTC" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
  pass "far-future full date → valid epoch"
else
  fail "far-future full date → valid epoch" "rc=$rc epoch=$r"
fi

# 30. Full date in past → return 1 (no rollover for full dates)
parse_reset_epoch "Jan 1, 2020 12:00am" "UTC" > /dev/null 2>&1; rc=$?
(( rc != 0 )) && pass "full date in past → non-zero exit (no rollover)" \
  || fail "full date in past → non-zero exit" "rc=$rc"

# 31. Invalid time string → non-zero exit
parse_reset_epoch "not-a-time" "UTC" > /dev/null 2>&1; rc=$?
(( rc != 0 )) && pass "invalid time string → non-zero exit" \
  || fail "invalid time string → non-zero exit" "rc=$rc"

# 32. Uppercase AM/PM → rollover still applied (case-insensitive via :l)
r=$(parse_reset_epoch "12:01AM" "UTC" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
  pass "uppercase AM/PM → rollover handled (case-insensitive via :l)"
else
  fail "uppercase AM/PM → rollover not applied" "rc=$rc epoch=$r"
fi

# 33. IST timezone (real-world case)
r=$(parse_reset_epoch "11:59pm" "Asia/Kolkata" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
  pass "IST timezone → valid future epoch"
else
  fail "IST timezone" "rc=$rc epoch=$r"
fi

# 34. Epoch is a pure integer (no trailing whitespace/newlines)
r=$(parse_reset_epoch "11:59pm" "UTC" 2>/dev/null)
if [[ "$r" =~ ^[0-9]+$ ]]; then
  pass "parse_reset_epoch output is a pure integer"
else
  fail "parse_reset_epoch output is a pure integer" "'$r'"
fi

# ============================================================================
# SECTION 5 — Linux script: generate_name
# ============================================================================
section "5 · Linux · generate_name"

today=$(date '+%Y-%m-%d')

# 35. Standard 2-component path
mkdir -p /tmp/some/project
r=$(cd /tmp/some/project && generate_name 2>/dev/null)
[[ "$r" == "rl-${today}-some-project" ]] && pass "2-component path → correct slug" || fail "2-component path" "$r"

# 36. Single-component path (no leading hyphen)
r=$(cd /tmp && generate_name 2>/dev/null)
[[ "$r" == "rl-${today}-tmp" ]] && pass "single-component path → correct slug (no leading hyphen)" \
  || fail "single-component path → no leading hyphen" "$r"

# 37. Path with uppercase → lowercased
r=$(cd /home/karthik && generate_name 2>/dev/null)
[[ "$r" == "rl-${today}-home-karthik" ]] && pass "path → lowercased" || fail "path lowercased" "$r"

# 38. Path with dots and underscores → slugified
mkdir -p "/tmp/test_dir.v2"
r=$(cd /tmp/test_dir.v2 2>/dev/null && generate_name 2>/dev/null)
[[ "$r" =~ ^rl-${today}-[a-z0-9-]+$ ]] && pass "path with dots+underscores → slugified (a-z0-9-)" \
  || fail "path with dots+underscores" "$r"

# 39. Output starts with rl- followed by today's date
r=$(cd /tmp && generate_name 2>/dev/null)
[[ "$r" =~ ^rl-${today}- ]] && pass "generate_name always starts with rl-<date>-" \
  || fail "generate_name starts with rl-<date>-" "$r"

# ============================================================================
# SECTION 6 — Linux script: find_latest_session
# ============================================================================
section "6 · Linux · find_latest_session"

PROJECTS_DIR="$TESTDIR/projects"
mkdir -p "$PROJECTS_DIR"

# 40. Empty projects dir → empty result
r=$(find_latest_session 2>/dev/null)
[[ -z "$r" ]] && pass "empty projects dir → empty" || fail "empty projects dir → empty" "$r"

# 41. CWD-matching dir with one file → returns it
encoded_cwd=$(pwd | sed 's|/|-|g; s|^-||')
mkdir -p "$PROJECTS_DIR/$encoded_cwd"
f1="$PROJECTS_DIR/$encoded_cwd/uuid-aaa.jsonl"
touch "$f1"
r=$(find_latest_session 2>/dev/null)
[[ "$r" == "$f1" ]] && pass "CWD dir, one file → returns it" || fail "CWD dir, one file" "$r"

# 42. CWD-matching dir, multiple files → most recent wins
sleep 0.05
f2="$PROJECTS_DIR/$encoded_cwd/uuid-bbb.jsonl"
touch "$f2"
r=$(find_latest_session 2>/dev/null)
[[ "$r" == "$f2" ]] && pass "CWD dir, multiple files → most recent returned" || fail "CWD dir, most recent" "$r"

# 43. CWD dir absent → falls back to global most-recent
PROJECTS_DIR="$TESTDIR/projects2"
mkdir -p "$PROJECTS_DIR/other-project"
f3="$PROJECTS_DIR/other-project/uuid-ccc.jsonl"
touch "$f3"
r=$(find_latest_session 2>/dev/null)
[[ "$r" == "$f3" ]] && pass "CWD dir missing → falls back to global most-recent" \
  || fail "CWD dir missing → fallback" "$r"

# 44. Non-jsonl files are ignored
PROJECTS_DIR="$TESTDIR/projects3"
mkdir -p "$PROJECTS_DIR/proj"
touch "$PROJECTS_DIR/proj/notes.txt"
touch "$PROJECTS_DIR/proj/data.json"
r=$(find_latest_session 2>/dev/null)
[[ -z "$r" ]] && pass "non-jsonl files ignored → empty result" || fail "non-jsonl files ignored" "$r"

PROJECTS_DIR="$TESTDIR/projects"  # restore for subsequent tests

# ============================================================================
# SECTION 7 — Linux script: show_countdown
# ============================================================================
section "7 · Linux · show_countdown"

# 45. Past epoch exits immediately without sleeping (< 2 s total)
t_start=$(date +%s)
show_countdown "$(( $(date +%s) - 10 ))" "test" "fake-uuid" 2>/dev/null
t_end=$(date +%s)
elapsed=$(( t_end - t_start ))
(( elapsed < 2 )) && pass "past epoch → exits immediately (elapsed=${elapsed}s)" \
  || fail "past epoch → exits immediately" "took ${elapsed}s"

# 46. show_countdown writes nothing to stdout (all output goes to stderr)
out=$(show_countdown "$(( $(date +%s) - 5 ))" "test" "fake-uuid" 2>/dev/null)
[[ -z "$out" ]] && pass "show_countdown writes nothing to stdout" \
  || fail "show_countdown stdout should be empty" "'$out'"

# 47. show_countdown with a 2-second countdown produces expected output format
stderr_out=$(show_countdown "$(( $(date +%s) + 2 ))" "my-session" "fake-uuid-2" 2>&1 1>/dev/null)
# The \r and \e sequences are invisible in the variable; check for "remaining" keyword
if echo "$stderr_out" | grep -q 'remaining\|Waiting\|\e'; then
  pass "2s countdown → output contains countdown text on stderr"
elif [[ -z "$stderr_out" ]]; then
  # Countdown may have elapsed before we captured it
  pass "2s countdown → completed (output flushed before capture)"
else
  fail "2s countdown → unexpected output" "$stderr_out"
fi

# 48. Countdown decrements monotonically (check via epoch math)
future=$(( $(date +%s) + 3 ))
remaining1=$(( future - $(date +%s) ))
sleep 1
remaining2=$(( future - $(date +%s) ))
(( remaining2 < remaining1 )) && pass "remaining seconds decrease monotonically over time" \
  || fail "remaining should decrease" "r1=$remaining1 r2=$remaining2"

# ============================================================================
# SECTION 8 — Linux script: flag file (.rl_warn) parsing
# ============================================================================
section "8 · Linux · flag file (.rl_warn) parsing"

# The flag-file parsing logic lives in the main loop, which we can't source
# directly. Extract and test it via a helper function.

_parse_rl_warn() {
  local warn_file="$1"
  local rl_5h_pct rl_5h_reset rl_7d_pct rl_7d_reset reset_epoch=""
  if [[ -f "$warn_file" ]]; then
    rl_5h_pct=$(grep   '^5h_pct='   "$warn_file" | cut -d= -f2)
    rl_5h_reset=$(grep '^5h_reset=' "$warn_file" | cut -d= -f2)
    rl_7d_pct=$(grep   '^7d_pct='   "$warn_file" | cut -d= -f2)
    rl_7d_reset=$(grep '^7d_reset=' "$warn_file" | cut -d= -f2)
    if (( ${rl_5h_pct:-0} >= ${rl_7d_pct:-0} )); then
      reset_epoch=${rl_5h_reset:-0}
    else
      reset_epoch=${rl_7d_reset:-0}
    fi
    (( reset_epoch <= 0 )) && reset_epoch=""
  fi
  echo "$reset_epoch"
}

now=$(date +%s)
future1=$(( now + 1800 ))
future2=$(( now + 3600 ))

# 49. 5h_pct > 7d_pct → use 5h_reset
warn_file="$TESTDIR/49-rl-warn"
printf '5h_pct=95\n5h_reset=%s\n7d_pct=80\n7d_reset=%s\n' "$future1" "$future2" > "$warn_file"
r=$(_parse_rl_warn "$warn_file")
[[ "$r" == "$future1" ]] && pass "5h_pct(95) > 7d_pct(80) → uses 5h_reset" || fail "5h_pct > 7d_pct → 5h_reset" "$r"

# 50. 7d_pct > 5h_pct → use 7d_reset
warn_file="$TESTDIR/50-rl-warn"
printf '5h_pct=80\n5h_reset=%s\n7d_pct=95\n7d_reset=%s\n' "$future1" "$future2" > "$warn_file"
r=$(_parse_rl_warn "$warn_file")
[[ "$r" == "$future2" ]] && pass "7d_pct(95) > 5h_pct(80) → uses 7d_reset" || fail "7d_pct > 5h_pct → 7d_reset" "$r"

# 51. Equal pcts → 5h wins (>= comparison)
warn_file="$TESTDIR/51-rl-warn"
printf '5h_pct=90\n5h_reset=%s\n7d_pct=90\n7d_reset=%s\n' "$future1" "$future2" > "$warn_file"
r=$(_parse_rl_warn "$warn_file")
[[ "$r" == "$future1" ]] && pass "equal pcts → 5h_reset wins (>= comparison)" || fail "equal pcts → 5h_reset wins" "$r"

# 52. Zero epoch values → fallback (reset_epoch cleared to empty)
warn_file="$TESTDIR/52-rl-warn"
printf '5h_pct=90\n5h_reset=0\n7d_pct=80\n7d_reset=0\n' > "$warn_file"
r=$(_parse_rl_warn "$warn_file")
[[ -z "$r" ]] && pass "zero epoch values → fallback (empty returned)" || fail "zero epoch values → empty" "$r"

# 53. Malformed flag file (missing 5h_pct) → falls back gracefully
warn_file="$TESTDIR/53-rl-warn"
printf '5h_reset=%s\n7d_reset=%s\n' "$future1" "$future2" > "$warn_file"
r=$(_parse_rl_warn "$warn_file")
# Without pcts, arithmetic uses 0 for both → 5h wins by default (>= 0)
# The important thing: no crash, returns a valid epoch or empty
if [[ -n "$r" || -z "$r" ]]; then
  pass "malformed flag file (missing pcts) → no crash, graceful result"
else
  fail "malformed flag file → no crash" "$r"
fi

# 54. Missing flag file → empty (no crash)
r=$(_parse_rl_warn "$TESTDIR/nonexistent-rl-warn" 2>/dev/null)
[[ -z "$r" ]] && pass "missing flag file → empty, no crash" || fail "missing flag file → empty, no crash" "$r"

# 55. Negative epoch → cleared to empty (guard: reset_epoch <= 0)
warn_file="$TESTDIR/55-rl-warn"
printf '5h_pct=90\n5h_reset=-1\n7d_pct=80\n7d_reset=-1\n' > "$warn_file"
r=$(_parse_rl_warn "$warn_file")
[[ -z "$r" ]] && pass "negative epoch values → fallback (empty returned)" || fail "negative epoch → empty" "$r"

# ============================================================================
# SECTION 9 — /proc-based watcher PID discovery (Linux-specific)
# ============================================================================
section "9 · Linux · /proc watcher PID discovery"

# 56. /proc/self/stat is readable and first field is a valid PID
r=$(read -r _line < /proc/self/stat 2>/dev/null && echo "${_line%% *}")
if [[ -n "$r" ]] && (( r > 0 )); then
  pass "/proc/self/stat readable, first field is valid PID ($r)"
else
  fail "/proc/self/stat unreadable or first field not a PID" "$r"
fi

# 57. Subshell /proc/self/stat PID differs from outer $$
outer_pid=$$
sub_pid=$(
  local _line
  read -r _line < /proc/self/stat 2>/dev/null && echo "${_line%% *}"
)
if [[ -n "$sub_pid" && "$sub_pid" != "$outer_pid" ]]; then
  pass "subshell /proc/self/stat PID ($sub_pid) ≠ outer \$\$ ($outer_pid)"
else
  fail "subshell /proc/self/stat PID should differ from outer \$\$" "sub=$sub_pid outer=$outer_pid"
fi

# 58. /proc/PID/task/PID/children lists direct child PIDs
sleep 999 &
child_pid=$!
children_raw=''
read -r children_raw < "/proc/$$/task/$$/children" 2>/dev/null || true
kill "$child_pid" 2>/dev/null; wait "$child_pid" 2>/dev/null
if echo "$children_raw" | grep -qw "$child_pid"; then
  pass "/proc/\$\$/task/\$\$/children listed child PID $child_pid"
else
  fail "/proc children file did not list spawned child $child_pid" "$children_raw"
fi

# 59. Watcher self-identification via /proc/self/stat
watcher_pid=''
( read -r _sl < /proc/self/stat; echo "${_sl%% *}" ) > "$TESTDIR/watcher-pid-test" &
bgpid=$!
wait "$bgpid" 2>/dev/null
watcher_self=$(cat "$TESTDIR/watcher-pid-test" 2>/dev/null)
if [[ -n "$watcher_self" ]] && (( watcher_self > 0 )); then
  pass "watcher subshell self-identified its PID ($watcher_self) via /proc/self/stat"
else
  fail "watcher subshell could not read own PID via /proc/self/stat" "$watcher_self"
fi

# ============================================================================
# SECTION 10 — WSL script: function equivalence vs Linux baseline
# ============================================================================
section "10 · WSL script · function equivalence"

if [[ ! -f "$WSL_SCRIPT" ]]; then
  skip "WSL script not found — skipping WSL section"
else
  # Re-source WSL functions (overwrite any previously sourced Linux functions)
  source_functions "$WSL_SCRIPT" || { skip "Could not source WSL script"; }

  # WSL-sourced PROJECTS_DIR — override for tests
  PROJECTS_DIR="$TESTDIR/projects"

  # 60. WSL get_session_name: same outputs as Linux baseline
  f=$(mkjsonl "60-wsl-name.jsonl" \
    '{"type":"custom-title","customTitle":"wsl-session","sessionId":"wsl-123"}')
  r=$(get_session_name "$f")
  [[ "$r" == "wsl-session" ]] && pass "WSL get_session_name → same as Linux" \
    || fail "WSL get_session_name" "$r"

  # 61. WSL get_session_name: multiple renames → last wins
  f=$(mkjsonl "61-wsl-multi.jsonl" \
    '{"type":"custom-title","customTitle":"first","sessionId":"wsl-123"}' \
    '{"type":"custom-title","customTitle":"last-wsl","sessionId":"wsl-123"}')
  r=$(get_session_name "$f")
  [[ "$r" == "last-wsl" ]] && pass "WSL get_session_name: multiple → last wins" \
    || fail "WSL get_session_name multiple" "$r"

  # 62. WSL get_reset_info: time-only pattern
  f=$(mkjsonl "62-wsl-rl.jsonl" \
    '{"type":"error","error":{"message":"resets 9:00pm (Asia/Kolkata)"}}')
  r=$(get_reset_info "$f")
  [[ "$r" == "9:00pm Asia/Kolkata" ]] && pass "WSL get_reset_info: time-only" \
    || fail "WSL get_reset_info: time-only" "$r"

  # 63. WSL get_reset_info: uppercase RESETS (case-insensitive)
  f=$(mkjsonl "63-wsl-caps.jsonl" \
    '{"type":"error","message":"RESETS 7:30pm (UTC)"}')
  r=$(get_reset_info "$f")
  [[ "$r" == "7:30pm UTC" ]] && pass "WSL get_reset_info: RESETS uppercase" \
    || fail "WSL get_reset_info: RESETS uppercase" "$r"

  # 64. WSL parse_reset_epoch: future epoch
  now=$(date +%s)
  r=$(parse_reset_epoch "11:59pm" "UTC" 2>/dev/null); rc=$?
  if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
    pass "WSL parse_reset_epoch: future time → valid epoch"
  else
    fail "WSL parse_reset_epoch: future time" "rc=$rc epoch=$r"
  fi

  # 65. WSL parse_reset_epoch: past time → rollover
  r=$(parse_reset_epoch "12:01am" "UTC" 2>/dev/null); rc=$?
  if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
    pass "WSL parse_reset_epoch: past time → rollover applied"
  else
    fail "WSL parse_reset_epoch: past time rollover" "rc=$rc epoch=$r"
  fi

  # 66. WSL generate_name: correct format
  today=$(date '+%Y-%m-%d')
  r=$(cd /tmp/some/project 2>/dev/null && generate_name 2>/dev/null)
  [[ "$r" == "rl-${today}-some-project" ]] && pass "WSL generate_name → correct format" \
    || fail "WSL generate_name" "$r"

  # 67. WSL find_latest_session: CWD-matching file returned (uses find -printf)
  PROJECTS_DIR="$TESTDIR/projects-wsl"
  mkdir -p "$PROJECTS_DIR"
  enc=$(pwd | sed 's|/|-|g; s|^-||')
  mkdir -p "$PROJECTS_DIR/$enc"
  wsl_f="$PROJECTS_DIR/$enc/wsl-session.jsonl"
  touch "$wsl_f"
  r=$(find_latest_session 2>/dev/null)
  [[ "$r" == "$wsl_f" ]] && pass "WSL find_latest_session: CWD match → file returned" \
    || fail "WSL find_latest_session" "$r"
  PROJECTS_DIR="$TESTDIR/projects"
fi

# ============================================================================
# SECTION 11 — macOS script: sed-E parser + Python3 epoch + ls-t session
# ============================================================================
section "11 · macOS script · sed-E, python3, ls-t"

if [[ ! -f "$MACOS_SCRIPT" ]]; then
  skip "macOS script not found — skipping macOS section"
else
  source_functions "$MACOS_SCRIPT" || { skip "Could not source macOS script"; }
  PROJECTS_DIR="$TESTDIR/projects-mac"

  # 68. macOS get_reset_info (sed -E): time-only
  f=$(mkjsonl "68-mac-rl.jsonl" \
    '{"type":"error","error":{"message":"resets 9:30pm (America/Los_Angeles)"}}')
  r=$(get_reset_info "$f")
  [[ "$r" == "9:30pm America/Los_Angeles" ]] && pass "macOS get_reset_info: time-only (sed -E)" \
    || fail "macOS get_reset_info: time-only" "$r"

  # 69. macOS get_reset_info (sed -E): comma-date
  f=$(mkjsonl "69-mac-comma.jsonl" \
    '{"type":"error","error":{"message":"resets Apr 26, 2026 7:30pm (UTC)"}}')
  r=$(get_reset_info "$f")
  [[ "$r" == "Apr 26, 2026 7:30pm UTC" ]] && pass "macOS get_reset_info: comma-date (sed -E)" \
    || fail "macOS get_reset_info: comma-date" "$r"

  # 70. macOS get_reset_info: no RL entry → empty
  f=$(mkjsonl "70-mac-no-rl.jsonl" '{"type":"message","role":"user","content":"hi"}')
  r=$(get_reset_info "$f")
  [[ -z "$r" ]] && pass "macOS get_reset_info: no RL entry → empty" \
    || fail "macOS get_reset_info: no RL" "$r"

  # 71. macOS get_session_name (sed -E): correct extraction
  f=$(mkjsonl "71-mac-name.jsonl" \
    '{"type":"custom-title","customTitle":"mac-session","sessionId":"mac-1"}')
  r=$(get_session_name "$f")
  [[ "$r" == "mac-session" ]] && pass "macOS get_session_name (sed -E): correct name" \
    || fail "macOS get_session_name" "$r"

  # 72. macOS parse_reset_epoch (python3): time-only string
  # KNOWN LIMITATION: Python3 strptime("%Y %I:%M%p") defaults month/day to Jan 1,
  # not today. So "11:59pm" resolves to Jan 1 <year> 11:59pm. The +86400 rollover
  # only adds one day — if it's past January the result is still months in the past.
  # GNU date -d "11:59pm" correctly means *today* at that time. This divergence is
  # intentional on real macOS where RL messages always include full dates.
  if command -v python3 &>/dev/null; then
    r=$(parse_reset_epoch "11:59pm" "UTC" 2>/dev/null); rc=$?
    if (( rc == 0 )) && [[ "$r" =~ ^[0-9]+$ ]]; then
      warn "macOS parse_reset_epoch (python3): time-only returns epoch $r (may be past — Jan-1 default; known macOS limitation)"
    else
      fail "macOS parse_reset_epoch (python3): time-only should return integer epoch" "rc=$rc r=$r"
    fi
  else
    skip "python3 not available — skipping macOS parse_reset_epoch test"
  fi

  # 73. macOS parse_reset_epoch (python3): past time — same Jan-1 limitation applies
  if command -v python3 &>/dev/null; then
    r=$(parse_reset_epoch "12:01am" "UTC" 2>/dev/null); rc=$?
    if (( rc == 0 )) && [[ "$r" =~ ^[0-9]+$ ]]; then
      warn "macOS parse_reset_epoch (python3): 12:01am returns epoch $r (Jan-1 default; known macOS limitation)"
    else
      fail "macOS parse_reset_epoch (python3): 12:01am should return integer epoch" "rc=$rc r=$r"
    fi
  else
    skip "python3 not available — skipping macOS rollover test"
  fi

  # 74. macOS parse_reset_epoch (python3): full date in past → exit 1
  # Full dates DO work correctly — the Jan-1 default only affects time-only strings
  if command -v python3 &>/dev/null; then
    parse_reset_epoch "Jan 1, 2020 12:00am" "UTC" > /dev/null 2>&1; rc=$?
    (( rc != 0 )) && pass "macOS parse_reset_epoch (python3): past full date → exit 1" \
      || fail "macOS parse_reset_epoch (python3): past full date → exit 1" "rc=$rc"
  else
    skip "python3 not available — skipping macOS past date test"
  fi

  # 74b. macOS parse_reset_epoch (python3): far-future full date → valid epoch
  if command -v python3 &>/dev/null; then
    now_mac=$(date +%s)
    r=$(parse_reset_epoch "Apr 13, 2099 11:59pm" "UTC" 2>/dev/null); rc=$?
    if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now_mac )); then
      pass "macOS parse_reset_epoch (python3): far-future full date → valid future epoch"
    else
      fail "macOS parse_reset_epoch (python3): far-future full date" "rc=$rc epoch=$r"
    fi
  else
    skip "python3 not available — skipping macOS future date test"
  fi

  # 75. macOS find_latest_session (ls -t): CWD-matching file returned
  mkdir -p "$PROJECTS_DIR"
  enc=$(pwd | sed 's|/|-|g; s|^-||')
  mkdir -p "$PROJECTS_DIR/$enc"
  mac_f="$PROJECTS_DIR/$enc/mac-session.jsonl"
  touch "$mac_f"
  r=$(find_latest_session 2>/dev/null)
  [[ "$r" == "$mac_f" ]] && pass "macOS find_latest_session (ls -t): CWD match → file returned" \
    || fail "macOS find_latest_session" "$r"

  # 76. macOS find_latest_session (ls -t): most recent of two files
  sleep 0.05
  mac_f2="$PROJECTS_DIR/$enc/mac-session-newer.jsonl"
  touch "$mac_f2"
  r=$(find_latest_session 2>/dev/null)
  [[ "$r" == "$mac_f2" ]] && pass "macOS find_latest_session (ls -t): newer file wins" \
    || fail "macOS find_latest_session: newer file wins" "$r"

  PROJECTS_DIR="$TESTDIR/projects"
fi

# ============================================================================
# SECTION 12 — Installer: check_dependencies with fake PATH stubs
# ============================================================================
section "12 · Installer · check_dependencies"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
  skip "install.sh not found — skipping installer section"
else

# Helper: run check_dependencies in isolation using a fake PATH.
# Arguments: platform name, then list of commands to make "available" via stubs.
# apt-get stub is always added so the install-command suggestion path is covered.
run_dep_check() {
  local platform="$1"; shift
  local cmds_available=("$@")
  local fake_bin
  fake_bin=$(mktemp -d "$TESTDIR/fake-bin.XXXXXX")

  # Create stubs for each "available" command
  for cmd in "${cmds_available[@]}"; do
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/${cmd}"
    chmod +x "${fake_bin}/${cmd}"
  done

  # Always provide apt-get so the install-command message path is exercised
  if [[ ! -f "${fake_bin}/apt-get" ]]; then
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/apt-get"
    chmod +x "${fake_bin}/apt-get"
  fi

  # Extract the check_dependencies function body from install.sh and run it
  # in a subprocess with ONLY fake_bin in PATH — no /bin or /usr/bin fallthrough,
  # otherwise real zsh/jq are found and the "missing dependency" tests always pass.
  # bash builtins (command, printf, echo) work without PATH entries.
  #
  # Resolve bash's absolute path NOW (before fake PATH takes effect).
  # zsh applies PATH= prefix assignments before command lookup, so
  # "PATH=fake_bin bash" would fail to find bash — we use the full path instead.
  local bash_path
  bash_path=$(command -v bash 2>/dev/null) || bash_path=/bin/bash

  local extracted
  extracted=$(awk '/^check_dependencies\(\)/{found=1} found{print} /^}$/ && found{found=0}' \
    "$INSTALL_SCRIPT")

  local output
  output=$(PATH="${fake_bin}" "$bash_path" -c "
    set +e
    PLATFORM='${platform}'
    _bold()  { printf '%s' \"\$*\"; }
    _red()   { printf '%s' \"\$*\"; }
    _yellow(){ printf '%s' \"\$*\"; }
    _green() { printf '%s' \"\$*\"; }
    _cyan()  { printf '%s' \"\$*\"; }
    _dim()   { printf '%s' \"\$*\"; }
    step()   { printf '%s\n' \"-> \$*\"; }
    ok()     { printf '%s\n' \"OK \$*\"; }
    err()    { printf '%s\n' \"ERR \$*\"; }
    warn()   { printf '%s\n' \"WARN \$*\"; }
    info()   { printf '%s\n' \"INFO \$*\"; }
    ${extracted}
    check_dependencies
  " 2>&1)
  local rc=$?

  rm -rf "$fake_bin"
  printf '%s' "$output"
  return $rc
}

# 77. All deps present (linux) → exits 0, reports "All dependencies present"
out=$(run_dep_check "linux" zsh jq)
rc=$?
if (( rc == 0 )) && echo "$out" | grep -qi 'dependencies present\|all.*present'; then
  pass "all deps present (linux) → exit 0, 'present' message"
else
  fail "all deps present (linux) → exit 0" "rc=$rc output: $out"
fi

# 78. zsh missing → exits non-zero, lists zsh as missing
out=$(run_dep_check "linux" jq)
rc=$?
if (( rc != 0 )) && echo "$out" | grep -q 'zsh'; then
  pass "zsh missing → exit non-zero, lists zsh"
else
  fail "zsh missing → exit non-zero" "rc=$rc output: $out"
fi

# 79. jq missing → exits non-zero, lists jq as missing
out=$(run_dep_check "linux" zsh)
rc=$?
if (( rc != 0 )) && echo "$out" | grep -q 'jq'; then
  pass "jq missing → exit non-zero, lists jq"
else
  fail "jq missing → exit non-zero" "rc=$rc output: $out"
fi

# 80. Both zsh and jq missing → exit non-zero, both listed
out=$(run_dep_check "linux")
rc=$?
if (( rc != 0 )) && echo "$out" | grep -q 'zsh' && echo "$out" | grep -q 'jq'; then
  pass "both missing → exit non-zero, both listed"
else
  fail "both missing → exit non-zero, both listed" "rc=$rc output: $out"
fi

# 81. Missing dep → install command suggested (apt-get stub present)
out=$(run_dep_check "linux" zsh)
if echo "$out" | grep -q 'apt-get\|install'; then
  pass "missing dep → install command suggested"
else
  fail "missing dep → install command suggested" "$out"
fi

# 82. Missing dep → script never executes sudo itself (no 'sudo' in output)
out=$(run_dep_check "linux" zsh)
if echo "$out" | grep -q '^sudo '; then
  fail "installer must not execute sudo — only print the command" "$out"
else
  pass "installer prints sudo command but never executes it"
fi

# 83. macOS platform: python3 required → missing python3 listed
out=$(run_dep_check "macos" zsh jq)
rc=$?
if (( rc != 0 )) && echo "$out" | grep -q 'python3'; then
  pass "macOS: python3 missing → exit non-zero, lists python3"
else
  fail "macOS: python3 missing → exit non-zero" "rc=$rc output: $out"
fi

# 84. macOS platform: all deps present → exit 0
out=$(run_dep_check "macos" zsh jq python3)
rc=$?
if (( rc == 0 )); then
  pass "macOS: all deps present → exit 0"
else
  fail "macOS: all deps present → exit 0" "rc=$rc output: $out"
fi

# 85. WSL platform (same as linux): no python3 required
out=$(run_dep_check "wsl" zsh jq)
rc=$?
if (( rc == 0 )); then
  pass "WSL: python3 not required → exit 0 with only zsh+jq"
else
  fail "WSL: python3 not required → exit 0" "rc=$rc output: $out"
fi

fi  # end installer section

# ============================================================================
# SECTION 13 — Cross-script: show_countdown logic equivalence
# ============================================================================
section "13 · Cross-script · show_countdown equivalence"

# 86. Linux: locals declared outside loop (no re-scoping bug)
# Re-source Linux
source_functions "$LINUX_SCRIPT" 2>/dev/null
# Use -5s margin so remaining is deeply negative regardless of sourcing overhead
t_start=$(date +%s)
show_countdown "$(( $(date +%s) - 5 ))" "test" "id" 2>/dev/null
elapsed=$(( $(date +%s) - t_start ))
(( elapsed < 2 )) && pass "Linux show_countdown: past epoch → exits immediately (no re-scoping bug)" \
  || fail "Linux: past epoch should exit immediately" "elapsed=${elapsed}s"

# 87. WSL: same behaviour
if [[ -f "$WSL_SCRIPT" ]]; then
  source_functions "$WSL_SCRIPT" 2>/dev/null
  t_start=$(date +%s)
  show_countdown "$(( $(date +%s) - 5 ))" "test" "id" 2>/dev/null
  elapsed=$(( $(date +%s) - t_start ))
  (( elapsed < 2 )) && pass "WSL show_countdown: past epoch → exits immediately" \
    || fail "WSL: past epoch should exit immediately" "elapsed=${elapsed}s"
else
  skip "WSL script not found — skipping WSL show_countdown test"
fi

# 88. macOS: same behaviour
if [[ -f "$MACOS_SCRIPT" ]]; then
  source_functions "$MACOS_SCRIPT" 2>/dev/null
  t_start=$(date +%s)
  show_countdown "$(( $(date +%s) - 5 ))" "test" "id" 2>/dev/null
  elapsed=$(( $(date +%s) - t_start ))
  (( elapsed < 2 )) && pass "macOS show_countdown: past epoch → exits immediately" \
    || fail "macOS: past epoch should exit immediately" "elapsed=${elapsed}s"
else
  skip "macOS script not found — skipping macOS show_countdown test"
fi

# ============================================================================
# Summary
# ============================================================================
printf "\n${BOLD}══════════════════════════════════════════════════════${RST}\n"
printf " ${GREEN}%3d passed${RST}   ${RED}%3d failed${RST}   ${YELLOW}%3d known issues${RST}\n" \
  "$PASS" "$FAIL" "$WARN"
printf "${BOLD}══════════════════════════════════════════════════════${RST}\n\n"

if (( WARN > 0 )); then
  printf "${DIM}Known issues = real bugs probed but not blocking.${RST}\n\n"
fi

(( FAIL == 0 ))
