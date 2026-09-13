# archive-pc

`archive-pc` is a small Bash project for preserving personal-computer disks from a Debian-based live environment and then extracting useful inventory metadata without writing to the archived image.

The workflow is deliberately split:

- [`archive-disk.sh`](archive-disk.sh) reads a physical disk with GNU ddrescue, hashes and optionally compresses the image, and records how the archive was created.
- [`extract-metadata.sh`](extract-metadata.sh) inspects an existing raw or zstd-compressed image through read-only libguestfs mounts and creates Windows and Linux inventory reports.
- [`lib/common.sh`](lib/common.sh) provides shared logging, command recording, cleanup, JSON, and managed-README helpers.

This project is intended for personal archiving. It does not implement evidence handling, signing, or chain-of-custody procedures.

## Safety model

The acquisition script accepts only whole block devices, excludes the physical disk that contains the output directory when it can resolve that relationship, and asks for the PC ID before reading a source unless `--yes` is supplied. It never mounts the source disk.

The metadata script uses `guestfish` and `guestmount --ro`. It never runs filesystem repair tools. Paths read from a mounted guest must resolve beneath that mount, preventing a guest symlink from redirecting collection into the live system. `/etc/shadow` and Windows SAM password hashes are never collected. Network secrets are redacted by default.

Disk imaging is inherently consequential. Review the selected source and destination carefully, keep the source as idle as possible, and use stable device paths such as `/dev/disk/by-id/...` when available.

## Live environment dependencies

Install the core tools on a Debian-based live system:

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends \
  gddrescue jq zstd libguestfs-tools util-linux coreutils
```

These optional packages improve the collected inventory:

```bash
sudo apt-get install --no-install-recommends \
  smartmontools parted fdisk dmidecode lshw usbutils pciutils \
  libhivex-bin libevtx-utils qemu-utils rpm
```

Package names can differ between Debian releases. `archive-disk.sh` records optional tools as skipped instead of failing the disk image. `extract-metadata.sh` requires the libguestfs commands used for read-only inspection; Windows registry, event-log, RPM, and boot-history details remain best effort.

## Capture a disk

All three setup values can be selected interactively:

```bash
sudo ./archive-disk.sh
```

When `--pc-id` is omitted, the script prompts for a text identifier. When `--output` is omitted, it displays numbered writable, non-root filesystem mount points, their source and filesystem type, and their available space. The list also provides an option to enter a different parent directory. When neither `--target` nor `--all-internal-disks` is supplied, the script displays the available whole disks and prompts for an integer selection. The disk containing the selected archive output is excluded from the source-disk list when that relationship can be resolved.

All prompts can instead be supplied as command-line options for repeatable or unattended use:

```bash
sudo ./archive-disk.sh \
  --pc-id PC-001 \
  --output /mnt/archive \
  --compress zstd
```

`--output` is the parent directory. The script derives its working directory from `--pc-id`, so this example writes everything beneath `/mnt/archive/PC-001/`.

You can also inspect the devices yourself and select one explicitly:

```bash
lsblk --output NAME,PATH,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINTS
```

Preview the archive plan without creating directories or reading the full disk:

```bash
sudo ./archive-disk.sh \
  --pc-id PC-001 \
  --output /mnt/archive \
  --target /dev/disk/by-id/ata-example \
  --compress zstd \
  --dry-run
```

Run the capture:

```bash
sudo ./archive-disk.sh \
  --pc-id PC-001 \
  --output /mnt/archive \
  --target /dev/disk/by-id/ata-example \
  --compress zstd \
  --retry-count 3
```

The default keeps both the raw and compressed images. Add `--remove-raw-after-compress` to remove the raw image only after the compressed image has been hashed and that hash has been successfully verified. A raw image and its ddrescue map file can be reused to resume an interrupted capture.

ddrescue progress and errors are displayed live while also being saved under `ARCHIVE/logs/`. The retry pass first requests direct input I/O. If the device or operating system does not support it, the script records that failed attempt and automatically retries using buffered I/O. Compression output is also displayed live.

`--all-internal-disks` selects all non-removable whole disks except the resolved output disk. Explicit `--target` selection is easier to audit and is recommended when only one disk is being archived.

### Documentation-only runs

Use `--documentation-only` (or its shorter alias, `--docs-only`) to generate the archive directory, machine and disk inventory, command records, JSON summary, and README files without invoking ddrescue, hashing, or compression:

```bash
sudo ./archive-disk.sh \
  --pc-id PC-001-DEMO \
  --output /mnt/archive \
  --target /dev/disk/by-id/ata-example \
  --documentation-only
```

This mode writes documentation, unlike `--dry-run`, which only prints a plan and does not create anything. It does not require root when the output directory is writable, although privileged inventory commands such as `dmidecode`, `smartctl`, and `blkid` may then be recorded as unavailable. The structured summary records `run.mode` as `documentation_only`, and every selected disk records `capture_status` as `not_run`.

### Limited validation captures

Use `--max-read-gb NUMBER` to capture only the requested number of decimal gigabytes from the beginning of each selected disk. One GB is exactly 1,000,000,000 bytes. Up to nine decimal places are accepted, so `--max-read-gb 0.25` captures the first 250,000,000 bytes. Limited images include the range in their names so they cannot be mistaken for full images:

```bash
sudo ./archive-disk.sh \
  --pc-id PC-001-TEST \
  --output /mnt/archive \
  --target /dev/disk/by-id/ata-example \
  --max-read-gb 2 \
  --compress none
```

This example creates `PC-001-TEST.first-2GB.img`, its ddrescue map, checksum, logs, and documentation. The byte limit is passed to both ddrescue passes and is recorded in the JSON summary. If necessary, the effective capture range is rounded down to the source disk's logical sector size; both the requested and effective byte counts remain documented. Compression and raw-image retention options work normally with limited captures.

## Extract metadata

Keeping the raw image makes this step faster. When a compressed image is supplied, the script prefers the corresponding `.img` file if it exists. Otherwise it checks the zstd frame's decompressed size against available space and creates a temporary raw image under `METADATA/work/`.

```bash
sudo ./extract-metadata.sh \
  --pc-id PC-001 \
  --root /mnt/archive/PC-001 \
  --image /mnt/archive/PC-001/ARCHIVE/PC-001.img.zst
```

Use `--windows` or `--linux` to limit extraction after detection. `--all` is the default. `--keep-work-image` preserves a temporary decompressed image. `--no-redact-secrets` is available for an archive where retaining network configuration secrets is intentional; the resulting metadata should then be protected as sensitive.

## Generated archive layout

```text
PC-001/
├── README.md
├── ARCHIVE/
│   ├── README.md
│   ├── PC-001.img
│   ├── PC-001.img.zst
│   ├── PC-001.img.raw.sha256
│   ├── PC-001.img.zst.sha256
│   ├── PC-001.ddrescue.map
│   ├── PC-001.archive.json
│   ├── commands.jsonl
│   ├── disks/
│   ├── hardware/
│   ├── livecd/
│   └── logs/
└── METADATA/
    ├── README.md
    ├── PC-001.metadata.json
    ├── detected-os.json
    ├── commands.jsonl
    ├── linux/
    ├── logs/
    ├── mount/
    └── windows/
```

`VM/` and `RECOVERED/` are reserved for future workflows; these scripts do not create or modify them. Each script updates only its own marked block in the archived PC's top-level README, preserving manual notes and the other script's block.

## Command records

Every significant external operation records one JSON object per line in `commands.jsonl`, including `America/New_York` start and completion times, timezone, duration, exit code, and the paths used for standard output and standard error. ISO 8601 numeric offsets distinguish EST (`-05:00`) from EDT (`-04:00`). The generated summary JSON files are validated with `jq` before the run completes.

## Development checks

Run the self-contained fixture tests with:

```bash
./tests/run.sh
```

If ShellCheck is installed, also run:

```bash
shellcheck archive-disk.sh extract-metadata.sh lib/common.sh tests/run.sh
```
