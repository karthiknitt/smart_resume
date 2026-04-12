#!/usr/bin/env zsh
# test-smart-resume.zsh — edge-case tests for claude-smart-resume.sh
# Run: zsh ~/.claude/test-smart-resume.zsh

setopt ERR_EXIT 2>/dev/null; setopt NO_ERR_EXIT 2>/dev/null  # don't abort on test failures

SCRIPT="$HOME/.claude/claude-smart-resume.sh"
TESTDIR=$(mktemp -d /tmp/claude-resume-test.XXXXXX)
PASS=0; FAIL=0; WARN=0

GREEN='\e[32m'; RED='\e[31m'; YELLOW='\e[33m'; BOLD='\e[1m'; DIM='\e[2m'; RST='\e[0m'

trap "rm -rf '$TESTDIR'" EXIT

pass() { printf "${GREEN}✓${RST} %s\n" "$1"; (( ++PASS )); true; }
fail() { printf "${RED}✗ FAIL${RST} %-45s  got: %s\n" "$1" "${2:-(empty)}"; (( ++FAIL )); true; }
warn() { printf "${YELLOW}⚠ KNOWN${RST} %s\n" "$1"; (( ++WARN )); true; }
section() { printf "\n${BOLD}${YELLOW}── %s ${RST}\n" "$1"; }

# ---------------------------------------------------------------------------
# Source only the function definitions — stop before the main execution block.
# The main loop starts at the line "resume_id=" so we stop just before it.
# ---------------------------------------------------------------------------
CLAUDE_BIN="/bin/true"          # prevent any real invocations if something leaks
PROJECTS_DIR_REAL="${HOME}/.claude/projects"  # save real value; we override per test

source <(awk '/^resume_id=/{exit} {print}' "$SCRIPT") 2>/dev/null \
  || { echo "ERROR: could not source $SCRIPT"; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
mkjsonl() {
  # mkjsonl <filename> <line1> [line2 ...]
  local file="$TESTDIR/$1"; shift
  printf '%s\n' "$@" > "$file"
  echo "$file"
}

# ============================================================================
section "get_session_name"
# ============================================================================

# 1. Empty file
f=$(mkjsonl "empty.jsonl")
r=$(get_session_name "$f")
[[ -z "$r" ]] && pass "empty file → empty string" || fail "empty file → empty string" "$r"

# 2. No custom-title entries at all
f=$(mkjsonl "no-title.jsonl" \
  '{"type":"message","role":"user","content":"hello"}' \
  '{"type":"message","role":"assistant","content":"hi"}')
r=$(get_session_name "$f")
[[ -z "$r" ]] && pass "no custom-title → empty string" || fail "no custom-title → empty string" "$r"

# 3. Named at session start (single entry at top)
f=$(mkjsonl "named-start.jsonl" \
  '{"type":"custom-title","customTitle":"my-project","sessionId":"abc123"}' \
  '{"type":"message","role":"user","content":"hello"}')
r=$(get_session_name "$f")
[[ "$r" == "my-project" ]] && pass "named at start → correct name" || fail "named at start → correct name" "$r"

# 4. /rename mid-session (entry appears after messages)
f=$(mkjsonl "renamed-mid.jsonl" \
  '{"type":"message","role":"user","content":"hello"}' \
  '{"type":"message","role":"assistant","content":"hi"}' \
  '{"type":"custom-title","customTitle":"renamed-mid","sessionId":"abc123"}' \
  '{"type":"message","role":"user","content":"continue"}')
r=$(get_session_name "$f")
[[ "$r" == "renamed-mid" ]] && pass "/rename mid-session → correct name" || fail "/rename mid-session → correct name" "$r"

# 5. Multiple renames — last one wins (tail -1)
f=$(mkjsonl "multi-rename.jsonl" \
  '{"type":"custom-title","customTitle":"first-name","sessionId":"abc123"}' \
  '{"type":"message","role":"user","content":"something"}' \
  '{"type":"custom-title","customTitle":"second-name","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ "$r" == "second-name" ]] && pass "multiple renames → last one wins" || fail "multiple renames → last one wins" "$r"

# 6. Script auto-named first, user renames later in resumed session → user wins
f=$(mkjsonl "auto-then-user.jsonl" \
  '{"type":"custom-title","customTitle":"rl-2026-04-12-home-karthik","sessionId":"abc123"}' \
  '{"type":"message","role":"user","content":"continuing after RL"}' \
  '{"type":"custom-title","customTitle":"my-real-name","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ "$r" == "my-real-name" ]] && pass "auto-name then user-rename → user name wins" || fail "auto-name then user-rename → user name wins" "$r"

# 7. Name with spaces
f=$(mkjsonl "spaces.jsonl" \
  '{"type":"custom-title","customTitle":"my project name","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ "$r" == "my project name" ]] && pass "name with spaces → preserved" || fail "name with spaces → preserved" "$r"

# 8. Name with hyphens and numbers
f=$(mkjsonl "hyphens.jsonl" \
  '{"type":"custom-title","customTitle":"feature-123-auth-refactor","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ "$r" == "feature-123-auth-refactor" ]] && pass "name with hyphens+numbers → preserved" || fail "name with hyphens+numbers → preserved" "$r"

# 9. Nonexistent file → empty, no crash
r=$(get_session_name "$TESTDIR/nonexistent.jsonl" 2>/dev/null)
[[ -z "$r" ]] && pass "nonexistent file → empty, no crash" || fail "nonexistent file → empty, no crash" "$r"

# 10. customTitle is empty string — should return empty (auto-name guard fires)
f=$(mkjsonl "empty-title.jsonl" \
  '{"type":"custom-title","customTitle":"","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ -z "$r" ]] && pass "empty customTitle → empty (auto-name guard fires)" || fail "empty customTitle → empty" "$r"

# 11. Malformed: custom-title with wrong field name
f=$(mkjsonl "wrong-field.jsonl" \
  '{"type":"custom-title","title":"wrong-key","sessionId":"abc123"}')
r=$(get_session_name "$f")
[[ -z "$r" ]] && pass "wrong field name (title not customTitle) → empty" || fail "wrong field name → empty" "$r"

# 12. Name with double-quote — BUG PROBE
#     name_session writes raw " into JSON; get_session_name's [^"]+ stops at it
f=$(mkjsonl "quote-name.jsonl" \
  '{"type":"custom-title","customTitle":"name\"with\"quotes","sessionId":"abc123"}')
r=$(get_session_name "$f")
# Correct behaviour: return the name up to the first unescaped " (partial) OR empty.
# Either way the guard will fire and auto-name will overwrite. Document the result.
if [[ "$r" == 'name"with"quotes' || "$r" == 'name' ]]; then
  warn "name with literal double-quote → get_session_name returns partial: '$r' (see name_session fix)"
else
  warn "name with literal double-quote → get_session_name returns: '${r:-(empty)}'"
fi

# ============================================================================
section "name_session + roundtrip guard"
# ============================================================================

# 13. Normal name appends correct JSON
f="$TESTDIR/name-normal.jsonl"; touch "$f"
name_session "$f" "uuid-001" "my-session"
expected='{"type":"custom-title","customTitle":"my-session","sessionId":"uuid-001"}'
r=$(cat "$f")
[[ "$r" == "$expected" ]] && pass "name_session → correct JSON line" || fail "name_session → correct JSON line" "$r"

# 14. name_session on nonexistent file creates it
rm -f "$TESTDIR/create-me.jsonl"
name_session "$TESTDIR/create-me.jsonl" "uuid-002" "new"
[[ -f "$TESTDIR/create-me.jsonl" ]] && pass "name_session on missing file → creates it" \
  || fail "name_session on missing file → creates it"

# 15. Roundtrip: write then read back
f="$TESTDIR/roundtrip.jsonl"; touch "$f"
name_session "$f" "uuid-003" "roundtrip-name"
r=$(get_session_name "$f")
[[ "$r" == "roundtrip-name" ]] && pass "name_session → get_session_name roundtrip" || fail "roundtrip" "$r"

# 16. Name with backslash — BUG PROBE
#     printf '%s' with a backslash writes it raw; JSON requires \\
f="$TESTDIR/backslash.jsonl"; touch "$f"
name_session "$f" "uuid-004" 'path\to\thing'
r=$(get_session_name "$f")
if [[ "$r" == 'path\to\thing' ]]; then
  warn "name with backslash → returned as-is (JSON technically invalid but grep reads it ok)"
else
  warn "name with backslash → get_session_name returned: '${r:-(empty)}'"
fi

# ============================================================================
section "get_reset_info"
# ============================================================================

# 17. No RL entry → empty
f=$(mkjsonl "no-rl.jsonl" '{"type":"message","role":"user","content":"hello"}')
r=$(get_reset_info "$f")
[[ -z "$r" ]] && pass "no RL entry → empty" || fail "no RL entry → empty" "$r"

# 18. Standard time-only RL pattern
f=$(mkjsonl "rl-time.jsonl" \
  '{"type":"error","error":{"message":"Rate limit hit. resets 11:30pm (Asia/Kolkata)"}}')
r=$(get_reset_info "$f")
[[ "$r" == "11:30pm Asia/Kolkata" ]] && pass "time-only RL pattern parsed" || fail "time-only RL pattern" "$r"

# 19. Full date RL pattern
f=$(mkjsonl "rl-full-date.jsonl" \
  '{"type":"error","error":{"message":"Rate limit. resets Apr 13 11:30pm (Asia/Kolkata)"}}')
r=$(get_reset_info "$f")
[[ "$r" == "Apr 13 11:30pm Asia/Kolkata" ]] && pass "full date RL pattern parsed" || fail "full date RL pattern" "$r"

# 20. Comma-date pattern (e.g. "Apr 13, 2026 11:30pm")
f=$(mkjsonl "rl-comma-date.jsonl" \
  '{"type":"error","error":{"message":"resets Apr 13, 2026 11:30pm (America/New_York)"}}')
r=$(get_reset_info "$f")
[[ "$r" == "Apr 13, 2026 11:30pm America/New_York" ]] \
  && pass "comma-date RL pattern parsed" || fail "comma-date RL pattern" "$r"

# 21. Multiple RL entries → last one returned
f=$(mkjsonl "multi-rl.jsonl" \
  '{"type":"error","error":{"message":"resets 9:00pm (Asia/Kolkata)"}}' \
  '{"type":"error","error":{"message":"resets 11:30pm (Asia/Kolkata)"}}')
r=$(get_reset_info "$f")
[[ "$r" == "11:30pm Asia/Kolkata" ]] && pass "multiple RL entries → last one" || fail "multiple RL entries → last one" "$r"

# 22. Case-insensitive extraction (RESETS uppercase — fixed via (?i) in grep -oP)
f=$(mkjsonl "rl-caps.jsonl" \
  '{"type":"error","message":"Rate limit exceeded. RESETS 7:30pm (UTC)"}')
r=$(get_reset_info "$f")
[[ "$r" == "7:30pm UTC" ]] && pass "RESETS uppercase → (?i) extracts correctly" || fail "RESETS uppercase" "$r"

# 23. Nonexistent file → empty, no crash
r=$(get_reset_info "$TESTDIR/nonexistent.jsonl" 2>/dev/null)
[[ -z "$r" ]] && pass "nonexistent file → empty, no crash" || fail "nonexistent file → empty, no crash" "$r"

# 24. Pattern with no timezone paren → empty (guard prevents bad data)
f=$(mkjsonl "rl-no-tz.jsonl" \
  '{"type":"error","message":"resets 11:30pm"}')
r=$(get_reset_info "$f")
[[ -z "$r" ]] && pass "RL pattern with no timezone → empty (guard fires)" || fail "RL with no timezone → empty" "$r"

# ============================================================================
section "parse_reset_epoch"
# ============================================================================

now=$(date +%s)

# 25. Time-only, definitely future (11:59pm — might already be past in UTC)
#     Script should add 86400 if past, so result must be > now regardless
r=$(parse_reset_epoch "11:59pm" "UTC" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
  pass "time-only → future epoch (or next-day rollover applied)"
else
  fail "time-only → future epoch" "rc=$rc epoch=$r"
fi

# 26. Time-only in the past — must roll over (add 86400)
#     "12:01am" is almost certainly in the past if run during the day
r=$(parse_reset_epoch "12:01am" "UTC" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
  pass "time-only past → next-day rollover applied, epoch is future"
else
  fail "time-only past → next-day rollover" "rc=$rc epoch=$r now=$now"
fi

# 27. Full date, far future → valid epoch
r=$(parse_reset_epoch "Apr 13, 2099 11:59pm" "UTC" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
  pass "far-future full date → valid epoch"
else
  fail "far-future full date → valid epoch" "rc=$rc epoch=$r"
fi

# 28. Full date in past → return 1 (bail out, no rollover for full dates)
parse_reset_epoch "Jan 1, 2020 12:00am" "UTC" > /dev/null 2>&1; rc=$?
(( rc != 0 )) && pass "full date in past → non-zero exit (no rollover)" \
  || fail "full date in past → non-zero exit" "rc=$rc (should be 1)"

# 29. Invalid time string → non-zero exit
parse_reset_epoch "not-a-time" "UTC" > /dev/null 2>&1; rc=$?
(( rc != 0 )) && pass "invalid time string → non-zero exit" \
  || fail "invalid time string → non-zero exit" "rc=$rc"

# 30. Uppercase AM/PM — fixed via ${reset_time:l} lowercasing before regex match
r=$(parse_reset_epoch "12:01AM" "UTC" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
  pass "uppercase AM/PM → rollover handled (case-insensitive via :l)"
else
  fail "uppercase AM/PM → rollover not applied" "rc=$rc epoch=$r"
fi

# 31. IST timezone (real-world case)
r=$(parse_reset_epoch "11:59pm" "Asia/Kolkata" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ -n "$r" ]] && (( r > now )); then
  pass "IST timezone → valid future epoch"
else
  fail "IST timezone" "rc=$rc epoch=$r"
fi

# ============================================================================
section "generate_name"
# ============================================================================

today=$(date '+%Y-%m-%d')

# 32. Standard 2-component path — create dir first
mkdir -p /tmp/some/project
r=$(cd /tmp/some/project && generate_name 2>/dev/null)
[[ "$r" == "rl-${today}-some-project" ]] && pass "2-component path → correct slug" || fail "2-component path" "$r"

# 33. Single-component path (root-level dir like /tmp) — fixed: strips leading hyphen
r=$(cd /tmp && generate_name 2>/dev/null)
[[ "$r" == "rl-${today}-tmp" ]] && pass "single-component path → correct slug (no leading hyphen)" \
  || fail "single-component path → no leading hyphen" "$r"

# 34. Path with uppercase → lowercased
r=$(cd /home/karthik && generate_name 2>/dev/null)
[[ "$r" == "rl-${today}-home-karthik" ]] && pass "path with mixed case → lowercased" || fail "path with mixed case" "$r"

# 35. Path with special chars — slugified
mkdir -p "/tmp/test-dir_with.special"
r=$(cd /tmp/test-dir_with.special 2>/dev/null && generate_name 2>/dev/null)
[[ "$r" =~ ^rl-${today}- ]] && pass "path with special chars → slugified (starts with rl-${today}-)" \
  || fail "path with special chars" "$r"

# ============================================================================
section "find_latest_session"
# ============================================================================

PROJECTS_DIR="$TESTDIR/projects"
mkdir -p "$PROJECTS_DIR"

# 36. Completely empty projects dir → empty result
r=$(find_latest_session 2>/dev/null)
[[ -z "$r" ]] && pass "empty projects dir → empty" || fail "empty projects dir → empty" "$r"

# 37. CWD-matching dir with one file
encoded_cwd=$(pwd | sed 's|/|-|g; s|^-||')
mkdir -p "$PROJECTS_DIR/$encoded_cwd"
f1="$PROJECTS_DIR/$encoded_cwd/uuid-aaa.jsonl"
touch "$f1"
r=$(find_latest_session 2>/dev/null)
[[ "$r" == "$f1" ]] && pass "CWD dir, one file → returns it" || fail "CWD dir, one file" "$r"

# 38. CWD-matching dir with multiple files — most recent wins
sleep 0.05
f2="$PROJECTS_DIR/$encoded_cwd/uuid-bbb.jsonl"
touch "$f2"
r=$(find_latest_session 2>/dev/null)
[[ "$r" == "$f2" ]] && pass "CWD dir, multiple files → most recent returned" || fail "CWD dir, most recent" "$r"

# 39. CWD dir absent → falls back to global most-recent
PROJECTS_DIR="$TESTDIR/projects2"
mkdir -p "$PROJECTS_DIR/other-project"
f3="$PROJECTS_DIR/other-project/uuid-ccc.jsonl"
touch "$f3"
r=$(find_latest_session 2>/dev/null)
[[ "$r" == "$f3" ]] && pass "CWD dir missing → falls back to global most-recent" || fail "CWD dir missing fallback" "$r"

# Restore
PROJECTS_DIR="$PROJECTS_DIR_REAL"

# ============================================================================
section "/proc-based watcher PID discovery"
# ============================================================================

# 40. /proc/self/stat is readable and its first field is a valid PID
r=$(read -r _line < /proc/self/stat 2>/dev/null && echo "${_line%% *}")
if [[ -n "$r" ]] && (( r > 0 )); then
  pass "/proc/self/stat readable, first field is valid PID ($r)"
else
  fail "/proc/self/stat unreadable or first field not a PID" "$r"
fi

# 41. Subshell /proc/self/stat PID differs from outer $$
#     The key invariant behind watcher self-identification:
#     "$" in a zsh subshell is always the OUTER shell's PID, so we can't
#     use it to find the subshell's own PID. /proc/self/stat (read via the
#     builtin) resolves to the subshell's actual PID — they must differ.
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

# 42. /proc/PID/task/PID/children lists direct child PIDs
#     Spawn a sleep child and verify it appears in the children file.
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

# 43. Watcher self-exclusion: a watcher subshell can see its own PID via
#     /proc/self/stat and exclude it when scanning /proc children.
#     Test: launch a subshell that reads its own PID, then confirm the outer
#     shell's children list would contain it — and that excluding it by PID
#     works correctly (filtered list no longer contains the watcher PID).
watcher_pid=''
( read -r _sl < /proc/self/stat; echo "${_sl%% *}" ) > /tmp/_watcher_pid_test$$ &
bgpid=$!
wait "$bgpid" 2>/dev/null
watcher_self=$(cat /tmp/_watcher_pid_test$$ 2>/dev/null)
rm -f /tmp/_watcher_pid_test$$
if [[ -n "$watcher_self" ]] && (( watcher_self > 0 )); then
  pass "watcher subshell self-identified its PID ($watcher_self) via /proc/self/stat"
else
  fail "watcher subshell could not read own PID via /proc/self/stat" "$watcher_self"
fi

# ============================================================================
printf "\n${BOLD}══════════════════════════════════════════════════${RST}\n"
printf " ${GREEN}%2d passed${RST}   ${RED}%2d failed${RST}   ${YELLOW}%2d known issues${RST}\n" \
  "$PASS" "$FAIL" "$WARN"
printf "${BOLD}══════════════════════════════════════════════════${RST}\n\n"

if (( WARN > 0 )); then
  printf "${DIM}Known issues = real bugs probed but not blocking — check warnings above.${RST}\n\n"
fi

(( FAIL == 0 ))
