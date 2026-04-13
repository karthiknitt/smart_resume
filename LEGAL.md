# Legal & Compliance Notes

## Does Smart Resume violate Anthropic's Terms of Service?

> **Disclaimer:** This is not legal advice. Review [Anthropic's current Terms of Service](https://www.anthropic.com/legal/consumer-terms) and [Acceptable Use Policy](https://www.anthropic.com/legal/aup) yourself before drawing conclusions. If you need certainty, consult a lawyer or contact Anthropic directly.

---

## What Smart Resume Actually Does

| Action | Detail |
|--------|--------|
| Reads local JSONL files | Written by Claude Code itself to `~/.claude/projects/` on your own machine. No Anthropic server is contacted. |
| Sends SIGINT to a local process | A standard Unix signal to a process you own. |
| Calls `claude --resume` | An official, documented CLI feature. |
| Uses the statusline hook | An officially documented hook system that Claude Code exposes. |

---

## The Critical Question: Does It Circumvent Rate Limits?

**No** — and this is the key distinction. Smart Resume waits for the rate limit to fully
expire as reported by Anthropic's own system, then resumes. It does not:

- Reduce the wait window
- Make additional requests during the limit period
- Find a workaround that bypasses the limit

A user doing this manually — noting the reset time, setting an alarm, resuming — would
be doing exactly the same thing. Smart Resume automates the waiting, not the bypass.

---

## Potential Grey Area: Unattended Automation

Running Claude Code unattended on a VPS through multiple rate-limit cycles is a pattern
Anthropic likely anticipated. Claude Code has explicit support for agentic and automated
use cases (`--dangerously-skip-permissions`, hooks, session resume). Smart Resume does
not increase request volume beyond what the user would generate interactively.

---

## What It Clearly Does NOT Do

- Bypass, reduce, or spoof rate limit windows
- Access Anthropic's API directly or outside the official CLI
- Scrape or exfiltrate data from Anthropic's servers
- Impersonate users or forge sessions
- Violate any content policies

---

## Assessment

Smart Resume is a quality-of-life wrapper around officially supported Claude Code CLI
features. It respects rate limits in full and operates entirely on local files that
Claude Code itself writes to the user's machine.

The disclaimer in the README — that this project is not affiliated with or endorsed by
Anthropic — is the correct posture regardless of compliance status.

For definitive answers, refer to:
- [Anthropic Terms of Service](https://www.anthropic.com/legal/consumer-terms)
- [Anthropic Acceptable Use Policy](https://www.anthropic.com/legal/aup)

Or contact Anthropic directly, since this is a public open-source tool.
