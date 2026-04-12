## What does this PR do?

<!-- One clear sentence. -->

## Why?

<!-- The motivation. Link to a related issue if one exists: Fixes #123 -->

## Changes

<!-- Bullet list of what changed and where. -->

- 

## Testing

<!-- How did you verify this works? What edge cases did you check? -->

- [ ] Tested on Linux with zsh
- [ ] Tested rate-limit detection path (Phase 2 watcher)
- [ ] Tested countdown and auto-resume loop
- [ ] No regressions in existing behaviour

## Checklist

- [ ] Script is POSIX-safe where required (no bashisms in non-zsh sections)
- [ ] ANSI output goes to stderr, never stdout (so `--print` mode is unaffected)
- [ ] Installer (`install.sh`) is still idempotent if this touches it
- [ ] README / public guide updated if behaviour changed
