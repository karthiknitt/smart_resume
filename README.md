# Smart Resume For Claude Code

**Author: Karthikeyan N
 License: MIT License**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-blue.svg)](#)
[![Shell: bash / zsh](https://img.shields.io/badge/Shell-bash%20%2F%20zsh-green.svg)](#)
[![macOS: Coming v0.3](https://img.shields.io/badge/macOS-Coming%20v0.3-lightgrey.svg)](#platforms)
[![Windows WSL](https://img.shields.io/badge/Windows%20WSL-v0.2-blue.svg)](#platforms)

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
  ╭────────────────────────────────────────────────────────────╮
  │  Smart Resume for Claude Code  ·  Karthikeyan N  ·  MIT License  │
  ╰────────────────────────────────────────────────────────────╯

  ⚡ Rate limit hit
  ──────────────────────────────────────────────────────────────────
  Session  "rl-2026-04-12-projects-myapp"
  Resets   00:30:00 IST  (2026-04-13)
  Waking   00:31:00 IST  (+60s buffer)
  ──────────────────────────────────────────────────────────────────
  Press Ctrl-C to cancel

    Waiting until reset.  Remaining: 4 min 23s

  ╭──────────────────────────────────────────────╮
  │  ✓ Resuming  "rl-2026-04-12-projects-myapp"  │
  ╰──────────────────────────────────────────────╯
```

---

## What It Does

- **Detects rate limits automatically** — no menu interaction required
- **Waits precisely** until the reset time, then resumes in the same terminal
- **Live countdown** ticks every second in place — single updating line, no scroll
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

A shell wrapper around the real `claude` binary. It runs two tasks in parallel:

- **Runs claude in the foreground** — the process inherits your terminal directly,
  so interactive features, colours, and input all work normally.
- **Polls the session JSONL in the background** — once the session file appears,
  checks every 5 s for a rate-limit line. The moment one is detected, it sends
  `SIGINT` to Claude — bypassing the interactive exit menu. Claude exits cleanly.

After Claude exits, the wrapper reads the reset epoch (from the `~/.claude/.rl_warn`
flag file if available, or by parsing the JSONL as fallback) and sleeps precisely
until then. It then resumes via `claude --resume <session-uuid>`.

> **Note:** `statusline.sh` is not required for auto-detection. JSONL polling starts
> immediately after the session file appears. The flag file is used only as a faster,
> already-parsed source of the reset epoch — it skips the JSONL grep entirely.

### 3. The flag file — `~/.claude/.rl_warn`

The shared signal between sensor and watcher. Contains pre-computed reset epochs so
no timestamp parsing ever happens in the critical path.

---

## Dependencies

The installer checks for all required packages before proceeding. If anything is
missing it prints the exact install command and exits — install the deps, then
re-run `./install.sh`.

### All platforms

| Package | Purpose | Required |
|---------|---------|:--------:|
| `jq` | Auto-patches `~/.claude/settings.json` with the statusLine hook | ✅ |

`zsh` is **not** required. The wrapper runs under `bash` (4+) or `zsh` — whichever
your system provides.

### macOS only

| Package | Purpose | Required |
|---------|---------|:--------:|
| `python3` | Parses timezone-aware reset times (BSD `date` lacks `-d`) | ✅ |

### Linux / WSL (typically pre-installed)

| Package | Purpose |
|---------|---------|
| `awk`, `sed` | JSONL parsing and path encoding |
| `grep` (with `-oP`) | Perl-regex reset-time extraction |
| `pgrep` | Process-discovery fallback |
| GNU `date` | Epoch arithmetic (`date -d`) |

**Install commands by platform** (if you need them):

```bash
# Debian / Ubuntu / WSL
sudo apt-get install -y jq

# Fedora / RHEL
sudo dnf install -y jq

# Arch
sudo pacman -S --noconfirm jq

# macOS (Homebrew)
brew install jq python3
```

---

## Installation

### Quick Install (recommended)

```bash
git clone https://github.com/karthiknitt/smart_resume.git
cd smart_resume
./install.sh
```

The installer will:
1. Check all required dependencies — prints the install command and exits if anything is missing
2. Detect your `claude` binary path automatically
3. Copy `claude-smart-resume.sh` and `statusline.sh` to `~/.claude/`
4. Patch the wrapper with your detected binary path
5. Offer to add the alias to your `~/.zshrc` or `~/.bashrc` and source it immediately
6. Register the `statusLine` hook in `~/.claude/settings.json`
7. Print a summary of everything done

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

```bash
CLAUDE_BIN="/home/yourname/.local/bin/claude"   # replace with your actual path
```

**Step 3 — Add the alias**

Add to your `~/.bashrc` or `~/.zshrc`:

```bash
alias claude="$HOME/.claude/claude-smart-resume.sh"
```

Reload your shell:

```bash
source ~/.bashrc   # or source ~/.zshrc
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

## Windows (WSL) Notes

WSL runs a full Linux kernel, so Smart Resume works identically to the Linux version.
The installer auto-detects WSL and copies the correct wrapper automatically.

**One WSL-specific consideration: where Claude Code stores sessions.**

**Option A — Claude installed natively inside WSL** (most common):

Sessions are stored at `~/.claude/projects/` inside WSL. No extra config needed —
the installer handles everything.

**Option B — Windows Claude Code app called via WSL path interop:**

Sessions are stored in the Windows user profile. After installation, open
`~/.claude/claude-smart-resume.sh` and update the path variables at the top:

```bash
WIN_USER="YourWindowsUsername"
CLAUDE_BIN="/mnt/c/Users/${WIN_USER}/AppData/Local/AnthropicClaude/claude.exe"
PROJECTS_DIR="/mnt/c/Users/${WIN_USER}/AppData/Roaming/Claude/projects"
```

**To check which applies:** run `ls ~/.claude/projects/` after a Claude session.
If the directory is empty, sessions are going to the Windows path (Option B).

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

```bash
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
  Cancelled. Resume manually:
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
command claude [args]   # bypasses alias in both bash and zsh
```

---

## Other Aliases

Shorthand aliases get auto-resume automatically — the shell expands `claude` through
the wrapper:

```bash
alias cc='claude'
alias cca='claude --permission-mode auto'
alias ccr='claude --resume'
alias ccskip='claude --dangerously-skip-permissions'
```

**One exception:** aliases using `env` or `command` bypass alias expansion:

```bash
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
| Windows (WSL) | **Available — v0.2** |
| macOS | Coming in v0.3 |

---

## Recommended Setup

### Run inside a tmux session

It is strongly recommended to run Claude Code — and therefore this wrapper — inside
a **tmux** session. Because Smart Resume sleeps for hours between a rate-limit hit and
the next resume, the process must stay alive for the full duration. A tmux session is
decoupled from your terminal emulator: if the terminal window closes, the connection
drops, or SSH times out, the tmux session continues running on the host and can be
reattached at any time.

```bash
tmux new-session -s claude    # start a named session
claude                        # run as normal — wrapper takes over on RL hit
# detach with Ctrl-b d; reattach later with: tmux attach -t claude
```

The countdown and resume happen entirely within the tmux pane. You can detach, close
your laptop, and come back hours later to find the session already resumed and working.

### Run on an always-on machine

For fully unattended operation, run Claude Code on a machine that stays online
continuously — a VPS, a home server, or any persistent Linux host. Combined with
tmux, this means:

- Rate limit hits are handled automatically with no human intervention
- The resumed session picks up exactly where it left off
- You are free to close your local machine entirely between rate limit windows

This setup is particularly effective for long-running autonomous tasks where you
want Claude to work through rate limit cycles overnight or across multiple days
without requiring you to be present.

---

## Limitations

- **~5 s detection lag** — watcher polls every 5 s; the RL menu may flash briefly before `SIGINT`. Cosmetic only.
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
