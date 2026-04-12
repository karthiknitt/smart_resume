# Contributing to Smart Resume

Thanks for your interest in contributing. This is a small, focused shell-script
project — contributions are welcome, but please read this first.

---

## Before You Open an Issue

- Check the [README](README.md) — your question may already be answered there.
- Search [existing issues](https://github.com/karthiknitt/smart_resume/issues)
  to avoid duplicates.

---

## Before You Open a Pull Request

- **Open an issue first** for anything beyond a trivial fix. This ensures we
  agree on direction before you invest time writing code.
- All PRs target `main` and require one review approval before merging.
  All merges are reviewed and approved by the maintainer.
- Keep PRs focused — one change per PR.

---

## Code Style

This project is zsh shell script. A few rules to follow:

- **ANSI output goes to stderr only** — never to stdout. The wrapper must not
  corrupt `--print` mode output.
  ```zsh
  printf '...' >&2   # correct
  printf '...'       # wrong — pollutes stdout
  ```

- **No `strings` on JSONL files** — use `grep -F` or `grep -oP`. `strings` can
  split JSON objects across lines, causing silent misses.

- **Idempotency in the installer** — `install.sh` must be safe to run twice.
  Check before writing; don't blindly append.

- **Keep the watcher silent** — the background watcher subshell must redirect
  all output to `/dev/null`:
  ```zsh
  ( ... ) > /dev/null 2>/dev/null &
  ```

- **Test both paths** — the flag-file fast path (statusline ≥ 90%) and the
  JSONL fallback path (no statusline configured).

---

## Test Suite

A test suite is included at `src/test-smart-resume.zsh` for developers who want
to explore or verify the core functions. It covers session naming, rate-limit
parsing, time/epoch logic, and PID discovery (43 tests). Run it with:

```bash
zsh src/test-smart-resume.zsh
```

It is not part of CI — it is reference material. Tests 40–43 (PID discovery via
`/proc`) only pass on Linux and WSL.

---

## Platforms

v0.1 added Linux. v0.2 added Windows WSL. macOS is planned for v0.3. If you are
contributing platform support, open an issue first to coordinate.

---

## Licensing

By submitting a pull request, you agree that your contribution will be licensed
under the [MIT License](LICENSE) that covers this project.
