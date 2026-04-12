# Smart Resume for Claude Code — by Karthikeyan N (MIT License)

## The Problem

Claude Code enforces two rate limit windows: **5-hour** and **7-day**. When limits
are hit, Claude exits mid-session. Without this setup, you'd have to remember to
manually resume later — and you'd have no idea when "later" is.

## The Solution

A foreground wrapper script (`claude-smart-resume.sh`) that sits between your shell
and the real `claude` binary. It:

1. Runs Claude normally
2. On exit, checks the session file for a rate limit error
3. Parses the **exact reset time** from the error message
4. Sleeps precisely until then (one sleep, wakes at the right moment — no polling)
5. Resumes the same session in your foreground terminal

---

## Files

| File | Purpose |
|------|---------|
| `~/.claude/claude-smart-resume.sh` | The wrapper script — core of this setup |
| `~/.zshrc` | `alias claude=...` pointing to the wrapper |

---

## How It Works, Step by Step

### 1. You type any claude command

The alias in `~/.zshrc` intercepts it:

```zsh
alias claude="$HOME/.claude/claude-smart-resume.sh"
```

The wrapper calls the real binary at `/home/karthik/.local/bin/claude` with your
original arguments. Claude runs normally in your terminal.

---

### 2. Rate limit hits

Claude Code prints its own rate limit message and exits. The wrapper reads the most
recently modified `.jsonl` file for your current directory:

```
~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl
```

Claude stores every message — including API errors — in this file. The rate limit
error contains the reset time:

```
"You're out of extra usage · resets 7:30pm (Asia/Calcutta)"
```

The wrapper extracts `7:30pm` and `Asia/Calcutta` from this text.

---

### 3. Session is auto-named

If you didn't name your session with `--name` or `/rename`, the wrapper appends a
`custom-title` entry directly to the `.jsonl` (same mechanism `/rename` uses):

```json
{"type":"custom-title","customTitle":"rl-2026-04-12-projects-photomind","sessionId":"..."}
```

Format: `rl-<date>-<parent-dir>-<project-dir>`

If the session already has a name, it's left unchanged.

---

### 4. Precise sleep

The exact sleep duration is calculated once and slept in a single call — no polling loop:

```zsh
reset_epoch=$(TZ="Asia/Calcutta" date -d "7:30pm" +%s)
wake_epoch=$(( reset_epoch + 60 ))   # 1-minute buffer
sleep $(( wake_epoch - $(date +%s) ))
```

The banner printed in step 2 already shows the exact wake time. No countdown is
displayed during the wait. Press Ctrl-C at any time to cancel; the script will
print the manual resume command and exit.

---

### 5. Foreground resume

When the sleep ends, the wrapper calls:

```zsh
claude --resume <session-uuid> "Rate limits have reset — continuing where we left off."
```

The session resumes in your **same terminal window**. If that resumed session also
hits a rate limit, the whole process repeats automatically.

---

## How Your Existing Aliases Work

All your existing aliases already call `claude`, which zsh expands through the
wrapper alias. So they all get auto-resume for free:

| Alias | Expands to | Wrapper applies? |
|-------|-----------|-----------------|
| `cc` | `claude` | Yes |
| `ccam` | `claude --permission-mode auto` | Yes |
| `cdsp` | `claude --dangerously-skip-permissions` | Yes |
| `cdspr` | `claude --dangerously-skip-permissions --resume` | Yes |
| `ccr` | `claude --resume` | Yes |
| `ccp` | `claude --permission-mode plan` | Yes |
| `cctg` | `env -u TELEGRAM_BOT_TOKEN claude --channels ...` | **No** |

**Why `cctg` is different:** `env` executes the command it's given by looking up
`claude` in `$PATH` — it doesn't go through shell alias expansion. So `cctg` calls
the real binary directly and bypasses the wrapper. This is fine: `cctg` is a
channel listener, not an interactive session, so auto-resume doesn't make sense
for it anyway.

**`cdspr` note:** On first invocation, the wrapper passes `--resume` through to
claude, which opens the interactive session picker as normal. If *that* resumed
session then hits a rate limit, the wrapper takes over and resumes by UUID.

---

## Tuning

Two constants at the top of `~/.claude/claude-smart-resume.sh`:

```zsh
CLAUDE_BIN="/home/karthik/.local/bin/claude"   # path to real claude binary
BUFFER_SECS=60                                  # wait after reset (default: 1 min)
```

---

## Opting Out

To run claude without the wrapper for one command:

```zsh
/home/karthik/.local/bin/claude [args]
```

To permanently remove the wrapper, delete the alias line from `~/.zshrc`.

---

## Limitations

- **Requires clean exit:** If Claude crashes or is force-killed, the `.jsonl` may
  not have the rate limit error and the wrapper won't trigger.
- **CWD must match:** Session lookup is based on your current directory. If you
  `cd` elsewhere, it falls back to the globally most-recent session.
- **Only handles rate limits:** Other exit reasons (crash, Ctrl-C, permission
  denied) are treated as clean exits and the loop stops.
