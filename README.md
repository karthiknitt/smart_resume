# Smart Resume For Claude Code

**by Karthikeyan N · MIT License**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-blue.svg)](#)
[![Shell: zsh](https://img.shields.io/badge/Shell-zsh-green.svg)](#)
[![macOS: Coming v0.2](https://img.shields.io/badge/macOS-Coming%20v0.2-lightgrey.svg)](#platforms)
[![Windows WSL: Coming v0.2](https://img.shields.io/badge/Windows%20WSL-Coming%20v0.2-lightgrey.svg)](#platforms)

> [!IMPORTANT]
> **Disclaimer:** Claude Code is a product of Anthropic, PBC. "Claude" and "Claude Code"
> are trademarks of Anthropic. All rights to Claude Code and its associated trademarks
> and copyrights are owned by Anthropic. **Smart Resume** is an independently-built
> tool. It is not affiliated with, endorsed by, or officially connected to Anthropic in
> any way.

When Claude Code hits a rate limit, it exits mid-session. **Smart Resume** makes it
automatically wait until the limit clears and resume your session in the same terminal
window — no manual intervention, no lost context.

```
  ╭──────────────────────────────────────────────────────╮
  │  ⚡ Smart Resume  ·  Karthikeyan N  ·  MIT License   │
  ╰──────────────────────────────────────────────────────╯

  ⚡ Rate limit hit
  ──────────────────────────────────────────────────────
  Session  "rl-2026-04-12-projects-myapp"
  Resets   00:30:00 IST  (2026-04-13)
  Waking   00:31:00 IST  (+60s buffer)
  Wait     17280s  (288 min)
  ──────────────────────────────────────────────────────
  Press Ctrl-C to cancel

  ↻ 4:47:23 remaining — resuming "rl-2026-04-12-projects-myapp" at 00:31 IST
  Resuming "rl-2026-04-12-projects-myapp" ...
```

---

## What It Does

- **Detects rate limits automatically** — no menu interaction required
- **Waits precisely** until the reset time, then resumes in the same terminal
- **Live countdown** ticks every second in place — no scrolling output
- **Auto-names sessions** so they're easy to find in `/resume`
- **Chains** — if the resumed session also hits a limit, the whole process repeats

---

## How It Works

The system has three components that work together:

### 1. `statusline.sh` — the sensor

Claude Code calls this script each time it renders the status line (every response).
It receives rate-limit usage and exact reset timestamps from Claude's runtime. At
**90% usage** it writes a flag file to `~/.claude/.rl_warn` with pre-computed Unix
epochs — no text parsing needed in the hot path.

### 2. `claude-smart-resume.sh` — the watcher + scheduler

A shell wrapper around the real `claude` binary. It runs two phases in parallel:

- **Phase 1 (idle):** Checks for the `~/.claude/.rl_warn` flag every 5 seconds.
  Cost: one `stat()` call per 5 s.
- **Phase 2 (active, starts at 90%):** Once the flag appears, polls the session
  JSONL every 2 s. The moment it detects a rate-limit line, it sends `SIGINT` to
  Claude — bypassing the interactive exit menu. Claude exits cleanly.

After Claude exits, the wrapper reads the reset epoch from the flag file and sleeps
precisely until then. It then resumes via `claude --resume <session-uuid>`.

### 3. The flag file — `~/.claude/.rl_warn`

The shared signal between sensor and watcher. Contains pre-computed reset epochs so
no timestamp parsing ever happens in the critical path.

> **Graceful degradation:** If `statusline.sh` is not configured, the watcher stays
> in Phase 1 indefinitely (negligible cost) and falls back to parsing the JSONL for
> reset times. The tool still works — you just lose the optimised early-detection path.

---

## Installation

### Quick Install (recommended)

```bash
git clone https://github.com/karthiknitt/smart_resume.git
cd smart_resume
./install.sh
```

The installer will:
1. Detect your `claude` binary path automatically
2. Copy `claude-smart-resume.sh` and `statusline.sh` to `~/.claude/`
3. Patch the wrapper with your detected binary path
4. Offer to add the alias to your `~/.zshrc` or `~/.bashrc`
5. Offer to register the `statusLine` hook in `~/.claude/settings.json`
6. Print a summary of everything done

Running the installer twice is safe — it is fully **idempotent**.

**After installation, the cloned repo is no longer needed.** The scripts are copied
into `~/.claude/` — that is what runs. You can delete the repo directory:

```bash
cd .. && rm -rf smart_resume
```

---

### Manual Install

If you prefer to install without running a shell script:

**Step 1 — Copy the scripts**

```bash
cp src/claude-smart-resume.sh ~/.claude/
cp src/statusline.sh ~/.claude/
chmod +x ~/.claude/claude-smart-resume.sh ~/.claude/statusline.sh
```

**Step 2 — Set your Claude binary path**

Find your `claude` binary (run this **before** adding the alias):

```bash
which claude
```

Common locations:

| Install method | Typical path |
|----------------|-------------|
| npm (user) | `~/.local/bin/claude` |
| npm (global) | `/usr/local/bin/claude` |

Open `~/.claude/claude-smart-resume.sh` and set `CLAUDE_BIN` at the top:

```zsh
CLAUDE_BIN="/home/yourname/.local/bin/claude"   # replace with your actual path
```

**Step 3 — Add the alias**

Add to your `~/.zshrc` or `~/.bashrc`:

```zsh
alias claude="$HOME/.claude/claude-smart-resume.sh"
```

Reload your shell:

```bash
source ~/.zshrc   # or source ~/.bashrc
```

Verify:

```bash
type claude
# claude is an alias for /home/yourname/.claude/claude-smart-resume.sh
```

**Step 4 — Register the statusLine hook**

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/home/yourname/.claude/statusline.sh"
  }
}
```

Replace `/home/yourname` with your actual home directory path.

---

## Trusting Your Projects Folder

If Claude Code asks **"Do you trust this folder?"** every time you start a session
in your projects directory, you can suppress this prompt permanently by adding your
project directories to `permissions.additionalDirectories` in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "additionalDirectories": ["~/projects", "~/work"]
  }
}
```

This tells Claude Code to treat those directories as trusted — the prompt won't
appear again. Add any directory you work in regularly.

---

## Configuration

Two constants at the top of `~/.claude/claude-smart-resume.sh`:

```zsh
CLAUDE_BIN="/home/yourname/.local/bin/claude"   # path to real claude binary
BUFFER_SECS=60                                   # extra wait after reset (default: 1 min)
```

The 90% watcher threshold lives in `statusline.sh` — search for `rl_5h_int -ge 90`
to adjust it.

---

## Session Naming

If your session has no name, the wrapper auto-names it before sleeping:

```
rl-2026-04-12-projects-myapp
```

Format: `rl-<date>-<parent-dir>-<project-dir>`

If you already named the session (via `/rename` inside Claude or `--session-name`),
your name is preserved — the wrapper only auto-names unnamed sessions.

---

## Manual Resume

The wrapper resumes automatically. If you cancel the countdown (`Ctrl-C`) or need to
resume from a different terminal, the wrapper prints the exact command you need:

```
  Cancelled. Resume manually when limits clear:
    claude --resume a1b2c3d4-...
```

**Finding the UUID without the wrapper:**

```bash
# Most-recent session
find ~/.claude/projects -name "*.jsonl" -printf '%T@ %p\n' \
  | sort -rn | head -1 | awk '{print $2}' \
  | xargs basename | sed 's/\.jsonl//'
```

---

## Opting Out for One Command

```bash
command claude [args]   # bypasses alias in both zsh and bash
```

---

## Other Aliases

Shorthand aliases get auto-resume automatically — the shell expands `claude` through
the wrapper:

```zsh
alias cc='claude'
alias cca='claude --permission-mode auto'
alias ccr='claude --resume'
alias ccskip='claude --dangerously-skip-permissions'
```

**One exception:** aliases using `env` or `command` bypass alias expansion:

```zsh
# This does NOT go through the wrapper:
alias mybot='env -u MY_TOKEN claude --channels ...'

# Fix: point directly at the wrapper:
alias mybot="env -u MY_TOKEN $HOME/.claude/claude-smart-resume.sh --channels ..."
```

---

## Platforms

| Platform | Status |
|----------|--------|
| Linux | **Available — v0.1** |
| macOS | Coming in v0.2 |
| Windows (WSL) | Coming in v0.2 |

---

## Limitations

- **~2 s detection lag** — watcher polls every 2 s in Phase 2; the RL menu may flash briefly before `SIGINT`. Cosmetic only.
- **Blind before 90%** — if a hard cap hits before statusline reaches 90%, Phase 1 stays idle and the RL menu shows normally. Wrapper still resumes correctly after clean exit.
- **CWD-based session lookup** — session is found by current directory. Falls back to most-recent global session if you `cd` elsewhere.
- **Clean exit required** — if Claude crashes or is force-killed, the JSONL may not contain the rate-limit line and the wrapper won't trigger.

---

## Disclaimer

**Smart Resume** is an independently-built tool created by
[Karthikeyan N](https://github.com/karthiknitt).

- **Claude Code** is a product of [Anthropic, PBC](https://www.anthropic.com).
- **"Claude"** and **"Claude Code"** are trademarks of Anthropic. All rights to Claude Code
  and its associated trademarks, service marks, and copyrights are the exclusive property
  of Anthropic.
- This project is **not affiliated with, endorsed by, sponsored by, or officially connected
  to Anthropic** in any way.
- The name "Smart Resume For Claude Code" is used purely to describe what this tool does —
  it is not intended to imply any official relationship with Anthropic or the Claude product
  family.

Use of Claude Code itself is subject to [Anthropic's Terms of Service](https://www.anthropic.com/legal/consumer-terms).

---

## License

MIT License — Copyright (c) 2026 
Author: Karthikeyan N

See [LICENSE](LICENSE) for the full text.
