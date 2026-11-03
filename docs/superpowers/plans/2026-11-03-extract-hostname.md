# Quick Hostname Lookup Implementation Plan

> **For agentic workers:** Use executing-plans inline in this session. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retrieve a hostname directly from a healthy disk before archiving.

**Architecture:** A standalone Bash CLI uses a single read-only guestfish
listener. Built-in OS inspection retrieves hostnames; Bash validates and
selects the result. Shared logging writes diagnostics to stderr.

**Tech Stack:** Bash, libguestfs guestfish, util-linux, coreutils, apt-get.

**Spec:** `docs/superpowers/specs/2026-11-03-extract-hostname-design.md`

## Global Constraints

- One read-only libguestfs session; no host or FUSE mounts.
- Exactly one usable hostname on stdout; prompts and diagnostics on stderr.
- Keep all implementation within this approved task and current checkout.
- Generate a commit message; leave committing to the user as in prior turns.

## Review Focus

- Multiple installations: differing hostnames require explicit selection.
- Unknown or malformed names: never pass a fabricated ID to archiving.
- Failures/signals: close the listener and emit no successful result.
- Missing tools: prompt/install/recheck before reading the source disk.
- Physical-device safety: validate a whole block device and pass `--ro`.

## Task 1: Deliver the standalone lookup and usage documentation

**Files:** Create `extract-hostname.sh`, `tests/hostname.sh`; modify
`tests/run.sh`, `README.md`.

**Interfaces:** CLI consumes `--target DEVICE` or numbered disk selection;
returns one hostname and exit zero on success, otherwise stderr and nonzero.

- [x] Write fixture tests for Linux/Windows names, unknown/invalid names,
  multiple installations, selection, required-package decline/recheck,
  read-only session arguments, and cleanup after failure.
- [x] Run `bash tests/hostname.sh` and confirm failure because the script
  has not been implemented.
- [x] Implement the CLI with guestfish `inspect-os` and
  `inspect-get-hostname`, preserving a single listener through selection.
- [x] Document root usage, command substitution, dependencies and limits.
- [x] Run `bash tests/hostname.sh`, `./tests/run.sh`, Bash syntax checks,
  and `git diff --check`; expect all to pass.
- [x] Review the implementation against the spec and address important
  findings, then provide the generated commit message and verification results.

## Execution notes

- The existing full suite passed before implementation.
- The new test first failed because `extract-hostname.sh` was absent.
- The initial disk picker test exposed a whitespace-splitting error; an
  explicit space delimiter fixes parsing under the project's newline/tab IFS.
- Read-only review identified that implicit guestfish exit can hide appliance
  shutdown errors. Added a test that failed when shutdown was ignored, then
  implemented explicit `shutdown` followed by `exit`, preserving either failure.
- Review also clarified documentation for installations with unavailable names.
- No actual appliance or physical-disk test is available in this environment:
  guestfish is not installed. Fixture tests enforce the documented CLI boundary.
- Final verification: full `./tests/run.sh`, Bash syntax checks, and
  `git diff --check` passed. ShellCheck is not installed and was skipped.
