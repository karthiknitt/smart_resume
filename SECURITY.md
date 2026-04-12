# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

If you discover a security issue in Smart Resume, please report it privately:

1. Go to the [Security tab](https://github.com/karthiknitt/smart_resume/security)
   and use **"Report a vulnerability"** to open a private advisory.
2. Include a clear description of the issue, steps to reproduce, and potential impact.

You will receive a response within **7 days**. If the issue is confirmed, a fix
will be released as soon as possible and you will be credited in the release notes
(unless you prefer to remain anonymous).

## Scope

This project is a shell script wrapper. Relevant security concerns include:

- **Arbitrary command execution** via unsanitised input (e.g. session file paths,
  environment variables)
- **Privilege escalation** — the script should never require or request elevated
  privileges
- **Unintended credential exposure** — the script reads Claude session JSONL files;
  it must never log or transmit their contents
- **Race conditions** in the watcher that could cause unintended SIGINT delivery
  to the wrong process
