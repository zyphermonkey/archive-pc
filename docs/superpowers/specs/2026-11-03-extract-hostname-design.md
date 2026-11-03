# Quick hostname lookup

Approved in chat on 2026-11-03.

## Purpose

Read the stored hostname from a healthy source disk before imaging, so it
can be passed to `archive-disk.sh --pc-id`.

## Chosen approach

Use one read-only libguestfs appliance through guestfish. Direct host mounts
were considered for faster startup; libguestfs was selected for consistent
Windows/Linux inspection and source protection. Use guestfish inspection's
built-in hostname reader, avoiding full inventory collection, host mounts,
FUSE, and a separate Windows registry export.

## Interface

- New executable: `extract-hostname.sh [--target DEVICE] [--debug]`.
- If the target is omitted, show numbered whole disks with identifying details.
- Prompt before installing missing dependencies with root `apt-get`, then recheck.
- Write exactly one usable hostname to stdout, preserving its spelling.
- Send prompts, status, and errors to stderr.
- If installations have different usable hostnames, prompt for a selection.
- Unknown, missing, or archive-ID-incompatible hostnames cause a clear failure
  with no stdout hostname; do not silently invent or sanitize a name.
- Return nonzero on lookup, selection, or shutdown failure, so `&&` prevents
  archiving under an incorrect ID.
- Shut down the guestfish session on success, failure, and signals.
- Use the shared America/New_York logging convention.

## Limits

No imaging, filesystem repair, encryption unlocking, archive-script changes,
or bulk metadata extraction. Encrypted or unsupported installations may not
yield a hostname. Appliance startup remains part of the lookup cost.
